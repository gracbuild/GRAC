-- =====================================================================
-- 277 Audit -> Question Set link (Phase 2)
--
-- THE GAP THIS CLOSES
--   org_assurance_question_set (076) is organization-scoped: it has no
--   definition FK, and org_assurance_question_link only ties a QUESTION
--   to a PRACTICE / REQUIREMENT / OBLIGATION / ASSET / RISK /
--   EVIDENCE_TYPE -- never to an assurance definition. So "Question Sets"
--   could not inherit the audit chosen in the Audit Definition flow.
--
--   This table is that missing edge: which question sets a given audit
--   VERSION asks. Question sets stay reusable across audits -- this is a
--   many-to-many adoption, not ownership. Nothing in 076 changes and no
--   existing question set or question row is touched.
--
-- VERSION-SCOPED, LIKE EVERY OTHER CONFIG
--   Keyed on (org_assurance_definition_id,
--   org_assurance_definition_version_id) exactly as evidence (079),
--   workflow (083), scoring (086) and trigger (092) config are, so a new
--   version can adopt a different set of question sets without
--   rewriting history.
--
-- Re-runnable: yes -- guarded by OBJECT_ID checks.
-- Rollback: database/277_org_assurance_definition_question_set_schema_rollback.sql
-- DEPENDS ON: 069 (definition + version), 076 (question_set),
--             272 (record_status_master).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (277): schema grac_practice missing.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.org_assurance_definition','U') IS NULL
BEGIN PRINT 'ABORT (277): org_assurance_definition missing. Run 069 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.org_assurance_definition_version','U') IS NULL
BEGIN PRINT 'ABORT (277): org_assurance_definition_version missing. Run 069 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.org_assurance_question_set','U') IS NULL
BEGIN PRINT 'ABORT (277): org_assurance_question_set missing. Run 076 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('277_org_assurance_definition_question_set_schema: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

IF OBJECT_ID('grac_practice.org_assurance_definition_question_set','U') IS NULL
CREATE TABLE grac_practice.org_assurance_definition_question_set(
    org_assurance_definition_question_set_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_def_qset PRIMARY KEY,

    org_assurance_definition_id         BIGINT NOT NULL,
    org_assurance_definition_version_id BIGINT NOT NULL,
    -- Denormalized for org isolation on reads, matching every other
    -- org_assurance_* config table.
    organization_id                     BIGINT NOT NULL,
    org_assurance_question_set_id       BIGINT NOT NULL,

    -- Order the sets are asked in during execution.
    display_order                       INT NOT NULL
        CONSTRAINT df_pm_oa_def_qset_order DEFAULT 0,
    -- A set can be adopted as optional (for example a supplementary
    -- questionnaire that only some auditors complete).
    is_mandatory                        BIT NOT NULL
        CONSTRAINT df_pm_oa_def_qset_mandatory DEFAULT 1,

    is_active                           BIT NOT NULL
        CONSTRAINT df_pm_oa_def_qset_active DEFAULT 1,
    record_status_id                    INT NOT NULL,
    entered_by                          NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_def_qset_ent_by DEFAULT 'system',
    entered_dt                          DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_def_qset_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by                          NVARCHAR(100) NULL,
    updated_dt                          DATETIME2 NULL,

    CONSTRAINT fk_pm_oa_def_qset_def
        FOREIGN KEY(org_assurance_definition_id)
        REFERENCES grac_practice.org_assurance_definition(org_assurance_definition_id),
    CONSTRAINT fk_pm_oa_def_qset_version
        FOREIGN KEY(org_assurance_definition_version_id)
        REFERENCES grac_practice.org_assurance_definition_version(org_assurance_definition_version_id),
    CONSTRAINT fk_pm_oa_def_qset_org
        FOREIGN KEY(organization_id)
        REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_def_qset_qset
        FOREIGN KEY(org_assurance_question_set_id)
        REFERENCES grac_practice.org_assurance_question_set(org_assurance_question_set_id)
);
GO

-- One adoption per (version, question set). The save proc replaces the
-- whole set for a version, but the constraint keeps a hand-written
-- INSERT honest too.
IF OBJECT_ID('grac_practice.org_assurance_definition_question_set','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'uq_pm_oa_def_qset_version_set'
                      AND object_id = OBJECT_ID('grac_practice.org_assurance_definition_question_set'))
CREATE UNIQUE INDEX uq_pm_oa_def_qset_version_set
    ON grac_practice.org_assurance_definition_question_set(
        org_assurance_definition_version_id, org_assurance_question_set_id);
GO

IF OBJECT_ID('grac_practice.org_assurance_definition_question_set','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'ix_pm_oa_def_qset_version'
                      AND object_id = OBJECT_ID('grac_practice.org_assurance_definition_question_set'))
CREATE INDEX ix_pm_oa_def_qset_version
    ON grac_practice.org_assurance_definition_question_set(
        org_assurance_definition_version_id, organization_id, is_active)
    INCLUDE (org_assurance_question_set_id, display_order, is_mandatory);
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'org_assurance_definition_question_set present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_definition_question_set','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'unique (version, question set)' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uq_pm_oa_def_qset_version_set')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'existing question sets untouched' AS Check_,
       CAST((SELECT COUNT(*) FROM grac_practice.org_assurance_question_set) AS NVARCHAR(20))
       + ' question set row(s) still present' AS Result;

PRINT '277 Audit -> Question Set link schema complete.';
GO
SET NOEXEC OFF;
GO
