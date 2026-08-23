-- =====================================================================
-- 181 Organization SLA -- master-first grid + status actions -- ROLLBACK
--
-- Drops the two NEW procs introduced by 181, then re-installs the 179
-- versions of sp_ctrl_sla_master_list and sp_org_sla_config_upsert
-- inline so the module ends up in the 179 state after this file runs.
--
-- Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_org_sla_master_grid','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_sla_master_grid;
GO

IF OBJECT_ID('grac_practice.sp_org_sla_config_set_active','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_sla_config_set_active;
GO

-- Restore the 179 version of sp_ctrl_sla_master_list (defensive
-- column discovery -- may return empty against real masters, but
-- that's the state 179 shipped).
CREATE OR ALTER PROCEDURE grac_practice.sp_ctrl_sla_master_list
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('grac_new.sla_master','U') IS NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT)        AS Id,
               CAST(NULL AS NVARCHAR(120)) AS Code,
               CAST(NULL AS NVARCHAR(200)) AS Name,
               CAST(NULL AS NVARCHAR(1000)) AS Description,
               CAST(NULL AS INT)           AS TotalSlaDays
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @tbl_id INT = OBJECT_ID('grac_new.sla_master');
    DECLARE @id_col NVARCHAR(128), @code_col NVARCHAR(128),
            @name_col NVARCHAR(128), @desc_col NVARCHAR(128),
            @days_col NVARCHAR(128), @status_col NVARCHAR(128);

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @id_col = name FROM candidates
    WHERE name IN (N'sla_master_id', N'sla_id', N'id');

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @code_col = name FROM candidates
    WHERE name IN (N'sla_master_code', N'sla_code', N'code');

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @name_col = name FROM candidates
    WHERE name IN (N'sla_master_name', N'sla_name', N'name', N'label', N'display_name');

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @desc_col = name FROM candidates
    WHERE name IN (N'description', N'notes', N'remarks');

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @days_col = name FROM candidates
    WHERE name IN (N'total_sla_days', N'sla_days', N'target_days', N'duration_days');

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @status_col = name FROM candidates
    WHERE name IN (N'status', N'is_active', N'active_flag');

    IF @id_col IS NULL OR @name_col IS NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT)        AS Id,
               CAST(NULL AS NVARCHAR(120)) AS Code,
               CAST(NULL AS NVARCHAR(200)) AS Name,
               CAST(NULL AS NVARCHAR(1000)) AS Description,
               CAST(NULL AS INT)           AS TotalSlaDays
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @sql NVARCHAR(MAX) = N'
        SELECT ' + QUOTENAME(@id_col) + N' AS Id,
               ' + COALESCE(QUOTENAME(@code_col), N'CAST(NULL AS NVARCHAR(120))') + N' AS Code,
               ' + QUOTENAME(@name_col) + N' AS Name,
               ' + COALESCE(QUOTENAME(@desc_col), N'CAST(NULL AS NVARCHAR(1000))') + N' AS Description,
               ' + COALESCE(QUOTENAME(@days_col), N'CAST(NULL AS INT)') + N' AS TotalSlaDays
        FROM grac_new.sla_master';

    IF @status_col = N'status'
        SET @sql = @sql + N' WHERE ' + QUOTENAME(@status_col) + N' = N''Active''';
    ELSE IF @status_col IN (N'is_active', N'active_flag')
        SET @sql = @sql + N' WHERE ' + QUOTENAME(@status_col) + N' = 1';

    SET @sql = @sql + N' ORDER BY ' + QUOTENAME(@name_col) + N';';

    EXEC sp_executesql @sql;
END
GO

-- Restore the 179 version of sp_org_sla_config_upsert (throw on
-- re-adopt).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_config_upsert
    @organization_id            BIGINT,
    @org_sla_config_id          BIGINT        = NULL,
    @sla_master_id              BIGINT,
    @sla_master_code            NVARCHAR(120) = NULL,
    @sla_master_name            NVARCHAR(200) = NULL,
    @total_sla_days             INT           = NULL,
    @warning_before_due_days    INT,
    @escalation_after_due_days  INT,
    @notes                      NVARCHAR(1000) = NULL,
    @actor                      NVARCHAR(100) = 'system',
    @out_org_sla_config_id      BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @sla_master_id IS NULL
        THROW 53783, 'organization_id and sla_master_id are required.', 1;
    IF @warning_before_due_days IS NULL OR @warning_before_due_days < 0
        THROW 53784, 'warning_before_due_days must be >= 0.', 1;
    IF @escalation_after_due_days IS NULL OR @escalation_after_due_days < 0
        THROW 53785, 'escalation_after_due_days must be >= 0.', 1;
    IF @total_sla_days IS NOT NULL AND @warning_before_due_days > @total_sla_days
        THROW 53786, 'warning_before_due_days cannot exceed total_sla_days.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    BEGIN TRAN;

    IF @org_sla_config_id IS NULL
    BEGIN
        IF EXISTS (
            SELECT 1 FROM grac_practice.org_sla_config
            WHERE organization_id = @organization_id
              AND sla_master_id   = @sla_master_id
              AND is_active       = 1)
            THROW 53787,
                'This SLA master is already adopted for the organization.', 1;

        INSERT INTO grac_practice.org_sla_config
            (organization_id, sla_master_id, sla_master_code, sla_master_name,
             total_sla_days, warning_before_due_days, escalation_after_due_days,
             notes, is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@organization_id, @sla_master_id, @sla_master_code, @sla_master_name,
             @total_sla_days, @warning_before_due_days, @escalation_after_due_days,
             @notes, 1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @out_org_sla_config_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (
            SELECT 1 FROM grac_practice.org_sla_config
            WHERE org_sla_config_id = @org_sla_config_id
              AND organization_id   = @organization_id
              AND is_active         = 1)
            THROW 53788, 'SLA config not found or not editable for this organization.', 1;

        UPDATE grac_practice.org_sla_config
        SET sla_master_code           = COALESCE(@sla_master_code, sla_master_code),
            sla_master_name           = COALESCE(@sla_master_name, sla_master_name),
            total_sla_days            = @total_sla_days,
            warning_before_due_days   = @warning_before_due_days,
            escalation_after_due_days = @escalation_after_due_days,
            notes                     = @notes,
            updated_by                = @actor,
            updated_dt                = SYSUTCDATETIME()
        WHERE org_sla_config_id = @org_sla_config_id;

        SET @out_org_sla_config_id = @org_sla_config_id;
    END

    COMMIT;
END
GO

PRINT '181 Organization SLA master-first grid rolled back to 179 state.';
GO
