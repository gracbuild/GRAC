// =====================================================================
// ManagementDashboardServiceRegistration  (migrations 413 / 414)
// The parent-menu landing dashboards. Read-only; no worker.
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class ManagementDashboardServiceRegistration
{
    public static IServiceCollection AddPracticeManagementDashboardService(this IServiceCollection services)
    {
        services.AddScoped<IManagementDashboardService, ManagementDashboardService>();
        return services;
    }
}
