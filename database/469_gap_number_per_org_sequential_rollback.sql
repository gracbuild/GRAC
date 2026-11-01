-- =====================================================================
-- 469 ROLLBACK -- remove the per-org Gap number (G-001)
-- Drops the trigger, the filtered unique index, and the column.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.trg_pm_custom_gap_assign_number','TR') IS NOT NULL
    DROP TRIGGER grac_practice.trg_pm_custom_gap_assign_number;
GO

IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'uq_pm_custom_gap_gap_number'
             AND object_id = OBJECT_ID('grac_practice.custom_gap'))
    DROP INDEX uq_pm_custom_gap_gap_number ON grac_practice.custom_gap;
GO

IF COL_LENGTH('grac_practice.custom_gap','gap_number') IS NOT NULL
    ALTER TABLE grac_practice.custom_gap DROP COLUMN gap_number;
GO

PRINT '469 rolled back: custom_gap.gap_number removed.';
GO
