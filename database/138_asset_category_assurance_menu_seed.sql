-- =====================================================================
-- 138 Asset Category Assurance -- menu, permissions, feature flag
--     and retirement of the standalone Scoped Checklist Mapping screen
--
-- WHAT MOVED, AND WHY
-- -------------------
-- Scoped Checklist Mapping (125) was one screen doing two unrelated jobs:
-- picking a role and configuring its onboarding / offboarding checklists,
-- and picking an asset category and configuring its commissioning /
-- decommissioning checklists. Neither is a task queue -- both are master
-- data decisions -- so each now sits where that master data is maintained:
--
--   People  -> Role Master (Administration) Add/Edit, as a section on the
--              role form itself. Nothing to seed: the section renders
--              inside an existing screen.
--   Assets  -> this new screen, `asset-category-assurance`, under
--              Operations beside Assets.
--
-- WHY THE ASSET SIDE IS A SCREEN AND NOT A SECTION
-- ------------------------------------------------
-- grac_practice.dependency_asset_category_master has no organization_id --
-- the category list is global master data shared by every organization,
-- and there is no per-organization Add/Edit form to hang a section on.
-- The checklist decision, however, is per (organization, category).
-- Putting it on the global category row would leak one organization's
-- configuration into another's. A separate org-scoped screen is the only
-- placement that keeps the decision tenant-local.
--
-- WHAT IS REMOVED
-- ---------------
-- The `workflow-scope-mapping` menu row and its permissions. Leaving it
-- would give an organization two places to configure the same mapping,
-- writing to the same tables, with no answer to which is authoritative --
-- the same reasoning migration 135 applied to the Event Checklist Inbox.
--
-- NO DATA IS TOUCHED. event_checklist_mapping, event_obligation_
-- applicability, checklist and every scope column stay exactly as they
-- are; the rows configured through the old screen keep working and are
-- edited from the new locations. Only navigation changes.
--
-- Depends on 125 (feature flag + menu infrastructure), 136 (custom
-- checklist procs), 137 (obligation list without a scope value).
-- Rollback: 138_asset_category_assurance_menu_seed_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- =====================================================================
-- Prerequisites
-- =====================================================================
IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN
    RAISERROR('138: menu / feature-flag tables missing. Run 068 and 125 first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-operations')
BEGIN
    RAISERROR('138: nav-operations parent menu missing. Run 052 first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.sp_org_scope_question_list','P') IS NULL
BEGIN
    RAISERROR('138: sp_org_scope_question_list missing. Run 136 first -- the new screen calls it.', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. feature_flag_master
--
--    default_enabled = 0, as every other screen flag. A screen must not
--    appear in production merely because a migration ran. Section 5
--    below turns it on for the organizations that exist today.
-- =====================================================================
MERGE grac_practice.feature_flag_master AS t
USING (VALUES
    (N'screen.asset-category-assurance',
     N'Asset Category Assurance',
     N'Configure the checklists and obligations that apply when an asset of a given category is commissioned or decommissioned (migration 138).')
) AS src(feature_code, feature_name, description)
ON t.feature_code = src.feature_code
WHEN MATCHED THEN UPDATE SET
    feature_name = src.feature_name,
    description  = src.description,
    is_active    = 1,
    updated_by   = 'seed-138',
    updated_dt   = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (feature_code, feature_name, description, default_enabled, is_active, entered_by)
VALUES
    (src.feature_code, src.feature_name, src.description, 0, 1, 'seed-138');
GO

-- =====================================================================
-- 2. menu_master
--
--    display_order 316 places it immediately after Assets (315) and
--    before Processes (320), so the asset pair reads together.
-- =====================================================================
MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'asset-category-assurance', N'Asset Category Assurance',
     N'Practice/Index/asset-category-assurance', 316, N'boxes-stacked', N'Operations')
) AS source(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON target.menu_key = source.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name     = source.menu_name,
    menu_url      = source.menu_url,
    display_order = source.display_order,
    icon_class    = source.icon_class,
    module_type   = source.module_type,
    status        = N'Active',
    updated_by    = 'seed-138',
    updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
VALUES
    (source.menu_key, source.menu_name, source.menu_url, source.display_order,
     source.icon_class, source.module_type, N'Active', 'seed-138');
GO

-- =====================================================================
-- 3. Wire it to nav-operations
-- =====================================================================
DECLARE @ops_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-operations');
IF @ops_id IS NULL THROW 138001, 'nav-operations parent menu missing.', 1;

UPDATE grac_practice.menu_master
   SET parent_menu_id = @ops_id,
       updated_by     = 'seed-138',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'asset-category-assurance';
GO

-- =====================================================================
-- 4. Admin role permissions (mirrors the 068 / 125 pattern)
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
           CAST(1 AS BIT) AS can_add,
           CAST(1 AS BIT) AS can_edit,
           CAST(1 AS BIT) AS can_delete,
           CAST(1 AS BIT) AS can_approve,
           @active_record_status_id AS record_status_id
    FROM grac_practice.organization_role r
    CROSS JOIN grac_practice.menu_master m
    WHERE r.role_name = N'Admin'
      AND r.status    = N'Active'
      AND m.menu_key  = N'asset-category-assurance'
) AS source
ON target.role_id = source.role_id AND target.menu_id = source.menu_id
WHEN MATCHED THEN UPDATE SET
    can_view = source.can_view, can_add = source.can_add, can_edit = source.can_edit,
    can_delete = source.can_delete, can_approve = source.can_approve,
    status = N'Active', updated_by = 'seed-138', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by)
