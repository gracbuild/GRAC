-- =====================================================================
-- 125 Scoped Event Assurance -- menu, permissions, feature flags
--
-- Two screens, both under the existing nav-workflow parent seeded by 068:
--   workflow-scope-mapping   Map checklists to a role / asset category
--   workflow-event-inbox     Raise lifecycle events, complete checklists
--
-- display_order 459 / 460 places them after workflow-dashboard (458) and
-- before Administration (500), keeping the Workflow group contiguous.
--
-- Feature flags default OFF, matching every other workflow screen: the
-- schema and procs can ship to production ahead of the UI, and each
-- organization is switched on deliberately.
--
-- Depends on 068 (nav-workflow parent) and 123/124.
-- Rollback: 125_event_scope_menu_seed_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (125): schema grac_practice missing.'; SET @prereqs_ok = 0; END
IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (125): menu_master missing.'; SET @prereqs_ok = 0; END
IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN PRINT 'ABORT (125): feature_flag* missing.'; SET @prereqs_ok = 0; END
IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-workflow')
BEGIN PRINT 'ABORT (125): nav-workflow parent missing (run 068).'; SET @prereqs_ok = 0; END
IF OBJECT_ID('grac_practice.sp_event_instance_raise_scoped','P') IS NULL
BEGIN PRINT 'ABORT (125): run 124 procs first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 0
BEGIN
    RAISERROR('125: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. feature_flag_master
-- =====================================================================
MERGE grac_practice.feature_flag_master AS t
USING (VALUES
    (N'screen.workflow-scope-mapping',
     N'Scoped Checklist Mapping',
     N'Map checklists to an organisation role or asset category, restricted to subscribed releases (migrations 123/124).'),
    (N'screen.workflow-event-inbox',
     N'Event Checklist Inbox',
     N'Raise people and asset lifecycle events and complete the resulting scoped checklists (migrations 123/124).')
) AS src(feature_code, feature_name, description)
ON t.feature_code = src.feature_code
WHEN MATCHED THEN UPDATE SET
    feature_name = src.feature_name, description = src.description,
    updated_by = 'seed-125', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN INSERT
    (feature_code, feature_name, description, category, default_enabled, entered_by)
VALUES
    (src.feature_code, src.feature_name, src.description, N'Screen', 0, 'seed-125');
GO

-- =====================================================================
-- 2. menu_master
-- =====================================================================
MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'workflow-scope-mapping', N'Scoped Checklist Mapping',
     N'Practice/Index/workflow-scope-mapping', 459, N'diagram-project', N'Workflow'),
    (N'workflow-event-inbox',   N'Event Checklist Inbox',
     N'Practice/Index/workflow-event-inbox',   460, N'inbox',           N'Workflow')
) AS source(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON target.menu_key = source.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name     = source.menu_name,
    menu_url      = source.menu_url,
    display_order = source.display_order,
    icon_class    = source.icon_class,
    module_type   = source.module_type,
    status        = N'Active',
    updated_by    = 'seed-125',
    updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
VALUES
    (source.menu_key, source.menu_name, source.menu_url, source.display_order,
     source.icon_class, source.module_type, N'Active', 'seed-125');
GO

-- =====================================================================
-- 3. Wire both children to nav-workflow
-- =====================================================================
DECLARE @wf_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-workflow');
IF @wf_id IS NULL THROW 125001, 'nav-workflow parent menu missing.', 1;

UPDATE grac_practice.menu_master
   SET parent_menu_id = @wf_id,
       updated_by     = 'seed-125',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key IN (N'workflow-scope-mapping', N'workflow-event-inbox');
GO

-- =====================================================================
-- 4. Admin role permissions (mirrors the 068 pattern)
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
      AND m.menu_key IN (N'workflow-scope-mapping', N'workflow-event-inbox')
) AS source
ON target.role_id = source.role_id AND target.menu_id = source.menu_id
WHEN MATCHED THEN UPDATE SET
    can_view = source.can_view, can_add = source.can_add, can_edit = source.can_edit,
    can_delete = source.can_delete, can_approve = source.can_approve,
    status = N'Active', updated_by = 'seed-125', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by)
