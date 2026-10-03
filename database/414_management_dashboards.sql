-- =====================================================================
-- 414 Management dashboards: Governance, Issues & Actions, Audit &
--     Assurance (Risk Management is 413)
--
-- WHAT AND WHY
-- ------------
-- Each major parent menu opens a management dashboard as its landing
-- page. The child menus, their pages and routes are unchanged; the
-- dashboard drills into those same pages with their own filters.
--
--   Governance          nav-governance -> Practice/Index/governance-dashboard
--   Issues & Actions    nav-oversight  -> Practice/Index/issues-actions-dashboard
--   Audit & Assurance   nav-assurance  -> Practice/Index/audit-assurance-dashboard
--
-- Every figure is computed server-side, in one call per dashboard, from
-- the entity's own status master and date columns. Nothing below invents
-- a status; where a module has no date to age or overdue against
-- (Governance), no ageing is produced.
--
-- ONE DEFINITION PER BUCKET
-- -------------------------
-- A tile and the list it opens must agree, so each dashboard bucket is
-- defined once and read by BOTH the dashboard and the list's drill-down:
--
--   fn_pm_gap_centre_rows                 Gap Register rows (the rows 379
--                                         built inline, now one function)
--   vw_pm_practice_task (existing)        tasks: is_terminal / is_overdue
--   vw_pm_exception_request_state         exceptions: open / lapsed
--   vw_pm_org_assurance_execution_state   audits: stage / overdue / upcoming
--   vw_pm_org_assurance_observation_state findings: stage / overdue
--   fn_pm_ageing_band                     214's five ageing bands
--
-- CONTENTS
--   1. fn_pm_gap_centre_rows
--   2. sp_gap_centre_list                (379) rows from 1 + drill filters
--   3. state views (exceptions, audit executions, audit observations)
--   4. drill filters on the existing lists (CREATE OR ALTER of the latest
--      bodies; only "414" lines are new; every new parameter defaults to
--      NULL, so existing callers get exactly the rows they got before):
--        sp_task_list                      (253) @no_owner, age band
--        sp_exception_request_list         (193) @drill_code, age band
--        sp_org_assurance_execution_list   (120) @drill_code
--        sp_org_assurance_observation_list (116a) @drill_code, age band
--   5. fn_pm_ageing_band
--   6. sp_dashboard_issues_actions, sp_dashboard_audit_assurance,
--      sp_dashboard_governance -- four result sets each (KPIs, ageing,
--      distributions, lists), documented at section 6.
--   7. menu_master: the three parents get their dashboard url (274
--      snapshot updated to match).
--
-- Non-ASCII characters in re-issued COMMENTS are written as ASCII.
-- Re-runnable. ASCII-only. Error codes 57310-57312.
-- Depends on: 101, 116a, 120, 193, 253, 272, 326, 379, 394.
-- Rollback: 414_management_dashboards_rollback.sql
-- API: deploy with the matching Api build. The Api sends each new
--      parameter only when the procedure declares it (ProcParameterProbe),
--      so either can go first.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- =====================================================================
-- Prerequisites: every object and column the new and re-issued bodies
-- read.
-- =====================================================================
IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
   OR OBJECT_ID('grac_practice.gap_lifecycle_state_master','U') IS NULL
   OR OBJECT_ID('grac_practice.custom_gap_observation','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_gap','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_gap_obligation','U') IS NULL
   OR OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NULL
   OR OBJECT_ID('grac_practice.exception_request','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_execution','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_observation','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_observation_severity_master','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_plan','U') IS NULL
   OR OBJECT_ID('grac_practice.implementation_status_master','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_gap_centre_list','P') IS NULL
BEGIN
    RAISERROR('414: prerequisites missing. Run 098-102, 109-116a, 120, 156, 193, 245, 253, 326 and 379 first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.gap_lifecycle_state_master','is_valid_terminal') IS NULL
   OR COL_LENGTH('grac_practice.custom_gap','owner_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.custom_gap','opened_dt') IS NULL
   OR COL_LENGTH('grac_practice.custom_gap','target_resolution_date') IS NULL
   OR COL_LENGTH('grac_practice.exception_request','owner_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.exception_request','request_type_code') IS NULL
   OR COL_LENGTH('grac_practice.exception_request','effective_until') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_observation','assigned_owner_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_execution','owner_role_id') IS NULL
