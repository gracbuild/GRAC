-- =====================================================================
-- 152 Document Acknowledgement menu + role permissions + feature flag
--
-- Adds `document-acknowledgements` under nav-oversight (same parent as
-- Document Uploads, Tasks, Gaps). Grants Admin roles full rights and
-- enables the feature flag per-organization for immediate QA.
--
-- Same shape as 149_document_upload_menu_seed.sql -- ASCII only,
-- MERGE-on-natural-key, sanity report at end.
--
-- Rollback: 152_document_acknowledgement_menu_seed_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Prerequisite guard -----------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (152): schema grac_practice missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (152): menu_master missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN PRINT 'ABORT (152): organization_role / permission missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN PRINT 'ABORT (152): feature_flag master or per-org table missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.document_acknowledgement','U') IS NULL
BEGIN PRINT 'ABORT (152): document_acknowledgement missing. Run 150 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('152_document_acknowledgement_menu_seed: prerequisites missing -- see PRINT messages.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. feature_flag_master -- register `screen.document-acknowledgements` (OFF)
-- =====================================================================
MERGE grac_practice.feature_flag_master AS t
USING (VALUES
    (N'screen.document-acknowledgements', N'Document Acknowledgements',
     N'Admin batches for tracking user acknowledgement of published documents (migrations 150-151).')
) AS src(feature_code, feature_name, description)
ON t.feature_code = src.feature_code
WHEN MATCHED THEN UPDATE SET
    feature_name = src.feature_name,
    description  = src.description,
    updated_by   = 'seed-152',
    updated_dt   = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (feature_code, feature_name, description, default_enabled, entered_by)
VALUES
    (src.feature_code, src.feature_name, src.description, 0, 'seed-152');
GO

-- =====================================================================
-- 2. menu_master -- register `document-acknowledgements` under nav-oversight
--    display_order 250 -- immediately after document-uploads (240).
-- =====================================================================
DECLARE @oversight_menu_id BIGINT =
    (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-oversight');
IF @oversight_menu_id IS NULL
BEGIN
    RAISERROR('152: parent menu nav-oversight is missing. Run 052 first.', 16, 1);
    SET NOEXEC ON;
END

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'document-acknowledgements', N'Document Acknowledgements',
     N'Practice/Index/document-acknowledgements',
     @oversight_menu_id, 250, N'file-signature', N'Oversight')
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
    updated_by    = 'seed-152',
    updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order,
     icon_class, module_type, status, entered_by)
VALUES
    (source.menu_key, source.menu_name, source.menu_url, source.parent_menu_id,
     source.display_order, source.icon_class, source.module_type, N'Active', 'seed-152');
GO

-- =====================================================================
-- 3. organization_role_menu_permission -- grant Admin roles full rights
-- =====================================================================
DECLARE @menu_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'document-acknowledgements');
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
        WHERE r.role_name = N'Admin' AND r.status = N'Active'
    ) AS source
    ON target.role_id = source.role_id AND target.menu_id = source.menu_id
    WHEN MATCHED THEN UPDATE SET
        can_view    = source.can_view, can_add   = source.can_add,
        can_edit    = source.can_edit, can_delete= source.can_delete,
        can_approve = source.can_approve,
        status      = N'Active', updated_by = 'seed-152', updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
         status, record_status_id, entered_by)
    VALUES
        (source.role_id, source.menu_id, source.can_view, source.can_add,
         source.can_edit, source.can_delete, source.can_approve,
         N'Active', source.record_status_id, 'seed-152');
END
GO

-- =====================================================================
-- 4. feature_flag -- enable per-org.
-- =====================================================================
DECLARE @ack_feature_id INT =
    (SELECT feature_flag_id FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.document-acknowledgements');
IF @ack_feature_id IS NOT NULL
BEGIN
    MERGE grac_practice.feature_flag AS target
    USING (
        SELECT o.organization_id, @ack_feature_id AS feature_flag_id
        FROM grac_practice.organization o WHERE o.status = N'Active'
    ) AS source
    ON target.organization_id = source.organization_id AND target.feature_flag_id = source.feature_flag_id
    WHEN MATCHED THEN UPDATE SET
        is_enabled = 1, notes = COALESCE(target.notes, N'Enabled by seed-152'),
        updated_by = 'seed-152', updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (organization_id, feature_flag_id, is_enabled, notes, entered_by)
    VALUES
        (source.organization_id, source.feature_flag_id, 1, N'Enabled by seed-152', 'seed-152');
END
GO

-- Sanity report -----------------------------------------------------
SELECT 'menu_master.document-acknowledgements present' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'document-acknowledgements' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '152 Document Acknowledgement menu + permissions + feature flag seed complete.';
GO
SET NOEXEC OFF;
GO
