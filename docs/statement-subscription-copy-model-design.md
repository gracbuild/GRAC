# Statement Subscription Copy Model — Design

**Status:** Decisions final (§8). Phase 1: 391 (§9). Phase 2: 392-394 (§10). Phase 3: 395 + 396 + API/Web (§11). Phases 2 and 3 ship together. Phase 4 not started.
**Date:** 2026-09-28 (rev 2: decisions folded in, obligations catalogue added to scope)
**Builds on:** `docs/custom-statement-mapping-unification-plan.md`. This document is that plan's **Option A**, the follow-on to Option B (migration 347), which is already live.

---

## 1. Decisions this design implements (from sir)

1. **Subscribing copies.** When an organization subscribes a release, every statement of that release is copied into the organization's own statement table. From then on, every screen reads the organization's copy, not `grac_new`.
2. **One table for custom and repository statements.** Custom statements live in the same organization table, so both are managed the same way.
3. **Later repository changes are not automatic.** A change made in `grac_new` after an organization has subscribed must **not** reach that organization directly. It is raised as a pending change, the organization is notified, and it is applied only after approval.
4. **Approval covers add, edit and retire.** New items, content edits and retirements all wait for approval.
5. **Approver.** The release owner **or** an organization admin can approve.
6. **Notification.** A new dedicated notification table, not a generalised task outbox.
7. **Retirement is flag-only for now.** A retired statement or obligation is flagged. Its practices, instances and tasks are **not** closed or retired in this phase.
8. **Obligations catalogue is in this phase.** Obligations follow the same copy + approval model as statements.
9. **Detection is scheduled.** There is no on-demand "Check for updates" and no publish-time hook.

---

## 2. Current state (verified in code, 2026-09-28)

Today the organization side is an **overlay**, not a copy. A new `grac_new` statement appears in subscribed organizations immediately, for three reasons (§2.1–2.3). Obligations have the same problem (§2.6).

### 2.1 Read-time auto-sync
`PracticeRepositoryService.SyncOrganizationFrameworkStatementsAsync` inserts every active `grac_new.framework_statement` missing from `grac_practice.organization_framework_statements`, as *Not Updated*. It runs on these paths:

| Call site | Trigger |
|---|---|
| `subscribed-frameworks` query | Every Standards & Frameworks / Control Statements page load |
| `release-statements` query | Every statement-tree load |
| `organization-setup` save | Subscribing / organization setup |
| `QueryOrganizationRequirementFallbackAsync` (with `releaseId`) | Every Practices load for a release |

### 2.2 Live reads from `grac_new`
The statement tree (`QueryReleaseStatementsAsync`) is driven **from** `grac_new.framework_statement`, with the organization table as a `LEFT JOIN`. The code comment says a repository statement "must never disappear" when the organization row is missing. The release counts (`QuerySubscribedFrameworksAsync`) are built the same way.

The organization table holds only `framework_statement_id`, applicability, owner and reason. Reference, title, text and structure node always come from `grac_new`. As a result, an **edit** in `grac_new` also shows up in every organization at once.

### 2.3 Read-time practice import
`QueryOrganizationRequirementFallbackAsync` imports practices on read. When called with a `releaseId`, it inserts new `organization_requirement` rows (and `organization_statement_practice_mapping` rows) from `grac_new.framework_statement_requirement_map` / `grac_new.requirement`. Practice **content** is already a copy (`organization_requirement` carries code, name, statement and objective), but *which* practices exist still follows `grac_new` live.

### 2.4 Custom statements
Migration 347 gave custom statements a row in `organization_framework_statements` (`source_type = 'Custom'`, `custom_statement_id`). Their **content** is still in `custom_release_statement` and `custom_release_source_structure`.

### 2.5 Everything that reads `grac_new` statement data (blast radius)

**C#, `PracticeRepositoryService.cs`:**
- `SyncOrganizationFrameworkStatementsAsync`
- `QuerySubscribedFrameworksAsync`
- `QueryReleaseStatementsAsync`
- `QueryOrganizationRequirementFallbackAsync`
- `QueryPracticeStatementMappingsAsync`
- `SaveStatementApplicabilityAsync`

**SQL objects (latest definitions):**

| Object | Latest migration |
|---|---|
| `dbo.pm_get_practice_repository` | 300 |
| `dbo.pm_manage_practice_repository` | 380 |
| `sp_practice_detail_get` | 348 |
| `sp_practice_picker_controls` / `_structures` / `_practices` / `_resolve` | 351 |
| `sp_resolve_instance_list` | 315 |
| `sp_risk_scope_practice_context` | 284 |
| `sp_apply_practices_for_control` | 057 |

