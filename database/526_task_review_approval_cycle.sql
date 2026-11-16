-- =====================================================================
-- 526  Task review / approval cycle
--
-- REQUEST (2026-11-09)
--   "task nte module le task close cheyyumbo oru review and approve
--    introduce cheyyan pattanam. custom task adikumbo avarku
--    review/approver ne choose cheyyan ulla option venam. select cheythal
--    aa cycle koodi ponam. illenkil athu venda. athu pole thanne task nte
--    schedule nte view/calender view lu ee schedule nte review/approve
--    aranennu update cheyyan ulla option venam. athu cheythal cycle
--    follow cheyyanam."
--
--   Decided with sir in the same exchange:
--     * Two optional people, Reviewer then Approver. Only the step(s)
--       chosen run; with neither, Complete closes the task as today.
--     * Return (from either) sends the task back to the assignee,
--       In Progress, with the reason; completing it again restarts the
--       cycle.
--     * A schedule's reviewer / approver apply to tasks the schedule
--       raises AFTER the change; open tasks are not touched.
--
-- THE CYCLE
--   Complete Task (assignee)
--     reviewer set  -> Pending Review   (review_stage = Review)
--     approver only -> Pending Approval (review_stage = Approval)
--     neither       -> Closed, exactly as before
--   Reviewer:  Approve -> Pending Approval (approver set) or Closed
--              Return  -> In Progress
--   Approver:  Approve -> Closed;  Return -> In Progress
--   "Completed by" stays the person who did the work; the transition log
--   records who approved. Only the designated person (or a system admin)
--   may act, and never the person who completed the task.
--
--   review_stage, not the status, says where the task is in the cycle:
--   the SLA sweep (037) may move a Pending Review task to Escalated, and
--   the reviewer must still be able to act on it.
--
-- WHAT THIS SCRIPT DOES
--   1. practice_task: reviewer_employee_id, approver_employee_id,
--      review_stage, review_submitted_by_employee_id,
--      review_submitted_dt, review_submitted_remark.
--   2. assurance_schedule_rule: reviewer_employee_id,
--      approver_employee_id.
--   3. Task status Pending Approval (Pending Review exists since 035).
--   4. Task transition rules for the cycle (the 350 shape: no role).
--   5. sp_task_complete (200 body): routes a task with a reviewer /
--      approver into the cycle; @review_finalize closes it on the last
--      approval; @suppress_result for the inner call.
--   6. sp_task_list (414 body): @review_employee_id -- "Awaiting my
--      review / approval".
--   7. sp_schedule_obligation_tasks_generate (459 body): copies the
--      schedule's reviewer / approver onto each task it raises.
--   8. New: sp_task_review_settings_set, sp_task_review_get,
--      sp_task_review_decide, sp_schedule_rule_review_get,
--      sp_schedule_rule_review_save.
--
-- ERRORS 55961-55976 (Api: TaskService.HandleSqlError).
-- Re-issued bodies are verbatim apart from the lines marked 526.
-- SAFE TO RE-RUN. Requires 035, 200, 350, 414, 449, 459.
-- Rollback: 526_task_review_approval_cycle_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- Guard on the objects and COLUMNS the re-issued bodies read
-- (reissued_proc_needs_column_guard).
IF OBJECT_ID('grac_practice.practice_task','U') IS NULL
   OR COL_LENGTH('grac_practice.practice_task','completed_by_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_task','source_type_code') IS NULL
   OR COL_LENGTH('grac_practice.practice_task','parent_task_id') IS NULL
   OR OBJECT_ID('grac_practice.assurance_schedule_rule','U') IS NULL
   OR COL_LENGTH('grac_practice.assurance_schedule_rule','updated_by') IS NULL
   OR OBJECT_ID('grac_practice.schedule_occurrence_task','U') IS NULL
   OR OBJECT_ID('grac_practice.entity_status_master','U') IS NULL
   OR OBJECT_ID('grac_practice.entity_state_transition_rule','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_pm_state_transition','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_task_close','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_task_completion_eligibility','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_task_source_sync','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_task_activity_add','P') IS NULL
   OR OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NULL
   OR OBJECT_ID('grac_practice.fn_org_requirement_obligation') IS NULL
   OR NOT EXISTS (SELECT 1 FROM sys.parameters
                   WHERE object_id = OBJECT_ID('grac_practice.sp_task_list') AND name = '@max_age_days')
BEGIN
    PRINT 'ABORT (526): run 035, 200, 350, 414, 449 and 459 first. Nothing was changed.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. practice_task columns
-- =====================================================================
IF COL_LENGTH('grac_practice.practice_task','reviewer_employee_id') IS NULL
    ALTER TABLE grac_practice.practice_task ADD reviewer_employee_id BIGINT NULL;
IF COL_LENGTH('grac_practice.practice_task','approver_employee_id') IS NULL
    ALTER TABLE grac_practice.practice_task ADD approver_employee_id BIGINT NULL;
IF COL_LENGTH('grac_practice.practice_task','review_stage') IS NULL
    ALTER TABLE grac_practice.practice_task ADD review_stage NVARCHAR(20) NULL;
IF COL_LENGTH('grac_practice.practice_task','review_submitted_by_employee_id') IS NULL
    ALTER TABLE grac_practice.practice_task ADD review_submitted_by_employee_id BIGINT NULL;
IF COL_LENGTH('grac_practice.practice_task','review_submitted_dt') IS NULL
    ALTER TABLE grac_practice.practice_task ADD review_submitted_dt DATETIME2 NULL;
IF COL_LENGTH('grac_practice.practice_task','review_submitted_remark') IS NULL
    ALTER TABLE grac_practice.practice_task ADD review_submitted_remark NVARCHAR(MAX) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_review_stage')
    ALTER TABLE grac_practice.practice_task WITH CHECK
      ADD CONSTRAINT ck_pm_practice_task_review_stage
      CHECK (review_stage IS NULL OR review_stage IN (N'Review', N'Approval'));
GO

-- "Awaiting my review / approval" (sp_task_list @review_employee_id).
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_practice_task_review_stage'
                  AND object_id = OBJECT_ID('grac_practice.practice_task'))
    CREATE INDEX ix_pm_practice_task_review_stage
        ON grac_practice.practice_task (review_stage)
        INCLUDE (reviewer_employee_id, approver_employee_id)
        WHERE review_stage IS NOT NULL;
GO

-- =====================================================================
-- 2. assurance_schedule_rule columns
-- =====================================================================
IF COL_LENGTH('grac_practice.assurance_schedule_rule','reviewer_employee_id') IS NULL
    ALTER TABLE grac_practice.assurance_schedule_rule ADD reviewer_employee_id BIGINT NULL;
IF COL_LENGTH('grac_practice.assurance_schedule_rule','approver_employee_id') IS NULL
    ALTER TABLE grac_practice.assurance_schedule_rule ADD approver_employee_id BIGINT NULL;
