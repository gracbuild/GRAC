-- =====================================================================
-- DIAGNOSTIC: "No employee could be identified for this approval."
--
-- Read-only. Set @caller below to the id you SIGN IN WITH (the value the
-- Web tier stamps as callerDisplayName -- session UserKey, which is the
-- email or employee code you typed on the login screen), run the whole
-- script, and read section 4.
--
-- BACKGROUND
-- ----------
-- ExceptionCentreService.ResolveActorIdAsync answers "who is approving?"
-- in this order:
--
--     1. approvedByEmployeeId stamped on the session by the Web tier.
--        A DATABASE sign-in sets it (LoginController.SignIn). The
--        BOOTSTRAP sign-in (ReviewLogin, verified against configuration
--        rather than the employee table) sets it only when an employee
--        row exists for the configured email.
--     2. failing that, this lookup:
--
--            SELECT TOP 1 employee_id
--              FROM grac_practice.organization_employee
--             WHERE (email = @caller OR employee_code = @caller)
--               AND status = N'Active'
--             ORDER BY employee_id DESC;
--
--     3. failing that, the message you are reading about.
--
-- Nothing invents an employee: approved_by_employee_id is a foreign key,
-- and an approval recorded against a fabricated person is worse than an
-- approval that was refused.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @caller NVARCHAR(250) = N'REPLACE-WITH-THE-LOGIN-ID-YOU-USE';

-- =====================================================================
-- 1. What the service's own lookup returns
--    A row here means approval should now work; if it still does not,
--    the problem is elsewhere (check section 5).
-- =====================================================================
PRINT '=== 1. Exactly what ResolveActorIdAsync would find ===';
SELECT TOP 1 employee_id, organization_id, employee_code, employee_name, email, status
  FROM grac_practice.organization_employee
 WHERE (email = @caller OR employee_code = @caller)
   AND status = N'Active'
 ORDER BY employee_id DESC;

-- =====================================================================
-- 2. The same match with NO status filter, and case/space-insensitive
--    A row here but not in section 1 means the row exists and is simply
--    not Active, or differs by case or trailing spaces. The service
--    compares with the database collation and does not trim.
-- =====================================================================
PRINT '=== 2. Near matches (status ignored, case/space tolerant) ===';
SELECT employee_id, organization_id, employee_code, employee_name, email,
       status,
       CASE WHEN email         = @caller THEN 'exact email'
            WHEN employee_code = @caller THEN 'exact code'
            ELSE 'only matches when case/space is ignored' END AS match_kind,
       LEN(ISNULL(email, N''))         AS email_length,
       LEN(RTRIM(ISNULL(email, N'')))  AS email_length_trimmed
  FROM grac_practice.organization_employee
 WHERE UPPER(LTRIM(RTRIM(ISNULL(email, N''))))         = UPPER(LTRIM(RTRIM(@caller)))
    OR UPPER(LTRIM(RTRIM(ISNULL(employee_code, N'')))) = UPPER(LTRIM(RTRIM(@caller)))
 ORDER BY employee_id DESC;

-- =====================================================================
-- 3. Is this login a BOOTSTRAP (ReviewLogin) account?
--    An email that appears in user_organization_map but nowhere in
--    organization_employee is the classic case: a configured admin with
--    cross-org access and no personnel record behind it.
-- =====================================================================
PRINT '=== 3. Cross-org grants for this login (user_organization_map) ===';
IF OBJECT_ID('grac_practice.user_organization_map','U') IS NOT NULL
    SELECT user_organization_map_id, user_email, organization_id
      FROM grac_practice.user_organization_map
     WHERE UPPER(LTRIM(RTRIM(user_email))) = UPPER(LTRIM(RTRIM(@caller)));
ELSE
    PRINT '  user_organization_map does not exist in this database.';

-- =====================================================================
-- 4. The verdict
-- =====================================================================
PRINT '=== 4. Verdict ===';
IF EXISTS (SELECT 1 FROM grac_practice.organization_employee
            WHERE (email = @caller OR employee_code = @caller) AND status = N'Active')
    PRINT '  An active employee matches. Approval should succeed -- see section 5 if it does not.';
ELSE IF EXISTS (SELECT 1 FROM grac_practice.organization_employee
                 WHERE UPPER(LTRIM(RTRIM(ISNULL(email, N''))))         = UPPER(LTRIM(RTRIM(@caller)))
                    OR UPPER(LTRIM(RTRIM(ISNULL(employee_code, N'')))) = UPPER(LTRIM(RTRIM(@caller))))
    PRINT '  A row EXISTS but is not Active, or differs by case / trailing space. Fix the row (section 6a).';
ELSE
    PRINT '  No employee row at all for this login. This is a bootstrap admin. Create the row (section 6b) or sign in as a database user.';

-- =====================================================================
-- 5. If section 1 returned a row and approval still fails
--    The session is stamped at SIGN-IN, so a row created after you
--    signed in is not in your session yet: SIGN OUT AND BACK IN. The
--    callerDisplayName fallback should cover it either way, so if it
--    still fails, read the API log for
--    "ExceptionCentre.Approve: no active employee matches caller ..."
--    which prints the exact string that was searched for.
-- =====================================================================

-- =====================================================================
-- 6. Fixes -- NOT executed. Read, adjust, then run deliberately.
--
-- 6a. A row exists but is not Active:
--
--     UPDATE grac_practice.organization_employee
--        SET status = N'Active'
--      WHERE employee_id = <the id from section 2>;
--
-- 6b. No row exists. Create one for the admin, in the organisation they
--     should be recorded against. organization_id and record_status_id
--     are foreign keys -- take real values from your own data rather
--     than the placeholders:
--
--     DECLARE @org_id BIGINT = (SELECT TOP 1 organization_id
--                                 FROM grac_practice.organization
--                                ORDER BY organization_id);
--     DECLARE @active_status_id INT = (SELECT TOP 1 record_status_id
--                                        FROM grac_practice.record_status_master
--                                       WHERE status_code = 'ACTIVE'
--                                          OR status_name = 'Active');
--
--     INSERT grac_practice.organization_employee
--         (organization_id, employee_code, employee_name, email,
--          status, record_status_id, entered_by)
--     VALUES
--         (@org_id, N'ADMIN01', N'GRAC Administrator', @caller,
--          N'Active', @active_status_id, N'diagnostic');
--
--     employee_code is UNIQUE per organisation (uq_pm_employee_org_code),
--     so pick one that is free. This row gives the admin a personnel
--     identity for audit; it does NOT grant a password or a sign-in --
--     password_hash stays null and the bootstrap login keeps working the
--     way it does today.
-- =====================================================================
