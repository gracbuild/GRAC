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
    DateTime? UpdatedDt);

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
    DateTime? UpdatedDt);

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
    string?   Actor);

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
    DateTime? UpdatedDt);

public sealed record OrgAssurancePlanItemSaveRequest(
    long      OrganizationId,
    long      PlanId,
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
    string?   Actor);

public sealed record OrgAssurancePlanItemSaveResult(
    bool    Success,
    long?   PlanItemId = null,
    string? Error      = null,
    string? ReasonCode = null);
