-- =====================================================================
-- 220 GRAC Admin users -- ROLLBACK
--
-- Undoes database/220_grac_admin_users.sql for the three accounts:
--   anoop.ps@soffit.in, saji.p@soffit.in, aparna.mp@soffit.in
--
-- WHAT IT MATCHES ON
--   entered_by = 'seed-220', the stamp the forward script puts on every
--   row it writes -- the same discipline 217's rollback uses with
--   'seed-217'. An account or a map row that someone later re-saved
--   through the Users screen carries that person's id instead and is
--   therefore left alone: a rollback must not delete work that was done
--   after it.
--
-- WHAT IT DOES NOT UNDO
--   Section 6 of the forward script -- the
--   pm_grant_organization_default_access call. Those rows carry the same
--   'seed-220' stamp, but they are 217's default-access grants for every
--   organisation's OWN Admin role and its screen flags. Stripping them
--   would take menus and screens away from organisation admins who have
--   nothing to do with these three users, and re-open exactly the defect
--   217 exists to close. Use 217's own rollback if that is really the
--   intention.
--
-- DELETE VS DEACTIVATE
--   An employee row that other tables reference (ownership assignments,
--   tasks, evidence, acknowledgements) cannot be deleted -- the foreign
--   keys are there to stop history losing its author. Section 3 tries
--   the DELETE and, if a reference blocks it, deactivates the account
--   instead and says so. Deactivated is enough to stop sign-in:
--   PracticeAuthenticationService requires status = 'Active'.
--
-- ASCII-only on purpose (see the forward script header).
-- Idempotent: safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (220 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

DECLARE @emails TABLE (email NVARCHAR(250) PRIMARY KEY);
INSERT @emails (email) VALUES
    (N'anoop.ps@soffit.in'), (N'saji.p@soffit.in'), (N'aparna.mp@soffit.in');

DECLARE @role_id BIGINT = (
    SELECT TOP 1 role_id FROM grac_practice.organization_role
    WHERE organization_id = 4 AND role_code = N'GRAC_ADMIN'
    ORDER BY role_id
);

-- =====================================================================
-- 1. Role assignments (the M:N map).
--    Cleared before the employee rows so the FK does not block them.
-- =====================================================================
IF @role_id IS NOT NULL
BEGIN
    DELETE er
    FROM grac_practice.organization_employee_role er
    JOIN grac_practice.organization_employee e ON e.employee_id = er.employee_id
    JOIN @emails x ON LOWER(LTRIM(RTRIM(e.email))) = x.email
    WHERE er.role_id = @role_id
      AND er.entered_by = N'seed-220';

    PRINT '220 rollback: organization_employee_role rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

-- =====================================================================
-- 2. Organisation access rows.
-- =====================================================================
DELETE m
FROM grac_practice.user_organization_map m
JOIN @emails x ON LOWER(LTRIM(RTRIM(m.user_email))) = x.email
WHERE m.entered_by = N'seed-220';

PRINT '220 rollback: user_organization_map rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

-- =====================================================================
-- 3. The employee rows.
--    Only rows this script created (entered_by = 'seed-220'). An account
--    that already existed before 220 ran was left unchanged by the
--    forward script and must be left unchanged here too.
-- =====================================================================
DECLARE @orphan_role_id BIGINT;
BEGIN TRY
    DELETE e
    FROM grac_practice.organization_employee e
    JOIN @emails x ON LOWER(LTRIM(RTRIM(e.email))) = x.email
    WHERE e.entered_by = N'seed-220';

    PRINT '220 rollback: organization_employee rows deleted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END TRY
BEGIN CATCH
    -- 547 is the foreign key violation. Anything else is not ours to
    -- swallow, so re-raise it. ERROR_NUMBER() is captured into a local
    -- first so the preceding statement is semicolon-terminated, which is
    -- what a bare THROW requires.
    DECLARE @err_number INT = ERROR_NUMBER();
    IF @err_number <> 547
    BEGIN
        THROW;
    END

    PRINT '220 rollback: employee rows are referenced elsewhere (FK 547) -- deactivating instead of deleting.';

    UPDATE e
       SET e.status     = N'Inactive',
           e.updated_by = N'seed-220-rollback',
           e.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.organization_employee e
    JOIN @emails x ON LOWER(LTRIM(RTRIM(e.email))) = x.email
    WHERE e.entered_by = N'seed-220'
      AND e.status <> N'Inactive';

    PRINT '220 rollback: organization_employee rows deactivated = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END CATCH

-- =====================================================================
-- 4. The role and its menu grants.
--    Dropped only if nothing is left pointing at it -- another account
--    may have been given GRAC Admin through the Users screen after 220
--    ran, and that assignment is not this script's to revoke.
-- =====================================================================
IF @role_id IS NOT NULL
BEGIN
    SET @orphan_role_id = @role_id;

    IF EXISTS (SELECT 1 FROM grac_practice.organization_employee_role WHERE role_id = @role_id)
       OR EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE role_id = @role_id)
    BEGIN
        SET @orphan_role_id = NULL;
        PRINT '220 rollback: role GRAC_ADMIN is still assigned to at least one employee -- role and grants kept.';
    END

    IF @orphan_role_id IS NOT NULL
    BEGIN
        DELETE FROM grac_practice.organization_role_menu_permission
        WHERE role_id = @orphan_role_id AND entered_by = N'seed-220';

        PRINT '220 rollback: organization_role_menu_permission rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

        -- Only drop the role once it carries no grants at all; a grant
        -- written by someone else means the role is in use.
        IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission
                        WHERE role_id = @orphan_role_id)
        BEGIN
            DELETE FROM grac_practice.organization_role WHERE role_id = @orphan_role_id;
            PRINT '220 rollback: role GRAC_ADMIN removed.';
        END
        ELSE
            PRINT '220 rollback: role GRAC_ADMIN still carries grants written by another caller -- role kept.';
    END
END
ELSE
    PRINT '220 rollback: role GRAC_ADMIN not found -- nothing to remove.';
GO

-- =====================================================================
-- 5. Verification -- all three should be gone or Inactive, and no
--    active organisation access should remain.
-- =====================================================================
PRINT '=== 220 rollback verification ===';

SELECT e.employee_id, e.email, e.status AS employee_status, e.entered_by
FROM grac_practice.organization_employee e
WHERE LOWER(e.email) IN (N'anoop.ps@soffit.in', N'saji.p@soffit.in', N'aparna.mp@soffit.in')
ORDER BY e.email;

SELECT m.user_email, COUNT(*) AS RemainingOrgRows
FROM grac_practice.user_organization_map m
WHERE LOWER(m.user_email) IN (N'anoop.ps@soffit.in', N'saji.p@soffit.in', N'aparna.mp@soffit.in')
  AND m.status = N'Active'
GROUP BY m.user_email;

SELECT 'GRAC_ADMIN role still present' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.organization_role
                          WHERE organization_id = 4 AND role_code = N'GRAC_ADMIN')
            THEN 'YES -- see the PRINT above for why' ELSE 'NO' END AS Result;

PRINT '';
PRINT '220 GRAC Admin users rollback complete.';
GO

SET NOEXEC OFF;
GO
