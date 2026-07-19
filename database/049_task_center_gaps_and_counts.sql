-- =====================================================================
-- 049 Task Center — Gaps list + tab counts
--
-- Two new read-only procs used by the tabbed Task Center UI:
--   * sp_task_center_gaps_list  — Practice Instances whose
--     implementation_status IN ('Not Implemented','Partially Implemented')
--     joined with practice + organization + open-Implementation-task count.
--   * sp_task_center_counts     — tab count badges for the selected org.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 54900, 'schema grac_practice missing', 1;
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

    -- CTEs only bind to the immediately following statement, so we
    -- materialise the filtered set once into a table variable and reuse
    -- it across the count SELECT and the page SELECT.
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
        Owner                 NVARCHAR(200) NULL,
        Criticality           NVARCHAR(30) NULL,
        ExistingTaskCount     INT NOT NULL
    );

    INSERT INTO @results
        (PracticeInstanceId, InstanceCode, InstanceName,
         PracticeId, PracticeCode, PracticeName,
         OrganizationId, OrganizationName,
         ImplementationStatus, Owner, Criticality, ExistingTaskCount)
    SELECT pi.practice_instance_id,
           pi.instance_code,
           pi.instance_name,
           p.practice_id,
           p.practice_code,
           p.practice_name,
           o.organization_id,
           o.organization_name,
           COALESCE(ims.status_code, pi.implementation_status),
           pi.primary_owner,
           pi.criticality,
           (SELECT COUNT(*)
              FROM grac_practice.practice_task t
              JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
             WHERE t.subject_entity_type = N'PracticeInstance'
               AND t.subject_entity_id   = pi.practice_instance_id
               AND tt.type_code          = N'Implementation'
               AND t.closed_at IS NULL)
    FROM grac_practice.practice_instance pi
    LEFT JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
    LEFT JOIN grac_practice.organization o ON o.organization_id = pi.organization_id
    LEFT JOIN grac_practice.implementation_status_master ims
           ON ims.implementation_status_id = pi.implementation_status_id
    WHERE (@organization_id IS NULL OR pi.organization_id = @organization_id)
      AND COALESCE(ims.status_code, pi.implementation_status)
          IN (N'Not Implemented', N'Partially Implemented')
      AND (@search IS NULL
           OR pi.instance_code LIKE N'%' + @search + N'%'
           OR pi.instance_name LIKE N'%' + @search + N'%'
           OR p.practice_code  LIKE N'%' + @search + N'%'
           OR p.practice_name  LIKE N'%' + @search + N'%');

    -- Result-set #1 — counts + paging metadata
    SELECT COUNT_BIG(*) AS TotalCount,
           @page      AS PageNumber,
           @page_size AS PageSize
    FROM @results;

    -- Result-set #2 — the current page
    SELECT *
    FROM @results
    ORDER BY CASE ImplementationStatus
                  WHEN N'Not Implemented'       THEN 1
                  WHEN N'Partially Implemented' THEN 2
                  ELSE 3
             END,
             InstanceCode
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;
END;
GO

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

        -- Implementation tasks (open + closed; UI can further filter status)
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND tt.type_code = N'Implementation') AS ImplementationCount,

        -- Assurance tasks (system-generated once P6 lands; today usually 0)
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND tt.type_code = N'Assurance') AS AssuranceCount,

        -- Custom tasks (New Task button target)
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND tt.type_code = N'Custom') AS CustomCount;
END;
GO

PRINT '049 sp_task_center_gaps_list + sp_task_center_counts installed.';
GO
SET NOEXEC OFF;
GO
