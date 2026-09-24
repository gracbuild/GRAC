-- =====================================================================
-- 276 Assurance -> Audit Management menu restructure (Phase 1)
--
-- WHAT THIS DOES
--   1. Renames the nav-assurance row from 'Assurance' to
--      'Audit Management'. menu_key stays nav-assurance -- renaming the
--      key would orphan every organization_role_menu_permission row that
--      points at it, and 274 resolves parents by key.
--   2. Adds two container menus, each a real page AND a parent:
--        org-audit-definition     "Audit Definition"
--        org-audit-configuration  "Audit Configuration"
--   3. Re-parents eight existing screens beneath them:
--        Audit Definition    <- org-assurance-definitions
--                               org-assurance-scope-builder
--                               org-assurance-question-sets
--        Audit Configuration <- org-assurance-evidence-config
--                               org-assurance-workflow-config
--                               org-assurance-scoring-config
--                               org-assurance-triggers
--                               org-assurance-scope-resolution
--   4. Moves every Audit Management row to module_type 'Audit
--      Management' so the page eyebrow matches the sidebar. The Web
--      constant PracticeScreen.AuditManagementGroup carries the same
--      string.
--   5. Grants the two new menus to every active role that can already
--      see the children, so nobody gains or loses access.
--
-- WHAT IS DELIBERATELY LEFT ALONE
--   * org-assurance-plans stays a direct child of Audit Management.
--     org_assurance_plan is organization-scoped and its items each
--     reference a definition, so one plan spans several audits --
--     nesting it under a per-audit configuration flow would invert that.
--   * org-assurance-executions and org-assurance-observations stay
--     direct children: they are operational, not setup.
--   * No menu is deleted and no menu_key changes, so every existing
--     permission row, bookmark and deep link keeps working. The eight
--     re-parented screens keep their own menu rows and their own routes.
--   * No assurance DATA is touched. This script reads and writes
--     menu_master and organization_role_menu_permission only.
--
-- Re-runnable: yes. A second run reports 0 changes.
-- Rollback: database/276_audit_management_menu_restructure_rollback.sql
-- DEPENDS ON: 022 (menu_master, organization_role_menu_permission),
--             071/075/078/081/085/088/094/097 (the eight screens),
--             272 (record_status_master).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

-- ---------------------------------------------------------------------
-- Prerequisites
-- ---------------------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (276): grac_practice.menu_master missing. Run 022 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN PRINT 'ABORT (276): organization_role_menu_permission missing. Run 022 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance')
BEGIN PRINT 'ABORT (276): nav-assurance is missing. Run 063 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-assurance-definitions')
BEGIN PRINT 'ABORT (276): org-assurance-definitions is missing. Run 071 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('276_audit_management_menu_restructure: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Rename the group. menu_key is untouched on purpose.
-- =====================================================================
UPDATE grac_practice.menu_master
   SET menu_name   = N'Audit Management',
       module_type = N'Audit Management',
       icon_class  = N'clipboard-check',
       updated_by  = N'seed-276',
       updated_dt  = SYSUTCDATETIME()
 WHERE menu_key = N'nav-assurance'
   AND (menu_name <> N'Audit Management' OR ISNULL(module_type, N'') <> N'Audit Management');

PRINT '276: nav-assurance renamed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 2. The two container menus.
--    They carry a menu_url AND will have children -- the sidebar honours
--    a parent's url since this migration (see _PracticeMenuTree.cshtml).
--    display_order 440 / 450 puts the two setup flows first, ahead of the
--    operational rows that keep their existing orders: Assurance Plans
--    (466), Executions (469), Observations (470). The eight re-parented
--    screens get 10..50 within their container, which is their step
--    order in the flow.
-- =====================================================================
DECLARE @audit_root_id BIGINT =
    (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance');

MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'org-audit-definition'   , N'Audit Definition'   , N'Practice/org-audit-definition'   , 440, N'file-shield'),
    (N'org-audit-configuration', N'Audit Configuration', N'Practice/org-audit-configuration', 450, N'sliders')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class)
ON t.menu_key = s.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name      = s.menu_name,
    menu_url       = s.menu_url,
    parent_menu_id = @audit_root_id,
    display_order  = s.display_order,
    icon_class     = s.icon_class,
    module_type    = N'Audit Management',
    status         = N'Active',
    updated_by     = N'seed-276',
    updated_dt     = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id,
     display_order, icon_class, module_type, status, entered_by)
VALUES
    (s.menu_key, s.menu_name, s.menu_url, @audit_root_id,
     s.display_order, s.icon_class, N'Audit Management', N'Active', N'seed-276');

PRINT '276: container menus upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 3. Re-parent the eight screens and give them their step order.
-- =====================================================================
DECLARE @definition_id BIGINT =
    (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'org-audit-definition');
DECLARE @configuration_id BIGINT =
    (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'org-audit-configuration');

IF @definition_id IS NULL OR @configuration_id IS NULL
BEGIN
    RAISERROR('276: container menus did not get created.', 16, 1);
    SET NOEXEC ON;
END

UPDATE m
SET    parent_menu_id = x.new_parent_id,
       display_order  = x.step_order,
       module_type    = N'Audit Management',
       updated_by     = N'seed-276',
       updated_dt     = SYSUTCDATETIME()