### 2.6 Obligations today (verified in code, 2026-09-28)

**Repository catalogue in `grac_new`:**
- **Core:** `requirement_obligation` (name, text, type, frequency, responsibility, approval authority, retention).
- **Links:** `obligation_requirement_release_map` (obligation ↔ requirement, per release).
- **Evidence:** `requirement_obligation_evidence`.
- **Typed specs:** `obligation_assurance_spec`, `obligation_execution_spec`, `obligation_retention_spec`, `obligation_state_rule`, `obligation_event_response`, `obligation_constraint_rule`.
- **Evidence links:** the `*_evidence_link` table for each typed spec.
- **Master / lookup tables:** `obligation_type_master`, `evidence_type_master`, `reference_option`, `event_type_master`, `sla_master`.

**Organization side in `grac_practice`:**
- `practice_instance_obligation` (140, extended by 226/227/242) is created when an instance **adopts** an obligation (`sp_resolve_obligation_adopt`). It snapshots `obligation_name` and `obligation_type_code` and holds the organization's parameters (frequencies, responsibility, approval authority, retention). Its `obligation_id` is the `grac_new` key.
- `practice_obligation` (307) holds organization-defined obligations. They already carry their typed spec as `typed_detail_json`.
- The obligation **list**, **typed detail** and **evidence** are read live from `grac_new`. A new or edited repository obligation therefore shows up in every subscribed organization at once, exactly like statements.

**SQL readers of the `grac_new` obligation catalogue (latest definitions):**

| Object | Latest migration | `grac_new` tables read |
|---|---|---|
| `sp_resolve_obligation_list` | 353 | `requirement_obligation`, `obligation_requirement_release_map`, `obligation_type_master`, `reference_option` |
| `sp_resolve_obligation_adopt`, `sp_resolve_evidence_reconcile_for_instance` | 304 | `requirement_obligation`, `obligation_requirement_release_map`, `evidence_type_master` |
| `vw_pm_obligation_typed_detail` | 302 | `requirement_obligation`, all typed spec tables, `requirement_obligation_evidence` |
| `sp_resolve_evidence_list` | 306 | `requirement_obligation_evidence`, `evidence_type_master` |
| `dbo.sp_pm_view_obligations_typed` | 301 | `requirement_obligation`, `obligation_requirement_release_map` |
| `vw_pm_event_driven_obligation` | 342 | `requirement_obligation`, `obligation_assurance_spec`, `obligation_requirement_release_map` |
| `vw_pm_practice_default_frequency`, `sp_practice_instance_configure`, `sp_resolve_instance_frequency_save` | 145 | `requirement_obligation`, `obligation_assurance_spec`, `obligation_requirement_release_map` |
| `sp_resolve_instance_list` | 315 | `requirement_obligation`, `obligation_requirement_release_map` |
| `sp_risk_dependency_obligation_list` / `_set` | 309 | `requirement_obligation` |
| `sp_practice_obligation_*`, `sp_resolve_local_obligation_save` | 340 | `obligation_type_master`, `obligation_assurance_spec`, `event_type_master` |
| `sp_resolve_obligation_type_list` / `_fields` | 227 / 228 | type master + field rules |

---

## 3. Target model

### 3.1 The organization statement store
Extend `grac_practice.organization_framework_statements` (already the per-organization identity for both sources since 347) into a **self-contained statement table**. Add content snapshot columns:

| Column | Repository rows | Custom rows |
|---|---|---|
| `statement_reference`, `statement_title`, `statement_text`, `display_order` | copied from `grac_new.framework_statement` at subscribe / approval | copied from `custom_release_statement` (phase 4) |
| `org_structure_node_id` | FK → new `organization_statement_structure_node` | same table (custom structure) |
| `source_version_hash` | hash of the copied `grac_new` content, used for change detection | NULL |
| `copied_dt`, `copied_by` | audit | audit |
| `lifecycle_status` | `Active` / `Retired`. Set to `Retired` only when a retirement is approved (§4.5). | same |

**New table `organization_statement_structure_node`.** A per-organization, per-release copy of `grac_new.source_structure_node`: `org_structure_node_id`, `organization_id`, `release_id`, `source_structure_node_id` (NULL for custom), parent, level, reference, title, display order, `source_version_hash`.

**Practices** (`organization_requirement` + `organization_statement_practice_mapping`) are already copies. They change only in *when* they are created (§3.3).

### 3.2 The organization obligation catalogue (new, decision 8)