BEGIN
    RAISERROR('414: required columns missing. Run 109, 115, 166, 184, 272 and 327 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Gap Register rows as ONE inline function
--
--    fn_pm_gap_centre_rows returns exactly the rows sp_gap_centre_list
--    (379) built into its @results table -- the materialized custom_gap
--    arm and the unmaterialized practice_gap arm, same expressions, same
--    filters -- plus the columns a dashboard needs:
--
--      OwnerEmployeeId  custom_gap.owner_employee_id /
--                       practice_instance.primary_owner_id (the owner ID)
--      IsOpen       not Closed / Cancelled and not Invalid / Duplicate
--      IsPending    open and still in the Gap Centre's own lifecycle
--                   (gap_lifecycle_state_master.is_terminal = 0, or an
--                   unmaterialized "New" row) -- awaiting analysis
--      IsCompleted  status Closed (the list shows "Closed")
--      IsOverdue    open and DueDate before today
--      AgeDays      days since OpenedDt
--
--    The list procedure (below) and sp_dashboard_issues_actions both read
--    this function, so the Gap Register and the dashboard can never count
--    a gap differently. The classification uses the lifecycle master's
--    own is_terminal / is_valid_terminal flags (272), nothing new.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_pm_gap_centre_rows
(
    @organization_id     BIGINT,
    @source_module_code  NVARCHAR(30),
    @status_code         NVARCHAR(30),
    @search              NVARCHAR(200),
    @observation_id      BIGINT
)
RETURNS TABLE
AS
RETURN
SELECT u.*,
       CAST(CASE WHEN u.RawStatusCode IN (N'Closed', N'Cancelled')
                   OR u.LifecycleStateCode = N'Closed'
                   OR (u.LifecycleIsTerminal = 1 AND u.LifecycleIsValidTerminal = 0)
                 THEN 0 ELSE 1 END AS BIT) AS IsOpen,
       CAST(CASE WHEN u.RawStatusCode IN (N'Closed', N'Cancelled')
                   OR u.LifecycleStateCode = N'Closed'
                   OR u.LifecycleIsTerminal = 1
                 THEN 0 ELSE 1 END AS BIT) AS IsPending,
       CAST(CASE WHEN u.RawStatusCode = N'Closed' OR u.LifecycleStateCode = N'Closed'
                 THEN 1 ELSE 0 END AS BIT) AS IsCompleted,
       CAST(CASE WHEN u.DueDate IS NOT NULL
                  AND u.DueDate < CAST(SYSUTCDATETIME() AS DATE)
                  AND NOT (u.RawStatusCode IN (N'Closed', N'Cancelled')
                           OR u.LifecycleStateCode = N'Closed'
                           OR (u.LifecycleIsTerminal = 1 AND u.LifecycleIsValidTerminal = 0))
                 THEN 1 ELSE 0 END AS BIT) AS IsOverdue,
       DATEDIFF(DAY, u.OpenedDt, SYSUTCDATETIME()) AS AgeDays
FROM (
    -- ---- Arm 1: materialized gaps (379's first INSERT, verbatim) ----
    SELECT
        CAST(N'cg' + CAST(g.custom_gap_id AS NVARCHAR(20)) AS NVARCHAR(40)) AS RowKey,
        CAST(g.gap_source_module_code AS NVARCHAR(30))                       AS SourceModuleCode,
        g.custom_gap_id                                                      AS CustomGapId,
        CAST(NULL AS BIGINT)                                                 AS PracticeGapId,
        CASE WHEN g.source_reference_type = N'PracticeInstance'
             THEN g.source_reference_id ELSE NULL END                        AS PracticeInstanceId,
        CAST(1 AS BIT)                                                       AS IsMaterialized,
        CAST(g.title AS NVARCHAR(400))                                       AS Title,
        CAST(NULLIF(LTRIM(RTRIM(CONCAT(
            ISNULL(g.execution_name, N''),
            CASE WHEN g.execution_name IS NOT NULL AND g.entity_name IS NOT NULL
                 THEN N' / ' ELSE N'' END,
            ISNULL(g.entity_name, N'')))), N'') AS NVARCHAR(800))            AS Context,
        CAST(CASE WHEN g.status = N'Closed' THEN N'Closed'
                  ELSE COALESCE(s.state_name, g.status) END AS NVARCHAR(100)) AS StatusText,
        CAST(g.status AS NVARCHAR(30))                                       AS RawStatusCode,
        CAST(s.state_code AS NVARCHAR(60))                                   AS LifecycleStateCode,
        CAST(COALESCE(g.severity_name, g.severity_code, g.priority) AS NVARCHAR(200)) AS SeverityText,
        CAST(g.owner_display_name AS NVARCHAR(300))                          AS OwnerText,
        CAST(COALESCE(g.due_date, g.target_resolution_date) AS DATE)         AS DueDate,
        CAST(g.opened_dt AS DATETIME2(3))                                    AS OpenedDt,
        (SELECT COUNT(*) FROM grac_practice.custom_gap_observation j
          WHERE j.custom_gap_id = g.custom_gap_id AND j.is_active = 1)       AS LinkedCount,
        CAST(NULL AS NVARCHAR(100))                                          AS InstanceCode,
        CAST(NULL AS NVARCHAR(300))                                          AS InstanceName,
        (SELECT COUNT(*)
           FROM grac_practice.practice_task t
          WHERE t.subject_entity_type = N'CustomGap'
            AND t.subject_entity_id   = g.custom_gap_id
            AND t.closed_at IS NULL)                                         AS ExistingTaskCount,
        3                                                                    AS UrgencyRank,
        1                                                                    AS SortBucket,
        CAST(CASE WHEN g.source_reference_type = N'PracticeInstance' AND g.source_reference_id IS NOT NULL
             THEN (SELECT TOP 1 CASE pg1.gap_status
                                      WHEN N'Closed' THEN N'Implemented'
                                      WHEN N'Open'   THEN N'Not Implemented'
                                      ELSE NULL END
                     FROM grac_practice.practice_gap pg1
                    WHERE pg1.practice_instance_id = g.source_reference_id)
             ELSE NULL END AS NVARCHAR(30))                                  AS PracticeInstanceStatusText,
        CAST((SELECT CASE
                    WHEN COUNT(*) = 0 THEN NULL
                    WHEN SUM(CASE WHEN ts.is_terminal = 1 THEN 0 ELSE 1 END) = 0 THEN N'Completed'
                    ELSE N'Pending'
                END
           FROM grac_practice.practice_task t2
           JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = t2.current_status_id
          WHERE t2.subject_entity_type = N'CustomGap'
            AND t2.subject_entity_id   = g.custom_gap_id) AS NVARCHAR(30))  AS TaskStatusText,
        CAST((SELECT TOP 1 COALESCE(
                          (SELECT rr.status_code
                             FROM grac_practice.risk_register rr
                            WHERE rr.risk_register_id = rc.registered_risk_id),
                          rc.status_code)
           FROM grac_practice.risk_candidate rc
          WHERE rc.custom_gap_id = g.custom_gap_id
          ORDER BY rc.risk_candidate_id DESC) AS NVARCHAR(100))              AS RiskStatusText,
        CAST((SELECT TOP 1 er.status_code
           FROM grac_practice.exception_request er
          WHERE er.custom_gap_id = g.custom_gap_id
          ORDER BY er.exception_request_id DESC) AS NVARCHAR(30))            AS ExceptionStatusText,
        -- 414
        g.organization_id                                                    AS OrganizationId,
        g.owner_employee_id                                                  AS OwnerEmployeeId,
        s.is_terminal                                                        AS LifecycleIsTerminal,
        s.is_valid_terminal                                                  AS LifecycleIsValidTerminal
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
           OR g.observation_title LIKE N'%' + @search + N'%')

    UNION ALL

    -- ---- Arm 2: unmaterialized Implementation gaps (379's second
    --      INSERT, verbatim; its IF became the first two WHERE lines) ----
    SELECT
        CAST(N'pg' + CAST(pg.practice_gap_id AS NVARCHAR(20)) AS NVARCHAR(40)),
        CAST(N'Implementation' AS NVARCHAR(30)),
        CAST(NULL AS BIGINT),
        pg.practice_gap_id,
        pi.practice_instance_id,
        CAST(0 AS BIT),
        CAST(COALESCE(pi.instance_name, pi.instance_code) AS NVARCHAR(400)),
        CAST(NULLIF(LTRIM(RTRIM(CONCAT(
            ISNULL(pi.instance_code, N''),
            CASE WHEN pi.instance_code IS NOT NULL AND p.practice_name IS NOT NULL
                 THEN N' / ' ELSE N'' END,
            ISNULL(p.practice_name, N'')))), N'') AS NVARCHAR(800)),
        CAST(N'New' AS NVARCHAR(100)),
        CAST(NULL AS NVARCHAR(30)),
        CAST(NULL AS NVARCHAR(60)),
        CAST(pi.criticality AS NVARCHAR(200)),
        CAST(pi.primary_owner AS NVARCHAR(300)),
        CAST(NULL AS DATE),
        CAST(pg.opened_dt AS DATETIME2(3)),
        (SELECT COUNT(*) FROM grac_practice.practice_gap_obligation pgo
          WHERE pgo.practice_gap_id = pg.practice_gap_id
            AND pgo.status          = N'Active'),
        CAST(pi.instance_code AS NVARCHAR(100)),
        CAST(pi.instance_name AS NVARCHAR(300)),
        (SELECT COUNT(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE t.subject_entity_type = N'PracticeInstance'
            AND t.subject_entity_id   = pi.practice_instance_id
            AND tt.type_code          = N'Implementation'
            AND t.closed_at IS NULL),
        ISNULL((SELECT CASE MIN(CASE pgo.logged_status_code
                              WHEN N'Not Implemented'       THEN 1
                              WHEN N'Partially Implemented' THEN 2
                              ELSE 3 END)
                     WHEN 1 THEN 1
                     WHEN 2 THEN 2
                     ELSE 3
                 END
           FROM  grac_practice.practice_gap_obligation pgo
           WHERE pgo.practice_gap_id = pg.practice_gap_id
             AND pgo.status          = N'Active'), 3),
        0,
        CAST(CASE pg.gap_status WHEN N'Closed' THEN N'Implemented'
                            WHEN N'Open'   THEN N'Not Implemented'
                            ELSE NULL END AS NVARCHAR(30)),
        CAST(NULL AS NVARCHAR(30)),
        CAST(NULL AS NVARCHAR(100)),
        CAST(NULL AS NVARCHAR(30)),
        -- 414
        pi.organization_id,
        pi.primary_owner_id,
        CAST(0 AS BIT),
        CAST(0 AS BIT)
    FROM   grac_practice.practice_gap pg
    JOIN   grac_practice.practice_instance pi
           ON pi.practice_instance_id = pg.practice_instance_id
    LEFT   JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
    WHERE (@source_module_code IS NULL OR @source_module_code = N'Implementation')
      AND  @observation_id IS NULL
      AND (@organization_id IS NULL OR pi.organization_id = @organization_id)
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
                         AND pgo.logged_status_code = @status_code))
) u;
GO
PRINT '414: fn_pm_gap_centre_rows created.';
GO

