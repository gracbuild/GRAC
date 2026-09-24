// =====================================================================
// PracticePickerServiceRegistration
//
// One-line DI extension for Program.cs, matching the other
// *ServiceRegistration files.
//
// Wire-up:
//     builder.Services.AddPracticePickerService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class PracticePickerServiceRegistration
{
    public static IServiceCollection AddPracticePickerService(this IServiceCollection services)
    {
        services.AddScoped<IPracticePickerService, PracticePickerService>();
        return services;
    }
}
