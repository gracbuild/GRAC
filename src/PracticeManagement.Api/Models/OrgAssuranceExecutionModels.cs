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
    int     PageSize     = 25,
    // Migration 414: management dashboard drill-down (stage / overdue / upcoming).
    ListDrillFilter? Drill = null);

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
    DateTime? UpdatedDt,
    // 555: null = the scope is live (the auditor freezes it in My Audits).
    DateTime? ScopeFrozenAt       = null,
    string?   ScopeFrozenBy       = null,
    int       ScopeExclusionCount = 0);

// ---------- Materialize ----------
public sealed record OrgAssuranceExecutionMaterializeRequest(
    long      OrganizationId,
    long      DefinitionId,
    long?     VersionId,
    // 545: optional -- null resolves the scope when the execution is created.
    long?     ScopeResolutionId,
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

// ---------- 555: My Audits, live scope, Freeze Scope ----------
/// <summary>One audit of an engagement assigned to the caller. AuditState:
/// Upcoming / Ready / ScopeLive / InProgress / Done / Cancelled.</summary>
public sealed record OrgAssuranceMyAuditRow(
    long      OrganizationId,
    string?   OrganizationName,
    long?     PlanId,          // 566: none for an independent engagement
    string?   PlanCode,
    string?   PlanName,
    long      PlanItemId,
    string?   EngagementCode,
    string?   EngagementName,
    long?     BranchId,
    string?   BranchName,
    DateTime? ScheduledFrom,
    DateTime? ScheduledTo,
    long      DefinitionId,
    string?   DefinitionCode,
    string?   DefinitionName,
    long?     ExecutionId,
    string?   ExecutionCode,
    string?   ExecutionStatusCode,
    string?   ExecutionStatusName,
    DateTime? ScopeFrozenAt,
    long?     TotalEntityCount,
    long?     CompletedEntityCount,
    string    AuditState);

/// <summary>Result of starting one due engagement (My Audits open).</summary>
public sealed record OrgAssuranceMyAuditPrepareRow(
    long    PlanItemId,
    string? EngagementCode,
    bool    Started,
    string? Message);

public sealed record OrgAssuranceScopeItemRow(
    string  DimensionCode,
    string? DimensionName,
    long?   EntityId,
    string? EntityCode,
    string? EntityName);

public sealed record OrgAssuranceScopeExclusionRow(
    string    DimensionCode,
    string?   DimensionName,
    long      EntityId,
    string?   EntityCode,
    string?   EntityName,
    string    Reason,
    string?   EnteredBy,
    DateTime? EnteredDt);

public sealed record OrgAssuranceScopeExclusionInput(
    string DimensionCode,
    long   EntityId,
    string Reason);

public sealed record OrgAssuranceFreezeScopeRequest(
    long                                            OrganizationId,
    IReadOnlyList<OrgAssuranceScopeExclusionInput>? Exclusions,
    string?                                         Actor,
    OrgAssuranceScopeReviewInput?                   Review = null);   // 563: Step 3

// ---------- 563: Scope Builder Step 3 -- Review and Confirm ----------
/// <summary>ReviewId is null until the scope is frozen with a review
/// (a live scope, or one frozen before 563).</summary>
public sealed record OrgAssuranceScopeReviewHeader(
    long?     ReviewId,
    int?      VersionNo,
    string?   ReviewStatus,
    string?   ApprovedBy,
    DateTime? ApprovedDt,
    bool      IsFrozen);

public sealed record OrgAssuranceScopeReviewCategoryRow(
    string  CategoryCode,
    string? CategoryName,
    int?    DisplayOrder,
    long    ItemCount,
    bool    IsIncluded);

/// <summary>A related record (discovery) or a manual item (RecordId null).</summary>
public sealed record OrgAssuranceScopeReviewItemRow(
    string  CategoryCode,
    long?   RecordId,
    string? RecordCode,
    string? RecordName,
    string? Status,
    string? Reason,
    bool    IsKept,
    string? ExclusionReason,
    bool    IsManual,
    string? ManualNote);

public sealed record OrgAssuranceScopeReviewResult(
    OrgAssuranceScopeReviewHeader                     Header,
    IReadOnlyList<OrgAssuranceScopeReviewCategoryRow> Categories,
    IReadOnlyList<OrgAssuranceScopeReviewItemRow>     Items);

public sealed record OrgAssuranceScopeReviewCategoryInput(string Code, bool IsIncluded);
public sealed record OrgAssuranceScopeReviewExclusionInput(string CategoryCode, long RecordId, string Reason);
public sealed record OrgAssuranceScopeReviewManualInput(string? CategoryCode, string Name, string? Note);

public sealed record OrgAssuranceScopeReviewInput(
    IReadOnlyList<OrgAssuranceScopeReviewCategoryInput>?  Categories,
    IReadOnlyList<OrgAssuranceScopeReviewExclusionInput>? Excluded,
    IReadOnlyList<OrgAssuranceScopeReviewManualInput>?    Manual);

// ---------- 556: Continuous Assurance view ----------
/// <summary>SummaryKind: Totals / ObligationStatus / LastTaskStatus. Each
/// obligation is counted once.</summary>
public sealed record OrgAssuranceCaSummaryRow(
    string SummaryKind,
    string Label,
    int    ItemCount);

/// <summary>Scope item -> practice instance (Via: Direct or the dependency
/// type it is resolved through) -> obligation, with its implementation
/// status and last task. Instance / obligation fields are null when the
/// item has none.</summary>
public sealed record OrgAssuranceCaDetailRow(
    string    DimensionCode,
    string?   DimensionName,
    long?     EntityId,
    string?   EntityCode,
    string?   EntityName,
    long?     PracticeInstanceId,
    string?   InstanceCode,
    string?   InstanceName,
    string?   Via,
    long?     ObligationId,
    string?   ObligationName,
    string?   ObligationType,
    string?   Frequency,
    string?   ObligationStatusCode,
    string?   ObligationStatusName,
    long?     LastTaskId,
    string?   LastTaskNumber,
    string?   LastTaskStatusCode,
    string?   LastTaskStatusName,
    DateTime? LastTaskDueDate);

public sealed record OrgAssuranceContinuousAssuranceResult(
    IReadOnlyList<OrgAssuranceCaSummaryRow> Summary,
    IReadOnlyList<OrgAssuranceCaDetailRow>  Detail);

// ---------- 558: question responses and findings ----------
/// <summary>A question of the execution (its snapshot) with its answer.
/// ResultCode: Compliant / NotCompliant / NotApplicable, null = not
/// answered. Observation*: the finding a Not compliant answer raised.</summary>
public sealed record OrgAssuranceResponseRow(
    int?      SetOrder,
    string?   QuestionSetCode,
    string?   QuestionSetName,
    long      QuestionId,
    string?   QuestionCode,
    string?   QuestionText,
    string?   HelpText,
    bool      IsMandatory,
    int?      DisplayOrder,
    string?   EvidenceTypeName,
    string?   ExpectedEvidence,
    string?   ResultCode,
    string?   Description,
    long?     OwnerEmployeeId,
    string?   OwnerDisplayName,
    string?   AnsweredBy,
    DateTime? AnsweredDt,
    long?     ObservationId,
    string?   ObservationCode,
    string?   ObservationStatusCode,
    string?   ObservationStatusName);

/// <summary>ResultCode NotAnswered / Compliant / NotCompliant / NotApplicable.</summary>
public sealed record OrgAssuranceResponseCountRow(string ResultCode, int QuestionCount);

public sealed record OrgAssuranceResponseListResult(
    IReadOnlyList<OrgAssuranceResponseRow>      Questions,
    IReadOnlyList<OrgAssuranceResponseCountRow> Counts);

public sealed record OrgAssuranceResponseSaveRequest(
    long    OrganizationId,
    long    QuestionId,
    string  ResultCode,
    string? Description,
    long?   OwnerEmployeeId,
    string? Actor);

public sealed record OrgAssuranceResponseSaveResult(
    bool    Success,
    long?   QuestionId            = null,
    string? ResultCode            = null,
    long?   ObservationId         = null,
    string? ObservationCode       = null,
    string? ObservationStatusCode = null,
    string? ObservationStatusName = null,
    string? Error                 = null,
    string? ReasonCode            = null);

public sealed record OrgAssuranceFreezeScopeResult(
    bool    Success,
    long?   ExecutionId      = null,
    string? ExecutionCode    = null,
    long?   TotalEntityCount = null,
    int?    ExcludedCount    = null,
    string? Error            = null,
    string? ReasonCode       = null,
    long?   ReviewId         = null,    // 563
    int?    ReviewVersionNo  = null);   // 563
