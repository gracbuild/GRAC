-- =====================================================================
-- 383 ROLLBACK  Risk Management submenus -> single tabbed page
--
-- Reverses 383:
--   1. Removes the six submenu permission rows, then the six child menu
--      rows (risk-centre-candidates/register/accept/review/calendar/
--      dashboard).
--   2. Restores risk-centre's menu_url to Practice/Index/risk-centre so it
--      is a navigable page again (the tabbed landing page).
--
-- Does NOT touch risk-centre's name/parent/module_type (373's state) or any
-- risk data. ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ROLLBACK 383: menu_master missing; nothing to do.'; RETURN; END
GO

-- 1. Permissions on the six child rows.
DELETE p
  FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key IN (N'risk-centre-candidates', N'risk-centre-register',
                      N'risk-centre-accept', N'risk-centre-review',
                      N'risk-centre-calendar', N'risk-centre-dashboard');
PRINT 'ROLLBACK 383: submenu permission rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- 2. The six child menu rows.
DELETE FROM grac_practice.menu_master
 WHERE menu_key IN (N'risk-centre-candidates', N'risk-centre-register',
                    N'risk-centre-accept', N'risk-centre-review',
                    N'risk-centre-calendar', N'risk-centre-dashboard');
PRINT 'ROLLBACK 383: submenu rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- 3. risk-centre navigable again.
UPDATE grac_practice.menu_master
   SET menu_url   = N'Practice/Index/risk-centre',
       updated_by = 'rollback-383',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'risk-centre';
PRINT 'ROLLBACK 383: risk-centre menu_url restored rows = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO
PRINT 'ROLLBACK 383 complete.';
GO
