// =====================================================================
// OrganizationAccessServiceRegistration
//
// Mirrors TaskServiceRegistration / FeatureFlagServiceRegistration so
// Program.cs adoption is a one-line diff:
//     builder.Services.AddPracticeOrganizationAccessService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class OrganizationAccessServiceRegistration
{
    public static IServiceCollection AddPracticeOrganizationAccessService(this IServiceCollection services)
    {
        services.AddScoped<IOrganizationAccessService, OrganizationAccessService>();
        return services;
    }
}
