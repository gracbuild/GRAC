-- =====================================================================
-- 539 Audit Configuration -- one menu item
--
-- REQUEST (2026-11-13, sir)
--   "menu lu audit nte under le workflow polulla sub menus ini kalayalo
--    ... ini audit configuration mathram mathi"
--   Audit Configuration (537) is one page holding Workflow, Scoring,
--   Trigger and Scope Resolution, so their own sidebar rows under it go.
--
-- WHAT CHANGES (the 279 pattern, exactly)
--   Set to 'Inactive' -- out of the sidebar:
--       org-assurance-workflow-config   (Workflow Config)
--       org-assurance-scoring-config    (Scoring Config)
--       org-assurance-triggers          (Triggers)
--       org-assurance-scope-resolution  (Scope Resolution)
--   'Audit Configuration' (org-audit-configuration) has no active
--   children left, so it is a leaf -- the only way in.
--   (org-assurance-evidence-config is already Inactive since 536.)
--
-- HIDDEN, NOT DELETED -- as 279: the rows, their ids, parent links and
--   permission grants stay (deleting would cascade into
--   organization_role_menu_permission). Routes stay alive: the screens
--   are resolved from PracticeScreen.All, and Audit Configuration hosts
--   all four.
--
-- ALSO EDITED: 274_menu_master_seed.sql (the four rows' status).
-- NO AUDIT DATA IS TOUCHED. menu_master only.
-- Re-runnable: yes. Rollback: 539_audit_configuration_single_menu_rollback.sql
-- DEPENDS ON: 276 (re-parenting), 537 (the one page).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-audit-configuration')
BEGIN
    PRINT 'ABORT (539): menu_master or org-audit-configuration missing. Run 276 first. Nothing was changed.';
    RAISERROR('539_audit_configuration_single_menu: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

UPDATE grac_practice.menu_master
   SET status     = N'Inactive',
       updated_by = N'seed-539',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'org-assurance-workflow-config',
                    N'org-assurance-scoring-config',
                    N'org-assurance-triggers',
                    N'org-assurance-scope-resolution')
   AND status <> N'Inactive';

PRINT '539: configuration sub-menus hidden = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- Sanity report
SELECT '539 Audit Configuration has no active sub-menu' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.menu_master m
                  JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
                 WHERE p.menu_key = N'org-audit-configuration' AND m.status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '539 Audit Configuration is active',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'org-audit-configuration' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END;

SELECT ISNULL(p.menu_key, N'(root)') AS Parent, m.menu_key AS MenuKey,
       m.menu_name AS MenuName, m.display_order AS Ord, m.status AS Status
  FROM grac_practice.menu_master m
  LEFT JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
 WHERE p.menu_key IN (N'nav-assurance', N'org-audit-configuration')
 ORDER BY ISNULL(p.menu_key, N''), m.display_order;

PRINT '539 complete. Users sign out and back in to see the menu change.';
GO
SET NOEXEC OFF;
GO
