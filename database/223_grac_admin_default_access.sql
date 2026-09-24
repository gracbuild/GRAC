-- =====================================================================
-- 223 Cross-organisation admins get the default-access top-up too
--
-- SYMPTOM
-- -------
-- Signed in as one of the GRAC Admin users created by migration 220,
-- Document Uploads, Document Acknowledgements and My Acknowledgements
-- all answer "No permission".
--
-- (Before the Forbid() fix in the same change set this was a bare HTTP
--  500 / "The practice service returned an invalid response". The page
--  now names the problem, which is how this was found.)
--
-- CAUSE
-- -----
-- Two migrations that never met.
--
-- The document module seeds its own menus and grants them itself --
-- 149, 152, 154 each MERGE a permission row for
--     WHERE r.role_name = N'Admin'
-- a hardcoded role NAME. Every module seed since 042 follows that
-- pattern.
--
-- Migration 220 could not name its cross-organisation role 'Admin'.
-- pm_create_organization_admin (034 section 1, re-issued by 217) hunts
-- for role_name = 'Admin' and forces data_scope back to 'ORGANIZATION'
-- every time it runs, so a GLOBAL scope parked on that name is reverted
-- the next time an org admin is provisioned or credentials are resent.
-- 220 therefore created 'GRAC Admin' / role_code 'GRAC_ADMIN'.
--
-- 220 granted it every menu that existed AT THE TIME, and said so:
--
--     "a menu_master row added by a FUTURE module will not reach this
--      role on its own. Re-run section 2 of this script after any
--      migration that seeds new menus."
--
-- That is a standing manual step, and this is it coming due.
--
-- FIX
-- ---
-- Stop making it manual. pm_grant_organization_default_access (217) is
-- the designated top-up path -- it already grants every active menu and
-- enables every 'screen.%' flag -- but its filter is
--     (r.role_name = N'Admin' OR r.role_code = N'ORG_ADMIN')
-- so GRAC_ADMIN falls outside it. One more predicate closes the gap
-- permanently, and section 2 below runs the proc so today's missing
-- grants land now.
--
-- WHY WIDEN THE PROC RATHER THAN RE-RUN 220
-- -----------------------------------------
-- Re-running 220 fixes the symptom and leaves the cause: the next module
-- that seeds a menu re-opens it, and nothing in the codebase would say
-- so. 217 exists precisely so "which roles get default access" is
-- answered in one place; GRAC_ADMIN belongs in that answer.
--
-- WHAT THIS DOES NOT DO
-- ---------------------
-- It does not touch the module seeds. A future module following the 149
-- pattern still grants only role_name = 'Admin' at seed time -- but from
-- here on 217's proc catches what those seeds miss, for GRAC_ADMIN and
-- ORG_ADMIN alike, and pm_create_organization_admin calls it on every
-- organisation onboarding.
--
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
--
-- Idempotent: CREATE OR ALTER, and the proc's own inserts are guarded by
-- NOT EXISTS. Safe to re-run.
--
-- DEPENDS ON: 217 (pm_grant_organization_default_access), 220 (the
--             GRAC_ADMIN role). Neither is required for the proc change
--             itself -- an organisation with no GRAC_ADMIN role simply
--             matches nothing extra.
-- Rollback:   database/223_grac_admin_default_access_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

-- ---------------------------------------------------------------------
-- Prerequisite guard -- same pattern as 217.
-- ---------------------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (223): schema grac_practice missing. Run base scripts first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.pm_grant_organization_default_access','P') IS NULL
BEGIN
    PRINT 'ABORT (223): pm_grant_organization_default_access missing. Run 217_organization_default_access.sql first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN
    PRINT 'ABORT (223): menu_master / organization_role / organization_role_menu_permission missing. Run 022 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN
    PRINT 'ABORT (223): feature_flag_master or feature_flag missing. Run 041_feature_flag.sql first.';
    SET @prereqs_ok = 0;
END

IF COL_LENGTH('grac_practice.organization_role','role_code') IS NULL
BEGIN
    PRINT 'ABORT (223): organization_role.role_code missing. Run 027_organization_access_administration.sql first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('223_grac_admin_default_access: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. pm_grant_organization_default_access -- re-issued
