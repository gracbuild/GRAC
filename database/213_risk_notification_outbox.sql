-- =====================================================================
-- 213 Risk Centre — notification outbox  (BRD §21)  Phase B
--
-- WHAT §21 ASKS FOR
-- -----------------
-- "The system should generate notifications/tasks for relevant workflow
-- events, including: New Risk Candidate assigned for analysis;
-- Clarification requested; Analysis completed; Approval required; Risk
-- approved for registration; Candidate rejected; Risk Owner assignment;
-- Risk treatment actions, where integrated with Task Centre."
--
-- AN OUTBOX, NOT A SENDER — AND WHY A SWEEP, NOT A TRIGGER
-- --------------------------------------------------------
-- The first half of that decision is settled precedent: 201 established
-- that GRAC records the OBLIGATION to notify, not the delivery, because
-- there is no dispatcher in this codebase and because "GRAC determined
-- that these people should have been told, at this time, for this
-- reason" is the evidentiary claim an auditor wants. This migration
-- follows 201 exactly.
--
-- The second half is new, and it is the interesting one. There were
-- three ways to make a notification happen when a risk event occurs:
--
--   a) Rewrite every workflow proc to call an enqueue. Correct, but it
--      would mean 206's and 212's procs being re-emitted a third time in
--      a third file — the same body copied into three migrations, which
--      is precisely the duplication that makes a schema unmaintainable.
--
--   b) An AFTER INSERT trigger on the history tables. No rewrites, but
--      it runs INSIDE the workflow transaction, so a notification
--      problem could roll back a governance decision. 199 and 206 both
--      went out of their way to put downstream side effects outside the
--      transaction; a trigger would quietly undo that.
--
--   c) A sweep over the history tables. No rewrites, runs on a timer
--      outside every workflow transaction, and is idempotent by
--      construction because history rows are immutable and each has an
--      id.
--
-- (c) is what 202 already does for SLA thresholds, so it is also the
-- shape this codebase's operators already know how to run. The dedupe
-- key is (source history row, recipient): a history row is exactly one
-- event that happened once, which makes "notify twice" impossible
-- without any date-keying gymnastics.
--
-- The cost of (c) is honest and worth stating: notifications are
-- generated when the sweep runs, not at the instant of the event. For a
-- system with no dispatcher at all, that is not a real difference.
--
-- CONTENTS
--   1. risk_notification_outbox
--   2. sp_risk_notification_enqueue    single-row writer
--   3. sp_risk_notification_sweep      history -> obligations
--   4. sp_risk_notification_list
--   5. sp_risk_notification_mark
--   6. sp_risk_notification_counts
--
-- NOTHING IN 204-207 OR 212 IS MODIFIED BY THIS MIGRATION.
--
-- ERROR CODE RANGE: 56300-56349
-- Rollback: database/213_risk_notification_outbox_rollback.sql
-- Depends:  205, 206, 212 (org_risk_config), 117 (sp_org_role_holders_list)
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.risk_candidate_history','U') IS NULL
BEGIN PRINT 'ABORT (213): risk_candidate_history missing — run 169 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.risk_register_history','U') IS NULL
BEGIN PRINT 'ABORT (213): risk_register_history missing — run 205 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.org_risk_config','U') IS NULL
BEGIN PRINT 'ABORT (213): org_risk_config missing — run 212 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_org_role_holders_list','P') IS NULL
BEGIN PRINT 'ABORT (213): sp_org_role_holders_list missing — run 117 first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('213_risk_notification_outbox: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. risk_notification_outbox
--
-- Shape follows task_notification_outbox (201) so the two inboxes render
-- with one component and an operator reads them the same way. The
-- differences are the two that matter:
--
--   * subject is (type, record id), not a task id — a risk event can be
--     about a candidate OR a registered risk.
--   * the dedupe anchor is the history row, not a due date — see header.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_notification_outbox','U') IS NULL
CREATE TABLE grac_practice.risk_notification_outbox(
    risk_notification_id   BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_notification_outbox PRIMARY KEY,
    organization_id        BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_notification_org
            REFERENCES grac_practice.organization(organization_id),

    -- ---- What this is about ------------------------------------------
    subject_type_code      NVARCHAR(20) NOT NULL,   -- Candidate | Risk
    subject_record_id      BIGINT NOT NULL,

    -- Same vocabulary as org_risk_config_notify_role.notify_event_code
    -- (212), so the configuration and the outbox never need translating
    -- between each other.
    notify_event_code      NVARCHAR(40) NOT NULL,

    -- ---- The event that caused it ------------------------------------
    -- The history row is the anchor: immutable, unique, and already
    -- written by the workflow proc that did the thing. Nothing else can
    -- serve as an idempotency key this cleanly.
    source_history_code    NVARCHAR(20) NOT NULL,   -- CandidateHistory | RegisterHistory
    source_history_id      BIGINT NOT NULL,
    event_dt               DATETIME2 NOT NULL,

    -- ---- Recipient ----------------------------------------------------
    -- Employee AND a snapshot of their contact details. The snapshot
    -- matters: an outbox row records what GRAC decided at a point in
    -- time, and it must stay readable after somebody changes role,
    -- changes email or leaves.
    recipient_employee_id  BIGINT NULL
        CONSTRAINT fk_pm_risk_notification_recipient
            REFERENCES grac_practice.organization_employee(employee_id),
    recipient_name         NVARCHAR(200) NULL,
    recipient_email        NVARCHAR(250) NULL,

    role_id                BIGINT NULL,
    role_name              NVARCHAR(200) NULL,

    -- Why this person is on the list. PARTICIPANT reasons are people the
    -- workflow itself named (the analyst it was assigned to, the owner it
    -- was given to); ROLE is somebody the organisation configured.
    recipient_reason_code  NVARCHAR(30) NOT NULL
        CONSTRAINT df_pm_risk_notification_reason DEFAULT N'ROLE',

    -- ---- Message ------------------------------------------------------
    -- Composed at enqueue time, not at send time: the message must
    -- describe the situation as it WAS when the event happened, even if
    -- a dispatcher only gets to it days later.
    subject                NVARCHAR(400) NULL,
    body_text              NVARCHAR(MAX) NULL,

    -- ---- Snapshot of the situation ------------------------------------
    subject_number         NVARCHAR(60)  NULL,      -- RC-1-42 / RSK-1-7
    subject_title          NVARCHAR(300) NULL,
    inherent_rating_code   NVARCHAR(30)  NULL,
    status_code_snapshot   NVARCHAR(30)  NULL,

    -- ---- Delivery lifecycle -------------------------------------------
    status_code            NVARCHAR(20) NOT NULL
        CONSTRAINT df_pm_risk_notification_status DEFAULT N'Pending',
    attempt_count          INT NOT NULL
        CONSTRAINT df_pm_risk_notification_attempts DEFAULT 0,
    last_attempt_dt        DATETIME2 NULL,
    failure_reason         NVARCHAR(1000) NULL,
    sent_dt                DATETIME2 NULL,

    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_risk_notification_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_notification_entered_dt DEFAULT SYSUTCDATETIME(),

    CONSTRAINT ck_pm_risk_notification_subject
        CHECK (subject_type_code IN (N'Candidate', N'Risk')),
    CONSTRAINT ck_pm_risk_notification_history
        CHECK (source_history_code IN (N'CandidateHistory', N'RegisterHistory')),
    CONSTRAINT ck_pm_risk_notification_event
        CHECK (notify_event_code IN (
            N'CANDIDATE_ASSIGNED', N'CLARIFICATION_REQUESTED',
            N'ANALYSIS_COMPLETED', N'APPROVAL_REQUIRED',
            N'RISK_APPROVED',      N'CANDIDATE_REJECTED',
            N'RISK_OWNER_ASSIGNED', N'RISK_REGISTERED')),
    CONSTRAINT ck_pm_risk_notification_status
        CHECK (status_code IN (N'Pending', N'Sent', N'Failed', N'Suppressed')),
    CONSTRAINT ck_pm_risk_notification_reason
        CHECK (recipient_reason_code IN (N'ANALYST', N'OWNER', N'APPROVER',
                                         N'REQUESTER', N'ROLE'))
);
GO

