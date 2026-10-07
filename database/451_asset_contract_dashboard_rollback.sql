-- =====================================================================
-- 451 ROLLBACK  Asset & Contract dashboard
-- =====================================================================
-- Drops sp_dashboard_asset_contract and the Dashboard menu row of Asset &
-- Contract with its grants. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
DROP PROCEDURE IF EXISTS grac_practice.sp_dashboard_asset_contract;
GO
DELETE p
  FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'asset-contract-dashboard';
DELETE FROM grac_practice.menu_master WHERE menu_key = N'asset-contract-dashboard';
GO
SELECT '451 rollback' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_dashboard_asset_contract','P') IS NULL
             AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'asset-contract-dashboard')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
