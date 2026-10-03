-- =====================================================================
-- 416 MSP (organisation 1) admin users -- Adarsh Narayanan, Arathi J
--
-- WHAT THIS PROVISIONS
--   Two sign-in accounts in organisation 1 (organization_code MSP) with
--   that organisation's ORGANIZATION-scoped 'Admin' role -- the same
--   role and menu rights the MSP GRAC Admin (msp.admin@grac.in, 273)
--   signs in with.
--
--     adarsh.narayan@grac.in   Adarsh Narayanan   employee_code ADARSH.NARAYAN
--     arathi.j@grac.in         Arathi J           employee_code ARATHI.J
--
-- WHAT EACH ACCOUNT GETS (mirrors pm_create_organization_admin 034/217
-- plus the home-organisation row 273 section 5 adds)
--   organization_employee        role_id = org 1 'Admin', status Active,
--                                force_password_change = 1,
--                                email_credentials_sent = 0
--   organization_employee_role   employee -> org 1 'Admin' (M:N map)
--   user_organization_map        organisation 1, access_role 'Admin',
--                                is_default = 1
--   organization_role_menu_permission  topped up for org 1's Admin via
--                                pm_grant_organization_default_access
--                                (insert-only; never clobbers tuned rows)
--
-- WHY NOT pm_create_organization_admin
--   It hardcodes employee_code 'ORGADMIN-<org id>' on insert, which
--   organisation 1 already uses -- a second call would collide on
--   uq_pm_employee_org_code. Its steps are reproduced here per user.
--
-- WHY NOT sp_org_user_save
--   Since 366 it requires a Department, and it maps the user with
--   access_role 'Organization User' and writes no
--   organization_employee_role row. These are admin accounts, provisioned
--   the same way the existing org admins were (no department). A
--   Department can be added later from Organization -> Users; the screen
--   will ask for one on the next edit.
--
-- PASSWORD
--   Default Grac@123 (UserProvisioning:DefaultPassword). Hashes generated
--   offline with the exact Web/Security/PasswordHasher.cs parameters --
--   PBKDF2-HMAC-SHA256, 210000 iterations, 16-byte salt, 32-byte key,
--   "<iterations>.<base64 salt>.<base64 hash>", one salt per account.
--   force_password_change = 1, so LoginController.Index redirects to
--   ChangePassword before any session is issued.
--
-- SAFETY GUARDS (section 0)
--   * organisation 1 must exist, be Active and carry code MSP -- aborts
--     with the organisation list otherwise, rather than seeding the
--     wrong tenant.
--   * org 1 must already have an Active 'Admin' role (273/322 create it).
--   * either email already held in a DIFFERENT organisation -> abort
--     (ux_pm_employee_email is global).
--   * either employee_code already held in org 1 by a different email
--     -> abort.
--
-- RE-RUNNABLE
--   An account that already exists in org 1 is reactivated and its role
--   / map rows re-synchronised, but its password is NOT reset -- a user
--   who has already chosen a password keeps it. Set @ForcePasswordReset
--   = 1 in section 1 to push both back to Grac@123 with the first-login
--   change re-armed.
--
-- ASCII-only on purpose (sqlcmd codepage safety).
-- DEPENDS ON: 002, 027, 032/034, 217 (pm_grant_organization_default_access),
--             273 (MSP organisation).
-- Rollback:   database/416_msp_admin_users_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

-- ---------------------------------------------------------------------
-- 0. Prerequisite and collision guards.
-- ---------------------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (416): schema grac_practice missing. Run base scripts first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 1 AND (
       OBJECT_ID('grac_practice.organization','U') IS NULL
    OR OBJECT_ID('grac_practice.organization_employee','U') IS NULL
    OR OBJECT_ID('grac_practice.organization_role','U') IS NULL
    OR OBJECT_ID('grac_practice.organization_employee_role','U') IS NULL
    OR OBJECT_ID('grac_practice.user_organization_map','U') IS NULL)
BEGIN
    PRINT 'ABORT (416): core organisation tables missing. Run 002/027 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 1 AND (
       COL_LENGTH('grac_practice.organization_employee','force_password_change') IS NULL
    OR COL_LENGTH('grac_practice.organization_employee','email_credentials_sent') IS NULL)
BEGIN
    PRINT 'ABORT (416): organization_employee is missing columns from 032/034. Run those first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.pm_grant_organization_default_access','P') IS NULL
BEGIN
    PRINT 'ABORT (416): pm_grant_organization_default_access missing. Run 217 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 1 AND NOT EXISTS (
    SELECT 1 FROM grac_practice.organization
    WHERE organization_id = 1 AND status = N'Active' AND organization_code = N'MSP')
BEGIN
    PRINT 'ABORT (416): organisation 1 is not the Active MSP organisation. Organisations:';
    SELECT organization_id, organization_code, organization_name, status
    FROM grac_practice.organization ORDER BY organization_id;
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 1 AND NOT EXISTS (
    SELECT 1 FROM grac_practice.organization_role
    WHERE organization_id = 1 AND role_name = N'Admin' AND status = N'Active')
