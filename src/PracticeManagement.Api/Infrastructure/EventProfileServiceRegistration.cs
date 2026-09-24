// =====================================================================
// EventProfileServiceRegistration
//
// One-line extension so Program.cs adoption is a small, reviewable diff.
// Mirrors EventScopeServiceRegistration.
//
// Wire-up in Program.cs (added alongside AddPracticeEventScopeService()):
//     builder.Services.AddPracticeEventProfileService();
//
// No hosted service here: profiles are configuration, and the auto-raise
// worker registered by AddPracticeEventScopeService already drains the
// queue that consumes them.
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class EventProfileServiceRegistration
{
    public static IServiceCollection AddPracticeEventProfileService(this IServiceCollection services)
    {
        services.AddScoped<IEventProfileService, EventProfileService>();
        return services;
    }
}