**`organization_obligation`.** One row per organization and repository obligation, holding a copy of the catalogue content.

| Column | Meaning |
|---|---|
| `org_obligation_id` | PK |
| `organization_id`, `release_id` | scope |
| `obligation_id` | the `grac_new.requirement_obligation` key. Unique per `organization_id`. This is the same value `practice_instance_obligation.obligation_id` already stores, so existing instance rows join to the copy **without any data change**. |
| `obligation_name`, `obligation_text`, `obligation_type_id`, `frequency_type`, `execution_frequency_id`, `responsibility`, `approval_authority`, `retention_requirement`, `status` | copied from `requirement_obligation` |
| `typed_detail_json` | the typed spec rows (assurance / execution / retention / state / event response / constraint) as JSON. This reuses the shape `practice_obligation.typed_detail_json` (307) already uses, so the typed-detail renderer is shared. |
| `source_version_hash` | hash over the core row + typed specs + evidence, used for change detection |
| `lifecycle_status` | `Active` / `Retired` |
| `copied_dt`, `copied_by` | audit |

**`organization_obligation_requirement_map`.** A copy of `obligation_requirement_release_map` for the subscribed release: `organization_id`, `release_id`, `obligation_id`, `requirement_id`, `status`.

**`organization_obligation_evidence`.** A copy of `requirement_obligation_evidence` plus the typed `*_evidence_link` rows: `organization_id`, `obligation_id`, source `obligation_evidence_id`, `evidence_type_id`, evidence text / remarks, `spec_kind` (NULL for core evidence), `status`. The evidence readers (304 / 306) repoint here.

**Not copied.** Master and lookup tables stay live reads from `grac_new`: `obligation_type_master`, `evidence_type_master`, `reference_option`, `event_type_master`, `sla_master`. They are shared reference data, not catalogue content, and the organization never approves them. `artifact` (read by 227/301/353) will be classified in phase 1 before its readers are changed.

**Organization-defined obligations** (`practice_obligation`, 307) are untouched. They are already the organization's own data.

### 3.3 Subscribe = one copy procedure
New `sp_repository_subscription_copy(@organization_id, @release_id, @actor)`. In one transaction, and idempotently, it copies:
1. structure nodes → `organization_statement_structure_node`;
2. statements → `organization_framework_statements`, with content, hash and *Not Updated* status;
3. statement → requirement links → `organization_requirement` + `organization_statement_practice_mapping`. This is the logic that today runs at read time inside `QueryOrganizationRequirementFallbackAsync`, moved here.
4. obligations of those requirements for this release → `organization_obligation`, `organization_obligation_requirement_map`, `organization_obligation_evidence`.

It is called from the subscribe path (the `organization-setup` / Repository Subscriptions save) **only**. Each step is also exposed as an item-level routine so that approval (§4.5) reuses exactly the same code.

*Implementation note (391):* step 3 (practices) is **not** in phase 1. It moves out of `QueryOrganizationRequirementFallbackAsync` in phase 2, in the same change that deletes the C# version, so the logic is moved once rather than duplicated for a release.

### 3.4 Reads use only the organization copy
- Delete the four read-time `SyncOrganizationFrameworkStatementsAsync` calls and the read-time import block in `QueryOrganizationRequirementFallbackAsync`.
- Repoint every statement reader in §2.5 from `grac_new.framework_statement` / `source_structure_node` to `organization_framework_statements` / `organization_statement_structure_node`. The statement tree becomes `FROM organization_framework_statements`, so no `LEFT JOIN` "never disappear" rule is needed.
- Repoint every obligation reader in §2.6 from `requirement_obligation` / typed spec tables / `obligation_requirement_release_map` / `requirement_obligation_evidence` to the three organization obligation tables. `vw_pm_obligation_typed_detail` then reads `typed_detail_json`, as it already does for organization-defined obligations.
- `grac_new` catalogue content is read only by the copy procedure and by change detection (§4). Master / lookup tables stay live (§3.2).

---

## 4. Repository changes: detect, notify, approve

### 4.1 What counts as a change (decision 4: add, edit and retire all need approval)

