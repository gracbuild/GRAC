// =====================================================================
// OrgAssuranceDefinitionModels
//
// Phase 2 Assurance Management (Practice Management / Organization
// Portal) -- Stage 1 (Assurance Definition + lifecycle).
//
// New, INDEPENDENT module. Does NOT reference / extend / merge with
// the existing (unrelated) assurance_activity / assurance_execution /
// assurance_finding / workflow / task / custom_gap models. Follows the
// same request/response record conventions established by TaskModels.
// =====================================================================
namespace PracticeManagement.Api.Models;

/// <summary>Lifecycle status row (Draft / UnderReview / Approved / Active / Retired).</summary>
public sealed record OrgAssuranceStatusRow(
    int    StatusId,
    string StatusCode,
    string StatusName,
    int    DisplayOrder,
    bool   IsTerminal);

/// <summary>Admin-published Assurance Category dropdown row
/// (sourced from grac_new.assurance_category via
/// grac_practice.sp_org_assurance_admin_category_list).</summary>
public sealed record OrgAssuranceAdminCategoryRow(
    long?   Id,
    string? Code,
    string? Name,
    string? Description);

/// <summary>List / grid query parameters.</summary>
public sealed record OrgAssuranceDefinitionListQuery(
    long    OrganizationId,
    string? StatusCode = null,
    string? Search     = null,
    int     Page       = 1,
    int     PageSize   = 25);

/// <summary>List row projection (mirrors sp_org_assurance_definition_list).</summary>
public sealed record OrgAssuranceDefinitionListRow(
    long      DefinitionId,
    long      OrganizationId,
    string    DefinitionCode,
    string    DefinitionName,
    // 119 hybrid role+employee Owner -- adjacent to display_name pair.
    long?     OwnerRoleId,
    string?   OwnerRoleName,
    long?     OwnerEmployeeId,
    string?   OwnerDisplayName,
    long?     CurrentVersionId,
    long?     ActiveVersionId,
    string    CurrentStatusCode,
    string    CurrentStatusName,
    bool      CurrentStatusIsTerminal,
    int?      CurrentVersionNumber,
    string?   CurrentVersionLabel,
    DateTime? CurrentEffectiveDate,
    string?   CurrentCategoryCode,
    string?   CurrentCategoryName,
    DateTime? EnteredDt,
    DateTime? UpdatedDt);

public sealed record OrgAssuranceDefinitionListResult(
    long TotalCount,
    int  PageNumber,
    int  PageSize,
    IReadOnlyList<OrgAssuranceDefinitionListRow> Rows);

/// <summary>Detail projection (mirrors sp_org_assurance_definition_get).</summary>
public sealed record OrgAssuranceDefinitionDetail(
    long      DefinitionId,
    long      OrganizationId,
    string    DefinitionCode,
    string    DefinitionName,
    // 119 hybrid role+employee Owner -- adjacent to display_name pair.
    long?     OwnerRoleId,
    string?   OwnerRoleName,
    long?     OwnerEmployeeId,
    string?   OwnerDisplayName,
    long?     CurrentVersionId,
    long?     ActiveVersionId,
    string    CurrentStatusCode,
    string    CurrentStatusName,
    bool      CurrentStatusIsTerminal,
    int?      CurrentVersionNumber,
    string?   CurrentVersionLabel,
    string?   Description,
    string?   Objective,
    DateTime? EffectiveDate,
    long?     AssuranceCategoryId,
    string?   AssuranceCategoryCode,
    string?   AssuranceCategoryName,
    string?   SubmittedBy,
    DateTime? SubmittedDt,
    string?   ApprovedBy,
    DateTime? ApprovedDt,
    string?   ActivatedBy,
    DateTime? ActivatedDt,
    string?   RetiredBy,
    DateTime? RetiredDt,
    string?   EnteredBy,
    DateTime? EnteredDt,
    string?   UpdatedBy,
    DateTime? UpdatedDt);

