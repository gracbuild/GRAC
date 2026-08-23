-- =====================================================================
-- 178 Organization SLA Config schema
--
-- Business context:
--   Control Management (GRAC_New / Authority Portal) publishes SLA
--   masters that define a target SLA duration for a control activity
--   (e.g. "Access review closure -- 15 days"). Each organization
--   adopts a subset of these SLA masters, tunes the WARNING and
--   ESCALATION thresholds to their operating cadence, picks the ROLES
--   that must be notified when each of those events fires, and finally
--   BINDS the tuned SLA against one or more processes (Gap Analysis,
--   Task, Observation, Exception ...).
--
--   Downstream sweeps (task overdue sweep, gap breach detector,
--   exception overdue watcher) resolve the applicable SLA via
--   sp_org_sla_config_for_process and route notifications to the
--   current holders of the configured roles via
--   sp_org_role_holders_list (migration 117).
--
-- Naming (all in schema grac_practice):
--   sla_process_type_master        catalog of process types SLAs can bind to
--   org_sla_config                 header per adopted SLA per org
--   org_sla_config_notify_role     roles to notify per event (WARNING/ESCALATION)
--   org_sla_process_binding        (org, process_type[, scope_ref]) -> config
--
-- The SLA master itself lives in grac_new.sla_master and is referenced
-- softly by id + snapshotted name/code -- same pattern used by
-- org_assurance_workflow_config (migration 083) for workflow templates.
--
-- Rollback: 178_org_sla_config_schema_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- =====================================================================
-- Prerequisite guard
-- =====================================================================
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (178): schema grac_practice missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.organization','U') IS NULL
BEGIN PRINT 'ABORT (178): organization table missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.organization_role','U') IS NULL
BEGIN PRINT 'ABORT (178): organization_role table missing.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN PRINT 'ABORT (178): record_status_master missing.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('178_org_sla_config_schema: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. sla_process_type_master  (fixed catalog, extensible via INSERT)
--
-- process_type_code is the join key downstream sweeps use:
--   GAP          -> custom_gap breach
--   TASK         -> practice_task overdue sweep
--   OBSERVATION  -> org_assurance_observation SLA
--   EXCEPTION    -> exception centre overdue watcher
--
-- More rows can be inserted without a schema change.
-- =====================================================================
IF OBJECT_ID('grac_practice.sla_process_type_master','U') IS NULL
CREATE TABLE grac_practice.sla_process_type_master(
    sla_process_type_id   INT           IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_sla_process_type PRIMARY KEY,
    process_type_code     NVARCHAR(60)  NOT NULL
        CONSTRAINT uq_pm_sla_process_type_code UNIQUE,
    process_type_name     NVARCHAR(200) NOT NULL,
    description           NVARCHAR(500) NULL,
    -- Optional column pointer that lets the resolver understand what
    -- process_scope_ref_id means for this process type (e.g. for TASK
    -- the scope_ref is task_type_id, for GAP it may be control_id).
    -- Free-form documentation column; not enforced.
    scope_ref_hint        NVARCHAR(200) NULL,
    display_order         INT           NOT NULL
        CONSTRAINT df_pm_sla_process_type_order DEFAULT 100,
    is_active             BIT           NOT NULL
        CONSTRAINT df_pm_sla_process_type_active DEFAULT 1,
    entered_by            NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_sla_process_type_ent_by DEFAULT 'system',
    entered_dt            DATETIME2     NOT NULL
        CONSTRAINT df_pm_sla_process_type_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by            NVARCHAR(100) NULL,
    updated_dt            DATETIME2     NULL
);
GO

-- Seed baseline process types (MERGE so re-runs stay idempotent).
;WITH src AS (
    SELECT * FROM (VALUES
        (N'GAP',         N'Gap Analysis',
         N'Custom gap lifecycle SLA (target close date driven).',
         N'process_scope_ref_id = custom_gap_id or control_id (optional).', 10),
        (N'TASK',        N'Task',
         N'Practice task engine SLA (task_type_master.default_sla_hours override).',
         N'process_scope_ref_id = task_type_id (optional).', 20),
        (N'OBSERVATION', N'Assurance Observation',
         N'Assurance observation resolution SLA.',
         N'process_scope_ref_id = org_assurance_definition_id (optional).', 30),
        (N'EXCEPTION',   N'Exception',
         N'Exception centre response and closure SLA.',
         N'process_scope_ref_id = exception_type_id (optional).', 40)
    ) t(process_type_code, process_type_name, description, scope_ref_hint, display_order)
)
MERGE grac_practice.sla_process_type_master AS tgt
USING src
   ON tgt.process_type_code = src.process_type_code
WHEN MATCHED THEN UPDATE SET
    process_type_name = src.process_type_name,
    description       = src.description,
    scope_ref_hint    = src.scope_ref_hint,
    display_order     = src.display_order,
    updated_by        = 'seed-178',
    updated_dt        = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN INSERT
    (process_type_code, process_type_name, description, scope_ref_hint,
     display_order, entered_by)
VALUES
    (src.process_type_code, src.process_type_name, src.description,
     src.scope_ref_hint, src.display_order, 'seed-178');
GO

-- =====================================================================
-- 2. org_sla_config -- header per adopted SLA master per organization
--
-- sla_master_id is a SOFT reference to grac_new.sla_master (Control
-- Management). We snapshot the code + name at adoption time so the
-- Practice Management screens can render without a cross-database
-- join and so we survive rename/retire events on the master side.
--
-- warning_before_due_days:
--   How many days BEFORE the process due date the WARNING notification
--   fires. e.g. warning_before_due_days = 3, due_date = 2026-08-20 -->
--   WARNING event dispatched at 2026-08-17.
--
-- escalation_after_due_days:
--   How many days AFTER the process due date has elapsed the
--   ESCALATION notification fires. e.g. escalation_after_due_days = 2,
--   due_date = 2026-08-20 --> ESCALATION event dispatched at 2026-08-22.
--
-- total_sla_days is snapshot of the master's SLA target (optional,
-- kept for display + for computing due_date when the process itself
-- does not carry a target date).
--
-- CHECK: warning_before_due_days >= 0 AND escalation_after_due_days >= 0
--        AND (total_sla_days IS NULL OR warning_before_due_days <= total_sla_days)
-- =====================================================================
IF OBJECT_ID('grac_practice.org_sla_config','U') IS NULL
CREATE TABLE grac_practice.org_sla_config(
    org_sla_config_id           BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_org_sla_config PRIMARY KEY,
    organization_id             BIGINT        NOT NULL,

    -- Soft ref to grac_new.sla_master (Control Management).
    sla_master_id               BIGINT        NOT NULL,
    sla_master_code             NVARCHAR(120) NULL,
    sla_master_name             NVARCHAR(200) NULL,

    -- Adoption-time snapshot of the master's SLA target (days).
    total_sla_days              INT           NULL,

    -- Org-tuned thresholds.
    warning_before_due_days     INT           NOT NULL
        CONSTRAINT df_pm_org_sla_warning DEFAULT 3,
    escalation_after_due_days   INT           NOT NULL
        CONSTRAINT df_pm_org_sla_escalation DEFAULT 2,

    notes                       NVARCHAR(1000) NULL,

    is_active                   BIT           NOT NULL
        CONSTRAINT df_pm_org_sla_active DEFAULT 1,
    record_status_id            INT           NOT NULL,
    entered_by                  NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_org_sla_ent_by DEFAULT 'system',
    entered_dt                  DATETIME2     NOT NULL
        CONSTRAINT df_pm_org_sla_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by                  NVARCHAR(100) NULL,
    updated_dt                  DATETIME2     NULL,

    CONSTRAINT fk_pm_org_sla_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_org_sla_record_status
        FOREIGN KEY(record_status_id)
        REFERENCES grac_practice.record_status_master(record_status_id),
    CONSTRAINT ck_pm_org_sla_thresholds
        CHECK (warning_before_due_days >= 0 AND escalation_after_due_days >= 0),
    CONSTRAINT ck_pm_org_sla_warning_within_total
        CHECK (total_sla_days IS NULL
            OR warning_before_due_days <= total_sla_days)
);
GO

