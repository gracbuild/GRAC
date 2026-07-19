-- =====================================================================
-- 043 Rollback (v2) — only reverses what 043 v2 actually owns.
--
-- The column practice_instance.implementation_status_id and the FK
-- fk_pm_practice_instance_implementation_status were introduced by
-- migrations 002 + 008, NOT by 043. Dropping them here would be
-- destructive and would fail (as v1 of this rollback discovered).
--
-- This rollback ONLY:
--   1. Drops the supporting index ix_pm_practice_instance_impl_status
--      that 043 created.
--   2. Drops the duplicate FK fk_pm_practice_instance_impl_status left
--      behind by 043 v1 (if it survived — v2 already cleans it up).
--   3. Leaves the column, the canonical FK, and the master rows intact.
--      Master rows are shared data and may already be referenced by
--      other rows written after 043 v2 ran.
--
-- If you need to physically remove the three seeded master rows, do it
-- MANUALLY after verifying no practice_instance references them:
--
--   DELETE FROM grac_practice.implementation_status_master
--    WHERE status_code IN (N'Not Implemented', N'Partially Implemented', N'N/A')
--      AND NOT EXISTS (
--        SELECT 1 FROM grac_practice.practice_instance
--        WHERE implementation_status_id = implementation_status_master.implementation_status_id);
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (043-rollback): schema grac_practice missing.';
    RAISERROR('schema missing', 16, 1);
    SET NOEXEC ON;
END
GO

-- 1. Drop supporting index (owned by 043)
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_practice_instance_impl_status'
           AND object_id = OBJECT_ID('grac_practice.practice_instance'))
BEGIN
    PRINT '043-rollback: dropping ix_pm_practice_instance_impl_status.';
    DROP INDEX ix_pm_practice_instance_impl_status ON grac_practice.practice_instance;
END
ELSE
    PRINT '043-rollback: ix_pm_practice_instance_impl_status already absent.';
GO

-- 2. Drop duplicate FK left by 043 v1 if still present
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_practice_instance_impl_status'
           AND parent_object_id = OBJECT_ID('grac_practice.practice_instance'))
BEGIN
    PRINT '043-rollback: dropping duplicate FK fk_pm_practice_instance_impl_status (v1 remnant).';
    ALTER TABLE grac_practice.practice_instance
        DROP CONSTRAINT fk_pm_practice_instance_impl_status;
END
ELSE
    PRINT '043-rollback: duplicate FK not present (already clean).';
GO

PRINT '043-rollback complete. Canonical FK, column, and seed master rows preserved by design.';
GO

SET NOEXEC OFF;
GO