| Change in `grac_new` | Pending item type | Applied on approval as |
|---|---|---|
| New statement in a subscribed release | `StatementAdded` | new organization row, *Not Updated*, plus its practices and their obligations |
| Reference / title / text / node changed | `StatementChanged` (old vs new shown) | content columns updated, hash refreshed |
| Statement retired | `StatementRetired` | flag only (§4.6) |
| New statement → requirement link | `PracticeLinkAdded` | practice created / linked, with its obligations |
| Structure node added or changed | `StructureChanged` | node copy updated |
| New obligation linked to a subscribed requirement / release | `ObligationAdded` | `organization_obligation` + map + evidence rows created |
| Obligation core row, typed spec or evidence changed | `ObligationChanged` (old vs new shown, including typed detail) | copy updated, hash refreshed. Instance parameters the organization set on `practice_instance_obligation` (frequencies, responsibility, and so on) are **not** overwritten. |
| Obligation retired or unlinked | `ObligationRetired` | flag only (§4.6) |

### 4.2 Detection (decision 9: scheduled only)
New `sp_repository_change_detect(@organization_id = NULL)`. It compares each active subscription's copy against `grac_new` by key plus `source_version_hash`, and writes one pending row per difference.

- **How it runs.** It runs on a schedule only. A new `RepositoryChangeDetectWorker` (a `BackgroundService`) follows the existing `TaskNotificationWorker` / `EventAutoRaiseWorker` pattern: no Hangfire, the interval comes from configuration (default nightly), and there is a registration switch so that an on-prem deployment can drive the same procedure from SQL Agent instead.
- **What it does not add.** There is no "Check for updates" button and no trigger or publish hook on `grac_new`, which belongs to Control Management.
- **Re-runnable.** An item already pending, approved or rejected for the same `(org, release, change type, source key, hash)` is not raised again.

### 4.3 Storage — pending changes
- **`organization_repository_change`**
  - `change_id`, `organization_id`, `release_id`, `subscription_id`, `detection_run_id` (GUID of the worker run)
  - `change_type`, `source_key` (`framework_statement_id` / node id / map id / `obligation_id`), `old_snapshot_json`, `new_snapshot_json`, `new_version_hash`
  - `status` (`Pending` / `Approved` / `Rejected` / `Superseded`), `detected_dt`
  - `decided_by_employee_id`, `decided_dt`, `decision_remark`
- A newer difference on the same key marks the older pending row `Superseded`.

### 4.4 Notification (decisions 5 and 6)
- **New table `organization_repository_change_notification`**
  - `notification_id`, `organization_id`, `release_id`, `detection_run_id`
  - `recipient_employee_id`, `recipient_reason` (`ReleaseOwner` / `OrgAdmin`)
  - `pending_count`, `created_dt`, `read_dt`, `status` (`Unread` / `Read` / `Cleared`)
  - One row per recipient, per release, per detection run, and only when that run raised new pending items.
- **Recipients.**
  - The release owner: `repository_subscription.owner_id`.
  - Every organization admin: an active employee of the organization whose role's `organization_role.data_scope` is `ORGANIZATION` or `GLOBAL`. This uses the same rule `PracticeAuthenticationService` already applies (`organization_employee.role_id` plus `organization_employee_role`).
- **Cleared.** A row is cleared when its release has no pending items left.

### 4.5 Approval UI and apply
- **Where it shows.**
  - A "Pending repository updates (N)" badge on the release row in **Standards & Frameworks**, opening a review page.
  - A row in Home → *Needs your attention*, rendered by the existing `home-my-work.js` from a new endpoint that reads the notification table.
- **Who can approve.** The release owner **or** an organization admin. The API checks: the caller's employee id equals the subscription `owner_id`, **or** the caller is an admin, using the same `X-PM-Caller-Is-Admin` header pattern that `ResolveWorkspaceController` already uses. Everyone else can view but not decide.
- **Review page.** A list of pending items with old/new diff (typed detail diff for obligations), approve/reject each or in bulk, and a mandatory remark on reject.
- **Apply.** `sp_repository_change_apply(@change_id, @decision, @actor, @remark)`. Approving calls the same item-level copy routines as subscribe (§3.3), so there is one implementation of "copy".
- **Audit.** Every decision goes to `practice_audit_trace`.

### 4.6 Retirement is flag-only (decision 7)
- **On approval of `StatementRetired`:** `organization_framework_statements.lifecycle_status = 'Retired'`.
- **On approval of `ObligationRetired`:** `organization_obligation.lifecycle_status = 'Retired'`.
- **What stays unchanged:** practices, `practice_instance`, `practice_instance_obligation`, tasks and evidence. Their status is not changed. The UI shows a "Retired in repository" badge, read from the copy's `lifecycle_status`, on the statement tree, the practice detail and the resolve obligation list.
- **What is left for later:** closing or retiring dependent practices and instances is a later phase. It is not designed here.

---

