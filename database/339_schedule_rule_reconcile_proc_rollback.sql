-- =====================================================================
-- 339 ROLLBACK  Drop the bulk reconcile proc
--
-- Drops sp_pm_reconcile_schedule_rules. Rules it already created stay
-- (they are ordinary per-obligation streams the per-instance sync would
-- have made anyway). SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_pm_reconcile_schedule_rules','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_pm_reconcile_schedule_rules;
    PRINT '339 rollback: dropped sp_pm_reconcile_schedule_rules';
END
ELSE PRINT '339 rollback: proc already absent -- skipped';
GO
