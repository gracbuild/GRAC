using PracticeManagement.Api.Services;
namespace PracticeManagement.Api.Infrastructure;

public static class ExceptionCentreServiceRegistration
{
    public static IServiceCollection AddPracticeExceptionCentreService(this IServiceCollection services)
    {
        services.AddScoped<IExceptionCentreService, ExceptionCentreService>();
        return services;
    }
}
