-- =====================================================================
-- 322 Organisation 1 admin sign-in user
--
-- WHAT THIS PROVISIONS
--   One real, sign-in-capable database account in organisation 1:
--
--     email       admin@grac.local
--     name        Admin
--     role        organisation 1's ORGANIZATION-scoped 'Admin' role
--                 (created if org 1 does not already have one)
--     password    Grac@123 (UserProvisioning:DefaultPassword),
--                 force_password_change = 1
--
-- ****************  READ THIS BEFORE RUNNING  ****************
-- admin@grac.local is ALSO the email of the config-based ReviewLogin
-- bootstrap account (Web/appsettings*.json -- see database/220's header
-- and database/_setup_admin_employee_identity.sql for the full history).
-- That account is NOT a database row: LoginController.Index authenticates
-- against grac_practice FIRST --
--
--     var dbLogin = await loginService.AuthenticateAsync(...);
--     if (dbLogin is not null) { ... sign in as the DB user ... }
--     // only falls through to ReviewLogin:Email / ReviewLogin:PasswordHash
--     // when the line above returns null
--
-- so after this script runs, signing in with admin@grac.local:
--   * using THIS row's password (Grac@123, then whatever it is changed
--     to) signs in as this database employee -- data_scope ORGANIZATION,
--     confined to organisation 1, with only the menu rights org 1's
--     'Admin' role carries. NOT the ReviewLogin config's PM_ADMIN "*:*".
--   * using the ReviewLogin:PasswordHash plaintext still falls through to
--     the config bootstrap exactly as before, because that plaintext
--     will not verify against this row's hash. The bootstrap path is
--     unaffected AS LONG AS the two passwords stay different.
-- This trade-off (a real, organisation-scoped login shadowing part of
-- what used to be a single unambiguous bootstrap email) was confirmed
-- deliberately before this script was written -- see the alternative,
-- non-login-capable pattern in database/_setup_admin_employee_identity.sql
-- if that is ever what is wanted instead.
-- ***************************************************************
--
-- WHY pm_create_organization_admin AND NOT sp_org_user_save
--   pm_create_organization_admin (migration 034) is the exact proc the
--   organisation-setup flow already calls to provision an org's admin:
--   it creates-or-reuses an ORGANIZATION-scoped 'Admin' role for the
--   organisation (034 Rule 1 -- Admin is ORGANIZATION-scoped by default,
--   GLOBAL is reserved for accounts like database/220's), creates-or-
--   refreshes the employee row, sets force_password_change = 1 and
--   email_credentials_sent = 0, and maps the employee to the role in
--   organization_employee_role. Reusing it here avoids a second,
--   divergent copy of that logic.
--
-- PASSWORD HASH
--   T-SQL cannot produce a value PasswordHasher.Verify accepts (see
--   database/220's header for the same note), so the hash below was
--   generated offline with the exact parameters in
--   Web/Security/PasswordHasher.cs -- PBKDF2-HMAC-SHA256, 210000
--   iterations, 16-byte salt, 32-byte key, formatted
--   "<iterations>.<base64 salt>.<base64 hash>". It encodes the standard
--   first-issue password Grac@123. force_password_change = 1 means
--   LoginController.Index redirects to ChangePassword before any session
--   is issued -- the value above is a handover credential, not a stored
--   secret.
--
-- SAFETY GUARDS (section 0)
--   pm_create_organization_admin looks up an existing employee only
--   WITHIN the target organisation (organization_id = @organization_id
--   AND (email OR employee_code) = @admin_email). It does not check
--   whether admin@grac.local already exists in a DIFFERENT organisation
--   (for example because database/_setup_admin_employee_identity.sql was
--   run against it at some point) or whether organisation 1's generated
--   employee_code ORGADMIN-1 is already taken by a differently-emailed
--   row. Either case would surface as a raw constraint error from inside
--   the proc, or silently create a second, unrelated identity for the
--   same email in a different organisation. Section 0 checks both and
--   aborts with a diagnosis instead of running into either blind.
--
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
--
-- Idempotent: safe to re-run. An account that already exists in org 1
-- under this email is refreshed (password, force_password_change,
-- status), not duplicated.
--
-- DEPENDS ON: 001/002 (organization, organization_employee, organization_role),
--             027 (organization_employee_role),
--             032/034 (data_scope, force_password_change,
--                      pm_create_organization_admin, email_credentials_sent).
-- Rollback:   database/322_organization1_admin_user_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

-- ---------------------------------------------------------------------
-- 0. Prerequisite and collision guards -- same pattern as 042/050/163/
--    217/220.
-- ---------------------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (322): schema grac_practice missing. Run base scripts first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_employee','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_employee_role','U') IS NULL
BEGIN
    PRINT 'ABORT (322): core organisation tables missing. Run 001/002/027 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.pm_create_organization_admin','P') IS NULL
BEGIN
    PRINT 'ABORT (322): pm_create_organization_admin missing. Run 034 first.';
    SET @prereqs_ok = 0;
END

IF COL_LENGTH('grac_practice.organization_employee','email_credentials_sent') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','force_password_change') IS NULL
BEGIN
    PRINT 'ABORT (322): organization_employee is missing columns from 032/034. Run those first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 1 AND NOT EXISTS (
    SELECT 1 FROM grac_practice.organization
    WHERE organization_id = 1 AND status = N'Active'
)
BEGIN
    PRINT 'ABORT (322): organization_id 1 does not exist or is not Active. Active organisations:';
    SELECT organization_id, organization_code, organization_name, status
    FROM grac_practice.organization
    ORDER BY organization_id;
    SET @prereqs_ok = 0;
