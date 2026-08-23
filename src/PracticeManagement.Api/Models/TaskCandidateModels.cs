// =====================================================================
// TaskCandidateModels  (Task Centre v2, Phase 2 — BRD §4, §5, §14, §15)
//
// Contracts for TaskCandidateController. Kept in its own file per charter
// §5: do not extend TaskModels.cs, which belongs to the task engine.
//
// A Task Candidate is "an identified action awaiting execution
// validation" (BRD §2). The only questions this stage asks are WHO owns
// it and HOW URGENT it is — the SLA follows from urgency, and everything
// else (severity, impact, root cause) stays with the source. That is why
// these records look thin compared with TaskListRow: they are meant to.
//
// Backing migrations: 197-200. See docs/task-centre-v2.md.
// =====================================================================
namespace PracticeManagement.Api.Models;

public sealed record TaskCandidateListQuery(
    long? OrganizationId,
    string? StatusCode,          // 'OpenSet' = New + Validated, else a specific status
    string? SourceTypeCode,
    long? SourceRecordId,
    long? OwnerEmployeeId,
    string? Priority,
    string? Search,
    int Page = 1,
    int PageSize = 25);

public sealed record TaskCandidateRow(
    long TaskCandidateId,
    string? CandidateNumber,
    long OrganizationId,
    string SourceTypeCode,
    long SourceRecordId,
    string? SourceReference,
    string CandidateTitle,
    string? CandidateDescription,
    string TaskTypeCode,
    long? ProposedOwnerEmployeeId,
    string? ProposedOwnerName,
    string? OwnerSourceCode,
    string ProposedPriority,
    int? ProposedSlaDays,
    DateTime? ProposedDueAt,
    string? SlaMasterName,
    string? SlaSourceCode,
    string StatusCode,
    long? ApprovedTaskId,
    string? ApprovedTaskNumber,
    /// <summary>BRD §5 — a candidate may only be approved once an owner is
    /// confirmed. Drives the Approve button.</summary>
    bool IsReadyToApprove,
    DateTime EnteredDt,
    string? EnteredBy);

public sealed record TaskCandidateListResult(
    long TotalCount,
    int PageNumber,
    int PageSize,
    IReadOnlyList<TaskCandidateRow> Rows);

public sealed record TaskCandidateHistoryRow(
    long TaskCandidateHistoryId,
    string ActionCode,
    string? FromStatusCode,
    string? ToStatusCode,
    string? Remark,
    long? ActorEmployeeId,
    string? ActorDisplayName,
    DateTime EnteredDt);

public sealed record TaskCandidateDetail(
    long TaskCandidateId,
    string? CandidateNumber,
    long OrganizationId,
    string SourceTypeCode,
    long SourceRecordId,
    string? SourceReference,
    string? SourceDedupeKey,
    string CandidateTitle,
    string? CandidateDescription,
    string TaskTypeCode,
    long? LinkedReleaseId,
    long? LinkedControlId,
    long? LinkedPracticeId,
    long? LinkedInstanceId,
    long? ProposedOwnerEmployeeId,
    string? ProposedOwnerName,
    string? OwnerSourceCode,
    string ProposedPriority,
    int? ProposedSlaDays,
    DateTime? ProposedDueAt,
    long? SlaMasterId,
    string? SlaMasterName,
    string? SlaSourceCode,
    string StatusCode,
    long? ApprovedTaskId,
    string? ApprovedTaskNumber,
    DateTime? ValidatedDt,
    string? ValidatedByName,
    DateTime? ApprovedDt,
    string? ApprovedByName,
    DateTime? DiscardedDt,
    string? DiscardedByName,
    string? DiscardReason,
    bool IsReadyToApprove,
    string? EnteredBy,
    DateTime EnteredDt);

public sealed record TaskCandidateDetailResult(
    TaskCandidateDetail Header,
    IReadOnlyList<TaskCandidateHistoryRow> History);

/// <summary>
/// Manual creation. Automatic generators go through the source procs in
/// 199 instead, which supply their own dedupe key. A manual add passes no
/// key, which is what lets one source raise many tasks (BRD §15).
/// </summary>
public sealed record TaskCandidateCreateRequest(
    long OrganizationId,
    string SourceTypeCode,
    long SourceRecordId,
    string CandidateTitle,
    string? CandidateDescription,
    string? SourceReference,
    string? TaskTypeCode,
    long? LinkedReleaseId,
    long? LinkedControlId,
    long? LinkedPracticeId,
    long? LinkedInstanceId,
    long? ExplicitOwnerEmployeeId,
    string? ProposedPriority,
    long? ActorEmployeeId);

/// <summary>
/// BRD §5 — confirm owner and priority. Priority is NOT governed here the
/// way it is on an Approved Task: a candidate has made no commitment yet,
/// so a validator may move it either way. The §7 asymmetry begins at
/// approval.
/// </summary>
public sealed record TaskCandidateValidateRequest(
    long TaskCandidateId,
    long? ProposedOwnerEmployeeId,
    string? ProposedPriority,
    string? Remark,
    long? ActorEmployeeId);

public sealed record TaskCandidateApproveRequest(
    long TaskCandidateId,
    long? ApprovedByEmployeeId,
    string? Remark);

public sealed record TaskCandidateDiscardRequest(
    long TaskCandidateId,
    string DiscardReason,
    long? DiscardedByEmployeeId);

public sealed record TaskCandidateCommandResult(
    bool Success,
    long? TaskCandidateId = null,
    string? StatusCode = null,
    long? ApprovedTaskId = null,
    string? Error = null,
    string? ReasonCode = null,
    /// <summary>False when an idempotent create matched an existing open
    /// candidate instead of raising a new one.</summary>
    bool Created = false);

public sealed record TaskCandidateCounts(
    long NewCount,
    long ValidatedCount,
    long OpenCount,
    long ApprovedCount,
    long DiscardedCount,
    /// <summary>Open candidates the owner ladder could not resolve — these
    /// are the ones a human has to pick up (BRD §6 rung 7).</summary>
    long UnownedCount);

// =====================================================================
// BRD §15 / §14 — what a source screen shows
// =====================================================================

/// <summary>
/// One row of the source's "Related Tasks" panel. Candidates and tasks
/// arrive in a single list discriminated by <see cref="ItemKind"/>, so a
/// gap owner sees identified-but-not-yet-accountable work alongside real
/// tasks instead of being told nothing is happening.
/// </summary>
public sealed record TaskSourceItemRow(
    string ItemKind,             // 'Candidate' | 'Task'
    long ItemId,
    string? ItemNumber,
    string Title,
    string StatusCode,
    string? StatusName,
    long? OwnerEmployeeId,
    string? OwnerName,
    string Priority,
    DateTime? DueAt,
    string? SlaStatusCode,
    bool IsChild,
    long? ParentTaskId,
    int ChildCount,
    DateTime? CompletedDt,
    DateTime RaisedDt);

/// <summary>
/// BRD §14. Reports that the source's task action is complete — and
/// deliberately says nothing about whether the source itself should
/// close. <see cref="ActionStatusMessage"/> carries the §18 wording,
/// which always hands that decision back to the source module.
/// </summary>
public sealed record TaskSourceActionState(
    string SourceTypeCode,
    long SourceRecordId,
    long? OrganizationId,
    int TotalTasks,
    int OpenTasks,
    int CompletedTasks,
    int OpenCandidates,
    string ActionStatusCode,     // NotStarted | InProgress | Completed
    DateTime? FirstTaskDt,
    DateTime? LastCompletedDt,
    string ActionStatusMessage);
