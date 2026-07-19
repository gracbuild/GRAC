-- =====================================================================
-- 059 Organization group sidebar reshape
--
-- Before this migration:
--   * menu_key='organizations' (menu_name 'Organization Onboarding')
--     lives under the Organization sidebar group.
--   * menu_key='organization-administration' exists but is Inactive
--     (deactivated by migration 051 as a wrapper index row) and has
--     parent_menu_id = NULL, so it does not show up anywhere.
--
-- After this migration:
--   * organization-administration is Active, parented to nav-organization,
--     and appears at the top of the Organization group in the sidebar.
--   * organizations (Organization Onboarding) is Inactive -- it is dropped
--     from the sidebar but its screen key stays valid so any direct URL
--     or bookmark still resolves.
--
-- The rest of the Organization group children (organization-metadata,
-- locations, departments, business-functions, teams, committees) are
-- left where migration 052 placed them.
--
-- ASCII-only. Idempotent -- safe to re-run.
-- Rollback: database/059_organization_admin_under_organization_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    RAISERROR('059: prerequisites missing (schema grac_practice or menu_master).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- ---------------------------------------------------------------------------
-- Step 1 -- Resolve the Organization group's parent menu id.
--           nav-organization is the synthetic parent introduced by 052.
--           Fall back gracefully if it is missing.
-- ---------------------------------------------------------------------------
DECLARE @org_parent_id BIGINT = (
    SELECT menu_id
    FROM grac_practice.menu_master
    WHERE menu_key = N'nav-organization'
);

IF @org_parent_id IS NULL
BEGIN
    RAISERROR('059: nav-organization parent row is missing. Run 052_menu_parent_hierarchy.sql first.', 16, 1);
    ROLLBACK TRAN;
    RETURN;
END

-- ---------------------------------------------------------------------------
-- Step 2 -- Reactivate + reparent organization-administration.
--           Position it as the first entry inside the Organization group
--           (display_order = 195 sits just above the existing 200/205/...
--           children set by 051 / 052).
-- ---------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'organization-administration')
BEGIN
    UPDATE grac_practice.menu_master
       SET menu_name      = N'Organization Administration',
           menu_url       = N'Practice/Index/organization-administration',
           parent_menu_id = @org_parent_id,
           display_order  = 195,
           icon_class     = N'building-user',
           module_type    = N'Organization',
           status         = N'Active',
           updated_by     = 'seed-059',
           updated_dt     = SYSUTCDATETIME()
     WHERE menu_key = N'organization-administration';
END
ELSE
BEGIN
    INSERT INTO grac_practice.menu_master
        (menu_key, menu_name, menu_url, parent_menu_id, display_order,
         icon_class, module_type, status, entered_by)
    VALUES
        (N'organization-administration',
         N'Organization Administration',
         N'Practice/Index/organization-administration',
         @org_parent_id,
         195,
         N'building-user',
         N'Organization',
         N'Active',
         'seed-059');
END

-- ---------------------------------------------------------------------------
-- Step 3 -- Inactivate the Organization Onboarding sidebar entry
--           (menu_key='organizations'). The screen key stays in
--           PracticeScreen.All so /Practice/Index/organizations still
--           resolves for admin bookmarks; only the sidebar row goes away.
-- ---------------------------------------------------------------------------
UPDATE grac_practice.menu_master
   SET status     = N'Inactive',
       updated_by = 'seed-059',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'organizations';

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

SELECT menu_key, menu_name, menu_url, parent_menu_id, display_order, status
FROM grac_practice.menu_master
WHERE menu_key IN (N'organizations', N'organization-administration');

PRINT '059 Organization group reshape complete.';
PRINT '  Organization Administration -> Active under nav-organization.';
PRINT '  Organization Onboarding (organizations) -> Inactive.';
GO

SET NOEXEC OFF;
GO