VALUES
    (source.role_id, source.menu_id, source.can_view, source.can_add,
     source.can_edit, source.can_delete, source.can_approve,
     N'Active', source.record_status_id, 'seed-125');
GO

-- =====================================================================
-- 5. feature_flag -- enable both screens for every active organization.
--
--    WHY THIS BLOCK EXISTS
--    ---------------------
--    grac_practice.fn_pm_feature_enabled resolves in two steps: it looks
--    for a per-organization feature_flag row first, and only falls back to
--    feature_flag_master.default_enabled when none exists. default_enabled
--    is 0 above (deliberately -- a screen must never appear in production
--    just because a migration ran), so WITHOUT this block the probe returns
--    0 and both screens render "not yet enabled for this organization".
--
--    068 enables every other workflow screen exactly this way so QA sees
--    the module immediately. This block was missing in the first cut of
--    125; adding it here keeps the two migrations consistent. The whole
--    file is MERGE-based, so re-running it is safe.
-- =====================================================================
MERGE grac_practice.feature_flag AS target
USING (
    SELECT o.organization_id, fm.feature_flag_id
    FROM   grac_practice.organization o
    CROSS JOIN grac_practice.feature_flag_master fm
    WHERE  o.status = N'Active'
      AND  fm.feature_code IN (N'screen.workflow-scope-mapping',
                               N'screen.workflow-event-inbox')
) AS source
ON  target.organization_id = source.organization_id
AND target.feature_flag_id = source.feature_flag_id
WHEN MATCHED THEN UPDATE SET
    is_enabled = 1,
    notes      = COALESCE(target.notes, N'Enabled by seed-125'),
    updated_by = 'seed-125',
    updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (organization_id, feature_flag_id, is_enabled, notes, entered_by)
VALUES
    (source.organization_id, source.feature_flag_id, 1, N'Enabled by seed-125', 'seed-125');
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'scope-mapping menu present' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'workflow-scope-mapping'
                            AND parent_menu_id IS NOT NULL AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'event-inbox menu present' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'workflow-event-inbox'
                            AND parent_menu_id IS NOT NULL AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'feature flags registered' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.feature_flag_master
                   WHERE feature_code IN (N'screen.workflow-scope-mapping',
                                          N'screen.workflow-event-inbox')) = 2
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- This is the check that catches the "not yet enabled" symptom: the probe
-- reads fn_pm_feature_enabled, which needs a per-org row here.
DECLARE @active_orgs INT = (SELECT COUNT(*) FROM grac_practice.organization WHERE status = N'Active');
SELECT 'both screens enabled for every active org' AS Check_,
       CASE WHEN (SELECT COUNT(*)
                    FROM grac_practice.feature_flag ff
                    JOIN grac_practice.feature_flag_master fm ON fm.feature_flag_id = ff.feature_flag_id
                   WHERE fm.feature_code IN (N'screen.workflow-scope-mapping',
                                             N'screen.workflow-event-inbox')
                     AND ff.is_enabled = 1) >= @active_orgs * 2
            THEN 'PASS' ELSE 'FAIL -- screens will render "not yet enabled"' END AS Result;

-- Per-organization truth table, so a tester can see exactly where each
-- screen will appear.
SELECT o.organization_id,
       o.organization_name AS OrganizationName,
       fm.feature_code     AS FeatureCode,
       grac_practice.fn_pm_feature_enabled(o.organization_id, fm.feature_code) AS EffectiveEnabled
FROM   grac_practice.organization o
CROSS JOIN grac_practice.feature_flag_master fm
WHERE  o.status = N'Active'
  AND  fm.feature_code IN (N'screen.workflow-scope-mapping', N'screen.workflow-event-inbox')
ORDER BY o.organization_id, fm.feature_code;

PRINT '125 Scoped event assurance menu + permissions seeded.';
PRINT 'Both screens are ENABLED for every active organization (same as 068 does for the';
PRINT 'other workflow screens). To hide one, set is_enabled = 0 on its grac_practice.feature_flag row.';
GO

SET NOEXEC OFF;
GO
