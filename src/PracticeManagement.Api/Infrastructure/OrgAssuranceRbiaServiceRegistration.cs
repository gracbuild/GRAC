// =====================================================================
// OrgAssuranceRbiaServiceRegistration (582)
//
// One-line DI extension for Program.cs, matching
// OrgAssuranceUniverseServiceRegistration (which it depends on: the RBIA
// service reads the Universe service's risk intelligence at approval).
//
// Wire-up:
//     builder.Services.AddOrgAssuranceRbiaService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class OrgAssuranceRbiaServiceRegistration
{
    public static IServiceCollection AddOrgAssuranceRbiaService(this IServiceCollection services)
    {
        services.AddScoped<IOrgAssuranceRbiaService, OrgAssuranceRbiaService>();
        return services;
    }
}
