-- =====================================================================
-- 402 Organization sidebar menus: rename + re-home
--
--  * organization-administration ("Administration", a child of the
--    Organization nav group) -> renamed to "Organization", promoted to a
--    ROOT (parent_menu_id = NULL), icon building-user -> building.
--  * nav-organization ("Organization", the top-level group) -> renamed to
--    "Settings", icon building -> gear.
--
-- Menu-only change to grac_practice.menu_master. status, urls, permissions
-- and every child under nav-organization ("Settings") are untouched. The 274
-- snapshot is amended to match (menu_master cannot be reconstructed
-- statically, so both must move together). Idempotent. ASCII-only.
-- Rollback restores the previous names, icons and parent.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- "Administration" -> "Organization", promoted to a root menu.
UPDATE grac_practice.menu_master
   SET menu_name      = N'Organization',
       icon_class     = N'building',
       parent_menu_id = NULL,
       updated_by     = N'migration-402',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'organization-administration';

-- "Organization" nav group -> "Settings".
UPDATE grac_practice.menu_master
   SET menu_name  = N'Settings',
       icon_class = N'gear',
       updated_by = N'migration-402',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'nav-organization';
GO

PRINT '402 complete.';
GO
