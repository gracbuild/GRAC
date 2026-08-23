// =====================================================================
// CustomGapModels
//
// Unified Gap Center DTOs. custom_gap is now the single source of
// truth for gaps across all modules (Implementation / Assurance /
// Custom / Exception / Risk / Audit) -- previously the Assurance
// module had a parallel org_assurance_gap table which has been
// retired (migrations 109-113).
//
// Notes on backward compatibility:
//   * CustomGapOpenRequest / CustomGapCloseRequest are the legacy
//     minimal contracts from migration 055. They stay -- existing UI
//     callers (Custom Gaps tab) keep working.
//   * CustomGapListRow is extended with new nullable fields at the
//     end so existing positional construction still compiles. All new
//     fields default to null / 0.
//   * New records at the bottom cover the extended lifecycle,
//     junction, actions, merge, history and generate flows.
// =====================================================================
namespace PracticeManagement.Api.Models;

// ---------- Legacy / minimal (from 055) ----------
public sealed record CustomGapOpenRequest(
    long   OrganizationId,
    string Title,
    string? Description,
    string? Priority,
    long?   OwnerEmployeeId,
    DateTime? DueDate,
    string? Status,
    string? Remarks,
    string? GapTypeCode,
    long?   ActorEmployeeId);

public sealed record CustomGapCloseRequest(
    long   CustomGapId,
    long?  ActorEmployeeId,
    string? Remarks);

public sealed record CustomGapListQuery(
    long?   OrganizationId,
    string? StatusCode,
    string? Priority,
    long?   OwnerEmployeeId,
    string? Search,
    int     Page              = 1,
    int     PageSize          = 25,
    // Stage 4b unified filters (all optional):
    string? GapSourceModuleCode = null,
    string? SeverityCode        = null,
    long?   ObservationId       = null,
    long?   ExecutionId         = null);

public sealed record CustomGapListRow(
    long      CustomGapId,
    long      OrganizationId,
    string    GapTypeCode,
    string    Title,
    string?   Description,
    string    Priority,
    long?     OwnerEmployeeId,
    DateTime? DueDate,
    string    Status,
    string?   Remarks,
    long?     LinkedTaskId,
    DateTime  EnteredDt,
    string    EnteredBy,
    // Stage 4b unified extensions (nullable / defaulted for legacy rows):
    string?   GapSourceModuleCode  = null,
    string?   SourceReferenceType  = null,
    long?     SourceReferenceId    = null,
    string?   SeverityCode         = null,
    string?   SeverityName         = null,
    string?   OwnerDisplayName     = null,
    string?   ReviewerDisplayName  = null,
    DateTime? TargetResolutionDate = null,
    string?   ExecutionCode        = null,
    string?   ExecutionName        = null,
    string?   EntityDimensionCode  = null,
    string?   EntityDimensionName  = null,
    string?   EntityCode           = null,
    string?   EntityName           = null,
    string?   ObservationCode      = null,
    string?   ObservationTitle     = null,
    DateTime? OpenedDt             = null,
    DateTime? ClosedDt             = null,
    long?     RiskId               = null,
    long      LinkedObservationCount = 0,
    long      ActionCount            = 0,
    long      ActionCompletedCount   = 0,
    // 116b hybrid role+employee
    long?     OwnerRoleId            = null,
    string?   OwnerRoleName          = null,
    long?     AssignedReviewerRoleId = null,
    string?   AssignedReviewerRoleName = null);

public sealed record CustomGapListResult(
    long TotalCount,
    int  PageNumber,
    int  PageSize,
    IReadOnlyList<CustomGapListRow> Rows);

public sealed record CustomGapCommandResult(
    bool    Success,
    long?   CustomGapId,
    string? Error      = null,
    string? ReasonCode = null);

// ---------- Detail ----------
public sealed record CustomGapDetail(
    long      CustomGapId,
    long      OrganizationId,
    string    GapTypeCode,
    string    GapSourceModuleCode,
    string?   SourceReferenceType,
    long?     SourceReferenceId,
    string    Title,
    string?   Description,
    string    Priority,
    string?   SeverityCode,
    string?   SeverityName,
    long?     OwnerEmployeeId,
    string?   OwnerDisplayName,
    long?     OwnerRoleId,
    string?   OwnerRoleName,
    long?     ReviewerEmployeeId,
    string?   ReviewerDisplayName,
    long?     ReviewerRoleId,
    string?   ReviewerRoleName,
    DateTime? DueDate,
    DateTime? TargetResolutionDate,
    string    Status,
    string?   ExecutionCode,
    string?   ExecutionName,
    string?   EntityDimensionCode,
    string?   EntityDimensionName,
    string?   EntityCode,
    string?   EntityName,
    string?   ObservationCode,
    string?   ObservationTitle,
    DateTime? OpenedDt,
    DateTime? RemediationSubmittedDt,
    DateTime? VerifiedDt,
    DateTime? ClosedDt,
    DateTime? ReopenedDt,
    string?   RemediationPlan,
    string?   ResolutionNotes,
    string?   VerificationNotes,
    string?   ClosureNotes,
    string?   Remarks,
    long?     LinkedTaskId,
    long?     RiskId,
    string?   EnteredBy,
    DateTime? EnteredDt,
    string?   UpdatedBy,
    DateTime? UpdatedDt,
    long      LinkedObservationCount);

