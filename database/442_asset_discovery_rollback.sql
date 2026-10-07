-- =====================================================================
-- 442 rollback -- Asset discovery and reconciliation
--
--   * removes the Asset Discovery menu row and its grants;
--   * drops the discovery procedures, functions and tables (sources,
--     precedence, rules, settings, batches, observations, links, attribute
--     sources, reconciliation exceptions, duplicate decisions);
--   * removes the Asset Reconciliation task type when no task uses it
--     (conflict tasks already created stay in Task Centre).
-- Values written to the asset register by discovery stay (their audit rows
-- too). Deploy the API / Web without the 442 changes first. Re-runnable.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DELETE p FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'asset-discovery';
DELETE FROM grac_practice.menu_master WHERE menu_key = N'asset-discovery';
PRINT '442 rollback: menu row removed.';
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_asset_discovery_asset_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_discovery_confidence;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_reconciliation_exceptions;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_discovery_batch_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_discovery_batches;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_discovery_config_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_reconciliation_resolve;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_discovery_ingest;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_discovery_reconcile;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_discovery_apply;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_reconciliation_exception_raise;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_discovery_identity_load;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_discovery_setting_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_identification_rule_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_discovery_priorities_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_discovery_source_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_discovery_defaults_ensure;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_discovery_confidence;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_norm;
PRINT '442 rollback: procedures and functions dropped.';
GO

DROP TABLE IF EXISTS grac_practice.asset_duplicate_decision;
DROP TABLE IF EXISTS grac_practice.asset_reconciliation_exception;
DROP TABLE IF EXISTS grac_practice.asset_attribute_source;
DROP TABLE IF EXISTS grac_practice.asset_discovery_link;
DROP TABLE IF EXISTS grac_practice.asset_discovery_observation;
DROP TABLE IF EXISTS grac_practice.asset_discovery_batch;
DROP TABLE IF EXISTS grac_practice.asset_discovery_setting;
DROP TABLE IF EXISTS grac_practice.asset_identification_rule;
DROP TABLE IF EXISTS grac_practice.asset_discovery_priority;
DROP TABLE IF EXISTS grac_practice.asset_discovery_source;
PRINT '442 rollback: tables dropped.';
GO

DELETE tt FROM grac_practice.task_type_master tt
 WHERE tt.type_code = N'AssetReconciliation'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.practice_task t WHERE t.task_type_id = tt.task_type_id);
GO

SELECT '442 rollback' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_discovery_source','U') IS NULL
             AND OBJECT_ID('grac_practice.sp_asset_discovery_ingest','P') IS NULL
             AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'asset-discovery')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
