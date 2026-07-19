-- =====================================================================
-- 037 Task engine — ROLLBACK  (charter §9)
--
-- Drops procedures, view, indexes, and tables introduced by:
--   * 037_task_engine.sql
--   * 037_task_engine_procs.sql
--
-- Existing rows in practice_task are lost. Callers that need the data
-- preserved must EXPORT before running this script.
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 53790, 'PracticeManagement schema grac_practice is missing.', 1;
GO

-- Procedures
IF OBJECT_ID('grac_practice.sp_task_open','P')            IS NOT NULL DROP PROCEDURE grac_practice.sp_task_open;
IF OBJECT_ID('grac_practice.sp_task_assign','P')          IS NOT NULL DROP PROCEDURE grac_practice.sp_task_assign;
IF OBJECT_ID('grac_practice.sp_task_transition','P')      IS NOT NULL DROP PROCEDURE grac_practice.sp_task_transition;
IF OBJECT_ID('grac_practice.sp_task_close','P')           IS NOT NULL DROP PROCEDURE grac_practice.sp_task_close;
IF OBJECT_ID('grac_practice.sp_task_overdue_sweep','P')   IS NOT NULL DROP PROCEDURE grac_practice.sp_task_overdue_sweep;
IF OBJECT_ID('grac_practice.sp_task_list','P')            IS NOT NULL DROP PROCEDURE grac_practice.sp_task_list;
GO

-- View
IF OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NOT NULL
    DROP VIEW grac_practice.vw_pm_practice_task;
GO

-- Table (drops its indexes + FKs implicitly)
IF OBJECT_ID('grac_practice.practice_task','U') IS NOT NULL
    DROP TABLE grac_practice.practice_task;
GO

IF OBJECT_ID('grac_practice.task_type_master','U') IS NOT NULL
    DROP TABLE grac_practice.task_type_master;
GO

PRINT '037 task engine rollback complete.';
