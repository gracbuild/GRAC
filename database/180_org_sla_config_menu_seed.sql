-- =====================================================================
-- 180 Organization SLA Config -- menu + permissions + feature flag
--
-- Registers the "SLA Configuration" screen under the existing
-- nav-governance parent (introduced in migration 052 / 065).
--
-- Screen key : org-sla-config
-- Menu label : SLA Configuration
-- Route      : Practice/org-sla-config  (matches project's Razor route
--              convention -- see 071 for org-assurance-definitions)
-- Feature    : screen.org-sla-config
--
-- Follows the exact shape of 071 (menu seed) and 088 (scoring config
-- seed). Idempotent MERGE on menu_key + feature_code.
--
-- Rollback: 180_org_sla_config_menu_seed_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (180): schema grac_practice missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (180): menu_master missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN PRINT 'ABORT (180): organization_role* missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN PRINT 'ABORT (180): feature_flag* missing. Run 041.'; SET @prereqs_ok = 0; END

IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-governance')
BEGIN
    PRINT 'ABORT (180): parent menu nav-governance not present. Run 052 / 065 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('180_org_sla_config_menu_seed: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. feature_flag_master -- one screen.* flag.
-- =====================================================================
MERGE grac_practice.feature_flag_master AS t
USING (VALUES
    (N'screen.org-sla-config',
     N'SLA Configuration',
     N'Organization-level adoption of Control Management SLA masters, with warning/escalation thresholds, notify roles, and per-process bindings.')
) AS src(feature_code, feature_name, description)
ON t.feature_code = src.feature_code
WHEN MATCHED THEN UPDATE SET
    feature_name = src.feature_name,
    description  = src.description,
    updated_by   = 'seed-180',
    updated_dt   = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN INSERT
    (feature_code, feature_name, description, category, default_enabled, entered_by)
VALUES
    (src.feature_code, src.feature_name, src.description, N'Screen', 0, 'seed-180');
GO

-- =====================================================================
-- 2. menu_master upsert.
--    display_order 550 places it near the end of nav-governance
--    children without disturbing existing rows.
-- =====================================================================
MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'org-sla-config',
     N'SLA Configuration',
     N'Practice/org-sla-config',
     550, N'clock', N'Governance')
) AS source(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON target.menu_key = source.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name     = source.menu_name,
    menu_url      = source.menu_url,
    display_order = source.display_order,
    icon_class    = source.icon_class,
    module_type   = source.module_type,
    status        = N'Active',
    updated_by    = 'seed-180',
    updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, display_order, icon_class, module_type,
     status, entered_by)
VALUES
    (source.menu_key, source.menu_name, source.menu_url, source.display_order,
     source.icon_class, source.module_type, N'Active', 'seed-180');
GO

-- =====================================================================
-- 3. parent_menu_id wiring -> nav-governance.
-- =====================================================================
DECLARE @gov_id BIGINT = (
    SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-governance');

IF @gov_id IS NULL
    THROW 18001, 'nav-governance parent menu missing. Run migration 052 / 065 first.', 1;

UPDATE grac_practice.menu_master
   SET parent_menu_id = @gov_id,
       updated_by     = 'seed-180',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'org-sla-config';
GO

-- =====================================================================
-- 4. Admin role permissions (view/add/edit/approve).
-- =====================================================================
DECLARE @active_record_status_id INT = (
    SELECT TOP 1 record_status_id
    FROM grac_practice.record_status_master
    WHERE status_code = 'ACTIVE' OR status_name = 'Active'
    ORDER BY record_status_id);
IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

MERGE grac_practice.organization_role_menu_permission AS target
USING (
    SELECT r.role_id, m.menu_id,
           CAST(1 AS BIT) AS can_view,
           CAST(1 AS BIT) AS can_add,
           CAST(1 AS BIT) AS can_edit,
           CAST(0 AS BIT) AS can_delete,
           CAST(1 AS BIT) AS can_approve,
           @active_record_status_id AS record_status_id
    FROM grac_practice.organization_role r
    CROSS JOIN grac_practice.menu_master m
    WHERE r.role_name = N'Admin'
      AND r.status    = N'Active'
      AND m.menu_key  = N'org-sla-config'
) AS source
ON target.role_id = source.role_id AND target.menu_id = source.menu_id
WHEN MATCHED THEN UPDATE SET
    can_view    = source.can_view,
    can_add     = source.can_add,
    can_edit    = source.can_edit,
    can_delete  = source.can_delete,
    can_approve = source.can_approve,
    status      = N'Active',
    updated_by  = 'seed-180',
    updated_dt  = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by)
VALUES
    (source.role_id, source.menu_id, source.can_view, source.can_add,
     source.can_edit, source.can_delete, source.can_approve,
     N'Active', source.record_status_id, 'seed-180');
GO

-- =====================================================================
-- 5. feature_flag enable for every active organization.
-- =====================================================================
MERGE grac_practice.feature_flag AS target
USING (
    SELECT o.organization_id, fm.feature_flag_id
    FROM grac_practice.organization o
    CROSS JOIN grac_practice.feature_flag_master fm
    WHERE o.status = N'Active'
      AND fm.feature_code = N'screen.org-sla-config'
) AS source
ON target.organization_id = source.organization_id
   AND target.feature_flag_id = source.feature_flag_id
WHEN MATCHED THEN UPDATE SET
    is_enabled = 1,
    notes      = COALESCE(target.notes, N'Enabled by seed-180'),
    updated_by = 'seed-180',
    updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (organization_id, feature_flag_id, is_enabled, notes, entered_by)
VALUES
    (source.organization_id, source.feature_flag_id, 1,
     N'Enabled by seed-180', 'seed-180');
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Post-seed sanity report
-- =====================================================================
SELECT 'org-sla-config parent = nav-governance' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1
           FROM grac_practice.menu_master c
           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
           WHERE c.menu_key = N'org-sla-config'
             AND p.menu_key = N'nav-governance')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'screen.org-sla-config feature flag exists' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1 FROM grac_practice.feature_flag_master
           WHERE feature_code = N'screen.org-sla-config')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '180 Organization SLA Config menu seed complete.';
GO

SET NOEXEC OFF;
GO
