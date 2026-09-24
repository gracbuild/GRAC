// =====================================================================
// TaskModels  (charter §12.1.3)
//
// Request / response contracts for TaskController. Kept in its own file
// per charter §5 non-negotiable (do not extend PracticeRepositoryModels).
//
// Task Centre v2 (BRD 16 Aug 2026) additions are grouped at the bottom
// under clearly marked regions. Everything above them is the original
// contract, unchanged, so existing callers keep compiling.
//
// Backing migrations: 192-196. See docs/task-centre-v2.md.
// =====================================================================
namespace PracticeManagement.Api.Models;

public sealed record TaskOpenRequest(
    long OrganizationId,
    string TaskTypeCode,
    string SubjectEntityType,
    long SubjectEntityId,
    string SubjectTitle,
    string? SubjectDescription,
    long? LinkedReleaseId,
    long? LinkedControlId,
    long? LinkedPracticeId,
    long? LinkedInstanceId,
    string? Priority,
    string? Criticality,
    string? OriginCode,
    long? AssignedToEmployeeId,
    long? ActorEmployeeId,
    string? ActorRoleCode,
    Guid? CorrelationId,
    // ---- Task Centre v2 (196: sp_task_open v3) ----------------------
    // All optional. SourceTypeCode/SourceRecordId let a caller state the
    // BRD §15 origin explicitly; when omitted the proc derives it from
    // SubjectEntityType. ResolveOwner defaults to true — pass false only
    // when the caller deliberately wants an unassigned task.
    string? SourceTypeCode = null,
    long? SourceRecordId = null,
    string? SourceReference = null,
    bool? ResolveOwner = null,
    DateTime? StartDate = null,
    DateTime? TargetDate = null);

public sealed record TaskAssignRequest(
    long TaskId,
    long AssignedToEmployeeId,
    long? ActorEmployeeId,
    string? ActorRoleCode,
    string? ReasonCode,
    string? ReasonText,
    Guid? CorrelationId);

public sealed record TaskTransitionRequest(
    long TaskId,
    string ToStatusCode,
    long? ActorEmployeeId,
    string? ActorRoleCode,
    string? ReasonCode,
    string? ReasonText,
    Guid? CorrelationId);

public sealed record TaskCloseRequest(
    long TaskId,
    long? ActorEmployeeId,
    string? ActorRoleCode,
    string? ReasonCode,
    string? ReasonText,
    Guid? CorrelationId);

public sealed record TaskListQuery(
    long? OrganizationId,
    long? AssignedToEmployeeId,
    string? TaskTypeCode,
    string? StatusCode,       // 'OpenSet' or a specific status_code
    bool? OverdueOnly,
    string? Search,
    int Page = 1,
    int PageSize = 25,
    // ---- Task Centre v2 (195: sp_task_list) -------------------------
    // IncludeChildren defaults to false: child tasks are sub-activities
    // of a parent work package and would misrepresent the grid if listed
    // as peers (BRD §11). Setting ParentTaskId implies IncludeChildren.
    long? ParentTaskId = null,
    bool? IncludeChildren = null,
    string? SlaStatusCode = null,
    string? SourceTypeCode = null,
    long? SourceRecordId = null,
    string? Priority = null);

