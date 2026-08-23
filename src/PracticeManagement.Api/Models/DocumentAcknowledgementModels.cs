// =====================================================================
// DocumentAcknowledgementModels  (charter §5)
//
// Request / response contracts for DocumentAcknowledgementController
// (Phase 2 -- admin batches over published documents that require
// acknowledgement).
// =====================================================================
namespace PracticeManagement.Api.Models;

// -------------------- Pending list -----------------------------------

public sealed record DocumentAckPendingRow(
    long PendingId,
    long DocumentId,
    string DocumentCode,
    string DocumentName,
    string VersionNumber,
    DateTime? NextReviewDate,
    int CycleNo,
    DateTime QueuedOn);

public sealed record DocumentAckPendingResult(
    long TotalRows, int Page, int PageSize,
    IReadOnlyList<DocumentAckPendingRow> Rows);

// -------------------- Create batch -----------------------------------

public sealed record DocumentAckCreateRequest(
    long OrganizationId,
    string AcknowledgementName,
    DateTime? DueDate,
    IReadOnlyList<long> PendingIds,
    long? CallerEmployeeId,
    string? CallerDisplayName);

public sealed record DocumentAckCreateResult(
    bool Success,
    long? AcknowledgementId,
    string? Error);

// -------------------- Batch list -------------------------------------

public sealed record DocumentAckBatchRow(
    long AcknowledgementId,
    string AcknowledgementName,
    DateTime? DueDate,
    string StatusCode,
    int DocumentCount,
    int UserCount,
    int AckCount,
    decimal CompletionPct,
    string ProgressLabel,
    DateTime CreatedOn,
    string CreatedBy);

public sealed record DocumentAckBatchListResult(
    long TotalRows, int Page, int PageSize,
    IReadOnlyList<DocumentAckBatchRow> Rows);

// -------------------- Docs in a batch --------------------------------

public sealed record DocumentAckBatchDocumentRow(
    long DocumentId,
    string DocumentCode,
    string DocumentName,
    string VersionNumber,
    int CycleNo,
    int UserCount,
    int AckCount,
    decimal CompletionPct,
    string ProgressLabel);

// -------------------- Users for a doc in a batch ---------------------

public sealed record DocumentAckDocumentUserRow(
    long EmployeeId,
    string? EmployeeCode,
    string EmployeeName,
    string? Email,
    string StatusCode,
    DateTime? AcknowledgedOn,
    string? Remark);

// -------------------- USER SIDE (Phase 3) ---------------------------

public sealed record DocumentAckUserBatchRow(
    long AcknowledgementId,
    string AcknowledgementName,
    DateTime? DueDate,
    string BatchStatusCode,
    int MyDocCount,
    int MyAckCount,
    int MyPendingCount,
    decimal MyCompletionPct,
    string MyStatusLabel,
    DateTime CreatedOn);

public sealed record DocumentAckUserDocumentRow(
    long AcknowledgementUserId,
    long AcknowledgementId,
    string AcknowledgementName,
    DateTime? DueDate,
    long DocumentId,
    string DocumentCode,
    string DocumentName,
    string VersionNumber,
    DateTime? NextReviewDate,
    string StatusCode,
    DateTime? AcknowledgedOn,
    string? Remark,
    long EmployeeId,
    string EmployeeName,
    string? EmployeeCode,
    string? EmployeeEmail);

public sealed record DocumentAckUserAckRequest(
    long AcknowledgementId,
    long DocumentId,
    string? Remark,
    long? CallerEmployeeId,       // server overrides from session -- see Web proxy
    string? CallerDisplayName);

public sealed record DocumentAckUserAckResult(
    bool Success,
    long AcknowledgementId,
    long DocumentId,
    long EmployeeId,
    string? StatusCode,
    DateTime? AcknowledgedOn,
    string? Error);
