-- =====================================================================
-- 050 Gap Center menu + feature flag  (Task Center -> Gap Center split)
--
-- Charter alignment:
--   * Sec 7 -- every new screen defaults OFF via feature_flag_master; this
--     migration registers 'screen.gaps' and then explicitly enables it
--     per-org so the module renders immediately for QA.
--   * Sec 12.1.3 -- Task Center remains the execution surface. Gap-source
--     identification moves into its own module (Gap Center) so future
--     assurance / risk / audit / exception gap sources can grow without
--     bloating Task Center.
--
-- Sidebar impact:
--   * NEW menu row 'gaps' under module_type = 'Oversight'
--   * EXISTING menu row 'tasks' moved from 'Practice Management' to
--     'Oversight' so the two sit together under the new group.
--   * All other menus intentionally left untouched -- a broader menu
--     reorganisation (Governance / Administration / Reports) is a
--     separate follow-up so this migration is small and reversible.
--
-- Idempotent: MERGEs on natural keys; safe to re-run.
--
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default, and multi-byte UTF-8 characters can corrupt string literals
-- and confuse the parser (observed as Msg 2812 during initial roll-out).
--
-- Rollback: database/050_gap_center_menu_seed_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Prerequisite guard -- same pattern as 041 / 042.
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (050): schema grac_practice missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (050): menu_master missing. Run deployment/01_Create_Schema_Tables.sql first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN
    PRINT 'ABORT (050): organization_role or organization_role_menu_permission missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN
    PRINT 'ABORT (050): feature_flag_master or feature_flag missing. Run 041_feature_flag.sql first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('050_gap_center_menu_seed: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. feature_flag_master -- register 'screen.gaps' (OFF by default).
--    Uses the plain "MERGE ... USING (VALUES ...) AS src(...)" form
--    (same shape as migration 042) to avoid the ";WITH ... MERGE"
--    pattern that Msg 2812 in some client/codepage combinations.
-- =====================================================================
MERGE grac_practice.feature_flag_master AS t
USING (VALUES
    (N'screen.gaps', N'Gap Center', N'Gap-source module split from Task Center (see Sec 12.1.3 follow-up).')
) AS src(feature_code, feature_name, description)
ON t.feature_code = src.feature_code
WHEN MATCHED THEN UPDATE SET
    feature_name = src.feature_name,
    description  = src.description,
    updated_by   = 'seed-050',
    updated_dt   = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (feature_code, feature_name, description, category, default_enabled, entered_by)
    VALUES (src.feature_code, src.feature_name, src.description, N'Screen', 0, 'seed-050');
GO

-- =====================================================================
-- 2. menu_master -- insert 'gaps', move 'tasks' into Oversight.
--    display_order: gaps 224 (just above tasks 228), both sit inside the
--    'Oversight' module so BuildModuleGroups renders them together.
-- =====================================================================
MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'gaps',  N'Gap Center',   N'Practice/Index/gaps',  224, N'triangle-exclamation', N'Oversight'),
    (N'tasks', N'Task Center',  N'Practice/Index/tasks', 228, N'list-check',           N'Oversight')
) AS source(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON target.menu_key = source.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name    = source.menu_name,
    menu_url     = source.menu_url,
    display_order= source.display_order,
    icon_class   = source.icon_class,
    module_type  = source.module_type,
    status       = N'Active',
    updated_by   = 'seed-050',
    updated_dt   = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
VALUES
    (source.menu_key, source.menu_name, source.menu_url, source.display_order,
     source.icon_class, source.module_type, N'Active', 'seed-050');
GO

-- =====================================================================
-- 3. organization_role_menu_permission -- grant Admin roles full rights
--    on the new 'gaps' menu (mirrors the 042 pattern for 'tasks').
-- =====================================================================
DECLARE @menu_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'gaps');
DECLARE @active_record_status_id INT = (
    SELECT TOP 1 record_status_id
    FROM grac_practice.record_status_master
    WHERE status_code = 'ACTIVE' OR status_name = 'Active'
    ORDER BY record_status_id
);
IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

