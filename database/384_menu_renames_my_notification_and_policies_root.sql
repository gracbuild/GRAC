-- =====================================================================
-- 384  Sidebar renames, "My Notification" parent, "Policies & Documents"
--      promoted to a root menu
--
-- SIR'S INSTRUCTION (2026-09-26)
-- ------------------------------
--   Renames (display label only):
--     Audit Management     -> Audit Assurance        (nav-assurance)
--     Document Management  -> Policies & Documents   (nav-documents)
--     Oversight            -> Issues & Actions       (nav-oversight)
--     Gap Center           -> Gap Register           (gaps)
--     Task Center          -> Task Board             (tasks)
--     Exception Centre     -> Exceptions & Waivers   (exception-centre)
--     Dashboard            -> Home                   (dashboard)
--   Structure:
--     * "My Notification" becomes a parent menu with three submenus:
--         My Practices, My Approvals, My Acknowledgements.
--       My Acknowledgements moves there from Document Management (same
--       link). My Practices / My Approvals links will be supplied later.
--     * Document Management (now Policies & Documents) is taken out from
--       under Governance and becomes a top-level (root) menu again.
--
-- DECISIONS CONFIRMED WITH SIR BEFORE WRITING
-- -------------------------------------------
--   * The EXISTING 'my-notifications' row IS the new parent (not a new
--     row). It is renamed 'My Notification', promoted to a root, and
--     keeps its menu_url -- so clicking the parent still opens the
--     existing task-notification inbox, using the "page AND parent"
--     pattern introduced by 276 (_PracticeMenuTree emits data-nav-href
--     for a parent that has a url). Its menu_id, permission grants and
--     the unread-badge hook in _Layout.cshtml (data-menu-key=
--     "my-notifications") are all unchanged.
--   * Page headings / eyebrows follow the sidebar -- done in
--     PracticeScreen.cs (Title / Group constants), see docs.
--
-- WHAT THIS DOES
-- --------------
--   1. menu_name renames above. menu_key is NEVER changed -- every
--      permission row, route, active-highlight and screen mapping is
--      keyed on menu_id / menu_key, so all of them survive.
--   2. module_type follows the renamed group label, the same way 276
--      re-labelled every Audit Management row, because the Role
--      Permission matrix (practice.js renderRolePermissionMatrix) groups
--      menus by module_type and PracticeMenuService overlays module_type
--      onto the screen Group:
--        'Oversight'        -> 'Issues & Actions'   (all rows)
--        'Audit Management' -> 'Audit Assurance'    (all rows)
--        nav-documents, document-uploads, document-acknowledgements
--                           -> 'Policies & Documents'
--        my-notifications, my-acknowledgements, my-practices,
--        my-approvals       -> 'My Notification'
--      The legacy, inactive 'Assurance Management' rows are untouched.
--   3. nav-documents -> root (parent NULL), display_order 400 -- the root
--      slot it held before 359 (between Audit Assurance 300 and
--      Organization 500).
--   4. my-notifications -> root, display_order 50 (right after Home at 0,
--      before Governance at 100).
--   5. my-acknowledgements -> child of my-notifications, display_order 30.
--   6. Two NEW placeholder child rows under my-notifications:
--        my-practices  'My Practices'  url '#'  order 10
--        my-approvals  'My Approvals'  url '#'  order 20
--      url '#' renders a non-navigating item (_PracticeMenuTree
--      NormalizeMenuUrl) until sir supplies the real links; update
--      menu_url here AND in 274 when they are known.
--   7. Grants full menu permissions on the two new rows to every active
--      role in every active organisation (383's pattern / 274 section 3).
--
-- NOT DONE
-- --------
--   * No screen, API, proc or business-data change. document-uploads and
--     document-acknowledgements keep their parent (nav-documents) and
--     simply travel with it to the root.
--   * Stored remark text such as 'Closed from Gap Center 3-dot menu.' is
--     historical data and is left alone.
--
-- ALSO EDITED: 274_menu_master_seed.sql (the authoritative MERGE snapshot
--   -- a re-run would otherwise revert all of this). While there, 274 was
--   also brought in line with 363 ('Control Statements') and 364
--   ('Standards & Frameworks'), which had never been carried into it.
--
-- DEPENDS ON: 022, 155 (document menus), 201-203 (my-notifications),
--   276, 359, 383.
-- Rollback: 384_menu_renames_my_notification_and_policies_root_rollback.sql
-- Re-runnable: yes. A second run makes no changes. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (384): grac_practice.menu_master missing.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN PRINT 'ABORT (384): organization_role_menu_permission missing.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'my-notifications')
BEGIN PRINT 'ABORT (384): my-notifications menu row missing. Run 201-203 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-documents')
BEGIN PRINT 'ABORT (384): nav-documents menu row missing. Run 155/359 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 0
BEGIN
    RAISERROR('384_menu_renames_my_notification_and_policies_root: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Display-name renames (menu_key unchanged).
-- ---------------------------------------------------------------------
UPDATE m
   SET menu_name  = x.new_name,
       updated_by = 'seed-384',
       updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master m
  JOIN (VALUES
        (N'nav-assurance'    , N'Audit Assurance'),
        (N'nav-documents'    , N'Policies & Documents'),
        (N'nav-oversight'    , N'Issues & Actions'),
        (N'gaps'             , N'Gap Register'),
        (N'tasks'            , N'Task Board'),
        (N'exception-centre' , N'Exceptions & Waivers'),
        (N'dashboard'        , N'Home'),
        (N'my-notifications' , N'My Notification')
  ) AS x(menu_key, new_name) ON x.menu_key = m.menu_key
 WHERE ISNULL(m.menu_name, N'') <> x.new_name;
PRINT '384: menu rows renamed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- 2. module_type follows the renamed groups.
-- ---------------------------------------------------------------------
UPDATE grac_practice.menu_master
   SET module_type = N'Issues & Actions', updated_by = 'seed-384', updated_dt = SYSUTCDATETIME()
 WHERE module_type = N'Oversight' AND menu_key <> N'my-notifications';
PRINT '384: module_type Oversight -> Issues & Actions rows = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE grac_practice.menu_master
   SET module_type = N'Audit Assurance', updated_by = 'seed-384', updated_dt = SYSUTCDATETIME()
 WHERE module_type = N'Audit Management';
PRINT '384: module_type Audit Management -> Audit Assurance rows = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE grac_practice.menu_master
   SET module_type = N'Policies & Documents', updated_by = 'seed-384', updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'nav-documents', N'document-uploads', N'document-acknowledgements')
   AND ISNULL(module_type, N'') <> N'Policies & Documents';
