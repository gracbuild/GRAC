-- =====================================================================
-- 217 Organization default access provisioning
--
-- PROBLEM
--   grac_practice.pm_create_organization_admin (migration 034) creates
--   the organisation, the ORGANIZATION-scoped 'Admin' role and the
--   Organisation GRAC Admin employee -- but it never writes a single row
--   into grac_practice.organization_role_menu_permission, and never
--   writes a grac_practice.feature_flag row.
--
--   PracticeAuthenticationService.LoadPermissionsAsync builds the login
--   permission set purely from organization_role_menu_permission, and
--   grac_practice.fn_pm_feature_enabled resolves
--       per-org row > feature_flag_master.default_enabled (0) > 0.
--
--   Net effect for every organisation created after 034: the Admin has
--   no menu grants and no screen flags, so Gap Center, Task Center and
--   Exception Centre answer "no permission" / "not available".
--
--   Menu seeds 042 (tasks), 050 (gaps) and 163 (exception-centre) each
--   granted only the organisations that existed when they were run, so
--   the hole re-opens for every organisation added afterwards.
--
-- FIX
--   1. New proc grac_practice.pm_grant_organization_default_access --
--      one reusable place that grants an organisation's Admin role full
--      rights on every active menu_master row, and enables every active
--      'screen.%' feature flag for that organisation.
--      @organization_id = NULL means "every active organisation", which
--      is what the backfill in section 3 uses.
--   2. pm_create_organization_admin now calls it, so provisioning a new
--      organisation grants access automatically. The proc's result set
--      gains MenusGranted / FlagsEnabled so the Web tier can report it.
--   3. Backfill for every organisation that exists today.
--
-- INSERT-ONLY ON PURPOSE
--   Existing (role_id, menu_id) and (organization_id, feature_flag_id)
--   rows are left untouched. A row that is deliberately set to
--   can_view = 0 / is_enabled = 0 is an operator decision; this script
--   only fills the gaps where no row exists at all. That is what causes
--   the "no permission" symptom.
--
-- NEW MODULES STILL NEED THEIR OWN MENU SEED
--   This proc grants what is in menu_master *now*. A future module must
--   still ship its own menu_master + feature_flag_master seed (the 042 /
--   050 / 163 pattern) to backfill organisations that already exist.
--   What it no longer needs to worry about is organisations created
--   later -- those are covered from here on.
--
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
--
-- Idempotent: NOT EXISTS guards on natural keys; safe to re-run.
--
-- DEPENDS ON: 022 (menu_master, organization_role_menu_permission),
--             034 (pm_create_organization_admin), 041 (feature_flag).
-- Rollback:   database/217_organization_default_access_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

-- ---------------------------------------------------------------------
-- Prerequisite guard -- same pattern as 042 / 050 / 163.
-- ---------------------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (217): schema grac_practice missing. Run base scripts first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN
    PRINT 'ABORT (217): menu_master / organization_role / organization_role_menu_permission missing. Run 022 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN
    PRINT 'ABORT (217): feature_flag_master or feature_flag missing. Run 041_feature_flag.sql first.';
    SET @prereqs_ok = 0;
END

IF COL_LENGTH('grac_practice.organization_role','role_code') IS NULL
BEGIN
    PRINT 'ABORT (217): organization_role.role_code missing. Run 027_organization_access_administration.sql first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.pm_create_organization_admin','P') IS NULL
BEGIN
    PRINT 'ABORT (217): pm_create_organization_admin missing. Run 034_simplified_role_model.sql first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('217_organization_default_access: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. pm_grant_organization_default_access
