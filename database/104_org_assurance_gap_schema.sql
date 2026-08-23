-- =====================================================================
-- 104 Organization Assurance (Phase 2) -- Stage 4 Gap Management
--
-- Business context (BRD Part 2 Sec 12):
--   A Gap is a corrective-action record generated (usually
--   automatically) from an Accepted Observation. Gaps carry a
--   remediation plan, target date, owner + reviewer, and one or more
--   corrective actions. Each gap has its own lifecycle independent
--   of the source observation (Open -> InProgress ->
--   RemediationSubmitted -> Verified -> Closed, with Reopen).
--
-- Design guarantees:
--   * Immutable audit trail via org_assurance_gap_history.
--   * gap.source_observation_id is a soft ref (nullable) so gaps can
--     be manually created without an observation.
--   * gap.risk_id and gap.task_id are nullable soft refs to reserve
--     Stage 4c Risk/Task integration hooks without hard-coupling.
--   * Reuses org_assurance_observation_severity_master (101) instead
--     of duplicating vocabulary.
--
-- Tables:
--   grac_practice.org_assurance_gap_status_master
--   grac_practice.org_assurance_gap
--   grac_practice.org_assurance_gap_action
--   grac_practice.org_assurance_gap_history
--
-- Rollback: 104_org_assurance_gap_schema_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
   OR OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_observation','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_observation_severity_master','U') IS NULL
