-- =====================================================================
-- 180 Organization SLA Config -- menu seed ROLLBACK
--
-- Removes the org-sla-config menu row, its role permission grants, and
-- the feature_flag_master row. Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

-- 1. Remove role permission rows referring to the menu.
DELETE p
  FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'org-sla-config';

-- 2. Remove feature_flag rows for the screen flag.
DELETE f
  FROM grac_practice.feature_flag f
  JOIN grac_practice.feature_flag_master fm ON fm.feature_flag_id = f.feature_flag_id
 WHERE fm.feature_code = N'screen.org-sla-config';

-- 3. Remove the menu row itself.
DELETE FROM grac_practice.menu_master
 WHERE menu_key = N'org-sla-config';

-- 4. Remove the feature flag master row.
DELETE FROM grac_practice.feature_flag_master
 WHERE feature_code = N'screen.org-sla-config';

COMMIT TRAN;
GO

PRINT '180 Organization SLA Config menu seed rolled back.';
GO
