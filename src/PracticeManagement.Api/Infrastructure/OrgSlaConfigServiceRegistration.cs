// =====================================================================
// OrgSlaConfigServiceRegistration
//
// One-line DI extension for Program.cs, matching the shape used by
// OrgAssuranceDefinitionServiceRegistration.
//
// Wire-up in Program.cs:
//     builder.Services.AddOrgSlaConfigService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class OrgSlaConfigServiceRegistration
{
    public static IServiceCollection AddOrgSlaConfigService(this IServiceCollection services)
    {
        services.AddScoped<IOrgSlaConfigService, OrgSlaConfigService>();
        return services;
    }
}