GO

-- =====================================================================
-- 3. Status Pending Approval (Task). Pending Review is 035's (order 40).
-- =====================================================================
IF NOT EXISTS (SELECT 1 FROM grac_practice.entity_status_master
                WHERE entity_type = N'Task' AND status_code = N'PendingApproval')
    INSERT grac_practice.entity_status_master
           (entity_type, status_code, status_name, display_order, is_terminal, is_initial, description, is_active, entered_by)
    VALUES (N'Task', N'PendingApproval', N'Pending Approval', 45, 0, 0,
            N'Completed and reviewed (or no reviewer); waiting for the approver (526).', 1, N'seed-526');
ELSE
    UPDATE grac_practice.entity_status_master
       SET is_active = 1, updated_by = N'seed-526', updated_dt = SYSUTCDATETIME()
     WHERE entity_type = N'Task' AND status_code = N'PendingApproval' AND is_active = 0;
GO

-- =====================================================================
-- 4. Transition rules (350 shape: actor_role_code NULL -- who may act is
--    decided by the procedures, not the state machine).
-- =====================================================================
;WITH rules AS (
    SELECT * FROM (VALUES
        -- Complete Task with a reviewer
        (N'Task', N'Open',             N'PendingReview',   CAST(NULL AS NVARCHAR(60)), 0),
        (N'Task', N'Assigned',         N'PendingReview',   NULL, 0),
        (N'Task', N'InProgress',       N'PendingReview',   NULL, 0),
        (N'Task', N'Escalated',        N'PendingReview',   NULL, 0),
        -- Complete Task with an approver only / reviewer approves
        (N'Task', N'Open',             N'PendingApproval', NULL, 0),
        (N'Task', N'Assigned',         N'PendingApproval', NULL, 0),
        (N'Task', N'InProgress',       N'PendingApproval', NULL, 0),
        (N'Task', N'Escalated',        N'PendingApproval', NULL, 0),
        (N'Task', N'PendingReview',    N'PendingApproval', NULL, 0),
        -- last approval closes (PendingReview -> Closed is 350's)
        (N'Task', N'PendingApproval',  N'Closed',          NULL, 0),
        -- Return to the assignee
        (N'Task', N'PendingReview',    N'InProgress',      NULL, 1),
        (N'Task', N'PendingApproval',  N'InProgress',      NULL, 1),
        (N'Task', N'Escalated',        N'InProgress',      NULL, 1),
        -- the SLA sweep and Close / Cancel, as for Pending Review
        (N'Task', N'PendingApproval',  N'Escalated',       NULL, 1),
        (N'Task', N'PendingReview',    N'Cancelled',       NULL, 1),
        (N'Task', N'PendingApproval',  N'Cancelled',       NULL, 1)
    ) v(entity_type, from_status_code, to_status_code, actor_role_code, requires_reason)
)
MERGE grac_practice.entity_state_transition_rule AS t
USING rules
   ON  t.entity_type      = rules.entity_type
   AND ISNULL(t.from_status_code, N'__NULL__') = ISNULL(rules.from_status_code, N'__NULL__')
   AND t.to_status_code   = rules.to_status_code
   AND ISNULL(t.actor_role_code, N'__NULL__')  = ISNULL(rules.actor_role_code, N'__NULL__')
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, from_status_code, to_status_code, actor_role_code,
            requires_reason, is_active, entered_by)
    VALUES (rules.entity_type, rules.from_status_code, rules.to_status_code,
            rules.actor_role_code, rules.requires_reason, 1, 'seed-526')
WHEN MATCHED AND (t.is_active = 0) THEN
    UPDATE SET is_active  = 1,
               updated_by = 'seed-526',
               updated_dt = SYSUTCDATETIME();
GO

