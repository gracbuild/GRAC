-- =====================================================================
-- 223 Cross-organisation admins get the default-access top-up -- ROLLBACK
--
-- Restores grac_practice.pm_grant_organization_default_access to the
-- exact 217_organization_default_access.sql body, dropping the
-- role_code = 'GRAC_ADMIN' predicate from step 1a.
--
-- THE GRANTED ROWS ARE LEFT ALONE, ON PURPOSE
-- -------------------------------------------
-- 223's backfill inserted permission rows stamped entered_by =
-- 'seed-223'. Deleting them would take Document Uploads, Document
-- Acknowledgements and My Acknowledgements away from the GRAC Admin
-- users again -- which is the defect 223 exists to fix, not a side
-- effect of it. Rolling back the PROCEDURE stops future menus reaching
-- GRAC_ADMIN automatically; it does not have to undo access that is
-- currently correct and in use.
--
-- If the grants really are unwanted, remove them explicitly and
-- deliberately:
--
--     DELETE p
--     FROM   grac_practice.organization_role_menu_permission p
--     JOIN   grac_practice.organization_role r ON r.role_id = p.role_id
--     WHERE  r.role_code = N'GRAC_ADMIN'
--       AND  p.entered_by = N'seed-223';
--
-- The feature_flag rows are shared with every other role in the
-- organisation, so those are not GRAC_ADMIN's to give back.
--
-- ASCII-only on purpose (see the forward script header).
-- Idempotent: safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (223 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.pm_grant_organization_default_access','P') IS NULL
BEGIN
    PRINT 'ABORT (223 rollback): pm_grant_organization_default_access is missing -- nothing to restore. Run 217 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- pm_grant_organization_default_access -- back to the 217 body.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.pm_grant_organization_default_access
    @organization_id BIGINT        = NULL,          -- NULL = every active organisation
    @entered_by      NVARCHAR(100) = N'system',
    @menus_granted   INT           = 0 OUTPUT,
    @flags_enabled   INT           = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @menus_granted = 0;
    SET @flags_enabled = 0;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id
    );
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    -- 1a. Menu permissions -- Admin role of every in-scope organisation
    --     gets full rights on every active menu it does not already
    --     have a row for.
    INSERT grac_practice.organization_role_menu_permission
        (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
         status, record_status_id, entered_by, entered_dt)
    SELECT r.role_id, m.menu_id, 1, 1, 1, 1, 1,
           N'Active', @active_record_status_id, @entered_by, SYSUTCDATETIME()
    FROM grac_practice.organization_role r
    JOIN grac_practice.organization o
      ON o.organization_id = r.organization_id
    CROSS JOIN grac_practice.menu_master m
    WHERE (@organization_id IS NULL OR r.organization_id = @organization_id)
      AND o.status = N'Active'
      AND r.status = N'Active'
      AND (r.role_name = N'Admin' OR r.role_code = N'ORG_ADMIN')
      AND m.status = N'Active'
      AND NOT EXISTS (
            SELECT 1
            FROM grac_practice.organization_role_menu_permission p
            WHERE p.role_id = r.role_id
              AND p.menu_id = m.menu_id
      );

    SET @menus_granted = @@ROWCOUNT;

    -- 1b. Screen feature flags -- every active 'screen.%' flag is turned
    --     ON for in-scope organisations that have no row yet. Flags an
    --     operator has explicitly switched OFF keep their row and stay
    --     OFF.
    INSERT grac_practice.feature_flag
        (organization_id, feature_flag_id, is_enabled, notes, entered_by, entered_dt)
    SELECT o.organization_id, fm.feature_flag_id, 1,
           N'Default access provisioned by pm_grant_organization_default_access.',
           @entered_by, SYSUTCDATETIME()
    FROM grac_practice.organization o
    CROSS JOIN grac_practice.feature_flag_master fm
    WHERE (@organization_id IS NULL OR o.organization_id = @organization_id)
      AND o.status = N'Active'
      AND fm.is_active = 1
      AND fm.feature_code LIKE N'screen.%'
      AND NOT EXISTS (
            SELECT 1
            FROM grac_practice.feature_flag ff
            WHERE ff.organization_id = o.organization_id
              AND ff.feature_flag_id = fm.feature_flag_id
      );

    SET @flags_enabled = @@ROWCOUNT;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 223 rollback verification ===';

SELECT 'proc no longer matches GRAC_ADMIN' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.pm_grant_organization_default_access','P'))
                 LIKE '%GRAC_ADMIN%'
            THEN 'FAIL -- still carries the 223 predicate' ELSE 'PASS' END AS Result
UNION ALL
SELECT 'grants written by 223 are still in place',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission
                          WHERE entered_by = N'seed-223')
            THEN 'YES -- left deliberately, see the header' ELSE 'none found' END;

PRINT '';
PRINT '223 rollback complete.';
PRINT 'Menus seeded by a FUTURE module will no longer reach GRAC_ADMIN on';
PRINT 'their own -- re-run section 2 of 220_grac_admin_users.sql after any';
PRINT 'migration that seeds new menus, as that script''s header describes.';
GO

SET NOEXEC OFF;
GO
