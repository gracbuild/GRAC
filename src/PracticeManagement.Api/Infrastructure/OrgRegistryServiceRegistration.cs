// =====================================================================
// OrgRegistryServiceRegistration  (migrations 569-572)
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class OrgRegistryServiceRegistration
{
    public static IServiceCollection AddPracticeOrgRegistryService(this IServiceCollection services)
    {
        services.AddScoped<IOrgRegistryService, OrgRegistryService>();
        return services;
    }
}
