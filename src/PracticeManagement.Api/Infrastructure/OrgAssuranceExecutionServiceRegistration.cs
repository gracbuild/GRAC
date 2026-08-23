// =====================================================================
// OrgAssuranceExecutionServiceRegistration
//
// One-line DI extension for Program.cs, matching
// OrgAssurancePlanServiceRegistration.
//
// Wire-up:
//     builder.Services.AddOrgAssuranceExecutionService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class OrgAssuranceExecutionServiceRegistration
{
    public static IServiceCollection AddOrgAssuranceExecutionService(this IServiceCollection services)
    {
        services.AddScoped<IOrgAssuranceExecutionService, OrgAssuranceExecutionService>();
        return services;
    }
}
