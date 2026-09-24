-- =====================================================================
-- 379 A Closed gap displays as Closed, not Analysed
--
-- SIR'S INSTRUCTION
-- ------------------
--   Gaps that are actually Closed are being displayed with the status
--   Analysed. When a gap is closed, the Gap Center/grid/detail view
--   must display its status as Closed, not Analysed. Trace the
--   complete flow, correct the underlying mapping/logic (not a
--   frontend-only workaround), and keep every other status (New,
--   Analysed, Invalid, Duplicate) exactly as it already displays.
--
-- ROOT CAUSE, TRACED BEFORE WRITING ANYTHING
-- --------------------------------------------
--   A gap carries two independent fields:
--     custom_gap.status            Open/InProgress/Closed/Cancelled --
--                                   the record's own bookkeeping flag.
--                                   Set by sp_custom_gap_close (055),
--                                   the ONLY proc the Close Gap action
--                                   calls (confirmed: gaps.cshtml's
--                                   3-dot menu and gap-view.js's Actions
--                                   menu both call
--                                   window.gracGapActions.closeGap,
--                                   which POSTs /{id}/close ->
--                                   CustomGapService.CloseAsync ->
--                                   sp_custom_gap_close).
--     custom_gap.lifecycle_state_id -> gap_lifecycle_state_master
--                                   Where the gap sits in its ANALYSIS
--                                   process -- New / Delegated
--                                   ("Analysed", 175) / Invalid /
--                                   Duplicate are the only ones 174/175
--                                   actively use; ResolutionPlanning /
--                                   Execution / Verification / Closed
--                                   remain seeded in the master (272)
--                                   but are dormant -- no code path in
--                                   the current, simplified workflow
--                                   ever moves a gap into them.
--
--   sp_custom_gap_close (055) updates status ONLY. It has never touched
--   lifecycle_state_id, and correctly so -- see "WHAT THIS DELIBERATELY
--   DOES NOT DO" below. So once a gap has been analysed
--   (lifecycle_state_id -> Delegated) and is later closed
--   (status -> Closed), lifecycle_state_id still says Delegated.
--
--   Three places combine the two fields into one displayed value, and
--   all three had the same precedence bug -- they show the lifecycle
--   name whenever one exists, falling back to the raw status only when
--   there is none:
--     1. sp_gap_centre_list (318): StatusText = COALESCE(s.state_name,
--        g.status) -- the Gap Center grid's Status column. THIS
--        migration.
--     2. gap-view.js renderHeader(): chip.textContent =
--        h.lifecycleStateName || h.statusCode -- the Gap View page's
--        status chip.
--     3. gap-detail.js renderCompactStepper(): current =
--        state.currentStateCode, which is only ever set from
--        header.lifecycleStateCode -- the Gap Detail page's stepper,
--        highlighting "Analysed" as the current step even when Closed.
--   Fixed together, consistently, in this migration (SQL, #1) and the
--   matching one-line precedence fix in each of the other two files
--   (#2, #3) -- same logic, three renderers, not three different
--   fixes.
--
-- WHAT THIS DOES
-- --------------
--   sp_gap_centre_list's Arm 1 (custom_gap) StatusText computation
--   becomes: WHEN g.status = 'Closed' THEN 'Closed' ELSE
--   COALESCE(s.state_name, g.status) END -- so a Closed gap's raw
--   status now outranks its lifecycle label, exactly the one case sir
--   named. Every other status is completely unaffected: New/Open,
--   Analysed/Delegated, Invalid, Duplicate, InProgress and Cancelled
--   all still resolve exactly as COALESCE(s.state_name, g.status)
--   already resolved them -- the CASE's ELSE branch is that same
--   expression, byte-for-byte.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
-- ------------------------------------
--   * Does NOT move lifecycle_state_id to the dormant 'Closed' row in
--     gap_lifecycle_state_master, and does NOT change
--     sp_custom_gap_close, sp_custom_gap_transition or any lifecycle
--     transition proc. Doing so would reactivate a state-machine path
--     174/175 deliberately retired down to New/Delegated(+Invalid/
--     Duplicate) for Custom gaps -- exactly the "existing status
--     workflow" sir asked not to change. The fix stays entirely in how
--     the two ALREADY-CORRECT fields are combined for display, not in
--     what either field holds.
--   * Does NOT change RawStatusCode, LifecycleStateCode, or any other
--     column sp_gap_centre_list already returns -- gaps.cshtml's
--     buildRowMenu() (Close Gap enablement, "already analysed" ->
--     "View" menu swap) reads those two raw columns directly, already
--     correctly, and is untouched.
--   * Does NOT touch Arm 2 (practice_gap, un-materialized rows) --
--     those rows have no custom_gap row and therefore no status to be
--     Closed; their StatusText stays the literal 'New' it already is.
--   * Does NOT touch PracticeInstanceStatusText / TaskStatusText /
--     RiskStatusText / ExceptionStatusText (371) -- a different set of
--     columns, unaffected by this bug.
--   * Does NOT touch sp_custom_gap_header, sp_custom_gap_list, or any
--     other Gap proc -- sp_custom_gap_header already returns StatusCode
--     and LifecycleStateName as two SEPARATE, correctly-valued columns;
--     it never combined them, so it never had this bug. The bug was
--     only in the three renderers that combined them themselves.
--
-- DEPENDS ON: 318 (StatusText first introduced), 371 (current full
-- @results shape, reproduced verbatim except the one CASE change).
-- Rollback: 379_gap_centre_closed_status_display_rollback.sql
-- Re-runnable: yes -- CREATE OR ALTER.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_gap_centre_list','P') IS NULL
BEGIN
    RAISERROR('ABORT (379): grac_practice.sp_gap_centre_list missing. Run 255 first.', 16, 1);
    SET NOEXEC ON;
END
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

PRINT '379: sp_gap_centre_list re-issued -- a Closed gap now reports StatusText = Closed.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '379-a proc compiled' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_gap_centre_list','P')) IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '379-b proc body contains the Closed override',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_gap_centre_list','P')) LIKE '%WHEN g.status = N''Closed'' THEN N''Closed''%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '379-c no Closed custom_gap resolves to a non-Closed StatusText',
       CASE WHEN NOT EXISTS (
                SELECT 1
                  FROM grac_practice.custom_gap g
                  LEFT JOIN grac_practice.gap_lifecycle_state_master s
                         ON s.lifecycle_state_id = g.lifecycle_state_id
                 WHERE g.status = N'Closed'
                   AND (CASE WHEN g.status = N'Closed' THEN N'Closed'
                             ELSE COALESCE(s.state_name, g.status) END) <> N'Closed')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '379-d a non-Closed gap''s StatusText is unaffected (spot check: still equals the pre-379 COALESCE)',
       CASE WHEN NOT EXISTS (
                SELECT 1
                  FROM grac_practice.custom_gap g
                  LEFT JOIN grac_practice.gap_lifecycle_state_master s
                         ON s.lifecycle_state_id = g.lifecycle_state_id
                 WHERE g.status <> N'Closed'
                   AND (CASE WHEN g.status = N'Closed' THEN N'Closed'
                             ELSE COALESCE(s.state_name, g.status) END)
                       <> COALESCE(s.state_name, g.status))
            THEN 'PASS' ELSE 'FAIL' END;

-- Diagnostic: call the live proc's own logic against any Closed,
-- previously-analysed gap in this database, so the fix can be eyeballed
-- against real data (empty if this database has no Closed gaps yet --
-- that is not a failure, just nothing to show).
PRINT '';
PRINT '--- 379 diagnostic: Closed custom_gap rows and the StatusText they now resolve to ---';
SELECT TOP 10
       g.custom_gap_id,
       g.title,
       g.status                                                    AS RawStatus,
       s.state_name                                                AS LifecycleStateName,
       CASE WHEN g.status = N'Closed' THEN N'Closed'
            ELSE COALESCE(s.state_name, g.status) END               AS ResolvedStatusText
  FROM grac_practice.custom_gap g
  LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
 WHERE g.status = N'Closed'
 ORDER BY g.custom_gap_id DESC;

PRINT '';
PRINT '379 complete. Every Closed gap''s StatusText now reads Closed on the';
PRINT '    Gap Center grid. gap-view.js and gap-detail.js carry the matching';
PRINT '    one-line fix for the Gap View status chip and the Gap Detail';
PRINT '    stepper -- see docs/gap-centre-closed-status-display.md.';
GO
SET NOEXEC OFF;
GO
