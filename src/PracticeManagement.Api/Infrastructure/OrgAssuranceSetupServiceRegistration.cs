// =====================================================================
// OrgAssuranceSetupServiceRegistration
//
// One-line DI extension for Program.cs, matching
// OrgAssuranceQuestionServiceRegistration.
//
// Wire-up (added alongside AddOrgAssuranceQuestionService in Program.cs):
//     builder.Services.AddOrgAssuranceSetupService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class OrgAssuranceSetupServiceRegistration
{
    public static IServiceCollection AddOrgAssuranceSetupService(this IServiceCollection services)
    {
        services.AddScoped<IOrgAssuranceSetupService, OrgAssuranceSetupService>();
        return services;
    }
}
