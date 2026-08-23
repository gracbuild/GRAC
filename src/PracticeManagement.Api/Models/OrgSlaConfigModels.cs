// =====================================================================
// OrgSlaConfigModels
//
// DTOs for the Organization SLA Configuration API surface (migrations
// 178/179/180/181/182/183/186). Post-186 shape: no more
// process-binding rows / requests / responses -- that surface was
// removed when we settled on severity->classification matching as the
// single SLA lookup pattern (see 184).
//
// Conventions:
//   * PascalCase record members
//   * Nullable long? for potentially absent IDs
//   * camelCase JSON on the wire (System.Text.Json default)
//
// See OrgSlaConfigService / OrgSlaConfigController for consumers.
// =====================================================================
namespace PracticeManagement.Api.Models;

// ---------------------------------------------------------------------
// Lookups
// ---------------------------------------------------------------------

public sealed record CtrlSlaMasterRow(
    long     Id,
    string   Code,
    string   Name,
    string?  Description,
    int?     TotalSlaDays,
    string?  ProcessCode,
    string?  Classification,
    int?     DurationValue,
    string?  DurationUnit,
    string?  TimeBasis,
    decimal? WarningPct,
    decimal? EscalationPct,
    DateTime? EffectiveFrom,
    string?  Status);

// Master-first grid row (sp_org_sla_master_grid). One row per active
// grac_new.sla_master row for the caller's org. ConfigStatusCode is
// one of: NotConfigured, Active, Inactive.
public sealed record OrgSlaMasterGridRow(
    long      SlaMasterId,
    string?   SlaMasterCode,
    string?   SlaMasterName,
    string?   Description,
    string?   ProcessCode,
    string?   Classification,
    int?      DurationValue,
    string?   DurationUnit,
    // Master-side snapshot (grac_new.sla_master.time_basis / warning_pct / escalation_pct).
    string?   MasterTimeBasis,
    decimal?  MasterWarningPct,
    decimal?  MasterEscalationPct,
    int?      TotalSlaDays,
    DateTime? EffectiveFrom,
    long?     OrgSlaConfigId,
    string    ConfigStatusCode,
    string    ConfigStatusLabel,
    // Effective tunables: config override when present, else master fallback.
    decimal?  WarningPct,
    decimal?  EscalationPct,
    string?   TimeBasis,
    int       NotifyRoleCount,
    DateTime? ConfiguredDt);

public sealed record OrgSlaMasterGridQuery(
    long    OrganizationId,
    string? Search);

public sealed record OrgSlaMasterGridResult(IReadOnlyList<OrgSlaMasterGridRow> Rows);

// Toggle for Inactivate / Reactivate menu items. Keyed by master id
// (grid identity), not config id, so it works uniformly across the
// three states.
public sealed record OrgSlaConfigSetActiveRequest(
    long   OrganizationId,
    long   SlaMasterId,
    bool   IsActive,
    string Actor);

// ---------------------------------------------------------------------
// List (grid) -- legacy adopted-only view; not used by the redesigned
// UI (see OrgSlaMasterGridRow above) but retained for API back-compat.
// ---------------------------------------------------------------------

public sealed record OrgSlaConfigListQuery(
    long   OrganizationId,
    string? Search,
    int    Page,
    int    PageSize);

public sealed record OrgSlaConfigListRow(
    long      OrgSlaConfigId,
    long      OrganizationId,
    long      SlaMasterId,
    string?   SlaMasterCode,
    string?   SlaMasterName,
    int?      TotalSlaDays,
    decimal?  WarningPct,
    decimal?  EscalationPct,
    string?   TimeBasis,
    string?   Notes,
    int       NotifyRoleCount,
    string?   EnteredBy,
    DateTime? EnteredDt,
    string?   UpdatedBy,
    DateTime? UpdatedDt);

public sealed record OrgSlaConfigListResult(
    IReadOnlyList<OrgSlaConfigListRow> Rows,
    int TotalCount,
    int Page,
    int PageSize);

// ---------------------------------------------------------------------
// Detail (2 result sets in sp_org_sla_config_get -- post-186)
// ---------------------------------------------------------------------

public sealed record OrgSlaConfigHeader(
    long      OrgSlaConfigId,
    long      OrganizationId,
    long      SlaMasterId,
    string?   SlaMasterCode,
    string?   SlaMasterName,
    int?      TotalSlaDays,
    decimal?  WarningPct,
    decimal?  EscalationPct,
    string?   TimeBasis,
    string?   Notes,
    string?   EnteredBy,
    DateTime? EnteredDt,
    string?   UpdatedBy,
    DateTime? UpdatedDt);

public sealed record OrgSlaNotifyRoleRow(
    long   NotifyRoleId,
    string NotifyEventCode,
    long   RoleId,
    string? RoleName);

public sealed record OrgSlaConfigDetail(
    OrgSlaConfigHeader                 Header,
    IReadOnlyList<OrgSlaNotifyRoleRow> NotifyRoles);

// ---------------------------------------------------------------------
// Upsert / notify-role requests
// ---------------------------------------------------------------------

public sealed record OrgSlaConfigUpsertRequest(
    long    OrganizationId,
    long?   OrgSlaConfigId,          // null = adopt new; non-null = update
    long    SlaMasterId,
    string? SlaMasterCode,
    string? SlaMasterName,
    int?    TotalSlaDays,
    decimal WarningPct,
    decimal EscalationPct,
    string? TimeBasis,
    string? Notes,
    string  Actor);

public sealed record OrgSlaConfigUpsertResult(
    bool   Success,
    long?  OrgSlaConfigId,
    string? Error);

public sealed record OrgSlaNotifyRoleInput(
    string NotifyEventCode,  // WARNING | BREACH | ESCALATION
    long   RoleId);

public sealed record OrgSlaNotifyRoleSetRequest(
    long                                 OrganizationId,
    long                                 OrgSlaConfigId,
    IReadOnlyList<OrgSlaNotifyRoleInput> Roles,
    string                               Actor);

public sealed record OrgSlaMutationResult(bool Success, string? Error);
