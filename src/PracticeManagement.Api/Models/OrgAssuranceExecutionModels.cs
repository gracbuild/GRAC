// =====================================================================
// OrgAssuranceExecutionModels
//
// Phase 2 Assurance Management -- Stage 3 Execution (BRD Part 2 Sec
// 9-10). Executions are org-level artifacts that materialize a
// definition + resolved scope + immutable config snapshot into a live
// working record, so this module lives in its own service (matching
// OrgAssurancePlanModels).
// =====================================================================
namespace PracticeManagement.Api.Models;

// ---------- Lookups ----------
public sealed record OrgAssuranceExecutionStatusRow(
    int    StatusId,
    string StatusCode,
    string StatusName,
    int    DisplayOrder,
    bool   IsTerminal);

// ---------- Execution header (list / detail) ----------
public sealed record OrgAssuranceExecutionListQuery(
    long    OrganizationId,
    long?   DefinitionId = null,
    string? StatusCode   = null,
    string? OriginType   = null,
    string? Search       = null,
    int     Page         = 1,
    int     PageSize     = 25);

public sealed record OrgAssuranceExecutionListRow(
    long      ExecutionId,
    long      OrganizationId,
    long      DefinitionId,
    long      DefinitionVersionId,
    string    DefinitionCode,
    string    DefinitionName,
    int       VersionNumber,
    string    ExecutionCode,
    string    ExecutionName,
    string    StatusCode,
    string    StatusName,
    bool      StatusIsTerminal,
    string    OriginType,
    long?     PlanId,
    long?     PlanItemId,
    long?     TriggerConfigId,
    long      ScopeResolutionId,
    // 120 hybrid role+employee Owner -- adjacent to display_name pair.
    long?     OwnerRoleId,
    string?   OwnerRoleName,
    long?     OwnerEmployeeId,
    string?   OwnerDisplayName,
    DateTime? PlannedStartDt,
    DateTime? PlannedEndDt,
    DateTime? ActualStartDt,
    DateTime? ActualEndDt,
    long      TotalEntityCount,
    long      CompletedEntityCount,
    DateTime? EnteredDt,
    DateTime? UpdatedDt);

public sealed record OrgAssuranceExecutionListResult(
    long TotalCount,
    int  PageNumber,
    int  PageSize,
    IReadOnlyList<OrgAssuranceExecutionListRow> Rows);

public sealed record OrgAssuranceExecutionDetail(
    long      ExecutionId,
    long      OrganizationId,
    long      DefinitionId,
    long      DefinitionVersionId,
    string    DefinitionCode,
    string    DefinitionName,
    int       VersionNumber,
    string    ExecutionCode,
    string    ExecutionName,
    string    StatusCode,
    string    StatusName,
    bool      StatusIsTerminal,
    string    OriginType,
    long?     PlanId,
    long?     PlanItemId,
    long?     TriggerConfigId,
    long      ScopeResolutionId,
    string?   DefinitionSnapshotJson,
    string?   QuestionsSnapshotJson,
    string?   EvidenceSnapshotJson,
    string?   WorkflowSnapshotJson,
    string?   ScoringSnapshotJson,
    // 120 hybrid role+employee Owner -- adjacent to display_name pair.
    long?     OwnerRoleId,
    string?   OwnerRoleName,
    long?     OwnerEmployeeId,
    string?   OwnerDisplayName,
    string?   AssignedTeamName,
    DateTime? PlannedStartDt,
    DateTime? PlannedEndDt,
    DateTime? ActualStartDt,
    DateTime? ActualEndDt,
    long      TotalEntityCount,
    long      CompletedEntityCount,
    string?   Notes,
    string?   EnteredBy,
    DateTime? EnteredDt,
    string?   UpdatedBy,
    DateTime? UpdatedDt);

// ---------- Materialize ----------
public sealed record OrgAssuranceExecutionMaterializeRequest(
    long      OrganizationId,
    long      DefinitionId,
    long?     VersionId,
    long      ScopeResolutionId,
    string?   ExecutionCode,
    string?   ExecutionName,
    string?   OriginType,
    long?     PlanId,
    long?     PlanItemId,
    long?     TriggerConfigId,
    DateTime? PlannedStartDt,
    DateTime? PlannedEndDt,
    // 120 hybrid role+employee Owner -- adjacent to display_name pair.
    long?     OwnerRoleId,
    string?   OwnerRoleName,
    long?     OwnerEmployeeId,
    string?   OwnerDisplayName,
    string?   AssignedTeamName,
    string?   Notes,
    string?   Actor);

public sealed record OrgAssuranceExecutionMaterializeResult(
    bool    Success,
    long?   ExecutionId       = null,
    string? ExecutionCode     = null,
    string? ExecutionName     = null,
    long?   TotalEntityCount  = null,
    string? Error             = null,
    string? ReasonCode        = null);

// ---------- Commands (lifecycle, delete) ----------
public sealed record OrgAssuranceExecutionCommandRequest(
    long    OrganizationId,
    long    ExecutionId,
    string? Actor);

public sealed record OrgAssuranceExecutionCommandResult(
    bool    Success,
    long?   ExecutionId = null,
    string? Error       = null,
    string? ReasonCode  = null);

// ---------- Entities ----------
public sealed record OrgAssuranceExecutionEntityRow(
    long      ExecutionEntityId,
    string    DimensionCode,
    string?   DimensionName,
    long?     EntityId,
    string?   EntityCode,
    string?   EntityName,
    int?      SourceGroupOrder,
    int?      SourceConditionOrder,
    string    EntityStatusCode,
    DateTime? StartedDt,
    DateTime? CompletedDt,
    // 120 hybrid role+employee Auditor -- adjacent to name pair.
    long?     AssignedAuditorRoleId,
    string?   AssignedAuditorRoleName,
    long?     AssignedAuditorEmployeeId,
    string?   AssignedAuditorName);

public sealed record OrgAssuranceExecutionEntityListResult(
    long TotalCount,
    int  PageNumber,
    int  PageSize,
    IReadOnlyList<OrgAssuranceExecutionEntityRow> Rows);

// ---------- Per-entity Auditor assignment (120) ----------
public sealed record OrgAssuranceExecutionAuditorAssignRequest(
    long    OrganizationId,
    long    ExecutionId,
    long    ExecutionEntityId,
    long?   AuditorRoleId,
    string? AuditorRoleName,
    long?   AuditorEmployeeId,
    string? AuditorDisplayName,
    string? Actor);

public sealed record OrgAssuranceExecutionAuditorAssignResult(
    bool    Success,
    long?   ExecutionEntityId = null,
    string? Error             = null,
    string? ReasonCode        = null);
