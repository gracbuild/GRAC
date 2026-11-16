-- =====================================================================
-- 512  "Organizations" as a real menu row in Organization Management
--
-- REQUEST (2026-11-02)
--   "subscription request eduthu kazhinjal pinne organization list leku
--    pokan ipo oru vazhi illa. so organizations nte oru menu koodi
--    ittolu."  Then: "menu db nnu alle? apo db change ille?"
--
--   Both are right. The organization list needed a menu entry, and a menu
--   belongs in menu_master. The first cut put the entry in code only (a
--   fallback to the static PracticeScreen registry in
--   PracticeController.MenuScreenFor); sir asked for it in the database,
--   so this migration makes the row real and that fallback is removed.
--
-- WHAT CHANGES
--   menu_master's 'organizations' row already exists and has since the
--   beginning. It is INACTIVE, named "Organization Onboarding", and
--   parented to 'nav-organization'. Three edits:
--
--     status      Inactive -> Active   the Organization Management module's
--                                      menu is projected from the Active
--                                      rows (PracticeMenuService
--                                      .VisibleScreens), so an Inactive row
--                                      is dropped and the entry never shows
--     menu_name   "Organization Onboarding" -> "Organizations"
--                                      the row's name is what the sidebar
--                                      prints (VisibleScreens overrides the
--                                      registry Title with menu_name)
--     parent      nav-organization -> Organization
--                                      the same parent organization-setup
--                                      has. 'Organization' is itself
--                                      InActive, which is what keeps these
--                                      rows out of PRACTICE MANAGEMENT's
--                                      sidebar: that one is a tree built
--                                      from Active rows, and a child whose
--                                      parent is absent is never reached.
--                                      Organization Management does not use
--                                      the tree, so it still shows them.
--
--   module_type becomes 'Organization' (the value organization-dependencies
--   already carries, and the group the screen itself declares in
--   PracticeScreen.All). NOT 'Organization Setup': _Layout's no-menu
--   fallback block lists every Active screen whose group is
--   'Organization Setup' under Organization Setup, and the list does not
--   belong there.
--
--   show_in_sidebar = 0 as well. The InActive parent already keeps the row
--   out of Practice Management's sidebar; this is the explicit guard, so
--   activating the 'Organization' group later cannot surface it there. It
--   does NOT affect Organization Management, whose menu comes from
--   VisibleScreens -- which deliberately still includes hidden rows.
--
-- PERMISSIONS: none granted here, and none needed.
--   PracticeController.ScreenPermissionArea maps 'organizations' to
--   'organization-setup', so whoever may open Organization Setup may see
--   the list -- as was already the case while the row was Inactive. The row
--   does now appear in Role Master's matrix; ticking it there has no effect
--   while that mapping stands. Removing the mapping and giving the screen
--   its own grants is a separate change (sir chose not to, for now).
--
-- SAFE TO RE-RUN. Requires 390 (menu_master.show_in_sidebar) and the
-- 'Organization' group row (274).
-- Rollback: 512_organizations_menu_in_org_management_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
   OR COL_LENGTH('grac_practice.menu_master','show_in_sidebar') IS NULL
BEGIN
    PRINT 'ABORT (512): run 390_home_route_and_my_work_on_home.sql first (menu_master.show_in_sidebar). Nothing was changed.';
    SET NOEXEC ON;
END
GO
IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'Organization')
BEGIN
    PRINT 'ABORT (512): the Organization group row is missing; run 274_menu_master_seed.sql first. Nothing was changed.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. The row: Active, renamed, module_type Organization
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'organizations', N'Organizations', N'Practice/Index/organizations', 5, N'building', N'Organization')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name
               OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order
               OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type
               OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order,
    icon_class = s.icon_class, module_type = s.module_type, status = N'Active',
    updated_by = N'seed-512', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-512');
PRINT CONCAT('512: organizations menu row upserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 2. Parent -- the inactive 'Organization' group, as organization-setup
-- =====================================================================
UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-512', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'Organization'
 WHERE c.menu_key = N'organizations'
   AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
PRINT CONCAT('512: parent wired to Organization: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 3. Explicitly out of the Practice Management sidebar
-- =====================================================================
UPDATE grac_practice.menu_master
   SET show_in_sidebar = 0, updated_by = N'seed-512', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'organizations'
   AND show_in_sidebar = 1;
PRINT CONCAT('512: hidden from the Practice Management sidebar: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 4. Verification
-- =====================================================================
PRINT '--- 512 verification ---';
SELECT m.menu_key, m.menu_name, m.status, m.show_in_sidebar, m.display_order, m.module_type,
       (SELECT p.menu_key FROM grac_practice.menu_master p WHERE p.menu_id = m.parent_menu_id) AS parent_key
  FROM grac_practice.menu_master m
 WHERE m.menu_key IN (N'organizations', N'subscription-requests', N'organization-setup')
 ORDER BY m.display_order;

-- Both Organization Management menu entries must be Active, or the module's
-- sidebar comes up short -- which is the fault this whole change fixes.
DECLARE @active_entries INT = (
    SELECT COUNT(*) FROM grac_practice.menu_master
     WHERE menu_key IN (N'organizations', N'subscription-requests') AND status = N'Active');
PRINT CONCAT('512: Organization Management menu rows Active (expect 2): ', @active_entries);
IF @active_entries < 2
    PRINT '512: WARNING -- run 511_subscription_requests_org_management.sql as well.';
GO

SET NOEXEC OFF;
GO
PRINT '512 complete. Sign out and in again -- the menu is read at sign-in.';
GO