-- =====================================================================
-- 2. Idempotency
--
-- The one index that makes a timer-driven sweep safe. A history row is
-- one event that happened once, so (history row, recipient) is exactly
-- "this person was told about this event" — at most once, forever.
--
-- recipient_employee_id is NULLable; SQL Server treats NULLs as equal
-- for uniqueness, so at most one recipient-less row per event can exist
-- too, which is the desired behaviour for a configured role with no
-- active holder (the obligation is still recorded — that a role was
-- empty when it mattered is itself an audit finding).
-- =====================================================================
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_risk_notification_dedupe'
                  AND object_id = OBJECT_ID('grac_practice.risk_notification_outbox'))
    CREATE UNIQUE INDEX ux_pm_risk_notification_dedupe
        ON grac_practice.risk_notification_outbox
           (source_history_code, source_history_id, notify_event_code, recipient_employee_id);
GO

-- The dispatcher's hot path: oldest Pending first.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_notification_pending'
                  AND object_id = OBJECT_ID('grac_practice.risk_notification_outbox'))
    CREATE INDEX ix_pm_risk_notification_pending
        ON grac_practice.risk_notification_outbox(entered_dt)
        INCLUDE (risk_notification_id, organization_id, subject_type_code,
                 subject_record_id, notify_event_code, recipient_email, subject)
        WHERE status_code = N'Pending';
