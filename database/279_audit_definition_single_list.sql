-- =====================================================================
-- 279 One audit list (Phase 3)
--
-- WHAT CHANGES
--   Audit Definition, Scope Builder and Question Sets were three separate
--   menu rows, each opening its own list. The audit is now the primary
--   entity: Audit Definition is a single audit list, and Scope Details
--   and Question Set are tabs inside the selected audit's page.
--
--   So the three standalone rows are taken OUT OF THE SIDEBAR:
--       org-assurance-definitions      (its list is now the container)
--       org-assurance-scope-builder    (now tab 2)
--       org-assurance-question-sets    (now tab 3)
--
--   'Audit Definition' (org-audit-definition) becomes a leaf again and is
--   the only way in.
--
-- HIDDEN, NOT DELETED -- AND WHY
--   These rows are set to status 'Inactive', not removed. Deleting them
--   would cascade into organization_role_menu_permission (menu_id FK) and
--   throw away every per-screen grant, which would have to be rebuilt if
--   the decision is ever reversed. Only 'Active' passes the sidebar and
--   permission filters, so Inactive is exactly "not shown" -- the rows,
--   their ids and their grants all survive.
--
--   The ROUTES stay alive either way: PracticeController resolves a screen
--   from PracticeScreen.All, not from menu_master, so existing deep links
--   such as /Practice/org-assurance-scope-builder?definitionId=123 keep
--   working. The row 3-dot menu still offers those per-section jumps.
--
-- NO AUDIT DATA IS TOUCHED. This script reads and writes menu_master only.
--
-- Re-runnable: yes. A second run reports 0 changes.
-- Rollback: database/279_audit_definition_single_list_rollback.sql
-- DEPENDS ON: 276 (the containers and the re-parenting).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (279): grac_practice.menu_master missing. Run 022 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-audit-definition')
BEGIN PRINT 'ABORT (279): org-audit-definition is missing. Run 276 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('279_audit_definition_single_list: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Take the three standalone list rows out of the sidebar.
--    parent_menu_id is left pointing at org-audit-definition so the
--    relationship is still readable, and so 276's rollback still finds
--    them where it expects.
-- =====================================================================
UPDATE grac_practice.menu_master
   SET status     = N'Inactive',
       updated_by = N'seed-279',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'org-assurance-definitions',
                    N'org-assurance-scope-builder',
                    N'org-assurance-question-sets')
   AND status <> N'Inactive';

PRINT '279: standalone list menus hidden = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 2. Audit Definition is now a leaf -- it has no active children left.
--    Its url is unchanged; this only refreshes the description-bearing
--    fields so the sidebar reads as the single audit list.
-- =====================================================================
UPDATE grac_practice.menu_master
   SET menu_name  = N'Audit Definition',
       menu_url   = N'Practice/org-audit-definition',
       icon_class = N'file-shield',
       status     = N'Active',
       updated_by = N'seed-279',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-audit-definition'
   AND (menu_name <> N'Audit Definition'
     OR ISNULL(menu_url, N'') <> N'Practice/org-audit-definition'
     OR status <> N'Active');

PRINT '279: Audit Definition refreshed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 3. Sanity report
-- =====================================================================
SELECT 'Only one audit list is visible' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.menu_master
                 WHERE menu_key IN (N'org-assurance-definitions',
                                    N'org-assurance-scope-builder',
                                    N'org-assurance-question-sets')
                   AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Audit Definition is active' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'org-audit-definition' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Hidden rows kept their permissions' AS Check_,
       CAST((SELECT COUNT(*)
               FROM grac_practice.organization_role_menu_permission p
               JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
              WHERE m.menu_key IN (N'org-assurance-definitions',
                                   N'org-assurance-scope-builder',
                                   N'org-assurance-question-sets')) AS NVARCHAR(20))
       + ' grant row(s) preserved' AS Result;

SELECT ISNULL(p.menu_key, N'(root)') AS Parent, m.menu_key AS MenuKey,
       m.menu_name AS MenuName, m.display_order AS Ord, m.status AS Status
  FROM grac_practice.menu_master m
  LEFT JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
 WHERE m.menu_key = N'nav-assurance'
    OR p.menu_key = N'nav-assurance'
    OR p.menu_key IN (N'org-audit-definition', N'org-audit-configuration')
 ORDER BY ISNULL(p.menu_key, N''), m.display_order;

PRINT '279 One audit list complete.';
GO
SET NOEXEC OFF;
GO
