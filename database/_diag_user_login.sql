-- =====================================================================
-- DIAGNOSTIC: why does a newly-added user get "Invalid user ID/email or
--             password"?
--
-- Read-only. Set @login_id below to the email (or Employee Code) that is
-- failing, run the whole script, and read section 3.
--
-- BACKGROUND
-- ----------
-- PracticeLoginService.AuthenticateAsync returns "no user" — which the
-- screen renders as "Invalid user ID/email or password" — when ANY of
-- these is true:
--     a) no organization_employee row matches the login id
--     b) e.status <> 'Active'
--     c) the joined record_status_master row is not the Active one
--     d) the organization row is missing
--     e) password_hash is NULL or blank
--     f) PBKDF2 verification fails
-- The message is deliberately identical for all six, so this script
-- separates them. (a)-(e) are visible in SQL; (f) is inferred by
-- elimination, and section 4 says what to check next when it is the
-- remaining candidate.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @login_id NVARCHAR(250) = N'REPLACE-WITH-THE-FAILING-EMAIL';

-- =====================================================================
-- 1. Every row that matches the login id, with no filters applied
--    Nothing here => cause (a): the account was never created, or was
--    created against a different email / employee code.
-- =====================================================================
PRINT '=== 1. Matching employee rows (unfiltered) ===';
SELECT e.employee_id,
       e.organization_id,
       e.employee_code,
       e.employee_name,
       e.email,
       e.status                                   AS employee_status,
       e.record_status_id,
       rs.status_code                             AS record_status_code,
       rs.status_name                             AS record_status_name,
       e.role_id,
       r.role_name,
       e.entered_by,
       e.entered_dt,
       CASE WHEN COL_LENGTH('grac_practice.organization_employee','force_password_change') IS NULL
            THEN NULL ELSE e.force_password_change END AS force_password_change,
       -- Never print the hash. Its shape is enough: PasswordHasher writes
       -- "<iterations>.<base64 salt>.<base64 hash>", ~76 characters.
       CASE WHEN e.password_hash IS NULL THEN 'NULL'
            WHEN LTRIM(RTRIM(e.password_hash)) = '' THEN 'EMPTY'
            ELSE 'present' END                    AS password_hash_state,
       LEN(e.password_hash)                       AS password_hash_length,
       LEFT(e.password_hash, CHARINDEX('.', e.password_hash + '.') - 1) AS pbkdf2_iterations,
       LEN(e.password_hash) - LEN(REPLACE(e.password_hash, '.', ''))    AS dot_count
  FROM grac_practice.organization_employee e
  LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id = e.record_status_id
  LEFT JOIN grac_practice.organization_role r     ON r.role_id = e.role_id AND r.organization_id = e.organization_id
 WHERE LOWER(e.employee_code) = LOWER(@login_id)
    OR LOWER(LTRIM(RTRIM(e.email))) = LOWER(LTRIM(RTRIM(@login_id)));

-- =====================================================================
-- 2. The login predicates, one at a time
-- =====================================================================
PRINT '=== 2. Login predicates ===';
WITH candidate AS (
    SELECT TOP (1) e.*
      FROM grac_practice.organization_employee e
     WHERE LOWER(e.employee_code) = LOWER(@login_id)
        OR LOWER(LTRIM(RTRIM(e.email))) = LOWER(LTRIM(RTRIM(@login_id)))
     ORDER BY e.employee_id
)
SELECT 'a. row exists for this login id' AS Predicate,
       CASE WHEN EXISTS(SELECT 1 FROM candidate) THEN 'PASS' ELSE 'FAIL' END AS Result,
       'FAIL => the user was never created, or the email differs (trailing space? different domain?)' AS IfItFails
UNION ALL
SELECT 'b. e.status = ''Active''',
       CASE WHEN EXISTS(SELECT 1 FROM candidate WHERE status = 'Active') THEN 'PASS' ELSE 'FAIL' END,
       'FAIL => the Status dropdown on the Users form was saved as something other than Active'
UNION ALL
SELECT 'c. record_status_master row is Active',
       CASE WHEN EXISTS(SELECT 1 FROM candidate c
                         JOIN grac_practice.record_status_master rs ON rs.record_status_id = c.record_status_id
                        WHERE rs.status_code = 'ACTIVE' OR rs.status_name = 'Active') THEN 'PASS' ELSE 'FAIL' END,
       'FAIL => record_status_id points at Inactive/Retired/Draft'