PRINT '384: module_type -> Policies & Documents rows = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE grac_practice.menu_master
   SET module_type = N'My Notification', updated_by = 'seed-384', updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'my-notifications', N'my-acknowledgements')
   AND ISNULL(module_type, N'') <> N'My Notification';
PRINT '384: module_type -> My Notification rows = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- 3 + 4. Policies & Documents and My Notification become roots.
-- ---------------------------------------------------------------------
UPDATE m
   SET parent_menu_id = NULL,
       display_order  = x.display_order,
       updated_by     = 'seed-384',
       updated_dt     = SYSUTCDATETIME()
  FROM grac_practice.menu_master m
  JOIN (VALUES
        (N'nav-documents'   , 400),
        (N'my-notifications',  50)
  ) AS x(menu_key, display_order) ON x.menu_key = m.menu_key
 WHERE m.parent_menu_id IS NOT NULL OR ISNULL(m.display_order, -1) <> x.display_order;
PRINT '384: rows promoted to root = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- 5 + 6. My Notification children.
-- ---------------------------------------------------------------------
DECLARE @notif_parent_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'my-notifications');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'my-practices', N'My Practices', N'#', 10, N'list-check'),
    (N'my-approvals', N'My Approvals', N'#', 20, N'circle-check')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED AND (
       ISNULL(target.parent_menu_id, -1) <> @notif_parent_id
    OR ISNULL(target.module_type, N'')   <> N'My Notification'
    OR ISNULL(target.status, N'')        <> N'Active'
) THEN UPDATE SET
    parent_menu_id = @notif_parent_id, module_type = N'My Notification',
    status = N'Active', updated_by = 'seed-384', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @notif_parent_id, src.display_order,
     src.icon_class, N'My Notification', N'Active', 'seed-384');
