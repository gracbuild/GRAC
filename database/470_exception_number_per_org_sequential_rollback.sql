-- =====================================================================
-- 470 ROLLBACK -- remove the per-org Exception number (E-001)
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.trg_pm_exception_request_assign_number','TR') IS NOT NULL
    DROP TRIGGER grac_practice.trg_pm_exception_request_assign_number;
GO

IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'uq_pm_exception_request_number'
             AND object_id = OBJECT_ID('grac_practice.exception_request'))
    DROP INDEX uq_pm_exception_request_number ON grac_practice.exception_request;
GO

IF COL_LENGTH('grac_practice.exception_request','exception_number') IS NOT NULL
    ALTER TABLE grac_practice.exception_request DROP COLUMN exception_number;
GO

PRINT '470 rolled back: exception_request.exception_number removed.';
GO
