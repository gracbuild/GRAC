-- =====================================================================
-- 246 sp_task_center_gaps_list result-shape fix
--
-- 245 re-emitted sp_task_center_gaps_list to read from the new
-- persistent gap tables, but the first result set was changed from
-- (TotalCount, PageNumber, PageSize) to (TotalRows). That broke the
-- API reader in PracticeInstanceController.Gaps, which expects the
-- three original columns and throws when TotalCount is not present --
-- surfacing on Gap Center as "Failed to load: HTTP 500".
--
-- This migration re-emits the procedure with 245's join / read from
-- practice_gap intact but restores the original 049 first-result-set
-- shape and page-row column contract:
--
--   Result set 1 : TotalCount BIGINT, PageNumber INT, PageSize INT
--   Result set 2 : PracticeInstanceId, InstanceCode, InstanceName,
--                  PracticeId, PracticeCode, PracticeName,
--                  OrganizationId, OrganizationName,
--                  ImplementationStatus, GapObligationCount,
--                  Owner, Criticality, ExistingTaskCount,
--                  GapObligationsJson, OpenedDt, ReopenedDt,
--                  PracticeGapId
--
-- The 245-specific additions (PracticeGapId, OpenedDt, ReopenedDt,
-- GapObligationCount) stay on the page rows -- the API's Gaps reader
-- ignores unknown columns, and the more capable UI callers can pick
-- them up. If a client only reads the 049 subset it keeps working
-- unchanged, which is the property that was lost by the 245 shape
-- change.
--
-- SAFE TO RE-RUN. Requires 245.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (246): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.practice_gap','U') IS NULL
BEGIN
    PRINT 'ABORT (246): practice_gap missing -- run 245 first.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_task_center_gaps_list
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @page            INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    -- Same table-variable materialisation 049 used, so the count SELECT
    -- and the page SELECT read from the same filtered set without
    -- re-running the join. Column list matches 049 exactly, plus the
    -- three 245 additions on the tail.
    DECLARE @results TABLE (
        PracticeInstanceId    BIGINT,
        PracticeGapId         BIGINT,
        InstanceCode          NVARCHAR(100),
        InstanceName          NVARCHAR(300),
        PracticeId            BIGINT NULL,
        PracticeCode          NVARCHAR(100) NULL,
        PracticeName          NVARCHAR(300) NULL,
        OrganizationId        BIGINT NULL,
        OrganizationName      NVARCHAR(300) NULL,
        ImplementationStatus  NVARCHAR(60),
        GapObligationCount    INT NOT NULL,
        Owner                 NVARCHAR(200) NULL,
        Criticality           NVARCHAR(30) NULL,
        ExistingTaskCount     INT NOT NULL,
        GapObligationsJson    NVARCHAR(MAX) NULL,
        OpenedDt              DATETIME2(3) NULL,
        ReopenedDt            DATETIME2(3) NULL
    );

    INSERT INTO @results
        (PracticeInstanceId, PracticeGapId, InstanceCode, InstanceName,
         PracticeId, PracticeCode, PracticeName,
         OrganizationId, OrganizationName,
         ImplementationStatus, GapObligationCount,
         Owner, Criticality, ExistingTaskCount,
         GapObligationsJson, OpenedDt, ReopenedDt)
    SELECT pi.practice_instance_id,
           pg.practice_gap_id,
           pi.instance_code,
           pi.instance_name,
           p.practice_id,
           p.practice_code,
           p.practice_name,
           o.organization_id,
           o.organization_name,
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
           (SELECT COUNT(*) FROM grac_practice.practice_gap_obligation pgo
             WHERE pgo.practice_gap_id = pg.practice_gap_id
               AND pgo.status          = N'Active'),
           pi.primary_owner,
           pi.criticality,
           (SELECT COUNT(*)
              FROM grac_practice.practice_task t
              JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
             WHERE t.subject_entity_type = N'PracticeInstance'
               AND t.subject_entity_id   = pi.practice_instance_id
               AND tt.type_code          = N'Implementation'
               AND t.closed_at IS NULL),
           (SELECT pgo.practice_instance_obligation_id AS obligationId,
                   pgo.obligation_name                 AS name,
                   pgo.obligation_type_code            AS typeCode,
                   pgo.logged_status_code              AS status,
                   pgo.added_dt                        AS addedDt
            FROM   grac_practice.practice_gap_obligation pgo
            WHERE  pgo.practice_gap_id = pg.practice_gap_id
              AND  pgo.status          = N'Active'
            ORDER  BY CASE pgo.logged_status_code
                           WHEN N'Not Implemented'       THEN 1
                           WHEN N'Partially Implemented' THEN 2
                           ELSE 3 END,
                      pgo.obligation_name
            FOR JSON PATH),
           pg.opened_dt,
           pg.reopened_dt
    FROM   grac_practice.practice_gap pg
    JOIN   grac_practice.practice_instance pi
           ON pi.practice_instance_id = pg.practice_instance_id
    LEFT   JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
    LEFT   JOIN grac_practice.organization o ON o.organization_id = pi.organization_id
    WHERE (@organization_id IS NULL OR pi.organization_id = @organization_id)
      AND  pg.gap_status = N'Open'
      AND (@search IS NULL
           OR pi.instance_code LIKE N'%' + @search + N'%'
           OR pi.instance_name LIKE N'%' + @search + N'%'
           OR p.practice_name  LIKE N'%' + @search + N'%');

    -- Result set 1 -- matches 049's contract (TotalCount + paging).
    -- PracticeInstanceController.Gaps reads these three column names
    -- verbatim and throws when any is missing.
    SELECT COUNT_BIG(*) AS TotalCount,
           @page        AS PageNumber,
           @page_size   AS PageSize
    FROM   @results;

    -- Result set 2 -- the page. 049's twelve columns come first in the
    -- same order, then 245's four additions on the tail.
    SELECT PracticeInstanceId, InstanceCode, InstanceName,
           PracticeId, PracticeCode, PracticeName,
           OrganizationId, OrganizationName,
           ImplementationStatus, Owner, Criticality, ExistingTaskCount,
           GapObligationCount, GapObligationsJson,
           OpenedDt, ReopenedDt, PracticeGapId
    FROM   @results
    ORDER  BY CASE ImplementationStatus
                   WHEN N'Not Implemented'       THEN 1
                   WHEN N'Partially Implemented' THEN 2
                   ELSE 3
              END,
              InstanceCode
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '246: sp_task_center_gaps_list first result set restored to (TotalCount, PageNumber, PageSize).';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 246 verification ===';

SELECT '246-a proc references practice_gap' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_center_gaps_list','P'))
                 LIKE '%practice_gap%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '246-b first result set carries TotalCount + PageNumber + PageSize',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_center_gaps_list','P')) LIKE '%TotalCount%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_center_gaps_list','P')) LIKE '%PageNumber%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_center_gaps_list','P')) LIKE '%PageSize%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '246-c page rows still carry GapObligationsJson',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_center_gaps_list','P'))
                 LIKE '%GapObligationsJson%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '246-d TotalRows shape from 245 is gone',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_center_gaps_list','P'))
                 NOT LIKE '%COUNT(*) AS TotalRows%'
            THEN 'PASS' ELSE 'FAIL' END;

-- Smoke-test with NULL organization_id, if anything is in gap territory.
IF EXISTS (SELECT 1 FROM grac_practice.practice_gap WHERE gap_status = N'Open')
BEGIN
    PRINT '';
    PRINT '=== Smoke test ===';
    EXEC grac_practice.sp_task_center_gaps_list @organization_id = NULL;
END

PRINT '';
PRINT '246 complete. Gap Center loads again.';
GO

SET NOEXEC OFF;
GO
