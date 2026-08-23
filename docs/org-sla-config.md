# Organization SLA Configuration — developer notes

**Migrations:**
`178_org_sla_config_schema.sql` / `178_..._rollback.sql`,
`179_org_sla_config_procs.sql` / `179_..._rollback.sql`,
`180_org_sla_config_menu_seed.sql` / `180_..._rollback.sql`,
`181_org_sla_master_grid.sql` / `181_..._rollback.sql`,
`182_org_sla_notify_add_breach_event.sql` / `182_..._rollback.sql`,
`183_org_sla_pct_and_time_basis.sql` / `183_..._rollback.sql`

**Backend:**
`Api/Services/OrgSlaConfigService.cs`,
`Api/Controllers/OrgSlaConfigController.cs`,
`Api/Models/OrgSlaConfigModels.cs`,
`Api/Infrastructure/OrgSlaConfigServiceRegistration.cs`
(wired in `Api/Program.cs` via `AddOrgSlaConfigService()`)

**Web:**
`Web/Controllers/OrgSlaConfigController.cs` (proxy),
`Web/Views/Practice/Partials/org-sla-config.cshtml`,
`Web/wwwroot/js/OrgSlaConfig/org-sla-config.js`,
screen registered in `PracticeScreen.All` (key `org-sla-config`, group Governance)

---

## Scope

SLA masters live in `grac_new.sla_master` (Control Management / Authority Portal). Each master row carries columns `sla_id`, `sla_code`, `process_code`, `classification`, `duration_value`, `duration_unit`, `time_basis`, `warning_pct`, `escalation_pct`, `effective_from`, `status` — no `name`, no `total_sla_days`. `sp_ctrl_sla_master_list` (rewritten in 181) reads those columns directly and derives a display Name from `classification` (falling back to `sla_code`) and TotalSlaDays from `duration_value` normalised through `duration_unit`.

**Master-first flow (post-181).** The screen is not an "adopt" flow — the grid shows **every active master** for the org, one of three statuses:

- **Not Configured** — no `org_sla_config` row yet. Menu shows only *Configure*.
- **Active** — configured and in force. Menu shows *Configure*, *Notifies*, *Processes*, *Inactivate*.
- **Inactive** — configured but disabled. Menu shows *Configure*, *Notifies*, *Processes*, *Reactivate*.

Configuring a Not Configured row auto-creates an `org_sla_config` row with `is_active = 1`. Re-configuring an existing row updates thresholds/notes only — `is_active` is untouched, so the explicit *Inactivate* / *Reactivate* menu items are the single source of truth for status transitions.

Once configured, the operator can:

1. **Tune** the thresholds as PERCENTAGES of the SLA duration **(post-183)** — matches the master which stores `warning_pct` / `escalation_pct` natively:
   - `warning_pct` — % of SLA elapsed when WARNING fires (e.g. 75).
   - `escalation_pct` — % of SLA elapsed when ESCALATION fires (must be ≥ `warning_pct`).
   - **BREACH** is implicit at 100% (no separate percentage).
   - `time_basis` — how "days" are counted (Calendar Days, Business Days, Calendar Hours, Business Hours). Snapshots from the master on first configure; overridable per org.

   Downstream sweeps compute the fire times as `start + duration × pct / 100`, honouring `time_basis` when advancing the clock.

2. **Pick roles** to be notified for each of THREE events **(post-182)** — the same Configure dialog now carries all three role multi-selects:
   - **WARNING** fires `warning_before_due_days` before due.
   - **BREACH** fires exactly at the due date (the moment the SLA is crossed).
   - **ESCALATION** fires `escalation_after_due_days` after the breach.

   Roles are stored, not employees — the actual notify list is resolved at fire time via `sp_org_role_holders_list` (117), so employee turnover never orphans the config.
3. **Bind** the tuned SLA against one or more processes: **GAP**, **TASK**, **OBSERVATION**, **EXCEPTION** (extensible — insert into `sla_process_type_master`). Each binding can be a default (`process_scope_ref_id IS NULL`, applies to every item of that process type) or scoped (e.g. specific `task_type_id` for TASK).

**Only Active configs feed downstream process pickers.** `sp_org_sla_config_for_process` filters both binding and config `is_active = 1`, so an Inactive row disappears from the resolver's output automatically — no separate filter needed at the caller.

## Schema (migration 178)

