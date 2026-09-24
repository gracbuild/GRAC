-- =====================================================================
-- 257 Exception Centre: an Analysis stage before approval
--
-- Sir's specification:
--
--   * A Pending request offers ANALYSIS on the 3-dot menu. Approve and
--     Reject are NOT offered at Pending -- nothing should be decided
--     before it has been analysed.
--   * Analysis happens on its own page. The request-level detail that
--     used to be captured inside the Approve modal moves there.
--   * The analysis can attach remediation work: raise a NEW task, or map
--     an EXISTING one. "Existing" means the tasks recorded under this
--     exception's linked practice.
--   * Finishing analysis presses SUBMIT FOR APPROVAL.
--   * The approver may change the effective dates, then Approve or
--     Reject.
--   * Linked practice is DISPLAYED on the analysis page, not selected --
--     it comes from the request. Linked requirement ref, approval note
--     and compensating control leave the analysis form. (The approval
--     note stays, on the approver's form, where it belongs.)
--
-- WHAT THIS MIGRATION DOES
--
--   1. status_code gains 'SubmittedForApproval'
--   2. exception_request_task -- the many-to-many remediation link
--   3. sp_exception_request_analysis_save
--   4. sp_exception_request_submit_for_approval
--   5. sp_exception_request_task_link / _unlink / _list
--   6. sp_exception_practice_task_candidates
--   7. approve + reject re-gated onto the new status
--
-- WHY task_id WAS NOT REUSED. exception_request.task_id already exists
-- (192) and already means something else: the task whose SLA extension
-- or priority reduction is being requested. It carries a filtered unique
-- index (ux_pm_exception_request_task_sla_pending) enforcing one open
-- request per task. Hanging remediation tasks off the same column would
-- collide with that rule and with its meaning. Hence a link table.
--
-- WHY THE RE-GATE IS CONDITIONAL. Approve and Reject are moved onto
-- 'SubmittedForApproval' for GAP_CANDIDATE requests only. The task-side
-- request types -- TASK_SLA_EXTENSION and TASK_PRIORITY_REDUCTION, raised
-- from Task Centre (192/193) -- have no analysis stage and are decided
-- straight from Pending. Gating them the same way would strand every SLA
-- extension approval in the product.
--
-- BODIES RE-EMITTED FROM THEIR LIVE ANCESTORS, deliberately:
--     approve -> 166   (request-level fields, evidence, history)
--     reject  -> 193   (176's risk auto-create AND 192/193's task-side
--                       release; 193 is a strict superset of both)
-- Nothing else in either body changes.
--
-- SAFE TO RE-RUN. Requires 161, 166, 192, 193.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (257): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.exception_request','U') IS NULL
BEGIN PRINT 'ABORT (257): exception_request missing (run 161 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_task','U') IS NULL
BEGIN PRINT 'ABORT (257): practice_task missing (run 037 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.exception_request','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.exception_request','request_type_code') IS NULL
BEGIN PRINT 'ABORT (257): exception_request.request_type_code missing (run 184 first).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('257_exception_analysis_stage: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Status vocabulary
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'ck_pm_exception_request_status')
    ALTER TABLE grac_practice.exception_request DROP CONSTRAINT ck_pm_exception_request_status;
GO

ALTER TABLE grac_practice.exception_request
    ADD CONSTRAINT ck_pm_exception_request_status
        CHECK (status_code IN (N'Pending', N'SubmittedForApproval',
                               N'Approved', N'Rejected', N'Withdrawn', N'Expired'));
GO
PRINT '257: status_code now allows SubmittedForApproval.';
GO

