-- =====================================================================
-- 037 Task engine  (charter §12.1.3)
--
-- One canonical task entity backing every workflow trigger in Waves 1–5:
--   Implementation / Rectification / Change / Waiver / Reverification /
--   AssignmentPending / AuditDriven / RiskDriven.
--
-- Depends on: §12.1.1 state-machine framework (035_*).
--
-- Contents:
--   1. task_type_master
--   2. practice_task
--   3. Indexes tuned per charter §5.3
--   4. Seed task types
--
-- Procedures live in 037_task_engine_procs.sql (charter §5: never extend
-- the monolith 02_Create_Procedures.sql).
--
-- Rollback:  database/037_task_engine_rollback.sql
-- Docs:      docs/task-engine.md
-- Smoke:     database/deployment/08_UAT_Diagnostics_TaskEngine.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

-- =====================================================================
-- Prerequisite guard.
-- Uses SET NOEXEC ON so that ALL subsequent batches in this script are
-- parsed-but-not-executed when a prerequisite is missing (a bare THROW
-- only terminates the current batch — later GO-separated batches would
-- otherwise proceed and fail with confusing FK / missing-object errors).
-- =====================================================================
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (037): schema grac_practice is missing. Run base scripts first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.entity_status_master','U') IS NULL
BEGIN
    PRINT 'ABORT (037): entity_status_master missing. Run 035_state_machine_framework.sql before this file.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('037_task_engine: prerequisites missing — see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. task_type_master
-- =====================================================================
IF OBJECT_ID('grac_practice.task_type_master','U') IS NULL
CREATE TABLE grac_practice.task_type_master(
    task_type_id     INT           IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_task_type_master PRIMARY KEY,
    type_code        NVARCHAR(60)  NOT NULL
        CONSTRAINT uq_pm_task_type_code UNIQUE,
    type_name        NVARCHAR(120) NOT NULL,
    description      NVARCHAR(400) NULL,
    default_sla_hours INT          NOT NULL DEFAULT 72,
    default_priority NVARCHAR(30)  NOT NULL DEFAULT N'Medium',
    is_system_only   BIT           NOT NULL DEFAULT 0,   -- true when only sp_* callers may open this type
    display_order    INT           NOT NULL DEFAULT 0,
    is_active        BIT           NOT NULL DEFAULT 1,
    entered_by       NVARCHAR(100) NOT NULL DEFAULT 'system',
    entered_dt       DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_by       NVARCHAR(100) NULL,
    updated_dt       DATETIME2     NULL
);
GO

;WITH src AS (
    SELECT * FROM (VALUES
        (N'Implementation',       N'Implementation',      N'Configure and operationalise an Instance', 168, N'High',     0, 10),
        (N'Rectification',        N'Rectification',       N'Address a Fail from assurance execution',   72, N'High',     0, 20),
        (N'Change',               N'Change',              N'Approved change request for content',      168, N'Medium',   0, 30),
        (N'Waiver',               N'Waiver',              N'Waiver request or extension',              120, N'Medium',   0, 40),
        (N'Reverification',       N'Reverification',      N'Reverify an NA or Waiver before expiry',   240, N'Medium',   0, 50),
        (N'AssignmentPending',    N'Assignment Pending',  N'Ownership acceptance pending',             168, N'Medium',   1, 60),
        (N'AuditDriven',          N'Audit Driven',        N'Task raised from an auditor finding',      168, N'High',     0, 70),
        (N'RiskDriven',           N'Risk Driven',         N'Task raised from a KRI or risk change',    120, N'High',     0, 80)
    ) v(type_code, type_name, description, default_sla_hours, default_priority, is_system_only, display_order)
)
MERGE grac_practice.task_type_master AS t
USING src
   ON t.type_code = src.type_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (type_code, type_name, description, default_sla_hours, default_priority, is_system_only, display_order, entered_by)
    VALUES (src.type_code, src.type_name, src.description, src.default_sla_hours, src.default_priority, src.is_system_only, src.display_order, 'seed-037');
GO

-- =====================================================================
-- 2. practice_task  (per charter §13.1)
--    current_status_id references entity_status_master where
--    entity_type = 'Task' (seeded in 035_).
-- =====================================================================
IF OBJECT_ID('grac_practice.practice_task','U') IS NULL
CREATE TABLE grac_practice.practice_task(
    task_id                  BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_practice_task PRIMARY KEY,
    organization_id          BIGINT        NOT NULL,
    task_type_id             INT           NOT NULL
        CONSTRAINT fk_pm_task_type
        REFERENCES grac_practice.task_type_master(task_type_id),
    subject_entity_type      NVARCHAR(60)  NOT NULL,
    subject_entity_id        BIGINT        NOT NULL,
    linked_release_id        BIGINT        NULL,
    linked_control_id        BIGINT        NULL,
    linked_practice_id       BIGINT        NULL,
    linked_instance_id       BIGINT        NULL,
    subject_title            NVARCHAR(250) NOT NULL,
    subject_description      NVARCHAR(MAX) NULL,
    assigned_to_employee_id  BIGINT        NULL
        CONSTRAINT fk_pm_task_assignee
        REFERENCES grac_practice.organization_employee(employee_id),
    current_status_id        INT           NOT NULL
        CONSTRAINT fk_pm_task_current_status
        REFERENCES grac_practice.entity_status_master(entity_status_id),
    priority                 NVARCHAR(30)  NOT NULL DEFAULT N'Medium',
    criticality              NVARCHAR(30)  NULL,
    origin_code              NVARCHAR(30)  NULL,          -- GRAC / Custom for downstream RBAC
    sla_due_at               DATETIME2     NULL,
    escalated_at             DATETIME2     NULL,
    reason_code              NVARCHAR(60)  NULL,
    reason_text              NVARCHAR(1000) NULL,
    correlation_id           UNIQUEIDENTIFIER NULL,
    closed_at                DATETIME2     NULL,
    entered_by               NVARCHAR(100) NOT NULL DEFAULT 'system',
    entered_dt               DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_by               NVARCHAR(100) NULL,
    updated_dt               DATETIME2     NULL,
    CONSTRAINT ck_pm_task_priority
        CHECK (priority IN (N'Low', N'Medium', N'High', N'Critical'))
);
GO

