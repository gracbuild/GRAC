// =====================================================================
// GapLifecycleServiceRegistration  (charter §5)  -- Gap Centre v1.0
//     builder.Services.AddPracticeGapLifecycleService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class GapLifecycleServiceRegistration
{
    public static IServiceCollection AddPracticeGapLifecycleService(this IServiceCollection services)
    {
        services.AddScoped<IGapLifecycleService, GapLifecycleService>();
        return services;
    }
}
