-- =====================================================================
-- 516  Audit -> Question Repository
--      ** SUPERSEDED by 520 -- withdrawn on 2026-11-05. Kept for history;
--         it refuses to run once 520 is applied. **
--
-- REQUEST (2026-11-05)
--   A "Question Repository" menu under Audit, where an organization adds
--   its audit questions with these inputs:
--     Question Code (mandatory, unique), Question (mandatory),
--     Category (mandatory), Subcategory (optional),
--     Description / Guidance (optional), Response Type (mandatory),
--     Mandatory (mandatory), Evidence Required (mandatory),
--     Expected Evidence (optional), Weight (optional),
--     Status Active / Inactive (mandatory), Version (system managed),
--     Created By / Date, Modified By / Date (system audit fields).
--   Category and Subcategory start from a default set; each organization
--   can add / edit / remove its own, and sees only its own.
--   Question Sets no longer type their questions in: they PICK them from
--   the Repository.
--
-- WHAT THIS ADDS
--   1. Tables
--      org_assurance_question_category          per-organization categories
--      org_assurance_question_subcategory       per-organization subcategories
--      org_assurance_question_category_default  the default set (global)
--      org_assurance_question_category_seed     which organizations got it
--      org_assurance_question_repository        the repository questions
--      org_assurance_question.repository_question_id  set item -> repository
--   2. Default categories / subcategories (section 3). "General" is added
--      to the agreed list so existing set questions (which have no
--      category) have one to land in; an organization may rename or
--      remove it once it is unused.
--   3. Procedures (section 4), all new except the three set-question
--      procedures from 077, re-issued from their 077 bodies:
--        sp_org_assurance_question_list / _get   + RepositoryQuestionId,
--                                                  CategoryName, SubcategoryName
--        sp_org_assurance_question_save          a set item can no longer be
--          created here (53320 -- add it from the Repository); for a
--          Repository-linked item only Order changes, the content belongs
--          to the Repository and is kept in step by the Repository save.
--   4. Existing set questions become Repository questions (section 5):
--      one Repository question per organization + code + text, category
--      "General"; a code shared by DIFFERENT texts gets "-S<set id>" on the
--      later ones. Set rows are linked; their old code / link are backed up
--      in migration_516_question_backup for the rollback.
--   5. Menu 'org-assurance-question-repository' (Question Repository)
--      under Audit Assurance at 445 (after Audit Definition, 440), with
--      full rights for every active role of every active organization
--      (the 476 way). 274 edited as well. The screen uses the Question
--      Sets feature flag (screen.org-assurance-question-sets): same
--      Question Builder feature, so no new flag to enable.
--
-- Error numbers 53301-53323 (block 533xx was unused).
-- SAFE TO RE-RUN.  Requires 076 / 077.
-- Rollback: 516_audit_question_repository_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @prereqs_ok BIT = 1;
IF OBJECT_ID('grac_practice.org_assurance_question_set','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_question','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_assurance_question_save','P') IS NULL
BEGIN PRINT 'ABORT (516): run 076 / 077 first.'; SET @prereqs_ok = 0; END
IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance')
BEGIN PRINT 'ABORT (516): menu_master / nav-assurance missing. Run 274 first.'; SET @prereqs_ok = 0; END
-- 077 body columns the re-issued procedures read.
IF COL_LENGTH('grac_practice.org_assurance_question','expected_response') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_question','question_type_name') IS NULL
BEGIN PRINT 'ABORT (516): org_assurance_question is not the 076 shape.'; SET @prereqs_ok = 0; END
-- SUPERSEDED by 520 (2026-11-05): the Repository was withdrawn. Once 520
-- has run, this script must not bring it back.
IF OBJECT_ID('grac_practice.sp_org_assurance_question_set_questions_save','P') IS NOT NULL
BEGIN PRINT 'ABORT (516): superseded by 520 (Question Sets with an inline questions grid). Nothing was changed.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 0
BEGIN
    RAISERROR('516: prerequisites missing -- see PRINT messages above. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Tables
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_question_category','U') IS NULL
CREATE TABLE grac_practice.org_assurance_question_category(
    org_assurance_question_category_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_qcat PRIMARY KEY,
    organization_id   BIGINT        NOT NULL,
    category_name     NVARCHAR(200) NOT NULL,
    display_order     INT           NOT NULL CONSTRAINT df_pm_oa_qcat_order  DEFAULT 0,
    is_active         BIT           NOT NULL CONSTRAINT df_pm_oa_qcat_active DEFAULT 1,
    record_status_id  INT           NOT NULL,
    entered_by        NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_qcat_ent_by DEFAULT 'system',
    entered_dt        DATETIME2     NOT NULL CONSTRAINT df_pm_oa_qcat_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by        NVARCHAR(100) NULL,
    updated_dt        DATETIME2     NULL,
    CONSTRAINT fk_pm_oa_qcat_org FOREIGN KEY(organization_id)
        REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_qcat_record_status FOREIGN KEY(record_status_id)
        REFERENCES grac_practice.record_status_master(record_status_id)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_oa_qcat_name'
               AND object_id = OBJECT_ID('grac_practice.org_assurance_question_category'))
    CREATE UNIQUE INDEX ux_pm_oa_qcat_name
        ON grac_practice.org_assurance_question_category(organization_id, category_name)
        WHERE is_active = 1;
GO

IF OBJECT_ID('grac_practice.org_assurance_question_subcategory','U') IS NULL
CREATE TABLE grac_practice.org_assurance_question_subcategory(
    org_assurance_question_subcategory_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_qsub PRIMARY KEY,
    org_assurance_question_category_id BIGINT NOT NULL,
    organization_id   BIGINT        NOT NULL,
    subcategory_name  NVARCHAR(200) NOT NULL,
    display_order     INT           NOT NULL CONSTRAINT df_pm_oa_qsub_order  DEFAULT 0,
    is_active         BIT           NOT NULL CONSTRAINT df_pm_oa_qsub_active DEFAULT 1,
    record_status_id  INT           NOT NULL,
    entered_by        NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_qsub_ent_by DEFAULT 'system',
    entered_dt        DATETIME2     NOT NULL CONSTRAINT df_pm_oa_qsub_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by        NVARCHAR(100) NULL,
    updated_dt        DATETIME2     NULL,
    CONSTRAINT fk_pm_oa_qsub_category FOREIGN KEY(org_assurance_question_category_id)
        REFERENCES grac_practice.org_assurance_question_category(org_assurance_question_category_id),
    CONSTRAINT fk_pm_oa_qsub_org FOREIGN KEY(organization_id)
        REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_qsub_record_status FOREIGN KEY(record_status_id)
        REFERENCES grac_practice.record_status_master(record_status_id)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_oa_qsub_name'
               AND object_id = OBJECT_ID('grac_practice.org_assurance_question_subcategory'))
    CREATE UNIQUE INDEX ux_pm_oa_qsub_name
        ON grac_practice.org_assurance_question_subcategory(org_assurance_question_category_id, subcategory_name)
        WHERE is_active = 1;
GO

-- The default set every organization starts from (global, not per org).
IF OBJECT_ID('grac_practice.org_assurance_question_category_default','U') IS NULL
CREATE TABLE grac_practice.org_assurance_question_category_default(
    category_name     NVARCHAR(200) NOT NULL,
    subcategory_name  NVARCHAR(200) NOT NULL CONSTRAINT df_pm_oa_qcatdef_sub DEFAULT N'',  -- '' = the category row itself
    display_order     INT           NOT NULL,
    CONSTRAINT pk_pm_oa_qcatdef PRIMARY KEY(category_name, subcategory_name)
);
GO

-- Which organizations have received the default set. Seeding happens
-- once per organization; removing every category later does NOT bring
-- the defaults back.
IF OBJECT_ID('grac_practice.org_assurance_question_category_seed','U') IS NULL
CREATE TABLE grac_practice.org_assurance_question_category_seed(
    organization_id BIGINT    NOT NULL CONSTRAINT pk_pm_oa_qcatseed PRIMARY KEY,
    seeded_by       NVARCHAR(100) NOT NULL,
    seeded_dt       DATETIME2 NOT NULL CONSTRAINT df_pm_oa_qcatseed_dt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_pm_oa_qcatseed_org FOREIGN KEY(organization_id)
        REFERENCES grac_practice.organization(organization_id)
);
GO

IF OBJECT_ID('grac_practice.org_assurance_question_repository','U') IS NULL
CREATE TABLE grac_practice.org_assurance_question_repository(
    org_assurance_question_repository_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_qrepo PRIMARY KEY,
    organization_id      BIGINT        NOT NULL,
    question_code        NVARCHAR(80)  NOT NULL,
    question_text        NVARCHAR(MAX) NOT NULL,
    org_assurance_question_category_id    BIGINT NOT NULL,
    org_assurance_question_subcategory_id BIGINT NULL,
    guidance             NVARCHAR(MAX) NULL,           -- Description / Guidance
    question_type_id     BIGINT        NULL,           -- Response Type (Admin question type)
    question_type_code   NVARCHAR(120) NULL,
    question_type_name   NVARCHAR(200) NULL,
    is_mandatory         BIT           NOT NULL CONSTRAINT df_pm_oa_qrepo_mand  DEFAULT 0,
    evidence_required    BIT           NOT NULL CONSTRAINT df_pm_oa_qrepo_evid  DEFAULT 0,
    expected_evidence    NVARCHAR(MAX) NULL,
    weight               DECIMAL(10,2) NULL,
    status               NVARCHAR(20)  NOT NULL CONSTRAINT df_pm_oa_qrepo_status DEFAULT N'Active',
    version_number       INT           NOT NULL CONSTRAINT df_pm_oa_qrepo_ver    DEFAULT 1,
    is_active            BIT           NOT NULL CONSTRAINT df_pm_oa_qrepo_active DEFAULT 1,
    record_status_id     INT           NOT NULL,
    entered_by           NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_qrepo_ent_by DEFAULT 'system',
    entered_dt           DATETIME2     NOT NULL CONSTRAINT df_pm_oa_qrepo_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by           NVARCHAR(100) NULL,
    updated_dt           DATETIME2     NULL,
    CONSTRAINT fk_pm_oa_qrepo_org FOREIGN KEY(organization_id)
        REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_qrepo_category FOREIGN KEY(org_assurance_question_category_id)
        REFERENCES grac_practice.org_assurance_question_category(org_assurance_question_category_id),
    CONSTRAINT fk_pm_oa_qrepo_subcategory FOREIGN KEY(org_assurance_question_subcategory_id)
        REFERENCES grac_practice.org_assurance_question_subcategory(org_assurance_question_subcategory_id),
    CONSTRAINT fk_pm_oa_qrepo_record_status FOREIGN KEY(record_status_id)
        REFERENCES grac_practice.record_status_master(record_status_id),
    CONSTRAINT ck_pm_oa_qrepo_status CHECK (status IN (N'Active', N'Inactive'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_oa_qrepo_code'
               AND object_id = OBJECT_ID('grac_practice.org_assurance_question_repository'))
    CREATE UNIQUE INDEX ux_pm_oa_qrepo_code
        ON grac_practice.org_assurance_question_repository(organization_id, question_code)
        WHERE is_active = 1;
GO

-- Set item -> Repository question.
IF COL_LENGTH('grac_practice.org_assurance_question','repository_question_id') IS NULL
    ALTER TABLE grac_practice.org_assurance_question
        ADD repository_question_id BIGINT NULL
            CONSTRAINT fk_pm_oa_question_repository
            REFERENCES grac_practice.org_assurance_question_repository(org_assurance_question_repository_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_oa_question_repository'
               AND object_id = OBJECT_ID('grac_practice.org_assurance_question'))
    CREATE INDEX ix_pm_oa_question_repository
        ON grac_practice.org_assurance_question(repository_question_id)
        WHERE is_active = 1 AND repository_question_id IS NOT NULL;
GO

-- Backup for the rollback of section 5.
IF OBJECT_ID('grac_practice.migration_516_question_backup','U') IS NULL
CREATE TABLE grac_practice.migration_516_question_backup(
    org_assurance_question_id BIGINT       NOT NULL CONSTRAINT pk_pm_mig516_qbak PRIMARY KEY,
    question_code_before      NVARCHAR(80) NOT NULL,
    backed_up_dt              DATETIME2    NOT NULL CONSTRAINT df_pm_mig516_qbak_dt DEFAULT SYSUTCDATETIME()
);
GO

-- =====================================================================
-- 2. (reserved)
-- 3. Default categories / subcategories
-- =====================================================================
MERGE grac_practice.org_assurance_question_category_default AS t
USING (VALUES
    (N'IT Infrastructure'    , N''                        , 10),
    (N'IT Infrastructure'    , N'Network'                 , 11),
    (N'IT Infrastructure'    , N'Servers'                 , 12),
    (N'IT Infrastructure'    , N'Endpoints'               , 13),
    (N'IT Infrastructure'    , N'Backup & DR'             , 14),
    (N'IT Applications'      , N''                        , 20),
    (N'IT Applications'      , N'Access Control'          , 21),
    (N'IT Applications'      , N'Change Management'       , 22),
    (N'IT Applications'      , N'Application Security'    , 23),
    (N'Information Security' , N''                        , 30),
    (N'Information Security' , N'Policy'                  , 31),
    (N'Information Security' , N'Incident Management'     , 32),
    (N'Information Security' , N'Vulnerability Management', 33),
    (N'HR'                   , N''                        , 40),
    (N'HR'                   , N'Onboarding'              , 41),
    (N'HR'                   , N'Offboarding'             , 42),
    (N'HR'                   , N'Training & Awareness'    , 43),
    (N'Treasury'             , N''                        , 50),
    (N'Treasury'             , N'Payments'                , 51),
    (N'Treasury'             , N'Cash Management'         , 52),
    (N'Treasury'             , N'Reconciliation'          , 53),
    (N'Finance & Accounts'   , N''                        , 60),
    (N'Finance & Accounts'   , N'General Ledger'          , 61),
    (N'Finance & Accounts'   , N'Payables'                , 62),
    (N'Finance & Accounts'   , N'Receivables'             , 63),
    (N'Operations'           , N''                        , 70),
    (N'Operations'           , N'Process Controls'        , 71),
    (N'Operations'           , N'Vendor Management'       , 72),
    (N'Compliance'           , N''                        , 80),
    (N'Compliance'           , N'Regulatory Reporting'    , 81),
    (N'Compliance'           , N'Policies & Procedures'   , 82),
    (N'General'              , N''                        , 90)
) AS s(category_name, subcategory_name, display_order)
ON t.category_name = s.category_name AND t.subcategory_name = s.subcategory_name
WHEN MATCHED AND t.display_order <> s.display_order THEN UPDATE SET display_order = s.display_order
WHEN NOT MATCHED BY TARGET THEN INSERT (category_name, subcategory_name, display_order)
    VALUES (s.category_name, s.subcategory_name, s.display_order);
GO

-- =====================================================================
-- 4. Procedures
-- =====================================================================

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_category_ensure_defaults
--   Gives an organization the default set, once.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_category_ensure_defaults
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL THROW 53301, 'organization_id is required.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_question_category_seed
               WHERE organization_id = @organization_id) RETURN;

    DECLARE @rs INT = (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
                       WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
    IF @rs IS NULL SET @rs = 1;

    BEGIN TRAN;
    -- Re-check under the transaction (two first visits at once).
    IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_question_category_seed WITH (UPDLOCK, HOLDLOCK)
               WHERE organization_id = @organization_id)
    BEGIN COMMIT; RETURN; END

    INSERT grac_practice.org_assurance_question_category
        (organization_id, category_name, display_order, is_active, record_status_id, entered_by)
    SELECT @organization_id, d.category_name, d.display_order, 1, @rs, ISNULL(@actor, 'system')
    FROM   grac_practice.org_assurance_question_category_default d
    WHERE  d.subcategory_name = N''
      AND  NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_question_category c
                       WHERE c.organization_id = @organization_id AND c.is_active = 1
                         AND c.category_name = d.category_name);

    INSERT grac_practice.org_assurance_question_subcategory
        (org_assurance_question_category_id, organization_id, subcategory_name, display_order,
         is_active, record_status_id, entered_by)
    SELECT c.org_assurance_question_category_id, @organization_id, d.subcategory_name, d.display_order,
           1, @rs, ISNULL(@actor, 'system')
    FROM   grac_practice.org_assurance_question_category_default d
    JOIN   grac_practice.org_assurance_question_category c
           ON c.organization_id = @organization_id AND c.is_active = 1 AND c.category_name = d.category_name
    WHERE  d.subcategory_name <> N''
      AND  NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_question_subcategory s
                       WHERE s.org_assurance_question_category_id = c.org_assurance_question_category_id
                         AND s.is_active = 1 AND s.subcategory_name = d.subcategory_name);

    INSERT grac_practice.org_assurance_question_category_seed(organization_id, seeded_by)
    VALUES (@organization_id, ISNULL(@actor, 'system'));
    COMMIT;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_category_list