-- =====================================================================
-- 5. sp_task_complete (200 body; 526 lines marked)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_complete
    @task_id             BIGINT,
    @completion_remark   NVARCHAR(MAX) = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @actor_role_code     NVARCHAR(60)  = NULL,
    @caller_display_name NVARCHAR(100) = N'system',
    -- 526: review / approval cycle.
    --   @review_finalize = 1   called by sp_task_review_decide on the last
    --                          approval: skip the routing below and close.
    --   @completed_by_employee_id   who did the work (the person who
    --                          submitted it), when the actor is the approver.
    --   @suppress_result = 1   no result set (an inner call).
    @review_finalize          BIT    = 0,
    @completed_by_employee_id BIGINT = NULL,
    @suppress_result          BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_id IS NULL
        THROW 55690, 'sp_task_complete: task_id is required.', 1;

    DECLARE @closed_at DATETIME2, @parent_task_id BIGINT, @title NVARCHAR(250),
            @found BIT = 0, @source_type NVARCHAR(40), @source_record_id BIGINT;
    -- 526: the task's reviewer / approver and where it is in the cycle.
    DECLARE @reviewer_id BIGINT, @approver_id BIGINT, @review_stage NVARCHAR(20),
            @from_status_code NVARCHAR(60);
    SELECT @closed_at        = t.closed_at,
           @parent_task_id   = t.parent_task_id,
           @title            = t.subject_title,
           @source_type      = t.source_type_code,
           @source_record_id = t.source_record_id,
           @reviewer_id      = t.reviewer_employee_id,
           @approver_id      = t.approver_employee_id,
           @review_stage     = t.review_stage,
           @from_status_code = m.status_code,
           @found            = 1
      FROM grac_practice.practice_task t
      LEFT JOIN grac_practice.entity_status_master m ON m.entity_status_id = t.current_status_id
     WHERE t.task_id = @task_id;

    IF @found = 0
        THROW 55691, 'sp_task_complete: task not found.', 1;

    IF @closed_at IS NOT NULL
        THROW 55692, 'sp_task_complete: the task is already completed.', 1;

    -- 526: once submitted, the task waits for its reviewer / approver;
    -- completing it again would skip them.
    IF ISNULL(@review_finalize, 0) = 0 AND @review_stage IS NOT NULL
        THROW 55961, 'This task has already been completed and is waiting for review or approval.', 1;
    IF ISNULL(@review_finalize, 0) = 1 AND @review_stage IS NULL
        THROW 55962, 'sp_task_complete: the task is not waiting for review or approval.', 1;

    -- ---- Mandatory-child gate (BRD Sec 12) -----------------------------
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

    -- ---- 526: review / approval cycle ---------------------------------
    -- A task with a reviewer and/or approver is not closed here: it goes
    -- to Pending Review (reviewer set) or Pending Approval (approver
    -- only), and sp_task_review_decide closes it on the last approval by
    -- calling this procedure again with @review_finalize = 1. A task with
    -- neither closes exactly as before.
    IF ISNULL(@review_finalize, 0) = 0
       AND (@reviewer_id IS NOT NULL OR @approver_id IS NOT NULL)
    BEGIN
        DECLARE @next_status NVARCHAR(60) =
                    CASE WHEN @reviewer_id IS NOT NULL THEN N'PendingReview' ELSE N'PendingApproval' END,
                @next_stage  NVARCHAR(20) =
                    CASE WHEN @reviewer_id IS NOT NULL THEN N'Review' ELSE N'Approval' END,
                @waiting_name NVARCHAR(240),
                @sub_to_id INT, @sub_log_id BIGINT;
        SELECT @waiting_name = e.employee_name
          FROM grac_practice.organization_employee e
         WHERE e.employee_id = COALESCE(@reviewer_id, @approver_id);

        BEGIN TRAN;

        EXEC grac_practice.sp_pm_state_transition
             @entity_type       = N'Task',
             @entity_id         = @task_id,
             @from_status_code  = @from_status_code,
             @to_status_code    = @next_status,
             @actor_employee_id = @actor_employee_id,
             @actor_role_code   = @actor_role_code,
             @reason_code       = N'SUBMITTED_FOR_REVIEW',
             @reason_text       = NULL,
             @to_status_id      = @sub_to_id  OUTPUT,
             @transition_log_id = @sub_log_id OUTPUT;

        UPDATE grac_practice.practice_task
           SET current_status_id               = @sub_to_id,
               review_stage                    = @next_stage,
               review_submitted_by_employee_id = @actor_employee_id,
               review_submitted_dt             = SYSUTCDATETIME(),
               review_submitted_remark         = @completion_remark,
               updated_by                      = @caller_display_name,
               updated_dt                      = SYSUTCDATETIME()
         WHERE task_id = @task_id;

        EXEC grac_practice.sp_task_activity_add
             @task_id             = @task_id,
             @activity_type_code  = N'SubmittedForReview',
             @remark              = @completion_remark,
             @to_value            = @waiting_name,
             @actor_employee_id   = @actor_employee_id,
             @caller_display_name = @caller_display_name;

        COMMIT;

        IF ISNULL(@suppress_result, 0) = 0
            SELECT @task_id          AS TaskId,
                   @next_status      AS StatusCode,
                   @parent_task_id   AS ParentTaskId,
                   @source_type      AS SourceTypeCode,
                   @source_record_id AS SourceRecordId,
                   CAST(NULL AS NVARCHAR(30)) AS SourceActionStatusCode;
        RETURN;
    END

    -- 526: on the final approval the work was done by the submitter; the
    -- approver is the actor of the closing transition only.
    DECLARE @done_by BIGINT = COALESCE(@completed_by_employee_id, @actor_employee_id);

    BEGIN TRAN;

    EXEC grac_practice.sp_task_close
         @task_id           = @task_id,
         @actor_employee_id = @actor_employee_id,
         @actor_role_code   = @actor_role_code,
         @reason_code       = N'TASK_COMPLETED',
         @reason_text       = @completion_remark;

    UPDATE grac_practice.practice_task
       SET completed_by_employee_id = @done_by,
           completed_dt             = SYSUTCDATETIME(),
           review_stage             = NULL,   -- 526
           updated_by               = @caller_display_name,
           updated_dt               = SYSUTCDATETIME()
     WHERE task_id = @task_id;

    EXEC grac_practice.sp_task_activity_add
         @task_id             = @task_id,
         @activity_type_code  = N'Completed',
         @remark              = @completion_remark,
         @actor_employee_id   = @done_by,
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

    -- ---- NEW in 200: upstream synchronisation (BRD Sec 14) --------------
    -- Reports; never decides. Nothing below writes to a source table's
    -- own status.
    DECLARE @sync_status NVARCHAR(30) = NULL;

    IF @source_type IS NOT NULL AND @source_record_id IS NOT NULL
    BEGIN
        BEGIN TRY
            EXEC grac_practice.sp_task_source_sync
                 @source_type_code    = @source_type,
                 @source_record_id    = @source_record_id,
                 @caller_display_name = @caller_display_name,
                 @action_status_code  = @sync_status OUTPUT;
        END TRY
        BEGIN CATCH
            DECLARE @sync_warn NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_task_complete: upstream sync warning: ', @sync_warn);
        END CATCH
    END

    IF ISNULL(@suppress_result, 0) = 0
    SELECT @task_id             AS TaskId,
           N'Completed'         AS StatusCode,
           @parent_task_id      AS ParentTaskId,
           @source_type         AS SourceTypeCode,
           @source_record_id    AS SourceRecordId,
           @sync_status         AS SourceActionStatusCode;
END;
GO

