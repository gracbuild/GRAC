-- =====================================================================
-- 052 Sidebar hierarchy via parent_menu_id
--
-- Migration 051 grouped rows by module_type and relied on
-- PracticeMenuService.BuildMenuItems' fallback path (BuildModuleGroups).
-- That path only kicks in when NO row has parent_menu_id set -- as soon
-- as any row has one, the code takes the true parent-child branch
-- (BuildChildren) which is what the UI is designed around and what
-- AdminLTE renders with proper indentation and collapsibility.
--
-- This migration switches to the correct model:
--   1. Insert 5 synthetic PARENT rows (menu_url = NULL, parent_menu_id = NULL):
--        nav-governance      -> "Governance"
--        nav-organization    -> "Organization"
--        nav-operations      -> "Operations"
--        nav-oversight       -> "Oversight"
--        nav-administration  -> "Administration"
--      Dashboard stays parent-less (rendered as a top-level leaf).
--
--   2. Set parent_menu_id on every existing menu row per the user's
--      hierarchy. Assurance / Exceptions / Risks under Oversight are
--      placeholders -- their menu rows will be added by their own
--      migrations when those screens ship.
--
--   3. Grant every organization's Admin role can_view on the new parents
--      so they aren't filtered out if role-based menu filtering is
--      enabled later.
--
--   4. module_type is preserved (still 'Governance' / 'Organization' /
--      etc. from migration 051) -- kept as CLASSIFICATION metadata only.
--      It is no longer the primary grouping key; parent_menu_id is.
--
-- Idempotent: MERGE on menu_key for parents; UPDATE-by-key for children.
-- ASCII-only.
--
-- Rollback: database/052_menu_parent_hierarchy_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Prerequisite guard.
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (052): schema grac_practice missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (052): menu_master missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN
    PRINT 'ABORT (052): organization_role or organization_role_menu_permission missing.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('052_menu_parent_hierarchy: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Insert / update the 5 synthetic parent rows.
--    parent_menu_id stays NULL, menu_url stays NULL (parents are toggle
--    targets in AdminLTE, not screens). display_order values (100/200/
--    300/400/500) sort them below Dashboard (10).
-- =====================================================================
MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'nav-governance',     N'Governance',     100,  N'landmark',            N'Governance'),
    (N'nav-organization',   N'Organization',   200,  N'building',            N'Organization'),
    (N'nav-operations',     N'Operations',     300,  N'gears',               N'Operations'),
    (N'nav-oversight',      N'Oversight',      400,  N'binoculars',          N'Oversight'),
    (N'nav-administration', N'Administration', 500,  N'user-shield',         N'Administration'),
    -- Registers is NOT in the user's target hierarchy but the workbench-*
    -- rows already exist and need a home so they don't become top-level
    -- orphans in the sidebar. Deactivate the parent + its children later
    -- if you want to remove Registers from the sidebar entirely.
    (N'nav-registers',      N'Registers',      600,  N'network-wired',       N'Registers')
) AS source(menu_key, menu_name, display_order, icon_class, module_type)
ON target.menu_key = source.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name      = source.menu_name,
    menu_url       = NULL,
    parent_menu_id = NULL,
    display_order  = source.display_order,
    icon_class     = source.icon_class,
    module_type    = source.module_type,
    status         = N'Active',
    updated_by     = 'seed-052',
    updated_dt     = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (source.menu_key, source.menu_name, NULL, NULL, source.display_order,
     source.icon_class, source.module_type, N'Active', 'seed-052');
GO

-- =====================================================================
-- 2. Wire children to their parents.
--    Look up parent menu_ids by natural key, then UPDATE each child by
--    natural key. Children keep their own display_order (used to sort
--    them within a parent).
-- =====================================================================
DECLARE @gov_id   BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-governance');
DECLARE @org_id   BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-organization');
DECLARE @ops_id   BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-operations');
DECLARE @over_id  BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-oversight');
DECLARE @admin_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-administration');
DECLARE @reg_id   BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-registers');

-- Dashboard: explicit clear (root-level leaf).
UPDATE grac_practice.menu_master
   SET parent_menu_id = NULL,
       updated_by     = 'seed-052',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'dashboard';

-- Governance children.
UPDATE grac_practice.menu_master
   SET parent_menu_id = @gov_id,
       updated_by     = 'seed-052',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key IN (N'repository-subscriptions', N'organization-controls',
                    N'organization-requirements', N'practice-instances');

-- Organization children.
UPDATE grac_practice.menu_master
   SET parent_menu_id = @org_id,
       updated_by     = 'seed-052',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key IN (N'organizations', N'organization-metadata',
                    N'locations', N'departments', N'business-functions',
                    N'teams', N'committees');

