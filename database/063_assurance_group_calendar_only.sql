-- =====================================================================
-- 063 Introduce the Assurance sidebar group + dissolve Registers
--
-- Sidebar shape change:
--   * NEW: synthetic parent 'nav-assurance' (menu_name 'Assurance'),
--          slotted between Oversight (400) and Administration (500)
--          at display_order 450.
--   * assurance-calendar reparented under nav-assurance and relabelled
--     'Calendar'. URL / screen key unchanged so the existing Assurance
--     Calendar page is reused as-is.
--   * All OTHER assurance-* sidebar rows go Inactive (dashboard,
--     generation, activities, execution, evidence-assurance,
--     dependency-assurance, results, findings, signals, trends,
--     practice-health, audit-intelligence, risk-intelligence). Screen
--     keys stay valid in PracticeScreen.All so direct URLs still resolve.
--   * Registers group (nav-registers + workbench-* children) is
--     Inactivated -- the custodian queues stay reachable by URL but drop
--     out of the sidebar per the request.
--
-- Grants Admin role can_view on nav-assurance so it renders in the
-- sidebar the same way the other 052-seeded parents do.
--
-- ASCII-only. Idempotent -- safe to re-run.
-- Rollback: database/063_assurance_group_calendar_only_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    RAISERROR('063: prerequisites missing (schema grac_practice or menu_master).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- ---------------------------------------------------------------------------
-- Step 1 -- Upsert the synthetic 'nav-assurance' parent row.
-- ---------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance')
BEGIN
    UPDATE grac_practice.menu_master
       SET menu_name      = N'Assurance',
           menu_url       = NULL,
           parent_menu_id = NULL,
           display_order  = 450,
           icon_class     = N'shield-halved',
           module_type    = N'Assurance',
           status         = N'Active',
           updated_by     = 'seed-063',
           updated_dt     = SYSUTCDATETIME()
     WHERE menu_key = N'nav-assurance';
END
ELSE
BEGIN
    INSERT INTO grac_practice.menu_master
        (menu_key, menu_name, menu_url, parent_menu_id, display_order,
         icon_class, module_type, status, entered_by)
    VALUES
        (N'nav-assurance', N'Assurance', NULL, NULL, 450,
         N'shield-halved', N'Assurance', N'Active', 'seed-063');
END

DECLARE @assurance_parent_id BIGINT = (
    SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance'
);

-- ---------------------------------------------------------------------------
-- Step 2 -- Reparent + rename assurance-calendar as the sole child.
--           menu_key + menu_url stay put so the existing page is reused.
-- ---------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'assurance-calendar')
BEGIN
    UPDATE grac_practice.menu_master
       SET menu_name      = N'Calendar',
           menu_url       = N'Practice/Index/assurance-calendar',
           parent_menu_id = @assurance_parent_id,
           display_order  = 455,
           icon_class     = N'calendar-days',
           module_type    = N'Assurance',
           status         = N'Active',
           updated_by     = 'seed-063',
           updated_dt     = SYSUTCDATETIME()
     WHERE menu_key = N'assurance-calendar';
END
ELSE
BEGIN
    -- If migration 028 was never applied, insert a fresh row pointing at
    -- the existing page.
    INSERT INTO grac_practice.menu_master
        (menu_key, menu_name, menu_url, parent_menu_id, display_order,
         icon_class, module_type, status, entered_by)
    VALUES
        (N'assurance-calendar', N'Calendar',
         N'Practice/Index/assurance-calendar',
         @assurance_parent_id, 455,
         N'calendar-days', N'Assurance', N'Active', 'seed-063');
END

