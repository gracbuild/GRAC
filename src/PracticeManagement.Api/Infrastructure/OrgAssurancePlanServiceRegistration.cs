// =====================================================================
// OrgAssurancePlanServiceRegistration
//
// One-line DI extension for Program.cs, matching TaskServiceRegistration.
//
// Wire-up:
//     builder.Services.AddOrgAssurancePlanService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class OrgAssurancePlanServiceRegistration
{
    public static IServiceCollection AddOrgAssurancePlanService(this IServiceCollection services)
    {
        services.AddScoped<IOrgAssurancePlanService, OrgAssurancePlanService>();
        return services;
    }
}
