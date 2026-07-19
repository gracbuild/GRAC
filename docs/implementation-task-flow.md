# Practice Instance — Add Implementation Task flow

**Charter reference:** Adjacent to §12.2.2 (Implementation Task auto-generation) but manually-triggered from the Practice Instance screen. Uses the §12.1.3 Task engine unchanged.
**Question log:** `docs/QUESTIONS.md` Q13, Q14, Q15 — resolved.
**Migrations:** `database/043_practice_instance_impl_status.sql`, `database/043_open_implementation_task_proc.sql`, `database/043_practice_instance_impl_status_rollback.sql`
**Smoke test:** `database/deployment/09_UAT_Diagnostics_ImplementationTask.sql`
**Api:** `Api/Services/PracticeInstanceWorkflowService.cs`, `Api/Controllers/PracticeInstanceController.cs`, `Api/Infrastructure/PracticeInstanceWorkflowRegistration.cs`
**Web:** `Web/Controllers/PracticeInstanceWorkflowController.cs`, `Web/Views/Practice/Partials/_add-implementation-task-modal.cshtml`, `Web/wwwroot/js/practice-instance-implementation-task.js`, small edits to `Web/Views/Practice/Manage.cshtml`

---

## Behaviour

1. Practice Instance list has an implementation status per row.
2. Status values (from `implementation_status_master`):
   - **Not Implemented** *(new)*
   - **Partially Implemented** *(new)*
   - **Implemented** *(pre-existing, display order harmonised)*
   - **N/A** *(new)*
   Legacy values (`Not Started`, `In Progress`, `Active`, `Inactive`) remain in the master for compatibility with existing insert paths but are remapped at read time for Practice Instance rows.
3. When status = **Not Implemented**, the UI surfaces "Add Implementation Task" in two places:
   - A header button on the Practice Instances screen.
   - A row-level inline link in the action cell (best-effort — detects rows whose `ImplementationStatus` text is `Not Implemented` and decorates them).
4. Clicking the button opens a modal with fields:
   - **Task Name** (required) → `subject_title`
   - **Description** → `subject_description`
   - **Assigned To** → `assigned_to_employee_id`
   - **Target Date** → `sla_due_at` (override of type default 168h)
   - **Priority** → `priority` (default Medium)
   - **Status** → `Open` (read-only; advance via Task Center)
   - **Remarks** → `reason_text` *(Q14 resolution — reuse existing column)*
5. Submit `POST`s to `/practice/api/instances/{id}/open-implementation-task` → proxied to `/api/practice/instances/{id}/open-implementation-task` → executes `sp_practice_instance_open_implementation_task`.

## Idempotency + validation

- Guarded by `sp_practice_instance_open_implementation_task`:
  - **54301** Instance not found (HTTP 404)
  - **54302** Instance not in `Not Implemented` state (HTTP 409)
  - **54303** Missing `subject_title` (HTTP 400)
- Task-engine level:
  - Filtered unique index `ux_pm_practice_task_impl_dedup` on `(subject_entity_type='PracticeInstance', subject_entity_id)` where `closed_at IS NULL` — second call for the same instance returns the existing `task_id` instead of duplicating.
- Full audit trail via `sp_task_open` → `sp_pm_state_transition` → `practice_audit_trace` (charter §9).

## Two-gate closure link

The Implementation task, once open, follows the standard `sp_task_close` two-gate rule (§12.2.3): closes only from `OperationalGatePassed` or `PendingReview`. Gate procedures (`sp_instance_config_gate_check`, `sp_instance_operational_gate_check`) still land in migration `044` when §12.2.3 begins.

## Wire-up (pending explicit approval — charter §5)

Program.cs additions required by the reviewer:

```csharp
using PracticeManagement.Api.Infrastructure;
...
builder.Services.AddPracticeTaskService();
builder.Services.AddPracticePermissionService();
builder.Services.AddPracticeInstanceWorkflow();
```

Web-side named HttpClient in Web's `Program.cs`:

```csharp
builder.Services.AddHttpClient("PracticeManagementApi", c =>
{
    c.BaseAddress = new Uri(builder.Configuration["PracticeManagementApi:BaseUrl"]!);
});
```

Web `appsettings.json`:
```json
"PracticeManagementApi": { "BaseUrl": "http://localhost:5000/" }
```

Until wired, the modal submit returns 503 ("Upstream API unreachable") with a clear message.

## UAT scenarios

1. **Happy path** — pick an instance in `Not Implemented`, fill Task Name, submit → 200 with `taskId`; verify row appears in Task Center.
2. **Idempotent** — resubmit same instance → returns the same `taskId`; only one open task exists.
3. **Wrong state** — pick an instance in `Implemented` (temporarily flipping the status) and call the API → 409 with `reasonCode=STATE_NOT_ALLOWED`.
4. **Missing title** — omit subject_title → 400 with `reasonCode=BAD_REQUEST`.
5. **Nonexistent instance** — call `/instances/999999999/open-implementation-task` → 404 with `reasonCode=INSTANCE_NOT_FOUND`.
6. **Audit trail** — after each successful call verify:
   - one row in `entity_state_transition_log` for the Task creation
   - one row in `practice_audit_trace` with `action_type = 'STATE_TRANSITION'`

## Follow-ups (out of scope for this PR)

- Employee picker with search on the "Assigned To" field (currently accepts a numeric id).
- Row-level dropdown selector for changing `implementation_status_id` (currently read-only in the grid — status can only be flipped via existing Save path).
- Wire feature-flag gating around the header button (deferred until Task Center itself is fully live for the org).
- Bulk "Open Implementation Tasks for all Not-Implemented instances" from the header.