--   Result 1: categories.  Result 2: subcategories.  Both with the
--   number of (not removed) Repository questions using them.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_category_list
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 53301, 'organization_id is required.', 1;
    EXEC grac_practice.sp_org_assurance_question_category_ensure_defaults @organization_id = @organization_id;

    SELECT c.org_assurance_question_category_id AS CategoryId,
           c.category_name                      AS CategoryName,
           c.display_order                      AS DisplayOrder,
           (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_question_repository r
             WHERE r.org_assurance_question_category_id = c.org_assurance_question_category_id
               AND r.is_active = 1)             AS QuestionCount
    FROM   grac_practice.org_assurance_question_category c
    WHERE  c.organization_id = @organization_id AND c.is_active = 1
    ORDER  BY c.display_order, c.category_name;

    SELECT s.org_assurance_question_subcategory_id AS SubcategoryId,
           s.org_assurance_question_category_id    AS CategoryId,
           s.subcategory_name                      AS SubcategoryName,
           s.display_order                         AS DisplayOrder,
           (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_question_repository r
             WHERE r.org_assurance_question_subcategory_id = s.org_assurance_question_subcategory_id
               AND r.is_active = 1)                AS QuestionCount
    FROM   grac_practice.org_assurance_question_subcategory s
    JOIN   grac_practice.org_assurance_question_category c
           ON c.org_assurance_question_category_id = s.org_assurance_question_category_id AND c.is_active = 1
    WHERE  s.organization_id = @organization_id AND s.is_active = 1
    ORDER  BY s.display_order, s.subcategory_name;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_category_save  (add / rename)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_category_save
    @organization_id BIGINT,
    @category_id     BIGINT        = NULL,
    @category_name   NVARCHAR(200),
    @display_order   INT           = NULL,
    @actor           NVARCHAR(100) = 'system',
    @category_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @category_name = LTRIM(RTRIM(@category_name));
    IF @organization_id IS NULL THROW 53301, 'organization_id is required.', 1;
    IF @category_name IS NULL OR @category_name = N'' THROW 53302, 'Category name is required.', 1;

    IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_question_category
               WHERE organization_id = @organization_id AND is_active = 1
                 AND category_name = @category_name
                 AND (@category_id IS NULL OR org_assurance_question_category_id <> @category_id))
        THROW 53303, 'A category with this name already exists in the organization.', 1;

    IF @category_id IS NULL
    BEGIN
        DECLARE @rs INT = (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
                           WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
        IF @rs IS NULL SET @rs = 1;
        INSERT grac_practice.org_assurance_question_category
            (organization_id, category_name, display_order, is_active, record_status_id, entered_by)
        VALUES (@organization_id, @category_name,
                ISNULL(@display_order, (SELECT ISNULL(MAX(display_order), 0) + 10
                                        FROM grac_practice.org_assurance_question_category
                                        WHERE organization_id = @organization_id AND is_active = 1)),
                1, @rs, ISNULL(@actor, 'system'));
        SET @category_id_out = SCOPE_IDENTITY();
        RETURN;
    END

    DECLARE @org BIGINT = (SELECT organization_id FROM grac_practice.org_assurance_question_category
                           WHERE org_assurance_question_category_id = @category_id AND is_active = 1);
    IF @org IS NULL THROW 53304, 'Category not found.', 1;
    IF @org <> @organization_id THROW 53305, 'Category belongs to a different organization.', 1;

    UPDATE grac_practice.org_assurance_question_category
    SET    category_name = @category_name,
           display_order = ISNULL(@display_order, display_order),
           updated_by    = ISNULL(@actor, 'system'),
           updated_dt    = SYSUTCDATETIME()
    WHERE  org_assurance_question_category_id = @category_id;
    SET @category_id_out = @category_id;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_category_delete  (soft; with its subcategories)
--   Refused while a Repository question uses the category or one of its
--   subcategories.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_category_delete
    @organization_id BIGINT,
    @category_id     BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL OR @category_id IS NULL THROW 53301, 'organization_id and category_id are required.', 1;

    DECLARE @org BIGINT = (SELECT organization_id FROM grac_practice.org_assurance_question_category
                           WHERE org_assurance_question_category_id = @category_id AND is_active = 1);
    IF @org IS NULL THROW 53304, 'Category not found.', 1;
    IF @org <> @organization_id THROW 53305, 'Category belongs to a different organization.', 1;

    IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_question_repository
               WHERE org_assurance_question_category_id = @category_id AND is_active = 1)
        THROW 53306, 'This category is used by questions in the repository. Move those questions to another category first.', 1;

    BEGIN TRAN;
    UPDATE grac_practice.org_assurance_question_subcategory
    SET    is_active = 0, updated_by = ISNULL(@actor, 'system'), updated_dt = SYSUTCDATETIME()
    WHERE  org_assurance_question_category_id = @category_id AND is_active = 1;
    UPDATE grac_practice.org_assurance_question_category
    SET    is_active = 0, updated_by = ISNULL(@actor, 'system'), updated_dt = SYSUTCDATETIME()
    WHERE  org_assurance_question_category_id = @category_id;
    COMMIT;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_subcategory_save  (add / rename / move)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_subcategory_save
    @organization_id    BIGINT,
    @category_id        BIGINT,
    @subcategory_id     BIGINT        = NULL,
    @subcategory_name   NVARCHAR(200),
    @display_order      INT           = NULL,
    @actor              NVARCHAR(100) = 'system',
    @subcategory_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @subcategory_name = LTRIM(RTRIM(@subcategory_name));
    IF @organization_id IS NULL OR @category_id IS NULL THROW 53301, 'organization_id and category_id are required.', 1;
    IF @subcategory_name IS NULL OR @subcategory_name = N'' THROW 53310, 'Subcategory name is required.', 1;

    DECLARE @cat_org BIGINT = (SELECT organization_id FROM grac_practice.org_assurance_question_category
                               WHERE org_assurance_question_category_id = @category_id AND is_active = 1);
    IF @cat_org IS NULL THROW 53304, 'Category not found.', 1;
    IF @cat_org <> @organization_id THROW 53305, 'Category belongs to a different organization.', 1;

    IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_question_subcategory
               WHERE org_assurance_question_category_id = @category_id AND is_active = 1
                 AND subcategory_name = @subcategory_name
                 AND (@subcategory_id IS NULL OR org_assurance_question_subcategory_id <> @subcategory_id))
        THROW 53307, 'A subcategory with this name already exists in the category.', 1;

    IF @subcategory_id IS NULL
    BEGIN
        DECLARE @rs INT = (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
                           WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
        IF @rs IS NULL SET @rs = 1;
        INSERT grac_practice.org_assurance_question_subcategory
            (org_assurance_question_category_id, organization_id, subcategory_name, display_order,
             is_active, record_status_id, entered_by)
        VALUES (@category_id, @organization_id, @subcategory_name,
                ISNULL(@display_order, (SELECT ISNULL(MAX(display_order), 0) + 1
                                        FROM grac_practice.org_assurance_question_subcategory
                                        WHERE org_assurance_question_category_id = @category_id AND is_active = 1)),
                1, @rs, ISNULL(@actor, 'system'));
        SET @subcategory_id_out = SCOPE_IDENTITY();
        RETURN;
    END

    DECLARE @sub_org BIGINT, @sub_cat BIGINT;
    SELECT @sub_org = organization_id, @sub_cat = org_assurance_question_category_id
    FROM   grac_practice.org_assurance_question_subcategory
    WHERE  org_assurance_question_subcategory_id = @subcategory_id AND is_active = 1;
    IF @sub_org IS NULL THROW 53308, 'Subcategory not found.', 1;
    IF @sub_org <> @organization_id THROW 53305, 'Subcategory belongs to a different organization.', 1;
    -- Moving a subcategory that questions use would leave them in a
    -- category they were not filed under.
    IF @sub_cat <> @category_id AND EXISTS (
            SELECT 1 FROM grac_practice.org_assurance_question_repository
            WHERE org_assurance_question_subcategory_id = @subcategory_id AND is_active = 1)
        THROW 53309, 'This subcategory is used by questions in the repository, so it cannot move to another category.', 1;

    UPDATE grac_practice.org_assurance_question_subcategory
    SET    org_assurance_question_category_id = @category_id,
           subcategory_name = @subcategory_name,
           display_order    = ISNULL(@display_order, display_order),
           updated_by       = ISNULL(@actor, 'system'),
           updated_dt       = SYSUTCDATETIME()
    WHERE  org_assurance_question_subcategory_id = @subcategory_id;
    SET @subcategory_id_out = @subcategory_id;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_subcategory_delete  (soft)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_subcategory_delete
    @organization_id BIGINT,
    @subcategory_id  BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @subcategory_id IS NULL THROW 53301, 'organization_id and subcategory_id are required.', 1;

    DECLARE @org BIGINT = (SELECT organization_id FROM grac_practice.org_assurance_question_subcategory
                           WHERE org_assurance_question_subcategory_id = @subcategory_id AND is_active = 1);
    IF @org IS NULL THROW 53308, 'Subcategory not found.', 1;
    IF @org <> @organization_id THROW 53305, 'Subcategory belongs to a different organization.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_question_repository
               WHERE org_assurance_question_subcategory_id = @subcategory_id AND is_active = 1)
        THROW 53309, 'This subcategory is used by questions in the repository. Move those questions first.', 1;

    UPDATE grac_practice.org_assurance_question_subcategory
    SET    is_active = 0, updated_by = ISNULL(@actor, 'system'), updated_dt = SYSUTCDATETIME()
    WHERE  org_assurance_question_subcategory_id = @subcategory_id;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_repository_list