-- =====================================================================
-- 2. sp_gap_centre_list -- 379's parameters, @results table and its two
--    final SELECTs unchanged; the rows now come from
--    fn_pm_gap_centre_rows (section 1). New, all NULL = no opinion:
--
--      @drill_code    'open' | 'pending' | 'overdue' | 'completed' |
--                     'noowner' (open and owner ID NULL)
--      @status_text   the list's own Status column value
--      @severity_text the list's own Severity column value
--      @min_age_days / @max_age_days  one ageing band (open gaps)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_gap_centre_list
    @organization_id     BIGINT        = NULL,
    @source_module_code  NVARCHAR(30)  = NULL,
    @status_code         NVARCHAR(30)  = NULL,
    @search              NVARCHAR(200) = NULL,
    @observation_id      BIGINT        = NULL,
    @page                INT           = 1,
    @page_size           INT           = 25,
    -- 414: dashboard drill-down
    @drill_code          NVARCHAR(20)  = NULL,
    @status_text         NVARCHAR(100) = NULL,
    @severity_text       NVARCHAR(200) = NULL,
    @min_age_days        INT           = NULL,
    @max_age_days        INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @search = N'' SET @search = NULL;
    IF @source_module_code = N'' SET @source_module_code = NULL;
    IF @status_code = N'' SET @status_code = NULL;
    IF @drill_code = N'' SET @drill_code = NULL;
    IF @status_text = N'' SET @status_text = NULL;
    IF @severity_text = N'' SET @severity_text = NULL;

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
        PracticeInstanceStatusText NVARCHAR(30)  NULL,
        TaskStatusText             NVARCHAR(30)  NULL,
        RiskStatusText             NVARCHAR(100) NULL,
        ExceptionStatusText        NVARCHAR(30)  NULL
    );

    INSERT INTO @results
        (RowKey, SourceModuleCode, CustomGapId, PracticeGapId, PracticeInstanceId,
         IsMaterialized, Title, Context, StatusText, RawStatusCode, LifecycleStateCode,
         SeverityText, OwnerText,
         DueDate, OpenedDt, LinkedCount,
         InstanceCode, InstanceName, ExistingTaskCount, UrgencyRank, SortBucket,
         PracticeInstanceStatusText, TaskStatusText, RiskStatusText, ExceptionStatusText)
    SELECT f.RowKey, f.SourceModuleCode, f.CustomGapId, f.PracticeGapId, f.PracticeInstanceId,
           f.IsMaterialized, f.Title, f.Context, f.StatusText, f.RawStatusCode, f.LifecycleStateCode,
           f.SeverityText, f.OwnerText,
           f.DueDate, f.OpenedDt, f.LinkedCount,
           f.InstanceCode, f.InstanceName, f.ExistingTaskCount, f.UrgencyRank, f.SortBucket,
           f.PracticeInstanceStatusText, f.TaskStatusText, f.RiskStatusText, f.ExceptionStatusText
      FROM grac_practice.fn_pm_gap_centre_rows(@organization_id, @source_module_code,
                                               @status_code, @search, @observation_id) f
     WHERE (@drill_code IS NULL
            OR (@drill_code = N'open'      AND f.IsOpen      = 1)
            OR (@drill_code = N'pending'   AND f.IsPending   = 1)
            OR (@drill_code = N'overdue'   AND f.IsOverdue   = 1)
            OR (@drill_code = N'completed' AND f.IsCompleted = 1)
            OR (@drill_code = N'noowner'   AND f.IsOpen = 1 AND f.OwnerEmployeeId IS NULL))
       AND (@status_text   IS NULL OR f.StatusText   = @status_text)
       AND (@severity_text IS NULL OR f.SeverityText = @severity_text)
       AND (@min_age_days  IS NULL OR f.AgeDays >= @min_age_days)
       AND (@max_age_days  IS NULL OR f.AgeDays <= @max_age_days);

    SELECT COUNT_BIG(*) AS TotalCount,
           @page        AS PageNumber,
           @page_size   AS PageSize
    FROM   @results;

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
PRINT '414: sp_gap_centre_list re-issued on fn_pm_gap_centre_rows.';
GO

-- =====================================================================
-- 3. State views -- ONE definition each of the dashboard's buckets, read
--    by both the list procedure (drill-down) and the dashboard procedure
--    (counts), so a tile and the list it opens always agree. Every rule
--    is built from the entity's own status master / date columns.
-- =====================================================================

-- 3a. Exceptions & Waivers (exception_request, 161/166/184/257)
--     is_open    Pending / SubmittedForApproval -- awaiting a decision
--     is_lapsed  Approved with effective_until before today: the waiver
--                has run out but sp_exception_request_expire_due has not
--                yet moved it to Expired (the same test that proc uses)
--     age_days   days since the request was raised
CREATE OR ALTER VIEW grac_practice.vw_pm_exception_request_state
AS
SELECT r.exception_request_id,
       r.organization_id,
       r.status_code,
       r.request_type_code,
       r.owner_employee_id,
       CAST(CASE WHEN r.status_code IN (N'Pending', N'SubmittedForApproval')
                 THEN 1 ELSE 0 END AS BIT) AS is_open,
       CAST(CASE WHEN r.status_code = N'Approved'
                  AND r.effective_until IS NOT NULL
                  AND r.effective_until < CAST(SYSUTCDATETIME() AS DATE)
                 THEN 1 ELSE 0 END AS BIT) AS is_lapsed,
       DATEDIFF(DAY, r.requested_dt, SYSUTCDATETIME()) AS age_days
  FROM grac_practice.exception_request r;
GO

-- 3b. Audit executions (org_assurance_execution, 098/099)
--     stage_code  Planned (status Planned) | InProgress (every other
--                 non-terminal status: InProgress, Submitted, Reviewed,
--                 Approved) | Completed (Closed) | Cancelled
--     is_overdue  not terminal and planned_end_dt before today
--     is_upcoming Planned and planned_start_dt within the next 30 days
CREATE OR ALTER VIEW grac_practice.vw_pm_org_assurance_execution_state
AS
SELECT e.org_assurance_execution_id,
       e.organization_id,
       s.status_code,
       CAST(CASE WHEN s.status_code = N'Planned'   THEN N'Planned'
                 WHEN s.status_code = N'Closed'    THEN N'Completed'
                 WHEN s.status_code = N'Cancelled' THEN N'Cancelled'
                 WHEN s.is_terminal = 1            THEN N'Completed'
                 ELSE N'InProgress' END AS NVARCHAR(20)) AS stage_code,
       CAST(CASE WHEN s.is_terminal = 0
                  AND e.planned_end_dt IS NOT NULL
                  AND e.planned_end_dt < CAST(SYSUTCDATETIME() AS DATE)
                 THEN 1 ELSE 0 END AS BIT) AS is_overdue,
       CAST(CASE WHEN s.status_code = N'Planned'
                  AND e.planned_start_dt IS NOT NULL
                  AND e.planned_start_dt >= CAST(SYSUTCDATETIME() AS DATE)
                  AND e.planned_start_dt <= DATEADD(DAY, 30, CAST(SYSUTCDATETIME() AS DATE))
                 THEN 1 ELSE 0 END AS BIT) AS is_upcoming
  FROM grac_practice.org_assurance_execution e
  JOIN grac_practice.org_assurance_execution_status_master s
    ON s.org_assurance_execution_status_id = e.execution_status_id
 WHERE e.is_active = 1;
GO

-- 3c. Audit observations / findings (org_assurance_observation, 101/102)
--     stage_code  Pending (Open, InReview, Accepted -- being worked) |
--                 AwaitingClosure (Resolved) | Closed (Closed, Rejected)
--     is_overdue  Pending and due_date before today
--     age_days    days since observed_dt
CREATE OR ALTER VIEW grac_practice.vw_pm_org_assurance_observation_state
AS
SELECT o.org_assurance_observation_id,
       o.organization_id,
       st.status_code,
       o.severity_code,
       o.assigned_owner_employee_id,
       CAST(CASE WHEN st.is_terminal = 1           THEN N'Closed'
                 WHEN st.status_code = N'Resolved' THEN N'AwaitingClosure'
                 ELSE N'Pending' END AS NVARCHAR(20)) AS stage_code,
       CAST(CASE WHEN st.is_terminal = 0
                  AND st.status_code <> N'Resolved'
                  AND o.due_date IS NOT NULL
                  AND o.due_date < CAST(SYSUTCDATETIME() AS DATE)
                 THEN 1 ELSE 0 END AS BIT) AS is_overdue,
       DATEDIFF(DAY, o.observed_dt, SYSUTCDATETIME()) AS age_days
  FROM grac_practice.org_assurance_observation o
  JOIN grac_practice.org_assurance_observation_status_master st
    ON st.org_assurance_observation_status_id = o.observation_status_id
 WHERE o.is_active = 1;
