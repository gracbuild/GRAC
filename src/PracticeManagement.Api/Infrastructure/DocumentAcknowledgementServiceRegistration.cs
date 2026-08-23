// =====================================================================
// DocumentAcknowledgementServiceRegistration  (charter §5)
//
// Single-line DI extension. Reviewer wires it up in Program.cs:
//     builder.Services.AddPracticeDocumentAcknowledgementService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class DocumentAcknowledgementServiceRegistration
{
    public static IServiceCollection AddPracticeDocumentAcknowledgementService(this IServiceCollection services)
    {
        services.AddScoped<IDocumentAcknowledgementService, DocumentAcknowledgementService>();
        return services;
    }
}