--   Result 1: TotalCount / PageNumber / PageSize.  Result 2: the page.
--   @exclude_set_id leaves out questions already in that set (the
--   Question Set picker); @status filters Active / Inactive.
--   UsedInSets = active sets holding the question.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_repository_list
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @category_id     BIGINT        = NULL,
    @subcategory_id  BIGINT        = NULL,
    @status          NVARCHAR(20)  = NULL,
    @exclude_set_id  BIGINT        = NULL,
    @page            INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 53301, 'organization_id is required.', 1;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @search = N'' SET @search = NULL;
    IF @status = N'' SET @status = NULL;

    SELECT r.org_assurance_question_repository_id AS id
    INTO   #ids
    FROM   grac_practice.org_assurance_question_repository r
    WHERE  r.organization_id = @organization_id
      AND  r.is_active = 1
      AND  (@search IS NULL OR r.question_code LIKE N'%' + @search + N'%'
                            OR r.question_text LIKE N'%' + @search + N'%')
      AND  (@category_id    IS NULL OR r.org_assurance_question_category_id    = @category_id)
      AND  (@subcategory_id IS NULL OR r.org_assurance_question_subcategory_id = @subcategory_id)
      AND  (@status         IS NULL OR r.status = @status)
      AND  (@exclude_set_id IS NULL OR NOT EXISTS (
                SELECT 1 FROM grac_practice.org_assurance_question q
                WHERE q.org_assurance_question_set_id = @exclude_set_id
                  AND q.repository_question_id = r.org_assurance_question_repository_id
                  AND q.is_active = 1));

    SELECT CAST(COUNT_BIG(1) AS BIGINT) AS TotalCount,
           CAST(@page      AS INT)      AS PageNumber,
           CAST(@page_size AS INT)      AS PageSize
    FROM   #ids;

    SELECT r.org_assurance_question_repository_id  AS RepositoryQuestionId,
           r.organization_id                       AS OrganizationId,
           r.question_code                         AS QuestionCode,
           r.question_text                         AS QuestionText,
           r.org_assurance_question_category_id    AS CategoryId,
           c.category_name                         AS CategoryName,
           r.org_assurance_question_subcategory_id AS SubcategoryId,
           s.subcategory_name                      AS SubcategoryName,
           r.guidance                              AS Guidance,
           r.question_type_id                      AS QuestionTypeId,
           r.question_type_code                    AS QuestionTypeCode,
           r.question_type_name                    AS QuestionTypeName,
           r.is_mandatory                          AS IsMandatory,
           r.evidence_required                     AS EvidenceRequired,
           r.expected_evidence                     AS ExpectedEvidence,
           r.weight                                AS Weight,
           r.status                                AS Status,
           r.version_number                        AS VersionNumber,
           (SELECT COUNT_BIG(DISTINCT q.org_assurance_question_set_id)
              FROM grac_practice.org_assurance_question q
              JOIN grac_practice.org_assurance_question_set qs
                ON qs.org_assurance_question_set_id = q.org_assurance_question_set_id AND qs.is_active = 1
             WHERE q.repository_question_id = r.org_assurance_question_repository_id
               AND q.is_active = 1)                AS UsedInSets,
           r.entered_by                            AS EnteredBy,
           r.entered_dt                            AS EnteredDt,
           r.updated_by                            AS UpdatedBy,
           r.updated_dt                            AS UpdatedDt
    FROM   #ids i
    JOIN   grac_practice.org_assurance_question_repository r
           ON r.org_assurance_question_repository_id = i.id
    JOIN   grac_practice.org_assurance_question_category c
           ON c.org_assurance_question_category_id = r.org_assurance_question_category_id
    LEFT JOIN grac_practice.org_assurance_question_subcategory s
           ON s.org_assurance_question_subcategory_id = r.org_assurance_question_subcategory_id
    ORDER  BY r.question_code, r.org_assurance_question_repository_id
    OFFSET (@page - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_repository_get  (same columns as the list)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_repository_get
    @organization_id        BIGINT,
    @repository_question_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @repository_question_id IS NULL
        THROW 53301, 'organization_id and repository_question_id are required.', 1;

    SELECT r.org_assurance_question_repository_id  AS RepositoryQuestionId,
           r.organization_id                       AS OrganizationId,
           r.question_code                         AS QuestionCode,
           r.question_text                         AS QuestionText,
           r.org_assurance_question_category_id    AS CategoryId,
           c.category_name                         AS CategoryName,
           r.org_assurance_question_subcategory_id AS SubcategoryId,
           s.subcategory_name                      AS SubcategoryName,
           r.guidance                              AS Guidance,
           r.question_type_id                      AS QuestionTypeId,
           r.question_type_code                    AS QuestionTypeCode,
           r.question_type_name                    AS QuestionTypeName,
           r.is_mandatory                          AS IsMandatory,
           r.evidence_required                     AS EvidenceRequired,
           r.expected_evidence                     AS ExpectedEvidence,
           r.weight                                AS Weight,
           r.status                                AS Status,
           r.version_number                        AS VersionNumber,
           (SELECT COUNT_BIG(DISTINCT q.org_assurance_question_set_id)
              FROM grac_practice.org_assurance_question q
              JOIN grac_practice.org_assurance_question_set qs
                ON qs.org_assurance_question_set_id = q.org_assurance_question_set_id AND qs.is_active = 1
             WHERE q.repository_question_id = r.org_assurance_question_repository_id
               AND q.is_active = 1)                AS UsedInSets,
           r.entered_by                            AS EnteredBy,
           r.entered_dt                            AS EnteredDt,
           r.updated_by                            AS UpdatedBy,
           r.updated_dt                            AS UpdatedDt
    FROM   grac_practice.org_assurance_question_repository r
    JOIN   grac_practice.org_assurance_question_category c
           ON c.org_assurance_question_category_id = r.org_assurance_question_category_id
    LEFT JOIN grac_practice.org_assurance_question_subcategory s
           ON s.org_assurance_question_subcategory_id = r.org_assurance_question_subcategory_id
    WHERE  r.org_assurance_question_repository_id = @repository_question_id
      AND  r.organization_id = @organization_id
      AND  r.is_active = 1;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_repository_save  (create / update)
--   Code is fixed after create.  Version goes up by one whenever the
--   question's content changes (status alone does not).  Every set item
--   linked to the question is kept in step with the content.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_repository_save
    @organization_id        BIGINT,
    @repository_question_id BIGINT        = NULL,
    @question_code          NVARCHAR(80),
    @question_text          NVARCHAR(MAX),
    @category_id            BIGINT,
    @subcategory_id         BIGINT        = NULL,
    @guidance               NVARCHAR(MAX) = NULL,
    @question_type_id       BIGINT        = NULL,
    @question_type_code     NVARCHAR(120) = NULL,
    @question_type_name     NVARCHAR(200) = NULL,
    @is_mandatory           BIT           = 0,
    @evidence_required      BIT           = 0,
    @expected_evidence      NVARCHAR(MAX) = NULL,
    @weight                 DECIMAL(10,2) = NULL,
    @status                 NVARCHAR(20)  = N'Active',
    @actor                  NVARCHAR(100) = 'system',
    @repository_question_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @question_code = LTRIM(RTRIM(@question_code));
    SET @question_text = LTRIM(RTRIM(@question_text));
    IF @guidance          = N'' SET @guidance = NULL;
    IF @expected_evidence = N'' SET @expected_evidence = NULL;
    SET @status = ISNULL(NULLIF(LTRIM(RTRIM(@status)), N''), N'Active');

    IF @organization_id IS NULL THROW 53301, 'organization_id is required.', 1;
    IF @repository_question_id IS NULL AND (@question_code IS NULL OR @question_code = N'')
        THROW 53313, 'Question Code is required.', 1;
    IF @question_text IS NULL OR @question_text = N'' THROW 53314, 'Question is required.', 1;
    IF @category_id IS NULL THROW 53315, 'Category is required.', 1;
    IF @question_type_id IS NULL AND @question_type_code IS NULL
        THROW 53316, 'Response Type is required.', 1;
    IF @status NOT IN (N'Active', N'Inactive') THROW 53319, 'Status must be Active or Inactive.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_question_category
                   WHERE org_assurance_question_category_id = @category_id
                     AND organization_id = @organization_id AND is_active = 1)
        THROW 53304, 'Category not found.', 1;
    IF @subcategory_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM grac_practice.org_assurance_question_subcategory
            WHERE org_assurance_question_subcategory_id = @subcategory_id
              AND org_assurance_question_category_id = @category_id
              AND organization_id = @organization_id AND is_active = 1)
        THROW 53318, 'The subcategory does not belong to the selected category.', 1;

    DECLARE @rs INT = (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
                       WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
    IF @rs IS NULL SET @rs = 1;

    BEGIN TRAN;

    IF @repository_question_id IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_question_repository WITH (UPDLOCK, HOLDLOCK)
                   WHERE organization_id = @organization_id AND question_code = @question_code AND is_active = 1)
        BEGIN
            ROLLBACK;
            THROW 53317, 'A question with this code already exists in the repository.', 1;
        END

        INSERT grac_practice.org_assurance_question_repository
            (organization_id, question_code, question_text,
             org_assurance_question_category_id, org_assurance_question_subcategory_id,
             guidance, question_type_id, question_type_code, question_type_name,
             is_mandatory, evidence_required, expected_evidence, weight,
             status, version_number, is_active, record_status_id, entered_by)
        VALUES
            (@organization_id, @question_code, @question_text,
             @category_id, @subcategory_id,
             @guidance, @question_type_id, @question_type_code, @question_type_name,
             ISNULL(@is_mandatory, 0), ISNULL(@evidence_required, 0), @expected_evidence, @weight,
             @status, 1, 1, @rs, ISNULL(@actor, 'system'));
        SET @repository_question_id_out = SCOPE_IDENTITY();
        COMMIT;
        RETURN;
    END

    DECLARE @org BIGINT = (SELECT organization_id FROM grac_practice.org_assurance_question_repository
                           WHERE org_assurance_question_repository_id = @repository_question_id AND is_active = 1);
    IF @org IS NULL BEGIN ROLLBACK; THROW 53311, 'Question not found in the repository.', 1; END
    IF @org <> @organization_id BEGIN ROLLBACK; THROW 53305, 'Question belongs to a different organization.', 1; END

    -- Content changed? (NULL-safe compare through EXCEPT.)
    DECLARE @content_changed BIT = 0;
    IF EXISTS (
        SELECT r.question_text, r.org_assurance_question_category_id, r.org_assurance_question_subcategory_id,
               r.guidance, r.question_type_id, r.question_type_code, r.is_mandatory, r.evidence_required,
               r.expected_evidence, r.weight
        FROM   grac_practice.org_assurance_question_repository r
        WHERE  r.org_assurance_question_repository_id = @repository_question_id
        EXCEPT
        SELECT @question_text, @category_id, @subcategory_id,
               @guidance, @question_type_id, @question_type_code, ISNULL(@is_mandatory, 0), ISNULL(@evidence_required, 0),
               @expected_evidence, @weight)
        SET @content_changed = 1;

    UPDATE grac_practice.org_assurance_question_repository
    SET    question_text      = @question_text,
           org_assurance_question_category_id    = @category_id,
           org_assurance_question_subcategory_id = @subcategory_id,
           guidance           = @guidance,
           question_type_id   = @question_type_id,
           question_type_code = @question_type_code,
           question_type_name = @question_type_name,
           is_mandatory       = ISNULL(@is_mandatory, 0),
           evidence_required  = ISNULL(@evidence_required, 0),
           expected_evidence  = @expected_evidence,
           weight             = @weight,
           status             = @status,
           version_number     = version_number + CASE WHEN @content_changed = 1 THEN 1 ELSE 0 END,
           updated_by         = ISNULL(@actor, 'system'),
           updated_dt         = SYSUTCDATETIME()
    WHERE  org_assurance_question_repository_id = @repository_question_id;

    -- Keep the sets that hold this question in step.
    IF @content_changed = 1
        UPDATE grac_practice.org_assurance_question
        SET    question_text      = @question_text,
               help_text          = @guidance,
               question_type_id   = @question_type_id,
               question_type_code = @question_type_code,
               question_type_name = @question_type_name,
               is_mandatory       = ISNULL(@is_mandatory, 0),
               weight             = @weight,
               updated_by         = ISNULL(@actor, 'system'),
               updated_dt         = SYSUTCDATETIME()
        WHERE  repository_question_id = @repository_question_id AND is_active = 1;

    SET @repository_question_id_out = @repository_question_id;
    COMMIT;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_repository_delete  (soft)