GO
PRINT '414: state views created.';
GO

-- =====================================================================
-- 4. Drill-down filters on the existing lists
-- =====================================================================
-- ---- sp_task_list -- 253 body + @no_owner, @min_age_days, @max_age_days
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
    @priority                NVARCHAR(30)  = NULL,
    -- 414: dashboard drill-down. NULL = no opinion.
    --   @no_owner  1 = assigned_to_employee_id IS NULL
    --   @min_age_days / @max_age_days  one ageing band, age measured
    --              from the SLA baseline COALESCE(start_date, entered_dt)
    @no_owner                BIT           = NULL,
    @min_age_days            INT           = NULL,
    @max_age_days            INT           = NULL
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
       -- 414
       AND (ISNULL(@no_owner, 0) = 0         OR v.assigned_to_employee_id IS NULL)
       AND (@min_age_days IS NULL
            OR DATEDIFF(DAY, COALESCE(v.start_date, v.entered_dt), SYSUTCDATETIME()) >= @min_age_days)
       AND (@max_age_days IS NULL
            OR DATEDIFF(DAY, COALESCE(v.start_date, v.entered_dt), SYSUTCDATETIME()) <= @max_age_days)
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
PRINT '414: sp_task_list re-issued.';
GO

-- ---- sp_exception_request_list -- 193 body + @drill_code, @min_age_days, @max_age_days
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_list
    @organization_id   BIGINT,
    @status_code       NVARCHAR(30) = NULL,
    @request_type_code NVARCHAR(30) = NULL,
    @page_number       INT = 1,
    @page_size         INT = 25,
    -- 414: dashboard drill-down (vw_pm_exception_request_state).
    --   @drill_code  'open' | 'lapsed' | 'noowner' (open, no owner ID)
    --   @min_age_days / @max_age_days  one ageing band (days since raised)
    @drill_code        NVARCHAR(20) = NULL,
    @min_age_days      INT          = NULL,
    @max_age_days      INT          = NULL
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
      JOIN grac_practice.vw_pm_exception_request_state xs ON xs.exception_request_id = r.exception_request_id
     WHERE r.organization_id = @organization_id
       AND (@status_code IS NULL OR r.status_code = @status_code)
       AND (@request_type_code IS NULL OR r.request_type_code = @request_type_code)
       -- 414
       AND (NULLIF(@drill_code, N'') IS NULL
            OR (@drill_code = N'open'    AND xs.is_open   = 1)
            OR (@drill_code = N'lapsed'  AND xs.is_lapsed = 1)
            OR (@drill_code = N'noowner' AND xs.is_open   = 1 AND xs.owner_employee_id IS NULL))
       AND (@min_age_days IS NULL OR xs.age_days >= @min_age_days)
       AND (@max_age_days IS NULL OR xs.age_days <= @max_age_days)
     ORDER BY r.requested_dt DESC, r.exception_request_id DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO
PRINT '414: sp_exception_request_list re-issued.';
GO

-- ---- sp_org_assurance_execution_list -- 120 body + @drill_code
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_list
    @organization_id BIGINT,
    @definition_id   BIGINT       = NULL,
    @status_code     NVARCHAR(60) = NULL,
    @origin_type     NVARCHAR(20) = NULL,
    @search          NVARCHAR(200) = NULL,
    @page            INT = 1,
    @page_size       INT = 25,
    -- 414: dashboard drill-down (vw_pm_org_assurance_execution_state).
    --   'planned' | 'inprogress' | 'completed' | 'cancelled' | 'overdue' | 'upcoming'
    @drill_code      NVARCHAR(20) = NULL
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
        JOIN grac_practice.vw_pm_org_assurance_execution_state xs
             ON xs.org_assurance_execution_id = e.org_assurance_execution_id
        WHERE e.organization_id = @organization_id
          AND e.is_active = 1
          -- 414
          AND (NULLIF(@drill_code, N'') IS NULL
               OR (@drill_code = N'planned'    AND xs.stage_code = N'Planned')
               OR (@drill_code = N'inprogress' AND xs.stage_code = N'InProgress')
               OR (@drill_code = N'completed'  AND xs.stage_code = N'Completed')
               OR (@drill_code = N'cancelled'  AND xs.stage_code = N'Cancelled')
               OR (@drill_code = N'overdue'    AND xs.is_overdue  = 1)
               OR (@drill_code = N'upcoming'   AND xs.is_upcoming = 1))
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
        JOIN grac_practice.vw_pm_org_assurance_execution_state xs
             ON xs.org_assurance_execution_id = e.org_assurance_execution_id
        WHERE e.organization_id = @organization_id
          AND e.is_active = 1
          -- 414
          AND (NULLIF(@drill_code, N'') IS NULL
               OR (@drill_code = N'planned'    AND xs.stage_code = N'Planned')
               OR (@drill_code = N'inprogress' AND xs.stage_code = N'InProgress')
               OR (@drill_code = N'completed'  AND xs.stage_code = N'Completed')
               OR (@drill_code = N'cancelled'  AND xs.stage_code = N'Cancelled')
               OR (@drill_code = N'overdue'    AND xs.is_overdue  = 1)
               OR (@drill_code = N'upcoming'   AND xs.is_upcoming = 1))
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
PRINT '414: sp_org_assurance_execution_list re-issued.';
GO

-- ---- sp_org_assurance_observation_list -- 116a body + @drill_code, @min_age_days, @max_age_days
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_list
    @organization_id BIGINT,
    @execution_id    BIGINT       = NULL,
    @entity_id       BIGINT       = NULL,
    @status_code     NVARCHAR(60) = NULL,
    @severity_code   NVARCHAR(30) = NULL,
    @observation_type NVARCHAR(30) = NULL,
    @search          NVARCHAR(200) = NULL,
    @page            INT = 1,
    @page_size       INT = 25,
    -- 414: dashboard drill-down (vw_pm_org_assurance_observation_state).
    --   @drill_code 'pending' | 'awaiting' | 'closed' | 'overdue' |
    --               'noowner' (pending, no owner ID)
    --   @min_age_days / @max_age_days  one ageing band (days since observed)
    @drill_code      NVARCHAR(20) = NULL,
    @min_age_days    INT          = NULL,
    @max_age_days    INT          = NULL
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
        JOIN grac_practice.vw_pm_org_assurance_observation_state os
             ON os.org_assurance_observation_id = o.org_assurance_observation_id
        WHERE o.organization_id = @organization_id
          AND o.is_active = 1
          -- 414
          AND (NULLIF(@drill_code, N'') IS NULL
               OR (@drill_code = N'pending'  AND os.stage_code = N'Pending')
               OR (@drill_code = N'awaiting' AND os.stage_code = N'AwaitingClosure')
               OR (@drill_code = N'closed'   AND os.stage_code = N'Closed')
               OR (@drill_code = N'overdue'  AND os.is_overdue = 1)
               OR (@drill_code = N'noowner'  AND os.stage_code = N'Pending' AND os.assigned_owner_employee_id IS NULL))
          AND (@min_age_days IS NULL OR os.age_days >= @min_age_days)
          AND (@max_age_days IS NULL OR os.age_days <= @max_age_days)
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
        JOIN grac_practice.vw_pm_org_assurance_observation_state os
             ON os.org_assurance_observation_id = o.org_assurance_observation_id
        WHERE o.organization_id = @organization_id
          AND o.is_active = 1
          -- 414
          AND (NULLIF(@drill_code, N'') IS NULL
               OR (@drill_code = N'pending'  AND os.stage_code = N'Pending')
               OR (@drill_code = N'awaiting' AND os.stage_code = N'AwaitingClosure')
               OR (@drill_code = N'closed'   AND os.stage_code = N'Closed')
               OR (@drill_code = N'overdue'  AND os.is_overdue = 1)
               OR (@drill_code = N'noowner'  AND os.stage_code = N'Pending' AND os.assigned_owner_employee_id IS NULL))
          AND (@min_age_days IS NULL OR os.age_days >= @min_age_days)
          AND (@max_age_days IS NULL OR os.age_days <= @max_age_days)
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
PRINT '414: sp_org_assurance_observation_list re-issued.';
GO

