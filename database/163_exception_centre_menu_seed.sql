-- =====================================================================
-- 163 Exception Centre menu + role permissions + feature flag
-- Placed under nav-oversight, ordered after Gap Centre. Follows 149 shape.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;
IF OBJECT_ID('grac_practice.menu_master','U') IS NULL BEGIN PRINT 'ABORT (163): menu_master missing.'; SET @prereqs_ok = 0; END
IF OBJECT_ID('grac_practice.organization_role','U') IS NULL OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN PRINT 'ABORT (163): role / permission missing.'; SET @prereqs_ok = 0; END
IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN PRINT 'ABORT (163): feature_flag missing.'; SET @prereqs_ok = 0; END
IF OBJECT_ID('grac_practice.exception_request','U') IS NULL
BEGIN PRINT 'ABORT (163): exception_request missing. Run 161 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 0
BEGIN
    RAISERROR('163: prerequisites missing.', 16, 1); SET NOEXEC ON;
END
GO

MERGE grac_practice.feature_flag_master AS t
USING (VALUES (N'screen.exception-centre', N'Exception Centre',
       N'Governance workflow for time-boxed acceptance of gaps (migrations 161-162).')
) AS s(feature_code, feature_name, description)
ON t.feature_code = s.feature_code
WHEN MATCHED THEN UPDATE SET feature_name=s.feature_name, description=s.description, updated_by='seed-163', updated_dt=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT (feature_code, feature_name, description, default_enabled, entered_by)
VALUES (s.feature_code, s.feature_name, s.description, 0, 'seed-163');
GO

DECLARE @oversight_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-oversight');
IF @oversight_id IS NULL
BEGIN RAISERROR('163: nav-oversight missing. Run 052 first.', 16, 1); SET NOEXEC ON; END

MERGE grac_practice.menu_master AS target
USING (VALUES (N'exception-centre', N'Exception Centre', N'Practice/Index/exception-centre',
               @oversight_id, 270, N'shield-halved', N'Oversight'))
    AS src(menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = src.parent_menu_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = src.module_type,
    status = N'Active', updated_by = 'seed-163', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, src.parent_menu_id,
     src.display_order, src.icon_class, src.module_type, N'Active', 'seed-163');
GO

DECLARE @menu_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'exception-centre');
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
               CAST(1 AS BIT) AS can_edit, CAST(1 AS BIT) AS can_delete,
               CAST(1 AS BIT) AS can_approve, @active_record_status_id AS record_status_id
          FROM grac_practice.organization_role r
         WHERE r.role_name = N'Admin' AND r.status = N'Active'
    ) AS source
    ON target.role_id = source.role_id AND target.menu_id = source.menu_id
    WHEN MATCHED THEN UPDATE SET
        can_view = source.can_view, can_add = source.can_add,
        can_edit = source.can_edit, can_delete = source.can_delete,
        can_approve = source.can_approve,
        status = N'Active', updated_by = 'seed-163', updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
         status, record_status_id, entered_by)
    VALUES (source.role_id, source.menu_id, source.can_view, source.can_add,
            source.can_edit, source.can_delete, source.can_approve,
            N'Active', source.record_status_id, 'seed-163');
END
GO

DECLARE @f INT = (SELECT feature_flag_id FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.exception-centre');
IF @f IS NOT NULL
BEGIN
    MERGE grac_practice.feature_flag AS target
    USING (SELECT o.organization_id, @f AS feature_flag_id FROM grac_practice.organization o WHERE o.status = N'Active') AS src
    ON target.organization_id = src.organization_id AND target.feature_flag_id = src.feature_flag_id
    WHEN MATCHED THEN UPDATE SET is_enabled = 1, notes = COALESCE(target.notes, N'Enabled by seed-163'),
        updated_by = 'seed-163', updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (organization_id, feature_flag_id, is_enabled, notes, entered_by)
    VALUES (src.organization_id, src.feature_flag_id, 1, N'Enabled by seed-163', 'seed-163');
END
GO
PRINT '163 Exception Centre menu ready.';
GO
