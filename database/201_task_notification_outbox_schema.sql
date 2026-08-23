-- =====================================================================
-- 201 Task notification outbox — schema  (Phase 3; BRD §13)
--
-- WHAT THE BRD ASKS FOR
-- ---------------------
-- §13: "SLA monitoring must be common to all Approved Tasks regardless of
--  origin. Use configurable notification thresholds rather than
--  hard-coded timings. ... On Track. Due Soon. Due Today / Due Date
--  reached. SLA Breached. Escalation after breach. Owner reminders and
--  configured management escalation."
--
-- Phase 1 delivered the monitoring half: vw_pm_practice_task derives
-- sla_status_code from the organisation's own warning_pct. What was
-- missing is the other half — telling anybody.
--
-- WHY AN OUTBOX AND NOT A SENDER
-- ------------------------------
-- There is no notification delivery infrastructure in this codebase.
-- org_sla_config_notify_role (178/182) stores WHICH ROLES to notify and
-- sp_org_role_holders_list (117) resolves WHO holds them, but nothing
-- queues or sends. PracticeEmailService exists only in the Web tier and
-- is registered in Web/Program.cs, so an Api-side sweeper cannot reach it
-- without moving a working component.
--
-- So this migration records the OBLIGATION, not the delivery: one row per
-- (task, threshold, recipient), auditable, with a status lifecycle ready
-- for whatever dispatcher is chosen later. That is also the honest
-- compliance answer — "GRAC determined that these five people should have
-- been told, at this time, for this reason" is the evidentiary claim; the
-- SMTP transcript is not.
--
-- THE DEDUPE PROBLEM, AND WHY THE KEY INCLUDES THE DUE DATE
-- ---------------------------------------------------------
-- The sweeper runs on a timer, so it must be idempotent: a task that is
-- Breached today must not generate a fresh row every 60 seconds. The
-- obvious key is (task_id, notify_event_code, recipient) — one warning
-- per person per task, ever.
--
-- But BRD §8 lets an approved SLA extension move the due date. Under that
-- key, a task warned about in January could never be warned about again
-- after an extension pushed it to June — the one case where a reminder
-- matters most. So the key also carries `due_at_key`, the effective due
-- date at the moment the row was raised. A new commitment is a new key,
-- which re-arms the whole threshold sequence exactly once.
--
-- Rollback: database/201_task_notification_outbox_schema_rollback.sql
-- Procs:    202_task_notification_procs.sql
-- Docs:     docs/task-centre-v2.md
-- ERROR CODE RANGE: 55900-55999
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (201): schema grac_practice is missing.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.practice_task','U') IS NULL
BEGIN PRINT 'ABORT (201): practice_task missing — run 037 first.'; SET @ok = 0; END

IF COL_LENGTH('grac_practice.practice_task','standard_due_at') IS NULL
BEGIN PRINT 'ABORT (201): Task Centre v2 schema missing — run 192 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.organization_employee','U') IS NULL
BEGIN PRINT 'ABORT (201): organization_employee missing — run 009 first.'; SET @ok = 0; END

