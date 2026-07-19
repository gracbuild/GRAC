-- =====================================================================
-- 056 Governance menu: separate Repository Subscriptions from Source Statements
--
-- Before this migration:
--   * menu_key 'repository-subscriptions'  -> Practice/Index/repository-subscriptions
--                                             (RS1 admin/subscription grid -- WRONG default)
--   * menu_key 'organization-controls'     -> Practice/Index/organization-controls
--                                             (RS2 release summary -- but labelled 'Source Statements')
--
-- After this migration:
--   * NEW: menu_key 'source-statements'    -> Practice/Index/source-statements
--          (RS3 statement grid -- auto-drills into first release)
--          This is the RENAMED row that was formerly menu_key='organization-controls'.
--   * NEW: menu_key 'organization-controls' -> Practice/Index/organization-controls
--          (RS2 release summary -- labelled 'Repository Subscriptions')
--          This is the RENAMED row that was formerly menu_key='repository-subscriptions'.
--   * RS1 admin/subscription grid is HIDDEN from sidebar (row deactivated).
--     Direct URL Practice/Index/repository-subscriptions still resolves for
--     any admin / bookmark that needs the RS1 grid.
--
-- menu_id is preserved on both rows (we UPDATE by natural key, not delete +
-- insert), so parent_menu_id linkage and permission grants stay intact.
--
-- Rename order matters because of the UNIQUE constraint on menu_key:
--   Step 1 renames the existing 'organization-controls' row to 'source-statements'
--          (frees the 'organization-controls' key).
--   Step 2 renames the existing 'repository-subscriptions' row to 'organization-controls'.
--   Step 3 inserts a new stub row keyed 'repository-subscriptions' whose sole
--          purpose is to keep the RS1 admin screen reachable via its historical
--          URL, but marked Inactive so it stays out of the sidebar.
--
-- ASCII-only. Idempotent (safe to re-run -- checks current state first).
-- Rollback: database/056_menu_repository_vs_source_statements_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    RAISERROR('056: prerequisites missing (schema grac_practice or menu_master).', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- Guard: if 056 already applied, exit early.
-- =====================================================================
IF EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'source-statements')
BEGIN
    PRINT 'SKIP (056): source-statements row already exists -- migration previously applied.';
    RETURN;
END
GO

-- =====================================================================
-- Step 1: Rename the existing 'organization-controls' row -> 'source-statements'.
--         Keeps menu_id / parent_menu_id / permission grants intact.
-- =====================================================================
UPDATE grac_practice.menu_master
   SET menu_key      = N'source-statements',
       menu_name     = N'Source Statements',
       menu_url      = N'Practice/Index/source-statements',
       display_order = 105,
       icon_class    = N'file-lines',
       updated_by    = 'seed-056',
       updated_dt    = SYSUTCDATETIME()
 WHERE menu_key = N'organization-controls';
GO

-- =====================================================================
-- Step 2: Rename the existing 'repository-subscriptions' row -> 'organization-controls'.
--         This is now the "Repository Subscriptions" sidebar entry that
--         opens the release summary (RS2) via the shared organization-controls
--         screen. Icon left as bookmark to match the menu label.
-- =====================================================================
UPDATE grac_practice.menu_master
   SET menu_key      = N'organization-controls',
       menu_name     = N'Repository Subscriptions',
       menu_url      = N'Practice/Index/organization-controls',
       display_order = 100,
       icon_class    = N'bookmark',
       updated_by    = 'seed-056',
       updated_dt    = SYSUTCDATETIME()
 WHERE menu_key = N'repository-subscriptions';
GO

-- =====================================================================
-- Step 3: Reserve the historical 'repository-subscriptions' menu_key so any
--         direct URL / bookmark to /Practice/Index/repository-subscriptions
--         still points to a well-formed (but sidebar-hidden) menu row.
--         Inactive status -> BuildModuleGroups / _PracticeMenuTree drop it.
--         Screen 'repository-subscriptions' remains in PracticeScreen.All
--         so the URL itself still renders (RS1 admin grid).
-- =====================================================================
IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'repository-subscriptions')
BEGIN
    INSERT INTO grac_practice.menu_master
        (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES
        (N'repository-subscriptions',
         N'Repository Subscriptions (Admin)',
         N'Practice/Index/repository-subscriptions',
         999,
         N'bookmark',
         N'Governance',
         N'Inactive',
         'seed-056');
END
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT menu_key, menu_name, menu_url, display_order, status
FROM grac_practice.menu_master
WHERE menu_key IN (N'organization-controls', N'source-statements', N'repository-subscriptions')
ORDER BY display_order;

PRINT '056 governance menu split complete: Repository Subscriptions -> RS2, Source Statements -> RS3.';
GO

SET NOEXEC OFF;
GO
