-- =====================================================================
-- 060 Trim the Organization sidebar group + surface Organization Dependencies
--
-- After migration 059 the Organization group looks like:
--   Organization Administration   (Active, first entry)
--   Organization Metadata
--   Location Management
--   Department Management
--   Business Function Management
--   Team Management
--   Committee Management
--
-- The child rows (metadata / locations / departments / business-functions /
-- teams / committees) are all reachable as TABS inside the Organization
-- Administration workspace, so keeping them in the sidebar too is duplicated
-- clutter. This migration:
--
--   1. Deactivates every non-admin, non-dependency child of nav-organization
--      so the sidebar only shows Organization Administration + Organization
--      Dependencies. Their screen keys stay valid in PracticeScreen.All so
--      any direct URL / bookmark still resolves.
--
--   2. Activates + reparents organization-dependencies to nav-organization
--      (051 had deactivated it as a wrapper index row; the Organization
--      Dependencies workspace is exactly the parent tab the user wants).
--
-- ASCII-only. Idempotent -- safe to re-run.
-- Rollback: database/060_organization_menu_trim_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    RAISERROR('060: prerequisites missing (schema grac_practice or menu_master).', 16, 1);
    SET NOEXEC ON;
END
GO

DECLARE @org_parent_id BIGINT = (
    SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-organization'
);

IF @org_parent_id IS NULL
BEGIN
    RAISERROR('060: nav-organization parent row is missing. Run 052_menu_parent_hierarchy.sql first.', 16, 1);
    RETURN;
END

BEGIN TRAN;

-- ---------------------------------------------------------------------------
-- Step 1 -- Inactivate the six sidebar entries that are already reachable
--           as Administration tabs inside the Organization Administration
--           workspace. Screen keys are preserved so the URLs still resolve
--           for anyone with a bookmark.
-- ---------------------------------------------------------------------------
UPDATE grac_practice.menu_master
   SET status     = N'Inactive',
       updated_by = 'seed-060',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (
        N'organization-metadata',
        N'locations',
        N'departments',
        N'business-functions',
        N'teams',
        N'committees'
   );

-- ---------------------------------------------------------------------------
-- Step 2 -- Activate organization-dependencies and place it inside the
--           Organization group, right after Organization Administration
--           (display_order 197 sits between admin's 195 and the old 200
--           slot vacated by the inactivated organizations row).
-- ---------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'organization-dependencies')
BEGIN
    UPDATE grac_practice.menu_master
       SET menu_name      = N'Organization Dependencies',
           menu_url       = N'Practice/Index/organization-dependencies',
           parent_menu_id = @org_parent_id,
           display_order  = 197,
           icon_class     = N'diagram-project',
           module_type    = N'Organization',
           status         = N'Active',
           updated_by     = 'seed-060',
           updated_dt     = SYSUTCDATETIME()
     WHERE menu_key = N'organization-dependencies';
END
ELSE
BEGIN
    INSERT INTO grac_practice.menu_master
        (menu_key, menu_name, menu_url, parent_menu_id, display_order,
         icon_class, module_type, status, entered_by)
    VALUES
        (N'organization-dependencies',
         N'Organization Dependencies',
         N'Practice/Index/organization-dependencies',
         @org_parent_id,
         197,
         N'diagram-project',
         N'Organization',
         N'Active',
         'seed-060');
END

COMMIT TRAN;

-- ---------------------------------------------------------------------------
-- Sanity report
-- ---------------------------------------------------------------------------
SELECT p.menu_key AS ParentKey,
       p.menu_name AS Parent,
       c.menu_key AS ChildKey,
       c.menu_name AS ChildName,
       c.menu_url,
       c.display_order,
       c.status
FROM grac_practice.menu_master p
LEFT JOIN grac_practice.menu_master c ON c.parent_menu_id = p.menu_id
WHERE p.menu_key = N'nav-organization'
ORDER BY c.status DESC, c.display_order;

PRINT '060 Organization sidebar trim complete.';
PRINT '  Active under nav-organization: organization-administration + organization-dependencies.';
PRINT '  Inactive (moved to Admin tabs): organization-metadata, locations, departments,';
PRINT '                                  business-functions, teams, committees.';
GO

SET NOEXEC OFF;
GO
