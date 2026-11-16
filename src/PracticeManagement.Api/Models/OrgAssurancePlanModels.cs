// =====================================================================
// OrgAssurancePlanModels
//
// Phase 2 Assurance Management -- Stage 3 Assurance Plans (BRD Part 2
// Sec 8). Plans are org-level artifacts so this module lives in its
// own service (matching TaskModels / WorkflowModels / QuestionModels
// pattern), not on the Definition module.
// =====================================================================
namespace PracticeManagement.Api.Models;

// ---------- Lookups ----------
public sealed record OrgAssurancePlanStatusRow(
    int    StatusId,
    string StatusCode,
    string StatusName,
    int    DisplayOrder,
    bool   IsTerminal);

public sealed record OrgAssurancePlanTypeRow(
    string PlanTypeCode,
    string PlanTypeName,
    int    DisplayOrder);

// ---------- Plan header ----------
public sealed record OrgAssurancePlanListQuery(
    long    OrganizationId,
    string? StatusCode = null,
    string? PlanType   = null,
    string? Search     = null,
    int     Page       = 1,
    int     PageSize   = 25);

public sealed record OrgAssurancePlanListRow(
    long      PlanId,
    long      OrganizationId,
    string    PlanCode,
    string    PlanName,
    string    PlanType,
    DateTime? PeriodFrom,
    DateTime? PeriodTo,
    // 121 hybrid role+employee Owner -- adjacent to display_name pair.
    long?     OwnerRoleId,
    string?   OwnerRoleName,
    long?     OwnerEmployeeId,
    string?   OwnerDisplayName,
    string    StatusCode,
    string    StatusName,
    bool      StatusIsTerminal,
    int       Version,
    long      ItemCount,
    DateTime? EnteredDt,
    DateTime? UpdatedDt,
    // 565: annual plan, programmes, planned vs actual (ItemCount = engagements planned).
    string?   FinancialYear             = null,
    int?      ProgrammeCount            = null,
    string?   Methodologies             = null,
    int?      EngagementInProgressCount = null,
    int?      EngagementCompletedCount  = null);

public sealed record OrgAssurancePlanListResult(
    long TotalCount,
    int  PageNumber,
    int  PageSize,
    IReadOnlyList<OrgAssurancePlanListRow> Rows);

public sealed record OrgAssurancePlanDetail(
    long      PlanId,
    long      OrganizationId,
    string    PlanCode,
    string    PlanName,
    string    PlanType,
    DateTime? PeriodFrom,
    DateTime? PeriodTo,
    // 121 hybrid role+employee Owner -- adjacent to display_name pair.
    long?     OwnerRoleId,
    string?   OwnerRoleName,
    long?     OwnerEmployeeId,
    string?   OwnerDisplayName,
    string    StatusCode,
    string    StatusName,
    bool      StatusIsTerminal,
    string?   Description,
    int       Version,
    string?   EnteredBy,
    DateTime? EnteredDt,
    string?   UpdatedBy,
    DateTime? UpdatedDt,
    // 565: annual plan fields, programmes, planned vs actual.
    string?   FinancialYear             = null,
    string?   Objectives                = null,
    string?   PlannedCoverage           = null,
    decimal?  PlannedBudget             = null,
    string?   BudgetCurrency            = null,
    decimal?  PlannedEffortDays         = null,
    string?   ResourcesNote             = null,
    int?      ProgrammeCount            = null,
    string?   Methodologies             = null,
    int?      EngagementCount           = null,
    int?      EngagementInProgressCount = null,
    int?      EngagementCompletedCount  = null);

public sealed record OrgAssurancePlanSaveRequest(
    long      OrganizationId,
    long?     PlanId,
    string    PlanCode,
    string    PlanName,
    string    PlanType,
    DateTime? PeriodFrom,
    DateTime? PeriodTo,
    // 121 hybrid role+employee Owner -- adjacent to display_name pair.
    long?     OwnerRoleId,
    string?   OwnerRoleName,
    long?     OwnerEmployeeId,
    string?   OwnerDisplayName,
    string?   Description,
    string?   Actor,
    // 565: annual plan fields.
    string?   FinancialYear     = null,
    string?   Objectives        = null,
    string?   PlannedCoverage   = null,
    decimal?  PlannedBudget     = null,
    string?   BudgetCurrency    = null,
    decimal?  PlannedEffortDays = null,
    string?   ResourcesNote     = null);

public sealed record OrgAssurancePlanSaveResult(
    bool    Success,
    long?   PlanId     = null,
    string? Error      = null,
    string? ReasonCode = null);

