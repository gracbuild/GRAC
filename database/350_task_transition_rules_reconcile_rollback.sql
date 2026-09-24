-- =====================================================================
-- 350_task_transition_rules_reconcile_rollback.sql
--
-- Removes ONLY the Task transition rows this migration inserted
-- (entered_by = 'seed-350'). Rows that pre-existed and were merely
-- reactivated are left active -- deleting them would re-break task
-- movement. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO
DELETE FROM grac_practice.entity_state_transition_rule
WHERE entity_type = N'Task'
  AND entered_by  = 'seed-350';
PRINT CONCAT('350 rollback: rows removed = ', @@ROWCOUNT);
GO