--
--    The 217 body, unchanged except for one predicate in step 1a:
--    role_code 'GRAC_ADMIN' now matches alongside role_name 'Admin' and
--    role_code 'ORG_ADMIN'.
--
--    Everything else is byte-for-byte 217. Keep the two in step if 217
--    is ever revised.
--
--    Still returns NO result set -- counts come back through OUTPUT
--    parameters -- because pm_create_organization_admin calls it inline
--    and an extra result set would shift the row the Web gateway reads
--    in PracticeManagementGatewayController.ExtractProvisionResult.
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

    -- 1a. Menu permissions -- the administrator roles of every in-scope
    --     organisation get full rights on every active menu they do not
    --     already have a row for.
    --
    --     GRAC_ADMIN (migration 220) is matched here as of 223. It is a
    --     cross-organisation role that cannot be called 'Admin' -- see
    --     the header of 223 -- so without this predicate every module
    --     that seeds a new menu leaves it behind.
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
      AND (r.role_name = N'Admin' OR r.role_code = N'ORG_ADMIN' OR r.role_code = N'GRAC_ADMIN')
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
-- 2. Backfill -- close today's gap for every active organisation.
--
--    INSERT-ONLY, like 217. A row deliberately set to can_view = 0 or
--    is_enabled = 0 is an operator decision and is left alone; this only
--    fills the gaps where no row exists at all.
-- =====================================================================
DECLARE @menus INT = 0, @flags INT = 0;

EXEC grac_practice.pm_grant_organization_default_access
     @organization_id = NULL,
     @entered_by      = N'seed-223',
     @menus_granted   = @menus OUTPUT,
     @flags_enabled   = @flags OUTPUT;

PRINT '223: menu grants inserted  = ' + CAST(@menus AS NVARCHAR(20));
PRINT '223: feature flags enabled = ' + CAST(@flags AS NVARCHAR(20));
GO

-- =====================================================================
-- 3. Verification
--
--    3a is the one that matters: the three document-module menus against
--    every administrator role. Anything other than PASS and the screens
--    still answer "No permission" after signing in again.
-- =====================================================================
PRINT '=== 223 verification ===';

SELECT 'proc matches GRAC_ADMIN' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.pm_grant_organization_default_access','P'))
                 LIKE '%GRAC_ADMIN%'
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '=== 3a. Document module menus, per administrator role ===';
SELECT o.organization_id,
       o.organization_name,
       r.role_name,
       r.role_code,
       m.menu_key,
       CASE WHEN p.role_menu_permission_id IS NULL THEN 'MISSING'
            WHEN p.can_view = 0                    THEN 'can_view = 0'
            WHEN p.status <> N'Active'             THEN 'row not Active'
            ELSE 'PASS' END AS Result
FROM grac_practice.organization o
JOIN grac_practice.organization_role r
  ON r.organization_id = o.organization_id
 AND r.status = N'Active'
 AND (r.role_name = N'Admin' OR r.role_code = N'ORG_ADMIN' OR r.role_code = N'GRAC_ADMIN')
CROSS JOIN grac_practice.menu_master m
LEFT JOIN grac_practice.organization_role_menu_permission p
  ON p.role_id = r.role_id AND p.menu_id = m.menu_id
WHERE o.status = N'Active'
  AND m.menu_key IN (N'document-uploads', N'document-acknowledgements', N'my-acknowledgements')
ORDER BY o.organization_id, r.role_name, m.menu_key;

-- A menu row that is not Active is invisible to the grant above AND to
-- PracticeAuthenticationService.LoadPermissionsAsync, so it would look
-- like a missing grant when it is really a missing menu. Separate it.
PRINT '=== 3b. Are the three menus themselves Active? ===';
SELECT k.menu_key,
       CASE WHEN m.menu_id IS NULL       THEN 'MISSING -- run 149 / 152 / 154'
            WHEN m.status <> N'Active'   THEN 'NOT ACTIVE -- status = ' + m.status
            ELSE 'PASS' END AS Result
FROM (VALUES (N'document-uploads'), (N'document-acknowledgements'), (N'my-acknowledgements')) AS k(menu_key)
LEFT JOIN grac_practice.menu_master m ON m.menu_key = k.menu_key;

PRINT '=== 3c. Screen feature flags for the three screens ===';
IF OBJECT_ID('grac_practice.fn_pm_feature_enabled','FN') IS NOT NULL
    SELECT o.organization_id,
           o.organization_name,
           fm.feature_code,
           grac_practice.fn_pm_feature_enabled(o.organization_id, fm.feature_code) AS Enabled
    FROM grac_practice.organization o
    CROSS JOIN grac_practice.feature_flag_master fm
    WHERE o.status = N'Active'
      AND fm.is_active = 1
      AND fm.feature_code IN (N'screen.document-uploads',
                              N'screen.document-acknowledgements',
                              N'screen.my-acknowledgements')
    ORDER BY o.organization_id, fm.feature_code;
ELSE
    PRINT 'fn_pm_feature_enabled not present -- run 041_feature_flag.sql.';

PRINT '';
PRINT '223 complete.';
PRINT '';
PRINT 'SIGN OUT AND SIGN IN AGAIN. Permission tokens are built once, at';
PRINT 'sign-in, by PracticeAuthenticationService.LoadPermissionsAsync and';
PRINT 'stored in the session -- a grant added while somebody is logged in';
PRINT 'does nothing until their next sign-in.';
GO

SET NOEXEC OFF;
GO
