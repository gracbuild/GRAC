-- =====================================================================
-- 560  Audit Definition refinements (Audit Change spec 4.1, P0 phase A)
--
-- REQUEST (2026-11-15, sir): rewrite the audit module by the Audit Change
--   document (Consolidated Functional Change Specification), in P0 phases.
--   Phase A = 4.1 Audit Definition. The definition gains:
--     * Assurance Approach -- HOW the audit is conducted, a master kept
--       apart from Audit Category (WHAT kind of audit): Risk-Based,
--       Periodic, Continuous, Event-Driven, Thematic, Ad-hoc;
--     * Audit Mandate -- WHY the audit is required: one or more bases from
--       a master (sir, 2026-11-15: a multi-select, these 14 values):
--       REG Regulatory Requirement, STAT Statutory Requirement, BOARD
--       Board-Directed, AC Audit Committee-Directed, RC Risk Committee-
--       Directed, CHARTER Internal Audit Charter, POLICY Internal Policy /
--       Governance Requirement, MGMT Management-Directed, CONTRACT
--       Contractual / Agreement Requirement, FRAMEWORK Framework /
--       Certification Requirement, INCIDENT Incident / Event-Driven
--       Mandate, INVEST Special Investigation / Vigilance, EXTERNAL External
--       Authority / Supervisory Direction, OTHER Other;
--     * Applicable Frameworks -- the frameworks / standards the audit
--       evaluates against: any of the organization's subscribed frameworks
--       (the Practice picker's list), plus frameworks typed by hand for an
--       organization without subscriptions (standalone use, spec 7).
--   Associated risks are NOT stored on the definition (spec 4.1); they come
--   in at planning / scope.
--
-- WHAT THIS DOES
--   1. NEW org_assurance_approach_master, seeded with the six approaches,
--      and NEW org_assurance_mandate_master, seeded with the 14 mandates
--      (a code no longer in the list is made inactive).
--   2. org_assurance_definition_version gains assurance_approach_id / _code
--      / _name (the id, and the code + name as of the save, as for the
--      category). The free-text audit_mandate column of the first 560 cut
--      is dropped when empty.
--   3a. NEW org_assurance_definition_mandate -- one row per mandate per
--      definition VERSION (mandate id, and its code + name as saved).
--   3. NEW org_assurance_definition_framework -- one row per framework per
--      definition VERSION (release_id when it is a subscribed framework,
--      NULL when typed; framework_name always). Versioned with the
--      definition: a new version carries the list (copy_config), and a
--      changed list on a later version never alters an approved one.
--   4. NEW sp_org_assurance_approach_list and sp_org_assurance_mandate_list
--      -- the active rows, in order.
--   5. sp_org_assurance_definition_save (551 body) -- @assurance_approach_id,
--      @audit_mandate_ids_json ([1, 4, ...]) and @applicable_frameworks_json
--      (for each list: NULL = leave it as it is; '[]' = clear it).
--   6. sp_org_assurance_definition_get (119 body) -- the approach, a SECOND
--      result set (the current version's frameworks) and a THIRD (its
--      mandates).
--   7. sp_org_assurance_definition_version_copy_config (551 body) -- also
--      copies the frameworks and mandates, so a version made by a Question
--      Set approval (551) keeps them. The approach is a column of the
--      version row, which 551 copies whole.
--
-- ERRORS: 53613 approach not found or inactive; 53614 framework list is
--   not valid JSON; 53615 a mandate not found or inactive, or the mandate
--   list not valid JSON.
-- DEPENDS ON: 551 (definition save / copy_config bodies), 119 (get body),
--   282 (sp_practice_picker_frameworks -- the subscribed framework list the
--   page offers; not called here).
-- Rollback: 560_audit_definition_fields_rollback.sql (procedures back to
--   551 / 119, the approach list dropped; tables and columns kept, so no
--   saved data is lost). Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_definition_version_copy_config','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_assurance_clone_rows','P') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_definition_version','assurance_category_name') IS NULL
BEGIN
    PRINT 'ABORT (560): run 551 first. Nothing was changed.';
    RAISERROR('560_audit_definition_fields: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Assurance Approach master
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.org_assurance_approach_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_approach_master (
        assurance_approach_id BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_org_assurance_approach_master PRIMARY KEY,
        approach_code   NVARCHAR(60)  NOT NULL
            CONSTRAINT UQ_org_assurance_approach_master_code UNIQUE,
        approach_name   NVARCHAR(120) NOT NULL,
        description     NVARCHAR(400) NULL,
        display_order   INT           NOT NULL CONSTRAINT DF_org_assurance_approach_master_order  DEFAULT (0),
        is_active       BIT           NOT NULL CONSTRAINT DF_org_assurance_approach_master_active DEFAULT (1),
        entered_by      NVARCHAR(100) NOT NULL CONSTRAINT DF_org_assurance_approach_master_eby    DEFAULT (N'system'),
        entered_dt      DATETIME2     NOT NULL CONSTRAINT DF_org_assurance_approach_master_edt    DEFAULT (SYSUTCDATETIME()),
        updated_by      NVARCHAR(100) NULL,
        updated_dt      DATETIME2     NULL
    );
    PRINT '560: org_assurance_approach_master created.';
END
GO

MERGE grac_practice.org_assurance_approach_master AS t
USING (VALUES
    (N'RISK_BASED',   N'Risk-Based',   N'Audit scope and frequency driven by assessed risk.', 1),
    (N'PERIODIC',     N'Periodic',     N'Audit performed on a fixed cycle.', 2),
    (N'CONTINUOUS',   N'Continuous',   N'Ongoing or automated assurance monitoring.', 3),
    (N'EVENT_DRIVEN', N'Event-Driven', N'Audit started by an event, incident or trigger.', 4),
    (N'THEMATIC',     N'Thematic',     N'Audit of one theme across units, processes or locations.', 5),
    (N'AD_HOC',       N'Ad-hoc',       N'One-off audit outside the regular cycle.', 6)
) AS s (approach_code, approach_name, description, display_order)
ON t.approach_code = s.approach_code
WHEN NOT MATCHED THEN
    INSERT (approach_code, approach_name, description, display_order, is_active, entered_by)
    VALUES (s.approach_code, s.approach_name, s.description, s.display_order, 1, N'560_audit_definition_fields');
GO

-- Audit Mandate master (the basis of the audit)
IF OBJECT_ID('grac_practice.org_assurance_mandate_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_mandate_master (
        audit_mandate_id BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_org_assurance_mandate_master PRIMARY KEY,
        mandate_code    NVARCHAR(60)  NOT NULL
            CONSTRAINT UQ_org_assurance_mandate_master_code UNIQUE,
        mandate_name    NVARCHAR(120) NOT NULL,
        description     NVARCHAR(400) NULL,
        display_order   INT           NOT NULL CONSTRAINT DF_org_assurance_mandate_master_order  DEFAULT (0),
        is_active       BIT           NOT NULL CONSTRAINT DF_org_assurance_mandate_master_active DEFAULT (1),
        entered_by      NVARCHAR(100) NOT NULL CONSTRAINT DF_org_assurance_mandate_master_eby    DEFAULT (N'system'),
        entered_dt      DATETIME2     NOT NULL CONSTRAINT DF_org_assurance_mandate_master_edt    DEFAULT (SYSUTCDATETIME()),
        updated_by      NVARCHAR(100) NULL,
        updated_dt      DATETIME2     NULL
    );
    PRINT '560: org_assurance_mandate_master created.';
END
GO

MERGE grac_practice.org_assurance_mandate_master AS t
USING (VALUES
    (N'REG',       N'Regulatory Requirement',                    1),
    (N'STAT',      N'Statutory Requirement',                     2),
    (N'BOARD',     N'Board-Directed',                            3),
    (N'AC',        N'Audit Committee-Directed',                  4),
    (N'RC',        N'Risk Committee-Directed',                   5),
    (N'CHARTER',   N'Internal Audit Charter',                    6),
    (N'POLICY',    N'Internal Policy / Governance Requirement',  7),
    (N'MGMT',      N'Management-Directed',                       8),
    (N'CONTRACT',  N'Contractual / Agreement Requirement',       9),
    (N'FRAMEWORK', N'Framework / Certification Requirement',    10),
    (N'INCIDENT',  N'Incident / Event-Driven Mandate',          11),
    (N'INVEST',    N'Special Investigation / Vigilance',        12),
    (N'EXTERNAL',  N'External Authority / Supervisory Direction', 13),
    (N'OTHER',     N'Other',                                    14)
) AS s (mandate_code, mandate_name, display_order)
ON t.mandate_code = s.mandate_code
WHEN MATCHED THEN
    UPDATE SET mandate_name = s.mandate_name, display_order = s.display_order, is_active = 1,
               updated_by = N'560_audit_definition_fields', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (mandate_code, mandate_name, display_order, is_active, entered_by)
    VALUES (s.mandate_code, s.mandate_name, s.display_order, 1, N'560_audit_definition_fields')
WHEN NOT MATCHED BY SOURCE THEN
    UPDATE SET is_active = 0, updated_by = N'560_audit_definition_fields', updated_dt = SYSUTCDATETIME();
GO

-- ---------------------------------------------------------------------
-- 2. Definition version columns
-- ---------------------------------------------------------------------
IF COL_LENGTH('grac_practice.org_assurance_definition_version','assurance_approach_id') IS NULL
    ALTER TABLE grac_practice.org_assurance_definition_version ADD assurance_approach_id BIGINT NULL;
IF COL_LENGTH('grac_practice.org_assurance_definition_version','assurance_approach_code') IS NULL
    ALTER TABLE grac_practice.org_assurance_definition_version ADD assurance_approach_code NVARCHAR(60) NULL;
IF COL_LENGTH('grac_practice.org_assurance_definition_version','assurance_approach_name') IS NULL
    ALTER TABLE grac_practice.org_assurance_definition_version ADD assurance_approach_name NVARCHAR(120) NULL;
-- The first 560 cut had a free-text audit_mandate; the mandate is now a
-- dropdown. The column is dropped only while it holds no text.
-- (dynamic SQL: a batch naming a column that is not there does not compile)
IF COL_LENGTH('grac_practice.org_assurance_definition_version','audit_mandate') IS NOT NULL
    EXEC (N'
        IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_definition_version
                   WHERE NULLIF(LTRIM(RTRIM(CAST(audit_mandate AS NVARCHAR(4000)))), N'''') IS NOT NULL)
            PRINT ''560: audit_mandate (free text) holds values -- kept; it is no longer used.'';
        ELSE
            ALTER TABLE grac_practice.org_assurance_definition_version DROP COLUMN audit_mandate;');
GO

IF OBJECT_ID('grac_practice.FK_org_assurance_def_version_approach','F') IS NULL
    ALTER TABLE grac_practice.org_assurance_definition_version
        ADD CONSTRAINT FK_org_assurance_def_version_approach
            FOREIGN KEY (assurance_approach_id)
            REFERENCES grac_practice.org_assurance_approach_master (assurance_approach_id);
GO

-- ---------------------------------------------------------------------
-- 3a. Audit Mandates per definition version
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.org_assurance_definition_mandate','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_definition_mandate (
        definition_mandate_id               BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_org_assurance_definition_mandate PRIMARY KEY,
        org_assurance_definition_version_id BIGINT        NOT NULL
            CONSTRAINT FK_org_assurance_definition_mandate_version
                REFERENCES grac_practice.org_assurance_definition_version (org_assurance_definition_version_id),
        organization_id                     BIGINT        NOT NULL,
        audit_mandate_id                    BIGINT        NOT NULL
            CONSTRAINT FK_org_assurance_definition_mandate_master
                REFERENCES grac_practice.org_assurance_mandate_master (audit_mandate_id),
        mandate_code                        NVARCHAR(60)  NOT NULL,   -- as saved
        mandate_name                        NVARCHAR(120) NOT NULL,   -- as saved
        display_order                       INT           NOT NULL CONSTRAINT DF_org_assurance_definition_mandate_order  DEFAULT (0),
        is_active                           BIT           NOT NULL CONSTRAINT DF_org_assurance_definition_mandate_active DEFAULT (1),
        entered_by                          NVARCHAR(100) NOT NULL CONSTRAINT DF_org_assurance_definition_mandate_eby    DEFAULT (N'system'),
        entered_dt                          DATETIME2     NOT NULL CONSTRAINT DF_org_assurance_definition_mandate_edt    DEFAULT (SYSUTCDATETIME()),
        updated_by                          NVARCHAR(100) NULL,
        updated_dt                          DATETIME2     NULL
    );
    CREATE INDEX IX_org_assurance_definition_mandate_version
        ON grac_practice.org_assurance_definition_mandate (org_assurance_definition_version_id, is_active);
    PRINT '560: org_assurance_definition_mandate created.';
END
GO

-- ---------------------------------------------------------------------
-- 3. Applicable Frameworks per definition version
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.org_assurance_definition_framework','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_definition_framework (
        definition_framework_id             BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_org_assurance_definition_framework PRIMARY KEY,
        org_assurance_definition_version_id BIGINT        NOT NULL
            CONSTRAINT FK_org_assurance_definition_framework_version
                REFERENCES grac_practice.org_assurance_definition_version (org_assurance_definition_version_id),
        organization_id                     BIGINT        NOT NULL,
        release_id                          BIGINT        NULL,   -- subscribed framework (grac_new.release); NULL = typed
        framework_name                      NVARCHAR(300) NOT NULL,
        display_order                       INT           NOT NULL CONSTRAINT DF_org_assurance_definition_framework_order  DEFAULT (0),
        is_active                           BIT           NOT NULL CONSTRAINT DF_org_assurance_definition_framework_active DEFAULT (1),
        entered_by                          NVARCHAR(100) NOT NULL CONSTRAINT DF_org_assurance_definition_framework_eby    DEFAULT (N'system'),
        entered_dt                          DATETIME2     NOT NULL CONSTRAINT DF_org_assurance_definition_framework_edt    DEFAULT (SYSUTCDATETIME()),
        updated_by                          NVARCHAR(100) NULL,
        updated_dt                          DATETIME2     NULL
    );
    CREATE INDEX IX_org_assurance_definition_framework_version
        ON grac_practice.org_assurance_definition_framework (org_assurance_definition_version_id, is_active);
    PRINT '560: org_assurance_definition_framework created.';
END
GO

-- ---------------------------------------------------------------------
-- 4. Approach list (dropdown feed)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_approach_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT assurance_approach_id AS Id,
           approach_code         AS Code,
           approach_name         AS Name,
           description           AS Description
    FROM grac_practice.org_assurance_approach_master
    WHERE is_active = 1
    ORDER BY display_order, approach_name;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_mandate_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT audit_mandate_id AS Id,
           mandate_code     AS Code,
           mandate_name     AS Name,
           description      AS Description
    FROM grac_practice.org_assurance_mandate_master
    WHERE is_active = 1
    ORDER BY display_order, mandate_name;
END
GO
