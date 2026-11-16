-- =====================================================================
-- 556  Phase 4 -- Continuous Assurance view (audit flow redesign)
--
-- REQUEST (2026-11-14, sir) -- docs/audit-flow-redesign.md Phase 4,
-- decision 4: Continuous Assurance covers every scope item -- practice
-- instances directly; assets, departments, locations (branches), vendors,
-- applications and processes through the practice instances they are
-- resolved against in Operationalize (practice_dependency_resolution);
-- asset categories through their assets.
--
-- WHAT THE AUDITOR SEES (My Audits -> Continuous Assurance, under the row)
--   For the execution's scope (frozen, or live = the scope now, branch-
--   narrowed): each scope item -> its practice instances -> their active
--   Execution / Assurance obligations -> the obligation's implementation
--   status and the last task raised for it (number, status, due date).
--   Summary: each obligation counted ONCE (by status, by last task status);
--   detail: an obligation is shown under every item that brings it in.
--   Read-only.
--
-- WHAT THIS DOES
--   sp_org_assurance_execution_live_scope (555) re-issued with @mode:
--   SCOPE (default) -- unchanged output; ASSURANCE -- two result sets
--   (summary, detail). One procedure resolves the items, so Freeze, the
--   scope view and this view never disagree. No schema change.
--
-- DEPENDS ON: 555 (live scope), 140 / 449 (obligations, occurrence tasks).
-- Rollback: 556_continuous_assurance_view_rollback.sql (555 body).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_execution_live_scope','P') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_execution','scope_frozen_at') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_obligation','implementation_status_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_obligation','obligation_type_code') IS NULL
   OR OBJECT_ID('grac_practice.schedule_occurrence_task','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NULL
BEGIN
    PRINT 'ABORT (556): run 555 (and 449) first. Nothing was changed.';
    RAISERROR('556_continuous_assurance_view: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_org_assurance_execution_live_scope (555) + @mode
--    SCOPE (default): the scope items, as 555 returned them.
--    ASSURANCE: the Continuous Assurance view over the same items --
--      result 1: the summary, each obligation counted ONCE;
--      result 2: the detail, scope item -> practice instance ->
--                obligation, with the obligation's status and its last task.
--    The items are the frozen entities, or (live) the audit's scope resolved
--    now in a rolled-back transaction and narrowed to the Branch -- one
--    place, so Freeze, the scope view and this view never disagree.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_live_scope
    @organization_id BIGINT,
    @execution_id    BIGINT,
    @actor           NVARCHAR(100) = 'system',
    @mode            NVARCHAR(20)  = N'SCOPE'      -- 556: SCOPE / ASSURANCE
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL OR @execution_id IS NULL
        THROW 54009, 'organization_id and execution_id are required.', 1;

    DECLARE @def BIGINT, @ver BIGINT, @item BIGINT, @frozen DATETIME2;
    SELECT @def    = e.org_assurance_definition_id,
           @ver    = e.org_assurance_definition_version_id,
           @item   = e.org_assurance_plan_item_id,
           @frozen = e.scope_frozen_at
      FROM grac_practice.org_assurance_execution e
     WHERE e.org_assurance_execution_id = @execution_id
       AND e.organization_id = @organization_id
       AND e.is_active = 1;
    IF @def IS NULL
        THROW 54010, 'Execution not found or not accessible in this organization.', 1;

    DECLARE @ents TABLE (dimension_code NVARCHAR(60) NULL, dimension_name NVARCHAR(160) NULL,
                         entity_id BIGINT NULL, entity_code NVARCHAR(120) NULL, entity_name NVARCHAR(240) NULL);

    IF @frozen IS NOT NULL
        INSERT INTO @ents (dimension_code, dimension_name, entity_id, entity_code, entity_name)
        SELECT ee.dimension_code, ee.dimension_name, ee.entity_id, ee.entity_code, ee.entity_name
          FROM grac_practice.org_assurance_execution_entity ee
         WHERE ee.org_assurance_execution_id = @execution_id
           AND ee.organization_id = @organization_id
           AND ee.is_active = 1;
    ELSE
    BEGIN
        DECLARE @branch BIGINT = (SELECT assigned_branch_id FROM grac_practice.org_assurance_plan_item
                                   WHERE org_assurance_plan_item_id = @item);
        DECLARE @res BIGINT;

        BEGIN TRAN;
        EXEC grac_practice.sp_org_assurance_scope_resolve
             @organization_id    = @organization_id,
             @definition_id      = @def,
             @version_id         = @ver,
             @resolution_purpose = N'PREVIEW',
             @execution_id       = NULL,
             @actor              = @actor,
             @resolution_id_out  = @res OUTPUT;
        IF @branch IS NOT NULL
            EXEC grac_practice.sp_org_assurance_scope_resolution_narrow_location
                 @organization_id = @organization_id,
                 @resolution_id   = @res,
                 @location_id     = @branch;
        INSERT INTO @ents (dimension_code, dimension_name, entity_id, entity_code, entity_name)
        SELECT DISTINCT r.dimension_code, r.dimension_name, r.entity_id, r.entity_code, r.entity_name
          FROM grac_practice.org_assurance_scope_resolution_entity r
         WHERE r.org_assurance_scope_resolution_id = @res;
        ROLLBACK;   -- live: nothing the resolver wrote is kept
    END

    IF ISNULL(@mode, N'SCOPE') <> N'ASSURANCE'
    BEGIN
        SELECT dimension_code AS DimensionCode, dimension_name AS DimensionName,
               entity_id AS EntityId, entity_code AS EntityCode, entity_name AS EntityName
          FROM @ents
         ORDER BY dimension_code, entity_name, entity_code;
        RETURN;
    END

    -- -----------------------------------------------------------------
    -- 556: Continuous Assurance (decision 4, 2026-11-14)
    -- Each scope item -> its practice instances:
    --   PRACTICE_INSTANCE   directly;
    --   ASSET, DEPARTMENT, VENDOR, APPLICATION, PROCESS, BRANCH (Location)
    --                       through practice_dependency_resolution (the
    --                       Operationalize resolution, active rows);
    --   ASSET_CATEGORY      through its assets, then as ASSET.
    -- -> their active Execution / Assurance obligations (the scheduled
    --    ones, 338 / 449) -> implementation status and the last task raised
    --    for the obligation (schedule_occurrence_task -> practice_task).
    -- -----------------------------------------------------------------
    DECLARE @map TABLE (dimension_code NVARCHAR(60) PRIMARY KEY, dependency_type_code NVARCHAR(60) NOT NULL);
    INSERT INTO @map VALUES
        (N'ASSET', N'Asset'), (N'DEPARTMENT', N'Department'), (N'VENDOR', N'Vendor'),
        (N'APPLICATION', N'Application'), (N'PROCESS', N'Process'), (N'BRANCH', N'Location');

    DECLARE @link TABLE (dimension_code NVARCHAR(60) NULL, entity_id BIGINT NULL,
                         practice_instance_id BIGINT NOT NULL, via NVARCHAR(60) NOT NULL);

    -- directly
    INSERT INTO @link (dimension_code, entity_id, practice_instance_id, via)
    SELECT e.dimension_code, e.entity_id, e.entity_id, N'Direct'
      FROM @ents e
     WHERE e.dimension_code = N'PRACTICE_INSTANCE' AND e.entity_id IS NOT NULL;

    -- through the Operationalize resolution
    INSERT INTO @link (dimension_code, entity_id, practice_instance_id, via)
    SELECT DISTINCT e.dimension_code, e.entity_id, r.practice_instance_id, dt.dependency_type_name
      FROM @ents e
      JOIN @map m ON m.dimension_code = e.dimension_code
      JOIN grac_practice.dependency_type_master dt
           ON dt.dependency_type_code = m.dependency_type_code
      JOIN grac_practice.practice_dependency_resolution r
           ON r.dependency_type_id     = dt.dependency_type_id
          AND r.resolved_dependency_id = e.entity_id
          AND r.organization_id        = @organization_id
          AND r.is_active              = 1;

    -- asset category -> its assets -> as ASSET
    INSERT INTO @link (dimension_code, entity_id, practice_instance_id, via)
    SELECT DISTINCT e.dimension_code, e.entity_id, r.practice_instance_id, N'Asset: ' + a.asset_name
      FROM @ents e
      JOIN grac_practice.organization_dependency_asset a
           ON a.asset_category_id = e.entity_id
          AND a.organization_id   = @organization_id
      JOIN grac_practice.dependency_type_master dt
           ON dt.dependency_type_code = N'Asset'
      JOIN grac_practice.practice_dependency_resolution r
           ON r.dependency_type_id     = dt.dependency_type_id
          AND r.resolved_dependency_id = a.asset_id
          AND r.organization_id        = @organization_id
          AND r.is_active              = 1
     WHERE e.dimension_code = N'ASSET_CATEGORY';

    DECLARE @detail TABLE (
        dimension_code NVARCHAR(60) NULL, dimension_name NVARCHAR(160) NULL,
        entity_id BIGINT NULL, entity_code NVARCHAR(120) NULL, entity_name NVARCHAR(240) NULL,
        practice_instance_id BIGINT NULL, instance_code NVARCHAR(100) NULL, instance_name NVARCHAR(300) NULL,
        via NVARCHAR(400) NULL,
        obligation_id BIGINT NULL, obligation_name NVARCHAR(500) NULL, obligation_type NVARCHAR(60) NULL,
        frequency NVARCHAR(120) NULL,
        status_code NVARCHAR(60) NULL, status_name NVARCHAR(100) NULL,
        task_id BIGINT NULL, task_number NVARCHAR(60) NULL, task_status_code NVARCHAR(60) NULL,
        task_status_name NVARCHAR(120) NULL, task_due DATE NULL);

    INSERT INTO @detail
    SELECT e.dimension_code, e.dimension_name, e.entity_id, e.entity_code, e.entity_name,
           pi.practice_instance_id, pi.instance_code, pi.instance_name,
           l.via,
           pio.practice_instance_obligation_id, pio.obligation_name, pio.obligation_type_code,
           CASE WHEN pio.obligation_type_code = N'Assurance' THEN pio.assurance_frequency ELSE pio.execution_frequency END,
           ism.status_code, ism.status_name,
           lt.task_id, CONVERT(NVARCHAR(60), lt.task_number), lt.status_code, lt.status_name, lt.occurrence_date
      FROM @ents e
      LEFT JOIN @link l
             ON l.dimension_code = e.dimension_code AND l.entity_id = e.entity_id
      LEFT JOIN grac_practice.practice_instance pi
             ON pi.practice_instance_id = l.practice_instance_id
            AND pi.organization_id = @organization_id
            AND pi.status = N'Active'
      LEFT JOIN grac_practice.practice_instance_obligation pio
             ON pio.practice_instance_id = pi.practice_instance_id
            AND pio.status = N'Active'
            AND pio.obligation_type_code IN (N'Execution', N'Assurance')
      LEFT JOIN grac_practice.implementation_status_master ism
             ON ism.implementation_status_id = pio.implementation_status_id
      OUTER APPLY (
          SELECT TOP 1 t.task_id, t.task_number, es.status_code, es.status_name, x.occurrence_date
            FROM grac_practice.schedule_occurrence_task x
            JOIN grac_practice.practice_task t ON t.task_id = x.task_id
            LEFT JOIN grac_practice.entity_status_master es
                   ON es.entity_status_id = t.current_status_id
           WHERE x.practice_instance_obligation_id = pio.practice_instance_obligation_id
             AND x.task_id IS NOT NULL
           ORDER BY x.occurrence_date DESC, x.occurrence_task_id DESC) lt;

    -- Result 1: the summary -- every obligation counted once, however many
    -- scope items bring it in.
    ;WITH ob AS (
        SELECT DISTINCT obligation_id, ISNULL(status_name, N'Not set') AS status_name,
               ISNULL(task_status_name, N'No task yet') AS task_status_name
          FROM @detail WHERE obligation_id IS NOT NULL
    )
    SELECT N'Totals' AS SummaryKind, N'Scope items' AS Label,
           (SELECT COUNT(*) FROM @ents) AS ItemCount, 1 AS SortOrder
    UNION ALL SELECT N'Totals', N'Practice instances',
           (SELECT COUNT(DISTINCT practice_instance_id) FROM @detail WHERE practice_instance_id IS NOT NULL), 2
    UNION ALL SELECT N'Totals', N'Obligations', (SELECT COUNT(*) FROM ob), 3
    UNION ALL SELECT N'Totals', N'Scope items with no practice instance',
           (SELECT COUNT(*) FROM @ents e
             WHERE NOT EXISTS (SELECT 1 FROM @detail d
                                WHERE d.dimension_code = e.dimension_code
                                  AND d.entity_id = e.entity_id
                                  AND d.practice_instance_id IS NOT NULL)), 4
    UNION ALL SELECT N'ObligationStatus', status_name, COUNT(*), 10 FROM ob GROUP BY status_name
    UNION ALL SELECT N'LastTaskStatus', task_status_name, COUNT(*), 20 FROM ob GROUP BY task_status_name
    ORDER BY SortOrder, Label;

    -- Result 2: the detail.
    SELECT dimension_code AS DimensionCode, dimension_name AS DimensionName,
           entity_id AS EntityId, entity_code AS EntityCode, entity_name AS EntityName,
           practice_instance_id AS PracticeInstanceId, instance_code AS InstanceCode,
           instance_name AS InstanceName, via AS Via,
           obligation_id AS ObligationId, obligation_name AS ObligationName,
           obligation_type AS ObligationType, frequency AS Frequency,
           status_code AS ObligationStatusCode, status_name AS ObligationStatusName,
           task_id AS LastTaskId, task_number AS LastTaskNumber,
           task_status_code AS LastTaskStatusCode, task_status_name AS LastTaskStatusName,
           task_due AS LastTaskDueDate
      FROM @detail
     ORDER BY dimension_code, entity_name, instance_name, obligation_name;
END
GO

SELECT '556 live scope has ASSURANCE mode' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_execution_live_scope')) LIKE '%ASSURANCE%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
PRINT '556 complete. Restart the Api and publish Web.';
GO
SET NOEXEC OFF;
GO