-- =====================================================================
-- 2. exception_request_task -- remediation work attached to an exception
--
-- Many tasks per exception, and the same task may legitimately serve two
-- exceptions, so the uniqueness is on the PAIR. link_source_code records
-- whether the task was raised from the analysis page or mapped to it,
-- because "we created this to fix it" and "this already existed and also
-- covers it" are different claims.
-- =====================================================================
IF OBJECT_ID('grac_practice.exception_request_task','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.exception_request_task (
        exception_request_task_id BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_exception_request_task PRIMARY KEY,
        exception_request_id      BIGINT NOT NULL
            CONSTRAINT fk_pm_exception_request_task_request
                REFERENCES grac_practice.exception_request(exception_request_id),
        task_id                   BIGINT NOT NULL
            CONSTRAINT fk_pm_exception_request_task_task
                REFERENCES grac_practice.practice_task(task_id),
        link_source_code          NVARCHAR(20) NOT NULL
            CONSTRAINT df_pm_exception_request_task_source DEFAULT N'Mapped'
            CONSTRAINT ck_pm_exception_request_task_source
                CHECK (link_source_code IN (N'Created', N'Mapped')),
        -- Soft-unlink: the row stays so history shows the task WAS once
        -- attached, which an audit of "what did you do about it" needs.
        status                    NVARCHAR(20) NOT NULL
            CONSTRAINT df_pm_exception_request_task_status DEFAULT N'Active',
        linked_by                 NVARCHAR(100) NULL,
        linked_dt                 DATETIME2(3) NOT NULL
            CONSTRAINT df_pm_exception_request_task_dt DEFAULT SYSUTCDATETIME(),
        unlinked_by               NVARCHAR(100) NULL,
        unlinked_dt               DATETIME2(3) NULL
    );
    PRINT '257: exception_request_task created.';
END
GO

-- One ACTIVE link per (request, task). A re-link after an unlink is
-- allowed, which a plain unique constraint would refuse.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_exception_request_task_active'
                  AND object_id = OBJECT_ID('grac_practice.exception_request_task'))
    CREATE UNIQUE INDEX ux_pm_exception_request_task_active
        ON grac_practice.exception_request_task(exception_request_id, task_id)
        WHERE status = N'Active';
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_exception_request_task_request'
                  AND object_id = OBJECT_ID('grac_practice.exception_request_task'))
    CREATE INDEX ix_pm_exception_request_task_request
        ON grac_practice.exception_request_task(exception_request_id, status)
        INCLUDE (task_id, link_source_code);
GO

-- =====================================================================
-- 3. sp_exception_request_analysis_save
--
-- The request-level fields, saved from the analysis page. Every one is
-- COALESCE-preserved: the page can save a partial analysis without
-- blanking what is already recorded.
--
-- Deliberately NOT here: linked_practice_id (displayed, not chosen --
-- it comes from the request), linked_requirement_ref, approval_note and
-- compensating_control. The columns are untouched; this procedure simply
-- does not write them.
--
-- Status is NOT changed. Saving analysis leaves the request Pending;
-- only sp_exception_request_submit_for_approval moves it.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_analysis_save
    @exception_request_id BIGINT,
    @exception_type_code  NVARCHAR(60)  = NULL,
    @justification        NVARCHAR(MAX) = NULL,
    @risk_impact          NVARCHAR(MAX) = NULL,
    @owner_employee_id    BIGINT        = NULL,
    @caller_display_name  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @exception_request_id IS NULL
        THROW 55260, 'sp_exception_request_analysis_save: exception_request_id is required.', 1;

    DECLARE @current NVARCHAR(30);
    SELECT @current = status_code
      FROM grac_practice.exception_request
     WHERE exception_request_id = @exception_request_id;

    IF @current IS NULL
        THROW 55261, 'sp_exception_request_analysis_save: request not found.', 1;
    IF @current NOT IN (N'Pending', N'SubmittedForApproval')
        THROW 55262, 'sp_exception_request_analysis_save: analysis applies to a Pending or SubmittedForApproval request only.', 1;

    DECLARE @type_id INT = NULL;
    IF @exception_type_code IS NOT NULL AND LEN(LTRIM(RTRIM(@exception_type_code))) > 0
    BEGIN
        SELECT @type_id = exception_type_id
          FROM grac_practice.exception_type_master
         WHERE exception_type_code = @exception_type_code;
        IF @type_id IS NULL
            THROW 55263, 'sp_exception_request_analysis_save: unknown exception_type_code.', 1;
    END

    UPDATE grac_practice.exception_request
       SET exception_type_id = COALESCE(@type_id,            exception_type_id),
           justification     = COALESCE(@justification,      justification),
           risk_impact       = COALESCE(@risk_impact,        risk_impact),
           owner_employee_id = COALESCE(@owner_employee_id,  owner_employee_id),
           updated_by        = @caller_display_name,
           updated_dt        = SYSUTCDATETIME()
     WHERE exception_request_id = @exception_request_id;

    SELECT @exception_request_id AS ExceptionRequestId,
           CAST(1 AS BIT)        AS Success,
           N'Analysis saved.'    AS Message;
