// =====================================================================
// TaskServiceRegistration  (charter §12.1.3)
//
// One-line extension so Program.cs adoption is a small, reviewable
// diff. Charter §5 forbids modifying Program.cs without an explicit
// request — this file does not touch Program.cs.
//
// Wire-up (to be added by reviewer with approval):
//     using PracticeManagement.Api.Infrastructure;
//     builder.Services.AddPracticeTaskService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class TaskServiceRegistration
{
    public static IServiceCollection AddPracticeTaskService(this IServiceCollection services)
    {
        services.AddScoped<ITaskService, TaskService>();
        return services;
    }
}
