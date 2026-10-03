// =====================================================================
// RepositoryChangeServiceRegistration  (statement subscription copy model,
// phase 3). Service and worker are registered separately, as with
// TaskNotificationServiceRegistration: the service alone serves the review
// page and Home; the worker adds the scheduled detection (decision 9).
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class RepositoryChangeServiceRegistration
{
    public static IServiceCollection AddPracticeRepositoryChangeService(this IServiceCollection services)
    {
        services.AddScoped<IRepositoryChangeService, RepositoryChangeService>();
        return services;
    }

    /// <summary>Timer-driven detection. Requires AddPracticeRepositoryChangeService.</summary>
    public static IServiceCollection AddPracticeRepositoryChangeDetectWorker(this IServiceCollection services)
    {
        services.AddHostedService<RepositoryChangeDetectWorker>();
        return services;
    }
}
