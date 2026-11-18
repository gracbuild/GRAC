// =====================================================================
// OrgAssuranceFindingServiceRegistration (584)
//
// Wire-up:
//     builder.Services.AddOrgAssuranceFindingService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class OrgAssuranceFindingServiceRegistration
{
    public static IServiceCollection AddOrgAssuranceFindingService(this IServiceCollection services)
    {
        services.AddScoped<IOrgAssuranceFindingService, OrgAssuranceFindingService>();
        return services;
    }
}
