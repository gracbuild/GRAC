-- =====================================================================
-- 382_custom_gap_practice_map_rollback.sql
--
-- Reverses 382:
--   * drops sp_custom_gap_practice_map_list
--   * restores sp_custom_gap_open to 368's body (no @practice_ids_json)
--   * drops custom_gap_practice_map (mapping rows are removed with it)
--
-- ASCII-only. SAFE TO RE-RUN.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_custom_gap_practice_map_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_custom_gap_practice_map_list;
GO

-- Restore 368's sp_custom_gap_open body verbatim (no practice mapping).
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_open
    @organization_id        BIGINT,
    @title                  NVARCHAR(250),
    @description            NVARCHAR(MAX) = NULL,
    @priority               NVARCHAR(30)  = N'Medium',
    @owner_employee_id      BIGINT        = NULL,
    @due_date               DATE          = NULL,
    @status                 NVARCHAR(30)  = N'Open',
    @remarks                NVARCHAR(1000) = NULL,
    @gap_type_code          NVARCHAR(60)  = N'Custom',
    @actor_employee_id      BIGINT        = NULL,
    @severity_code          NVARCHAR(30)  = NULL,
    @severity_name          NVARCHAR(120) = NULL,
    @detection_method_code  NVARCHAR(60)  = NULL,
    @detection_method_name  NVARCHAR(200) = NULL,
    @custom_gap_id          BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @title IS NULL OR LTRIM(RTRIM(@title)) = N''
        THROW 54010, 'sp_custom_gap_open: organization_id and title are required.', 1;

    IF @priority NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @priority = N'Medium';

    IF @status NOT IN (N'Open', N'InProgress', N'Closed', N'Cancelled')
        SET @status = N'Open';

    IF @severity_code IS NOT NULL AND @severity_code NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @severity_code = NULL;
    IF @severity_code IS NULL
        SET @severity_code = @priority;
    IF @severity_name IS NULL
        SET @severity_name = @severity_code;

    DECLARE @owner_display_name NVARCHAR(240) = NULL;
    IF @owner_employee_id IS NOT NULL
        SELECT @owner_display_name = employee_name
          FROM grac_practice.organization_employee
         WHERE employee_id = @owner_employee_id;

    DECLARE @new_state_id INT =
        (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'New');

    INSERT INTO grac_practice.custom_gap
        (organization_id, gap_type_code, title, description, priority,
         owner_employee_id, owner_display_name, due_date, status, remarks,
         severity_code, severity_name,
         detection_method_code, detection_method_name,
         lifecycle_state_id,
         opened_dt,
         entered_by, entered_dt)
    VALUES
        (@organization_id, ISNULL(@gap_type_code, N'Custom'),
         @title, @description, @priority,
         @owner_employee_id, @owner_display_name, @due_date, @status, @remarks,
         @severity_code, @severity_name,
         NULLIF(LTRIM(RTRIM(@detection_method_code)), N''),
         NULLIF(LTRIM(RTRIM(@detection_method_name)), N''),
         @new_state_id,
         SYSUTCDATETIME(),
         COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api'),
         SYSUTCDATETIME());

    SET @custom_gap_id = SCOPE_IDENTITY();
END
GO
PRINT '382 rollback: sp_custom_gap_open restored to 368 body.';
GO

IF OBJECT_ID('grac_practice.custom_gap_practice_map','U') IS NOT NULL
    DROP TABLE grac_practice.custom_gap_practice_map;
GO
PRINT '382 rollback complete.';
GO