END

-- Collision 1: admin@grac.local already attached to a DIFFERENT
-- organisation (e.g. via _setup_admin_employee_identity.sql).
-- pm_create_organization_admin's own lookup is scoped to organization_id
-- = 1, so it would not see this row and would try to INSERT a second one.
IF @prereqs_ok = 1 AND EXISTS (
    SELECT 1 FROM grac_practice.organization_employee
    WHERE LOWER(LTRIM(RTRIM(email))) = N'admin@grac.local'
      AND organization_id <> 1
)
BEGIN
    PRINT 'ABORT (322): admin@grac.local already exists in a different organisation:';
    SELECT employee_id, organization_id, employee_code, employee_name, email, status
    FROM grac_practice.organization_employee
    WHERE LOWER(LTRIM(RTRIM(email))) = N'admin@grac.local';
    PRINT 'Resolve (move, rename, or deactivate that row) before running this script against organisation 1.';
    SET @prereqs_ok = 0;
END

-- Collision 2: organisation 1's generated employee_code ORGADMIN-1 is
-- already in use by a row with a DIFFERENT email. pm_create_organization_admin
-- hardcodes that code on INSERT and does not check for this.
IF @prereqs_ok = 1 AND EXISTS (
    SELECT 1 FROM grac_practice.organization_employee
    WHERE organization_id = 1
      AND employee_code = N'ORGADMIN-1'
      AND LOWER(LTRIM(RTRIM(email))) <> N'admin@grac.local'
)
BEGIN
    PRINT 'ABORT (322): organisation 1 already has an employee_code ORGADMIN-1 under a different email:';
    SELECT employee_id, organization_id, employee_code, employee_name, email, status
    FROM grac_practice.organization_employee
    WHERE organization_id = 1 AND employee_code = N'ORGADMIN-1';
    PRINT 'pm_create_organization_admin would collide on that code. Resolve manually before running this script.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('322_organization1_admin_user: prerequisites/guards failed -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Create or refresh the account.
-- =====================================================================
DECLARE @org_id         BIGINT        = 1;
DECLARE @entered_by     NVARCHAR(100) = N'seed-322';
DECLARE @admin_email    NVARCHAR(250) = N'admin@grac.local';
DECLARE @admin_name     NVARCHAR(200) = N'Admin';
-- PBKDF2-HMAC-SHA256, 210000 iterations, per-account salt. Plaintext: Grac@123
DECLARE @password_hash  NVARCHAR(500) =
    N'210000.37OOaGiqasrF3NAw+fI/6g==.4XaP0XBwfrZpxorvxyGp7kvvhlUdqxrxK3WMxzU5LFc=';

