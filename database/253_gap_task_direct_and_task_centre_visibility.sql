-- =====================================================================
-- 253 Gap remediation opens a Task directly, and Task Centre shows it
--
-- SYMPTOM: after 252 fixed the save error, saving Gap Analysis with
--      remediation_possible = 'Y' reported "Auto-created: a Task" but no
--      task appeared anywhere in Task Centre.
--
-- CAUSE: three independent breaks in the same chain.
--
--   1. Migration 199 rerouted sp_custom_gap_task_create to raise a Task
--      *Candidate* instead of a Task. TaskId came back NULL by design --
--      no task exists until the candidate is approved.
--
--   2. The Task Candidates tab was retired from Task Centre
--      (tasks.cshtml: "nothing renders it because no tab reaches it"),
--      so the candidate had no surface to be approved from. The work sat
--      in task_candidate, reachable by nothing.
--
--   3. Even an approved candidate would not have shown. Gap work is
--      opened as task_type_code = 'Rectification', but sp_task_list is
--      only ever asked for 'Implementation', 'Assurance', 'Custom' and
--      the event-driven set, and it filters strictly on equality.
--      sp_task_center_counts counts the same three. 'Rectification' was
--      listed nowhere and counted nowhere.
--
-- DECISION (sir): revert the gap seam to direct task creation, and widen
--      the Custom Tasks tab to carry Rectification, rather than adding a
--      fifth tab. The candidate model itself is NOT withdrawn -- Risk and
--      Assurance Observation sources keep raising candidates through
--      199's other rewrites, which this migration does not touch.
--
-- SCOPE
--   1. sp_custom_gap_task_create  -- 174's direct-task body restored,
--                                    keeping 199's priority carry-forward
--   2. sp_task_list               -- 195's body, tab->type predicate widened
--   3. sp_task_center_counts      -- 247's body, CustomCount widened
--
-- Callers are unchanged: sp_custom_gap_analysis_save (252) still calls
-- sp_custom_gap_task_create at the same seam with the same parameters,
-- and the Web tier still asks for taskTypeCode=Custom. The widening
-- lives in the one predicate that owns the tab -> type mapping.
--
-- SAFE TO RE-RUN. Requires 037 (task types), 174, 195, 247, 252.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (253): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_task_open','P') IS NULL
BEGIN PRINT 'ABORT (253): sp_task_open missing (run 196 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NULL
BEGIN PRINT 'ABORT (253): vw_pm_practice_task missing (run 195 first).'; SET @ok = 0; END
-- Guarded on the table's existence first: a bare reference to a missing
-- table aborts the batch with "Invalid object name" instead of printing
-- the ABORT line this block exists to print.
IF OBJECT_ID('grac_practice.task_type_master','U') IS NULL
BEGIN PRINT 'ABORT (253): task_type_master missing (run 037 first).'; SET @ok = 0; END
ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.task_type_master WHERE type_code = N'Rectification')
BEGIN PRINT 'ABORT (253): task type Rectification missing (run 037 first).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('253_gap_task_direct_and_task_centre_visibility: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_custom_gap_task_create -- back to opening a Task directly
--
-- 174's body, with two things carried forward from 199 rather than
-- thrown away:
--
--   * PRIORITY. 174 hardcoded 'Medium'; 199 carried the gap's own
--     priority through. BRD section 5 says urgency is upstream's call, so
--     199 was right and the value is kept.
--   * RESULT SET. 199 returned (TaskCandidateId, TaskId, Created); 174
--     returned (TaskId, Created). This emits the superset -- all three
--     columns, TaskCandidateId always NULL -- so a consumer written
--     against either shape still binds.
--
-- IDEMPOTENCY is unchanged in meaning: one open task per gap. Re-saving
-- an analysis returns the existing task and creates nothing.
--
-- ORPHANED CANDIDATES: a gap analysed between 199 and this migration
-- left an open GAP_REMEDIATION candidate and no task. Re-saving that
-- gap's analysis now opens the task (the check below looks in
-- practice_task, finds nothing, and proceeds). The stale candidate row
-- is left in place -- it is history, and this migration does not delete
-- operator data. The verification section reports how many exist.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_task_create
    @custom_gap_id           BIGINT,
    @assigned_to_employee_id BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @custom_gap_id IS NULL
        THROW 55500, 'sp_custom_gap_task_create: custom_gap_id is required.', 1;

    -- Idempotent per gap: one open task per gap.
    DECLARE @existing_id BIGINT =
        (SELECT TOP 1 task_id
           FROM grac_practice.practice_task
          WHERE subject_entity_type = N'CustomGap'
            AND subject_entity_id   = @custom_gap_id
            AND closed_at IS NULL
          ORDER BY task_id DESC);
    IF @existing_id IS NOT NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT) AS TaskCandidateId,
               @existing_id         AS TaskId,
               CAST(0 AS BIT)       AS Created;
        RETURN;
    END

    DECLARE @org_id BIGINT, @gap_title NVARCHAR(250),
            @gap_priority NVARCHAR(30), @summary NVARCHAR(MAX);

    SELECT @org_id       = organization_id,
           @gap_title    = title,
           @gap_priority = priority
      FROM grac_practice.custom_gap
     WHERE custom_gap_id = @custom_gap_id;

    IF @org_id IS NULL
        THROW 55501, 'sp_custom_gap_task_create: custom_gap not found.', 1;

    SELECT @summary = recommended_action_summary
      FROM grac_practice.custom_gap_analysis WHERE custom_gap_id = @custom_gap_id;

    -- Carried from 199: the gap's own priority drives the task. Anything
    -- outside the four valid values falls back to Medium.
    IF @gap_priority NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @gap_priority = N'Medium';

    -- T-SQL: EXEC parameters can't take expressions; precompute the title.
    DECLARE @task_id    BIGINT;
    DECLARE @task_title NVARCHAR(250) = LEFT(CONCAT(N'Gap task: ', @gap_title), 250);
    BEGIN TRY
        EXEC grac_practice.sp_task_open
            @organization_id         = @org_id,
            @task_type_code          = N'Rectification',
            @subject_entity_type     = N'CustomGap',
            @subject_entity_id       = @custom_gap_id,
            @subject_title           = @task_title,
            @subject_description     = @summary,
            @priority                = @gap_priority,
            @origin_code             = N'Custom',
            @assigned_to_employee_id = @assigned_to_employee_id,
            @actor_employee_id       = @assigned_to_employee_id,
            @task_id                 = @task_id OUTPUT;
    END TRY
    BEGIN CATCH
        DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
        THROW 55502, @msg, 1;
    END CATCH

    SELECT CAST(NULL AS BIGINT) AS TaskCandidateId,
           @task_id             AS TaskId,
           CAST(1 AS BIT)       AS Created;