-- =====================================================================
-- 6. sp_task_list (414 body; 526 lines marked)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_list
    @organization_id         BIGINT        = NULL,
    @assigned_to_employee_id BIGINT        = NULL,
    @task_type_code          NVARCHAR(60)  = NULL,
    @status_code             NVARCHAR(60)  = NULL,   -- 'OpenSet' for non-terminal, else specific
    @overdue_only            BIT           = 0,
    @search                  NVARCHAR(200) = NULL,
    @page                    INT           = 1,
    @page_size               INT           = 25,
    @parent_task_id          BIGINT        = NULL,   -- children of one parent
    @include_children        BIT           = 0,
    @sla_status_code         NVARCHAR(30)  = NULL,   -- OnTrack/DueSoon/DueToday/Breached/Extended/Completed
    @source_type_code        NVARCHAR(40)  = NULL,
    @source_record_id        BIGINT        = NULL,
    @priority                NVARCHAR(30)  = NULL,
    -- 414: dashboard drill-down. NULL = no opinion.
    --   @no_owner  1 = assigned_to_employee_id IS NULL
    --   @min_age_days / @max_age_days  one ageing band, age measured
    --              from the SLA baseline COALESCE(start_date, entered_dt)
    @no_owner                BIT           = NULL,
    @min_age_days            INT           = NULL,
    @max_age_days            INT           = NULL,
    -- 526: tasks waiting for THIS employee's review or approval.
    @review_employee_id      BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    -- Asking for one parent's children implies you want children.
    IF @parent_task_id IS NOT NULL SET @include_children = 1;

    DECLARE @filtered TABLE (task_id BIGINT PRIMARY KEY, sort_due DATETIME2);

    INSERT INTO @filtered (task_id, sort_due)
    SELECT v.task_id, v.sla_due_at
      FROM grac_practice.vw_pm_practice_task v
     WHERE (@organization_id IS NULL         OR v.organization_id = @organization_id)
       AND (@assigned_to_employee_id IS NULL OR v.assigned_to_employee_id = @assigned_to_employee_id)
       -- Migration 253: the Custom Tasks tab is also the home for gap
       -- remediation work, which opens as 'Rectification'.
       AND (@task_type_code IS NULL
            OR v.task_type_code = @task_type_code
            OR (@task_type_code = N'Custom' AND v.task_type_code = N'Rectification'))
       AND (
             @status_code IS NULL
          OR (@status_code = N'OpenSet' AND v.current_status_is_terminal = 0)
          OR v.current_status_code = @status_code
           )
       AND (@overdue_only = 0 OR v.is_overdue = 1)
       AND (@priority IS NULL                OR v.priority = @priority)
       AND (@sla_status_code IS NULL         OR v.sla_status_code = @sla_status_code)
       AND (@source_type_code IS NULL        OR v.source_type_code = @source_type_code)
       AND (@source_record_id IS NULL        OR v.source_record_id = @source_record_id)
       AND (@parent_task_id IS NULL          OR v.parent_task_id = @parent_task_id)
       AND (@include_children = 1            OR v.parent_task_id IS NULL)
       -- 414
       AND (ISNULL(@no_owner, 0) = 0         OR v.assigned_to_employee_id IS NULL)
       AND (@min_age_days IS NULL
            OR DATEDIFF(DAY, COALESCE(v.start_date, v.entered_dt), SYSUTCDATETIME()) >= @min_age_days)
       AND (@max_age_days IS NULL
            OR DATEDIFF(DAY, COALESCE(v.start_date, v.entered_dt), SYSUTCDATETIME()) <= @max_age_days)
       -- 526
       AND (@review_employee_id IS NULL
            OR EXISTS (SELECT 1 FROM grac_practice.practice_task rt
                        WHERE rt.task_id = v.task_id
                          AND ((rt.review_stage = N'Review'   AND rt.reviewer_employee_id = @review_employee_id)
                            OR (rt.review_stage = N'Approval' AND rt.approver_employee_id = @review_employee_id))))
       AND (@search IS NULL
            OR v.subject_title LIKE N'%' + @search + N'%'
            OR v.subject_description LIKE N'%' + @search + N'%'
            OR v.task_number LIKE N'%' + @search + N'%');

    -- Result-set #1 -- count + paging metadata (unchanged shape)
    SELECT COUNT_BIG(*) AS TotalCount,
           @page        AS PageNumber,
           @page_size   AS PageSize
      FROM @filtered;

    -- Result-set #2 -- the current page
    SELECT v.*
      FROM @filtered f
      JOIN grac_practice.vw_pm_practice_task v ON v.task_id = f.task_id
     ORDER BY CASE WHEN f.sort_due IS NULL THEN 1 ELSE 0 END,
              f.sort_due ASC,
              f.task_id DESC
     OFFSET (@page - 1) * @page_size ROWS
     FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- =====================================================================