public sealed record OrgAssurancePlanCommandRequest(
    long    OrganizationId,
    long    PlanId,
    string? Actor);

public sealed record OrgAssurancePlanCommandResult(
    bool    Success,
    long?   PlanId     = null,
    string? Error      = null,
    string? ReasonCode = null);

// ---------- Plan items ----------
public sealed record OrgAssurancePlanItemRow(
    long      PlanItemId,
    long      PlanId,
    long      DefinitionId,
    string?   DefinitionCode,
    string?   DefinitionName,
    long?     DefinitionVersionId,
    int       ItemOrder,
    DateTime? ScheduledFrom,
    DateTime? ScheduledTo,
    // 121 hybrid role+employee Auditor -- adjacent to name pair.
    long?     AssignedAuditorRoleId,
    string?   AssignedAuditorRoleName,
    long?     AssignedAuditorEmployeeId,
    string?   AssignedAuditorName,
    string?   AssignedTeamName,
    long?     AssignedDepartmentId,
    string?   AssignedDepartmentName,
    long?     AssignedBranchId,
    string?   AssignedBranchName,
    string?   Notes,
    string?   EnteredBy,
    DateTime? EnteredDt,
    string?   UpdatedBy,
    DateTime? UpdatedDt,
    // 546: the audit's current status, the slot's latest execution and the
    // slot status (Planned / InProgress / Completed / NotExecuted).
    string?   DefinitionStatusCode,
    string?   DefinitionStatusName,
    long?     ExecutionId,
    string?   ExecutionCode,
    string?   ExecutionStatusCode,
    string?   ExecutionStatusName,
    string?   SlotStatus,
    // 551: the audit has an Active version and is not Retired, so the slot
    // can be started (its current version may be a Draft revision). Null
    // before 551 is run. 552: any audit of the engagement.
    bool?     DefinitionIsPlannable = null,
    // 552: the engagement -- code, name, its audits (count, codes), live /
    // done executions, and whether an audit is left to start.
    string?   EngagementCode     = null,
    string?   EngagementName     = null,
    int?      DefinitionCount    = null,
    string?   DefinitionCodes    = null,
    int?      ExecutionCount     = null,
    int?      ExecutionDoneCount = null,
    bool?     CanStart           = null,
    // 565: the programme the engagement belongs to.
    long?     ProgrammeId        = null,
    string?   ProgrammeCode      = null,
    string?   ProgrammeName      = null,
    // 566: origin, subject, approval (independent) and cancelled.
    string?   EngagementOrigin   = null,
    string?   AuditSubject       = null,
    string?   ApprovalStatus     = null,
    DateTime? CancelledDt        = null);

/// <summary>552: one audit of an engagement (sp_org_assurance_engagement_definition_list).</summary>
public sealed record OrgAssuranceEngagementDefinitionRow(
    long    EngagementDefinitionId,
    long    DefinitionId,
    string? DefinitionCode,
    string? DefinitionName,
    int     DisplayOrder,
    string? DefinitionStatusCode,
    string? DefinitionStatusName,
    int?    ActiveVersionNumber,
    bool    IsPlannable,
    long?   ExecutionId,
    string? ExecutionCode,
    string? ExecutionStatusCode,
    string? ExecutionStatusName);

/// <summary>552: View Scope -- an engagement's audits' scope resolved live,
/// nothing saved. PlanItemId for a saved engagement, or DefinitionIds for an
/// unsaved pick. 554: LocationId -- the branch (a Location) that narrows the
/// scope of an unsaved pick; a saved engagement uses its own branch.</summary>
public sealed record OrgAssuranceEngagementScopeRequest(
    long                 OrganizationId,
    long?                PlanItemId,
    IReadOnlyList<long>? DefinitionIds,
    string?              Actor,
    long?                LocationId = null);

public sealed record OrgAssuranceEngagementScopeDimensionRow(
    string? DimensionCode,
    string? DimensionName,
    int     EntityCount);

public sealed record OrgAssuranceEngagementScopeEntityRow(
    string? DimensionCode,
    string? DimensionName,
    long?   EntityId,
    string? EntityCode,
    string? EntityName,
    string? DefinitionCodes);

public sealed record OrgAssuranceEngagementScopeResult(
    IReadOnlyList<OrgAssuranceEngagementScopeDimensionRow> Dimensions,
    IReadOnlyList<OrgAssuranceEngagementScopeEntityRow>    Entities);

