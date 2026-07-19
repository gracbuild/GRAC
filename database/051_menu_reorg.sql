-- =====================================================================
-- 051 Sidebar navigation reorganisation
--
-- Reorganises grac_practice.menu_master into the enterprise-GRC style
-- hierarchy the user requested:
--
--   Dashboard      -> dashboard
--   Governance     -> repository-subscriptions, organization-controls
--                    (renamed to "Source Statements"),
--                    organization-requirements (renamed to "Practices"),
--                    practice-instances
--   Organization   -> organizations, organization-metadata, locations,
--                    departments, business-functions, teams, committees
--   Operations     -> dependency-{applications,tools,vendors,assets,processes},
--                    resolve
--   Oversight      -> gaps, tasks   (already migrated by 050 -- re-asserted
--                    here so this migration is self-contained)
--   Administration -> users, roles, role-menu-permissions,
--                    user-role-assignments, audit-trace, menu-master
--   Registers      -> workbench-*   (unchanged group; kept out of the
--                    Operations group to avoid duplicate menu names --
--                    Applications / Tools / Vendors / Assets / Processes
--                    already live in Operations via dependency-*)
--
-- Wrapper index rows deactivated (they were redirect landing pages for
-- the old flat sidebar and are redundant now that each screen has a
-- direct nested entry):
--     organization-setup, organization-administration, organization-dependencies
--
-- Design constraints honoured:
--   * No new menu rows -- reuses every existing menu_key.
--   * No new screens -- only module_type, display_order, menu_name updated.
--   * BuildModuleGroups in PracticeMenuService.cs groups by module_type
--     and orders groups by the minimum display_order within each group,
--     so display_order ranges (100s / 200s / 300s / 400s / 500s / 600s)
--     drive the group order.
--   * Idempotent -- MERGE on menu_key; safe to re-run.
--
-- Rollback: database/051_menu_reorg_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Prerequisite guard.
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (051): schema grac_practice missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (051): menu_master missing. Run deployment/01_Create_Schema_Tables.sql first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('051_menu_reorg: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Move / relabel / reorder every menu_key in scope.
--    Source list is authoritative -- any row whose menu_key appears here
--    gets its module_type, display_order, and (where explicitly changed)
--    menu_name overwritten.
-- =====================================================================
MERGE grac_practice.menu_master AS target
USING (VALUES
    -- Dashboard
    (N'dashboard',                    N'Dashboard',                        10,  N'Dashboard'),

    -- Governance
    (N'repository-subscriptions',     N'Repository Subscriptions',        100,  N'Governance'),
    (N'organization-controls',        N'Source Statements',                105,  N'Governance'),
    (N'organization-requirements',    N'Practices',                        110,  N'Governance'),
    (N'practice-instances',           N'Practice Instances',               115,  N'Governance'),

    -- Organization
    (N'organizations',                N'Organization Onboarding',          200,  N'Organization'),
    (N'organization-metadata',        N'Organization Metadata',            205,  N'Organization'),
    (N'locations',                    N'Location Management',              210,  N'Organization'),
    (N'departments',                  N'Department Management',            212,  N'Organization'),
    (N'business-functions',           N'Business Function Management',     214,  N'Organization'),
    (N'teams',                        N'Team Management',                  216,  N'Organization'),
    (N'committees',                   N'Committee Management',             218,  N'Organization'),

    -- Operations
    (N'dependency-applications',      N'Applications',                     300,  N'Operations'),
    (N'dependency-tools',             N'Tools',                            305,  N'Operations'),
    (N'dependency-vendors',           N'Vendors',                          310,  N'Operations'),
    (N'dependency-assets',            N'Assets',                           315,  N'Operations'),
    (N'dependency-processes',         N'Processes',                        320,  N'Operations'),
    (N'resolve',                      N'Resolve',                          330,  N'Operations'),

    -- Oversight (also asserted by migration 050 -- repeated for self-containment)
    (N'gaps',                         N'Gap Center',                       400,  N'Oversight'),
    (N'tasks',                        N'Task Center',                      405,  N'Oversight'),

    -- Administration
    (N'users',                        N'User Management',                  500,  N'Administration'),
    (N'roles',                        N'Role Master',                      505,  N'Administration'),
    (N'role-menu-permissions',        N'Role Menu Permission',             510,  N'Administration'),
    (N'user-role-assignments',        N'User Role Assignment',             515,  N'Administration'),
    (N'audit-trace',                  N'Audit Traceability',               520,  N'Administration'),
    (N'menu-master',                  N'Menu Master',                      525,  N'Administration')
) AS source(menu_key, menu_name, display_order, module_type)
ON target.menu_key = source.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name     = source.menu_name,
    display_order = source.display_order,
    module_type   = source.module_type,
    status        = N'Active',
    updated_by    = 'seed-051',
    updated_dt    = SYSUTCDATETIME();
-- No WHEN NOT MATCHED clause -- this migration only reorganises existing
-- rows. Missing menu keys mean their upstream migration hasn't run yet
-- and we should surface that (see the sanity check at the bottom).
GO

-- =====================================================================
-- 2. Deactivate wrapper index rows.
--    These pointed at Practice/Index/{key} landing pages that dispatched
--    into the setup wizards. With the new nested sidebar every wizard
--    screen has its own reachable entry, so the wrappers only add noise.
--    Screens themselves stay accessible via direct URL for anyone with a
--    bookmark -- only the sidebar entries go away.
-- =====================================================================
UPDATE grac_practice.menu_master
   SET status     = N'Inactive',
       updated_by = 'seed-051',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'organization-setup', N'organization-administration', N'organization-dependencies')
   AND status    = N'Active';
