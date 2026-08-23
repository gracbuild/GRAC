// =====================================================================
// OrgAssuranceDefinitionServiceRegistration
//
// One-line DI extension for Program.cs, matching TaskServiceRegistration
// and WorkflowServiceRegistration.
//
// Wire-up (already added in Program.cs alongside the other layers):
//     builder.Services.AddOrgAssuranceDefinitionService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class OrgAssuranceDefinitionServiceRegistration
{
    public static IServiceCollection AddOrgAssuranceDefinitionService(this IServiceCollection services)
    {
        services.AddScoped<IOrgAssuranceDefinitionService, OrgAssuranceDefinitionService>();
        return services;
    }
}
