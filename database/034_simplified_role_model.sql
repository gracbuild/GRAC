-- =====================================================================
-- 034 Simplified Role Model
--
-- Implements the "simplified role model" the product now standardises on:
--
--   Rule 1 — the default Admin role for an organisation is scoped to
--            ORGANIZATION, not GLOBAL. GLOBAL is reserved for internal
--            platform administrators (created outside this flow).
--
--   Rule 6 — organisation creation must not depend on email delivery.
--            The DB step creates the org, the auto-generated Organisation
--            GRAC Admin employee, the multi-role assignment, and the
--            one-time password. Emailing credentials is best-effort and
--            happens outside the transaction (see PracticeEmailService).
--
--   Rule 5 — backend enforcement of release / statement scope. This
--            script adds scalar helpers `pm_is_release_visible` and
--            `pm_is_statement_visible` that wrap the table-valued
--            functions from migration 032. Both C# fallback queries and
--            the future SP rewrite call these helpers rather than
--            duplicating the ownership logic.
--
-- Re-run database/deployment/02_Create_Procedures.sql AFTER this script.
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 53400, 'PracticeManagement schema grac_practice is missing. Run base scripts first.', 1;
GO

DECLARE @active_record_status_id INT = (
    SELECT TOP 1 record_status_id
    FROM grac_practice.record_status_master
    WHERE status_code = 'ACTIVE' OR status_name = 'Active'
    ORDER BY record_status_id
);
IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

-- =====================================================================
-- 1. Reverse the 032 seed: Admin roles for tenant orgs must be scoped
--    to ORGANIZATION. Only the internal "platform" org (if one exists
--    and is explicitly tagged) may keep GLOBAL scope.
--
--    Migration 032 unconditionally set every Admin role to GLOBAL. We
--    now demote them, except for any org that has been explicitly
--    marked as the platform tenant via organization.organization_code
--    starting with 'GRAC_PLATFORM'.
-- =====================================================================
UPDATE r
SET r.data_scope = 'ORGANIZATION',
    r.updated_by = 'seed-034',
    r.updated_dt = SYSUTCDATETIME()
FROM grac_practice.organization_role r
JOIN grac_practice.organization o ON o.organization_id = r.organization_id
WHERE r.role_name = 'Admin'
  AND r.data_scope = 'GLOBAL'
  AND ISNULL(o.organization_code, N'') NOT LIKE N'GRAC_PLATFORM%';
GO

-- Also update the default constraint documentation: new Admin roles
-- should inherit the column default 'ORGANIZATION' (already set in 032).
-- Nothing to alter here.

-- =====================================================================
-- 2. Scalar helpers wrapping migration 032's table-valued functions.
--
--    These are what the C# service layer and pm_manage_practice_repository
--    call to reject unauthorised release / statement actions.
--
--    A GLOBAL or ORGANIZATION scope caller always passes; narrower scopes
--    only pass when the release/statement is in fn_visible_releases /
--    fn_visible_statements.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.pm_is_release_visible
(
    @employee_id      BIGINT,
    @data_scope       NVARCHAR(30),
    @organization_id  BIGINT,
    @subscription_id  BIGINT
)
RETURNS BIT
AS
BEGIN
    IF @subscription_id IS NULL RETURN 0;
    IF @data_scope IN ('GLOBAL', 'ORGANIZATION') RETURN 1;

    DECLARE @allowed BIT = 0;
    IF EXISTS (
        SELECT 1
        FROM grac_practice.fn_visible_releases(@employee_id, @data_scope, @organization_id) v
        WHERE v.subscription_id = @subscription_id
    ) SET @allowed = 1;
    RETURN @allowed;
END
GO

IF OBJECT_ID('grac_practice.custom_release_statement','U') IS NOT NULL
BEGIN
    EXEC('
CREATE OR ALTER FUNCTION grac_practice.pm_is_statement_visible
(
    @employee_id       BIGINT,
    @data_scope        NVARCHAR(30),
    @organization_id   BIGINT,
    @custom_statement_id BIGINT
)
RETURNS BIT
AS
BEGIN
    IF @custom_statement_id IS NULL RETURN 0;
    IF @data_scope IN (''GLOBAL'', ''ORGANIZATION'') RETURN 1;

    DECLARE @allowed BIT = 0;
    IF EXISTS (
        SELECT 1
        FROM grac_practice.fn_visible_statements(@employee_id, @data_scope, @organization_id) v
        WHERE v.custom_statement_id = @custom_statement_id
    ) SET @allowed = 1;
    RETURN @allowed;
END
');
END
GO

-- =====================================================================
-- 3. pm_create_organization_admin
--    Called by the organisation-setup flow after an org row has been
--    inserted. Creates:
--      * an "Admin" organization_role scoped to ORGANIZATION (if none)
--      * an "Organization GRAC Admin" organization_employee
--      * the role assignment in organization_employee_role
--      * a one-time password hash (caller supplies the hash + plain
--        password) and force_password_change=1, email_credentials_sent=0
--
--    The plaintext password is generated in the C# layer so we don't
--    persist it here. This proc only stores the hash.
--
--    Returns a single row with employee_id, employee_code, email and a
--    flag indicating whether the admin was created or already existed.
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
-- 4. pm_mark_credentials_emailed
--    Best-effort flag flipped by the C# email service after a successful
--    SMTP send. Kept as a dedicated SP so the org-setup flow does not
--    have to expose employee update permissions.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.pm_mark_credentials_emailed
    @employee_id BIGINT,
    @entered_by  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE grac_practice.organization_employee
    SET email_credentials_sent = 1,
        updated_by = @entered_by,
        updated_dt = SYSUTCDATETIME()
    WHERE employee_id = @employee_id;
END
GO

-- =====================================================================
-- 5. Convenience view exposing which admins still need credentials.
--    Used by the "Resend credentials" action on the users tab.
-- =====================================================================
CREATE OR ALTER VIEW grac_practice.vw_pending_admin_credentials
AS
SELECT
    e.employee_id,
    e.organization_id,
    e.employee_code,
    e.employee_name,
    e.email,
    e.email_credentials_sent,
    e.force_password_change,
    r.role_name,
    r.data_scope
FROM grac_practice.organization_employee e
LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id
WHERE e.status = N'Active'
  AND ISNULL(e.email_credentials_sent, 0) = 0;
GO

SELECT '034 Simplified Role Model applied. Re-run database/deployment/02_Create_Procedures.sql so the SPs pick up the new helpers.' AS Message;
