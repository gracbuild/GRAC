// =====================================================================
// TaskNotificationServiceRegistration  (Task Centre v2, Phase 3)
//
// Charter §5 forbids modifying Program.cs without an explicit request —
// this file does not touch it.
//
// Wire-up (to be added by reviewer with approval):
//     using PracticeManagement.Api.Infrastructure;
//     builder.Services.AddPracticeTaskNotificationService();
//
// The SERVICE and the WORKER are registered separately, on purpose. The
// service alone gives you the read APIs and a manually-triggerable sweep;
// adding the hosted service is what makes it run on a timer. An
// environment that would rather drive the sweep from SQL Agent registers
// only the service. Mirrors how EventAutoRaiseWorker is kept distinct
// from IEventScopeService.
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class TaskNotificationServiceRegistration
{
    public static IServiceCollection AddPracticeTaskNotificationService(this IServiceCollection services)
    {
        services.AddScoped<ITaskNotificationService, TaskNotificationService>();
        return services;
    }

    /// <summary>
    /// Adds the timer-driven sweeper. Requires
    /// <see cref="AddPracticeTaskNotificationService"/> to have been called,
    /// because the worker resolves ITaskNotificationService from a scope
    /// on every pass.
    /// </summary>
    public static IServiceCollection AddPracticeTaskNotificationWorker(this IServiceCollection services)
    {
        services.AddHostedService<TaskNotificationWorker>();
        return services;
    }
}
