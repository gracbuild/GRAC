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
    long?   ActorEmployeeId,
    // Migration 250: detection method + severity captured at Add-Gap
    // time on Custom gaps. All optional and last so an older payload
    // still binds; NULL leaves the store un-opinionated and the
    // fallback path (severity -> priority) still applies.
    string? SeverityCode         = null,
    string? SeverityName         = null,
    string? DetectionMethodCode  = null,
    string? DetectionMethodName  = null,
    // Migration 382: practice ids to map to the new Custom Gap. Optional
    // and last so an older payload still binds; the UI/API require >= 1.
    IReadOnlyList<long>? PracticeIds = null);

// Migration 382: one practice mapped to a Custom Gap (read model for the
// read-only display on the Gap view / detail).
public sealed record CustomGapPracticeRow(
    long   CustomGapPracticeMapId,
    long   CustomGapId,
    long   PracticeId,
    string? PracticeName,
    string? PracticeCode,
    DateTime? MappedDt);

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

// ---------- Migration 255: the unified Gap Centre list ----------
/// <summary>
/// One row of <c>grac_practice.sp_gap_centre_list</c>, which UNIONs the
/// two origins Gap Centre used to show as separate tabs:
/// <c>custom_gap</c> (every source module) and <c>practice_gap</c> rows
/// that have not been materialized into a custom gap yet.
/// <para>
/// Columns only one origin can answer are null on the other rather than
/// faked — an un-materialized instance gap has no CustomGapId and no due
/// date, and a custom gap has no PracticeGapId. <see cref="IsMaterialized"/>
/// says which arm the row came from, which is what decides whether the
/// screen offers Materialize on it.
/// </para>
/// </summary>
public sealed record GapCentreListRow(
    string    RowKey,
    string    SourceModuleCode,
    long?     CustomGapId,
    long?     PracticeGapId,
    long?     PracticeInstanceId,
    bool      IsMaterialized,
    string?   Title,
    string?   Context,
    /// <summary>Migration 318: the gap's lifecycle stage (New / Analysed /
    /// Invalid / Duplicate / a dormant historical name) on the custom_gap
    /// arm — the same value sp_custom_gap_header projects as
    /// LifecycleStateName. On the practice_gap arm (no lifecycle state
    /// yet) this stays the worst logged Obligation status, unchanged.</summary>
    string?   StatusText,
    string?   SeverityText,
    string?   OwnerText,
    DateTime? DueDate,
    DateTime? OpenedDt,
    int       LinkedCount,
    /// <summary>Instance code/name, non-null only on the practice_gap arm —
    /// the Add Implementation Task dialog needs them as separate values.</summary>
    string?   InstanceCode,
    string?   InstanceName,
    int       ExistingTaskCount,
    /// <summary>Migration 318: custom_gap.status verbatim (Open /
    /// InProgress / Closed / Cancelled), NULL on the practice_gap arm.
    /// StatusText above no longer carries this — the UI's "already
    /// Closed/Cancelled" check (Close Gap menu action) reads this
    /// instead. Trailing/optional so the one existing call site keeps
    /// compiling without every field re-supplied in a specific order.</summary>
    string?   RawStatusCode = null,
    /// <summary>Migration 324: the raw lifecycle state_code (e.g.
    /// "Delegated"), NULL on the practice_gap arm. StatusText carries the
    /// DISPLAY name ("Analysed") which 175/319 already show can be
    /// reworded — this is the stable code the UI gates View-vs-Analysis
    /// on instead. Trailing/optional for the same reason as RawStatusCode
    /// above.</summary>
    string?   LifecycleStateCode = null,
    /// <summary>Migration 371: derived from the current obligation state of
    /// the Practice Instance behind the Gap ("Implemented" when every
    /// obligation is Implemented, else "Not Implemented"), reusing
    /// practice_gap.gap_status (kept live by sp_practice_gap_sync_for_instance,
    /// migration 367) rather than re-deriving it. NULL when the Gap has no
    /// linked Practice Instance.</summary>
    string?   PracticeInstanceStatusText = null,
    /// <summary>Migration 371: aggregated across every Task linked to this
    /// Gap (practice_task.subject_entity_type = 'CustomGap') -- "Completed"
    /// only when all linked Tasks are in a terminal status
    /// (entity_status_master.is_terminal = 1, i.e. Closed/Cancelled),
    /// "Pending" if any are not. NULL when the Gap has no linked Tasks.</summary>
    string?   TaskStatusText = null,
    /// <summary>Migration 371: the most recently linked Risk's status --
    /// risk_register.status_code when the candidate has been registered
    /// (registered_risk_id set), else risk_candidate.status_code, matching
    /// gap-view.js's buildRiskCard() precedence. NULL when the Gap has no
    /// linked Risk.</summary>
    string?   RiskStatusText = null,
    /// <summary>Migration 371: the most recently linked Exception's
    /// exception_request.status_code. NULL when the Gap has no linked
    /// Exception.</summary>
    string?   ExceptionStatusText = null);

public sealed record GapCentreListQuery(
    long?   OrganizationId,
    string? SourceModuleCode,
    string? StatusCode,
    string? Search,
    /// <summary>Assurance Observations deep-links here with one. Only the
    /// custom_gap arm can answer it, so it suppresses the practice_gap
    /// arm rather than returning unrelated instance gaps.</summary>
    long?   ObservationId = null,
    int     Page     = 1,
    int     PageSize = 25);

public sealed record GapCentreListResult(
    long TotalCount,
    int  PageNumber,
    int  PageSize,
    IReadOnlyList<GapCentreListRow> Rows,
    /// <summary>
    /// Null on success. Set when the read failed — most often because
    /// migration 255 has not been applied, which otherwise surfaces as a
    /// bare HTTP 500 with nothing on screen to say why.
    /// </summary>
    string? Error = null);

/// <summary>
/// One entry of the Source filter. The full CHECK-constraint vocabulary
/// is returned including zero counts, so the dropdown does not gain and
/// lose options as data changes.
/// </summary>
public sealed record GapCentreSourceCount(
    string SourceModuleCode,
    int    DisplayOrder,
    long   GapCount);

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
