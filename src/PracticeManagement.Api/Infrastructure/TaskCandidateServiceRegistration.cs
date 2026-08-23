// =====================================================================
// TaskCandidateServiceRegistration  (Task Centre v2, Phase 2)
//
// One-line extension so Program.cs adoption is a small, reviewable diff.
// Charter §5 forbids modifying Program.cs without an explicit request —
// this file does not touch Program.cs.
//
// Wire-up (to be added by reviewer with approval):
//     using PracticeManagement.Api.Infrastructure;
//     builder.Services.AddPracticeTaskCandidateService();
//
// Mirrors TaskServiceRegistration; the two are independent, so the task
// engine can be enabled without the candidate stage.
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class TaskCandidateServiceRegistration
{
    public static IServiceCollection AddPracticeTaskCandidateService(this IServiceCollection services)
    {
        services.AddScoped<ITaskCandidateService, TaskCandidateService>();
        return services;
    }
}
