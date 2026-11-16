-- =====================================================================
-- 533 ROLLBACK  Risk Management -> Settings
--
-- Puts Risk Settings (old name) and Risk Methodology back under the
-- organisation Settings menu (nav-organization) at 265 / 267, re-activates
-- Risk Acceptance Approval Authority, and removes the group row and its
-- permission rows. Revert the Web files with it (risk-settings.cshtml /
-- .js, risk-acceptance-authority.cshtml / .js, PracticeScreen.cs,
-- Manage.cshtml), or the acceptance-authority menu opens an empty page.
-- Also revert 274_menu_master_seed.sql. ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ROLLBACK 533: menu_master missing; nothing to do.'; RETURN; END
GO
DECLARE @settings_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-organization');
IF @settings_id IS NULL
BEGIN PRINT 'ROLLBACK 533: nav-organization missing; nothing changed.'; RETURN; END

UPDATE grac_practice.menu_master
   SET menu_name = N'Risk Settings', parent_menu_id = @settings_id, display_order = 265,
       module_type = N'Organization', updated_by = 'rollback-533', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'risk-settings';
PRINT 'ROLLBACK 533: risk-settings restored = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE grac_practice.menu_master
   SET menu_name = N'Risk Methodology', parent_menu_id = @settings_id, display_order = 267,
       module_type = N'Organization', updated_by = 'rollback-533', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'risk-methodology';
PRINT 'ROLLBACK 533: risk-methodology restored = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE grac_practice.menu_master
   SET status = N'Active', updated_by = 'rollback-533', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'risk-acceptance-authority';
PRINT 'ROLLBACK 533: risk-acceptance-authority re-activated = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO
DELETE p
  FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'risk-centre-settings';
PRINT 'ROLLBACK 533: group permission rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
DELETE FROM grac_practice.menu_master
 WHERE menu_key = N'risk-centre-settings'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master c
                    JOIN grac_practice.menu_master g ON g.menu_id = c.parent_menu_id
                   WHERE g.menu_key = N'risk-centre-settings');
PRINT 'ROLLBACK 533: group row removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO
PRINT 'ROLLBACK 533 complete.';
GO
