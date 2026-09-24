-- =====================================================================
-- 332 Event Profiles -- menu, permissions and feature flag
--
-- Seeds the `event-profiles` screen. Follows migration 138 exactly: a
-- feature_flag_master row defaulted off, a menu_master row, the parent
-- link, Admin permissions, then a per-organisation feature_flag row so
-- the screen is actually reachable.
--
-- WHY UNDER nav-organization
-- --------------------------
-- A Profile is a named population expressed in Location, Department and
-- Role -- the organisation masters maintained under Organization. Its
-- asset-side counterpart, `asset-category-assurance`, is parented there
-- too (274 re-parents it from nav-operations), so the two scoping
-- screens sit together and next to the masters they draw on.
--
-- Moving it elsewhere -- Audit Management, Workflow -- is one value in
-- section 3 below plus the matching line in 274. Nothing else depends on
-- the placement.
--
-- 274 MUST BE AMENDED, AND HAS BEEN
-- ---------------------------------
-- 274_menu_master_seed.sql is a MERGE-with-UPDATE snapshot and is
-- authoritative: a menu row it does not carry is reverted to the
-- snapshot on its next run, and a row it does not know is left alone
-- only until someone re-exports. The matching row and parent link have
-- been added to 274 in the same change as this file. If you move the
-- screen, move it in both places.
--
-- WHY default_enabled = 0 AND THEN SECTION 5
-- ------------------------------------------
-- 125 shipped with the flag defaulted off and no per-organisation rows,
-- so every organisation saw "not yet enabled for this organization" and
-- the screen looked broken. A screen must not appear in production
-- merely because a migration ran -- hence the 0 -- and it must not be
-- unreachable for every existing tenant either -- hence section 5.
--
-- Depends on 329 (the tables the screen reads), 052 (nav-organization),
-- 068 / 125 (menu and feature-flag infrastructure).
-- Rollback: 332_event_profile_menu_seed_rollback.sql.
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
    RAISERROR('332: menu / feature-flag tables missing. Run 068 and 125 first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.event_profile','U') IS NULL
BEGIN
    RAISERROR('332: event_profile missing. Run 329 first -- seeding a menu to a screen with no tables gives a page that 500s.', 16, 1);
    SET NOEXEC ON;
END
GO

IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-organization')
BEGIN
    RAISERROR('332: nav-organization parent menu missing. Run 052 first.', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. feature_flag_master
-- =====================================================================
MERGE grac_practice.feature_flag_master AS t
USING (VALUES
    (N'screen.event-profiles',
     N'Event Profiles',
     N'Define attribute-based user populations (Location / Department / Role) and map the event-driven obligations that apply to each (migration 329-332).')
) AS src(feature_code, feature_name, description)
ON t.feature_code = src.feature_code
WHEN MATCHED THEN UPDATE SET
    feature_name = src.feature_name,
    description  = src.description,
    is_active    = 1,
    updated_by   = 'seed-332',
    updated_dt   = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (feature_code, feature_name, description, default_enabled, is_active, entered_by)
VALUES
    (src.feature_code, src.feature_name, src.description, 0, 1, 'seed-332');
GO

-- =====================================================================
-- 2. menu_master
--
--    display_order 317 places it immediately after asset-category-
--    assurance (316), so the two event-scoping screens read together.
-- =====================================================================
MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'event-profiles', N'Event Profiles',
     N'Practice/Index/event-profiles', 317, N'users-gear', N'Organization')
) AS source(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON target.menu_key = source.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name     = source.menu_name,
    menu_url      = source.menu_url,
    display_order = source.display_order,
    icon_class    = source.icon_class,
    module_type   = source.module_type,
    status        = N'Active',
    updated_by    = 'seed-332',
    updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
VALUES
    (source.menu_key, source.menu_name, source.menu_url, source.display_order,
     source.icon_class, source.module_type, N'Active', 'seed-332');
GO

-- =====================================================================
-- 3. Wire it to nav-organization
-- =====================================================================
DECLARE @org_nav_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-organization');
IF @org_nav_id IS NULL THROW 332001, 'nav-organization parent menu missing.', 1;

UPDATE grac_practice.menu_master
   SET parent_menu_id = @org_nav_id,
       updated_by     = 'seed-332',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'event-profiles';
GO

-- =====================================================================
-- 4. Admin role permissions (mirrors the 068 / 125 / 138 pattern)
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
      AND m.menu_key  = N'event-profiles'
) AS source
ON target.role_id = source.role_id AND target.menu_id = source.menu_id
WHEN MATCHED THEN UPDATE SET
    can_view = source.can_view, can_add = source.can_add, can_edit = source.can_edit,
    can_delete = source.can_delete, can_approve = source.can_approve,
    status = N'Active', updated_by = 'seed-332', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by)