END
GO
PRINT '257: sp_exception_request_analysis_save created.';
GO

-- =====================================================================
-- 4. sp_exception_request_submit_for_approval
--
-- The gate between analysis and decision. Refuses an analysis that has
-- not answered the two questions an approver cannot answer for himself:
-- WHY the exception is wanted, and WHAT it exposes. Anything softer and
-- "Submit" becomes a button that forwards blank forms.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_submit_for_approval
    @exception_request_id BIGINT,
    @actor_employee_id    BIGINT        = NULL,
    @caller_display_name  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @exception_request_id IS NULL
        THROW 55265, 'sp_exception_request_submit_for_approval: exception_request_id is required.', 1;

    DECLARE @current NVARCHAR(30), @just NVARCHAR(MAX), @risk NVARCHAR(MAX);
    SELECT @current = status_code,
           @just    = justification,
           @risk    = risk_impact
      FROM grac_practice.exception_request
     WHERE exception_request_id = @exception_request_id;

    IF @current IS NULL
        THROW 55266, 'sp_exception_request_submit_for_approval: request not found.', 1;
    IF @current <> N'Pending'
        THROW 55267, 'sp_exception_request_submit_for_approval: only a Pending request can be submitted for approval.', 1;
    IF @just IS NULL OR LEN(LTRIM(RTRIM(@just))) = 0
        THROW 55268, 'sp_exception_request_submit_for_approval: justification is required before submitting for approval.', 1;
    IF @risk IS NULL OR LEN(LTRIM(RTRIM(@risk))) = 0
        THROW 55269, 'sp_exception_request_submit_for_approval: risk / impact is required before submitting for approval.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.exception_request
           SET status_code = N'SubmittedForApproval',
               updated_by  = @caller_display_name,
               updated_dt  = SYSUTCDATETIME()
         WHERE exception_request_id = @exception_request_id;

        INSERT INTO grac_practice.exception_request_history
            (exception_request_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@exception_request_id, N'SubmitForApproval', N'Pending', N'SubmittedForApproval',
             N'Analysis completed and submitted for approval.',
             @actor_employee_id, @caller_display_name, @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @exception_request_id AS ExceptionRequestId,
           CAST(1 AS BIT)        AS Success,
           N'Submitted for approval.' AS Message;
END
GO
PRINT '257: sp_exception_request_submit_for_approval created.';
GO

-- =====================================================================
-- 5. Task links
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_task_link
    @exception_request_id BIGINT,
    @task_id              BIGINT,
    @link_source_code     NVARCHAR(20)  = N'Mapped',
    @caller_display_name  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @exception_request_id IS NULL OR @task_id IS NULL
        THROW 55270, 'sp_exception_request_task_link: exception_request_id and task_id are both required.', 1;
    IF @link_source_code NOT IN (N'Created', N'Mapped')
        SET @link_source_code = N'Mapped';

    DECLARE @org_request BIGINT, @org_task BIGINT;
    SELECT @org_request = organization_id FROM grac_practice.exception_request
     WHERE exception_request_id = @exception_request_id;
    IF @org_request IS NULL
        THROW 55271, 'sp_exception_request_task_link: request not found.', 1;

    SELECT @org_task = organization_id FROM grac_practice.practice_task WHERE task_id = @task_id;
    IF @org_task IS NULL
        THROW 55272, 'sp_exception_request_task_link: task not found.', 1;

    -- Same rule the rest of the module applies: nothing links across
    -- tenants, whatever ids a caller hands in.
    IF @org_task <> @org_request
        THROW 55273, 'sp_exception_request_task_link: the task belongs to a different organization.', 1;

    -- Idempotent: re-linking an already-active pair is a no-op, and
    -- re-linking a previously unlinked pair revives that row rather than
    -- accumulating duplicates.
    IF EXISTS (SELECT 1 FROM grac_practice.exception_request_task
                WHERE exception_request_id = @exception_request_id
                  AND task_id = @task_id AND status = N'Active')
    BEGIN
        SELECT @exception_request_id AS ExceptionRequestId, @task_id AS TaskId,
               CAST(0 AS BIT) AS Created, N'Task is already linked.' AS Message;
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM grac_practice.exception_request_task
                WHERE exception_request_id = @exception_request_id
                  AND task_id = @task_id)
    BEGIN
        UPDATE grac_practice.exception_request_task
           SET status           = N'Active',
               link_source_code = @link_source_code,
               linked_by        = @caller_display_name,
               linked_dt        = SYSUTCDATETIME(),
               unlinked_by      = NULL,
               unlinked_dt      = NULL
         WHERE exception_request_id = @exception_request_id
           AND task_id = @task_id;
    END
    ELSE
    BEGIN
        INSERT INTO grac_practice.exception_request_task
            (exception_request_id, task_id, link_source_code, status, linked_by, linked_dt)
        VALUES
            (@exception_request_id, @task_id, @link_source_code, N'Active',
             @caller_display_name, SYSUTCDATETIME());
    END

    SELECT @exception_request_id AS ExceptionRequestId, @task_id AS TaskId,
           CAST(1 AS BIT) AS Created, N'Task linked.' AS Message;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_task_unlink
    @exception_request_id BIGINT,
    @task_id              BIGINT,
    @caller_display_name  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @exception_request_id IS NULL OR @task_id IS NULL
        THROW 55275, 'sp_exception_request_task_unlink: exception_request_id and task_id are both required.', 1;

    -- Soft unlink. The row survives so an audit can still see the task
    -- was once put forward as the answer to this exception.
    UPDATE grac_practice.exception_request_task
       SET status      = N'Removed',
           unlinked_by = @caller_display_name,
           unlinked_dt = SYSUTCDATETIME()
     WHERE exception_request_id = @exception_request_id
       AND task_id = @task_id
       AND status = N'Active';

    SELECT @exception_request_id AS ExceptionRequestId, @task_id AS TaskId,
           CAST(1 AS BIT) AS Success, N'Task unlinked.' AS Message;
