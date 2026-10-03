-- =====================================================================
-- 415 Role View Data Scope -- ROLLBACK
--
-- Drops the security policy first (so no read is filtered from that
-- moment), then the predicate functions, the procedures, and the
-- organization_role.view_data_scope column with its constraints. The
-- saved settings are lost; every role is back to seeing all records,
-- which is what "All records" meant anyway. The Api's ViewScopeSession
-- treats the missing procedure as "no scope" (2812), so an Api build
-- with 415 keeps working against a rolled-back database.
-- =====================================================================
SET NOCOUNT ON;
GO

IF EXISTS (SELECT 1 FROM sys.security_policies
            WHERE name = N'pm_view_data_scope_policy' AND schema_id = SCHEMA_ID(N'grac_practice'))
    DROP SECURITY POLICY grac_practice.pm_view_data_scope_policy;
GO

IF OBJECT_ID('grac_practice.fn_pm_view_scope_gap')            IS NOT NULL DROP FUNCTION grac_practice.fn_pm_view_scope_gap;
IF OBJECT_ID('grac_practice.fn_pm_view_scope_owner_instance') IS NOT NULL DROP FUNCTION grac_practice.fn_pm_view_scope_owner_instance;
IF OBJECT_ID('grac_practice.fn_pm_view_scope_owner')          IS NOT NULL DROP FUNCTION grac_practice.fn_pm_view_scope_owner;
IF OBJECT_ID('grac_practice.fn_pm_view_scope_core')           IS NOT NULL DROP FUNCTION grac_practice.fn_pm_view_scope_core;
IF OBJECT_ID('grac_practice.sp_pm_view_scope_session_set','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_pm_view_scope_session_set;
IF OBJECT_ID('grac_practice.sp_role_view_data_scope_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_role_view_data_scope_save;
IF OBJECT_ID('grac_practice.sp_role_view_data_scope_get','P')  IS NOT NULL DROP PROCEDURE grac_practice.sp_role_view_data_scope_get;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'ck_pm_org_role_view_data_scope')
    ALTER TABLE grac_practice.organization_role DROP CONSTRAINT ck_pm_org_role_view_data_scope;
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = N'df_pm_org_role_view_data_scope')
    ALTER TABLE grac_practice.organization_role DROP CONSTRAINT df_pm_org_role_view_data_scope;
GO
IF COL_LENGTH('grac_practice.organization_role','view_data_scope') IS NOT NULL
    ALTER TABLE grac_practice.organization_role DROP COLUMN view_data_scope;
GO

SELECT '415-rollback removed' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.security_policies WHERE name = N'pm_view_data_scope_policy')
             AND COL_LENGTH('grac_practice.organization_role','view_data_scope') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
PRINT '415 rolled back.';
GO
