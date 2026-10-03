-- =====================================================================
-- 390 rollback: Home menu_url back to 'Practice/Index', the My group
-- back in the sidebar, show_in_sidebar dropped.
-- ALSO revert the 390 edits in 274_menu_master_seed.sql, or its next
-- run re-applies them. Program.cs's route constraint can stay (it only
-- makes /Practice/Index resolve to Home). ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
GO
UPDATE grac_practice.menu_master
   SET menu_url = N'Practice/Index', updated_by = N'390-rollback', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'dashboard' AND menu_url = N'dashboard';
GO
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'df_pm_menu_show_in_sidebar')
    ALTER TABLE grac_practice.menu_master DROP CONSTRAINT df_pm_menu_show_in_sidebar;
GO
IF COL_LENGTH('grac_practice.menu_master','show_in_sidebar') IS NOT NULL
    ALTER TABLE grac_practice.menu_master DROP COLUMN show_in_sidebar;
GO
PRINT '390 rolled back.';
GO