--   Refused while an active question set holds the question; it can be
--   made Inactive instead (no new set can pick it).
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_repository_delete
    @organization_id        BIGINT,
    @repository_question_id BIGINT,
    @actor                  NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @repository_question_id IS NULL
        THROW 53301, 'organization_id and repository_question_id are required.', 1;

    DECLARE @org BIGINT = (SELECT organization_id FROM grac_practice.org_assurance_question_repository
                           WHERE org_assurance_question_repository_id = @repository_question_id AND is_active = 1);
    IF @org IS NULL THROW 53311, 'Question not found in the repository.', 1;
    IF @org <> @organization_id THROW 53305, 'Question belongs to a different organization.', 1;

    IF EXISTS (SELECT 1
               FROM   grac_practice.org_assurance_question q
               JOIN   grac_practice.org_assurance_question_set qs
                      ON qs.org_assurance_question_set_id = q.org_assurance_question_set_id AND qs.is_active = 1
               WHERE  q.repository_question_id = @repository_question_id AND q.is_active = 1)
        THROW 53312, 'This question is used in a question set. Remove it from those sets first, or set its Status to Inactive.', 1;

    UPDATE grac_practice.org_assurance_question_repository
    SET    is_active = 0, updated_by = ISNULL(@actor, 'system'), updated_dt = SYSUTCDATETIME()
    WHERE  org_assurance_question_repository_id = @repository_question_id;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_set_add_from_repository
