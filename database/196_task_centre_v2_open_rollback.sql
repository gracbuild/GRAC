-- =====================================================================
-- 196 Task Centre v2 — sp_task_open v3 ROLLBACK
--
-- Restores sp_task_open to its 048 (v2) definition: no source stamping,
-- no owner resolution, no org SLA derivation. Re-running
-- 048_task_model_procs.sql achieves the same thing — this script exists
-- so the rollback is self-contained and does not also re-drop/rebuild
-- the view that 048 rewrites.
--
-- Run this BEFORE 193's rollback: v3 calls sp_task_owner_resolve and
-- sp_task_apply_sla, so restoring v2 first removes the dependency.
--
-- Existing tasks keep whatever source_type_code, owner_source_code and
-- standard_due_at they were stamped with — those are 192 columns and are
-- removed by 192's rollback, not this one.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.practice_task','U') IS NULL
   OR COL_LENGTH('grac_practice.practice_task','related_entity_type_id') IS NULL
BEGIN
    PRINT '196-rollback: practice_task / 048 columns missing — nothing to restore.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_task_open
    @organization_id      BIGINT,
    @task_type_code       NVARCHAR(60),
    @subject_entity_type  NVARCHAR(60),
    @subject_entity_id    BIGINT,
    @subject_title        NVARCHAR(250),
    @subject_description  NVARCHAR(MAX)   = NULL,
    @linked_release_id    BIGINT          = NULL,
    @linked_control_id    BIGINT          = NULL,
    @linked_practice_id   BIGINT          = NULL,
    @linked_instance_id   BIGINT          = NULL,
    @priority             NVARCHAR(30)    = NULL,
    @criticality          NVARCHAR(30)    = NULL,
    @origin_code          NVARCHAR(30)    = NULL,
    @assigned_to_employee_id BIGINT       = NULL,
    @actor_employee_id    BIGINT          = NULL,
    @actor_role_code      NVARCHAR(60)    = NULL,
    @correlation_id       UNIQUEIDENTIFIER = NULL,
    @related_entity_type_code NVARCHAR(60)  = NULL,
    @related_record_id        BIGINT        = NULL,
    @start_date               DATETIME2     = NULL,
    @target_date              DATETIME2     = NULL,
    @workflow_id              BIGINT        = NULL,
    @current_workflow_stage_id BIGINT       = NULL,
    @assurance_activity_id    BIGINT        = NULL,
    @task_id                  BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @task_type_code IS NULL OR @subject_entity_type IS NULL
       OR @subject_entity_id IS NULL OR @subject_title IS NULL
        THROW 53720, 'sp_task_open: organization_id, task_type_code, subject_entity_*, and subject_title are required.', 1;

    DECLARE @type_id INT, @default_sla_hours INT, @default_priority NVARCHAR(30);
    SELECT @type_id = task_type_id,
           @default_sla_hours = default_sla_hours,
           @default_priority  = default_priority
    FROM grac_practice.task_type_master
    WHERE type_code = @task_type_code AND is_active = 1;

    IF @type_id IS NULL
    BEGIN
        DECLARE @msg NVARCHAR(200) = CONCAT('Unknown task_type_code: ', @task_type_code);
        THROW 53721, @msg, 1;
    END

    DECLARE @open_status_id INT = grac_practice.fn_get_entity_status_id(N'Task', N'Open');
    IF @open_status_id IS NULL
        THROW 53722, 'Task lifecycle not seeded — run 035_state_machine_framework.sql.', 1;

    DECLARE @related_type_id INT = NULL;
    IF @related_entity_type_code IS NOT NULL
        SELECT @related_type_id = related_entity_type_id
        FROM grac_practice.related_entity_type_master
        WHERE entity_code = @related_entity_type_code AND is_active = 1;

    DECLARE @actor_label NVARCHAR(100) =
        CASE WHEN @actor_employee_id IS NOT NULL
             THEN CONCAT('emp:', CAST(@actor_employee_id AS NVARCHAR(30)))
             ELSE N'system' END;

    DECLARE @now DATETIME2 = SYSUTCDATETIME();
    DECLARE @sla DATETIME2 = COALESCE(@target_date, DATEADD(HOUR, @default_sla_hours, @now));
    DECLARE @prio NVARCHAR(30) = ISNULL(@priority, @default_priority);

    BEGIN TRAN;

    IF @task_type_code = N'Implementation'
    BEGIN
        SELECT @task_id = task_id
        FROM grac_practice.practice_task WITH (UPDLOCK, HOLDLOCK)
        WHERE task_type_id       = @type_id
          AND subject_entity_type = @subject_entity_type
          AND subject_entity_id   = @subject_entity_id
          AND closed_at IS NULL;

        IF @task_id IS NOT NULL
        BEGIN
            COMMIT TRAN;
            RETURN;
        END
    END

    INSERT INTO grac_practice.practice_task
        (organization_id, task_type_id, subject_entity_type, subject_entity_id,
         linked_release_id, linked_control_id, linked_practice_id, linked_instance_id,
         subject_title, subject_description,
         assigned_to_employee_id, current_status_id,
         priority, criticality, origin_code,
         sla_due_at, correlation_id, entered_by,
         related_entity_type_id, related_record_id,
         start_date, workflow_id, current_workflow_stage_id, assurance_activity_id)
    VALUES
        (@organization_id, @type_id, @subject_entity_type, @subject_entity_id,
         @linked_release_id, @linked_control_id, @linked_practice_id, @linked_instance_id,
         @subject_title, @subject_description,
         @assigned_to_employee_id, @open_status_id,
         @prio, @criticality, @origin_code,
         @sla, @correlation_id, @actor_label,
         @related_type_id, @related_record_id,
         @start_date, @workflow_id, @current_workflow_stage_id, @assurance_activity_id);

    SET @task_id = SCOPE_IDENTITY();

    DECLARE @to_status_id INT, @log_id BIGINT;
    EXEC grac_practice.sp_pm_state_transition
        @entity_type       = N'Task',
        @entity_id         = @task_id,
        @from_status_code  = NULL,
        @to_status_code    = N'Open',
        @actor_employee_id = @actor_employee_id,
        @actor_role_code   = @actor_role_code,
        @reason_code       = N'TASK_OPENED',
        @reason_text       = @subject_title,
        @correlation_id    = @correlation_id,
        @to_status_id      = @to_status_id      OUTPUT,
        @transition_log_id = @log_id            OUTPUT;

    IF @assigned_to_employee_id IS NOT NULL
    BEGIN
        DECLARE @assigned_status_id INT;
        EXEC grac_practice.sp_pm_state_transition
            @entity_type       = N'Task',
            @entity_id         = @task_id,
            @from_status_code  = N'Open',
            @to_status_code    = N'Assigned',
            @actor_employee_id = @actor_employee_id,
            @actor_role_code   = @actor_role_code,
            @reason_code       = N'TASK_ASSIGNED_AT_OPEN',
            @correlation_id    = @correlation_id,
            @to_status_id      = @assigned_status_id OUTPUT,
            @transition_log_id = @log_id             OUTPUT;

        UPDATE grac_practice.practice_task
           SET current_status_id = @assigned_status_id,
               updated_by        = @actor_label,
               updated_dt        = @now
         WHERE task_id = @task_id;
    END

    COMMIT TRAN;
END;
GO

PRINT '196 rolled back — sp_task_open restored to the 048 (v2) definition.';
GO

SET NOEXEC OFF;
GO