FROM   grac_practice.menu_master m
JOIN  (VALUES
    -- Audit Definition flow, in step order
    (N'org-assurance-definitions'     , @definition_id   , 10),
    (N'org-assurance-scope-builder'   , @definition_id   , 20),
    (N'org-assurance-question-sets'   , @definition_id   , 30),
    -- Audit Configuration flow, in step order
    (N'org-assurance-evidence-config' , @configuration_id, 10),
    (N'org-assurance-workflow-config' , @configuration_id, 20),
    (N'org-assurance-scoring-config'  , @configuration_id, 30),
    (N'org-assurance-triggers'        , @configuration_id, 40),
    (N'org-assurance-scope-resolution', @configuration_id, 50)
) AS x(menu_key, new_parent_id, step_order) ON x.menu_key = m.menu_key
WHERE  ISNULL(m.parent_menu_id, -1) <> x.new_parent_id
    OR m.display_order <> x.step_order
    OR ISNULL(m.module_type, N'') <> N'Audit Management';

PRINT '276: screens re-parented = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 3b. The rows that stay direct children of Audit Management still need
--     the new module_type so the page eyebrow reads consistently.
-- =====================================================================
UPDATE grac_practice.menu_master
   SET module_type = N'Audit Management',
       updated_by  = N'seed-276',
       updated_dt  = SYSUTCDATETIME()
 WHERE menu_key IN (N'org-assurance-plans', N'org-assurance-executions', N'org-assurance-observations')
   AND ISNULL(module_type, N'') <> N'Audit Management';

PRINT '276: direct children retyped = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 4. Permissions for the two new container menus.
--
--    A container is pure navigation, so its visibility must follow the
--    screens it hosts rather than invent new access: a role gets can_view
--    on a container exactly when it can already view at least one child.
--    Nobody gains access to a screen they could not already open, and
--    nobody loses any. can_add/edit/delete/approve stay 0 -- there is
--    nothing on a container page to add or edit.
-- =====================================================================
DECLARE @active_record_status_id INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

MERGE grac_practice.organization_role_menu_permission AS t
USING (
    SELECT DISTINCT
           p.role_id,
           parent.menu_id AS menu_id,
           @active_record_status_id AS record_status_id
      FROM grac_practice.organization_role_menu_permission p
      JOIN grac_practice.menu_master child  ON child.menu_id  = p.menu_id
      JOIN grac_practice.menu_master parent ON parent.menu_id = child.parent_menu_id
     WHERE parent.menu_key IN (N'org-audit-definition', N'org-audit-configuration')
       AND p.can_view = 1
       AND p.status   = N'Active'
) AS s
ON t.role_id = s.role_id AND t.menu_id = s.menu_id
WHEN MATCHED THEN UPDATE SET
    can_view   = 1,
    status     = N'Active',
    updated_by = N'seed-276',
    updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by)
VALUES
    (s.role_id, s.menu_id, 1, 0, 0, 0, 0,
     N'Active', s.record_status_id, N'seed-276');

PRINT '276: container permissions granted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 5. Sanity report
-- =====================================================================
SELECT 'Assurance renamed to Audit Management' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'nav-assurance' AND menu_name = N'Audit Management')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'No menu still displays as Assurance' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.menu_master
                              WHERE menu_name = N'Assurance' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Both containers exist and are Active' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.menu_master
                   WHERE menu_key IN (N'org-audit-definition', N'org-audit-configuration')
                     AND status = N'Active') = 2
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'All eight screens re-parented' AS Check_,
       CASE WHEN (SELECT COUNT(*)
                    FROM grac_practice.menu_master m
                    JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
                   WHERE p.menu_key IN (N'org-audit-definition', N'org-audit-configuration')) = 8
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'No role lost visibility of a child' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1
                  FROM grac_practice.organization_role_menu_permission p
                  JOIN grac_practice.menu_master child  ON child.menu_id  = p.menu_id
                  JOIN grac_practice.menu_master parent ON parent.menu_id = child.parent_menu_id
                 WHERE parent.menu_key IN (N'org-audit-definition', N'org-audit-configuration')
                   AND p.can_view = 1 AND p.status = N'Active'
                   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission pp
                                    WHERE pp.role_id = p.role_id AND pp.menu_id = parent.menu_id
                                      AND pp.can_view = 1 AND pp.status = N'Active'))
            THEN 'PASS' ELSE 'FAIL (a role can see a child but not its container)' END AS Result;

SELECT ISNULL(p.menu_key, N'(root)') AS Parent, m.menu_key AS MenuKey, m.menu_name AS MenuName,
       m.menu_url AS Url, m.display_order AS Ord, m.module_type AS ModuleType, m.status AS Status
  FROM grac_practice.menu_master m
  LEFT JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
 WHERE m.menu_key = N'nav-assurance'
    OR p.menu_key = N'nav-assurance'
    OR p.menu_key IN (N'org-audit-definition', N'org-audit-configuration')
 ORDER BY ISNULL(p.menu_key, N''), m.display_order;

PRINT '276 Audit Management menu restructure complete.';
GO
SET NOEXEC OFF;
GO
