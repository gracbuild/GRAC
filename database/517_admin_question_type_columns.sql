-- =====================================================================
-- 517  Response Type list empty in the Question Repository / Question Sets
--
-- REPORTED (2026-11-05)
--   Question Repository -> Add Question -> Response Type shows
--   "(no response types published by Admin)".
--
-- CAUSE
--   The types ARE published: Control Management 024 creates
--   GRAC_New.assurance_question_type and seeds Yes / No, Multiple Choice,
--   Text, Numeric, Date, Rating, Observation Only, Evidence Upload and
--   Checklist Item. But that table names its columns question_code /
--   question_name, and sp_org_assurance_admin_question_type_list (077)
--   discovers the columns from a fixed candidate list that has neither.
--   With no name column found it returns an empty list by design -- so
--   Practice Management never showed a single type.
--
-- FIX
--   Re-issue the procedure from its 077 body with question_code /
--   question_name added to the candidates, and ordered by the Admin's
--   display_order when the table has one (Yes / No first). Nothing else
--   changes: still Active rows only, still an empty list when the Admin
--   table is missing.
--
-- SAFE TO RE-RUN. Requires 077.
-- Rollback: 517_admin_question_type_columns_rollback.sql (077 body).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_admin_question_type_list','P') IS NULL
BEGIN
    PRINT 'ABORT (517): run 077 first. Nothing was changed.';
    SET NOEXEC ON;
END
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
                   N'type_code', N'question_code', N'code')
    ORDER BY CASE name
        WHEN N'assurance_question_type_code' THEN 1
        WHEN N'question_type_code'           THEN 2
        WHEN N'type_code'                    THEN 3
        WHEN N'question_code'                THEN 4   -- 517: Control Management 024
        WHEN N'code'                         THEN 5
        ELSE 99 END;

    ;WITH candidates AS (
        SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id
    )
    SELECT TOP 1 @name_col = name FROM candidates
    WHERE name IN (N'assurance_question_type_name', N'question_type_name',
                   N'type_name', N'question_name', N'name', N'label', N'display_name')
    ORDER BY CASE name
        WHEN N'assurance_question_type_name' THEN 1
        WHEN N'question_type_name'           THEN 2
        WHEN N'type_name'                    THEN 3
        WHEN N'question_name'                THEN 4   -- 517: Control Management 024
        WHEN N'name'                         THEN 5
        WHEN N'label'                        THEN 6
        WHEN N'display_name'                 THEN 7
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

    -- 517: list in the Admin's own order when the table has one.
    DECLARE @order_col NVARCHAR(128) =
        (SELECT TOP 1 c.name FROM sys.columns c
         WHERE c.object_id = @tbl_id AND c.name IN (N'display_order', N'sort_order'));

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

    SET @sql = @sql + N' ORDER BY '
             + CASE WHEN @order_col IS NOT NULL THEN QUOTENAME(@order_col) + N', ' ELSE N'' END
             + QUOTENAME(@name_col) + N';';

    EXEC sp_executesql @sql;
END
GO

-- 517-a  what the screens will now list.
EXEC grac_practice.sp_org_assurance_admin_question_type_list;
GO
PRINT '517 complete. The list above is what Response Type offers.';
GO
SET NOEXEC OFF;
GO
