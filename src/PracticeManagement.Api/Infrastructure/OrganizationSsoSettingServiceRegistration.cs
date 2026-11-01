// =====================================================================
// OrganizationSsoSettingServiceRegistration  (migration 466)
// The organization-wise single sign-on policy (read / write).
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class OrganizationSsoSettingServiceRegistration
{
    public static IServiceCollection AddPracticeOrganizationSsoSettingService(this IServiceCollection services)
    {
        services.AddScoped<IOrganizationSsoSettingService, OrganizationSsoSettingService>();
        return services;
    }
}