GO

-- =====================================================================
-- Post-seed sanity report
-- =====================================================================
;WITH expected(menu_key, module_type) AS (
    SELECT * FROM (VALUES
        (N'dashboard',                    N'Dashboard'),
        (N'repository-subscriptions',     N'Governance'),
        (N'organization-controls',        N'Governance'),
        (N'organization-requirements',    N'Governance'),
        (N'practice-instances',           N'Governance'),
        (N'organizations',                N'Organization'),
        (N'organization-metadata',        N'Organization'),
        (N'locations',                    N'Organization'),
        (N'departments',                  N'Organization'),
        (N'business-functions',           N'Organization'),
        (N'teams',                        N'Organization'),
        (N'committees',                   N'Organization'),
        (N'dependency-applications',      N'Operations'),
        (N'dependency-tools',             N'Operations'),
        (N'dependency-vendors',           N'Operations'),
        (N'dependency-assets',            N'Operations'),
        (N'dependency-processes',         N'Operations'),
        (N'resolve',                      N'Operations'),
        (N'gaps',                         N'Oversight'),
        (N'tasks',                        N'Oversight'),
        (N'users',                        N'Administration'),
        (N'roles',                        N'Administration'),
        (N'role-menu-permissions',        N'Administration'),
        (N'audit-trace',                  N'Administration')
    ) v(menu_key, module_type)
)
SELECT e.menu_key,
       e.module_type      AS ExpectedGroup,
       m.module_type      AS ActualGroup,
       CASE WHEN m.menu_id IS NULL THEN 'MISSING_ROW'
            WHEN m.status <> N'Active' THEN 'INACTIVE'
            WHEN m.module_type = e.module_type THEN 'OK'
            ELSE 'WRONG_GROUP' END AS Result
FROM expected e
LEFT JOIN grac_practice.menu_master m ON m.menu_key = e.menu_key
ORDER BY e.module_type, e.menu_key;

SELECT 'Wrappers inactivated' AS Check_,
       COUNT(*)               AS Inactive
FROM grac_practice.menu_master
WHERE menu_key IN (N'organization-setup', N'organization-administration', N'organization-dependencies')
  AND status    = N'Inactive';

PRINT '051 sidebar navigation reorganisation complete.';
GO

SET NOEXEC OFF;
GO
