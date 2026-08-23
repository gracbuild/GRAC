// =====================================================================
// DocumentUploadServiceRegistration  (charter §5)
//
// Single-file extension so Program.cs adoption stays a one-line diff.
// Charter §5 forbids modifying Program.cs without an explicit request --
// this file does NOT touch Program.cs.
//
// Wire-up (to be added by reviewer with approval):
//     using PracticeManagement.Api.Infrastructure;
//     builder.Services.AddPracticeDocumentUploadService();
// =====================================================================
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Infrastructure;

public static class DocumentUploadServiceRegistration
{
    public static IServiceCollection AddPracticeDocumentUploadService(this IServiceCollection services)
    {
        services.AddScoped<IDocumentUploadService, DocumentUploadService>();
        return services;
    }
}