VALUES
    (source.role_id, source.menu_id, source.can_view, source.can_add,
     source.can_edit, source.can_delete, source.can_approve,
     N'Active', source.record_status_id, 'seed-138');
GO

-- =====================================================================
-- 5. feature_flag -- enable the screen for every active organization.
--
--    fn_pm_feature_enabled looks for a per-organization feature_flag row
--    first and only falls back to feature_flag_master.default_enabled
--    (0, above) when none exists. Without this block the probe returns 0
--    and the screen renders "not yet enabled for this organization" --
--    the exact defect 125 shipped with.
-- =====================================================================
MERGE grac_practice.feature_flag AS target
USING (
    SELECT o.organization_id, fm.feature_flag_id
    FROM   grac_practice.organization o
    CROSS JOIN grac_practice.feature_flag_master fm
    WHERE  o.status = N'Active'
      AND  fm.feature_code = N'screen.asset-category-assurance'
) AS source
ON  target.organization_id = source.organization_id
AND target.feature_flag_id = source.feature_flag_id
WHEN MATCHED THEN UPDATE SET
    is_enabled = 1,
    notes      = COALESCE(target.notes, N'Enabled by seed-138'),
    updated_by = 'seed-138',
    updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (organization_id, feature_flag_id, is_enabled, notes, entered_by)
VALUES
    (source.organization_id, source.feature_flag_id, 1, N'Enabled by seed-138', 'seed-138');
GO

-- =====================================================================
-- 6. Retire the standalone Scoped Checklist Mapping screen
--
--    Permissions first -- they reference menu_id.
-- =====================================================================
DELETE p
FROM   grac_practice.organization_role_menu_permission p
JOIN   grac_practice.menu_master m ON m.menu_id = p.menu_id
WHERE  m.menu_key = N'workflow-scope-mapping';
GO

DELETE FROM grac_practice.menu_master
 WHERE menu_key = N'workflow-scope-mapping';
GO

-- The flag row is kept, not deleted. Deleting it would silently discard
-- whichever organizations had deliberately switched the screen OFF, and
-- that record is worth more than a tidy table. Marked inactive so it
-- stops appearing in flag administration.
UPDATE grac_practice.feature_flag_master
   SET is_active   = 0,
       description = N'RETIRED by migration 138. Role checklists are configured in Role Master Add/Edit; asset-category checklists in the Asset Category Assurance screen.',
       updated_by  = 'seed-138',
       updated_dt  = SYSUTCDATETIME()
 WHERE feature_code = N'screen.workflow-scope-mapping';
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'asset-category-assurance menu present' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'asset-category-assurance'
                            AND parent_menu_id IS NOT NULL
                            AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'parent is nav-operations',
       CASE WHEN EXISTS (SELECT 1
                         FROM   grac_practice.menu_master c
                         JOIN   grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
                         WHERE  c.menu_key = N'asset-category-assurance'
                           AND  p.menu_key = N'nav-operations')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'feature flag registered',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.feature_flag_master
                          WHERE feature_code = N'screen.asset-category-assurance'
                            AND is_active = 1)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'Admin permission granted',
       CASE WHEN EXISTS (SELECT 1
                         FROM   grac_practice.organization_role_menu_permission p
                         JOIN   grac_practice.menu_master m ON m.menu_id = p.menu_id
                         JOIN   grac_practice.organization_role r ON r.role_id = p.role_id
                         WHERE  m.menu_key = N'asset-category-assurance'
                           AND  r.role_name = N'Admin')
            THEN 'PASS' ELSE 'FAIL -- no Active role named Admin to grant to' END
UNION ALL SELECT 'scope-mapping menu removed',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.menu_master
                              WHERE menu_key = N'workflow-scope-mapping')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'role-master section procs intact',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_scope_question_list','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_event_obligation_mapping_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL -- Role Master section would be blank' END
UNION ALL SELECT 'configured mappings preserved',
       CASE WHEN OBJECT_ID('grac_practice.event_checklist_mapping','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;

-- Effective enablement per organization. Anything showing 0 will render
-- "not yet enabled" -- that is what section 5 exists to prevent.
SELECT o.organization_id,
       o.organization_name AS OrganizationName,
       grac_practice.fn_pm_feature_enabled(o.organization_id, N'screen.asset-category-assurance') AS AssetCategoryAssuranceEnabled
FROM   grac_practice.organization o
WHERE  o.status = N'Active'
ORDER BY o.organization_id;

-- How many asset categories the new screen has to work with. Zero is not
-- an error, but the category dropdown will be empty and nothing can be
-- configured until dependency_asset_category_master is populated.
SELECT COUNT(*) AS ActiveAssetCategories
FROM   grac_practice.dependency_asset_category_master
WHERE  is_active = 1;

PRINT '138 Asset Category Assurance seeded; Scoped Checklist Mapping retired.';
PRINT 'People-side mapping now lives in Role Master Add/Edit; asset-side in the new screen.';
PRINT 'No mapping data was moved or deleted.';
GO
