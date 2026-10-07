// =====================================================================
// AssetConfigServiceRegistration  (migration 420)
// Asset & Contract Management -- field dictionary + asset form templates.
// Wire-up in Program.cs:  builder.Services.AddPracticeAssetConfigService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class AssetConfigServiceRegistration
{
    public static IServiceCollection AddPracticeAssetConfigService(this IServiceCollection services)
    {
        services.AddScoped<IAssetConfigService, AssetConfigService>();
        return services;
    }
}