UNION ALL
SELECT 'd. organization row exists',
       CASE WHEN EXISTS(SELECT 1 FROM candidate c
                         JOIN grac_practice.organization o ON o.organization_id = c.organization_id) THEN 'PASS' ELSE 'FAIL' END,
       'FAIL => orphaned organization_id; the login query INNER JOINs organization'
UNION ALL
SELECT 'e. password_hash is present',
       CASE WHEN EXISTS(SELECT 1 FROM candidate WHERE LEN(LTRIM(RTRIM(ISNULL(password_hash,'')))) > 0) THEN 'PASS' ELSE 'FAIL' END,
       'FAIL => the row was written without a hash; the Web gateway did not substitute the default'
UNION ALL
SELECT 'e2. password_hash has the PasswordHasher shape',
       CASE WHEN EXISTS(SELECT 1 FROM candidate
                        WHERE LEN(password_hash) - LEN(REPLACE(password_hash,'.','')) = 2
                          AND ISNUMERIC(LEFT(password_hash, CHARINDEX('.', password_hash) - 1)) = 1)
            THEN 'PASS' ELSE 'FAIL' END,
       'FAIL => the stored value is not "<iterations>.<salt>.<hash>" and can never verify';

-- =====================================================================
-- 3. Which build of the save procedure is deployed
--    Tells you whether migration 208 and the 133/134 shims are actually
--    in this database — the commonest reason a code fix appears to have
--    no effect.
-- =====================================================================
PRINT '=== 3. Deployed objects ===';
SELECT 'sp_org_user_save exists (133)' AS Object,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_user_save','P') IS NOT NULL THEN 'YES' ELSE 'NO' END AS Present
UNION ALL
SELECT 'sp_org_user_save carries the 208 change',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_user_save','P')) LIKE '%force_password_change%'
            THEN 'YES' ELSE 'NO — migration 208 not applied' END
UNION ALL
SELECT 'sp_org_user_set_password exists (208)',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_user_set_password','P') IS NOT NULL THEN 'YES' ELSE 'NO' END
UNION ALL
SELECT 'sp_org_user_repository_manage shim exists (134)',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_user_repository_manage','P') IS NOT NULL
            THEN 'YES' ELSE 'NO — saves fall back to dbo.pm_manage_practice_repository' END
UNION ALL
SELECT 'force_password_change column exists (032)',
       CASE WHEN COL_LENGTH('grac_practice.organization_employee','force_password_change') IS NOT NULL THEN 'YES' ELSE 'NO' END;

-- =====================================================================
-- 4. Recently created accounts, for comparison
--    A working account next to a failing one usually makes the
--    difference obvious at a glance.
-- =====================================================================
PRINT '=== 4. Ten most recent accounts ===';
SELECT TOP (10)
       e.employee_id, e.organization_id, e.employee_code, e.email,
       e.status AS employee_status, rs.status_name AS record_status,
       CASE WHEN LEN(LTRIM(RTRIM(ISNULL(e.password_hash,'')))) > 0 THEN 'present' ELSE 'MISSING' END AS password_hash_state,
       CASE WHEN COL_LENGTH('grac_practice.organization_employee','force_password_change') IS NULL
            THEN NULL ELSE e.force_password_change END AS force_password_change,
       e.entered_by, e.entered_dt
  FROM grac_practice.organization_employee e
  LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id = e.record_status_id
 ORDER BY e.employee_id DESC;

PRINT '';
PRINT 'READING THE RESULT';
PRINT '------------------';
PRINT 'Section 2 shows a FAIL  -> that is the cause. Fix it and sign in again.';
PRINT 'Section 2 all PASS      -> the row is reachable and the hash is well formed,';
PRINT '                           so PBKDF2 verification is what failed. That means the';
PRINT '                           password typed at the screen is not the one that was';
PRINT '                           hashed at creation. Check the RUNNING site''s';
PRINT '                           appsettings.json (and appsettings.Production.json, and';
PRINT '                           any UserProvisioning__DefaultPassword environment';
PRINT '                           variable) for UserProvisioning:DefaultPassword — the';
PRINT '                           deployed value, not the one in source control.';