--
--    Grants the default access set. Deliberately returns NO result set
--    (counts come back through OUTPUT parameters) because
--    pm_create_organization_admin calls it inline, and an extra result
--    set would shift the row the Web gateway reads in
--    PracticeManagementGatewayController.ExtractProvisionResult.
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
-- 2. pm_create_organization_admin -- re-issued from the 034 body with
--    one addition: step 3d calls the new proc, and the result set
--    carries MenusGranted / FlagsEnabled.
--
--    Everything above 3d is byte-for-byte the 034 behaviour; keep the
--    two in step if 034 is ever revised.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.pm_create_organization_admin
    @organization_id  BIGINT,
    @admin_email      NVARCHAR(250),
    @admin_name       NVARCHAR(200),
    @password_hash    NVARCHAR(500),
    @entered_by       NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id
    );
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    IF @organization_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53410, 'pm_create_organization_admin: organization not found.', 1;
    IF LEN(ISNULL(@admin_email, N'')) = 0
        THROW 53411, 'pm_create_organization_admin: admin email is required.', 1;
    IF LEN(ISNULL(@password_hash, N'')) = 0
        THROW 53412, 'pm_create_organization_admin: password hash is required.', 1;

    -- 3a. Ensure an ORGANIZATION-scoped Admin role exists for this org.
    DECLARE @admin_role_id BIGINT;
    SELECT TOP 1 @admin_role_id = role_id
    FROM grac_practice.organization_role
    WHERE organization_id = @organization_id AND role_name = 'Admin' AND status = 'Active'
    ORDER BY role_id;

    IF @admin_role_id IS NULL
    BEGIN
        INSERT grac_practice.organization_role(organization_id, role_name, role_code, data_scope, description, status, record_status_id, entered_by, entered_dt)
        VALUES(@organization_id, N'Admin', N'ORG_ADMIN', N'ORGANIZATION',
               N'Organisation-scoped GRAC administrator (auto-created).',
               N'Active', @active_record_status_id, @entered_by, SYSUTCDATETIME());
        SET @admin_role_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        -- If the role already exists but got carried over from the old
        -- migration-032 seed, force it back to ORGANIZATION.
        UPDATE grac_practice.organization_role
        SET data_scope = 'ORGANIZATION',
            updated_by = @entered_by,
            updated_dt = SYSUTCDATETIME()
        WHERE role_id = @admin_role_id AND data_scope <> 'ORGANIZATION';
    END

    -- 3b. Create or refresh the admin employee row.
    DECLARE @employee_id BIGINT, @already_existed BIT = 0;
    SELECT TOP 1 @employee_id = employee_id
    FROM grac_practice.organization_employee
    WHERE organization_id = @organization_id
      AND (LOWER(email) = LOWER(@admin_email) OR LOWER(employee_code) = LOWER(@admin_email))
    ORDER BY employee_id;

    IF @employee_id IS NULL
    BEGIN
        DECLARE @employee_code NVARCHAR(80) = N'ORGADMIN-' + CAST(@organization_id AS NVARCHAR(20));
        INSERT grac_practice.organization_employee(
            organization_id, employee_code, employee_name, email, password_hash,
            role_id, force_password_change, email_credentials_sent,
            status, record_status_id, entered_by, entered_dt)
        VALUES(
            @organization_id, @employee_code, ISNULL(@admin_name, @admin_email), @admin_email, @password_hash,
            @admin_role_id, 1, 0,
            N'Active', @active_record_status_id, @entered_by, SYSUTCDATETIME());
        SET @employee_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        SET @already_existed = 1;
        UPDATE grac_practice.organization_employee
        SET password_hash = @password_hash,
            role_id = ISNULL(role_id, @admin_role_id),
            force_password_change = 1,
            email_credentials_sent = 0,
            status = N'Active',
            updated_by = @entered_by,
            updated_dt = SYSUTCDATETIME()
        WHERE employee_id = @employee_id;
    END

    -- 3c. Map the employee to the admin role (multi-role table from 027).
    IF OBJECT_ID('grac_practice.organization_employee_role','U') IS NOT NULL
    BEGIN
        IF NOT EXISTS (
            SELECT 1 FROM grac_practice.organization_employee_role
            WHERE employee_id = @employee_id AND role_id = @admin_role_id
        )
        INSERT grac_practice.organization_employee_role(employee_id, role_id, status, record_status_id, entered_by, entered_dt)
        VALUES(@employee_id, @admin_role_id, N'Active', @active_record_status_id, @entered_by, SYSUTCDATETIME());
    END

    -- 3d. (217) Grant the default access set so the brand-new admin can
    --     actually open Gap Center / Task Center / Exception Centre and
    --     every other registered menu. Insert-only, so re-provisioning an
    --     existing organisation never clobbers tuned permissions.
    DECLARE @menus_granted INT = 0, @flags_enabled INT = 0;
    EXEC grac_practice.pm_grant_organization_default_access
         @organization_id = @organization_id,
         @entered_by      = @entered_by,
         @menus_granted   = @menus_granted OUTPUT,
         @flags_enabled   = @flags_enabled OUTPUT;

    SELECT
        @employee_id       AS EmployeeId,
        @admin_role_id     AS RoleId,
        @admin_email       AS Email,
        @already_existed   AS AlreadyExisted,
        CAST(0 AS BIT)     AS EmailCredentialsSent,
        @menus_granted     AS MenusGranted,
        @flags_enabled     AS FlagsEnabled;
