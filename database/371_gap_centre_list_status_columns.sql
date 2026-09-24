-- =====================================================================
-- 371 Gap Centre list: Practice Instance / Task / Risk / Exception
--     status columns
--
-- REQUEST
-- -------
-- Gap Center list must show, in this order: Gap, Status, Practice
-- Instance Status, Task Status, Risk Status, Exception Status, Owner
-- (Raised On and Actions stay, per sir's follow-up; Source and Severity
-- are dropped from the grid -- see gaps.cshtml's own comment and the
-- Web-side migration note for that UI-only change; this migration does
-- not touch either column's data).
--
--   * Practice Instance Status: Implemented if every Obligation on the
--     linked Practice Instance is Implemented, else Not Implemented.
--     Must reflect the CURRENT obligation state, not a value frozen at
--     gap creation.
--   * Task Status: Completed if every Task linked to the gap is
--     Completed/Closed, else Pending. Aggregated at gap level, not the
--     individual Task's own status.
--   * Risk Status: the current status of the Risk linked to the gap,
--     using existing Risk status values; -- (dash) if none.
--   * Exception Status: the current status of the Exception linked to
--     the gap, using existing Exception status values; -- if none.
--
-- No new table, no new business rule, no change to the Gap / Task /
-- Risk / Exception / Practice workflows themselves -- every value below
-- is read from data another migration already computes and keeps
-- current on every save. See each column's own comment for its source.
--
-- WHERE EACH COLUMN ACTUALLY COMES FROM
-- --------------------------------------------------------------------
-- Practice Instance Status
--   practice_gap.gap_status IS ALREADY this exact binary, live. Migration
--   367's sp_practice_gap_sync_for_instance (called by the API after
--   EVERY Obligation save, both bulk-adopt and single local save) closes
--   a practice_gap's gap_status the moment its Active practice_gap_
--   obligation children reach zero -- i.e. every Obligation on that
--   instance is now Implemented (N/A obligations are excluded from the
--   rollup entirely, same as everywhere else in this codebase, 243) --
--   and reopens it the moment a new one appears. So "Implemented" /
--   "Not Implemented" here is simply gap_status re-labelled (Closed ->
--   Implemented, Open -> Not Implemented) for THIS column, not a new
--   computation over practice_instance_obligation -- re-deriving that
--   here would duplicate exactly what 367 already centralized and risk
--   drifting from it. Only a gap materialized from (or, for the
--   un-materialized arm, backed by) a Practice Instance has one; a
--   Custom/Assurance/Exception/Risk-sourced custom_gap has no
--   practice_instance_id and shows NULL (-- on the grid).
--
-- Task Status
--   practice_task rows where subject_entity_type = 'CustomGap' AND
--   subject_entity_id = custom_gap_id -- the exact link sp_custom_gap_
--   linked_artefacts (174) already reads for its own Task result set,
--   just aggregated across every linked Task instead of TOP 1. "Completed
--   or Closed" is entity_status_master.is_terminal = 1 for entity_type
--   'Task' (035's seed: Closed and Cancelled are the two terminal codes;
--   Open/Assigned/InProgress/PendingReview/Escalated/the three
--   Implementation-Task gate codes are not) -- reusing the terminal flag
--   rather than hard-coding status_code strings, so this never drifts
--   from whatever the task engine itself already calls "done". All
--   terminal -> Completed; any non-terminal -> Pending; no Task at all
--   -> NULL (-- on the grid, same empty-state convention as Risk/
--   Exception below -- gap-view.js's own Related Actions cards already
--   show nothing when an artefact does not exist, for the same reason).
--   Only the materialized (custom_gap) arm can have a Task -- an
--   un-materialized practice_gap row has no custom_gap_id for any Task
--   to be linked against, so it is NULL by construction, not computed.
--
-- Risk Status
--   risk_candidate.custom_gap_id = custom_gap_id (same link sp_custom_
--   gap_linked_artefacts' Risk result set uses), most recent by
--   risk_candidate_id. Once registered (risk_candidate.registered_
--   risk_id IS NOT NULL), the "current status of the Risk" is the
--   REGISTERED risk's own risk_register.status_code -- reusing exactly
--   the precedence gap-view.js's buildRiskCard() already applies
--   (registeredId present -> read the register row; else show the
--   candidate's own status_code) -- not a new rule. No Risk linked ->
--   NULL (-- on the grid, per sir's own stated convention).
--
-- Exception Status
--   exception_request.custom_gap_id = custom_gap_id (same link sp_
--   custom_gap_linked_artefacts' Exception result set uses), most
--   recent by exception_request_id, its own status_code verbatim
--   (Pending / SubmittedForApproval / Approved / Rejected / Withdrawn /
--   Expired -- 257's live CHECK constraint). No Exception linked -> NULL
--   (-- on the grid, per sir's own stated convention).
--
-- PERFORMANCE
-- -----------
-- Every new column is a correlated scalar subquery keyed on custom_gap_id
-- / source_reference_id -- the same shape ExistingTaskCount and LinkedCount
-- already use in this exact proc, run once per row returned (a paged,
-- max-200-row result set), never once per related record. No N+1 from
-- the API: this is still the single sp_gap_centre_list round trip the
-- Gap Centre grid has always made.
--
-- WHAT THIS DOES NOT DO
--   * Does not touch practice_gap, practice_gap_obligation, practice_
--     task, risk_candidate, risk_register, or exception_request -- read
--     only, four new SELECT-list expressions.
--   * Does not change what StatusText (the existing Status column) means
--     -- that stays the gap's own lifecycle stage (New/Analysed), exactly
--     as 318/357 left it. Practice Instance Status is a new, separate
--     column so the two are never confused with each other.
--   * Does not change pagination, search, sort order, the @status_code /
--     @source_module_code / @observation_id filters, or which rows are
--     returned -- only which columns are, on the same rows, in the same
--     order.
--
-- Depends on 255/318/319/324/357 (sp_gap_centre_list's current live
-- body), 245/356/367 (practice_gap / sp_practice_gap_sync_for_instance),
-- 035 (entity_status_master), 205 (risk_register/registered_risk_id),
-- 257 (exception_request status vocabulary).
-- Rollback: 371_gap_centre_list_status_columns_rollback.sql restores
-- 357's body verbatim.
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_gap_centre_list','P') IS NULL
BEGIN PRINT 'ABORT (371): sp_gap_centre_list missing (run 255/318/324/357 first).'; SET NOEXEC ON; END
GO

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
        COALESCE(s.state_name, g.status),
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

-- =====================================================================
-- Verification
-- =====================================================================
DECLARE @def371 NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_gap_centre_list','P'));

SELECT '371-a sp_gap_centre_list compiled' AS Check_,
       CASE WHEN @def371 IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '371-b PracticeInstanceStatusText column present',
       CASE WHEN @def371 LIKE '%PracticeInstanceStatusText%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '371-c TaskStatusText column present',
       CASE WHEN @def371 LIKE '%TaskStatusText%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '371-d RiskStatusText column present',
       CASE WHEN @def371 LIKE '%RiskStatusText%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '371-e ExceptionStatusText column present',
       CASE WHEN @def371 LIKE '%ExceptionStatusText%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '371-f existing filters/paging/order untouched',
       CASE WHEN @def371 LIKE '%OFFSET (@page - 1) * @page_size ROWS%'
             AND @def371 LIKE '%ORDER  BY SortBucket,%'
            THEN 'PASS' ELSE 'FAIL' END;

-- Diagnostic -- current status text for every open gap, both arms.
PRINT '--- Diagnostic: new status columns, spot check ---';
EXEC grac_practice.sp_gap_centre_list @page = 1, @page_size = 20;

PRINT '371 complete. Gap Centre list now returns PracticeInstanceStatusText,';
PRINT '    TaskStatusText, RiskStatusText, ExceptionStatusText alongside every';
PRINT '    existing column -- no change to which rows are returned, their';
PRINT '    paging, sort order, or any existing column''s value.';
GO
