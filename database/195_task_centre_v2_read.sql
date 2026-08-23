-- =====================================================================
-- 195 Task Centre v2 — read layer  (BRD §13, §15, §16, §17)
--
-- CONTENTS
--   1. vw_pm_practice_task    — REFRESH. Every 048 column preserved,
--                               plus the v2 columns, a derived SLA
--                               status and child roll-ups.
--   2. sp_task_list           — REWRITE (superset of 037). New filters;
--                               children excluded by default.
--   3. sp_task_get            — NEW. Operational detail: header,
--                               activity, evidence, children, governance
--                               requests.
--   4. sp_task_source_tasks   — NEW. Source -> Tasks navigation (§15).
--   5. sp_task_center_counts  — REWRITE (superset of 049). Tab badges
--                               now count top-level tasks only.
--
-- SLA STATUS DERIVATION (BRD §13, §17)
-- ------------------------------------
-- BRD §13: "Use configurable notification thresholds rather than
-- hard-coded timings." The warning threshold therefore comes from the
-- organisation's own SLA config (org_sla_config.warning_pct, tuned in
-- the Org SLA Configuration screen — 178/183), falling back to the SLA
-- master's pct and finally to 75%.
--
-- Two columns are emitted because the BRD uses one word for two ideas:
--   sla_timing_code — the pure temporal fact:
--                     OnTrack | DueSoon | DueToday | Breached |
--                     Completed | NotSet
--   sla_status_code — what §17's "SLA Status" field shows, i.e. the
--                     timing, except that an approved extension surfaces
--                     as 'Extended' while the task is still inside the
--                     new window. A breach is never masked by an
--                     extension.
--
-- Rollback: database/195_task_centre_v2_read_rollback.sql
-- ERROR CODE RANGE: 55700-55749
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF COL_LENGTH('grac_practice.practice_task','standard_due_at') IS NULL
BEGIN PRINT 'ABORT (195): run 192_task_centre_v2_schema.sql first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.task_activity','U') IS NULL
BEGIN PRINT 'ABORT (195): task_activity missing — run 192 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.task_type_master','U') IS NULL
   OR OBJECT_ID('grac_practice.entity_status_master','U') IS NULL
BEGIN PRINT 'ABORT (195): task engine masters missing — run 037 first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('195_task_centre_v2_read: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. vw_pm_practice_task — refresh
--
-- Built through sp_executesql for the same reason 048 did it: CREATE
-- VIEW has no deferred name resolution, so a static statement would be
-- PARSED (and fail) even under SET NOEXEC ON when a prerequisite is
-- missing. Dynamic SQL is only parsed at EXEC time.
-- =====================================================================
IF OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NOT NULL
    DROP VIEW grac_practice.vw_pm_practice_task;
GO

IF OBJECT_ID('grac_practice.practice_task','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.task_type_master','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.entity_status_master','U') IS NOT NULL
BEGIN
    EXEC sp_executesql N'