-- 7. sp_schedule_obligation_tasks_generate (459 body; 526 lines marked)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_schedule_obligation_tasks_generate
    @organization_id BIGINT        = NULL,   -- NULL = every organisation
    @run_date        DATE          = NULL,   -- NULL = today (UTC)
    @actor           NVARCHAR(100) = N'scheduler',
    @tasks_created   INT           = NULL OUTPUT,
    @error_count     INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;   -- per-row TRY/CATCH must survive a failed task

    DECLARE @today DATE = ISNULL(@run_date, CAST(SYSUTCDATETIME() AS DATE));
    SET @tasks_created = 0;
    SET @error_count   = 0;

    DECLARE @lock INT;
    EXEC @lock = sp_getapplock @Resource = N'grac_practice.schedule_obligation_tasks', @LockMode = N'Exclusive',
                               @LockOwner = N'Session', @LockTimeout = 0;
    IF @lock < 0
    BEGIN
        SELECT @today AS RunDate, N'SKIPPED' AS Result, 0 AS TasksCreated, 0 AS ErrorCount;
        RETURN;
    END

    BEGIN TRY
        -- ---- Active rules with a periodic frequency ---------------------
        CREATE TABLE #rule (
            schedule_rule_id BIGINT NOT NULL PRIMARY KEY,
            organization_id  BIGINT NOT NULL,
            practice_instance_id BIGINT NOT NULL,
            practice_instance_obligation_id BIGINT NULL,
            anchor_date DATE NOT NULL,
            end_date    DATE NULL,
            freq_value  INT NOT NULL,
            freq_unit   NVARCHAR(20) NOT NULL);

        INSERT #rule
        SELECT r.schedule_rule_id, r.organization_id, r.practice_instance_id,
               r.practice_instance_obligation_id, r.anchor_date, r.end_date,
               fm.frequency_value, fm.frequency_unit
          FROM grac_practice.assurance_schedule_rule r
          JOIN grac_practice.frequency_master fm ON fm.frequency_id = r.frequency_id
          JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = r.practice_instance_id
          LEFT JOIN grac_practice.practice_instance_obligation pio
                 ON pio.practice_instance_obligation_id = r.practice_instance_obligation_id
         WHERE r.status = N'Active' AND r.is_active = 1
           AND (@organization_id IS NULL OR r.organization_id = @organization_id)
           AND pi.status = N'Active'
           AND (r.practice_instance_obligation_id IS NULL OR pio.status = N'Active')
           AND fm.frequency_value > 0
           AND fm.frequency_unit IS NOT NULL AND LEN(fm.frequency_unit) > 0
           AND r.anchor_date <= @today
           AND (r.end_date IS NULL OR r.end_date >= @today);

        -- ---- Natural occurrences on @today -----------------------------
        CREATE TABLE #due (schedule_rule_id BIGINT NOT NULL, occurrence_date DATE NOT NULL);

        -- Day / Week: arithmetic (a daily rule can be thousands of steps old).
        INSERT #due (schedule_rule_id, occurrence_date)
        SELECT schedule_rule_id, @today
          FROM #rule
         WHERE freq_unit IN (N'Day', N'Week')
           AND DATEDIFF(DAY, anchor_date, @today)
               % (CASE WHEN freq_unit = N'Week' THEN freq_value * 7 ELSE freq_value END) = 0;

        -- Month / Year / anything else (the C# falls back to AddMonths):
        -- stepped one at a time, as AddMonths/AddYears are, so day-of-month
        -- clamping drifts identically.
        ;WITH step AS (
            SELECT schedule_rule_id, freq_value, freq_unit, anchor_date AS occ
              FROM #rule
             WHERE freq_unit NOT IN (N'Day', N'Week')
            UNION ALL
            SELECT schedule_rule_id, freq_value, freq_unit,
                   CASE WHEN freq_unit = N'Year' THEN DATEADD(YEAR,  freq_value, occ)
                        ELSE                          DATEADD(MONTH, freq_value, occ) END
              FROM step
             WHERE occ < @today
        )
        INSERT #due (schedule_rule_id, occurrence_date)
        SELECT schedule_rule_id, occ FROM step WHERE occ = @today
        OPTION (MAXRECURSION 5000);

        -- ---- Overrides (same rules as the calendar) --------------------
        DELETE d
          FROM #due d
         WHERE EXISTS (SELECT 1 FROM grac_practice.assurance_schedule_override o
                        WHERE o.schedule_rule_id = d.schedule_rule_id
                          AND o.status = N'Active'
                          AND o.override_type IN (N'Skipped', N'Moved')
                          AND o.original_date = d.occurrence_date);

        INSERT #due (schedule_rule_id, occurrence_date)
        SELECT DISTINCT o.schedule_rule_id, @today
          FROM grac_practice.assurance_schedule_override o
          JOIN #rule r ON r.schedule_rule_id = o.schedule_rule_id
         WHERE o.status = N'Active'
           AND ((o.override_type = N'Moved' AND o.new_date = @today)
             OR (o.override_type = N'Added' AND COALESCE(o.new_date, o.original_date) = @today))
           AND NOT EXISTS (SELECT 1 FROM #due d WHERE d.schedule_rule_id = o.schedule_rule_id);

        -- ---- Claim (once per rule and date, ever) ------------------------
        INSERT grac_practice.schedule_occurrence_task
              (organization_id, schedule_rule_id, occurrence_date, practice_instance_id,
               practice_instance_obligation_id, entered_by)
        SELECT r.organization_id, d.schedule_rule_id, d.occurrence_date, r.practice_instance_id,
               r.practice_instance_obligation_id, @actor
          FROM (SELECT DISTINCT schedule_rule_id, occurrence_date FROM #due) d
          JOIN #rule r ON r.schedule_rule_id = d.schedule_rule_id
         WHERE NOT EXISTS (SELECT 1 FROM grac_practice.schedule_occurrence_task x
                            WHERE x.schedule_rule_id = d.schedule_rule_id
                              AND x.occurrence_date  = d.occurrence_date);

        -- ---- Raise a task for every claimed row of the day without one ---
        DECLARE @occ BIGINT, @org BIGINT, @pi BIGINT, @practice BIGINT, @pio BIGINT,
                @owner BIGINT, @crit NVARCHAR(30), @title NVARCHAR(250), @descr NVARCHAR(MAX),
                @ref NVARCHAR(200), @target DATETIME2, @start DATETIME2, @tid BIGINT,
                @date_text NVARCHAR(20);

        DECLARE c CURSOR LOCAL FAST_FORWARD FOR
            SELECT x.occurrence_task_id
              FROM grac_practice.schedule_occurrence_task x
             WHERE x.occurrence_date = @today
               AND x.task_id IS NULL
               AND (@organization_id IS NULL OR x.organization_id = @organization_id)
             ORDER BY x.occurrence_task_id;
        OPEN c;
        FETCH NEXT FROM c INTO @occ;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @tid = NULL;
                SET @date_text = CONVERT(NVARCHAR(20), @today, 106);   -- 06 Oct 2026
                SELECT @org      = x.organization_id,
                       @pi       = x.practice_instance_id,
                       @pio      = x.practice_instance_obligation_id,
                       @practice = pi.practice_id,
                       @crit     = pi.criticality,
                       @owner    = CASE WHEN EXISTS (SELECT 1 FROM grac_practice.organization_employee e
                                                      WHERE e.employee_id = pi.primary_owner_id
                                                        AND e.organization_id = x.organization_id
                                                        AND ISNULL(e.status, N'Active') = N'Active')
                                        THEN pi.primary_owner_id END,
                       @title    = LEFT(CONCAT(COALESCE(NULLIF(LTRIM(RTRIM(pio.obligation_name)), N''),
                                                        pi.instance_name),
                                               N' - due ', @date_text), 250),
                       -- 459: the task description is the OBLIGATION's own
                       -- description -- the organisation's copy for a
                       -- published obligation (fn_org_requirement_obligation),
                       -- obligation_description for one the organisation
                       -- added. Only an obligation with no description falls
                       -- back to the 449 summary, so it is never blank.
                       @descr    = COALESCE(
                                       NULLIF(LTRIM(RTRIM(pio.obligation_description)), N''),
                                       NULLIF(LTRIM(RTRIM(od.obligation_text)), N''),
                                       CONCAT(N'Scheduled ', COALESCE(r.schedule_kind, N'Assurance'),
                                          N' obligation due ', @date_text, N'.', CHAR(13), CHAR(10),
                                          N'Practice instance: ', pi.instance_code, N' - ', pi.instance_name, CHAR(13), CHAR(10),
                                          N'Frequency: ', fm.frequency_name,
                                          CASE WHEN pio.responsibility IS NULL THEN N''
                                               ELSE CONCAT(CHAR(13), CHAR(10), N'Responsibility: ', pio.responsibility) END)),
                       @ref      = CONCAT(N'Schedule rule ', x.schedule_rule_id, N' / ', CONVERT(NVARCHAR(10), x.occurrence_date, 23))
                  FROM grac_practice.schedule_occurrence_task x
                  JOIN grac_practice.assurance_schedule_rule r ON r.schedule_rule_id = x.schedule_rule_id
                  JOIN grac_practice.frequency_master fm ON fm.frequency_id = r.frequency_id
                  JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = x.practice_instance_id
                  LEFT JOIN grac_practice.practice_instance_obligation pio
                         ON pio.practice_instance_obligation_id = x.practice_instance_obligation_id
                  OUTER APPLY (SELECT TOP 1 o.obligation_text
                                 FROM grac_practice.fn_org_requirement_obligation(x.organization_id) o
                                WHERE o.obligation_id = pio.obligation_id
                                ORDER BY CASE WHEN o.status = N'Active' THEN 0 ELSE 1 END) od
                 WHERE x.occurrence_task_id = @occ;

                SET @start  = CAST(@today AS DATETIME2);
                SET @target = DATEADD(SECOND, 86399, CAST(@today AS DATETIME2));   -- end of the due day

                EXEC grac_practice.sp_task_open
                     @organization_id          = @org,
                     @task_type_code           = N'ScheduledObligation',
                     @subject_entity_type      = N'ScheduleOccurrence',
                     @subject_entity_id        = @occ,
                     @subject_title            = @title,
                     @subject_description      = @descr,
                     @linked_practice_id       = @practice,
                     @linked_instance_id       = @pi,
                     @criticality              = @crit,
                     @assigned_to_employee_id  = @owner,
                     @related_entity_type_code = N'PracticeInstance',
                     @related_record_id        = @pi,
                     @start_date               = @start,
                     @target_date              = @target,
                     @source_type_code         = N'Schedule',
                     @source_record_id         = @occ,
                     @source_reference         = @ref,
                     @resolve_owner            = 1,
                     @task_id                  = @tid OUTPUT;

                -- 526: the schedule's reviewer / approver (Task Calendar)
                -- go onto the task it raised, so its completion follows
                -- the review cycle. Copied when the task is raised: a
                -- later change on the schedule affects later tasks only.
                -- Someone who is also the task's assignee is left out
                -- (nobody reviews their own work).
                UPDATE t
                   SET reviewer_employee_id = CASE WHEN r.reviewer_employee_id <> ISNULL(t.assigned_to_employee_id, -1)
                                                   THEN r.reviewer_employee_id END,
                       approver_employee_id = CASE WHEN r.approver_employee_id <> ISNULL(t.assigned_to_employee_id, -1)
                                                   THEN r.approver_employee_id END
                  FROM grac_practice.practice_task t
                  JOIN grac_practice.schedule_occurrence_task x ON x.occurrence_task_id = @occ
                  JOIN grac_practice.assurance_schedule_rule r  ON r.schedule_rule_id   = x.schedule_rule_id
                 WHERE t.task_id = @tid
                   AND (r.reviewer_employee_id IS NOT NULL OR r.approver_employee_id IS NOT NULL);

                UPDATE grac_practice.schedule_occurrence_task
                   SET task_id = @tid, task_error = NULL, updated_by = @actor, updated_dt = SYSUTCDATETIME()
                 WHERE occurrence_task_id = @occ;
                SET @tasks_created = @tasks_created + 1;
            END TRY
            BEGIN CATCH
                IF XACT_STATE() <> 0 ROLLBACK;
                SET @error_count = @error_count + 1;
                UPDATE grac_practice.schedule_occurrence_task
                   SET task_error = LEFT(ERROR_MESSAGE(), 1000), updated_by = @actor, updated_dt = SYSUTCDATETIME()
                 WHERE occurrence_task_id = @occ;
            END CATCH
            FETCH NEXT FROM c INTO @occ;
        END
        CLOSE c;
        DEALLOCATE c;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        EXEC sp_releaseapplock @Resource = N'grac_practice.schedule_obligation_tasks', @LockOwner = N'Session';
        THROW;
    END CATCH

    EXEC sp_releaseapplock @Resource = N'grac_practice.schedule_obligation_tasks', @LockOwner = N'Session';

    SELECT @today AS RunDate, N'OK' AS Result, @tasks_created AS TasksCreated, @error_count AS ErrorCount;
END;
GO

-- =====================================================================
-- 8. New procedures
-- =====================================================================
-- =====================================================================
-- sp_task_review_settings_set -- reviewer / approver of one task.
-- Used by the Api right after a Custom task is opened (Task Centre ->
-- New Task). Both NULL = no review cycle (the task closes on Complete).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_review_settings_set
    @task_id              BIGINT,
    @reviewer_employee_id BIGINT        = NULL,
    @approver_employee_id BIGINT        = NULL,
    @actor_employee_id    BIGINT        = NULL,
    @caller_display_name  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @org BIGINT, @closed_at DATETIME2, @stage NVARCHAR(20), @assignee BIGINT,
            @type_code NVARCHAR(60), @found BIT = 0;
    SELECT @org       = t.organization_id,
           @closed_at = t.closed_at,
           @stage     = t.review_stage,
           @assignee  = t.assigned_to_employee_id,
           @type_code = tt.type_code,
           @found     = 1
      FROM grac_practice.practice_task t
      JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
     WHERE t.task_id = @task_id;

    IF @found = 0
        THROW 55965, 'Task not found.', 1;
    IF @closed_at IS NOT NULL
        THROW 55970, 'The reviewer and approver cannot be changed on a closed task.', 1;
    IF @stage IS NOT NULL
        THROW 55970, 'The reviewer and approver cannot be changed while the task is waiting for review or approval.', 1;
    -- Implementation tasks close through their Config / Operational gates
    -- (037 two-gate rule); they do not take a review cycle.
    IF @type_code = N'Implementation'
       AND (@reviewer_employee_id IS NOT NULL OR @approver_employee_id IS NOT NULL)
        THROW 55971, 'An Implementation task closes through its gates and cannot have a reviewer or approver.', 1;
    IF @reviewer_employee_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM grac_practice.organization_employee e
            WHERE e.employee_id = @reviewer_employee_id AND e.organization_id = @org
              AND ISNULL(e.status, N'Active') = N'Active')
        THROW 55972, 'The reviewer must be an active employee of the task''s organization.', 1;
    IF @approver_employee_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM grac_practice.organization_employee e
            WHERE e.employee_id = @approver_employee_id AND e.organization_id = @org
              AND ISNULL(e.status, N'Active') = N'Active')
        THROW 55972, 'The approver must be an active employee of the task''s organization.', 1;
    IF @reviewer_employee_id IS NOT NULL AND @reviewer_employee_id = @approver_employee_id
        THROW 55973, 'The reviewer and the approver must be two different people.', 1;
    IF @assignee IS NOT NULL
       AND (@reviewer_employee_id = @assignee OR @approver_employee_id = @assignee)
        THROW 55974, 'The reviewer and approver must be someone other than the person the task is assigned to.', 1;

    BEGIN TRAN;

    UPDATE grac_practice.practice_task
       SET reviewer_employee_id = @reviewer_employee_id,
           approver_employee_id = @approver_employee_id,
           updated_by           = @caller_display_name,
           updated_dt           = SYSUTCDATETIME()
     WHERE task_id = @task_id;

    IF @reviewer_employee_id IS NOT NULL OR @approver_employee_id IS NOT NULL
    BEGIN
        DECLARE @summary NVARCHAR(400) = LEFT(CONCAT(
            N'Reviewer: ', COALESCE((SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id = @reviewer_employee_id), N'none'),
            N'; Approver: ', COALESCE((SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id = @approver_employee_id), N'none')), 400);
        EXEC grac_practice.sp_task_activity_add
             @task_id             = @task_id,
             @activity_type_code  = N'ReviewCycleSet',
             @to_value            = @summary,
             @actor_employee_id   = @actor_employee_id,
             @caller_display_name = @caller_display_name;
    END

    COMMIT;

    SELECT @task_id              AS TaskId,
           @reviewer_employee_id AS ReviewerEmployeeId,
           @approver_employee_id AS ApproverEmployeeId;
END;
GO

-- =====================================================================
-- sp_task_review_get -- the review cycle of one task (Task View, the
-- Review / Approve dialog, the Complete page's notice).
-- AwaitingEmployeeId = who must act now (NULL when nobody).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_review_get
    @task_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT t.task_id                          AS TaskId,
           t.reviewer_employee_id             AS ReviewerEmployeeId,
           rv.employee_name                   AS ReviewerName,
           t.approver_employee_id             AS ApproverEmployeeId,
           ap.employee_name                   AS ApproverName,
           t.review_stage                     AS ReviewStage,
           t.review_submitted_by_employee_id  AS SubmittedByEmployeeId,
           sb.employee_name                   AS SubmittedByName,
           t.review_submitted_dt              AS SubmittedDt,
           t.review_submitted_remark          AS SubmittedRemark,
           CASE t.review_stage WHEN N'Review'   THEN t.reviewer_employee_id
                               WHEN N'Approval' THEN t.approver_employee_id END AS AwaitingEmployeeId,
           CASE t.review_stage WHEN N'Review'   THEN rv.employee_name
                               WHEN N'Approval' THEN ap.employee_name END       AS AwaitingName
      FROM grac_practice.practice_task t
      LEFT JOIN grac_practice.organization_employee rv ON rv.employee_id = t.reviewer_employee_id
      LEFT JOIN grac_practice.organization_employee ap ON ap.employee_id = t.approver_employee_id
      LEFT JOIN grac_practice.organization_employee sb ON sb.employee_id = t.review_submitted_by_employee_id
     WHERE t.task_id = @task_id;
END;
GO

-- =====================================================================
-- sp_task_review_decide -- the reviewer / approver acts.
--   Approve at Review   -> Pending Approval (approver set) or Closed
--   Approve at Approval -> Closed
--   Return (either)     -> In Progress, back to the assignee; a remark
--                          is required. Completing again restarts the
--                          cycle from the beginning.
-- Only the designated person may act, and never the person who completed
-- the task. An organisation admin (@is_admin, the Web tier's
-- CallerIdentityHandler rule) may act only when the designated person is
-- no longer an active employee -- otherwise the task could never close.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_review_decide
    @task_id             BIGINT,
    @decision            NVARCHAR(20),
    @remark              NVARCHAR(MAX)  = NULL,
    @actor_employee_id   BIGINT         = NULL,
    @is_admin            BIT            = 0,
    @caller_display_name NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @decision = LTRIM(RTRIM(ISNULL(@decision, N'')));
    IF @decision NOT IN (N'Approve', N'Return')
        THROW 55963, 'The decision must be Approve or Return.', 1;
    IF @actor_employee_id IS NULL AND ISNULL(@is_admin, 0) = 0
        THROW 55964, 'Your sign-in is not linked to an employee, so you cannot review or approve tasks.', 1;

    DECLARE @stage NVARCHAR(20), @reviewer BIGINT, @approver BIGINT, @submitted_by BIGINT,
            @submitted_remark NVARCHAR(MAX), @closed_at DATETIME2, @from_status NVARCHAR(60),
            @approver_name NVARCHAR(240), @found BIT = 0;
    SELECT @stage            = t.review_stage,
           @reviewer         = t.reviewer_employee_id,
           @approver         = t.approver_employee_id,
           @submitted_by     = t.review_submitted_by_employee_id,
           @submitted_remark = t.review_submitted_remark,
           @closed_at        = t.closed_at,
           @from_status      = m.status_code,
           @found            = 1
      FROM grac_practice.practice_task t
      JOIN grac_practice.entity_status_master m ON m.entity_status_id = t.current_status_id
     WHERE t.task_id = @task_id;

    IF @found = 0
        THROW 55965, 'Task not found.', 1;
    IF @stage IS NULL OR @closed_at IS NOT NULL
        THROW 55966, 'This task is not waiting for review or approval.', 1;

    DECLARE @expected BIGINT = CASE @stage WHEN N'Review' THEN @reviewer ELSE @approver END;
    DECLARE @expected_active BIT = CASE WHEN EXISTS (
                SELECT 1 FROM grac_practice.organization_employee e
                 WHERE e.employee_id = @expected AND ISNULL(e.status, N'Active') = N'Active')
            THEN 1 ELSE 0 END;
    IF (@actor_employee_id IS NULL OR @expected IS NULL OR @actor_employee_id <> @expected)
       AND NOT (ISNULL(@is_admin, 0) = 1 AND @expected_active = 0)
    BEGIN
        IF @stage = N'Review'
            THROW 55967, 'Only the reviewer of this task can review it.', 1;
        THROW 55967, 'Only the approver of this task can approve it.', 1;
    END
    IF @actor_employee_id IS NOT NULL AND @actor_employee_id = @submitted_by
        THROW 55968, 'The person who completed the task cannot review or approve it.', 1;

    DECLARE @to_id INT, @log_id BIGINT, @reason NVARCHAR(1000) = LEFT(@remark, 1000);

    -- ---- Return to the assignee -------------------------------------
    IF @decision = N'Return'
    BEGIN
        IF @remark IS NULL OR LEN(LTRIM(RTRIM(@remark))) = 0
            THROW 55969, 'Say why the task is being returned.', 1;

        BEGIN TRAN;
        EXEC grac_practice.sp_pm_state_transition
             @entity_type       = N'Task',
             @entity_id         = @task_id,
             @from_status_code  = @from_status,
             @to_status_code    = N'InProgress',
             @actor_employee_id = @actor_employee_id,
             @reason_code       = N'REVIEW_RETURNED',
             @reason_text       = @reason,
             @to_status_id      = @to_id  OUTPUT,
             @transition_log_id = @log_id OUTPUT;

        UPDATE grac_practice.practice_task
           SET current_status_id = @to_id,
               review_stage      = NULL,
               updated_by        = @caller_display_name,
               updated_dt        = SYSUTCDATETIME()
         WHERE task_id = @task_id;

        EXEC grac_practice.sp_task_activity_add
             @task_id             = @task_id,
             @activity_type_code  = N'ReviewReturned',
             @remark              = @remark,
             @from_value          = @stage,
             @actor_employee_id   = @actor_employee_id,
             @caller_display_name = @caller_display_name;
        COMMIT;

        SELECT @task_id AS TaskId, N'InProgress' AS StatusCode;
        RETURN;
    END

    -- ---- Approve at Review, an approver still to come ----------------
    IF @stage = N'Review' AND @approver IS NOT NULL
    BEGIN
        SELECT @approver_name = employee_name
          FROM grac_practice.organization_employee WHERE employee_id = @approver;

        BEGIN TRAN;
        EXEC grac_practice.sp_pm_state_transition
             @entity_type       = N'Task',
             @entity_id         = @task_id,
             @from_status_code  = @from_status,
             @to_status_code    = N'PendingApproval',
             @actor_employee_id = @actor_employee_id,
             @reason_code       = N'REVIEWED',
             @reason_text       = @reason,
             @to_status_id      = @to_id  OUTPUT,
             @transition_log_id = @log_id OUTPUT;

        UPDATE grac_practice.practice_task
           SET current_status_id = @to_id,
               review_stage      = N'Approval',
               updated_by        = @caller_display_name,
               updated_dt        = SYSUTCDATETIME()
         WHERE task_id = @task_id;

        EXEC grac_practice.sp_task_activity_add
             @task_id             = @task_id,
             @activity_type_code  = N'Reviewed',
             @remark              = @remark,
             @to_value            = @approver_name,
             @actor_employee_id   = @actor_employee_id,
             @caller_display_name = @caller_display_name;
        COMMIT;

        SELECT @task_id AS TaskId, N'PendingApproval' AS StatusCode;
        RETURN;
    END

    -- ---- Last approval: the task closes -------------------------------
    -- The completion itself is sp_task_complete's own close (children,
    -- parent notice, upstream sync), not a copy of it. It runs in its own
    -- transaction; the decision is recorded once it has succeeded.
    EXEC grac_practice.sp_task_complete
         @task_id                  = @task_id,
         @completion_remark        = @submitted_remark,
         @actor_employee_id        = @actor_employee_id,
         @caller_display_name      = @caller_display_name,
         @review_finalize          = 1,
         @completed_by_employee_id = @submitted_by,
         @suppress_result          = 1;

    -- EXEC takes a variable or a constant, never an expression.
    DECLARE @decision_code NVARCHAR(40) = CASE WHEN @stage = N'Review' THEN N'Reviewed' ELSE N'Approved' END;
    EXEC grac_practice.sp_task_activity_add
         @task_id             = @task_id,
         @activity_type_code  = @decision_code,
         @remark              = @remark,
         @actor_employee_id   = @actor_employee_id,
         @caller_display_name = @caller_display_name;

    SELECT @task_id AS TaskId, N'Completed' AS StatusCode;
END;
GO

-- =====================================================================
-- sp_schedule_rule_review_get / _save -- reviewer / approver of a
-- schedule (Task Calendar). Tasks the schedule raises from then on carry
-- them (sp_schedule_obligation_tasks_generate). Saving needs the Practice
-- Instance Owner or a system admin -- the test Edit Schedule applies.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_schedule_rule_review_get
    @schedule_rule_id BIGINT,
    @organization_id  BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT r.schedule_rule_id      AS ScheduleRuleId,
           r.organization_id       AS OrganizationId,
           r.practice_instance_id  AS PracticeInstanceId,
           pi.primary_owner_id     AS OwnerEmployeeId,
           ow.employee_name        AS OwnerName,
           r.reviewer_employee_id  AS ReviewerEmployeeId,
           rv.employee_name        AS ReviewerName,
           r.approver_employee_id  AS ApproverEmployeeId,
           ap.employee_name        AS ApproverName
      FROM grac_practice.assurance_schedule_rule r
      JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = r.practice_instance_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = pi.primary_owner_id
      LEFT JOIN grac_practice.organization_employee rv ON rv.employee_id = r.reviewer_employee_id
      LEFT JOIN grac_practice.organization_employee ap ON ap.employee_id = r.approver_employee_id
     WHERE r.schedule_rule_id = @schedule_rule_id
       AND (@organization_id IS NULL OR r.organization_id = @organization_id);
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_schedule_rule_review_save
    @schedule_rule_id     BIGINT,
    @organization_id      BIGINT        = NULL,
    @reviewer_employee_id BIGINT        = NULL,
    @approver_employee_id BIGINT        = NULL,
    @actor_employee_id    BIGINT        = NULL,
    @is_system_admin      BIT           = 0,
    @caller_display_name  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @org BIGINT, @owner BIGINT, @found BIT = 0;
    SELECT @org   = r.organization_id,
           @owner = pi.primary_owner_id,
           @found = 1
      FROM grac_practice.assurance_schedule_rule r
      JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = r.practice_instance_id
     WHERE r.schedule_rule_id = @schedule_rule_id;

    IF @found = 0 OR (@organization_id IS NOT NULL AND @org <> @organization_id)
        THROW 55975, 'Schedule not found.', 1;
    -- The Task Calendar's Edit Schedule rule (2026-09-23): only the
    -- Practice Instance Owner, or a system admin (PM_ADMIN).
    IF ISNULL(@is_system_admin, 0) = 0
       AND (@actor_employee_id IS NULL OR @owner IS NULL OR @actor_employee_id <> @owner)
        THROW 55976, 'Only the Practice Instance Owner can change the reviewer and approver of this schedule.', 1;
    IF @reviewer_employee_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM grac_practice.organization_employee e
            WHERE e.employee_id = @reviewer_employee_id AND e.organization_id = @org
              AND ISNULL(e.status, N'Active') = N'Active')
        THROW 55972, 'The reviewer must be an active employee of the schedule''s organization.', 1;
    IF @approver_employee_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM grac_practice.organization_employee e
            WHERE e.employee_id = @approver_employee_id AND e.organization_id = @org
              AND ISNULL(e.status, N'Active') = N'Active')
        THROW 55972, 'The approver must be an active employee of the schedule''s organization.', 1;
    IF @reviewer_employee_id IS NOT NULL AND @reviewer_employee_id = @approver_employee_id
        THROW 55973, 'The reviewer and the approver must be two different people.', 1;
    -- The schedule's tasks are assigned to the Practice Instance Owner.
    IF @owner IS NOT NULL
       AND (@reviewer_employee_id = @owner OR @approver_employee_id = @owner)
        THROW 55974, 'The reviewer and approver must be someone other than the Practice Instance Owner, who does the scheduled task.', 1;

    UPDATE grac_practice.assurance_schedule_rule
       SET reviewer_employee_id = @reviewer_employee_id,
           approver_employee_id = @approver_employee_id,
           updated_by           = @caller_display_name,
           updated_dt           = SYSUTCDATETIME()
     WHERE schedule_rule_id = @schedule_rule_id;

    EXEC grac_practice.sp_schedule_rule_review_get
         @schedule_rule_id = @schedule_rule_id,
         @organization_id  = @org;
