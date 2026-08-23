-- =====================================================================
-- 196 Task Centre v2 — sp_task_open v3  (BRD §4, §5, §6, §8, §9, §15)
--
-- WHY THIS FILE EXISTS
-- --------------------
-- 193 built the owner ladder and the SLA derivation; 194 built
-- decomposition; 195 built the read layer. But nothing CALLED the new
-- logic at the moment a task is born, so a freshly created task would
-- still get a hardcoded task-type SLA and a NULL owner.
--
-- Putting the wiring inside sp_task_open — rather than in the API tier —
-- means every existing caller inherits it with ZERO call-site changes:
--
--     sp_practice_instance_open_implementation_task  (043)
--     sp_custom_gap_task_create                      (174)
--     sp_task_child_create                           (194)
--     TaskService.OpenAsync / "+ New Task"           (Custom tasks)
--     053 sample data
--
-- STRICT SUPERSET of the 048 definition. Every original parameter keeps
-- its name, default and meaning; the Implementation idempotency
-- short-circuit and the Open -> Assigned transition are byte-for-byte
-- unchanged. Four optional parameters are added at the end.
--
-- WHAT v3 ADDS
--   1. Source reference stamping        — source_type_code / _record_id /
--                                         _reference (BRD §15)
--   2. Automatic owner resolution       — when no assignee was supplied
--                                         (BRD §6), recording which rung
--                                         answered in owner_source_code
--   3. Standard SLA derivation from priority via the org SLA policy
--      (BRD §8), by delegating to sp_task_apply_sla
--
-- DOCUMENTED CONFLICT (BRD §19) — CALLER-SUPPLIED TARGET DATE
-- -----------------------------------------------------------
-- BRD §8 says "Users must not directly edit or overwrite the standard
-- SLA." But the existing Add Implementation Task modal (043) offers a
-- Target Date field, and removing it would delete working functionality,
-- which §19 forbids.
--
-- Resolution: when @target_date IS SUPPLIED we honour it and treat it as
-- the standard commitment — standard_due_at = @target_date,
-- standard_sla_days = the implied day count, sla_source_code =
-- 'TYPE_DEFAULT'. The invariant sla_due_at = COALESCE(extended,
-- standard) therefore still holds, and the org SLA policy is simply not
-- consulted for that task. When @target_date IS NULL — every
-- system-generated path — the policy drives the date exactly as the BRD
-- specifies. Flagged for review in docs/task-centre-v2.md.
--
-- Rollback: database/196_task_centre_v2_open_rollback.sql
-- ERROR CODE RANGE: reuses 53720-53722 (unchanged contract) + 55750-55759
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF COL_LENGTH('grac_practice.practice_task','source_type_code') IS NULL
BEGIN PRINT 'ABORT (196): run 192_task_centre_v2_schema.sql first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_task_owner_resolve','P') IS NULL
BEGIN PRINT 'ABORT (196): sp_task_owner_resolve missing — run 193 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_task_apply_sla','P') IS NULL
BEGIN PRINT 'ABORT (196): sp_task_apply_sla missing — run 193 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.fn_get_entity_status_id','FN') IS NULL
BEGIN PRINT 'ABORT (196): fn_get_entity_status_id missing — run 035 first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('196_task_centre_v2_open: prerequisites missing.', 16, 1);
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
    -- from 048 (v2):
    @related_entity_type_code NVARCHAR(60)  = NULL,
    @related_record_id        BIGINT        = NULL,
    @start_date               DATETIME2     = NULL,
    @target_date              DATETIME2     = NULL,
    @workflow_id              BIGINT        = NULL,
    @current_workflow_stage_id BIGINT       = NULL,
    @assurance_activity_id    BIGINT        = NULL,
    -- new in 196 (v3):
    @source_type_code         NVARCHAR(40)  = NULL,
    @source_record_id         BIGINT        = NULL,
    @source_reference         NVARCHAR(200) = NULL,
    @resolve_owner            BIT           = 1,
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

    -- =================================================================
    -- v3: source reference (BRD §15)
    --
    -- Default the source from the state-machine subject so EVERY task —
    -- including ones created by callers that predate 192 — is navigable
    -- from its origin. Callers that know better pass it explicitly.
    -- 'TaskChild' is left NULL here: sp_task_child_create overwrites it
    -- with the PARENT's source immediately after creation, so a child
    -- traces back to the same Gap/Risk/Assurance as its parent.
    -- =================================================================
    IF @source_type_code IS NULL
        SET @source_type_code =
            CASE @subject_entity_type
                 WHEN N'CustomGap'        THEN N'Gap'
                 WHEN N'ExceptionRequest' THEN N'Exception'
                 WHEN N'Risk'             THEN N'Risk'
                 WHEN N'AssuranceTicket'  THEN N'ContinuousAssurance'
                 WHEN N'AssuranceActivity' THEN N'ContinuousAssurance'
                 WHEN N'EventInstance'    THEN N'EventAssurance'
                 WHEN N'TaskChild'        THEN NULL
                 ELSE N'Custom'
            END;

    IF @source_record_id IS NULL AND @source_type_code IS NOT NULL
        SET @source_record_id = @subject_entity_id;

    -- =================================================================
    -- v3: owner resolution (BRD §6)
    --
    -- Only when the caller did not name an owner. An explicit assignee
    -- always wins — the ladder exists to PROPOSE, never to override.
    -- =================================================================
    DECLARE @owner_source_code NVARCHAR(40) =
        CASE WHEN @assigned_to_employee_id IS NOT NULL THEN N'EXPLICIT_SOURCE' END;

    IF @assigned_to_employee_id IS NULL AND ISNULL(@resolve_owner, 1) = 1
    BEGIN
        DECLARE @resolved TABLE (
            OwnerEmployeeId BIGINT, OwnerEmployeeName NVARCHAR(200),
            OwnerSourceCode NVARCHAR(40), OwnerSourceName NVARCHAR(120));

        BEGIN TRY
            INSERT @resolved
            EXEC grac_practice.sp_task_owner_resolve
                 @organization_id    = @organization_id,
                 @source_type_code   = @source_type_code,
                 @source_record_id   = @source_record_id,
                 @linked_practice_id = @linked_practice_id,
                 @linked_control_id  = @linked_control_id,
                 @linked_instance_id = @linked_instance_id;

            SELECT TOP 1 @assigned_to_employee_id = OwnerEmployeeId,
                         @owner_source_code       = OwnerSourceCode
              FROM @resolved;
        END TRY
        BEGIN CATCH
            -- Owner resolution is a convenience, never a blocker. A task
            -- with no owner is recoverable (the UI prompts for manual
            -- assignment); a task that failed to be created is not.
            DECLARE @owner_warn NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_task_open: owner resolution warning: ', @owner_warn);
            SET @owner_source_code = N'MANUAL';
        END CATCH
    END

    BEGIN TRAN;

    -- Idempotency for Implementation tasks (unchanged behaviour).
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
         start_date, workflow_id, current_workflow_stage_id, assurance_activity_id,
         source_type_code, source_record_id, source_reference, owner_source_code)
    VALUES
        (@organization_id, @type_id, @subject_entity_type, @subject_entity_id,
         @linked_release_id, @linked_control_id, @linked_practice_id, @linked_instance_id,
         @subject_title, @subject_description,
         @assigned_to_employee_id, @open_status_id,
         @prio, @criticality, @origin_code,
         @sla, @correlation_id, @actor_label,
         @related_type_id, @related_record_id,
         @start_date, @workflow_id, @current_workflow_stage_id, @assurance_activity_id,
         @source_type_code, @source_record_id, @source_reference,
         ISNULL(@owner_source_code, N'MANUAL'));

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

    -- =================================================================
    -- v3: standard SLA  (BRD §8)  — after COMMIT, on purpose.
    --
    -- A missing or misconfigured org SLA policy must never roll back a
    -- successfully created task. sp_task_apply_sla is idempotent and can
    -- be re-run at any time, so the worst case is a task that briefly
    -- carries the legacy task-type SLA.
    -- =================================================================
    IF @target_date IS NULL
    BEGIN
        BEGIN TRY
            EXEC grac_practice.sp_task_apply_sla
                 @task_id             = @task_id,
                 @caller_display_name = @actor_label;
        END TRY
        BEGIN CATCH
            DECLARE @sla_warn NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_task_open: SLA derivation warning: ', @sla_warn);
        END CATCH
    END
    ELSE
    BEGIN
        -- Caller-supplied target date wins — see the documented conflict
        -- in this file's header. Record it AS the standard commitment so
        -- the sla_due_at = COALESCE(extended, standard) invariant holds.
        UPDATE grac_practice.practice_task
           SET standard_due_at   = @target_date,
               standard_sla_days = DATEDIFF(DAY, CAST(COALESCE(@start_date, @now) AS DATE),
                                                 CAST(@target_date AS DATE)),
               sla_source_code   = N'TYPE_DEFAULT'
         WHERE task_id = @task_id
           AND standard_due_at IS NULL;
    END
END;
GO

-- =====================================================================
-- Sanity — confirm the v3 signature is in place.
-- =====================================================================
SELECT 'sp_task_open v3 accepts source + owner params' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_task_open')
                            AND name = '@source_type_code')
             AND EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_task_open')
                            AND name = '@resolve_owner')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'original 048 parameters preserved' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM sys.parameters
                   WHERE object_id = OBJECT_ID('grac_practice.sp_task_open')
                     AND name IN ('@organization_id','@task_type_code','@subject_entity_type',
                                  '@subject_entity_id','@subject_title','@subject_description',
                                  '@linked_release_id','@linked_control_id','@linked_practice_id',
                                  '@linked_instance_id','@priority','@criticality','@origin_code',
                                  '@assigned_to_employee_id','@actor_employee_id','@actor_role_code',
                                  '@correlation_id','@related_entity_type_code','@related_record_id',
                                  '@start_date','@target_date','@workflow_id',
                                  '@current_workflow_stage_id','@assurance_activity_id','@task_id')) = 25
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '196 sp_task_open v3 installed — owner ladder + org SLA policy now apply at task creation.';
GO

SET NOEXEC OFF;
GO