END
GO

-- The tasks currently attached to one exception.
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_task_list
    @exception_request_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @exception_request_id IS NULL
        THROW 55277, 'sp_exception_request_task_list: exception_request_id is required.', 1;

    SELECT l.exception_request_task_id AS ExceptionRequestTaskId,
           l.task_id                   AS TaskId,
           t.task_number               AS TaskNumber,
           t.subject_title             AS TaskTitle,
           tt.type_code                AS TaskTypeCode,
           tt.type_name                AS TaskTypeName,
           s.status_code               AS TaskStatusCode,
           s.status_name               AS TaskStatusName,
           t.priority                  AS Priority,
           t.sla_due_at                AS DueAt,
           t.assigned_to_employee_id   AS AssignedToEmployeeId,
           e.employee_name             AS AssignedToName,
           l.link_source_code          AS LinkSourceCode,
           l.linked_by                 AS LinkedBy,
           l.linked_dt                 AS LinkedOn
      FROM grac_practice.exception_request_task l
      JOIN grac_practice.practice_task t ON t.task_id = l.task_id
      LEFT JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = t.assigned_to_employee_id
     WHERE l.exception_request_id = @exception_request_id
       AND l.status = N'Active'
     ORDER BY l.linked_dt DESC, l.exception_request_task_id DESC;
