-- =====================================================================
-- 520 ROLLBACK
--   * sp_org_assurance_question_list / _get / _save back to their 077
--     bodies; sp_org_assurance_question_set_questions_save dropped;
--   * the 520 question columns dropped (Evidence Type, Evidence Required,
--     Expected Evidence, Status, Version are lost);
--   * Question Sets menu row back to how 274 had it before 516/520
--     (Inactive, under Audit Definition, 30).
--   The 516 Question Repository is NOT recreated; run 516 again if it is
--   wanted (it rebuilds the Repository from the set questions).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
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
           q.updated_dt                    AS UpdatedDt
    FROM grac_practice.org_assurance_question q
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
           q.updated_dt                    AS UpdatedDt
    FROM grac_practice.org_assurance_question q
    WHERE q.org_assurance_question_id = @question_id
      AND q.organization_id = @organization_id
      AND q.is_active = 1;
END
GO

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
    IF @question_code IS NULL OR LEN(LTRIM(RTRIM(@question_code))) = 0
        THROW 53808, 'question_code is required.', 1;
    IF @question_text IS NULL OR LEN(LTRIM(RTRIM(@question_text))) = 0
        THROW 53809, 'question_text is required.', 1;

    -- Verify set ownership.
    DECLARE @set_org BIGINT;
    SELECT @set_org = organization_id
    FROM grac_practice.org_assurance_question_set
    WHERE org_assurance_question_set_id = @question_set_id
      AND is_active = 1;

    IF @set_org IS NULL THROW 53806, 'Question set not found.', 1;
    IF @set_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    BEGIN TRAN;

    IF @question_id IS NULL
    BEGIN
        IF EXISTS (
            SELECT 1 FROM grac_practice.org_assurance_question
            WHERE org_assurance_question_set_id = @question_set_id
              AND question_code = @question_code
              AND is_active = 1)
        BEGIN
            ROLLBACK;
            THROW 53810, 'A question with this code already exists in the set.', 1;
        END

        INSERT INTO grac_practice.org_assurance_question
            (org_assurance_question_set_id, organization_id,
             question_code, question_text, help_text,
             question_type_id, question_type_code, question_type_name,
             is_mandatory, display_order, weight, expected_response,
             is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@question_set_id, @organization_id,
             @question_code, @question_text, @help_text,
             @question_type_id, @question_type_code, @question_type_name,
             ISNULL(@is_mandatory, 0), ISNULL(@display_order, 0),
             @weight, @expected_response,
             1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @question_id_out = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        DECLARE @q_org BIGINT, @q_set BIGINT;
        SELECT @q_org = organization_id,
               @q_set = org_assurance_question_set_id
        FROM grac_practice.org_assurance_question
        WHERE org_assurance_question_id = @question_id
          AND is_active = 1;

        IF @q_org IS NULL BEGIN ROLLBACK; THROW 53811, 'Question not found.', 1; END
        IF @q_org <> @organization_id BEGIN ROLLBACK; THROW 53807, 'Question belongs to a different organization.', 1; END
        IF @q_set <> @question_set_id BEGIN ROLLBACK; THROW 53812, 'Question does not belong to the specified set.', 1; END

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

        SET @question_id_out = @question_id;
    END

    COMMIT;
END
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_question_set_questions_save;
GO

IF OBJECT_ID('grac_practice.ck_pm_oa_question_status','C') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_question DROP CONSTRAINT ck_pm_oa_question_status;
IF OBJECT_ID('grac_practice.df_pm_oa_question_status','D') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_question DROP CONSTRAINT df_pm_oa_question_status;
IF OBJECT_ID('grac_practice.df_pm_oa_question_evid','D') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_question DROP CONSTRAINT df_pm_oa_question_evid;
IF OBJECT_ID('grac_practice.df_pm_oa_question_ver','D') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_question DROP CONSTRAINT df_pm_oa_question_ver;
GO
IF OBJECT_ID('grac_practice.fk_pm_oa_question_evidence_type','F') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_question DROP CONSTRAINT fk_pm_oa_question_evidence_type;
GO
IF COL_LENGTH('grac_practice.org_assurance_question','evidence_type_id') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_question DROP COLUMN evidence_type_id, evidence_type_code, evidence_type_name;
IF COL_LENGTH('grac_practice.org_assurance_question','status') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_question DROP COLUMN status;
IF COL_LENGTH('grac_practice.org_assurance_question','version_number') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_question DROP COLUMN version_number;
IF COL_LENGTH('grac_practice.org_assurance_question','evidence_required') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_question DROP COLUMN evidence_required;
IF COL_LENGTH('grac_practice.org_assurance_question','expected_evidence') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_question DROP COLUMN expected_evidence;
GO

DECLARE @def_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'org-audit-definition');
UPDATE grac_practice.menu_master
SET    parent_menu_id = @def_id, display_order = 30, status = N'Inactive',
       updated_by = 'rollback-520', updated_dt = SYSUTCDATETIME()
WHERE  menu_key = N'org-assurance-question-sets';
GO

PRINT '520 rollback complete. Put the 274 Question Sets row and parent link back as well.';
GO
