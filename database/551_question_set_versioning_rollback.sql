-- =====================================================================
-- 551 ROLLBACK -- restores the procedures 551 re-issued (077, 520, 535,
-- 278, 119, 546 bodies) and drops the procedures it added. The version
-- columns, their values and the (organization_id, set_code,
-- version_number) unique key are KEPT: sets may now have several versions
-- sharing a code, which the old (organization_id, set_code) key would
-- reject. Deploy the pre-551 Api and Web with it. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_save
    @organization_id      BIGINT,
    @question_set_id      BIGINT        = NULL,
    @set_code             NVARCHAR(80),
    @set_name             NVARCHAR(240),
    @description          NVARCHAR(MAX) = NULL,
    @owner_employee_id    BIGINT        = NULL,
    @owner_display_name   NVARCHAR(240) = NULL,
    @status               NVARCHAR(30)  = N'Active',
    @actor                NVARCHAR(100) = 'system',
    @question_set_id_out  BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL
        THROW 53801, 'organization_id is required.', 1;
    IF @set_code IS NULL OR LEN(LTRIM(RTRIM(@set_code))) = 0
        THROW 53803, 'set_code is required.', 1;
    IF @set_name IS NULL OR LEN(LTRIM(RTRIM(@set_name))) = 0
        THROW 53804, 'set_name is required.', 1;
    IF @status NOT IN (N'Active', N'Inactive', N'Draft')
        SET @status = N'Active';

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    BEGIN TRAN;

    IF @question_set_id IS NULL
    BEGIN
        IF EXISTS (
            SELECT 1 FROM grac_practice.org_assurance_question_set
            WHERE organization_id = @organization_id
              AND set_code        = @set_code
              AND is_active       = 1)
        BEGIN
            ROLLBACK;
            THROW 53805, 'A question set with this code already exists in the organization.', 1;
        END

        INSERT INTO grac_practice.org_assurance_question_set
            (organization_id, set_code, set_name, description,
             owner_employee_id, owner_display_name,
             status, is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@organization_id, @set_code, @set_name, @description,
             @owner_employee_id, @owner_display_name,
             @status, 1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @question_set_id_out = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        DECLARE @def_org BIGINT;
        SELECT @def_org = organization_id
        FROM grac_practice.org_assurance_question_set
        WHERE org_assurance_question_set_id = @question_set_id
          AND is_active = 1;

        IF @def_org IS NULL
        BEGIN ROLLBACK; THROW 53806, 'Question set not found.', 1; END
        IF @def_org <> @organization_id
        BEGIN ROLLBACK; THROW 53807, 'Question set belongs to a different organization.', 1; END

        UPDATE grac_practice.org_assurance_question_set
        SET set_name           = @set_name,
            description        = @description,
            owner_employee_id  = @owner_employee_id,
            owner_display_name = @owner_display_name,
            status             = @status,
            updated_by         = @actor,
            updated_dt         = SYSUTCDATETIME()
        WHERE org_assurance_question_set_id = @question_set_id;

        SET @question_set_id_out = @question_set_id;
    END

    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_get
    @organization_id BIGINT,
    @question_set_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @question_set_id IS NULL
        THROW 53802, 'organization_id and question_set_id are required.', 1;

    SELECT qs.org_assurance_question_set_id AS QuestionSetId,
           qs.organization_id               AS OrganizationId,
           qs.set_code                      AS SetCode,
           qs.set_name                      AS SetName,
           qs.description                   AS Description,
           qs.owner_employee_id             AS OwnerEmployeeId,
           qs.owner_display_name            AS OwnerDisplayName,
           qs.status                        AS Status,
           qs.entered_by                    AS EnteredBy,
           qs.entered_dt                    AS EnteredDt,
           qs.updated_by                    AS UpdatedBy,
           qs.updated_dt                    AS UpdatedDt
    FROM grac_practice.org_assurance_question_set qs
    WHERE qs.organization_id               = @organization_id
      AND qs.org_assurance_question_set_id = @question_set_id
      AND qs.is_active = 1;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_list
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @page            INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 53801, 'organization_id is required.', 1;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    DECLARE @offset INT = (@page - 1) * @page_size;

    ;WITH base AS (
        SELECT qs.org_assurance_question_set_id,
               qs.organization_id,
               qs.set_code,
               qs.set_name,
               qs.description,
               qs.owner_employee_id,
               qs.owner_display_name,
               qs.status,
               qs.entered_dt,
               qs.updated_dt,
               (SELECT COUNT_BIG(1)
                  FROM grac_practice.org_assurance_question q
                 WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
                   AND q.is_active = 1) AS question_count
        FROM grac_practice.org_assurance_question_set qs
        WHERE qs.organization_id = @organization_id
          AND qs.is_active = 1
          AND (@search IS NULL OR @search = ''
               OR qs.set_name LIKE N'%' + @search + N'%'
               OR qs.set_code LIKE N'%' + @search + N'%')
    )
    SELECT CAST(COUNT_BIG(1) AS BIGINT) AS TotalCount,
           CAST(@page      AS INT)      AS PageNumber,
           CAST(@page_size AS INT)      AS PageSize
    FROM base;

    ;WITH base AS (
        SELECT qs.org_assurance_question_set_id,
               qs.organization_id,
               qs.set_code,
               qs.set_name,
               qs.description,
               qs.owner_employee_id,
               qs.owner_display_name,
               qs.status,
               qs.entered_dt,
               qs.updated_dt,
               (SELECT COUNT_BIG(1)
                  FROM grac_practice.org_assurance_question q
                 WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
                   AND q.is_active = 1) AS question_count,
               -- 535: same rows as question_count (is_active = 1).
               (SELECT COUNT_BIG(1)
                  FROM grac_practice.org_assurance_question q
                 WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
                   AND q.is_active = 1
                   AND q.is_mandatory = 1) AS mandatory_count,
               (SELECT ISNULL(SUM(q.weight), 0)
                  FROM grac_practice.org_assurance_question q
                 WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
                   AND q.is_active = 1) AS total_weight
        FROM grac_practice.org_assurance_question_set qs
        WHERE qs.organization_id = @organization_id
          AND qs.is_active = 1
          AND (@search IS NULL OR @search = ''
               OR qs.set_name LIKE N'%' + @search + N'%'
               OR qs.set_code LIKE N'%' + @search + N'%')
    )
    SELECT org_assurance_question_set_id AS QuestionSetId,
           organization_id               AS OrganizationId,
           set_code                      AS SetCode,
           set_name                      AS SetName,
           description                   AS Description,
           owner_employee_id             AS OwnerEmployeeId,
           owner_display_name            AS OwnerDisplayName,
           status                        AS Status,
           question_count                AS QuestionCount,
           mandatory_count               AS MandatoryCount,   -- 535
           total_weight                  AS TotalWeight,      -- 535
           entered_dt                    AS EnteredDt,
           updated_dt                    AS UpdatedDt
    FROM base
    ORDER BY set_name, org_assurance_question_set_id
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_delete
    @organization_id BIGINT,
    @question_set_id BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @question_set_id IS NULL
        THROW 53802, 'organization_id and question_set_id are required.', 1;

    DECLARE @def_org BIGINT;
    SELECT @def_org = organization_id
    FROM grac_practice.org_assurance_question_set
    WHERE org_assurance_question_set_id = @question_set_id
      AND is_active = 1;

    IF @def_org IS NULL THROW 53806, 'Question set not found.', 1;
    IF @def_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;

    BEGIN TRAN;

    -- Soft-delete cascades to questions (Stage 2b will refine if needed).
    UPDATE grac_practice.org_assurance_question
    SET is_active  = 0,
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_question_set_id = @question_set_id
      AND is_active = 1;

    UPDATE grac_practice.org_assurance_question_set
    SET is_active  = 0,
        status     = N'Inactive',
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_question_set_id = @question_set_id;

    COMMIT;
END
GO

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

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_delete
    @organization_id BIGINT,
    @question_id     BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @question_id IS NULL
        THROW 53802, 'organization_id and question_id are required.', 1;

    DECLARE @q_org BIGINT;
    SELECT @q_org = organization_id
    FROM grac_practice.org_assurance_question
    WHERE org_assurance_question_id = @question_id
      AND is_active = 1;

    IF @q_org IS NULL THROW 53811, 'Question not found.', 1;
    IF @q_org <> @organization_id THROW 53807, 'Question belongs to a different organization.', 1;

    UPDATE grac_practice.org_assurance_question
    SET is_active  = 0,
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_question_id = @question_id;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_question_set_get
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @version_id      BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;

    DECLARE @def_org BIGINT, @current_version_id BIGINT, @current_status_code NVARCHAR(60);

    SELECT @def_org             = d.organization_id,
           @current_version_id  = d.current_version_id,
           @current_status_code = s.status_code
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    WHERE d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    IF @def_org IS NULL      THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id
        THROW 53607, 'Definition belongs to a different organization.', 1;

    IF @version_id IS NULL SET @version_id = @current_version_id;

    -- Header.
    SELECT @definition_id       AS DefinitionId,
           @version_id          AS VersionId,
           @current_version_id  AS CurrentVersionId,
           @current_status_code AS CurrentStatusCode,
           CAST(CASE WHEN @current_status_code = N'Draft'
                     AND @version_id = @current_version_id
                     THEN 1 ELSE 0 END AS BIT) AS IsEditable;

    -- Adopted sets.
    SELECT dqs.org_assurance_definition_question_set_id AS DefinitionQuestionSetId,
           dqs.org_assurance_question_set_id            AS QuestionSetId,
           qs.set_code                                  AS SetCode,
           qs.set_name                                  AS SetName,
           dqs.display_order                            AS DisplayOrder,
           dqs.is_mandatory                             AS IsMandatory,
           (SELECT COUNT(*)
              FROM grac_practice.org_assurance_question q
             WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
               AND q.is_active = 1)                     AS QuestionCount
    FROM grac_practice.org_assurance_definition_question_set dqs
    JOIN grac_practice.org_assurance_question_set qs
         ON qs.org_assurance_question_set_id = dqs.org_assurance_question_set_id
    WHERE dqs.organization_id = @organization_id
      AND dqs.org_assurance_definition_version_id = @version_id
      AND dqs.is_active = 1
    ORDER BY dqs.display_order, dqs.org_assurance_definition_question_set_id;

    -- Every set available to adopt.
    SELECT qs.org_assurance_question_set_id AS QuestionSetId,
           qs.set_code                      AS SetCode,
           qs.set_name                      AS SetName,
           (SELECT COUNT(*)
              FROM grac_practice.org_assurance_question q
             WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
               AND q.is_active = 1)         AS QuestionCount
    FROM grac_practice.org_assurance_question_set qs
    WHERE qs.organization_id = @organization_id
      AND qs.is_active = 1
    ORDER BY qs.set_name;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_question_set_save
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @items_json      NVARCHAR(MAX),
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;
    IF @items_json IS NULL SET @items_json = N'[]';
    IF ISJSON(@items_json) = 0
        THROW 53703, 'items_json is not a valid JSON document.', 1;

    DECLARE @def_org BIGINT, @current_version_id BIGINT, @current_status_code NVARCHAR(60);

    SELECT @def_org             = d.organization_id,
           @current_version_id  = d.current_version_id,
           @current_status_code = s.status_code
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    WHERE d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    IF @def_org IS NULL      THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id
        THROW 53607, 'Definition belongs to a different organization.', 1;
    IF @current_version_id IS NULL
        THROW 53611, 'Definition has no current version.', 1;
    IF @current_status_code <> N'Draft'
        THROW 53608, 'Question sets can only be adopted while the current version is Draft.', 1;

    DECLARE @incoming TABLE(
        question_set_id BIGINT NOT NULL,
        display_order   INT    NULL,
        is_mandatory    BIT    NULL);

    INSERT INTO @incoming(question_set_id, display_order, is_mandatory)
    SELECT x.questionSetId, x.displayOrder, x.isMandatory
    FROM OPENJSON(@items_json)
    WITH (
        questionSetId BIGINT '$.questionSetId',
        displayOrder  INT    '$.displayOrder',
        isMandatory   BIT    '$.isMandatory'
    ) AS x
    WHERE x.questionSetId IS NOT NULL;

    -- Reject duplicates in the payload -- the unique index would catch
    -- them, but the message here is far clearer.
    IF EXISTS (SELECT 1 FROM @incoming GROUP BY question_set_id HAVING COUNT(*) > 1)
        THROW 53712, 'The same question set was listed more than once.', 1;

    -- Reject anything that is not an active set in this organization.
    IF EXISTS (
        SELECT 1
        FROM @incoming i
        WHERE NOT EXISTS (
            SELECT 1 FROM grac_practice.org_assurance_question_set qs
             WHERE qs.org_assurance_question_set_id = i.question_set_id
               AND qs.organization_id = @organization_id
               AND qs.is_active = 1))
        THROW 53713, 'One or more question sets do not exist in this organization.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    BEGIN TRAN;

    DELETE FROM grac_practice.org_assurance_definition_question_set
     WHERE org_assurance_definition_version_id = @current_version_id
       AND organization_id = @organization_id;

    INSERT INTO grac_practice.org_assurance_definition_question_set
        (org_assurance_definition_id, org_assurance_definition_version_id,
         organization_id, org_assurance_question_set_id,
         display_order, is_mandatory,
         is_active, record_status_id, entered_by, entered_dt)
    SELECT @definition_id,
           @current_version_id,
           @organization_id,
           i.question_set_id,
           ISNULL(i.display_order, 0),
           ISNULL(i.is_mandatory, 1),
           1, @active_record_status_id, @actor, SYSUTCDATETIME()
    FROM @incoming i;

    COMMIT TRAN;

    SELECT CAST(1 AS BIT) AS Success,
           @definition_id      AS DefinitionId,
           @current_version_id AS VersionId,
           (SELECT COUNT(*) FROM @incoming) AS AdoptedCount;
END
GO

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
             status_id, is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@definition_id_out, @organization_id, 1, N'1.0',
             @description, @objective, @effective_date,
             @assurance_category_id, @assurance_category_code, @assurance_category_name,
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
                 status_id, is_active, record_status_id, entered_by, entered_dt)
            VALUES
                (@definition_id, @organization_id, @next_version_number,
                 CAST(@next_version_number AS NVARCHAR(20)) + N'.0',
                 @description, @objective, @effective_date,
                 @assurance_category_id, @assurance_category_code, @assurance_category_name,
                 @draft_status_id, 1, @active_record_status_id, @actor, SYSUTCDATETIME());

            SET @definition_version_id_out = SCOPE_IDENTITY();

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

    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_item_save
    @organization_id             BIGINT,
    @plan_id                     BIGINT,
    @plan_item_id                BIGINT        = NULL,
    @org_assurance_definition_id BIGINT,
    @definition_code             NVARCHAR(80)  = NULL,
    @definition_name             NVARCHAR(240) = NULL,
    @item_order                  INT           = 0,
    @scheduled_from              DATE          = NULL,
    @scheduled_to                DATE          = NULL,
    @assigned_auditor_role_id    BIGINT        = NULL,   -- 121
    @assigned_auditor_role_name  NVARCHAR(120) = NULL,   -- 121
    @assigned_auditor_employee_id BIGINT       = NULL,
    @assigned_auditor_name       NVARCHAR(240) = NULL,
    @assigned_team_name          NVARCHAR(200) = NULL,
    @assigned_department_id      BIGINT        = NULL,
    @assigned_department_name    NVARCHAR(200) = NULL,
    @assigned_branch_id          BIGINT        = NULL,
    @assigned_branch_name        NVARCHAR(200) = NULL,
    @notes                       NVARCHAR(MAX) = NULL,
    @actor                       NVARCHAR(100) = 'system',
    @plan_item_id_out            BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @plan_id IS NULL
        THROW 53902, 'organization_id and plan_id are required.', 1;
    IF @org_assurance_definition_id IS NULL
        THROW 53913, 'org_assurance_definition_id is required.', 1;

    -- Verify plan ownership.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_plan
        WHERE org_assurance_plan_id = @plan_id
          AND organization_id       = @organization_id
          AND is_active = 1)
        THROW 53908, 'Plan belongs to a different organization.', 1;

    -- Verify definition ownership.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_definition
        WHERE org_assurance_definition_id = @org_assurance_definition_id
          AND organization_id            = @organization_id
          AND is_active = 1)
        THROW 53914, 'Assurance definition not accessible in this organization.', 1;

    -- 546: slots change only while the plan can still be edited (Draft /
    -- Submitted -- the plan header's own rule, 121); only an Active audit
    -- is planned; a slot lies inside the plan period, from <= to. The code
    -- and name are the audit's own (the snapshot no longer trusts the
    -- caller's copy).
    DECLARE @plan_status NVARCHAR(60), @period_from DATE, @period_to DATE;
    SELECT @plan_status = s.status_code,
           @period_from = p.period_from,
           @period_to   = p.period_to
      FROM grac_practice.org_assurance_plan p
      JOIN grac_practice.org_assurance_plan_status_master s
           ON s.org_assurance_plan_status_id = p.status_id
     WHERE p.org_assurance_plan_id = @plan_id;
    IF @plan_status NOT IN (N'Draft', N'Submitted')
        THROW 53909, 'Plan items can be changed only while the plan is Draft or Submitted.', 1;

    DECLARE @def_status NVARCHAR(60);
    SELECT @def_status      = s.status_code,
           @definition_code = d.definition_code,
           @definition_name = d.definition_name
      FROM grac_practice.org_assurance_definition d
      JOIN grac_practice.org_assurance_status_master s
           ON s.org_assurance_status_id = d.current_status_id
     WHERE d.org_assurance_definition_id = @org_assurance_definition_id;
    IF @def_status <> N'Active'
        THROW 53933, 'Only an Active audit can be added to a plan.', 1;

    IF @scheduled_from IS NOT NULL AND @scheduled_to IS NOT NULL AND @scheduled_to < @scheduled_from
        THROW 53934, 'Scheduled To must be on or after Scheduled From.', 1;
    IF (@period_from IS NOT NULL AND (@scheduled_from < @period_from OR @scheduled_to < @period_from))
       OR (@period_to IS NOT NULL AND (@scheduled_from > @period_to OR @scheduled_to > @period_to))
        THROW 53934, 'The scheduled dates must fall within the plan period.', 1;

    -- ==========================================================
    -- 121 hybrid ownership resolver -- Auditor
    -- ==========================================================
    IF @assigned_auditor_role_id IS NOT NULL
       AND (@assigned_auditor_role_name IS NULL OR LEN(LTRIM(RTRIM(@assigned_auditor_role_name))) = 0)
        SELECT @assigned_auditor_role_name = role_name
        FROM grac_practice.organization_role
        WHERE role_id = @assigned_auditor_role_id AND organization_id = @organization_id;

    IF @assigned_auditor_role_id IS NOT NULL AND @assigned_auditor_employee_id IS NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id   = @organization_id,
             @role_id           = @assigned_auditor_role_id,
             @employee_id_out   = @assigned_auditor_employee_id  OUTPUT,
             @employee_name_out = @assigned_auditor_name         OUTPUT;

    IF @assigned_auditor_employee_id IS NOT NULL AND @assigned_auditor_role_id IS NULL
    BEGIN
        SELECT @assigned_auditor_role_id   = e.role_id,
               @assigned_auditor_role_name = r.role_name
        FROM grac_practice.organization_employee e
        LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id
        WHERE e.employee_id = @assigned_auditor_employee_id
          AND e.organization_id = @organization_id;
    END

    IF @assigned_auditor_employee_id IS NOT NULL
       AND (@assigned_auditor_name IS NULL OR LEN(LTRIM(RTRIM(@assigned_auditor_name))) = 0)
        SELECT @assigned_auditor_name = employee_name
        FROM grac_practice.organization_employee
        WHERE employee_id = @assigned_auditor_employee_id;

    BEGIN TRAN;

    IF @plan_item_id IS NULL
    BEGIN
        INSERT INTO grac_practice.org_assurance_plan_item
            (org_assurance_plan_id, organization_id,
             org_assurance_definition_id, definition_code, definition_name,
             item_order, scheduled_from, scheduled_to,
             assigned_auditor_role_id, assigned_auditor_role_name,       -- 121
             assigned_auditor_employee_id, assigned_auditor_name,
             assigned_team_name,
             assigned_department_id, assigned_department_name,
             assigned_branch_id, assigned_branch_name,
             notes, is_active, entered_by, entered_dt)
        VALUES
            (@plan_id, @organization_id,
             @org_assurance_definition_id, @definition_code, @definition_name,
             ISNULL(@item_order, 0), @scheduled_from, @scheduled_to,
             @assigned_auditor_role_id, @assigned_auditor_role_name,     -- 121
             @assigned_auditor_employee_id, @assigned_auditor_name,
             @assigned_team_name,
             @assigned_department_id, @assigned_department_name,
             @assigned_branch_id, @assigned_branch_name,
             @notes, 1, @actor, SYSUTCDATETIME());

        SET @plan_item_id_out = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        DECLARE @item_plan BIGINT;
        SELECT @item_plan = org_assurance_plan_id
        FROM grac_practice.org_assurance_plan_item
        WHERE org_assurance_plan_item_id = @plan_item_id
          AND is_active = 1;

        IF @item_plan IS NULL BEGIN ROLLBACK; THROW 53915, 'Plan item not found.', 1; END
        IF @item_plan <> @plan_id
        BEGIN ROLLBACK; THROW 53916, 'Plan item does not belong to the specified plan.', 1; END

        UPDATE grac_practice.org_assurance_plan_item
        SET org_assurance_definition_id = @org_assurance_definition_id,
            definition_code             = @definition_code,
            definition_name             = @definition_name,
            item_order                  = ISNULL(@item_order, 0),
            scheduled_from              = @scheduled_from,
            scheduled_to                = @scheduled_to,
            assigned_auditor_role_id    = @assigned_auditor_role_id,       -- 121
            assigned_auditor_role_name  = @assigned_auditor_role_name,     -- 121
            assigned_auditor_employee_id = @assigned_auditor_employee_id,
            assigned_auditor_name       = @assigned_auditor_name,
            assigned_team_name          = @assigned_team_name,
            assigned_department_id      = @assigned_department_id,
            assigned_department_name    = @assigned_department_name,
            assigned_branch_id          = @assigned_branch_id,
            assigned_branch_name        = @assigned_branch_name,
            notes                       = @notes,
            updated_by                  = @actor,
            updated_dt                  = SYSUTCDATETIME()
        WHERE org_assurance_plan_item_id = @plan_item_id;

        SET @plan_item_id_out = @plan_item_id;
    END

    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_item_list
    @organization_id BIGINT,
    @plan_id         BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @plan_id IS NULL
        THROW 53902, 'organization_id and plan_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_plan
        WHERE org_assurance_plan_id = @plan_id
          AND organization_id       = @organization_id)
        THROW 53908, 'Plan belongs to a different organization.', 1;

    SELECT i.org_assurance_plan_item_id  AS PlanItemId,
           i.org_assurance_plan_id       AS PlanId,
           i.org_assurance_definition_id AS DefinitionId,
           i.definition_code             AS DefinitionCode,
           i.definition_name             AS DefinitionName,
           i.org_assurance_definition_version_id AS DefinitionVersionId,
           i.item_order                  AS ItemOrder,
           i.scheduled_from              AS ScheduledFrom,
           i.scheduled_to                AS ScheduledTo,
           i.assigned_auditor_role_id    AS AssignedAuditorRoleId,      -- 121
           i.assigned_auditor_role_name  AS AssignedAuditorRoleName,    -- 121
           i.assigned_auditor_employee_id AS AssignedAuditorEmployeeId,
           i.assigned_auditor_name       AS AssignedAuditorName,
           i.assigned_team_name          AS AssignedTeamName,
           i.assigned_department_id      AS AssignedDepartmentId,
           i.assigned_department_name    AS AssignedDepartmentName,
           i.assigned_branch_id          AS AssignedBranchId,
           i.assigned_branch_name        AS AssignedBranchName,
           i.notes                       AS Notes,
           i.entered_by                  AS EnteredBy,
           i.entered_dt                  AS EnteredDt,
           i.updated_by                  AS UpdatedBy,
           i.updated_dt                  AS UpdatedDt,
           -- 546: the audit's current status, the slot's latest execution,
           -- and the slot status derived from them:
           --   InProgress / Completed  -- a live execution (Completed once
           --                              Approved or Closed);
           --   NotExecuted             -- none, and the audit is Retired or
           --                              the plan Closed;
           --   Planned                 -- none yet (a Cancelled one counts
           --                              as none).
           ds.status_code                AS DefinitionStatusCode,
           ds.status_name                AS DefinitionStatusName,
           ex.org_assurance_execution_id AS ExecutionId,
           ex.execution_code             AS ExecutionCode,
           ex.status_code                AS ExecutionStatusCode,
           ex.status_name                AS ExecutionStatusName,
           CASE WHEN ex.org_assurance_execution_id IS NOT NULL AND ex.status_code <> N'Cancelled'
                     THEN CASE WHEN ex.status_code IN (N'Approved', N'Closed') THEN N'Completed' ELSE N'InProgress' END
                WHEN ds.status_code = N'Retired' OR ps.status_code = N'Closed'
                     THEN N'NotExecuted'
                ELSE N'Planned' END      AS SlotStatus
    FROM grac_practice.org_assurance_plan_item i
    JOIN grac_practice.org_assurance_plan p
         ON p.org_assurance_plan_id = i.org_assurance_plan_id
    JOIN grac_practice.org_assurance_plan_status_master ps
         ON ps.org_assurance_plan_status_id = p.status_id
    LEFT JOIN grac_practice.org_assurance_definition d
         ON d.org_assurance_definition_id = i.org_assurance_definition_id
    LEFT JOIN grac_practice.org_assurance_status_master ds
         ON ds.org_assurance_status_id = d.current_status_id
    OUTER APPLY (
        SELECT TOP 1 e.org_assurance_execution_id, e.execution_code,
               es.status_code, es.status_name
          FROM grac_practice.org_assurance_execution e
          JOIN grac_practice.org_assurance_execution_status_master es
               ON es.org_assurance_execution_status_id = e.execution_status_id
         WHERE e.org_assurance_plan_item_id = i.org_assurance_plan_item_id
           AND e.organization_id = i.organization_id
           AND e.is_active = 1
         ORDER BY CASE WHEN es.status_code = N'Cancelled' THEN 1 ELSE 0 END,
                  e.org_assurance_execution_id DESC
    ) ex
    WHERE i.org_assurance_plan_id = @plan_id
      AND i.organization_id       = @organization_id
      AND i.is_active = 1
    ORDER BY i.item_order, i.org_assurance_plan_item_id;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_item_start_execution
    @organization_id  BIGINT,
    @plan_id          BIGINT,
    @plan_item_id     BIGINT,
    @actor            NVARCHAR(100) = 'system',
    @execution_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @plan_id IS NULL OR @plan_item_id IS NULL
        THROW 53902, 'organization_id, plan_id and plan_item_id are required.', 1;

    DECLARE @item_plan BIGINT, @definition_id BIGINT,
            @from DATE, @to DATE,
            @aud_role_id BIGINT, @aud_role_name NVARCHAR(120),
            @aud_emp_id BIGINT, @aud_name NVARCHAR(240),
            @team NVARCHAR(200);
    SELECT @item_plan     = i.org_assurance_plan_id,
           @definition_id = i.org_assurance_definition_id,
           @from          = i.scheduled_from,
           @to            = i.scheduled_to,
           @aud_role_id   = i.assigned_auditor_role_id,
           @aud_role_name = i.assigned_auditor_role_name,
           @aud_emp_id    = i.assigned_auditor_employee_id,
           @aud_name      = i.assigned_auditor_name,
           @team          = i.assigned_team_name
      FROM grac_practice.org_assurance_plan_item i
     WHERE i.org_assurance_plan_item_id = @plan_item_id
       AND i.organization_id = @organization_id
       AND i.is_active = 1;

    IF @item_plan IS NULL      THROW 53915, 'Plan item not found.', 1;
    IF @item_plan <> @plan_id  THROW 53916, 'Plan item does not belong to the specified plan.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_plan p
          JOIN grac_practice.org_assurance_plan_status_master s
               ON s.org_assurance_plan_status_id = p.status_id
         WHERE p.org_assurance_plan_id = @plan_id
           AND p.organization_id = @organization_id
           AND p.is_active = 1
           AND s.status_code IN (N'Approved', N'Active'))
        THROW 53935, 'An execution can be started only from an Approved or Active plan.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_definition d
          JOIN grac_practice.org_assurance_status_master s
               ON s.org_assurance_status_id = d.current_status_id
         WHERE d.org_assurance_definition_id = @definition_id
           AND s.status_code = N'Active')
        THROW 53933, 'The audit is not Active (it may have been retired), so this slot cannot be executed.', 1;

    IF EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_execution e
          JOIN grac_practice.org_assurance_execution_status_master es
               ON es.org_assurance_execution_status_id = e.execution_status_id
         WHERE e.org_assurance_plan_item_id = @plan_item_id
           AND e.is_active = 1
           AND es.status_code <> N'Cancelled')
        THROW 53936, 'This plan item already has an execution.', 1;

    -- The slot becomes the execution: its dates, its auditor as the
    -- owner, its team. No snapshot is passed, so the scope is resolved
    -- now (545). Materialize runs its own transaction.
    EXEC grac_practice.sp_org_assurance_execution_materialize
         @organization_id     = @organization_id,
         @definition_id       = @definition_id,
         @version_id          = NULL,
         @scope_resolution_id = NULL,
         @execution_code      = NULL,
         @execution_name      = NULL,
         @origin_type         = N'PLAN',
         @plan_id             = @plan_id,
         @plan_item_id        = @plan_item_id,
         @trigger_config_id   = NULL,
         @planned_start_dt    = @from,
         @planned_end_dt      = @to,
         @owner_role_id       = @aud_role_id,
         @owner_role_name     = @aud_role_name,
         @owner_employee_id   = @aud_emp_id,
         @owner_display_name  = @aud_name,
         @assigned_team_name  = @team,
         @notes               = NULL,
         @actor               = @actor,
         @execution_id_out    = @execution_id_out OUTPUT;

    SELECT e.org_assurance_execution_id AS ExecutionId,
           e.execution_code             AS ExecutionCode,
           e.execution_name             AS ExecutionName,
           e.total_entity_count         AS TotalEntityCount
      FROM grac_practice.org_assurance_execution e
     WHERE e.org_assurance_execution_id = @execution_id_out;
END
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_question_set_version_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_question_set_version_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_question_set_new_version','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_question_set_new_version;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_question_set_submit','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_question_set_submit;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_question_set_return','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_question_set_return;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_question_set_impact','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_question_set_impact;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_question_set_approve','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_question_set_approve;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_definition_version_copy_config','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_definition_version_copy_config;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_clone_rows','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_clone_rows;
GO
PRINT '551 rolled back (procedures). Version columns kept.';
GO
