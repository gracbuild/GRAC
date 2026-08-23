-- =====================================================================
-- 083 Organization Assurance (Phase 2) -- Stage 2 Workflow Config
--
-- Business context (BRD Part 2 Sec 6):
--   Organizations customize workflow templates published by the
--   Authority Portal. Support auditor assignment / reviewer / approver
--   / escalation / SLA per stage. Store the org-customized copy
--   SEPARATELY from the Admin template -- never modify the template.
--
-- Naming:
--   grac_practice.org_assurance_workflow_config  (header per version)
--   grac_practice.org_assurance_workflow_stage   (stages within header)
--
-- Zero integration with the unrelated grac_practice.workflow /
-- workflow_stage engine from migrations 066/067 (kept intact).
--
-- Rollback: 083_org_assurance_workflow_schema_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.org_assurance_definition','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_definition_version','U') IS NULL
BEGIN
    RAISERROR('083: run 069 first (org_assurance_definition schema missing).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Header -- one row per definition version
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_workflow_config','U') IS NULL
CREATE TABLE grac_practice.org_assurance_workflow_config(
    org_assurance_workflow_config_id    BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_workflow_config PRIMARY KEY,
    org_assurance_definition_id         BIGINT NOT NULL,
    org_assurance_definition_version_id BIGINT NOT NULL,
    organization_id                     BIGINT NOT NULL,

    -- Admin (grac_new) workflow template soft reference.
    workflow_template_id                BIGINT NULL,
    workflow_template_code              NVARCHAR(120) NULL,
    workflow_template_name              NVARCHAR(200) NULL,

    -- Header fields
    workflow_name                       NVARCHAR(200) NULL,
    description                         NVARCHAR(MAX) NULL,
    total_sla_days                      INT NULL,

    is_active                           BIT NOT NULL
        CONSTRAINT df_pm_oa_wfcfg_active DEFAULT 1,
    record_status_id                    INT NOT NULL,
    entered_by                          NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_wfcfg_ent_by DEFAULT 'system',
    entered_dt                          DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_wfcfg_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by                          NVARCHAR(100) NULL,
    updated_dt                          DATETIME2 NULL,

    CONSTRAINT fk_pm_oa_wfcfg_definition
        FOREIGN KEY(org_assurance_definition_id)
        REFERENCES grac_practice.org_assurance_definition(org_assurance_definition_id),
    CONSTRAINT fk_pm_oa_wfcfg_version
        FOREIGN KEY(org_assurance_definition_version_id)
        REFERENCES grac_practice.org_assurance_definition_version(org_assurance_definition_version_id),
    CONSTRAINT fk_pm_oa_wfcfg_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_wfcfg_record_status
        FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
    CONSTRAINT uq_pm_oa_wfcfg_version UNIQUE(org_assurance_definition_version_id)
);
GO

CREATE INDEX ix_pm_oa_wfcfg_org
    ON grac_practice.org_assurance_workflow_config(organization_id, org_assurance_definition_id, is_active)
    WHERE is_active = 1;
GO

-- =====================================================================
-- 2. Stages
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_workflow_stage','U') IS NULL
CREATE TABLE grac_practice.org_assurance_workflow_stage(
    org_assurance_workflow_stage_id     BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_workflow_stage PRIMARY KEY,
    org_assurance_workflow_config_id    BIGINT NOT NULL,
    org_assurance_definition_version_id BIGINT NOT NULL,
    organization_id                     BIGINT NOT NULL,

    stage_order                         INT NOT NULL,
    stage_code                          NVARCHAR(60)  NOT NULL,
    stage_name                          NVARCHAR(200) NOT NULL,
    -- AUDITOR / REVIEWER / APPROVER / CUSTOM (see sp_..._stage_type_list)
    stage_type                          NVARCHAR(30)  NOT NULL,

    -- Role assignment (soft ref to grac_practice.organization_role).
    assigned_role_id                    BIGINT NULL,
    assigned_role_name                  NVARCHAR(200) NULL,

    -- Direct-employee assignment (soft ref to grac_practice.organization_employee).
    assigned_employee_id                BIGINT NULL,
    assigned_employee_name              NVARCHAR(240) NULL,

    sla_days                            INT NULL,

    -- Escalation
    escalation_role_id                  BIGINT NULL,
    escalation_role_name                NVARCHAR(200) NULL,
    escalation_after_days               INT NULL,

    instructions                        NVARCHAR(MAX) NULL,

    is_active                           BIT NOT NULL
        CONSTRAINT df_pm_oa_wfstg_active DEFAULT 1,
    entered_by                          NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_wfstg_ent_by DEFAULT 'system',
    entered_dt                          DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_wfstg_ent_dt DEFAULT SYSUTCDATETIME(),

    CONSTRAINT fk_pm_oa_wfstg_config
        FOREIGN KEY(org_assurance_workflow_config_id)
        REFERENCES grac_practice.org_assurance_workflow_config(org_assurance_workflow_config_id),
    CONSTRAINT fk_pm_oa_wfstg_version
        FOREIGN KEY(org_assurance_definition_version_id)
        REFERENCES grac_practice.org_assurance_definition_version(org_assurance_definition_version_id),
    CONSTRAINT fk_pm_oa_wfstg_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT ck_pm_oa_wfstg_type CHECK (
        stage_type IN (N'AUDITOR', N'REVIEWER', N'APPROVER', N'CUSTOM'))
);
GO

CREATE INDEX ix_pm_oa_wfstg_config
    ON grac_practice.org_assurance_workflow_stage(
        org_assurance_workflow_config_id, stage_order, org_assurance_workflow_stage_id)
    WHERE is_active = 1;
GO

COMMIT TRAN;
GO

SELECT 'org_assurance_workflow_config present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_workflow_config','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_assurance_workflow_stage present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_workflow_stage','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '083 Organization Assurance Workflow schema deployed.';
GO

SET NOEXEC OFF;
GO
