-- =====================================================================
-- 479 Task Reopen -- bring a Closed task back to Open
--
-- SIR'S INSTRUCTION
-- ------------------
--   A task that was Closed / Inactivated (sp_task_close -> status
--   'Closed') must be reopenable. Who may reopen: an administrator OR
--   the task's own owner (assigned_to_employee_id). (The Edit flow has
--   always said "Reopening a closed task is a separate, deliberate act";
--   this is that act.)
--
-- STATE MACHINE
-- -------------
--   035 already seeds a Closed -> Open transition, but restricted to the
--   'Admin' role (actor_role_code = 'Admin'). fn_is_transition_allowed
--   treats a rule with actor_role_code = NULL as "any role", so this
--   migration ADDS a NULL-role Closed -> Open rule (requires_reason = 1,
--   same as the admin one) so the structural transition is permitted for
--   the owner too. The REAL authorization (admin OR owner) is enforced
--   inside sp_task_reopen, where the owner relationship is known -- the
--   state machine cannot express "owner".
--
-- MIRRORS sp_task_close (037): same sp_pm_state_transition call shape,
--   then updates practice_task (status -> Open, closed_at -> NULL,
--   reason, updated_by/dt). closed_at is cleared so the task leaves every
--   "terminal / closed" filter and list.
--
-- Idempotent / safe to re-run. ASCII-only.
-- DEPENDS ON: 035 (state machine), 037 (sp_task_close pattern),
--             048 (practice_task.assigned_to_employee_id / closed_at).
-- Rollback: 479_task_reopen_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_pm_state_transition','P') IS NULL
   OR OBJECT_ID('grac_practice.practice_task','U') IS NULL
   OR OBJECT_ID('grac_practice.entity_state_transition_rule','U') IS NULL
BEGIN
    RAISERROR('479: prerequisites missing (run 035/037 first).', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Permit Closed -> Open for any role (owner path). Admin rule stays.
-- ---------------------------------------------------------------------
MERGE grac_practice.entity_state_transition_rule AS t
USING (VALUES (N'Task', N'Closed', N'Open', CAST(NULL AS NVARCHAR(60)), 1))
      AS src(entity_type, from_status_code, to_status_code, actor_role_code, requires_reason)
   ON  t.entity_type = src.entity_type
  AND  ISNULL(t.from_status_code, N'__NULL__') = ISNULL(src.from_status_code, N'__NULL__')
  AND  t.to_status_code = src.to_status_code
  AND  ISNULL(t.actor_role_code, N'__NULL__') = ISNULL(src.actor_role_code, N'__NULL__')
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, from_status_code, to_status_code, actor_role_code, requires_reason, entered_by)
    VALUES (src.entity_type, src.from_status_code, src.to_status_code, src.actor_role_code, src.requires_reason, 'seed-479');
GO

-- ---------------------------------------------------------------------
-- 2. sp_task_reopen
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_task_reopen
    @task_id              BIGINT,
    @actor_employee_id    BIGINT         = NULL,
    @actor_role_code      NVARCHAR(60)   = NULL,
    @is_admin             BIT            = 0,
    @reason_text          NVARCHAR(1000) = NULL,
    @correlation_id       UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_id IS NULL
        THROW 53760, 'sp_task_reopen: task_id is required.', 1;

    DECLARE @from_status_code NVARCHAR(60), @owner_id BIGINT;
    SELECT @from_status_code = m.status_code,
           @owner_id         = t.assigned_to_employee_id
    FROM grac_practice.practice_task t
    JOIN grac_practice.entity_status_master m ON m.entity_status_id = t.current_status_id
    WHERE t.task_id = @task_id;

    IF @from_status_code IS NULL
    BEGIN
        DECLARE @msg NVARCHAR(200) = CONCAT('Task not found: ', CAST(@task_id AS NVARCHAR(30)));
        THROW 53761, @msg, 1;
    END

    -- Only a Closed task can be reopened.
    IF @from_status_code <> N'Closed'
    BEGIN
        DECLARE @msg2 NVARCHAR(300) = CONCAT(
            N'Task ', CAST(@task_id AS NVARCHAR(30)),
            N' is ', @from_status_code, N', not Closed -- only a closed task can be reopened.');
        THROW 53762, @msg2, 1;
    END

    -- Authorization: an administrator OR the task's own owner.
    IF ISNULL(@is_admin, 0) = 0
       AND (@actor_employee_id IS NULL OR @owner_id IS NULL OR @actor_employee_id <> @owner_id)
        THROW 53763, 'Only an administrator or the task owner can reopen this task.', 1;

    BEGIN TRAN;

    DECLARE @to_id INT, @log_id BIGINT;
    EXEC grac_practice.sp_pm_state_transition
        @entity_type       = N'Task',
        @entity_id         = @task_id,
        @from_status_code  = N'Closed',
        @to_status_code    = N'Open',
        @actor_employee_id = @actor_employee_id,
        @actor_role_code   = @actor_role_code,
        @reason_code       = N'TASK_REOPENED',
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
           closed_at         = NULL,
           reason_code       = N'TASK_REOPENED',
           reason_text       = @reason_text,
           updated_by        = @actor_label,
           updated_dt        = SYSUTCDATETIME()
     WHERE task_id = @task_id;

    COMMIT TRAN;
END;
GO

PRINT '479 complete: sp_task_reopen created; Closed -> Open permitted for admin or task owner.';
GO
SET NOEXEC OFF;
GO
