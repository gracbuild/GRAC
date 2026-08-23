-- =====================================================================
-- 086 Organization Assurance (Phase 2) -- Stage 2 Scoring Config
--
-- Business context (BRD Part 2 Sec 7):
--   Organizations select or customize scoring models. Support:
--     Pass / Fail, Weighted, Risk Based, Maturity Based,
--     Percentage, Custom.
--
--   BRD security rule: "Do not execute unsafe dynamic SQL, scripts, or
--   arbitrary executable code from user-entered formulas. Use a
--   controlled and validated scoring-rule representation." -- so this
--   schema captures a STRUCTURED representation only (bands + numeric
--   thresholds). A Stage 3 evaluator will interpret bands to produce
--   the final score; no runtime evaluation of user text.
--
-- Tables:
--   grac_practice.org_assurance_scoring_config  (header per version)
--   grac_practice.org_assurance_scoring_band    (score-range bands)
--
-- Rollback: 086_org_assurance_scoring_schema_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.org_assurance_definition','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_definition_version','U') IS NULL
BEGIN
    RAISERROR('086: run 069 first (org_assurance_definition schema missing).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Header -- one row per definition version
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_scoring_config','U') IS NULL
CREATE TABLE grac_practice.org_assurance_scoring_config(
    org_assurance_scoring_config_id     BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_scoring_config PRIMARY KEY,
    org_assurance_definition_id         BIGINT NOT NULL,
    org_assurance_definition_version_id BIGINT NOT NULL,
    organization_id                     BIGINT NOT NULL,

    -- Admin (grac_new) scoring model soft reference.
    scoring_model_id                    BIGINT NULL,
    scoring_model_code                  NVARCHAR(120) NULL,
    scoring_model_name                  NVARCHAR(200) NULL,

    -- Model type -- controlled vocabulary; see sp_..._scoring_model_type_list.
    scoring_model_type                  NVARCHAR(30) NOT NULL
        CONSTRAINT df_pm_oa_scoring_type DEFAULT N'PASS_FAIL',

    -- Numeric thresholds. Meaning varies by model type but the SP layer
    -- normalizes their interpretation.
    max_score                           DECIMAL(10,2) NULL,
    pass_threshold                      DECIMAL(10,2) NULL,
    warning_threshold                   DECIMAL(10,2) NULL,
    fail_threshold                      DECIMAL(10,2) NULL,

    description                         NVARCHAR(MAX) NULL,

    is_active                           BIT NOT NULL
        CONSTRAINT df_pm_oa_scoring_active DEFAULT 1,
    record_status_id                    INT NOT NULL,
    entered_by                          NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_scoring_ent_by DEFAULT 'system',
    entered_dt                          DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_scoring_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by                          NVARCHAR(100) NULL,
    updated_dt                          DATETIME2 NULL,

    CONSTRAINT fk_pm_oa_scoring_definition
        FOREIGN KEY(org_assurance_definition_id)
        REFERENCES grac_practice.org_assurance_definition(org_assurance_definition_id),
    CONSTRAINT fk_pm_oa_scoring_version
        FOREIGN KEY(org_assurance_definition_version_id)
        REFERENCES grac_practice.org_assurance_definition_version(org_assurance_definition_version_id),
    CONSTRAINT fk_pm_oa_scoring_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_scoring_record_status
        FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
    CONSTRAINT ck_pm_oa_scoring_type CHECK (scoring_model_type IN (
        N'PASS_FAIL', N'WEIGHTED', N'RISK_BASED',
        N'MATURITY_BASED', N'PERCENTAGE', N'CUSTOM')),
    CONSTRAINT uq_pm_oa_scoring_version UNIQUE(org_assurance_definition_version_id)
);
GO

CREATE INDEX ix_pm_oa_scoring_org
    ON grac_practice.org_assurance_scoring_config(organization_id, org_assurance_definition_id, is_active)
    WHERE is_active = 1;
GO

-- =====================================================================
-- 2. Bands (for MATURITY_BASED / RISK_BASED / PERCENTAGE)
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_scoring_band','U') IS NULL
CREATE TABLE grac_practice.org_assurance_scoring_band(
    org_assurance_scoring_band_id       BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_scoring_band PRIMARY KEY,
    org_assurance_scoring_config_id     BIGINT NOT NULL,
    org_assurance_definition_version_id BIGINT NOT NULL,
    organization_id                     BIGINT NOT NULL,

    band_order                          INT NOT NULL,
    band_code                           NVARCHAR(60)  NOT NULL,
    band_name                           NVARCHAR(160) NOT NULL,
    min_score                           DECIMAL(10,2) NOT NULL,
    max_score                           DECIMAL(10,2) NOT NULL,
    -- Semantic (Pass / Warning / Fail) that a Stage-3 evaluator can
    -- honour. Optional -- band naming alone is fine for UI display.
    outcome_code                        NVARCHAR(30)  NULL,
    color_hex                           NVARCHAR(20)  NULL,
    description                         NVARCHAR(MAX) NULL,

    is_active                           BIT NOT NULL
        CONSTRAINT df_pm_oa_scoring_band_active DEFAULT 1,
    entered_by                          NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_scoring_band_ent_by DEFAULT 'system',
    entered_dt                          DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_scoring_band_ent_dt DEFAULT SYSUTCDATETIME(),

    CONSTRAINT fk_pm_oa_scoring_band_config
        FOREIGN KEY(org_assurance_scoring_config_id)
        REFERENCES grac_practice.org_assurance_scoring_config(org_assurance_scoring_config_id),
    CONSTRAINT fk_pm_oa_scoring_band_version
        FOREIGN KEY(org_assurance_definition_version_id)
        REFERENCES grac_practice.org_assurance_definition_version(org_assurance_definition_version_id),
    CONSTRAINT fk_pm_oa_scoring_band_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT ck_pm_oa_scoring_band_outcome
        CHECK (outcome_code IS NULL OR outcome_code IN (N'PASS', N'WARNING', N'FAIL')),
    CONSTRAINT ck_pm_oa_scoring_band_range
        CHECK (max_score >= min_score)
);
GO

CREATE INDEX ix_pm_oa_scoring_band_config
    ON grac_practice.org_assurance_scoring_band(
        org_assurance_scoring_config_id, band_order, org_assurance_scoring_band_id)
    WHERE is_active = 1;
GO

COMMIT TRAN;
GO

SELECT 'org_assurance_scoring_config present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_scoring_config','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_assurance_scoring_band present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_scoring_band','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '086 Organization Assurance Scoring schema deployed.';
GO

SET NOEXEC OFF;
GO
