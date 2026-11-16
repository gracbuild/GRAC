// =====================================================================
// EvidenceAutomationServiceRegistration  (migration 530)
//
// The service alone gives the configuration / review / intake APIs. The
// timer-driven passes (file drop pick-up, "not received" notices) run in
// the existing TaskNotificationWorker, which resolves this service per
// pass with GetService -- so an install that does not register it simply
// skips those passes.
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class EvidenceAutomationServiceRegistration
{
    public static IServiceCollection AddPracticeEvidenceAutomationService(this IServiceCollection services)
    {
        services.AddScoped<IEvidenceAutomationService, EvidenceAutomationService>();
        return services;
    }
}
