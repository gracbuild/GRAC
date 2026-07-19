-- =====================================================================
-- 037 Task engine — procedures  (charter §12.1.3)
--
-- All procedures write to practice_audit_trace and delegate state
-- transitions to sp_pm_state_transition (035_*).
--
-- Contents:
--   * sp_task_open              — create a new task
--   * sp_task_assign            — set assigned_to_employee_id + transition Open->Assigned
--   * sp_task_transition        — generic transition wrapper (updates row)
--   * sp_task_close             — close with two-gate guard for Implementation
--   * sp_task_overdue_sweep     — SLA breach nudge/escalate; idempotent
--   * sp_task_list              — filter/pagination read API
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

-- Prerequisite guard — see 037_task_engine.sql for the pattern explanation.
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (037-procs): schema grac_practice missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.practice_task','U') IS NULL
BEGIN
    PRINT 'ABORT (037-procs): practice_task missing. Run 037_task_engine.sql before this file.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.sp_pm_state_transition','P') IS NULL
BEGIN
    PRINT 'ABORT (037-procs): sp_pm_state_transition missing. Run 035_state_machine_procs.sql before this file.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('037_task_engine_procs: prerequisites missing — see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_task_open
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_open
    @organization_id      BIGINT,
    @task_type_code       NVARCHAR(60),
    @subject_entity_type  NVARCHAR(60),
    @subject_entity_id    BIGINT,
    @subject_title        NVARCHAR(250),
    @subject_description  NVARCHAR(MAX) = NULL,
    @linked_release_id    BIGINT       = NULL,
    @linked_control_id    BIGINT       = NULL,
    @linked_practice_id   BIGINT       = NULL,
    @linked_instance_id   BIGINT       = NULL,
    @priority             NVARCHAR(30) = NULL,
    @criticality          NVARCHAR(30) = NULL,
    @origin_code          NVARCHAR(30) = NULL,
    @assigned_to_employee_id BIGINT   = NULL,
    @actor_employee_id    BIGINT       = NULL,
    @actor_role_code      NVARCHAR(60) = NULL,
    @correlation_id       UNIQUEIDENTIFIER = NULL,
    @task_id              BIGINT       OUTPUT
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
           @default_priority = default_priority
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

    DECLARE @actor_label NVARCHAR(100) =
        CASE WHEN @actor_employee_id IS NOT NULL
             THEN CONCAT('emp:', CAST(@actor_employee_id AS NVARCHAR(30)))
             ELSE N'system' END;

    DECLARE @now DATETIME2 = SYSUTCDATETIME();
    DECLARE @sla DATETIME2 = DATEADD(HOUR, @default_sla_hours, @now);
    DECLARE @prio NVARCHAR(30) = ISNULL(@priority, @default_priority);

    BEGIN TRAN;

    -- Idempotency for Implementation tasks:
    -- If an open Implementation task already exists for this subject,
    -- return its id instead of inserting a duplicate.
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
         sla_due_at, correlation_id, entered_by)
    VALUES
        (@organization_id, @type_id, @subject_entity_type, @subject_entity_id,
         @linked_release_id, @linked_control_id, @linked_practice_id, @linked_instance_id,
         @subject_title, @subject_description,
         @assigned_to_employee_id, @open_status_id,
         @prio, @criticality, @origin_code,
         @sla, @correlation_id, @actor_label);

    SET @task_id = SCOPE_IDENTITY();

    -- Log initial (creation) transition via framework.
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

    -- If assignee was set at creation, immediately transition Open -> Assigned.
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

