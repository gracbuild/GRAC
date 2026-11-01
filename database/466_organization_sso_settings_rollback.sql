-- =====================================================================
-- 466 Organization-wise Single Sign-On settings -- ROLLBACK
--
-- Drops the procedures and the organization_sso_setting table. Saved SSO
-- policies are lost. The API treats a missing table as "no organization
-- has SSO enabled": every SSO sign-in is refused and every password
-- sign-in is allowed, so an API build with 466 keeps working against a
-- rolled-back database. Audit rows already written stay (that table is
-- immutable by design).
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_org_sso_setting_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_sso_setting_save;
IF OBJECT_ID('grac_practice.sp_org_sso_setting_get','P')  IS NOT NULL DROP PROCEDURE grac_practice.sp_org_sso_setting_get;
GO
IF OBJECT_ID('grac_practice.organization_sso_setting','U') IS NOT NULL DROP TABLE grac_practice.organization_sso_setting;
GO

SELECT '466-rollback removed' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.organization_sso_setting','U') IS NULL
             AND OBJECT_ID('grac_practice.sp_org_sso_setting_save','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_org_sso_setting_get','P') IS NULL
            THEN 'OK' ELSE 'STILL PRESENT' END AS Result;
GO
