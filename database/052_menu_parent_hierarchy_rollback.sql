-- =====================================================================
-- 052 Sidebar hierarchy via parent_menu_id -- ROLLBACK
--
-- Reverses 052_menu_parent_hierarchy.sql:
--   1. Clears parent_menu_id on all children whose parent is one of the
--      five synthetic nav-* rows.
--   2. Removes Admin role grants on the nav-* rows.
--   3. Deletes the nav-* parent rows.
--
-- After this rollback, the sidebar reverts to the module_type-grouped
-- flat layout produced by BuildModuleGroups (as it was after migrations
-- 050 + 051 but before 052).
--
-- Idempotent.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- 1. Clear parent_menu_id on children whose parent is a nav-* row.
IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
    UPDATE c
       SET c.parent_menu_id = NULL,
           c.updated_by     = 'rollback-052',
           c.updated_dt     = SYSUTCDATETIME()
    FROM grac_practice.menu_master c
    JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
    WHERE p.menu_key IN (N'nav-governance', N'nav-organization',
                         N'nav-operations', N'nav-oversight',
                         N'nav-administration', N'nav-registers');
END
GO

-- 2. Remove Admin role grants on the nav-* rows.
IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
    DELETE p
    FROM grac_practice.organization_role_menu_permission p
    JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
    WHERE m.menu_key IN (N'nav-governance', N'nav-organization',
                         N'nav-operations', N'nav-oversight',
                         N'nav-administration', N'nav-registers');
END
GO

-- 3. Delete the nav-* parent rows themselves.
IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.menu_master
    WHERE menu_key IN (N'nav-governance', N'nav-organization',
                       N'nav-operations', N'nav-oversight',
                       N'nav-administration', N'nav-registers');
END
GO

PRINT '052 sidebar parent hierarchy rollback complete.';
GO

SET NOEXEC OFF;
GO