IF @menu_id IS NOT NULL
BEGIN
    MERGE grac_practice.organization_role_menu_permission AS target
    USING (
        SELECT r.role_id,
               @menu_id                    AS menu_id,
               CAST(1 AS BIT)              AS can_view,
               CAST(1 AS BIT)              AS can_add,
               CAST(1 AS BIT)              AS can_edit,
               CAST(1 AS BIT)              AS can_delete,
               CAST(1 AS BIT)              AS can_approve,
               @active_record_status_id    AS record_status_id
        FROM grac_practice.organization_role r
        WHERE r.role_name = N'Admin'
          AND r.status = N'Active'
    ) AS source
    ON target.role_id = source.role_id AND target.menu_id = source.menu_id
    WHEN MATCHED THEN UPDATE SET
        can_view    = source.can_view,
        can_add     = source.can_add,
        can_edit    = source.can_edit,
        can_delete  = source.can_delete,
        can_approve = source.can_approve,
        status      = N'Active',
        updated_by  = 'seed-050',
        updated_dt  = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
         status, record_status_id, entered_by)
    VALUES
        (source.role_id, source.menu_id, source.can_view, source.can_add,
         source.can_edit, source.can_delete, source.can_approve,
         N'Active', source.record_status_id, 'seed-050');
END
GO

-- =====================================================================
-- 4. feature_flag -- enable 'screen.gaps' for every existing org so QA can
--    verify Gap Center immediately. Flip OFF per-org later if needed:
--        UPDATE grac_practice.feature_flag
--           SET is_enabled = 0, updated_by = 'ops', updated_dt = SYSUTCDATETIME()
--         WHERE organization_id = <id>
--           AND feature_flag_id = (SELECT feature_flag_id FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.gaps');
-- =====================================================================
DECLARE @gaps_feature_id INT =
    (SELECT feature_flag_id FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.gaps');

IF @gaps_feature_id IS NOT NULL
BEGIN
    MERGE grac_practice.feature_flag AS target
    USING (
        SELECT o.organization_id, @gaps_feature_id AS feature_flag_id
        FROM grac_practice.organization o
        WHERE o.status = N'Active'
    ) AS source
    ON target.organization_id = source.organization_id
       AND target.feature_flag_id = source.feature_flag_id
    WHEN MATCHED THEN UPDATE SET
        is_enabled = 1,
        notes      = COALESCE(target.notes, N'Enabled by seed-050'),
        updated_by = 'seed-050',
        updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (organization_id, feature_flag_id, is_enabled, notes, entered_by)
    VALUES
        (source.organization_id, source.feature_flag_id, 1, N'Enabled by seed-050', 'seed-050');
END
GO

-- =====================================================================
-- Post-seed sanity report
-- =====================================================================
SELECT 'menu_master.gaps present + Oversight' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1 FROM grac_practice.menu_master
           WHERE menu_key = N'gaps' AND status = N'Active' AND module_type = N'Oversight'
       ) THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'menu_master.tasks moved to Oversight' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1 FROM grac_practice.menu_master
           WHERE menu_key = N'tasks' AND status = N'Active' AND module_type = N'Oversight'
       ) THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Admin role permissions granted on gaps' AS Check_,
       COUNT(*) AS AdminRoleGrants
FROM grac_practice.organization_role_menu_permission p
JOIN grac_practice.organization_role r ON r.role_id = p.role_id
JOIN grac_practice.menu_master m       ON m.menu_id = p.menu_id
WHERE m.menu_key = N'gaps'
  AND r.role_name = N'Admin'
  AND p.can_view = 1;

SELECT 'screen.gaps enabled per-org' AS Check_,
       COUNT(*) AS EnabledOrgs
FROM grac_practice.feature_flag ff
JOIN grac_practice.feature_flag_master m ON m.feature_flag_id = ff.feature_flag_id
WHERE m.feature_code = N'screen.gaps'
  AND ff.is_enabled = 1;

PRINT '050 Gap Center menu + permissions + feature flag seed complete.';
GO

SET NOEXEC OFF;
GO
