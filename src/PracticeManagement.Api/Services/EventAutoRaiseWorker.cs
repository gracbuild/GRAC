// =====================================================================
// EventAutoRaiseWorker
//
// Drains grac_practice.event_autoraise_queue on a timer, turning the
// entries the migration-131 triggers enqueue into event instances.
//
// WHY A BackgroundService AND NOT HANGFIRE
// ---------------------------------------
// docs/QUESTIONS.md Q002 approved Hangfire, but with the explicit condition
// that the package addition arrives in a dedicated PR touching .csproj
// only. BackgroundService ships with ASP.NET Core, so this needs no new
// dependency and does not pre-empt that PR. Q002's option 2 named this
// exact approach. If and when Hangfire lands, this worker becomes a
// recurring job with the same body.
//
// WHY NOT DRAIN ON INBOX LOAD
// ---------------------------
// That would put a write behind a GET, so the queue would only ever move
// when somebody happened to open the screen -- and an onboarding checklist
// that appears only once a human looks for it is not an assurance control.
// A timer fires whether or not anyone is watching.
//
// FAILURE POSTURE
// ---------------
// The loop must never take the API down. Every iteration is wrapped, the
// exception is logged and the loop continues; a permanently broken entry is
// parked as Failed by the procedure itself after three attempts, so a bad
// row cannot spin forever. Draining is idempotent, so a crash mid-queue
// costs nothing but a retry.
// =====================================================================
namespace PracticeManagement.Api.Services;

public sealed class EventAutoRaiseOptions
{
    public const string SectionName = "EventAutoRaise";

    /// <summary>Set false to stop the worker without redeploying.</summary>
    public bool Enabled { get; set; } = true;

    /// <summary>Seconds between passes. Kept short so a new employee's checklist appears promptly.</summary>
    public int IntervalSeconds { get; set; } = 30;

    /// <summary>Entries per pass. Bounds how long one iteration can hold a connection.</summary>
    public int BatchSize { get; set; } = 200;

    /// <summary>Delay before the first pass, so startup migrations and warm-up finish first.</summary>
    public int StartupDelaySeconds { get; set; } = 20;
}

public sealed class EventAutoRaiseWorker(
    IServiceScopeFactory scopeFactory,
    IConfiguration configuration,
    ILogger<EventAutoRaiseWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var options = new EventAutoRaiseOptions();
        configuration.GetSection(EventAutoRaiseOptions.SectionName).Bind(options);

        if (!options.Enabled)
        {
            logger.LogInformation("EventAutoRaiseWorker disabled by configuration; queue must be drained manually.");
            return;
        }

        var interval = TimeSpan.FromSeconds(Math.Clamp(options.IntervalSeconds, 5, 3600));

        logger.LogInformation(
            "EventAutoRaiseWorker starting: every {Interval}s, batch {BatchSize}, first pass in {Delay}s.",
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
                // A new scope per pass: IEventScopeService is scoped, and
                // holding one for the app's lifetime would pin a connection.
                using var scope = scopeFactory.CreateScope();
                var service = scope.ServiceProvider.GetRequiredService<IEventScopeService>();

                var processed = await service.DrainAutoRaiseQueueAsync(
                    organizationId: null, maxRows: options.BatchSize, stoppingToken);

                // Only log when work happened -- an idle queue every 30s would
                // bury everything else in the log.
                if (processed > 0)
                    logger.LogInformation("EventAutoRaiseWorker processed {Processed} auto-raise queue entr{Suffix}.",
                        processed, processed == 1 ? "y" : "ies");
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;   // shutting down
            }
            catch (Exception ex)
            {
                // Swallow deliberately: a database blip or a misconfigured
                // organization must not stop the loop or fault the host.
                logger.LogError(ex, "EventAutoRaiseWorker pass failed; will retry on the next interval.");
            }
        }
        while (await SafeWaitAsync(timer, stoppingToken));

        logger.LogInformation("EventAutoRaiseWorker stopped.");
    }

    private static async Task<bool> SafeWaitAsync(PeriodicTimer timer, CancellationToken token)
    {
        try { return await timer.WaitForNextTickAsync(token); }
        catch (OperationCanceledException) { return false; }
    }
}
