// =====================================================================
// TaskNotificationModels  (Task Centre v2, Phase 3 — BRD §13)
//
// Contracts for TaskNotificationController. Own file per charter §5.
//
// These describe an OBLIGATION TO NOTIFY, not a message that was sent.
// Phase 3 has no dispatcher — see TaskNotificationService's header for
// why. Every field is therefore about the decision (who, why, when, on
// what grounds), with a small delivery lifecycle attached for whatever
// dispatcher is built later.
//
// Backing migrations: 201-202. See docs/task-centre-v2.md.
// =====================================================================
namespace PracticeManagement.Api.Models;

public sealed record TaskNotificationListQuery(
    long? OrganizationId,
    long? RecipientEmployeeId,
    long? TaskId,
    string? StatusCode,          // Pending | Sent | Failed | Suppressed
    string? NotifyEventCode,     // WARNING | BREACH | ESCALATION
    int Page = 1,
    int PageSize = 25);

public sealed record TaskNotificationRow(
    long TaskNotificationId,
    long OrganizationId,
    long TaskId,
    string? TaskNumber,
    string? TaskTitle,
    string? Priority,
    string NotifyEventCode,

    /// <summary>Null when the notified role has no active holder. That row is
    /// kept on purpose — "we were supposed to escalate and nobody holds
    /// the role" is a governance gap worth surfacing, not an error to
    /// swallow.</summary>
    long? RecipientEmployeeId,
    string? RecipientName,
    string? RecipientEmail,
    long? RoleId,
    string? RoleName,
    /// <summary>OWNER (BRD §13 owner reminders) or ROLE (configured
    /// management escalation).</summary>
    string RecipientReasonCode,

    string? Subject,
    string? BodyText,
    string? SlaStatusCode,
    /// <summary>The effective due date when the threshold was crossed. Part of
    /// the dedupe key, so an approved SLA extension re-arms the sequence
    /// exactly once.</summary>
    DateTime? DueAt,

    string StatusCode,
    int AttemptCount,
    DateTime? LastAttemptDt,
    string? FailureReason,
    DateTime? SentDt,
    DateTime EnteredDt);

public sealed record TaskNotificationListResult(
    long TotalCount,
    int PageNumber,
    int PageSize,
    IReadOnlyList<TaskNotificationRow> Rows);

public sealed record TaskNotificationCounts(
    long PendingCount,
    long SentCount,
    long FailedCount,
    long SuppressedCount,
    long WarningCount,
    long BreachCount,
    long EscalationCount,
    /// <summary>Obligations that could not be routed to a person because the
    /// configured role has no active holder.</summary>
    long UnroutableCount);

/// <summary>Dispatcher feedback. This layer has no opinion about retry
/// policy — the dispatcher owns that and reports the outcome.</summary>
public sealed record TaskNotificationMarkRequest(
    long TaskNotificationId,
    string StatusCode,
    string? FailureReason);

public sealed record TaskNotificationCommandResult(
    bool Success,
    long? TaskNotificationId = null,
    string? StatusCode = null,
    string? Error = null,
    string? ReasonCode = null);

/// <summary>
/// One sweep pass. <see cref="Enqueued"/> is 0 in a steady state — every
/// crossed threshold has already been recorded — so a non-zero value means
/// something genuinely changed.
/// </summary>
public sealed record TaskNotificationSweepResult(
    int Enqueued,
    int TasksScanned);
