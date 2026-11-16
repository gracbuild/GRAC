// =====================================================================
// TaskNotificationWorker  (Task Centre v2, Phase 3 — BRD §13)
//
// Runs grac_practice.sp_task_notification_sweep on a timer, recording who
// should be told that a task is Due Soon, Breached, or past its
// escalation point.
//
// WHY A BackgroundService AND NOT HANGFIRE
// ----------------------------------------
// Identical reasoning to EventAutoRaiseWorker, which this deliberately
// mirrors line for line: docs/QUESTIONS.md Q002 approved Hangfire but on
// the condition that the package arrives in a dedicated PR touching
// .csproj only. BackgroundService ships with ASP.NET Core, so this adds
// no dependency and does not pre-empt that PR. If Hangfire lands, this
// worker becomes a recurring job with the same body.
//
// WHY A TIMER AND NOT AN ON-DEMAND SWEEP
// --------------------------------------
// An SLA warning that only fires when somebody happens to open the Task
// Centre is not a control — the whole point is to reach a person who is
// NOT looking at the screen. The timer fires whether or not anyone is
// watching, exactly as EventAutoRaiseWorker argues for the event queue.
//
// RELATIONSHIP TO sp_task_overdue_sweep (037)
// -------------------------------------------
// That procedure transitions a breached task to Escalated. This worker
// decides who should be TOLD. They are independent, can run on different
// schedules, and neither is aware of the other: the transition is guarded
// by escalated_at IS NULL, the notification by the outbox dedupe index.
// 037 is untouched by Phase 3.
//
// FAILURE POSTURE
// ---------------
// The loop must never take the API down. Every pass is wrapped; the
// exception is logged and the loop continues. The sweep itself parks
// per-task failures in practice_audit_trace as NOTIFY_SWEEP_ERROR, so one
// malformed task cannot stall the batch. Sweeping is idempotent, so a
// crash mid-pass costs nothing but a retry.
//
// Wire-up (to be added by reviewer with approval — charter §5 keeps
// Program.cs off-limits without an explicit request):
//     builder.Services.AddPracticeTaskNotificationService();
//     builder.Services.AddHostedService<TaskNotificationWorker>();
//
// ASSET SCHEDULER (migration 437 -- registered in Program.cs on request)
// ----------------------------------------------------------------------
// The same loop also runs the Asset & Contract scheduler pass
// (IAssetConfigService.RunSchedulerAsync -> grac_practice.sp_asset_scheduler_run):
// contract effective dates, renewal occurrences, periodic attestation runs
// and the asset / contract reminders and escalations. It works in dates, so
// it runs at most every AssetSchedulerIntervalMinutes (default 60), not on
// every 5-minute tick, and it is guarded by its own try/catch so neither job
// can stop the other. The procedure takes an application lock: a second API
// instance, or "Run now" on the screen, skips instead of running twice.
// 438 adds the recurring asset activities (calibration, maintenance,
// inspection, licence renewal tasks) to the same pass.
// AssetSchedulerEnabled=false leaves it to SQL Agent:
//     EXEC grac_practice.sp_asset_scheduler_run;
//
// SCHEDULED OBLIGATION TASKS (migration 449)
// ------------------------------------------
// A third pass, same shape as the asset one: every
// ScheduledObligationTasksIntervalMinutes (default 60) it runs
// grac_practice.sp_schedule_obligation_tasks_generate, which raises the
// Task Centre task for each scheduled Execution / Assurance obligation
// occurrence due TODAY (UTC) -- on the due date, not ahead of it. The
// procedure claims each rule + date once and takes an application lock,
// so repeated passes and several API instances never raise twice.
// ScheduledObligationTasksEnabled=false leaves it to SQL Agent:
//     EXEC grac_practice.sp_schedule_obligation_tasks_generate;
//
// ASSET REPORT DELIVERIES (migration 453)
// ---------------------------------------
// A fourth pass: every AssetReportDeliveryIntervalMinutes (default 60) it
// runs IAssetConfigService.RunReportDeliveriesAsync, which starts the
// deliveries of the report schedules due today (one per schedule and day),
// checks every recipient at delivery time and produces the report for each
// recipient under that recipient permissions and View Data Scope. The rows
// are produced in the API, so there is no SQL Agent equivalent;
// AssetReportDeliveryEnabled=false stops scheduled deliveries ("Run now" on
// the screen still works).
//
// EVIDENCE EXPIRY (migration 477)
// -------------------------------
// A fifth pass: every EvidenceExpiryIntervalMinutes (default 60) it runs
// grac_practice.sp_evidence_expiry_sweep, which raises an "expiring" notice
// for Evidence Center items whose validity ends within EvidenceExpiryDays
// (default 30) and an "expired" one when it has ended, addressed to the
// item's owner and uploader (My Notifications). Idempotent.
// EvidenceExpiryEnabled=false leaves it to SQL Agent:
//     EXEC grac_practice.sp_evidence_expiry_sweep;
//
// EVIDENCE AUTOMATION (migration 530)
// -----------------------------------
// Two more passes, each guarded on its own like the ones above:
//   * file drop -- every EvidenceFileDropIntervalMinutes (default 5) it
//     picks up the files written to the watched folders of the active
//     file-drop sources (IEvidenceAutomationService.RunFileDropAsync). Off
//     when EvidenceAutomation:FileDropRoot is empty. Files are never
//     deleted: stored ones move to _processed/, refused ones to _failed/.
//   * not received -- every EvidenceAutomationIntervalMinutes (default 60)
//     it runs grac_practice.sp_evidence_automation_missing_sweep, which
//     raises one notice per missed period to the source owner and the
//     obligation owner (My Notifications). Idempotent; application lock.
// EvidenceAutomationEnabled=false leaves the sweep to SQL Agent:
//     EXEC grac_practice.sp_evidence_automation_missing_sweep;
//   * email (531) -- every EvidenceEmailIntervalMinutes (default 5) it reads
//     the intake mailbox over IMAP (IEvidenceAutomationService.RunEmailAsync).
//     Off while EvidenceAutomation:Email:Host is empty. Read mail is moved to
//     the processed / failed folders, never deleted.
//
// TPRM MONITORING (migrations 486-490)
// ------------------------------------
// A sixth pass: every TprmMonitoringIntervalMinutes (default 60) it runs
// grac_practice.sp_tprm_monitoring_sweep, which raises third-party reviews
// that are due: periodic reviews, contract / certification / risk
// acceptance expiry, reassessment flags, overdue remediation and new
// assurance findings on a live engagement's vendor or practice instances.
// Each review is raised once per source key, so the pass is idempotent.
// TprmMonitoringEnabled=false leaves it to SQL Agent:
//     EXEC grac_practice.sp_tprm_monitoring_sweep;
// =====================================================================
namespace PracticeManagement.Api.Services;