-- =====================================================================
-- 5. fn_pm_ageing_band -- the ageing bands every module dashboard uses.
--    The same five bands, same day ranges and codes, as the Risk
--    dashboard's candidate ageing (214, result set 8), so "8-30 days"
--    means the same thing on every dashboard. One place to change them.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_pm_ageing_band()
RETURNS TABLE
AS
RETURN
SELECT b.BandCode, b.BandName, b.SortOrder, b.MinDays, b.MaxDays
  FROM (VALUES
          (N'0_7',    N'0-7 days',      1,   0,      7),
          (N'8_30',   N'8-30 days',     2,   8,     30),
          (N'31_90',  N'31-90 days',    3,  31,     90),
          (N'91_180', N'91-180 days',   4,  91,    180),
          (N'180_',   N'Over 180 days', 5, 181, 100000)
       ) AS b(BandCode, BandName, SortOrder, MinDays, MaxDays);
GO

-- =====================================================================
-- 6. Module dashboard procedures. One call per dashboard, org-scoped,
--    FOUR result sets in this fixed order (the API reads them by
--    position, and each is empty rather than absent when a module has
--    nothing to show):
--
--      0  KPIs           SectionKey, SectionTitle, KpiKey, Label, Value,
--                        IsAlert, SortOrder
--      1  Ageing bands   GroupKey, GroupTitle, BandCode, BandName,
--                        SortOrder, MinDays, MaxDays, ItemCount
--      2  Distributions  GroupKey, GroupTitle, ItemKey, ItemLabel,
--                        ItemCount, ColourHex, SortOrder
--      3  Lists          ListKey, ListTitle, RecordId, RefText, Title,
--                        OwnerName, StatusText, DateValue, SortOrder
--
--    Keys (SectionKey.KpiKey, GroupKey, ItemKey, ListKey) are what the
--    page maps to the drill-down on the EXISTING list page; ItemKey is
--    the exact value that list's filter takes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 6a. Issues & Actions: Gap Register (issues), Task Board, Exceptions
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_dashboard_issues_actions
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 57310, 'sp_dashboard_issues_actions: organization_id is required.', 1;

    -- Gap Register rows, exactly as the Gap Register lists them.
    SELECT f.RowKey, f.CustomGapId, f.Title, f.StatusText, f.SeverityText, f.OwnerText,
           f.OwnerEmployeeId, f.DueDate, f.IsOpen, f.IsPending, f.IsCompleted, f.IsOverdue, f.AgeDays
      INTO #gap
      FROM grac_practice.fn_pm_gap_centre_rows(@organization_id, NULL, NULL, NULL, NULL) f;

    -- Task Board rows: top-level tasks (sp_task_list shows children only
    -- when asked), with the view's own terminal / overdue flags. Age is
    -- measured from the SLA baseline, COALESCE(start_date, entered_dt).
    SELECT v.task_id, v.task_number, v.subject_title,
           v.current_status_code, v.current_status_name, v.current_status_is_terminal,
           v.is_overdue, v.assigned_to_employee_id, v.assigned_to_employee_name,
           v.priority, v.sla_due_at,
           DATEDIFF(DAY, COALESCE(v.start_date, v.entered_dt), SYSUTCDATETIME()) AS age_days
      INTO #task
      FROM grac_practice.vw_pm_practice_task v
     WHERE v.organization_id = @organization_id
       AND v.parent_task_id IS NULL;

    SELECT x.* INTO #exc
      FROM grac_practice.vw_pm_exception_request_state x
     WHERE x.organization_id = @organization_id;

    -- ---- 0. KPIs --------------------------------------------------------
    SELECT k.SectionKey, k.SectionTitle, k.KpiKey, k.Label, k.Value, k.IsAlert, k.SortOrder
      FROM (
        SELECT N'gaps' AS SectionKey, N'Issues (Gap Register)' AS SectionTitle, N'total' AS KpiKey,
               N'Total' AS Label, COUNT(*) AS Value, CAST(0 AS BIT) AS IsAlert, 1 AS SortOrder FROM #gap
        UNION ALL SELECT N'gaps', N'Issues (Gap Register)', N'open',      N'Open',              SUM(CAST(IsOpen AS INT)),      0, 2 FROM #gap
        UNION ALL SELECT N'gaps', N'Issues (Gap Register)', N'pending',   N'Pending analysis',  SUM(CAST(IsPending AS INT)),   0, 3 FROM #gap
        UNION ALL SELECT N'gaps', N'Issues (Gap Register)', N'overdue',   N'Overdue',           SUM(CAST(IsOverdue AS INT)),   1, 4 FROM #gap
        UNION ALL SELECT N'gaps', N'Issues (Gap Register)', N'completed', N'Closed',            SUM(CAST(IsCompleted AS INT)), 0, 5 FROM #gap
        UNION ALL SELECT N'gaps', N'Issues (Gap Register)', N'noowner',   N'No owner',
                         SUM(CASE WHEN IsOpen = 1 AND OwnerEmployeeId IS NULL THEN 1 ELSE 0 END), 1, 6 FROM #gap

        UNION ALL SELECT N'tasks', N'Tasks (Task Board)', N'total',     N'Total',          COUNT(*), 0, 1 FROM #task
        UNION ALL SELECT N'tasks', N'Tasks (Task Board)', N'open',      N'Open',
                         SUM(CASE WHEN current_status_is_terminal = 0 THEN 1 ELSE 0 END), 0, 2 FROM #task
        UNION ALL SELECT N'tasks', N'Tasks (Task Board)', N'pending',   N'Pending review',
                         SUM(CASE WHEN current_status_code = N'PendingReview' THEN 1 ELSE 0 END), 0, 3 FROM #task
        UNION ALL SELECT N'tasks', N'Tasks (Task Board)', N'overdue',   N'Overdue',
                         SUM(CASE WHEN is_overdue = 1 THEN 1 ELSE 0 END), 1, 4 FROM #task
        UNION ALL SELECT N'tasks', N'Tasks (Task Board)', N'completed', N'Completed',
                         SUM(CASE WHEN current_status_code = N'Closed' THEN 1 ELSE 0 END), 0, 5 FROM #task
        UNION ALL SELECT N'tasks', N'Tasks (Task Board)', N'noowner',   N'No owner',
                         SUM(CASE WHEN current_status_is_terminal = 0 AND assigned_to_employee_id IS NULL THEN 1 ELSE 0 END), 1, 6 FROM #task

        UNION ALL SELECT N'exceptions', N'Exceptions & Waivers', N'total',    N'Total',             COUNT(*), 0, 1 FROM #exc
        UNION ALL SELECT N'exceptions', N'Exceptions & Waivers', N'open',     N'Open requests',     SUM(CAST(is_open AS INT)), 0, 2 FROM #exc
        UNION ALL SELECT N'exceptions', N'Exceptions & Waivers', N'pending',  N'Awaiting approval',
                         SUM(CASE WHEN status_code = N'SubmittedForApproval' THEN 1 ELSE 0 END), 0, 3 FROM #exc
        UNION ALL SELECT N'exceptions', N'Exceptions & Waivers', N'lapsed',   N'Lapsed waivers',    SUM(CAST(is_lapsed AS INT)), 1, 4 FROM #exc
        UNION ALL SELECT N'exceptions', N'Exceptions & Waivers', N'approved', N'Approved',
                         SUM(CASE WHEN status_code = N'Approved' THEN 1 ELSE 0 END), 0, 5 FROM #exc
        UNION ALL SELECT N'exceptions', N'Exceptions & Waivers', N'noowner',  N'No owner',
                         SUM(CASE WHEN is_open = 1 AND owner_employee_id IS NULL THEN 1 ELSE 0 END), 1, 6 FROM #exc
      ) k
     ORDER BY CASE k.SectionKey WHEN N'gaps' THEN 1 WHEN N'tasks' THEN 2 ELSE 3 END, k.SortOrder;

    -- ---- 1. Ageing: OPEN items only ------------------------------------
    SELECT g.GroupKey, g.GroupTitle, b.BandCode, b.BandName, b.SortOrder, b.MinDays, b.MaxDays,
           (SELECT COUNT(*) FROM #gap  x WHERE g.GroupKey = N'gaps'       AND x.IsOpen = 1
                                           AND x.AgeDays BETWEEN b.MinDays AND b.MaxDays)
         + (SELECT COUNT(*) FROM #task x WHERE g.GroupKey = N'tasks'      AND x.current_status_is_terminal = 0
                                           AND x.age_days BETWEEN b.MinDays AND b.MaxDays)
         + (SELECT COUNT(*) FROM #exc  x WHERE g.GroupKey = N'exceptions' AND x.is_open = 1
                                           AND x.age_days BETWEEN b.MinDays AND b.MaxDays) AS ItemCount
      FROM (VALUES (N'gaps',       N'Open issues',              1),
                   (N'tasks',      N'Open tasks',               2),
                   (N'exceptions', N'Open exception requests',  3)) g(GroupKey, GroupTitle, GroupOrder)
     CROSS JOIN grac_practice.fn_pm_ageing_band() b
     ORDER BY g.GroupOrder, b.SortOrder;

    -- ---- 2. Distributions ----------------------------------------------
    SELECT d.GroupKey, d.GroupTitle, d.ItemKey, d.ItemLabel, d.ItemCount, d.ColourHex, d.SortOrder
      FROM (
        -- Issues by the Gap Register's own Status column.
        SELECT N'gaps_status' AS GroupKey, N'Issues by status' AS GroupTitle,
               StatusText AS ItemKey, ISNULL(StatusText, N'(none)') AS ItemLabel,
               COUNT(*) AS ItemCount, CAST(NULL AS NVARCHAR(20)) AS ColourHex,
               ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, StatusText) AS SortOrder
          FROM #gap GROUP BY StatusText
        UNION ALL
        -- Open issues by the list's Severity column.
        SELECT N'gaps_severity', N'Open issues by severity',
               SeverityText, ISNULL(SeverityText, N'(not set)'), COUNT(*), NULL,
               ROW_NUMBER() OVER (ORDER BY CASE SeverityText WHEN N'Critical' THEN 1 WHEN N'High' THEN 2
                                              WHEN N'Medium' THEN 3 WHEN N'Low' THEN 4 ELSE 5 END, SeverityText)
          FROM #gap WHERE IsOpen = 1 GROUP BY SeverityText
        UNION ALL
        SELECT N'tasks_status', N'Tasks by status',
               current_status_code, MAX(current_status_name), COUNT(*), NULL,
               ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, current_status_code)
          FROM #task GROUP BY current_status_code
        UNION ALL
        SELECT N'tasks_priority', N'Open tasks by priority',
               priority, ISNULL(priority, N'(not set)'), COUNT(*), NULL,
               ROW_NUMBER() OVER (ORDER BY CASE priority WHEN N'Critical' THEN 1 WHEN N'High' THEN 2
                                              WHEN N'Medium' THEN 3 WHEN N'Low' THEN 4 ELSE 5 END, priority)
          FROM #task WHERE current_status_is_terminal = 0 GROUP BY priority
        UNION ALL
        -- Labels are the Exceptions & Waivers filter's own labels.
        SELECT N'exceptions_status', N'Exception requests by status',
               status_code,
               CASE status_code WHEN N'SubmittedForApproval' THEN N'Submitted for approval' ELSE status_code END,
               COUNT(*), NULL,
               ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, status_code)
          FROM #exc GROUP BY status_code
        UNION ALL
        SELECT N'exceptions_type', N'Exception requests by type',
               request_type_code,
               CASE request_type_code WHEN N'GAP_CANDIDATE'            THEN N'Gap Candidate'
                                      WHEN N'SLA_CANDIDATE'            THEN N'SLA Candidate'
                                      WHEN N'TASK_SLA_EXTENSION'       THEN N'Task SLA Extension'
                                      WHEN N'TASK_PRIORITY_REDUCTION'  THEN N'Task Priority Reduction'
                                      WHEN N'CUSTOM'                   THEN N'Custom Exception'
                                      ELSE ISNULL(request_type_code, N'(not set)') END,
               COUNT(*), NULL,
               ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, request_type_code)
          FROM #exc GROUP BY request_type_code
      ) d
     ORDER BY CASE d.GroupKey WHEN N'gaps_status' THEN 1 WHEN N'gaps_severity' THEN 2
                              WHEN N'tasks_status' THEN 3 WHEN N'tasks_priority' THEN 4
                              WHEN N'exceptions_status' THEN 5 ELSE 6 END, d.SortOrder;

    -- ---- 3. Lists: the oldest overdue work -----------------------------
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName,
           l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (5) N'tasks_overdue' AS ListKey, N'Overdue tasks' AS ListTitle,
               task_id AS RecordId, task_number AS RefText, subject_title AS Title,
               assigned_to_employee_name AS OwnerName, current_status_name AS StatusText,
               CAST(sla_due_at AS DATE) AS DateValue,
               ROW_NUMBER() OVER (ORDER BY sla_due_at, task_id) AS SortOrder
          FROM #task WHERE is_overdue = 1
         ORDER BY sla_due_at, task_id
      ) l
    UNION ALL
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName,
           l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (5) N'gaps_overdue' AS ListKey, N'Overdue issues' AS ListTitle,
               CustomGapId AS RecordId, RowKey AS RefText, Title,
               OwnerText AS OwnerName, StatusText, DueDate AS DateValue,
               ROW_NUMBER() OVER (ORDER BY DueDate, RowKey) AS SortOrder
          FROM #gap WHERE IsOverdue = 1
         ORDER BY DueDate, RowKey
      ) l
     ORDER BY 1, 9;
