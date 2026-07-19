// One-line DI extension (charter §5: Program.cs not touched here).
// Reviewer adds:  builder.Services.AddPracticeInstanceWorkflow();
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class PracticeInstanceWorkflowRegistration
{
    public static IServiceCollection AddPracticeInstanceWorkflow(this IServiceCollection services)
    {
        services.AddScoped<IPracticeInstanceWorkflowService, PracticeInstanceWorkflowService>();
        return services;
    }
}