public sealed class TaskNotificationOptions
{
    public const string SectionName = "TaskNotification";

    /// <summary>Set false to stop the worker without redeploying. The sweep
    /// procedure remains callable by hand or from SQL Agent.</summary>
    public bool Enabled { get; set; } = true;

    /// <summary>Seconds between passes. Longer than the event worker's 30s:
    /// SLA thresholds move in hours and days, so a tighter loop would
    /// only add load without changing when anyone is told.</summary>
    public int IntervalSeconds { get; set; } = 300;

    /// <summary>Tasks examined per pass. Bounds how long one iteration can
    /// hold a connection.</summary>
    public int BatchSize { get; set; } = 200;

    /// <summary>Delay before the first pass, so startup migrations and
    /// warm-up finish first.</summary>
    public int StartupDelaySeconds { get; set; } = 45;

    /// <summary>Restrict to one organisation. NULL sweeps every organisation,
    /// which is the normal deployment.</summary>
    public long? OrganizationId { get; set; }

    /// <summary>437: run the Asset & Contract scheduler pass from this worker.</summary>
    public bool AssetSchedulerEnabled { get; set; } = true;

    /// <summary>437: minutes between asset scheduler passes (reminders are
    /// date-based; an hour is ample).</summary>
    public int AssetSchedulerIntervalMinutes { get; set; } = 60;

