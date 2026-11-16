-- =====================================================================
-- 520  Audit: back to Question Sets, questions entered in the set's grid
--      (replaces the 516 Question Repository)
--
-- REQUEST (2026-11-05)
--   Remove the Question Repository and its Category / Subcategory, and
--   go back to Question Sets -- but with one page per set: the set's
--   name and details, then its questions entered directly in a grid on
--   the same page, saved together. The menu reads "Question Sets".
--   Each question keeps the fields asked for on 2026-11-05 except
--   Category / Subcategory: Code, Question, Description / Guidance,
--   Response Type, Mandatory, Evidence Required, Expected Evidence,
--   Weight, Status, system-managed Version.
--
-- WHAT THIS DOES
--   1. org_assurance_question gains evidence_type_id / _code / _name,
--      evidence_required, expected_evidence, status (Active / Inactive)
--      and version_number.  Description / Guidance is the existing
--      help_text.
--      Evidence (2026-11-05, same day): ONE input -- the question's
--      Evidence Type from grac_practice.evidence_type_master (the list
--      Evidence Config uses), or "Not Applicable" (NULL).  A type chosen
--      means evidence is required: evidence_required is derived from it
--      (kept so existing readers of the flag keep working).
--      Already ran an earlier copy of 520?  Run this one again: every
--      step is guarded / CREATE OR ALTER, so it only adds what is new.
--   2. If 516 ran: each set question takes Evidence Required, Expected
--      Evidence, Status and Version from the Repository question it was
--      linked to (text, guidance, type, mandatory and weight were already
--      kept in step by 516); a code that 516 suffixed with "-S<set>" gets
--      its original code back when no other question in the set uses it.
--      Then everything 516 added is removed: the repository_question_id
--      link, the 11 procedures, the Repository / Category / Subcategory
--      tables and the 'org-assurance-question-repository' menu row.
--      Questions created only in the Repository and never put in a set
--      are reported (520-b) before they are dropped.
--   3. Procedures:
--        sp_org_assurance_question_list / _get  077 body + the new columns
--        sp_org_assurance_question_save         077 body + the new fields;
--                                               creates again; version +1
--                                               when the content changes
--        sp_org_assurance_question_set_questions_save   NEW -- saves the
--          set page's whole grid in one call (JSON): updates, inserts and
--          removes (rows left out of the grid are soft-deleted).
--   4. Menu: 'org-assurance-question-sets' (Question Sets) is Active again,
--      directly under Audit Assurance at 445, with full rights for every
--      active role that lacks them.  274 edited to match.
--
-- New error numbers 53813-53817 (Question Builder block).
-- SAFE TO RE-RUN.  Requires 076 / 077.
-- Rollback: 520_question_sets_inline_questions_rollback.sql
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
BEGIN PRINT 'ABORT (520): run 076 / 077 first.'; SET @prereqs_ok = 0; END
IF COL_LENGTH('grac_practice.org_assurance_question','expected_response') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_question','question_type_name') IS NULL
BEGIN PRINT 'ABORT (520): org_assurance_question is not the 076 shape.'; SET @prereqs_ok = 0; END
IF OBJECT_ID('grac_practice.evidence_type_master','U') IS NULL
BEGIN PRINT 'ABORT (520): grac_practice.evidence_type_master missing (001).'; SET @prereqs_ok = 0; END
IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance')
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-assurance-question-sets')
BEGIN PRINT 'ABORT (520): nav-assurance / org-assurance-question-sets menu rows missing. Run 274 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 0
BEGIN
    RAISERROR('520: prerequisites missing -- see PRINT messages above. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. New question columns
-- =====================================================================
IF COL_LENGTH('grac_practice.org_assurance_question','evidence_required') IS NULL
    ALTER TABLE grac_practice.org_assurance_question
        ADD evidence_required BIT NOT NULL CONSTRAINT df_pm_oa_question_evid DEFAULT 0;
GO
IF COL_LENGTH('grac_practice.org_assurance_question','evidence_type_id') IS NULL
    ALTER TABLE grac_practice.org_assurance_question
        ADD evidence_type_id   INT           NULL
                CONSTRAINT fk_pm_oa_question_evidence_type
                REFERENCES grac_practice.evidence_type_master(evidence_type_id),
            evidence_type_code NVARCHAR(60)  NULL,
            evidence_type_name NVARCHAR(160) NULL;
GO
IF COL_LENGTH('grac_practice.org_assurance_question','expected_evidence') IS NULL
    ALTER TABLE grac_practice.org_assurance_question ADD expected_evidence NVARCHAR(MAX) NULL;
GO
IF COL_LENGTH('grac_practice.org_assurance_question','status') IS NULL
    ALTER TABLE grac_practice.org_assurance_question
        ADD status NVARCHAR(20) NOT NULL CONSTRAINT df_pm_oa_question_status DEFAULT N'Active'
            CONSTRAINT ck_pm_oa_question_status CHECK (status IN (N'Active', N'Inactive'));
GO
IF COL_LENGTH('grac_practice.org_assurance_question','version_number') IS NULL
    ALTER TABLE grac_practice.org_assurance_question
        ADD version_number INT NOT NULL CONSTRAINT df_pm_oa_question_ver DEFAULT 1;
GO

-- =====================================================================
-- 2. Undo 516 (only when it ran)
-- =====================================================================

-- 520-b: Repository questions that are in no set -- they go with the
-- Repository.  Listed so nothing disappears unseen.
IF OBJECT_ID('grac_practice.org_assurance_question_repository','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.org_assurance_question','repository_question_id') IS NOT NULL
    EXEC sp_executesql N'
    SELECT N''520-b repository questions in no set (dropped with the Repository)'' AS [Check],
           r.organization_id AS OrganizationId, r.question_code AS QuestionCode, r.question_text AS QuestionText
    FROM   grac_practice.org_assurance_question_repository r
    WHERE  r.is_active = 1
      AND  NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_question q
                       WHERE q.repository_question_id = r.org_assurance_question_repository_id
                         AND q.is_active = 1);';
