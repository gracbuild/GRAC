-- =====================================================================
-- 243 Instance effective implementation status + gap-list rewrite
--
-- WHY
-- ---
-- Migration 242 moved implementation status to the obligation. This
-- migration
--
--   1. exposes the "worst" obligation status per instance as a view, so
--      dashboards and rollups keep a single value to name;
--   2. rewires sp_task_center_gaps_list to look at that view instead of
--      pi.implementation_status -- one gap-centre row per instance where
--      any obligation is Not Implemented or Partially Implemented; and
--   3. returns a GapObligationsJson column carrying the offending
--      obligations, so the view-details expansion on the gap-centre row
--      can list what needs work without a second round trip.
--
-- RANK ORDER (worst first, so MIN() picks it)
--     Not Implemented         1
--     Partially Implemented   2
--     In Progress             3
--     Not Started             4
--     Implemented             5
--     N/A                     6   (excluded from the rollup below)
--
-- An instance with no Assurance/Execution obligations, or only N/A ones,
-- has no rollup and drops out of the gap list -- there is nothing to
-- close. An unstated obligation (implementation_status_id IS NULL) is
-- treated as Not Started, matching what the instance-level column
-- historically defaulted to.
--
-- SAFE TO RE-RUN. Requires 242.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (243): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.practice_instance_obligation','implementation_status_id') IS NULL
BEGIN
    PRINT 'ABORT (243): implementation_status_id column missing -- run 242 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- vw_pm_instance_effective_impl_status
--
-- The status_name / status_code / rank / obligation counts, one row per
-- instance that has at least one non-N/A obligation.
-- =====================================================================
CREATE OR ALTER VIEW grac_practice.vw_pm_instance_effective_impl_status
AS
    WITH ranked AS (
        SELECT pio.practice_instance_id,
               pio.practice_instance_obligation_id,
               pio.obligation_name,
               pio.obligation_type_code,
               COALESCE(ims.status_code, N'Not Started') AS status_code,
               COALESCE(ims.status_name, N'Not Started') AS status_name,
               CASE COALESCE(ims.status_code, N'Not Started')
                    WHEN N'Not Implemented'       THEN 1
                    WHEN N'Partially Implemented' THEN 2
                    WHEN N'In Progress'           THEN 3
                    WHEN N'Not Started'           THEN 4
                    WHEN N'Implemented'           THEN 5
                    ELSE 6
               END AS rank_
        FROM   grac_practice.practice_instance_obligation pio
        LEFT   JOIN grac_practice.implementation_status_master ims
               ON ims.implementation_status_id = pio.implementation_status_id
        WHERE  pio.status = N'Active'
          AND  COALESCE(ims.status_code, N'Not Started') <> N'N/A'
    ),
    picked AS (
        SELECT practice_instance_id,
               status_code,
               status_name,
               rank_,
               ROW_NUMBER() OVER (
                   PARTITION BY practice_instance_id
                   ORDER BY rank_, status_name
               ) AS rn
        FROM   ranked
    )
    SELECT p.practice_instance_id                                             AS PracticeInstanceId,
           MAX(CASE WHEN p.rn = 1 THEN p.status_code END)                     AS StatusCode,
           MAX(CASE WHEN p.rn = 1 THEN p.status_name END)                     AS StatusName,
           MAX(CASE WHEN p.rn = 1 THEN p.rank_       END)                     AS StatusRank,
           COUNT(*)                                                           AS ObligationCount,
           SUM(CASE WHEN p.rank_ <= 2 THEN 1 ELSE 0 END)                      AS GapObligationCount
    FROM   picked p
    GROUP  BY p.practice_instance_id;
GO
PRINT '243: vw_pm_instance_effective_impl_status created.';
GO

