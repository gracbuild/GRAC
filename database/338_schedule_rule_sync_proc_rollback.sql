-- =====================================================================
-- 338 ROLLBACK  Remove the schedule-rule sync proc + anchor column
--
-- Drops sp_pm_sync_instance_schedule_rules and the
-- practice_instance_obligation.first_occurrence_date column. Rules
-- already created by the proc are left in place (they are ordinary rows);
-- remove them separately if that is intended.
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('grac_practice.sp_pm_sync_instance_schedule_rules','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_pm_sync_instance_schedule_rules;
    PRINT '338 rollback: dropped sp_pm_sync_instance_schedule_rules';
END
ELSE PRINT '338 rollback: proc already absent -- skipped';
GO

IF COL_LENGTH('grac_practice.practice_instance_obligation','first_occurrence_date') IS NOT NULL
BEGIN
    ALTER TABLE grac_practice.practice_instance_obligation DROP COLUMN first_occurrence_date;
    PRINT '338 rollback: dropped first_occurrence_date';
END
ELSE PRINT '338 rollback: first_occurrence_date already absent -- skipped';
GO

PRINT '338 rollback complete.';
GO