--   Adds Active Repository questions to a set, after its current last
--   question.  Questions already in the set are skipped.  A question
--   once removed from the set (soft-deleted row with the same code --
--   076's UNIQUE(set, code) is not filtered) is brought back instead of
--   inserted again.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_add_from_repository
    @organization_id         BIGINT,
    @question_set_id         BIGINT,
    @repository_question_ids NVARCHAR(MAX),          -- comma-separated ids
    @actor                   NVARCHAR(100) = 'system',
    @added_count             INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @added_count = 0;
    IF @organization_id IS NULL OR @question_set_id IS NULL
        THROW 53801, 'organization_id and question_set_id are required.', 1;

    DECLARE @set_org BIGINT = (SELECT organization_id FROM grac_practice.org_assurance_question_set
                               WHERE org_assurance_question_set_id = @question_set_id AND is_active = 1);
    IF @set_org IS NULL THROW 53806, 'Question set not found.', 1;
    IF @set_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;

    DECLARE @pick TABLE(repository_question_id BIGINT PRIMARY KEY, seq INT);
    INSERT @pick(repository_question_id, seq)
    SELECT x.id, MIN(x.seq)
    FROM  (SELECT TRY_CAST(LTRIM(RTRIM(v.value)) AS BIGINT) AS id,
                  CAST(v.ordinal AS INT) AS seq          -- order as picked (compat 160)
           FROM   STRING_SPLIT(ISNULL(@repository_question_ids, N''), N',', 1) v) x
    WHERE  x.id IS NOT NULL
    GROUP  BY x.id;
    IF NOT EXISTS (SELECT 1 FROM @pick) THROW 53322, 'Select at least one question.', 1;

    IF EXISTS (SELECT 1 FROM @pick p
               LEFT JOIN grac_practice.org_assurance_question_repository r
                      ON r.org_assurance_question_repository_id = p.repository_question_id
                     AND r.organization_id = @organization_id AND r.is_active = 1
               WHERE r.org_assurance_question_repository_id IS NULL)
        THROW 53311, 'A selected question was not found in the repository.', 1;
    IF EXISTS (SELECT 1 FROM @pick p
               JOIN grac_practice.org_assurance_question_repository r
                 ON r.org_assurance_question_repository_id = p.repository_question_id
               WHERE r.status <> N'Active')
        THROW 53323, 'Only Active questions can be added to a set.', 1;

    DECLARE @rs INT = (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
                       WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
    IF @rs IS NULL SET @rs = 1;

    BEGIN TRAN;

    DECLARE @base INT = ISNULL((SELECT MAX(display_order) FROM grac_practice.org_assurance_question
                                WHERE org_assurance_question_set_id = @question_set_id AND is_active = 1), 0);

    -- New to the set, in the order picked.
    SELECT r.org_assurance_question_repository_id AS rid, r.question_code, r.question_text, r.guidance,
           r.question_type_id, r.question_type_code, r.question_type_name, r.is_mandatory, r.weight,
           @base + ROW_NUMBER() OVER (ORDER BY p.seq) AS display_order
    INTO   #add
    FROM   @pick p
    JOIN   grac_practice.org_assurance_question_repository r
           ON r.org_assurance_question_repository_id = p.repository_question_id
    WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_question q
                       WHERE q.org_assurance_question_set_id = @question_set_id AND q.is_active = 1
                         AND (q.repository_question_id = r.org_assurance_question_repository_id
                              OR q.question_code = r.question_code));

    -- Bring back a removed row with the same code.
    UPDATE q
    SET    is_active = 1, repository_question_id = a.rid,
           question_text = a.question_text, help_text = a.guidance,
           question_type_id = a.question_type_id, question_type_code = a.question_type_code,
           question_type_name = a.question_type_name, is_mandatory = a.is_mandatory,
           weight = a.weight, display_order = a.display_order,
           updated_by = ISNULL(@actor, 'system'), updated_dt = SYSUTCDATETIME()
    FROM   grac_practice.org_assurance_question q
    JOIN   #add a ON a.question_code = q.question_code
    WHERE  q.org_assurance_question_set_id = @question_set_id AND q.is_active = 0;
    SET @added_count = @@ROWCOUNT;

    INSERT grac_practice.org_assurance_question
        (org_assurance_question_set_id, organization_id, question_code, question_text, help_text,
         question_type_id, question_type_code, question_type_name, is_mandatory, display_order,
         weight, expected_response, is_active, record_status_id, entered_by, entered_dt,
         repository_question_id)
    SELECT @question_set_id, @organization_id, a.question_code, a.question_text, a.guidance,
           a.question_type_id, a.question_type_code, a.question_type_name, a.is_mandatory, a.display_order,
           a.weight, NULL, 1, @rs, ISNULL(@actor, 'system'), SYSUTCDATETIME(),
           a.rid
    FROM   #add a
    WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_question q
                       WHERE q.org_assurance_question_set_id = @question_set_id
                         AND q.question_code = a.question_code);
    SET @added_count = @added_count + @@ROWCOUNT;

    COMMIT;