GO

-- Copy the Repository-only fields back onto the set questions.
IF OBJECT_ID('grac_practice.org_assurance_question_repository','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.org_assurance_question','repository_question_id') IS NOT NULL
BEGIN
    DECLARE @n INT;
    EXEC sp_executesql N'
    UPDATE q
    SET    evidence_required = r.evidence_required,
           expected_evidence = r.expected_evidence,
           status            = r.status,
           version_number    = r.version_number,
           help_text         = r.guidance,
           question_text     = r.question_text,
           question_type_id  = r.question_type_id,
           question_type_code= r.question_type_code,
           question_type_name= r.question_type_name,
           is_mandatory      = r.is_mandatory,
           weight            = r.weight
    FROM   grac_practice.org_assurance_question q
    JOIN   grac_practice.org_assurance_question_repository r
           ON r.org_assurance_question_repository_id = q.repository_question_id;
    SET @n = @@ROWCOUNT;', N'@n INT OUTPUT', @n = @n OUTPUT;
    PRINT '520: set questions given their Repository fields = ' + CAST(@n AS NVARCHAR(20));
END
GO

-- Original codes back (516 suffixed clashing codes for the Repository).
IF OBJECT_ID('grac_practice.migration_516_question_backup','U') IS NOT NULL
BEGIN
    DECLARE @n2 INT;
    EXEC sp_executesql N'
    UPDATE q
    SET    question_code = b.question_code_before
    FROM   grac_practice.org_assurance_question q
    JOIN   grac_practice.migration_516_question_backup b
           ON b.org_assurance_question_id = q.org_assurance_question_id
    WHERE  q.question_code <> b.question_code_before
      AND  NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_question o
                       WHERE o.org_assurance_question_set_id = q.org_assurance_question_set_id
                         AND o.question_code = b.question_code_before
                         AND o.org_assurance_question_id <> q.org_assurance_question_id);
    SET @n = @@ROWCOUNT;', N'@n INT OUTPUT', @n = @n2 OUTPUT;
    PRINT '520: original question codes restored = ' + CAST(@n2 AS NVARCHAR(20));
