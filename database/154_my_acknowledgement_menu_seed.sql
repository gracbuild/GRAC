-- =====================================================================
-- 154 My Acknowledgements menu + role permissions + feature flag
--
-- Adds `my-acknowledgements` under nav-oversight. This is the user
-- inbox for pending acknowledgements -- every organisation user needs
-- to see it (not just Admin). Granted to every ACTIVE organization
-- role, not just Admin, so a regular employee can find and act on
-- their own pending items.
--
-- Rollback: 154_my_acknowledgement_menu_seed_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (154): menu_master missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN PRINT 'ABORT (154): organization_role / permission missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN PRINT 'ABORT (154): feature_flag master missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.document_acknowledgement_user','U') IS NULL
BEGIN PRINT 'ABORT (154): document_acknowledgement_user missing. Run 150 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('154_my_acknowledgement_menu_seed: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- Feature flag ------------------------------------------------------
MERGE grac_practice.feature_flag_master AS t
USING (VALUES
    (N'screen.my-acknowledgements', N'My Acknowledgements',
     N'Employee inbox for pending document acknowledgements (migration 153).')
) AS src(feature_code, feature_name, description)
ON t.feature_code = src.feature_code
WHEN MATCHED THEN UPDATE SET
    feature_name = src.feature_name, description = src.description,
    updated_by = 'seed-154', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (feature_code, feature_name, description, default_enabled, entered_by)
VALUES (src.feature_code, src.feature_name, src.description, 0, 'seed-154');
GO

-- Menu row ----------------------------------------------------------
DECLARE @oversight_menu_id BIGINT =
    (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-oversight');
IF @oversight_menu_id IS NULL
BEGIN
    RAISERROR('154: parent menu nav-oversight is missing. Run 052 first.', 16, 1);
    SET NOEXEC ON;
END

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'my-acknowledgements', N'My Acknowledgements',
     N'Practice/Index/my-acknowledgements',
     @oversight_menu_id, 260, N'inbox', N'Oversight')
) AS source(menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type)
ON target.menu_key = source.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = source.menu_name, menu_url = source.menu_url,
    parent_menu_id = source.parent_menu_id, display_order = source.display_order,
    icon_class = source.icon_class, module_type = source.module_type,
    status = N'Active', updated_by = 'seed-154', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order,
     icon_class, module_type, status, entered_by)
VALUES (source.menu_key, source.menu_name, source.menu_url, source.parent_menu_id,
        source.display_order, source.icon_class, source.module_type, N'Active', 'seed-154');
GO

-- Grant view+add+edit to EVERY active organization role (not just Admin) --
DECLARE @menu_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'my-acknowledgements');
DECLARE @active_record_status_id INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

IF @menu_id IS NOT NULL
BEGIN
    MERGE grac_practice.organization_role_menu_permission AS target
    USING (
        SELECT r.role_id, @menu_id AS menu_id,
               CAST(1 AS BIT) AS can_view, CAST(1 AS BIT) AS can_add,
               CAST(1 AS BIT) AS can_edit, CAST(0 AS BIT) AS can_delete,
               CAST(0 AS BIT) AS can_approve, @active_record_status_id AS record_status_id
          FROM grac_practice.organization_role r
         WHERE r.status = N'Active'
    ) AS source
    ON target.role_id = source.role_id AND target.menu_id = source.menu_id
    WHEN MATCHED THEN UPDATE SET
        can_view = source.can_view, can_add = source.can_add,
        can_edit = source.can_edit, can_delete = source.can_delete,
        can_approve = source.can_approve,
        status = N'Active', updated_by = 'seed-154', updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
         status, record_status_id, entered_by)
    VALUES (source.role_id, source.menu_id, source.can_view, source.can_add,
            source.can_edit, source.can_delete, source.can_approve,
            N'Active', source.record_status_id, 'seed-154');
END
GO

-- Enable per-org ---------------------------------------------------
DECLARE @f_id INT = (SELECT feature_flag_id FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.my-acknowledgements');
IF @f_id IS NOT NULL
BEGIN
    MERGE grac_practice.feature_flag AS target
    USING (
        SELECT o.organization_id, @f_id AS feature_flag_id
          FROM grac_practice.organization o WHERE o.status = N'Active'
    ) AS source
    ON target.organization_id = source.organization_id AND target.feature_flag_id = source.feature_flag_id
    WHEN MATCHED THEN UPDATE SET is_enabled = 1,
        notes = COALESCE(target.notes, N'Enabled by seed-154'),
        updated_by = 'seed-154', updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (organization_id, feature_flag_id, is_enabled, notes, entered_by)
    VALUES (source.organization_id, source.feature_flag_id, 1, N'Enabled by seed-154', 'seed-154');
END
GO

PRINT '154 My Acknowledgements menu + permissions + feature flag seed complete.';
GO
SET NOEXEC OFF;
GO