GO

-- "What has this candidate / risk generated?" on the detail modal.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_notification_subject'
                  AND object_id = OBJECT_ID('grac_practice.risk_notification_outbox'))
    CREATE INDEX ix_pm_risk_notification_subject
        ON grac_practice.risk_notification_outbox
           (subject_type_code, subject_record_id, entered_dt DESC)
        INCLUDE (notify_event_code, recipient_name, status_code);
GO

-- "What is waiting for me?" — a per-recipient inbox.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_notification_recipient'
                  AND object_id = OBJECT_ID('grac_practice.risk_notification_outbox'))
    CREATE INDEX ix_pm_risk_notification_recipient
        ON grac_practice.risk_notification_outbox
           (organization_id, recipient_employee_id, status_code, entered_dt DESC);
GO

-- =====================================================================
-- 3. sp_risk_notification_enqueue   (single-row writer)
--
-- Composes the message from the subject record as it stands NOW, which
-- for a sweep running minutes after the event is the same thing. Returns
-- silently when the row already exists — that is the whole point.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_notification_enqueue
    @organization_id       BIGINT,
    @subject_type_code     NVARCHAR(20),
    @subject_record_id     BIGINT,
    @notify_event_code     NVARCHAR(40),
    @source_history_code   NVARCHAR(20),
    @source_history_id     BIGINT,
    @event_dt              DATETIME2,
    @recipient_employee_id BIGINT        = NULL,
    @role_id               BIGINT        = NULL,
    @role_name             NVARCHAR(200) = NULL,
    @recipient_reason_code NVARCHAR(30)  = N'ROLE',
    @event_remark          NVARCHAR(MAX) = NULL,
    @caller_display_name   NVARCHAR(100) = N'system',
    @risk_notification_id  BIGINT        = NULL OUTPUT,
    @enqueued              BIT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @enqueued = 0;
    SET @risk_notification_id = NULL;

    IF @subject_record_id IS NULL OR @notify_event_code IS NULL OR @source_history_id IS NULL
        THROW 56300, 'sp_risk_notification_enqueue: subject_record_id, notify_event_code and source_history_id are required.', 1;

    -- Already recorded for this exact event and person? Nothing to do.
    SELECT TOP 1 @risk_notification_id = risk_notification_id
      FROM grac_practice.risk_notification_outbox
     WHERE source_history_code = @source_history_code
       AND source_history_id   = @source_history_id
       AND notify_event_code   = @notify_event_code
       AND ((recipient_employee_id IS NULL AND @recipient_employee_id IS NULL)
             OR recipient_employee_id = @recipient_employee_id);

    IF @risk_notification_id IS NOT NULL RETURN;

    -- ---- Snapshot the subject ---------------------------------------
    DECLARE @number NVARCHAR(60), @title NVARCHAR(300),
            @rating NVARCHAR(30), @status NVARCHAR(30);

    IF @subject_type_code = N'Candidate'
        SELECT @number = c.candidate_number,
               @title  = c.candidate_title,
               @status = c.status_code,
               @rating = a.inherent_rating_code
          FROM grac_practice.risk_candidate c
     LEFT JOIN grac_practice.risk_analysis a
            ON a.risk_candidate_id = c.risk_candidate_id AND a.is_current = 1
         WHERE c.risk_candidate_id = @subject_record_id;
    ELSE
        SELECT @number = r.risk_number,
               @title  = r.risk_title,
               @status = r.status_code,
               @rating = r.inherent_rating_code
          FROM grac_practice.risk_register r
         WHERE r.risk_register_id = @subject_record_id;

    DECLARE @recipient_name NVARCHAR(200), @recipient_email NVARCHAR(250);
    SELECT @recipient_name  = e.employee_name,
           @recipient_email = e.email
      FROM grac_practice.organization_employee e
     WHERE e.employee_id = @recipient_employee_id;

    DECLARE @headline NVARCHAR(200) =
        CASE @notify_event_code
             WHEN N'CANDIDATE_ASSIGNED'      THEN N'Risk candidate assigned for analysis'
             WHEN N'CLARIFICATION_REQUESTED' THEN N'Clarification requested on a risk candidate'
             WHEN N'ANALYSIS_COMPLETED'      THEN N'Risk analysis completed'
             WHEN N'APPROVAL_REQUIRED'       THEN N'Risk approval required'
             WHEN N'RISK_APPROVED'           THEN N'Risk approved for registration'
             WHEN N'CANDIDATE_REJECTED'      THEN N'Risk candidate rejected'
             WHEN N'RISK_OWNER_ASSIGNED'     THEN N'You have been assigned as risk owner'
             ELSE                                 N'Risk registered'
        END;

    DECLARE @subject NVARCHAR(400) =
        LEFT(CONCAT(N'[GRAC] ', @headline, N': ',
                    ISNULL(@number, CONCAT(N'#', CAST(@subject_record_id AS NVARCHAR(20)))),
                    N' — ', LEFT(ISNULL(@title, N''), 200)), 400);

    DECLARE @body NVARCHAR(MAX) =
        CONCAT(@headline, CHAR(13), CHAR(10), CHAR(13), CHAR(10),
               N'Reference: ', ISNULL(@number, N'(none)'), CHAR(13), CHAR(10),
               N'Title:     ', ISNULL(@title, N'(none)'), CHAR(13), CHAR(10),
               N'Status:    ', ISNULL(@status, N'(none)'), CHAR(13), CHAR(10),
               N'Rating:    ', ISNULL(@rating, N'(not yet rated)'), CHAR(13), CHAR(10),
               N'Occurred:  ', CONVERT(NVARCHAR(30), @event_dt, 120), N' UTC', CHAR(13), CHAR(10),
               CASE WHEN @role_name IS NULL THEN N''
                    ELSE CONCAT(N'You are receiving this as: ', @role_name, CHAR(13), CHAR(10)) END,
               CASE WHEN @event_remark IS NULL THEN N''
                    ELSE CONCAT(CHAR(13), CHAR(10), N'Detail: ', @event_remark, CHAR(13), CHAR(10)) END);

    INSERT INTO grac_practice.risk_notification_outbox
        (organization_id, subject_type_code, subject_record_id, notify_event_code,
         source_history_code, source_history_id, event_dt,
         recipient_employee_id, recipient_name, recipient_email,
         role_id, role_name, recipient_reason_code,
         subject, body_text,
         subject_number, subject_title, inherent_rating_code, status_code_snapshot,
         status_code, entered_by, entered_dt)
    VALUES
        (@organization_id, @subject_type_code, @subject_record_id, @notify_event_code,
         @source_history_code, @source_history_id, @event_dt,
         @recipient_employee_id, @recipient_name, @recipient_email,
         @role_id, @role_name, @recipient_reason_code,
         @subject, @body,
         @number, @title, @rating, @status,
         -- A recipient with no email address cannot be delivered to.
         -- Recording it as Suppressed rather than Pending keeps the
         -- obligation visible without leaving a dispatcher to retry
         -- something that can never succeed.
         CASE WHEN @recipient_email IS NULL OR LEN(LTRIM(RTRIM(@recipient_email))) = 0
              THEN N'Suppressed' ELSE N'Pending' END,
         @caller_display_name, SYSUTCDATETIME());

    SET @risk_notification_id = SCOPE_IDENTITY();
    SET @enqueued = 1;