END
GO

-- Drop the link, then the 516 objects.
IF COL_LENGTH('grac_practice.org_assurance_question','repository_question_id') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_oa_question_repository'
               AND object_id = OBJECT_ID('grac_practice.org_assurance_question'))
        DROP INDEX ix_pm_oa_question_repository ON grac_practice.org_assurance_question;
    IF OBJECT_ID('grac_practice.fk_pm_oa_question_repository','F') IS NOT NULL
        ALTER TABLE grac_practice.org_assurance_question DROP CONSTRAINT fk_pm_oa_question_repository;
    ALTER TABLE grac_practice.org_assurance_question DROP COLUMN repository_question_id;
    PRINT '520: repository_question_id removed.';
END
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_question_set_add_from_repository;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_question_repository_delete;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_question_repository_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_question_repository_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_question_repository_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_question_subcategory_delete;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_question_subcategory_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_question_category_delete;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_question_category_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_question_category_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_question_category_ensure_defaults;
GO
DROP TABLE IF EXISTS grac_practice.org_assurance_question_repository;
DROP TABLE IF EXISTS grac_practice.org_assurance_question_subcategory;
DROP TABLE IF EXISTS grac_practice.org_assurance_question_category_seed;
DROP TABLE IF EXISTS grac_practice.org_assurance_question_category;
DROP TABLE IF EXISTS grac_practice.org_assurance_question_category_default;
DROP TABLE IF EXISTS grac_practice.migration_516_question_backup;
GO

-- =====================================================================
-- 3. Procedures
-- =====================================================================
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
           -- 520
           q.evidence_required             AS EvidenceRequired,
           q.evidence_type_id              AS EvidenceTypeId,
           q.evidence_type_code            AS EvidenceTypeCode,
           q.evidence_type_name            AS EvidenceTypeName,
           q.expected_evidence             AS ExpectedEvidence,
           q.status                        AS Status,
           q.version_number                AS VersionNumber
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
           q.updated_dt                    AS UpdatedDt,
           -- 520
           q.evidence_required             AS EvidenceRequired,
           q.evidence_type_id              AS EvidenceTypeId,
           q.evidence_type_code            AS EvidenceTypeCode,
           q.evidence_type_name            AS EvidenceTypeName,
           q.expected_evidence             AS ExpectedEvidence,
           q.status                        AS Status,
           q.version_number                AS VersionNumber
    FROM grac_practice.org_assurance_question q
    WHERE q.org_assurance_question_id = @question_id
      AND q.organization_id = @organization_id
      AND q.is_active = 1;
END
GO

