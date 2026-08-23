-- =====================================================================
-- 149 Document Upload menu + role permissions + feature flag
--
-- The Web sidebar is built from grac_practice.menu_master filtered by
-- grac_practice.organization_role_menu_permission. Registering
-- 'document-uploads' in workflowScreens (Manage.cshtml) is not enough --
-- a menu_master row plus role grants are required for the item to
-- appear in the UI, and the feature flag has to be on for the partial
-- to render.
--
-- This migration:
--   1. Adds `document-uploads` to menu_master with URL
--      Practice/Index/document-uploads
--   2. Grants every organisation's Admin role can_view + can_add +
--      can_edit + can_delete + can_approve on the new menu
--   3. Registers `screen.document-uploads` in feature_flag_master
--      (default OFF per charter §7)
--   4. Explicitly enables the flag per-org so the partial renders
--      immediately for QA (turn OFF per-org later via UPDATE)
--
-- Idempotent: MERGEs on natural keys; safe to re-run.
-- Follows the exact shape of 042_task_center_menu_seed.sql (same MERGE
-- form, same ASCII-only guard, same sanity report). Any bug fix that
-- applies to 042 will apply here identically.
--
-- Rollback: database/149_document_upload_menu_seed_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Prerequisite guard -----------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (149): schema grac_practice missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (149): menu_master missing. Run deployment/01_Create_Schema_Tables.sql first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN
    PRINT 'ABORT (149): organization_role or organization_role_menu_permission missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN
    PRINT 'ABORT (149): feature_flag_master or feature_flag missing. Run 041_feature_flag.sql first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.document_upload','U') IS NULL
BEGIN
    PRINT 'ABORT (149): document_upload missing. Run 146 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('149_document_upload_menu_seed: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. feature_flag_master -- register `screen.document-uploads` (OFF)
-- =====================================================================
MERGE grac_practice.feature_flag_master AS t
USING (VALUES
    (N'screen.document-uploads', N'Document Uploads', N'Controlled document register, upload, and review/approve workflow (migrations 146-148).')
) AS src(feature_code, feature_name, description)
ON t.feature_code = src.feature_code
WHEN MATCHED THEN UPDATE SET
    feature_name = src.feature_name,
    description  = src.description,
    updated_by   = 'seed-149',
    updated_dt   = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (feature_code, feature_name, description, default_enabled, entered_by)
VALUES
    (src.feature_code, src.feature_name, src.description, 0, 'seed-149');
GO

-- =====================================================================
-- 2. menu_master -- register `document-uploads` under nav-oversight
--
-- Since migration 052 the sidebar renders via parent_menu_id, not
-- module_type. A row with parent_menu_id = NULL is treated as a
-- top-level parent (like nav-oversight itself) and will not surface
-- as a child. Task Center and Gap Center both sit under nav-oversight;
-- Document Uploads (review/approve workflow) belongs with them.
--
-- Placed at display_order 240 so it sits after Task Center (225) and
-- Gap Center (230) within the Oversight group.
-- =====================================================================
DECLARE @oversight_menu_id BIGINT =
    (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-oversight');

IF @oversight_menu_id IS NULL
BEGIN
    RAISERROR('149: parent menu nav-oversight is missing. Run 052 first.', 16, 1);
    SET NOEXEC ON;
END

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'document-uploads', N'Document Uploads', N'Practice/Index/document-uploads',
     @oversight_menu_id, 240, N'file-lines', N'Oversight')
) AS source(menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type)
ON target.menu_key = source.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name     = source.menu_name,
    menu_url      = source.menu_url,
    parent_menu_id= source.parent_menu_id,
    display_order = source.display_order,
    icon_class    = source.icon_class,
    module_type   = source.module_type,
    status        = N'Active',
    updated_by    = 'seed-149',
    updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order,
     icon_class, module_type, status, entered_by)
VALUES
    (source.menu_key, source.menu_name, source.menu_url, source.parent_menu_id,
     source.display_order, source.icon_class, source.module_type, N'Active', 'seed-149');
GO

-- =====================================================================
-- 3. organization_role_menu_permission -- grant Admin roles full rights
-- =====================================================================
DECLARE @menu_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'document-uploads');
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
               @menu_id                 AS menu_id,
               CAST(1 AS BIT)           AS can_view,
               CAST(1 AS BIT)           AS can_add,
               CAST(1 AS BIT)           AS can_edit,
               CAST(1 AS BIT)           AS can_delete,
               CAST(1 AS BIT)           AS can_approve,
               @active_record_status_id AS record_status_id
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
        updated_by  = 'seed-149',
        updated_dt  = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
         status, record_status_id, entered_by)
    VALUES
        (source.role_id, source.menu_id, source.can_view, source.can_add,
         source.can_edit, source.can_delete, source.can_approve,
         N'Active', source.record_status_id, 'seed-149');
END
GO

-- =====================================================================
-- 4. feature_flag -- enable per-org so the partial renders immediately.
--    Turn OFF later via:
--      UPDATE grac_practice.feature_flag
--         SET is_enabled = 0, updated_by = 'ops', updated_dt = SYSUTCDATETIME()
--       WHERE organization_id = <id>
--         AND feature_flag_id = (SELECT feature_flag_id FROM grac_practice.feature_flag_master
--                                 WHERE feature_code = N'screen.document-uploads');
-- =====================================================================
DECLARE @doc_feature_id INT =
    (SELECT feature_flag_id FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.document-uploads');

IF @doc_feature_id IS NOT NULL
BEGIN
    MERGE grac_practice.feature_flag AS target
    USING (
        SELECT o.organization_id, @doc_feature_id AS feature_flag_id
        FROM grac_practice.organization o
        WHERE o.status = N'Active'
    ) AS source
    ON target.organization_id = source.organization_id
       AND target.feature_flag_id = source.feature_flag_id
    WHEN MATCHED THEN UPDATE SET
        is_enabled = 1,
        notes      = COALESCE(target.notes, N'Enabled by seed-149'),
        updated_by = 'seed-149',
        updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (organization_id, feature_flag_id, is_enabled, notes, entered_by)
    VALUES
        (source.organization_id, source.feature_flag_id, 1, N'Enabled by seed-149', 'seed-149');
END
GO

-- =====================================================================
-- Post-seed sanity report
-- =====================================================================
SELECT 'menu_master.document-uploads present' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'document-uploads' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Admin role permissions granted' AS Check_, COUNT(*) AS AdminRoleGrants
  FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.organization_role r ON r.role_id = p.role_id
  JOIN grac_practice.menu_master m       ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'document-uploads' AND r.role_name = N'Admin' AND p.can_view = 1;

SELECT 'screen.document-uploads enabled per-org' AS Check_, COUNT(*) AS EnabledOrgs
  FROM grac_practice.feature_flag ff
  JOIN grac_practice.feature_flag_master m ON m.feature_flag_id = ff.feature_flag_id
 WHERE m.feature_code = N'screen.document-uploads' AND ff.is_enabled = 1;

PRINT '149 Document Upload menu + permissions + feature flag seed complete.';
GO

SET NOEXEC OFF;
GO
