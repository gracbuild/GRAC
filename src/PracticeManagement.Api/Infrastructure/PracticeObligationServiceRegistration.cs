// =====================================================================
// PracticeObligationServiceRegistration
//
// One-line extension so Program.cs adoption is a small, reviewable diff.
// Mirrors ResolveWorkspaceServiceRegistration.
//
// Wire-up in Program.cs:
//     builder.Services.AddPracticeObligationService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class PracticeObligationServiceRegistration
{
    public static IServiceCollection AddPracticeObligationService(this IServiceCollection services)
    {
        services.AddScoped<IPracticeObligationService, PracticeObligationService>();
        return services;
    }
}
