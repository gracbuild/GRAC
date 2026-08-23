-- =====================================================================
-- 071 Organization Assurance (Phase 2) -- Stage 1 menu + permissions
--
-- Places the Stage 1 screen under the EXISTING 'nav-assurance' parent
-- (introduced by migration 063) using parent_menu_id -- the mandatory
-- grouping mechanism defined in migration 052.
--
-- Stage 1 seeds a single child screen:
--   org-assurance-definitions   Organization Assurance Definitions
--
-- Stages 2-4 will add additional child rows (scope-builder, questions,
-- evidence-config, workflows, scoring, plans, triggers, executions,
-- observations, gaps, dashboards, reports) using the same
-- parent_menu_id -> nav-assurance pattern.
--
-- Does NOT touch the existing assurance-calendar row or any of the
-- other (unrelated) assurance-* screens registered under nav-assurance.
--
-- ASCII-only. Idempotent (MERGE on menu_key + feature_code).
-- Rollback: database/071_org_assurance_menu_seed_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (071): schema grac_practice missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (071): menu_master missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN PRINT 'ABORT (071): organization_role* missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN PRINT 'ABORT (071): feature_flag* missing. Run 041.'; SET @prereqs_ok = 0; END

IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance')
BEGIN
    PRINT 'ABORT (071): parent menu nav-assurance not present. Run 063 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('071_org_assurance_menu_seed: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. feature_flag_master -- one screen.* flag per Stage 1 child.
-- =====================================================================
MERGE grac_practice.feature_flag_master AS t
USING (VALUES
    (N'screen.org-assurance-definitions',
     N'Organization Assurance Definitions',
     N'Phase 2 Assurance Management -- Organization-level Assurance Definitions (BRD Part 2 Sec 1).')
) AS src(feature_code, feature_name, description)
ON t.feature_code = src.feature_code
WHEN MATCHED THEN UPDATE SET
    feature_name = src.feature_name,
    description  = src.description,
    updated_by   = 'seed-071',
    updated_dt   = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN INSERT
    (feature_code, feature_name, description, category, default_enabled, entered_by)
VALUES
    (src.feature_code, src.feature_name, src.description, N'Screen', 0, 'seed-071');
GO

-- =====================================================================
-- 2. menu_master -- upsert child rows for Stage 1.
--    display_order values 460+ interleave under nav-assurance without
--    disturbing 'assurance-calendar' (which sits earlier under the
--    same parent per migration 063).
-- =====================================================================
MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'org-assurance-definitions',
     N'Assurance Definitions',
     N'Practice/org-assurance-definitions',
     460, N'file-shield', N'Assurance')
) AS source(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON target.menu_key = source.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name     = source.menu_name,
    menu_url      = source.menu_url,
    display_order = source.display_order,
    icon_class    = source.icon_class,
    module_type   = source.module_type,
    status        = N'Active',
    updated_by    = 'seed-071',
    updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, display_order, icon_class, module_type,
     status, entered_by)
VALUES
    (source.menu_key, source.menu_name, source.menu_url, source.display_order,
     source.icon_class, source.module_type, N'Active', 'seed-071');
GO

-- =====================================================================
-- 3. parent_menu_id wiring -- point every Stage 1 child at nav-assurance
--    (the parent introduced by migration 063). MUST use parent_menu_id
--    -- no route / name / display-order grouping.
-- =====================================================================
DECLARE @nav_id BIGINT = (
    SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance');

IF @nav_id IS NULL
    THROW 71001, 'nav-assurance parent menu missing. Run migration 063 first.', 1;

UPDATE grac_practice.menu_master
   SET parent_menu_id = @nav_id,
       updated_by     = 'seed-071',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key IN (N'org-assurance-definitions');
GO

-- =====================================================================
-- 4. Admin role permissions -- grant view/add/edit/approve on the new
--    child row. Follows the shape used in 068 (workflow) and 050 (gap
--    center).
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
           CAST(0 AS BIT) AS can_delete,          -- hard-delete not part of Stage 1
           CAST(1 AS BIT) AS can_approve,
           @active_record_status_id AS record_status_id
    FROM grac_practice.organization_role r
    CROSS JOIN grac_practice.menu_master m
    WHERE r.role_name = N'Admin'
      AND r.status    = N'Active'
      AND m.menu_key IN (N'org-assurance-definitions')
) AS source
ON target.role_id = source.role_id AND target.menu_id = source.menu_id
WHEN MATCHED THEN UPDATE SET
    can_view    = source.can_view,
    can_add     = source.can_add,
    can_edit    = source.can_edit,
    can_delete  = source.can_delete,
    can_approve = source.can_approve,
    status      = N'Active',
    updated_by  = 'seed-071',
    updated_dt  = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by)
VALUES
    (source.role_id, source.menu_id, source.can_view, source.can_add,
     source.can_edit, source.can_delete, source.can_approve,
     N'Active', source.record_status_id, 'seed-071');
GO

-- =====================================================================
-- 5. feature_flag -- enable the flag for every active organization so
--    the screen is visible immediately. Same shape as 068.
-- =====================================================================
MERGE grac_practice.feature_flag AS target
USING (
    SELECT o.organization_id, fm.feature_flag_id
    FROM grac_practice.organization o
    CROSS JOIN grac_practice.feature_flag_master fm
    WHERE o.status = N'Active'
      AND fm.feature_code IN (N'screen.org-assurance-definitions')
) AS source
ON target.organization_id = source.organization_id
   AND target.feature_flag_id = source.feature_flag_id
WHEN MATCHED THEN UPDATE SET
    is_enabled = 1,
    notes      = COALESCE(target.notes, N'Enabled by seed-071'),
    updated_by = 'seed-071',
    updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (organization_id, feature_flag_id, is_enabled, notes, entered_by)
VALUES
    (source.organization_id, source.feature_flag_id, 1,
     N'Enabled by seed-071', 'seed-071');
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Post-seed sanity report
-- =====================================================================
SELECT 'org-assurance-definitions has parent_menu_id = nav-assurance' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1
           FROM grac_practice.menu_master c
           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
           WHERE c.menu_key = N'org-assurance-definitions'
             AND p.menu_key = N'nav-assurance')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT p.menu_name AS Parent,
       COUNT(c.menu_id) AS ChildCount,
       STRING_AGG(c.menu_key, ', ') WITHIN GROUP (ORDER BY c.display_order) AS ChildKeys
FROM grac_practice.menu_master p
LEFT JOIN grac_practice.menu_master c
       ON c.parent_menu_id = p.menu_id AND c.status = N'Active'
WHERE p.menu_key = N'nav-assurance'
GROUP BY p.menu_id, p.menu_name;

PRINT '071 org-assurance-definitions menu seed complete.';
GO

SET NOEXEC OFF;
GO
