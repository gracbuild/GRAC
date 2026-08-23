-- =====================================================================
-- 213 Risk notification outbox ROLLBACK
--
-- Reverses 213_risk_notification_outbox.sql.
--
-- CLEAN ROLLBACK. 213 modified nothing that existed before it — no proc
-- was rewritten, no column was added to another table — so there is
-- nothing to restore. Dropping its own objects is the whole job.
--
-- DATA LOSS WARNING: every recorded notification obligation is DROPPED,
-- including rows a dispatcher already marked Sent. That is the audit
-- trail of "GRAC determined these people should have been told" — if it
-- matters, export risk_notification_outbox before running this.
--
-- Re-running 213 afterwards will NOT rebuild the history: the sweep only
-- looks back @since_hours (default 7 days). Older events stay
-- un-notified, which is correct — back-filling a year of stale
-- notifications would be worse than the gap.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT '213-rollback: schema grac_practice missing — nothing to do.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.sp_risk_notification_counts','P')  IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_notification_counts;
IF OBJECT_ID('grac_practice.sp_risk_notification_mark','P')    IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_notification_mark;
IF OBJECT_ID('grac_practice.sp_risk_notification_list','P')    IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_notification_list;
IF OBJECT_ID('grac_practice.sp_risk_notification_sweep','P')   IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_notification_sweep;
IF OBJECT_ID('grac_practice.sp_risk_notification_enqueue','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_notification_enqueue;
GO

IF OBJECT_ID('grac_practice.risk_notification_outbox','U') IS NOT NULL
    DROP TABLE grac_practice.risk_notification_outbox;
GO

PRINT '213 Risk notification outbox rolled back.';
GO

SET NOEXEC OFF;
GO
