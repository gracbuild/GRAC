// =====================================================================
// TaskModels  (charter §12.1.3)
//
// Request / response contracts for TaskController. Kept in its own file
// per charter §5 non-negotiable (do not extend PracticeRepositoryModels).
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
    Guid? CorrelationId);

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
    int PageSize = 25);

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
    DateTime? ClosedAt);

public sealed record TaskListResult(
    long TotalCount,
    int PageNumber,
    int PageSize,
    IReadOnlyList<TaskListRow> Rows);

public sealed record TaskCommandResult(
    bool Success,
    long? TaskId = null,
    string? Error = null,
    string? ReasonCode = null);
