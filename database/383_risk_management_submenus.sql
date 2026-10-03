-- =====================================================================
-- 383  Risk Management split into submenus
--
-- REQUEST
-- -------
--   The single "Risk Management" page (menu_key 'risk-centre', promoted to
--   a root menu by 373) hosts five tabbed sections plus a Dashboard tab:
--     Risk Candidate, Risk Register, Accept Risk, Review Risk, Calendar,
--     Dashboard.
--   Turn each tab into its own submenu/page under a "Risk Management"
--   parent, so clicking a submenu opens that section directly instead of a
--   tab inside one common page.
--
-- WHAT THIS DOES (menu configuration only)
-- ----------------------------------------
--   1. Makes 'risk-centre' a NON-navigable parent group: menu_url -> '#'.
--      menu_id, menu_key, menu_name ('Risk Management'), parent_menu_id
--      (root/NULL), display_order (280), module_type ('Risk Management')
--      and status are otherwise unchanged, so every existing permission
--      grant on it is preserved (grants are keyed by menu_id).
--   2. Adds six child menu rows under it (parent_menu_id = risk-centre's
--      menu_id), each routing to its own screen:
--        risk-centre-candidates  Practice/Index/risk-centre-candidates
--        risk-centre-register    Practice/Index/risk-centre-register
--        risk-centre-accept      Practice/Index/risk-centre-accept
--        risk-centre-review      Practice/Index/risk-centre-review
--        risk-centre-calendar    Practice/Index/risk-centre-calendar
--        risk-centre-dashboard   Practice/Index/risk-centre-dashboard
--      Each screen REUSES the existing risk-centre partial locked to one
--      tab (see PracticeScreen.cs, Manage.cshtml and risk-centre.js) -- no
--      grid/filter/action/API/business-logic change.
--   3. Grants full menu permissions on the six new rows to every active
--      role in every active organisation, matching how 274 seeds menu
--      rights, so any role that could see Risk Management sees the new
--      submenus.
--
-- NOT DONE
-- --------
--   * No feature_flag rows: the sidebar menu query does not gate on
--     feature flags (PracticeRepositoryService.QueryMenuMasterAsync returns
--     every Active row) and the risk-centre partial performs no inline flag
--     check, so the submenus need none.
--   * No change to the risk-centre screen, its APIs, procs or any risk
--     data. Practice/Index/risk-centre still resolves (legacy/direct link);
--     it is simply no longer linked from the menu.
--   * VIEW permission for the six pages rides on 'risk-centre' via
--     PracticeController.ScreenPermissionArea, so no per-page permission
--     area is introduced.
--
-- ALSO EDITED: 274_menu_master_seed.sql -- per this project's convention
--   (274 is a MERGE snapshot re-asserted on every run): risk-centre's
--   menu_url set to '#', the six child rows added to Section 1, and their
--   (child -> 'risk-centre') links added to Section 2, so a later re-run of
--   274 does not undo this migration.
--
-- DEPENDS ON: 022 (menu_master), 171 (risk-centre menu row), 373
--   (risk-centre is the 'Risk Management' root).
-- Rollback: 383_risk_management_submenus_rollback.sql
-- Re-runnable: yes (MERGE + guarded inserts). A second run makes no changes.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (383): grac_practice.menu_master missing.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN PRINT 'ABORT (383): organization_role_menu_permission missing.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'risk-centre')
BEGIN PRINT 'ABORT (383): risk-centre menu row missing. Run 171/373 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 0
BEGIN
    RAISERROR('383_risk_management_submenus: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. risk-centre becomes a non-navigable parent group.
-- ---------------------------------------------------------------------
UPDATE grac_practice.menu_master
   SET menu_url    = N'#',
       updated_by  = 'seed-383',
       updated_dt  = SYSUTCDATETIME()
 WHERE menu_key = N'risk-centre'
   AND menu_url <> N'#';
PRINT '383: risk-centre menu_url set to # (parent group) rows = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- 2. Six child submenu rows under risk-centre.
-- ---------------------------------------------------------------------
DECLARE @risk_parent_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'risk-centre');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'risk-centre-candidates', N'Risk Candidate', N'Practice/Index/risk-centre-candidates', 281, N'inbox'),
    (N'risk-centre-register',   N'Risk Register',  N'Practice/Index/risk-centre-register',   282, N'book'),
    (N'risk-centre-accept',     N'Accept Risk',    N'Practice/Index/risk-centre-accept',     283, N'circle-check'),
    (N'risk-centre-review',     N'Review Risk',    N'Practice/Index/risk-centre-review',     284, N'rotate-left'),
    (N'risk-centre-calendar',   N'Calendar',       N'Practice/Index/risk-centre-calendar',   285, N'calendar-days'),
    (N'risk-centre-dashboard',  N'Dashboard',      N'Practice/Index/risk-centre-dashboard',  286, N'chart-pie')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @risk_parent_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Risk Management',
    status = N'Active', updated_by = 'seed-383', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @risk_parent_id, src.display_order,
     src.icon_class, N'Risk Management', N'Active', 'seed-383');
PRINT '383: risk submenu rows upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- 3. Menu permissions for the six new rows -- every active role in every
--    active organisation, full rights, matching 274's Section 3.
-- ---------------------------------------------------------------------
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 1, 1,
       N'Active', @active_rs, N'seed-383', SYSUTCDATETIME()
FROM   grac_practice.organization_role r
JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
JOIN   grac_practice.menu_master m
       ON m.menu_key IN (N'risk-centre-candidates', N'risk-centre-register',
                         N'risk-centre-accept', N'risk-centre-review',
                         N'risk-centre-calendar', N'risk-centre-dashboard')
WHERE  o.status = N'Active' AND r.status = N'Active'
  AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission p
        WHERE p.role_id = r.role_id AND p.menu_id = m.menu_id);
PRINT '383: submenu permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------
SELECT '383-a risk-centre is a parent group (url #)' AS Check_,
       CASE WHEN (SELECT menu_url FROM grac_practice.menu_master WHERE menu_key=N'risk-centre') = N'#'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '383-b six submenu rows exist and are Active under risk-centre',
       CASE WHEN (
            SELECT COUNT(*) FROM grac_practice.menu_master c
              JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
             WHERE p.menu_key = N'risk-centre' AND c.status = N'Active'
               AND c.menu_key IN (N'risk-centre-candidates', N'risk-centre-register',
                                  N'risk-centre-accept', N'risk-centre-review',
                                  N'risk-centre-calendar', N'risk-centre-dashboard')) = 6
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '383-c risk-centre existing permissions preserved',
       CASE WHEN EXISTS (
            SELECT 1 FROM grac_practice.organization_role_menu_permission p
              JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
             WHERE m.menu_key = N'risk-centre' AND p.can_view = 1)
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '--- Diagnostic: Risk Management parent + children, in display order ---';
SELECT c.display_order AS Ord, c.menu_key AS Key_, c.menu_name AS Name_, c.menu_url AS Url_, c.status AS Status_
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
 WHERE p.menu_key = N'risk-centre'
 ORDER BY c.display_order;

PRINT '383 complete. Risk Management is now an expandable parent with six';
PRINT '    submenu pages, each reusing the risk-centre content on one tab.';
GO
SET NOEXEC OFF;
GO