-- 077 body + 520 fields (Evidence Required, Expected Evidence, Status)
-- and Version (+1 when the content changes).
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
    @evidence_type_id      INT           = NULL,      -- 520: NULL = Not Applicable
    @evidence_type_code    NVARCHAR(60)  = NULL,
    @evidence_type_name    NVARCHAR(160) = NULL,
    @expected_evidence     NVARCHAR(MAX) = NULL,      -- 520
    @status                NVARCHAR(20)  = N'Active', -- 520
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
    SET @status = ISNULL(NULLIF(LTRIM(RTRIM(@status)), N''), N'Active');
    IF @status NOT IN (N'Active', N'Inactive')
        THROW 53814, 'Status must be Active or Inactive.', 1;

    -- Evidence: a type from the master, or Not Applicable (NULL).
    IF @evidence_type_id IS NOT NULL
    BEGIN
        SELECT @evidence_type_code = evidence_type_code, @evidence_type_name = evidence_type_name
        FROM grac_practice.evidence_type_master WHERE evidence_type_id = @evidence_type_id;
        IF @evidence_type_code IS NULL THROW 53817, 'Evidence type not found.', 1;
    END
    ELSE SELECT @evidence_type_code = NULL, @evidence_type_name = NULL;
    DECLARE @evidence_required BIT = CASE WHEN @evidence_type_id IS NULL THEN 0 ELSE 1 END;

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
             evidence_required, evidence_type_id, evidence_type_code, evidence_type_name,
             expected_evidence, status, version_number,
             is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@question_set_id, @organization_id,
             @question_code, @question_text, @help_text,
             @question_type_id, @question_type_code, @question_type_name,
             ISNULL(@is_mandatory, 0), ISNULL(@display_order, 0),
             @weight, @expected_response,
             @evidence_required, @evidence_type_id, @evidence_type_code, @evidence_type_name,
             @expected_evidence, @status, 1,
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

        DECLARE @changed BIT = 0;
        IF EXISTS (
            SELECT question_text, help_text, question_type_id, question_type_code, is_mandatory,
                   weight, expected_response, evidence_type_id, expected_evidence
            FROM grac_practice.org_assurance_question WHERE org_assurance_question_id = @question_id
            EXCEPT
            SELECT @question_text, @help_text, @question_type_id, @question_type_code, ISNULL(@is_mandatory, 0),
                   @weight, @expected_response, @evidence_type_id, @expected_evidence)
            SET @changed = 1;

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
            evidence_required  = @evidence_required,
            evidence_type_id   = @evidence_type_id,
            evidence_type_code = @evidence_type_code,
            evidence_type_name = @evidence_type_name,
            expected_evidence  = @expected_evidence,
            status             = @status,
            version_number     = version_number + CASE WHEN @changed = 1 THEN 1 ELSE 0 END,
            updated_by         = @actor,
            updated_dt         = SYSUTCDATETIME()
        WHERE org_assurance_question_id = @question_id;

        SET @question_id_out = @question_id;
    END

    COMMIT;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_set_questions_save   (NEW)
