-- =====================================================================
-- 512_organizations_menu_in_org_management_rollback.sql
--
-- Puts the 'organizations' menu row back as 512 found it: Inactive, named
-- "Organization Onboarding", module_type 'Organization Setup', parented to
-- 'nav-organization', and visible in the sidebar (show_in_sidebar = 1 --
-- its Inactive status is what hid it before).
--
-- The row is NEVER deleted: it has existed since the beginning and carries
-- menu_id plus every permission grant made against it.
--
-- AFTER THIS the Organization Management sidebar loses its Organizations
-- entry, and the organization list is reachable only at the module root --
-- which is the state that prompted 512. The list page itself, the landing
-- route and every permission are untouched.
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

UPDATE c
   SET status          = N'Inactive',
       menu_name       = N'Organization Onboarding',
       module_type     = N'Organization Setup',
       display_order   = 30,
       show_in_sidebar = 1,
       parent_menu_id  = (SELECT TOP (1) p.menu_id FROM grac_practice.menu_master p
                           WHERE p.menu_key = N'nav-organization'),
       updated_by      = N'rollback-512',
       updated_dt      = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
 WHERE c.menu_key = N'organizations';
PRINT CONCAT('512 rollback: organizations menu row restored: ', @@ROWCOUNT);
GO

PRINT '--- 512 rollback verification ---';
SELECT m.menu_key, m.menu_name, m.status, m.show_in_sidebar, m.display_order, m.module_type,
       (SELECT p.menu_key FROM grac_practice.menu_master p WHERE p.menu_id = m.parent_menu_id) AS parent_key
  FROM grac_practice.menu_master m
 WHERE m.menu_key = N'organizations';
PRINT '512 rollback: done. Sign out and in again.';
GO