## 5. Custom statements in the same table (phase 4)
Move custom statement content (`custom_release_statement`, `custom_release_source_structure`) into the content columns and `organization_statement_structure_node` (`source_type = 'Custom'`). Custom authoring then writes that table directly. The old custom tables are kept read-only until every reader is confirmed, then retired. After this, readers have no `source_type` branch for content.

---

## 6. Migration / backfill
For every active subscription, snapshot the **current** `grac_new` content into the new statement columns, the node table and the three obligation tables. This is exactly what organizations see today, so nothing changes visually on cut-over. The baseline hash is recorded. Only changes made **after** the cut-over go through approval.

The backfill is re-runnable and has a rollback that drops the new columns and tables. Readers must be repointed in the same release as the backfill.

---

## 7. Phasing

| Phase | Scope | Visible result |
|---|---|---|
| 1 | Statement snapshot columns, node table, obligation copy tables, backfill, `sp_repository_subscription_copy` | none (data only) |
| 2 | Repoint all statement and obligation readers (§2.5, §2.6); remove read-time sync and read-time practice import | a new or edited `grac_new` statement or obligation **no longer appears automatically** |
| 3 | Detection worker, pending-change table, notification table, review/approve UI, retired badges | changes arrive as *pending updates* for the release owner / org admin to approve |
| 4 | Custom statement content into the same table | one store for all statements |

**Phases 2 and 3 ship in the same release.** Detection is scheduled only, with no manual fallback, so phase 2 alone would leave new repository content with no way to reach an organization.

---

## 8. Decisions log (sir, 2026-09-28)

| # | Question | Decision | Where applied |
|---|---|---|---|
| 1 | Which changes need approval? | New, edit **and** retire | §4.1 |
| 2 | Who approves? | Release owner **or** org admin | §4.4, §4.5 |
| 3 | Notification channel | New dedicated table | §4.4 |
| 4 | Retired statements' practices / instances | Flag only for now | §4.6 |
| 5 | Obligations catalogue in this phase? | Yes, same copy + approval model | §2.6, §3.2, §4.1 |
| 6 | Detection cadence | Scheduled | §4.2, §7 |

---

## 9. Phase 1 implementation — migration 391 (2026-09-28)

**Files**
- `database/391_repository_subscription_copy_phase1.sql` (+ `_rollback.sql`)
- `src/PracticeManagement.Api/Services/PracticeRepositoryService.cs`

**No screen or API contract change.** Every reader still reads `grac_new`.

### 9.1 Why the copy tables are built from the catalogue
`grac_new` DDL is not in this repository. Instead of guessing column names and types, 391 reads them from `sys.columns`, the same approach 228/302 use for the typed obligation detail. After a Control Management schema change, re-run 391: views are rebuilt, and new source columns are added to the copy tables.

### 9.2 Objects

| Object | Purpose |
|---|---|
| `fn_repo_column_type(@object_id, @column)` | exact DDL type of a source column (`rowversion` → `binary(8)`) |
| `fn_repo_clone_reserved_columns()` | organization-side column names never taken from a source |
| `sp_repo_build_source_view` | builds `vw_repo_src_*` = source columns + `content_hash` (SHA2_256 of the row as JSON; audit columns excluded) |
| `sp_repo_clone_ensure_table` | creates / widens an organization copy table from a source view |
| `sp_repo_clone_sync(@copy_code, @organization_id, @release_id, @refresh, @actor, @key_value)` | inserts missing rows; with `@refresh = 1` overwrites rows whose hash differs; `@key_value` limits it to one item (phase 3 apply) |
| `repository_copy_config` | one row per copied object: source, view, target, key, scope predicate, order |
| `sp_repository_subscription_copy(@organization_id, @release_id = NULL, @refresh = 0, @actor, @suppress_result)` | **the** copy routine: runs every config row in order, per release, one transaction per release |

### 9.3 Copy steps (`repository_copy_config`)

| Order | Code | Source → target | Key |
|---|---|---|---|
| 10 | `StructureNode` | `source_structure_node` → `organization_statement_structure_node` | `structure_node_id` |
| 20 | `Statement` | `framework_statement` → content columns on `organization_framework_statements` | `framework_statement_id` |
| 30 | `Obligation` | `requirement_obligation` + the 7 JSON columns of `vw_pm_obligation_typed_detail` → `organization_obligation` | `obligation_id` |
| 40 | `ObligationMap` | `obligation_requirement_release_map` → `organization_obligation_requirement_map` | the map's own primary key, read from the catalogue |
| 50 | `ObligationEvidence` | `requirement_obligation_evidence` → `organization_obligation_evidence` | `obligation_evidence_id`; scope = the ids the obligation's copied `evidence_json` lists (direct + per-type links, as 302 resolves them) |