BEGIN
    PRINT 'ABORT (416): organisation 1 has no Active Admin role. Run 273 (or 322) first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 1 AND EXISTS (
    SELECT 1 FROM grac_practice.organization_employee
    WHERE LOWER(LTRIM(RTRIM(email))) IN (N'adarsh.narayan@grac.in', N'arathi.j@grac.in')
      AND organization_id <> 1)
BEGIN
    PRINT 'ABORT (416): one of the emails already exists in a different organisation:';
    SELECT employee_id, organization_id, employee_code, employee_name, email, status
    FROM grac_practice.organization_employee
    WHERE LOWER(LTRIM(RTRIM(email))) IN (N'adarsh.narayan@grac.in', N'arathi.j@grac.in');
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 1 AND EXISTS (
    SELECT 1 FROM grac_practice.organization_employee e
    JOIN (VALUES (N'ADARSH.NARAYAN', N'adarsh.narayan@grac.in'),
                 (N'ARATHI.J',       N'arathi.j@grac.in')) s(code, email)
      ON e.organization_id = 1 AND e.employee_code = s.code
    WHERE LOWER(LTRIM(RTRIM(e.email))) <> s.email)
BEGIN
    PRINT 'ABORT (416): employee_code ADARSH.NARAYAN or ARATHI.J is already used in organisation 1 under a different email:';
    SELECT employee_id, employee_code, employee_name, email, status
    FROM grac_practice.organization_employee
    WHERE organization_id = 1 AND employee_code IN (N'ADARSH.NARAYAN', N'ARATHI.J');
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('416_msp_admin_users: prerequisites/guards failed -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Create or refresh the two accounts.
-- =====================================================================
SET XACT_ABORT ON;
BEGIN TRY
BEGIN TRAN;

DECLARE @ForcePasswordReset BIT           = 0;  -- 1 = re-stamp Grac@123 on existing rows
DECLARE @org_id             BIGINT        = 1;
DECLARE @entered_by         NVARCHAR(100) = N'seed-416';

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
    WHERE status_code IN (N'Active', N'ACTIVE') OR status_name = N'Active'
    ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;

DECLARE @admin_role_id BIGINT = (
    SELECT TOP 1 role_id FROM grac_practice.organization_role
    WHERE organization_id = @org_id AND role_name = N'Admin' AND status = N'Active'
    ORDER BY role_id);

DECLARE @seed TABLE(
    employee_code NVARCHAR(80)  NOT NULL,
    employee_name NVARCHAR(200) NOT NULL,
    email         NVARCHAR(250) NOT NULL,
    password_hash NVARCHAR(500) NOT NULL);

-- PBKDF2-HMAC-SHA256, 210000 iterations, per-account salt. Plaintext: Grac@123
INSERT @seed(employee_code, employee_name, email, password_hash) VALUES
 (N'ADARSH.NARAYAN', N'Adarsh Narayanan', N'adarsh.narayan@grac.in',
  N'210000.vZwRojdcuOCAs9Kz7num/A==.2j9mro85MaPlcMHG1YEu+lPZ+AlosIKvOvOrfwE7HMs='),
 (N'ARATHI.J',       N'Arathi J',         N'arathi.j@grac.in',
  N'210000.BSrfmM+Ru1f2LIFf+wSL8g==.kFKdw5IjhaCzbsnQJrAwHzRJi6/RmYGLOKHa7gZacVI=');

-- 1a. Existing rows in org 1: reactivate, point at Admin; password only
--     on @ForcePasswordReset = 1.
UPDATE e
   SET e.employee_name          = s.employee_name,
       e.role_id                = @admin_role_id,
       e.status                 = N'Active',
       e.record_status_id       = @active_rs,
       e.password_hash          = CASE WHEN @ForcePasswordReset = 1 THEN s.password_hash ELSE e.password_hash END,
       e.force_password_change  = CASE WHEN @ForcePasswordReset = 1 THEN 1 ELSE e.force_password_change END,
       e.email_credentials_sent = CASE WHEN @ForcePasswordReset = 1 THEN 0 ELSE e.email_credentials_sent END,
       e.updated_by             = @entered_by,
       e.updated_dt             = SYSUTCDATETIME()
FROM grac_practice.organization_employee e
JOIN @seed s ON LOWER(LTRIM(RTRIM(e.email))) = s.email
WHERE e.organization_id = @org_id;
PRINT '416: existing accounts refreshed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

-- 1b. New rows.
INSERT grac_practice.organization_employee(
    organization_id, employee_code, employee_name, email, password_hash,
    role_id, force_password_change, email_credentials_sent,
    status, record_status_id, entered_by, entered_dt)
SELECT @org_id, s.employee_code, s.employee_name, s.email, s.password_hash,
       @admin_role_id, 1, 0,
       N'Active', @active_rs, @entered_by, SYSUTCDATETIME()
FROM @seed s
WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee e
                  WHERE LOWER(LTRIM(RTRIM(e.email))) = s.email);