public sealed record TaskListRow(
    long TaskId,
    long OrganizationId,
    string TaskTypeCode,
    string TaskTypeName,
    string SubjectEntityType,
    long SubjectEntityId,
    long? LinkedReleaseId,
    long? LinkedControlId,
    long? LinkedPracticeId,
    long? LinkedInstanceId,
    string SubjectTitle,
    string? SubjectDescription,
    long? AssignedToEmployeeId,
    string CurrentStatusCode,
    string CurrentStatusName,
    bool CurrentStatusIsTerminal,
    string Priority,
    string? Criticality,
    string? OriginCode,
    DateTime? SlaDueAt,
    bool IsOverdue,
    DateTime? EscalatedAt,
    string? ReasonCode,
    string? ReasonText,
    DateTime? ClosedAt,

    // =================================================================
    // Task Centre v2 — all defaulted so the record stays constructible
    // from the pre-192 column set while migrations roll out.
    // =================================================================

    // ---- Identity / ownership (BRD §6, §16) -------------------------
    string? TaskNumber = null,
    string? AssignedToEmployeeName = null,
    string? OwnerSourceCode = null,

    // ---- SLA split (BRD §8) -----------------------------------------
    int? StandardSlaDays = null,
    DateTime? StandardDueAt = null,
    DateTime? ApprovedExtendedDueAt = null,
    string? SlaSourceCode = null,
    string? SlaMasterName = null,
    string? ExtensionStatusCode = null,
    DateTime? RequestedDueAt = null,
    string? ExtensionReason = null,
    bool IsExtended = false,

    // ---- SLA monitoring (BRD §13, §17) -------------------------------
    string? SlaTimingCode = null,
    string? SlaStatusCode = null,
    int? DaysToDue = null,

    // ---- Priority governance (BRD §7) --------------------------------
    string? RequestedPriority = null,
    string? PriorityChangeStatusCode = null,

    // ---- Parent / child (BRD §11, §12) -------------------------------
    long? ParentTaskId = null,
    string? ParentTaskNumber = null,
    string? ParentTaskTitle = null,
    bool IsChild = false,
    bool? IsMandatoryChild = null,
    DateTime? ChildTargetDate = null,
    int ChildCount = 0,
    int MandatoryChildCount = 0,
    int MandatoryChildOpenCount = 0,
    bool IsEligibleForCompletion = false,

    // ---- Source navigation (BRD §15) ---------------------------------
    string? SourceTypeCode = null,
    long? SourceRecordId = null,
    string? SourceReference = null,

    // ---- Completion (BRD §10) ----------------------------------------
    long? CompletedByEmployeeId = null,
    string? CompletedByEmployeeName = null,
    DateTime? CompletedDt = null,

    // ---- Organization (326) -------------------------------------------
    // Resolved once, on vw_pm_practice_task (326), for the Task View full
    // page's "Related Organization" fact. Null against an un-migrated
    // database -- read tolerantly by MapRow like every other v2 column.
    string? OrganizationName = null,

    // ---- Created / Updated (326) --------------------------------------
    // practice_task.entered_by/entered_dt/updated_by/updated_dt have
    // always been on vw_pm_practice_task (195); nothing read them until
    // the Task View full page needed a Created/Updated section.
    string? EnteredBy = null,
    DateTime? EnteredDt = null,
    string? UpdatedBy = null,
    DateTime? UpdatedDt = null);

public sealed record TaskListResult(
    long TotalCount,
    int PageNumber,
    int PageSize,
    IReadOnlyList<TaskListRow> Rows);

public sealed record TaskCommandResult(
    bool Success,
    long? TaskId = null,
    string? Error = null,
    string? ReasonCode = null,
    // Populated when the command produced an Exception Centre request
    // instead of applying the change directly (BRD §7, §8).
    long? ExceptionRequestId = null,
    string? StatusCode = null);

// =====================================================================
// Task Centre v2 — detail view  (BRD §16)
// =====================================================================

public sealed record TaskActivityRow(
    long TaskActivityId,
    long TaskId,
    string ActivityTypeCode,
    string? Remark,
    string? FromValue,
    string? ToValue,
    long? ActorEmployeeId,
    string? ActorDisplayName,
    DateTime EnteredDt);

public sealed record TaskAttachmentRow(
    long TaskAttachmentId,
    string FileName,
    string? ContentType,
    long FileSizeBytes,
    string? EvidenceDescription,
    long? UploadedByEmployeeId,
    string? UploadedByName,
    DateTime UploadedDt);

public sealed record TaskChildRow(
    long TaskId,
    string? TaskNumber,
    string SubjectTitle,
    string? SubjectDescription,
    long? AssignedToEmployeeId,
    string? AssignedToEmployeeName,
    string Priority,
    bool? IsMandatoryChild,
    DateTime? ChildTargetDate,
    DateTime? SlaDueAt,
    string? SlaStatusCode,
    string CurrentStatusCode,
    string CurrentStatusName,
    DateTime? ClosedAt,
    DateTime? CompletedDt);

/// <summary>
/// An Exception Centre request raised against a task — either a
/// TASK_SLA_EXTENSION (BRD §8) or a TASK_PRIORITY_REDUCTION (BRD §7).
/// </summary>
public sealed record TaskGovernanceRequestRow(
    long ExceptionRequestId,
    string RequestTypeCode,
    string RequestTitle,
    string? RequestReason,
    string StatusCode,
    string? PriorityOriginal,
    string? PriorityRequested,
    DateTime? DueAtOriginal,
    DateTime? DueAtRequested,
    DateTime? RequestedOn,
    string? RequestedByName,
    DateTime? ApprovedOn,
    string? ApprovedByName,
    DateTime? RejectedOn,
    string? RejectedByName,
    string? RejectionReason);

public sealed record TaskDetailResult(
    TaskListRow Header,
    IReadOnlyList<TaskActivityRow> Activity,
    IReadOnlyList<TaskAttachmentRow> Attachments,
    IReadOnlyList<TaskChildRow> Children,
    IReadOnlyList<TaskGovernanceRequestRow> GovernanceRequests);

// =====================================================================
// Task Centre v2 — commands
// =====================================================================

