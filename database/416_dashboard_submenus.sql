-- =====================================================================
-- 416  Dashboard submenu under each module parent
--
-- REQUEST
-- -------
--   Governance, Issues & Actions, Risk Management and Audit Assurance
--   opened their dashboard from the PARENT row (413 / 414 gave the parent
--   a menu_url, and the sidebar navigates a parent that has a url --
--   data-nav-href, 276). One click both expanded the subtree and loaded
--   the dashboard. Now:
--     * a parent click only expands / collapses its children;
--     * a "Dashboard" child, FIRST under each parent, opens that module's
--       existing dashboard.
--
-- WHAT THIS DOES (menu configuration only)
-- ----------------------------------------
--   1. Parents lose their url, back to what they were before 413 / 414:
--        nav-governance, nav-oversight, nav-assurance -> NULL (414's
--        rollback value); risk-centre -> '#' (383's value).
--      A parent with no url renders no data-nav-href, so the sidebar only
--      toggles it (_PracticeMenuTree.cshtml / _Layout.cshtml, unchanged).
--   2. Three new child rows, each the first child of its parent (its
--      display_order is one below the parent's lowest existing child):
--        governance-dashboard      under nav-governance   99   (first child 100)
--        issues-actions-dashboard  under nav-oversight   223   (first child 224)
--        audit-assurance-dashboard under nav-assurance   439   (first child 440)
--      menu_key = the existing dashboard screen key, so the sidebar
--      highlights it on the dashboard page and its grant is the
--      "<key>:VIEW" permission the page now checks (see below).
--   3. Risk Management already has its Dashboard child (383,
--      risk-centre-dashboard, last at 286). It moves to 280, ahead of
--      Risk Candidate (281). Its permission is unchanged: like every
--      risk-centre-* page it rides on the 'risk-centre' grant (383).
--   4. Permissions for the three new rows. Until now a module dashboard
--      had no menu row and was open to whoever could VIEW one of the
--      screens it summarises (Web Models/ManagementDashboards.cs). The
--      page now ALSO requires VIEW on its own Dashboard row, so a role
--      can be denied a dashboard in Role Master. To change nobody's
--      access today, each role gets can_view (only -- the page is
--      read-only) on a Dashboard row exactly when it already has an
--      Active can_view grant on one of that dashboard's child screens:
--        governance-dashboard      organization-controls, organization-requirements, resolve
--        issues-actions-dashboard  gaps, tasks, exception-centre
--        audit-assurance-dashboard org-assurance-executions, org-assurance-observations, org-assurance-plans
--      (the same lists as ManagementDashboards.Sections). Existing rows
--      are never touched, so a re-run never re-grants a removed right.
--
-- NOT CHANGED: every other child row, its order relative to its
--   siblings, its route and its grants; the dashboard pages, their
--   procedures and APIs.
--
-- ALSO EDITED: 274_menu_master_seed.sql (parent urls, the three rows,
--   their parent links, risk-centre-dashboard's order), so a re-run of
--   274 does not undo this.
--
-- DEPLOY WITH the matching Web build (PracticeController.CanViewScreen /
--   ManagementDashboardController check the new grant). Users re-login so
--   their session picks up the new "<dashboard>:VIEW" permission.
-- DEPENDS ON: 274, 383, 390, 413, 414.
-- Rollback: 416_dashboard_submenus_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role','U') IS NULL
BEGIN PRINT 'ABORT (416): menu / permission tables missing.'; SET @ok = 0; END
IF @ok = 1 AND (SELECT COUNT(*) FROM grac_practice.menu_master
                 WHERE menu_key IN (N'nav-governance', N'nav-oversight', N'nav-assurance',
                                    N'risk-centre', N'risk-centre-dashboard')) <> 5
BEGIN PRINT 'ABORT (416): a module parent or risk-centre-dashboard is missing. Run 274/383 first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('416_dashboard_submenus: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Parents only expand / collapse.
-- ---------------------------------------------------------------------
UPDATE grac_practice.menu_master
   SET menu_url = NULL, updated_by = N'seed-416', updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'nav-governance', N'nav-oversight', N'nav-assurance')
   AND menu_url IS NOT NULL;
PRINT CONCAT('416: module parent urls cleared: ', @@ROWCOUNT);

UPDATE grac_practice.menu_master
   SET menu_url = N'#', updated_by = N'seed-416', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'risk-centre'
   AND ISNULL(menu_url, N'') <> N'#';
PRINT CONCAT('416: risk-centre url reset to #: ', @@ROWCOUNT);
GO

-- ---------------------------------------------------------------------
-- 2. The three Dashboard children.
-- ---------------------------------------------------------------------
MERGE grac_practice.menu_master AS t
USING (
    SELECT x.menu_key, x.menu_url, x.display_order, x.module_type, p.menu_id AS parent_menu_id
      FROM (VALUES
        (N'governance-dashboard',      N'Practice/Index/governance-dashboard',       99, N'Governance',       N'nav-governance'),
        (N'issues-actions-dashboard',  N'Practice/Index/issues-actions-dashboard',  223, N'Issues & Actions', N'nav-oversight'),
        (N'audit-assurance-dashboard', N'Practice/Index/audit-assurance-dashboard', 439, N'Audit Assurance',  N'nav-assurance')
      ) x(menu_key, menu_url, display_order, module_type, parent_key)
      JOIN grac_practice.menu_master p ON p.menu_key = x.parent_key
) AS s
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_url, N'') <> s.menu_url
               OR ISNULL(t.parent_menu_id, -1) <> s.parent_menu_id
               OR t.display_order <> s.display_order
               OR t.menu_name <> N'Dashboard'
               OR t.status <> N'Active') THEN UPDATE SET
    menu_name = N'Dashboard', menu_url = s.menu_url, parent_menu_id = s.parent_menu_id,
    display_order = s.display_order, icon_class = N'chart-pie', module_type = s.module_type,
    status = N'Active', updated_by = N'seed-416', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (s.menu_key, N'Dashboard', s.menu_url, s.parent_menu_id, s.display_order,
     N'chart-pie', s.module_type, N'Active', N'seed-416');
