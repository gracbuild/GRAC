-- =====================================================================
-- 200 Task completion -> upstream synchronisation ROLLBACK
--
-- Restores sp_task_complete to its 194 body (no upstream sync), then
-- drops the sync procs and the state table.
--
-- Run this FIRST when unwinding Phase 2, before 199/198/197: the
-- restored sp_task_complete no longer references task_source_action_state
-- or task_candidate, so the later drops cannot fail on a dependency.
--
-- DATA LOSS: task_source_action_state is dropped. Everything in it is
-- derived from practice_task, so re-running 200 rebuilds it exactly —
-- nothing unique is lost.
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT '200-rollback: schema grac_practice missing — nothing to do.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. sp_task_complete -> the 194 body
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_task_completion_eligibility','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_task_close','P') IS NULL
BEGIN
    PRINT '200-rollback: 194/037 prerequisites missing — skipping sp_task_complete restore.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_task_complete
    @task_id             BIGINT,
    @completion_remark   NVARCHAR(MAX) = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @actor_role_code     NVARCHAR(60)  = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_id IS NULL
        THROW 55690, 'sp_task_complete: task_id is required.', 1;

    DECLARE @closed_at DATETIME2, @parent_task_id BIGINT, @title NVARCHAR(250),
            @found BIT = 0;
    SELECT @closed_at      = closed_at,
           @parent_task_id = parent_task_id,
           @title          = subject_title,
           @found          = 1
      FROM grac_practice.practice_task WHERE task_id = @task_id;

    IF @found = 0
        THROW 55691, 'sp_task_complete: task not found.', 1;

    IF @closed_at IS NOT NULL
        THROW 55692, 'sp_task_complete: the task is already completed.', 1;

    DECLARE @elig TABLE (
        TaskId BIGINT, IsEligible BIT, Reason NVARCHAR(300),
        ChildCount INT, MandatoryChildCount INT,
        MandatoryChildCompletedCount INT, MandatoryChildOpenCount INT);

    INSERT @elig EXEC grac_practice.sp_task_completion_eligibility @task_id = @task_id;

    DECLARE @eligible BIT, @reason NVARCHAR(300);
    SELECT TOP 1 @eligible = IsEligible, @reason = Reason FROM @elig;

    IF @eligible = 0
    BEGIN
        DECLARE @gate_msg NVARCHAR(400) =
            CONCAT(N'sp_task_complete: task ', CAST(@task_id AS NVARCHAR(20)),
                   N' is not eligible for completion. ', @reason);
        THROW 55693, @gate_msg, 1;
    END

    BEGIN TRAN;

    EXEC grac_practice.sp_task_close
         @task_id           = @task_id,
         @actor_employee_id = @actor_employee_id,
         @actor_role_code   = @actor_role_code,
         @reason_code       = N'TASK_COMPLETED',
         @reason_text       = @completion_remark;

    UPDATE grac_practice.practice_task
       SET completed_by_employee_id = @actor_employee_id,
           completed_dt             = SYSUTCDATETIME(),
           updated_by               = @caller_display_name,
           updated_dt               = SYSUTCDATETIME()
     WHERE task_id = @task_id;

    EXEC grac_practice.sp_task_activity_add
         @task_id             = @task_id,
         @activity_type_code  = N'Completed',
         @remark              = @completion_remark,
         @actor_employee_id   = @actor_employee_id,
         @caller_display_name = @caller_display_name;

    IF @parent_task_id IS NOT NULL
    BEGIN
        EXEC grac_practice.sp_task_activity_add
             @task_id             = @parent_task_id,
             @activity_type_code  = N'ChildCompleted',
             @remark              = @completion_remark,
             @to_value            = @title,
             @actor_employee_id   = @actor_employee_id,
             @caller_display_name = @caller_display_name;

        DECLARE @pelig TABLE (
            TaskId BIGINT, IsEligible BIT, Reason NVARCHAR(300),
            ChildCount INT, MandatoryChildCount INT,
            MandatoryChildCompletedCount INT, MandatoryChildOpenCount INT);

        INSERT @pelig EXEC grac_practice.sp_task_completion_eligibility @task_id = @parent_task_id;

        IF EXISTS (SELECT 1 FROM @pelig WHERE IsEligible = 1)
            EXEC grac_practice.sp_task_activity_add
                 @task_id             = @parent_task_id,
                 @activity_type_code  = N'ParentEligibleForCompletion',
                 @remark              = N'All mandatory child tasks are complete. The parent owner can now confirm completion of the overall objective.',
                 @actor_employee_id   = @actor_employee_id,
                 @caller_display_name = @caller_display_name;
    END

    COMMIT;

    SELECT @task_id        AS TaskId,
           N'Completed'    AS StatusCode,
           @parent_task_id AS ParentTaskId;
END;
GO

SET NOEXEC OFF;
GO

-- ---------------------------------------------------------------------
-- 2. Drop the sync surface
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_task_source_action_state_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_source_action_state_get;
IF OBJECT_ID('grac_practice.sp_task_source_sync','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_source_sync;
GO

IF OBJECT_ID('grac_practice.task_source_action_state','U') IS NOT NULL
    DROP TABLE grac_practice.task_source_action_state;
GO

PRINT '200 upstream synchronisation rolled back; sp_task_complete restored to the 194 body.';
GO