END
GO

-- =====================================================================
-- 6. sp_exception_practice_task_candidates
--
-- What the "map an existing task" picker offers: every task recorded
-- under THIS exception's linked practice, as sir specified. Tasks already
-- linked to this exception are returned with IsLinked = 1 rather than
-- filtered out, so the picker can show them ticked instead of silently
-- lacking them.
--
-- When the request has no linked_practice_id there is no practice to
-- scope by; the procedure returns an empty set rather than falling back
-- to every task in the organization, which would be a different question
-- than the one asked.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_practice_task_candidates
    @exception_request_id BIGINT,
    @search               NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @exception_request_id IS NULL
        THROW 55280, 'sp_exception_practice_task_candidates: exception_request_id is required.', 1;
    IF @search = N'' SET @search = NULL;

    DECLARE @org_id BIGINT, @practice_id BIGINT;
    SELECT @org_id      = organization_id,
           @practice_id = linked_practice_id
      FROM grac_practice.exception_request
     WHERE exception_request_id = @exception_request_id;

    IF @org_id IS NULL
        THROW 55281, 'sp_exception_practice_task_candidates: request not found.', 1;

    SELECT t.task_id              AS TaskId,
           t.task_number          AS TaskNumber,
           t.subject_title        AS TaskTitle,
           tt.type_code           AS TaskTypeCode,
           tt.type_name           AS TaskTypeName,
           s.status_code          AS TaskStatusCode,
           s.status_name          AS TaskStatusName,
           t.priority             AS Priority,
           t.sla_due_at           AS DueAt,
           e.employee_name        AS AssignedToName,
           CAST(CASE WHEN EXISTS (
                    SELECT 1 FROM grac_practice.exception_request_task l
                     WHERE l.exception_request_id = @exception_request_id
                       AND l.task_id = t.task_id
                       AND l.status = N'Active')
                THEN 1 ELSE 0 END AS BIT) AS IsLinked
      FROM grac_practice.practice_task t
      LEFT JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = t.assigned_to_employee_id
     WHERE t.organization_id = @org_id
       AND @practice_id IS NOT NULL
       AND t.linked_practice_id = @practice_id
       AND t.parent_task_id IS NULL
       AND (@search IS NULL
            OR t.subject_title LIKE N'%' + @search + N'%'
            OR t.task_number   LIKE N'%' + @search + N'%')
     ORDER BY CASE WHEN s.status_code IN (N'Closed', N'Cancelled') THEN 1 ELSE 0 END,
              t.task_id DESC;
END
GO
PRINT '257: task link procedures created.';
GO

