// =====================================================================
// SubscriptionRequestServiceRegistration  (migration 511)
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class SubscriptionRequestServiceRegistration
{
    public static IServiceCollection AddPracticeSubscriptionRequestService(this IServiceCollection services)
    {
        services.AddScoped<ISubscriptionRequestService, SubscriptionRequestService>();
        return services;
    }
}
