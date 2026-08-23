-- =====================================================================
-- 202 Task notification — sweep and read procedures  (BRD §13)
--
-- CONTENTS
--   1. sp_task_notification_enqueue — one recipient, idempotent
--   2. sp_task_notification_sweep   — the timer-driven engine
--   3. sp_task_notification_list    — outbox / per-recipient inbox
--   4. sp_task_notification_mark    — dispatcher feedback
--   5. sp_task_notification_counts  — badges
--
-- WHAT THIS FILE DOES *NOT* TOUCH
-- -------------------------------
-- sp_task_overdue_sweep (037) is left exactly as it is. It transitions a
-- breached task to Escalated; this sweeper decides who should be TOLD.
-- Two jobs, one concern each — and 037's behaviour, which the Gap flow
-- and the existing UAT diagnostics both rely on, is not disturbed.
--
-- The two can run on completely different schedules without interfering:
-- the state transition is guarded by escalated_at IS NULL, and the
-- notification is guarded by the outbox dedupe index.
--
-- THRESHOLD MODEL  (BRD §13 "configurable thresholds, not hard-coded")
-- --------------------------------------------------------------------
-- Elapsed percentage of the SLA window drives everything:
--
--     elapsed_pct = (now - baseline) / (due - baseline) * 100
--
-- taken against the EFFECTIVE due date, so an approved extension moves
-- the whole scale with it (BRD §8).
--
--   WARNING    elapsed_pct >= org_sla_config.warning_pct     (default 75)
--   BREACH     now > due                                     (implicit 100%)
--   ESCALATION elapsed_pct >= org_sla_config.escalation_pct  (default 100)
--
-- Percentages come from the organisation's own tuned config (183) and
-- fall back to the SLA master, then to 75/100. A task with no matched SLA
-- master still gets WARNING and BREACH on the defaults — silence would be
-- the worst possible failure mode for an SLA monitor.
--
-- RECIPIENTS  (BRD §13 "Owner reminders AND configured management
-- escalation")
-- --------------------------------------------------------------------
-- Two independent sources, unioned:
--   * the task owner, always, for every event — reason_code 'OWNER'
--   * every active holder of every role configured in
--     org_sla_config_notify_role for that event — reason_code 'ROLE'
--
-- A role with no active holder still produces ONE row with a NULL
-- recipient. That is deliberate: "we were supposed to escalate to the
-- Compliance Manager and nobody holds that role" is exactly the finding
-- an audit needs to surface, and silently dropping it would hide a
-- governance gap behind a technical one.
--
-- Rollback: database/201_task_notification_outbox_schema_rollback.sql
-- ERROR CODE RANGE: 55900-55999
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.task_notification_outbox','U') IS NULL
BEGIN PRINT 'ABORT (202): task_notification_outbox missing — run 201 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NULL
BEGIN PRINT 'ABORT (202): vw_pm_practice_task missing — run 195 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.org_sla_config','U') IS NULL
BEGIN PRINT 'ABORT (202): org_sla_config missing — run 178 first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('202_task_notification_procs: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_task_notification_enqueue
--
-- Records one obligation. Idempotent by the 201 dedupe index — a repeat
-- for the same (task, event, due date, recipient) is swallowed, so the
-- sweeper can run as often as it likes.
--
-- OUTPUT-only: it is called in a loop from the sweep, which returns its
-- own summary. (Same discipline as sp_task_activity_add in 193.)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_notification_enqueue
    @task_id               BIGINT,
    @notify_event_code     NVARCHAR(30),
    @due_at_key            DATETIME2,
    @recipient_employee_id BIGINT        = NULL,
    @role_id               BIGINT        = NULL,
    @role_name             NVARCHAR(200) = NULL,
    @recipient_reason_code NVARCHAR(30)  = N'ROLE',
    @caller_display_name   NVARCHAR(100) = N'system',
    @task_notification_id  BIGINT        = NULL OUTPUT,
    @enqueued              BIT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @enqueued = 0;
    SET @task_notification_id = NULL;

    IF @task_id IS NULL OR @notify_event_code IS NULL OR @due_at_key IS NULL
        THROW 55900, 'sp_task_notification_enqueue: task_id, notify_event_code and due_at_key are required.', 1;

    -- Already recorded for this exact commitment? Nothing to do.
    SELECT TOP 1 @task_notification_id = task_notification_id
      FROM grac_practice.task_notification_outbox
     WHERE task_id           = @task_id
       AND notify_event_code = @notify_event_code
       AND due_at_key        = @due_at_key
       AND ((recipient_employee_id IS NULL AND @recipient_employee_id IS NULL)
             OR recipient_employee_id = @recipient_employee_id);

    IF @task_notification_id IS NOT NULL RETURN;

    DECLARE @organization_id BIGINT, @task_number NVARCHAR(60), @task_title NVARCHAR(250),
            @priority NVARCHAR(30), @sla_status NVARCHAR(30), @owner_name NVARCHAR(200);

    SELECT @organization_id = v.organization_id,
           @task_number     = v.task_number,
           @task_title      = v.subject_title,
           @priority        = v.priority,
           @sla_status      = v.sla_status_code,
           @owner_name      = v.assigned_to_employee_name
      FROM grac_practice.vw_pm_practice_task v
     WHERE v.task_id = @task_id;

    IF @organization_id IS NULL
        THROW 55901, 'sp_task_notification_enqueue: task not found.', 1;

    DECLARE @recipient_name NVARCHAR(200), @recipient_email NVARCHAR(250);
    SELECT @recipient_name  = e.employee_name,
           @recipient_email = e.email
      FROM grac_practice.organization_employee e
     WHERE e.employee_id = @recipient_employee_id;

    -- Composed now, not at send time: the message must describe the
    -- situation as it was when the threshold was crossed.
    DECLARE @subject NVARCHAR(400) =
        CONCAT(CASE @notify_event_code
                    WHEN N'WARNING'    THEN N'[GRAC] Task due soon: '
                    WHEN N'BREACH'     THEN N'[GRAC] SLA BREACHED: '
                    ELSE                    N'[GRAC] Escalation: '
               END,
               ISNULL(@task_number, CONCAT(N'Task #', CAST(@task_id AS NVARCHAR(20)))),
               N' — ', LEFT(ISNULL(@task_title, N''), 200));

    DECLARE @body NVARCHAR(MAX) =
        CONCAT(N'Task: ',      ISNULL(@task_number, CAST(@task_id AS NVARCHAR(20))),
               N' — ',         ISNULL(@task_title, N''), CHAR(13), CHAR(10),
               N'Owner: ',     ISNULL(@owner_name, N'unassigned'), CHAR(13), CHAR(10),
               N'Priority: ',  ISNULL(@priority, N''), CHAR(13), CHAR(10),
               N'Due: ',       CONVERT(NVARCHAR(16), @due_at_key, 120), CHAR(13), CHAR(10),
               N'SLA status: ',ISNULL(@sla_status, N''), CHAR(13), CHAR(10),
               CASE @recipient_reason_code
                    WHEN N'OWNER' THEN N'You are receiving this because you own this task.'
                    ELSE CONCAT(N'You are receiving this as a holder of the notified role: ',
                                ISNULL(@role_name, N'(role)'), N'.')
               END);

    BEGIN TRY
        INSERT INTO grac_practice.task_notification_outbox
            (organization_id, task_id, notify_event_code,
             recipient_employee_id, recipient_name, recipient_email,
             role_id, role_name, recipient_reason_code,
             subject, body_text,
             task_number, task_title, priority, sla_status_code,
             due_at_key, status_code, entered_by, entered_dt)
        VALUES
            (@organization_id, @task_id, @notify_event_code,
             @recipient_employee_id, @recipient_name, @recipient_email,
             @role_id, @role_name, @recipient_reason_code,
             @subject, @body,
             @task_number, @task_title, @priority, @sla_status,
             @due_at_key, N'Pending', @caller_display_name, SYSUTCDATETIME());

        SET @task_notification_id = SCOPE_IDENTITY();
        SET @enqueued = 1;
    END TRY
    BEGIN CATCH
        -- 2601/2627 = the dedupe index fired because a concurrent sweep
        -- inserted the same row microseconds earlier. That is the index
        -- doing its job, not a fault.
        IF ERROR_NUMBER() IN (2601, 2627)
        BEGIN
            SELECT TOP 1 @task_notification_id = task_notification_id
              FROM grac_practice.task_notification_outbox
             WHERE task_id           = @task_id
               AND notify_event_code = @notify_event_code
               AND due_at_key        = @due_at_key
               AND ((recipient_employee_id IS NULL AND @recipient_employee_id IS NULL)
                     OR recipient_employee_id = @recipient_employee_id);
            SET @enqueued = 0;
        END
        ELSE
            THROW;
    END CATCH
