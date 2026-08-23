// =====================================================================
// WorkflowServiceRegistration
//
// One-line extension so Program.cs adoption is a small, reviewable diff.
// Mirrors CustomGapServiceRegistration.
//
// Wire-up in Program.cs (added alongside AddPracticeCustomGapService()):
//     builder.Services.AddPracticeWorkflowService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class WorkflowServiceRegistration
{
    public static IServiceCollection AddPracticeWorkflowService(this IServiceCollection services)
    {
        services.AddScoped<IWorkflowService, WorkflowService>();
        return services;
    }
}