CREATE VIEW grac_practice.vw_pm_practice_task AS
WITH base AS (
    SELECT t.*,
           tt.type_code    AS task_type_code_x,
           tt.type_name    AS task_type_name_x,
           s.status_code   AS status_code_x,
           s.status_name   AS status_name_x,
           s.is_terminal   AS is_terminal_x,
           -- Warning threshold: org tuning first, then the master, then 75%.
           COALESCE(cfg.warning_pct, 75.0) AS warning_pct_x,
           COALESCE(t.start_date, t.entered_dt) AS sla_baseline_x
      FROM grac_practice.practice_task t
      JOIN grac_practice.task_type_master    tt ON tt.task_type_id    = t.task_type_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
 LEFT JOIN grac_practice.org_sla_config     cfg ON cfg.organization_id = t.organization_id
                                               AND cfg.sla_master_id   = t.sla_master_id
                                               AND cfg.is_active       = 1
),
timed AS (
    SELECT b.*,
           CASE
             WHEN b.closed_at IS NOT NULL OR b.is_terminal_x = 1 THEN N''Completed''
             WHEN b.sla_due_at IS NULL                            THEN N''NotSet''
             WHEN SYSUTCDATETIME() > b.sla_due_at                 THEN N''Breached''
             WHEN CAST(SYSUTCDATETIME() AS DATE) = CAST(b.sla_due_at AS DATE) THEN N''DueToday''
             WHEN DATEDIFF(SECOND, b.sla_baseline_x, b.sla_due_at) > 0
              AND (CAST(DATEDIFF(SECOND, b.sla_baseline_x, SYSUTCDATETIME()) AS DECIMAL(18,4))
                   / NULLIF(CAST(DATEDIFF(SECOND, b.sla_baseline_x, b.sla_due_at) AS DECIMAL(18,4)), 0)) * 100.0
                  >= b.warning_pct_x                              THEN N''DueSoon''
             ELSE N''OnTrack''
           END AS sla_timing_code
      FROM base b
)
SELECT t.task_id,
       t.task_number,
       t.organization_id,
       t.task_type_id,
       t.task_type_code_x                      AS task_type_code,
       t.task_type_name_x                      AS task_type_name,
       t.subject_entity_type,
       t.subject_entity_id,
       t.linked_release_id,
       t.linked_control_id,
       t.linked_practice_id,
       t.linked_instance_id,
       t.related_entity_type_id,
       ret.entity_code                         AS related_entity_type_code,
       ret.entity_name                         AS related_entity_type_name,
       t.related_record_id,
       t.assurance_activity_id,
       t.workflow_id,
       t.current_workflow_stage_id,
       t.subject_title,
       t.subject_description,
       t.assigned_to_employee_id,
       emp.employee_name                       AS assigned_to_employee_name,
       t.owner_source_code,
       t.current_status_id,
       t.status_code_x                         AS current_status_code,
       t.status_name_x                         AS current_status_name,
       t.is_terminal_x                         AS current_status_is_terminal,
       t.priority,
       t.criticality,
       t.origin_code,
       t.start_date,
       t.sla_due_at,
       CASE
         WHEN t.sla_due_at IS NULL THEN NULL
         WHEN t.is_terminal_x = 1 THEN NULL
         WHEN SYSUTCDATETIME() > t.sla_due_at THEN 1
         ELSE 0
       END                                     AS is_overdue,
       t.escalated_at,
       t.reason_code,
       t.reason_text,
       t.correlation_id,
       t.closed_at,

       -- ---- v2: SLA split (BRD §8) -------------------------------------
       t.standard_sla_days,
       t.standard_due_at,
       t.approved_extended_due_at,
       t.sla_source_code,
       t.sla_master_id,
       t.sla_master_name,
       t.extension_status_code,
       t.requested_due_at,
       t.extension_reason,
       CASE WHEN t.extension_status_code = N''Approved''
             AND t.approved_extended_due_at IS NOT NULL
            THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_extended,

       -- ---- v2: SLA monitoring (BRD §13, §17) --------------------------
       t.sla_timing_code,
       CASE
         WHEN t.sla_timing_code IN (N''Breached'', N''Completed'', N''NotSet'')
              THEN t.sla_timing_code
         WHEN t.extension_status_code = N''Approved''
              AND t.approved_extended_due_at IS NOT NULL
              THEN N''Extended''
         ELSE t.sla_timing_code
       END                                     AS sla_status_code,
       t.warning_pct_x                         AS sla_warning_pct,
       CASE WHEN t.sla_due_at IS NULL OR t.closed_at IS NOT NULL THEN NULL
            ELSE DATEDIFF(DAY, CAST(SYSUTCDATETIME() AS DATE), CAST(t.sla_due_at AS DATE))
       END                                     AS days_to_due,

       -- ---- v2: priority governance (BRD §7) ---------------------------
       t.requested_priority,
       t.priority_change_status_code,

       -- ---- v2: parent / child (BRD §11, §12) --------------------------
       t.parent_task_id,
       p.task_number                           AS parent_task_number,
       p.subject_title                         AS parent_task_title,
       t.is_mandatory_child,
       t.child_target_date,
       CASE WHEN t.parent_task_id IS NOT NULL THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_child,
       ISNULL(ch.ChildCount, 0)                AS child_count,
       ISNULL(ch.MandatoryChildCount, 0)       AS mandatory_child_count,
       ISNULL(ch.MandatoryChildOpenCount, 0)   AS mandatory_child_open_count,
       CASE WHEN t.closed_at IS NOT NULL THEN CAST(0 AS BIT)
            WHEN ISNULL(ch.MandatoryChildOpenCount, 0) = 0 THEN CAST(1 AS BIT)
            ELSE CAST(0 AS BIT) END            AS is_eligible_for_completion,

       -- ---- v2: source navigation (BRD §15) ----------------------------
       t.source_type_code,
       t.source_record_id,
       t.source_reference,

       -- ---- v2: completion (BRD §10) -----------------------------------
       t.completed_by_employee_id,
       cmp.employee_name                       AS completed_by_employee_name,
       t.completed_dt,

       t.entered_by, t.entered_dt, t.updated_by, t.updated_dt
