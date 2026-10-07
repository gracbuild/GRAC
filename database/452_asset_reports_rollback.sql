-- =====================================================================
-- 452 ROLLBACK  Asset & Contract report catalogue and exports
-- =====================================================================
-- Drops the 452 procedures, functions and tables (organization report
-- settings and the export log are lost) and the Asset Reports menu row
-- and its grants. 452 re-issues no existing object, so nothing is
-- restored. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_org_setting_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_exports;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_export_log;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_run;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_catalogue;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_privacy;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_governance;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_risk;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_technology;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_contract;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_discovery;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_cmdb;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_attestation;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_asset;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_report_effective;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_report_relationships;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_report_contracts;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_report_assets;
GO
DROP TABLE IF EXISTS grac_practice.asset_report_export;
DROP TABLE IF EXISTS grac_practice.asset_report_org_setting;
DROP TABLE IF EXISTS grac_practice.asset_report_definition;
GO
DELETE p
  FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'asset-reports';
DELETE FROM grac_practice.menu_master WHERE menu_key = N'asset-reports';
GO
PRINT '452 rollback: report objects and menu dropped.';
GO
SELECT '452 rollback' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_report_definition','U') IS NULL
             AND OBJECT_ID('grac_practice.sp_asset_report_run','P') IS NULL
             AND OBJECT_ID('grac_practice.fn_asset_report_assets') IS NULL
             AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'asset-reports')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