VALUES
    (source.role_id, source.menu_id, source.can_view, source.can_add,
     source.can_edit, source.can_delete, source.can_approve,
     N'Active', source.record_status_id, 'seed-332');
GO

-- =====================================================================
-- 5. feature_flag -- enable for every active organization
-- =====================================================================
MERGE grac_practice.feature_flag AS target
USING (
    SELECT o.organization_id, fm.feature_flag_id
    FROM   grac_practice.organization o
    CROSS JOIN grac_practice.feature_flag_master fm
    WHERE  o.status = N'Active'
      AND  fm.feature_code = N'screen.event-profiles'
) AS source
ON  target.organization_id = source.organization_id
AND target.feature_flag_id = source.feature_flag_id
WHEN MATCHED THEN UPDATE SET
    is_enabled = 1,
    notes      = COALESCE(target.notes, N'Enabled by seed-332'),
    updated_by = 'seed-332',
    updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (organization_id, feature_flag_id, is_enabled, notes, entered_by)
VALUES
    (source.organization_id, source.feature_flag_id, 1, N'Enabled by seed-332', 'seed-332');
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'event-profiles menu present' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'event-profiles'
                            AND parent_menu_id IS NOT NULL
                            AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'parent is nav-organization',
       CASE WHEN EXISTS (SELECT 1
                         FROM   grac_practice.menu_master c
                         JOIN   grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
                         WHERE  c.menu_key = N'event-profiles'
                           AND  p.menu_key = N'nav-organization')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'feature flag registered',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.feature_flag_master
                          WHERE feature_code = N'screen.event-profiles' AND is_active = 1)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'Admin permission granted',
       CASE WHEN EXISTS (SELECT 1
                         FROM   grac_practice.organization_role_menu_permission p
                         JOIN   grac_practice.menu_master m ON m.menu_id = p.menu_id
                         JOIN   grac_practice.organization_role r ON r.role_id = p.role_id
                         WHERE  m.menu_key = N'event-profiles'
                           AND  r.role_name = N'Admin')
            THEN 'PASS' ELSE 'FAIL -- no Active role named Admin to grant to' END
UNION ALL SELECT 'profile procedures present',
       CASE WHEN OBJECT_ID('grac_practice.sp_event_profile_list','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_event_profile_save','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL -- run 330 or the screen loads empty' END
UNION ALL SELECT 'resolver is profile-aware',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_obligation_raise')) LIKE '%fn_pm_event_profile_matches%'
            THEN 'PASS' ELSE 'FAIL -- run 331 or profiles configure but never fire' END;

-- Effective enablement per organization. Anything showing 0 renders
-- "not yet enabled" -- which is what section 5 exists to prevent.
SELECT o.organization_id,
       o.organization_name AS OrganizationName,
       grac_practice.fn_pm_feature_enabled(o.organization_id, N'screen.event-profiles') AS EventProfilesEnabled
FROM   grac_practice.organization o
WHERE  o.status = N'Active'
ORDER BY o.organization_id;

-- What the screen has to work with. An organisation with no locations
-- or departments can still build role-only profiles, but the criteria
-- pickers will be empty and that is worth seeing now rather than later.
SELECT o.organization_id,
       o.organization_name AS OrganizationName,
       (SELECT COUNT(1) FROM grac_practice.organization_location   l WHERE l.organization_id = o.organization_id AND l.status = N'Active') AS ActiveLocations,
       (SELECT COUNT(1) FROM grac_practice.organization_department d WHERE d.organization_id = o.organization_id AND d.status = N'Active') AS ActiveDepartments,
       (SELECT COUNT(1) FROM grac_practice.organization_role       r WHERE r.organization_id = o.organization_id AND r.status = N'Active') AS ActiveRoles
FROM   grac_practice.organization o
WHERE  o.status = N'Active'
ORDER BY o.organization_id;

PRINT '332 Event Profiles menu, permissions and feature flag seeded.';
PRINT 'Remember: 274_menu_master_seed.sql carries the matching row -- it is the authoritative snapshot.';
PRINT '333 (optional) converts existing role-scoped mappings into Profiles.';
GO

SET NOEXEC OFF;
GO