Every copy table has:
- `<org pk> BIGINT IDENTITY`, `organization_id`, `lifecycle_status` (default `Active`), `source_version_hash`, `copied_dt`, `copied_by`;
- then all source columns (nullable);
- a unique index on `(organization_id, key)`.

`organization_framework_statements` gains `statement_reference`, `statement_title`, `statement_text`, `display_order`, `structure_node_id` (typed as in `grac_new`), `org_structure_node_id` (FK), `source_version_hash`, `copied_dt`, `copied_by`, `lifecycle_status`.

### 9.4 When the copy runs
- **Migration backfill:** every organization with an active repository subscription, `@refresh = 0`.
- **Organization-setup save** (`PracticeRepositoryService`, after the existing statement sync): new `CopyRepositorySubscriptionsAsync`. The save has already committed, so a copy failure is logged as a warning, not returned as an error. The organization-id resolution SQL is now one shared constant, `OrganizationIdFromPayloadSql`, used by both the sync and the copy.
- **Cut-over, just before phase 2:** `EXEC grac_practice.sp_repository_subscription_copy @organization_id = <id>, @refresh = 1, @actor = N'cutover';` per organization. Until phase 2, screens still read `grac_new`, so the copy can fall behind.

### 9.5 Known points for later phases
- **Phase 3, hash stability:** the typed-spec JSON (`FOR JSON` without `ORDER BY` in 302) has no guaranteed row order. Phase 3 must confirm the hash is stable before trusting it for change detection, and give 302's builder an `ORDER BY` if it is not.
- **Phase 2, `artifact` and `release`:** readers that join `grac_new.artifact` / `grac_new.release` (release header data) stay live. `artifact` is still to be classified.

---

## 10. Phase 2 implementation — migrations 392-394 (2026-09-28)

### 10.1 Scope found while tracing the readers
Three more catalogues reached organizations live, beyond 391's scope:
- **Statement → practice links:** `framework_statement_requirement_map` + `requirement`. The Practices page imported practices from them at read time, and so did every Applicable save.
- **Controls:** `control`, `source_control_map`, `control_requirement_map`. `pm_get_practice_repository` re-INSERTed and re-UPDATEd `organization_control` from them on every load. Sir, 2026-09-28: controls join the copy + approval model in this phase.
- **Practice content:** comes from `requirement`, copied as `organization_repository_requirement`.

### 10.2 392 — foundation (no screen change)

**New copy steps**

| Order | Code | Target |
|---|---|---|
| 12 | `SourceControlMap` | `organization_source_control_map` |
| 14 | `Control` | `organization_repository_control` |
| 16 | `ControlRequirementMap` | `organization_control_requirement_map` |
| 22 | `StatementRequirementMap` | `organization_statement_requirement_map` |
| 24 | `Requirement` | `organization_repository_requirement` |
| 26 | `PracticeImport` | handler step: `sp_repository_practice_import` |

**Other objects**
- **`repository_copy_config.handler_proc`:** non-generic steps run through a named handler. The Statement step moved into `sp_repository_copy_statements`. `sp_repository_subscription_copy` now dispatches by handler and does not change again when a step is added.
- **Reader layer `fn_org_<grac_new table>(@organization_id)`:** one inline function per copied table, with the same column names. `fn_org_framework_statement` is written out over `organization_framework_statements`. A reader is repointed by replacing `grac_new.<t> x` with `grac_practice.fn_org_<t>(<org>) x`. Where the organization comes from a row, the copy table is joined on `organization_id` instead.
- **`sp_repository_practice_import`:** the one statement → practice import, reading copies only. `@framework_statement_id` limits it to one statement, which is what the Applicable save uses.
- **Backfill:** every subscribed release now has the practices the Practices page would have created the first time it was opened. Existing practices are reused, never duplicated.

### 10.3 393 — statement, structure, control and monolith readers

**Procedures re-issued:** `sp_apply_practices_for_control` (057), `sp_practice_picker_controls/_practices/_resolve/_structures` (351), `sp_risk_scope_practice_context` (284), `sp_practice_detail_get` (348), `dbo.pm_get_practice_repository` (300), `dbo.pm_manage_practice_repository` (380).

**`pm_manage_practice_repository`:** the organization-setup and repository-subscriptions branches run `sp_repository_subscription_copy` right after writing subscriptions, inside the procedure's transaction. A failed copy rolls the save back.

