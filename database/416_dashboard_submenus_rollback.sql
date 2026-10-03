-- =====================================================================
-- 416 rollback -- parents open their dashboards again (413 / 414 state),
-- the three Dashboard rows and their grants are removed, and
-- risk-centre-dashboard returns to the end of its siblings (286).
-- Deploy with the Web build from before 416 (it does not check the
-- "<dashboard>:VIEW" grant). Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

UPDATE m
   SET menu_url = x.url, updated_by = N'rollback-416', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master m
  JOIN (VALUES (N'nav-governance', N'Practice/Index/governance-dashboard'),
               (N'nav-oversight',  N'Practice/Index/issues-actions-dashboard'),
               (N'nav-assurance',  N'Practice/Index/audit-assurance-dashboard'),
               (N'risk-centre',    N'Practice/Index/risk-centre-dashboard')) x(menu_key, url)
    ON x.menu_key = m.menu_key
 WHERE ISNULL(m.menu_url, N'') <> x.url;
PRINT CONCAT('416 rollback: parent urls restored: ', @@ROWCOUNT);

DELETE p
  FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key IN (N'governance-dashboard', N'issues-actions-dashboard', N'audit-assurance-dashboard');
PRINT CONCAT('416 rollback: dashboard grants removed: ', @@ROWCOUNT);

DELETE FROM grac_practice.menu_master
 WHERE menu_key IN (N'governance-dashboard', N'issues-actions-dashboard', N'audit-assurance-dashboard');
PRINT CONCAT('416 rollback: dashboard rows removed: ', @@ROWCOUNT);

UPDATE grac_practice.menu_master
   SET display_order = 286, updated_by = N'rollback-416', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'risk-centre-dashboard' AND display_order <> 286;
GO

SELECT '416 rollback' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.menu_master
                              WHERE menu_key IN (N'governance-dashboard', N'issues-actions-dashboard', N'audit-assurance-dashboard'))
             AND (SELECT menu_url FROM grac_practice.menu_master WHERE menu_key = N'nav-governance') = N'Practice/Index/governance-dashboard'
            THEN 'PASS' ELSE 'FAIL' END AS Result;
PRINT '416 rolled back.';
GO