END;
GO

-- =====================================================================
-- 2. sp_task_notification_sweep
--
-- The engine. Finds every open task whose elapsed SLA percentage has
-- crossed a threshold, resolves the audience, and records the
-- obligations. Safe to run on any schedule — everything downstream is
-- idempotent.
--
-- Deliberately does NOT transition task state. That belongs to
-- sp_task_overdue_sweep (037), which is untouched.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_notification_sweep
    @organization_id BIGINT = NULL,      -- NULL = every organisation
    @batch_size      INT    = 200,
    @caller_display_name NVARCHAR(100) = N'GRAC_SYSTEM',
    @enqueued_count  INT    = NULL OUTPUT,
    @task_count      INT    = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @enqueued_count = 0;
    SET @task_count     = 0;

    IF @batch_size IS NULL OR @batch_size < 1 SET @batch_size = 200;
    IF @batch_size > 2000 SET @batch_size = 2000;

    -- ---- Which tasks have crossed which threshold? -------------------
    -- One pass, computed from the effective due date so an approved
    -- extension automatically moves the whole scale.
    DECLARE @due TABLE (
        task_id           BIGINT PRIMARY KEY,
        organization_id   BIGINT,
        owner_employee_id BIGINT,
        sla_master_id     BIGINT,
        due_at            DATETIME2,
        elapsed_pct       DECIMAL(9,2),
        is_breached       BIT,
        warning_pct       DECIMAL(5,2),
        escalation_pct    DECIMAL(5,2));

    INSERT INTO @due (task_id, organization_id, owner_employee_id, sla_master_id,
                      due_at, elapsed_pct, is_breached, warning_pct, escalation_pct)
    SELECT TOP (@batch_size)
           t.task_id,
           t.organization_id,
           t.assigned_to_employee_id,
           t.sla_master_id,
           t.sla_due_at,
           CASE WHEN DATEDIFF(SECOND, COALESCE(t.start_date, t.entered_dt), t.sla_due_at) > 0
                THEN CAST(DATEDIFF(SECOND, COALESCE(t.start_date, t.entered_dt), SYSUTCDATETIME()) AS DECIMAL(18,4))
                     / NULLIF(CAST(DATEDIFF(SECOND, COALESCE(t.start_date, t.entered_dt), t.sla_due_at) AS DECIMAL(18,4)), 0) * 100.0
                ELSE 100.0            -- zero-length window: treat as fully elapsed
           END,
           CASE WHEN SYSUTCDATETIME() > t.sla_due_at THEN 1 ELSE 0 END,
           COALESCE(cfg.warning_pct,    75.0),
           COALESCE(cfg.escalation_pct, 100.0)
      FROM grac_practice.practice_task t
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
 LEFT JOIN grac_practice.org_sla_config      cfg ON cfg.organization_id = t.organization_id
                                                AND cfg.sla_master_id   = t.sla_master_id
                                                AND cfg.is_active       = 1
     WHERE t.closed_at   IS NULL
       AND t.sla_due_at  IS NOT NULL
       AND s.is_terminal = 0
       -- Children inherit the parent's commitment; notifying about both
       -- would double every message for a decomposed work package.
       AND t.parent_task_id IS NULL
       AND (@organization_id IS NULL OR t.organization_id = @organization_id)
     ORDER BY t.sla_due_at ASC;

    SELECT @task_count = COUNT(*) FROM @due;
    IF @task_count = 0 RETURN;

    -- ---- Flatten (task x event) -------------------------------------
    -- A newly-breached task can legitimately owe WARNING, BREACH and
    -- ESCALATION all at once — for instance a task created already past
    -- its due date, or one nobody swept for a week. Recording all three
    -- is correct: each is a distinct governance fact.
    DECLARE @events TABLE (
        task_id           BIGINT,
        organization_id   BIGINT,
        owner_employee_id BIGINT,
        sla_master_id     BIGINT,
        due_at            DATETIME2,
        notify_event_code NVARCHAR(30),
        PRIMARY KEY (task_id, notify_event_code));

    INSERT INTO @events (task_id, organization_id, owner_employee_id, sla_master_id, due_at, notify_event_code)
    SELECT d.task_id, d.organization_id, d.owner_employee_id, d.sla_master_id, d.due_at, N'WARNING'
      FROM @due d WHERE d.elapsed_pct >= d.warning_pct
    UNION ALL
    SELECT d.task_id, d.organization_id, d.owner_employee_id, d.sla_master_id, d.due_at, N'BREACH'
      FROM @due d WHERE d.is_breached = 1
    UNION ALL
    SELECT d.task_id, d.organization_id, d.owner_employee_id, d.sla_master_id, d.due_at, N'ESCALATION'
      FROM @due d WHERE d.elapsed_pct >= d.escalation_pct;

    -- ---- Resolve the audience and record --------------------------------
    DECLARE @task_id BIGINT, @org_id BIGINT, @owner_id BIGINT,
            @master_id BIGINT, @due_at DATETIME2, @event NVARCHAR(30);

    DECLARE ev_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT task_id, organization_id, owner_employee_id, sla_master_id, due_at, notify_event_code
          FROM @events;

    OPEN ev_cur;
    FETCH NEXT FROM ev_cur INTO @task_id, @org_id, @owner_id, @master_id, @due_at, @event;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            DECLARE @nid BIGINT, @did BIT;

            -- ---- The owner, always (BRD §13 "Owner reminders") --------
            IF @owner_id IS NOT NULL
            BEGIN
                EXEC grac_practice.sp_task_notification_enqueue
                     @task_id               = @task_id,
                     @notify_event_code     = @event,
                     @due_at_key            = @due_at,
                     @recipient_employee_id = @owner_id,
                     @recipient_reason_code = N'OWNER',
                     @caller_display_name   = @caller_display_name,
                     @task_notification_id  = @nid OUTPUT,
                     @enqueued              = @did OUTPUT;

                IF @did = 1 SET @enqueued_count = @enqueued_count + 1;
            END

            -- ---- Configured management escalation --------------------
            -- Roles are read per (org, sla master, event). No matched SLA
            -- master means no configured roles — the owner still gets the
            -- notification above, which is the point of doing the owner
            -- unconditionally.
            IF @master_id IS NOT NULL
            BEGIN
                DECLARE @role_id BIGINT, @role_name NVARCHAR(200);

                DECLARE role_cur CURSOR LOCAL FAST_FORWARD FOR
                    SELECT nr.role_id, nr.role_name
                      FROM grac_practice.org_sla_config_notify_role nr
                      JOIN grac_practice.org_sla_config c
                        ON c.org_sla_config_id = nr.org_sla_config_id
                     WHERE nr.organization_id   = @org_id
                       AND nr.notify_event_code = @event
                       AND nr.is_active         = 1
                       AND c.sla_master_id      = @master_id
                       AND c.is_active          = 1;

                OPEN role_cur;
                FETCH NEXT FROM role_cur INTO @role_id, @role_name;

                WHILE @@FETCH_STATUS = 0
                BEGIN
                    DECLARE @holders TABLE (
                        EmployeeId BIGINT, EmployeeCode NVARCHAR(80), EmployeeName NVARCHAR(200),
                        Email NVARCHAR(250), Designation NVARCHAR(150), Department NVARCHAR(150),
                        RoleId BIGINT, RoleName NVARCHAR(200));
                    DELETE FROM @holders;

                    INSERT @holders
                    EXEC grac_practice.sp_org_role_holders_list
                         @organization_id = @org_id,
                         @role_id         = @role_id;

                    IF EXISTS (SELECT 1 FROM @holders)
                    BEGIN
                        DECLARE @holder_id BIGINT;
                        DECLARE h_cur CURSOR LOCAL FAST_FORWARD FOR
                            SELECT EmployeeId FROM @holders;
                        OPEN h_cur;
                        FETCH NEXT FROM h_cur INTO @holder_id;
                        WHILE @@FETCH_STATUS = 0
                        BEGIN
                            -- Skip when the holder IS the owner: they
                            -- already have a row, and two identical
                            -- emails for one event is noise.
                            IF @holder_id <> ISNULL(@owner_id, -1)
                            BEGIN
                                EXEC grac_practice.sp_task_notification_enqueue
                                     @task_id               = @task_id,
                                     @notify_event_code     = @event,
                                     @due_at_key            = @due_at,
                                     @recipient_employee_id = @holder_id,
                                     @role_id               = @role_id,
                                     @role_name             = @role_name,
                                     @recipient_reason_code = N'ROLE',
                                     @caller_display_name   = @caller_display_name,
                                     @task_notification_id  = @nid OUTPUT,
                                     @enqueued              = @did OUTPUT;

                                IF @did = 1 SET @enqueued_count = @enqueued_count + 1;
                            END
                            FETCH NEXT FROM h_cur INTO @holder_id;
                        END
                        CLOSE h_cur;
                        DEALLOCATE h_cur;
                    END
                    ELSE
                    BEGIN
                        -- Configured role, nobody holds it. Recorded with
                        -- a NULL recipient so the governance gap is
                        -- visible rather than silently swallowed.
                        EXEC grac_practice.sp_task_notification_enqueue
                             @task_id               = @task_id,
                             @notify_event_code     = @event,
                             @due_at_key            = @due_at,
                             @recipient_employee_id = NULL,
                             @role_id               = @role_id,
                             @role_name             = @role_name,
                             @recipient_reason_code = N'ROLE',
                             @caller_display_name   = @caller_display_name,
                             @task_notification_id  = @nid OUTPUT,
                             @enqueued              = @did OUTPUT;

                        IF @did = 1 SET @enqueued_count = @enqueued_count + 1;
                    END

                    FETCH NEXT FROM role_cur INTO @role_id, @role_name;
                END
                CLOSE role_cur;
                DEALLOCATE role_cur;
            END
        END TRY
        BEGIN CATCH
            -- One bad task must never stop the sweep. Logged to the same
            -- audit trace sp_task_overdue_sweep uses for its own errors.
            INSERT INTO grac_practice.practice_audit_trace
                (entity_type, entity_id, action_type, before_json, after_json,
                 status, entered_by, entered_dt)
            VALUES
                (N'Task', ISNULL(@task_id, 0), N'NOTIFY_SWEEP_ERROR',
                 (SELECT @event AS notify_event_code FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                 (SELECT ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message
                  FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                 N'Error', @caller_display_name, SYSUTCDATETIME());
        END CATCH

        FETCH NEXT FROM ev_cur INTO @task_id, @org_id, @owner_id, @master_id, @due_at, @event;
    END
    CLOSE ev_cur;
    DEALLOCATE ev_cur;
END;
GO

-- =====================================================================
-- 3. sp_task_notification_list
--
-- Serves two screens from one proc: the org-wide outbox (admin) and a
-- single person's inbox (@recipient_employee_id). Two result sets, same
-- count-then-page shape as sp_task_list.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_notification_list
    @organization_id       BIGINT       = NULL,
    @recipient_employee_id BIGINT       = NULL,
    @task_id               BIGINT       = NULL,
    @status_code           NVARCHAR(20) = NULL,
    @notify_event_code     NVARCHAR(30) = NULL,
    @page                  INT = 1,
    @page_size             INT = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    DECLARE @filtered TABLE (task_notification_id BIGINT PRIMARY KEY, sort_dt DATETIME2);

    INSERT INTO @filtered (task_notification_id, sort_dt)
    SELECT n.task_notification_id, n.entered_dt
      FROM grac_practice.task_notification_outbox n
     WHERE (@organization_id IS NULL       OR n.organization_id       = @organization_id)
       AND (@recipient_employee_id IS NULL OR n.recipient_employee_id = @recipient_employee_id)
       AND (@task_id IS NULL               OR n.task_id               = @task_id)
       AND (@status_code IS NULL           OR n.status_code           = @status_code)
       AND (@notify_event_code IS NULL     OR n.notify_event_code     = @notify_event_code);

    SELECT COUNT_BIG(*) AS TotalCount,
           @page        AS PageNumber,
           @page_size   AS PageSize
      FROM @filtered;

    SELECT n.task_notification_id  AS TaskNotificationId,
           n.organization_id       AS OrganizationId,
           n.task_id               AS TaskId,
           n.task_number           AS TaskNumber,
           n.task_title            AS TaskTitle,
           n.priority              AS Priority,
           n.notify_event_code     AS NotifyEventCode,
           n.recipient_employee_id AS RecipientEmployeeId,
           n.recipient_name        AS RecipientName,
           n.recipient_email       AS RecipientEmail,
           n.role_id               AS RoleId,
           n.role_name             AS RoleName,
           n.recipient_reason_code AS RecipientReasonCode,
           n.subject               AS Subject,
           n.body_text             AS BodyText,
           n.sla_status_code       AS SlaStatusCode,
           n.due_at_key            AS DueAt,
           n.status_code           AS StatusCode,
           n.attempt_count         AS AttemptCount,
           n.last_attempt_dt       AS LastAttemptDt,
           n.failure_reason        AS FailureReason,
           n.sent_dt               AS SentDt,
           n.entered_dt            AS EnteredDt
      FROM @filtered f
      JOIN grac_practice.task_notification_outbox n ON n.task_notification_id = f.task_notification_id
     ORDER BY f.sort_dt DESC, f.task_notification_id DESC
     OFFSET (@page - 1) * @page_size ROWS
     FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- =====================================================================
-- 4. sp_task_notification_mark
--
-- Dispatcher feedback. Kept deliberately dumb — this layer has no opinion
-- about retry policy; whatever dispatcher is eventually built owns that
-- and simply reports the outcome here.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_notification_mark
    @task_notification_id BIGINT,
    @status_code          NVARCHAR(20),
    @failure_reason       NVARCHAR(1000) = NULL,
    @caller_display_name  NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_notification_id IS NULL
        THROW 55910, 'sp_task_notification_mark: task_notification_id is required.', 1;
    IF @status_code NOT IN (N'Pending', N'Sent', N'Failed', N'Suppressed')
        THROW 55911, 'sp_task_notification_mark: status_code must be Pending, Sent, Failed or Suppressed.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.task_notification_outbox
                    WHERE task_notification_id = @task_notification_id)
        THROW 55912, 'sp_task_notification_mark: notification not found.', 1;

    UPDATE grac_practice.task_notification_outbox
       SET status_code     = @status_code,
           attempt_count   = attempt_count + CASE WHEN @status_code IN (N'Sent', N'Failed') THEN 1 ELSE 0 END,
           last_attempt_dt = CASE WHEN @status_code IN (N'Sent', N'Failed') THEN SYSUTCDATETIME() ELSE last_attempt_dt END,
           sent_dt         = CASE WHEN @status_code = N'Sent' THEN SYSUTCDATETIME() ELSE sent_dt END,
           failure_reason  = CASE WHEN @status_code = N'Failed' THEN @failure_reason ELSE failure_reason END
     WHERE task_notification_id = @task_notification_id;

    SELECT @task_notification_id AS TaskNotificationId, @status_code AS StatusCode;
END;
GO

-- =====================================================================
-- 5. sp_task_notification_counts
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_notification_counts
    @organization_id       BIGINT = NULL,
    @recipient_employee_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        SUM(CASE WHEN status_code = N'Pending'    THEN 1 ELSE 0 END) AS PendingCount,
        SUM(CASE WHEN status_code = N'Sent'       THEN 1 ELSE 0 END) AS SentCount,
        SUM(CASE WHEN status_code = N'Failed'     THEN 1 ELSE 0 END) AS FailedCount,
        SUM(CASE WHEN status_code = N'Suppressed' THEN 1 ELSE 0 END) AS SuppressedCount,
        SUM(CASE WHEN notify_event_code = N'WARNING'    THEN 1 ELSE 0 END) AS WarningCount,
        SUM(CASE WHEN notify_event_code = N'BREACH'     THEN 1 ELSE 0 END) AS BreachCount,
        SUM(CASE WHEN notify_event_code = N'ESCALATION' THEN 1 ELSE 0 END) AS EscalationCount,
        -- Configured roles with no active holder — a governance gap, not
        -- a delivery problem. Worth its own badge.
        SUM(CASE WHEN recipient_employee_id IS NULL THEN 1 ELSE 0 END)     AS UnroutableCount
      FROM grac_practice.task_notification_outbox
     WHERE (@organization_id IS NULL       OR organization_id       = @organization_id)
       AND (@recipient_employee_id IS NULL OR recipient_employee_id = @recipient_employee_id);
END;
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '202 procedures present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_task_notification_enqueue','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_notification_sweep','P')    IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_notification_list','P')     IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_notification_mark','P')     IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_notification_counts','P')   IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'sp_task_overdue_sweep untouched by Phase 3' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_task_overdue_sweep','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL — 037 must still be installed' END AS Result;

PRINT '202 task notification procedures installed.';
PRINT 'Run manually with:  DECLARE @n INT, @t INT; EXEC grac_practice.sp_task_notification_sweep @enqueued_count=@n OUTPUT, @task_count=@t OUTPUT; SELECT @n AS Enqueued, @t AS TasksScanned;';
GO

SET NOEXEC OFF;
GO