END
GO

-- ---------------------------------------------------------------------
-- 6b. Audit & Assurance: audits (executions), findings (observations),
--     audit plans
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_dashboard_audit_assurance
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 57311, 'sp_dashboard_audit_assurance: organization_id is required.', 1;

    SELECT xs.org_assurance_execution_id, xs.status_code, xs.stage_code, xs.is_overdue, xs.is_upcoming,
           s.status_name, s.display_order,
           e.execution_code, e.execution_name, e.owner_display_name,
           e.planned_start_dt, e.planned_end_dt
      INTO #aud
      FROM grac_practice.vw_pm_org_assurance_execution_state xs
      JOIN grac_practice.org_assurance_execution e
        ON e.org_assurance_execution_id = xs.org_assurance_execution_id
      JOIN grac_practice.org_assurance_execution_status_master s
        ON s.org_assurance_execution_status_id = e.execution_status_id
     WHERE xs.organization_id = @organization_id;

    SELECT os.org_assurance_observation_id, os.status_code, os.stage_code, os.is_overdue, os.age_days,
           os.severity_code, os.assigned_owner_employee_id,
           st.status_name, st.display_order
      INTO #obs
      FROM grac_practice.vw_pm_org_assurance_observation_state os
      JOIN grac_practice.org_assurance_observation o
        ON o.org_assurance_observation_id = os.org_assurance_observation_id
      JOIN grac_practice.org_assurance_observation_status_master st
        ON st.org_assurance_observation_status_id = o.observation_status_id
     WHERE os.organization_id = @organization_id;

    SELECT p.org_assurance_plan_id, ps.status_code, ps.status_name, ps.display_order
      INTO #pln
      FROM grac_practice.org_assurance_plan p
      JOIN grac_practice.org_assurance_plan_status_master ps
        ON ps.org_assurance_plan_status_id = p.status_id
     WHERE p.organization_id = @organization_id
       AND p.is_active = 1;

    -- ---- 0. KPIs --------------------------------------------------------
    SELECT k.SectionKey, k.SectionTitle, k.KpiKey, k.Label, k.Value, k.IsAlert, k.SortOrder
      FROM (
        SELECT N'audits' AS SectionKey, N'Audits (Executions)' AS SectionTitle, N'total' AS KpiKey,
               N'Total' AS Label, COUNT(*) AS Value, CAST(0 AS BIT) AS IsAlert, 1 AS SortOrder FROM #aud
        UNION ALL SELECT N'audits', N'Audits (Executions)', N'planned',    N'Planned',
                         SUM(CASE WHEN stage_code = N'Planned'    THEN 1 ELSE 0 END), 0, 2 FROM #aud
        UNION ALL SELECT N'audits', N'Audits (Executions)', N'inprogress', N'In progress',
                         SUM(CASE WHEN stage_code = N'InProgress' THEN 1 ELSE 0 END), 0, 3 FROM #aud
        UNION ALL SELECT N'audits', N'Audits (Executions)', N'completed',  N'Completed',
                         SUM(CASE WHEN stage_code = N'Completed'  THEN 1 ELSE 0 END), 0, 4 FROM #aud
        UNION ALL SELECT N'audits', N'Audits (Executions)', N'overdue',    N'Overdue',
                         SUM(CAST(is_overdue AS INT)), 1, 5 FROM #aud
        UNION ALL SELECT N'audits', N'Audits (Executions)', N'upcoming',   N'Starting in 30 days',
                         SUM(CAST(is_upcoming AS INT)), 0, 6 FROM #aud

        UNION ALL SELECT N'findings', N'Findings (Observations)', N'total',    N'Total', COUNT(*), 0, 1 FROM #obs
        UNION ALL SELECT N'findings', N'Findings (Observations)', N'pending',  N'Pending',
                         SUM(CASE WHEN stage_code = N'Pending'         THEN 1 ELSE 0 END), 0, 2 FROM #obs
        UNION ALL SELECT N'findings', N'Findings (Observations)', N'awaiting', N'Resolved, awaiting closure',
                         SUM(CASE WHEN stage_code = N'AwaitingClosure' THEN 1 ELSE 0 END), 0, 3 FROM #obs
        UNION ALL SELECT N'findings', N'Findings (Observations)', N'overdue',  N'Overdue',
                         SUM(CAST(is_overdue AS INT)), 1, 4 FROM #obs
        UNION ALL SELECT N'findings', N'Findings (Observations)', N'closed',   N'Closed',
                         SUM(CASE WHEN stage_code = N'Closed'          THEN 1 ELSE 0 END), 0, 5 FROM #obs
        UNION ALL SELECT N'findings', N'Findings (Observations)', N'noowner',  N'No owner',
                         SUM(CASE WHEN stage_code = N'Pending' AND assigned_owner_employee_id IS NULL THEN 1 ELSE 0 END), 1, 6 FROM #obs

        UNION ALL SELECT N'plans', N'Audit plans', N'total',  N'Total',  COUNT(*), 0, 1 FROM #pln
        UNION ALL SELECT N'plans', N'Audit plans', N'active', N'Active',
                         SUM(CASE WHEN status_code = N'Active' THEN 1 ELSE 0 END), 0, 2 FROM #pln
      ) k
     ORDER BY CASE k.SectionKey WHEN N'audits' THEN 1 WHEN N'findings' THEN 2 ELSE 3 END, k.SortOrder;

    -- ---- 1. Ageing: pending findings, from observed_dt ------------------
    SELECT N'findings' AS GroupKey, N'Pending findings' AS GroupTitle,
           b.BandCode, b.BandName, b.SortOrder, b.MinDays, b.MaxDays,
           (SELECT COUNT(*) FROM #obs x WHERE x.stage_code = N'Pending'
                                          AND x.age_days BETWEEN b.MinDays AND b.MaxDays) AS ItemCount
      FROM grac_practice.fn_pm_ageing_band() b
     ORDER BY b.SortOrder;

    -- ---- 2. Distributions ----------------------------------------------
    SELECT d.GroupKey, d.GroupTitle, d.ItemKey, d.ItemLabel, d.ItemCount, d.ColourHex, d.SortOrder
      FROM (
        SELECT N'audits_status' AS GroupKey, N'Audits by status' AS GroupTitle,
               status_code AS ItemKey, MAX(status_name) AS ItemLabel, COUNT(*) AS ItemCount,
               CAST(NULL AS NVARCHAR(20)) AS ColourHex, MIN(display_order) AS SortOrder
          FROM #aud GROUP BY status_code
        UNION ALL
        -- Colours are the severity master's own (101).
        SELECT N'findings_severity', N'Pending findings by severity',
               o.severity_code, ISNULL(MAX(sv.severity_name), ISNULL(o.severity_code, N'(not set)')),
               COUNT(*), MAX(sv.color_hex), ISNULL(MIN(sv.display_order), 99)
          FROM #obs o
          LEFT JOIN grac_practice.org_assurance_observation_severity_master sv
                 ON sv.severity_code = o.severity_code
         WHERE o.stage_code = N'Pending'
         GROUP BY o.severity_code
        UNION ALL
        SELECT N'findings_status', N'Findings by status',
               status_code, MAX(status_name), COUNT(*), NULL, MIN(display_order)
          FROM #obs GROUP BY status_code
        UNION ALL
        SELECT N'plans_status', N'Audit plans by status',
               status_code, MAX(status_name), COUNT(*), NULL, MIN(display_order)
          FROM #pln GROUP BY status_code
      ) d
     ORDER BY CASE d.GroupKey WHEN N'audits_status' THEN 1 WHEN N'findings_severity' THEN 2
                              WHEN N'findings_status' THEN 3 ELSE 4 END, d.SortOrder;

    -- ---- 3. Lists: upcoming and overdue audits ---------------------------
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName,
           l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (10) N'audits_upcoming' AS ListKey, N'Audits starting in the next 30 days' AS ListTitle,
               org_assurance_execution_id AS RecordId, execution_code AS RefText, execution_name AS Title,
               owner_display_name AS OwnerName, status_name AS StatusText,
               planned_start_dt AS DateValue,
               ROW_NUMBER() OVER (ORDER BY planned_start_dt, org_assurance_execution_id) AS SortOrder
          FROM #aud WHERE is_upcoming = 1
         ORDER BY planned_start_dt, org_assurance_execution_id
      ) l
    UNION ALL
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName,
           l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (5) N'audits_overdue' AS ListKey, N'Overdue audits' AS ListTitle,
               org_assurance_execution_id AS RecordId, execution_code AS RefText, execution_name AS Title,
               owner_display_name AS OwnerName, status_name AS StatusText,
               planned_end_dt AS DateValue,
               ROW_NUMBER() OVER (ORDER BY planned_end_dt, org_assurance_execution_id) AS SortOrder
          FROM #aud WHERE is_overdue = 1
         ORDER BY planned_end_dt, org_assurance_execution_id
      ) l
     ORDER BY 1, 9;