/// <summary>Save request (create or update). Actor / OrganizationId are trusted --
/// the Web tier resolves them from the session per the project's isolation model.</summary>
public sealed record OrgAssuranceDefinitionSaveRequest(
    long    OrganizationId,
    long?   DefinitionId,
    string  DefinitionCode,
    string  DefinitionName,
    // 119 hybrid role+employee Owner -- adjacent to display_name pair.
    long?   OwnerRoleId,
    string? OwnerRoleName,
    long?   OwnerEmployeeId,
    string? OwnerDisplayName,
    string? Description,
    string? Objective,
    DateTime? EffectiveDate,
    long?   AssuranceCategoryId,
    string? AssuranceCategoryCode,
    string? AssuranceCategoryName,
    string? Actor);

public sealed record OrgAssuranceDefinitionSaveResult(
    bool    Success,
    long?   DefinitionId        = null,
    long?   DefinitionVersionId = null,
    string? Error               = null,
    string? ReasonCode          = null);

/// <summary>Lifecycle transition request. Same shape for submit / approve /
/// activate / retire so the controller stays symmetrical.</summary>
public sealed record OrgAssuranceDefinitionTransitionRequest(
    long    OrganizationId,
    long    DefinitionId,
    string? ReasonText,
    string? Actor);

public sealed record OrgAssuranceDefinitionTransitionResult(
    bool    Success,
    long?   DefinitionId = null,
    string? Error        = null,
    string? ReasonCode   = null);

/// <summary>Transition audit-log row.</summary>
public sealed record OrgAssuranceDefinitionHistoryRow(
    long      HistoryId,
    long      DefinitionId,
    long?     DefinitionVersionId,
    string    ActionCode,
    string?   FromStatusCode,
    string?   FromStatusName,
    string?   ToStatusCode,
    string?   ToStatusName,
    string?   ReasonText,
    string?   ActorDisplayName,
    string?   EnteredBy,
    DateTime? EnteredDt);

// =====================================================================
// Scope Builder (Stage 2 -- BRD Part 2 Sec 2)
// =====================================================================

/// <summary>Scope dimension master row (17 seeded).</summary>
public sealed record OrgAssuranceScopeDimensionRow(
    int    DimensionId,
    string DimensionCode,
    string DimensionName,
    string Category,
    bool   IsPickable,
    int    DisplayOrder);

/// <summary>Dimension-value picker row (id / code / name).</summary>
public sealed record OrgAssuranceScopeDimensionValueRow(
    long?   Id,
    string? Code,
    string? Name);

/// <summary>Header row returned by sp_org_assurance_scope_get so the
/// UI can render read-only mode when the version isn't Draft.</summary>
public sealed record OrgAssuranceScopeHeader(
    long   DefinitionId,
    long   VersionId,
    long?  CurrentVersionId,
    string CurrentStatusCode,
    bool   IsEditable);

public sealed record OrgAssuranceScopeGroupRow(
    long   ScopeGroupId,
    string GroupOperator,
    int    GroupOrder,
    string? GroupLabel);

public sealed record OrgAssuranceScopeConditionRow(
    long   ScopeConditionId,
    long   ScopeGroupId,
    int    DimensionId,
    string DimensionCode,
    string DimensionName,
    bool   IsNot,
    string ConditionOperator,
    int    ConditionOrder,
    bool   IncludeAll);

public sealed record OrgAssuranceScopeConditionValueRow(
    long    ScopeConditionValueId,
    long    ScopeConditionId,
    long?   DimensionEntityId,
    string? DimensionEntityCode,
    string? DimensionEntityName);

/// <summary>Full scope tree (from sp_org_assurance_scope_get).</summary>
public sealed record OrgAssuranceScopeTree(
    OrgAssuranceScopeHeader Header,
    IReadOnlyList<OrgAssuranceScopeGroupRow> Groups,
    IReadOnlyList<OrgAssuranceScopeConditionRow> Conditions,
    IReadOnlyList<OrgAssuranceScopeConditionValueRow> Values);

/// <summary>Save request: full replacement of the version's scope.</summary>
public sealed record OrgAssuranceScopeSaveRequest(
    long   OrganizationId,
    long   DefinitionId,
    IReadOnlyList<OrgAssuranceScopeSaveGroup>? Groups,
    string? Actor);

public sealed record OrgAssuranceScopeSaveGroup(
    string? GroupOperator,
    int?    GroupOrder,
    string? GroupLabel,
    IReadOnlyList<OrgAssuranceScopeSaveCondition>? Conditions);