PRINT '416: accounts created = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

DECLARE @targets TABLE(employee_id BIGINT PRIMARY KEY, email NVARCHAR(250) NOT NULL);
INSERT @targets(employee_id, email)
SELECT e.employee_id, s.email
FROM grac_practice.organization_employee e
JOIN @seed s ON LOWER(LTRIM(RTRIM(e.email))) = s.email
WHERE e.organization_id = @org_id;

-- 1c. Admin role in the M:N map (reactivate, else insert).
UPDATE er
   SET er.status = N'Active', er.record_status_id = @active_rs,
       er.updated_by = @entered_by, er.updated_dt = SYSUTCDATETIME()
FROM grac_practice.organization_employee_role er
JOIN @targets t ON t.employee_id = er.employee_id
WHERE er.role_id = @admin_role_id AND er.status <> N'Active';

INSERT grac_practice.organization_employee_role(employee_id, role_id, status, record_status_id, entered_by, entered_dt)
SELECT t.employee_id, @admin_role_id, N'Active', @active_rs, @entered_by, SYSUTCDATETIME()
FROM @targets t
WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee_role er
                  WHERE er.employee_id = t.employee_id AND er.role_id = @admin_role_id);

-- 1d. Home-organisation row -- what the gateway's allowed-organisation
--     list is built from (see 273 section 5).
UPDATE m
   SET m.status = N'Active', m.record_status_id = @active_rs
FROM grac_practice.user_organization_map m
JOIN @targets t ON t.email = m.user_email
WHERE m.organization_id = @org_id AND m.status <> N'Active';

INSERT grac_practice.user_organization_map
    (user_email, organization_id, access_role, is_default, status, record_status_id, entered_by)
SELECT t.email, @org_id, N'Admin', 1, N'Active', @active_rs, @entered_by
FROM @targets t
WHERE NOT EXISTS (SELECT 1 FROM grac_practice.user_organization_map m
                  WHERE m.user_email = t.email AND m.organization_id = @org_id);

-- 1e. Top up org 1 Admin's menu grants / screen flags (insert-only).
DECLARE @menus_granted INT = 0, @flags_enabled INT = 0;
EXEC grac_practice.pm_grant_organization_default_access
     @organization_id = @org_id,
     @entered_by      = @entered_by,
     @menus_granted   = @menus_granted OUTPUT,
     @flags_enabled   = @flags_enabled OUTPUT;
PRINT '416: menu grants topped up = ' + CAST(@menus_granted AS NVARCHAR(20))
    + ', screen flags enabled = ' + CAST(@flags_enabled AS NVARCHAR(20));

COMMIT;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
END CATCH
GO

-- =====================================================================
-- 2. Verification. Expect two rows: org 1 / MSP, Active, role Admin
--    (ORGANIZATION scope), force_password_change 1, hash present, map
--    rows YES.
-- =====================================================================
PRINT '=== 416 verification ===';

SELECT e.employee_id,
       e.organization_id,
       o.organization_code,
       e.employee_code,
       e.employee_name,
       e.email,
       e.status                AS employee_status,
       rs.status_name          AS record_status,
       r.role_name,
       r.data_scope,
       e.force_password_change,
       CASE WHEN LEN(LTRIM(RTRIM(ISNULL(e.password_hash,N'')))) > 0 THEN 'present' ELSE 'MISSING' END AS password_hash_state,
       CASE WHEN er.employee_role_id IS NOT NULL THEN 'YES' ELSE 'NO' END AS employee_role_map_row,
       CASE WHEN m.user_email IS NOT NULL THEN 'YES' ELSE 'NO' END        AS user_org_map_row,
       (SELECT COUNT(*) FROM grac_practice.organization_role_menu_permission p
         WHERE p.role_id = r.role_id AND p.status = N'Active')            AS admin_menu_grants
FROM grac_practice.organization_employee e
JOIN grac_practice.organization o               ON o.organization_id = e.organization_id
LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id = e.record_status_id
LEFT JOIN grac_practice.organization_role r     ON r.role_id = e.role_id
LEFT JOIN grac_practice.organization_employee_role er
       ON er.employee_id = e.employee_id AND er.role_id = e.role_id AND er.status = N'Active'
LEFT JOIN grac_practice.user_organization_map m
       ON m.user_email = e.email AND m.organization_id = e.organization_id AND m.status = N'Active'
WHERE e.organization_id = 1
  AND LOWER(e.email) IN (N'adarsh.narayan@grac.in', N'arathi.j@grac.in')
ORDER BY e.employee_name;

PRINT '416 complete. Sign in with adarsh.narayan@grac.in / arathi.j@grac.in and Grac@123;';
PRINT 'the change-password screen appears before any session is issued.';
PRINT 'If sign-in fails, run database/_diag_user_login.sql with the email.';
GO

SET NOEXEC OFF;
GO
