// =====================================================================
// DocumentUploadModels  (charter §5)
//
// Request / response contracts for DocumentUploadController.
// Kept in its own file per charter §5 non-negotiable.
//
// The upload/edit contract is bound via [FromForm] (multipart) because
// the payload carries a file. Every OTHER contract in this module is a
// JSON DTO so the Web tier proxy can serialise transparently.
// =====================================================================
using Microsoft.AspNetCore.Http;

namespace PracticeManagement.Api.Models;

// -------------------- Lookup rows (all share simple shapes) ----------

public sealed record DocumentTypeRow(int DocumentTypeId, string DocumentType, string TypeCode, int SortOrder);
public sealed record DocumentStageRow(int DocumentStageId, string DocumentStage, string StageCode, int SortOrder);
public sealed record DocumentStatusRow(int DocumentStatusId, string DocumentStatus, string StatusCode, int SortOrder);
public sealed record DocumentSourceTypeRow(int SourceTypeId, string SourceType, string SourceCode, int SortOrder);
public sealed record DocumentDistributionTypeRow(int DistributionTypeId, string DistributionType, string DistributionCode, int SortOrder);

public sealed record OrganizationDepartmentRow(long DepartmentId, string DepartmentName);
public sealed record OrganizationEmployeeRow(long EmployeeId, string EmployeeName, string? EmployeeCode, string? Email);

// -------------------- Register list ----------------------------------

public sealed record DocumentRegisterQuery(
    long OrganizationId,
    int? DocumentTypeId,
    int? StageId,
    int? StatusId,
    string? Search,
    int Page,
    int PageSize);

public sealed record DocumentRegisterRow(
    long DocumentId,
    string DocumentCode,
    string? CompanyDocumentCode,
    string DocumentName,
    int DocumentTypeId,
    string DocumentType,
    string VersionNumber,
    DateTime? NextReviewDate,
    int StageId,
    string DocumentStage,
    int StatusId,
    string DocumentStatus,
    DateTime LastActivityDt);

public sealed record DocumentRegisterResult(long TotalRows, int Page, int PageSize, IReadOnlyList<DocumentRegisterRow> Rows);

// -------------------- Detail card ------------------------------------

public sealed record DocumentDetail(
    long DocumentId,
    long OrganizationId,
    string OrganizationName,
    string DocumentCode,
    string? CompanyDocumentCode,
    string DocumentName,
    int DocumentTypeId,
    string DocumentType,
    int? SourceTypeId,
    string? SourceType,
    string VersionNumber,
    DateTime? EffectiveDate,
    DateTime? NextReviewDate,
    bool AcknowledgementRequired,
    int StageId,
    string DocumentStage,
    int StatusId,
    string DocumentStatus,
    string? ChangeSummary,
    string? KeywordsTag,
    long? OwnerId,
    string? OwnerName,
    long? ReviewerId,
    string? ReviewerName,
    long? ApproverId,
    string? ApproverName,
    int? DistributionTypeId,
    string? DistributionType,
    long? ReviewedById,
    string? ReviewedByName,
    DateTime? ReviewedOn,
    string? ReviewRemark,
    long? ApprovedById,
    string? ApprovedByName,
    DateTime? ApprovedOn,
    string? ApprovedRemark,
    string CreatedBy,
    DateTime CreatedOn,
    string? UpdatedBy,
    DateTime? UpdatedOn);

// -------------------- Upload / edit request (multipart) --------------
//
// One shape covers both New and Edit. On Edit the file is optional --
// only sent when the caller is re-uploading a new version. Distribution
// ids arrive as a comma-separated string so the multipart form stays
// flat (matches the legacy wire format).

public sealed class DocumentUploadSaveForm
{
    public long? DocumentId { get; set; }                        // required on Edit, null on New
    public long OrganizationId { get; set; }
    public string DocumentName { get; set; } = "";
    public string? CompanyDocumentCode { get; set; }
    public int DocumentTypeId { get; set; }
    public int? SourceTypeId { get; set; }
    public string VersionNumber { get; set; } = "";
    public DateTime? EffectiveDate { get; set; }
    public DateTime? NextReviewDate { get; set; }
    public string? DistributionTypeCode { get; set; }            // Organization | Departments | Users
    public string? DistributionIds { get; set; }                 // CSV of dept ids or employee ids
    public bool AcknowledgementRequired { get; set; }
    public string? ChangeSummary { get; set; }
    public string? KeywordsTag { get; set; }
    public long? OwnerId { get; set; }
    public long? ReviewerId { get; set; }
    public long? ApproverId { get; set; }
    public IFormFile? File { get; set; }                         // required on New, optional on Edit
    public long? CallerEmployeeId { get; set; }
    public string? CallerDisplayName { get; set; }
}

public sealed record DocumentSaveResult(bool Success, long? DocumentId, string? Error);

// -------------------- Workflow ---------------------------------------

public sealed record DocumentWorkflowRequest(
    string Transition,                  // Review | Approve
    string Decision,                    // Approve | Reject
    string? Remark,
    long? CallerEmployeeId,
    string? CallerDisplayName);

public sealed record DocumentWorkflowResult(bool Success, long DocumentId, int? StageId, string? StageCode, string? Error);

// -------------------- Status toggle ----------------------------------

public sealed record DocumentStatusToggleRequest(long? CallerEmployeeId, string? CallerDisplayName);

// -------------------- File payload -----------------------------------

public sealed record DocumentFilePayload(
    long DocumentFileId,
    long DocumentId,
    string VersionNumber,
    string FileName,
    string? ContentType,
    long FileSizeBytes,
    byte[] FileData,
    DateTime UploadedOn);