public sealed record OrgAssuranceScopeSaveCondition(
    string  DimensionCode,
    bool?   IsNot,
    string? ConditionOperator,
    int?    ConditionOrder,
    bool?   IncludeAll,
    IReadOnlyList<OrgAssuranceScopeSaveValue>? Values);

public sealed record OrgAssuranceScopeSaveValue(
    long?   EntityId,
    string? EntityCode,
    string? EntityName);

public sealed record OrgAssuranceScopeSaveResult(
    bool    Success,
    long?   DefinitionId = null,
    string? Error        = null,
    string? ReasonCode   = null);

// =====================================================================
// Evidence Configuration (Stage 2 -- BRD Part 2 Sec 5)
// =====================================================================

/// <summary>Simple lookup row used for evidence type and collection
/// method dropdowns.</summary>
public sealed record OrgAssuranceEvidenceLookupRow(
    int?    Id,
    string? Code,
    string? Name);

/// <summary>Header returned by sp_org_assurance_evidence_config_get --
/// mirrors the scope header so the UI can decide read-only vs edit.</summary>
public sealed record OrgAssuranceEvidenceConfigHeader(
    long   DefinitionId,
    long   VersionId,
    long?  CurrentVersionId,
    string CurrentStatusCode,
    bool   IsEditable);

/// <summary>One evidence config row (what evidence is expected + how
/// it's collected + validity / expiry + auto-engine details).</summary>
public sealed record OrgAssuranceEvidenceConfigRow(
    long    EvidenceConfigId,
    int?    EvidenceTypeId,
    string? EvidenceTypeCode,
    string? EvidenceTypeName,
    int?    CollectionMethodId,
    string? CollectionMethodCode,
    string? CollectionMethodName,
    int?    CollectionFrequencyId,
    string? CollectionFrequencyCode,
    string? CollectionFrequencyName,
    string? EvidenceOwner,
    string? RetentionPeriod,
    string? EvidenceLocation,
    string? EvidenceLocator,
    string  EvidenceLabel,
    string? Description,
    bool    IsMandatory,
    int?    ValidityDays,
    int?    ExpiryWarningDays,
    int     DisplayOrder,
    // 118 hybrid role+employee Owner (nullable defaults for legacy rows)
    long?   OwnerRoleId       = null,
    string? OwnerRoleName     = null,
    long?   OwnerEmployeeId   = null,
    string? OwnerDisplayName  = null);

/// <summary>Full evidence config for a definition version (header + rows).</summary>
public sealed record OrgAssuranceEvidenceConfigResult(
    OrgAssuranceEvidenceConfigHeader Header,
    IReadOnlyList<OrgAssuranceEvidenceConfigRow> Items);

/// <summary>Save request -- full replacement of the version's config.
/// Only accepted while the definition version is Draft.</summary>
public sealed record OrgAssuranceEvidenceConfigSaveRequest(
    long   OrganizationId,
    long   DefinitionId,
    IReadOnlyList<OrgAssuranceEvidenceConfigSaveItem>? Items,
    string? Actor);

public sealed record OrgAssuranceEvidenceConfigSaveItem(
    int?    EvidenceTypeId,
    string? EvidenceTypeCode,
    string? EvidenceTypeName,
    int?    CollectionMethodId,
    string? CollectionMethodCode,
    string? CollectionMethodName,
    int?    CollectionFrequencyId,
    string? CollectionFrequencyCode,
    string? CollectionFrequencyName,
    string? EvidenceOwner,
    string? RetentionPeriod,
    string? EvidenceLocation,
    string? EvidenceLocator,
    string  EvidenceLabel,
    string? Description,
    bool?   IsMandatory,
    int?    ValidityDays,
    int?    ExpiryWarningDays,
    int?    DisplayOrder,
    // 118 hybrid role+employee Owner (nullable defaults so legacy
    // callers keep compiling; DB auto-resolver fills whichever side
    // was omitted).
    long?   OwnerRoleId       = null,
    string? OwnerRoleName     = null,
    long?   OwnerEmployeeId   = null,
    string? OwnerDisplayName  = null);

