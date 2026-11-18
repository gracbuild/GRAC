-- =====================================================================
-- 585  Sidebar: "Organization" becomes a pure menu group
--
-- REQUEST (2026-11-18, sir): the Organization menu now holds Organization
--   Structure, People & Governance and Business Operations (575), but its
--   parent row still had a url, so a click always opened a page and the
--   sub-menu could not be closed again. Remove the parent's url.
--
-- WHAT: menu_master 'organization-administration' (sidebar "Organization"):
--   menu_url -> NULL. A parent without a url renders as "#" in
--   _PracticeMenuTree (no data-nav-href), so AdminLTE's treeview opens and
--   closes it like every other group. Its children, their order and every
--   role grant are unchanged; PermittedMenu keeps the group while a
--   permitted child exists.
-- Decision (sir): the Organization Administration page (profile, single
--   sign-on, subscribed releases) is not given another sidebar entry. Its
--   route (Practice/organization-administration) and permissions are
--   unchanged.
-- 274 amended to match. Idempotent. ASCII only.
-- Rollback: 585_organization_menu_group_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO
IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'organization-administration')
BEGIN
    PRINT 'ABORT (585): menu organization-administration not found. Nothing was changed.';
    RAISERROR('585_organization_menu_group: menu row missing.', 16, 1);
    SET NOEXEC ON;
END
GO
UPDATE grac_practice.menu_master
   SET menu_url = NULL, updated_by = N'seed-585', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'organization-administration' AND menu_url IS NOT NULL;
PRINT '585: organization-administration url cleared, rows = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO
SELECT m.menu_key, m.menu_name, m.menu_url, m.status,
       (SELECT COUNT(*) FROM grac_practice.menu_master c WHERE c.parent_menu_id = m.menu_id AND c.status = N'Active') AS active_children
  FROM grac_practice.menu_master m
 WHERE m.menu_key = N'organization-administration';
PRINT '585 done: Organization is a menu group (opens / closes).';
GO