public sealed record OrgAssurancePlanItemSaveRequest(
    long      OrganizationId,
    long?     PlanId,          // 566: none for an independent engagement
    long?     PlanItemId,
    long      DefinitionId,
    string?   DefinitionCode,
    string?   DefinitionName,
    int?      ItemOrder,
    DateTime? ScheduledFrom,
    DateTime? ScheduledTo,
    // 121 hybrid role+employee Auditor -- adjacent to name pair.
    long?     AssignedAuditorRoleId,
    string?   AssignedAuditorRoleName,
    long?     AssignedAuditorEmployeeId,
    string?   AssignedAuditorName,
    string?   AssignedTeamName,
    long?     AssignedDepartmentId,
    string?   AssignedDepartmentName,
    long?     AssignedBranchId,
    string?   AssignedBranchName,
    string?   Notes,
    string?   Actor,
    // 552: the engagement's name and its audits in order (DefinitionId is
    // then the first of them; it is still accepted alone).
    string?              EngagementName = null,
    IReadOnlyList<long>? DefinitionIds  = null,
    // 565: the programme (mandatory; may be left out when the plan has one).
    long?                ProgrammeId    = null,
    // 566: the engagement record -- origin (PLANNED / INDEPENDENT), subject,
    // objective, scope, auditee, instructions, the team (besides the lead),
    // and for an independent one its initiation source and reason.
    string?              EngagementOrigin       = null,
    string?              AuditSubject           = null,
    string?              EngagementObjective    = null,
    string?              ScopeSummary           = null,
    long?                AuditeeRoleId          = null,
    string?              AuditeeRoleName        = null,
    long?                AuditeeEmployeeId      = null,
    string?              AuditeeName            = null,
    string?              EngagementInstructions = null,
    string?              TeamRemarks            = null,
    IReadOnlyList<OrgAssuranceEngagementTeamPick>? Team = null,
    string?              InitiationSourceCode   = null,
    string?              InitiationReason       = null,
    string?              ApprovalReference      = null);

// =====================================================================
// 565: Audit Programmes, Planning Methodology, plan revisions (spec 4.3).
// =====================================================================
public sealed record OrgAssurancePlanningMethodologyRow(
    int     Id,
    string  Code,
    string  Name,
    string? Description);

/// <summary>A programme of a plan, with planned vs actual engagements.</summary>
public sealed record OrgAssurancePlanProgrammeRow(
    long    ProgrammeId,
    long    PlanId,
    string  ProgrammeCode,
    string  ProgrammeName,
    string? Objective,
    int?    PlanningMethodologyId,
    string? MethodologyCode,
    string? MethodologyName,
    long?   OwnerRoleId,
    string? OwnerRoleName,
    long?   OwnerEmployeeId,
    string? OwnerDisplayName,
    int     DisplayOrder,
    bool    IsDefault,
    int     EngagementCount,
    int     EngagementInProgressCount,
    int     EngagementCompletedCount);

public sealed record OrgAssurancePlanProgrammeSaveRequest(
    long    OrganizationId,
    long    PlanId,
    long?   ProgrammeId,
    string  ProgrammeName,
    string? Objective,
    int?    PlanningMethodologyId,
    long?   OwnerRoleId,
    string? OwnerRoleName,
    long?   OwnerEmployeeId,
    string? OwnerDisplayName,
    int?    DisplayOrder,
    string? Actor);

public sealed record OrgAssurancePlanProgrammeSaveResult(
    bool    Success,
    long?   ProgrammeId = null,
    string? Error       = null,
    string? ReasonCode  = null);

/// <summary>Revise an Approved / Active plan: back to Draft, version + 1.</summary>
public sealed record OrgAssurancePlanReviseRequest(
    long    OrganizationId,
    long    PlanId,
    string? Reason,
    string? Actor);

public sealed record OrgAssurancePlanRevisionRow(
    long      RevisionId,
    int       FromVersion,
    int       ToVersion,
    string?   FromStatusCode,
    string    Reason,
    string?   SnapshotJson,
    string?   RevisedBy,
    DateTime? RevisedDt);

public sealed record OrgAssurancePlanItemSaveResult(
    bool    Success,
    long?   PlanItemId = null,
    string? Error      = null,
    string? ReasonCode = null);

/// <summary>546: Start Execution from a plan slot
/// (sp_org_assurance_plan_item_start_execution).</summary>
public sealed record OrgAssurancePlanItemExecutionResult(
    bool    Success,
    long?   ExecutionId      = null,
    string? ExecutionCode    = null,
    string? ExecutionName    = null,
    long?   TotalEntityCount = null,
    string? Error            = null,
    string? ReasonCode       = null,
    // 552: every execution started (one per audit of the engagement); the
    // fields above are the first.
    IReadOnlyList<OrgAssuranceStartedExecutionRow>? Executions = null);

