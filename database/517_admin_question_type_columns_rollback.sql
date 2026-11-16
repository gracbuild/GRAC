-- =====================================================================
-- 517 ROLLBACK -- sp_org_assurance_admin_question_type_list back to 077.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
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
PRINT '517 rollback complete.';
GO