END
GO

-- =====================================================================
-- 3. Backfill -- every organisation that exists today.
--    entered_by = 'seed-217' is what the rollback script keys on, so do
--    not change it without changing the rollback too.
-- =====================================================================
DECLARE @backfill_menus INT = 0, @backfill_flags INT = 0;

EXEC grac_practice.pm_grant_organization_default_access
     @organization_id = NULL,
     @entered_by      = N'seed-217',
     @menus_granted   = @backfill_menus OUTPUT,
     @flags_enabled   = @backfill_flags OUTPUT;

SELECT 'Backfill: menu permissions inserted' AS Check_, @backfill_menus AS Count_;
SELECT 'Backfill: screen feature flags enabled' AS Check_, @backfill_flags AS Count_;
GO

-- =====================================================================
-- Post-seed sanity report
-- =====================================================================
SELECT 'pm_grant_organization_default_access created' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.pm_grant_organization_default_access','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- Any active organisation whose Admin role is still missing a grant on
-- one of the three centres is a FAIL.
SELECT 'Active orgs missing gaps/tasks/exception-centre grants' AS Check_,
       COUNT(*) AS OrgCount,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS Result
FROM grac_practice.organization o
WHERE o.status = N'Active'
  AND EXISTS (
        SELECT 1
        FROM grac_practice.menu_master m
        WHERE m.status = N'Active'
          AND m.menu_key IN (N'gaps', N'tasks', N'exception-centre')
          AND NOT EXISTS (
                SELECT 1
                FROM grac_practice.organization_role_menu_permission p
                JOIN grac_practice.organization_role r ON r.role_id = p.role_id
                WHERE r.organization_id = o.organization_id
                  AND r.status = N'Active'
                  AND (r.role_name = N'Admin' OR r.role_code = N'ORG_ADMIN')
                  AND p.menu_id = m.menu_id
                  AND p.can_view = 1
                  AND p.status = N'Active'
          )
  );

-- Same shape for the two screen flags the centres probe.
SELECT 'Active orgs with screen.gaps / screen.tasks resolved OFF' AS Check_,
       COUNT(*) AS OrgCount,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'REVIEW' END AS Result
FROM grac_practice.organization o
WHERE o.status = N'Active'
  AND (grac_practice.fn_pm_feature_enabled(o.organization_id, N'screen.gaps') = 0
       OR grac_practice.fn_pm_feature_enabled(o.organization_id, N'screen.tasks') = 0);

SELECT 'Admin menu grants per organisation' AS Check_,
       o.organization_id,
       o.organization_name,
       COUNT(p.role_menu_permission_id) AS GrantedMenus
FROM grac_practice.organization o
LEFT JOIN grac_practice.organization_role r
       ON r.organization_id = o.organization_id
      AND r.status = N'Active'
      AND (r.role_name = N'Admin' OR r.role_code = N'ORG_ADMIN')
LEFT JOIN grac_practice.organization_role_menu_permission p
       ON p.role_id = r.role_id
      AND p.status = N'Active'
WHERE o.status = N'Active'
GROUP BY o.organization_id, o.organization_name
ORDER BY o.organization_id;

PRINT '217 Organization default access provisioning complete.';
GO

SET NOEXEC OFF;
GO
