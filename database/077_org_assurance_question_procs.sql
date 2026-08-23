-- =====================================================================
-- 077 Organization Assurance Question -- Stage 2 stored procedures
--
-- Depends on 076 (schema).
--
-- Procedures:
--   sp_org_assurance_admin_question_type_list  Admin-published types
--   sp_org_assurance_question_set_list         Paginated org list
--   sp_org_assurance_question_set_get          Single set detail
--   sp_org_assurance_question_set_save         Insert or update
--   sp_org_assurance_question_set_delete       Soft delete
--   sp_org_assurance_question_list             All questions in a set
--   sp_org_assurance_question_get              Single question detail
--   sp_org_assurance_question_save             Insert or update
--   sp_org_assurance_question_delete           Soft delete
--
-- Rollback: 077_org_assurance_question_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_question_set','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_question','U') IS NULL
BEGIN
    RAISERROR('077: run 076 schema first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_org_assurance_admin_question_type_list
--   Same defensive pattern as sp_org_assurance_admin_category_list
--   (migration 072): if grac_new.assurance_question_type is not
--   deployed here, return an empty rowset with the expected shape.
--
--   The Admin table can carry any of several naming conventions
--   ({entity}_code / code, {entity}_name / name / label, etc.). We
--   discover the actual column names from sys.columns at RUNTIME and
--   build the SELECT dynamically -- so this proc installs regardless
--   of the Admin schema and just returns an empty rowset when it
--   can't find id + name columns to project.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_admin_question_type_list
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('grac_new.assurance_question_type','U') IS NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT)      AS Id,
               CAST(NULL AS NVARCHAR(120)) AS Code,
               CAST(NULL AS NVARCHAR(200)) AS Name,
               CAST(NULL AS NVARCHAR(1000)) AS Description
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @tbl_id INT = OBJECT_ID('grac_new.assurance_question_type');
    DECLARE @id_col NVARCHAR(128), @code_col NVARCHAR(128),
            @name_col NVARCHAR(128), @desc_col NVARCHAR(128),
            @status_col NVARCHAR(128);

    ;WITH candidates AS (
        SELECT c.name, c.column_id
        FROM sys.columns c WHERE c.object_id = @tbl_id
    )
    SELECT TOP 1 @id_col = name FROM candidates
    WHERE name IN (N'assurance_question_type_id', N'question_type_id', N'type_id', N'id')
    ORDER BY CASE name
        WHEN N'assurance_question_type_id' THEN 1
        WHEN N'question_type_id'           THEN 2
        WHEN N'type_id'                    THEN 3
        WHEN N'id'                         THEN 4
        ELSE 99 END;

    ;WITH candidates AS (
        SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id
    )
    SELECT TOP 1 @code_col = name FROM candidates
    WHERE name IN (N'assurance_question_type_code', N'question_type_code',
                   N'type_code', N'code')
    ORDER BY CASE name
        WHEN N'assurance_question_type_code' THEN 1
        WHEN N'question_type_code'           THEN 2
        WHEN N'type_code'                    THEN 3
        WHEN N'code'                         THEN 4
        ELSE 99 END;

    ;WITH candidates AS (
        SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id
    )
    SELECT TOP 1 @name_col = name FROM candidates
    WHERE name IN (N'assurance_question_type_name', N'question_type_name',
                   N'type_name', N'name', N'label', N'display_name')
    ORDER BY CASE name
        WHEN N'assurance_question_type_name' THEN 1
        WHEN N'question_type_name'           THEN 2
        WHEN N'type_name'                    THEN 3
        WHEN N'name'                         THEN 4
        WHEN N'label'                        THEN 5
        WHEN N'display_name'                 THEN 6
        ELSE 99 END;

    ;WITH candidates AS (
        SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id
    )
    SELECT TOP 1 @desc_col = name FROM candidates
    WHERE name IN (N'description', N'notes', N'remarks');

    ;WITH candidates AS (
        SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id
    )
    SELECT TOP 1 @status_col = name FROM candidates
    WHERE name IN (N'status', N'is_active', N'active_flag');

    IF @id_col IS NULL OR @name_col IS NULL
    BEGIN
        -- Can't safely project -- degrade to empty result set.
        SELECT CAST(NULL AS BIGINT)      AS Id,
               CAST(NULL AS NVARCHAR(120)) AS Code,
               CAST(NULL AS NVARCHAR(200)) AS Name,
               CAST(NULL AS NVARCHAR(1000)) AS Description
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @sql NVARCHAR(MAX) = N'
        SELECT ' + QUOTENAME(@id_col) + N' AS Id,
               ' + COALESCE(QUOTENAME(@code_col), N'CAST(NULL AS NVARCHAR(120))') + N' AS Code,
               ' + QUOTENAME(@name_col) + N' AS Name,
               ' + COALESCE(QUOTENAME(@desc_col), N'CAST(NULL AS NVARCHAR(1000))') + N' AS Description
        FROM grac_new.assurance_question_type';

    IF @status_col = N'status'
        SET @sql = @sql + N' WHERE ' + QUOTENAME(@status_col) + N' = N''Active''';
    ELSE IF @status_col IN (N'is_active', N'active_flag')
        SET @sql = @sql + N' WHERE ' + QUOTENAME(@status_col) + N' = 1';

    SET @sql = @sql + N' ORDER BY ' + QUOTENAME(@name_col) + N';';

    EXEC sp_executesql @sql;
END
GO

-- =====================================================================
-- sp_org_assurance_question_set_list
-- =====================================================================
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
                   AND q.is_active = 1) AS question_count
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
           entered_dt                    AS EnteredDt,
           updated_dt                    AS UpdatedDt
    FROM base
    ORDER BY set_name, org_assurance_question_set_id
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- sp_org_assurance_question_set_get
-- =====================================================================
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

-- =====================================================================
-- sp_org_assurance_question_set_save
-- =====================================================================
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

-- =====================================================================
-- sp_org_assurance_question_set_delete  (soft)
-- =====================================================================
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

-- =====================================================================
-- sp_org_assurance_question_list
--   Lists every active question in the set. No paging -- question
--   sets are expected to fit comfortably in one screen; if that
--   changes, add @page/@page_size the same way the set list does.
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
           q.updated_dt                    AS UpdatedDt
    FROM grac_practice.org_assurance_question q
    WHERE q.org_assurance_question_set_id = @question_set_id
      AND q.organization_id = @organization_id
      AND q.is_active = 1
    ORDER BY q.display_order, q.org_assurance_question_id;
END
GO

-- =====================================================================
-- sp_org_assurance_question_get
-- =====================================================================
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

-- =====================================================================
-- sp_org_assurance_question_save
-- =====================================================================
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

-- =====================================================================
-- sp_org_assurance_question_delete  (soft)
-- =====================================================================
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

PRINT '077 Organization Assurance Question procedures deployed.';
GO