-- =====================================================================
-- 7. Approve / Reject re-gated onto SubmittedForApproval
--
-- GAP_CANDIDATE requests must have been analysed and submitted.
-- TASK_SLA_EXTENSION and TASK_PRIORITY_REDUCTION keep decidng from
-- Pending -- they are raised by Task Centre, have no analysis stage, and
-- gating them here would strand every SLA extension in the product.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_approve
    @exception_request_id    BIGINT,
    @effective_until         DATE,
    @approval_note           NVARCHAR(MAX),
    @approved_by_employee_id BIGINT,
    @effective_from          DATE           = NULL,
    @compensating_control    NVARCHAR(MAX)  = NULL,
    @review_frequency_id     INT            = NULL,
    -- Request-level fields. The analysis page owns these now; the
    -- parameters stay so an older caller still binds, and every one is
    -- COALESCE-preserved as before.
    @exception_type_code     NVARCHAR(60)   = NULL,
    @justification           NVARCHAR(MAX)  = NULL,
    @risk_impact             NVARCHAR(MAX)  = NULL,
    @owner_employee_id       BIGINT         = NULL,
    @linked_practice_id      BIGINT         = NULL,
    @linked_requirement_ref  NVARCHAR(200)  = NULL,
    @caller_display_name     NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @exception_request_id IS NULL
        THROW 55230, 'sp_exception_request_approve: exception_request_id is required.', 1;
    IF @effective_until IS NULL
        THROW 55231, 'sp_exception_request_approve: effective_until date is required.', 1;
    IF @approval_note IS NULL OR LEN(LTRIM(RTRIM(@approval_note))) = 0
        THROW 55232, 'sp_exception_request_approve: approval_note is required.', 1;
    IF @approved_by_employee_id IS NULL
        THROW 55233, 'sp_exception_request_approve: approved_by_employee_id is required.', 1;
    IF @effective_from IS NOT NULL AND @effective_from > @effective_until
        THROW 55236, 'sp_exception_request_approve: effective_from must be on or before effective_until.', 1;

    DECLARE @current NVARCHAR(30), @req_type NVARCHAR(30);
    SELECT @current  = status_code,
           @req_type = request_type_code
      FROM grac_practice.exception_request WHERE exception_request_id = @exception_request_id;
    IF @current IS NULL
        THROW 55234, 'sp_exception_request_approve: request not found.', 1;

    -- 257: the gate depends on the request type.
    DECLARE @required_status NVARCHAR(30) =
        CASE WHEN @req_type IN (N'TASK_SLA_EXTENSION', N'TASK_PRIORITY_REDUCTION')
             THEN N'Pending' ELSE N'SubmittedForApproval' END;

    IF @current <> @required_status
    BEGIN
        DECLARE @msg NVARCHAR(400) =
            CONCAT(N'sp_exception_request_approve: this request must be ', @required_status,
                   N' to be approved (current: ', @current,
                   N'). Complete the analysis and submit it for approval first.');
        THROW 55235, @msg, 1;
    END

    DECLARE @type_id INT = NULL;
    IF @exception_type_code IS NOT NULL AND LEN(LTRIM(RTRIM(@exception_type_code))) > 0
    BEGIN
        SELECT @type_id = exception_type_id FROM grac_practice.exception_type_master
         WHERE exception_type_code = @exception_type_code;
        IF @type_id IS NULL
            THROW 55237, 'sp_exception_request_approve: unknown exception_type_code.', 1;
    END

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.exception_request
           SET status_code             = N'Approved',
               approved_by_employee_id = @approved_by_employee_id,
               approved_dt             = SYSUTCDATETIME(),
               effective_from          = COALESCE(@effective_from, SYSUTCDATETIME()),
               effective_until         = @effective_until,
               approval_note           = @approval_note,
               compensating_control    = COALESCE(@compensating_control, compensating_control),
               review_frequency_id     = COALESCE(@review_frequency_id, review_frequency_id),
               exception_type_id       = COALESCE(@type_id,               exception_type_id),
               justification           = COALESCE(@justification,         justification),
               risk_impact             = COALESCE(@risk_impact,           risk_impact),
               owner_employee_id       = COALESCE(@owner_employee_id,     owner_employee_id),
               linked_practice_id      = COALESCE(@linked_practice_id,    linked_practice_id),
               linked_requirement_ref  = COALESCE(@linked_requirement_ref,linked_requirement_ref),
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE exception_request_id = @exception_request_id;

        INSERT INTO grac_practice.exception_request_history
            (exception_request_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@exception_request_id, N'Approve', @current, N'Approved',
             CONCAT(
                 N'Valid ',
                 CONVERT(NVARCHAR(10), COALESCE(@effective_from, CAST(SYSUTCDATETIME() AS DATE)), 23),
                 N' -> ',
                 CONVERT(NVARCHAR(10), @effective_until, 23),
                 N'. Note: ', @approval_note),
             @approved_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK; THROW; END CATCH

    -- 166's result-set shape, unchanged -- the service binds these names.
    SELECT @exception_request_id AS ExceptionRequestId, N'Approved' AS StatusCode;
END
GO
PRINT '257: sp_exception_request_approve re-gated onto SubmittedForApproval (GAP_CANDIDATE only).';
GO

-- 193's body, with the same conditional gate. Everything else --- 176's
-- risk auto-create and 192/193's task-side release --- is preserved
-- verbatim.
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_reject
    @exception_request_id    BIGINT,
    @rejection_reason        NVARCHAR(MAX),
    @rejected_by_employee_id BIGINT,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @exception_request_id IS NULL
        THROW 55240, 'sp_exception_request_reject: exception_request_id is required.', 1;
    IF @rejection_reason IS NULL OR LEN(LTRIM(RTRIM(@rejection_reason))) = 0
        THROW 55241, 'sp_exception_request_reject: rejection_reason is required.', 1;
    IF @rejected_by_employee_id IS NULL
        THROW 55242, 'sp_exception_request_reject: rejected_by_employee_id is required.', 1;

    DECLARE @current NVARCHAR(30), @type NVARCHAR(30), @task_id BIGINT;
    SELECT @current = status_code,
           @type    = request_type_code,
           @task_id = task_id
      FROM grac_practice.exception_request WHERE exception_request_id = @exception_request_id;
    IF @current IS NULL
        THROW 55243, 'sp_exception_request_reject: request not found.', 1;

    DECLARE @required_status NVARCHAR(30) =
        CASE WHEN @type IN (N'TASK_SLA_EXTENSION', N'TASK_PRIORITY_REDUCTION')
             THEN N'Pending' ELSE N'SubmittedForApproval' END;

    IF @current <> @required_status
    BEGIN
        DECLARE @rmsg NVARCHAR(400) =
            CONCAT(N'sp_exception_request_reject: this request must be ', @required_status,
                   N' to be rejected (current: ', @current, N').');
        THROW 55244, @rmsg, 1;
    END

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.exception_request
           SET status_code             = N'Rejected',
               rejected_by_employee_id = @rejected_by_employee_id,
               rejected_dt             = SYSUTCDATETIME(),
               rejection_reason        = @rejection_reason,
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE exception_request_id = @exception_request_id;

        INSERT INTO grac_practice.exception_request_history
            (exception_request_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@exception_request_id, N'Reject', @current, N'Rejected',
             @rejection_reason, @rejected_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        IF @type = N'TASK_PRIORITY_REDUCTION' AND @task_id IS NOT NULL
        BEGIN
            UPDATE grac_practice.practice_task
               SET priority_change_status_code = N'Rejected',
                   updated_by                  = @caller_display_name,
                   updated_dt                  = SYSUTCDATETIME()
             WHERE task_id = @task_id;
        END

        IF @type = N'TASK_SLA_EXTENSION' AND @task_id IS NOT NULL
        BEGIN
            UPDATE grac_practice.practice_task
               SET extension_status_code = N'Rejected',
                   updated_by            = @caller_display_name,
                   updated_dt            = SYSUTCDATETIME()
             WHERE task_id = @task_id;
        END

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    IF @type IN (N'TASK_PRIORITY_REDUCTION', N'TASK_SLA_EXTENSION') AND @task_id IS NOT NULL
    BEGIN
        BEGIN TRY
            DECLARE @activity NVARCHAR(40) =
                CASE WHEN @type = N'TASK_SLA_EXTENSION'
                     THEN N'SlaExtensionRejected' ELSE N'PriorityRequestRejected' END;

            EXEC grac_practice.sp_task_activity_add
                 @task_id             = @task_id,
                 @activity_type_code  = @activity,
                 @remark              = @rejection_reason,
                 @actor_employee_id   = @rejected_by_employee_id,
                 @caller_display_name = @caller_display_name;
        END TRY
        BEGIN CATCH
            DECLARE @amsg NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_exception_request_reject: task activity warning: ', @amsg);
        END CATCH
    END

    -- 176: a rejected gap exception means the risk was NOT accepted by
    -- exception, so it becomes a risk candidate. Outside the transaction
    -- for the reason 184 documents: a Risk Centre problem must never roll
    -- back a completed governance decision.
    --
    -- Copied verbatim from 193, summary wording included -- an auto-raised
    -- candidate says why it exists, and paraphrasing it here would have
    -- quietly changed what operators read in Risk Centre.
    IF @type = N'GAP_CANDIDATE'
    BEGIN
        BEGIN TRY
            DECLARE @gap_id BIGINT;
            SELECT @gap_id = custom_gap_id
              FROM grac_practice.exception_request
             WHERE exception_request_id = @exception_request_id;

            DECLARE @risk_summary NVARCHAR(MAX) =
                CONCAT(N'Auto-raised because exception request #',
                       CAST(@exception_request_id AS NVARCHAR(20)),
                       N' was rejected. Rejection reason: ',
                       @rejection_reason);

            EXEC grac_practice.sp_risk_candidate_create
                @custom_gap_id            = @gap_id,
                @candidate_title          = NULL,
                @candidate_summary        = @risk_summary,
                @requested_by_employee_id = @rejected_by_employee_id,
                @caller_display_name      = @caller_display_name;
        END TRY
        BEGIN CATCH
            DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_exception_request_reject: risk auto-create warning: ', @msg);
        END CATCH
    END

    -- 193's result-set shape, unchanged. ExceptionCentreService reads
    -- these column names; inventing a Success/Message shape here would
    -- have broken the caller.
    SELECT @exception_request_id AS ExceptionRequestId,
           N'Rejected' AS StatusCode,
           @type AS RequestTypeCode;
END;
GO
PRINT '257: sp_exception_request_reject re-gated onto SubmittedForApproval (GAP_CANDIDATE only).';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 257 verification ===';

DECLARE @ap NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_exception_request_approve','P'));
DECLARE @rj NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_exception_request_reject','P'));

SELECT '257-a SubmittedForApproval allowed by the CHECK' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.check_constraints
                          WHERE name = N'ck_pm_exception_request_status'
                            AND definition LIKE '%SubmittedForApproval%')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '257-b exception_request_task exists',
       CASE WHEN OBJECT_ID('grac_practice.exception_request_task','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '257-c one ACTIVE link per (request, task)',
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                          WHERE name = 'ux_pm_exception_request_task_active')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '257-d analysis + submit procedures exist',
       CASE WHEN OBJECT_ID('grac_practice.sp_exception_request_analysis_save','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_exception_request_submit_for_approval','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '257-e task link procedures exist',
       CASE WHEN OBJECT_ID('grac_practice.sp_exception_request_task_link','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_exception_request_task_unlink','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_exception_request_task_list','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_exception_practice_task_candidates','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '257-f approve gates on the new status',
       CASE WHEN @ap LIKE '%SubmittedForApproval%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '257-g approve still lets task types decide from Pending',
       CASE WHEN @ap LIKE '%TASK_SLA_EXTENSION%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Regression guards: the two behaviours a careless re-emit would drop.
SELECT '257-h reject KEPT 176 risk auto-create',
       CASE WHEN @rj LIKE '%sp_risk_candidate_create%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '257-i reject KEPT 192/193 task-side release',
       CASE WHEN @rj LIKE '%extension_status_code%'
             AND @rj LIKE '%priority_change_status_code%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '257-j approve still requires an approval note',
       CASE WHEN @ap LIKE '%approval_note is required%' THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- Existing Pending GAP_CANDIDATE requests ---';
PRINT 'These now need Analysis + Submit for approval before they can be';
PRINT 'decided. Nothing is migrated automatically: they stay Pending, which';
PRINT 'is the correct starting point for the new flow.';

SELECT COUNT_BIG(*) AS PendingGapCandidates
  FROM grac_practice.exception_request
 WHERE status_code = N'Pending'
   AND request_type_code = N'GAP_CANDIDATE';

PRINT '';
PRINT '257 complete.';
GO

SET NOEXEC OFF;
GO