END
GO
PRINT '253: sp_custom_gap_task_create opens a Task directly again.';
GO

-- =====================================================================
-- 2. sp_task_list -- Custom tab also carries Rectification
--
-- 195's body verbatim except for the task-type predicate. This is the
-- single place that maps a Task Centre tab onto a task type, so widening
-- it here means no Web or API change: the UI still sends
-- taskTypeCode=Custom.
--
-- Deliberately NOT symmetric -- asking for 'Rectification' explicitly
-- still returns only Rectification. Only the 'Custom' tab widens.
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
PRINT '253: sp_task_list Custom tab now includes Rectification.';
GO

-- =====================================================================
-- 3. sp_task_center_counts -- CustomCount matches the widened tab
--
-- 247's body (NOT 195's -- 247 is the live version; it rebased GapsCount
-- onto practice_gap and dropped the two 195 badges the UI never read).
-- Only CustomCount changes, so the badge and the list agree.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_center_counts
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        -- Migration 247: Gaps = distinct practice instances with an Open
        -- persistent gap. Matches sp_task_center_gaps_list exactly.
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_gap pg
           JOIN grac_practice.practice_instance pi
                  ON pi.practice_instance_id = pg.practice_instance_id
          WHERE (@organization_id IS NULL OR pi.organization_id = @organization_id)
            AND pg.gap_status = N'Open') AS GapsCount,

        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND tt.type_code = N'Implementation') AS ImplementationCount,

        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND tt.type_code = N'Assurance') AS AssuranceCount,

        -- Migration 253: same widening as sp_task_list, so the badge and
        -- the Custom tab can never disagree.
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND tt.type_code IN (N'Custom', N'Rectification')) AS CustomCount;
END
GO
PRINT '253: sp_task_center_counts CustomCount includes Rectification.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 253 verification ===';

DECLARE @gaptask NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_task_create','P'));
DECLARE @list    NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_list','P'));
DECLARE @counts  NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_center_counts','P'));

SELECT '253-a gap seam opens a task (sp_task_open)' AS Check_,
       CASE WHEN @gaptask LIKE '%sp_task_open%'              THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '253-b gap seam no longer raises a candidate',
       CASE WHEN @gaptask NOT LIKE '%sp_task_candidate_create%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '253-c gap seam carries the gap priority (199 kept)',
       CASE WHEN @gaptask LIKE '%@gap_priority%'             THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '253-d gap seam still emits TaskCandidateId column',
       CASE WHEN @gaptask LIKE '%AS TaskCandidateId%'        THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '253-e list widens Custom to Rectification',
       CASE WHEN @list LIKE '%@task_type_code = N''Custom'' AND v.task_type_code = N''Rectification''%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '253-f list keeps 195 filters (sla_status_code)',
       CASE WHEN @list LIKE '%@sla_status_code%'             THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '253-g counts widen CustomCount',
       CASE WHEN @counts LIKE '%IN (N''Custom'', N''Rectification'')%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '253-h counts keep 247 GapsCount from practice_gap',
       CASE WHEN @counts LIKE '%practice_gap%'               THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- 252 must still be in place; 253 depends on that caller being correct.
SELECT '253-i sp_custom_gap_analysis_save still has 252 shape',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P'))
                 LIKE '%@remediation_possible%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- Informational: gaps analysed between 199 and 253 ---';
PRINT 'Open GAP_REMEDIATION candidates with no task yet. Re-saving each';
PRINT 'gap analysis opens its task. Nothing is deleted by this migration.';

SELECT c.task_candidate_id  AS TaskCandidateId,
       c.source_record_id   AS CustomGapId,
       c.source_reference   AS SourceReference,
       c.candidate_title    AS CandidateTitle,
       c.status_code        AS StatusCode
  FROM grac_practice.task_candidate c
 WHERE c.source_type_code  = N'Gap'
   AND c.source_dedupe_key = N'GAP_REMEDIATION'
   AND c.status_code IN (N'New', N'Validated')
   AND NOT EXISTS (SELECT 1
                     FROM grac_practice.practice_task t
                    WHERE t.subject_entity_type = N'CustomGap'
                      AND t.subject_entity_id   = c.source_record_id
                      AND t.closed_at IS NULL)
 ORDER BY c.task_candidate_id;

PRINT '';
PRINT '253 complete. Gap analysis opens a Task; it lands in Custom Tasks.';
GO

SET NOEXEC OFF;
GO
