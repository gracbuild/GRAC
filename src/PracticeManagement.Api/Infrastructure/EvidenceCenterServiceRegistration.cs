// =====================================================================
// EvidenceCenterServiceRegistration  (migration 476, Phase 1)
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class EvidenceCenterServiceRegistration
{
    public static IServiceCollection AddPracticeEvidenceCenterService(this IServiceCollection services)
    {
        services.AddScoped<IEvidenceCenterService, EvidenceCenterService>();
        return services;
    }
}
