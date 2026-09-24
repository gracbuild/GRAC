-- =====================================================================
-- 269 Task Centre — ONE edit path
--
-- THE PROBLEM
-- -----------
-- Changing three things about a task took three round trips through
-- three different 3-dot actions, three procedures and three audit
-- shapes:
--
--     Update Status   -> sp_task_transition
--     Assign/Reassign -> sp_task_assign
--     Change Priority -> sp_task_priority_change
--
-- and title, description and start date could not be changed AT ALL
-- after creation -- there has never been an sp_task_update. A typo in a
-- task name was permanent.
--
-- Each action also audited differently: sp_task_assign writes an
-- audit_trail row, sp_task_priority_change writes a task_activity row,
-- sp_task_transition writes a state transition log. "What changed on
-- this task?" had three answers in three places.
--
-- ---------------------------------------------------------------------
-- DECISION 1 — COMPOSE THE EXISTING PROCEDURES, DO NOT REPLACE THEM
-- ---------------------------------------------------------------------
-- sp_task_update does NOT reimplement assignment, priority or status.
-- It diffs the change-set and calls the procedure that already owns each
-- field. Every rule those procedures enforce still applies, unchanged
-- and in one place:
--
--     owner     -> sp_task_assign                     (Open -> Assigned)
--     priority  -> sp_task_priority_change            (§7 approval rules)
--     due date  -> sp_task_sla_extension_request_create (§8)
--     status    -> sp_task_transition                 (state machine)
--     title / description / start date / mandatory / child target date
--               -> written here, because nothing else owns them
--
-- Reimplementing them would have created a second place for the §7
-- reduction rule to live, which is exactly the drift this migration
-- exists to end.
--
-- ---------------------------------------------------------------------
-- DECISION 2 — ONLY WHAT CHANGED IS TOUCHED, AND ONLY WHAT CHANGED IS
--              AUDITED
-- ---------------------------------------------------------------------
-- Every parameter is NULL-means-leave-alone, and each is additionally
-- compared against the current value. A form that posts all ten fields
-- because the user edited one produces ONE activity row, not ten
-- "Priority: High -> High" entries.
--
-- The audit is the EXISTING mechanism, not a new one: task_activity
-- already carries from_value / to_value / actor_employee_id /
-- actor_display_name / entered_dt, and sp_task_activity_add already
-- takes @from_value and @to_value. This migration adds no audit table
-- and no audit column. It adds activity_type_code values -- which needs
-- no schema change, because that column is a free NVARCHAR(40) with no
-- CHECK and no FK by design (192).
--
-- ---------------------------------------------------------------------
-- DECISION 3 — ALL OR NOTHING
-- ---------------------------------------------------------------------
-- The whole edit is one transaction. If any single field is refused --
-- an illegal status transition, a priority reduction with no reason, an
-- SLA extension on a task that already has one pending -- NOTHING is
-- saved and the error names the field.
--
-- The alternative (apply what works, report what did not) would leave
-- the operator looking at a form whose fields are now in two different
-- states, having to work out which half took. On a screen whose purpose
-- is an accurate audit trail, a partial save is the wrong default.
--
-- ---------------------------------------------------------------------
-- DECISION 4 — THE RESULT SET REPORTS PER FIELD, BECAUSE "SAVED" WOULD
--              BE A LIE
-- ---------------------------------------------------------------------
-- A priority REDUCTION and an SLA extension do not change the task. They
-- create an Exception Centre request and leave every column exactly as
-- it was (§7, §8). A form that says "Saved" after one of those has told
-- the user something false.
--
-- So sp_task_update returns one row per attempted field:
--
--     FieldCode  FieldLabel  FromValue  ToValue  Outcome  Detail
--
-- Outcome is 'Applied'         the task changed
--            'PendingApproval' a request was raised; the task did NOT
--                              change and will not until approved
--            'Unchanged'       posted, but identical to the current value
--
-- The UI renders that list verbatim. Nobody has to infer from a green
-- tick whether their priority reduction actually happened.
--
-- CONTENTS
--   1. sp_task_edit_options   NEW — what may be edited, and which status
--                                   transitions are legal right now
--   2. sp_task_update         NEW — the single edit entry point
--
-- ERROR CODE RANGE: 56700-56719
-- Rollback: database/269_task_update_rollback.sql
-- Depends:  037 (practice_task, sp_task_assign, sp_task_transition),
--           192 (task_activity), 193 (sp_task_activity_add,
--           sp_task_priority_change), 194 (sla extension request),
--           035 (fn_is_transition_allowed), 268 (closure transitions)
-- Docs:     docs/task-centre-v2.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF OBJECT_ID('grac_practice.practice_task','U') IS NULL
BEGIN PRINT 'ABORT (269): practice_task missing -- run 037 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.task_activity','U') IS NULL
BEGIN PRINT 'ABORT (269): task_activity missing -- run 192 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.sp_task_activity_add','P') IS NULL
BEGIN PRINT 'ABORT (269): sp_task_activity_add missing -- run 193 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.sp_task_assign','P') IS NULL
BEGIN PRINT 'ABORT (269): sp_task_assign missing -- run 037 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.sp_task_transition','P') IS NULL
BEGIN PRINT 'ABORT (269): sp_task_transition missing -- run 037 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.sp_task_priority_change','P') IS NULL
BEGIN PRINT 'ABORT (269): sp_task_priority_change missing -- run 193 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.sp_task_sla_extension_request_create','P') IS NULL
BEGIN PRINT 'ABORT (269): sp_task_sla_extension_request_create missing -- run 194 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.fn_is_transition_allowed','FN') IS NULL
BEGIN PRINT 'ABORT (269): fn_is_transition_allowed missing -- run 035 first.'; SET @ok = 0; END

