// =====================================================================
// OrgAssuranceReportServiceRegistration (568)
//
// One-line DI extension for Program.cs, matching
// OrgAssuranceWorkpaperServiceRegistration.
//
// Wire-up:
//     builder.Services.AddOrgAssuranceReportService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class OrgAssuranceReportServiceRegistration
{
    public static IServiceCollection AddOrgAssuranceReportService(this IServiceCollection services)
    {
        services.AddScoped<IOrgAssuranceReportService, OrgAssuranceReportService>();
        return services;
    }
}
