-- =====================================================================
-- 068 Workflow Engine menu + feature flag
--
-- User requirement:
--   "menu idumbo workflow nnu parent ittu bhaki ellam athinte under ku idanam."
--   -> Create a new parent 'Workflow' in the sidebar, and place every
--      new Event-Driven Assurance screen under it.
--
-- Charter alignment:
--   * Migration 052 established the parent_menu_id hierarchy. We follow
--     the same pattern here -- one synthetic parent row (nav-workflow)
--     plus one child leaf per screen. display_order 450 places the group
--     between Oversight (400) and Administration (500).
--   * Every new screen defaults OFF via feature_flag_master (charter
--     Sec 7) and is then enabled per-org so QA can verify immediately.
--
-- Screens (each child menu row + PracticeScreen registration):
--   workflows                Workflow Definitions       (BRD Sec 6)
--   workflow-stages          Workflow Stages            (BRD Sec 7)
--   workflow-entity-types    Entity Types               (BRD Sec 9)
--   workflow-events          Events                     (BRD Sec 8)
--   workflow-checklists      Checklists                 (BRD Sec 11)
--   workflow-event-mappings  Event-Checklist Mappings   (BRD Sec 10)
--   event-assurance          Event Assurance            (BRD Sec 13/14)
--   workflow-dashboard       Workflow Dashboard         (BRD Sec 16)
--
-- ASCII-only. Idempotent (MERGE on natural keys).
-- Rollback: database/068_workflow_menu_seed_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (068): schema grac_practice missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (068): menu_master missing. Run deployment/01_Create_Schema_Tables.sql first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN
    PRINT 'ABORT (068): feature_flag_master or feature_flag missing. Run 041 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('068_workflow_menu_seed: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. feature_flag_master -- register a screen.* flag for every child.
-- =====================================================================
MERGE grac_practice.feature_flag_master AS t
USING (VALUES
    (N'screen.workflows',                N'Workflow Definitions',      N'Workflow & Event-Driven Assurance Engine (BRD Sec 6).'),
    (N'screen.workflow-stages',          N'Workflow Stages',           N'BRD Sec 7.'),
    (N'screen.workflow-entity-types',    N'Entity Types',              N'BRD Sec 9.'),
    (N'screen.workflow-events',          N'Events',                    N'BRD Sec 8.'),
    (N'screen.workflow-checklists',      N'Checklists',                N'BRD Sec 11.'),
    (N'screen.workflow-event-mappings',  N'Event-Checklist Mappings',  N'BRD Sec 10.'),
    (N'screen.event-assurance',          N'Event Assurance',           N'BRD Sec 13/14.'),
    (N'screen.workflow-dashboard',       N'Workflow Dashboard',        N'BRD Sec 16.')
) AS src(feature_code, feature_name, description)
ON t.feature_code = src.feature_code
WHEN MATCHED THEN UPDATE SET
    feature_name = src.feature_name,
    description  = src.description,
    updated_by   = 'seed-068',
    updated_dt   = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (feature_code, feature_name, description, category, default_enabled, entered_by)
    VALUES (src.feature_code, src.feature_name, src.description, N'Screen', 0, 'seed-068');
GO

