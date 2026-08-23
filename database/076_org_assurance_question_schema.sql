-- =====================================================================
-- 076 Organization Assurance (Phase 2) -- Stage 2 Question Builder
--
-- Business context (BRD Part 2 Sec 4):
--   * Reusable question sets are org-level artifacts (not tied to a
--     single assurance definition). A definition later ADOPTS one or
--     more sets when it is being configured.
--   * Questions belong to a set. Each question has:
--       code, text, help text, question type (from Admin), mandatory
--       flag, display order, weight, expected response.
--   * Questions may be LINKED to Practices / Requirements / Obligations
--     / Assets / Risks / Evidence Types so a resolver (Stage 3) can
--     later target the right questions for a given engagement.
--
-- Naming:
--   grac_practice.org_assurance_question_set
--   grac_practice.org_assurance_question
--   grac_practice.org_assurance_question_link
--
-- Rollback: 076_org_assurance_question_schema_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
   OR OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN
    RAISERROR('076: prerequisites missing (run 001).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Question Set
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_question_set','U') IS NULL
CREATE TABLE grac_practice.org_assurance_question_set(
    org_assurance_question_set_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_question_set PRIMARY KEY,
    organization_id     BIGINT       NOT NULL,
    set_code            NVARCHAR(80) NOT NULL,
    set_name            NVARCHAR(240) NOT NULL,
    description         NVARCHAR(MAX) NULL,
    owner_employee_id   BIGINT NULL,
    owner_display_name  NVARCHAR(240) NULL,
    status              NVARCHAR(30) NOT NULL
        CONSTRAINT df_pm_oa_qset_status DEFAULT N'Active',
    is_active           BIT NOT NULL
        CONSTRAINT df_pm_oa_qset_active DEFAULT 1,
    record_status_id    INT NOT NULL,
    entered_by          NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_qset_ent_by DEFAULT 'system',
    entered_dt          DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_qset_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by          NVARCHAR(100) NULL,
    updated_dt          DATETIME2 NULL,
    CONSTRAINT fk_pm_oa_qset_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_qset_record_status
        FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
    CONSTRAINT uq_pm_oa_qset_code UNIQUE(organization_id, set_code)
);
GO

CREATE INDEX ix_pm_oa_qset_org
    ON grac_practice.org_assurance_question_set(organization_id, is_active)
    WHERE is_active = 1;
GO

-- =====================================================================
-- 2. Question
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_question','U') IS NULL
CREATE TABLE grac_practice.org_assurance_question(
    org_assurance_question_id     BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_question PRIMARY KEY,
    org_assurance_question_set_id BIGINT NOT NULL,
    organization_id               BIGINT NOT NULL,
    question_code                 NVARCHAR(80)  NOT NULL,
    question_text                 NVARCHAR(MAX) NOT NULL,
    help_text                     NVARCHAR(MAX) NULL,
    -- Admin (grac_new) published question type. Soft reference; the
    -- denormalized code/name is captured at save-time so questions
    -- stay readable if the Admin row is later retired.
    question_type_id              BIGINT NULL,
    question_type_code            NVARCHAR(120) NULL,
    question_type_name            NVARCHAR(200) NULL,
    is_mandatory                  BIT NOT NULL
        CONSTRAINT df_pm_oa_question_mandatory DEFAULT 0,
    display_order                 INT NOT NULL
        CONSTRAINT df_pm_oa_question_order DEFAULT 0,
    weight                        DECIMAL(10,2) NULL,
    expected_response             NVARCHAR(MAX) NULL,
    is_active                     BIT NOT NULL
        CONSTRAINT df_pm_oa_question_active DEFAULT 1,
    record_status_id              INT NOT NULL,
    entered_by                    NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_question_ent_by DEFAULT 'system',
    entered_dt                    DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_question_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by                    NVARCHAR(100) NULL,
    updated_dt                    DATETIME2 NULL,
    CONSTRAINT fk_pm_oa_question_set
        FOREIGN KEY(org_assurance_question_set_id)
        REFERENCES grac_practice.org_assurance_question_set(org_assurance_question_set_id),
    CONSTRAINT fk_pm_oa_question_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_question_record_status
        FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
    CONSTRAINT uq_pm_oa_question_code
        UNIQUE(org_assurance_question_set_id, question_code)
);
GO

CREATE INDEX ix_pm_oa_question_set
    ON grac_practice.org_assurance_question(org_assurance_question_set_id, display_order, org_assurance_question_id)
    WHERE is_active = 1;
GO

-- =====================================================================
-- 3. Question Link (question -> Practice / Requirement / Obligation /
--    Asset / Risk / Evidence Type)
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_question_link','U') IS NULL
CREATE TABLE grac_practice.org_assurance_question_link(
    org_assurance_question_link_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_question_link PRIMARY KEY,
    org_assurance_question_id      BIGINT NOT NULL,
    organization_id                BIGINT NOT NULL,
    -- Free-text link type but constrained to the BRD set below.
    link_type                      NVARCHAR(40) NOT NULL,
    linked_entity_id               BIGINT NULL,
    linked_entity_code             NVARCHAR(120) NULL,
    linked_entity_name             NVARCHAR(240) NULL,
    is_active                      BIT NOT NULL
        CONSTRAINT df_pm_oa_qlink_active DEFAULT 1,
    entered_by                     NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_qlink_ent_by DEFAULT 'system',
    entered_dt                     DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_qlink_ent_dt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_pm_oa_qlink_question
        FOREIGN KEY(org_assurance_question_id)
        REFERENCES grac_practice.org_assurance_question(org_assurance_question_id),
    CONSTRAINT fk_pm_oa_qlink_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT ck_pm_oa_qlink_type CHECK (link_type IN (
        N'PRACTICE', N'REQUIREMENT', N'OBLIGATION',
        N'ASSET',    N'RISK',        N'EVIDENCE_TYPE'))
);
GO

CREATE INDEX ix_pm_oa_qlink_question
    ON grac_practice.org_assurance_question_link(org_assurance_question_id, is_active)
    WHERE is_active = 1;
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'org_assurance_question_set present'  AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_question_set','U') IS NOT NULL  THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_assurance_question present'      AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_question','U') IS NOT NULL      THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_assurance_question_link present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_question_link','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '076 Organization Assurance Question schema deployed.';
GO

SET NOEXEC OFF;
GO
