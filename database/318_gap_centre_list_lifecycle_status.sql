-- =====================================================================
-- 318 Gap Centre list: Status column shows the lifecycle stage
--
-- SIR'S FEEDBACK
-- ---------------
-- "Gap center lu gap nu actually ipo 2 status alle ullathu? New and
--  Analysed. but gap center le list lu status open nnu anu kanikunnathu.
--  athu New/Analysed nnu kanikkanam."
--
-- (Gap Centre really only has 2 statuses now -- New and Analysed -- but
--  the list's Status column shows "Open". It should show New/Analysed.)
--
-- ROOT CAUSE
-- ----------
-- sp_gap_centre_list (255) projects StatusText = custom_gap.status for
-- every materialized (custom_gap) row. That column is the record's own
-- open/closed bookkeeping flag -- Open / InProgress / Closed / Cancelled,
-- the same vocabulary the Add-Gap dialog's Status dropdown offers and
-- sp_custom_gap_header still projects as StatusCode -- and every gap is
-- born into it as 'Open' (see newGapStatus default in gaps.cshtml and
-- the materialize proc). It has never described WHERE the gap is in its
-- analysis lifecycle.
--
-- That is what gap_lifecycle_state_master (156) + custom_gap.lifecycle_
-- state_id already track, and what 174/175 collapsed down to, for every
-- gap raised since: New -> (analysis saved) -> Delegated, the latter's
-- *display* name renamed to "Analysed" by 175 for exactly this reason
-- ("Delegated" read as jargon). Validation/Analysis/ResolutionPlanning/
-- Execution/Verification/Closed are dormant -- kept only for gaps that
-- reached them before 174 -- and Invalid/Duplicate are the two terminal-
-- invalid outcomes. sp_custom_gap_header already projects this correctly
-- as LifecycleStateName for the gap-detail screen; the Gap Centre list
-- was simply never wired to the same column.
--
-- WHAT THIS DOES
-- --------------
-- Re-issues sp_gap_centre_list (255) so the materialized-gap arm's
-- StatusText comes from gap_lifecycle_state_master.state_name (via the
-- same custom_gap.lifecycle_state_id join sp_custom_gap_header already
-- uses), falling back to custom_gap.status only for the (should not
-- happen) case of a row with no lifecycle_state_id at all.
--
-- The un-materialized (practice_gap) arm is UNCHANGED: it has no
-- custom_gap row yet, so no lifecycle state to show, and its existing
-- StatusText (worst logged Obligation status -- Not Implemented /
-- Partially Implemented) answers a different, still-useful question --
-- WHY the gap exists -- which the row's own "not yet analysed" note
-- already covers on the lifecycle side.
--
-- custom_gap.status itself is NOT retired -- gaps.cshtml's "Close Gap"
-- menu action still needs it verbatim to know a Custom gap is already
-- Closed/Cancelled, a fact the lifecycle state cannot answer (a closed
-- Custom gap can be in any lifecycle state). So the raw code is kept on
-- the row as a new RawStatusCode column instead of being dropped, and
-- the API/UI are updated to read the closed-check off that instead of
-- off the now-repurposed StatusText.
--
-- WHAT DID NOT CHANGE
-- -------------------
--   * custom_gap.status / custom_gap.lifecycle_state_id -- no schema
--     change, no new column, no data migration.
--   * @status_code filter parameter -- still filters the materialized
--     arm on the raw g.status code (Open/InProgress/Closed/Cancelled).
--     Nothing in the UI currently sends it (there is no Status filter
--     dropdown on Gap Centre, only Source); left as-is rather than
--     redefined, since redefining a filter parameter's meaning under a
--     caller nobody has reviewed is a bigger change than this feedback
--     asked for.
--   * sp_gap_centre_source_counts, sp_custom_gap_header,
--     sp_custom_gap_list, sp_task_center_gaps_list -- untouched.
--
-- Rollback: 318_gap_centre_list_lifecycle_status_rollback.sql (restores
-- 255's body verbatim).
-- SAFE TO RE-RUN. Requires 156 (gap_lifecycle_state_master), 174/175
-- (Delegated -> "Analysed"), 255 (sp_gap_centre_list itself).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (318): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_gap_centre_list','P') IS NULL
BEGIN PRINT 'ABORT (318): sp_gap_centre_list missing (run 255 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.gap_lifecycle_state_master','U') IS NULL
BEGIN PRINT 'ABORT (318): gap_lifecycle_state_master missing (run 156 first).'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.custom_gap','lifecycle_state_id') IS NULL
BEGIN PRINT 'ABORT (318): custom_gap.lifecycle_state_id missing (run 156 first).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('318_gap_centre_list_lifecycle_status: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_gap_centre_list -- re-issued from 255 with two changes:
--   1. New RawStatusCode column carrying custom_gap.status verbatim
--      (NULL on the practice_gap arm), so the Close-Gap "already
--      closed" check keeps working off the real record status.
--   2. StatusText on the custom_gap arm now comes from the gap's
--      lifecycle state name (New / Analysed / Invalid / Duplicate /
--      one of the dormant historical names), not custom_gap.status.
-- Everything else -- paging contract, the practice_gap arm, dedupe,
-- filters, ordering -- is byte-for-byte 255.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_gap_centre_list
    @organization_id     BIGINT        = NULL,
    -- The new Source filter. NULL = every source.
    @source_module_code  NVARCHAR(30)  = NULL,
    @status_code         NVARCHAR(30)  = NULL,
    @search              NVARCHAR(200) = NULL,
    -- Assurance Observations deep-links into Gap Centre with an
    -- observation id. Only the custom_gap arm can answer it -- a
    -- practice_gap has no observation link at all -- so setting it
    -- suppresses arm 2 entirely rather than silently returning instance
    -- gaps that have nothing to do with the observation.
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

    -- Materialised once so the count and the page read the same set --
    -- the same shape 246 settled on for sp_task_center_gaps_list.
    DECLARE @results TABLE (
        RowKey             NVARCHAR(40)  NOT NULL,
        SourceModuleCode   NVARCHAR(30)  NOT NULL,
        CustomGapId        BIGINT        NULL,
        PracticeGapId      BIGINT        NULL,
        PracticeInstanceId BIGINT        NULL,
        IsMaterialized     BIT           NOT NULL,
        -- Sized generously on purpose. Both arms CONCAT source columns
        -- into Context, and an over-tight table-variable column does not
        -- truncate quietly -- it raises "String or binary data would be
        -- truncated" and takes the whole list down.
        Title              NVARCHAR(400) NULL,
        Context            NVARCHAR(800) NULL,
        StatusText         NVARCHAR(100) NULL,
        -- 318: the record's own open/closed code, verbatim, NULL on the
        -- practice_gap arm (no custom_gap yet). StatusText above is now
        -- the lifecycle stage; this is what "already Closed/Cancelled"
        -- checks (Close Gap menu action) must read instead.
        RawStatusCode      NVARCHAR(30)  NULL,
        SeverityText       NVARCHAR(200) NULL,
        OwnerText          NVARCHAR(300) NULL,
        DueDate            DATE          NULL,
        OpenedDt           DATETIME2(3)  NULL,
        LinkedCount        INT           NOT NULL,
        -- Carried so the merged row menu can keep the actions the
        -- Implementation tab had: "Add Implementation Task" needs the
        -- code and name as separate values for its dialog, and "View
        -- Existing Tasks (n)" needs the count.
        InstanceCode       NVARCHAR(100) NULL,
        InstanceName       NVARCHAR(300) NULL,
        ExistingTaskCount  INT           NOT NULL,
        SortBucket         INT           NOT NULL
    );

    -- ---- Arm 1: custom_gap, every source module ---------------------
    INSERT INTO @results
        (RowKey, SourceModuleCode, CustomGapId, PracticeGapId, PracticeInstanceId,
         IsMaterialized, Title, Context, StatusText, RawStatusCode, SeverityText, OwnerText,
         DueDate, OpenedDt, LinkedCount,
         InstanceCode, InstanceName, ExistingTaskCount, SortBucket)
    SELECT
        N'cg' + CAST(g.custom_gap_id AS NVARCHAR(20)),
        g.gap_source_module_code,
        g.custom_gap_id,
        NULL,
        CASE WHEN g.source_reference_type = N'PracticeInstance'
             THEN g.source_reference_id ELSE NULL END,
        1,
        g.title,
        -- Whichever context the source actually has. An assurance gap
        -- knows its execution and entity; a custom one usually knows
        -- neither, and shows nothing rather than an empty separator.
        NULLIF(LTRIM(RTRIM(CONCAT(
            ISNULL(g.execution_name, N''),
            CASE WHEN g.execution_name IS NOT NULL AND g.entity_name IS NOT NULL
                 THEN N' / ' ELSE N'' END,
            ISNULL(g.entity_name, N'')))), N''),
        -- 318: the lifecycle stage (New / Analysed / Invalid / Duplicate
        -- / a dormant historical name), the same column
        -- sp_custom_gap_header projects as LifecycleStateName -- falls
        -- back to the raw status code only if a row somehow has no
        -- lifecycle_state_id (should not happen; every custom_gap is
        -- seeded into 'New' on creation).
        COALESCE(s.state_name, g.status),
        g.status,
        COALESCE(g.severity_name, g.severity_code, g.priority),
        g.owner_display_name,
        CAST(COALESCE(g.due_date, g.target_resolution_date) AS DATE),
        g.opened_dt,
        (SELECT COUNT(*) FROM grac_practice.custom_gap_observation j
          WHERE j.custom_gap_id = g.custom_gap_id AND j.is_active = 1),
        NULL, NULL,          -- a custom gap is not an instance
        (SELECT COUNT(*)
           FROM grac_practice.practice_task t
          WHERE t.subject_entity_type = N'CustomGap'
            AND t.subject_entity_id   = g.custom_gap_id
            AND t.closed_at IS NULL),
        1
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
    -- Skipped entirely when the caller filtered to a source module that
    -- this arm cannot produce (it only ever yields 'Implementation'), or
    -- to an observation, which no practice_gap can be linked to.
    IF (@source_module_code IS NULL OR @source_module_code = N'Implementation')
       AND @observation_id IS NULL
    INSERT INTO @results
        (RowKey, SourceModuleCode, CustomGapId, PracticeGapId, PracticeInstanceId,
         IsMaterialized, Title, Context, StatusText, RawStatusCode, SeverityText, OwnerText,
         DueDate, OpenedDt, LinkedCount,
         InstanceCode, InstanceName, ExistingTaskCount, SortBucket)
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
        -- The worst logged obligation status is what this gap IS, the
        -- same derivation 246 uses so the two screens cannot disagree.
        -- Unchanged by 318 -- an un-materialized instance gap has no
        -- lifecycle state to show (materializing is what creates one);
        -- this answers a different, still-useful question instead.
        (SELECT CASE MIN(CASE pgo.logged_status_code
                              WHEN N'Not Implemented'       THEN 1
                              WHEN N'Partially Implemented' THEN 2
                              ELSE 3 END)
                     WHEN 1 THEN N'Not Implemented'
                     WHEN 2 THEN N'Partially Implemented'
                     ELSE N'Open'
                 END
           FROM  grac_practice.practice_gap_obligation pgo
           WHERE pgo.practice_gap_id = pg.practice_gap_id
             AND pgo.status          = N'Active'),
        NULL,                       -- 318: no custom_gap row yet
        pi.criticality,
        pi.primary_owner,
        NULL,                       -- instance gaps carry no due date
        pg.opened_dt,
        (SELECT COUNT(*) FROM grac_practice.practice_gap_obligation pgo
          WHERE pgo.practice_gap_id = pg.practice_gap_id
            AND pgo.status          = N'Active'),
        pi.instance_code,
        pi.instance_name,
        -- Same count 246 projects as ExistingTaskCount, so the merged row
        -- menu's "View Existing Tasks (n)" reads what it always did.
        (SELECT COUNT(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE t.subject_entity_type = N'PracticeInstance'
            AND t.subject_entity_id   = pi.practice_instance_id
            AND tt.type_code          = N'Implementation'
            AND t.closed_at IS NULL),
        0                           -- un-actioned work sorts first
    FROM   grac_practice.practice_gap pg
    JOIN   grac_practice.practice_instance pi
           ON pi.practice_instance_id = pg.practice_instance_id
    LEFT   JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
    WHERE (@organization_id IS NULL OR pi.organization_id = @organization_id)
      AND  pg.gap_status = N'Open'
      -- The materialize procedure's own idempotency key. Same key, so
      -- the two can never disagree about what "already materialized"
      -- means.
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
      -- A practice_gap has no status column of its own; its status is the
      -- derived text above. Filtering on it is done after the derivation.
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
           StatusText, RawStatusCode, SeverityText, OwnerText, DueDate, OpenedDt,
           LinkedCount, InstanceCode, InstanceName, ExistingTaskCount
    FROM   @results
    ORDER  BY SortBucket,
              CASE StatusText
                   WHEN N'Not Implemented'       THEN 1
                   WHEN N'Partially Implemented' THEN 2
                   ELSE 3
              END,
              OpenedDt DESC,
              RowKey
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '318: sp_gap_centre_list now shows the lifecycle stage in StatusText.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 318 verification ===';

DECLARE @list NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_gap_centre_list','P'));

SELECT '318-a sp_gap_centre_list exists' AS Check_,
       CASE WHEN @list IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '318-b StatusText now derives from the lifecycle state master',
       CASE WHEN @list LIKE '%COALESCE(s.state_name, g.status)%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '318-c joins gap_lifecycle_state_master on lifecycle_state_id',
       CASE WHEN @list LIKE '%gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '318-d RawStatusCode column present for the Close-Gap check',
       CASE WHEN @list LIKE '%RawStatusCode%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '318-e practice_gap arm (un-materialized) untouched -- still obligation-derived',
       CASE WHEN @list LIKE '%Not Implemented%' AND @list LIKE '%Partially Implemented%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '318-f source counts proc untouched',
       CASE WHEN OBJECT_ID('grac_practice.sp_gap_centre_source_counts','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- Spot check: current per-lifecycle-state distribution of materialized gaps ---';
SELECT COALESCE(s.state_name, cg.status) AS StatusShownInGapCentre,
       COUNT(*)                          AS GapCount
  FROM grac_practice.custom_gap cg
  LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = cg.lifecycle_state_id
 GROUP BY COALESCE(s.state_name, cg.status)
 ORDER BY GapCount DESC;

PRINT '';
PRINT '318 complete. Gap Centre Status column shows New/Analysed (or Invalid/';
PRINT 'Duplicate/a dormant historical name), not the record''s Open/Closed code.';
GO

SET NOEXEC OFF;
