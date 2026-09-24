-- =====================================================================
-- 349_task_open_no_role_transition_rollback.sql
--
-- Reverses 349 by removing ONLY the rule row this migration inserted
-- (entered_by = 'seed-349'). A pre-existing row that 349 merely
-- reactivated is left active -- deleting it could re-break task creation.
-- After this runs, opening a task with no actor role becomes illegal
-- again (the original faulty state). ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO
DELETE FROM grac_practice.entity_state_transition_rule
WHERE entity_type      = N'Task'
  AND from_status_code  IS NULL
  AND to_status_code    = N'Open'
  AND actor_role_code   IS NULL
  AND entered_by        = 'seed-349';
PRINT CONCAT('349 rollback: rows removed = ', @@ROWCOUNT);
GO