END
GO

-- ---------------------------------------------------------------------
-- 077 procedures, re-issued from their 077 bodies.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_list
    @organization_id BIGINT,
    @question_set_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @question_set_id IS NULL
        THROW 53802, 'organization_id and question_set_id are required.', 1;

    -- Verify ownership before returning rows.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_question_set
        WHERE org_assurance_question_set_id = @question_set_id
          AND organization_id = @organization_id)
        THROW 53807, 'Question set belongs to a different organization.', 1;

    SELECT q.org_assurance_question_id     AS QuestionId,
           q.org_assurance_question_set_id AS QuestionSetId,
           q.question_code                 AS QuestionCode,
           q.question_text                 AS QuestionText,
           q.help_text                     AS HelpText,
           q.question_type_id              AS QuestionTypeId,
           q.question_type_code            AS QuestionTypeCode,
           q.question_type_name            AS QuestionTypeName,
           q.is_mandatory                  AS IsMandatory,
           q.display_order                 AS DisplayOrder,
           q.weight                        AS Weight,
           q.expected_response             AS ExpectedResponse,
           q.entered_by                    AS EnteredBy,
           q.entered_dt                    AS EnteredDt,
           q.updated_by                    AS UpdatedBy,
           q.updated_dt                    AS UpdatedDt,
           -- 516
           q.repository_question_id        AS RepositoryQuestionId,
           c.category_name                 AS CategoryName,
           s.subcategory_name              AS SubcategoryName
    FROM grac_practice.org_assurance_question q
    LEFT JOIN grac_practice.org_assurance_question_repository r
           ON r.org_assurance_question_repository_id = q.repository_question_id
    LEFT JOIN grac_practice.org_assurance_question_category c
           ON c.org_assurance_question_category_id = r.org_assurance_question_category_id
    LEFT JOIN grac_practice.org_assurance_question_subcategory s
           ON s.org_assurance_question_subcategory_id = r.org_assurance_question_subcategory_id
    WHERE q.org_assurance_question_set_id = @question_set_id
      AND q.organization_id = @organization_id
      AND q.is_active = 1
    ORDER BY q.display_order, q.org_assurance_question_id;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_get
    @organization_id BIGINT,
    @question_id     BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @question_id IS NULL
        THROW 53802, 'organization_id and question_id are required.', 1;

    SELECT q.org_assurance_question_id     AS QuestionId,
           q.org_assurance_question_set_id AS QuestionSetId,
           q.question_code                 AS QuestionCode,
           q.question_text                 AS QuestionText,
           q.help_text                     AS HelpText,
           q.question_type_id              AS QuestionTypeId,
           q.question_type_code            AS QuestionTypeCode,
           q.question_type_name            AS QuestionTypeName,
           q.is_mandatory                  AS IsMandatory,
           q.display_order                 AS DisplayOrder,
           q.weight                        AS Weight,
           q.expected_response             AS ExpectedResponse,
           q.entered_by                    AS EnteredBy,
           q.entered_dt                    AS EnteredDt,
           q.updated_by                    AS UpdatedBy,
           q.updated_dt                    AS UpdatedDt,
           -- 516
           q.repository_question_id        AS RepositoryQuestionId,
           c.category_name                 AS CategoryName,
           s.subcategory_name              AS SubcategoryName
    FROM grac_practice.org_assurance_question q
    LEFT JOIN grac_practice.org_assurance_question_repository r
           ON r.org_assurance_question_repository_id = q.repository_question_id
    LEFT JOIN grac_practice.org_assurance_question_category c
           ON c.org_assurance_question_category_id = r.org_assurance_question_category_id
    LEFT JOIN grac_practice.org_assurance_question_subcategory s
           ON s.org_assurance_question_subcategory_id = r.org_assurance_question_subcategory_id
    WHERE q.org_assurance_question_id = @question_id
      AND q.organization_id = @organization_id
      AND q.is_active = 1;
