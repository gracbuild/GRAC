-- =====================================================================
-- 042 Task Center menu + role permissions  (charter §12.1.3, §9)
--
-- The Web sidebar is built from grac_practice.menu_master filtered by
-- grac_practice.organization_role_menu_permission. Registering a key
-- in PracticeScreen.All is not sufficient — a corresponding menu_master
-- row plus role grants are required for the item to appear in the UI.
--
-- This migration:
--   1. Adds `tasks` (Task Center) to menu_master with URL Practice/Index/tasks
--   2. Grants the Admin role of every organisation can_view + can_add +
--      can_edit + can_delete + can_approve on that menu
--   3. Enables the `screen.tasks` feature flag for every organisation
--      (default was OFF — flipped ON here so the partial actually renders
--      once the menu is visible; can be flipped OFF per-org later)
--
-- Idempotent: MERGEs on natural keys; safe to re-run.
--
-- Rollback: database/042_task_center_menu_seed_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Prerequisite guard — same pattern as 035/037/040/041.
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (042): schema grac_practice missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (042): menu_master missing. Run deployment/01_Create_Schema_Tables.sql first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN
    PRINT 'ABORT (042): organization_role or organization_role_menu_permission missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN
    PRINT 'ABORT (042): feature_flag_master or feature_flag missing. Run 041_feature_flag.sql first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('042_task_center_menu_seed: prerequisites missing — see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. menu_master — insert `tasks` row
--    Placed at display_order 225 so it sits between practice-instances (220)
--    and resolve (230) inside the Practice Management group.
-- =====================================================================
MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'tasks', N'Task Center', N'Practice/Index/tasks', 225, N'list-check', N'Practice Management')
) AS source(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON target.menu_key = source.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name    = source.menu_name,
    menu_url     = source.menu_url,
    display_order= source.display_order,
    icon_class   = source.icon_class,
    module_type  = source.module_type,
    status       = N'Active',
    updated_by   = 'seed-042',
    updated_dt   = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
VALUES
    (source.menu_key, source.menu_name, source.menu_url, source.display_order,
     source.icon_class, source.module_type, N'Active', 'seed-042');
GO

-- =====================================================================
-- 2. organization_role_menu_permission — grant Admin roles full rights
--    Grants for every organisation's Admin role. Other roles are NOT
--    granted here — they can be added via the Roles / Role-Menu-Permission
--    UI once QA is complete.
-- =====================================================================
DECLARE @menu_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'tasks');
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
        updated_by  = 'seed-042',
        updated_dt  = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
         status, record_status_id, entered_by)
    VALUES
        (source.role_id, source.menu_id, source.can_view, source.can_add,
         source.can_edit, source.can_delete, source.can_approve,
         N'Active', source.record_status_id, 'seed-042');
END
GO

-- =====================================================================
-- 3. feature_flag — enable `screen.tasks` for every existing org
--    Charter §7 requires new screens default OFF. That default holds at
--    the feature_flag_master level (default_enabled = 0). This step
--    explicitly enables the flag per-org so the partial can render right
--    now for testing. Turn OFF per-org later with:
--        UPDATE grac_practice.feature_flag
--           SET is_enabled = 0, updated_by = 'ops', updated_dt = SYSUTCDATETIME()
--         WHERE organization_id = <id>
--           AND feature_flag_id = (SELECT feature_flag_id FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.tasks');
-- =====================================================================
DECLARE @tasks_feature_id INT =
    (SELECT feature_flag_id FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.tasks');

IF @tasks_feature_id IS NOT NULL
BEGIN
    MERGE grac_practice.feature_flag AS target
    USING (
        SELECT o.organization_id, @tasks_feature_id AS feature_flag_id
        FROM grac_practice.organization o
        WHERE o.status = N'Active'
    ) AS source
    ON target.organization_id = source.organization_id
       AND target.feature_flag_id = source.feature_flag_id
    WHEN MATCHED THEN UPDATE SET
        is_enabled = 1,
        notes      = COALESCE(target.notes, N'Enabled by seed-042'),
        updated_by = 'seed-042',
        updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (organization_id, feature_flag_id, is_enabled, notes, entered_by)
    VALUES
        (source.organization_id, source.feature_flag_id, 1, N'Enabled by seed-042', 'seed-042');
END
GO

-- =====================================================================
-- Post-seed sanity report
-- =====================================================================
SELECT 'menu_master.tasks present' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'tasks' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Admin role permissions granted' AS Check_,
       COUNT(*) AS AdminRoleGrants
FROM grac_practice.organization_role_menu_permission p
JOIN grac_practice.organization_role r ON r.role_id = p.role_id
JOIN grac_practice.menu_master m       ON m.menu_id = p.menu_id
WHERE m.menu_key = N'tasks'
  AND r.role_name = N'Admin'
  AND p.can_view = 1;

SELECT 'screen.tasks enabled per-org' AS Check_,
       COUNT(*) AS EnabledOrgs
FROM grac_practice.feature_flag ff
JOIN grac_practice.feature_flag_master m ON m.feature_flag_id = ff.feature_flag_id
WHERE m.feature_code = N'screen.tasks'
  AND ff.is_enabled = 1;

PRINT '042 Task Center menu + permissions + feature flag seed complete.';
GO

SET NOEXEC OFF;
GO