END;
GO

-- =====================================================================
-- 4. sp_risk_notification_sweep   (BRD §21)
--
-- Scans history rows that have not yet produced obligations, maps each
-- to a §21 event, resolves who should hear about it, and enqueues one
-- row per recipient.
--
-- ACTION -> EVENT MAP
-- -------------------
--   Candidate history
--     Assign               -> CANDIDATE_ASSIGNED
--     Clarify              -> CLARIFICATION_REQUESTED
--     ReturnFromApproval   -> CLARIFICATION_REQUESTED   (same state to
--                             everyone downstream — see 212 §7)
--     SubmitApproval       -> APPROVAL_REQUIRED
--     Approve              -> RISK_APPROVED
--     Reject               -> CANDIDATE_REJECTED
--     Register             -> RISK_REGISTERED
--     AnalysisSave         -> (none)  deliberately: an analyst saving a
--                             draft five times is not five events. §21's
--                             "Analysis completed" is the transition into
--                             AnalysisCompleted, which SubmitApproval and
--                             Approve already carry.
--     Create / Withdraw / CloseDuplicate / AttachmentUpload -> (none):
--                             not in §21's list.
--   Register history
--     OwnerChange          -> RISK_OWNER_ASSIGNED
--     Register             -> (none) the candidate-side Register row
--                             already covers it; emitting both would
--                             notify twice for one act.
--
-- RECIPIENTS
--   Always the people the workflow itself named — the assigned analyst,
--   the risk owner, the approver role — plus any roles the organisation
--   configured for that event in org_risk_config_notify_role (212).
--
-- @since_hours bounds the scan so a first run on an old database does not
-- generate a year of back-notifications. Default 168 (7 days).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_notification_sweep
    @organization_id     BIGINT = NULL,      -- NULL = every organisation
    @since_hours         INT    = 168,
    @max_events          INT    = 500,
    @caller_display_name NVARCHAR(100) = N'sweep'
