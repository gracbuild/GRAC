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

/// <summary>560: a row of an Audit Definition master dropdown -- Assurance Approach
/// (org_assurance_approach_master, how the audit is conducted) and Audit Mandate
/// (org_assurance_mandate_master, the basis of the audit).</summary>
public sealed record OrgAssuranceMasterRow(
    long?   Id,
    string? Code,
    string? Name,
    string? Description);

/// <summary>560: one Applicable Framework of a definition version. ReleaseId is the
/// subscribed framework (grac_new.release); null for a framework typed by hand.</summary>
public sealed record OrgAssuranceDefinitionFrameworkRow(
    long?  DefinitionFrameworkId,
    long?  ReleaseId,
    string FrameworkName,
    int    DisplayOrder);

/// <summary>560: one Audit Mandate of a definition version (code / name as saved).</summary>
public sealed record OrgAssuranceDefinitionMandateRow(
    long?  DefinitionMandateId,
    long   AuditMandateId,
    string MandateCode,
    string MandateName,
    int    DisplayOrder);

/// <summary>560: an Applicable Framework sent on save.</summary>
public sealed record OrgAssuranceDefinitionFrameworkInput(
    long?   ReleaseId,
    string? Name);

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
    // 560: Assurance Approach (id + code / name as saved).
    long?     AssuranceApproachId,
    string?   AssuranceApproachCode,
    string?   AssuranceApproachName,
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
    DateTime? UpdatedDt,
    // 560: the current version's Applicable Frameworks (second result set).
    IReadOnlyList<OrgAssuranceDefinitionFrameworkRow>? ApplicableFrameworks = null,
    // 560: the current version's Audit Mandates (third result set).
    IReadOnlyList<OrgAssuranceDefinitionMandateRow>? AuditMandates = null);

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
    string? Actor,
    // 560: Assurance Approach, Audit Mandates, Applicable Frameworks
    // (a list left null = leave the saved list as it is; empty = clear it).
    long?   AssuranceApproachId = null,
    IReadOnlyList<long>? AuditMandateIds = null,
    IReadOnlyList<OrgAssuranceDefinitionFrameworkInput>? ApplicableFrameworks = null);

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
    int    DisplayOrder,
    // 562: the Operationalize dependency type behind a DEP_<CODE> subject dimension.
    long?  DependencyTypeId = null);

/// <summary>Dimension-value picker row (id / code / name).</summary>
public sealed record OrgAssuranceScopeDimensionValueRow(
    long?   Id,
    string? Code,
    string? Name);

/// <summary>One source statement in the Scope Builder's tree picker
/// (migration 534): Framework -> Release -> Source Structure -> Source
/// Statement. StatementId is organization_framework_statements
/// .org_statement_id -- the value stored for the SOURCE_STATEMENT
/// dimension. The keys are opaque strings, unique per level.</summary>
public sealed record OrgAssuranceScopeStatementTreeRow(
    string  FrameworkKey,
    string  FrameworkName,
    string  ReleaseKey,
    string  ReleaseName,
    string  StructureKey,
    string  StructureName,
    long    StatementId,
    string? StatementCode,
    string? StatementName,
    int     InstanceCount);

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

/// <summary>562: Scope Builder Step 2 -- one discovered category (sp_org_assurance_scope_discover, result 1).</summary>
public sealed record OrgAssuranceScopeDiscoveryCategory(
    string CategoryCode,
    string CategoryName,
    int    DisplayOrder,
    long   ItemCount,
    bool   IsIncluded);

/// <summary>562: one discovered record and why it is related (result 2).</summary>
public sealed record OrgAssuranceScopeDiscoveryRow(
    string  CategoryCode,
    long    RecordId,
    string? RecordCode,
    string? RecordName,
    string? Status,
    string? Reason);

/// <summary>562: GET definitions/{id}/scope-discovery.</summary>
public sealed record OrgAssuranceScopeDiscovery(
    IReadOnlyList<OrgAssuranceScopeDiscoveryCategory> Categories,
    IReadOnlyList<OrgAssuranceScopeDiscoveryRow>      Rows);

