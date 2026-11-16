// =====================================================================
// OrgAssuranceWorkpaperServiceRegistration (567)
//
// One-line DI extension for Program.cs, matching
// OrgAssuranceExecutionServiceRegistration.
//
// Wire-up:
//     builder.Services.AddOrgAssuranceWorkpaperService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class OrgAssuranceWorkpaperServiceRegistration
{
    public static IServiceCollection AddOrgAssuranceWorkpaperService(this IServiceCollection services)
    {
        services.AddScoped<IOrgAssuranceWorkpaperService, OrgAssuranceWorkpaperService>();
        return services;
    }
}
