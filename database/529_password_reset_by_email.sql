-- =====================================================================
-- 529  Forgot password -- reset by email link
--
-- REQUEST (2026-11-10)
--   "login page lu oru forgot password nte link undayille? athu ipo miss
--    ayallo"  -- decided with sir: email reset link (one-time, expiring).
--
--   The link was never built: the 2026-11-03 login restyle left "Forgot
--   password?" out because there was no reset flow behind it.
--
-- THE FLOW
--   1. Login page -> "Forgot password?" -> enter User ID / Email ID.
--   2. Api resolves the active employee (same predicate as sign-in),
--      skips SSO-Only organizations, then sp_password_reset_request
--      stores the SHA-256 of a random token (the token itself is never
--      stored) and returns 1 = issued.
--   3. Web emails the link  .../Login/ResetPassword?token=<token>.
--      The page always says the same thing ("if an account exists ...")
--      so it is not an account-enumeration oracle.
--   4. The link opens Reset Password; sp_password_reset_validate checks
--      the token (Open, not expired, employee still Active).
--   5. New password -> sp_password_reset_complete: marks the token Used,
--      closes every other open token of the employee and sets the
--      password through sp_org_user_set_password (208) -- the one place
--      that writes a password; force_password_change is cleared there.
--
-- RULES
--   * A token is single use and expires (Api PasswordReset:TokenMinutes,
--     default 30). A new request supersedes the employee's open tokens.
--   * At most @max_per_hour requests per employee per hour (default 5);
--     beyond that nothing is issued (the page still shows the same text).
--
-- ERRORS 55981-55984 (Api: PracticeAuthenticationService).
-- SAFE TO RE-RUN. Requires 208. ASCII-only.
-- Rollback: 529_password_reset_by_email_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.organization_employee','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','password_hash') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','status') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_user_set_password','P') IS NULL
BEGIN
    PRINT 'ABORT (529): run 208_default_password_provisioning.sql first. Nothing was changed.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Table
-- =====================================================================
IF OBJECT_ID('grac_practice.password_reset_token','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.password_reset_token (
        reset_token_id  BIGINT IDENTITY(1,1) NOT NULL
                        CONSTRAINT pk_pm_password_reset_token PRIMARY KEY,
        employee_id     BIGINT        NOT NULL
                        CONSTRAINT fk_pm_password_reset_token_employee
                        REFERENCES grac_practice.organization_employee(employee_id),
        token_hash      NVARCHAR(128) NOT NULL,          -- SHA-256 hex of the emailed token
        status          NVARCHAR(20)  NOT NULL
                        CONSTRAINT df_pm_password_reset_token_status DEFAULT (N'Open'),
        requested_dt    DATETIME2     NOT NULL
                        CONSTRAINT df_pm_password_reset_token_requested DEFAULT (SYSUTCDATETIME()),
        expires_dt      DATETIME2     NOT NULL,
        requested_ip    NVARCHAR(64)  NULL,
        used_dt         DATETIME2     NULL,
        CONSTRAINT ck_pm_password_reset_token_status
            CHECK (status IN (N'Open', N'Used', N'Superseded'))
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_password_reset_token_hash'
                  AND object_id = OBJECT_ID('grac_practice.password_reset_token'))
    CREATE UNIQUE INDEX ux_pm_password_reset_token_hash
        ON grac_practice.password_reset_token (token_hash);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_password_reset_token_employee'
                  AND object_id = OBJECT_ID('grac_practice.password_reset_token'))
    CREATE INDEX ix_pm_password_reset_token_employee
        ON grac_practice.password_reset_token (employee_id, requested_dt)
        INCLUDE (status);
GO

