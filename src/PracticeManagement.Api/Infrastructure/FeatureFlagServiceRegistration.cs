// =====================================================================
// FeatureFlagServiceRegistration  (charter §7 cross-cut, §12.1.6)
//
// Mirrors TaskServiceRegistration so Program.cs adoption is a one-line
// diff:
//     builder.Services.AddPracticeFeatureFlagService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class FeatureFlagServiceRegistration
{
    public static IServiceCollection AddPracticeFeatureFlagService(this IServiceCollection services)
    {
        services.AddScoped<IFeatureFlagService, FeatureFlagService>();
        return services;
    }
}
