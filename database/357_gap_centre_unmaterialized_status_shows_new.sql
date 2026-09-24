-- =====================================================================
-- 357 Gap Centre list: an un-materialized (auto-created) Implementation
-- gap now also shows New, not the raw Obligation status
--
-- SIR'S FEEDBACK
-- ---------------
-- "in gap center there is only 2 status new and analysed. but when auto
--  create a gap it is now displayed as not implemented. please correct"
--
-- ROOT CAUSE
-- ----------
-- Migration 318 already fixed this exact complaint once, for the
-- MATERIALIZED (custom_gap) arm of sp_gap_centre_list: StatusText there
-- comes from gap_lifecycle_state_master.state_name, so a materialized
-- gap only ever shows 'New' or 'Analysed' (175/319's display name for
-- the Delegated state).
--
-- 318 deliberately left the OTHER arm alone -- practice_gap rows that
-- have not yet been materialized into a custom_gap (which is exactly
-- what an auto-created Implementation gap is, from the moment
-- sp_practice_gap_sync_for_instance opens it until somebody opens
-- Analysis on it for the first time). For that arm, StatusText was the
-- worst logged Obligation status instead (Not Implemented / Partially
-- Implemented), on the reasoning that it answered "why does this gap
-- exist" rather than "where is it in its lifecycle."
--
-- That reasoning does not survive this report: it puts a THIRD value in
-- a Status column Sir has now twice said must only ever read New or
-- Analysed. An un-materialized gap has not been analysed -- so it is
-- simply New, the exact state sp_custom_gap_materialize_for_instance
-- (160/320) puts every gap into the moment it IS materialized (New is
-- gap_lifecycle_state_master's is_initial=1 row, seeded 158). There is
-- no reason the row should say anything else before that moment.
--
-- WHAT THIS DOES
-- --------------
-- Re-issues sp_gap_centre_list (324's body, byte for byte otherwise):
--
--   1. Arm 2's (un-materialized practice_gap) StatusText is now the
--      literal N'New' instead of the worst-Obligation-status CASE.
--
--   2. That CASE is not thrown away -- it still decided which
--      un-materialized gap is more urgent than another (Not Implemented
--      ranked above Partially Implemented), and the grid's own final
--      ORDER BY read that ordering back out of StatusText's text. It is
--      kept, unprojected, as a new @results column -- UrgencyRank -- and
--      the ORDER BY now reads that column directly instead of pattern-
--      matching StatusText. The sort order Sir already sees (the more
--      urgent Obligation failures first) is unchanged; only the label
--      is.
--
-- The row's own "not yet analysed" note (gaps.cshtml's sourceNote(),
-- rendered under Source, untouched by this migration) already tells the
-- analyst this New gap has not been through Analysis yet -- the same
-- signal a materialized New gap gives simply by not showing "Analysed".
-- Nothing about WHY the gap exists is lost either: the "N obligation(s)"
-- note under the Title (gaps.cshtml's linkedNote, also untouched) still
-- says how many Obligations are behind it; only the raw Obligation-
-- status text is moved out of the Status column.
--
-- WHAT THIS DOES NOT DO
-- ----------------------
--   * Does not touch RawStatusCode / LifecycleStateCode -- both stay
--     NULL on the un-materialized arm exactly as 318/324 left them; this
--     gap genuinely has no custom_gap row and no lifecycle_state_id yet.
--     IsMaterialized=0 is still the one authoritative flag saying so.
--   * Does not touch the @status_code filter -- it already matches
--     against pgo.logged_status_code directly, never against StatusText,
--     so filtering by Not Implemented / Partially Implemented from the
--     API still works exactly as before.
--   * Does not touch Arm 1 (the materialized/custom_gap arm) at all --
--     318 already fixed its StatusText; this migration only reproduces
--     it verbatim.
--   * Does not re-run sp_practice_gap_sync_for_instance, touch
--     custom_gap, practice_gap, or any lifecycle table -- this is a
--     projection-only change in one read proc.
--
-- SCOPE
-- -----
-- Only the Status column's text for a not-yet-materialized Implementation
-- gap on the Gap Centre LIST screen (sp_gap_centre_list). gap-detail.cshtml
-- and gap-view.cshtml read their own status from sp_custom_gap_header,
-- which only ever runs for a materialized gap and is untouched by this.
--
-- Depends on 255, 318, 324 (sp_gap_centre_list's current live body).
-- Rollback: 357_gap_centre_unmaterialized_status_shows_new_rollback.sql
-- restores 324's body verbatim.
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_gap_centre_list','P') IS NULL
BEGIN PRINT 'ABORT (357): sp_gap_centre_list missing (run 255/318/324 first).'; SET NOEXEC ON; END
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
        -- Migration 357: un-materialized-arm urgency, formerly read back
        -- out of StatusText's own text by the final ORDER BY. Never
        -- projected by either SELECT below -- sort-only. Arm 1 rows
        -- default to 3 (its StatusText never matched the old CASE
        -- either, so this reproduces its existing ordering exactly).
        UrgencyRank        INT           NOT NULL DEFAULT 3,
        SortBucket         INT           NOT NULL
    );

    -- ---- Arm 1: custom_gap, every source module ---------------------
    INSERT INTO @results
        (RowKey, SourceModuleCode, CustomGapId, PracticeGapId, PracticeInstanceId,
         IsMaterialized, Title, Context, StatusText, RawStatusCode, LifecycleStateCode,
         SeverityText, OwnerText,
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
    -- Migration 357: StatusText is now the literal N'New'. This gap has
    -- no lifecycle_state_id yet because it has no custom_gap row yet --
    -- but it has not been analysed either, so New is exactly correct,
    -- and keeps this column to the two values Gap Centre is meant to
    -- ever show. The worst-Obligation-status read that used to BE
    -- StatusText now only drives UrgencyRank (sort-only, see the
    -- @results declaration above) -- WHY this gap exists is still
    -- visible on the row via LinkedCount's "N obligation(s)" note under
    -- the Title (gaps.cshtml, unchanged), so nothing is hidden, only
    -- moved out of the Status column.
    IF (@source_module_code IS NULL OR @source_module_code = N'Implementation')
       AND @observation_id IS NULL
    INSERT INTO @results
        (RowKey, SourceModuleCode, CustomGapId, PracticeGapId, PracticeInstanceId,
         IsMaterialized, Title, Context, StatusText, RawStatusCode, LifecycleStateCode,
         SeverityText, OwnerText,
         DueDate, OpenedDt, LinkedCount,
         InstanceCode, InstanceName, ExistingTaskCount, UrgencyRank, SortBucket)
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
        NULL,                       -- 324: no lifecycle state yet either
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
        0
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
    -- Migration 357: ordering within a bucket now reads UrgencyRank
    -- (computed at insert time above) instead of pattern-matching
    -- StatusText -- StatusText no longer carries Obligation-status text
    -- for the un-materialized arm, and never carried it for the
    -- materialized arm to begin with (318), so this is a like-for-like
    -- re-expression of the exact ordering already in place.
    SELECT RowKey, SourceModuleCode, CustomGapId, PracticeGapId,
           PracticeInstanceId, IsMaterialized, Title, Context,
           StatusText, RawStatusCode, LifecycleStateCode,
           SeverityText, OwnerText, DueDate, OpenedDt,
           LinkedCount, InstanceCode, InstanceName, ExistingTaskCount
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
DECLARE @def357 NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_gap_centre_list','P'));

SELECT '357-a sp_gap_centre_list compiled' AS Check_,
       CASE WHEN @def357 IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '357-b UrgencyRank column now carries the urgency ordering',
       CASE WHEN @def357 LIKE '%UrgencyRank%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '357-c Arm 2 no longer assigns the Obligation-status text to StatusText',
       CASE WHEN @def357 NOT LIKE '%WHEN 1 THEN N''Not Implemented''%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '357-d Final ORDER BY now reads UrgencyRank, not StatusText',
       CASE WHEN @def357 LIKE '%ORDER  BY SortBucket,%UrgencyRank,%'
             OR @def357 LIKE '%ORDER BY SortBucket,%UrgencyRank,%'
            THEN 'PASS' ELSE 'FAIL' END;

-- Diagnostic -- every currently-open, not-yet-materialized Implementation
-- gap: what it used to show in Status vs what it shows now. Purely
-- informational, changes nothing.
PRINT '--- Diagnostic: un-materialized gaps, old vs new Status text ---';
SELECT pg.practice_gap_id                       AS PracticeGapId,
       pi.instance_code                         AS InstanceCode,
       pi.instance_name                         AS InstanceName,
       N'New'                                   AS NowShows,
       (SELECT CASE MIN(CASE pgo.logged_status_code
                             WHEN N'Not Implemented'       THEN 1
                             WHEN N'Partially Implemented' THEN 2
                             ELSE 3 END)
                    WHEN 1 THEN N'Not Implemented'
                    WHEN 2 THEN N'Partially Implemented'
                    ELSE N'Open' END
          FROM  grac_practice.practice_gap_obligation pgo
          WHERE pgo.practice_gap_id = pg.practice_gap_id
            AND pgo.status          = N'Active')      AS PreviouslyShowed
FROM   grac_practice.practice_gap pg
JOIN   grac_practice.practice_instance pi ON pi.practice_instance_id = pg.practice_instance_id
WHERE  pg.gap_status = N'Open'
  AND  NOT EXISTS (
           SELECT 1 FROM grac_practice.custom_gap cg
            WHERE cg.source_reference_type = N'PracticeInstance'
              AND cg.source_reference_id   = pg.practice_instance_id
              AND cg.organization_id       = pi.organization_id)
ORDER BY pg.opened_dt DESC;

PRINT '357 complete. Gap Centre''s list now shows only New or Analysed in';
PRINT '    the Status column, for every row -- materialized (318) and';
PRINT '    un-materialized (this migration) alike. The obligation-urgency';
PRINT '    sort order within the un-materialized group (worse first) is';
PRINT '    unchanged -- it now runs off UrgencyRank instead of StatusText.';
GO
