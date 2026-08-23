-- =====================================================================
-- 079 Organization Assurance (Phase 2) -- Stage 2 Evidence Config
--
-- Business context (BRD Part 2 Sec 5):
--   Configure per-assurance-definition evidence expectations:
--     Mandatory / Optional (flag)
--     Existing Practice Evidence / API Retrieved / Manual Upload (method)
--     Evidence Validity + Expiry Warning
--   Config is tied to a definition VERSION so historical executions
--   (Stage 3) can snapshot the exact evidence config that ran.
--
-- Reuses the existing Practice Management masters:
--   grac_practice.evidence_type_master     (evidence_type_id, code, name)
--   grac_practice.collection_method_master (collection_method_id, code, name)
-- via soft references + denormalized code/name.
--
-- Rollback: 079_org_assurance_evidence_schema_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.org_assurance_definition','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_definition_version','U') IS NULL
BEGIN
    RAISERROR('079: run 069 first (org_assurance_definition schema missing).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- org_assurance_evidence_config
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_evidence_config','U') IS NULL
CREATE TABLE grac_practice.org_assurance_evidence_config(
    org_assurance_evidence_config_id    BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_evidence_config PRIMARY KEY,
    org_assurance_definition_id         BIGINT NOT NULL,
    org_assurance_definition_version_id BIGINT NOT NULL,
    organization_id                     BIGINT NOT NULL,

    -- Evidence type (soft ref to grac_practice.evidence_type_master).
    -- Denormalized code / name preserved so config stays readable if
    -- the master row is later inactivated.
    evidence_type_id                    INT NULL,
    evidence_type_code                  NVARCHAR(60) NULL,
    evidence_type_name                  NVARCHAR(200) NULL,

    -- Collection method (soft ref to grac_practice.collection_method_master).
    collection_method_id                INT NULL,
    collection_method_code              NVARCHAR(60) NULL,
    collection_method_name              NVARCHAR(200) NULL,

    -- Config fields
    evidence_label                      NVARCHAR(240) NOT NULL,
    description                         NVARCHAR(MAX) NULL,
    is_mandatory                        BIT NOT NULL
        CONSTRAINT df_pm_oa_evidence_mandatory DEFAULT 0,
    validity_days                       INT NULL,
    expiry_warning_days                 INT NULL,
    display_order                       INT NOT NULL
        CONSTRAINT df_pm_oa_evidence_order DEFAULT 0,

    is_active                           BIT NOT NULL
        CONSTRAINT df_pm_oa_evidence_active DEFAULT 1,
    record_status_id                    INT NOT NULL,
    entered_by                          NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_evidence_ent_by DEFAULT 'system',
    entered_dt                          DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_evidence_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by                          NVARCHAR(100) NULL,
    updated_dt                          DATETIME2 NULL,

    CONSTRAINT fk_pm_oa_evidence_definition
        FOREIGN KEY(org_assurance_definition_id)
        REFERENCES grac_practice.org_assurance_definition(org_assurance_definition_id),
    CONSTRAINT fk_pm_oa_evidence_version
        FOREIGN KEY(org_assurance_definition_version_id)
        REFERENCES grac_practice.org_assurance_definition_version(org_assurance_definition_version_id),
    CONSTRAINT fk_pm_oa_evidence_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_evidence_record_status
        FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id)
);
GO

CREATE INDEX ix_pm_oa_evidence_version
    ON grac_practice.org_assurance_evidence_config(
        org_assurance_definition_version_id, display_order, org_assurance_evidence_config_id)
    WHERE is_active = 1;
GO

CREATE INDEX ix_pm_oa_evidence_org
    ON grac_practice.org_assurance_evidence_config(
        organization_id, org_assurance_definition_id, is_active)
    WHERE is_active = 1;
GO

COMMIT TRAN;
GO

SELECT 'org_assurance_evidence_config present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_evidence_config','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '079 Organization Assurance Evidence schema deployed.';
GO

SET NOEXEC OFF;
GO