-- One active adoption per (org, sla master) -- prevents duplicate rows.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name='ux_pm_org_sla_org_master_active'
                  AND object_id=OBJECT_ID('grac_practice.org_sla_config'))
    CREATE UNIQUE INDEX ux_pm_org_sla_org_master_active
        ON grac_practice.org_sla_config(organization_id, sla_master_id)
        WHERE is_active = 1;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name='ix_pm_org_sla_org'
                  AND object_id=OBJECT_ID('grac_practice.org_sla_config'))
    CREATE INDEX ix_pm_org_sla_org
        ON grac_practice.org_sla_config(organization_id, is_active)
        INCLUDE (sla_master_id, sla_master_name, warning_before_due_days,
                 escalation_after_due_days);
GO

-- =====================================================================
-- 3. org_sla_config_notify_role
--   Roles to notify per event. notify_event_code is fixed vocabulary
--   (WARNING / ESCALATION). Resolution to current employees happens at
--   notify time via sp_org_role_holders_list (117) -- so employee
--   turnover never orphans a config.
-- =====================================================================
IF OBJECT_ID('grac_practice.org_sla_config_notify_role','U') IS NULL
CREATE TABLE grac_practice.org_sla_config_notify_role(
    org_sla_config_notify_role_id BIGINT       IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_org_sla_notify_role PRIMARY KEY,
    org_sla_config_id             BIGINT        NOT NULL,
    organization_id               BIGINT        NOT NULL,

    notify_event_code             NVARCHAR(30)  NOT NULL,
    role_id                       BIGINT        NOT NULL,
    role_name                     NVARCHAR(200) NULL,

    is_active                     BIT           NOT NULL
        CONSTRAINT df_pm_org_sla_nr_active DEFAULT 1,
    entered_by                    NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_org_sla_nr_ent_by DEFAULT 'system',
    entered_dt                    DATETIME2     NOT NULL
        CONSTRAINT df_pm_org_sla_nr_ent_dt DEFAULT SYSUTCDATETIME(),

    CONSTRAINT fk_pm_org_sla_nr_config
        FOREIGN KEY(org_sla_config_id)
        REFERENCES grac_practice.org_sla_config(org_sla_config_id),
    CONSTRAINT fk_pm_org_sla_nr_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT ck_pm_org_sla_nr_event
        CHECK (notify_event_code IN (N'WARNING', N'ESCALATION'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name='ux_pm_org_sla_notify_role_uniq'
                  AND object_id=OBJECT_ID('grac_practice.org_sla_config_notify_role'))
    CREATE UNIQUE INDEX ux_pm_org_sla_notify_role_uniq
        ON grac_practice.org_sla_config_notify_role
           (org_sla_config_id, notify_event_code, role_id)
        WHERE is_active = 1;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name='ix_pm_org_sla_notify_role_config'
                  AND object_id=OBJECT_ID('grac_practice.org_sla_config_notify_role'))
    CREATE INDEX ix_pm_org_sla_notify_role_config
        ON grac_practice.org_sla_config_notify_role(org_sla_config_id, notify_event_code)
        INCLUDE (role_id, role_name)
        WHERE is_active = 1;
GO

-- =====================================================================
-- 4. org_sla_process_binding
--   Attaches an org_sla_config to one or more processes. The pair
--   (process_type_code, process_scope_ref_id) is the "against process"
--   link the user picks in the UI:
--     GAP + NULL          -> default SLA for every gap in the org
--     GAP + <control_id>  -> override for gaps under a specific control
--     TASK + <task_type_id> -> override for tasks of one type
--
--   Uniqueness: one active binding per (org, process_type, scope_ref).
--   scope_ref = NULL is treated as a distinct value (this is default).
-- =====================================================================
IF OBJECT_ID('grac_practice.org_sla_process_binding','U') IS NULL
CREATE TABLE grac_practice.org_sla_process_binding(
    org_sla_process_binding_id  BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_org_sla_process_binding PRIMARY KEY,
    organization_id             BIGINT        NOT NULL,
    org_sla_config_id           BIGINT        NOT NULL,

    process_type_code           NVARCHAR(60)  NOT NULL,
    -- NULL == default binding for this process_type in this org.
    process_scope_ref_id        BIGINT        NULL,
    process_scope_label         NVARCHAR(200) NULL, -- snapshot for display

    is_active                   BIT           NOT NULL
        CONSTRAINT df_pm_org_sla_bind_active DEFAULT 1,
    record_status_id            INT           NOT NULL,
    entered_by                  NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_org_sla_bind_ent_by DEFAULT 'system',
    entered_dt                  DATETIME2     NOT NULL
        CONSTRAINT df_pm_org_sla_bind_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by                  NVARCHAR(100) NULL,
    updated_dt                  DATETIME2     NULL,

    CONSTRAINT fk_pm_org_sla_bind_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_org_sla_bind_config
        FOREIGN KEY(org_sla_config_id)
        REFERENCES grac_practice.org_sla_config(org_sla_config_id),
    CONSTRAINT fk_pm_org_sla_bind_process_type
        FOREIGN KEY(process_type_code)
        REFERENCES grac_practice.sla_process_type_master(process_type_code),
    CONSTRAINT fk_pm_org_sla_bind_record_status
        FOREIGN KEY(record_status_id)
        REFERENCES grac_practice.record_status_master(record_status_id)
);
GO

-- Uniqueness of active binding per (org, process_type, scope_ref).
-- Filtered index on is_active = 1; scope_ref = NULL slot is unique too
-- (SQL Server treats NULL as a value in filtered UNIQUE indexes when
-- there's only one such row -- proven by ux_pm_practice_task_impl_dedup
-- pattern in migration 037).
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name='ux_pm_org_sla_bind_org_process_scope'
                  AND object_id=OBJECT_ID('grac_practice.org_sla_process_binding'))
    CREATE UNIQUE INDEX ux_pm_org_sla_bind_org_process_scope
        ON grac_practice.org_sla_process_binding
           (organization_id, process_type_code, process_scope_ref_id)
        WHERE is_active = 1;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name='ix_pm_org_sla_bind_config'
                  AND object_id=OBJECT_ID('grac_practice.org_sla_process_binding'))
    CREATE INDEX ix_pm_org_sla_bind_config
        ON grac_practice.org_sla_process_binding(org_sla_config_id, is_active)
        INCLUDE (process_type_code, process_scope_ref_id);
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Post-deploy sanity report
-- =====================================================================
SELECT 'sla_process_type_master present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sla_process_type_master','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_sla_config present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_sla_config','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_sla_config_notify_role present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_sla_config_notify_role','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_sla_process_binding present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_sla_process_binding','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'sla_process_type_master seeded (>=4 rows)' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.sla_process_type_master) >= 4
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '178 Organization SLA Config schema deployed.';
GO

SET NOEXEC OFF;
GO
