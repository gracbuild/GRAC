-- =====================================================================
-- 201 Task notification outbox — schema ROLLBACK
--
-- Drops the 202 procedures (guarded, so this can run standalone) and then
-- the outbox table.
--
-- DATA LOSS: task_notification_outbox is dropped. Rows in it are a record
-- of who GRAC determined should have been notified and when — if that has
-- any evidentiary value in your environment, export it before running
-- this. Nothing regenerates historical rows: the sweeper only ever looks
-- at thresholds that are crossed NOW.
--
-- Nothing else in Task Centre depends on this table, so no other
-- migration's rollback is required first.
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT '201-rollback: schema grac_practice missing — nothing to do.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.task_notification_outbox','U') IS NOT NULL
BEGIN
    SELECT '201-rollback: rows about to be dropped' AS Check_,
           status_code AS StatusCode,
           COUNT(*)    AS Rows_
      FROM grac_practice.task_notification_outbox
     GROUP BY status_code;
END
GO

-- Procedures first — they bind to the table.
IF OBJECT_ID('grac_practice.sp_task_notification_counts','P')  IS NOT NULL DROP PROCEDURE grac_practice.sp_task_notification_counts;
IF OBJECT_ID('grac_practice.sp_task_notification_mark','P')    IS NOT NULL DROP PROCEDURE grac_practice.sp_task_notification_mark;
IF OBJECT_ID('grac_practice.sp_task_notification_list','P')    IS NOT NULL DROP PROCEDURE grac_practice.sp_task_notification_list;
IF OBJECT_ID('grac_practice.sp_task_notification_sweep','P')   IS NOT NULL DROP PROCEDURE grac_practice.sp_task_notification_sweep;
IF OBJECT_ID('grac_practice.sp_task_notification_enqueue','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_task_notification_enqueue;
GO

IF OBJECT_ID('grac_practice.task_notification_outbox','U') IS NOT NULL
    DROP TABLE grac_practice.task_notification_outbox;
GO

PRINT '201 task notification outbox rolled back.';
PRINT 'NOTE: sp_task_overdue_sweep (037) was never modified by Phase 3 and still escalates on breach.';
GO

SET NOEXEC OFF;
GO