END
GO

-- 077 body; 516: no create here (questions come from the Repository),
-- and a Repository-linked item takes only its Order from this call.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_save
    @organization_id       BIGINT,
    @question_set_id       BIGINT,
    @question_id           BIGINT        = NULL,
    @question_code         NVARCHAR(80),
    @question_text         NVARCHAR(MAX),
    @help_text             NVARCHAR(MAX) = NULL,
    @question_type_id      BIGINT        = NULL,
    @question_type_code    NVARCHAR(120) = NULL,
    @question_type_name    NVARCHAR(200) = NULL,
    @is_mandatory          BIT           = 0,
    @display_order         INT           = 0,
    @weight                DECIMAL(10,2) = NULL,
    @expected_response     NVARCHAR(MAX) = NULL,
    @actor                 NVARCHAR(100) = 'system',
    @question_id_out       BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @question_set_id IS NULL
        THROW 53801, 'organization_id and question_set_id are required.', 1;
    IF @question_id IS NULL
        THROW 53320, 'Questions are added to a set from the Question Repository.', 1;

    -- Verify set ownership.
    DECLARE @set_org BIGINT;
    SELECT @set_org = organization_id
    FROM grac_practice.org_assurance_question_set
    WHERE org_assurance_question_set_id = @question_set_id
      AND is_active = 1;

    IF @set_org IS NULL THROW 53806, 'Question set not found.', 1;
    IF @set_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;

    BEGIN TRAN;

    DECLARE @q_org BIGINT, @q_set BIGINT, @q_repo BIGINT;
    SELECT @q_org  = organization_id,
           @q_set  = org_assurance_question_set_id,
           @q_repo = repository_question_id
    FROM grac_practice.org_assurance_question
    WHERE org_assurance_question_id = @question_id
      AND is_active = 1;

    IF @q_org IS NULL BEGIN ROLLBACK; THROW 53811, 'Question not found.', 1; END
    IF @q_org <> @organization_id BEGIN ROLLBACK; THROW 53807, 'Question belongs to a different organization.', 1; END
    IF @q_set <> @question_set_id BEGIN ROLLBACK; THROW 53812, 'Question does not belong to the specified set.', 1; END

    IF @q_repo IS NOT NULL
    BEGIN
        -- Content is the Repository's; the set decides only the order.
        UPDATE grac_practice.org_assurance_question
        SET display_order = ISNULL(@display_order, 0),
            updated_by    = @actor,
            updated_dt    = SYSUTCDATETIME()
        WHERE org_assurance_question_id = @question_id;
    END
    ELSE
    BEGIN
        IF @question_text IS NULL OR LEN(LTRIM(RTRIM(@question_text))) = 0
        BEGIN ROLLBACK; THROW 53809, 'question_text is required.', 1; END

        UPDATE grac_practice.org_assurance_question
        SET question_text      = @question_text,
            help_text          = @help_text,
            question_type_id   = @question_type_id,
            question_type_code = @question_type_code,
            question_type_name = @question_type_name,
            is_mandatory       = ISNULL(@is_mandatory, 0),
            display_order      = ISNULL(@display_order, 0),
            weight             = @weight,
            expected_response  = @expected_response,
            updated_by         = @actor,
            updated_dt         = SYSUTCDATETIME()
        WHERE org_assurance_question_id = @question_id;
    END

    SET @question_id_out = @question_id;
    COMMIT;
END
GO

-- =====================================================================
-- 5. Existing set questions -> Repository questions
--    One Repository question per organization + code + text.  A code
--    used for DIFFERENT texts keeps the code on its first text; the
--    others get "-S<set id>".  Category "General".  Skipped for rows
--    already linked, so a re-run does nothing.
-- =====================================================================
DECLARE @org BIGINT;
DECLARE org_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT organization_id FROM grac_practice.organization;
OPEN org_cur;
FETCH NEXT FROM org_cur INTO @org;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC grac_practice.sp_org_assurance_question_category_ensure_defaults
         @organization_id = @org, @actor = N'migration-516';
    FETCH NEXT FROM org_cur INTO @org;
END
CLOSE org_cur;
DEALLOCATE org_cur;
GO

-- Temp tables live for the session; a re-run in the same window needs them gone.
DROP TABLE IF EXISTS #todo;
DROP TABLE IF EXISTS #grp;
SET XACT_ABORT ON;
BEGIN TRAN;