-- =====================================================================
-- 2. menu_master -- parent 'nav-workflow' + child leaves.
--    display_order 450 places the group between Oversight (400) and
--    Administration (500). All URLs route through the generic
--    Practice/Index/{key} pattern -- Practice/Manage.cshtml dispatches
--    to Views/Practice/Partials/{key}.cshtml via workflowScreens set.
-- =====================================================================
MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'nav-workflow',              N'Workflow',                  CAST(NULL AS NVARCHAR(200)), 450, N'diagram-project',       N'Workflow'),
    (N'workflows',                 N'Workflow Definitions',      N'Practice/Index/workflows',                 451, N'sitemap',        N'Workflow'),
    (N'workflow-stages',           N'Workflow Stages',           N'Practice/Index/workflow-stages',           452, N'route',          N'Workflow'),
    (N'workflow-entity-types',     N'Entity Types',              N'Practice/Index/workflow-entity-types',     453, N'shapes',         N'Workflow'),
    (N'workflow-events',           N'Events',                    N'Practice/Index/workflow-events',           454, N'bolt',           N'Workflow'),
    (N'workflow-checklists',       N'Checklists',                N'Practice/Index/workflow-checklists',       455, N'list-check',     N'Workflow'),
    (N'workflow-event-mappings',   N'Event-Checklist Mappings',  N'Practice/Index/workflow-event-mappings',   456, N'link',           N'Workflow'),
    (N'event-assurance',           N'Event Assurance',           N'Practice/Index/event-assurance',           457, N'shield-halved', N'Workflow'),
    (N'workflow-dashboard',        N'Workflow Dashboard',        N'Practice/Index/workflow-dashboard',        458, N'chart-line',    N'Workflow')
) AS source(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON target.menu_key = source.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name     = source.menu_name,
    menu_url      = source.menu_url,
    display_order = source.display_order,
    icon_class    = source.icon_class,
    module_type   = source.module_type,
    status        = N'Active',
    updated_by    = 'seed-068',
    updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
VALUES
    (source.menu_key, source.menu_name, source.menu_url, source.display_order,
     source.icon_class, source.module_type, N'Active', 'seed-068');
GO

-- =====================================================================
-- 3. Wire children to nav-workflow parent.
-- =====================================================================
DECLARE @wf_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-workflow');

-- Parent stays parentless (root nav entry).
UPDATE grac_practice.menu_master
   SET parent_menu_id = NULL,
       menu_url       = NULL,
       updated_by     = 'seed-068',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'nav-workflow';

-- All children point at nav-workflow.
IF @wf_id IS NOT NULL
BEGIN
    UPDATE grac_practice.menu_master
       SET parent_menu_id = @wf_id,
           updated_by     = 'seed-068',
           updated_dt     = SYSUTCDATETIME()
     WHERE menu_key IN (N'workflows', N'workflow-stages', N'workflow-entity-types',
                        N'workflow-events', N'workflow-checklists',
                        N'workflow-event-mappings', N'event-assurance',
                        N'workflow-dashboard');
END
GO

-- =====================================================================
-- 4. Grant Admin role full permissions on every new menu row (child +
--    parent). Mirrors the 050 pattern.
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
           CAST(CASE WHEN m.menu_key = N'nav-workflow' THEN 0 ELSE 1 END AS BIT) AS can_add,
           CAST(CASE WHEN m.menu_key = N'nav-workflow' THEN 0 ELSE 1 END AS BIT) AS can_edit,
           CAST(CASE WHEN m.menu_key = N'nav-workflow' THEN 0 ELSE 1 END AS BIT) AS can_delete,
           CAST(CASE WHEN m.menu_key = N'nav-workflow' THEN 0 ELSE 1 END AS BIT) AS can_approve,
           @active_record_status_id AS record_status_id
    FROM grac_practice.organization_role r
    CROSS JOIN grac_practice.menu_master m
    WHERE r.role_name = N'Admin'
      AND r.status    = N'Active'
      AND m.menu_key IN (N'nav-workflow', N'workflows', N'workflow-stages',
                         N'workflow-entity-types', N'workflow-events',
                         N'workflow-checklists', N'workflow-event-mappings',
                         N'event-assurance', N'workflow-dashboard')
) AS source
ON target.role_id = source.role_id AND target.menu_id = source.menu_id
WHEN MATCHED THEN UPDATE SET
    can_view    = source.can_view,
    can_add     = source.can_add,
    can_edit    = source.can_edit,
    can_delete  = source.can_delete,
    can_approve = source.can_approve,
    status      = N'Active',
    updated_by  = 'seed-068',
    updated_dt  = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by)
VALUES
    (source.role_id, source.menu_id, source.can_view, source.can_add,
     source.can_edit, source.can_delete, source.can_approve,
     N'Active', source.record_status_id, 'seed-068');
GO

-- =====================================================================
-- 5. feature_flag -- enable every screen.workflow* / screen.event-assurance
--    flag for every active organization so QA sees the module immediately.
-- =====================================================================
MERGE grac_practice.feature_flag AS target
USING (
    SELECT o.organization_id, fm.feature_flag_id
    FROM grac_practice.organization o
    CROSS JOIN grac_practice.feature_flag_master fm
    WHERE o.status = N'Active'
      AND fm.feature_code IN (N'screen.workflows', N'screen.workflow-stages',
                              N'screen.workflow-entity-types',
                              N'screen.workflow-events',
                              N'screen.workflow-checklists',
                              N'screen.workflow-event-mappings',
                              N'screen.event-assurance',
                              N'screen.workflow-dashboard')
) AS source
ON target.organization_id = source.organization_id
   AND target.feature_flag_id = source.feature_flag_id
WHEN MATCHED THEN UPDATE SET
    is_enabled = 1,
    notes      = COALESCE(target.notes, N'Enabled by seed-068'),
    updated_by = 'seed-068',
    updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (organization_id, feature_flag_id, is_enabled, notes, entered_by)
VALUES
    (source.organization_id, source.feature_flag_id, 1, N'Enabled by seed-068', 'seed-068');
GO

-- =====================================================================
-- Post-seed sanity report
-- =====================================================================
SELECT 'Workflow parent present' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1 FROM grac_practice.menu_master
           WHERE menu_key = N'nav-workflow'
             AND parent_menu_id IS NULL
             AND menu_url IS NULL
             AND status = N'Active'
       ) THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT p.menu_name AS Parent, COUNT(c.menu_id) AS Children,
       STRING_AGG(c.menu_key, ', ') WITHIN GROUP (ORDER BY c.display_order) AS ChildKeys
FROM grac_practice.menu_master p
LEFT JOIN grac_practice.menu_master c ON c.parent_menu_id = p.menu_id AND c.status = N'Active'
WHERE p.menu_key = N'nav-workflow'
GROUP BY p.menu_id, p.menu_name;

PRINT '068 workflow menu seed complete.';
GO

SET NOEXEC OFF;
GO
