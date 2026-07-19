-- =====================================================================
-- 051 Sidebar navigation reorganisation -- ROLLBACK
--
-- Restores every menu_master row touched by 051 to its pre-051 values.
-- Reference: baseline seed in database/022_practice_login_menu_permissions.sql
-- (and 027 for role/permission menus which had the newer names).
--
-- After this rollback:
--   * gaps + tasks REMAIN under module_type = 'Oversight' (put there by
--     migration 050, which is a separate concern). If you also need to
--     undo 050, run 050_gap_center_menu_seed_rollback.sql afterwards.
--   * The wrapper index rows (organization-setup, organization-administration,
--     organization-dependencies) are reactivated.
--
-- Idempotent.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- 1. Restore module_type + display_order + original menu_name.
MERGE grac_practice.menu_master AS target
USING (VALUES
    -- Dashboard
    (N'dashboard',                    N'Dashboard',                                 5,   N'Dashboard'),

    -- Governance items -> back to their original groups + names
    (N'repository-subscriptions',     N'Repository Subscriptions',                 50,   N'Organization Setup'),
    (N'organization-controls',        N'Organization Controls',                   200,   N'Practice Management'),
    (N'organization-requirements',    N'Organization Requirements / Practices',   210,   N'Practice Management'),
    (N'practice-instances',           N'Practice Instances',                      220,   N'Practice Management'),

    -- Organization items -> back to Organization Setup / Organization Administration
    (N'organizations',                N'Organization Onboarding',                  30,   N'Organization Setup'),
    (N'organization-metadata',        N'Organization Metadata',                    40,   N'Organization Setup'),
    (N'locations',                    N'Location Management',                      60,   N'Organization Administration'),
    (N'departments',                  N'Department Management',                    70,   N'Organization Administration'),
    (N'business-functions',           N'Business Function Management',             80,   N'Organization Administration'),
    (N'teams',                        N'Team Management',                          90,   N'Organization Administration'),
    (N'committees',                   N'Committee Management',                    100,   N'Organization Administration'),

    -- Operations items -> back to Organization Dependencies
    (N'dependency-applications',      N'Applications',                            150,   N'Organization Dependencies'),
    (N'dependency-tools',             N'Tools',                                   160,   N'Organization Dependencies'),
    (N'dependency-vendors',           N'Vendors',                                 170,   N'Organization Dependencies'),
    (N'dependency-assets',            N'Assets',                                  180,   N'Organization Dependencies'),
    (N'dependency-processes',         N'Processes',                               190,   N'Organization Dependencies'),
    (N'resolve',                      N'Resolve',                                 230,   N'Practice Management'),

    -- Administration items -> back to Organization Administration / Organization Access Administration / Practice Management
    (N'users',                        N'User Management',                         130,   N'Organization Administration'),
    (N'roles',                        N'Organization Role Management',            111,   N'Organization Access Administration'),
    (N'role-menu-permissions',        N'Organization Role Menu Permission',       112,   N'Organization Access Administration'),
    (N'user-role-assignments',        N'Organization User Role Assignment',       113,   N'Organization Access Administration'),
    (N'audit-trace',                  N'Audit Traceability',                      900,   N'Practice Management'),
    (N'menu-master',                  N'Menu Master',                               6,   N'System')

    -- gaps + tasks intentionally NOT touched here -- see header note.
) AS source(menu_key, menu_name, display_order, module_type)
ON target.menu_key = source.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name     = source.menu_name,
    display_order = source.display_order,
    module_type   = source.module_type,
    updated_by    = 'rollback-051',
    updated_dt    = SYSUTCDATETIME();
GO

-- 2. Reactivate wrapper index rows.
UPDATE grac_practice.menu_master
   SET status     = N'Active',
       updated_by = 'rollback-051',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'organization-setup', N'organization-administration', N'organization-dependencies');
GO

PRINT '051 sidebar navigation rollback complete.';
GO

SET NOEXEC OFF;
GO
