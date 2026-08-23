// =====================================================================
// ExceptionCentreModels  (charter §5)
// Request/response contracts for ExceptionCentreController.
// =====================================================================
using Microsoft.AspNetCore.Http;

namespace PracticeManagement.Api.Models;

public sealed record ExceptionTypeRow(
    int ExceptionTypeId,
    string ExceptionTypeCode,
    string ExceptionTypeName,
    string? Description,
    int SortOrder);

public sealed record ExceptionRequestRow(
    long ExceptionRequestId,
    long OrganizationId,
    long CustomGapId,
    string? GapTitle,
    string RequestTitle,
    string? ExceptionTypeName,
    string StatusCode,          // Pending | Approved | Rejected | Withdrawn | Expired
    DateTime RequestedOn,
    string? RequestedByName,
    DateTime? ApprovedOn,
    string? ApprovedByName,
    DateTime? EffectiveFrom,
    DateTime? EffectiveUntil,
    DateTime? RejectedOn,
    string? RejectedByName,
    int AttachmentCount,
    // Migration 184 -- exception-centre tab filter + SLA-override payload.
    string RequestTypeCode = "GAP_CANDIDATE",
    int?   SlaDaysOriginal  = null,
    int?   SlaDaysRequested = null);

public sealed record ExceptionRequestListResult(
    long TotalRows, int Page, int PageSize,
    IReadOnlyList<ExceptionRequestRow> Rows);

public sealed record ExceptionRequestDetail(
    long ExceptionRequestId,
    long OrganizationId,
    long CustomGapId,
    string? GapTitle,
    string RequestTitle,
    string? RequestReason,
    string? Justification,
    string? RiskImpact,
    string? ExceptionTypeCode,
    string? ExceptionTypeName,
    long? OwnerEmployeeId,
    string? OwnerName,
    long? LinkedPracticeId,
    string? LinkedRequirementRef,
    string StatusCode,
    long? RequestedByEmployeeId,
    string? RequestedByName,
    DateTime RequestedOn,
    long? ApprovedByEmployeeId,
    string? ApprovedByName,
    DateTime? ApprovedOn,
    DateTime? EffectiveFrom,
    DateTime? EffectiveUntil,
    string? ApprovalNote,
    string? CompensatingControl,
    int? ReviewFrequencyId,
    string? ReviewFrequencyName,
    long? RejectedByEmployeeId,
    string? RejectedByName,
    DateTime? RejectedOn,
    string? RejectionReason);

public sealed record ExceptionApproveRequest(
    DateTime EffectiveUntil,
    string ApprovalNote,
    long? ApprovedByEmployeeId,
    DateTime? EffectiveFrom,
    string? CompensatingControl,
    int? ReviewFrequencyId,
    // Optional request-level fields that the approver may fill/edit at
    // approve time if analyst did not capture them earlier.
    string? ExceptionTypeCode,
    string? Justification,
    string? RiskImpact,
    long? OwnerEmployeeId,
    long? LinkedPracticeId,
    string? LinkedRequirementRef,
    string? CallerDisplayName);

// Migration 184 -- SLA Candidate approve. No effective_until / note --
// the requested days already sit on the exception_request row.
public sealed record ExceptionApproveSlaRequest(
    long?   ApprovedByEmployeeId,
    string? CallerDisplayName);

// Fields the analyst / admin can set on Pending (before approval).
public sealed record ExceptionRequestUpdateFields(
    string? ExceptionTypeCode,
    string? Justification,
    string? RiskImpact,
    long? OwnerEmployeeId,
    long? LinkedPracticeId,
    string? LinkedRequirementRef);

public sealed record ExceptionRejectRequest(
    string RejectionReason,
    long? RejectedByEmployeeId,
    string? CallerDisplayName);

public sealed record ExceptionActionResult(
    bool Success,
    long ExceptionRequestId,
    string? StatusCode,
    string? Error);

public sealed class ExceptionAttachmentUploadForm
{
    // Manual (default) requires File; Automated requires EvidenceLocation
    // + EvidenceLocator. Same vocabulary as practice_instance_evidence.
    public string? CollectionMethodCode { get; set; } = "Manual";
    public string? EvidenceTypeCode { get; set; }        // optional; from evidence_type_master
    public IFormFile? File { get; set; }
    public string? EvidenceLocation { get; set; }
    public string? EvidenceLocator { get; set; }
    public long? UploadedByEmployeeId { get; set; }
    public string? CallerDisplayName { get; set; }
}

public sealed record EvidenceTypeRow(
    int EvidenceTypeId,
    string EvidenceTypeCode,
    string EvidenceTypeName,
    int SortOrder);

public sealed record OrganizationPracticeRow(
    long PracticeId,
    string PracticeCode,
    string PracticeName,
    string? ApplicabilityStatus,
    string? PracticeOwner);

public sealed record ExceptionAttachmentRow(
    long AttachmentId,
    string? CollectionMethodCode,
    string? CollectionMethodName,
    string? EvidenceTypeCode,
    string? EvidenceTypeName,
    string? FileName,
    string? ContentType,
    long FileSizeBytes,
    string? EvidenceLocation,
    string? EvidenceLocator,
    long? UploadedByEmployeeId,
    string? UploadedByName,
    DateTime UploadedOn);
