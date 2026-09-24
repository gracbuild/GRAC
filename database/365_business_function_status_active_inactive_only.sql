-- =====================================================================
-- 365_business_function_status_active_inactive_only.sql
--
-- Business Function status restriction: new inserts and status updates
-- may only be 'Active' or 'Inactive'. Enforced at the DATABASE level with
-- a CHECK constraint, added WITH NOCHECK so EXISTING historical rows that
-- already hold other status values (e.g. Retired/Draft/Disposed) are NOT
-- validated, modified or deleted -- the restriction applies only to new
-- and updated rows going forward.
--
-- Scope: organization_business_function only. No other module affected.
-- All current write paths already set 'Active' or 'Inactive', so this is
-- defense-in-depth behind the Add/Edit form (which offers only those two).
--
-- Idempotent and re-runnable. ASCII-only.
-- Rollback: 365_business_function_status_active_inactive_only_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.organization_business_function','U') IS NULL
BEGIN
    PRINT 'ABORT (365): grac_practice.organization_business_function is missing.';
    RETURN;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = 'ck_pm_business_function_status_active_inactive'
                 AND parent_object_id = OBJECT_ID('grac_practice.organization_business_function'))
BEGIN
    -- WITH NOCHECK: do not validate existing rows, only new/updated ones.
    ALTER TABLE grac_practice.organization_business_function
        WITH NOCHECK
        ADD CONSTRAINT ck_pm_business_function_status_active_inactive
            CHECK (status IN (N'Active', N'Inactive'));
    PRINT '365: CHECK constraint added -- Business Function status limited to Active/Inactive for new/updated rows.';
END
ELSE
    PRINT '365: CHECK constraint already present -- nothing to do.';
GO

-- Verification
IF EXISTS (SELECT 1 FROM sys.check_constraints
           WHERE name = 'ck_pm_business_function_status_active_inactive'
             AND parent_object_id = OBJECT_ID('grac_practice.organization_business_function'))
    PRINT '365: PASS -- constraint ck_pm_business_function_status_active_inactive is in place.';
ELSE
    PRINT '365: WARNING -- constraint not found after run.';
GO
