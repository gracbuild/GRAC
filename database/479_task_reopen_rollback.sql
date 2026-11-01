-- =====================================================================
-- 479 ROLLBACK -- remove sp_task_reopen and the any-role Closed->Open rule
-- (the 035 Admin-only Closed->Open rule is left untouched).
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_task_reopen','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_reopen;
GO

DELETE FROM grac_practice.entity_state_transition_rule
 WHERE entity_type = N'Task'
   AND from_status_code = N'Closed'
   AND to_status_code   = N'Open'
   AND actor_role_code IS NULL;
GO

PRINT '479 rolled back: sp_task_reopen dropped; NULL-role Closed->Open rule removed.';
GO
