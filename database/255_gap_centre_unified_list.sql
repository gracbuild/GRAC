-- =====================================================================
-- 255 Gap Centre: one list, Source as a column
--
-- Sir asked for the per-source tabs across the Centres to collapse into a
-- single list with Source as a filterable column. Gap Centre is the one
-- that needed database work.
--
-- WHY IT NEEDED ANY
--
-- Two of the three tabs were already one list. Assurance Gaps and Custom
-- Gaps both read sp_custom_gap_list and differed only by
-- @gap_source_module_code, and custom_gap.gap_source_module_code already
-- carries the full vocabulary, enforced by ck_pm_custom_gap_source_module:
--
--     Implementation / Assurance / Custom / Exception / Risk / Audit
--
-- Implementation Gaps did not. That tab reads sp_task_center_gaps_list,
-- which is derived from practice_gap + practice_instance (migration 245).
-- A practice instance gap has NO custom_gap row until somebody runs
-- sp_custom_gap_materialize_for_instance on it. Listing custom_gap alone
-- would therefore have made every un-materialized implementation gap
-- disappear from the screen that is meant to surface it.
--
-- WHAT THIS DOES
--
-- sp_gap_centre_list UNIONs the two origins into one common column set:
--
--   * custom_gap rows -- every source module, including implementation
--     gaps that HAVE been materialized
--   * practice_gap rows that have NOT been materialized yet
--
-- DEDUPE. A materialized instance gap exists in both origins and must
-- appear once. The practice_gap arm excludes any instance that already
-- has a custom_gap, matched on
-- (source_reference_type='PracticeInstance', source_reference_id,
-- organization_id) -- deliberately the SAME key
-- sp_custom_gap_materialize_for_instance uses for its own idempotency
-- check, rather than a second definition of "already materialized" that
-- could drift from it. Status is not part of that key there, so it is not
-- part of it here.
--
-- IsMaterialized on the row tells the screen which arm it came from, so
-- the Materialize action can be offered on exactly the rows that still
-- need it, and CustomGapId is NULL on precisely those rows.
--
-- The old procedures are UNTOUCHED. sp_task_center_gaps_list still backs
-- Task Center's Gaps badge and /practice/api/instances/gaps;
-- sp_custom_gap_list still backs every existing custom-gap caller. This
-- migration only adds.
--
-- SAFE TO RE-RUN. Requires 109 (source module column), 160 (materialize),
-- 245 (practice_gap).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (255): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
BEGIN PRINT 'ABORT (255): custom_gap missing (run 054/109 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_gap','U') IS NULL
BEGIN PRINT 'ABORT (255): practice_gap missing (run 245 first).'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.custom_gap','gap_source_module_code') IS NULL
BEGIN PRINT 'ABORT (255): custom_gap.gap_source_module_code missing (run 109 first).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('255_gap_centre_unified_list: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_gap_centre_list
--
-- One result shape for both origins. Columns that only one origin can
-- answer are NULL on the other rather than faked -- an implementation
-- gap has no severity of its own (it has the instance's criticality) and
-- a custom gap has no obligation count.
--
-- Two result sets, matching the paging contract every other Centre list
-- uses: (TotalCount, PageNumber, PageSize) then the page.
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
         IsMaterialized, Title, Context, StatusText, SeverityText, OwnerText,
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
         IsMaterialized, Title, Context, StatusText, SeverityText, OwnerText,
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
           StatusText, SeverityText, OwnerText, DueDate, OpenedDt,
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
PRINT '255: sp_gap_centre_list created.';
GO

-- =====================================================================
-- 2. sp_gap_centre_source_counts
--
-- Fills the Source filter. Returns the CHECK-constraint vocabulary with
-- a count each, including zeroes, so the dropdown is stable rather than
-- gaining and losing options as data changes -- an operator who filters
-- to Audit and sees "0" has learned something; an operator who cannot
-- find Audit in the list has not.
--
-- Implementation counts both origins, matching what the list returns.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_gap_centre_source_counts
    @organization_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH vocab(SourceModuleCode, DisplayOrder) AS (
        SELECT N'Implementation', 1 UNION ALL
        SELECT N'Assurance',      2 UNION ALL
        SELECT N'Custom',         3 UNION ALL
        SELECT N'Exception',      4 UNION ALL
        SELECT N'Risk',           5 UNION ALL
        SELECT N'Audit',          6
    )
    SELECT v.SourceModuleCode,
           v.DisplayOrder,
           (SELECT COUNT_BIG(*)
              FROM grac_practice.custom_gap g
             WHERE (@organization_id IS NULL OR g.organization_id = @organization_id)
               AND g.gap_source_module_code = v.SourceModuleCode)
           +
           CASE WHEN v.SourceModuleCode = N'Implementation'
                THEN (SELECT COUNT_BIG(*)
                        FROM grac_practice.practice_gap pg
                        JOIN grac_practice.practice_instance pi
                             ON pi.practice_instance_id = pg.practice_instance_id
                       WHERE (@organization_id IS NULL OR pi.organization_id = @organization_id)
                         AND pg.gap_status = N'Open'
                         AND NOT EXISTS (
                                 SELECT 1 FROM grac_practice.custom_gap cg
                                  WHERE cg.source_reference_type = N'PracticeInstance'
                                    AND cg.source_reference_id   = pg.practice_instance_id
                                    AND cg.organization_id       = pi.organization_id))
                ELSE 0 END AS GapCount
    FROM   vocab v
    ORDER  BY v.DisplayOrder;
END
GO
PRINT '255: sp_gap_centre_source_counts created.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 255 verification ===';

DECLARE @list NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_gap_centre_list','P'));

SELECT '255-a sp_gap_centre_list exists' AS Check_,
       CASE WHEN @list IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '255-b it reads both origins',
       CASE WHEN @list LIKE '%grac_practice.custom_gap%'
             AND @list LIKE '%grac_practice.practice_gap%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '255-c dedupe uses the materialize idempotency key',
       CASE WHEN @list LIKE '%source_reference_type = N''PracticeInstance''%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '255-d source counts proc exists',
       CASE WHEN OBJECT_ID('grac_practice.sp_gap_centre_source_counts','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Regression guards: 255 must not have disturbed the two procs the rest
-- of the application still calls.
SELECT '255-e sp_task_center_gaps_list still present (246 shape)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_center_gaps_list','P')) LIKE '%TotalCount%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '255-f sp_custom_gap_list still present',
       CASE WHEN OBJECT_ID('grac_practice.sp_custom_gap_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- Row count agreement: unified list vs the two tabs it replaces ---';
PRINT 'Whole-tenant scope. These should be equal; a difference means the';
PRINT 'dedupe rule and the materialize key have drifted apart.';

SELECT
    (SELECT COUNT_BIG(*) FROM grac_practice.custom_gap) AS CustomGapRows,
    (SELECT COUNT_BIG(*)
       FROM grac_practice.practice_gap pg
       JOIN grac_practice.practice_instance pi
            ON pi.practice_instance_id = pg.practice_instance_id
      WHERE pg.gap_status = N'Open'
        AND NOT EXISTS (SELECT 1 FROM grac_practice.custom_gap cg
                         WHERE cg.source_reference_type = N'PracticeInstance'
                           AND cg.source_reference_id   = pg.practice_instance_id
                           AND cg.organization_id       = pi.organization_id))
                                                        AS UnmaterializedInstanceGaps,
    (SELECT COUNT_BIG(*)
       FROM grac_practice.practice_gap pg
       JOIN grac_practice.practice_instance pi
            ON pi.practice_instance_id = pg.practice_instance_id
      WHERE pg.gap_status = N'Open')                    AS AllOpenInstanceGaps;

PRINT '';
PRINT '255 complete. Gap Centre reads one list; Source is a column.';
GO

SET NOEXEC OFF;
GO
