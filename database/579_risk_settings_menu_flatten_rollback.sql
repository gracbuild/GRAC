-- =====================================================================
-- 579 ROLLBACK  Workflow and Methodology back under Risk Management -> Settings
--   Re-activates 'risk-centre-settings' and puts 'risk-settings' (291) and
--   'risk-methodology' (292) back under it -- the 533 layout. Also revert
--   274_menu_master_seed.sql. ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ROLLBACK 579: menu_master missing; nothing to do.'; RETURN; END
GO
DECLARE @group_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'risk-centre-settings');
IF @group_id IS NULL
BEGIN PRINT 'ROLLBACK 579: risk-centre-settings missing (run 533); nothing changed.'; RETURN; END

UPDATE grac_practice.menu_master
   SET status = N'Active', updated_by = 'rollback-579', updated_dt = SYSUTCDATETIME()
 WHERE menu_id = @group_id;
UPDATE grac_practice.menu_master
   SET parent_menu_id = @group_id, display_order = 291, updated_by = 'rollback-579', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'risk-settings';
UPDATE grac_practice.menu_master
   SET parent_menu_id = @group_id, display_order = 292, updated_by = 'rollback-579', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'risk-methodology';
PRINT 'ROLLBACK 579 complete.';
GO