IF @ok = 0
BEGIN
    RAISERROR('201_task_notification_outbox_schema: prerequisites missing. Run database/_diag_task_centre_v2_prereqs.sql for a full report.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. task_notification_outbox
-- =====================================================================
IF OBJECT_ID('grac_practice.task_notification_outbox','U') IS NULL
CREATE TABLE grac_practice.task_notification_outbox(
    task_notification_id   BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_task_notification_outbox PRIMARY KEY,
    organization_id        BIGINT NOT NULL
        CONSTRAINT fk_pm_task_notification_org
            REFERENCES grac_practice.organization(organization_id),
    task_id                BIGINT NOT NULL
        CONSTRAINT fk_pm_task_notification_task
            REFERENCES grac_practice.practice_task(task_id),

    -- Same vocabulary as org_sla_config_notify_role.notify_event_code
    -- (WARNING / BREACH / ESCALATION, widened in 182) so the config and
    -- the outbox never need translating between each other.
    notify_event_code      NVARCHAR(30) NOT NULL,

    -- ---- Recipient ---------------------------------------------------
    -- Employee AND a snapshot of their contact details. The snapshot
    -- matters: an outbox row is a record of what GRAC decided at a point
    -- in time, and it must stay readable after somebody changes role,
    -- changes email or leaves.
    recipient_employee_id  BIGINT NULL
        CONSTRAINT fk_pm_task_notification_recipient
            REFERENCES grac_practice.organization_employee(employee_id),
    recipient_name         NVARCHAR(200) NULL,
    recipient_email        NVARCHAR(250) NULL,

    -- Why this person: the notify role, or NULL when they are the task
    -- owner (BRD §13 "Owner reminders AND configured management
    -- escalation" — the owner is notified regardless of configuration).
    role_id                BIGINT NULL,
    role_name              NVARCHAR(200) NULL,
    recipient_reason_code  NVARCHAR(30) NOT NULL
        CONSTRAINT df_pm_task_notification_reason DEFAULT N'ROLE',

    -- ---- Message ------------------------------------------------------
    -- Composed at enqueue time, not at send time: the message must
    -- describe the situation as it WAS when the threshold was crossed,
    -- even if a dispatcher only gets to it hours later.
    subject                NVARCHAR(400) NULL,
    body_text              NVARCHAR(MAX) NULL,

    -- ---- Snapshot of the situation that triggered it -----------------
    task_number            NVARCHAR(60)  NULL,
    task_title             NVARCHAR(250) NULL,
    priority               NVARCHAR(30)  NULL,
    sla_status_code        NVARCHAR(30)  NULL,

    -- The effective due date when this row was raised. Part of the dedupe
    -- key — see the header note on why.
    due_at_key             DATETIME2 NOT NULL,

    -- ---- Delivery lifecycle -------------------------------------------
    --   Pending    — recorded, not yet handed to any dispatcher
    --   Sent       — a dispatcher confirmed delivery
    --   Failed     — a dispatcher gave up (attempt_count says how often)
    --   Suppressed — deliberately not sent (no email address, opt-out,
    --                task completed before anyone got to it)
    status_code            NVARCHAR(20) NOT NULL
        CONSTRAINT df_pm_task_notification_status DEFAULT N'Pending',
    attempt_count          INT NOT NULL
        CONSTRAINT df_pm_task_notification_attempts DEFAULT 0,
    last_attempt_dt        DATETIME2 NULL,
    failure_reason         NVARCHAR(1000) NULL,
    sent_dt                DATETIME2 NULL,

    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_task_notification_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_task_notification_entered_dt DEFAULT SYSUTCDATETIME(),

    CONSTRAINT ck_pm_task_notification_event
        CHECK (notify_event_code IN (N'WARNING', N'BREACH', N'ESCALATION')),
    CONSTRAINT ck_pm_task_notification_status
        CHECK (status_code IN (N'Pending', N'Sent', N'Failed', N'Suppressed')),
    CONSTRAINT ck_pm_task_notification_reason
        CHECK (recipient_reason_code IN (N'OWNER', N'ROLE'))
);
GO

-- =====================================================================
-- 2. Idempotency
--
-- The one index that makes a timer-driven sweeper safe. Without it, a
-- sweep every 60 seconds would enqueue 1,440 identical warnings a day.
--
-- recipient_employee_id is part of the key and is NULLable; SQL Server
-- treats NULLs as equal for uniqueness purposes in an index, so at most
-- one recipient-less row per (task, event, due date) can exist too —
-- which is the desired behaviour for a role with no active holder.
-- =====================================================================
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_task_notification_dedupe'
                  AND object_id = OBJECT_ID('grac_practice.task_notification_outbox'))
    CREATE UNIQUE INDEX ux_pm_task_notification_dedupe
        ON grac_practice.task_notification_outbox
           (task_id, notify_event_code, due_at_key, recipient_employee_id);
GO

-- The dispatcher's hot path: oldest Pending first.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_task_notification_pending'
                  AND object_id = OBJECT_ID('grac_practice.task_notification_outbox'))
    CREATE INDEX ix_pm_task_notification_pending
        ON grac_practice.task_notification_outbox(entered_dt)
        INCLUDE (task_notification_id, organization_id, task_id,
                 notify_event_code, recipient_email, subject)
        WHERE status_code = N'Pending';
GO

-- "What was this task's notification history?" on the task detail page.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_task_notification_task'
                  AND object_id = OBJECT_ID('grac_practice.task_notification_outbox'))
    CREATE INDEX ix_pm_task_notification_task
        ON grac_practice.task_notification_outbox(task_id, entered_dt DESC)
        INCLUDE (notify_event_code, recipient_name, status_code);
GO

-- "What is waiting for me?" — a per-recipient inbox view.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_task_notification_recipient'
                  AND object_id = OBJECT_ID('grac_practice.task_notification_outbox'))
    CREATE INDEX ix_pm_task_notification_recipient
        ON grac_practice.task_notification_outbox(organization_id, recipient_employee_id, status_code, entered_dt DESC)
        INCLUDE (task_id, notify_event_code, subject);
GO

-- =====================================================================
-- 3. Sanity
-- =====================================================================
SELECT 'task_notification_outbox present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.task_notification_outbox','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'dedupe index includes the due date' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1
             FROM sys.index_columns ic
             JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
             JOIN sys.indexes  i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
            WHERE i.name = 'ux_pm_task_notification_dedupe'
              AND c.name = 'due_at_key')
           THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '201 task notification outbox installed. Next: 202_task_notification_procs.sql';
GO

SET NOEXEC OFF;
GO
