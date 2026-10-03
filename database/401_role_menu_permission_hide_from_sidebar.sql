-- =====================================================================
-- 401 Hide the standalone "Role Menu Permission" screen from the sidebar
--
-- Its matrix now lives inside Role Master (the Role add/edit editor), so the
-- separate sidebar entry is redundant. It is HIDDEN (show_in_sidebar = 0),
-- not deactivated: status stays 'Active' because status is also the
-- permission filter (PracticeAuthenticationService.LoadPermissionsAsync joins
-- menu_master WHERE m.status='Active'). Setting it Inactive would strip every
-- role's role-menu-permissions:* permission and 403 the unified editor's own
-- save, which still posts through the role-menu-permissions API. Hiding keeps
-- authorization intact while removing it from navigation (the same mechanism
-- migration 390 used for the My group).
--
-- No data change to organization_role_menu_permission. Reuses 390's
-- show_in_sidebar column. Idempotent. ASCII-only.
-- DEPENDS ON: 390 (show_in_sidebar column). Rollback restores it to the sidebar.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('grac_practice.menu_master','show_in_sidebar') IS NULL
   THROW 52840, '401 requires grac_practice.menu_master.show_in_sidebar -- apply migration 390 first.', 1;
GO

UPDATE grac_practice.menu_master
   SET show_in_sidebar = 0,
       updated_by = N'migration-401',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'role-menu-permissions'
   AND show_in_sidebar = 1;
GO

PRINT '401 complete.';
GO