/// <summary>
/// BRD §7. An increase applies immediately; a reduction creates a
/// Pending Exception Centre request and changes nothing on the task
/// until it is approved. Reason and ActorEmployeeId are mandatory for a
/// reduction — the proc rejects the call without them.
/// </summary>
public sealed record TaskPriorityChangeRequest(
    long TaskId,
    string NewPriority,
    string? Reason,
    long? ActorEmployeeId);

/// <summary>BRD §8. RequestedDueAt must be LATER than the current due date —
/// early completion never needs approval.</summary>
public sealed record TaskSlaExtensionRequest(
    long TaskId,
    DateTime RequestedDueAt,
    string ExtensionReason,
    long RequestedByEmployeeId);

/// <summary>Approval of a Pending TASK_SLA_EXTENSION or
/// TASK_PRIORITY_REDUCTION, from the Exception Centre.</summary>
public sealed record TaskGovernanceApproveRequest(
    long ExceptionRequestId,
    long ApprovedByEmployeeId);

/// <summary>BRD §11. Priority and SLA are inherited from the parent and are
/// not accepted here — they are read-only on a child.</summary>
public sealed record TaskChildCreateRequest(
    long ParentTaskId,
    string SubjectTitle,
    string? SubjectDescription,
    long? AssignedToEmployeeId,
    bool? IsMandatory,
    DateTime? ChildTargetDate,
    long? ActorEmployeeId);

/// <summary>BRD §10/§12. Fails with COMPLETION_BLOCKED when mandatory child
/// tasks are still open, and still honours the Implementation two-gate
/// closure rule from §12.2.3.</summary>
public sealed record TaskCompleteRequest(
    long TaskId,
    string? CompletionRemark,
    long? ActorEmployeeId,
    string? ActorRoleCode);

public sealed record TaskCompletionEligibility(
    long TaskId,
    bool IsEligible,
    string Reason,
    int ChildCount,
    int MandatoryChildCount,
    int MandatoryChildCompletedCount,
    int MandatoryChildOpenCount);

public sealed record TaskActivityAddRequest(
    long TaskId,
    string ActivityTypeCode,
    string? Remark,
    string? FromValue,
    string? ToValue,
    long? ActorEmployeeId);

// =====================================================================
// Task edit — migration 269
//
// ONE request for every editable field, replacing the four single-field
// commands the UI used to call one at a time (transition, assign,
// priority, sla-extension). Those commands still exist and still own
// their rules; sp_task_update composes them.
//
// EVERY FIELD IS NULLABLE AND NULL MEANS "LEAVE ALONE", not "clear".
// A partial form (the mobile edit sheet, a future inline editor) can
// post only what it shows without blanking what it does not.
//
// The consequence, stated because it is a real limitation: a field
// cannot be cleared through this contract. Nothing in the current form
// needs to clear one -- title and owner are required, dates are governed
// -- so an explicit "clear this field" marker is not invented ahead of a
// caller that wants it.
// =====================================================================

/// <summary>
/// One save for the whole edit form (migration 269).
///
/// <para><b>Not every field applies immediately.</b> Priority reductions
/// (§7) and due-date changes (§8) create Exception Centre requests and
/// leave the task untouched until approved. The per-field
/// <see cref="TaskFieldChange.Outcome"/> in the result says which
/// happened; the caller must not report "saved" without reading it.</para>
///
/// <para><b>All or nothing.</b> If any field is refused the whole edit
/// rolls back, so the form the user is looking at still matches the task.</para>
///
/// <para><see cref="ExpectedUpdatedDt"/> is optimistic concurrency: pass
/// the value the form was loaded with and a save is refused (56705) if
/// someone else edited the task meanwhile. NULL skips the check.</para>
/// </summary>
public sealed record TaskUpdateRequest(
    long TaskId,
    string? SubjectTitle = null,
    string? SubjectDescription = null,
    long? AssignedToEmployeeId = null,
    string? Priority = null,
    string? StatusCode = null,
    DateTime? StartDate = null,
    DateTime? DueAt = null,
    bool? IsMandatoryChild = null,
    DateTime? ChildTargetDate = null,
    // Required by the governed paths (a priority reduction and an SLA
    // extension are both refused without one); optional for the rest.
    string? ChangeReason = null,
    long? ActorEmployeeId = null,
    string? ActorRoleCode = null,
    DateTime? ExpectedUpdatedDt = null);

/// <summary>
/// What one field did. <c>Outcome</c> is <c>Applied</c> (the task
/// changed), <c>PendingApproval</c> (a request was raised and the task
/// did NOT change), or <c>Unchanged</c>.
///
/// <para>FromValue/ToValue are the same strings written to
/// <c>task_activity</c>, so the confirmation the user sees after saving
/// and the audit row recorded against the task cannot disagree.</para>
/// </summary>
public sealed record TaskFieldChange(
    string FieldCode,
    string FieldLabel,
    string? FromValue,
    string? ToValue,
    string Outcome,
    string? Detail);