// ---------- Save (full unified upsert) ----------
public sealed record CustomGapSaveRequest(
    long      OrganizationId,
    long?     CustomGapId,
    string?   GapSourceModuleCode,
    string?   SourceReferenceType,
    long?     SourceReferenceId,
    string?   GapTypeCode,
    string    Title,
    string?   Description,
    string?   Priority,
    string?   SeverityCode,
    string?   SeverityName,
    long?     OwnerEmployeeId,
    string?   OwnerDisplayName,
    long?     OwnerRoleId,
    string?   OwnerRoleName,
    long?     AssignedReviewerEmployeeId,
    string?   AssignedReviewerDisplayName,
    long?     AssignedReviewerRoleId,
    string?   AssignedReviewerRoleName,
    DateTime? DueDate,
    DateTime? TargetResolutionDate,
    string?   RemediationPlan,
    string?   Remarks,
    string?   Actor);

public sealed record CustomGapSaveResult(
    bool    Success,
    long?   CustomGapId = null,
    string? Error       = null,
    string? ReasonCode  = null);

// ---------- Generate from Assurance observation ----------
public sealed record CustomGapGenerateRequest(
    long    OrganizationId,
    long    ObservationId,
    string? Actor);

public sealed record CustomGapGenerateResult(
    bool    Success,
    long?   CustomGapId = null,
    string? Error       = null,
    string? ReasonCode  = null);

// ---------- Lifecycle / delete command ----------
public sealed record CustomGapCommandRequest(
    long    OrganizationId,
    long    CustomGapId,
    string? Notes,
    string? Actor);

// ---------- Junction (attach / detach / list) ----------
public sealed record CustomGapObservationLinkRow(
    long      JunctionId,
    long      GapId,
    long      ObservationId,
    // For gap -> observations:
    string?   ObservationCode,
    string?   ObservationTitle,
    string?   SeverityCode,
    string?   SeverityName,
    string?   ObservationStatusCode,
    string?   ObservationStatusName,
    string?   ExecutionCode,
    string?   ExecutionName,
    string?   EntityName,
    // For observation -> gaps:
    string?   GapTitle,
    string?   SourceModule,
    string?   GapStatusCode,
    // Common:
    string    LinkSource,
    string    LinkedBy,
    DateTime  LinkedDt,
    string?   Notes,
    bool      IsActive,
    string?   DetachBy,
    DateTime? DetachDt,
    string?   DetachReason);

public sealed record CustomGapAttachRequest(
    long    OrganizationId,
    long    CustomGapId,
    long    ObservationId,
    string? LinkSource,
    string? Notes,
    string? Actor);

public sealed record CustomGapAttachResult(
    bool    Success,
    long?   JunctionId = null,
    string? Error      = null,
    string? ReasonCode = null);

public sealed record CustomGapDetachRequest(
    long    OrganizationId,
    long    CustomGapId,
    long    ObservationId,
    string? Reason,
    string? Actor);

// ---------- Merge ----------
public sealed record CustomGapMergeRequest(
    long    OrganizationId,
    long    SourceCustomGapId,
    long    TargetCustomGapId,
    string? Reason,
    string? Actor);

public sealed record CustomGapMergeResult(
    bool    Success,
    long?   TargetCustomGapId = null,
    string? Error             = null,
    string? ReasonCode        = null);

// ---------- Actions ----------
public sealed record CustomGapActionRow(
    long      ActionId,
    long      GapId,
    int       ActionOrder,
    string    ActionTitle,
    string?   ActionDescription,
    long?     AssignedEmployeeId,
    string?   AssignedDisplayName,
    DateTime? DueDate,
    DateTime? CompletedDt,
    string    ActionStatusCode,
    long?     TaskId,
    string?   Notes,
    string?   EnteredBy,
    DateTime? EnteredDt,
    string?   UpdatedBy,
    DateTime? UpdatedDt,
    // 116b hybrid role+employee
    long?     AssignedRoleId   = null,
    string?   AssignedRoleName = null);

public sealed record CustomGapActionSaveRequest(
    long      OrganizationId,
    long      CustomGapId,
    long?     ActionId,
    int       ActionOrder,
    string    ActionTitle,
    string?   ActionDescription,
    long?     AssignedEmployeeId,
    string?   AssignedDisplayName,
    DateTime? DueDate,
    string?   ActionStatusCode,
    string?   Notes,
    string?   Actor,
    // 116b hybrid role+employee
    long?     AssignedRoleId   = null,
    string?   AssignedRoleName = null);

public sealed record CustomGapActionSaveResult(
    bool    Success,
    long?   ActionId   = null,
    string? Error      = null,
    string? ReasonCode = null);

// ---------- History ----------
public sealed record CustomGapHistoryRow(
    long      HistoryId,
    string    ActionCode,
    string?   FromStatusCode,
    string?   ToStatusCode,
    string?   ReasonText,
    string?   ActorDisplayName,
    string?   EnteredBy,
    DateTime? EnteredDt);

// ---------- Migration 184: SLA override (goes to Exception Centre) ----------
// Payload for `POST /api/practice/custom-gaps/{id}/sla/override`.
// Reason is mandatory; approver simply approves/rejects -- the request
// already carries the exact days being requested.
public sealed record SlaOverrideRequestPayload(
    long    CustomGapId,
    int     SlaDaysRequested,
    string  RequestReason,
    long?   RequestedByEmployeeId,
    string? CallerDisplayName);

public sealed record SlaOverrideRequestResult(
    bool    Success,
    long?   ExceptionRequestId,
    string? Error);