PRINT '384: My Practices / My Approvals rows upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
-- NOTE: on MATCHED the name / url / order are deliberately NOT forced,
-- so the real links sir sets later are not reset by a re-run of 384.

UPDATE grac_practice.menu_master
   SET parent_menu_id = @notif_parent_id,
       display_order  = 30,
       updated_by     = 'seed-384',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'my-acknowledgements'
   AND (ISNULL(parent_menu_id, -1) <> @notif_parent_id OR ISNULL(display_order, -1) <> 30);
PRINT '384: my-acknowledgements moved under My Notification rows = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- 7. Permissions for the two new rows -- every active role, every active
--    organisation, full rights (383 / 274 section 3 pattern).
-- ---------------------------------------------------------------------
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 1, 1,
       N'Active', @active_rs, N'seed-384', SYSUTCDATETIME()
FROM   grac_practice.organization_role r
JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
JOIN   grac_practice.menu_master m ON m.menu_key IN (N'my-practices', N'my-approvals')
WHERE  o.status = N'Active' AND r.status = N'Active'
  AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission p
        WHERE p.role_id = r.role_id AND p.menu_id = m.menu_id);
PRINT '384: new submenu permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------
SELECT '384-a renamed labels' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.menu_master
                   WHERE (menu_key = N'nav-assurance'    AND menu_name = N'Audit Assurance')
                      OR (menu_key = N'nav-documents'    AND menu_name = N'Policies & Documents')
                      OR (menu_key = N'nav-oversight'    AND menu_name = N'Issues & Actions')
                      OR (menu_key = N'gaps'             AND menu_name = N'Gap Register')
                      OR (menu_key = N'tasks'            AND menu_name = N'Task Board')
                      OR (menu_key = N'exception-centre' AND menu_name = N'Exceptions & Waivers')
                      OR (menu_key = N'dashboard'        AND menu_name = N'Home')
                      OR (menu_key = N'my-notifications' AND menu_name = N'My Notification')) = 8
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '384-b Policies & Documents and My Notification are roots',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.menu_master
                   WHERE menu_key IN (N'nav-documents', N'my-notifications')
                     AND parent_menu_id IS NULL) = 2
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '384-c My Notification has its three submenus',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.menu_master c
                    JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
                   WHERE p.menu_key = N'my-notifications' AND c.status = N'Active'
                     AND c.menu_key IN (N'my-practices', N'my-approvals', N'my-acknowledgements')) = 3
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '384-d no row left on module_type Oversight / Audit Management',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.menu_master
                              WHERE module_type IN (N'Oversight', N'Audit Management'))
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '384-e existing my-acknowledgements / my-notifications grants preserved',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission p
                           JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
                          WHERE m.menu_key = N'my-acknowledgements' AND p.can_view = 1)
            THEN 'PASS' ELSE 'REVIEW' END;

PRINT '--- Diagnostic: root menus in display order ---';
SELECT display_order AS Ord, menu_key AS Key_, menu_name AS Name_, status AS Status_
  FROM grac_practice.menu_master
 WHERE parent_menu_id IS NULL AND status = N'Active'
 ORDER BY display_order;

PRINT '--- Diagnostic: My Notification / Policies & Documents children ---';
SELECT p.menu_name AS Parent_, c.display_order AS Ord, c.menu_key AS Key_, c.menu_name AS Name_, c.menu_url AS Url_
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
 WHERE p.menu_key IN (N'my-notifications', N'nav-documents')
 ORDER BY p.menu_key, c.display_order;

PRINT '384 complete.';
GO
SET NOEXEC OFF;
GO