/// <summary>
/// An empty <see cref="Changes"/> list means the form was saved with
/// nothing actually different — reported honestly rather than as a save.
/// </summary>
public sealed record TaskUpdateResult(
    bool Success,
    long TaskId,
    IReadOnlyList<TaskFieldChange> Changes,
    string? Error = null,
    string? ReasonCode = null)
{
    public bool AnyApplied         => Changes.Any(c => c.Outcome == "Applied");
    public bool AnyPendingApproval => Changes.Any(c => c.Outcome == "PendingApproval");
}

/// <summary>
/// What the editor may offer for one task (migration 269), so the UI
/// never renders a control whose save SQL would refuse.
///
/// <para><see cref="AllowedStatuses"/> comes from
/// <c>fn_is_transition_allowed</c> against the live rule table — not a
/// list hard-coded in JavaScript that drifts the day a status is added.
/// Closed and Cancelled are deliberately absent: a task is closed with
/// Complete or Close, which carry the §12 gate and the completion
/// record.</para>
/// </summary>
public sealed record TaskEditOptions(
    long TaskId,
    string? CurrentStatusCode,
    string? TaskTypeCode,
    string? CurrentPriority,
    bool IsChild,
    bool IsTerminal,
    bool CanEdit,
    bool CanEditPriority,
    bool CanEditDueDate,
    bool PriorityChangePending,
    bool SlaExtensionPending,
    bool CanEditMandatory,
    IReadOnlyList<TaskStatusOption> AllowedStatuses,
    // Current values the editor needs that TaskListRow does not carry.
    // Returned here rather than widening the list contract that every
    // grid, count and export reads, to serve one form.
    DateTime? StartDate = null,
    bool? IsMandatoryChild = null,
    DateTime? ChildTargetDate = null,
    // Optimistic-concurrency token: post it back as
    // TaskUpdateRequest.ExpectedUpdatedDt and a save is refused if
    // someone else changed the task in the meantime.
    DateTime? UpdatedDt = null);

public sealed record TaskStatusOption(string StatusCode, string StatusName);

/// <summary>BRD §6. Read-only preview of the owner ladder — used by the
/// UI to show "Proposed owner: X (Practice owner)" before anything is
/// committed.</summary>
public sealed record TaskOwnerResolveQuery(
    long OrganizationId,
    string? SourceTypeCode,
    long? SourceRecordId,
    long? LinkedPracticeId,
    long? LinkedControlId,
    long? LinkedInstanceId,
    long? ExplicitOwnerEmployeeId);

public sealed record TaskOwnerResolveResult(
    long? OwnerEmployeeId,
    string? OwnerEmployeeName,
    string OwnerSourceCode,
    string OwnerSourceName);

/// <summary>BRD §15. One source item may generate many tasks.</summary>
public sealed record TaskSourceTaskRow(
    long TaskId,
    string? TaskNumber,
    string SubjectTitle,
    string TaskTypeCode,
    string TaskTypeName,
    long? AssignedToEmployeeId,
    string? AssignedToEmployeeName,
    string Priority,
    DateTime? StandardDueAt,
    DateTime? ApprovedExtendedDueAt,
    DateTime? SlaDueAt,
    string? SlaStatusCode,
    string CurrentStatusCode,
    string CurrentStatusName,
    bool IsChild,
    long? ParentTaskId,
    int ChildCount,
    DateTime? ClosedAt,
    DateTime? CompletedDt);

public sealed record TaskAttachmentContent(
    long TaskAttachmentId,
    long TaskId,
    string FileName,
    string? ContentType,
    long FileSizeBytes,
    byte[] FileData);

public sealed record TaskCountsResult(
    long GapsCount,
    long ImplementationCount,
    long AssuranceCount,
    long CustomCount,
    long BreachedCount,
    long PendingApprovalCount);

// ---------- Migration 256: Task Centre Source filter counts ----------
/// <summary>
/// One entry of Task Centre's Source dropdown. Mirrors
/// <c>GapCentreSourceCount</c> so the two Centres read the same way — the
/// full <c>ck_pm_practice_task_source_type</c> vocabulary, zero counts
/// included, rather than only the values that happen to have rows.
/// </summary>
public sealed record TaskSourceCount(
    string SourceTypeCode,
    int    DisplayOrder,
    long   TaskCount);

/// <summary>
/// Totals alongside the per-source counts. <see cref="UnsourcedCount"/>
/// is reported rather than hidden so the dropdown's numbers reconcile
/// against the grid, but it is not filterable — <c>sp_task_list</c>'s
/// predicate cannot express "source is null".
/// </summary>
public sealed record TaskSourceCountsResult(
    IReadOnlyList<TaskSourceCount> Sources,
    long TotalCount,
    long UnsourcedCount,
    string? Error = null);
