// =====================================================================
// OrgAssuranceQuestionServiceRegistration
//
// One-line DI extension for Program.cs, matching TaskServiceRegistration
// / OrgAssuranceDefinitionServiceRegistration.
//
// Wire-up (added alongside AddOrgAssuranceDefinitionService in Program.cs):
//     builder.Services.AddOrgAssuranceQuestionService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class OrgAssuranceQuestionServiceRegistration
{
    public static IServiceCollection AddOrgAssuranceQuestionService(this IServiceCollection services)
    {
        services.AddScoped<IOrgAssuranceQuestionService, OrgAssuranceQuestionService>();
        return services;
    }
}
