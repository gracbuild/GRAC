// =====================================================================
// TprmServiceRegistration  (migrations 486-490, Third-Party Risk Management)
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class TprmServiceRegistration
{
    public static IServiceCollection AddPracticeTprmService(this IServiceCollection services)
    {
        services.AddScoped<ITprmService, TprmService>();
        return services;
    }
}