**C# (`PracticeRepositoryService.cs`)**

Deleted:
- `SyncOrganizationFrameworkStatementsAsync` and its three read-path calls.
- The read-time practice import in `QueryOrganizationRequirementFallbackAsync`. Only its subscription check remains.
- The inline import in `SaveStatementApplicabilityAsync`. The Applicable save now calls `sp_repository_practice_import`.
- 391's `CopyRepositorySubscriptionsAsync` and `OrganizationIdFromPayloadSql`, now that the copy runs inside `pm_manage`.

Repointed to the copy:
- `QuerySubscribedFrameworksAsync` (counts)
- `QueryReleaseStatementsAsync` (tree)
- `QueryPracticeStatementMappingsAsync`
- The Practices grid query
- `QueryEvidenceObligationsFallbackAsync`

### 10.4 394 — obligation readers
- **New `vw_pm_org_obligation_typed_detail`:** one row per (OrganizationId, ObligationId), with the same JSON columns as before.
- **`vw_pm_obligation_typed_detail` is unchanged.** It is now used only as the 391 copy source.
- **`vw_pm_obligation_evidence` (144):** now organization-scoped. It has a new first column `organization_id`, and every consumer filters on it. Direct rows come from the evidence copy. Link rows come from the copied `evidence_json`.
- **Views repointed:**
  - `vw_pm_practice_default_frequency` (145) and `vw_pm_event_driven_obligation` (342): copy tables, with the assurance spec read from `assurance_specs_json`.
  - `vw_pm_instance_effective_assurance_frequency` (237) and `vw_pm_instance_schedulable_obligations` (337): the organization typed-detail view.
- **Procedures repointed:** `dbo.sp_pm_view_obligations_typed` (301), `sp_resolve_evidence_reconcile_for_instance` and `sp_resolve_obligation_adopt` (304), `sp_resolve_evidence_list` (306), `sp_resolve_instance_list` (315), `sp_resolve_obligation_list` (353).
- **Still live:** master / lookup tables and release headers.

### 10.5 Operating notes
- **Run order:** 391 → 392 → 393 → 394. After a Control Management schema change, re-run 391 then 392 (the `fn_org_*` functions select `t.*` and must be rebound).
- **Rollbacks:** each rollback re-issues the previous definitions. 393's rollback also needs the C# reverted.
- **Ship together with phase 3.** From 393 on, nothing Control Management publishes reaches an organization until it is approved.

---

## 11. Phase 3 implementation — migration 395 + API + Web (2026-09-28)

### 11.1 Database (395)

**Tables**
- **`organization_repository_change`:** `change_id`, `organization_id`, `release_id` (NULL for a shared item found without a release), `copy_code`, `change_action` (Added / Changed / Retired), `change_type`, `source_key`, `source_label`, `old_snapshot_json` / `new_snapshot_json`, `new_version_hash`, `status` (Pending / Approved / Rejected / Superseded), `detection_run_id`, the decision columns, and `entered_by`.
- **`organization_repository_change_notification`:** one row per recipient, release and run. `recipient_reason` is ReleaseOwner or OrgAdmin; `status` is Unread / Read / Cleared / Superseded.
- **`repository_copy_config.label_sql`:** the item name shown for review. Map rows name both ends of the link.

**Detection**
- **`sp_repo_change_detect_step`:** runs one copy step for one organization.
  - Added and Changed are found per subscribed release, using the release scope.
  - Retired is found once per organization: a copy row whose source is gone or no longer Active.
  - A difference already Pending, Approved or Rejected with the same hash is never raised again.
- **`sp_repository_change_detect`:** runs every organization, then:
  - A newer pending difference on the same item supersedes the older one.
  - Notifications go to the release owner(s) and every organization admin (role `data_scope` ORGANIZATION or GLOBAL, the sign-in rule). An unread notice for the same organization, release and person is replaced, so Home shows one line with the current count.

**Approval — `sp_repository_change_apply`**
- **Who may decide:** `@is_admin = 1`, or the caller owns an active subscription of the change's release (any subscription of the organization for a shared item). Otherwise error 53922.
- **Reject:** needs a remark (53923).
- **Approve Added / Changed:** runs the subscribe copy routines for that one key. `sp_repo_clone_sync` now bypasses the release scope when `@key_value` is given. `sp_repository_copy_statements` takes an optional `@framework_statement_id`.
- **Approve Added when the source is no longer Active:** refused with 53924. Detection re-evaluates it at the next run.
- **Approve Retired:** sets `lifecycle_status = 'Retired'` and nothing else (flag only).
- **Side effects of an approval:**
  - Statement, statement-link or requirement approved for a release: `sp_repository_practice_import` runs for that release.
  - Requirement Changed: `organization_requirement` name, statement and objective are updated to match.
  - Obligation approved: the evidence listed in its copied `evidence_json` is synced, and `practice_instance_obligation.obligation_name` is updated where `organization_modified = 0`.
