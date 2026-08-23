-- =====================================================================
-- 217 Organization default access provisioning -- ROLLBACK
--
-- Undoes database/217_organization_default_access.sql:
--   1. Removes ONLY the rows the 217 backfill inserted, identified by
--      entered_by = 'seed-217'. Grants written at provisioning time
--      carry the caller's entered_by (the signed-in admin's id), so a
--      rollback never strips access from an organisation that was
--      created through the normal flow.
--   2. Restores grac_practice.pm_create_organization_admin to the exact
--      034_simplified_role_model.sql body (no default-access call, no
--      MenusGranted / FlagsEnabled columns).
--   3. Drops grac_practice.pm_grant_organization_default_access.
--
-- Run order matters: drop the proc last, because step 2 is what removes
-- the only reference to it.
--
-- NOTE: the Web tier reads MenusGranted / FlagsEnabled defensively
-- (missing columns fall back to 0), so rolling the DB back on its own
-- does not break PracticeManagementGatewayController.
--
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (217 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Remove the backfilled rows only.
-- =====================================================================
IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.organization_role_menu_permission
    WHERE entered_by = N'seed-217';

    PRINT '217 rollback: organization_role_menu_permission rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END
GO

IF OBJECT_ID('grac_practice.feature_flag','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.feature_flag
    WHERE entered_by = N'seed-217';

    PRINT '217 rollback: feature_flag rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END
GO

-- =====================================================================
-- 2. Restore pm_create_organization_admin to the 034 body.
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

    SELECT
        @employee_id       AS EmployeeId,
        @admin_role_id     AS RoleId,
        @admin_email       AS Email,
        @already_existed   AS AlreadyExisted,
        CAST(0 AS BIT)     AS EmailCredentialsSent;
END
GO

-- =====================================================================
-- 3. Drop the default-access proc (now unreferenced).
-- =====================================================================
IF OBJECT_ID('grac_practice.pm_grant_organization_default_access','P') IS NOT NULL
    DROP PROCEDURE grac_practice.pm_grant_organization_default_access;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'pm_grant_organization_default_access dropped' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.pm_grant_organization_default_access','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'seed-217 menu grants remaining' AS Check_,
       COUNT(*) AS Count_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS Result
FROM grac_practice.organization_role_menu_permission
WHERE entered_by = N'seed-217';

SELECT 'seed-217 feature flags remaining' AS Check_,
       COUNT(*) AS Count_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS Result
FROM grac_practice.feature_flag
WHERE entered_by = N'seed-217';

PRINT '217 Organization default access rollback complete.';
GO

SET NOEXEC OFF;
GO