/// <summary>562: POST definitions/{id}/scope-categories -- which categories the audit brings in.</summary>
public sealed record OrgAssuranceScopeCategorySaveRequest(
    long    OrganizationId,
    long    DefinitionId,
    IReadOnlyList<OrgAssuranceScopeCategoryInput>? Categories,
    string? Actor);

public sealed record OrgAssuranceScopeCategoryInput(
    string Code,
    bool   IsIncluded);

public sealed record OrgAssuranceScopeSaveResult(
    bool    Success,
    long?   DefinitionId = null,
    string? Error        = null,
    string? ReasonCode   = null);

// =====================================================================
// 564: Audit Configuration -- Control and Practice Mapping (spec 4.2.2).
// MappingType: CONTROL_STATEMENT / PRACTICE / PRACTICE_INSTANCE / MANUAL.
// =====================================================================
/// <summary>An organization practice or practice instance the mapping can pick.</summary>
public sealed record OrgAssuranceMappingOptionRow(
    long    Id,
    string? Code,
    string? Name,
    long?   PracticeId,       // instances: their practice
    string? PracticeCode,     // instances
    int?    InstanceCount);   // practices

public sealed record OrgAssuranceMappingOptions(
    IReadOnlyList<OrgAssuranceMappingOptionRow> Practices,
    IReadOnlyList<OrgAssuranceMappingOptionRow> Instances);

public sealed record OrgAssuranceMappingHeader(
    long    DefinitionId,
    long?   VersionId,
    string? StatusCode,
    bool    IsEditable);

/// <summary>One mapped row. IsAvailable: the GRAC record is still active
/// (always true for MANUAL).</summary>
public sealed record OrgAssuranceMappingRow(
    long    MappingId,
    string  MappingType,
    long?   RecordId,
    string? RecordCode,
    string? RecordName,
    string? ManualKind,
    string? ManualReference,
    string? Note,
    int     DisplayOrder,
    long?   PracticeId,
    bool    IsAvailable);

public sealed record OrgAssuranceMappingResult(
    OrgAssuranceMappingHeader            Header,
    IReadOnlyList<OrgAssuranceMappingRow> Items);

/// <summary>POST definitions/{id}/mapping -- replaces the Draft version's mapping.</summary>
public sealed record OrgAssuranceMappingSaveRequest(
    long    OrganizationId,
    long    DefinitionId,
    IReadOnlyList<OrgAssuranceMappingInput>? Items,
    string? Actor);

/// <summary>A GRAC record (MappingType + RecordId), or MANUAL (ManualKind:
/// CONTROL / PRACTICE / PRACTICE_INSTANCE / OTHER, Reference, Name).</summary>
public sealed record OrgAssuranceMappingInput(
    string  MappingType,
    long?   RecordId,
    string? ManualKind,
    string? Reference,
    string? Name,
    string? Note);

public sealed record OrgAssuranceMappingSaveResult(
    bool    Success,
    int?    MappingCount = null,
    string? Error        = null,
    string? ReasonCode   = null);

// =====================================================================
// Evidence Types (question Evidence Type lookup). The Evidence
// Configuration models were removed by 536 -- evidence is set per
// question in the question sets.
// =====================================================================

/// <summary>Simple lookup row used for the evidence type dropdown.</summary>
public sealed record OrgAssuranceEvidenceLookupRow(
    int?    Id,
    string? Code,
    string? Name);

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

/// <summary>538: one Admin template stage, already shaped as an organization
/// workflow stage (type mapped to AUDITOR / REVIEWER / APPROVER / CUSTOM, SLA
/// in days, the template's rules in Instructions). Roles / employees are the
/// organization's to pick, so they are not here.</summary>
public sealed record OrgAssuranceAdminWorkflowTemplateStageRow(
    int?    StageOrder,
    string? StageCode,
    string? StageName,
    string? StageType,
    int?    SlaDays,
    string? Instructions,
    string? AdminStageType,
    int?    SlaHours);

/// <summary>538: an Admin workflow template with its stages
/// (sp_org_assurance_admin_workflow_template_stage_list).</summary>
public sealed record OrgAssuranceAdminWorkflowTemplateDetail(
    long?   Id,
    string? Code,
    string? Name,
    string? Description,
    int?    TotalSlaDays,
    IReadOnlyList<OrgAssuranceAdminWorkflowTemplateStageRow> Stages);

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