- **Record keeping:** every decision goes to `practice_audit_trace` (entity `repository-change`). When nothing is left pending for the organization and release, its notices are Cleared.

**Read procedures:** `sp_repository_change_list`, `sp_repository_change_counts`, `sp_repository_change_notification_list`, `sp_repository_change_notification_mark_read`.

### 11.2 API

| Method | Route (`/api/practice/repository-changes`) | Purpose |
|---|---|---|
| GET | `?organizationId&releaseId&status&pageNumber&pageSize` | review list (`status` Pending / Approved / Rejected / Superseded / All) |
| GET | `/counts?organizationId` | pending count per release |
| POST | `/{id}/decision` body `{decision, remark}` | Approve / Reject one change. 400 carries the procedure's message. |
| POST | `/decisions` body `{changeIds[], decision, remark}` | same decision for several changes, applied one by one in the order given; returns per-id results |
| GET | `/notifications?recipientEmployeeId&organizationId` | open notices for Home |
| POST | `/notifications/mark-read?recipientEmployeeId&organizationId` | the recipient opened the review page |

- **No detect endpoint** (decision 9). `RepositoryChangeDetectWorker` runs `sp_repository_change_detect` every `RepositoryChangeDetect:IntervalSeconds` (default 86400), starting `StartupDelaySeconds` (default 300) after start-up. Set `RepositoryChangeDetect:Enabled = false` to schedule the procedure from SQL Agent instead.
- **Registration:** `Program.cs` registers `AddPracticeRepositoryChangeService()` and `AddPracticeRepositoryChangeDetectWorker()`.
- **Web proxy:** `/practice/api/repository-changes` (plus `/me/notifications` and `/me/notifications/mark-read`) checks the session and organization, and stamps `X-PM-Caller-Employee-Id` and `X-PM-Caller-Is-Admin` from the session.

### 11.3 UI
- **Standards & Frameworks:** a release row shows an "N updates" badge (`PendingUpdatesCount`, added to the subscribed-frameworks query). The 3-dot menu has **Repository Updates**. Employee-scope release owners get only this action.
- **Repository Updates page** (`Practice/Index/repository-updates?organizationId&releaseId`, no menu row, VIEW through organization-controls):
  - Release and status filters.
  - Item, kind, change, release, detected date and status for each row.
  - **Details** shows a field-by-field diff: this organization vs the repository.
  - Approve / Reject per row, and Approve selected / Reject selected. Bulk actions apply in repository order. Reject asks for a remark.
  - Opening the page marks the caller's notices Read.
- **Home → Needs your attention:** one line per release with pending updates for the signed-in owner or admin. Needs VIEW on organization-controls and an employee record.

### 11.4 Notes
- **"Organization admin"** is the codebase's existing rule: a role `data_scope` of ORGANIZATION or GLOBAL. The column defaults to ORGANIZATION (032), so in an organization whose roles were never narrowed, many users are admins and receive the notices.
- **Hash stability (§9.5):** confirm that the first detection runs after deployment raise nothing for unchanged data. If they do, give the 302 typed-detail builder an `ORDER BY`.

### 11.5 First detection run and migration 396
- **First run found real retirements.** The first run (from 395's verification) raised 3 changes, all Retired: statement CH4 (`framework_statement_id` 28, release 6), for organizations 1, 2 and 4. CH4 was already Inactive in `grac_new` before the 391 copy. The old tree query hid it by filtering `fs.status = 'Active'`. The copy kept it Active until a retirement is approved.
- **No false Changed items**, so the hash is stable and 302 needs no `ORDER BY`.
- **"Retired in repository" badge (§4.6) — migration 396 and code:**
  - `sp_resolve_obligation_list` returns `RepositoryLifecycleStatus`. The Resolve workspace card shows the badge.
  - `sp_practice_detail_get` returns it inside `MappedSourceStatementsJson`. Practice View marks the chip.
  - The statement tree returns `LifecycleStatus` and shows the badge. The practice statement picker no longer offers retired statements.
  - The Standards & Frameworks counts exclude retired statements. They stay in the tree.
  - The API reads the new column as optional (`ResolveObligationRow.RepositoryLifecycleStatus`).
