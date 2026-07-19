# Task engine — developer notes

**Charter reference:** §12.1.3 (work item), §13.1 (`practice_task` shape)
**Migrations:** `037_task_engine.sql`, `037_task_engine_procs.sql`, `037_task_engine_rollback.sql`, `041_feature_flag.sql`
**Smoke test:** `database/deployment/08_UAT_Diagnostics_TaskEngine.sql`
**Backend:** `Api/Services/TaskService.cs`, `Api/Controllers/TaskController.cs`, `Api/Models/TaskModels.cs`, `Api/Infrastructure/TaskServiceRegistration.cs`
**Web:** `Web/Controllers/TaskController.cs`, `Web/Views/Practice/Partials/tasks.cshtml`, screen registered in `PracticeScreen.All`

---

## Scope

One canonical `practice_task` entity backs every workflow trigger in Waves 1–5. Task types (from `task_type_master`): `Implementation`, `Rectification`, `Change`, `Waiver`, `Reverification`, `AssignmentPending`, `AuditDriven`, `RiskDriven`.

## Lifecycle

```
Open ─▶ Assigned ─▶ InProgress ─▶ PendingReview ─▶ Closed
                       │              │              │
                       ▼              ▼              ▼
                   Cancelled     Escalated       Reopened (Admin only)

Implementation-Task extension (§12.2.3, two-gate closure):
InProgress ─▶ ConfigGatePassed ─▶ AwaitingFirstExecution ─▶ OperationalGatePassed ─▶ Closed
```

Legality of every arrow is data-driven — see `entity_state_transition_rule` seeded in `035_state_machine_framework.sql`.

## Idempotency

- **Implementation tasks** use a filtered unique index `ux_pm_practice_task_impl_dedup` on `(subject_entity_type, subject_entity_id)` where `closed_at IS NULL`. `sp_task_open` detects a duplicate and returns the existing `task_id` instead of throwing.
- **`sp_task_overdue_sweep`** is idempotent by construction — only tasks with `escalated_at IS NULL` are picked up; second runs move zero rows.

## Two-gate closure

`sp_task_close` blocks closure of Implementation tasks whose status is not `OperationalGatePassed` or `PendingReview`. Full gate procedures (`sp_instance_config_gate_check`, `sp_instance_operational_gate_check`) land in migration `043` alongside §12.2.3.

## Audit trail

Every mutating procedure writes to `practice_audit_trace` via the framework proc `sp_pm_state_transition`. Silent failures forbidden (charter §11) — the overdue sweeper's TRY/CATCH also writes to `practice_audit_trace` with `action_type = 'SWEEP_ERROR'` when an individual task fails so the batch does not cascade.

## API

Base route: `/api/practice/tasks` (charter §7 convention). All endpoints are stateless.

| Verb | Path | Purpose |
|---|---|---|
| GET  | `/api/practice/tasks` | List (paged) |
| POST | `/api/practice/tasks` | Open |
| POST | `/api/practice/tasks/{id}/assign` | Reassign |
| POST | `/api/practice/tasks/{id}/transition` | State change (409 on illegal) |
| POST | `/api/practice/tasks/{id}/close` | Close (409 on two-gate not passed) |

**Error mapping:**

| SQL error | Reason code | HTTP |
|---|---|---|
| 53520 | `ILLEGAL_TRANSITION` | 409 Conflict |
| 53521 | `REASON_REQUIRED` | 400 Bad Request |
| 53752 | `TWO_GATE_NOT_PASSED` | 409 Conflict |
| other | `SQL_ERROR` | 500 |

## Program.cs wire-up (pending explicit approval)

Charter §5 lists Program.cs on the "never modify without an explicit request" list. This PR does not touch Program.cs. To activate the service, add:

```csharp
using PracticeManagement.Api.Infrastructure;
...
builder.Services.AddPracticeTaskService();
```

## Web tier

- Web controller `TaskController` at `/practice/api/tasks/…` proxies to the Api tier via `HttpClientFactory` (`PracticeManagementApi` named client). Config key: `PracticeManagementApi:BaseUrl`.
- View partial at `Views/Practice/Partials/tasks.cshtml`. `Manage.cshtml` was extended with a small top-of-file dispatcher: if `Model.Key ∈ workflow-screens`, render the partial and skip the generic layout.
- Feature flag `screen.tasks` defaults OFF (charter §7). The partial's `checkFeatureFlag()` hits `/practice/api/tasks/feature-status` and shows the "not enabled" empty state until enabled.

## Hangfire overdue sweeper (deferred pending Q2 wire-up)

- Q2 (Hangfire NuGet) was pre-approved via TDD sign-off, but Program.cs + `.csproj` modifications are still §5 items that need an explicit ok.
- Until then, `sp_task_overdue_sweep` is fully usable as a SQL Agent job (T-SQL only, idempotent) or as a manual `EXEC` in on-prem deployments.
- The follow-up PR adds:
  - NuGet `Hangfire.AspNetCore`, `Hangfire.SqlServer`
  - Program.cs wiring (`AddHangfire`, `UseHangfireDashboard` — Admin role guard)
  - `Api/Jobs/TaskOverdueSweeperJob.cs` (calls `sp_task_overdue_sweep` hourly)

## Test scenarios (deferred pending Api.Tests project)

1. `sp_task_open` inserts row, `current_status_id` resolves to Open, one transition-log row + one audit-trace row.
2. Open an Implementation task twice with same `(subject_entity_type, subject_entity_id)` — second call returns first `task_id`, no duplicate.
3. `sp_task_transition Task Open→Closed` throws `53520`, no audit rows written.
4. `sp_task_close` on an Implementation task in `InProgress` throws `53752`.
5. `sp_task_overdue_sweep` on empty universe → `@escalated_count = 0`, second run also 0.
6. TaskController `POST /assign` with unknown employee ID → 400 with reason.
7. Web `POST /practice/api/tasks/{id}/transition` → 409 mirrored from Api on illegal transition.
