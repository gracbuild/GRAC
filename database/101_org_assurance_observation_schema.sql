-- =====================================================================
-- 101 Organization Assurance (Phase 2) -- Stage 4 Observations
--
-- Business context (BRD Part 2 Sec 11):
--   Observations are findings recorded during an assurance execution.
--   Each observation carries: severity, type, source context (which
--   execution + entity produced it), reviewer + owner assignment,
--   evidence attachments, and its own lifecycle (Open -> InReview ->
--   Accepted/Rejected -> Resolved -> Closed).
--
-- Key design guarantees:
--   * Observation is IMMUTABLE evidence once accepted -- edits are
--     blocked at the SP layer past InReview.
--   * Snapshot the triggering execution + entity context at
--     insert-time so the observation stays interpretable even if the
--     source execution or its entities are later archived.
--   * gap_id column exists but is nullable -- Stage 4 item #2
--     (automatic gap generation) populates it once implemented. No
--     hard FK, so schema doesn't need a rev when the gap table lands.
--
-- Tables:
--   grac_practice.org_assurance_observation_severity_master
--   grac_practice.org_assurance_observation_status_master
--   grac_practice.org_assurance_observation
--   grac_practice.org_assurance_observation_evidence
--   grac_practice.org_assurance_observation_history
--
-- Rollback: 101_org_assurance_observation_schema_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
   OR OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_execution','U') IS NULL