-- sp_task_activity_add's @from_value/@to_value are what make a field
-- diff recordable without a new audit table. A pre-193 build has the
-- procedure but not those parameters, and the edit would then silently
-- log "Priority changed" with no values -- the exact uselessness this
-- migration exists to remove.
IF OBJECT_ID('grac_practice.sp_task_activity_add','P') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.parameters
                    WHERE object_id = OBJECT_ID('grac_practice.sp_task_activity_add')
                      AND name = '@from_value')
BEGIN
    PRINT 'ABORT (269): sp_task_activity_add has no @from_value -- it is on a pre-193 version.';
    PRINT '            Field-level audit is impossible against it. Run 193 first.';
    SET @ok = 0;
END

IF @ok = 0
BEGIN
    RAISERROR('269_task_update: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_task_edit_options
--
-- Answers "what may this task's editor offer?" in one round trip, so the
-- UI never renders a control whose save SQL would refuse.
--
-- Two result sets:
--   1) editability flags + current values
--   2) the status codes this task may legally move to RIGHT NOW,
--      straight out of fn_is_transition_allowed -- not a hard-coded list
--      in JavaScript that drifts from the rule table the day someone
--      adds a status.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_edit_options
    @task_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @task_id IS NULL
        THROW 56700, 'sp_task_edit_options: task_id is required.', 1;

    DECLARE @status_code NVARCHAR(60), @is_child BIT, @closed_at DATETIME2,
            @task_type NVARCHAR(60), @priority NVARCHAR(30),
            @start_date DATETIME2, @is_mandatory BIT, @updated_dt DATETIME2,
            @child_target DATETIME2;

    SELECT @status_code  = m.status_code,
           @is_child     = CASE WHEN t.parent_task_id IS NOT NULL THEN 1 ELSE 0 END,
           @closed_at    = t.closed_at,
           @task_type    = tt.type_code,
           @priority     = t.priority,
           -- Returned here rather than added to sp_task_list's row: these
           -- three are needed ONLY by the editor, and widening the list
           -- contract that every grid, count and export reads would be a
           -- large change to serve one form.
           @start_date   = t.start_date,
           @is_mandatory = t.is_mandatory_child,
           @child_target = t.child_target_date,
           @updated_dt   = t.updated_dt
      FROM grac_practice.practice_task t
      JOIN grac_practice.entity_status_master m ON m.entity_status_id = t.current_status_id
      JOIN grac_practice.task_type_master tt    ON tt.task_type_id    = t.task_type_id
     WHERE t.task_id = @task_id;

    IF @status_code IS NULL
        THROW 56701, 'sp_task_edit_options: task not found.', 1;

    DECLARE @is_terminal BIT =
        CASE WHEN @closed_at IS NOT NULL THEN 1 ELSE 0 END;

    -- A pending governed request blocks a second one (§7 refuses with
    -- 55622). Reported so the form can disable the control and say why,
    -- rather than letting the user type a reason and then be refused.
    DECLARE @priority_pending BIT = 0, @sla_pending BIT = 0;

    IF COL_LENGTH('grac_practice.practice_task', 'priority_change_status_code') IS NOT NULL
        SELECT @priority_pending =
            CASE WHEN EXISTS (
                SELECT 1 FROM grac_practice.practice_task t
                 WHERE t.task_id = @task_id
                   AND t.priority_change_status_code = N'Pending') THEN 1 ELSE 0 END;

    IF COL_LENGTH('grac_practice.practice_task', 'extension_status_code') IS NOT NULL
        SELECT @sla_pending =
            CASE WHEN EXISTS (
                SELECT 1 FROM grac_practice.practice_task t
                 WHERE t.task_id = @task_id
                   AND t.extension_status_code = N'Pending') THEN 1 ELSE 0 END;

    -- ---- 1) editability -------------------------------------------
    SELECT @task_id                                  AS TaskId,
           @status_code                              AS CurrentStatusCode,
           @task_type                                AS TaskTypeCode,
           @priority                                 AS CurrentPriority,
           @is_child                                 AS IsChild,
           @is_terminal                              AS IsTerminal,
           -- Nothing is editable on a closed task. Reopening is a
           -- deliberate act with its own rule (035 seeds
           -- Closed -> Open for Admin only); editing a closed task
           -- would be that reopening by the back door.
           CASE WHEN @is_terminal = 1 THEN 0 ELSE 1 END AS CanEdit,
           -- §11: a child inherits priority and SLA from its parent, so
           -- neither control is offered on a child row at all.
           CASE WHEN @is_terminal = 1 OR @is_child = 1 THEN 0 ELSE 1 END AS CanEditPriority,
           CASE WHEN @is_terminal = 1 OR @is_child = 1 THEN 0 ELSE 1 END AS CanEditDueDate,
           @priority_pending                         AS PriorityChangePending,
           @sla_pending                              AS SlaExtensionPending,
           CASE WHEN @is_child = 1 THEN 1 ELSE 0 END AS CanEditMandatory,
           -- Current values the editor needs and the list row does not
           -- carry, so the form prefills from one call.
           @start_date                               AS StartDate,
           @is_mandatory                             AS IsMandatoryChild,
           @child_target                             AS ChildTargetDate,
           -- The optimistic-concurrency token. The form posts it back as
           -- @expected_updated_dt; if someone else saved meanwhile, the
           -- update is refused (56705) instead of overwriting them.
           @updated_dt                               AS UpdatedDt;

    -- ---- 2) legal status transitions ------------------------------
    -- Closed and Cancelled are excluded even where the rule table
    -- allows them: closing a task is Complete/Close, which carry the
    -- §12 gate and the completion stamp. Offering "Closed" in an edit
    -- dropdown would be a third way to close a task, bypassing both.
    SELECT s.status_code AS StatusCode,
           s.status_name AS StatusName
      FROM grac_practice.entity_status_master s
     WHERE s.entity_type = N'Task'
       AND s.status_code NOT IN (N'Closed', N'Cancelled')
       AND @is_terminal = 0
       AND (s.status_code = @status_code
            OR grac_practice.fn_is_transition_allowed(
                   N'Task', @status_code, s.status_code, NULL) = 1)
     ORDER BY s.display_order;