    /// <summary>449: raise tasks for scheduled obligation occurrences due today.</summary>
    public bool ScheduledObligationTasksEnabled { get; set; } = true;

    /// <summary>449: minutes between passes. The work is per day; an hour
    /// means a task appears within the hour after the UTC day starts.</summary>
    public int ScheduledObligationTasksIntervalMinutes { get; set; } = 60;

    /// <summary>453: deliver the asset report schedules due today.</summary>
    public bool AssetReportDeliveryEnabled { get; set; } = true;

    /// <summary>453: minutes between delivery passes (schedules are per day).</summary>
    public int AssetReportDeliveryIntervalMinutes { get; set; } = 60;
    /// <summary>477: raise Evidence Center expiry notices.</summary>
    public bool EvidenceExpiryEnabled { get; set; } = true;
    /// <summary>477: minutes between expiry passes (validity is per day).</summary>
    public int EvidenceExpiryIntervalMinutes { get; set; } = 60;
    /// <summary>477: "expiring" = valid-to within this many days.</summary>
    public int EvidenceExpiryDays { get; set; } = 30;
    /// <summary>486-490: raise due Third-Party Risk reviews.</summary>
    public bool TprmMonitoringEnabled { get; set; } = true;
    /// <summary>486-490: minutes between monitoring passes (dates are per day).</summary>
    public int TprmMonitoringIntervalMinutes { get; set; } = 60;
    /// <summary>530: raise "automated evidence not received" notices.</summary>
    public bool EvidenceAutomationEnabled { get; set; } = true;
    /// <summary>530: minutes between not-received passes (cadences are per day).</summary>
    public int EvidenceAutomationIntervalMinutes { get; set; } = 60;
    /// <summary>530: pick up file-drop evidence (no-op while EvidenceAutomation:FileDropRoot is empty).</summary>
    public bool EvidenceFileDropEnabled { get; set; } = true;
    /// <summary>530: minutes between file-drop passes.</summary>
    public int EvidenceFileDropIntervalMinutes { get; set; } = 5;
    /// <summary>531: read the evidence intake mailbox (no-op while EvidenceAutomation:Email:Host is empty).</summary>
    public bool EvidenceEmailEnabled { get; set; } = true;
    /// <summary>531: minutes between mailbox passes.</summary>
    public int EvidenceEmailIntervalMinutes { get; set; } = 5;
}