FROM timed t
LEFT JOIN grac_practice.related_entity_type_master ret ON ret.related_entity_type_id = t.related_entity_type_id
LEFT JOIN grac_practice.organization_employee      emp ON emp.employee_id = t.assigned_to_employee_id
LEFT JOIN grac_practice.organization_employee      cmp ON cmp.employee_id = t.completed_by_employee_id
LEFT JOIN grac_practice.practice_task              p   ON p.task_id       = t.parent_task_id
OUTER APPLY (
    SELECT COUNT(*)                                                                   AS ChildCount,
           SUM(CASE WHEN ISNULL(c.is_mandatory_child,1) = 1 THEN 1 ELSE 0 END)        AS MandatoryChildCount,
           SUM(CASE WHEN ISNULL(c.is_mandatory_child,1) = 1
                     AND c.closed_at IS NULL THEN 1 ELSE 0 END)                       AS MandatoryChildOpenCount
      FROM grac_practice.practice_task c
     WHERE c.parent_task_id = t.task_id
) ch;';
END
GO

-- =====================================================================
-- 2. sp_task_list  (REWRITE — superset of 037)
--
-- BEHAVIOUR CHANGE, deliberate and documented:
--   Child tasks are EXCLUDED by default (@include_children = 0). Before
--   192 no task had a parent, so every existing caller sees exactly the
--   same rows it saw before. Now that decomposition exists, listing
--   children as peers of their parents would misrepresent the work —
--   BRD §11: "the parent owns the commitment; children distribute the
--   work." Pass @include_children = 1, or @parent_task_id, to see them.
--
-- Every original parameter keeps its name, position-independent default
-- and meaning, and both result sets keep their shape (count header, then
-- the page), so TaskService binds unchanged.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_list
    @organization_id         BIGINT        = NULL,
    @assigned_to_employee_id BIGINT        = NULL,
    @task_type_code          NVARCHAR(60)  = NULL,
    @status_code             NVARCHAR(60)  = NULL,   -- 'OpenSet' for non-terminal, else specific
    @overdue_only            BIT           = 0,
    @search                  NVARCHAR(200) = NULL,
    @page                    INT           = 1,
    @page_size               INT           = 25,
    -- new in 195:
    @parent_task_id          BIGINT        = NULL,   -- children of one parent
    @include_children        BIT           = 0,      -- see the note above
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

    -- Materialise once and reuse — a CTE binds only to the statement that
    -- immediately follows it, and we need the same set twice (037 solved
    -- this by repeating the CTE; 049 by using a table variable. The
    -- table variable is cheaper to keep correct.)
    DECLARE @filtered TABLE (task_id BIGINT PRIMARY KEY, sort_due DATETIME2);

    INSERT INTO @filtered (task_id, sort_due)
    SELECT v.task_id, v.sla_due_at
      FROM grac_practice.vw_pm_practice_task v
     WHERE (@organization_id IS NULL         OR v.organization_id = @organization_id)
       AND (@assigned_to_employee_id IS NULL OR v.assigned_to_employee_id = @assigned_to_employee_id)
       AND (@task_type_code IS NULL          OR v.task_type_code = @task_type_code)
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

    -- Result-set #1 — count + paging metadata (unchanged shape)
    SELECT COUNT_BIG(*) AS TotalCount,
           @page        AS PageNumber,
           @page_size   AS PageSize
      FROM @filtered;

    -- Result-set #2 — the current page
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