END;
GO

-- =====================================================================
-- 2. sp_task_update
--
-- The single edit entry point. Every parameter is NULL-means-unchanged.
--
-- @expected_updated_dt is optimistic concurrency: pass the updated_dt
-- the form was loaded with and a save is refused if someone else has
-- edited the task since. Optional -- NULL skips the check -- because a
-- caller that does not track it should not be forced to lie about it.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_update
    @task_id                 BIGINT,
    @subject_title           NVARCHAR(250)  = NULL,
    @subject_description     NVARCHAR(MAX)  = NULL,
    @assigned_to_employee_id BIGINT         = NULL,
    @priority                NVARCHAR(30)   = NULL,
    @status_code             NVARCHAR(60)   = NULL,
    @start_date              DATETIME2      = NULL,
    @due_at                  DATETIME2      = NULL,
    @is_mandatory_child      BIT            = NULL,
    @child_target_date       DATETIME2      = NULL,
    -- Reasons. The governed paths REQUIRE these (55620 / the extension
    -- procedure's own check); the free fields do not.
    @change_reason           NVARCHAR(MAX)  = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor_role_code         NVARCHAR(60)   = NULL,
    @caller_display_name     NVARCHAR(100)  = N'system',
    @expected_updated_dt     DATETIME2      = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_id IS NULL
        THROW 56702, 'sp_task_update: task_id is required.', 1;

    -- ---- current state -------------------------------------------
    DECLARE @cur_title       NVARCHAR(250),
            @cur_description NVARCHAR(MAX),
            @cur_owner       BIGINT,
            @cur_owner_name  NVARCHAR(240),
            @cur_priority    NVARCHAR(30),
            @cur_status      NVARCHAR(60),
            @cur_start       DATETIME2,
            @cur_due         DATETIME2,
            @cur_mandatory   BIT,
            @cur_child_due   DATETIME2,
            @cur_updated_dt  DATETIME2,
            @closed_at       DATETIME2,
            @parent_task_id  BIGINT;

    SELECT @cur_title       = t.subject_title,
           @cur_description = t.subject_description,
           @cur_owner       = t.assigned_to_employee_id,
           @cur_priority    = t.priority,
           @cur_status      = m.status_code,
           @cur_start       = t.start_date,
           @cur_due         = t.sla_due_at,
           @cur_mandatory   = t.is_mandatory_child,
           @cur_child_due   = t.child_target_date,
           @cur_updated_dt  = t.updated_dt,
           @closed_at       = t.closed_at,
           @parent_task_id  = t.parent_task_id
      FROM grac_practice.practice_task t
      JOIN grac_practice.entity_status_master m ON m.entity_status_id = t.current_status_id
     WHERE t.task_id = @task_id;

    IF @cur_status IS NULL
        THROW 56703, 'sp_task_update: task not found.', 1;

    IF @closed_at IS NOT NULL
        THROW 56704, 'sp_task_update: a closed task cannot be edited. Reopen it first (Closed -> Open is an Admin transition).', 1;

    -- Optimistic concurrency. Two people editing the same task from two
    -- screens is not hypothetical in a task centre, and last-write-wins
    -- would silently discard one of them -- on the one screen whose
    -- purpose is an accurate record of what changed.
    IF @expected_updated_dt IS NOT NULL
       AND @cur_updated_dt IS NOT NULL
       AND @cur_updated_dt <> @expected_updated_dt
        THROW 56705, 'sp_task_update: this task was changed by someone else after you opened it. Reload and re-apply your changes.', 1;

    SELECT @cur_owner_name = e.employee_name
      FROM grac_practice.organization_employee e
     WHERE e.employee_id = @cur_owner;

    -- ---- the per-field report -------------------------------------
    DECLARE @out TABLE (
        Seq        INT IDENTITY(1,1),
        FieldCode  NVARCHAR(40),
        FieldLabel NVARCHAR(60),
        FromValue  NVARCHAR(400),
        ToValue    NVARCHAR(400),
        Outcome    NVARCHAR(20),   -- Applied | PendingApproval | Unchanged
        Detail     NVARCHAR(400)
    );

    BEGIN TRAN;

    BEGIN TRY

    -- =================================================================
    -- FREE FIELDS — owned by nothing else, so written here.
    -- One UPDATE for all of them; one activity row per field changed.
    -- =================================================================
    DECLARE @set_title BIT = 0, @set_desc BIT = 0, @set_start BIT = 0,
            @set_mand  BIT = 0, @set_ctd  BIT = 0;

    IF @subject_title IS NOT NULL AND @subject_title <> ISNULL(@cur_title, N'')
        SET @set_title = 1;
    IF @subject_description IS NOT NULL
       AND ISNULL(@subject_description, N'') <> ISNULL(@cur_description, N'')
        SET @set_desc = 1;
    IF @start_date IS NOT NULL AND (@cur_start IS NULL OR @start_date <> @cur_start)
        SET @set_start = 1;
    IF @is_mandatory_child IS NOT NULL AND @parent_task_id IS NOT NULL
       AND @is_mandatory_child <> ISNULL(@cur_mandatory, 0)
        SET @set_mand = 1;
    IF @child_target_date IS NOT NULL AND @parent_task_id IS NOT NULL
       AND (@cur_child_due IS NULL OR @child_target_date <> @cur_child_due)
        SET @set_ctd = 1;

    IF @set_title = 1 OR @set_desc = 1 OR @set_start = 1 OR @set_mand = 1 OR @set_ctd = 1
    BEGIN
        UPDATE grac_practice.practice_task
           SET subject_title       = CASE WHEN @set_title = 1 THEN @subject_title       ELSE subject_title       END,
               subject_description = CASE WHEN @set_desc  = 1 THEN @subject_description ELSE subject_description END,
               start_date          = CASE WHEN @set_start = 1 THEN @start_date          ELSE start_date          END,
               is_mandatory_child  = CASE WHEN @set_mand  = 1 THEN @is_mandatory_child  ELSE is_mandatory_child  END,
               child_target_date   = CASE WHEN @set_ctd   = 1 THEN @child_target_date   ELSE child_target_date   END,
               updated_by          = @caller_display_name,
               updated_dt          = SYSUTCDATETIME()
         WHERE task_id = @task_id;
    END

    IF @set_title = 1
    BEGIN
        EXEC grac_practice.sp_task_activity_add
             @task_id = @task_id, @activity_type_code = N'FieldChange',
             @remark = N'Task name', @from_value = @cur_title, @to_value = @subject_title,
             @actor_employee_id = @actor_employee_id, @caller_display_name = @caller_display_name;
        INSERT @out (FieldCode, FieldLabel, FromValue, ToValue, Outcome, Detail) VALUES (N'title', N'Task name', @cur_title, @subject_title, N'Applied', NULL);
    END

    IF @set_desc = 1
    BEGIN
        -- Descriptions are NVARCHAR(MAX); from_value/to_value are 400.
        -- Truncated with a marker rather than silently cut, so a reader
        -- knows the audit row is a summary of a longer text.
        DECLARE @d_from NVARCHAR(400) = CASE WHEN LEN(ISNULL(@cur_description, N'')) > 397
                                             THEN LEFT(@cur_description, 397) + N'...' ELSE @cur_description END,
                @d_to   NVARCHAR(400) = CASE WHEN LEN(@subject_description) > 397
                                             THEN LEFT(@subject_description, 397) + N'...' ELSE @subject_description END;
        EXEC grac_practice.sp_task_activity_add
             @task_id = @task_id, @activity_type_code = N'FieldChange',
             @remark = N'Description', @from_value = @d_from, @to_value = @d_to,
             @actor_employee_id = @actor_employee_id, @caller_display_name = @caller_display_name;
        INSERT @out (FieldCode, FieldLabel, FromValue, ToValue, Outcome, Detail) VALUES (N'description', N'Description', @d_from, @d_to, N'Applied', NULL);
    END

    IF @set_start = 1
    BEGIN
        DECLARE @s_from NVARCHAR(400) = CONVERT(NVARCHAR(30), @cur_start, 106),
                @s_to   NVARCHAR(400) = CONVERT(NVARCHAR(30), @start_date, 106);
        EXEC grac_practice.sp_task_activity_add
             @task_id = @task_id, @activity_type_code = N'FieldChange',
             @remark = N'Start date', @from_value = @s_from, @to_value = @s_to,
             @actor_employee_id = @actor_employee_id, @caller_display_name = @caller_display_name;
        INSERT @out (FieldCode, FieldLabel, FromValue, ToValue, Outcome, Detail) VALUES (N'startDate', N'Start date', @s_from, @s_to, N'Applied', NULL);
    END

    IF @set_mand = 1
    BEGIN
        DECLARE @m_from NVARCHAR(400) = CASE WHEN ISNULL(@cur_mandatory,0) = 1 THEN N'Mandatory' ELSE N'Optional' END,
                @m_to   NVARCHAR(400) = CASE WHEN @is_mandatory_child = 1 THEN N'Mandatory' ELSE N'Optional' END;
        EXEC grac_practice.sp_task_activity_add
             @task_id = @task_id, @activity_type_code = N'FieldChange',
             @remark = N'Sub task requirement', @from_value = @m_from, @to_value = @m_to,
             @actor_employee_id = @actor_employee_id, @caller_display_name = @caller_display_name;
        INSERT @out (FieldCode, FieldLabel, FromValue, ToValue, Outcome, Detail) VALUES (N'isMandatoryChild', N'Sub task requirement', @m_from, @m_to, N'Applied',
                            N'Mandatory sub tasks block the parent''s completion (BRD §12).');
    END

    IF @set_ctd = 1
    BEGIN
        DECLARE @c_from NVARCHAR(400) = CONVERT(NVARCHAR(30), @cur_child_due, 106),
                @c_to   NVARCHAR(400) = CONVERT(NVARCHAR(30), @child_target_date, 106);
        EXEC grac_practice.sp_task_activity_add
             @task_id = @task_id, @activity_type_code = N'FieldChange',
             @remark = N'Target date', @from_value = @c_from, @to_value = @c_to,
             @actor_employee_id = @actor_employee_id, @caller_display_name = @caller_display_name;
        INSERT @out (FieldCode, FieldLabel, FromValue, ToValue, Outcome, Detail) VALUES (N'childTargetDate', N'Target date', @c_from, @c_to, N'Applied', NULL);
    END

    -- =================================================================
    -- OWNER — sp_task_assign owns this, including the Open -> Assigned
    -- transition it performs as a side effect.
    -- =================================================================
    IF @assigned_to_employee_id IS NOT NULL
       AND (@cur_owner IS NULL OR @assigned_to_employee_id <> @cur_owner)
    BEGIN
        DECLARE @new_owner_name NVARCHAR(240);
        SELECT @new_owner_name = e.employee_name
          FROM grac_practice.organization_employee e
         WHERE e.employee_id = @assigned_to_employee_id;

        IF @new_owner_name IS NULL
            THROW 56706, 'sp_task_update: the selected owner is not an employee of this organization.', 1;

        EXEC grac_practice.sp_task_assign
             @task_id                 = @task_id,
             @assigned_to_employee_id = @assigned_to_employee_id,
             @actor_employee_id       = @actor_employee_id,
             @actor_role_code         = @actor_role_code,
             @reason_code             = N'TASK_EDIT',
             @reason_text             = @change_reason;

        -- sp_task_assign writes an audit_trail row, not a task_activity
        -- one, so the task's own feed would not show the reassignment.
        -- This is the diff row for the feed -- the same shape every
        -- other field gets.
        EXEC grac_practice.sp_task_activity_add
             @task_id = @task_id, @activity_type_code = N'Reassign',
             @remark = N'Owner', @from_value = @cur_owner_name, @to_value = @new_owner_name,
             @actor_employee_id = @actor_employee_id, @caller_display_name = @caller_display_name;

        INSERT @out (FieldCode, FieldLabel, FromValue, ToValue, Outcome, Detail) VALUES (N'assignedToEmployeeId', N'Owner',
                            ISNULL(@cur_owner_name, N'unassigned'), @new_owner_name, N'Applied', NULL);
    END

    -- =================================================================
    -- STATUS — the state machine owns this.
    --
    -- Closed and Cancelled are refused here on purpose: closing a task
    -- is Complete or Close, which carry the §12 mandatory-child gate and
    -- the completion stamp. Allowing "status = Closed" in an edit would
    -- be a third closure path that bypasses both.
    -- =================================================================
    IF @status_code IS NOT NULL AND @status_code <> @cur_status
    BEGIN
        IF @status_code IN (N'Closed', N'Cancelled')
            THROW 56707, 'sp_task_update: a task is closed with Complete Task or Close Task, not by editing its status -- those carry the mandatory sub task gate and the completion record.', 1;

        IF grac_practice.fn_is_transition_allowed(N'Task', @cur_status, @status_code, @actor_role_code) = 0
        BEGIN
            DECLARE @msg_st NVARCHAR(400) = CONCAT(
                N'sp_task_update: status cannot move from ', @cur_status,
                N' to ', @status_code, N'.');
            THROW 56708, @msg_st, 1;
        END

        DECLARE @from_status_name NVARCHAR(120), @to_status_name NVARCHAR(120);
        SELECT @from_status_name = status_name FROM grac_practice.entity_status_master
         WHERE entity_type = N'Task' AND status_code = @cur_status;
        SELECT @to_status_name = status_name FROM grac_practice.entity_status_master
         WHERE entity_type = N'Task' AND status_code = @status_code;

        EXEC grac_practice.sp_task_transition
             @task_id           = @task_id,
             @to_status_code    = @status_code,
             @actor_employee_id = @actor_employee_id,
             @actor_role_code   = @actor_role_code,
             @reason_code       = N'TASK_EDIT',
             @reason_text       = @change_reason;

        EXEC grac_practice.sp_task_activity_add
             @task_id = @task_id, @activity_type_code = N'StatusChange',
             @remark = N'Status', @from_value = @from_status_name, @to_value = @to_status_name,
             @actor_employee_id = @actor_employee_id, @caller_display_name = @caller_display_name;

        INSERT @out (FieldCode, FieldLabel, FromValue, ToValue, Outcome, Detail) VALUES (N'statusCode', N'Status',
                            ISNULL(@from_status_name, @cur_status),
                            ISNULL(@to_status_name, @status_code), N'Applied', NULL);
    END

    -- =================================================================
    -- PRIORITY — §7. sp_task_priority_change decides whether this
    -- applies or becomes a request; this only reports which happened.
    -- =================================================================
    IF @priority IS NOT NULL AND @priority <> ISNULL(@cur_priority, N'')
    BEGIN
        DECLARE @rank_new INT = CASE @priority     WHEN N'Low' THEN 1 WHEN N'Medium' THEN 2 WHEN N'High' THEN 3 WHEN N'Critical' THEN 4 ELSE 0 END,
                @rank_cur INT = CASE @cur_priority WHEN N'Low' THEN 1 WHEN N'Medium' THEN 2 WHEN N'High' THEN 3 WHEN N'Critical' THEN 4 ELSE 2 END;

        IF @rank_new = 0
            THROW 56709, 'sp_task_update: priority must be Low, Medium, High or Critical.', 1;

        -- Checked here as well as in sp_task_priority_change (55620) so
        -- the whole edit is refused before anything is written, rather
        -- than half-applied and then rolled back by a THROW.
        IF @rank_new < @rank_cur AND (@change_reason IS NULL OR LTRIM(RTRIM(@change_reason)) = N'')
            THROW 56710, 'sp_task_update: reducing priority needs a reason -- it is submitted to Exception Centre for approval (BRD §7).', 1;

        EXEC grac_practice.sp_task_priority_change
             @task_id             = @task_id,
             @new_priority        = @priority,
             @reason              = @change_reason,
             @actor_employee_id   = @actor_employee_id,
             @caller_display_name = @caller_display_name;

        -- sp_task_priority_change already wrote its own PriorityChange /
        -- PriorityRequest activity row with from/to. Not duplicated here
        -- -- the feed would show the same change twice.
        IF @rank_new > @rank_cur
            INSERT @out (FieldCode, FieldLabel, FromValue, ToValue, Outcome, Detail) VALUES (N'priority', N'Priority', @cur_priority, @priority, N'Applied',
                                N'An increase applies immediately and recalculates the SLA.');
        ELSE
            INSERT @out (FieldCode, FieldLabel, FromValue, ToValue, Outcome, Detail) VALUES (N'priority', N'Priority', @cur_priority, @priority, N'PendingApproval',
                                N'A reduction needs Exception Centre approval. The priority is UNCHANGED until it is approved.');
    END

    -- =================================================================
    -- DUE DATE — §8. Always a request; the task never changes here.
    -- =================================================================
    IF @due_at IS NOT NULL AND (@cur_due IS NULL OR @due_at <> @cur_due)
    BEGIN
        IF @change_reason IS NULL OR LTRIM(RTRIM(@change_reason)) = N''
            THROW 56711, 'sp_task_update: changing the due date needs a reason -- it is submitted to Exception Centre as an SLA extension (BRD §8).', 1;

        IF @actor_employee_id IS NULL
            THROW 56712, 'sp_task_update: an SLA extension records who requested it, so actor_employee_id is required.', 1;

        EXEC grac_practice.sp_task_sla_extension_request_create
             @task_id                  = @task_id,
             @requested_due_at         = @due_at,
             @extension_reason         = @change_reason,
             @requested_by_employee_id = @actor_employee_id,
             @caller_display_name      = @caller_display_name;

        INSERT @out (FieldCode, FieldLabel, FromValue, ToValue, Outcome, Detail) VALUES (N'dueAt', N'Due date',
                            CONVERT(NVARCHAR(30), @cur_due, 106),
                            CONVERT(NVARCHAR(30), @due_at, 106), N'PendingApproval',
                            N'An SLA extension needs Exception Centre approval. The due date is UNCHANGED until it is approved.');
    END

    -- =================================================================
    -- A free-text note, when the editor left one and no field carried
    -- it. Without this, "why did you change these three things?" has
    -- nowhere to live.
    -- =================================================================
    IF @change_reason IS NOT NULL AND LTRIM(RTRIM(@change_reason)) <> N''
       AND EXISTS (SELECT 1 FROM @out WHERE Outcome = N'Applied')
       AND NOT EXISTS (SELECT 1 FROM @out WHERE FieldCode IN (N'priority', N'dueAt'))
        EXEC grac_practice.sp_task_activity_add
             @task_id = @task_id, @activity_type_code = N'Update',
             @remark = @change_reason,
             @actor_employee_id = @actor_employee_id, @caller_display_name = @caller_display_name;

    COMMIT;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    -- ---- the report -----------------------------------------------
    -- Empty when the form was saved with nothing actually changed. The
    -- caller reports that honestly rather than claiming a save.
    SELECT FieldCode, FieldLabel, FromValue, ToValue, Outcome, Detail
      FROM @out ORDER BY Seq;
END;
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '--- 269 verification ---';

SELECT '269 sp_task_update exists' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_task_update','P') IS NOT NULL
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

SELECT '269 sp_task_edit_options exists' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_task_edit_options','P') IS NOT NULL
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

SELECT '269 update composes rather than reimplements' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_task_update')
                            AND definition LIKE '%sp_task_assign%'
                            AND definition LIKE '%sp_task_priority_change%'
                            AND definition LIKE '%sp_task_transition%'
                            AND definition LIKE '%sp_task_sla_extension_request_create%')
            THEN 'PASS -- all four owning procedures are called'
            ELSE '*** FAIL -- a field is being written directly that another procedure owns' END AS Result;

SELECT '269 closure is NOT reachable from edit' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_task_update')
                            AND definition LIKE '%56707%')
            THEN 'PASS -- status = Closed/Cancelled is refused'
            ELSE '*** FAIL -- edit could close a task, bypassing the §12 gate' END AS Result;

SELECT '269 audit reuses the existing mechanism' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_task_update')
                            AND definition LIKE '%sp_task_activity_add%'
                            AND definition LIKE '%@from_value%')
            THEN 'PASS -- task_activity with from/to, no new audit table'
            ELSE '*** FAIL' END AS Result;

SELECT '269 no new audit table was created' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.task_field_audit','U') IS NULL
            THEN 'PASS' ELSE '*** FAIL -- a parallel audit store appeared' END AS Result;

PRINT '269 Task edit installed.';
PRINT '     sp_task_update  — one save, per-field audit, all-or-nothing.';
PRINT '     sp_task_edit_options — what may be edited and which statuses are legal.';
PRINT '     Complete / Close remain separate: they carry the §12 gate and the completion stamp.';
GO

SET NOEXEC OFF;
GO
