-- =====================================================================
-- 377_task_calendar_edit_scheduler_execution_date_only_rollback.sql
--
-- Drops the SAVE shim added by 377. Once this runs, PracticeRepositoryService's
-- ResolveProcedureAsync probe for 'assurance-schedule-overrides' finds no
-- shim and 'SAVE' falls back to dbo.pm_manage_practice_repository's own
-- untouched branch (002) -- Skipped overrides become creatable again at
-- the database layer. No data is discarded: existing override rows are
-- untouched either way. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_pm_schedule_override_repository_manage','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_pm_schedule_override_repository_manage;
GO
