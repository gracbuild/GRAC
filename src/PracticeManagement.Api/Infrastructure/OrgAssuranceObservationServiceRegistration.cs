// =====================================================================
// OrgAssuranceObservationServiceRegistration
//
// One-line DI extension for Program.cs, matching
// OrgAssuranceExecutionServiceRegistration.
//
// Wire-up:
//     builder.Services.AddOrgAssuranceObservationService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class OrgAssuranceObservationServiceRegistration
{
    public static IServiceCollection AddOrgAssuranceObservationService(this IServiceCollection services)
    {
        services.AddScoped<IOrgAssuranceObservationService, OrgAssuranceObservationService>();
        return services;
    }
}
