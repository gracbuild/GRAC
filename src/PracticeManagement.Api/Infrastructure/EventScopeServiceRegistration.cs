// =====================================================================
// EventScopeServiceRegistration
//
// One-line extension so Program.cs adoption is a small, reviewable diff.
// Mirrors WorkflowServiceRegistration.
//
// Wire-up in Program.cs (added alongside AddPracticeWorkflowService()):
//     builder.Services.AddPracticeEventScopeService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class EventScopeServiceRegistration
{
    public static IServiceCollection AddPracticeEventScopeService(this IServiceCollection services)
    {
        services.AddScoped<IEventScopeService, EventScopeService>();

        // Drains the migration-131 auto-raise queue on a timer. Registered
        // here rather than in Program.cs so adopting the whole feature stays
        // a one-line diff. Disable with EventAutoRaise:Enabled = false --
        // no redeploy needed, and the queue can then be drained by hand with
        // EXEC grac_practice.sp_event_autoraise_drain.
        services.AddHostedService<EventAutoRaiseWorker>();
        return services;
    }
}