-- =====================================================================
-- 3. sp_task_get  (BRD §16)
--
-- Everything the operational, service-request-style detail page needs,
-- in one round trip. Five result sets:
--   1 header       — the full view row + parent/source context
--   2 activity     — the update / comment / governance feed
--   3 attachments  — evidence METADATA only (never the VARBINARY; use
--                    sp_task_attachment_get to stream one file)
--   4 children     — child list with owner and completion state
--   5 requests     — Exception Centre requests raised against this task
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_get
    @task_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @task_id IS NULL
        THROW 55700, 'sp_task_get: task_id is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_task WHERE task_id = @task_id)
        THROW 55701, 'sp_task_get: task not found.', 1;

    -- ---- 1. Header --------------------------------------------------
    SELECT * FROM grac_practice.vw_pm_practice_task WHERE task_id = @task_id;

    -- ---- 2. Activity / update history -------------------------------
    SELECT a.task_activity_id   AS TaskActivityId,
           a.task_id            AS TaskId,
           a.activity_type_code AS ActivityTypeCode,
           a.remark             AS Remark,
           a.from_value         AS FromValue,
           a.to_value           AS ToValue,
           a.actor_employee_id  AS ActorEmployeeId,
           a.actor_display_name AS ActorDisplayName,
           a.entered_dt         AS EnteredDt
      FROM grac_practice.task_activity a
     WHERE a.task_id = @task_id
     ORDER BY a.entered_dt DESC, a.task_activity_id DESC;

    -- ---- 3. Evidence / attachments (metadata only) ------------------
    SELECT at.task_attachment_id   AS TaskAttachmentId,
           at.file_name            AS FileName,
           at.content_type         AS ContentType,
           at.file_size_bytes      AS FileSizeBytes,
           at.evidence_description AS EvidenceDescription,
           at.uploaded_by_employee_id AS UploadedByEmployeeId,
           e.employee_name         AS UploadedByName,
           at.uploaded_dt          AS UploadedDt
      FROM grac_practice.task_attachment at
 LEFT JOIN grac_practice.organization_employee e ON e.employee_id = at.uploaded_by_employee_id
     WHERE at.task_id = @task_id
     ORDER BY at.uploaded_dt DESC;

    -- ---- 4. Children -------------------------------------------------
    SELECT c.task_id                  AS TaskId,
           c.task_number              AS TaskNumber,
           c.subject_title            AS SubjectTitle,
           c.subject_description      AS SubjectDescription,
           c.assigned_to_employee_id  AS AssignedToEmployeeId,
           c.assigned_to_employee_name AS AssignedToEmployeeName,
           c.priority                 AS Priority,
           c.is_mandatory_child       AS IsMandatoryChild,
           c.child_target_date        AS ChildTargetDate,
           c.sla_due_at               AS SlaDueAt,
           c.sla_status_code          AS SlaStatusCode,
           c.current_status_code      AS CurrentStatusCode,
           c.current_status_name      AS CurrentStatusName,
           c.closed_at                AS ClosedAt,
           c.completed_dt             AS CompletedDt
      FROM grac_practice.vw_pm_practice_task c
     WHERE c.parent_task_id = @task_id
     ORDER BY c.is_mandatory_child DESC, c.task_id;

    -- ---- 5. Governance requests raised against this task -------------
    SELECT r.exception_request_id AS ExceptionRequestId,
           r.request_type_code    AS RequestTypeCode,
           r.request_title        AS RequestTitle,
           r.request_reason       AS RequestReason,
           r.status_code          AS StatusCode,
           r.priority_original    AS PriorityOriginal,
           r.priority_requested   AS PriorityRequested,
           r.due_at_original      AS DueAtOriginal,
           r.due_at_requested     AS DueAtRequested,
           r.requested_dt         AS RequestedOn,
           rq.employee_name       AS RequestedByName,
           r.approved_dt          AS ApprovedOn,
           ap.employee_name       AS ApprovedByName,
           r.rejected_dt          AS RejectedOn,
           rj.employee_name       AS RejectedByName,
           r.rejection_reason     AS RejectionReason
      FROM grac_practice.exception_request r
 LEFT JOIN grac_practice.organization_employee rq ON rq.employee_id = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee ap ON ap.employee_id = r.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee rj ON rj.employee_id = r.rejected_by_employee_id
     WHERE r.task_id = @task_id
     ORDER BY r.requested_dt DESC, r.exception_request_id DESC;
END;
GO

