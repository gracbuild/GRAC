// =====================================================================
// PermissionServiceRegistration  (charter §12.1.6)
//
// Extension method that registers IPermissionService. Kept as an
// extension so Program.cs can adopt this with a single line and be
// reviewed independently. Charter §5 requires an explicit request to
// modify Program.cs — Program.cs is NOT touched in this PR.
//
// Wire-up (to be added by reviewer with approval):
//     using PracticeManagement.Api.Infrastructure;
//     builder.Services.AddPracticePermissionService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class PermissionServiceRegistration
{
    public static IServiceCollection AddPracticePermissionService(this IServiceCollection services)
    {
        services.AddScoped<IPermissionService, PermissionService>();
        return services;
    }
}
