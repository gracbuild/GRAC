-- =====================================================================
-- 402 rollback: restore the Organization menus.
--  * nav-organization: "Settings" -> "Organization", icon gear -> building.
--  * organization-administration: "Organization" -> "Administration", icon
--    building -> building-user, re-parented under nav-organization.
-- ASCII-only. Idempotent.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

UPDATE grac_practice.menu_master
   SET menu_name  = N'Organization',
       icon_class = N'building',
       updated_by = N'migration-402-rollback',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'nav-organization';

UPDATE grac_practice.menu_master
   SET menu_name      = N'Administration',
       icon_class     = N'building-user',
       parent_menu_id = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-organization'),
       updated_by     = N'migration-402-rollback',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'organization-administration';
GO

PRINT '402 rollback complete.';
GO
