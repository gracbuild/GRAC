-- =====================================================================
-- 549 Audit Configuration leaves the sidebar
--
-- REQUEST (2026-11-14, sir)
--   "main menu nnu audit configuration remove cheyyam. athu definition
--    nte view page le actions lum 3 dots menu lum undallo."
--   Audit Configuration is opened from Audit Definition (the list's
--   3-dot and the view page's Actions -> "Audit Configuration"), so its
--   own sidebar row goes.
--
-- WHAT CHANGES (the 279 / 539 pattern)
--   org-audit-configuration -> 'Inactive' (out of the sidebar).
--
-- HIDDEN, NOT DELETED -- the row, its id, parent link and permission
--   grants stay (deleting would cascade into
--   organization_role_menu_permission). Only Active rows pass the
--   permission filter (279), so the Web maps the screen onto Audit
--   Definition -- whoever may open Audit Definition may open its
--   configuration (PracticeController.ScreenPermissionArea and
--   Security/PermissionAreaMap: org-audit-configuration ->
--   org-audit-definition). The route stays (PracticeScreen.All).
--
-- ALSO EDITED: 274_menu_master_seed.sql (the row's status).
-- NO AUDIT DATA IS TOUCHED. menu_master only.
-- Re-runnable: yes. Rollback: 549_audit_configuration_menu_hidden_rollback.sql
-- DEPENDS ON: 276, 539. Users sign out and back in to see the menu change.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-audit-configuration')
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-audit-definition' AND status = N'Active')
BEGIN
    PRINT 'ABORT (549): menu_master, org-audit-configuration or an Active org-audit-definition missing. Run 276 first. Nothing was changed.';
    RAISERROR('549_audit_configuration_menu_hidden: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

UPDATE grac_practice.menu_master
   SET status     = N'Inactive',
       updated_by = N'seed-549',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-audit-configuration'
   AND status <> N'Inactive';

PRINT '549: Audit Configuration hidden = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- Sanity report
SELECT '549 Audit Configuration is out of the sidebar' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'org-audit-configuration' AND status = N'Inactive')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '549 Audit Definition is active',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'org-audit-definition' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END;

SELECT ISNULL(p.menu_key, N'(root)') AS Parent, m.menu_key AS MenuKey,
       m.menu_name AS MenuName, m.display_order AS Ord, m.status AS Status
  FROM grac_practice.menu_master m
  LEFT JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
 WHERE p.menu_key = N'nav-assurance'
 ORDER BY m.display_order;

PRINT '549 complete. Publish Web; users sign out and back in to see the menu change.';
GO
SET NOEXEC OFF;
GO
