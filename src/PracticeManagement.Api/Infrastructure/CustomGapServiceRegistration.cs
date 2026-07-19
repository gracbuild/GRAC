// =====================================================================
// CustomGapServiceRegistration
//
// One-line extension so Program.cs adoption is a small, reviewable diff.
// Mirrors TaskServiceRegistration.
//
// Wire-up in Program.cs (added alongside AddPracticeTaskService()):
//     builder.Services.AddPracticeCustomGapService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class CustomGapServiceRegistration
{
    public static IServiceCollection AddPracticeCustomGapService(this IServiceCollection services)
    {
        services.AddScoped<ICustomGapService, CustomGapService>();
        return services;
    }
}
