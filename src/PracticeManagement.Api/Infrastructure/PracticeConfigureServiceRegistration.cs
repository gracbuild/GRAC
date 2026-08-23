// =====================================================================
// PracticeConfigureServiceRegistration
//
// One-line extension so Program.cs adoption is a small, reviewable diff.
// Mirrors EventScopeServiceRegistration / WorkflowServiceRegistration.
//
// Wire-up in Program.cs:
//     builder.Services.AddPracticeConfigureService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class PracticeConfigureServiceRegistration
{
    public static IServiceCollection AddPracticeConfigureService(this IServiceCollection services)
    {
        services.AddScoped<IPracticeConfigureService, PracticeConfigureService>();
        return services;
    }
}
