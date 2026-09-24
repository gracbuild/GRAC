-- =====================================================================
-- SETUP: give the GRAC Admin (bootstrap / ReviewLogin) sign-in a
--        personnel identity, so it can approve and reject.
--
-- WHY THIS IS NEEDED
-- ------------------
-- The GRAC Admin is authenticated against CONFIGURATION (ReviewLogin in
-- appsettings), not against grac_practice.organization_employee. It is a
-- permission holder, not a person. But every decision the product
-- records names a person:
--
--     exception_request.approved_by_employee_id  -> organization_employee
--     exception_request.rejected_by_employee_id  -> organization_employee
--
-- Those are FOREIGN KEYS. ExceptionCentreService.ResolveActorIdAsync
-- will take the id from the session, or resolve it from the caller's
-- email / employee_code -- but it will not invent one, because an
-- approval recorded against a fabricated person is worse than an
-- approval that was refused.
--
-- So the fix is to give the admin a real, minimal personnel row. This
-- script does that and nothing else.
--
-- WHAT THIS ROW IS AND IS NOT
--   IS      a personnel identity for audit: who approved, who rejected.
--   IS NOT  a sign-in. password_hash stays NULL, so this row cannot be
--           logged in with. The bootstrap login keeps working exactly as
--           it does today, through configuration.
--   IS NOT  a permission grant. Menu access still comes from ReviewLogin
--           roles and data_scope, untouched here.
--
-- SAFE TO RE-RUN. Idempotent: an existing row is reported (and
-- reactivated if it was inactive) rather than duplicated.
-- Read section 1, set the three values, then run the whole script.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;

-- =====================================================================
-- 1. Set these three
--
--    @admin_login MUST equal ReviewLogin:Email in the appsettings the
--    application is actually running with -- that is the exact string
--    the Web tier stamps as callerDisplayName and the service searches
--    for. A different-but-similar value silently fails to match.
--
--    @org_code: leave NULL to attach the row to the lowest-numbered
--    active organisation. A GLOBAL-scope admin has no single home
--    organisation, so this is a bookkeeping choice, not a scope change;
--    section 2 prints the alternatives.
-- =====================================================================
DECLARE @admin_login    NVARCHAR(250) = N'REPLACE-WITH-ReviewLogin-Email';
DECLARE @employee_code  NVARCHAR(80)  = N'GRACADMIN';
DECLARE @employee_name  NVARCHAR(200) = N'GRAC Administrator';
DECLARE @org_code       NVARCHAR(80)  = NULL;   -- e.g. N'ORG001'

IF @admin_login = N'REPLACE-WITH-ReviewLogin-Email'
BEGIN
    RAISERROR('Set @admin_login to your ReviewLogin:Email first.', 16, 1);
    RETURN;
END

-- =====================================================================
-- 2. The organisations available
-- =====================================================================
PRINT '=== Organisations ===';
SELECT organization_id, organization_code, organization_name, status
  FROM grac_practice.organization
 ORDER BY organization_id;

DECLARE @org_id BIGINT =
    CASE WHEN @org_code IS NULL
         THEN (SELECT TOP 1 organization_id
                 FROM grac_practice.organization
                WHERE status = N'Active'
                ORDER BY organization_id)
         ELSE (SELECT TOP 1 organization_id
                 FROM grac_practice.organization
                WHERE organization_code = @org_code)
    END;

IF @org_id IS NULL
BEGIN
    RAISERROR('No organisation resolved. Set @org_code to one of the codes listed above.', 16, 1);
    RETURN;
END

DECLARE @active_status_id INT =
    (SELECT TOP 1 record_status_id
       FROM grac_practice.record_status_master
      WHERE status_code = N'ACTIVE' OR status_name = N'Active'
      ORDER BY record_status_id);

IF @active_status_id IS NULL
BEGIN
    RAISERROR('No Active row in record_status_master. Run database/002 first.', 16, 1);
    RETURN;
END

-- =====================================================================
-- 3. Does an identity already exist for this login?
--    Matched the same way the service matches: email OR employee_code.
-- =====================================================================
DECLARE @existing_id BIGINT =
    (SELECT TOP 1 employee_id
       FROM grac_practice.organization_employee
      WHERE email = @admin_login OR employee_code = @admin_login
      ORDER BY employee_id DESC);

IF @existing_id IS NOT NULL
BEGIN
    PRINT '=== An employee row already matches this login ===';

    UPDATE grac_practice.organization_employee
       SET status           = N'Active',
           record_status_id = @active_status_id,
           updated_by       = N'admin-identity-setup',
           updated_dt       = SYSUTCDATETIME()
     WHERE employee_id = @existing_id
       AND (status <> N'Active' OR record_status_id <> @active_status_id);

    IF @@ROWCOUNT > 0
        PRINT '  It was not Active. Reactivated -- the service filters on status = Active.';
    ELSE
        PRINT '  It is already Active. Nothing to change.';
END
ELSE
BEGIN
    -- employee_code is UNIQUE per organisation (uq_pm_employee_org_code),
    -- so step aside if the preferred code is taken in this organisation.
    IF EXISTS (SELECT 1 FROM grac_practice.organization_employee
                WHERE organization_id = @org_id AND employee_code = @employee_code)
    BEGIN
        DECLARE @suffix INT = 2;
        WHILE EXISTS (SELECT 1 FROM grac_practice.organization_employee
                       WHERE organization_id = @org_id
                         AND employee_code = @employee_code + CAST(@suffix AS NVARCHAR(10)))
            SET @suffix = @suffix + 1;
        SET @employee_code = @employee_code + CAST(@suffix AS NVARCHAR(10));
        PRINT '  Preferred employee_code was taken; using ' + @employee_code + '.';
    END

    INSERT grac_practice.organization_employee
        (organization_id, employee_code, employee_name, email,
         status, record_status_id, entered_by)
    VALUES
        (@org_id, @employee_code, @employee_name, @admin_login,
         N'Active', @active_status_id, N'admin-identity-setup');

    SET @existing_id = SCOPE_IDENTITY();
    PRINT '=== Identity created ===';
END

-- =====================================================================
-- 4. What the service will now find
--    This is the service's own lookup, verbatim. A row here means
--    approve and reject will succeed.
-- =====================================================================
PRINT '=== What ResolveActorIdAsync will now find ===';
SELECT TOP 1 employee_id, organization_id, employee_code, employee_name, email, status
  FROM grac_practice.organization_employee
 WHERE (email = @admin_login OR employee_code = @admin_login)
   AND status = N'Active'
 ORDER BY employee_id DESC;

PRINT '';
PRINT 'Done. SIGN OUT AND SIGN IN AGAIN before approving: the employee id is';
PRINT 'stamped onto the session at sign-in, and your current session predates';
PRINT 'this row.';
GO