DECLARE @rs INT = (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
                   WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
IF @rs IS NULL SET @rs = 1;

-- Set questions still to link (active rows of active sets).
SELECT q.org_assurance_question_id, q.org_assurance_question_set_id, q.organization_id,
       q.question_code, HASHBYTES('SHA2_256', q.question_text) AS text_hash
INTO   #todo
FROM   grac_practice.org_assurance_question q
JOIN   grac_practice.org_assurance_question_set qs
       ON qs.org_assurance_question_set_id = q.org_assurance_question_set_id AND qs.is_active = 1
WHERE  q.is_active = 1 AND q.repository_question_id IS NULL;

-- One group per organization + code + text; its first row is the source.
SELECT g.organization_id, g.question_code, g.text_hash, g.first_qid, g.first_set_id,
       ROW_NUMBER() OVER (PARTITION BY g.organization_id, g.question_code ORDER BY g.first_qid) AS code_rank,
       CAST(NULL AS NVARCHAR(80)) AS repo_code,
       CAST(NULL AS BIGINT)       AS repo_id
INTO   #grp
FROM  (SELECT organization_id, question_code, text_hash,
              MIN(org_assurance_question_id)     AS first_qid,
              MIN(org_assurance_question_set_id) AS first_set_id
       FROM   #todo
       GROUP  BY organization_id, question_code, text_hash) g;

UPDATE #grp
SET    repo_code = CASE WHEN code_rank = 1 THEN question_code
                        ELSE LEFT(question_code, 60) + N'-S' + CAST(first_set_id AS NVARCHAR(20)) END;

-- A code the organization already has in the Repository (a re-run after
-- a partial one, or a question added by hand) is reused, not duplicated,
-- when the text matches; otherwise the group gets the -S suffix.
UPDATE g
SET    repo_id = r.org_assurance_question_repository_id
FROM   #grp g
JOIN   grac_practice.org_assurance_question_repository r
       ON r.organization_id = g.organization_id AND r.question_code = g.repo_code AND r.is_active = 1
      AND HASHBYTES('SHA2_256', r.question_text) = g.text_hash;
UPDATE g
SET    repo_code = LEFT(g.question_code, 60) + N'-S' + CAST(g.first_set_id AS NVARCHAR(20))
FROM   #grp g
WHERE  g.repo_id IS NULL
  AND  EXISTS (SELECT 1 FROM grac_practice.org_assurance_question_repository r
               WHERE r.organization_id = g.organization_id AND r.question_code = g.repo_code AND r.is_active = 1);

-- Create the Repository questions (MERGE so OUTPUT can carry first_qid).
DECLARE @made TABLE(repo_id BIGINT, first_qid BIGINT);
MERGE grac_practice.org_assurance_question_repository AS t
USING (
    SELECT g.first_qid, g.organization_id, g.repo_code, q.question_text, q.help_text,
           q.question_type_id, q.question_type_code, q.question_type_name, q.is_mandatory, q.weight,
           c.org_assurance_question_category_id AS category_id
    FROM   #grp g
    JOIN   grac_practice.org_assurance_question q ON q.org_assurance_question_id = g.first_qid
    JOIN   grac_practice.org_assurance_question_category c
           ON c.organization_id = g.organization_id AND c.category_name = N'General' AND c.is_active = 1
    WHERE  g.repo_id IS NULL
) AS s ON 1 = 0
WHEN NOT MATCHED BY TARGET THEN INSERT
    (organization_id, question_code, question_text, org_assurance_question_category_id,
     guidance, question_type_id, question_type_code, question_type_name,
     is_mandatory, evidence_required, weight, status, version_number, is_active, record_status_id, entered_by)
VALUES
    (s.organization_id, s.repo_code, s.question_text, s.category_id,
     s.help_text, s.question_type_id, s.question_type_code, s.question_type_name,
     s.is_mandatory, 0, s.weight, N'Active', 1, 1, @rs, N'migration-516')
OUTPUT inserted.org_assurance_question_repository_id, s.first_qid INTO @made(repo_id, first_qid);

UPDATE g SET repo_id = m.repo_id
FROM   #grp g JOIN @made m ON m.first_qid = g.first_qid
WHERE  g.repo_id IS NULL;

IF EXISTS (SELECT 1 FROM #grp WHERE repo_id IS NULL)
BEGIN
    ROLLBACK;
    THROW 53399, 'ABORT (516): an organization with set questions has no "General" category. Nothing in section 5 was changed.', 1;
END

-- Back up, then link the set rows (and give them the Repository code).
INSERT grac_practice.migration_516_question_backup(org_assurance_question_id, question_code_before)
SELECT t.org_assurance_question_id, t.question_code
FROM   #todo t
WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.migration_516_question_backup b
                   WHERE b.org_assurance_question_id = t.org_assurance_question_id);

UPDATE q
SET    repository_question_id = g.repo_id,
       question_code          = g.repo_code,
       updated_by             = N'migration-516',
       updated_dt             = SYSUTCDATETIME()
FROM   grac_practice.org_assurance_question q
JOIN   #todo t ON t.org_assurance_question_id = q.org_assurance_question_id
JOIN   #grp  g ON g.organization_id = t.organization_id AND g.question_code = t.question_code
              AND g.text_hash = t.text_hash;

DECLARE @linked INT = @@ROWCOUNT;
COMMIT;
PRINT '516: set questions linked to the Repository = ' + CAST(@linked AS NVARCHAR(20));
GO
SET XACT_ABORT OFF;
GO

-- =====================================================================
-- 6. Menu: Audit Assurance -> Question Repository
-- =====================================================================
DECLARE @assurance_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'org-assurance-question-repository', N'Question Repository',
     N'Practice/org-assurance-question-repository', 445, N'book-open')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @assurance_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Audit Assurance',
    status = N'Active', updated_by = 'seed-516', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @assurance_id, src.display_order,
     src.icon_class, N'Audit Assurance', N'Active', 'seed-516');
PRINT '516: question repository menu row upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- Every active role in every active organization, as 476 did.
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 1, 1,
       N'Active', @active_rs, N'seed-516', SYSUTCDATETIME()
FROM   grac_practice.organization_role r
JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
JOIN   grac_practice.menu_master m ON m.menu_key = N'org-assurance-question-repository'
WHERE  o.status = N'Active' AND r.status = N'Active'
  AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission p
        WHERE p.role_id = r.role_id AND p.menu_id = m.menu_id);
PRINT '516: question repository permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 7. Verification
-- =====================================================================
SELECT N'516-a tables' AS [Check],
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_question_repository','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.org_assurance_question_category','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.org_assurance_question_subcategory','U') IS NOT NULL
             AND COL_LENGTH('grac_practice.org_assurance_question','repository_question_id') IS NOT NULL
            THEN N'PASS' ELSE N'FAIL' END AS Result;
GO
SELECT N'516-b organizations without the default categories' AS [Check],
       COUNT(*) AS Organizations,
       CASE WHEN COUNT(*) = 0 THEN N'PASS' ELSE N'FAIL' END AS Result
FROM   grac_practice.organization o
WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_question_category_seed s
                   WHERE s.organization_id = o.organization_id);
GO
SELECT N'516-c set questions not linked to the Repository' AS [Check],
       COUNT(*) AS Questions,
       CASE WHEN COUNT(*) = 0 THEN N'PASS' ELSE N'FAIL' END AS Result
FROM   grac_practice.org_assurance_question q
JOIN   grac_practice.org_assurance_question_set qs
       ON qs.org_assurance_question_set_id = q.org_assurance_question_set_id AND qs.is_active = 1
WHERE  q.is_active = 1 AND q.repository_question_id IS NULL;
GO
SELECT N'516-d menu row' AS [Check],
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master m
                         JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
                         WHERE m.menu_key = N'org-assurance-question-repository'
                           AND p.menu_key = N'nav-assurance' AND m.status = N'Active')
            THEN N'PASS' ELSE N'FAIL' END AS Result;
GO

PRINT '516 complete.';
GO
SET NOEXEC OFF;
GO