END;
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '--- 526 verification ---';
SELECT '526 columns'      AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.practice_task','review_stage') IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','reviewer_employee_id') IS NOT NULL
             AND COL_LENGTH('grac_practice.assurance_schedule_rule','approver_employee_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '526 status Pending Approval',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.entity_status_master
                          WHERE entity_type = N'Task' AND status_code = N'PendingApproval' AND is_active = 1)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '526 transitions',
       CASE WHEN grac_practice.fn_is_transition_allowed(N'Task', N'InProgress',      N'PendingReview',   NULL) = 1
             AND grac_practice.fn_is_transition_allowed(N'Task', N'PendingReview',   N'PendingApproval', NULL) = 1
             AND grac_practice.fn_is_transition_allowed(N'Task', N'PendingApproval', N'Closed',          NULL) = 1
             AND grac_practice.fn_is_transition_allowed(N'Task', N'PendingApproval', N'InProgress',      NULL) = 1
             AND grac_practice.fn_is_transition_allowed(N'Task', N'PendingReview',   N'InProgress',      NULL) = 1
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '526 procedures',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('grac_practice.sp_task_complete') AND name = '@review_finalize')
             AND EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('grac_practice.sp_task_list') AND name = '@review_employee_id')
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_schedule_obligation_tasks_generate')) LIKE '%reviewer_employee_id%'
             AND OBJECT_ID('grac_practice.sp_task_review_decide','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_review_get','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_review_settings_set','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_schedule_rule_review_get','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_schedule_rule_review_save','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;
PRINT '526 complete. Deploy the Api and Web, then hard-refresh the browser.';
GO
SET NOEXEC OFF;
GO