-- =====================================================================
-- sp_task_center_gaps_list -- re-emitted to read from the view
--
-- Same signature and column contract as 049. GapObligationsJson is new:
-- the view-details expansion parses it to show which obligations still
-- need work. NULL / [] is a legitimate value on an instance whose
-- status rolled up above the gap threshold.
-- =====================================================================
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

    DECLARE @results TABLE (
        PracticeInstanceId    BIGINT,
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
        GapObligationsJson    NVARCHAR(MAX) NULL
    );

    INSERT INTO @results
        (PracticeInstanceId, InstanceCode, InstanceName,
         PracticeId, PracticeCode, PracticeName,
         OrganizationId, OrganizationName,
         ImplementationStatus, GapObligationCount,
         Owner, Criticality, ExistingTaskCount,
         GapObligationsJson)
    SELECT pi.practice_instance_id,
           pi.instance_code,
           pi.instance_name,
           p.practice_id,
           p.practice_code,
           p.practice_name,
           o.organization_id,
           o.organization_name,
           eff.StatusName,
           eff.GapObligationCount,
           pi.primary_owner,
           pi.criticality,
           (SELECT COUNT(*)
              FROM grac_practice.practice_task t
              JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
             WHERE t.subject_entity_type = N'PracticeInstance'
               AND t.subject_entity_id   = pi.practice_instance_id
               AND tt.type_code          = N'Implementation'
               AND t.closed_at IS NULL),
           -- Offending obligations, ready for the view-details expansion.
           -- Every field a card would want is here so the UI does not
           -- have to hit another endpoint per row: id, name, type and
           -- the status that put the row on the list.
           (SELECT pio.practice_instance_obligation_id AS obligationId,
                   pio.obligation_name                 AS name,
                   pio.obligation_type_code            AS typeCode,
                   COALESCE(ims.status_code, N'Not Started') AS status
            FROM   grac_practice.practice_instance_obligation pio
            LEFT   JOIN grac_practice.implementation_status_master ims
                   ON ims.implementation_status_id = pio.implementation_status_id
            WHERE  pio.practice_instance_id = pi.practice_instance_id
              AND  pio.status = N'Active'
              AND  COALESCE(ims.status_code, N'Not Started')
                     IN (N'Not Implemented', N'Partially Implemented')
            ORDER  BY CASE COALESCE(ims.status_code, N'Not Started')
                           WHEN N'Not Implemented'       THEN 1
                           WHEN N'Partially Implemented' THEN 2
                           ELSE 3 END,
                      pio.obligation_name
            FOR JSON PATH)
    FROM   grac_practice.practice_instance pi
    JOIN   grac_practice.vw_pm_instance_effective_impl_status eff
           ON eff.PracticeInstanceId = pi.practice_instance_id
    LEFT   JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
    LEFT   JOIN grac_practice.organization o ON o.organization_id = pi.organization_id
    WHERE (@organization_id IS NULL OR pi.organization_id = @organization_id)
      AND  eff.StatusCode IN (N'Not Implemented', N'Partially Implemented')
      AND (@search IS NULL
           OR pi.instance_code LIKE N'%' + @search + N'%'
           OR pi.instance_name LIKE N'%' + @search + N'%'
           OR p.practice_name  LIKE N'%' + @search + N'%');

    -- Total for the pagination header, then the page.
    SELECT COUNT(*) AS TotalRows FROM @results;

    SELECT PracticeInstanceId, InstanceCode, InstanceName,
           PracticeId, PracticeCode, PracticeName,
           OrganizationId, OrganizationName,
           ImplementationStatus, GapObligationCount,
           Owner, Criticality, ExistingTaskCount,
           GapObligationsJson
    FROM   @results
    ORDER  BY InstanceCode
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '243: sp_task_center_gaps_list now reads from the effective-status view.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 243 verification ===';

SELECT 'effective-status view present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_instance_effective_impl_status','V') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'gaps list reads from the view',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_center_gaps_list','P'))
                 LIKE '%vw_pm_instance_effective_impl_status%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'gaps list carries GapObligationsJson',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_center_gaps_list','P'))
                 LIKE '%GapObligationsJson%'
            THEN 'PASS' ELSE 'FAIL' END;

-- Instances currently in gap territory, according to the new view.
PRINT '';
PRINT '=== Instances in gap territory ===';
SELECT eff.PracticeInstanceId, pi.instance_code, eff.StatusName, eff.GapObligationCount, eff.ObligationCount
FROM   grac_practice.vw_pm_instance_effective_impl_status eff
JOIN   grac_practice.practice_instance pi ON pi.practice_instance_id = eff.PracticeInstanceId
WHERE  eff.StatusCode IN (N'Not Implemented', N'Partially Implemented')
ORDER  BY eff.StatusRank, pi.instance_code;

PRINT '';
PRINT '243 complete. Task Center reflects obligation-level gaps.';
GO

SET NOEXEC OFF;
GO