public sealed record OrgAssuranceEvidenceConfigSaveResult(
    bool    Success,
    long?   DefinitionId = null,
    string? Error        = null,
    string? ReasonCode   = null);

// =====================================================================
// Workflow Configuration (Stage 2 -- BRD Part 2 Sec 6)
// =====================================================================

/// <summary>Admin-published workflow template dropdown row
/// (from grac_new.assurance_workflow_template via sp_..._admin_workflow_template_list).</summary>
public sealed record OrgAssuranceAdminWorkflowTemplateRow(
    long?   Id,
    string? Code,
    string? Name,
    string? Description);

/// <summary>Stage-type vocabulary (AUDITOR / REVIEWER / APPROVER / CUSTOM).</summary>
public sealed record OrgAssuranceWorkflowStageTypeRow(
    string StageTypeCode,
    string StageTypeName,
    int    DisplayOrder);

/// <summary>Simple org role row for the assignment dropdowns.</summary>
public sealed record OrgAssuranceOrganizationRoleRow(
    long   RoleId,
    string RoleName);

/// <summary>Header returned by sp_org_assurance_workflow_get -- mirrors
/// the scope / evidence header so the UI can pick read-only vs edit.</summary>
public sealed record OrgAssuranceWorkflowHeader(
    long   DefinitionId,
    long   VersionId,
    long?  CurrentVersionId,
    string CurrentStatusCode,
    bool   IsEditable);

public sealed record OrgAssuranceWorkflowConfigRow(
    long    WorkflowConfigId,
    long?   WorkflowTemplateId,
    string? WorkflowTemplateCode,
    string? WorkflowTemplateName,
    string? WorkflowName,
    string? Description,
    int?    TotalSlaDays);

public sealed record OrgAssuranceWorkflowStageRow(
    long    StageId,
    int     StageOrder,
    string  StageCode,
    string  StageName,
    string  StageType,
    long?   AssignedRoleId,
    string? AssignedRoleName,
    long?   AssignedEmployeeId,
    string? AssignedEmployeeName,
    int?    SlaDays,
    long?   EscalationRoleId,
    string? EscalationRoleName,
    int?    EscalationAfterDays,
    string? Instructions);

public sealed record OrgAssuranceWorkflowResult(
    OrgAssuranceWorkflowHeader Header,
    OrgAssuranceWorkflowConfigRow? Config,
    IReadOnlyList<OrgAssuranceWorkflowStageRow> Stages);

public sealed record OrgAssuranceWorkflowSaveHeader(
    long?   WorkflowTemplateId,
    string? WorkflowTemplateCode,
    string? WorkflowTemplateName,
    string? WorkflowName,
    string? Description,
    int?    TotalSlaDays);

public sealed record OrgAssuranceWorkflowSaveStage(
    int?    StageOrder,
    string  StageCode,
    string  StageName,
    string  StageType,           // AUDITOR / REVIEWER / APPROVER / CUSTOM
    long?   AssignedRoleId,
    string? AssignedRoleName,
    long?   AssignedEmployeeId,
    string? AssignedEmployeeName,
    int?    SlaDays,
    long?   EscalationRoleId,
    string? EscalationRoleName,
    int?    EscalationAfterDays,
    string? Instructions);

public sealed record OrgAssuranceWorkflowSaveRequest(
    long   OrganizationId,
    long   DefinitionId,
    OrgAssuranceWorkflowSaveHeader? Header,
    IReadOnlyList<OrgAssuranceWorkflowSaveStage>? Stages,
    string? Actor);

public sealed record OrgAssuranceWorkflowSaveResult(
    bool    Success,
    long?   DefinitionId = null,
    string? Error        = null,
    string? ReasonCode   = null);

// =====================================================================
// Scoring Configuration (Stage 2 -- BRD Part 2 Sec 7)
// =====================================================================

/// <summary>Admin-published scoring model row.</summary>
public sealed record OrgAssuranceAdminScoringModelRow(
    long?   Id,
    string? Code,
    string? Name,
    string? Description);

/// <summary>Fixed scoring-model type vocabulary
/// (PASS_FAIL / WEIGHTED / RISK_BASED / MATURITY_BASED / PERCENTAGE / CUSTOM).</summary>
public sealed record OrgAssuranceScoringModelTypeRow(
    string ModelTypeCode,
    string ModelTypeName,
    int    DisplayOrder,
    bool   SupportsBands,
    bool   SupportsThreshold);

