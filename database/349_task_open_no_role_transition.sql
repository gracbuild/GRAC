-- =====================================================================
-- 349_task_open_no_role_transition.sql
--
-- SYMPTOM
--   Gap Analysis and Risk Analysis stopped auto-creating Tasks. The gap
--   save reports success but no Task and no Risk appear. Reproduced
--   outside the save's best-effort CATCH, the real error is:
--
--     55502  Illegal transition for Task #NN: <initial> -> Open as <no-role>.
--     3930   The current transaction cannot be committed ...  (the Risk
--            trigger, poisoned by the doomed transaction above)
--
-- ROOT CAUSE
--   sp_task_open opens a task with sp_pm_state_transition(@from=NULL,
--   @to='Open'). When a task is created with NO actor -- every system /
--   auto-created task: gap remediation (analysed_by_employee_id NULL),
--   risk treatment, any task opened without a signed-in user -- the actor
--   role is NULL, so the state machine needs a rule with
--   actor_role_code = NULL for Task <initial> -> Open. That rule is absent
--   (or inactive) in this database, so fn_is_transition_allowed returns 0
--   and the transition THROWs. The throw dooms the transaction, which is
--   why the Risk trigger then fails with 3930, and why the whole
--   auto-create chain went silent.
--
-- FIX (same shape as 268_task_closure_transitions, which restored the
--   -> Closed rules): idempotently ensure the Task <initial> -> Open rule
--   exists with actor_role_code = NULL and is active. WHO may open a task
--   is an API authorization concern, not a state-machine one -- exactly
--   how every other working Task rule in the 035 seed is shaped.
--
-- SAFE TO RE-RUN. Additive; only reactivates/creates one rule row.
-- ASCII-only. Rollback: 349_task_open_no_role_transition_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.entity_state_transition_rule','U') IS NULL
BEGIN
    RAISERROR('349: entity_state_transition_rule missing -- run 035_state_machine_framework.sql first.', 16, 1);
END
GO

;WITH rules AS (
    SELECT * FROM (VALUES
        (N'Task', CAST(NULL AS NVARCHAR(60)), N'Open', CAST(NULL AS NVARCHAR(60)), 0,
            N'Open a task at creation with no actor role. System and auto-created tasks (gap remediation, risk treatment, and any task opened without a signed-in actor) legitimately have no human role. WHO may open a task is an API authorization question, not a state-machine one. Restores the 035 <initial>->Open seed.')
    ) v(entity_type, from_status_code, to_status_code, actor_role_code, requires_reason, description)
)
MERGE grac_practice.entity_state_transition_rule AS t
USING rules
   ON  t.entity_type      = rules.entity_type
   AND ISNULL(t.from_status_code, N'__NULL__') = ISNULL(rules.from_status_code, N'__NULL__')
   AND t.to_status_code   = rules.to_status_code
   AND ISNULL(t.actor_role_code, N'__NULL__')  = ISNULL(rules.actor_role_code, N'__NULL__')
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, from_status_code, to_status_code, actor_role_code,
            requires_reason, description, is_active, entered_by)
    VALUES (rules.entity_type, rules.from_status_code, rules.to_status_code,
            rules.actor_role_code, rules.requires_reason, rules.description, 1, 'seed-349')
WHEN MATCHED AND (t.is_active = 0) THEN
    UPDATE SET is_active  = 1,
               updated_by = 'seed-349',
               updated_dt = SYSUTCDATETIME();
GO

PRINT '=== 349 verification ===';
SELECT CASE WHEN grac_practice.fn_is_transition_allowed(N'Task', NULL, N'Open', NULL) = 1
            THEN 'PASS -- Task <initial> -> Open is allowed with no role'
            ELSE 'FAIL -- rule still missing' END AS Result;
GO
PRINT '349: Task <initial> -> Open (no role) transition ensured. Gap/Risk auto-create can open tasks again.';
GO
