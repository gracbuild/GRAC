// =====================================================================
// RoleViewDataScopeServiceRegistration  (migration 415)
// The role-level View Data Scope setting (read / write).
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class RoleViewDataScopeServiceRegistration
{
    public static IServiceCollection AddPracticeRoleViewDataScopeService(this IServiceCollection services)
    {
        services.AddScoped<IRoleViewDataScopeService, RoleViewDataScopeService>();
        return services;
    }
}
