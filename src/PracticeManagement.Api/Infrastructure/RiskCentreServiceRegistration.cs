using PracticeManagement.Api.Services;
namespace PracticeManagement.Api.Infrastructure;

public static class RiskCentreServiceRegistration
{
    public static IServiceCollection AddPracticeRiskCentreService(this IServiceCollection services)
    {
        services.AddScoped<IRiskCentreService, RiskCentreService>();
        return services;
    }
}
