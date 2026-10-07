-- =====================================================================
-- 425 rollback -- technology catalogue (makes and models)
--
--   * removes the Technology Catalogue menu row and its grants;
--   * drops the five procedures and the four tables (children first) --
--     every make, model and lifecycle event is lost;
--   * removes the AssetModel transition rules, and its statuses where no
--     (immutable) transition-log row references them.
-- practice_audit_trace rows are immutable and stay as history.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DELETE p FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'asset-tech-catalog';
DELETE FROM grac_practice.menu_master WHERE menu_key = N'asset-tech-catalog';
PRINT '425 rollback: menu row removed.';
GO

IF OBJECT_ID('grac_practice.sp_asset_tech_catalog_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_asset_tech_catalog_list;
IF OBJECT_ID('grac_practice.sp_asset_model_get','P') IS NOT NULL         DROP PROCEDURE grac_practice.sp_asset_model_get;
IF OBJECT_ID('grac_practice.sp_asset_make_save','P') IS NOT NULL         DROP PROCEDURE grac_practice.sp_asset_make_save;
IF OBJECT_ID('grac_practice.sp_asset_model_save','P') IS NOT NULL        DROP PROCEDURE grac_practice.sp_asset_model_save;
IF OBJECT_ID('grac_practice.sp_asset_model_transition','P') IS NOT NULL  DROP PROCEDURE grac_practice.sp_asset_model_transition;
PRINT '425 rollback: procedures dropped.';
GO

IF OBJECT_ID('grac_practice.technology_lifecycle_event','U') IS NOT NULL DROP TABLE grac_practice.technology_lifecycle_event;
IF OBJECT_ID('grac_practice.asset_model','U') IS NOT NULL                DROP TABLE grac_practice.asset_model;
IF OBJECT_ID('grac_practice.asset_make_asset_type','U') IS NOT NULL      DROP TABLE grac_practice.asset_make_asset_type;
IF OBJECT_ID('grac_practice.asset_make','U') IS NOT NULL                 DROP TABLE grac_practice.asset_make;
PRINT '425 rollback: tables dropped.';
GO

DELETE FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'AssetModel';
DELETE s FROM grac_practice.entity_status_master s
 WHERE s.entity_type = N'AssetModel'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_log l
                    WHERE l.from_status_id = s.entity_status_id OR l.to_status_id = s.entity_status_id);
PRINT '425 rollback: lifecycle rows removed.';
GO
