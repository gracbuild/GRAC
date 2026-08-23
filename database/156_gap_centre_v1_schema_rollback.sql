-- =====================================================================
-- 156 Gap Centre v1 schema -- ROLLBACK
--
-- Drops the new tables and the three custom_gap columns. Legacy gap
-- data (title, description, status, priority, actions, history) is
-- untouched. Roll 157 back before 156 so the transition proc stops
-- referencing the state master.
--
-- WARNING: Content in custom_gap_analysis / custom_gap_downstream_link
-- is lost. Capture first if live:
--   SELECT * FROM grac_practice.custom_gap_analysis;
--   SELECT * FROM grac_practice.custom_gap_downstream_link;
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.custom_gap_downstream_link','U') IS NOT NULL
    DROP TABLE grac_practice.custom_gap_downstream_link;
GO

IF OBJECT_ID('grac_practice.custom_gap_analysis','U') IS NOT NULL
    DROP TABLE grac_practice.custom_gap_analysis;
GO

-- Drop the three custom_gap columns (and their FKs / index).
IF EXISTS(SELECT 1 FROM sys.indexes
           WHERE name='ix_pm_custom_gap_lifecycle_state'
             AND object_id=OBJECT_ID('grac_practice.custom_gap'))
    DROP INDEX ix_pm_custom_gap_lifecycle_state
        ON grac_practice.custom_gap;
GO

IF EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_custom_gap_lifecycle_state')
    ALTER TABLE grac_practice.custom_gap DROP CONSTRAINT fk_pm_custom_gap_lifecycle_state;
GO
IF COL_LENGTH('grac_practice.custom_gap','lifecycle_state_id') IS NOT NULL
    ALTER TABLE grac_practice.custom_gap DROP COLUMN lifecycle_state_id;
GO

IF EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_custom_gap_duplicate_of')
    ALTER TABLE grac_practice.custom_gap DROP CONSTRAINT fk_pm_custom_gap_duplicate_of;
GO
IF COL_LENGTH('grac_practice.custom_gap','duplicate_of_gap_id') IS NOT NULL
    ALTER TABLE grac_practice.custom_gap DROP COLUMN duplicate_of_gap_id;
GO

IF COL_LENGTH('grac_practice.custom_gap','invalid_reason') IS NOT NULL
    ALTER TABLE grac_practice.custom_gap DROP COLUMN invalid_reason;
GO

IF OBJECT_ID('grac_practice.gap_lifecycle_transition_master','U') IS NOT NULL
    DROP TABLE grac_practice.gap_lifecycle_transition_master;
GO

IF OBJECT_ID('grac_practice.gap_lifecycle_state_master','U') IS NOT NULL
    DROP TABLE grac_practice.gap_lifecycle_state_master;
GO
