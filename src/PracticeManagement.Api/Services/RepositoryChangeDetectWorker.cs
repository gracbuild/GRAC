// =====================================================================
// RepositoryChangeDetectWorker  (statement subscription copy model, phase 3)
//
// Runs grac_practice.sp_repository_change_detect on a timer: compares every
// organization's copy of its subscribed releases with grac_new and records
// each difference as a pending change for the release owner / an
// organization admin to approve, with a notification.
//
// Sir's decision 9 (2026-09-28): detection is SCHEDULED -- no on-demand
// "Check for updates" and no publish hook on grac_new, which belongs to
// Control Management. Default: once a day.
//
// Mirrors TaskNotificationWorker / EventAutoRaiseWorker (BackgroundService,
// no Hangfire -- docs/QUESTIONS.md Q002). An environment that prefers SQL
// Agent sets RepositoryChangeDetect:Enabled = false and schedules
//     EXEC grac_practice.sp_repository_change_detect;
//
// FAILURE POSTURE: every pass is wrapped; a failure is logged and the next
// interval retries. Detection is idempotent (a difference already pending,
// approved or rejected is never raised twice), so a crash mid-pass costs
// only a retry.
// =====================================================================
namespace PracticeManagement.Api.Services;

public sealed class RepositoryChangeDetectOptions
{
    public const string SectionName = "RepositoryChangeDetect";

    /// <summary>Set false to stop the worker without redeploying.</summary>
    public bool Enabled { get; set; } = true;

    /// <summary>Seconds between passes. Default one day.</summary>
    public int IntervalSeconds { get; set; } = 86400;

    /// <summary>Delay before the first pass after start-up.</summary>
    public int StartupDelaySeconds { get; set; } = 300;

    /// <summary>Restrict to one organization. NULL = every organization.</summary>
    public long? OrganizationId { get; set; }
}

public sealed class RepositoryChangeDetectWorker(
    IServiceScopeFactory scopeFactory,
    IConfiguration configuration,
    ILogger<RepositoryChangeDetectWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var options = new RepositoryChangeDetectOptions();
        configuration.GetSection(RepositoryChangeDetectOptions.SectionName).Bind(options);

        if (!options.Enabled)
        {
            logger.LogInformation(
                "RepositoryChangeDetectWorker disabled by configuration; run grac_practice.sp_repository_change_detect from SQL Agent instead.");
            return;
        }

        var interval = TimeSpan.FromSeconds(Math.Clamp(options.IntervalSeconds, 300, 604800));
        logger.LogInformation("RepositoryChangeDetectWorker starting: every {Interval}s, first pass in {Delay}s.",
            interval.TotalSeconds, options.StartupDelaySeconds);

        try
        {
            await Task.Delay(TimeSpan.FromSeconds(Math.Clamp(options.StartupDelaySeconds, 0, 3600)), stoppingToken);
        }
        catch (OperationCanceledException) { return; }

        using var timer = new PeriodicTimer(interval);
        do
        {
            try
            {
                using var scope = scopeFactory.CreateScope();
                var service = scope.ServiceProvider.GetRequiredService<IRepositoryChangeService>();
                var result = await service.DetectAsync(options.OrganizationId, stoppingToken);
                if (result.RaisedCount > 0)
                    logger.LogInformation(
                        "RepositoryChangeDetectWorker raised {Raised} pending repository change(s), {Notified} notification(s).",
                        result.RaisedCount, result.NotifiedCount);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "RepositoryChangeDetectWorker pass failed; will retry on the next interval.");
            }
        }
        while (await SafeWaitAsync(timer, stoppingToken));

        logger.LogInformation("RepositoryChangeDetectWorker stopped.");
    }

    private static async Task<bool> SafeWaitAsync(PeriodicTimer timer, CancellationToken token)
    {
        try { return await timer.WaitForNextTickAsync(token); }
        catch (OperationCanceledException) { return false; }
    }
}
