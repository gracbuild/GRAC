-- =====================================================================
-- 044 Rollback — reactivates the values 044 hid, restores the column
-- default to 'Active', leaves practice_instance row values alone (they
-- carry business meaning and should not be reversed by rollback).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (044-rollback): schema grac_practice missing.';
    RAISERROR('schema missing', 16, 1);
    SET NOEXEC ON;
END
GO

-- Reactivate values that were deactivated by 044 step 2.
UPDATE grac_practice.implementation_status_master
   SET is_active  = 1,
       updated_by = 'rollback-044',
       updated_dt = SYSUTCDATETIME()
 WHERE status_code IN (N'Partially Implemented', N'N/A', N'Not Started', N'In Progress', N'Active', N'Inactive')
   AND is_active = 0;
GO

-- Restore the column default to 'Active' if the new constraint exists.
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'df_pm_practice_instance_impl_status'
           AND parent_object_id = OBJECT_ID('grac_practice.practice_instance'))
BEGIN
    ALTER TABLE grac_practice.practice_instance
        DROP CONSTRAINT df_pm_practice_instance_impl_status;
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.default_constraints dc
    JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
    WHERE dc.parent_object_id = OBJECT_ID('grac_practice.practice_instance')
      AND c.name = 'implementation_status')
    ALTER TABLE grac_practice.practice_instance
        ADD CONSTRAINT df_pm_practice_instance_impl_status_legacy
        DEFAULT N'Active' FOR implementation_status;
GO

-- 'Not Updated' seed row is intentionally kept — deletion could break FKs.

PRINT '044 rollback complete. Practice-instance row values preserved by design.';
GO

SET NOEXEC OFF;
GO