BEGIN
    RAISERROR('101: prerequisites missing (run 001 + 098).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Severity master
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_observation_severity_master','U') IS NULL
CREATE TABLE grac_practice.org_assurance_observation_severity_master(
    org_assurance_observation_severity_id INT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_obs_severity PRIMARY KEY,
    severity_code   NVARCHAR(30)  NOT NULL
        CONSTRAINT uq_pm_oa_obs_severity_code UNIQUE,
    severity_name   NVARCHAR(120) NOT NULL,
    display_order   INT           NOT NULL CONSTRAINT df_pm_oa_obs_sev_order  DEFAULT 0,
    color_hex       NVARCHAR(20)  NULL,
    is_active       BIT           NOT NULL CONSTRAINT df_pm_oa_obs_sev_active DEFAULT 1,
    entered_by      NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_obs_sev_ent_by DEFAULT 'system',
    entered_dt      DATETIME2     NOT NULL CONSTRAINT df_pm_oa_obs_sev_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by      NVARCHAR(100) NULL,
    updated_dt      DATETIME2     NULL
);
GO

MERGE grac_practice.org_assurance_observation_severity_master AS t
USING (VALUES
    (N'Critical',      N'Critical',      1, N'#b91c1c'),
    (N'High',          N'High',          2, N'#ea580c'),
    (N'Medium',        N'Medium',        3, N'#ca8a04'),
    (N'Low',           N'Low',           4, N'#65a30d'),
    (N'Informational', N'Informational', 5, N'#0284c7')
) AS src(severity_code, severity_name, display_order, color_hex)
ON t.severity_code = src.severity_code
WHEN MATCHED THEN UPDATE SET
    severity_name = src.severity_name,
    display_order = src.display_order,
    color_hex     = src.color_hex,
    is_active     = 1,
    updated_by    = 'seed-101',
    updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (severity_code, severity_name, display_order, color_hex, is_active, entered_by)
VALUES
    (src.severity_code, src.severity_name, src.display_order, src.color_hex, 1, 'seed-101');
GO

-- =====================================================================
-- 2. Status master (lifecycle vocabulary)
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_observation_status_master','U') IS NULL
CREATE TABLE grac_practice.org_assurance_observation_status_master(
    org_assurance_observation_status_id INT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_obs_status PRIMARY KEY,
    status_code   NVARCHAR(60)  NOT NULL
        CONSTRAINT uq_pm_oa_obs_status_code UNIQUE,
    status_name   NVARCHAR(120) NOT NULL,
    display_order INT           NOT NULL CONSTRAINT df_pm_oa_obs_status_order    DEFAULT 0,
    is_terminal   BIT           NOT NULL CONSTRAINT df_pm_oa_obs_status_terminal DEFAULT 0,
    is_active     BIT           NOT NULL CONSTRAINT df_pm_oa_obs_status_active   DEFAULT 1,
    entered_by    NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_obs_status_ent_by   DEFAULT 'system',
    entered_dt    DATETIME2     NOT NULL CONSTRAINT df_pm_oa_obs_status_ent_dt   DEFAULT SYSUTCDATETIME(),
    updated_by    NVARCHAR(100) NULL,
    updated_dt    DATETIME2     NULL
);
GO

MERGE grac_practice.org_assurance_observation_status_master AS t
USING (VALUES
    (N'Open',      N'Open',      1, 0),
    (N'InReview',  N'In Review', 2, 0),
    (N'Accepted',  N'Accepted',  3, 0),
    (N'Rejected',  N'Rejected',  4, 1),
    (N'Resolved',  N'Resolved',  5, 0),
    (N'Closed',    N'Closed',    6, 1)
) AS src(status_code, status_name, display_order, is_terminal)
ON t.status_code = src.status_code
WHEN MATCHED THEN UPDATE SET
    status_name   = src.status_name,
    display_order = src.display_order,
    is_terminal   = src.is_terminal,
    is_active     = 1,
    updated_by    = 'seed-101',
    updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (status_code, status_name, display_order, is_terminal, is_active, entered_by)
VALUES
    (src.status_code, src.status_name, src.display_order, src.is_terminal, 1, 'seed-101');
GO

-- =====================================================================
-- 3. Observation header
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_observation','U') IS NULL
CREATE TABLE grac_practice.org_assurance_observation(
    org_assurance_observation_id      BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_observation PRIMARY KEY,
    organization_id                   BIGINT NOT NULL,

    -- Source execution (mandatory) + optional entity (some observations
    -- are execution-level -- e.g. "overall control ineffective").
    org_assurance_execution_id        BIGINT NOT NULL,
    org_assurance_execution_entity_id BIGINT NULL,

    -- Denormalized copies from source -- lets lists render without
    -- joining, and keeps observation readable if source is later
    -- soft-deleted.
    execution_code                    NVARCHAR(120) NULL,
    execution_name                    NVARCHAR(300) NULL,
    entity_dimension_code             NVARCHAR(60)  NULL,
    entity_dimension_name             NVARCHAR(160) NULL,
    entity_code                       NVARCHAR(120) NULL,
    entity_name                       NVARCHAR(240) NULL,

    -- Identity + core content.
    observation_code                  NVARCHAR(120) NOT NULL,
    observation_title                 NVARCHAR(300) NOT NULL,
    observation_description           NVARCHAR(MAX) NULL,

    -- Classification.
    observation_type                  NVARCHAR(30) NOT NULL
        CONSTRAINT df_pm_oa_obs_type   DEFAULT N'Finding',
    severity_id                       INT NOT NULL,
    -- Denormalized severity_code for cheap filtering / rendering.
    severity_code                     NVARCHAR(30)  NOT NULL,
    severity_name                     NVARCHAR(120) NULL,

    observation_status_id             INT NOT NULL,

    -- Optional source question snapshot -- once definition <-> question
    -- set wiring exists in Stage 4b, materialize can populate this.
    source_question_code              NVARCHAR(120) NULL,
    source_question_text              NVARCHAR(MAX) NULL,
    source_question_snapshot_json     NVARCHAR(MAX) NULL,

    -- Assignment.
    reported_by_employee_id           BIGINT NULL,
    reported_by_display_name          NVARCHAR(240) NULL,
    assigned_owner_employee_id        BIGINT NULL,
    assigned_owner_display_name       NVARCHAR(240) NULL,
    assigned_reviewer_employee_id     BIGINT NULL,
    assigned_reviewer_display_name    NVARCHAR(240) NULL,

    -- Timeline.
    observed_dt                       DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_obs_observed_dt DEFAULT SYSUTCDATETIME(),
    due_date                          DATE NULL,
    accepted_dt                       DATETIME2 NULL,
    rejected_dt                       DATETIME2 NULL,
    resolved_dt                       DATETIME2 NULL,
    closed_dt                         DATETIME2 NULL,

    -- Stage 4b hookup -- gap generated from this observation. Nullable,
    -- soft ref (no FK). Populated only when auto-gap engine runs.
    gap_id                            BIGINT NULL,

    -- Outcome + resolution details.
    resolution_notes                  NVARCHAR(MAX) NULL,
    rejection_reason                  NVARCHAR(MAX) NULL,

    is_active                         BIT NOT NULL
        CONSTRAINT df_pm_oa_obs_active DEFAULT 1,
    record_status_id                  INT NOT NULL,
    entered_by                        NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_obs_ent_by DEFAULT 'system',
    entered_dt                        DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_obs_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by                        NVARCHAR(100) NULL,
    updated_dt                        DATETIME2 NULL,

    CONSTRAINT fk_pm_oa_obs_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_obs_execution
        FOREIGN KEY(org_assurance_execution_id)
        REFERENCES grac_practice.org_assurance_execution(org_assurance_execution_id),
    CONSTRAINT fk_pm_oa_obs_entity
        FOREIGN KEY(org_assurance_execution_entity_id)
        REFERENCES grac_practice.org_assurance_execution_entity(org_assurance_execution_entity_id),
    CONSTRAINT fk_pm_oa_obs_severity
        FOREIGN KEY(severity_id)
        REFERENCES grac_practice.org_assurance_observation_severity_master(org_assurance_observation_severity_id),
    CONSTRAINT fk_pm_oa_obs_status
        FOREIGN KEY(observation_status_id)
        REFERENCES grac_practice.org_assurance_observation_status_master(org_assurance_observation_status_id),
    CONSTRAINT fk_pm_oa_obs_record_status
        FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
    CONSTRAINT ck_pm_oa_obs_type CHECK (
        observation_type IN (N'Finding', N'Improvement', N'BestPractice', N'Risk')),
    CONSTRAINT uq_pm_oa_obs_code UNIQUE(organization_id, observation_code)
);
GO

CREATE INDEX ix_pm_oa_obs_org
    ON grac_practice.org_assurance_observation(
        organization_id, is_active, observation_status_id,
        observed_dt DESC, org_assurance_observation_id DESC)
    WHERE is_active = 1;
GO

CREATE INDEX ix_pm_oa_obs_execution
    ON grac_practice.org_assurance_observation(
        org_assurance_execution_id, observation_status_id,
        org_assurance_observation_id DESC)
    WHERE is_active = 1;
GO

CREATE INDEX ix_pm_oa_obs_entity
    ON grac_practice.org_assurance_observation(
        org_assurance_execution_entity_id, org_assurance_observation_id DESC)
    WHERE is_active = 1 AND org_assurance_execution_entity_id IS NOT NULL;
GO

CREATE INDEX ix_pm_oa_obs_severity
    ON grac_practice.org_assurance_observation(
        organization_id, severity_code, observation_status_id)
    WHERE is_active = 1;
GO

-- =====================================================================
-- 4. Observation evidence attachments
--    Each attachment is a soft ref to the file storage layer -- the
--    file_id / storage_locator fields describe WHERE the evidence
--    lives without a hard dependency on a specific storage backend.
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_observation_evidence','U') IS NULL
CREATE TABLE grac_practice.org_assurance_observation_evidence(
    org_assurance_observation_evidence_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_obs_evidence PRIMARY KEY,
    org_assurance_observation_id BIGINT NOT NULL,
    organization_id              BIGINT NOT NULL,

    -- Denormalized soft ref to the evidence config item captured in
    -- the execution's evidence_snapshot_json (from 099). Populated when
    -- the reviewer picked a specific evidence slot; free-form otherwise.
    evidence_config_id           BIGINT NULL,
    evidence_type_code           NVARCHAR(60)  NULL,
    evidence_type_name           NVARCHAR(200) NULL,
    evidence_label               NVARCHAR(240) NULL,

    -- File / storage locator. Neither is a hard FK; the storage
    -- backend may be file-system, S3, SharePoint, etc.
    file_id                      BIGINT NULL,
    storage_location             NVARCHAR(120) NULL,
    storage_locator              NVARCHAR(1000) NULL,
    original_file_name           NVARCHAR(400) NULL,
    file_size_bytes              BIGINT NULL,
    mime_type                    NVARCHAR(200) NULL,

    -- Collection metadata.
    collected_by_employee_id     BIGINT NULL,
    collected_by_display_name    NVARCHAR(240) NULL,
    collected_dt                 DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_obs_ev_collected_dt DEFAULT SYSUTCDATETIME(),
    notes                        NVARCHAR(MAX) NULL,

    is_active                    BIT NOT NULL
        CONSTRAINT df_pm_oa_obs_ev_active DEFAULT 1,
    entered_by                   NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_obs_ev_ent_by DEFAULT 'system',
    entered_dt                   DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_obs_ev_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by                   NVARCHAR(100) NULL,
    updated_dt                   DATETIME2 NULL,

    CONSTRAINT fk_pm_oa_obs_ev_obs
        FOREIGN KEY(org_assurance_observation_id)
        REFERENCES grac_practice.org_assurance_observation(org_assurance_observation_id),
    CONSTRAINT fk_pm_oa_obs_ev_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id)
);
GO

