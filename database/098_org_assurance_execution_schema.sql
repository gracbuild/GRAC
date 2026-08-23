-- =====================================================================
-- 098 Organization Assurance (Phase 2) -- Stage 3 Execution
--
-- Business context (BRD Part 2 Sec 9-10):
--   An Execution is a live instance of an Assurance Definition being
--   carried out over a resolved scope. Every execution is TRACEABLE and
--   AUDITABLE -- the definition config (questions / evidence config /
--   workflow config / scoring config) that was in force at the moment
--   of materialization is captured as an IMMUTABLE JSON SNAPSHOT on
--   the execution header. If the definition is later edited or a new
--   version is released, in-flight executions continue to operate on
--   the snapshot they were materialized from.
--
-- Origin (any of):
--   - Plan Item      (org_assurance_plan_item_id)
--   - Trigger        (org_assurance_trigger_config_id) -- future auto-materialize
--   - Manual         (both nullable)
--
-- Scope:
--   Each execution references an IMMUTABLE Scope Resolution snapshot
--   from migration 095 (org_assurance_scope_resolution). We also copy
--   the resolved entities into a dedicated per-execution table so the
--   execution remains readable even if the resolution snapshot is
--   later soft-deleted / archived.
--
-- Tables:
--   grac_practice.org_assurance_execution_status_master   lifecycle vocab
--   grac_practice.org_assurance_execution                 header
--   grac_practice.org_assurance_execution_entity          entity snapshot
--
-- Rollback: 098_org_assurance_execution_schema_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
   OR OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_definition','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_definition_version','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_scope_resolution','U') IS NULL
