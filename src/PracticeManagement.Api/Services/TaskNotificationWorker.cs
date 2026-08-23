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

        if (!options.Enabled)
        {
            logger.LogInformation(
                "TaskNotificationWorker disabled by configuration; SLA notifications must be swept manually via sp_task_notification_sweep.");
            return;
        }

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
