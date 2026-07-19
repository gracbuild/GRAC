# Technical Design Document — GRAC Workflow Layer (Waves 1–5)

**Project:** PracticeManagement (working copy of `gracbuild/GRAC`)
**Author:** Prepared for review by GRAC Builder
**Date:** 2026-07-14
**Charter reference:** `document.txt` (§1–§21), 30 work items across 5 waves
**Status:** DRAFT — pending review and approval. **No code will be written until this TDD and the accompanying wireframes are approved.**

---

## 0. Executive Summary

The current GRAC codebase (this repo) has a rich **content model** — Authority → Artifact → Release → Statement → Practice → Practice Instance → Evidence — implemented across migrations `001`–`034`, 58+ screens registered in `PracticeScreen.All`, an API monolith `PracticeRepositoryService.cs`, and a Web gateway `PracticeManagementGatewayController.cs`. What is largely absent is the **workflow layer**: a generic state-machine framework, a Task engine, ownership-assignment lifecycle, origin-aware permissions, the two-layer Template/Adoption practice model, the Continuous Assurance ticket engine + adapter framework, and the downstream Audit and Risk feeds.

This TDD covers the 30 work items in the charter, mapped to the existing project. It preserves every locked infra decision in §4 of the charter (state-machine framework, snapshot storage, Hangfire, pluggable SaaS/on-prem), respects all §5 non-negotiables, and continues numbering from migration `035_…` onwards (note: current tree already contains `034_simplified_role_model.sql`, so **Wave 1 starts at `035_state_machine_framework.sql`** — the charter's numbering is shifted by one; see §17 Risks).

---

## 1. Existing Modules Requiring Modifications

| # | Module | Location | Reason for change |
|---|---|---|---|
| 1 | **Practice registry** | `grac_practice.practice`, screen `practices` | Split into `practice_template` + `practice_adoption` (§12.2.4). Add `origin_type_id`, wire adoption overlay UI. |
| 2 | **Organization Control** | `grac_practice.organization_control`, screen `organization-controls` | Add `applicability_status_id`, `na_justification`, `na_approver_employee_id`, `na_approved_at`, `na_expiry_date`, `na_reference_url` (§12.2.5). Add derived-status recompute path. |
| 3 | **Ownership columns (denormalised cache)** | `repository_subscription.owner_id`, `custom_release_statement.owner_id` | Retain as cache; authoritative ownership moves to `ownership_assignment` (§12.1.4). Add sync procedure. |
| 4 | **Repository subscription** | `grac_practice.repository_subscription`, screen `repository-subscriptions` | Add `origin_type_id` classification, feed subscription into task-generation for gaps. |
| 5 | **Organization requirement** | `grac_practice.organization_requirement`, screen `organization-requirements` | Point at Adoption overlay instead of raw practice, expose NA workflow, dual status display. |
| 6 | **Practice instance** | `grac_practice.practice_instance`, screen `practice-instances` | Point `adoption_id` FK (replacing direct `practice_id`), add `independently_verified_at`, `assurance_mode`, `assurance_frequency` (some fields exist — augment where needed). |
| 7 | **Custom release statement** | `grac_practice.custom_release_statement` | Add `lifecycle_status_id` for Draft→Active→Deprecated→Retired lifecycle (§12.2.6). Retire endpoint returns 403 for GRAC-origin. |
| 8 | **Assurance generation / activities / execution** | Screens `assurance-generation`, `assurance-activities`, `assurance-execution` | Rewire on top of new `assurance_ticket` entity + snapshots (§12.3.1–§12.3.2). Old "activity" model becomes the manual view over the new ticket. |
| 9 | **Assurance findings** | Screen `assurance-findings` | Restructure to distinguish Assurance Finding vs Auditor Finding (§12.5.4). Chain to Rectification Task. |
| 10 | **Assurance signals** | Screen `assurance-signals` | Wire to new `assurance_signal_publication` table (§12.5.1). Add materiality filter. |
| 11 | **Audit / Risk intelligence** | Screens `audit-intelligence`, `risk-intelligence` | Turn from static views into subscribers of the pub/sub layer. |
| 12 | **PracticeScreen registry** | `src/PracticeManagement.Web/Models/PracticeScreen.cs` | Add new screen keys (11 new — see §2). Every new screen defaults OFF via feature flag. |
| 13 | **Gateway controller** | `PracticeManagementGatewayController.cs` | Add proxy routes for the new API controllers (Task, Assignment, Waiver, Inbox, Auditor, Ownership Tree, KRI, Risk, Adapter). No changes to existing routes. |
| 14 | **Deployment package** | `database/deployment/01–04_*.sql` | Do **not** modify — add new packaged versions numbered higher (§5, §7). Post-deployment verification appends new checks. |
| 15 | **Audit trace** | `practice_audit_trace` (existing) + new `audit_trail` (charter §7) | Reconcile: keep `practice_audit_trace` for legacy entity actions; introduce charter's canonical `audit_trail` for all new mutating procedures (open Q1). |

## 2. New Modules / Screens

### 2.1 New backend modules (Api project, new files — no extension of `PracticeRepositoryService`)
| Module | Files |
|---|---|
| Task Service | `Api/Services/TaskService.cs`, `Api/Controllers/TaskController.cs` |
| Assignment Service | `Api/Services/AssignmentService.cs`, `Api/Controllers/AssignmentController.cs` |
| Waiver Service | `Api/Services/WaiverService.cs`, `Api/Controllers/WaiverController.cs` |
| Permission Service | `Api/Services/PermissionService.cs` |
| SoD Guard Service | `Api/Services/SoDGuardService.cs` |
| Assurance Ticket Service | `Api/Assurance/AssuranceTicketService.cs` |
| Adapter interface + registry | `Api/Assurance/IAssuranceSignalAdapter.cs`, `Api/Assurance/AdapterRegistry.cs`, `Api/Assurance/SignalEvaluator.cs` |
| Reference adapters | `Api/Assurance/Adapters/FilesystemExistenceAdapter.cs`, `Api/Assurance/Adapters/RestPullAdapter.cs` |
| Escalation Service | `Api/Services/EscalationService.cs` |
| Signal Publisher | `Api/Assurance/SignalPublisher.cs` |
| Auditor Service | `Api/Controllers/AuditorController.cs`, `Api/Services/AuditorService.cs` |
| Risk Service | `Api/Controllers/RiskController.cs`, `Api/Services/RiskService.cs` |
| KRI Service | `Api/Controllers/KriController.cs`, `Api/Services/KriService.cs` |
| Ownership Tree | `Api/Controllers/OwnershipTreeController.cs` |
| Inbox | `Api/Controllers/InboxController.cs` |
| Framework Gap Report | `Api/Reporting/FrameworkGapReportService.cs`, `Api/Reporting/Templates/*.docx/xlsx` |
| Secret Provider (seam) | `Api/Infrastructure/Secrets/ISecretProvider.cs` + `AzureKeyVault`, `HashiCorpVault`, `EncryptedDb` impls |
| Notification Transport (seam) | `Api/Infrastructure/Notifications/INotificationTransport.cs` + `SendGrid`, `Ses`, `Smtp` impls |
| Auth Provider (seam) | `Api/Infrastructure/Auth/IAuthProvider.cs` (impls deferred) |
| Hangfire jobs | `Api/Jobs/*.cs` (TaskOverdueSweeper, WaiverExpirySweeper, AssuranceTicketGenerator, EscalationSweeper, NaExpirySweeper, GapDetector) |

### 2.2 New screens (11) — every one added to `PracticeScreen.All`, feature-flagged OFF
| Screen key | Title | Group | From |
|---|---|---|---|
| `tasks` | Task Center | Practice Management | §12.1.3 |
| `waivers` | Waivers & Exceptions | Registers | §12.1.5 |
| `applicability-decision` | Applicability & NA Decisions | Practice Management | §12.2.5 |
| `ownership-tree` | Ownership Tree | Practice Management | §12.4.1 |
| `my-assignments` | My Assignments (Inbox) | Dashboard | §12.4.2 |
| `gap-view` | Gap View | Registers | §12.4.3 |
| `handover` | Handover / Bulk Reassign | Organization Access Administration | §12.4.4 |
| `auditor-workbench` | Auditor Workbench | Assurance Management | §12.5.3 |
| `risk-register` | Risk Register | Registers | §12.5.5 |
| `kri-dashboard` | KRI Dashboard | Dashboard | §12.5.6 |
| `adapter-bindings` | Assurance Adapter Bindings | Assurance Management | §12.3.3 (implicit — needed to configure a per-Instance adapter) |

## 3. Existing Forms Requiring Changes

| Form / Partial | Change |
|---|---|
| `practices.cshtml` (implied) | Template + Adoption side-by-side edit; SOP override input; origin badge; Deny/RequiresApproval banners driven by `fn_can_mutate`. |
| `practice-instances.cshtml` | Adopt `adoption_id` FK; add Assurance Mode selector (Manual / Automatic / Hybrid); Assurance Frequency; two-gate closure banner (ConfigGate/OperationalGate). |
| `organization-controls.cshtml` (Source Statements) | New Applicability workflow modal (NA justification, approver, expiry, reference URL). Dual-status pills (declared vs derived). |
| `organization-requirements.cshtml` | Show adoption overlay data; NA banner + expiry countdown; mismatch flag when `declared_status_id ≠ derived_status_id`. |
| `assurance-execution.cshtml` | Filter tab: Manual vs Automatic. Adapter status widget. Two-status pills (Execution Status × Result Status). |
| `assurance-findings.cshtml` | Split view: Assurance Findings vs Auditor Findings. Rectification Task link. |
| `assurance-signals.cshtml` | Add publish/subscribe columns + materiality tag. |
| `assurance-generation.cshtml` | Wire to `sp_assurance_generate_due_tickets` idempotency indicator; show next Hangfire run. |
| `audit-intelligence.cshtml`, `risk-intelligence.cshtml` | Subscriber-driven data source; add "Signal received at" timestamp. |
| `repository-subscriptions.cshtml` | Add `origin_type_id` column and filter. |
| Login / user profile (implied) | Origin-aware guard messages; Assignment inbox count badge. |

## 4. New Forms / Pages

Every new screen from §2.2 has a new partial at `Web/Views/Practice/Partials/{screen-key}.cshtml`. Detailed wireframes in `Wireframes.html`. Notable multi-step forms:

- **Task detail drawer** — used across Task Center and Inbox. State transitions surfaced as action buttons filtered by `fn_can_mutate`.
- **Assignment acceptance modal** — Accept / Decline / Delegate / Snooze; blocks close of dependent Task until Accepted.
- **Waiver request wizard** — 4 steps: Justification → Scope (entities) → Approver → Expiry & reference URL. All 4 required; blocks submit if any missing.
- **Adapter configuration modal** (`adapter-bindings`) — adapter-type-driven schema; secrets go to `ISecretProvider` (write-once, opaque display).
- **NA decision modal** — justification (mandatory), approver, expiry date (mandatory, ≤ 12 months by default, configurable), reference URL.
- **Handover preview modal** — before/after counts by entity type; irreversible action confirmation.
- **Framework gap report generator** — Framework (ISO 27001 / SOC 2 / HIPAA / DPDP / RBI / NIST) picker, date range, output (PDF / Excel).

## 5. Database Changes

### 5.1 New migrations (Wave 1–5) — continues from `035_…`
Charter says start at `034`, but this repo already has `034_simplified_role_model.sql`. Proposed renumbering **shifts every charter migration by +1** so no existing migration is renamed. Every migration ships with a rollback (`035_rollback.sql`), a smoke test appended to `05_UAT_Setup_Diagnostics.sql`, and — where structural — a data-migration follow-up.

| Charter § | Proposed file | Purpose |
|---|---|---|
| §12.1.1 | `035_state_machine_framework.sql` + `035_state_machine_procs.sql` | `entity_status_master`, `entity_state_transition_log`, `fn_is_transition_allowed`, `sp_state_transition` |
| §12.1.2 | `036_grac_synthetic_principal.sql` (+ seed) | `is_system` column, `GRAC_SYSTEM` employee per org |
| §12.1.3 | `037_task_engine.sql` + `037_task_engine_procs.sql` | `practice_task`, `task_type_master`, `task_status_master`, `sp_task_*` |
| §12.1.4 | `038_assignment_state_machine.sql` + procs | `ownership_assignment`, `assignment_status_master`, `sp_assignment_*` |
| §12.1.5 | `039_waiver_register.sql` + procs | `waiver`, `waiver_status_master`, `sp_waiver_*` |
| §12.1.6 | `040_origin_aware_permissions.sql` | `rbac_rule`, `origin_type_master`, `fn_can_mutate` |
| §12.2.1 | `041_practice_status_dual.sql` | `practice.declared_status_id`, `practice.derived_status_id`, `sp_practice_status_recompute` |
| §12.2.2 | `042_implementation_task_generation.sql` | `sp_gaps_detect_and_open_tasks` (Hangfire hourly) |
| §12.2.3 | `043_two_gate_closure.sql` | intermediate task states + `sp_instance_config_gate_check`, `sp_instance_operational_gate_check` |
| §12.2.4 | `044_template_adoption_model.sql` + `045_template_adoption_data_migration.sql` | Split `practice` → `practice_template` + `practice_adoption`; backfill; retag `practice_instance.adoption_id` |
| §12.2.5 | `046_applicability_workflow.sql` | NA columns on `organization_control` + `practice_adoption` |
| §12.2.6 | `047_retirement_lifecycle.sql` | `lifecycle_status_id` on custom content |
| §12.3.1 | `048_assurance_ticket.sql` | `assurance_ticket`, `assurance_ticket_snapshot`, `sp_assurance_generate_due_tickets` |
| §12.3.2 | `049_assurance_ticket_lifecycle.sql` | 2-status masters + procs |
| §12.3.3 | `050_assurance_adapter_binding.sql` | `assurance_adapter_binding`, `adapter_type_master` |
| §12.3.6 | `051_signal_evaluator_wiring.sql` | `sp_signal_evaluate`, retry/error columns |
| §12.3.7 | `052_fail_chain.sql` | `sp_assurance_finding_open_from_fail` |
| §12.3.8 | `053_escalation_ladder.sql` | `escalation_policy` |
| §12.4.5 | `054_sod_rules.sql` | `sod_rule_master`, `fn_sod_check` |
| §12.5.1 | `055_signal_pubsub.sql` | `assurance_signal_publication`, `signal_subscriber` |
| §12.5.2 | `056_materiality_policy.sql` | per-(criticality, signal_type) |
| §12.5.4 | `057_auditor_finding.sql` | `auditor_finding`, `sp_auditor_finding_*` |
| §12.5.5 | `058_risk_register.sql` | `risk`, `risk_control_mapping`, `sp_risk_score_recompute` |
| §12.5.6 | `059_kri.sql` | `kri_definition`, `kri_value_snapshot` |
| §12.5.9 | `060_metric_views.sql` | Coverage %, on-time %, evidence completeness, pass rate views |
| Cross-cut | `061_feature_flag.sql` | `feature_flag` (org-scoped), UI probe endpoint |
| Cross-cut | `062_audit_trail.sql` | Canonical `audit_trail` per §7 (reconciles with existing `practice_audit_trace`) |

### 5.2 Table alterations (summary)
- `organization_control` +6 cols (NA workflow) — §12.2.5
- `custom_release_statement` +1 col (lifecycle_status_id) — §12.2.6
- `practice_instance` — replace `practice_id` FK with `adoption_id` FK **without dropping** `practice_id` (kept as denormalised cache until data migration proves stable); add `assurance_mode_id`, `assurance_frequency_id`, `independently_verified_at`
- `practice` — add `declared_status_id`, `derived_status_id`, `origin_type_id`
- `organization_employee` +1 col (`is_system` BIT)
- `repository_subscription` +1 col (`origin_type_id`)
- All new stateful tables get `current_status_id` (never enum in code).

### 5.3 Indexes (following `029_performance_indexes.sql` conventions)
- `ix_practice_task_assignee_status(assigned_to_employee_id, current_status_id) INCLUDE (sla_due_at)`
- `ix_ownership_assignment_entity(entity_type, entity_id, current_status_id)`
- `ix_assurance_ticket_owner_due(owner_employee_id, due_at) INCLUDE (execution_status_id, result_status_id)`
- `ix_assurance_ticket_instance_period(instance_id, period_from, period_to)` UNIQUE (idempotency)
- `ix_signal_pub_entity_severity(entity_type, entity_id, severity_id)`
- `ix_waiver_expiry(expiry_date) WHERE current_status_id IN (Approved, Active)`
- All numeric on org-scoped queries include `organization_id` as leading column.

### 5.4 Stored procedures (all in new files — never appended to `02_Create_Procedures.sql`)
- `sp_state_transition`, `sp_task_open`, `sp_task_assign`, `sp_task_transition`, `sp_task_close`, `sp_assignment_nominate`, `sp_assignment_accept`, `sp_waiver_request`, `sp_waiver_approve`, `sp_waiver_expire_sweep`, `sp_practice_status_recompute`, `sp_gaps_detect_and_open_tasks`, `sp_instance_config_gate_check`, `sp_instance_operational_gate_check`, `sp_assurance_generate_due_tickets`, `sp_assurance_ticket_transition`, `sp_signal_evaluate`, `sp_assurance_finding_open_from_fail`, `sp_escalation_sweep`, `sp_bulk_reassign`, `sp_signal_publish`, `sp_auditor_finding_*`, `sp_risk_score_recompute`, `sp_kri_evaluate`, `sp_na_expiry_sweep`.
- Every mutating procedure writes to `audit_trail`.
- Every scheduler proc is idempotent (guard by `(subject, period)` unique).

## 6. API Changes

### 6.1 New API endpoints (base `/api/practice/…`)
| Route | Method | Purpose |
|---|---|---|
| `/api/practice/tasks` | GET, POST | List / open a task |
| `/api/practice/tasks/{id}/transition` | POST | State transition (checked by guard) |
| `/api/practice/tasks/{id}/close` | POST | Close (blocks unless two gates green for Implementation) |
| `/api/practice/assignments` | GET, POST | List / nominate |
| `/api/practice/assignments/{id}/accept` | POST | Accept |
| `/api/practice/assignments/{id}/decline` | POST | Decline |
| `/api/practice/assignments/{id}/delegate` | POST | Delegate |
| `/api/practice/assignments/bulk-reassign` | POST | Handover preview + commit |
| `/api/practice/waivers` | GET, POST | List / request |
| `/api/practice/waivers/{id}/approve` | POST | Approve |
| `/api/practice/waivers/{id}/withdraw` | POST | Withdraw |
| `/api/practice/permissions/probe` | POST | UI permission probe (returns Allow / Deny / RequiresApproval) |
| `/api/practice/applicability/{controlId}/mark-na` | POST | Mark control NA |
| `/api/practice/applicability/{controlId}/reverify` | POST | Manual reverify |
| `/api/practice/ownership-tree` | GET | Lazy-loading JSON tree |
| `/api/practice/inbox` | GET | Merged inbox (assignments + tasks + findings + upcoming) |
| `/api/practice/gap-view` | GET | Saved-filter queries |
| `/api/practice/assurance/tickets` | GET | List with two-status filter |
| `/api/practice/assurance/tickets/{id}` | GET | Detail incl. snapshot |
| `/api/practice/assurance/tickets/{id}/evidence` | POST | Attach evidence (manual path) |
| `/api/practice/assurance/tickets/{id}/execute` | POST | Trigger automatic run |
| `/api/practice/assurance/adapters` | GET | List available adapter types |
| `/api/practice/assurance/bindings` | GET, POST, PUT | Adapter binding CRUD |
| `/api/practice/auditor/workbench` | GET | Auditor filter grid |
| `/api/practice/auditor/findings` | GET, POST, PUT | Finding CRUD (workflow-guarded) |
| `/api/practice/risk` | GET, POST, PUT | Risk register CRUD |
| `/api/practice/risk/{id}/accept` | POST | Risk acceptance → creates Waiver |
| `/api/practice/kri` | GET | KRI list w/ live values |
| `/api/practice/kri/{id}/threshold` | POST | Threshold update |
| `/api/practice/reports/framework-gap` | POST | Generate PDF + Excel |
| `/api/practice/feature-flags` | GET | Client bootstrap probe |

### 6.2 Existing API endpoints modified
- Gateway `PracticeManagementGatewayController` adds proxy routes for every new endpoint above (`practice-management-gateway/{feature}/…`). Existing `{entityType}` fan-out is untouched.
- `Api/Controllers/PracticeRepositoryController.cs::secure/manage` gains no new payloads — new services own their own controllers (charter §5: do not extend the monolith).

## 7. Backend Service Changes

- **`PracticeRepositoryService`**: unchanged. Reads only.
- **New services** listed in §2.1 — each is a thin façade over `Dapper` calls to new stored procedures, with permission-probe up front and audit-log emission on write.
- **Hangfire** wired at `Program.cs` (config-only change requested explicitly). Jobs registered by `Api/Jobs/JobRegistrar.cs`; dashboard route `/hangfire` guarded by Admin role.
- **Pluggable seams** (`ISecretProvider`, `INotificationTransport`, `IAuthProvider`) registered in DI via `Api/Infrastructure/InfrastructureRegistration.cs`. Implementation selected by env var (`SecretProvider__Type` etc.).
- **`SignalPublisher`** is called from every terminal state transition on `assurance_ticket`, `auditor_finding`, `risk`, and `assurance_finding`. Subscribers ("Audit", "Risk") are seeded rows in `signal_subscriber` — pure DB pattern for now.

## 8. Frontend / UI Changes

- **Layout host `Manage.cshtml`** — no structural change. It already renders any `PracticeScreen` by key + partial.
- **New partials** (11) under `Views/Practice/Partials/`. Each partial uses:
  - Bootstrap 5 + FontAwesome icons matching existing convention (see §2.2 icon column pattern in `PracticeScreen.cs`).
  - A shared JS helper (`site/js/practice-workflow.js`, new) that fires `/api/practice/permissions/probe` on load and toggles action buttons.
- **Existing partials modified** per §3. Every change is additive (new tabs, new columns, new banners) — no removed fields.
- **Feature-flag gate** — a JS check at partial render blocks the partial with a message when `feature_flag.<screen-key>` is OFF (charter §7).
- **Inbox badge in header** — new component surfacing count from `/api/practice/inbox`.
- **State transition indicators** — colored pills bound to `entity_status_master.status_code` (never hard-coded).

## 9. Navigation / Menu Changes

- Existing group taxonomy in `PracticeScreen.cs` extended, no renames:
  - `Dashboard`: add `my-assignments`, `kri-dashboard`.
  - `Practice Management`: add `tasks`, `applicability-decision`, `ownership-tree`.
  - `Registers`: add `waivers`, `gap-view`, `risk-register`.
  - `Assurance Management`: add `auditor-workbench`, `adapter-bindings`.
  - `Organization Access Administration`: add `handover`.
- `menu_master` seeded via new master-data script `master-data/menu_workflow_seed.sql`.
- `organization_role_menu_permission` extended with rows for each new screen for **Admin only** by default; other roles inherit via §12.1.6 RBAC matrix (`rbac_rule`).

## 10. User Roles and Permission Changes

- **Roles** (existing + new logical roles surfaced via `data_scope`): GRAC Admin (GLOBAL, internal only), Organization Admin (ORGANIZATION), Release Owner (RELEASE), Control Owner (STATEMENT), Practice Owner (PRACTICE), Instance Owner (INSTANCE), Assurance Owner (INSTANCE + SoD), Auditor (STATEMENT read + Finding write), Risk Owner (ORGANIZATION), `GRAC_SYSTEM` (synthetic).
- **Permission model** = Role × Scope × Origin (§14 of charter). Encoded in `rbac_rule`; evaluated by `fn_can_mutate(entity_type, entity_id, actor_employee_id, action) → Allowed / Denied / RequiresApproval`.
- **Existing `data_scope` column** (from migration 032) is reused verbatim.
- **Existing `owner_id`** columns become denormalised caches (§12.1.4 coexistence rule). Documented in new file `docs/coexistence.md`.
- **`GRAC_SYSTEM` guardrail** — never selectable in owner pickers; UI hides; DB reject-trigger on `ownership_assignment.assignee_employee_id = GRAC_SYSTEM` unless `role_scope = 'AUTOMATIC_TICKET'`.

## 11. Workflow Changes

### 11.1 New workflows
1. **Task lifecycle** — Open → Assigned → InProgress → PendingReview → Closed; branches Cancelled / Escalated.
2. **Assignment lifecycle** — Nominated → Notified → Accepted → Active; branches Declined / Delegated / Reassigned / Vacated. Every ownership set triggers an `AssignmentPending` Task.
3. **Waiver lifecycle** — Draft → Requested → Approved → Active → Expired / Withdrawn.
4. **Assurance Ticket (Manual)** — Generated → Notified → Acknowledged → InProgress → EvidenceAttached → Reviewed → Closed.
5. **Assurance Ticket (Automatic)** — Generated → GRACInProgress → SignalFetch → SignalEvaluated → Closed.
6. **Two-gate closure for Implementation Task** — intermediate states `ConfigGatePassed`, `AwaitingFirstExecution`, `OperationalGatePassed`, then Closed.
7. **Retirement (Custom only)** — Draft → Active → Deprecated → Retired.
8. **NA workflow** — Set NA → Approval Task to Release Owner → Approved → Reverify sweeper 30 days before expiry opens a Reverification Task.
9. **Fail chain** — Automatic/Manual Ticket Result=Fail → Assurance Finding opens → Rectification Task opens → both must close AND next cycle passes to close Finding.
10. **Escalation ladder** — SLA nudge → 1.5× SLA escalate to Practice Owner → 2× SLA escalate to Control Owner.

### 11.2 Modified workflows
- **Applicability** (existing simple flag) becomes a full workflow (§12.2.5).
- **Assurance execution** — new dual-status; retains legacy `assurance-activities` list but underlying data is `assurance_ticket`.
- **Ownership set** on any entity now emits an Assignment row + Task instead of writing directly to `owner_id`.

## 12. State Transition Changes

- All new stateful entities use `{entity}_status_master` + `{entity}.current_status_id` + `{entity}_state_transition_log` (§4.1, §7).
- Guard function `fn_is_transition_allowed(entity_type, from_state, to_state, actor_role) → bit` is the single source of truth. UI never encodes transitions.
- Every transition writes a row to `entity_state_transition_log` with `actor_employee_id`, `at`, `reason_code`, `reason_text`.
- Illegal transitions raise SQL error → API returns 409 Conflict with `reason_code`.
- Snapshotting hooks at: Assurance Ticket generation, Applicability decision, Ownership assignment, Retirement.

## 13. Scheduler / Hangfire Changes

- **New Hangfire instance** in Api project (charter §4.3). Persistence in SQL (`hangfire.*` schema — separate from `grac_practice`).
- **Recurring jobs** (all idempotent):
  | Job | Cron | Purpose |
  |---|---|---|
  | `task-overdue-sweeper` | `0 * * * *` (hourly) | SLA breach → escalate Task |
  | `waiver-expiry-sweeper` | `0 6 * * *` (daily 06:00) | Expire waivers, open Reverification Tasks |
  | `assurance-ticket-generator` | `5 * * * *` (hourly at :05) | `sp_assurance_generate_due_tickets` |
  | `escalation-sweeper` | `10 * * * *` (hourly) | Nudge/escalate assurance tickets & findings |
  | `na-expiry-sweeper` | `15 6 * * *` (daily) | Reverify 30 days before NA expiry |
  | `gap-detector` | `30 * * * *` (hourly) | `sp_gaps_detect_and_open_tasks` |
  | `signal-digest-publisher` | `0 8 * * *` (daily) | Batches digest-class signals |
  | `kri-evaluator` | `0 */4 * * *` (every 4 hours) | Recompute KRI values |
- **Dashboard** at `/hangfire`, protected by Admin role (charter §4.3).
- **On-prem / air-gapped safety** — no external calls at startup (charter §4).

## 14. Integration Points

- **`gracbuild/GRAC-ADMIN`** — this repo *consumes* releases published there (read-only). No new integration — existing release ingestion continues.
- **Assurance Adapter framework** (`IAssuranceSignalAdapter`) — pluggable, one adapter per external signal source. Reference adapters:
  - Filesystem/SharePoint existence check (§12.3.4)
  - REST Pull (§12.3.5)
  - (Future) Cloud CSPM, SIEM, Ticketing, ITSM, etc. — deferred.
- **`ISecretProvider`** — Azure Key Vault / HashiCorp Vault / EncryptedDb. Selection via `SecretProvider__Type`.
- **`INotificationTransport`** — SendGrid / SES / SMTP. Selection via `NotificationTransport__Type`.
- **`IAuthProvider`** — implementations deferred; interface defined so Program.cs need not change later.
- **Report exports** — PDF via DinkToPdf (already in tree? verify — open Q4) or built-in HTML→PDF; Excel via ClosedXML (verify).

## 15. Impact Analysis

| Existing area | Impact | Mitigation |
|---|---|---|
| `PracticeRepositoryService` monolith | None (do not extend). New logic in new services. | Guardrail: PR review rejects any diff hunk in this file that isn't a comment or bugfix. |
| `02_Create_Procedures.sql` | None (do not extend). New procs in per-feature files. | Same guardrail. |
| Existing `practice` table | Structural change (adoption FK on instance). Data migration `045`. | Backfill preserves current instance → practice mapping; `practice_id` retained as cache; rollback restores. |
| `organization_control` | Additive columns only. | No default value changes; existing rows untouched. |
| `assurance-*` screens | UI adds tabs/columns. | All additive; feature flag lets us dark-ship. |
| `PracticeScreen.All` | 11 new keys, ordering preserved. | Every new key defaults OFF. |
| Existing `menu_master` / `role_menu_permission` | New rows only. | No renames, no deletes. |
| Existing tests | Should continue to pass. | Charter §11 rejects breaks; CI gate. |

## 16. Dependency Analysis Between Modules

Directed acyclic graph of work items (arrows = "depends on"):

```
§12.1.1 State-machine framework  ─┬─▶ §12.1.3 Task engine ─┬─▶ §12.1.4 Assignment ─┬─▶ §12.4.1 Ownership Tree
                                  │                        │                        │
                                  │                        │                        ├─▶ §12.4.2 Inbox
                                  │                        │                        ├─▶ §12.4.4 Handover
                                  │                        │                        └─▶ §12.4.5 SoD
                                  │                        │
                                  │                        ├─▶ §12.1.5 Waiver ──────▶ §12.5.7 Loop-back
                                  │                        ├─▶ §12.2.1 Dual status
                                  │                        ├─▶ §12.2.2 Gap tasks ──▶ §12.2.3 Two-gate closure
                                  │                        └─▶ §12.2.5 NA workflow
                                  │
                                  ├─▶ §12.3.1 Assurance Ticket + snapshot
                                  │       └─▶ §12.3.2 Two-status ──▶ §12.3.3 Adapter iface
                                  │                                 ├─▶ §12.3.4 FS adapter
                                  │                                 ├─▶ §12.3.5 REST adapter
                                  │                                 └─▶ §12.3.6 Error handling
                                  │                                          └─▶ §12.3.7 Fail chain ──▶ §12.3.8 Escalation
                                  │
§12.1.2 GRAC_SYSTEM ──────────────┘
§12.1.6 Origin-aware permissions ──▶ §12.2.4 Template/Adoption ──▶ §12.2.6 Retirement
                                                                     └─▶ Rest of Wave 2/3/4/5

§12.5.1 pub/sub ─▶ §12.5.2 Materiality
                  ├─▶ §12.5.3 Auditor Workbench ─▶ §12.5.4 Auditor Finding
                  ├─▶ §12.5.5 Risk Register ─▶ §12.5.6 KRI
                  └─▶ §12.5.8 Framework Gap report
§12.5.9 Metric views can start any time after §12.3.2
```

## 17. Risks and Assumptions

### 17.1 Risks
| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Migration numbering already used `034` — charter's numbers collide | Certain | Medium (procedural) | Shift charter's proposed numbers by +1 starting `035_state_machine_framework.sql`. Confirmed with §17.4 assumption. |
| R2 | Template/Adoption data migration is destructive if reverted | Medium | High | Data-migration migration `045` keeps `practice.practice_id` as cache column; rollback repopulates from cache. |
| R3 | Two-gate closure blocks legitimate closes if evidence config lags | Medium | Medium | Feature flag ON per-org gradually; provide `sp_two_gate_bypass_with_reason` for GRAC Admin only, fully audited. |
| R4 | Hangfire dashboard exposure risk | Low | Medium | Route protected by Admin role attribute; `[Authorize(Roles="Admin")]` on `MapHangfireDashboard` middleware. |
| R5 | Adapter secrets leak | Low | Critical | `secret_ref` only; UI opaque; `ISecretProvider` write-through; log redaction. |
| R6 | Signal publisher storm during large fail batches | Medium | High | Materiality policy defaults to `Digest`; publisher batches with `sp_signal_publish_batch`. |
| R7 | `GRAC_SYSTEM` accidentally selected as human owner | Low | High | UI filter + DB reject trigger + PermissionService guard. |
| R8 | Idempotency regressions in schedulers | Medium | High | Per-job unique key indexes (`(subject_entity_id, period)`), integration test asserts second run inserts 0 rows. |
| R9 | On-prem SQL Server older than 2019 (JSON support) | Low | Medium | Guard `OPENJSON`/`JSON_VALUE` usage; smoke test in `05_UAT_Setup_Diagnostics.sql`. |
| R10 | Existing screens/tests break under RBAC changes | Medium | Medium | RBAC defaults preserve current behavior — new checks only tighten for new actions. |

### 17.2 Assumptions
- A1: Migration renumbering (+1 offset) is acceptable — this needs product-owner sign-off (see Q1).
- A2: Existing `practice_audit_trace` will coexist with new charter `audit_trail`. New procedures write to both during a transition period; deprecation of the former is out of scope.
- A3: Hangfire NuGet packages will be added — this is a *new* NuGet dependency, so charter §5 says stop and ask. See Q2.
- A4: DinkToPdf / ClosedXML for reports — new NuGet packages; see Q3.
- A5: The `GRAC_SYSTEM` synthetic principal is one row per org (not one global row) — matches §12.1.2 wording.
- A6: `IAuthProvider` implementations are not part of this scope; interface only. Existing local auth continues to work.
- A7: `practice_instance.practice_id` is retained as a cache column when we introduce `adoption_id`. Not dropped in the same PR.
- A8: The 11 new screens are wired to `PracticeScreen.All` but every one defaults OFF via feature flag; nothing appears in menu until enabled.
- A9: SoD rules seed uses two starter rules only ("Practice Owner ≠ Instance Owner for Critical", "Preparer ≠ Reviewer") — full catalog is a follow-up.
- A10: The Web project remains ASP.NET MVC; no SPA introduction.

## 18. Questions / Ambiguities Requiring Clarification

*(Will be moved to `docs/QUESTIONS.md` in the format required by charter §19.)*

| # | Question | Options | Recommendation |
|---|---|---|---|
| **Q1** | Charter §3 says migration numbering "continues from `034_`" but this repo already has `034_simplified_role_model.sql`. Renumber charter targets to start at `035_`? | (a) Start at `035_` (this TDD's plan). (b) Insert new migrations as `034a_…`. (c) Rename existing `034_` (violates §5 non-negotiable). | **(a)** — cleanest and honors §5's "no renumber existing". |
| **Q2** | Hangfire is a new NuGet package. Charter §5 requires explicit approval. Proceed? | (a) Approve Hangfire (`Hangfire.AspNetCore`, `Hangfire.SqlServer`). (b) Use built-in `IHostedService` + `System.Threading.Channels`. | **(a)** — charter §4.3 locks Hangfire as the scheduler. Formal approval requested. |
| **Q3** | Report generation (PDF+Excel) needs libraries. | (a) DinkToPdf + ClosedXML. (b) QuestPDF + EPPlus. (c) Server-side headless Chromium. | **(a)** — LGPL/permissive, on-prem friendly. Approval requested. |
| **Q4** | Charter §7 introduces `audit_trail` as the canonical audit log, but codebase already has `practice_audit_trace`. Coexist or replace? | (a) Coexist; new procs write to both. (b) Replace `practice_audit_trace` (violates §5). (c) Alias `practice_audit_trace` as a view over `audit_trail`. | **(a)** — safest; can revisit in a follow-up. |
| **Q5** | Project instructions call this project the "primary working copy" but charter §2 says `gracbuild/PracticeManagement` is "older scaffolding, read-only reference" and `gracbuild/GRAC` is the target. Which is authoritative? | (a) Trust project instructions — treat this repo as GRAC. (b) Do nothing until confirmed. | **(a)** — the project instructions from the user explicitly designate this as source of truth. Confirm before code. |
| **Q6** | Feature flag scope — org-only or org+user? | (a) Org-only. (b) Org + user override. | **(a)** — matches "org-scoped" in charter §7. |
| **Q7** | Should the Web `PracticeManagementGatewayController` add explicit routes per new controller or continue the `{entityType}` fan-out? | (a) Explicit routes per feature (verbose but auditable). (b) Extend fan-out (denser). | **(a)** — matches charter §7 API-route convention `/api/practice/{feature}/{action}`. |
| **Q8** | Default NA expiry maximum — 6 or 12 months? | (a) 6 months. (b) 12 months. (c) Configurable per org (default 12). | **(c)** — least surprising. |
| **Q9** | Should we snapshot the entire `practice_adoption` at Assurance Ticket generation or only the fields the adapter needs? | (a) Full JSON. (b) Selected fields. | **(a)** — charter §7 says "immutable" and "criteria_json / evidence_template_json / adapter_config_json / owner_snapshot_json" — matches (a). |
| **Q10** | Escalation SLA multipliers hard-coded at 1.5× and 2× or configurable? | (a) Hard-coded per charter §12.3.8. (b) Configurable per criticality. | **(b)** — configurable in `escalation_policy` table (still defaulted to 1.5×/2×). |
| **Q11** | Bulk reassignment audit — one audit row per moved assignment, or one summary row? | (a) One row per assignment. (b) One summary row + child rows. | **(a)** — grep-ability wins. |
| **Q12** | Two-gate closure — is `sp_two_gate_bypass_with_reason` acceptable as an escape hatch? | (a) Yes, GRAC Admin only, fully audited. (b) No — never bypass. | **(a)** — for stuck-instance recovery only. |

## 19. Per-Requirement Traceability Matrix

*(One row per work item — Requirement / Existing / Gap / Proposed / Files / Effort. Sizes S ≤ 2 d, M 3–7 d, L > 1 wk, from charter §12.)*

### Wave 1 — Foundation
| § | Requirement | Existing | Gap | Proposed | Files (proposed) | Effort |
|---|---|---|---|---|---|---|
| 12.1.1 | Generic state-machine framework | Ad-hoc `status` columns; `record_status_master` only | No generic transition guard, no log table | Add `entity_status_master`, `entity_state_transition_log`, `fn_is_transition_allowed`, `sp_state_transition` | `035_state_machine_framework.sql`, `035_state_machine_procs.sql` | M |
| 12.1.2 | GRAC_SYSTEM synthetic principal | `organization_employee` table exists | No `is_system` flag, no per-org synthetic row | Add `is_system` col, seed `GRAC_SYSTEM` per org, UI filter, reject-trigger | `036_grac_synthetic_principal.sql`, seed extension | S |
| 12.1.3 | Task engine | No task table | Absent | `practice_task`, task type/status masters, sp_task_*, TaskController on Api+Web, `tasks` screen, Hangfire overdue sweeper | `037_task_engine.sql` + procs, `Api/Services/TaskService.cs`, `Api/Controllers/TaskController.cs`, `Web/Controllers/TaskController.cs`, `Views/Practice/Partials/tasks.cshtml` | L |
| 12.1.4 | Assignment state machine | `owner_id` on subscription + statement (denorm) | No assignment lifecycle, no acceptance step | `ownership_assignment` + procs; keep `owner_id` as cache; `AssignmentController`; auto-`AssignmentPending` task | `038_assignment_state_machine.sql`, `Api/Services/AssignmentService.cs`, `Api/Controllers/AssignmentController.cs`, `docs/coexistence.md` | M |
| 12.1.5 | Waiver / Exception register | No waiver table | Absent | `waiver` + procs; expiry sweeper; screen | `039_waiver_register.sql`, `Api/Services/WaiverService.cs`, `Api/Controllers/WaiverController.cs`, `Views/.../waivers.cshtml` | M |
| 12.1.6 | Origin-aware permission guards | `data_scope` on `organization_role` (from 032/034) | No `rbac_rule`, no `fn_can_mutate`, no `origin_type` | Add `rbac_rule`, `origin_type_master`, `fn_can_mutate`, PermissionService, probe endpoint | `040_origin_aware_permissions.sql`, `Api/Services/PermissionService.cs` | M |

### Wave 2 — Practice Implementation & Closure
| § | Requirement | Existing | Gap | Proposed | Files | Effort |
|---|---|---|---|---|---|---|
| 12.2.1 | Dual-status (declared × derived) | Single `implementation_status_id` on `practice` (implicit) | Only one status | Add both, mismatch → Rectification Task | `041_practice_status_dual.sql` | M |
| 12.2.2 | Gap detector → Implementation Task | None | Missing Instance not surfaced as work | `sp_gaps_detect_and_open_tasks`, hourly Hangfire | `042_implementation_task_generation.sql` | M |
| 12.2.3 | Two-gate closure | `sp_task_close` doesn't exist | No gate concept | Add intermediate task states, `sp_instance_config_gate_check`, `sp_instance_operational_gate_check`, close guard | `043_two_gate_closure.sql` | M |
| 12.2.4 | Template + Adoption two-layer | Single `practice` table | Direct-editable GRAC-origin practices | Split into `practice_template` + `practice_adoption`; retag instance FK | `044_template_adoption_model.sql`, `045_template_adoption_data_migration.sql`, adjust `practices` + `organization-requirements` screens | L |
| 12.2.5 | Applicability workflow with NA | Only `applicability_status_master` values | No NA justification/approver/expiry | Add 6 NA cols on `organization_control` & `practice_adoption`; sweeper for reverify | `046_applicability_workflow.sql`, `Views/.../applicability-decision.cshtml` | M |
| 12.2.6 | Retirement lifecycle (Custom only) | No lifecycle status | Custom deleted directly (violation) | `lifecycle_status_id` on custom entities; retire endpoint 403 for GRAC-origin | `047_retirement_lifecycle.sql` | M |

### Wave 3 — Continuous Assurance
| § | Requirement | Existing | Gap | Proposed | Files | Effort |
|---|---|---|---|---|---|---|
| 12.3.1 | Assurance Ticket entity + generator + snapshot | Existing `assurance-activities` list ≈ manual placeholder | No snapshot, no idempotent generation, no owner logic | `assurance_ticket` + immutable `assurance_ticket_snapshot`; `sp_assurance_generate_due_tickets` hourly | `048_assurance_ticket.sql` | L |
| 12.3.2 | Two-status ticket lifecycle | Existing "activity status" single-dim | No orthogonal Execution / Result | Add both statuses w/ own masters, Manual & Automatic paths | `049_assurance_ticket_lifecycle.sql` | M |
| 12.3.3 | Adapter interface + registry | None | Absent | `IAssuranceSignalAdapter`, `AdapterRegistry`, `assurance_adapter_binding` table | `Api/Assurance/*`, `050_assurance_adapter_binding.sql` | M |
| 12.3.4 | Filesystem adapter | None | Absent | Reference implementation | `Api/Assurance/Adapters/FilesystemExistenceAdapter.cs` | S |
| 12.3.5 | REST Pull adapter | None | Absent | Reference implementation | `Api/Assurance/Adapters/RestPullAdapter.cs` | M |
| 12.3.6 | No-signal / adapter-error handling | None | Silent failures possible | `SignalEvaluator` + procs for AdapterError / Empty / Ambiguous | `051_signal_evaluator_wiring.sql`, `Api/Assurance/SignalEvaluator.cs` | M |
| 12.3.7 | Fail → Finding → Rectification chain | None | Absent | `sp_assurance_finding_open_from_fail` + close guard | `052_fail_chain.sql` | M |
| 12.3.8 | Escalation ladder | None | Absent | `escalation_policy`, hourly sweeper | `053_escalation_ladder.sql` | S |

### Wave 4 — Views & Workflows
| § | Requirement | Existing | Gap | Proposed | Files | Effort |
|---|---|---|---|---|---|---|
| 12.4.1 | Ownership Tree screen | None | Absent | Lazy-load JSON tree of Release→Control→Practice→Instance with owners | `Api/Controllers/OwnershipTreeController.cs`, `Views/.../ownership-tree.cshtml` | M |
| 12.4.2 | My Assignments Inbox | None | Absent | `/api/practice/inbox` merges pending, tasks, findings, upcoming | `Api/Controllers/InboxController.cs`, `Views/.../my-assignments.cshtml` | M |
| 12.4.3 | Gap View | None | Absent | Saved-filter grid | `Views/.../gap-view.cshtml` (thin over existing services) | S |
| 12.4.4 | Handover / bulk reassignment | None | Absent | Preview + `sp_bulk_reassign` | `Views/.../handover.cshtml`, proc | S |
| 12.4.5 | SoD guardrails | None | Absent | `sod_rule_master`, `SoDGuardService`, "Allow/Warn/Block" | `054_sod_rules.sql`, `Api/Services/SoDGuardService.cs` | S |

### Wave 5 — Audit & Risk downstream
| § | Requirement | Existing | Gap | Proposed | Files | Effort |
|---|---|---|---|---|---|---|
| 12.5.1 | Signal pub/sub layer | None | Absent | `assurance_signal_publication` + subscribers | `055_signal_pubsub.sql`, `Api/Assurance/SignalPublisher.cs` | M |
| 12.5.2 | Materiality policy | None | Absent | Per (criticality, signal_type) → Immediate/Digest/Suppress | `056_materiality_policy.sql` | S |
| 12.5.3 | Auditor Workbench | None | Absent | Filter grid with sampling | `Api/Controllers/AuditorController.cs`, partial | M |
| 12.5.4 | Auditor Finding entity | Existing `assurance_findings` screen — different concept | Absent as a distinct entity | `auditor_finding` + workflow, feeds Rectification Task | `057_auditor_finding.sql` | M |
| 12.5.5 | Risk Register + mapping | None | Absent | `risk`, `risk_control_mapping`, `sp_risk_score_recompute` | `058_risk_register.sql`, `Views/.../risk-register.cshtml` | M |
| 12.5.6 | KRI Dashboard | None | Absent | `kri_definition`, `kri-dashboard` screen, breach → RiskDriven Task | `059_kri.sql`, partial | M |
| 12.5.7 | Bidirectional loop-back | Partial (§12.5.4 covers half) | Absent | Risk Acceptance → Waiver; Risk criticality up → Reverification | New procs across feature-scoped files | M |
| 12.5.8 | Framework gap report generator | None | Absent | ISO 27001 / SOC 2 / HIPAA PDF + Excel | `Api/Reporting/FrameworkGapReportService.cs`, templates | M |
| 12.5.9 | Metric definitions + rollup views | None | Absent | Views: coverage %, on-time %, evidence completeness, pass rate, auto vs manual | `060_metric_views.sql`, `docs/metric-definitions.md` | S |

**Total estimated effort:** ~110 dev-days across the 30 work items (roughly S×8 + M×18 + L×4). Waves 1 and 3 are the largest; Waves 4 and 5 depend on Waves 1–3.

---

## 20. Cross-Cutting Deliverables per Work Item (§9 of charter)

Every PR includes: migration + rollback, procs in a *new* file (never appended to `02_Create_Procedures.sql`), audit trail on every mutating proc, idempotency proof for schedulers, unit tests for state transitions and permission guards, one integration test, feature flag default OFF, docs stub in `/docs/`, backfill migration where structural, smoke test appended to `05_UAT_Setup_Diagnostics.sql`.

---

## 21. Not-in-Scope (explicitly deferred)

- Additional adapter implementations beyond the two reference adapters (§12.3.4, §12.3.5).
- SSO / SAML / LDAP `IAuthProvider` implementations — interface only.
- Real-time notification transports beyond email — SMS/webhook/Slack deferred.
- Reporting beyond Framework Gap — dashboard exports, audit binders → later.
- BIA / BCP / DR modules — outside charter.
- Multi-language UI — not in charter.

---

## 22. Sign-off Gate

**No code will be written until this TDD and the accompanying wireframes are reviewed and approved.** Please review §17 Risks, §18 Questions (especially Q1, Q2, Q3, Q5 which block Wave 1), and confirm the migration renumbering plan. On approval, execution begins per charter §21 Quick Start: §12.1.1 and §12.1.6 in parallel.
