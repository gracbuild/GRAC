-- =====================================================================
-- 322 Organisation 1 admin sign-in user -- ROLLBACK
--
-- Undoes database/322_organization1_admin_user.sql for admin@grac.local
-- in organisation 1.
--
-- WHAT IT MATCHES ON
--   entered_by = 'seed-322', the stamp pm_create_organization_admin
--   wrote on every row IT inserted -- same discipline as 220's rollback.
--   If admin@grac.local already existed in organisation 1 before 322 ran
--   (@already_existed = 1 in the forward script's own PRINT), its
--   organization_employee row keeps ITS ORIGINAL entered_by and is left
--   alone here: only the password_hash / force_password_change / status
--   the forward script refreshed on that pre-existing row are not
--   reverted, because their prior values were never captured. A row a
--   person later re-saved through the Users screen also carries their
--   id instead of 'seed-322' and is likewise left alone.
--
-- WHAT IT DOES NOT TOUCH
--   Organisation 1's 'Admin' role (organization_role). The forward
--   script never creates a role of its own -- it calls
--   pm_create_organization_admin, which reuses org 1's role if one
--   already exists (the overwhelmingly likely case for an organisation
--   that is already in use) and only creates one if org 1 had none at
--   all. Either way that role is the SAME role every other admin in
--   organisation 1 signs in with; deleting it on this rollback would
--   lock them out. If 322 really did create org 1's very first Admin
--   role and it is provably unused by anyone else, remove it by hand.
--
-- DELETE VS DEACTIVATE
--   An employee row referenced elsewhere (ownership assignments, tasks,
--   evidence, acknowledgements, approvals) cannot be deleted -- the
--   foreign keys exist so history does not lose its author. Section 2
--   tries DELETE and, if a reference blocks it (FK violation 547),
--   deactivates the account instead. Deactivated is enough to stop
--   sign-in: PracticeAuthenticationService requires status = 'Active'.
--
-- ASCII-only on purpose (see the forward script header).
-- Idempotent: safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (322 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

DECLARE @employee_id BIGINT = (
    SELECT TOP 1 employee_id
    FROM grac_practice.organization_employee
    WHERE organization_id = 1 AND LOWER(email) = N'admin@grac.local'
);

-- =====================================================================
-- 1. Role assignment (the M:N map). Cleared before the employee row so
--    the FK does not block it.
-- =====================================================================
IF @employee_id IS NOT NULL
BEGIN
    DELETE FROM grac_practice.organization_employee_role
    WHERE employee_id = @employee_id
      AND entered_by = N'seed-322';

    PRINT '322 rollback: organization_employee_role rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END
ELSE
    PRINT '322 rollback: admin@grac.local not found in organisation 1 -- nothing to remove.';

-- =====================================================================
-- 2. The employee row. Only if THIS script created it (entered_by =
--    'seed-322'); a pre-existing account that 322 merely refreshed is
--    left exactly where it is (see header).
-- =====================================================================
IF @employee_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM grac_practice.organization_employee
    WHERE employee_id = @employee_id AND entered_by = N'seed-322'
)
BEGIN
    BEGIN TRY
        DELETE FROM grac_practice.organization_employee
        WHERE employee_id = @employee_id;

        PRINT '322 rollback: organization_employee row deleted.';
    END TRY
    BEGIN CATCH
        -- 547 is the foreign key violation. Anything else is not ours to
        -- swallow, so re-raise it. ERROR_NUMBER() is captured into a
        -- local first so the preceding statement is semicolon-terminated,
        -- which is what a bare THROW requires.
        DECLARE @err_number INT = ERROR_NUMBER();
        IF @err_number <> 547
        BEGIN
            THROW;
        END

        PRINT '322 rollback: employee row is referenced elsewhere (FK 547) -- deactivating instead of deleting.';

        UPDATE grac_practice.organization_employee
           SET status     = N'Inactive',
               updated_by = N'seed-322-rollback',
               updated_dt = SYSUTCDATETIME()
         WHERE employee_id = @employee_id
           AND status <> N'Inactive';

        PRINT '322 rollback: organization_employee row deactivated.';
    END CATCH
END
ELSE IF @employee_id IS NOT NULL
    PRINT '322 rollback: admin@grac.local pre-dates this script (entered_by <> seed-322) -- employee row left unchanged.';
GO

-- =====================================================================
-- 3. Verification.
-- =====================================================================
PRINT '=== 322 rollback verification ===';

SELECT e.employee_id, e.organization_id, e.email, e.status AS employee_status, e.entered_by
FROM grac_practice.organization_employee e
WHERE LOWER(e.email) = N'admin@grac.local'
ORDER BY e.organization_id;

PRINT '';
PRINT '322 organisation 1 admin user rollback complete.';
GO

SET NOEXEC OFF;
GO
