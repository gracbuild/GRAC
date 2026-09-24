-- =====================================================================
-- 365_business_function_status_active_inactive_only_rollback.sql
--
-- Reverses 365: drops the Business Function status CHECK constraint.
-- Existing data is untouched. Idempotent. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints
           WHERE name = 'ck_pm_business_function_status_active_inactive'
             AND parent_object_id = OBJECT_ID('grac_practice.organization_business_function'))
BEGIN
    ALTER TABLE grac_practice.organization_business_function
        DROP CONSTRAINT ck_pm_business_function_status_active_inactive;
    PRINT '365 rollback: CHECK constraint dropped.';
END
ELSE
    PRINT '365 rollback: constraint not present -- nothing to do.';
GO
