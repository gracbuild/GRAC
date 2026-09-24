-- =====================================================================
-- 379 ROLLBACK -- sp_gap_centre_list back to 371's exact body
--
-- Restores StatusText to plain COALESCE(s.state_name, g.status) -- a
-- Closed, previously-analysed gap goes back to showing its lifecycle
-- label ("Analysed") instead of Closed, exactly the pre-379 behaviour.
-- Every other column and both arms are otherwise unchanged from 379,
-- which itself only touched the one StatusText expression.
--
-- Does not touch gap-view.js or gap-detail.js -- their own 379 fixes
-- are reverted separately, by hand, the same way any other UI-only
-- change in this project is rolled back (no SQL governs them).
--
-- Re-runnable: yes -- CREATE OR ALTER.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_gap_centre_list','P') IS NULL
BEGIN
    RAISERROR('379 rollback: grac_practice.sp_gap_centre_list missing.', 16, 1);
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
        CASE WHEN g.source_reference_type = N'PracticeInstance' AND g.source_reference_id IS NOT NULL
             THEN (SELECT TOP 1 CASE pg1.gap_status
                                      WHEN N'Closed' THEN N'Implemented'
                                      WHEN N'Open'   THEN N'Not Implemented'
                                      ELSE NULL END
                     FROM grac_practice.practice_gap pg1
                    WHERE pg1.practice_instance_id = g.source_reference_id)
             ELSE NULL END,
        (SELECT CASE
                    WHEN COUNT(*) = 0 THEN NULL
                    WHEN SUM(CASE WHEN ts.is_terminal = 1 THEN 0 ELSE 1 END) = 0 THEN N'Completed'
                    ELSE N'Pending'
                END
           FROM grac_practice.practice_task t2
           JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = t2.current_status_id
          WHERE t2.subject_entity_type = N'CustomGap'
            AND t2.subject_entity_id   = g.custom_gap_id),
        (SELECT TOP 1 COALESCE(
                          (SELECT rr.status_code
                             FROM grac_practice.risk_register rr
                            WHERE rr.risk_register_id = rc.registered_risk_id),
                          rc.status_code)
           FROM grac_practice.risk_candidate rc
          WHERE rc.custom_gap_id = g.custom_gap_id
          ORDER BY rc.risk_candidate_id DESC),
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
        CASE pg.gap_status WHEN N'Closed' THEN N'Implemented'
                            WHEN N'Open'   THEN N'Not Implemented'
                            ELSE NULL END,
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

PRINT '379 rollback: sp_gap_centre_list restored to 371''s COALESCE-only body.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '379 rollback-a proc compiled' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_gap_centre_list','P')) IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '379 rollback-b Closed override removed',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_gap_centre_list','P')) NOT LIKE '%WHEN g.status = N''Closed'' THEN N''Closed''%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '379 rollback complete. StatusText is back to COALESCE(s.state_name, g.status)';
PRINT '    for every gap, Closed included.';
GO
SET NOEXEC OFF;
GO