public sealed class TaskNotificationWorker(
    IServiceScopeFactory scopeFactory,
    IConfiguration configuration,
    ILogger<TaskNotificationWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var options = new TaskNotificationOptions();
        configuration.GetSection(TaskNotificationOptions.SectionName).Bind(options);

        if (!options.Enabled && !options.AssetSchedulerEnabled && !options.ScheduledObligationTasksEnabled && !options.AssetReportDeliveryEnabled
            && !options.EvidenceExpiryEnabled && !options.TprmMonitoringEnabled
            && !options.EvidenceAutomationEnabled && !options.EvidenceFileDropEnabled && !options.EvidenceEmailEnabled)
        {
            logger.LogInformation(
                "TaskNotificationWorker disabled by configuration; SLA notifications must be swept manually via sp_task_notification_sweep.");
            return;
        }
        if (!options.Enabled)
            logger.LogInformation("TaskNotificationWorker: task SLA sweep disabled by configuration; only the scheduler passes (asset, scheduled obligations) run.");

        var assetInterval = TimeSpan.FromMinutes(Math.Clamp(options.AssetSchedulerIntervalMinutes, 5, 1440));
        DateTime? lastAssetRun = null;   // 437
        var obligationInterval = TimeSpan.FromMinutes(Math.Clamp(options.ScheduledObligationTasksIntervalMinutes, 5, 1440));
        DateTime? lastObligationRun = null;   // 449
        var reportInterval = TimeSpan.FromMinutes(Math.Clamp(options.AssetReportDeliveryIntervalMinutes, 5, 1440));
        DateTime? lastReportRun = null;   // 453
        var evidenceInterval = TimeSpan.FromMinutes(Math.Clamp(options.EvidenceExpiryIntervalMinutes, 5, 1440));
        DateTime? lastEvidenceRun = null;   // 477
        var tprmInterval = TimeSpan.FromMinutes(Math.Clamp(options.TprmMonitoringIntervalMinutes, 5, 1440));
        DateTime? lastTprmRun = null;   // 486-490
        var automationInterval = TimeSpan.FromMinutes(Math.Clamp(options.EvidenceAutomationIntervalMinutes, 5, 1440));
        DateTime? lastAutomationRun = null;   // 530
        var fileDropInterval = TimeSpan.FromMinutes(Math.Clamp(options.EvidenceFileDropIntervalMinutes, 1, 1440));
        DateTime? lastFileDropRun = null;   // 530
        var emailInterval = TimeSpan.FromMinutes(Math.Clamp(options.EvidenceEmailIntervalMinutes, 1, 1440));
        DateTime? lastEmailRun = null;   // 531

        var interval = TimeSpan.FromSeconds(Math.Clamp(options.IntervalSeconds, 30, 86400));

        logger.LogInformation(
            "TaskNotificationWorker starting: every {Interval}s, batch {BatchSize}, first pass in {Delay}s.",
            interval.TotalSeconds, options.BatchSize, options.StartupDelaySeconds);

        try
        {
            await Task.Delay(TimeSpan.FromSeconds(Math.Clamp(options.StartupDelaySeconds, 0, 600)), stoppingToken);
        }
        catch (OperationCanceledException) { return; }

        using var timer = new PeriodicTimer(interval);

        do
        {
            if (options.Enabled)
            try
            {
                // A new scope per pass: ITaskNotificationService is scoped,
                // and holding one for the app's lifetime would pin a
                // connection.
                using var scope = scopeFactory.CreateScope();
                var service = scope.ServiceProvider.GetRequiredService<ITaskNotificationService>();

                var result = await service.SweepAsync(options.OrganizationId, options.BatchSize, stoppingToken);

                // Only log when work happened. In a steady state the sweep
                // enqueues nothing — every threshold already recorded — and
                // logging that every 5 minutes would bury everything else.
                if (result.Enqueued > 0)
                    logger.LogInformation(
                        "TaskNotificationWorker recorded {Enqueued} notification obligation(s) across {Scanned} task(s).",
                        result.Enqueued, result.TasksScanned);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;   // shutting down
            }
            catch (Exception ex)
            {
                // Swallow deliberately: a database blip or a misconfigured
                // organization must not stop the loop or fault the host.
                logger.LogError(ex, "TaskNotificationWorker pass failed; will retry on the next interval.");
            }

            // 437: the Asset & Contract scheduler pass, at most every assetInterval.
            if (options.AssetSchedulerEnabled && (lastAssetRun is null || DateTime.UtcNow - lastAssetRun.Value >= assetInterval))
            {
                lastAssetRun = DateTime.UtcNow;   // also after a failure: retry on the next interval, not every tick
                try
                {
                    using var scope = scopeFactory.CreateScope();
                    var assets = scope.ServiceProvider.GetService<IAssetConfigService>();
                    if (assets is not null)
                    {
                        var run = await assets.RunSchedulerAsync(options.OrganizationId, "SCHEDULED", "scheduler", stoppingToken);
                        run.TryGetValue("result", out var result);
                        run.TryGetValue("notificationsQueued", out var queued);
                        run.TryGetValue("renewalsStarted", out var renewals);
                        run.TryGetValue("errorCount", out var errors);
                        run.TryGetValue("tasksCreated", out var tasks);   // 438: recurring asset activities
                        if (Convert.ToInt32(queued ?? 0) > 0 || Convert.ToInt32(renewals ?? 0) > 0 || Convert.ToInt32(errors ?? 0) > 0
                            || Convert.ToInt32(tasks ?? 0) > 0)
                            logger.LogInformation(
                                "Asset scheduler pass {Result}: {Queued} notification(s), {Renewals} renewal(s) started, {Tasks} activity task(s), {Errors} error(s).",
                                result, queued, renewals, tasks, errors);
                    }
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    break;   // shutting down
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "Asset scheduler pass failed; will retry on the next interval.");
                }
            }

            // 449: scheduled obligation tasks, at most every obligationInterval.
            if (options.ScheduledObligationTasksEnabled
                && (lastObligationRun is null || DateTime.UtcNow - lastObligationRun.Value >= obligationInterval))
            {
                lastObligationRun = DateTime.UtcNow;   // also after a failure: retry on the next interval
                try
                {
                    using var scope = scopeFactory.CreateScope();
                    var service = scope.ServiceProvider.GetRequiredService<ITaskNotificationService>();
                    var run = await service.GenerateScheduledObligationTasksAsync(options.OrganizationId, null, stoppingToken);
                    if (run.TasksCreated > 0 || run.ErrorCount > 0)
                        logger.LogInformation(
                            "Scheduled obligation pass {Result} for {RunDate:yyyy-MM-dd}: {Tasks} task(s) raised, {Errors} error(s).",
                            run.Result, run.RunDate, run.TasksCreated, run.ErrorCount);
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    break;   // shutting down
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "Scheduled obligation task pass failed; will retry on the next interval.");
                }
            }

            // 453: asset report deliveries, at most every reportInterval.
            if (options.AssetReportDeliveryEnabled && (lastReportRun is null || DateTime.UtcNow - lastReportRun.Value >= reportInterval))
            {
                lastReportRun = DateTime.UtcNow;   // also after a failure: retry on the next interval
                try
                {
                    using var scope = scopeFactory.CreateScope();
                    var assets = scope.ServiceProvider.GetService<IAssetConfigService>();
                    if (assets is not null)
                    {
                        var run = await assets.RunReportDeliveriesAsync(options.OrganizationId, stoppingToken);
                        if (run.Deliveries > 0)
                            logger.LogInformation(
                                "Asset report delivery pass: {Deliveries} delivery(ies), {Delivered} file(s) delivered, {Skipped} recipient(s) skipped, {Failed} failed.",
                                run.Deliveries, run.Delivered, run.Skipped, run.Failed);
                    }
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    break;   // shutting down
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "Asset report delivery pass failed; will retry on the next interval.");
                }
            }

            // 477: Evidence Center expiry notices, at most every evidenceInterval.
            if (options.EvidenceExpiryEnabled && (lastEvidenceRun is null || DateTime.UtcNow - lastEvidenceRun.Value >= evidenceInterval))
            {
                lastEvidenceRun = DateTime.UtcNow;   // also after a failure: retry on the next interval
                try
                {
                    using var scope = scopeFactory.CreateScope();
                    var evidence = scope.ServiceProvider.GetService<IEvidenceCenterService>();
                    if (evidence is not null)
                    {
                        var run = await evidence.RunExpirySweepAsync(options.OrganizationId, options.EvidenceExpiryDays, stoppingToken);
                        if (run.ExpiringRaised > 0 || run.ExpiredRaised > 0)
                            logger.LogInformation(
                                "Evidence expiry pass: {Expiring} expiring and {Expired} expired notice(s) raised.",
                                run.ExpiringRaised, run.ExpiredRaised);
                    }
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    break;   // shutting down
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "Evidence expiry pass failed; will retry on the next interval.");
                }
            }

            // 486-490: Third-Party Risk monitoring, at most every tprmInterval.
            if (options.TprmMonitoringEnabled && (lastTprmRun is null || DateTime.UtcNow - lastTprmRun.Value >= tprmInterval))
            {
                lastTprmRun = DateTime.UtcNow;   // also after a failure: retry on the next interval
                try
                {
                    using var scope = scopeFactory.CreateScope();
                    var tprm = scope.ServiceProvider.GetService<ITprmService>();
                    if (tprm is not null)
                    {
                        var raised = await tprm.RunMonitoringSweepAsync(options.OrganizationId, stoppingToken);
                        if (raised > 0)
                            logger.LogInformation("TPRM monitoring pass: {Raised} review(s) raised.", raised);
                    }
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    break;   // shutting down
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "TPRM monitoring pass failed; will retry on the next interval.");
                }
            }

            // 530: evidence automation -- file drop pick-up, at most every fileDropInterval.
            if (options.EvidenceFileDropEnabled && (lastFileDropRun is null || DateTime.UtcNow - lastFileDropRun.Value >= fileDropInterval))
            {
                lastFileDropRun = DateTime.UtcNow;   // also after a failure: retry on the next interval
                try
                {
                    using var scope = scopeFactory.CreateScope();
                    var automation = scope.ServiceProvider.GetService<IEvidenceAutomationService>();
                    if (automation is not null)
                    {
                        var run = await automation.RunFileDropAsync(options.OrganizationId, stoppingToken);
                        if (run.Received > 0 || run.Failed > 0)
                            logger.LogInformation(
                                "Evidence file drop pass: {Received} file(s) received, {Failed} refused, across {Bindings} source(s).",
                                run.Received, run.Failed, run.Bindings);
                    }
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    break;   // shutting down
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "Evidence file drop pass failed; will retry on the next interval.");
                }
            }

            // 531: evidence automation -- intake mailbox, at most every emailInterval.
            if (options.EvidenceEmailEnabled && (lastEmailRun is null || DateTime.UtcNow - lastEmailRun.Value >= emailInterval))
            {
                lastEmailRun = DateTime.UtcNow;   // also after a failure: retry on the next interval
                try
                {
                    using var scope = scopeFactory.CreateScope();
                    var automation = scope.ServiceProvider.GetService<IEvidenceAutomationService>();
                    if (automation is not null)
                    {
                        var run = await automation.RunEmailAsync(stoppingToken);
                        if (run.Received > 0 || run.Refused > 0)
                            logger.LogInformation(
                                "Evidence email pass: {Messages} mail(s) read, {Received} stored, {Refused} refused.",
                                run.Messages, run.Received, run.Refused);
                    }
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    break;   // shutting down
                }
                catch (Exception ex)
                {
                    // Mailbox unreachable, wrong password: logged, retried next interval.
                    logger.LogError(ex, "Evidence email pass failed; will retry on the next interval.");
                }
            }

            // 530: evidence automation -- "not received" notices, at most every automationInterval.
            if (options.EvidenceAutomationEnabled && (lastAutomationRun is null || DateTime.UtcNow - lastAutomationRun.Value >= automationInterval))
            {
                lastAutomationRun = DateTime.UtcNow;   // also after a failure: retry on the next interval
                try
                {
                    using var scope = scopeFactory.CreateScope();
                    var automation = scope.ServiceProvider.GetService<IEvidenceAutomationService>();
                    if (automation is not null)
                    {
                        var run = await automation.RunMissingSweepAsync(options.OrganizationId, stoppingToken);
                        if (run.NoticesRaised > 0)
                            logger.LogInformation("Evidence automation pass: {Raised} not-received notice(s) raised.", run.NoticesRaised);
                    }
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    break;   // shutting down
                }
                catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 2812)
                {
                    // A database without 530: nothing to sweep yet.
                    logger.LogDebug("Evidence automation pass skipped: migration 530 not applied.");
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "Evidence automation pass failed; will retry on the next interval.");
                }
            }
        }
        while (await SafeWaitAsync(timer, stoppingToken));

        logger.LogInformation("TaskNotificationWorker stopped.");
    }

    private static async Task<bool> SafeWaitAsync(PeriodicTimer timer, CancellationToken token)
    {
        try { return await timer.WaitForNextTickAsync(token); }
        catch (OperationCanceledException) { return false; }
    }
}
