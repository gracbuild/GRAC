// =====================================================================
// ResolveWorkspaceServiceRegistration
//
// One-line extension so Program.cs adoption is a small, reviewable diff.
// Mirrors PracticeConfigureServiceRegistration.
//
// Wire-up in Program.cs:
//     builder.Services.AddPracticeResolveWorkspace();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class ResolveWorkspaceServiceRegistration
{
    public static IServiceCollection AddPracticeResolveWorkspace(this IServiceCollection services)
    {
        services.AddScoped<IResolveWorkspaceService, ResolveWorkspaceService>();
        return services;
    }
}