-- Idempotency key for Implementation-Task generation (§12.2.2 dependency):
-- a single Implementation task per (subject_entity_type, subject_entity_id,
-- task_type_id) in a non-terminal state. Enforced by a filtered unique
-- index so re-runs of the gap detector cannot duplicate.
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'ux_pm_practice_task_impl_dedup'
      AND object_id = OBJECT_ID('grac_practice.practice_task'))
BEGIN
    -- SQL Server does not support subqueries in filtered index predicates,
    -- so we filter on task_type_id via the seeded surrogate (looked up at
    -- migration time). This is safe because task_type_master.type_code is
    -- unique + is_active + never deleted.
    DECLARE @impl_type_id INT = (SELECT task_type_id FROM grac_practice.task_type_master WHERE type_code = N'Implementation');
    IF @impl_type_id IS NOT NULL
    BEGIN
        DECLARE @ddl NVARCHAR(MAX) = CONCAT(
            N'CREATE UNIQUE INDEX ux_pm_practice_task_impl_dedup ',
            N'ON grac_practice.practice_task(subject_entity_type, subject_entity_id) ',
            N'WHERE task_type_id = ', @impl_type_id,
            N' AND closed_at IS NULL;');
        EXEC sp_executesql @ddl;
    END
END
GO

-- Hot-path indexes per charter §5.3
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_practice_task_assignee_status' AND object_id = OBJECT_ID('grac_practice.practice_task'))
    CREATE INDEX ix_pm_practice_task_assignee_status
        ON grac_practice.practice_task(assigned_to_employee_id, current_status_id)
        INCLUDE (sla_due_at, priority, task_type_id, organization_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_practice_task_org_status' AND object_id = OBJECT_ID('grac_practice.practice_task'))
    CREATE INDEX ix_pm_practice_task_org_status
        ON grac_practice.practice_task(organization_id, current_status_id)
        INCLUDE (assigned_to_employee_id, sla_due_at, task_type_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_practice_task_subject' AND object_id = OBJECT_ID('grac_practice.practice_task'))
    CREATE INDEX ix_pm_practice_task_subject
        ON grac_practice.practice_task(subject_entity_type, subject_entity_id)
        INCLUDE (current_status_id, task_type_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_practice_task_sla_open' AND object_id = OBJECT_ID('grac_practice.practice_task'))
    CREATE INDEX ix_pm_practice_task_sla_open
        ON grac_practice.practice_task(sla_due_at)
        INCLUDE (task_id, organization_id, current_status_id, assigned_to_employee_id, task_type_id)
        WHERE closed_at IS NULL;
GO

-- Convenience view: task with resolved status_code / type_code, for read APIs.
--
-- Wrapped in EXEC sp_executesql because CREATE VIEW does NOT support
-- deferred name resolution — it needs practice_task / task_type_master /
-- entity_status_master to exist at parse time. When the prerequisite
-- guard at the top of this file sets NOEXEC ON, static CREATE VIEW would
-- still parse (and fail) even though it wouldn't execute. Dynamic SQL is
-- only parsed at EXEC time, so NOEXEC blocks it cleanly.
IF OBJECT_ID('grac_practice.practice_task','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.task_type_master','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.entity_status_master','U') IS NOT NULL
BEGIN
    EXEC sp_executesql N'
CREATE OR ALTER VIEW grac_practice.vw_pm_practice_task AS
SELECT t.task_id,
       t.organization_id,
       t.task_type_id,
       tt.type_code                            AS task_type_code,
       tt.type_name                            AS task_type_name,
       t.subject_entity_type,
       t.subject_entity_id,
       t.linked_release_id,
       t.linked_control_id,
       t.linked_practice_id,
       t.linked_instance_id,
       t.subject_title,
       t.subject_description,
       t.assigned_to_employee_id,
       t.current_status_id,
       s.status_code                           AS current_status_code,
       s.status_name                           AS current_status_name,
       s.is_terminal                           AS current_status_is_terminal,
       t.priority,
       t.criticality,
       t.origin_code,
       t.sla_due_at,
       CASE
         WHEN t.sla_due_at IS NULL THEN NULL
         WHEN s.is_terminal = 1 THEN NULL
         WHEN SYSUTCDATETIME() > t.sla_due_at THEN 1
         ELSE 0
       END                                     AS is_overdue,
       t.escalated_at,
       t.reason_code,
       t.reason_text,
       t.correlation_id,
       t.closed_at,
       t.entered_by, t.entered_dt, t.updated_by, t.updated_dt
FROM grac_practice.practice_task t
JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id;';
END
GO

PRINT '037 task engine schema installed. Next: run 037_task_engine_procs.sql';
GO

SELECT '037 task engine migration complete.' AS Message,
       (SELECT COUNT(*) FROM grac_practice.task_type_master) AS TaskTypeCount;
GO

-- Restore normal execution regardless of guard outcome.
SET NOEXEC OFF;
GO
