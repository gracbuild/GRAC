# State-machine framework — developer notes

**Charter reference:** §4.1 (locked infra decision), §7 (conventions), §12.1.1 (work item)
**Migrations:** `035_state_machine_framework.sql` (schema), `035_state_machine_procs.sql` (procs), `035_state_machine_framework_rollback.sql` (rollback)
**Smoke test:** `database/deployment/07_UAT_Diagnostics_WorkflowLayer.sql`

---

## What it is

A generic, reusable substrate that every stateful entity in GRAC hooks into. Instead of each entity carrying its own `status` NVARCHAR column with hard-coded transitions, they carry an `INT current_status_id` FK to `entity_status_master` and rely on the framework for legality + logging.

## Tables

| Table | Purpose |
|---|---|
| `entity_status_master` | The universe of statuses per `entity_type`. Unique on `(entity_type, status_code)`. |
| `entity_state_transition_rule` | Legal `(from → to)` pairs per `entity_type`, optionally gated by `actor_role_code`. `requires_reason` and `requires_approval` are per-rule flags. |
| `entity_state_transition_log` | Append-only history. Made immutable by an `INSTEAD OF UPDATE, DELETE` trigger. |

## Functions

- `fn_is_transition_allowed(entity_type, from_status_code, to_status_code, actor_role_code) → BIT` — the guard. NULL `from_status_code` means "creation". NULL `actor_role_code` matches only rules with a NULL `actor_role_code` unless the caller passes one that matches a role-specific rule.
- `fn_get_entity_status_id(entity_type, status_code) → INT` — resolve a friendly code to its surrogate id.

## Procedures

- `sp_pm_state_transition` — validates + logs + writes to `practice_audit_trace`. Does **not** mutate the owning entity: the caller is expected to `UPDATE {entity} SET current_status_id = @to_status_id ... ` inside the same transaction. This keeps the procedure entity-agnostic.
- `sp_pm_state_transition_probe` — read-only. Answers "would this transition succeed if I ran it?" for UI grey-out logic.

## How to onboard a new entity

1. Insert rows into `entity_status_master` with the new `entity_type` label (e.g. `'AssuranceTicket'`).
2. Insert rows into `entity_state_transition_rule` for every legal transition.
3. On the new entity's table, add:
   ```sql
   current_status_id INT NOT NULL
     CONSTRAINT fk_{entity}_current_status
     REFERENCES grac_practice.entity_status_master(entity_status_id)
   ```
4. Every mutation calls `sp_pm_state_transition` first, then updates the entity row in the same transaction.

## Callable pattern for a new entity's `sp_{entity}_transition` wrapper

```sql
CREATE OR ALTER PROCEDURE grac_practice.sp_task_transition
    @task_id BIGINT,
    @to_status_code NVARCHAR(60),
    @actor_employee_id BIGINT,
    @actor_role_code NVARCHAR(60),
    @reason_code NVARCHAR(60) = NULL,
    @reason_text NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @from_status_code NVARCHAR(60),
            @to_status_id INT,
            @log_id BIGINT;

    SELECT @from_status_code = m.status_code
    FROM grac_practice.practice_task t
    JOIN grac_practice.entity_status_master m ON m.entity_status_id = t.current_status_id
    WHERE t.task_id = @task_id;

    BEGIN TRAN;

    EXEC grac_practice.sp_pm_state_transition
        @entity_type       = N'Task',
        @entity_id         = @task_id,
        @from_status_code  = @from_status_code,
        @to_status_code    = @to_status_code,
        @actor_employee_id = @actor_employee_id,
        @actor_role_code   = @actor_role_code,
        @reason_code       = @reason_code,
        @reason_text       = @reason_text,
        @to_status_id      = @to_status_id      OUTPUT,
        @transition_log_id = @log_id            OUTPUT;

    UPDATE grac_practice.practice_task
       SET current_status_id = @to_status_id,
           updated_by        = CAST(@actor_employee_id AS NVARCHAR(30)),
           updated_dt        = SYSUTCDATETIME()
     WHERE task_id = @task_id;

    COMMIT TRAN;
END;
```

## Error codes

| Code | Meaning |
|---|---|
| `53500..53509` | Framework schema errors |
| `53510..53519` | Framework procedure setup errors |
| `53520` | Illegal transition (surfaced as HTTP 409 at the API layer) |
| `53521` | Missing required `reason_code` |
| `53522..53525` | Bad arguments to `sp_pm_state_transition` |
| `53550..53559` | Rollback errors |

## Audit trail

Every successful transition writes to `practice_audit_trace` with `action_type = 'STATE_TRANSITION'`, `before_json` = `{ from_status_code, from_status_id }`, `after_json` = `{ to_status_code, to_status_id, actor_employee_id, actor_role_code, reason_code, reason_text, correlation_id, transition_log_id }`. Coexists with the canonical `audit_trail` deferred to migration 062 (see `docs/QUESTIONS.md` Q004).

## Idempotency

The migration is safe to re-run. Seed rows use `MERGE` on natural keys. Rollback drops in reverse dependency order; if downstream migrations have added FKs to `entity_status_master`, their rollback must run first.

## Unit tests (to add in the Api test project when it exists)

The following scenarios should be covered:

1. **Legal transition succeeds** — `Task Open→Assigned` returns success, inserts one `entity_state_transition_log` row and one `practice_audit_trace` row.
2. **Illegal transition rejected** — `Task Open→Closed` throws `53520`; no log rows written.
3. **Idempotent probe** — `sp_pm_state_transition_probe` never mutates.
4. **Reason enforcement** — `Task Open→Cancelled` without `reason_code` throws `53521`.
5. **Role-gated transition** — `Task Closed→Open` allowed only with `actor_role_code = 'Admin'`.
6. **Log immutability** — `UPDATE entity_state_transition_log` throws `53501`.

Because no test project currently exists in the repo, tests are captured here as a scenario list and will be codified when Wave 1's Task Engine (§12.1.3) introduces the `Api.Tests` project.
