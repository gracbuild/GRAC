-- =====================================================================
-- 202 Task notification — procedures ROLLBACK
--
-- Drops only the procedures. The outbox TABLE and its rows survive —
-- 201's rollback owns those, and the records of who GRAC determined
-- should have been notified may have evidentiary value.
--
-- After this, nothing enqueues new notifications. Existing Pending rows
-- stay Pending; a dispatcher reading the table directly would still find
-- them, but sp_task_notification_mark is gone, so mark them by hand or
-- re-run 202.
--
-- sp_task_overdue_sweep (037) is NOT affected — Phase 3 never modified
-- it. Breached tasks continue to transition to Escalated exactly as
-- before.
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT '202-rollback: schema grac_practice missing — nothing to do.';
    SET NOEXEC ON;
END
GO

-- Dependents first: the sweep calls the enqueue proc.
IF OBJECT_ID('grac_practice.sp_task_notification_counts','P')  IS NOT NULL DROP PROCEDURE grac_practice.sp_task_notification_counts;
IF OBJECT_ID('grac_practice.sp_task_notification_mark','P')    IS NOT NULL DROP PROCEDURE grac_practice.sp_task_notification_mark;
IF OBJECT_ID('grac_practice.sp_task_notification_list','P')    IS NOT NULL DROP PROCEDURE grac_practice.sp_task_notification_list;
IF OBJECT_ID('grac_practice.sp_task_notification_sweep','P')   IS NOT NULL DROP PROCEDURE grac_practice.sp_task_notification_sweep;
IF OBJECT_ID('grac_practice.sp_task_notification_enqueue','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_task_notification_enqueue;
GO

IF OBJECT_ID('grac_practice.task_notification_outbox','U') IS NOT NULL
    SELECT '202-rollback: notifications left undeliverable' AS Check_,
           status_code AS StatusCode, COUNT(*) AS Rows_
      FROM grac_practice.task_notification_outbox
     WHERE status_code = N'Pending'
     GROUP BY status_code;
GO

PRINT '202 task notification procedures rolled back. Outbox table retained — run 201 rollback to remove it.';
PRINT 'ALSO: disable the TaskNotification worker (TaskNotification:Enabled = false) so it stops calling a missing proc.';
GO

SET NOEXEC OFF;
GO