CREATE INDEX ix_pm_oa_obs_ev_obs
    ON grac_practice.org_assurance_observation_evidence(
        org_assurance_observation_id, is_active,
        org_assurance_observation_evidence_id DESC)
    WHERE is_active = 1;
GO

-- =====================================================================
-- 5. Observation history (lifecycle audit log)
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_observation_history','U') IS NULL
CREATE TABLE grac_practice.org_assurance_observation_history(
    org_assurance_observation_history_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_obs_history PRIMARY KEY,
    org_assurance_observation_id BIGINT NOT NULL,
    organization_id              BIGINT NOT NULL,
    action_code                  NVARCHAR(40)  NOT NULL,
    from_status_id               INT NULL,
    to_status_id                 INT NULL,
    reason_text                  NVARCHAR(1000) NULL,
    actor_display_name           NVARCHAR(240) NULL,
    entered_by                   NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_obs_hist_ent_by DEFAULT 'system',
    entered_dt                   DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_obs_hist_ent_dt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_pm_oa_obs_hist_obs
        FOREIGN KEY(org_assurance_observation_id)
        REFERENCES grac_practice.org_assurance_observation(org_assurance_observation_id),
    CONSTRAINT fk_pm_oa_obs_hist_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_obs_hist_from_status
        FOREIGN KEY(from_status_id)
        REFERENCES grac_practice.org_assurance_observation_status_master(org_assurance_observation_status_id),
    CONSTRAINT fk_pm_oa_obs_hist_to_status
        FOREIGN KEY(to_status_id)
        REFERENCES grac_practice.org_assurance_observation_status_master(org_assurance_observation_status_id)
);
GO

CREATE INDEX ix_pm_oa_obs_hist_obs
    ON grac_practice.org_assurance_observation_history(
        org_assurance_observation_id, entered_dt DESC);
GO

COMMIT TRAN;
GO

SELECT '5 observation severities seeded' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.org_assurance_observation_severity_master WHERE is_active = 1) = 5
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT '6 observation statuses seeded' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.org_assurance_observation_status_master WHERE is_active = 1) = 6
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_assurance_observation present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_observation','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_assurance_observation_evidence present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_observation_evidence','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_assurance_observation_history present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_observation_history','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '101 Organization Assurance Observation schema deployed.';
GO

SET NOEXEC OFF;
GO
