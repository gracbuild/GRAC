-- =====================================================================
-- 578  Audit Assurance menu grouped by area (2026-11-17, sir)
--
-- REQUEST: group the Audit Assurance menus as in sir's screenshot:
--   1. Audit Intelligence  -- Audit Universe, (RBIA Assessment)
--   2. Audit Definition    -- Audit Definitions, Question Sets
--                             (Audit Configuration stays inside a
--                             definition -- not on the menu, 549)
--   3. Audit Planning      -- Annual Audit Plans (programmes are inside
--                             a plan, 565), Audit Engagements
--   4. Audit Execution     -- My Audits, Executions, Workpapers
--   5. Audit Findings      -- Observations, (Audit Follow-up)
--   6. Audit Reporting     -- Audit Reports, (Audit Committee Dashboards)
--   7. Audit Governance    -- (Audit Quality & Review)
--   The Dashboard stays first, as the module's entry point.
--   Items in brackets are not built yet; their groups get them when they
--   are. Audit Governance has nothing built, so it is not added (an empty
--   group would not show anyway).
--
-- WHAT THIS DOES (menu only -- no screen, grant or url changes)
--   1. NEW group rows (no url) under 'nav-assurance':
--        nav-audit-intelligence (exists from 577) 441
--        nav-audit-definition   442   Audit Definition
--        nav-audit-planning     443   Audit Planning
--        nav-audit-execution    444   Audit Execution
--        nav-audit-findings     445   Audit Findings
--        nav-audit-reporting    446   Audit Reporting
--   2. The screens move under them (order within the group):
--        org-audit-definition         -> Audit Definition  10 ("Audit Definitions")
--        org-assurance-question-sets  -> Audit Definition  20
--        org-assurance-plans          -> Audit Planning    10 ("Annual Audit Plans")
--        org-audit-engagements        -> Audit Planning    20
--        org-my-audits                -> Audit Execution   10
--        org-assurance-executions     -> Audit Execution   20
--        org-workpapers               -> Audit Execution   30
--        org-assurance-observations   -> Audit Findings    10
--        org-audit-reports            -> Audit Reporting   10
--      Audit Intelligence keeps Audit Universe (10) and Universe
--      Configuration (20).
--   3. Written back into 274.
-- A group needs no permission row: the sidebar keeps a group while the
-- signed-in role may open one of its screens (PracticeController
-- .PermittedMenu). Every screen keeps its menu_id and so every role's
-- permission.
-- NOTE: 416 / 520 / 540 / 549 / 555 / 566 / 567 / 568 re-parent their row
-- to 'nav-assurance' when re-run; run 578 again after re-running any of
-- them (274 is updated, so a 274 run puts them back too).
-- DEPENDS ON: 577 (nav-audit-intelligence).
-- Rollback: 578_audit_assurance_menu_groups_rollback.sql.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance')
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-audit-intelligence')
BEGIN
    PRINT 'ABORT (578): run 577 first. Nothing was changed.';
    RAISERROR('578_audit_assurance_menu_groups: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. The groups
-- =====================================================================
DECLARE @assurance_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'nav-audit-intelligence', N'Audit Intelligence', 441, N'brain'),
    (N'nav-audit-definition',   N'Audit Definition',   442, N'file-shield'),
    (N'nav-audit-planning',     N'Audit Planning',     443, N'calendar-days'),
    (N'nav-audit-execution',    N'Audit Execution',    444, N'play-circle'),
    (N'nav-audit-findings',     N'Audit Findings',     445, N'triangle-exclamation'),
    (N'nav-audit-reporting',    N'Audit Reporting',    446, N'file-lines')
) AS src(menu_key, menu_name, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = NULL,
    parent_menu_id = @assurance_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Audit Assurance',
    status = N'Active', updated_by = 'seed-578', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, NULL, @assurance_id, src.display_order,
     src.icon_class, N'Audit Assurance', N'Active', 'seed-578');
PRINT '578.1: Audit Assurance group rows upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 2. The screens under their groups (name changed only where sir's list
--    names the screen differently)
-- =====================================================================
UPDATE m
   SET parent_menu_id = g.menu_id,
       display_order  = s.display_order,
       menu_name      = ISNULL(s.menu_name, m.menu_name),
       updated_by     = 'seed-578', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master m
  JOIN (VALUES
        (N'org-audit-definition',        N'nav-audit-definition', 10, N'Audit Definitions'),
        (N'org-assurance-question-sets', N'nav-audit-definition', 20, CAST(NULL AS NVARCHAR(200))),
        (N'org-assurance-plans',         N'nav-audit-planning',   10, N'Annual Audit Plans'),
        (N'org-audit-engagements',       N'nav-audit-planning',   20, NULL),
        (N'org-my-audits',               N'nav-audit-execution',  10, NULL),
        (N'org-assurance-executions',    N'nav-audit-execution',  20, NULL),
        (N'org-workpapers',              N'nav-audit-execution',  30, NULL),
        (N'org-assurance-observations',  N'nav-audit-findings',   10, NULL),
        (N'org-audit-reports',           N'nav-audit-reporting',  10, NULL),
        (N'org-audit-universe',          N'nav-audit-intelligence', 10, NULL),
        (N'org-audit-universe-config',   N'nav-audit-intelligence', 20, NULL)
       ) AS s(menu_key, group_key, display_order, menu_name)
       ON s.menu_key = m.menu_key
  JOIN grac_practice.menu_master g ON g.menu_key = s.group_key;
PRINT '578.2: screens moved under their groups = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 3. Verification: the tree under Audit Assurance
-- =====================================================================
SELECT ISNULL(g.menu_name, N'(Audit Assurance)') AS GroupName, m.menu_key AS MenuKey, m.menu_name AS MenuName,
       m.display_order AS DisplayOrder, m.status AS Status
  FROM grac_practice.menu_master m
  JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
  LEFT JOIN grac_practice.menu_master g ON g.menu_id = m.parent_menu_id AND g.menu_key <> N'nav-assurance'
 WHERE m.status = N'Active'
   AND (p.menu_key = N'nav-assurance' OR p.parent_menu_id = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance'))
 ORDER BY ISNULL(g.display_order, m.display_order), CASE WHEN g.menu_id IS NULL THEN 0 ELSE 1 END, m.display_order;
PRINT '578 done: Audit Assurance menus grouped (Intelligence, Definition, Planning, Execution, Findings, Reporting).';
GO