public sealed record OrgAssuranceScoringHeader(
    long   DefinitionId,
    long   VersionId,
    long?  CurrentVersionId,
    string CurrentStatusCode,
    bool   IsEditable);

public sealed record OrgAssuranceScoringConfigRow(
    long     ScoringConfigId,
    long?    ScoringModelId,
    string?  ScoringModelCode,
    string?  ScoringModelName,
    string   ScoringModelType,
    decimal? MaxScore,
    decimal? PassThreshold,
    decimal? WarningThreshold,
    decimal? FailThreshold,
    string?  Description);

public sealed record OrgAssuranceScoringBandRow(
    long     BandId,
    int      BandOrder,
    string   BandCode,
    string   BandName,
    decimal  MinScore,
    decimal  MaxScore,
    string?  OutcomeCode,
    string?  ColorHex,
    string?  Description);

public sealed record OrgAssuranceScoringResult(
    OrgAssuranceScoringHeader Header,
    OrgAssuranceScoringConfigRow? Config,
    IReadOnlyList<OrgAssuranceScoringBandRow> Bands);

public sealed record OrgAssuranceScoringSaveHeader(
    long?    ScoringModelId,
    string?  ScoringModelCode,
    string?  ScoringModelName,
    string?  ScoringModelType,
    decimal? MaxScore,
    decimal? PassThreshold,
    decimal? WarningThreshold,
    decimal? FailThreshold,
    string?  Description);

public sealed record OrgAssuranceScoringSaveBand(
    int?     BandOrder,
    string   BandCode,
    string   BandName,
    decimal  MinScore,
    decimal  MaxScore,
    string?  OutcomeCode,
    string?  ColorHex,
    string?  Description);

public sealed record OrgAssuranceScoringSaveRequest(
    long   OrganizationId,
    long   DefinitionId,
    OrgAssuranceScoringSaveHeader? Header,
    IReadOnlyList<OrgAssuranceScoringSaveBand>? Bands,
    string? Actor);

public sealed record OrgAssuranceScoringSaveResult(
    bool    Success,
    long?   DefinitionId = null,
    string? Error        = null,
    string? ReasonCode   = null);

// =====================================================================
// Trigger Configuration (Stage 3 -- BRD Part 2 Sec 9)
// =====================================================================

public sealed record OrgAssuranceTriggerTypeRow(
    string TriggerTypeCode,
    string TriggerTypeName,
    int    DisplayOrder);

public sealed record OrgAssuranceScheduleFrequencyRow(
    string FrequencyCode,
    string FrequencyName,
    int    DisplayOrder);

public sealed record OrgAssuranceEventCodeRow(
    string EventCode,
    string EventName,
    int    DisplayOrder);

public sealed record OrgAssuranceContinuousSourceRow(
    string SourceCode,
    string SourceName,
    int    DisplayOrder);

public sealed record OrgAssuranceTriggerHeader(
    long   DefinitionId,
    long   VersionId,
    long?  CurrentVersionId,
    string CurrentStatusCode,
    bool   IsEditable);

public sealed record OrgAssuranceTriggerRow(
    long      TriggerId,
    string    TriggerCode,
    string    TriggerName,
    string    TriggerType,
    bool      IsEnabled,
    string?   Description,

    string?   ScheduleFrequencyCode,
    int?      ScheduleFrequencyId,
    string?   ScheduleFrequencyName,
    DateTime? ScheduleStartDate,
    DateTime? ScheduleEndDate,
    TimeSpan? ScheduleTime,
    int?      DayOfWeek,
    int?      DayOfMonth,
    int?      MonthOfYear,
    DateTime? NextRunAt,
    DateTime? LastRunAt,

    string?   EventCode,
    string?   EventName,
    string?   EventSource,
    string?   EventFilterJson,

    string?   ContinuousSourceCode,
    string?   ContinuousEndpoint,
    string?   ContinuousRuleCode);

public sealed record OrgAssuranceTriggerListResult(
    OrgAssuranceTriggerHeader Header,
    IReadOnlyList<OrgAssuranceTriggerRow> Triggers);