END
GO

-- ---------------------------------------------------------------------
-- 6c. Governance: practice instances, on Operationalize's own rules
--     (sp_resolve_instance_list, 394): Active instances of the
--     organization; a non-admin caller sees only instances they own
--     (primary_owner_id); status = COALESCE(implementation_status_master
--     name, implementation_status). The standards / statements and
--     practices figures are NOT recomputed here -- the page reads them
--     from the existing subscribed-frameworks and dashboard-summary
--     queries, which already return them.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_dashboard_governance
    @organization_id    BIGINT,
    @caller_employee_id BIGINT = NULL,
    @is_admin           BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 57312, 'sp_dashboard_governance: organization_id is required.', 1;
    SET @is_admin = ISNULL(@is_admin, 0);

    -- A non-admin with no employee record owns nothing (398's rule for
    -- an unmatched caller): every count is zero rather than an error.
    SELECT pi.practice_instance_id,
           pi.primary_owner_id,
           COALESCE(ims.status_name, pi.implementation_status) AS implementation_status
      INTO #ins
      FROM grac_practice.practice_instance pi
      JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
      LEFT JOIN grac_practice.implementation_status_master ims
             ON ims.implementation_status_id = pi.implementation_status_id
     WHERE pi.organization_id = @organization_id
       AND pi.status = N'Active'
       AND (@is_admin = 1 OR (@caller_employee_id IS NOT NULL AND pi.primary_owner_id = @caller_employee_id));

    -- ---- 0. KPIs --------------------------------------------------------
    SELECT k.SectionKey, k.SectionTitle, k.KpiKey, k.Label, k.Value, k.IsAlert, k.SortOrder
      FROM (
        SELECT N'instances' AS SectionKey,
               CASE WHEN @is_admin = 1 THEN N'Practice instances' ELSE N'Your practice instances' END AS SectionTitle,
               N'total' AS KpiKey, N'Total' AS Label, COUNT(*) AS Value, CAST(0 AS BIT) AS IsAlert, 1 AS SortOrder
          FROM #ins
        UNION ALL SELECT N'instances', CASE WHEN @is_admin = 1 THEN N'Practice instances' ELSE N'Your practice instances' END,
                         N'implemented', N'Implemented',
                         SUM(CASE WHEN implementation_status = N'Implemented' THEN 1 ELSE 0 END), 0, 2 FROM #ins
        UNION ALL SELECT N'instances', CASE WHEN @is_admin = 1 THEN N'Practice instances' ELSE N'Your practice instances' END,
                         N'partial', N'Partially implemented',
                         SUM(CASE WHEN implementation_status = N'Partially Implemented' THEN 1 ELSE 0 END), 0, 3 FROM #ins
        UNION ALL SELECT N'instances', CASE WHEN @is_admin = 1 THEN N'Practice instances' ELSE N'Your practice instances' END,
                         N'notimplemented', N'Not implemented',
                         SUM(CASE WHEN implementation_status = N'Not Implemented' THEN 1 ELSE 0 END), 1, 4 FROM #ins
        -- Only an admin sees unowned instances in Operationalize, so only
        -- an admin gets this tile.
        UNION ALL SELECT N'instances', N'Practice instances', N'noowner', N'No owner',
                         SUM(CASE WHEN primary_owner_id IS NULL THEN 1 ELSE 0 END), 1, 5
                    FROM #ins WHERE @is_admin = 1
                  HAVING @is_admin = 1
      ) k
     ORDER BY k.SortOrder;

    -- ---- 1. Ageing: none. Practice instances carry no due, review or
    --      target date, so no ageing is invented. Empty set, same shape.
    SELECT CAST(NULL AS NVARCHAR(40)) AS GroupKey, CAST(NULL AS NVARCHAR(200)) AS GroupTitle,
           CAST(NULL AS NVARCHAR(20)) AS BandCode, CAST(NULL AS NVARCHAR(60)) AS BandName,
           CAST(NULL AS INT) AS SortOrder, CAST(NULL AS INT) AS MinDays, CAST(NULL AS INT) AS MaxDays,
           CAST(NULL AS INT) AS ItemCount
     WHERE 1 = 0;

    -- ---- 2. Distributions: instances by implementation status ----------
    -- ItemKey is the value Operationalize's Status filter takes.
    SELECT N'instances_status' AS GroupKey, N'Practice instances by implementation status' AS GroupTitle,
           implementation_status AS ItemKey, ISNULL(implementation_status, N'(not set)') AS ItemLabel,
           COUNT(*) AS ItemCount, CAST(NULL AS NVARCHAR(20)) AS ColourHex,
           ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, implementation_status) AS SortOrder
      FROM #ins
     GROUP BY implementation_status
     ORDER BY SortOrder;

    -- ---- 3. Lists: none (the page lists releases from subscribed-
    --      frameworks and attention items from dashboard-summary).
    SELECT CAST(NULL AS NVARCHAR(40)) AS ListKey, CAST(NULL AS NVARCHAR(200)) AS ListTitle,
           CAST(NULL AS BIGINT) AS RecordId, CAST(NULL AS NVARCHAR(100)) AS RefText,
           CAST(NULL AS NVARCHAR(400)) AS Title, CAST(NULL AS NVARCHAR(300)) AS OwnerName,
           CAST(NULL AS NVARCHAR(100)) AS StatusText, CAST(NULL AS DATE) AS DateValue,
           CAST(NULL AS INT) AS SortOrder
     WHERE 1 = 0;
