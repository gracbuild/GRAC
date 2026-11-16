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

-- ---------------------------------------------------------------------
-- 5. sp_org_assurance_definition_save (551 body + 560)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_save
    @organization_id            BIGINT,
    @definition_id              BIGINT        = NULL,
    @definition_code            NVARCHAR(80),
    @definition_name            NVARCHAR(240),
    @owner_role_id              BIGINT        = NULL,   -- 119
    @owner_role_name            NVARCHAR(120) = NULL,   -- 119
    @owner_employee_id          BIGINT        = NULL,
    @owner_display_name         NVARCHAR(240) = NULL,
    @description                NVARCHAR(MAX) = NULL,
    @objective                  NVARCHAR(MAX) = NULL,
    @effective_date             DATE          = NULL,
    @assurance_category_id      BIGINT        = NULL,
    @assurance_category_code    NVARCHAR(120) = NULL,
    @assurance_category_name    NVARCHAR(200) = NULL,
    @assurance_approach_id      BIGINT        = NULL,   -- 560
    @audit_mandate_ids_json     NVARCHAR(MAX) = NULL,   -- 560: [id, ...]; NULL = leave as is
    @applicable_frameworks_json NVARCHAR(MAX) = NULL,   -- 560: NULL = leave as is
    @actor                      NVARCHAR(100) = 'system',
    @definition_id_out          BIGINT OUTPUT,
    @definition_version_id_out  BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL
        THROW 53601, 'organization_id is required.', 1;
    IF @definition_code IS NULL OR LEN(LTRIM(RTRIM(@definition_code))) = 0
        THROW 53603, 'definition_code is required.', 1;
    IF @definition_name IS NULL OR LEN(LTRIM(RTRIM(@definition_name))) = 0
        THROW 53604, 'definition_name is required.', 1;

    -- ==========================================================
    -- 119 hybrid ownership resolver -- Owner (single owner field)
    -- ==========================================================
    IF @owner_role_id IS NOT NULL
       AND (@owner_role_name IS NULL OR LEN(LTRIM(RTRIM(@owner_role_name))) = 0)
        SELECT @owner_role_name = role_name
        FROM grac_practice.organization_role
        WHERE role_id = @owner_role_id AND organization_id = @organization_id;

    IF @owner_role_id IS NOT NULL AND @owner_employee_id IS NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id   = @organization_id,
             @role_id           = @owner_role_id,
             @employee_id_out   = @owner_employee_id  OUTPUT,
             @employee_name_out = @owner_display_name OUTPUT;

    IF @owner_employee_id IS NOT NULL AND @owner_role_id IS NULL
    BEGIN
        SELECT @owner_role_id   = e.role_id,
               @owner_role_name = r.role_name
        FROM grac_practice.organization_employee e
        LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id
        WHERE e.employee_id = @owner_employee_id
          AND e.organization_id = @organization_id;
    END

    IF @owner_employee_id IS NOT NULL
       AND (@owner_display_name IS NULL OR LEN(LTRIM(RTRIM(@owner_display_name))) = 0)
        SELECT @owner_display_name = employee_name
        FROM grac_practice.organization_employee
        WHERE employee_id = @owner_employee_id;

    -- 560: Assurance Approach (org_assurance_approach_master) -- id in,
    -- code / name kept on the version as of the save.
    DECLARE @assurance_approach_code NVARCHAR(60), @assurance_approach_name NVARCHAR(120);
    IF @assurance_approach_id IS NOT NULL
    BEGIN
        SELECT @assurance_approach_code = approach_code,
               @assurance_approach_name = approach_name
        FROM grac_practice.org_assurance_approach_master
        WHERE assurance_approach_id = @assurance_approach_id AND is_active = 1;
        IF @assurance_approach_code IS NULL
            THROW 53613, 'The selected Assurance Approach does not exist or is inactive.', 1;
    END

    -- 560: Audit Mandates (org_assurance_mandate_master) -- ids in; code /
    -- name kept on each row as of the save.
    IF @audit_mandate_ids_json IS NOT NULL AND ISJSON(@audit_mandate_ids_json) = 0
        THROW 53615, 'Audit Mandate: invalid list.', 1;
    DECLARE @md TABLE (audit_mandate_id BIGINT NOT NULL PRIMARY KEY, display_order INT NOT NULL);
    IF @audit_mandate_ids_json IS NOT NULL
    BEGIN
        INSERT @md (audit_mandate_id, display_order)
        SELECT x.id, MIN(x.ord)
        FROM (SELECT TRY_CAST(j.[value] AS BIGINT) AS id, CAST(j.[key] AS INT) AS ord
              FROM OPENJSON(@audit_mandate_ids_json) j) x
        WHERE x.id IS NOT NULL
        GROUP BY x.id;
        IF EXISTS (SELECT 1 FROM @md m
                   WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_mandate_master mm
                                     WHERE mm.audit_mandate_id = m.audit_mandate_id AND mm.is_active = 1))
            THROW 53615, 'A selected Audit Mandate does not exist or is inactive.', 1;
    END

    -- 560: Applicable Frameworks -- [{ "releaseId": 12 | null, "name": "..." }].
    IF @applicable_frameworks_json IS NOT NULL AND ISJSON(@applicable_frameworks_json) = 0
        THROW 53614, 'Applicable Frameworks: invalid list.', 1;
    DECLARE @fw TABLE (release_id BIGINT NULL, framework_name NVARCHAR(300) NOT NULL, display_order INT NOT NULL);
    IF @applicable_frameworks_json IS NOT NULL
        INSERT @fw (release_id, framework_name, display_order)
        SELECT MIN(x.release_id), x.framework_name, MIN(x.ord)
        FROM (
            SELECT TRY_CAST(JSON_VALUE(j.[value], '$.releaseId') AS BIGINT) AS release_id,
                   LTRIM(RTRIM(CAST(JSON_VALUE(j.[value], '$.name') AS NVARCHAR(300)))) AS framework_name,
                   CAST(j.[key] AS INT) AS ord
            FROM OPENJSON(@applicable_frameworks_json) j
        ) x
        WHERE x.framework_name IS NOT NULL AND x.framework_name <> N''
        GROUP BY x.framework_name;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    DECLARE @draft_status_id INT = (
        SELECT org_assurance_status_id
        FROM grac_practice.org_assurance_status_master
        WHERE status_code = N'Draft');

    BEGIN TRAN;

    IF @definition_id IS NULL
    BEGIN
        -- New definition
        IF EXISTS (
            SELECT 1 FROM grac_practice.org_assurance_definition
            WHERE organization_id = @organization_id
              AND definition_code = @definition_code
              AND is_active = 1)
        BEGIN
            ROLLBACK;
            THROW 53605, 'A definition with this code already exists in the organization.', 1;
        END

        INSERT INTO grac_practice.org_assurance_definition
            (organization_id, definition_code, definition_name,
             owner_role_id, owner_role_name,
             owner_employee_id, owner_display_name,
             current_version_id, current_status_id, active_version_id,
             is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@organization_id, @definition_code, @definition_name,
             @owner_role_id, @owner_role_name,
             @owner_employee_id, @owner_display_name,
             NULL, @draft_status_id, NULL,
             1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @definition_id_out = SCOPE_IDENTITY();

        INSERT INTO grac_practice.org_assurance_definition_version
            (org_assurance_definition_id, organization_id, version_number, version_label,
             description, objective, effective_date,
             assurance_category_id, assurance_category_code, assurance_category_name,
             assurance_approach_id, assurance_approach_code, assurance_approach_name,   -- 560
             status_id, is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@definition_id_out, @organization_id, 1, N'1.0',
             @description, @objective, @effective_date,
             @assurance_category_id, @assurance_category_code, @assurance_category_name,
             @assurance_approach_id, @assurance_approach_code, @assurance_approach_name,
             @draft_status_id, 1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @definition_version_id_out = SCOPE_IDENTITY();

        UPDATE grac_practice.org_assurance_definition
        SET current_version_id = @definition_version_id_out,
            updated_by = @actor,
            updated_dt = SYSUTCDATETIME()
        WHERE org_assurance_definition_id = @definition_id_out;

        INSERT INTO grac_practice.org_assurance_definition_history
            (org_assurance_definition_id, org_assurance_definition_version_id,
             organization_id, action_code, from_status_id, to_status_id,
             actor_display_name, entered_by)
        VALUES
            (@definition_id_out, @definition_version_id_out, @organization_id,
             N'CREATE', NULL, @draft_status_id, @actor, @actor);
    END
    ELSE
    BEGIN
        -- Existing definition -- validate org ownership + branch on version status
        DECLARE @current_version_id BIGINT,
                @current_status_code NVARCHAR(60),
                @current_status_id   INT,
                @next_version_number INT,
                @def_org             BIGINT;

        SELECT @def_org             = d.organization_id,
               @current_version_id  = d.current_version_id,
               @current_status_id   = d.current_status_id,
               @current_status_code = s.status_code
        FROM grac_practice.org_assurance_definition d
        JOIN grac_practice.org_assurance_status_master s
             ON s.org_assurance_status_id = d.current_status_id
        WHERE d.org_assurance_definition_id = @definition_id
          AND d.is_active = 1;

        IF @def_org IS NULL
        BEGIN
            ROLLBACK;
            THROW 53606, 'Definition not found.', 1;
        END
        IF @def_org <> @organization_id
        BEGIN
            ROLLBACK;
            THROW 53607, 'Definition belongs to a different organization.', 1;
        END

        SET @definition_id_out = @definition_id;

        IF @current_status_code IN (N'UnderReview', N'Approved')
        BEGIN
            ROLLBACK;
            THROW 53608, 'Cannot edit a definition that is Under Review or Approved. Withdraw the review first or activate + create a new draft.', 1;
        END

        IF @current_status_code = N'Draft'
        BEGIN
            -- In-place update of the existing draft version.
            UPDATE grac_practice.org_assurance_definition_version
            SET description             = @description,
                objective               = @objective,
                effective_date          = @effective_date,
                assurance_category_id   = @assurance_category_id,
                assurance_category_code = @assurance_category_code,
                assurance_category_name = @assurance_category_name,
                assurance_approach_id   = @assurance_approach_id,     -- 560
                assurance_approach_code = @assurance_approach_code,   -- 560
                assurance_approach_name = @assurance_approach_name,   -- 560
                updated_by              = @actor,
                updated_dt              = SYSUTCDATETIME()
            WHERE org_assurance_definition_version_id = @current_version_id;

            UPDATE grac_practice.org_assurance_definition
            SET definition_name    = @definition_name,
                owner_role_id      = @owner_role_id,        -- 119
                owner_role_name    = @owner_role_name,      -- 119
                owner_employee_id  = @owner_employee_id,
                owner_display_name = @owner_display_name,
                updated_by         = @actor,
                updated_dt         = SYSUTCDATETIME()
            WHERE org_assurance_definition_id = @definition_id;

            SET @definition_version_id_out = @current_version_id;

            INSERT INTO grac_practice.org_assurance_definition_history
                (org_assurance_definition_id, org_assurance_definition_version_id,
                 organization_id, action_code, from_status_id, to_status_id,
                 actor_display_name, entered_by)
            VALUES
                (@definition_id, @current_version_id, @organization_id,
                 N'EDIT', @current_status_id, @current_status_id, @actor, @actor);
        END
        ELSE
        BEGIN
            -- Active or Retired -- create a new Draft version.
            SELECT @next_version_number = ISNULL(MAX(version_number), 0) + 1
            FROM grac_practice.org_assurance_definition_version
            WHERE org_assurance_definition_id = @definition_id;

            INSERT INTO grac_practice.org_assurance_definition_version
                (org_assurance_definition_id, organization_id, version_number,
                 version_label, description, objective, effective_date,
                 assurance_category_id, assurance_category_code, assurance_category_name,
                 assurance_approach_id, assurance_approach_code, assurance_approach_name,   -- 560
                 status_id, is_active, record_status_id, entered_by, entered_dt)
            VALUES
                (@definition_id, @organization_id, @next_version_number,
                 CAST(@next_version_number AS NVARCHAR(20)) + N'.0',
                 @description, @objective, @effective_date,
                 @assurance_category_id, @assurance_category_code, @assurance_category_name,
                 @assurance_approach_id, @assurance_approach_code, @assurance_approach_name,
                 @draft_status_id, 1, @active_record_status_id, @actor, SYSUTCDATETIME());

            SET @definition_version_id_out = SCOPE_IDENTITY();

            -- 551: the new Draft version carries the configuration of the
            -- version it revises (scope, question sets, workflow, scoring);
            -- it started empty before.
            EXEC grac_practice.sp_org_assurance_definition_version_copy_config
                 @organization_id = @organization_id,
                 @from_version_id = @current_version_id,
                 @to_version_id   = @definition_version_id_out,
                 @actor           = @actor;

            UPDATE grac_practice.org_assurance_definition
            SET definition_name    = @definition_name,
                owner_role_id      = @owner_role_id,        -- 119
                owner_role_name    = @owner_role_name,      -- 119
                owner_employee_id  = @owner_employee_id,
                owner_display_name = @owner_display_name,
                current_version_id = @definition_version_id_out,
                current_status_id  = @draft_status_id,
                updated_by         = @actor,
                updated_dt         = SYSUTCDATETIME()
            WHERE org_assurance_definition_id = @definition_id;

            INSERT INTO grac_practice.org_assurance_definition_history
                (org_assurance_definition_id, org_assurance_definition_version_id,
                 organization_id, action_code, from_status_id, to_status_id,
                 actor_display_name, entered_by)
            VALUES
                (@definition_id, @definition_version_id_out, @organization_id,
                 N'CREATE', @current_status_id, @draft_status_id, @actor, @actor);
        END
    END

    -- 560: Applicable Frameworks of the saved version (a new version already
    -- carries the previous list through copy_config; a list sent replaces it).
    IF @applicable_frameworks_json IS NOT NULL
    BEGIN
        UPDATE grac_practice.org_assurance_definition_framework
           SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE org_assurance_definition_version_id = @definition_version_id_out
           AND is_active = 1;

        INSERT INTO grac_practice.org_assurance_definition_framework
            (org_assurance_definition_version_id, organization_id, release_id,
             framework_name, display_order, is_active, entered_by, entered_dt)
        SELECT @definition_version_id_out, @organization_id, f.release_id,
               f.framework_name, f.display_order, 1, @actor, SYSUTCDATETIME()
          FROM @fw f;
    END

    -- 560: Audit Mandates of the saved version (same rule as the frameworks).
    IF @audit_mandate_ids_json IS NOT NULL
    BEGIN
        UPDATE grac_practice.org_assurance_definition_mandate
           SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE org_assurance_definition_version_id = @definition_version_id_out
           AND is_active = 1;

        INSERT INTO grac_practice.org_assurance_definition_mandate
            (org_assurance_definition_version_id, organization_id, audit_mandate_id,
             mandate_code, mandate_name, display_order, is_active, entered_by, entered_dt)
        SELECT @definition_version_id_out, @organization_id, m.audit_mandate_id,
               mm.mandate_code, mm.mandate_name, m.display_order, 1, @actor, SYSUTCDATETIME()
          FROM @md m
          JOIN grac_practice.org_assurance_mandate_master mm ON mm.audit_mandate_id = m.audit_mandate_id;
    END

    COMMIT;
END
GO

-- ---------------------------------------------------------------------
-- 6. sp_org_assurance_definition_get (119 body + 560)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_get
    @organization_id BIGINT,
    @definition_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;

    SELECT d.org_assurance_definition_id AS DefinitionId,
           d.organization_id             AS OrganizationId,
           d.definition_code             AS DefinitionCode,
           d.definition_name             AS DefinitionName,
           d.owner_role_id               AS OwnerRoleId,
           d.owner_role_name             AS OwnerRoleName,
           d.owner_employee_id           AS OwnerEmployeeId,
           d.owner_display_name          AS OwnerDisplayName,
           d.current_version_id          AS CurrentVersionId,
           d.active_version_id           AS ActiveVersionId,
           s.status_code                 AS CurrentStatusCode,
           s.status_name                 AS CurrentStatusName,
           s.is_terminal                 AS CurrentStatusIsTerminal,
           v.version_number              AS CurrentVersionNumber,
           v.version_label               AS CurrentVersionLabel,
           v.description                 AS Description,
           v.objective                   AS Objective,
           v.effective_date              AS EffectiveDate,
           v.assurance_category_id       AS AssuranceCategoryId,
           v.assurance_category_code     AS AssuranceCategoryCode,
           v.assurance_category_name     AS AssuranceCategoryName,
           v.assurance_approach_id       AS AssuranceApproachId,     -- 560
           v.assurance_approach_code     AS AssuranceApproachCode,   -- 560
           v.assurance_approach_name     AS AssuranceApproachName,   -- 560
           v.submitted_by                AS SubmittedBy,
           v.submitted_dt                AS SubmittedDt,
           v.approved_by                 AS ApprovedBy,
           v.approved_dt                 AS ApprovedDt,
           v.activated_by                AS ActivatedBy,
           v.activated_dt                AS ActivatedDt,
           v.retired_by                  AS RetiredBy,
           v.retired_dt                  AS RetiredDt,
           d.entered_by                  AS EnteredBy,
           d.entered_dt                  AS EnteredDt,
           d.updated_by                  AS UpdatedBy,
           d.updated_dt                  AS UpdatedDt
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    LEFT JOIN grac_practice.org_assurance_definition_version v
         ON v.org_assurance_definition_version_id = d.current_version_id
    WHERE d.organization_id = @organization_id
      AND d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    -- 560: second result set -- Applicable Frameworks of the current version.
    SELECT f.definition_framework_id AS DefinitionFrameworkId,
           f.release_id              AS ReleaseId,
           f.framework_name          AS FrameworkName,
           f.display_order           AS DisplayOrder
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_definition_framework f
         ON f.org_assurance_definition_version_id = d.current_version_id
        AND f.is_active = 1
    WHERE d.organization_id = @organization_id
      AND d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1
    ORDER BY f.display_order, f.framework_name;

    -- 560: third result set -- Audit Mandates of the current version.
    SELECT m.definition_mandate_id AS DefinitionMandateId,
           m.audit_mandate_id      AS AuditMandateId,
           m.mandate_code          AS MandateCode,
           m.mandate_name          AS MandateName,
           m.display_order         AS DisplayOrder
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_definition_mandate m
         ON m.org_assurance_definition_version_id = d.current_version_id
        AND m.is_active = 1
    WHERE d.organization_id = @organization_id
      AND d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1
    ORDER BY m.display_order, m.mandate_name;
END
GO

-- ---------------------------------------------------------------------
-- 7. sp_org_assurance_definition_version_copy_config (551 body + 560)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_version_copy_config
    @organization_id  BIGINT,
    @from_version_id  BIGINT,
    @to_version_id    BIGINT,
    @swap_root_set_id BIGINT        = NULL,
    @swap_to_set_id   BIGINT        = NULL,
    @actor            NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @from_version_id IS NULL OR @to_version_id IS NULL OR @from_version_id = @to_version_id
        THROW 53849, 'Copy failed: two different versions are required.', 1;

    CREATE TABLE #cfg_group (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);
    CREATE TABLE #cfg_cond  (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);
    CREATE TABLE #cfg_wf    (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);
    CREATE TABLE #cfg_sc    (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);

    -- Scope
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scope_group', @key_column = N'scope_group_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @map_table = N'#cfg_group', @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scope_condition', @key_column = N'scope_condition_id',
         @where = N'src.is_active = 1',
         @source_join = N'JOIN #cfg_group m ON m.old_id = src.scope_group_id', @source_extra = N', m.new_id AS parent_new_id',
         @overrides = N'{"scope_group_id":"src.parent_new_id"}',
         @map_table = N'#cfg_cond', @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scope_condition_value', @key_column = N'scope_condition_value_id',
         @where = N'src.is_active = 1',
         @source_join = N'JOIN #cfg_cond m ON m.old_id = src.scope_condition_id', @source_extra = N', m.new_id AS parent_new_id',
         @overrides = N'{"scope_condition_id":"src.parent_new_id"}',
         @p_actor = @actor;

    -- Question sets (one family optionally moved to a new set version)
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_definition_question_set', @key_column = N'org_assurance_definition_question_set_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @source_join = N'LEFT JOIN grac_practice.org_assurance_question_set f ON f.org_assurance_question_set_id = src.org_assurance_question_set_id',
         @source_extra = N', f.root_question_set_id AS set_root_id',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version","org_assurance_question_set_id":"CASE WHEN @p_root IS NOT NULL AND src.set_root_id = @p_root THEN @p_set ELSE src.org_assurance_question_set_id END"}',
         @p_source = @from_version_id, @p_version = @to_version_id,
         @p_root = @swap_root_set_id, @p_set = @swap_to_set_id, @p_actor = @actor;

    -- Workflow
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_workflow_config', @key_column = N'org_assurance_workflow_config_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @map_table = N'#cfg_wf', @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_workflow_stage', @key_column = N'org_assurance_workflow_stage_id',
         @where = N'src.is_active = 1',
         @source_join = N'JOIN #cfg_wf m ON m.old_id = src.org_assurance_workflow_config_id', @source_extra = N', m.new_id AS parent_new_id',
         @overrides = N'{"org_assurance_workflow_config_id":"src.parent_new_id","org_assurance_definition_version_id":"@p_version"}',
         @p_version = @to_version_id, @p_actor = @actor;

    -- 560: Applicable Frameworks and Audit Mandates (definition details, carried like the configuration)
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_definition_framework', @key_column = N'definition_framework_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_definition_mandate', @key_column = N'definition_mandate_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;

    -- Scoring
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scoring_config', @key_column = N'org_assurance_scoring_config_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @map_table = N'#cfg_sc', @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scoring_band', @key_column = N'org_assurance_scoring_band_id',
         @where = N'src.is_active = 1',
         @source_join = N'JOIN #cfg_sc m ON m.old_id = src.org_assurance_scoring_config_id', @source_extra = N', m.new_id AS parent_new_id',
         @overrides = N'{"org_assurance_scoring_config_id":"src.parent_new_id","org_assurance_definition_version_id":"@p_version"}',
         @p_version = @to_version_id, @p_actor = @actor;
END
GO

PRINT '560 Audit Definition: Assurance Approach, Audit Mandates, Applicable Frameworks installed.';
GO
SET NOEXEC OFF;
GO