--   The set page's questions grid, saved in one call.
--   @questions_json = [ { "questionId": 12 | null, "questionCode": "...",
--     "questionText": "...", "helpText": "...", "questionTypeId": 1,
--     "questionTypeCode": "...", "questionTypeName": "...",
--     "isMandatory": true, "evidenceTypeId": 3 | null (Not Applicable),
--     "expectedEvidence": "...", "weight": 1.5, "status": "Active",
--     "displayOrder": 1 }, ... ]
--   * a row with questionId updates that question (its code is fixed);
--   * a row without one is inserted -- or, when the set once had a
--     question with that code (removed rows keep their code: 076's
--     UNIQUE(set, code) is not filtered), that question is brought back;
--   * a saved question missing from the grid is removed (soft delete).
--   Version: +1 on a content change; 1 for a new question.
--   All or nothing.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_questions_save
    @organization_id BIGINT,
    @question_set_id BIGINT,
    @questions_json  NVARCHAR(MAX),
    @actor           NVARCHAR(100) = 'system',
    @saved_count     INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @saved_count = 0;
    SET @actor = ISNULL(@actor, 'system');

    IF @organization_id IS NULL OR @question_set_id IS NULL
        THROW 53801, 'organization_id and question_set_id are required.', 1;
    IF @questions_json IS NULL SET @questions_json = N'[]';
    IF ISJSON(@questions_json) <> 1 THROW 53816, 'The questions could not be read.', 1;

    DECLARE @set_org BIGINT = (SELECT organization_id FROM grac_practice.org_assurance_question_set
                               WHERE org_assurance_question_set_id = @question_set_id AND is_active = 1);
    IF @set_org IS NULL THROW 53806, 'Question set not found.', 1;
    IF @set_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;

    DROP TABLE IF EXISTS #g;
    SELECT CAST(j.[key] AS INT) + 1                          AS row_no,
           x.question_id,
           NULLIF(LTRIM(RTRIM(x.question_code)), N'')        AS question_code,
           NULLIF(LTRIM(RTRIM(x.question_text)), N'')        AS question_text,
           NULLIF(x.help_text, N'')                          AS help_text,
           x.question_type_id,
           NULLIF(x.question_type_code, N'')                 AS question_type_code,
           NULLIF(x.question_type_name, N'')                 AS question_type_name,
           ISNULL(x.is_mandatory, 0)                         AS is_mandatory,
           x.evidence_type_id,
           CAST(NULL AS NVARCHAR(60))                        AS evidence_type_code,
           CAST(NULL AS NVARCHAR(160))                       AS evidence_type_name,
           CAST(CASE WHEN x.evidence_type_id IS NULL THEN 0 ELSE 1 END AS BIT) AS evidence_required,
           NULLIF(x.expected_evidence, N'')                  AS expected_evidence,
           x.weight,
           ISNULL(NULLIF(LTRIM(RTRIM(x.status)), N''), N'Active') AS status,
           ISNULL(x.display_order, CAST(j.[key] AS INT) + 1)  AS display_order
    INTO   #g
    FROM   OPENJSON(@questions_json) j
    CROSS APPLY OPENJSON(j.[value]) WITH (
           question_id         BIGINT         '$.questionId',
           question_code       NVARCHAR(80)   '$.questionCode',
           question_text       NVARCHAR(MAX)  '$.questionText',
           help_text           NVARCHAR(MAX)  '$.helpText',
           question_type_id    BIGINT         '$.questionTypeId',
           question_type_code  NVARCHAR(120)  '$.questionTypeCode',
           question_type_name  NVARCHAR(200)  '$.questionTypeName',
           is_mandatory        BIT            '$.isMandatory',
           evidence_type_id    INT            '$.evidenceTypeId',
           expected_evidence   NVARCHAR(MAX)  '$.expectedEvidence',
           weight              DECIMAL(10,2)  '$.weight',
           status              NVARCHAR(20)   '$.status',
           display_order       INT            '$.displayOrder') x;

    -- Evidence type code / name from the master (the id is what is chosen).
    UPDATE g SET evidence_type_code = m.evidence_type_code, evidence_type_name = m.evidence_type_name
    FROM   #g g JOIN grac_practice.evidence_type_master m ON m.evidence_type_id = g.evidence_type_id;

    -- Saved rows keep their code (fixed after create).
    UPDATE g SET question_code = q.question_code
    FROM   #g g JOIN grac_practice.org_assurance_question q
           ON q.org_assurance_question_id = g.question_id;

    DECLARE @bad INT, @msg NVARCHAR(400);
    SELECT TOP 1 @bad = row_no FROM #g WHERE question_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_question q
        WHERE q.org_assurance_question_id = #g.question_id
          AND q.org_assurance_question_set_id = @question_set_id AND q.is_active = 1) ORDER BY row_no;
    IF @bad IS NOT NULL
    BEGIN SET @msg = CONCAT(N'Row ', @bad, N': this question is not in the set any more. Reload the page.'); THROW 53812, @msg, 1; END

    SET @bad = NULL;
    SELECT TOP 1 @bad = row_no FROM #g WHERE question_code IS NULL ORDER BY row_no;
    IF @bad IS NOT NULL BEGIN SET @msg = CONCAT(N'Row ', @bad, N': Question Code is required.'); THROW 53808, @msg, 1; END
    SELECT TOP 1 @bad = row_no FROM #g WHERE question_text IS NULL ORDER BY row_no;
    IF @bad IS NOT NULL BEGIN SET @msg = CONCAT(N'Row ', @bad, N': Question is required.'); THROW 53809, @msg, 1; END
    SELECT TOP 1 @bad = row_no FROM #g WHERE question_type_id IS NULL AND question_type_code IS NULL ORDER BY row_no;
    IF @bad IS NOT NULL BEGIN SET @msg = CONCAT(N'Row ', @bad, N': Response Type is required.'); THROW 53813, @msg, 1; END
    SELECT TOP 1 @bad = row_no FROM #g WHERE status NOT IN (N'Active', N'Inactive') ORDER BY row_no;
    IF @bad IS NOT NULL BEGIN SET @msg = CONCAT(N'Row ', @bad, N': Status must be Active or Inactive.'); THROW 53814, @msg, 1; END

    SELECT TOP 1 @bad = row_no FROM #g WHERE evidence_type_id IS NOT NULL AND evidence_type_code IS NULL ORDER BY row_no;
    IF @bad IS NOT NULL BEGIN SET @msg = CONCAT(N'Row ', @bad, N': Evidence type not found.'); THROW 53817, @msg, 1; END

    DECLARE @dup NVARCHAR(80) = (SELECT TOP 1 question_code FROM #g GROUP BY question_code HAVING COUNT(*) > 1 ORDER BY question_code);
    IF @dup IS NOT NULL
    BEGIN SET @msg = CONCAT(N'Question Code "', @dup, N'" is used on more than one row.'); THROW 53815, @msg, 1; END

    DECLARE @rs INT = (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
                       WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
    IF @rs IS NULL SET @rs = 1;

    BEGIN TRAN;

    -- Removed from the grid.
    UPDATE q SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    FROM   grac_practice.org_assurance_question q
    WHERE  q.org_assurance_question_set_id = @question_set_id AND q.is_active = 1
      AND  NOT EXISTS (SELECT 1 FROM #g g WHERE g.question_id = q.org_assurance_question_id);

    -- Saved rows: update; version +1 when the content changed.
    UPDATE q
    SET    version_number = q.version_number + CASE WHEN EXISTS (
                SELECT q.question_text, q.help_text, q.question_type_id, q.question_type_code, q.is_mandatory,
                       q.weight, q.evidence_type_id, q.expected_evidence
                EXCEPT
                SELECT g.question_text, g.help_text, g.question_type_id, g.question_type_code, g.is_mandatory,
                       g.weight, g.evidence_type_id, g.expected_evidence) THEN 1 ELSE 0 END,
           question_text      = g.question_text,
           help_text          = g.help_text,
           question_type_id   = g.question_type_id,
           question_type_code = g.question_type_code,
           question_type_name = g.question_type_name,
           is_mandatory       = g.is_mandatory,
           weight             = g.weight,
           evidence_required  = g.evidence_required,
           evidence_type_id   = g.evidence_type_id,
           evidence_type_code = g.evidence_type_code,
           evidence_type_name = g.evidence_type_name,
           expected_evidence  = g.expected_evidence,
           status             = g.status,
           display_order      = g.display_order,
           updated_by         = @actor,
           updated_dt         = SYSUTCDATETIME()
    FROM   grac_practice.org_assurance_question q
    JOIN   #g g ON g.question_id = q.org_assurance_question_id;
    SET @saved_count = @@ROWCOUNT;

    -- New rows whose code the set used before: bring that question back.
    UPDATE q
    SET    is_active = 1, version_number = q.version_number + 1,
           question_text = g.question_text, help_text = g.help_text,
           question_type_id = g.question_type_id, question_type_code = g.question_type_code,
           question_type_name = g.question_type_name, is_mandatory = g.is_mandatory,
           weight = g.weight, evidence_required = g.evidence_required,
           evidence_type_id = g.evidence_type_id, evidence_type_code = g.evidence_type_code,
           evidence_type_name = g.evidence_type_name,
           expected_evidence = g.expected_evidence, status = g.status,
           display_order = g.display_order, expected_response = NULL,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
    FROM   grac_practice.org_assurance_question q
    JOIN   #g g ON g.question_id IS NULL AND g.question_code = q.question_code
    WHERE  q.org_assurance_question_set_id = @question_set_id AND q.is_active = 0;
    SET @saved_count = @saved_count + @@ROWCOUNT;

    INSERT grac_practice.org_assurance_question
        (org_assurance_question_set_id, organization_id, question_code, question_text, help_text,
         question_type_id, question_type_code, question_type_name, is_mandatory, display_order,
         weight, expected_response, evidence_required, evidence_type_id, evidence_type_code, evidence_type_name,
         expected_evidence, status, version_number,
         is_active, record_status_id, entered_by, entered_dt)
    SELECT @question_set_id, @organization_id, g.question_code, g.question_text, g.help_text,
           g.question_type_id, g.question_type_code, g.question_type_name, g.is_mandatory, g.display_order,
           g.weight, NULL, g.evidence_required, g.evidence_type_id, g.evidence_type_code, g.evidence_type_name,
           g.expected_evidence, g.status, 1,
           1, @rs, @actor, SYSUTCDATETIME()
    FROM   #g g
    WHERE  g.question_id IS NULL
      AND  NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_question q
                       WHERE q.org_assurance_question_set_id = @question_set_id
                         AND q.question_code = g.question_code);
    SET @saved_count = @saved_count + @@ROWCOUNT;

    -- A new row clashing with a question still active (cannot happen
    -- after the duplicate check unless two saves raced): refuse.
    IF EXISTS (SELECT 1 FROM #g g
               WHERE g.question_id IS NULL
                 AND (SELECT COUNT(*) FROM grac_practice.org_assurance_question q
                      WHERE q.org_assurance_question_set_id = @question_set_id
                        AND q.question_code = g.question_code AND q.is_active = 1) <> 1)
    BEGIN
        ROLLBACK;
        THROW 53810, 'A question with this code already exists in the set. Reload the page.', 1;
    END

    UPDATE grac_practice.org_assurance_question_set
    SET    updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE  org_assurance_question_set_id = @question_set_id;

    COMMIT;
END
GO

-- =====================================================================
-- 4. Menu: Audit Assurance -> Question Sets
-- =====================================================================
DECLARE @assurance_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance');
UPDATE grac_practice.menu_master
SET    menu_name = N'Question Sets', menu_url = N'Practice/org-assurance-question-sets',
       parent_menu_id = @assurance_id, display_order = 445, icon_class = N'clipboard-list',
       module_type = N'Audit Assurance', status = N'Active',
       updated_by = 'seed-520', updated_dt = SYSUTCDATETIME()
WHERE  menu_key = N'org-assurance-question-sets';
PRINT '520: Question Sets menu row active under Audit Assurance = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 1, 1,
       N'Active', @active_rs, N'seed-520', SYSUTCDATETIME()
FROM   grac_practice.organization_role r
JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
JOIN   grac_practice.menu_master m ON m.menu_key = N'org-assurance-question-sets'
WHERE  o.status = N'Active' AND r.status = N'Active'
  AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission p
        WHERE p.role_id = r.role_id AND p.menu_id = m.menu_id);
PRINT '520: Question Sets permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

DELETE p
FROM   grac_practice.organization_role_menu_permission p
JOIN   grac_practice.menu_master m ON m.menu_id = p.menu_id
WHERE  m.menu_key = N'org-assurance-question-repository';
DELETE FROM grac_practice.menu_master WHERE menu_key = N'org-assurance-question-repository';
PRINT '520: Question Repository menu row removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 5. Verification
-- =====================================================================
SELECT N'520-a question columns' AS [Check],
       CASE WHEN COL_LENGTH('grac_practice.org_assurance_question','evidence_required') IS NOT NULL
             AND COL_LENGTH('grac_practice.org_assurance_question','evidence_type_id') IS NOT NULL
             AND COL_LENGTH('grac_practice.org_assurance_question','expected_evidence') IS NOT NULL
             AND COL_LENGTH('grac_practice.org_assurance_question','status') IS NOT NULL
             AND COL_LENGTH('grac_practice.org_assurance_question','version_number') IS NOT NULL
             AND COL_LENGTH('grac_practice.org_assurance_question','repository_question_id') IS NULL
            THEN N'PASS' ELSE N'FAIL' END AS Result;
GO
SELECT N'520-c Repository removed' AS [Check],
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_question_repository','U') IS NULL
             AND OBJECT_ID('grac_practice.org_assurance_question_category','U') IS NULL
             AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-assurance-question-repository')
            THEN N'PASS' ELSE N'FAIL' END AS Result;
GO
SELECT N'520-d Question Sets menu' AS [Check],
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master m
                         JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
                         WHERE m.menu_key = N'org-assurance-question-sets' AND p.menu_key = N'nav-assurance'
                           AND m.status = N'Active')
            THEN N'PASS' ELSE N'FAIL' END AS Result;
GO

PRINT '520 complete.';
GO
SET NOEXEC OFF;
GO