public sealed record OrgAssuranceTriggerSaveRequest(
    long      OrganizationId,
    long      DefinitionId,
    long?     TriggerId,
    string    TriggerCode,
    string    TriggerName,
    string    TriggerType,
    bool?     IsEnabled,
    string?   Description,

    string?   ScheduleFrequencyCode,
    int?      ScheduleFrequencyId,
    string?   ScheduleFrequencyName,
    DateTime? ScheduleStartDate,
    DateTime? ScheduleEndDate,
    TimeSpan? ScheduleTime,
    int?      DayOfWeek,
    int?      DayOfMonth,
    int?      MonthOfYear,

    string?   EventCode,
    string?   EventName,
    string?   EventSource,
    string?   EventFilterJson,

    string?   ContinuousSourceCode,
    string?   ContinuousEndpoint,
    string?   ContinuousRuleCode,

    string?   Actor);

public sealed record OrgAssuranceTriggerSaveResult(
    bool    Success,
    long?   TriggerId  = null,
    string? Error      = null,
    string? ReasonCode = null);

public sealed record OrgAssuranceTriggerCommandResult(
    bool    Success,
    long?   TriggerId  = null,
    string? Error      = null,
    string? ReasonCode = null);

// =====================================================================
// Scope Resolution (Stage 3 -- BRD Part 2 Sec 3)
// =====================================================================

public sealed record OrgAssuranceScopeResolveRequest(
    long    OrganizationId,
    long    DefinitionId,
    long?   VersionId,
    string? ResolutionPurpose,   // PREVIEW / EXECUTION
    long?   ExecutionId,
    string? Actor);

public sealed record OrgAssuranceScopeResolveResult(
    bool    Success,
    long?   ResolutionId = null,
    string? Error        = null,
    string? ReasonCode   = null);

public sealed record OrgAssuranceScopeResolutionListRow(
    long      ResolutionId,
    long      DefinitionId,
    long      DefinitionVersionId,
    string    ResolutionPurpose,
    long?     ExecutionId,
    DateTime  ResolvedAt,
    string    ResolvedBy,
    long      TotalEntityCount,
    string?   SummaryJson,
    string?   Notes);

public sealed record OrgAssuranceScopeResolutionListResult(
    long TotalCount,
    int  PageNumber,
    int  PageSize,
    IReadOnlyList<OrgAssuranceScopeResolutionListRow> Rows);

public sealed record OrgAssuranceScopeResolutionSummaryRow(
    string DimensionCode,
    string? DimensionName,
    long    EntityCount);

public sealed record OrgAssuranceScopeResolutionDetail(
    OrgAssuranceScopeResolutionListRow Header,
    IReadOnlyList<OrgAssuranceScopeResolutionSummaryRow> DimensionSummary);

public sealed record OrgAssuranceScopeResolutionEntityRow(
    long    EntityRowId,
    string  DimensionCode,
    string? DimensionName,
    long?   EntityId,
    string? EntityCode,
    string? EntityName,
    int?    SourceGroupOrder,
    int?    SourceConditionOrder);

public sealed record OrgAssuranceScopeResolutionEntityListResult(
    long TotalCount,
    int  PageNumber,
    int  PageSize,
    IReadOnlyList<OrgAssuranceScopeResolutionEntityRow> Rows);

/// <summary>Version-history row.</summary>
public sealed record OrgAssuranceDefinitionVersionRow(
    long      VersionId,
    long      DefinitionId,
    int       VersionNumber,
    string?   VersionLabel,
    string?   Description,
    string?   Objective,
    DateTime? EffectiveDate,
    long?     AssuranceCategoryId,
    string?   AssuranceCategoryCode,
    string?   AssuranceCategoryName,
    string    StatusCode,
    string    StatusName,
    string?   SubmittedBy,
    DateTime? SubmittedDt,
    string?   ApprovedBy,
    DateTime? ApprovedDt,
    string?   ActivatedBy,
    DateTime? ActivatedDt,
    string?   RetiredBy,
    DateTime? RetiredDt,
    string?   EnteredBy,
    DateTime? EnteredDt,
    string?   UpdatedBy,
    DateTime? UpdatedDt);
