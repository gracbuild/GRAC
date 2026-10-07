-- =====================================================================
-- 423 rollback -- organization option lists
--
--   * removes the Option Lists menu row and its grants;
--   * drops the option-list procedures, fn_asset_field_options and the two
--     tables (organization values first -- they are lost);
--   * then re-run 422_asset_valuation_config.sql to restore the 422 bodies
--     of sp_asset_form_template_get and sp_asset_form_template_readiness
--     (422 is re-runnable).
-- Global defaults in reference_option are untouched.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DELETE p FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'asset-option-lists';
DELETE FROM grac_practice.menu_master WHERE menu_key = N'asset-option-lists';
PRINT '423 rollback: menu row removed.';
GO

IF OBJECT_ID('grac_practice.sp_asset_option_list_catalog','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_asset_option_list_catalog;
IF OBJECT_ID('grac_practice.sp_asset_option_list_get','P') IS NOT NULL     DROP PROCEDURE grac_practice.sp_asset_option_list_get;
IF OBJECT_ID('grac_practice.sp_asset_option_org_save','P') IS NOT NULL     DROP PROCEDURE grac_practice.sp_asset_option_org_save;
IF OBJECT_ID('grac_practice.sp_asset_option_org_override','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_asset_option_org_override;
PRINT '423 rollback: procedures dropped. Re-run 422 next, then the function and tables below can go.';
GO

-- The re-issued template procs reference the function; restore them first.
IF OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_form_template_get')) LIKE '%fn_asset_field_options%'
    PRINT '423 rollback: WARNING -- run 422_asset_valuation_config.sql now, then re-run this rollback to drop the function and tables.';
ELSE
BEGIN
    IF OBJECT_ID('grac_practice.fn_asset_field_options') IS NOT NULL EXEC (N'DROP FUNCTION grac_practice.fn_asset_field_options');
    IF OBJECT_ID('grac_practice.asset_field_option_org','U') IS NOT NULL EXEC (N'DROP TABLE grac_practice.asset_field_option_org');
    IF OBJECT_ID('grac_practice.asset_option_list_master','U') IS NOT NULL EXEC (N'DROP TABLE grac_practice.asset_option_list_master');
    PRINT '423 rollback: function and tables dropped.';
END
GO