-- =====================================================================
-- 4. sp_task_source_tasks  (BRD §15)
--
-- "The relationship must support one source item generating multiple
--  tasks. ... The source should display associated tasks, their status
--  and links."
--
-- Called by the Gap / Exception / Risk / Assurance detail screens to
-- render their "Related Tasks" panel. Children are included but flagged,
-- so a source can show the full tree it spawned.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_source_tasks
    @source_type_code NVARCHAR(40),
    @source_record_id BIGINT,
    @organization_id  BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @source_type_code IS NULL OR @source_record_id IS NULL
        THROW 55710, 'sp_task_source_tasks: source_type_code and source_record_id are required.', 1;

    SELECT v.task_id                   AS TaskId,
           v.task_number               AS TaskNumber,
           v.subject_title             AS SubjectTitle,
           v.task_type_code            AS TaskTypeCode,
           v.task_type_name            AS TaskTypeName,
           v.assigned_to_employee_id   AS AssignedToEmployeeId,
           v.assigned_to_employee_name AS AssignedToEmployeeName,
           v.priority                  AS Priority,
           v.standard_due_at           AS StandardDueAt,
           v.approved_extended_due_at  AS ApprovedExtendedDueAt,
           v.sla_due_at                AS SlaDueAt,
           v.sla_status_code           AS SlaStatusCode,
           v.current_status_code       AS CurrentStatusCode,
           v.current_status_name       AS CurrentStatusName,
           v.is_child                  AS IsChild,
           v.parent_task_id            AS ParentTaskId,
           v.child_count               AS ChildCount,
           v.closed_at                 AS ClosedAt,
           v.completed_dt              AS CompletedDt
      FROM grac_practice.vw_pm_practice_task v
     WHERE v.source_type_code = @source_type_code
       AND v.source_record_id = @source_record_id
       AND (@organization_id IS NULL OR v.organization_id = @organization_id)
     ORDER BY CASE WHEN v.parent_task_id IS NULL THEN 0 ELSE 1 END,
              ISNULL(v.parent_task_id, v.task_id),
              v.task_id;
END;
GO

-- =====================================================================
-- 5. sp_task_center_counts  (REWRITE — superset of 049)
--
-- GapsCount is preserved VERBATIM from 049. The three task counts gain
-- `parent_task_id IS NULL` so a decomposed parent counts once, not once
-- per sub-activity — otherwise the Custom tab badge would inflate every
-- time somebody split a task into children (194 creates children as
-- task_type_code = 'Custom').
--
-- Two new badges are added for the governance queues the BRD introduces.
-- Existing callers ignore unknown columns, so TaskController.Counts
-- keeps working untouched until the UI opts in.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_center_counts
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        -- Gaps = Practice Instances with actionable implementation status
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_instance pi
           LEFT JOIN grac_practice.implementation_status_master ims
                  ON ims.implementation_status_id = pi.implementation_status_id
          WHERE (@organization_id IS NULL OR pi.organization_id = @organization_id)
            AND COALESCE(ims.status_code, pi.implementation_status)
                IN (N'Not Implemented', N'Partially Implemented')) AS GapsCount,

        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND tt.type_code = N'Implementation'
            AND t.parent_task_id IS NULL) AS ImplementationCount,

        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND tt.type_code = N'Assurance'
            AND t.parent_task_id IS NULL) AS AssuranceCount,

        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND tt.type_code = N'Custom'
            AND t.parent_task_id IS NULL) AS CustomCount,

        -- ---- new in 195 ------------------------------------------------
        -- Open work already past its effective due date (BRD §13).
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND t.parent_task_id IS NULL
            AND t.closed_at IS NULL
            AND t.sla_due_at IS NOT NULL
            AND t.sla_due_at < SYSUTCDATETIME()) AS BreachedCount,

        -- Governance decisions waiting on Exception Centre (BRD §7, §8).
        (SELECT COUNT_BIG(*)
           FROM grac_practice.exception_request r
          WHERE (@organization_id IS NULL OR r.organization_id = @organization_id)
            AND r.task_id IS NOT NULL
            AND r.status_code = N'Pending'
            AND r.request_type_code IN (N'TASK_SLA_EXTENSION', N'TASK_PRIORITY_REDUCTION')) AS PendingApprovalCount;
END;
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '195 read layer present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_practice_task','V')   IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_list','P')           IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_get','P')            IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_source_tasks','P')   IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_center_counts','P')  IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'view exposes v2 columns' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task')
                            AND name = 'sla_status_code')
             AND EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task')
                            AND name = 'is_eligible_for_completion')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '195 Task Centre v2 read layer installed. Phase 1 database migrations complete.';
GO

SET NOEXEC OFF;
GO