// =====================================================================
// 566: Audit Engagements as a record of their own (spec 4.5). PLANNED
// (in a plan's programme, approved with the plan) or INDEPENDENT (no
// plan needed; initiation source, reason, approved by authority). Both
// run the same execution lifecycle. The audit team is kept against the
// engagement with its trail (removed members stay, with who / when).
// =====================================================================
public sealed record OrgAssuranceEngagementInitiationRow(string Code, string? Name);

/// <summary>One member picked for the team (MEMBER / SME / REVIEWER take
/// EmployeeId; EXTERNAL takes Name and Organisation). The lead is the
/// engagement's lead auditor.</summary>
public sealed record OrgAssuranceEngagementTeamPick(
    string  TeamRole,
    long?   EmployeeId   = null,
    string? Name         = null,
    string? Organisation = null);

public sealed record OrgAssuranceEngagementListQuery(
    long    OrganizationId,
    string? Status   = null,
    string? Origin   = null,
    long?   PlanId   = null,
    string? Search   = null,
    int     Page     = 1,
    int     PageSize = 25);

public sealed record OrgAssuranceEngagementRow(
    long      EngagementId,
    string?   EngagementCode,
    string?   EngagementName,
    string?   EngagementOrigin,
    int       ItemOrder,
    long?     PlanId,
    string?   PlanCode,
    string?   PlanName,
    string?   PlanStatusCode,
    long?     ProgrammeId,
    string?   ProgrammeCode,
    string?   ProgrammeName,
    string?   AuditSubject,
    string?   EngagementObjective,
    string?   ScopeSummary,
    long?     AuditeeRoleId,
    string?   AuditeeRoleName,
    long?     AuditeeEmployeeId,
    string?   AuditeeName,
    long?     LeadAuditorRoleId,
    string?   LeadAuditorRoleName,
    long?     LeadAuditorEmployeeId,
    string?   LeadAuditorName,
    int       TeamCount,
    string?   TeamRemarks,
    string?   TeamText,        // the pre-566 "Assigned Team" text, kept
    string?   EngagementInstructions,
    string?   InitiationSourceCode,
    string?   InitiationSourceName,
    string?   InitiationReason,
    string?   ApprovalStatus,
    string?   ApprovalReference,
    string?   ApprovedBy,
    DateTime? ApprovedDt,
    DateTime? CancelledDt,
    string?   CancelledBy,
    string?   CancelReason,
    DateTime? PlannedStart,
    DateTime? PlannedEnd,
    DateTime? ActualStart,
    DateTime? ActualEnd,
    long?     BranchId,
    string?   BranchName,
    string?   DepartmentName,
    string?   Notes,
    int       DefinitionCount,
    string?   DefinitionCodes,
    int       ExecutionCount,
    int       ExecutionDoneCount,
    bool      CanStart,
    string?   EngagementStatus,
    string?   EnteredBy,
    DateTime? EnteredDt,
    string?   UpdatedBy,
    DateTime? UpdatedDt);

public sealed record OrgAssuranceEngagementListResult(
    long TotalCount, int Page, int PageSize, IReadOnlyList<OrgAssuranceEngagementRow> Rows);

public sealed record OrgAssuranceEngagementAuditRow(
    long DefinitionId, string? DefinitionCode, string? DefinitionName, int DisplayOrder);

public sealed record OrgAssuranceEngagementTeamRow(
    long      TeamMemberId,
    string    TeamRole,
    long?     EmployeeId,
    string?   MemberName,
    string?   Designation,
    string?   RoleName,
    string?   ExternalOrganisation,
    bool      IsActive,
    string?   AddedBy,
    DateTime? AddedDt,
    string?   RemovedBy,
    DateTime? RemovedDt);

public sealed record OrgAssuranceEngagementDetail(
    OrgAssuranceEngagementRow                    Engagement,
    IReadOnlyList<OrgAssuranceEngagementAuditRow> Audits,
    IReadOnlyList<OrgAssuranceEngagementTeamRow>  Team);

public sealed record OrgAssuranceEngagementTeamSaveRequest(
    long OrganizationId,
    IReadOnlyList<OrgAssuranceEngagementTeamPick>? Team,
    string? TeamRemarks,
    string? Actor);

public sealed record OrgAssuranceEngagementCommandRequest(
    long    OrganizationId,
    string? Actor,
    string? ApprovalReference = null,   // approve
    string? Reason            = null);  // cancel

public sealed record OrgAssuranceStartedExecutionRow(
    long    ExecutionId,
    string? ExecutionCode,
    string? ExecutionName,
    string? DefinitionCode,
    long?   TotalEntityCount);
