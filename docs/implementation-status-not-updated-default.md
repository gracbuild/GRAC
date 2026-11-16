# Implementation Status defaults to "Not Updated" (migration 456, 2026-10-08)

## Request
Applicability already defaulted to **Not Updated**, but Implementation Status
defaulted to **Not Implemented** (Control Statement, Practice, Practice
Instance) and showed **Not set** on an Operationalize obligation. Implementation
Status now defaults to **Not Updated** everywhere, and becomes **Not Implemented**
only once something has actually been updated (decision 2026-10-08: "update
cheythaal mathram").

## Rule
| Level | Not Updated | Implemented | Partially Implemented | Not Implemented |
|---|---|---|---|---|
| Obligation (Operationalize card) | no status stored (NULL) | chosen | chosen | chosen |
| Practice Instance (stored, derived by DB) | no applicable obligation updated (all NULL / legacy Not Started); or no applicable obligation and only a default value stored | every applicable obligation Implemented | - | otherwise |
| Practice / Control Statement (derived on read) | applicability Not Updated, no instances, or no instance updated | Applicable + every instance Implemented | Applicable + some instance Implemented | Applicable + an instance updated, none Implemented |

N/A obligations are excluded (as in 346). Not Applicable / Deferred / Accepted Risk /
Retired applicability still gives **Not Applicable**.

Gap detection is unchanged: gaps come from obligation statuses (Not Implemented /
Partially Implemented - 243/245/367), never from the instance column.

## Database - `database/456_implementation_status_not_updated_default.sql`
1. `implementation_status_master` row `Not Updated` (is_active = 0 on purpose: the
   obligation dropdown lists active rows, and its empty option is already labelled
   "Not Updated"; the row exists so instances can reference it).
2. `sp_pm_recalc_instance_impl_status` (346) re-issued with the rule above.
3. New trigger `tr_pm_practice_instance_impl_status_default` (AFTER INSERT on
   `practice_instance`): a new instance starts at Not Updated whatever the creating
   path wrote; adopted obligations then derive the real value through
   `tr_pm_pio_impl_status_rollup`.
4. Backfill of every instance.
5. `sp_practice_detail_get` (from 396) - Practice View roll-up.
6. `sp_dashboard_governance` (from 414) - new KPI `instances.notupdated` "Not updated"
   (sort 5; "No owner" moves to 6).
7. `sp_practice_instance_open_implementation_task` (from 043) - also opens from
   Not Updated.

Rollback: `456_implementation_status_not_updated_default_rollback.sql`.
`database/recalc_practice_instance_impl_status.sql` now just runs the proc (it used
to carry its own copy of the old rule).

## API - `PracticeRepositoryService.cs`
No new endpoint or field. Response values change:
- Control Statement tree (`QueryReleaseStatementsAsync`), `ImplementationStatus`:
  new value `Not Updated` (CTE `statement_implementation` gains `UpdatedInstanceCount`).
- Organization Practices (`QueryOrganizationRequirementFallbackAsync`),
  `PracticeImplementationStatus`: new value `Not Updated` (`pic` apply gains
  `UpdatedInstanceCount`).
- Practice View (`sp_practice_detail_get`), `PracticeImplementationStatus`: same.
- Governance dashboard KPIs: extra row `instances` / `notupdated`.
- Practice instance rows: `ImplementationStatus` = `Not Updated` for untouched instances.

## Web
- `practice.js`: fallbacks "Not Implemented" -> "Not Updated" (statement tree,
  `practiceImplementationStatus`); `Not Updated` added to the static
  `implementation-status` lookup so the read-only instance field shows it.
- `resolve-workspace.cshtml`: obligation badge and Implementation status dropdown
  empty option "Not set" -> "Not Updated" (other fields keep "Not set").
- `Shared/obligation-form.js`, `_obligation-form-dialog.cshtml`: same for the
  shared obligation form's Implementation status.
- `_add-implementation-task-modal.cshtml`, `practice-instance-implementation-task.js`:
  "Add Implementation Task" also offered on Not Updated.
- `ManagementDashboard/management-dashboard.js`: `instances.notupdated` drills to
  Operationalize filtered by status Not Updated.

## Deploy
Run 456 -> rebuild Api + Web -> Ctrl+F5.

## Control statement: a practice with no instances now holds it back (2026-11-10)

> "oru control nu 2 practice oru practice implemented matte practice not updated (no instance
> created) ee case lanu control ne implemented ennu kanikunnathu"

**Cause.** A control statement's Implementation Status is derived from the **practice instances**
of the practices mapped to it. A mapped practice that has **no instance yet** adds nothing to
either count. So a statement with one fully Implemented practice and one practice that was never
configured passed the test `InstanceCount > 0 AND InstanceCount = ImplementedInstanceCount` and
read **Implemented**. The practice level was already right: with no instances it shows Not Updated.

**Rule now (statement level)**

| Condition | Result |
|---|---|
| Applicable, at least one instance, every instance Implemented, **and every mapped practice still to be implemented has at least one active instance** | Implemented |
| Applicable, at least one instance Implemented (otherwise) | Partially Implemented |
| Not Applicable / Deferred / Accepted Risk / Not Implemented / Retired | Not Applicable |
| Applicable, an instance updated | Not Implemented |
| Otherwise | Not Updated |

"Still to be implemented" means a mapped practice whose own applicability is **not** Not Applicable,
Deferred, Accepted Risk, Not Implemented or Retired. Such a practice is deliberately out of scope,
so it never holds the statement back. A practice whose applicability is still Not Updated does
hold it back.

So the reported case, one practice Implemented and one with no instance, now reads **Partially
Implemented**. If neither practice has an Implemented instance, the result is unchanged.

**Changed:** `PracticeRepositoryService.cs` only. No SQL migration was needed: every place that
derives a statement's implementation status lives there.

| Where | What |
|---|---|
| `QuerySubscribedFrameworksAsync`, repository releases (Level 1 summary) | new CTE `statement_pending_practices`; `ImplementedStatementsCount` requires none |
| `QuerySubscribedFrameworksAsync`, custom releases | new scalar `PracticeWithoutInstanceCount` per statement; same condition |
| `QueryReleaseStatementsAsync` (repository Control Statements tree) | new CTE `requirement_has_instance`; `statement_practice_counts.PracticeWithoutInstanceCount`; the Implemented branch of `ImplementationStatus` requires 0 |
| Custom release Control Statements query | the same two additions, keyed on `org_statement_id` |

The Level 1 Implemented count and the drill-down's statement status still follow one rule, so
they cannot disagree. The four changed query texts were extracted and parsed (`sqlfluff`, tsql):
0 unparsable.

**Deploy:** deploy the Api only. No Web or SQL change.
