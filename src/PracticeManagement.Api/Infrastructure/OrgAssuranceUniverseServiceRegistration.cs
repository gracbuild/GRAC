// =====================================================================
// OrgAssuranceUniverseServiceRegistration (577)
//
// One-line DI extension for Program.cs, matching
// OrgAssuranceReportServiceRegistration.
//
// Wire-up:
//     builder.Services.AddOrgAssuranceUniverseService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class OrgAssuranceUniverseServiceRegistration
{
    public static IServiceCollection AddOrgAssuranceUniverseService(this IServiceCollection services)
    {
        services.AddScoped<IOrgAssuranceUniverseService, OrgAssuranceUniverseService>();
        return services;
    }
}
