-- =====================================================================
-- 458 ROLLBACK  Settings -> Risk Settings
--
-- Removes the risk-settings permission rows and menu row. Revert the Web
-- files with it (risk-centre.cshtml / risk-centre.js gear + modal), or
-- the settings are reachable only by direct URL. Also remove the row from
-- 274_menu_master_seed.sql. ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ROLLBACK 458: menu_master missing; nothing to do.'; RETURN; END
GO
DELETE p
  FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'risk-settings';
PRINT 'ROLLBACK 458: permission rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO
DELETE FROM grac_practice.menu_master WHERE menu_key = N'risk-settings';
PRINT 'ROLLBACK 458: menu row removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO
PRINT 'ROLLBACK 458 complete.';
GO