-- =====================================================================
-- 2. sp_password_reset_request
--    The Api has already resolved the employee (sign-in predicate) and
--    applied the SSO policy. Returns Issued = 1 when the token was
--    stored; 0 when the hourly limit is reached or the employee is not
--    Active (the caller shows the same message either way).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_password_reset_request
    @employee_id     BIGINT,
    @token_hash      NVARCHAR(128),
    @expiry_minutes  INT          = 30,
    @requested_ip    NVARCHAR(64) = NULL,
    @max_per_hour    INT          = 5
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @employee_id IS NULL OR @employee_id <= 0
        THROW 55981, 'sp_password_reset_request: employee_id is required.', 1;
    IF LEN(ISNULL(@token_hash, N'')) = 0
        THROW 55982, 'sp_password_reset_request: token_hash is required.', 1;
    IF @expiry_minutes IS NULL OR @expiry_minutes <= 0 SET @expiry_minutes = 30;
    IF @expiry_minutes > 1440 SET @expiry_minutes = 1440;
    IF @max_per_hour IS NULL OR @max_per_hour <= 0 SET @max_per_hour = 5;

    DECLARE @now DATETIME2 = SYSUTCDATETIME();

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                    WHERE employee_id = @employee_id AND status = N'Active')
    BEGIN
        SELECT CAST(0 AS BIT) AS Issued, N'inactive' AS Reason;
        RETURN;
    END

    IF (SELECT COUNT(*) FROM grac_practice.password_reset_token
         WHERE employee_id = @employee_id
           AND requested_dt > DATEADD(HOUR, -1, @now)) >= @max_per_hour
    BEGIN
        SELECT CAST(0 AS BIT) AS Issued, N'limit' AS Reason;
        RETURN;
    END

    BEGIN TRAN;
        -- Only the newest link works.
        UPDATE grac_practice.password_reset_token
           SET status = N'Superseded'
         WHERE employee_id = @employee_id AND status = N'Open';

        INSERT grac_practice.password_reset_token
               (employee_id, token_hash, status, requested_dt, expires_dt, requested_ip)
        VALUES (@employee_id, @token_hash, N'Open', @now,
                DATEADD(MINUTE, @expiry_minutes, @now), NULLIF(LTRIM(RTRIM(@requested_ip)), N''));
    COMMIT;

    SELECT CAST(1 AS BIT) AS Issued, N'issued' AS Reason;
END;
GO

-- =====================================================================
-- 3. sp_password_reset_validate
--    One row (the employee the token belongs to) when the token is Open,
--    not expired and the employee is still Active; no row otherwise.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_password_reset_validate
    @token_hash NVARCHAR(128)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (1)
           e.employee_id   AS EmployeeId,
           e.employee_code AS EmployeeCode,
           e.employee_name AS EmployeeName,
           e.email         AS Email,
           t.expires_dt    AS ExpiresDt
      FROM grac_practice.password_reset_token t
      JOIN grac_practice.organization_employee e ON e.employee_id = t.employee_id
     WHERE t.token_hash = @token_hash
       AND t.status     = N'Open'
       AND t.expires_dt > SYSUTCDATETIME()
       AND e.status     = N'Active';
END;
GO

-- =====================================================================
-- 4. sp_password_reset_complete
--    Uses the token once and sets the password through 208's
--    sp_org_user_set_password (which also clears force_password_change).
--    THROW 55983 when the token is not usable (expired / used /
--    superseded / unknown); 55984 when the hash is missing.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_password_reset_complete
    @token_hash    NVARCHAR(128),
    @password_hash NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF LEN(ISNULL(@password_hash, N'')) = 0
        THROW 55984, 'A password hash is required.', 1;

    DECLARE @reset_token_id BIGINT, @employee_id BIGINT;

    BEGIN TRAN;
        SELECT @reset_token_id = t.reset_token_id,
               @employee_id    = t.employee_id
          FROM grac_practice.password_reset_token t WITH (UPDLOCK, HOLDLOCK)
          JOIN grac_practice.organization_employee e ON e.employee_id = t.employee_id
         WHERE t.token_hash = @token_hash
           AND t.status     = N'Open'
           AND t.expires_dt > SYSUTCDATETIME()
           AND e.status     = N'Active';

        IF @reset_token_id IS NULL
            THROW 55983, 'This password reset link is invalid or has expired. Request a new one.', 1;

        UPDATE grac_practice.password_reset_token
           SET status = N'Used', used_dt = SYSUTCDATETIME()
         WHERE reset_token_id = @reset_token_id;

        UPDATE grac_practice.password_reset_token
           SET status = N'Superseded'
         WHERE employee_id = @employee_id AND status = N'Open';

        EXEC grac_practice.sp_org_user_set_password
             @employee_id   = @employee_id,
             @password_hash = @password_hash,
             @entered_by    = N'password-reset';
    COMMIT;
END;
GO

-- =====================================================================
-- 5. Verification
-- =====================================================================
SELECT '529 password_reset_token' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.password_reset_token','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '529 sp_password_reset_request',
       CASE WHEN OBJECT_ID('grac_practice.sp_password_reset_request','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '529 sp_password_reset_validate',
       CASE WHEN OBJECT_ID('grac_practice.sp_password_reset_validate','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '529 sp_password_reset_complete',
       CASE WHEN OBJECT_ID('grac_practice.sp_password_reset_complete','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;
PRINT '529 complete. Restart the Api, deploy Web, and set Email:* (SMTP) in the Web appsettings.';
GO
SET NOEXEC OFF;
GO
