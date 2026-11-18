// =====================================================================
// OrgAssurancePlanRecommendationServiceRegistration (583)
//
// One-line DI extension for Program.cs, matching
// OrgAssuranceRbiaServiceRegistration.
//
// Wire-up:
//     builder.Services.AddOrgAssurancePlanRecommendationService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class OrgAssurancePlanRecommendationServiceRegistration
{
    public static IServiceCollection AddOrgAssurancePlanRecommendationService(this IServiceCollection services)
    {
        services.AddScoped<IOrgAssurancePlanRecommendationService, OrgAssurancePlanRecommendationService>();
        return services;
    }
}
