-- =====================================================================
-- 043 sp_practice_instance_open_implementation_task
--
-- Opens (or returns the existing open) Implementation task for a Practice
-- Instance. Enforces:
--   * Instance must exist
--   * Instance's implementation_status must be 'Not Implemented' (either
--     via the FK column implementation_status_id or the legacy NVARCHAR
--     column — whichever is populated)
--   * Idempotent via existing filtered unique index
--     ux_pm_practice_task_impl_dedup on practice_task
--
-- Errors:
--   54301 instance not found
--   54302 instance is not in 'Not Implemented' state
--
-- Delegates the actual insert + state-machine + audit trail to
-- sp_task_open (§12.1.3). This proc is a thin, entity-specific facade.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Prerequisite guard.
DECLARE @prereqs_ok BIT = 1;

IF OBJECT_ID('grac_practice.sp_task_open','P') IS NULL
BEGIN
    PRINT 'ABORT (043-proc): sp_task_open missing. Run 037_task_engine_procs.sql first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.practice_instance','U') IS NULL
BEGIN
    PRINT 'ABORT (043-proc): practice_instance missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.implementation_status_master','U') IS NULL
BEGIN
    PRINT 'ABORT (043-proc): implementation_status_master missing.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('043 open-implementation-task prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_practice_instance_open_implementation_task
    @practice_instance_id  BIGINT,
    @subject_title         NVARCHAR(250),
    @subject_description   NVARCHAR(MAX)   = NULL,
    @assigned_to_employee_id BIGINT        = NULL,
    @target_date           DATETIME2       = NULL,          -- maps to sla_due_at
    @priority              NVARCHAR(30)    = NULL,
    @remarks               NVARCHAR(1000)  = NULL,          -- Q14: reuse reason_text
    @actor_employee_id     BIGINT          = NULL,
    @actor_role_code       NVARCHAR(60)    = NULL,
    @correlation_id        UNIQUEIDENTIFIER = NULL,
    @task_id               BIGINT          OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL
        THROW 54301, 'sp_practice_instance_open_implementation_task: @practice_instance_id is required.', 1;
    IF @subject_title IS NULL OR LTRIM(RTRIM(@subject_title)) = N''
        THROW 54303, 'sp_practice_instance_open_implementation_task: @subject_title is required.', 1;

    -- Resolve instance + its declared status (from either column).
    DECLARE @organization_id BIGINT,
            @practice_id     BIGINT,
            @status_id_col   INT,
            @status_txt_col  NVARCHAR(40),
            @status_code_now NVARCHAR(60),
            @instance_code   NVARCHAR(100);

    SELECT @organization_id = pi.organization_id,
           @practice_id     = pi.practice_id,
           @status_id_col   = pi.implementation_status_id,
           @status_txt_col  = pi.implementation_status,
           @instance_code   = pi.instance_code
    FROM grac_practice.practice_instance pi
    WHERE pi.practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
    BEGIN
        DECLARE @msg1 NVARCHAR(200) = CONCAT(N'Practice Instance ', CAST(@practice_instance_id AS NVARCHAR(30)), N' not found.');
        THROW 54301, @msg1, 1;
    END

    -- Prefer the surrogate FK; fall back to the legacy NVARCHAR label.
    IF @status_id_col IS NOT NULL
        SELECT @status_code_now = ims.status_code
        FROM grac_practice.implementation_status_master ims
        WHERE ims.implementation_status_id = @status_id_col;

    IF @status_code_now IS NULL
        SET @status_code_now = @status_txt_col;

    IF ISNULL(@status_code_now, N'') NOT IN (N'Not Implemented', N'Not Started')
    BEGIN
        DECLARE @msg2 NVARCHAR(400) = CONCAT(
            N'Practice Instance ', @instance_code,
            N' is in state ''', ISNULL(@status_code_now, N'<null>'),
            N'''. Implementation Task can only be opened when state is ''Not Implemented''.');
        THROW 54302, @msg2, 1;
    END

    -- Delegate to the task engine — idempotent by the filtered unique index.
    EXEC grac_practice.sp_task_open
        @organization_id         = @organization_id,
        @task_type_code          = N'Implementation',
        @subject_entity_type     = N'PracticeInstance',
        @subject_entity_id       = @practice_instance_id,
        @subject_title           = @subject_title,
        @subject_description     = @subject_description,
        @linked_practice_id      = @practice_id,
        @linked_instance_id      = @practice_instance_id,
        @priority                = @priority,
        @criticality             = NULL,
        @origin_code             = NULL,
        @assigned_to_employee_id = @assigned_to_employee_id,
        @actor_employee_id       = @actor_employee_id,
        @actor_role_code         = @actor_role_code,
        @correlation_id          = @correlation_id,
        @task_id                 = @task_id OUTPUT;

    -- If caller supplied a Target Date override, apply it now (sp_task_open
    -- uses the type's default_sla_hours otherwise).
    IF @target_date IS NOT NULL AND @task_id IS NOT NULL
    BEGIN
        UPDATE grac_practice.practice_task
           SET sla_due_at  = @target_date,
               reason_text = ISNULL(@remarks, reason_text),
               updated_by  = CASE WHEN @actor_employee_id IS NOT NULL
                                  THEN CONCAT('emp:', CAST(@actor_employee_id AS NVARCHAR(30)))
                                  ELSE N'system' END,
               updated_dt  = SYSUTCDATETIME()
         WHERE task_id = @task_id;
    END
    ELSE IF @remarks IS NOT NULL AND @task_id IS NOT NULL
    BEGIN
        UPDATE grac_practice.practice_task
           SET reason_text = @remarks,
               updated_by  = CASE WHEN @actor_employee_id IS NOT NULL
                                  THEN CONCAT('emp:', CAST(@actor_employee_id AS NVARCHAR(30)))
                                  ELSE N'system' END,
               updated_dt  = SYSUTCDATETIME()
         WHERE task_id = @task_id;
    END
END;
GO

PRINT '043 sp_practice_instance_open_implementation_task installed.';
GO

SET NOEXEC OFF;
GO