-- ---------------------------------------------------------------------------
-- Step 3 -- Inactivate every other Assurance sidebar row.
--           Screen keys survive in PracticeScreen.All so /Practice/Index/*
--           URLs still resolve; only the sidebar hides them.
-- ---------------------------------------------------------------------------
UPDATE grac_practice.menu_master
   SET status     = N'Inactive',
       updated_by = 'seed-063',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (
        N'assurance-dashboard',
        N'assurance-generation',
        N'assurance-activities',
        N'assurance-execution',
        N'evidence-assurance',
        N'dependency-assurance',
        N'assurance-results',
        N'assurance-findings',
        N'assurance-signals',
        N'assurance-trends',
        N'practice-health',
        N'audit-intelligence',
        N'risk-intelligence'
   );

-- ---------------------------------------------------------------------------
-- Step 4 -- Dissolve the Registers group.
--           nav-registers parent + every workbench-* child go Inactive.
-- ---------------------------------------------------------------------------
UPDATE grac_practice.menu_master
   SET status     = N'Inactive',
       updated_by = 'seed-063',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'nav-registers'
    OR menu_key LIKE N'workbench-%';

-- ---------------------------------------------------------------------------
-- Step 5 -- Grant every Admin role can_view on the new nav-assurance
--           parent so it renders in the sidebar (mirrors what migration
--           052 does for the other synthetic parents).
-- ---------------------------------------------------------------------------
IF OBJECT_ID('grac_practice.organization_role','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
BEGIN
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
               CAST(0 AS BIT) AS can_add,
               CAST(0 AS BIT) AS can_edit,
               CAST(0 AS BIT) AS can_delete,
               CAST(0 AS BIT) AS can_approve,
               @active_record_status_id AS record_status_id
        FROM grac_practice.organization_role r
        CROSS JOIN grac_practice.menu_master m
        WHERE r.role_name = N'Admin'
          AND r.status    = N'Active'
          AND m.menu_key  = N'nav-assurance'
    ) AS source
    ON target.role_id = source.role_id AND target.menu_id = source.menu_id
    WHEN MATCHED THEN UPDATE SET
        can_view    = source.can_view,
        status      = N'Active',
        updated_by  = 'seed-063',
        updated_dt  = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
         status, record_status_id, entered_by)
    VALUES
        (source.role_id, source.menu_id, source.can_view, source.can_add,
         source.can_edit, source.can_delete, source.can_approve,
         N'Active', source.record_status_id, 'seed-063');
END

COMMIT TRAN;

-- ---------------------------------------------------------------------------
-- Sanity report
-- ---------------------------------------------------------------------------
SELECT p.menu_key AS ParentKey,
       p.menu_name AS Parent,
       c.menu_key AS ChildKey,
       c.menu_name AS ChildName,
       c.display_order,
       c.status
FROM grac_practice.menu_master p
LEFT JOIN grac_practice.menu_master c ON c.parent_menu_id = p.menu_id
WHERE p.menu_key IN (N'nav-assurance', N'nav-registers')
ORDER BY p.menu_key, c.status DESC, c.display_order;

SELECT 'Assurance sidebar rows' AS Check_,
       COUNT(*)                   AS Total,
       SUM(CASE WHEN status = N'Active'   THEN 1 ELSE 0 END) AS Active_,
       SUM(CASE WHEN status = N'Inactive' THEN 1 ELSE 0 END) AS Inactive_
FROM grac_practice.menu_master
WHERE menu_key = N'nav-assurance'
   OR menu_key LIKE N'assurance-%'
   OR menu_key IN (N'evidence-assurance', N'dependency-assurance',
                   N'practice-health', N'audit-intelligence', N'risk-intelligence');

SELECT 'Registers sidebar rows' AS Check_,
       COUNT(*)                   AS Total,
       SUM(CASE WHEN status = N'Active'   THEN 1 ELSE 0 END) AS Active_,
       SUM(CASE WHEN status = N'Inactive' THEN 1 ELSE 0 END) AS Inactive_
FROM grac_practice.menu_master
WHERE menu_key = N'nav-registers' OR menu_key LIKE N'workbench-%';

PRINT '063 Assurance group + Registers dissolve complete.';
PRINT '  nav-assurance -> Active (parent). Sole child: Calendar (assurance-calendar).';
PRINT '  Every other assurance-* row + evidence-assurance + dependency-assurance';
PRINT '  + practice-health + audit-intelligence + risk-intelligence -> Inactive.';
PRINT '  nav-registers + workbench-* -> Inactive.';
GO

SET NOEXEC OFF;
GO
