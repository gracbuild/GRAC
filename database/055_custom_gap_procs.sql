-- =====================================================================
-- 055 Custom Gap procedures
--
--   * sp_custom_gap_list  -- paginated read for Gap Center Custom tab
--   * sp_custom_gap_open  -- create a new Custom Gap
--   * sp_custom_gap_close -- terminal transition
--
-- Kept minimal on purpose. Update / re-open flows can be added later
-- without breaking the shape callers see.
--
-- Rollback: database/055_custom_gap_procs_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
BEGIN
    RAISERROR('055: custom_gap table missing -- run 054 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_custom_gap_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_list
    @organization_id BIGINT       = NULL,
    @status_code     NVARCHAR(30) = NULL,     -- NULL = all
    @priority        NVARCHAR(30) = NULL,
    @owner_employee_id BIGINT     = NULL,
    @search          NVARCHAR(200) = NULL,
    @page            INT          = 1,
    @page_size       INT          = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    ;WITH filtered AS (
        SELECT g.custom_gap_id,
               g.organization_id,
               g.gap_type_code,
               g.title,
               g.description,
               g.priority,
               g.owner_employee_id,
               g.due_date,
               g.status,
               g.remarks,
               g.linked_task_id,
               g.entered_by,
               g.entered_dt,
               g.updated_by,
               g.updated_dt
        FROM grac_practice.custom_gap g
        WHERE (@organization_id IS NULL OR g.organization_id = @organization_id)
          AND (@status_code     IS NULL OR g.status         = @status_code)
          AND (@priority        IS NULL OR g.priority       = @priority)
          AND (@owner_employee_id IS NULL OR g.owner_employee_id = @owner_employee_id)
          AND (@search          IS NULL
               OR g.title       LIKE N'%' + @search + N'%'
               OR g.description LIKE N'%' + @search + N'%'
               OR g.remarks     LIKE N'%' + @search + N'%')
    )
    SELECT (SELECT COUNT_BIG(*) FROM filtered) AS TotalCount,
           @page      AS PageNumber,
           @page_size AS PageSize
    OPTION (RECOMPILE);

    ;WITH filtered AS (
        SELECT g.custom_gap_id,
               g.organization_id,
               g.gap_type_code,
               g.title,
               g.description,
               g.priority,
               g.owner_employee_id,
               g.due_date,
               g.status,
               g.remarks,
               g.linked_task_id,
               g.entered_by,
               g.entered_dt,
               g.updated_by,
               g.updated_dt
        FROM grac_practice.custom_gap g
        WHERE (@organization_id IS NULL OR g.organization_id = @organization_id)
          AND (@status_code     IS NULL OR g.status         = @status_code)
          AND (@priority        IS NULL OR g.priority       = @priority)
          AND (@owner_employee_id IS NULL OR g.owner_employee_id = @owner_employee_id)
          AND (@search          IS NULL
               OR g.title       LIKE N'%' + @search + N'%'
               OR g.description LIKE N'%' + @search + N'%'
               OR g.remarks     LIKE N'%' + @search + N'%')
    )
    SELECT *
    FROM filtered
    ORDER BY CASE WHEN due_date IS NULL THEN 1 ELSE 0 END,
             due_date ASC,
             custom_gap_id DESC
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY
    OPTION (RECOMPILE);
END;
GO

-- =====================================================================
-- sp_custom_gap_open
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_open
    @organization_id    BIGINT,
    @title              NVARCHAR(250),
    @description        NVARCHAR(MAX) = NULL,
    @priority           NVARCHAR(30)  = N'Medium',
    @owner_employee_id  BIGINT        = NULL,
    @due_date           DATE          = NULL,
    @status             NVARCHAR(30)  = N'Open',
    @remarks            NVARCHAR(1000) = NULL,
    @gap_type_code      NVARCHAR(60)  = N'Custom',
    @actor_employee_id  BIGINT        = NULL,
    @custom_gap_id      BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @title IS NULL OR LTRIM(RTRIM(@title)) = N''
        THROW 54010, 'sp_custom_gap_open: organization_id and title are required.', 1;

    IF @priority NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @priority = N'Medium';

    IF @status NOT IN (N'Open', N'InProgress', N'Closed', N'Cancelled')
        SET @status = N'Open';

    INSERT INTO grac_practice.custom_gap
        (organization_id, gap_type_code, title, description, priority,
         owner_employee_id, due_date, status, remarks, entered_by, entered_dt)
    VALUES
        (@organization_id, ISNULL(@gap_type_code, N'Custom'),
         @title, @description, @priority,
         @owner_employee_id, @due_date, @status, @remarks,
         COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api'),
         SYSUTCDATETIME());

    SET @custom_gap_id = SCOPE_IDENTITY();
END;
GO

-- =====================================================================
-- sp_custom_gap_close
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_close
    @custom_gap_id     BIGINT,
    @actor_employee_id BIGINT       = NULL,
    @remarks           NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id)
        THROW 54011, 'sp_custom_gap_close: custom_gap_id not found.', 1;

    UPDATE grac_practice.custom_gap
       SET status     = N'Closed',
           remarks    = COALESCE(@remarks, remarks),
           updated_by = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api'),
           updated_dt = SYSUTCDATETIME()
     WHERE custom_gap_id = @custom_gap_id;
END;
GO

PRINT '055 custom_gap procedures installed.';
GO

SET NOEXEC OFF;
GO