-- =====================================================================
-- sp_task_assign — reassign / initial assign
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_assign
    @task_id              BIGINT,
    @assigned_to_employee_id BIGINT,
    @actor_employee_id    BIGINT       = NULL,
    @actor_role_code      NVARCHAR(60) = NULL,
    @reason_code          NVARCHAR(60) = N'TASK_ASSIGNED',
    @reason_text          NVARCHAR(1000) = NULL,
    @correlation_id       UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_id IS NULL OR @assigned_to_employee_id IS NULL
        THROW 53730, 'sp_task_assign: task_id and assigned_to_employee_id are required.', 1;

    DECLARE @from_status_code NVARCHAR(60), @to_status_code NVARCHAR(60) = N'Assigned';
    SELECT @from_status_code = m.status_code
    FROM grac_practice.practice_task t
    JOIN grac_practice.entity_status_master m ON m.entity_status_id = t.current_status_id
    WHERE t.task_id = @task_id;

    IF @from_status_code IS NULL
    BEGIN
        DECLARE @msg NVARCHAR(200) = CONCAT('Task not found: ', CAST(@task_id AS NVARCHAR(30)));
        THROW 53731, @msg, 1;
    END

    BEGIN TRAN;

    -- If currently Open, transition to Assigned; if already Assigned/InProgress,
    -- just update assignee without a status change.
    DECLARE @actor_label NVARCHAR(100) =
        CASE WHEN @actor_employee_id IS NOT NULL
             THEN CONCAT('emp:', CAST(@actor_employee_id AS NVARCHAR(30)))
             ELSE N'system' END;

    IF @from_status_code = N'Open'
    BEGIN
        DECLARE @to_id INT, @log_id BIGINT;
        EXEC grac_practice.sp_pm_state_transition
            @entity_type       = N'Task',
            @entity_id         = @task_id,
            @from_status_code  = @from_status_code,
            @to_status_code    = @to_status_code,
            @actor_employee_id = @actor_employee_id,
            @actor_role_code   = @actor_role_code,
            @reason_code       = @reason_code,
            @reason_text       = @reason_text,
            @correlation_id    = @correlation_id,
            @to_status_id      = @to_id      OUTPUT,
            @transition_log_id = @log_id     OUTPUT;

        UPDATE grac_practice.practice_task
           SET current_status_id       = @to_id,
               assigned_to_employee_id = @assigned_to_employee_id,
               updated_by              = @actor_label,
               updated_dt              = SYSUTCDATETIME()
         WHERE task_id = @task_id;
    END
    ELSE
    BEGIN
        -- Reassignment without status change: still emit an audit_trail row.
        UPDATE grac_practice.practice_task
           SET assigned_to_employee_id = @assigned_to_employee_id,
               updated_by              = @actor_label,
               updated_dt              = SYSUTCDATETIME()
         WHERE task_id = @task_id;

        INSERT INTO grac_practice.practice_audit_trace
            (entity_type, entity_id, action_type, before_json, after_json,
             status, entered_by, entered_dt)
        VALUES
            (N'Task', @task_id, N'REASSIGN',
             (SELECT @from_status_code AS from_status_code FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
             (SELECT @assigned_to_employee_id AS assigned_to_employee_id,
                     @reason_code AS reason_code, @reason_text AS reason_text
              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
             N'Active', @actor_label, SYSUTCDATETIME());
    END

    COMMIT TRAN;
END;
GO

-- =====================================================================
-- sp_task_transition — generic transition; updates current_status_id
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_transition
    @task_id              BIGINT,
    @to_status_code       NVARCHAR(60),
    @actor_employee_id    BIGINT       = NULL,
    @actor_role_code      NVARCHAR(60) = NULL,
    @reason_code          NVARCHAR(60) = NULL,
    @reason_text          NVARCHAR(1000) = NULL,
    @correlation_id       UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_id IS NULL OR @to_status_code IS NULL
        THROW 53740, 'sp_task_transition: task_id and to_status_code are required.', 1;

    DECLARE @from_status_code NVARCHAR(60);
    SELECT @from_status_code = m.status_code
    FROM grac_practice.practice_task t
    JOIN grac_practice.entity_status_master m ON m.entity_status_id = t.current_status_id
    WHERE t.task_id = @task_id;

    IF @from_status_code IS NULL
    BEGIN
        DECLARE @msg NVARCHAR(200) = CONCAT('Task not found: ', CAST(@task_id AS NVARCHAR(30)));
        THROW 53741, @msg, 1;
    END

    BEGIN TRAN;

    DECLARE @to_id INT, @log_id BIGINT;
    EXEC grac_practice.sp_pm_state_transition
        @entity_type       = N'Task',
        @entity_id         = @task_id,
        @from_status_code  = @from_status_code,
        @to_status_code    = @to_status_code,
        @actor_employee_id = @actor_employee_id,
        @actor_role_code   = @actor_role_code,
        @reason_code       = @reason_code,
        @reason_text       = @reason_text,
        @correlation_id    = @correlation_id,
        @to_status_id      = @to_id     OUTPUT,
        @transition_log_id = @log_id    OUTPUT;

    DECLARE @actor_label NVARCHAR(100) =
        CASE WHEN @actor_employee_id IS NOT NULL
             THEN CONCAT('emp:', CAST(@actor_employee_id AS NVARCHAR(30)))
             ELSE N'system' END;

    UPDATE grac_practice.practice_task
       SET current_status_id = @to_id,
           escalated_at      = CASE WHEN @to_status_code = N'Escalated' THEN SYSUTCDATETIME() ELSE escalated_at END,
           reason_code       = @reason_code,
           reason_text       = @reason_text,
           updated_by        = @actor_label,
           updated_dt        = SYSUTCDATETIME()
     WHERE task_id = @task_id;

    COMMIT TRAN;
END;
GO

-- =====================================================================
-- sp_task_close
--   For Implementation tasks, enforce the two-gate rule (charter §12.2.3).
--   Full gate procedures (sp_instance_config_gate_check /
--   sp_instance_operational_gate_check) land in migration 043. Until
--   then, this proc requires the caller to have driven the task through
--   OperationalGatePassed first — a code-level guard that becomes a
--   full DB-level guard when 043 lands.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_close
    @task_id              BIGINT,
    @actor_employee_id    BIGINT       = NULL,
    @actor_role_code      NVARCHAR(60) = NULL,
    @reason_code          NVARCHAR(60) = N'TASK_CLOSED',
    @reason_text          NVARCHAR(1000) = NULL,
    @correlation_id       UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_id IS NULL
        THROW 53750, 'sp_task_close: task_id is required.', 1;

    DECLARE @from_status_code NVARCHAR(60), @task_type_code NVARCHAR(60);
    SELECT @from_status_code = m.status_code,
           @task_type_code   = tt.type_code
    FROM grac_practice.practice_task t
    JOIN grac_practice.entity_status_master m ON m.entity_status_id = t.current_status_id
    JOIN grac_practice.task_type_master tt    ON tt.task_type_id    = t.task_type_id
    WHERE t.task_id = @task_id;

    IF @from_status_code IS NULL
    BEGIN
        DECLARE @msg NVARCHAR(200) = CONCAT('Task not found: ', CAST(@task_id AS NVARCHAR(30)));
        THROW 53751, @msg, 1;
    END

    -- Two-gate closure guard for Implementation tasks (§12.2.3)
    IF @task_type_code = N'Implementation'
       AND @from_status_code NOT IN (N'OperationalGatePassed', N'PendingReview')
    BEGIN
        DECLARE @msg2 NVARCHAR(400) = CONCAT(
            N'Implementation task ', CAST(@task_id AS NVARCHAR(30)),
            N' cannot close from ', @from_status_code,
            N'. Both Config Gate and Operational Gate must pass first.');
        THROW 53752, @msg2, 1;
    END

    BEGIN TRAN;

    DECLARE @to_id INT, @log_id BIGINT;
    EXEC grac_practice.sp_pm_state_transition
        @entity_type       = N'Task',
        @entity_id         = @task_id,
        @from_status_code  = @from_status_code,
        @to_status_code    = N'Closed',
        @actor_employee_id = @actor_employee_id,
        @actor_role_code   = @actor_role_code,
        @reason_code       = @reason_code,
        @reason_text       = @reason_text,
        @correlation_id    = @correlation_id,
        @to_status_id      = @to_id      OUTPUT,
        @transition_log_id = @log_id     OUTPUT;

    DECLARE @actor_label NVARCHAR(100) =
        CASE WHEN @actor_employee_id IS NOT NULL
             THEN CONCAT('emp:', CAST(@actor_employee_id AS NVARCHAR(30)))
             ELSE N'system' END;

    UPDATE grac_practice.practice_task
       SET current_status_id = @to_id,
           closed_at         = SYSUTCDATETIME(),
           reason_code       = @reason_code,
           reason_text       = @reason_text,
           updated_by        = @actor_label,
           updated_dt        = SYSUTCDATETIME()
     WHERE task_id = @task_id;

    COMMIT TRAN;
END;
GO

-- =====================================================================
-- sp_task_overdue_sweep
--   Idempotent SLA breach nudge/escalate. Intended to be called hourly
--   by Hangfire (Q2 approved but wiring pending). Also safe to run
--   ad-hoc from SQL Agent for on-prem deployments without Hangfire.
--
--   Behaviour:
--     * Non-terminal tasks past sla_due_at with escalated_at NULL:
--         set escalated_at = now, transition to Escalated,
--         open a REASON = SLA_BREACH audit row.
--     * Already-escalated tasks are skipped.
--     * Returns the number of tasks it moved.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_overdue_sweep
    @batch_size  INT = 200,
    @escalated_count INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @escalated_count = 0;

    DECLARE @candidates TABLE (task_id BIGINT PRIMARY KEY, from_status_code NVARCHAR(60));

    INSERT INTO @candidates
    SELECT TOP (@batch_size)
           t.task_id, m.status_code
    FROM grac_practice.practice_task t
    JOIN grac_practice.entity_status_master m ON m.entity_status_id = t.current_status_id
    WHERE t.closed_at IS NULL
      AND t.escalated_at IS NULL
      AND t.sla_due_at IS NOT NULL
      AND t.sla_due_at < SYSUTCDATETIME()
      AND m.is_terminal = 0
      AND m.status_code IN (N'Assigned', N'InProgress', N'PendingReview',
                            N'ConfigGatePassed', N'AwaitingFirstExecution',
                            N'OperationalGatePassed')
    ORDER BY t.sla_due_at ASC;

    DECLARE @task_id BIGINT, @from_code NVARCHAR(60);
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT task_id, from_status_code FROM @candidates;
    OPEN cur;
    FETCH NEXT FROM cur INTO @task_id, @from_code;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            BEGIN TRAN;

            DECLARE @to_id INT, @log_id BIGINT;
            EXEC grac_practice.sp_pm_state_transition
                @entity_type       = N'Task',
                @entity_id         = @task_id,
                @from_status_code  = @from_code,
                @to_status_code    = N'Escalated',
                @actor_employee_id = NULL,
                @actor_role_code   = N'GRAC_SYSTEM',
                @reason_code       = N'SLA_BREACH',
                @reason_text       = N'Autoescalated by sp_task_overdue_sweep',
                @correlation_id    = NULL,
                @to_status_id      = @to_id      OUTPUT,
                @transition_log_id = @log_id     OUTPUT;

            UPDATE grac_practice.practice_task
               SET current_status_id = @to_id,
                   escalated_at      = SYSUTCDATETIME(),
                   updated_by        = N'GRAC_SYSTEM',
                   updated_dt        = SYSUTCDATETIME()
             WHERE task_id = @task_id;

            SET @escalated_count += 1;

            COMMIT TRAN;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRAN;
            -- Charter §11: silent failures forbidden. Log to audit trail
            -- as a diagnostic marker; individual failures do not cascade.
            INSERT INTO grac_practice.practice_audit_trace
                (entity_type, entity_id, action_type, before_json, after_json,
                 status, entered_by, entered_dt)
            VALUES
                (N'Task', ISNULL(@task_id, 0), N'SWEEP_ERROR',
                 NULL,
                 (SELECT ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message
                  FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                 N'Error', N'GRAC_SYSTEM', SYSUTCDATETIME());
        END CATCH

        FETCH NEXT FROM cur INTO @task_id, @from_code;
    END
    CLOSE cur;
    DEALLOCATE cur;
END;
GO

-- =====================================================================
-- sp_task_list — filter/pagination read API used by TaskController
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_list
    @organization_id      BIGINT       = NULL,
    @assigned_to_employee_id BIGINT   = NULL,
    @task_type_code       NVARCHAR(60) = NULL,
    @status_code          NVARCHAR(60) = NULL,      -- 'OpenSet' for non-terminal, else specific
    @overdue_only         BIT          = 0,
    @search               NVARCHAR(200) = NULL,
    @page                 INT          = 1,
    @page_size            INT          = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    ;WITH filtered AS (
        SELECT v.*
        FROM grac_practice.vw_pm_practice_task v
        WHERE (@organization_id IS NULL OR v.organization_id = @organization_id)
          AND (@assigned_to_employee_id IS NULL OR v.assigned_to_employee_id = @assigned_to_employee_id)
          AND (@task_type_code IS NULL OR v.task_type_code = @task_type_code)
          AND (
                @status_code IS NULL
             OR (@status_code = N'OpenSet' AND v.current_status_is_terminal = 0)
             OR v.current_status_code = @status_code
              )
          AND (@overdue_only = 0 OR v.is_overdue = 1)
          AND (@search IS NULL
               OR v.subject_title LIKE N'%' + @search + N'%'
               OR v.subject_description LIKE N'%' + @search + N'%')
    )
    SELECT
        (SELECT COUNT_BIG(*) FROM filtered) AS TotalCount,
        @page      AS PageNumber,
        @page_size AS PageSize
    OPTION (RECOMPILE);

    ;WITH filtered AS (
        SELECT v.*
        FROM grac_practice.vw_pm_practice_task v
        WHERE (@organization_id IS NULL OR v.organization_id = @organization_id)
          AND (@assigned_to_employee_id IS NULL OR v.assigned_to_employee_id = @assigned_to_employee_id)
          AND (@task_type_code IS NULL OR v.task_type_code = @task_type_code)
          AND (
                @status_code IS NULL
             OR (@status_code = N'OpenSet' AND v.current_status_is_terminal = 0)
             OR v.current_status_code = @status_code
              )
          AND (@overdue_only = 0 OR v.is_overdue = 1)
          AND (@search IS NULL
               OR v.subject_title LIKE N'%' + @search + N'%'
               OR v.subject_description LIKE N'%' + @search + N'%')
    )
    SELECT *
    FROM filtered
    ORDER BY CASE WHEN sla_due_at IS NULL THEN 1 ELSE 0 END,
             sla_due_at ASC,
             task_id DESC
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY
    OPTION (RECOMPILE);
END;
GO

PRINT '037 task engine procedures installed.';
GO

SELECT '037 task engine procedures migration complete.' AS Message;
GO

SET NOEXEC OFF;
GO
