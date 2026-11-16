-- =====================================================================
-- 529 ROLLBACK  Forgot password by email.
-- Drops the three procedures and the token table. Passwords already
-- changed through a reset stay changed. The Api checks for the
-- procedures and then reports "not available"; the Forgot password page
-- says so. ASCII-only. Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_password_reset_complete','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_password_reset_complete;
IF OBJECT_ID('grac_practice.sp_password_reset_validate','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_password_reset_validate;
IF OBJECT_ID('grac_practice.sp_password_reset_request','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_password_reset_request;
GO

IF OBJECT_ID('grac_practice.password_reset_token','U') IS NOT NULL
    DROP TABLE grac_practice.password_reset_token;
GO

SELECT '529 rolled back' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.password_reset_token','U') IS NULL
             AND OBJECT_ID('grac_practice.sp_password_reset_request','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
GO
