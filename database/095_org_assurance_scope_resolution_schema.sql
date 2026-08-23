-- =====================================================================
-- 095 Organization Assurance (Phase 2) -- Stage 3 Scope Resolution
--
-- Business context (BRD Part 2 Sec 3):
--   At execution time the scope defined for an assurance definition
--   version is resolved into applicable organization entities. Every
--   resolution is an IMMUTABLE SNAPSHOT so historical executions can
--   reference the exact entity list that ran.
--
-- Key BRD guarantees this schema honours:
--   * Operates within the logged-in organization
--   * Preserves a resolution snapshot for historical execution
--   * Avoids modifying the original scope definition
--   * Supports future scope dimensions without major redesign
--     (dimension_code is a soft NVARCHAR reference; adding a new
--      dimension just needs a resolver branch, not a schema change)
--
-- Tables:
--   grac_practice.org_assurance_scope_resolution         header
--   grac_practice.org_assurance_scope_resolution_entity  entity snapshot
--
-- Rollback: 095_org_assurance_scope_resolution_schema_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.org_assurance_definition','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_definition_version','U') IS NULL
BEGIN
    RAISERROR('095: run 069 first (org_assurance_definition schema missing).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Resolution header
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_scope_resolution','U') IS NULL
CREATE TABLE grac_practice.org_assurance_scope_resolution(
    org_assurance_scope_resolution_id   BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_scope_resolution PRIMARY KEY,
    org_assurance_definition_id         BIGINT NOT NULL,
    org_assurance_definition_version_id BIGINT NOT NULL,
    organization_id                     BIGINT NOT NULL,

    -- PREVIEW / EXECUTION -- an execution snapshot is created by the
    -- Stage 4 engine and linked back through execution_id (Stage 4
    -- populates this once the execution row exists).
    resolution_purpose                  NVARCHAR(30) NOT NULL,
    execution_id                        BIGINT NULL,

    resolved_at                         DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_scope_res_at DEFAULT SYSUTCDATETIME(),
    resolved_by                         NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_scope_res_by DEFAULT 'system',

    -- Summary counts + JSON summary (per dimension) so the UI can
    -- render totals without joining to the entity table.
    total_entity_count                  BIGINT NOT NULL
        CONSTRAINT df_pm_oa_scope_res_total DEFAULT 0,
    summary_json                        NVARCHAR(MAX) NULL,
    notes                               NVARCHAR(MAX) NULL,

    is_active                           BIT NOT NULL
        CONSTRAINT df_pm_oa_scope_res_active DEFAULT 1,
    record_status_id                    INT NOT NULL,

    CONSTRAINT fk_pm_oa_scope_res_definition
        FOREIGN KEY(org_assurance_definition_id)
        REFERENCES grac_practice.org_assurance_definition(org_assurance_definition_id),
    CONSTRAINT fk_pm_oa_scope_res_version
        FOREIGN KEY(org_assurance_definition_version_id)
        REFERENCES grac_practice.org_assurance_definition_version(org_assurance_definition_version_id),
    CONSTRAINT fk_pm_oa_scope_res_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_scope_res_record_status
        FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
    CONSTRAINT ck_pm_oa_scope_res_purpose CHECK (
        resolution_purpose IN (N'PREVIEW', N'EXECUTION'))
);
GO

CREATE INDEX ix_pm_oa_scope_res_version
    ON grac_practice.org_assurance_scope_resolution(
        org_assurance_definition_version_id, resolved_at DESC, org_assurance_scope_resolution_id);
GO

CREATE INDEX ix_pm_oa_scope_res_org
    ON grac_practice.org_assurance_scope_resolution(organization_id, is_active, resolved_at DESC)
    WHERE is_active = 1;
GO

-- =====================================================================
-- 2. Resolution entities (immutable snapshot)
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_scope_resolution_entity','U') IS NULL
CREATE TABLE grac_practice.org_assurance_scope_resolution_entity(
    org_assurance_scope_resolution_entity_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_scope_res_entity PRIMARY KEY,
    org_assurance_scope_resolution_id        BIGINT NOT NULL,
    organization_id                          BIGINT NOT NULL,

    -- Soft dimension reference (matches
    -- org_assurance_scope_dimension_master.dimension_code from 073).
    dimension_code                           NVARCHAR(60) NOT NULL,
    dimension_name                           NVARCHAR(160) NULL,

    -- Snapshot of the resolved entity. entity_id references a source
    -- PM table (e.g. practice_instance.practice_instance_id) but is
    -- deliberately NOT a hard FK -- the snapshot must remain readable
    -- even if the source row is later inactivated or renamed.
    entity_id                                BIGINT NULL,
    entity_code                              NVARCHAR(120) NULL,
    entity_name                              NVARCHAR(240) NULL,

    -- Traceability back to the scope rule that surfaced this entity.
    source_group_order                       INT NULL,
    source_condition_order                   INT NULL,

    entered_dt                               DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_scope_res_ent_dt DEFAULT SYSUTCDATETIME(),

    CONSTRAINT fk_pm_oa_scope_res_entity_res
        FOREIGN KEY(org_assurance_scope_resolution_id)
        REFERENCES grac_practice.org_assurance_scope_resolution(org_assurance_scope_resolution_id),
    CONSTRAINT fk_pm_oa_scope_res_entity_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id)
);
GO

CREATE INDEX ix_pm_oa_scope_res_entity_res
    ON grac_practice.org_assurance_scope_resolution_entity(
        org_assurance_scope_resolution_id, dimension_code, org_assurance_scope_resolution_entity_id);
GO

CREATE INDEX ix_pm_oa_scope_res_entity_dim
    ON grac_practice.org_assurance_scope_resolution_entity(
        org_assurance_scope_resolution_id, dimension_code, entity_id);
GO

COMMIT TRAN;
GO

SELECT 'org_assurance_scope_resolution present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_scope_resolution','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_assurance_scope_resolution_entity present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_scope_resolution_entity','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '095 Organization Assurance Scope Resolution schema deployed.';
GO

SET NOEXEC OFF;
GO
