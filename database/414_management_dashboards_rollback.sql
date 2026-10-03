-- =====================================================================
-- 414 Management dashboards -- ROLLBACK
--
-- Puts the five list procedures back exactly as 414 found them (379,
-- 253, 193, 120 and 116a bodies; comment characters written as ASCII),
-- then drops what 414 created and clears the three parent urls. Read
-- objects and menu urls only: no data is touched. Also revert
-- 274_menu_master_seed.sql's three parent rows to url NULL.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- sp_gap_centre_list (as before 414)
CREATE OR ALTER PROCEDURE grac_practice.sp_gap_centre_list
    @organization_id     BIGINT        = NULL,
    @source_module_code  NVARCHAR(30)  = NULL,
    @status_code         NVARCHAR(30)  = NULL,
    @search              NVARCHAR(200) = NULL,
    @observation_id      BIGINT        = NULL,
    @page                INT           = 1,
    @page_size           INT           = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @search = N'' SET @search = NULL;
    IF @source_module_code = N'' SET @source_module_code = NULL;
    IF @status_code = N'' SET @status_code = NULL;

    DECLARE @results TABLE (
        RowKey             NVARCHAR(40)  NOT NULL,
        SourceModuleCode   NVARCHAR(30)  NOT NULL,
        CustomGapId        BIGINT        NULL,
        PracticeGapId      BIGINT        NULL,
        PracticeInstanceId BIGINT        NULL,
        IsMaterialized     BIT           NOT NULL,
        Title              NVARCHAR(400) NULL,
        Context            NVARCHAR(800) NULL,
        StatusText         NVARCHAR(100) NULL,
        RawStatusCode      NVARCHAR(30)  NULL,
        LifecycleStateCode NVARCHAR(60)  NULL,
        SeverityText       NVARCHAR(200) NULL,
        OwnerText          NVARCHAR(300) NULL,
        DueDate            DATE          NULL,
        OpenedDt           DATETIME2(3)  NULL,
        LinkedCount        INT           NOT NULL,
        InstanceCode       NVARCHAR(100) NULL,
        InstanceName       NVARCHAR(300) NULL,
        ExistingTaskCount  INT           NOT NULL,
        UrgencyRank        INT           NOT NULL DEFAULT 3,
        SortBucket         INT           NOT NULL,
        -- Migration 371. See this migration's own header for what each
        -- one means and where it is read from -- sort-irrelevant, plain
        -- display columns, appended after every pre-existing column so
        -- no ordinal-based reader elsewhere in this proc or its caller
        -- shifts.
        PracticeInstanceStatusText NVARCHAR(30)  NULL,
        TaskStatusText             NVARCHAR(30)  NULL,
        RiskStatusText             NVARCHAR(100) NULL,
        ExceptionStatusText        NVARCHAR(30)  NULL
    );

    -- ---- Arm 1: custom_gap, every source module ---------------------
    INSERT INTO @results
        (RowKey, SourceModuleCode, CustomGapId, PracticeGapId, PracticeInstanceId,
         IsMaterialized, Title, Context, StatusText, RawStatusCode, LifecycleStateCode,
         SeverityText, OwnerText,
         DueDate, OpenedDt, LinkedCount,
         InstanceCode, InstanceName, ExistingTaskCount, SortBucket,
         PracticeInstanceStatusText, TaskStatusText, RiskStatusText, ExceptionStatusText)
    SELECT
        N'cg' + CAST(g.custom_gap_id AS NVARCHAR(20)),
        g.gap_source_module_code,
        g.custom_gap_id,
        NULL,
        CASE WHEN g.source_reference_type = N'PracticeInstance'
             THEN g.source_reference_id ELSE NULL END,
        1,
        g.title,
        NULLIF(LTRIM(RTRIM(CONCAT(
            ISNULL(g.execution_name, N''),
            CASE WHEN g.execution_name IS NOT NULL AND g.entity_name IS NOT NULL
                 THEN N' / ' ELSE N'' END,
            ISNULL(g.entity_name, N'')))), N''),
        -- 379: a Closed gap shows Closed, full stop -- its lifecycle
        -- stage (almost always Delegated/"Analysed", since that is the
        -- normal path into Closed) never gets a say once the record's
        -- own status says Closed. Every other status keeps the exact
        -- COALESCE this ELSE branch always was.
        CASE WHEN g.status = N'Closed' THEN N'Closed'
             ELSE COALESCE(s.state_name, g.status) END,
        g.status,
        s.state_code,
        COALESCE(g.severity_name, g.severity_code, g.priority),
        g.owner_display_name,
        CAST(COALESCE(g.due_date, g.target_resolution_date) AS DATE),
        g.opened_dt,
        (SELECT COUNT(*) FROM grac_practice.custom_gap_observation j
          WHERE j.custom_gap_id = g.custom_gap_id AND j.is_active = 1),
        NULL, NULL,
        (SELECT COUNT(*)
           FROM grac_practice.practice_task t
          WHERE t.subject_entity_type = N'CustomGap'
            AND t.subject_entity_id   = g.custom_gap_id
            AND t.closed_at IS NULL),
        1,
        -- Practice Instance Status: only an Implementation gap sourced
        -- from a Practice Instance has one. practice_gap.gap_status is
        -- already "Closed once every Obligation on this instance is
        -- Implemented, Open otherwise" (367) -- re-labelled for this
        -- column so it is not confused with the gap's OWN Open/Closed
        -- bookkeeping (custom_gap.status / RawStatusCode above).
        CASE WHEN g.source_reference_type = N'PracticeInstance' AND g.source_reference_id IS NOT NULL
             THEN (SELECT TOP 1 CASE pg1.gap_status
                                      WHEN N'Closed' THEN N'Implemented'
                                      WHEN N'Open'   THEN N'Not Implemented'
                                      ELSE NULL END
                     FROM grac_practice.practice_gap pg1
                    WHERE pg1.practice_instance_id = g.source_reference_id)
             ELSE NULL END,
        -- Task Status: aggregated across every Task linked to this gap
        -- (subject_entity_type = 'CustomGap'), not the individual Task's
        -- own status text. entity_status_master.is_terminal is the
        -- existing Closed/Cancelled flag for entity_type 'Task' (035).
        (SELECT CASE
                    WHEN COUNT(*) = 0 THEN NULL
                    WHEN SUM(CASE WHEN ts.is_terminal = 1 THEN 0 ELSE 1 END) = 0 THEN N'Completed'
                    ELSE N'Pending'
                END
           FROM grac_practice.practice_task t2
           JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = t2.current_status_id
          WHERE t2.subject_entity_type = N'CustomGap'
            AND t2.subject_entity_id   = g.custom_gap_id),
        -- Risk Status: most recent Risk Candidate linked to this gap: its
        -- REGISTERED risk's status_code once registered (same precedence
        -- gap-view.js's buildRiskCard already applies), else the
        -- candidate's own status_code.
        (SELECT TOP 1 COALESCE(
                          (SELECT rr.status_code
                             FROM grac_practice.risk_register rr
                            WHERE rr.risk_register_id = rc.registered_risk_id),
                          rc.status_code)
           FROM grac_practice.risk_candidate rc
          WHERE rc.custom_gap_id = g.custom_gap_id
          ORDER BY rc.risk_candidate_id DESC),
        -- Exception Status: most recent Exception linked to this gap,
        -- its own status_code verbatim.
        (SELECT TOP 1 er.status_code
           FROM grac_practice.exception_request er
          WHERE er.custom_gap_id = g.custom_gap_id
          ORDER BY er.exception_request_id DESC)
    FROM   grac_practice.custom_gap g
    LEFT   JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
    WHERE (@organization_id IS NULL    OR g.organization_id        = @organization_id)
      AND (@source_module_code IS NULL OR g.gap_source_module_code = @source_module_code)
      AND (@status_code IS NULL        OR g.status                 = @status_code)
      AND (@observation_id IS NULL OR EXISTS (
                SELECT 1 FROM grac_practice.custom_gap_observation j
                 WHERE j.custom_gap_id                = g.custom_gap_id
                   AND j.org_assurance_observation_id = @observation_id
                   AND j.is_active                    = 1))
      AND (@search IS NULL
           OR g.title             LIKE N'%' + @search + N'%'
           OR g.description       LIKE N'%' + @search + N'%'
           OR g.execution_name    LIKE N'%' + @search + N'%'
           OR g.entity_name       LIKE N'%' + @search + N'%'
           OR g.observation_title LIKE N'%' + @search + N'%');

    -- ---- Arm 2: practice_gap not yet materialized -------------------
    IF (@source_module_code IS NULL OR @source_module_code = N'Implementation')
       AND @observation_id IS NULL
    INSERT INTO @results
        (RowKey, SourceModuleCode, CustomGapId, PracticeGapId, PracticeInstanceId,
         IsMaterialized, Title, Context, StatusText, RawStatusCode, LifecycleStateCode,
         SeverityText, OwnerText,
         DueDate, OpenedDt, LinkedCount,
         InstanceCode, InstanceName, ExistingTaskCount, UrgencyRank, SortBucket,
         PracticeInstanceStatusText, TaskStatusText, RiskStatusText, ExceptionStatusText)
    SELECT
        N'pg' + CAST(pg.practice_gap_id AS NVARCHAR(20)),
        N'Implementation',
        NULL,
        pg.practice_gap_id,
        pi.practice_instance_id,
        0,
        COALESCE(pi.instance_name, pi.instance_code),
        NULLIF(LTRIM(RTRIM(CONCAT(
            ISNULL(pi.instance_code, N''),
            CASE WHEN pi.instance_code IS NOT NULL AND p.practice_name IS NOT NULL
                 THEN N' / ' ELSE N'' END,
            ISNULL(p.practice_name, N'')))), N''),
        N'New',
        NULL,
        NULL,
        pi.criticality,
        pi.primary_owner,
        NULL,
        pg.opened_dt,
        (SELECT COUNT(*) FROM grac_practice.practice_gap_obligation pgo
          WHERE pgo.practice_gap_id = pg.practice_gap_id
            AND pgo.status          = N'Active'),
        pi.instance_code,
        pi.instance_name,
        (SELECT COUNT(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE t.subject_entity_type = N'PracticeInstance'
            AND t.subject_entity_id   = pi.practice_instance_id
            AND tt.type_code          = N'Implementation'
            AND t.closed_at IS NULL),
        (SELECT CASE MIN(CASE pgo.logged_status_code
                              WHEN N'Not Implemented'       THEN 1
                              WHEN N'Partially Implemented' THEN 2
                              ELSE 3 END)
                     WHEN 1 THEN 1
                     WHEN 2 THEN 2
                     ELSE 3
                 END
           FROM  grac_practice.practice_gap_obligation pgo
           WHERE pgo.practice_gap_id = pg.practice_gap_id
             AND pgo.status          = N'Active'),
        0,
        -- Practice Instance Status: pg IS this instance's practice_gap
        -- row already (that is what arm 2 is) -- same Closed/Open
        -- re-label as arm 1, no extra lookup needed. Arm 2's own WHERE
        -- below only ever selects pg.gap_status = 'Open' rows (a
        -- materialized-but-since-fully-resolved gap has a custom_gap row
        -- once analysed, or simply no un-materialized row to show once
        -- Closed with nothing to analyse), so this reads N'Not
        -- Implemented' for every arm-2 row today -- computed the same
        -- way as arm 1 rather than hard-coded, so the two arms cannot
        -- silently drift from each other if that WHERE clause ever
        -- changes.
        CASE pg.gap_status WHEN N'Closed' THEN N'Implemented'
                            WHEN N'Open'   THEN N'Not Implemented'
                            ELSE NULL END,
        -- Task / Risk / Exception Status: all three are linked via
        -- custom_gap_id (Task) or custom_gap_id (Risk/Exception), and an
        -- un-materialized practice_gap row has no custom_gap row yet --
        -- structurally nothing to link to, not merely unqueried.
        NULL, NULL, NULL
    FROM   grac_practice.practice_gap pg
    JOIN   grac_practice.practice_instance pi
           ON pi.practice_instance_id = pg.practice_instance_id
    LEFT   JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
    WHERE (@organization_id IS NULL OR pi.organization_id = @organization_id)
      AND  pg.gap_status = N'Open'
      AND  NOT EXISTS (
               SELECT 1
                 FROM grac_practice.custom_gap cg
                WHERE cg.source_reference_type = N'PracticeInstance'
                  AND cg.source_reference_id   = pg.practice_instance_id
                  AND cg.organization_id       = pi.organization_id)
      AND (@search IS NULL
           OR pi.instance_code LIKE N'%' + @search + N'%'
           OR pi.instance_name LIKE N'%' + @search + N'%'
           OR p.practice_name  LIKE N'%' + @search + N'%')
      AND (@status_code IS NULL
           OR @status_code = N'Open'
           OR EXISTS (SELECT 1
                        FROM grac_practice.practice_gap_obligation pgo
                       WHERE pgo.practice_gap_id    = pg.practice_gap_id
                         AND pgo.status             = N'Active'
                         AND pgo.logged_status_code = @status_code));

    -- Result set 1 -- paging metadata, same contract as every other list.
    SELECT COUNT_BIG(*) AS TotalCount,
           @page        AS PageNumber,
           @page_size   AS PageSize
    FROM   @results;

    -- Result set 2 -- the page.
    SELECT RowKey, SourceModuleCode, CustomGapId, PracticeGapId,
           PracticeInstanceId, IsMaterialized, Title, Context,
           StatusText, RawStatusCode, LifecycleStateCode,
           SeverityText, OwnerText, DueDate, OpenedDt,
           LinkedCount, InstanceCode, InstanceName, ExistingTaskCount,
           PracticeInstanceStatusText, TaskStatusText, RiskStatusText, ExceptionStatusText
    FROM   @results
    ORDER  BY SortBucket,
              UrgencyRank,
              OpenedDt DESC,
              RowKey
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;
END
GO

-- sp_task_list (as before 414)
CREATE OR ALTER PROCEDURE grac_practice.sp_task_list
    @organization_id         BIGINT        = NULL,
    @assigned_to_employee_id BIGINT        = NULL,
    @task_type_code          NVARCHAR(60)  = NULL,
    @status_code             NVARCHAR(60)  = NULL,   -- 'OpenSet' for non-terminal, else specific
    @overdue_only            BIT           = 0,
    @search                  NVARCHAR(200) = NULL,
    @page                    INT           = 1,
    @page_size               INT           = 25,
    @parent_task_id          BIGINT        = NULL,   -- children of one parent
    @include_children        BIT           = 0,
    @sla_status_code         NVARCHAR(30)  = NULL,   -- OnTrack/DueSoon/DueToday/Breached/Extended/Completed
    @source_type_code        NVARCHAR(40)  = NULL,
    @source_record_id        BIGINT        = NULL,
    @priority                NVARCHAR(30)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    -- Asking for one parent's children implies you want children.
    IF @parent_task_id IS NOT NULL SET @include_children = 1;

    DECLARE @filtered TABLE (task_id BIGINT PRIMARY KEY, sort_due DATETIME2);

    INSERT INTO @filtered (task_id, sort_due)
    SELECT v.task_id, v.sla_due_at
      FROM grac_practice.vw_pm_practice_task v
     WHERE (@organization_id IS NULL         OR v.organization_id = @organization_id)
       AND (@assigned_to_employee_id IS NULL OR v.assigned_to_employee_id = @assigned_to_employee_id)
       -- Migration 253: the Custom Tasks tab is also the home for gap
       -- remediation work, which opens as 'Rectification'.
       AND (@task_type_code IS NULL
            OR v.task_type_code = @task_type_code
            OR (@task_type_code = N'Custom' AND v.task_type_code = N'Rectification'))
       AND (
             @status_code IS NULL
          OR (@status_code = N'OpenSet' AND v.current_status_is_terminal = 0)
          OR v.current_status_code = @status_code
           )
       AND (@overdue_only = 0 OR v.is_overdue = 1)
       AND (@priority IS NULL                OR v.priority = @priority)
       AND (@sla_status_code IS NULL         OR v.sla_status_code = @sla_status_code)
       AND (@source_type_code IS NULL        OR v.source_type_code = @source_type_code)
       AND (@source_record_id IS NULL        OR v.source_record_id = @source_record_id)
       AND (@parent_task_id IS NULL          OR v.parent_task_id = @parent_task_id)
       AND (@include_children = 1            OR v.parent_task_id IS NULL)
       AND (@search IS NULL
            OR v.subject_title LIKE N'%' + @search + N'%'
            OR v.subject_description LIKE N'%' + @search + N'%'
            OR v.task_number LIKE N'%' + @search + N'%');

    -- Result-set #1 -- count + paging metadata (unchanged shape)
    SELECT COUNT_BIG(*) AS TotalCount,
           @page        AS PageNumber,
           @page_size   AS PageSize
      FROM @filtered;

    -- Result-set #2 -- the current page
    SELECT v.*
      FROM @filtered f
      JOIN grac_practice.vw_pm_practice_task v ON v.task_id = f.task_id
     ORDER BY CASE WHEN f.sort_due IS NULL THEN 1 ELSE 0 END,
              f.sort_due ASC,
              f.task_id DESC
     OFFSET (@page - 1) * @page_size ROWS
     FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- sp_exception_request_list (as before 414)
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_list
    @organization_id   BIGINT,
    @status_code       NVARCHAR(30) = NULL,
    @request_type_code NVARCHAR(30) = NULL,
    @page_number       INT = 1,
    @page_size         INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 55210, 'sp_exception_request_list: organization_id is required.', 1;
    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    SELECT
        r.exception_request_id  AS ExceptionRequestId,
        r.organization_id       AS OrganizationId,
        r.custom_gap_id         AS CustomGapId,
        g.title                 AS GapTitle,
        r.task_id               AS TaskId,
        t.task_number           AS TaskNumber,
        t.subject_title         AS TaskTitle,
        r.request_title         AS RequestTitle,
        et.exception_type_name  AS ExceptionTypeName,
        r.status_code           AS StatusCode,
        r.request_type_code     AS RequestTypeCode,
        r.sla_days_original     AS SlaDaysOriginal,
        r.sla_days_requested    AS SlaDaysRequested,
        r.due_at_original       AS DueAtOriginal,
        r.due_at_requested      AS DueAtRequested,
        r.priority_original     AS PriorityOriginal,
        r.priority_requested    AS PriorityRequested,
        r.requested_dt          AS RequestedOn,
        rq.employee_name        AS RequestedByName,
        r.approved_dt           AS ApprovedOn,
        ap.employee_name        AS ApprovedByName,
        r.effective_from        AS EffectiveFrom,
        r.effective_until       AS EffectiveUntil,
        r.rejected_dt           AS RejectedOn,
        rj.employee_name        AS RejectedByName,
        (SELECT COUNT(*) FROM grac_practice.exception_request_attachment a
          WHERE a.exception_request_id = r.exception_request_id) AS AttachmentCount,
        COUNT(*) OVER () AS TotalRows
      FROM grac_practice.exception_request r
 LEFT JOIN grac_practice.custom_gap                g  ON g.custom_gap_id     = r.custom_gap_id
 LEFT JOIN grac_practice.practice_task             t  ON t.task_id           = r.task_id
 LEFT JOIN grac_practice.exception_type_master     et ON et.exception_type_id = r.exception_type_id
 LEFT JOIN grac_practice.organization_employee     rq ON rq.employee_id       = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee     ap ON ap.employee_id       = r.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee     rj ON rj.employee_id       = r.rejected_by_employee_id
     WHERE r.organization_id = @organization_id
       AND (@status_code IS NULL OR r.status_code = @status_code)
       AND (@request_type_code IS NULL OR r.request_type_code = @request_type_code)
     ORDER BY r.requested_dt DESC, r.exception_request_id DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- sp_org_assurance_execution_list (as before 414)
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_list
    @organization_id BIGINT,
    @definition_id   BIGINT       = NULL,
    @status_code     NVARCHAR(60) = NULL,
    @origin_type     NVARCHAR(20) = NULL,
    @search          NVARCHAR(200) = NULL,
    @page            INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 54008, 'organization_id is required.', 1;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    DECLARE @offset INT = (@page - 1) * @page_size;

    ;WITH base AS (
        SELECT e.org_assurance_execution_id,
               e.organization_id,
               e.org_assurance_definition_id,
               e.org_assurance_definition_version_id,
               e.definition_code,
               e.definition_name,
               e.version_number,
               e.execution_code,
               e.execution_name,
               s.status_code AS status_code,
               s.status_name AS status_name,
               s.is_terminal AS status_is_terminal,
               e.origin_type,
               e.org_assurance_plan_id,
               e.org_assurance_plan_item_id,
               e.org_assurance_trigger_config_id,
               e.org_assurance_scope_resolution_id,
               e.owner_role_id,          -- 120
               e.owner_role_name,        -- 120
               e.owner_employee_id,
               e.owner_display_name,
               e.planned_start_dt,
               e.planned_end_dt,
               e.actual_start_dt,
               e.actual_end_dt,
               e.total_entity_count,
               e.completed_entity_count,
               e.entered_dt,
               e.updated_dt
        FROM grac_practice.org_assurance_execution e
        JOIN grac_practice.org_assurance_execution_status_master s
             ON s.org_assurance_execution_status_id = e.execution_status_id
        WHERE e.organization_id = @organization_id
          AND e.is_active = 1
          AND (@definition_id IS NULL OR e.org_assurance_definition_id = @definition_id)
          AND (@status_code   IS NULL OR s.status_code = @status_code)
          AND (@origin_type   IS NULL OR e.origin_type = @origin_type)
          AND (@search IS NULL OR @search = ''
               OR e.execution_code LIKE N'%' + @search + N'%'
               OR e.execution_name LIKE N'%' + @search + N'%'
               OR e.definition_code LIKE N'%' + @search + N'%'
               OR e.definition_name LIKE N'%' + @search + N'%')
    )
    SELECT CAST(COUNT_BIG(1) AS BIGINT) AS TotalCount,
           CAST(@page      AS INT)      AS PageNumber,
           CAST(@page_size AS INT)      AS PageSize
    FROM base;

    ;WITH base AS (
        SELECT e.org_assurance_execution_id,
               e.organization_id,
               e.org_assurance_definition_id,
               e.org_assurance_definition_version_id,
               e.definition_code,
               e.definition_name,
               e.version_number,
               e.execution_code,
               e.execution_name,
               s.status_code AS status_code,
               s.status_name AS status_name,
               s.is_terminal AS status_is_terminal,
               e.origin_type,
               e.org_assurance_plan_id,
               e.org_assurance_plan_item_id,
               e.org_assurance_trigger_config_id,
               e.org_assurance_scope_resolution_id,
               e.owner_role_id,          -- 120
               e.owner_role_name,        -- 120
               e.owner_employee_id,
               e.owner_display_name,
               e.planned_start_dt,
               e.planned_end_dt,
               e.actual_start_dt,
               e.actual_end_dt,
               e.total_entity_count,
               e.completed_entity_count,
               e.entered_dt,
               e.updated_dt
        FROM grac_practice.org_assurance_execution e
        JOIN grac_practice.org_assurance_execution_status_master s
             ON s.org_assurance_execution_status_id = e.execution_status_id
        WHERE e.organization_id = @organization_id
          AND e.is_active = 1
          AND (@definition_id IS NULL OR e.org_assurance_definition_id = @definition_id)
          AND (@status_code   IS NULL OR s.status_code = @status_code)
          AND (@origin_type   IS NULL OR e.origin_type = @origin_type)
          AND (@search IS NULL OR @search = ''
               OR e.execution_code LIKE N'%' + @search + N'%'
               OR e.execution_name LIKE N'%' + @search + N'%'
               OR e.definition_code LIKE N'%' + @search + N'%'
               OR e.definition_name LIKE N'%' + @search + N'%')
    )
    SELECT org_assurance_execution_id           AS ExecutionId,
           organization_id                       AS OrganizationId,
           org_assurance_definition_id           AS DefinitionId,
           org_assurance_definition_version_id   AS DefinitionVersionId,
           definition_code                       AS DefinitionCode,
           definition_name                       AS DefinitionName,
           version_number                        AS VersionNumber,
           execution_code                        AS ExecutionCode,
           execution_name                        AS ExecutionName,
           status_code                           AS StatusCode,
           status_name                           AS StatusName,
           status_is_terminal                    AS StatusIsTerminal,
           origin_type                           AS OriginType,
           org_assurance_plan_id                 AS PlanId,
           org_assurance_plan_item_id            AS PlanItemId,
           org_assurance_trigger_config_id       AS TriggerConfigId,
           org_assurance_scope_resolution_id     AS ScopeResolutionId,
           owner_role_id                         AS OwnerRoleId,        -- 120
           owner_role_name                       AS OwnerRoleName,      -- 120
           owner_employee_id                     AS OwnerEmployeeId,
           owner_display_name                    AS OwnerDisplayName,
           planned_start_dt                      AS PlannedStartDt,
           planned_end_dt                        AS PlannedEndDt,
           actual_start_dt                       AS ActualStartDt,
           actual_end_dt                         AS ActualEndDt,
           total_entity_count                    AS TotalEntityCount,
           completed_entity_count                AS CompletedEntityCount,
           entered_dt                            AS EnteredDt,
           updated_dt                            AS UpdatedDt
    FROM base
    ORDER BY entered_dt DESC, org_assurance_execution_id DESC
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- sp_org_assurance_observation_list (as before 414)
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_list
    @organization_id BIGINT,
    @execution_id    BIGINT       = NULL,
    @entity_id       BIGINT       = NULL,
    @status_code     NVARCHAR(60) = NULL,
    @severity_code   NVARCHAR(30) = NULL,
    @observation_type NVARCHAR(30) = NULL,
    @search          NVARCHAR(200) = NULL,
    @page            INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 54100, 'organization_id is required.', 1;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    DECLARE @offset INT = (@page - 1) * @page_size;

    ;WITH base AS (
        SELECT o.org_assurance_observation_id,
               o.organization_id,
               o.org_assurance_execution_id,
               o.org_assurance_execution_entity_id,
               o.execution_code,
               o.execution_name,
               o.entity_dimension_code,
               o.entity_dimension_name,
               o.entity_code,
               o.entity_name,
               o.observation_code,
               o.observation_title,
               o.observation_type,
               o.severity_code,
               o.severity_name,
               st.status_code AS status_code,
               st.status_name AS status_name,
               st.is_terminal AS status_is_terminal,
               o.assigned_owner_employee_id,
               o.assigned_owner_display_name,
               o.assigned_owner_role_id,
               o.assigned_owner_role_name,
               o.assigned_reviewer_employee_id,
               o.assigned_reviewer_display_name,
               o.assigned_reviewer_role_id,
               o.assigned_reviewer_role_name,
               o.observed_dt,
               o.due_date,
               o.gap_id,
               o.entered_dt,
               o.updated_dt,
               (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_observation_evidence e
                 WHERE e.org_assurance_observation_id = o.org_assurance_observation_id
                   AND e.is_active = 1) AS evidence_count
        FROM grac_practice.org_assurance_observation o
        JOIN grac_practice.org_assurance_observation_status_master st
             ON st.org_assurance_observation_status_id = o.observation_status_id
        WHERE o.organization_id = @organization_id
          AND o.is_active = 1
          AND (@execution_id  IS NULL OR o.org_assurance_execution_id        = @execution_id)
          AND (@entity_id     IS NULL OR o.org_assurance_execution_entity_id = @entity_id)
          AND (@status_code   IS NULL OR st.status_code   = @status_code)
          AND (@severity_code IS NULL OR o.severity_code  = @severity_code)
          AND (@observation_type IS NULL OR o.observation_type = @observation_type)
          AND (@search IS NULL OR @search = ''
               OR o.observation_title LIKE N'%' + @search + N'%'
               OR o.observation_code  LIKE N'%' + @search + N'%'
               OR o.execution_name    LIKE N'%' + @search + N'%'
               OR o.entity_name       LIKE N'%' + @search + N'%')
    )
    SELECT CAST(COUNT_BIG(1) AS BIGINT) AS TotalCount,
           CAST(@page      AS INT)      AS PageNumber,
           CAST(@page_size AS INT)      AS PageSize
    FROM base;

    ;WITH base AS (
        SELECT o.org_assurance_observation_id,
               o.organization_id,
               o.org_assurance_execution_id,
               o.org_assurance_execution_entity_id,
               o.execution_code,
               o.execution_name,
               o.entity_dimension_code,
               o.entity_dimension_name,
               o.entity_code,
               o.entity_name,
               o.observation_code,
               o.observation_title,
               o.observation_type,
               o.severity_code,
               o.severity_name,
               st.status_code AS status_code,
               st.status_name AS status_name,
               st.is_terminal AS status_is_terminal,
               o.assigned_owner_employee_id,
               o.assigned_owner_display_name,
               o.assigned_owner_role_id,
               o.assigned_owner_role_name,
               o.assigned_reviewer_employee_id,
               o.assigned_reviewer_display_name,
               o.assigned_reviewer_role_id,
               o.assigned_reviewer_role_name,
               o.observed_dt,
               o.due_date,
               o.gap_id,
               o.entered_dt,
               o.updated_dt,
               (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_observation_evidence e
                 WHERE e.org_assurance_observation_id = o.org_assurance_observation_id
                   AND e.is_active = 1) AS evidence_count
        FROM grac_practice.org_assurance_observation o
        JOIN grac_practice.org_assurance_observation_status_master st
             ON st.org_assurance_observation_status_id = o.observation_status_id
        WHERE o.organization_id = @organization_id
          AND o.is_active = 1
          AND (@execution_id  IS NULL OR o.org_assurance_execution_id        = @execution_id)
          AND (@entity_id     IS NULL OR o.org_assurance_execution_entity_id = @entity_id)
          AND (@status_code   IS NULL OR st.status_code   = @status_code)
          AND (@severity_code IS NULL OR o.severity_code  = @severity_code)
          AND (@observation_type IS NULL OR o.observation_type = @observation_type)
          AND (@search IS NULL OR @search = ''
               OR o.observation_title LIKE N'%' + @search + N'%'
               OR o.observation_code  LIKE N'%' + @search + N'%'
               OR o.execution_name    LIKE N'%' + @search + N'%'
               OR o.entity_name       LIKE N'%' + @search + N'%')
    )
    SELECT org_assurance_observation_id  AS ObservationId,
           organization_id                AS OrganizationId,
           org_assurance_execution_id     AS ExecutionId,
           org_assurance_execution_entity_id AS EntityId,
           execution_code                 AS ExecutionCode,
           execution_name                 AS ExecutionName,
           entity_dimension_code          AS EntityDimensionCode,
           entity_dimension_name          AS EntityDimensionName,
           entity_code                    AS EntityCode,
           entity_name                    AS EntityName,
           observation_code               AS ObservationCode,
           observation_title              AS ObservationTitle,
           observation_type               AS ObservationType,
           severity_code                  AS SeverityCode,
           severity_name                  AS SeverityName,
           status_code                    AS StatusCode,
           status_name                    AS StatusName,
           status_is_terminal             AS StatusIsTerminal,
           assigned_owner_display_name    AS OwnerDisplayName,
           assigned_owner_role_id         AS OwnerRoleId,
           assigned_owner_role_name       AS OwnerRoleName,
           assigned_reviewer_display_name AS ReviewerDisplayName,
           assigned_reviewer_role_id      AS ReviewerRoleId,
           assigned_reviewer_role_name    AS ReviewerRoleName,
           observed_dt                    AS ObservedDt,
           due_date                       AS DueDate,
           gap_id                         AS GapId,
           evidence_count                 AS EvidenceCount,
           entered_dt                     AS EnteredDt,
           updated_dt                     AS UpdatedDt
    FROM base
    ORDER BY observed_dt DESC, org_assurance_observation_id DESC
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

IF OBJECT_ID('grac_practice.sp_dashboard_issues_actions','P')  IS NOT NULL DROP PROCEDURE grac_practice.sp_dashboard_issues_actions;
IF OBJECT_ID('grac_practice.sp_dashboard_audit_assurance','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_dashboard_audit_assurance;
IF OBJECT_ID('grac_practice.sp_dashboard_governance','P')      IS NOT NULL DROP PROCEDURE grac_practice.sp_dashboard_governance;
IF OBJECT_ID('grac_practice.fn_pm_ageing_band')                IS NOT NULL DROP FUNCTION  grac_practice.fn_pm_ageing_band;
IF OBJECT_ID('grac_practice.fn_pm_gap_centre_rows')            IS NOT NULL DROP FUNCTION  grac_practice.fn_pm_gap_centre_rows;
IF OBJECT_ID('grac_practice.vw_pm_exception_request_state','V')         IS NOT NULL DROP VIEW grac_practice.vw_pm_exception_request_state;
IF OBJECT_ID('grac_practice.vw_pm_org_assurance_execution_state','V')   IS NOT NULL DROP VIEW grac_practice.vw_pm_org_assurance_execution_state;
IF OBJECT_ID('grac_practice.vw_pm_org_assurance_observation_state','V') IS NOT NULL DROP VIEW grac_practice.vw_pm_org_assurance_observation_state;
GO

UPDATE grac_practice.menu_master
   SET menu_url   = NULL,
       updated_by = N'rollback-414',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'nav-governance', N'nav-oversight', N'nav-assurance')
   AND menu_url IS NOT NULL;
GO

SELECT '414-rollback objects removed' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.fn_pm_gap_centre_rows') IS NULL
             AND OBJECT_ID('grac_practice.sp_dashboard_issues_actions','P') IS NULL
             AND NOT EXISTS (SELECT 1 FROM sys.parameters
                              WHERE object_id = OBJECT_ID('grac_practice.sp_task_list') AND name = '@no_owner')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO

PRINT '414 rolled back.';
GO

SET NOEXEC OFF;
GO