```
sla_process_type_master        (catalog: GAP / TASK / OBSERVATION / EXCEPTION)
    ↑ FK
org_sla_process_binding        (org, config, process_type[, scope_ref_id])
    ↓ FK
org_sla_config                 (header: org, sla_master, thresholds, notes)
    ↓ FK
org_sla_config_notify_role     (config, event WARNING|ESCALATION, role)
```

Guards enforced at the schema level:

- `ck_pm_org_sla_warning_pct` — `warning_pct` between 0 and 100 (or NULL). (Added in 183; replaces the day-based `ck_pm_org_sla_thresholds`.)
- `ck_pm_org_sla_escalation_pct` — `escalation_pct` between 0 and 100 (or NULL).
- `ck_pm_org_sla_pct_order` — `warning_pct ≤ escalation_pct` when both set, so WARNING always fires before ESCALATION.
- `ck_pm_org_sla_nr_event` — notify event code is WARNING / BREACH / ESCALATION (widened in 182).
- `ux_pm_org_sla_org_master_active` — no duplicate active adoption of the same master per org.
- `ux_pm_org_sla_notify_role_uniq` — no duplicate (config, event, role) triple.
- `ux_pm_org_sla_bind_org_process_scope` — one active binding per (org, process_type, scope_ref).

## Procedures (migrations 179 + 181)

| Proc | Purpose |
|---|---|
| `sp_ctrl_sla_master_list` **(181)** | Reads the actual `grac_new.sla_master` shape (`sla_id`, `sla_code`, `process_code`, `classification`, `duration_value`, `duration_unit`, `warning_pct`, `escalation_pct`, `effective_from`, `remarks`, `status`). Derives Name from classification (fallback to code) and TotalSlaDays from duration+unit. Filters `status = 'Active'`. |
| `sp_org_sla_master_grid` **(181)** | Master-first grid. LEFT JOINs every active master with `org_sla_config` and emits `ConfigStatusCode` (`NotConfigured`/`Active`/`Inactive`) plus the tuned or master-derived thresholds so the dialog opens with sensible defaults. |
| `sp_org_sla_config_set_active` **(181)** | Toggle handler for the Inactivate / Reactivate menu items. Keyed by `(organization_id, sla_master_id)`. Throws a friendly error if the SLA has no config row yet. |
| `sp_org_sla_process_type_list` | Fixed catalog for the UI dropdown. |
| `sp_org_sla_config_list` | Paged grid for an org (legacy, adopted-only). Retained; not used by the redesigned UI. |
| `sp_org_sla_config_get` | Detail — 3 result sets (header, notify roles, process bindings). Used by the Notifies + Processes dialogs. |
| `sp_org_sla_config_upsert` **(rewritten in 181, 183)** | Idempotent by `(organization_id, sla_master_id)`. Post-183 contract: `@warning_pct`, `@escalation_pct`, `@time_basis` (no day parameters). INSERT path creates with `is_active = 1`; UPDATE path leaves `is_active` untouched. `@out_org_sla_config_id` OUTPUT. Throws if pct outside 0..100 or if warning > escalation. |
| `sp_org_sla_config_notify_role_set` | Full-replacement save from JSON, with role-name snapshot. |
| `sp_org_sla_process_binding_set` | Full-replacement save from JSON. **Pre-validates** the target (process_type, scope_ref) pairs against active bindings owned by other configs in the same org; throws 53796 before wiping when a collision is detected. |
| `sp_org_sla_config_for_process` | Resolver used by sweeps. Filters both binding and config `is_active = 1` so Inactive configs disappear automatically. Match priority: exact scope → default (`scope_ref IS NULL`) → empty result sets. |

## API

Base route: `/api/practice/org-sla` (Api tier) proxied at `/practice/api/org-sla` (Web tier). Web proxy enforces session + `IsOrganizationAllowed` cross-org isolation exactly like `OrgAssuranceController`.