DECLARE @already_existed BIT = CASE WHEN EXISTS (
    SELECT 1 FROM grac_practice.organization_employee
    WHERE organization_id = @org_id AND LOWER(LTRIM(RTRIM(email))) = LOWER(@admin_email)
) THEN 1 ELSE 0 END;

IF @already_existed = 1
    PRINT '322: admin@grac.local already exists in organisation 1 -- password, role and status will be refreshed, row not duplicated.';
ELSE
    PRINT '322: creating admin@grac.local in organisation 1.';

EXEC grac_practice.pm_create_organization_admin
     @organization_id = @org_id,
     @admin_email      = @admin_email,
     @admin_name       = @admin_name,
     @password_hash    = @password_hash,
     @entered_by       = @entered_by;
GO

-- =====================================================================
-- 2. Verification -- read this before handing the credentials over.
-- =====================================================================
PRINT '=== 322 verification ===';

-- 2a. The account, exactly as the sign-in query sees it. Every column
--     here is one of the predicates in PracticeAuthenticationService: a
--     row must appear, employee_status Active, record_status Active,
--     and password_hash_state 'present'.
SELECT e.employee_id,
       e.organization_id,
       e.employee_code,
       e.employee_name,
       e.email,
       e.status                  AS employee_status,
       rs.status_name            AS record_status,
       r.role_name,
       r.role_code,
       r.data_scope,
       e.force_password_change,
       e.email_credentials_sent,
       CASE WHEN LEN(LTRIM(RTRIM(ISNULL(e.password_hash,N'')))) > 0
            THEN 'present' ELSE 'MISSING' END AS password_hash_state,
       LEN(e.password_hash) - LEN(REPLACE(e.password_hash, '.', '')) AS dot_count
FROM grac_practice.organization_employee e
LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id = e.record_status_id
LEFT JOIN grac_practice.organization_role r     ON r.role_id = e.role_id
WHERE e.organization_id = 1
  AND LOWER(e.email) = N'admin@grac.local';

-- 2b. Role assignment present in BOTH places sp_org_user_save / the app
--     rely on -- organization_employee.role_id and the M:N map.
SELECT e.email,
       CASE WHEN e.role_id = r.role_id THEN 'YES' ELSE 'NO' END AS employee_role_id_set,
       CASE WHEN er.employee_role_id IS NOT NULL THEN 'YES' ELSE 'NO' END AS employee_role_map_row,
       r.role_name, r.data_scope
FROM grac_practice.organization_employee e
JOIN grac_practice.organization_role r ON r.role_id = e.role_id
LEFT JOIN grac_practice.organization_employee_role er
       ON er.employee_id = e.employee_id AND er.role_id = r.role_id AND er.status = N'Active'
WHERE e.organization_id = 1 AND LOWER(e.email) = N'admin@grac.local';

-- 2c. Confirms the role is ORGANIZATION-scoped, not GLOBAL -- this
--     account should reach only organisation 1.
SELECT 'org 1 Admin role data_scope' AS Check_,
       r.data_scope,
       CASE WHEN r.data_scope = N'ORGANIZATION' THEN 'PASS'
            ELSE 'REVIEW -- expected ORGANIZATION' END AS Result
FROM grac_practice.organization_employee e
JOIN grac_practice.organization_role r ON r.role_id = e.role_id
WHERE e.organization_id = 1 AND LOWER(e.email) = N'admin@grac.local';

PRINT '';
PRINT '322 organisation 1 admin user complete.';
PRINT 'Hand over: sign in with admin@grac.local and Grac@123 -- the';
PRINT 'change-password screen appears before any session is issued.';
PRINT 'Remember: the SAME email also reaches the ReviewLogin config';
PRINT 'bootstrap login if its own password is supplied instead -- see';
PRINT 'the header of this script.';
PRINT 'If sign-in fails, run database/_diag_user_login.sql with the email.';
GO

SET NOEXEC OFF;
GO