-- Operations children.
UPDATE grac_practice.menu_master
   SET parent_menu_id = @ops_id,
       updated_by     = 'seed-052',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key IN (N'dependency-applications', N'dependency-tools',
                    N'dependency-vendors',      N'dependency-assets',
                    N'dependency-processes',    N'resolve');

-- Oversight children (Gap Center, Task Center only for now;
-- Assurance / Exceptions / Risks will land in their own migrations).
UPDATE grac_practice.menu_master
   SET parent_menu_id = @over_id,
       updated_by     = 'seed-052',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key IN (N'gaps', N'tasks');

-- Administration children.
UPDATE grac_practice.menu_master
   SET parent_menu_id = @admin_id,
       updated_by     = 'seed-052',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key IN (N'users', N'roles', N'role-menu-permissions',
                    N'user-role-assignments', N'audit-trace', N'menu-master');

-- Registers children (workbench-* custodian queues).
UPDATE grac_practice.menu_master
   SET parent_menu_id = @reg_id,
       updated_by     = 'seed-052',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key LIKE N'workbench-%';
GO

-- =====================================================================
-- 3. Grant Admin role can_view on all 5 parents.
--    Parents are pure navigation containers -- can_view is enough for
--    the sidebar to render them. If role-based menu filtering is
--    tightened later, this keeps the parents visible for the Admin role.
-- =====================================================================
DECLARE @active_record_status_id INT = (
    SELECT TOP 1 record_status_id
    FROM grac_practice.record_status_master
    WHERE status_code = 'ACTIVE' OR status_name = 'Active'
    ORDER BY record_status_id
);
IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

MERGE grac_practice.organization_role_menu_permission AS target
USING (
    SELECT r.role_id, m.menu_id,
           CAST(1 AS BIT) AS can_view,
           CAST(0 AS BIT) AS can_add,
           CAST(0 AS BIT) AS can_edit,
           CAST(0 AS BIT) AS can_delete,
           CAST(0 AS BIT) AS can_approve,
           @active_record_status_id AS record_status_id
    FROM grac_practice.organization_role r
    CROSS JOIN grac_practice.menu_master m
    WHERE r.role_name = N'Admin'
      AND r.status    = N'Active'
      AND m.menu_key IN (N'nav-governance', N'nav-organization',
                         N'nav-operations', N'nav-oversight',
                         N'nav-administration', N'nav-registers')
) AS source
ON target.role_id = source.role_id AND target.menu_id = source.menu_id
WHEN MATCHED THEN UPDATE SET
    can_view    = source.can_view,
    status      = N'Active',
    updated_by  = 'seed-052',
    updated_dt  = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by)
VALUES
    (source.role_id, source.menu_id, source.can_view, source.can_add,
     source.can_edit, source.can_delete, source.can_approve,
     N'Active', source.record_status_id, 'seed-052');
GO

-- =====================================================================
-- Post-seed sanity report
-- =====================================================================
SELECT 'Parent rows present' AS Check_,
       COUNT(*) AS Parents
FROM grac_practice.menu_master
WHERE menu_key IN (N'nav-governance', N'nav-organization', N'nav-operations',
                   N'nav-oversight',  N'nav-administration', N'nav-registers')
  AND status = N'Active'
  AND parent_menu_id IS NULL
  AND menu_url IS NULL;

SELECT p.menu_name AS Parent, COUNT(c.menu_id) AS Children,
       STRING_AGG(c.menu_key, ', ') WITHIN GROUP (ORDER BY c.display_order) AS ChildKeys
FROM grac_practice.menu_master p
LEFT JOIN grac_practice.menu_master c
       ON c.parent_menu_id = p.menu_id
      AND c.status = N'Active'
WHERE p.menu_key IN (N'nav-governance', N'nav-organization', N'nav-operations',
                     N'nav-oversight',  N'nav-administration', N'nav-registers')
GROUP BY p.menu_id, p.menu_name, p.display_order
ORDER BY p.display_order;

SELECT 'Orphan active rows (no parent, not a parent, not dashboard)' AS Check_,
       COUNT(*) AS Orphans,
       STRING_AGG(menu_key, ', ') WITHIN GROUP (ORDER BY menu_key) AS Keys
FROM grac_practice.menu_master
WHERE status = N'Active'
  AND parent_menu_id IS NULL
  AND menu_key NOT IN (N'dashboard', N'nav-governance', N'nav-organization',
                       N'nav-operations', N'nav-oversight', N'nav-administration',
                       N'nav-registers');

PRINT '052 sidebar parent_menu_id hierarchy seed complete.';
GO

SET NOEXEC OFF;
GO