AS
BEGIN
    SET NOCOUNT ON;

    IF @since_hours IS NULL OR @since_hours <= 0 SET @since_hours = 168;
    IF @max_events  IS NULL OR @max_events  <= 0 SET @max_events  = 500;
    DECLARE @since DATETIME2 = DATEADD(HOUR, -@since_hours, SYSUTCDATETIME());

    -- ---- 1. Collect the events worth notifying about -----------------
    CREATE TABLE #events(
        source_history_code NVARCHAR(20)  NOT NULL,
        source_history_id   BIGINT        NOT NULL,
        organization_id     BIGINT        NOT NULL,
        subject_type_code   NVARCHAR(20)  NOT NULL,
        subject_record_id   BIGINT        NOT NULL,
        notify_event_code   NVARCHAR(40)  NOT NULL,
        event_dt            DATETIME2     NOT NULL,
        remark              NVARCHAR(MAX) NULL,
        actor_employee_id   BIGINT        NULL
    );

    INSERT INTO #events
        (source_history_code, source_history_id, organization_id,
         subject_type_code, subject_record_id, notify_event_code,
         event_dt, remark, actor_employee_id)
    SELECT TOP (@max_events)
           N'CandidateHistory', h.history_id, c.organization_id,
           N'Candidate', c.risk_candidate_id,
           CASE h.action_code
                WHEN N'Assign'             THEN N'CANDIDATE_ASSIGNED'
                WHEN N'Clarify'            THEN N'CLARIFICATION_REQUESTED'
                WHEN N'ReturnFromApproval' THEN N'CLARIFICATION_REQUESTED'
                WHEN N'SubmitApproval'     THEN N'APPROVAL_REQUIRED'
                WHEN N'Approve'            THEN N'RISK_APPROVED'
                WHEN N'Reject'             THEN N'CANDIDATE_REJECTED'
                WHEN N'Register'           THEN N'RISK_REGISTERED'
           END,
           h.entered_dt, h.remark, h.actor_employee_id
      FROM grac_practice.risk_candidate_history h
      JOIN grac_practice.risk_candidate c ON c.risk_candidate_id = h.risk_candidate_id
     WHERE h.entered_dt >= @since
       AND h.action_code IN (N'Assign', N'Clarify', N'ReturnFromApproval',
                             N'SubmitApproval', N'Approve', N'Reject', N'Register')
       AND (@organization_id IS NULL OR c.organization_id = @organization_id)
       AND ISNULL((SELECT notifications_enabled FROM grac_practice.org_risk_config g
                    WHERE g.organization_id = c.organization_id), 1) = 1
       AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_notification_outbox o
                        WHERE o.source_history_code = N'CandidateHistory'
                          AND o.source_history_id   = h.history_id)
     ORDER BY h.history_id;

    INSERT INTO #events
        (source_history_code, source_history_id, organization_id,
         subject_type_code, subject_record_id, notify_event_code,
         event_dt, remark, actor_employee_id)
    SELECT TOP (@max_events)
           N'RegisterHistory', h.history_id, r.organization_id,
           N'Risk', r.risk_register_id,
           N'RISK_OWNER_ASSIGNED',
           h.entered_dt, h.remark, h.actor_employee_id
      FROM grac_practice.risk_register_history h
      JOIN grac_practice.risk_register r ON r.risk_register_id = h.risk_register_id
     WHERE h.entered_dt >= @since
       AND h.action_code = N'OwnerChange'
       AND (@organization_id IS NULL OR r.organization_id = @organization_id)
       AND ISNULL((SELECT notifications_enabled FROM grac_practice.org_risk_config g
                    WHERE g.organization_id = r.organization_id), 1) = 1
       AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_notification_outbox o
                        WHERE o.source_history_code = N'RegisterHistory'
                          AND o.source_history_id   = h.history_id)
     ORDER BY h.history_id;

    -- ---- 2. Resolve recipients, event by event -----------------------
    CREATE TABLE #recipients(
        employee_id BIGINT       NULL,
        role_id     BIGINT       NULL,
        role_name   NVARCHAR(200) NULL,
        reason_code NVARCHAR(30) NOT NULL
    );
    CREATE TABLE #holders(
        EmployeeId BIGINT, EmployeeCode NVARCHAR(100), EmployeeName NVARCHAR(240),
        Email NVARCHAR(250), Designation NVARCHAR(200), Department NVARCHAR(200),
        RoleId BIGINT, RoleName NVARCHAR(200)
    );

    DECLARE @hist_code NVARCHAR(20), @hist_id BIGINT, @org BIGINT,
            @subj_type NVARCHAR(20), @subj_id BIGINT, @event NVARCHAR(40),
            @event_dt DATETIME2, @remark NVARCHAR(MAX), @actor BIGINT;

    DECLARE ev CURSOR LOCAL FAST_FORWARD FOR
        SELECT source_history_code, source_history_id, organization_id,
               subject_type_code, subject_record_id, notify_event_code,
               event_dt, remark, actor_employee_id
          FROM #events;
    OPEN ev;
    FETCH NEXT FROM ev INTO @hist_code, @hist_id, @org, @subj_type, @subj_id,
                            @event, @event_dt, @remark, @actor;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DELETE FROM #recipients;

        -- ---- 2a. Participants the workflow itself named --------------
        IF @subj_type = N'Candidate'
        BEGIN
            -- The analyst, for anything that lands on their desk.
            IF @event IN (N'CANDIDATE_ASSIGNED', N'CLARIFICATION_REQUESTED',
                          N'RISK_APPROVED', N'CANDIDATE_REJECTED')
                INSERT INTO #recipients(employee_id, reason_code)
                SELECT assigned_analyst_employee_id, N'ANALYST'
                  FROM grac_practice.risk_candidate
                 WHERE risk_candidate_id = @subj_id
                   AND assigned_analyst_employee_id IS NOT NULL;

            -- Whoever raised it, when the answer is "no" or "not yet".
            IF @event IN (N'CLARIFICATION_REQUESTED', N'CANDIDATE_REJECTED')
                INSERT INTO #recipients(employee_id, reason_code)
                SELECT requested_by_employee_id, N'REQUESTER'
                  FROM grac_practice.risk_candidate
                 WHERE risk_candidate_id = @subj_id
                   AND requested_by_employee_id IS NOT NULL;

            -- The risk owner named on the analysis, once it is real.
            IF @event IN (N'RISK_REGISTERED', N'ANALYSIS_COMPLETED')
                INSERT INTO #recipients(employee_id, reason_code)
                SELECT a.risk_owner_employee_id, N'OWNER'
                  FROM grac_practice.risk_analysis a
                 WHERE a.risk_candidate_id = @subj_id AND a.is_current = 1
                   AND a.risk_owner_employee_id IS NOT NULL;

            -- §18 Risk Manager / Approver, when the org named a role.
            IF @event = N'APPROVAL_REQUIRED'
            BEGIN
                DECLARE @approver_role BIGINT =
                    (SELECT approver_role_id FROM grac_practice.org_risk_config
                      WHERE organization_id = @org);
                IF @approver_role IS NOT NULL
                BEGIN
                    DELETE FROM #holders;
                    INSERT INTO #holders
                        EXEC grac_practice.sp_org_role_holders_list
                             @organization_id = @org, @role_id = @approver_role;
                    INSERT INTO #recipients(employee_id, role_id, role_name, reason_code)
                    SELECT EmployeeId, RoleId, RoleName, N'APPROVER' FROM #holders;
                END
            END
        END
        ELSE
        BEGIN
            -- Register-side: the new owner is the point of the event.
            IF @event = N'RISK_OWNER_ASSIGNED'
                INSERT INTO #recipients(employee_id, reason_code)
                SELECT risk_owner_employee_id, N'OWNER'
                  FROM grac_practice.risk_register
                 WHERE risk_register_id = @subj_id
                   AND risk_owner_employee_id IS NOT NULL;
        END

        -- ---- 2b. Roles the organisation configured -------------------
        DECLARE @cfg_role_id BIGINT, @cfg_role_name NVARCHAR(200);
        DECLARE rl CURSOR LOCAL FAST_FORWARD FOR
            SELECT n.role_id, n.role_name
              FROM grac_practice.org_risk_config_notify_role n
             WHERE n.organization_id   = @org
               AND n.notify_event_code = @event
               AND n.is_active         = 1;
        OPEN rl;
        FETCH NEXT FROM rl INTO @cfg_role_id, @cfg_role_name;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DELETE FROM #holders;
            INSERT INTO #holders
                EXEC grac_practice.sp_org_role_holders_list
                     @organization_id = @org, @role_id = @cfg_role_id;

            IF EXISTS (SELECT 1 FROM #holders)
                INSERT INTO #recipients(employee_id, role_id, role_name, reason_code)
                SELECT EmployeeId, RoleId, RoleName, N'ROLE' FROM #holders;
            ELSE
                -- A configured role with no active holder still records
                -- the obligation. That the role was empty when it
                -- mattered is itself an audit finding, not a non-event.
                INSERT INTO #recipients(employee_id, role_id, role_name, reason_code)
                VALUES (NULL, @cfg_role_id, @cfg_role_name, N'ROLE');

            FETCH NEXT FROM rl INTO @cfg_role_id, @cfg_role_name;
        END
        CLOSE rl; DEALLOCATE rl;

        -- ---- 2c. Enqueue, one row per distinct person ----------------
        -- The actor is excluded: telling somebody what they just did is
        -- noise, and noise is how notification systems get switched off.
        DECLARE @rcp_emp BIGINT, @rcp_role BIGINT,
                @rcp_role_name NVARCHAR(200), @rcp_reason NVARCHAR(30);
        DECLARE rc CURSOR LOCAL FAST_FORWARD FOR
            SELECT employee_id, MIN(role_id), MIN(role_name), MIN(reason_code)
              FROM #recipients
             WHERE employee_id IS NULL OR employee_id <> ISNULL(@actor, -1)
             GROUP BY employee_id;
        OPEN rc;
        FETCH NEXT FROM rc INTO @rcp_emp, @rcp_role, @rcp_role_name, @rcp_reason;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                DECLARE @nid BIT, @out_id BIGINT;
                EXEC grac_practice.sp_risk_notification_enqueue
                     @organization_id       = @org,
                     @subject_type_code     = @subj_type,
                     @subject_record_id     = @subj_id,
                     @notify_event_code     = @event,
                     @source_history_code   = @hist_code,
                     @source_history_id     = @hist_id,
                     @event_dt              = @event_dt,
                     @recipient_employee_id = @rcp_emp,
                     @role_id               = @rcp_role,
                     @role_name             = @rcp_role_name,
                     @recipient_reason_code = @rcp_reason,
                     @event_remark          = @remark,
                     @caller_display_name   = @caller_display_name,
                     @risk_notification_id  = @out_id OUTPUT,
                     @enqueued              = @nid    OUTPUT;
            END TRY
            BEGIN CATCH
                -- One bad recipient must not abandon the sweep. The
                -- dedupe index makes a retry harmless.
                DECLARE @warn NVARCHAR(4000) = ERROR_MESSAGE();
                PRINT CONCAT(N'sp_risk_notification_sweep: enqueue warning (history ',
                             CAST(@hist_id AS NVARCHAR(20)), N'): ', @warn);
            END CATCH
            FETCH NEXT FROM rc INTO @rcp_emp, @rcp_role, @rcp_role_name, @rcp_reason;
        END
        CLOSE rc; DEALLOCATE rc;

        FETCH NEXT FROM ev INTO @hist_code, @hist_id, @org, @subj_type, @subj_id,
                                @event, @event_dt, @remark, @actor;
    END
    CLOSE ev; DEALLOCATE ev;

    -- Counts the obligations now standing against the events this run
    -- looked at. It is not "rows inserted by this run" — the dedupe index
    -- means a re-run legitimately inserts nothing while the events still
    -- have their notifications, and reporting 0 there would read like a
    -- failure.
    SELECT (SELECT COUNT(*) FROM #events) AS EventsScanned,
           (SELECT COUNT(*) FROM grac_practice.risk_notification_outbox o
             JOIN #events e ON e.source_history_code = o.source_history_code
                           AND e.source_history_id   = o.source_history_id)
               AS NotificationsForScannedEvents;

    DROP TABLE #recipients;
    DROP TABLE #holders;
    DROP TABLE #events;
END;
GO

-- =====================================================================
-- 5. sp_risk_notification_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_notification_list
    @organization_id       BIGINT,
    @status_code           NVARCHAR(20) = NULL,
    @notify_event_code     NVARCHAR(40) = NULL,
    @subject_type_code     NVARCHAR(20) = NULL,
    @subject_record_id     BIGINT       = NULL,
    @recipient_employee_id BIGINT       = NULL,
    @page_number           INT = 1,
    @page_size             INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 56310, 'sp_risk_notification_list: organization_id is required.', 1;
    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    SELECT
        o.risk_notification_id  AS RiskNotificationId,
        o.organization_id       AS OrganizationId,
        o.subject_type_code     AS SubjectTypeCode,
        o.subject_record_id     AS SubjectRecordId,
        o.subject_number        AS SubjectNumber,
        o.subject_title         AS SubjectTitle,
        o.notify_event_code     AS NotifyEventCode,
        o.inherent_rating_code  AS InherentRatingCode,
        o.status_code_snapshot  AS SubjectStatusCode,
        o.recipient_employee_id AS RecipientEmployeeId,
        o.recipient_name        AS RecipientName,
        o.recipient_email       AS RecipientEmail,
        o.role_name             AS RoleName,
        o.recipient_reason_code AS RecipientReasonCode,
        o.subject               AS Subject,
        o.body_text             AS BodyText,
        o.status_code           AS StatusCode,
        o.attempt_count         AS AttemptCount,
        o.failure_reason        AS FailureReason,
        o.sent_dt               AS SentOn,
        o.event_dt              AS EventOn,
        o.entered_dt            AS RecordedOn,
        COUNT(*) OVER ()        AS TotalRows
      FROM grac_practice.risk_notification_outbox o
     WHERE o.organization_id = @organization_id
       AND (@status_code           IS NULL OR o.status_code           = @status_code)
       AND (@notify_event_code     IS NULL OR o.notify_event_code     = @notify_event_code)
       AND (@subject_type_code     IS NULL OR o.subject_type_code     = @subject_type_code)
       AND (@subject_record_id     IS NULL OR o.subject_record_id     = @subject_record_id)
       AND (@recipient_employee_id IS NULL OR o.recipient_employee_id = @recipient_employee_id)
     ORDER BY o.entered_dt DESC, o.risk_notification_id DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- =====================================================================
-- 6. sp_risk_notification_mark   (for whatever dispatcher is chosen)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_notification_mark
    @risk_notification_id BIGINT,
    @status_code          NVARCHAR(20),
    @failure_reason       NVARCHAR(1000) = NULL,
    @caller_display_name  NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_notification_id IS NULL
        THROW 56320, 'sp_risk_notification_mark: risk_notification_id is required.', 1;
    IF @status_code NOT IN (N'Pending', N'Sent', N'Failed', N'Suppressed')
        THROW 56321, 'sp_risk_notification_mark: unknown status_code.', 1;

    UPDATE grac_practice.risk_notification_outbox
       SET status_code     = @status_code,
           attempt_count   = attempt_count + CASE WHEN @status_code IN (N'Sent', N'Failed') THEN 1 ELSE 0 END,
           last_attempt_dt = CASE WHEN @status_code IN (N'Sent', N'Failed') THEN SYSUTCDATETIME() ELSE last_attempt_dt END,
           sent_dt         = CASE WHEN @status_code = N'Sent' THEN SYSUTCDATETIME() ELSE sent_dt END,
           failure_reason  = CASE WHEN @status_code = N'Failed' THEN @failure_reason ELSE NULL END
     WHERE risk_notification_id = @risk_notification_id;

    SELECT @risk_notification_id AS RiskNotificationId, @status_code AS StatusCode;
END;
GO

-- =====================================================================
-- 7. sp_risk_notification_counts   (badge for the screen)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_notification_counts
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 56330, 'sp_risk_notification_counts: organization_id is required.', 1;

    SELECT
        SUM(CASE WHEN status_code = N'Pending'    THEN 1 ELSE 0 END) AS PendingCount,
        SUM(CASE WHEN status_code = N'Sent'       THEN 1 ELSE 0 END) AS SentCount,
        SUM(CASE WHEN status_code = N'Failed'     THEN 1 ELSE 0 END) AS FailedCount,
        SUM(CASE WHEN status_code = N'Suppressed' THEN 1 ELSE 0 END) AS SuppressedCount,
        COUNT(*)                                                     AS TotalCount
      FROM grac_practice.risk_notification_outbox
     WHERE organization_id = @organization_id;
END;
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '213 objects present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.risk_notification_outbox','U')    IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_notification_enqueue','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_notification_sweep','P')   IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_notification_list','P')    IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_notification_mark','P')    IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_notification_counts','P')  IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'dedupe index present' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                          WHERE name = 'ux_pm_risk_notification_dedupe')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '213 Risk notification outbox installed. Next: 214_risk_dashboard_procs.sql';
PRINT 'NOTE: this is an OUTBOX, not a sender. Schedule sp_risk_notification_sweep';
PRINT '      and point a dispatcher at status_code = Pending.';
GO

SET NOEXEC OFF;
GO