BEGIN
    RAISERROR('098: prerequisites missing (run 001 + 069 + 095).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Status master (lifecycle vocabulary)
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_execution_status_master','U') IS NULL
CREATE TABLE grac_practice.org_assurance_execution_status_master(
    org_assurance_execution_status_id INT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_exec_status PRIMARY KEY,
    status_code   NVARCHAR(60)  NOT NULL
        CONSTRAINT uq_pm_oa_exec_status_code UNIQUE,
    status_name   NVARCHAR(120) NOT NULL,
    display_order INT           NOT NULL CONSTRAINT df_pm_oa_exec_status_order    DEFAULT 0,
    is_terminal   BIT           NOT NULL CONSTRAINT df_pm_oa_exec_status_terminal DEFAULT 0,
    is_active     BIT           NOT NULL CONSTRAINT df_pm_oa_exec_status_active   DEFAULT 1,
    entered_by    NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_exec_status_ent_by   DEFAULT 'system',
    entered_dt    DATETIME2     NOT NULL CONSTRAINT df_pm_oa_exec_status_ent_dt   DEFAULT SYSUTCDATETIME(),
    updated_by    NVARCHAR(100) NULL,
    updated_dt    DATETIME2     NULL
);
GO

MERGE grac_practice.org_assurance_execution_status_master AS t
USING (VALUES
    (N'Planned',      N'Planned',       1, 0),
    (N'InProgress',   N'In Progress',   2, 0),
    (N'Submitted',    N'Submitted',     3, 0),
    (N'Reviewed',     N'Reviewed',      4, 0),
    (N'Approved',     N'Approved',      5, 0),
    (N'Closed',       N'Closed',        6, 1),
    (N'Cancelled',    N'Cancelled',     7, 1)
) AS src(status_code, status_name, display_order, is_terminal)
ON t.status_code = src.status_code
WHEN MATCHED THEN UPDATE SET
    status_name   = src.status_name,
    display_order = src.display_order,
    is_terminal   = src.is_terminal,
    is_active     = 1,
    updated_by    = 'seed-098',
    updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (status_code, status_name, display_order, is_terminal, is_active, entered_by)
VALUES
    (src.status_code, src.status_name, src.display_order, src.is_terminal, 1, 'seed-098');
GO

-- =====================================================================
-- 2. Execution header
--    Every business-relevant piece of the definition at the moment of
--    materialization is captured in JSON snapshot columns so the
--    execution can be interpreted historically without joining to
--    (mutable) config tables.
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_execution','U') IS NULL
CREATE TABLE grac_practice.org_assurance_execution(
    org_assurance_execution_id          BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_execution PRIMARY KEY,
    organization_id                     BIGINT NOT NULL,

    -- Definition + captured version (this version is the one whose
    -- config was snapshotted -- the SP validates it is Published /
    -- Approved / Active before materializing).
    org_assurance_definition_id         BIGINT NOT NULL,
    org_assurance_definition_version_id BIGINT NOT NULL,

    -- Denormalized identifiers -- render lists without joins.
    definition_code                     NVARCHAR(80)  NOT NULL,
    definition_name                     NVARCHAR(240) NOT NULL,
    version_number                      INT           NOT NULL,

    -- Execution identifiers.
    execution_code                      NVARCHAR(120) NOT NULL,
    execution_name                      NVARCHAR(300) NOT NULL,
    execution_status_id                 INT           NOT NULL,

    -- Origin (all nullable -- manual materialize needs no origin).
    origin_type                         NVARCHAR(20)  NOT NULL,
    org_assurance_plan_id               BIGINT NULL,
    org_assurance_plan_item_id          BIGINT NULL,
    org_assurance_trigger_config_id     BIGINT NULL,

    -- Immutable scope reference. NOT a hard FK on delete -- the
    -- resolution snapshot may later be soft-deleted, but the copied
    -- entities in org_assurance_execution_entity guarantee the
    -- execution remains readable.
    org_assurance_scope_resolution_id   BIGINT NOT NULL,

    -- Immutable definition config snapshot -- captured at materialize
    -- time from the current version's Questions / Evidence /
    -- Workflow / Scoring config. Persisted as JSON so future config
    -- schema changes cannot break historical executions.
    definition_snapshot_json            NVARCHAR(MAX) NULL,
    questions_snapshot_json             NVARCHAR(MAX) NULL,
    evidence_snapshot_json              NVARCHAR(MAX) NULL,
    workflow_snapshot_json              NVARCHAR(MAX) NULL,
    scoring_snapshot_json               NVARCHAR(MAX) NULL,

    -- Ownership + assignment (soft references).
    owner_employee_id                   BIGINT NULL,
    owner_display_name                  NVARCHAR(240) NULL,
    assigned_team_name                  NVARCHAR(200) NULL,

    -- Schedule.
    planned_start_dt                    DATE NULL,
    planned_end_dt                      DATE NULL,
    actual_start_dt                     DATETIME2 NULL,
    actual_end_dt                       DATETIME2 NULL,

    -- Progress rollup (kept fresh on entity-status changes in Stage 4).
    total_entity_count                  BIGINT NOT NULL
        CONSTRAINT df_pm_oa_exec_total    DEFAULT 0,
    completed_entity_count              BIGINT NOT NULL
        CONSTRAINT df_pm_oa_exec_complete DEFAULT 0,

    notes                               NVARCHAR(MAX) NULL,

    is_active                           BIT NOT NULL
        CONSTRAINT df_pm_oa_exec_active DEFAULT 1,
    record_status_id                    INT NOT NULL,
    entered_by                          NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_exec_ent_by DEFAULT 'system',
    entered_dt                          DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_exec_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by                          NVARCHAR(100) NULL,
    updated_dt                          DATETIME2 NULL,

    CONSTRAINT fk_pm_oa_exec_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_exec_definition
        FOREIGN KEY(org_assurance_definition_id)
        REFERENCES grac_practice.org_assurance_definition(org_assurance_definition_id),
    CONSTRAINT fk_pm_oa_exec_version
        FOREIGN KEY(org_assurance_definition_version_id)
        REFERENCES grac_practice.org_assurance_definition_version(org_assurance_definition_version_id),
    CONSTRAINT fk_pm_oa_exec_status
        FOREIGN KEY(execution_status_id)
        REFERENCES grac_practice.org_assurance_execution_status_master(org_assurance_execution_status_id),
    CONSTRAINT fk_pm_oa_exec_record_status
        FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
    CONSTRAINT ck_pm_oa_exec_origin CHECK (
        origin_type IN (N'MANUAL', N'PLAN', N'TRIGGER')),
    CONSTRAINT ck_pm_oa_exec_dates CHECK (
        planned_start_dt IS NULL OR planned_end_dt IS NULL
            OR planned_end_dt >= planned_start_dt),
    CONSTRAINT uq_pm_oa_exec_code UNIQUE(organization_id, execution_code)
);
GO

CREATE INDEX ix_pm_oa_exec_org
    ON grac_practice.org_assurance_execution(
        organization_id, is_active, execution_status_id,
        planned_start_dt DESC, org_assurance_execution_id DESC)
    WHERE is_active = 1;
GO

CREATE INDEX ix_pm_oa_exec_definition
    ON grac_practice.org_assurance_execution(
        org_assurance_definition_id, org_assurance_execution_id DESC)
    WHERE is_active = 1;
GO

CREATE INDEX ix_pm_oa_exec_scope_res
    ON grac_practice.org_assurance_execution(
        org_assurance_scope_resolution_id)
    WHERE is_active = 1;
GO

-- =====================================================================
-- 3. Execution entities (per-entity working row, snapshotted from
--    the resolution). Per-entity execution status supports partial
--    completion tracking (Stage 4 fills in evidence + question answers).
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_execution_entity','U') IS NULL
CREATE TABLE grac_practice.org_assurance_execution_entity(
    org_assurance_execution_entity_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_exec_entity PRIMARY KEY,
    org_assurance_execution_id        BIGINT NOT NULL,
    organization_id                   BIGINT NOT NULL,

    -- Snapshot copy of the scope resolution entity (see 095).
    dimension_code                    NVARCHAR(60)  NOT NULL,
    dimension_name                    NVARCHAR(160) NULL,
    entity_id                         BIGINT NULL,
    entity_code                       NVARCHAR(120) NULL,
    entity_name                       NVARCHAR(240) NULL,

    -- Traceability back to the scope rule that surfaced this entity.
    source_group_order                INT NULL,
    source_condition_order            INT NULL,

    -- Per-entity execution status (Stage 4 will use these -- keeping
    -- them free-text at the snapshot table level so a code-only
    -- addition later doesn't need a schema change).
    entity_status_code                NVARCHAR(30) NOT NULL
        CONSTRAINT df_pm_oa_exec_entity_status DEFAULT N'NotStarted',
    started_dt                        DATETIME2 NULL,
    completed_dt                      DATETIME2 NULL,
    assigned_auditor_employee_id      BIGINT NULL,
    assigned_auditor_name             NVARCHAR(240) NULL,

    is_active                         BIT NOT NULL
        CONSTRAINT df_pm_oa_exec_entity_active DEFAULT 1,
    entered_by                        NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_exec_entity_ent_by DEFAULT 'system',
    entered_dt                        DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_exec_entity_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by                        NVARCHAR(100) NULL,
    updated_dt                        DATETIME2 NULL,

    CONSTRAINT fk_pm_oa_exec_entity_exec
        FOREIGN KEY(org_assurance_execution_id)
        REFERENCES grac_practice.org_assurance_execution(org_assurance_execution_id),
    CONSTRAINT fk_pm_oa_exec_entity_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT ck_pm_oa_exec_entity_status CHECK (
        entity_status_code IN (N'NotStarted', N'InProgress', N'Done', N'Skipped'))
);
GO

CREATE INDEX ix_pm_oa_exec_entity_exec
    ON grac_practice.org_assurance_execution_entity(
        org_assurance_execution_id, dimension_code, entity_status_code,
        org_assurance_execution_entity_id)
    WHERE is_active = 1;
GO

CREATE INDEX ix_pm_oa_exec_entity_org
    ON grac_practice.org_assurance_execution_entity(
        organization_id, org_assurance_execution_id, is_active)
    WHERE is_active = 1;
GO

COMMIT TRAN;
GO

SELECT '7 execution statuses seeded' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.org_assurance_execution_status_master WHERE is_active = 1) = 7
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_assurance_execution present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_execution','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_assurance_execution_entity present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_execution_entity','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '098 Organization Assurance Execution schema deployed.';
GO

SET NOEXEC OFF;
GO
