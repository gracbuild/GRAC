-- =====================================================================
-- 422 rollback -- asset valuation configuration
--
--   * removes the Asset Valuation menu row and its grants;
--   * drops the valuation procedures, fn_asset_value_calc and the four
--     tables (children first);
--   * removes the AssetValuationConfig transition rules, and its statuses
--     where no (immutable) transition-log row references them;
--   * then re-run 421_asset_form_rules.sql to restore the 421 bodies of
--     sp_asset_form_template_get and sp_asset_form_template_readiness
--     (421 is re-runnable).
-- practice_audit_trace rows are immutable and stay as history.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DELETE p FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'asset-valuation-config';
DELETE FROM grac_practice.menu_master WHERE menu_key = N'asset-valuation-config';
PRINT '422 rollback: menu row removed.';
GO

IF OBJECT_ID('grac_practice.sp_asset_valuation_config_list','P') IS NOT NULL            DROP PROCEDURE grac_practice.sp_asset_valuation_config_list;
IF OBJECT_ID('grac_practice.sp_asset_valuation_config_get','P') IS NOT NULL             DROP PROCEDURE grac_practice.sp_asset_valuation_config_get;
IF OBJECT_ID('grac_practice.sp_asset_valuation_config_readiness','P') IS NOT NULL       DROP PROCEDURE grac_practice.sp_asset_valuation_config_readiness;
IF OBJECT_ID('grac_practice.sp_asset_valuation_config_assert_editable','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_asset_valuation_config_assert_editable;
IF OBJECT_ID('grac_practice.sp_asset_valuation_config_create','P') IS NOT NULL          DROP PROCEDURE grac_practice.sp_asset_valuation_config_create;
IF OBJECT_ID('grac_practice.sp_asset_valuation_config_header_save','P') IS NOT NULL     DROP PROCEDURE grac_practice.sp_asset_valuation_config_header_save;
IF OBJECT_ID('grac_practice.sp_asset_valuation_config_item_save','P') IS NOT NULL       DROP PROCEDURE grac_practice.sp_asset_valuation_config_item_save;
IF OBJECT_ID('grac_practice.sp_asset_valuation_config_transition','P') IS NOT NULL      DROP PROCEDURE grac_practice.sp_asset_valuation_config_transition;
IF OBJECT_ID('grac_practice.sp_asset_valuation_calculate','P') IS NOT NULL              DROP PROCEDURE grac_practice.sp_asset_valuation_calculate;
IF OBJECT_ID('grac_practice.fn_asset_value_calc') IS NOT NULL                           DROP FUNCTION grac_practice.fn_asset_value_calc;
PRINT '422 rollback: procedures and function dropped.';
GO

IF OBJECT_ID('grac_practice.asset_criticality_level','U') IS NOT NULL DROP TABLE grac_practice.asset_criticality_level;
IF OBJECT_ID('grac_practice.asset_value_band','U') IS NOT NULL        DROP TABLE grac_practice.asset_value_band;
IF OBJECT_ID('grac_practice.asset_cia_scale_level','U') IS NOT NULL   DROP TABLE grac_practice.asset_cia_scale_level;
IF OBJECT_ID('grac_practice.asset_valuation_config','U') IS NOT NULL  DROP TABLE grac_practice.asset_valuation_config;
PRINT '422 rollback: tables dropped.';
GO

DELETE FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'AssetValuationConfig';
DELETE s FROM grac_practice.entity_status_master s
 WHERE s.entity_type = N'AssetValuationConfig'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_log l
                    WHERE l.from_status_id = s.entity_status_id OR l.to_status_id = s.entity_status_id);
PRINT '422 rollback: lifecycle rows removed. Now re-run 421_asset_form_rules.sql.';
GO
