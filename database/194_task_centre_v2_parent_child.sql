-- =====================================================================
-- 194 Task Centre v2 — SLA extension, parent/child decomposition and
--     governed completion  (BRD §8, §11, §12)
--
-- CONTENTS
--   1. sp_task_sla_extension_request_create — raise the request (§8)
--   2. sp_task_sla_extension_approve        — apply an approved one (§8)
--   3. sp_task_child_create                 — decompose a parent (§11)
--   4. sp_task_completion_eligibility       — read-only gate check (§12)
--   5. sp_task_complete                     — governed completion (§10, §12)
--
-- THE TWO INVARIANTS THIS FILE PROTECTS
-- -------------------------------------
--  A. An approved SLA extension NEVER overwrites the standard SLA.
--     standard_sla_days / standard_due_at stay exactly as derived from
--     priority; approved_extended_due_at is a SEPARATE field and only
--     monitoring switches to it, and only after approval (BRD §8, §13).
--
--  B. The parent owns the commitment; children distribute the work.
--     A child cannot change priority, cannot change or extend SLA,
--     cannot have children of its own, and cannot have a target date
--     beyond the parent's. Completing a child NEVER completes the
--     parent (BRD §11, §12).
--
-- Rollback: database/194_task_centre_v2_parent_child_rollback.sql
-- ERROR CODE RANGE: 55650-55699
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF COL_LENGTH('grac_practice.practice_task','approved_extended_due_at') IS NULL
BEGIN PRINT 'ABORT (194): run 192_task_centre_v2_schema.sql first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_task_apply_sla','P') IS NULL
BEGIN PRINT 'ABORT (194): sp_task_apply_sla missing — run 193_task_centre_v2_procs.sql first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_task_activity_add','P') IS NULL
BEGIN PRINT 'ABORT (194): sp_task_activity_add missing — run 193 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_task_open','P') IS NULL
BEGIN PRINT 'ABORT (194): sp_task_open missing — run 037/048 first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('194_task_centre_v2_parent_child: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_task_sla_extension_request_create  (BRD §8)
--
-- "An SLA extension is not a direct SLA override. It is a controlled
--  exception handled through Exception Centre."
--
-- What this proc does NOT do is as important as what it does:
--   * it does NOT touch standard_sla_days / standard_due_at
--   * it does NOT touch sla_due_at — BRD §20: an extension request
--     "cannot alter the effective due date until approved"
--   * it does NOT touch priority
--
-- It records the ask, parks it on the task for display, and hands the
-- decision to Exception Centre.
--
-- Early completion needs no request at all (BRD §8: "Early completion is
-- always permitted"), so a requested date that is not LATER than the
-- current commitment is rejected as meaningless.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_sla_extension_request_create
    @task_id                  BIGINT,
    @requested_due_at         DATETIME2,
    @extension_reason         NVARCHAR(MAX),
    @requested_by_employee_id BIGINT,
    @caller_display_name      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_id IS NULL
        THROW 55650, 'sp_task_sla_extension_request_create: task_id is required.', 1;
    IF @requested_due_at IS NULL
        THROW 55651, 'sp_task_sla_extension_request_create: requested_due_at is required.', 1;
    IF @extension_reason IS NULL OR LEN(LTRIM(RTRIM(@extension_reason))) = 0
        THROW 55652, 'sp_task_sla_extension_request_create: extension_reason is required.', 1;
    IF @requested_by_employee_id IS NULL
        THROW 55653, 'sp_task_sla_extension_request_create: requested_by_employee_id is required.', 1;

    DECLARE @organization_id BIGINT,
            @parent_task_id  BIGINT,
            @closed_at       DATETIME2,
            @title           NVARCHAR(250),
            @standard_days   INT,
            @standard_due    DATETIME2,
            @effective_due   DATETIME2,
            @ext_status      NVARCHAR(20),
            @baseline        DATETIME2;

    SELECT @organization_id = t.organization_id,
           @parent_task_id  = t.parent_task_id,
           @closed_at       = t.closed_at,
           @title           = t.subject_title,
           @standard_days   = t.standard_sla_days,
           @standard_due    = t.standard_due_at,
           @effective_due   = t.sla_due_at,
           @ext_status      = t.extension_status_code,
           @baseline        = COALESCE(t.start_date, t.entered_dt)
      FROM grac_practice.practice_task t
     WHERE t.task_id = @task_id;

    IF @organization_id IS NULL
        THROW 55654, 'sp_task_sla_extension_request_create: task not found.', 1;
    IF @closed_at IS NOT NULL
        THROW 55655, 'sp_task_sla_extension_request_create: the task is already completed.', 1;

    -- BRD §11: "An SLA extension request is raised against the Parent Task."
    IF @parent_task_id IS NOT NULL
        THROW 55656, 'sp_task_sla_extension_request_create: child tasks cannot extend SLA independently. Raise the request on the parent task.', 1;

    IF @ext_status = N'Pending'
        THROW 55657, 'sp_task_sla_extension_request_create: an SLA extension is already awaiting approval for this task.', 1;

    IF @effective_due IS NOT NULL AND @requested_due_at <= @effective_due
        THROW 55658, 'sp_task_sla_extension_request_create: the requested due date must be later than the current due date. Early completion needs no approval.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
          FROM grac_practice.record_status_master
         WHERE status_code = 'ACTIVE' OR status_name = 'Active'
         ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    -- Day count is derived for reporting parity with the gap SLA flow
    -- (184 stores sla_days_*); the authoritative payload for a task is
    -- the absolute date pair due_at_original / due_at_requested.
    DECLARE @days_requested INT = DATEDIFF(DAY, CAST(@baseline AS DATE), CAST(@requested_due_at AS DATE));

    DECLARE @request_title NVARCHAR(300) =
        CONCAT(N'SLA extension: ', LEFT(ISNULL(@title, N''), 180),
               N' (to ', CONVERT(NVARCHAR(10), @requested_due_at, 23), N')');

    BEGIN TRAN;

    INSERT INTO grac_practice.exception_request
        (organization_id, custom_gap_id, task_id, request_title, request_reason,
         status_code, request_type_code,
         sla_days_original, sla_days_requested,
         due_at_original,  due_at_requested,
         requested_by_employee_id, requested_dt,
         record_status_id, entered_by, entered_dt)
    VALUES
        (@organization_id, NULL, @task_id, @request_title, @extension_reason,
         N'Pending', N'TASK_SLA_EXTENSION',
         @standard_days, @days_requested,
         @standard_due,  @requested_due_at,
         @requested_by_employee_id, SYSUTCDATETIME(),
         @active_record_status_id, @caller_display_name, SYSUTCDATETIME());

    DECLARE @request_id BIGINT = SCOPE_IDENTITY();

    INSERT INTO grac_practice.exception_request_history
        (exception_request_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@request_id, N'Create', NULL, N'Pending',
         CONCAT(N'SLA extension requested to ', CONVERT(NVARCHAR(10), @requested_due_at, 23),
                N' (standard due ', ISNULL(CONVERT(NVARCHAR(10), @standard_due, 23), N'unset'),
                N'). Reason: ', @extension_reason),
         @requested_by_employee_id, @caller_display_name, @caller_display_name, SYSUTCDATETIME());

    -- Park the ask on the task for display only. sla_due_at is untouched.
    UPDATE grac_practice.practice_task
       SET extension_status_code = N'Pending',
           requested_due_at      = @requested_due_at,
           extension_reason      = @extension_reason,
           updated_by            = @caller_display_name,
           updated_dt            = SYSUTCDATETIME()
     WHERE task_id = @task_id;

    EXEC grac_practice.sp_task_activity_add
         @task_id             = @task_id,
         @activity_type_code  = N'SlaExtensionRequest',
         @remark              = @extension_reason,
         @from_value          = @effective_due,
         @to_value            = @requested_due_at,
         @actor_employee_id   = @requested_by_employee_id,
         @caller_display_name = @caller_display_name;

    COMMIT;

    SELECT @request_id      AS ExceptionRequestId,
           N'Pending'       AS StatusCode,
           @task_id         AS TaskId,
           @standard_due    AS StandardDueAt,
           @requested_due_at AS RequestedDueAt;
END;
GO

-- =====================================================================
-- 2. sp_task_sla_extension_approve  (BRD §8, §13)
--
-- "If approved, retain original Standard SLA and store Approved Extended
--  Due Date. Monitor the task against the approved extended due date
--  only after approval."
--
-- Note on escalated_at: if the task had already breached and been
-- auto-escalated by sp_task_overdue_sweep (037), an approved extension
-- gives it a fresh, future commitment. We clear escalated_at so the
-- sweeper can escalate again if the NEW date is missed. The breach is
-- not erased — the transition log, task_activity and practice_audit_trace
-- all retain it.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_sla_extension_approve
    @exception_request_id    BIGINT,
    @approved_by_employee_id BIGINT,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @exception_request_id IS NULL
        THROW 55660, 'sp_task_sla_extension_approve: exception_request_id is required.', 1;
    IF @approved_by_employee_id IS NULL
        THROW 55661, 'sp_task_sla_extension_approve: approved_by_employee_id is required.', 1;

    DECLARE @task_id BIGINT, @type NVARCHAR(30), @status NVARCHAR(30),
            @due_original DATETIME2, @due_requested DATETIME2;

    SELECT @task_id       = task_id,
           @type          = request_type_code,
           @status        = status_code,
           @due_original  = due_at_original,
           @due_requested = due_at_requested
      FROM grac_practice.exception_request
     WHERE exception_request_id = @exception_request_id;

    IF @task_id IS NULL
        THROW 55662, 'sp_task_sla_extension_approve: request not found or not linked to a task.', 1;
    IF @type <> N'TASK_SLA_EXTENSION'
        THROW 55663, 'sp_task_sla_extension_approve: not an SLA extension request. Use sp_sla_override_approve for gap SLA overrides.', 1;
    IF @status <> N'Pending'
        THROW 55664, 'sp_task_sla_extension_approve: only Pending requests can be approved.', 1;
    IF @due_requested IS NULL
        THROW 55665, 'sp_task_sla_extension_approve: request is missing due_at_requested; cannot apply.', 1;

    BEGIN TRAN;

    UPDATE grac_practice.exception_request
       SET status_code             = N'Approved',
           approved_by_employee_id = @approved_by_employee_id,
           approved_dt             = SYSUTCDATETIME(),
           updated_by              = @caller_display_name,
           updated_dt              = SYSUTCDATETIME()
     WHERE exception_request_id = @exception_request_id;

    INSERT INTO grac_practice.exception_request_history
        (exception_request_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@exception_request_id, N'Approve', N'Pending', N'Approved',
         CONCAT(N'SLA extension approved. Approved extended due date: ',
                CONVERT(NVARCHAR(10), @due_requested, 23),
                N'. Standard SLA retained.'),
         @approved_by_employee_id, @caller_display_name, @caller_display_name, SYSUTCDATETIME());

    -- Record the approval. standard_sla_days / standard_due_at are NOT in
    -- this UPDATE list — that omission is the whole point of BRD §8.
    UPDATE grac_practice.practice_task
       SET approved_extended_due_at = @due_requested,
           extension_status_code    = N'Approved',
           escalated_at             = CASE WHEN @due_requested > SYSUTCDATETIME() THEN NULL ELSE escalated_at END,
           updated_by               = @caller_display_name,
           updated_dt               = SYSUTCDATETIME()
     WHERE task_id = @task_id;

    -- sp_task_apply_sla now sees extension_status_code = 'Approved' and
    -- recomputes sla_due_at = approved_extended_due_at, stamps
    -- sla_source_code = 'EXTENDED', and cascades to every open child.
    EXEC grac_practice.sp_task_apply_sla
         @task_id             = @task_id,
         @caller_display_name = @caller_display_name;

    EXEC grac_practice.sp_task_activity_add
         @task_id             = @task_id,
         @activity_type_code  = N'SlaExtensionApproved',
         @remark              = N'SLA extension approved via Exception Centre. Standard SLA retained for reporting.',
         @from_value          = @due_original,
         @to_value            = @due_requested,
         @actor_employee_id   = @approved_by_employee_id,
         @caller_display_name = @caller_display_name;

    INSERT INTO grac_practice.practice_audit_trace
        (entity_type, entity_id, action_type, before_json, after_json,
         status, entered_by, entered_dt)
    VALUES
        (N'Task', @task_id, N'SLA_EXTENSION_APPROVED',
         (SELECT @due_original AS standard_due_at FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
         (SELECT @due_requested AS approved_extended_due_at,
                 @exception_request_id AS exception_request_id
          FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
         N'Active', @caller_display_name, SYSUTCDATETIME());

    COMMIT;

    SELECT @exception_request_id AS ExceptionRequestId,
           N'Approved'           AS StatusCode,
           @task_id              AS TaskId,
           @due_requested        AS ApprovedExtendedDueAt;
END;
GO

-- =====================================================================
-- 3. sp_task_child_create  (BRD §11)
--
-- "An Approved Task may require multiple independent activities to
--  complete its overall objective."
--
-- TWO IMPLEMENTATION DECISIONS WORTH KNOWING
-- ------------------------------------------
--  a) subject_entity_type = 'TaskChild', subject_entity_id = parent id.
--     Children must NOT reuse the parent's subject pair, because 037's
--     filtered unique index ux_pm_practice_task_impl_dedup allows only
--     one open Implementation task per (subject_entity_type,
--     subject_entity_id) — sp_task_open would return the PARENT's id
--     instead of creating a child. Giving children their own subject
--     vocabulary sidesteps that entirely and is semantically honest: a
--     child's subject IS the parent work package. Source navigation is
--     unaffected because source_type_code / source_record_id are
--     inherited from the parent (BRD §15).
--
--  b) task_type_code = 'Custom' for every child. A child is a
--     distributed activity, not a second instance of the parent's
--     governed type. This also keeps children clear of the
--     Implementation two-gate closure rule in sp_task_close, which
--     applies to the accountable parent, not to each sub-activity.
--     The read layer (195) filters children out of the tab counts so
--     the Custom tab still means "custom top-level tasks".
--
-- Inheritance is total: priority, standard SLA, approved extension and
-- effective due date all come from the parent and are read-only on the
-- child. Only owner, title, description and an optional operational
-- target date are the child's own.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_child_create
    @parent_task_id          BIGINT,
    @subject_title           NVARCHAR(250),
    @subject_description     NVARCHAR(MAX) = NULL,
    @assigned_to_employee_id BIGINT        = NULL,
    @is_mandatory            BIT           = 1,
    @child_target_date       DATETIME2     = NULL,
    @actor_employee_id       BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N'system',
    @child_task_id           BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @parent_task_id IS NULL
        THROW 55670, 'sp_task_child_create: parent_task_id is required.', 1;
    IF @subject_title IS NULL OR LEN(LTRIM(RTRIM(@subject_title))) = 0
        THROW 55671, 'sp_task_child_create: subject_title is required.', 1;

    DECLARE @organization_id   BIGINT,
            @grandparent       BIGINT,
            @closed_at         DATETIME2,
            @priority          NVARCHAR(30),
            @standard_days     INT,
            @standard_due      DATETIME2,
            @extended_due      DATETIME2,
            @effective_due     DATETIME2,
            @sla_source        NVARCHAR(30),
            @sla_master_id     BIGINT,
            @sla_master_name   NVARCHAR(200),
            @source_type       NVARCHAR(40),
            @source_record_id  BIGINT,
            @source_reference  NVARCHAR(200),
            @linked_release_id BIGINT,
            @linked_control_id BIGINT,
            @linked_practice_id BIGINT,
            @linked_instance_id BIGINT,
            @parent_owner      BIGINT;

    SELECT @organization_id    = t.organization_id,
           @grandparent        = t.parent_task_id,
           @closed_at          = t.closed_at,
           @priority           = t.priority,
           @standard_days      = t.standard_sla_days,
           @standard_due       = t.standard_due_at,
           @extended_due       = t.approved_extended_due_at,
           @effective_due      = t.sla_due_at,
           @sla_source         = t.sla_source_code,
           @sla_master_id      = t.sla_master_id,
           @sla_master_name    = t.sla_master_name,
           @source_type        = t.source_type_code,
           @source_record_id   = t.source_record_id,
           @source_reference   = t.source_reference,
           @linked_release_id  = t.linked_release_id,
           @linked_control_id  = t.linked_control_id,
           @linked_practice_id = t.linked_practice_id,
           @linked_instance_id = t.linked_instance_id,
           @parent_owner       = t.assigned_to_employee_id
      FROM grac_practice.practice_task t
     WHERE t.task_id = @parent_task_id;

    IF @organization_id IS NULL
        THROW 55672, 'sp_task_child_create: parent task not found.', 1;
    IF @closed_at IS NOT NULL
        THROW 55673, 'sp_task_child_create: cannot add a child to a completed task.', 1;

    -- Single level only — see the header note on why the BRD's governance
    -- model has exactly one accountable parent.
    IF @grandparent IS NOT NULL
        THROW 55674, 'sp_task_child_create: child tasks cannot themselves have children. Add the activity to the parent task instead.', 1;

    -- BRD §11: child target dates "cannot exceed the parent's approved
    -- due date". Clamp rather than reject — the operator's intent is
    -- clear and rejecting on a date detail is needless friction.
    IF @child_target_date IS NOT NULL AND @effective_due IS NOT NULL
       AND @child_target_date > @effective_due
        SET @child_target_date = @effective_due;

    -- Owner: explicit, else resolved from the ownership ladder, else the
    -- parent owner (a child always has someone accountable).
    DECLARE @owner_id BIGINT = @assigned_to_employee_id,
            @owner_source NVARCHAR(40) = CASE WHEN @assigned_to_employee_id IS NOT NULL THEN N'EXPLICIT_SOURCE' END;

    IF @owner_id IS NULL
    BEGIN
        DECLARE @resolved TABLE (
            OwnerEmployeeId BIGINT, OwnerEmployeeName NVARCHAR(200),
            OwnerSourceCode NVARCHAR(40), OwnerSourceName NVARCHAR(120));

        INSERT @resolved
        EXEC grac_practice.sp_task_owner_resolve
             @organization_id    = @organization_id,
             @source_type_code   = @source_type,
             @source_record_id   = @source_record_id,
             @linked_practice_id = @linked_practice_id,
             @linked_control_id  = @linked_control_id,
             @linked_instance_id = @linked_instance_id;

        SELECT TOP 1 @owner_id = OwnerEmployeeId, @owner_source = OwnerSourceCode FROM @resolved;

        IF @owner_id IS NULL
        BEGIN
            SET @owner_id     = @parent_owner;
            SET @owner_source = N'EXPLICIT_SOURCE';   -- inherited from the parent
        END
    END

    BEGIN TRAN;

    -- Create through sp_task_open so the state machine, transition log
    -- and audit trace behave exactly as they do for any other task.
    EXEC grac_practice.sp_task_open
         @organization_id         = @organization_id,
         @task_type_code          = N'Custom',
         @subject_entity_type     = N'TaskChild',
         @subject_entity_id       = @parent_task_id,
         @subject_title           = @subject_title,
         @subject_description     = @subject_description,
         @linked_release_id       = @linked_release_id,
         @linked_control_id       = @linked_control_id,
         @linked_practice_id      = @linked_practice_id,
         @linked_instance_id      = @linked_instance_id,
         @priority                = @priority,
         @origin_code             = N'GRAC',
         @assigned_to_employee_id = @owner_id,
         @actor_employee_id       = @actor_employee_id,
         @target_date             = @effective_due,
         @task_id                 = @child_task_id OUTPUT;

    IF @child_task_id IS NULL
        THROW 55675, 'sp_task_child_create: child task creation failed.', 1;

    -- Stamp the inheritance. Everything here is read-only on the child;
    -- sp_task_priority_change and sp_task_sla_extension_request_create
    -- both refuse to run against a task with parent_task_id set.
    UPDATE grac_practice.practice_task
       SET parent_task_id           = @parent_task_id,
           is_mandatory_child       = ISNULL(@is_mandatory, 1),
           child_target_date        = @child_target_date,
           priority                 = @priority,
           standard_sla_days        = @standard_days,
           standard_due_at          = @standard_due,
           approved_extended_due_at = @extended_due,
           sla_due_at               = @effective_due,
           sla_source_code          = @sla_source,
           sla_master_id            = @sla_master_id,
           sla_master_name          = @sla_master_name,
           source_type_code         = @source_type,
           source_record_id         = @source_record_id,
           source_reference         = @source_reference,
           owner_source_code        = @owner_source,
           updated_by               = @caller_display_name,
           updated_dt               = SYSUTCDATETIME()
     WHERE task_id = @child_task_id;

    EXEC grac_practice.sp_task_activity_add
         @task_id             = @parent_task_id,
         @activity_type_code  = N'ChildAdded',
         @remark              = @subject_title,
         @to_value            = @subject_title,
         @actor_employee_id   = @actor_employee_id,
         @caller_display_name = @caller_display_name;

    COMMIT;

    SELECT @child_task_id      AS ChildTaskId,
           @parent_task_id     AS ParentTaskId,
           @priority           AS Priority,
           @effective_due      AS InheritedDueAt,
           @child_target_date  AS ChildTargetDate,
           ISNULL(@is_mandatory, 1) AS IsMandatoryChild;
END;
GO

-- =====================================================================
-- 4. sp_task_completion_eligibility  (BRD §12)
--
-- Read-only. Answers the single question the detail page and
-- sp_task_complete both need: may this task be completed right now?
--
-- "When all mandatory child tasks are completed, the parent becomes
--  'Eligible for Completion'. The parent owner confirms completion of
--  the overall objective. If the task has no children, the normal
--  completion action applies."
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_completion_eligibility
    @task_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @task_id IS NULL
        THROW 55680, 'sp_task_completion_eligibility: task_id is required.', 1;

    DECLARE @closed_at DATETIME2, @exists BIT = 0;
    SELECT @closed_at = closed_at, @exists = 1
      FROM grac_practice.practice_task WHERE task_id = @task_id;

    IF @exists = 0
        THROW 55681, 'sp_task_completion_eligibility: task not found.', 1;

    DECLARE @child_total     INT = 0,
            @mand_total      INT = 0,
            @mand_completed  INT = 0;

    SELECT @child_total    = COUNT(*),
           @mand_total     = SUM(CASE WHEN ISNULL(c.is_mandatory_child, 1) = 1 THEN 1 ELSE 0 END),
           @mand_completed = SUM(CASE WHEN ISNULL(c.is_mandatory_child, 1) = 1
                                       AND c.closed_at IS NOT NULL THEN 1 ELSE 0 END)
      FROM grac_practice.practice_task c
     WHERE c.parent_task_id = @task_id;

    SET @mand_total     = ISNULL(@mand_total, 0);
    SET @mand_completed = ISNULL(@mand_completed, 0);

    DECLARE @eligible BIT, @reason NVARCHAR(300);

    IF @closed_at IS NOT NULL
    BEGIN
        SET @eligible = 0;
        SET @reason   = N'Task is already completed.';
    END
    ELSE IF @mand_total > @mand_completed
    BEGIN
        SET @eligible = 0;
        SET @reason   = CONCAT(N'Waiting on ', @mand_total - @mand_completed,
                               N' of ', @mand_total, N' mandatory child task(s).');
    END
    ELSE
    BEGIN
        SET @eligible = 1;
        SET @reason   = CASE WHEN @child_total = 0
                             THEN N'No child tasks — ready to complete.'
                             ELSE N'All mandatory child tasks are complete — ready for owner confirmation.'
                        END;
    END

    SELECT @task_id        AS TaskId,
           @eligible       AS IsEligible,
           @reason         AS Reason,
           @child_total    AS ChildCount,
           @mand_total     AS MandatoryChildCount,
           @mand_completed AS MandatoryChildCompletedCount,
           @mand_total - @mand_completed AS MandatoryChildOpenCount;
END;
GO

-- =====================================================================
-- 5. sp_task_complete  (BRD §10, §12, §14)
--
-- The BRD-facing completion action. Layers governance ON TOP of the
-- existing sp_task_close rather than replacing it, so:
--   * the Implementation two-gate closure rule (§12.2.3 / 037) still
--     applies untouched;
--   * the state machine still refuses illegal transitions (53520 ->
--     HTTP 409, unchanged);
--   * closed_at, the transition log and practice_audit_trace all keep
--     their existing semantics.
--
-- What this proc adds:
--   * mandatory-child gate — "Completion of a Child Task does not
--     complete the Parent Task" (§11);
--   * completed_by / completed_dt attribution;
--   * a ChildCompleted note on the parent, plus a
--     ParentEligibleForCompletion note the moment the last mandatory
--     child lands, so the parent owner knows to confirm (§12).
--
-- NOT YET IMPLEMENTED — Phase 2 (BRD §14 upstream synchronisation):
--   writing "Task Action Completed" back onto the originating Gap /
--   Exception / Risk / Assurance record. The BRD is explicit that this
--   must NOT auto-close the source, so it is a separate, per-source
--   write that lands with the candidate integrations. Until then the
--   source relationship is fully navigable in both directions (195) but
--   the source's own status is unchanged by task completion, which is
--   the safe half of §14.
-- =====================================================================
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

    -- A separate @found flag rather than inferring existence from the
    -- other locals: subject_title is NOT NULL in the schema today, but
    -- relying on that to detect "row missing" would silently break if it
    -- ever became nullable.
    IF @found = 0
        THROW 55691, 'sp_task_complete: task not found.', 1;

    IF @closed_at IS NOT NULL
        THROW 55692, 'sp_task_complete: the task is already completed.', 1;

    -- ---- Mandatory-child gate (BRD §12) -----------------------------
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

    -- Delegates to the existing closure proc — two-gate rule and state
    -- machine legality are enforced there and will THROW through us.
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

    -- ---- Roll the news up to the parent (BRD §12) --------------------
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

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '194 procedures present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_task_sla_extension_request_create','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_sla_extension_approve','P')         IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_child_create','P')                  IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_completion_eligibility','P')        IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_complete','P')                      IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '194 Task Centre v2 parent/child + extension procedures installed. Next: 195_task_centre_v2_read.sql';
GO

SET NOEXEC OFF;
GO