BEGIN
    RAISERROR('104: prerequisites missing (run 001 + 098 + 101).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Status master (lifecycle vocabulary)
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_gap_status_master','U') IS NULL
CREATE TABLE grac_practice.org_assurance_gap_status_master(
    org_assurance_gap_status_id INT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_gap_status PRIMARY KEY,
    status_code   NVARCHAR(60)  NOT NULL
        CONSTRAINT uq_pm_oa_gap_status_code UNIQUE,
    status_name   NVARCHAR(120) NOT NULL,
    display_order INT           NOT NULL CONSTRAINT df_pm_oa_gap_status_order    DEFAULT 0,
    is_terminal   BIT           NOT NULL CONSTRAINT df_pm_oa_gap_status_terminal DEFAULT 0,
    is_active     BIT           NOT NULL CONSTRAINT df_pm_oa_gap_status_active   DEFAULT 1,
    entered_by    NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_gap_status_ent_by   DEFAULT 'system',
    entered_dt    DATETIME2     NOT NULL CONSTRAINT df_pm_oa_gap_status_ent_dt   DEFAULT SYSUTCDATETIME(),
    updated_by    NVARCHAR(100) NULL,
    updated_dt    DATETIME2     NULL
);
GO

MERGE grac_practice.org_assurance_gap_status_master AS t
USING (VALUES
    (N'Open',                 N'Open',                  1, 0),
    (N'InProgress',           N'In Progress',           2, 0),
    (N'RemediationSubmitted', N'Remediation Submitted', 3, 0),
    (N'Verified',             N'Verified',              4, 0),
    (N'Closed',               N'Closed',                5, 1),
    (N'Reopened',             N'Reopened',              6, 0)
) AS src(status_code, status_name, display_order, is_terminal)
ON t.status_code = src.status_code
WHEN MATCHED THEN UPDATE SET
    status_name   = src.status_name,
    display_order = src.display_order,
    is_terminal   = src.is_terminal,
    is_active     = 1,
    updated_by    = 'seed-104',
    updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (status_code, status_name, display_order, is_terminal, is_active, entered_by)
VALUES
    (src.status_code, src.status_name, src.display_order, src.is_terminal, 1, 'seed-104');
GO

-- =====================================================================
-- 2. Gap header
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_gap','U') IS NULL
CREATE TABLE grac_practice.org_assurance_gap(
    org_assurance_gap_id              BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_gap PRIMARY KEY,
    organization_id                   BIGINT NOT NULL,

    -- Source observation (nullable -- gaps CAN be created manually).
    org_assurance_observation_id      BIGINT NULL,

    -- Denormalized source-context copies. Same rationale as
    -- observation table -- lets gap render / filter without joins,
    -- keeps snapshot readable if source is later soft-deleted.
    org_assurance_execution_id        BIGINT NULL,
    org_assurance_execution_entity_id BIGINT NULL,
    execution_code                    NVARCHAR(120) NULL,
    execution_name                    NVARCHAR(300) NULL,
    entity_dimension_code             NVARCHAR(60)  NULL,
    entity_dimension_name             NVARCHAR(160) NULL,
    entity_code                       NVARCHAR(120) NULL,
    entity_name                       NVARCHAR(240) NULL,
    observation_code                  NVARCHAR(120) NULL,
    observation_title                 NVARCHAR(300) NULL,

    -- Identity + content.
    gap_code                          NVARCHAR(120) NOT NULL,
    gap_title                         NVARCHAR(300) NOT NULL,
    gap_description                   NVARCHAR(MAX) NULL,

    -- Severity mirror (reuses observation_severity_master from 101).
    severity_id                       INT NOT NULL,
    severity_code                     NVARCHAR(30)  NOT NULL,
    severity_name                     NVARCHAR(120) NULL,

    gap_status_id                     INT NOT NULL,

    -- Assignment.
    assigned_owner_employee_id        BIGINT NULL,
    assigned_owner_display_name       NVARCHAR(240) NULL,
    assigned_reviewer_employee_id     BIGINT NULL,
    assigned_reviewer_display_name    NVARCHAR(240) NULL,

    -- Timeline.
    opened_dt                         DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_gap_opened_dt DEFAULT SYSUTCDATETIME(),
    target_resolution_date            DATE NULL,
    remediation_submitted_dt          DATETIME2 NULL,
    verified_dt                       DATETIME2 NULL,
    closed_dt                         DATETIME2 NULL,
    reopened_dt                       DATETIME2 NULL,

    -- Remediation content.
    remediation_plan                  NVARCHAR(MAX) NULL,
    resolution_notes                  NVARCHAR(MAX) NULL,
    verification_notes                NVARCHAR(MAX) NULL,
    closure_notes                     NVARCHAR(MAX) NULL,

    -- Stage 4c integration hooks (nullable soft refs).
    risk_id                           BIGINT NULL,
    task_id                           BIGINT NULL,

    is_active                         BIT NOT NULL
        CONSTRAINT df_pm_oa_gap_active DEFAULT 1,
    record_status_id                  INT NOT NULL,
    entered_by                        NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_gap_ent_by DEFAULT 'system',
    entered_dt                        DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_gap_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by                        NVARCHAR(100) NULL,
    updated_dt                        DATETIME2 NULL,

    CONSTRAINT fk_pm_oa_gap_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_gap_observation
        FOREIGN KEY(org_assurance_observation_id)
        REFERENCES grac_practice.org_assurance_observation(org_assurance_observation_id),
    CONSTRAINT fk_pm_oa_gap_execution
        FOREIGN KEY(org_assurance_execution_id)
        REFERENCES grac_practice.org_assurance_execution(org_assurance_execution_id),
    CONSTRAINT fk_pm_oa_gap_entity
        FOREIGN KEY(org_assurance_execution_entity_id)
        REFERENCES grac_practice.org_assurance_execution_entity(org_assurance_execution_entity_id),
    CONSTRAINT fk_pm_oa_gap_severity
        FOREIGN KEY(severity_id)
        REFERENCES grac_practice.org_assurance_observation_severity_master(org_assurance_observation_severity_id),
    CONSTRAINT fk_pm_oa_gap_status
        FOREIGN KEY(gap_status_id)
        REFERENCES grac_practice.org_assurance_gap_status_master(org_assurance_gap_status_id),
    CONSTRAINT fk_pm_oa_gap_record_status
        FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
    CONSTRAINT uq_pm_oa_gap_code UNIQUE(organization_id, gap_code)
);
GO

CREATE INDEX ix_pm_oa_gap_org
    ON grac_practice.org_assurance_gap(
        organization_id, is_active, gap_status_id,
        opened_dt DESC, org_assurance_gap_id DESC)
    WHERE is_active = 1;
GO

CREATE INDEX ix_pm_oa_gap_observation
    ON grac_practice.org_assurance_gap(
        org_assurance_observation_id, org_assurance_gap_id DESC)
    WHERE is_active = 1 AND org_assurance_observation_id IS NOT NULL;
GO

CREATE INDEX ix_pm_oa_gap_execution
    ON grac_practice.org_assurance_gap(
        org_assurance_execution_id, gap_status_id, org_assurance_gap_id DESC)
    WHERE is_active = 1 AND org_assurance_execution_id IS NOT NULL;
GO

CREATE INDEX ix_pm_oa_gap_owner
    ON grac_practice.org_assurance_gap(
        organization_id, assigned_owner_employee_id, gap_status_id)
    WHERE is_active = 1 AND assigned_owner_employee_id IS NOT NULL;
GO

-- =====================================================================
-- 3. Gap corrective actions
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_gap_action','U') IS NULL
CREATE TABLE grac_practice.org_assurance_gap_action(
    org_assurance_gap_action_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_gap_action PRIMARY KEY,
    org_assurance_gap_id        BIGINT NOT NULL,
    organization_id             BIGINT NOT NULL,

    action_order                INT NOT NULL
        CONSTRAINT df_pm_oa_gap_action_order DEFAULT 0,
    action_title                NVARCHAR(300) NOT NULL,
    action_description          NVARCHAR(MAX) NULL,

    assigned_employee_id        BIGINT NULL,
    assigned_display_name       NVARCHAR(240) NULL,
    due_date                    DATE NULL,
    completed_dt                DATETIME2 NULL,

    -- Pending / InProgress / Completed / Cancelled (BRD verbs).
    action_status_code          NVARCHAR(30) NOT NULL
        CONSTRAINT df_pm_oa_gap_action_status DEFAULT N'Pending',

    -- Stage 4c integration hook -- link this action to a PM task.
    task_id                     BIGINT NULL,

    notes                       NVARCHAR(MAX) NULL,

    is_active                   BIT NOT NULL
        CONSTRAINT df_pm_oa_gap_action_active DEFAULT 1,
    entered_by                  NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_gap_action_ent_by DEFAULT 'system',
    entered_dt                  DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_gap_action_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by                  NVARCHAR(100) NULL,
    updated_dt                  DATETIME2 NULL,

    CONSTRAINT fk_pm_oa_gap_action_gap
        FOREIGN KEY(org_assurance_gap_id)
        REFERENCES grac_practice.org_assurance_gap(org_assurance_gap_id),
    CONSTRAINT fk_pm_oa_gap_action_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT ck_pm_oa_gap_action_status CHECK (
        action_status_code IN (N'Pending', N'InProgress', N'Completed', N'Cancelled'))
);
GO

CREATE INDEX ix_pm_oa_gap_action_gap
    ON grac_practice.org_assurance_gap_action(
        org_assurance_gap_id, action_order, org_assurance_gap_action_id)
    WHERE is_active = 1;
GO

-- =====================================================================
-- 4. Gap history (lifecycle audit log)
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_gap_history','U') IS NULL
CREATE TABLE grac_practice.org_assurance_gap_history(
    org_assurance_gap_history_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_gap_history PRIMARY KEY,
    org_assurance_gap_id BIGINT NOT NULL,
    organization_id      BIGINT NOT NULL,
    action_code          NVARCHAR(40)  NOT NULL,
    from_status_id       INT NULL,
    to_status_id         INT NULL,
    reason_text          NVARCHAR(1000) NULL,
    actor_display_name   NVARCHAR(240) NULL,
    entered_by           NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_gap_hist_ent_by DEFAULT 'system',
    entered_dt           DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_gap_hist_ent_dt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_pm_oa_gap_hist_gap
        FOREIGN KEY(org_assurance_gap_id)
        REFERENCES grac_practice.org_assurance_gap(org_assurance_gap_id),
    CONSTRAINT fk_pm_oa_gap_hist_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_gap_hist_from_status
        FOREIGN KEY(from_status_id)
        REFERENCES grac_practice.org_assurance_gap_status_master(org_assurance_gap_status_id),
    CONSTRAINT fk_pm_oa_gap_hist_to_status
        FOREIGN KEY(to_status_id)
        REFERENCES grac_practice.org_assurance_gap_status_master(org_assurance_gap_status_id)
);
GO

CREATE INDEX ix_pm_oa_gap_hist_gap
    ON grac_practice.org_assurance_gap_history(
        org_assurance_gap_id, entered_dt DESC);
GO

COMMIT TRAN;
GO

SELECT '6 gap statuses seeded' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.org_assurance_gap_status_master WHERE is_active = 1) = 6
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_assurance_gap present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_gap','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_assurance_gap_action present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_gap_action','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_assurance_gap_history present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_gap_history','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '104 Organization Assurance Gap schema deployed.';
GO

SET NOEXEC OFF;
GO
