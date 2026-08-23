// =====================================================================
// OrgAssuranceObservationModels
//
// Phase 2 Assurance Management -- Stage 4 Observation Management
// (BRD Part 2 Sec 11). Follows OrgAssurancePlanModels /
// OrgAssuranceExecutionModels conventions.
// =====================================================================
namespace PracticeManagement.Api.Models;

// ---------- Lookups ----------
public sealed record OrgAssuranceObservationSeverityRow(
    int    SeverityId,
    string SeverityCode,
    string SeverityName,
    int    DisplayOrder,
    string? ColorHex);

public sealed record OrgAssuranceObservationStatusRow(
    int    StatusId,
    string StatusCode,
    string StatusName,
    int    DisplayOrder,
    bool   IsTerminal);

public sealed record OrgAssuranceObservationTypeRow(
    string TypeCode,
    string TypeName,
    int    DisplayOrder);

// ---------- List ----------
public sealed record OrgAssuranceObservationListQuery(
    long    OrganizationId,
    long?   ExecutionId       = null,
    long?   EntityId          = null,
    string? StatusCode        = null,
    string? SeverityCode      = null,
    string? ObservationType   = null,
    string? Search            = null,
    int     Page              = 1,
    int     PageSize          = 25);

public sealed record OrgAssuranceObservationListRow(
    long      ObservationId,
    long      OrganizationId,
    long      ExecutionId,
    long?     EntityId,
    string?   ExecutionCode,
    string?   ExecutionName,
    string?   EntityDimensionCode,
    string?   EntityDimensionName,
    string?   EntityCode,
    string?   EntityName,
    string    ObservationCode,
    string    ObservationTitle,
    string    ObservationType,
    string    SeverityCode,
    string?   SeverityName,
    string    StatusCode,
    string    StatusName,
    bool      StatusIsTerminal,
    string?   OwnerDisplayName,
    long?     OwnerRoleId,
    string?   OwnerRoleName,
    string?   ReviewerDisplayName,
    long?     ReviewerRoleId,
    string?   ReviewerRoleName,
    DateTime? ObservedDt,
    DateTime? DueDate,
    long?     GapId,
    long      EvidenceCount,
    DateTime? EnteredDt,
    DateTime? UpdatedDt);

public sealed record OrgAssuranceObservationListResult(
    long TotalCount,
    int  PageNumber,
    int  PageSize,
    IReadOnlyList<OrgAssuranceObservationListRow> Rows);

// ---------- Detail ----------
public sealed record OrgAssuranceObservationDetail(
    long      ObservationId,
    long      OrganizationId,
    long      ExecutionId,
    long?     EntityId,
    string?   ExecutionCode,
    string?   ExecutionName,
    string?   EntityDimensionCode,
    string?   EntityDimensionName,
    string?   EntityCode,
    string?   EntityName,
    string    ObservationCode,
    string    ObservationTitle,
    string?   ObservationDescription,
    string    ObservationType,
    int       SeverityId,
    string    SeverityCode,
    string?   SeverityName,
    string    StatusCode,
    string    StatusName,
    bool      StatusIsTerminal,
    string?   SourceQuestionCode,
    string?   SourceQuestionText,
    string?   SourceQuestionSnapshotJson,
    long?     ReportedByEmployeeId,
    string?   ReportedByDisplayName,
    long?     OwnerEmployeeId,
    string?   OwnerDisplayName,
    long?     OwnerRoleId,
    string?   OwnerRoleName,
    long?     ReviewerEmployeeId,
    string?   ReviewerDisplayName,
    long?     ReviewerRoleId,
    string?   ReviewerRoleName,
    DateTime? ObservedDt,
    DateTime? DueDate,
    DateTime? AcceptedDt,
    DateTime? RejectedDt,
    DateTime? ResolvedDt,
    DateTime? ClosedDt,
    long?     GapId,
    string?   ResolutionNotes,
    string?   RejectionReason,
    string?   EnteredBy,
    DateTime? EnteredDt,
    string?   UpdatedBy,
    DateTime? UpdatedDt);

// ---------- Save ----------
public sealed record OrgAssuranceObservationSaveRequest(
    long      OrganizationId,
    long?     ObservationId,
    long      ExecutionId,
    long?     ExecutionEntityId,
    string?   ObservationCode,
    string    ObservationTitle,
    string?   ObservationDescription,
    string?   ObservationType,
    string?   SeverityCode,
    string?   SourceQuestionCode,
    string?   SourceQuestionText,
    long?     ReportedByEmployeeId,
    string?   ReportedByDisplayName,
    long?     AssignedOwnerEmployeeId,
    string?   AssignedOwnerDisplayName,
    long?     AssignedOwnerRoleId,
    string?   AssignedOwnerRoleName,
    long?     AssignedReviewerEmployeeId,
    string?   AssignedReviewerDisplayName,
    long?     AssignedReviewerRoleId,
    string?   AssignedReviewerRoleName,
    DateTime? ObservedDt,
    DateTime? DueDate,
    string?   Actor);

public sealed record OrgAssuranceObservationSaveResult(
    bool    Success,
    long?   ObservationId = null,
    string? Error         = null,
    string? ReasonCode    = null);

// ---------- Command (delete + lifecycle) ----------
public sealed record OrgAssuranceObservationCommandRequest(
    long    OrganizationId,
    long    ObservationId,
    string? Notes,
    string? Actor);

public sealed record OrgAssuranceObservationCommandResult(
    bool    Success,
    long?   ObservationId = null,
    string? Error         = null,
    string? ReasonCode    = null);

// ---------- Evidence ----------
public sealed record OrgAssuranceObservationEvidenceRow(
    long      EvidenceId,
    long      ObservationId,
    long?     EvidenceConfigId,
    string?   EvidenceTypeCode,
    string?   EvidenceTypeName,
    string?   EvidenceLabel,
    long?     FileId,
    string?   StorageLocation,
    string?   StorageLocator,
    string?   OriginalFileName,
    long?     FileSizeBytes,
    string?   MimeType,
    long?     CollectedByEmployeeId,
    string?   CollectedByDisplayName,
    DateTime? CollectedDt,
    string?   Notes,
    string?   EnteredBy,
    DateTime? EnteredDt,
    string?   UpdatedBy,
    DateTime? UpdatedDt);

public sealed record OrgAssuranceObservationEvidenceSaveRequest(
    long      OrganizationId,
    long      ObservationId,
    long?     EvidenceId,
    long?     EvidenceConfigId,
    string?   EvidenceTypeCode,
    string?   EvidenceTypeName,
    string?   EvidenceLabel,
    long?     FileId,
    string?   StorageLocation,
    string?   StorageLocator,
    string?   OriginalFileName,
    long?     FileSizeBytes,
    string?   MimeType,
    long?     CollectedByEmployeeId,
    string?   CollectedByDisplayName,
    DateTime? CollectedDt,
    string?   Notes,
    string?   Actor);

public sealed record OrgAssuranceObservationEvidenceSaveResult(
    bool    Success,
    long?   EvidenceId = null,
    string? Error      = null,
    string? ReasonCode = null);

// ---------- History ----------
public sealed record OrgAssuranceObservationHistoryRow(
    long      HistoryId,
    string    ActionCode,
    int?      FromStatusId,
    string?   FromStatusCode,
    string?   FromStatusName,
    int?      ToStatusId,
    string?   ToStatusCode,
    string?   ToStatusName,
    string?   ReasonText,
    string?   ActorDisplayName,
    string?   EnteredBy,
    DateTime? EnteredDt);