PRINT CONCAT('416: dashboard submenu rows upserted: ', @@ROWCOUNT);
GO

-- ---------------------------------------------------------------------
-- 3. Risk Management's Dashboard becomes its first child.
-- ---------------------------------------------------------------------
UPDATE grac_practice.menu_master
   SET display_order = 280, updated_by = N'seed-416', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'risk-centre-dashboard'
   AND display_order <> 280;
PRINT CONCAT('416: risk-centre-dashboard moved first: ', @@ROWCOUNT);
GO

-- ---------------------------------------------------------------------
-- 4. VIEW on each new Dashboard row for every role that can VIEW one of
--    that dashboard's child screens today. Missing rows only.
-- ---------------------------------------------------------------------
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT DISTINCT p.role_id, d.menu_id, 1, 0, 0, 0, 0,
       N'Active', @active_rs, N'seed-416', SYSUTCDATETIME()
  FROM (VALUES
        (N'governance-dashboard',      N'organization-controls'),
        (N'governance-dashboard',      N'organization-requirements'),
        (N'governance-dashboard',      N'resolve'),
        (N'issues-actions-dashboard',  N'gaps'),
        (N'issues-actions-dashboard',  N'tasks'),
        (N'issues-actions-dashboard',  N'exception-centre'),
        (N'audit-assurance-dashboard', N'org-assurance-executions'),
        (N'audit-assurance-dashboard', N'org-assurance-observations'),
        (N'audit-assurance-dashboard', N'org-assurance-plans')
       ) x(dashboard_key, child_key)
  JOIN grac_practice.menu_master d ON d.menu_key = x.dashboard_key
  JOIN grac_practice.menu_master c ON c.menu_key = x.child_key AND c.status = N'Active'
  JOIN grac_practice.organization_role_menu_permission p
       ON p.menu_id = c.menu_id AND p.can_view = 1 AND p.status = N'Active'
 WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = p.role_id AND e.menu_id = d.menu_id);
PRINT CONCAT('416: dashboard VIEW grants inserted: ', @@ROWCOUNT);
GO

-- ---------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------
SELECT '416-a parents carry no dashboard url' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.menu_master
                              WHERE menu_key IN (N'nav-governance', N'nav-oversight', N'nav-assurance')
                                AND menu_url IS NOT NULL)
             AND (SELECT menu_url FROM grac_practice.menu_master WHERE menu_key = N'risk-centre') = N'#'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '416-b each module parent has Dashboard as its first Active child',
       CASE WHEN (SELECT COUNT(*) FROM (
                    SELECT p.menu_key AS parent_key,
                           (SELECT TOP 1 c.menu_key FROM grac_practice.menu_master c
                             WHERE c.parent_menu_id = p.menu_id AND c.status = N'Active'
                             ORDER BY c.display_order, c.menu_name) AS first_child
                      FROM grac_practice.menu_master p
                     WHERE p.menu_key IN (N'nav-governance', N'nav-oversight', N'nav-assurance', N'risk-centre')) f
                   WHERE f.first_child = CASE f.parent_key
                           WHEN N'nav-governance' THEN N'governance-dashboard'
                           WHEN N'nav-oversight'  THEN N'issues-actions-dashboard'
                           WHEN N'nav-assurance'  THEN N'audit-assurance-dashboard'
                           ELSE N'risk-centre-dashboard' END) = 4
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '416-c no role lost a dashboard it could open (child VIEW => dashboard VIEW)',
       CASE WHEN NOT EXISTS (
            SELECT 1
              FROM (VALUES (N'governance-dashboard', N'organization-controls'), (N'governance-dashboard', N'organization-requirements'),
                           (N'governance-dashboard', N'resolve'), (N'issues-actions-dashboard', N'gaps'),
                           (N'issues-actions-dashboard', N'tasks'), (N'issues-actions-dashboard', N'exception-centre'),
                           (N'audit-assurance-dashboard', N'org-assurance-executions'),
                           (N'audit-assurance-dashboard', N'org-assurance-observations'),
                           (N'audit-assurance-dashboard', N'org-assurance-plans')) x(dashboard_key, child_key)
              JOIN grac_practice.menu_master d ON d.menu_key = x.dashboard_key
              JOIN grac_practice.menu_master c ON c.menu_key = x.child_key AND c.status = N'Active'
              JOIN grac_practice.organization_role_menu_permission p
                   ON p.menu_id = c.menu_id AND p.can_view = 1 AND p.status = N'Active'
             WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                                WHERE e.role_id = p.role_id AND e.menu_id = d.menu_id))
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '--- Module parents and their children, in sidebar order ---';
SELECT p.menu_key AS Parent_, ISNULL(p.menu_url, N'(none)') AS ParentUrl_,
       c.display_order AS Ord, c.menu_key AS Child_, c.menu_name AS Name_, c.status AS Status_
  FROM grac_practice.menu_master p
  JOIN grac_practice.menu_master c ON c.parent_menu_id = p.menu_id
 WHERE p.menu_key IN (N'nav-governance', N'nav-oversight', N'risk-centre', N'nav-assurance')
 ORDER BY p.display_order, c.display_order, c.menu_name;

PRINT '416 complete. Parents expand only; Dashboard is the first child of each.';
GO
SET NOEXEC OFF;
GO
