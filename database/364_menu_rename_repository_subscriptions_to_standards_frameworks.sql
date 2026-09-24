-- =====================================================================
-- 364_menu_rename_repository_subscriptions_to_standards_frameworks.sql
--
-- Renames the sidebar menu label "Repository Subscriptions" to
-- "Standards & Frameworks". DISPLAY LABEL ONLY.
--
--   * Updates grac_practice.menu_master.menu_name only.
--       'Repository Subscriptions'         -> 'Standards & Frameworks'
--       'Repository Subscriptions (Admin)' -> 'Standards & Frameworks (Admin)'
--     (both the visible Governance item 'organization-controls' and the
--      inactive Organization Setup admin row 'repository-subscriptions').
--   * Does NOT change menu_key, menu_url, display_order, module_type,
--     status, permissions or parent -- routes and grants stay intact.
--
-- Idempotent and re-runnable. ASCII-only.
-- Rollback: 364_menu_rename_repository_subscriptions_to_standards_frameworks_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (364): grac_practice.menu_master is missing.';
    RETURN;
END
GO

UPDATE grac_practice.menu_master
   SET menu_name  = N'Standards & Frameworks',
       updated_by = 'seed-364',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_name = N'Repository Subscriptions';
PRINT CONCAT('364: rows renamed to "Standards & Frameworks": ', @@ROWCOUNT);
GO

UPDATE grac_practice.menu_master
   SET menu_name  = N'Standards & Frameworks (Admin)',
       updated_by = 'seed-364',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_name = N'Repository Subscriptions (Admin)';
PRINT CONCAT('364: admin rows renamed to "Standards & Frameworks (Admin)": ', @@ROWCOUNT);
GO

-- Verification
IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master
               WHERE menu_name IN (N'Repository Subscriptions', N'Repository Subscriptions (Admin)'))
    PRINT '364: PASS -- no "Repository Subscriptions" menu labels remain.';
ELSE
    PRINT '364: WARNING -- some "Repository Subscriptions" labels still present.';
GO