END
GO
PRINT '414: dashboard procedures created.';
GO

-- =====================================================================
-- 7. The three parents open their dashboards. Children untouched.
-- =====================================================================
UPDATE m
   SET menu_url   = x.url,
       updated_by = N'seed-414',
       updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master m
  JOIN (VALUES (N'nav-governance', N'Practice/Index/governance-dashboard'),
               (N'nav-oversight',  N'Practice/Index/issues-actions-dashboard'),
               (N'nav-assurance',  N'Practice/Index/audit-assurance-dashboard')) x(menu_key, url)
    ON x.menu_key = m.menu_key
 WHERE ISNULL(m.menu_url, N'') <> x.url;
PRINT CONCAT('414: parent menu urls set: ', @@ROWCOUNT);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '414-a dashboard objects present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.fn_pm_gap_centre_rows') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_pm_ageing_band') IS NOT NULL
             AND OBJECT_ID('grac_practice.vw_pm_exception_request_state','V') IS NOT NULL
             AND OBJECT_ID('grac_practice.vw_pm_org_assurance_execution_state','V') IS NOT NULL
             AND OBJECT_ID('grac_practice.vw_pm_org_assurance_observation_state','V') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_dashboard_issues_actions','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_dashboard_audit_assurance','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_dashboard_governance','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '414-b list procedures carry the drill parameters',
       CASE WHEN (SELECT COUNT(*) FROM sys.parameters
                   WHERE (object_id = OBJECT_ID('grac_practice.sp_gap_centre_list')               AND name = '@drill_code')
                      OR (object_id = OBJECT_ID('grac_practice.sp_task_list')                     AND name = '@no_owner')
                      OR (object_id = OBJECT_ID('grac_practice.sp_exception_request_list')        AND name = '@drill_code')
                      OR (object_id = OBJECT_ID('grac_practice.sp_org_assurance_execution_list')  AND name = '@drill_code')
                      OR (object_id = OBJECT_ID('grac_practice.sp_org_assurance_observation_list') AND name = '@drill_code')) = 5
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '414-c the Gap Register still lists every gap (function = list)',
       CASE WHEN (SELECT COUNT_BIG(*) FROM grac_practice.fn_pm_gap_centre_rows(NULL, NULL, NULL, NULL, NULL))
               = (SELECT COUNT_BIG(*) FROM grac_practice.custom_gap)
               + (SELECT COUNT_BIG(*) FROM grac_practice.practice_gap pg
                    JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = pg.practice_instance_id
                   WHERE pg.gap_status = N'Open'
                     AND NOT EXISTS (SELECT 1 FROM grac_practice.custom_gap cg
                                      WHERE cg.source_reference_type = N'PracticeInstance'
                                        AND cg.source_reference_id   = pg.practice_instance_id
                                        AND cg.organization_id       = pi.organization_id))
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '414-d parent menus open their dashboards',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.menu_master
                   WHERE (menu_key = N'nav-governance' AND menu_url = N'Practice/Index/governance-dashboard')
                      OR (menu_key = N'nav-oversight'  AND menu_url = N'Practice/Index/issues-actions-dashboard')
                      OR (menu_key = N'nav-assurance'  AND menu_url = N'Practice/Index/audit-assurance-dashboard')) = 3
            THEN 'PASS' ELSE 'FAIL' END;
GO

PRINT 'Migration 414_management_dashboards applied. Users re-login to refresh the sidebar.';
GO

SET NOEXEC OFF;
GO