| Verb | Path | Purpose |
|---|---|---|
| GET  | `/masters` | Control Management SLA master list (also carries the extra columns exposed in 181) |
| GET  | `/masters-with-config?organizationId=&search=` | **Master-first grid (post-181)** — the UI's primary entry point |
| GET  | `/process-types` | Catalog |
| GET  | `/configs?organizationId=&search=&page=&pageSize=` | Legacy adopted-only grid; retained |
| GET  | `/configs/{id}?organizationId=` | Detail |
| POST | `/configs` | Create or update (idempotent by org+master; INSERT auto-activates) |
| POST | `/configs/set-active` | Toggle `is_active` for Inactivate / Reactivate menu actions |
| POST | `/configs/{id}/notify-roles` | Full-replacement save of notify roles |
| POST | `/configs/{id}/process-bindings` | Full-replacement save of process bindings |
| GET  | `/for-process?organizationId=&processType=&scopeRefId=` | Resolver (used by sweeps + UI diagnostics). Filters `is_active = 1` — only Active configs surface. |

Reads return `{ data: ... }`; writes return `{ success, ... }` — matches `OrgAssuranceDefinitionController`.

## UI

Single-partial screen keyed `org-sla-config`, registered under Governance group and rendered via the workflow-partial path in `Manage.cshtml`.

**Grid** — every master row for the org, sorted Not Configured → Active → Inactive. Columns: SLA name/code, Process, Classification, Duration (raw value + unit), Warning (days + master %), Escalation (days + master %), Status badge, notify role count, binding count, per-row action menu.

**3-dot menu per row** (status-aware, post-182):

| Status | Menu items |
|---|---|
| Not Configured | Configure |
| Active | Configure · Processes · Inactivate |
| Inactive | Configure · Processes · Reactivate |

**Configure dialog (one-stop, post-183)** — master identity is read-only (fixed by the row that was clicked; no picker). Two sections:

1. **Thresholds + time basis + notes** — inputs are `Total SLA (days)`, `Warning % of SLA`, `Escalation % of SLA`, `Time Basis` combo (Calendar Days / Business Days / Calendar Hours / Business Hours; blank = inherit master). Values pre-fill from the config override if present, otherwise from the master. The master's own values are also shown in the read-only meta line for comparison.
2. **Notify roles** — three role multi-selects: **WARNING**, **BREACH**, **ESCALATION**. Hydrated from existing config's notifies when editing. Custom collapsible combos (mounted by `mountMultiDropdown`) so the operator gets a proper dropdown instead of the native always-open list box.

Save issues two sequential POSTs: `/configs` (upsert pct + time_basis + notes — creates row with `is_active = 1` if new) then `/configs/{id}/notify-roles` (full-replace all three event role lists in one call). A partial-failure at step 2 leaves thresholds saved and prompts the user to retry.

**Bind Processes dialog** — add-row grid: process type (from catalog) + optional scope ref id + display label. Save is full replacement with pre-collision check.

**Inactivate / Reactivate** — a confirm() then POST `/configs/set-active`. No dialog.

Role picker feed reuses the existing shared `/practice/api/org-roles` endpoint (added in 116a/116b/117).

## Downstream integration

Sweeps that already exist:

- **Task Centre (192–196) — DONE for derivation, OUTSTANDING for notification.**
  `sp_task_apply_sla` (193) now resolves an SLA for every task from its
  **priority**, via `sp_org_sla_match_for_priority` → the same
  `classification`-match resolver the gap flow uses
  (`sp_org_sla_match_for_severity`, 184). Note this deliberately does
  **not** resurrect `org_sla_process_binding` / `sp_org_sla_config_for_process`,
  which 186 dropped as dead surface — Task Centre follows the
  classification pattern so GRAC has one lookup style, not two. The org's
  tuned `warning_pct` also drives the derived `sla_status_code` exposed by
  `vw_pm_practice_task` (195).
  Still outstanding: `sp_task_overdue_sweep` (037) escalates without
  notifying anyone. It should resolve the config's notify roles through
  `sp_org_role_holders_list` (117) and fire WARNING / BREACH / ESCALATION
  to the holders. See "Deferred to Phase 2" in
  [task-centre-v2.md](task-centre-v2.md).
- Gap Centre (156-158) — no SLA today. Resolver call for GAP goes at gap due-date crossing (a new sweep to add).
- Exception Centre (161-166) — same pattern (EXCEPTION resolver).

## Compat / safety

- All schema is additive; existing task engine, gap centre, exception centre, assurance workflow SLA fields are untouched.
- Menu seed puts the screen under an existing `nav-governance` parent and behind a feature flag (`screen.org-sla-config`) so the row is invisible until the flag is enabled.
- Rollbacks provided for schema, procs, and menu seed — safe to re-run.
