-- =====================================================================
-- 072 Organization Assurance -- Admin (grac_new) lookup procs
--
-- Depends on:
--   * 069 (org_assurance schema)
--   * Admin / ControlManagement (grac_new schema) -- the assurance
--     category master lives there, published by Phase 1.
--
-- Introduces:
--   grac_practice.sp_org_assurance_admin_category_list
--     Returns { Id, Code, Name, Description } sourced from
--     grac_new.assurance_category. Used by the "Assurance Category"
--     dropdown on the Assurance Definitions screen.
--
-- Defensive guard:
--   If grac_new.assurance_category is not yet deployed in this
--   environment (e.g. a Practice-Management-only sandbox), the proc
--   returns an EMPTY result set instead of failing. The UI then falls
--   back to a "no categories available" state, preserving the "no
--   guessing" contract.
--
-- Column-name convention:
--   Mirrors grac_new.control (control_code / control_name / status).
--   If the Admin migration used different column names, update the
--   SELECT list below -- no other file needs changing.
--
-- Rollback: database/072_org_assurance_admin_lookups_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

-- Column names in grac_new.assurance_category can vary across Admin
-- deployments (assurance_category_code vs category_code vs code, etc.).
-- We discover the actual column names at RUNTIME via sys.columns and
-- build the SELECT dynamically -- so this proc installs regardless of
-- the Admin schema and returns an empty result set gracefully when it
-- can't find id + name columns to project.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_admin_category_list
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('grac_new.assurance_category','U') IS NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT)     AS Id,
               CAST(NULL AS NVARCHAR(120)) AS Code,
               CAST(NULL AS NVARCHAR(200)) AS Name,
               CAST(NULL AS NVARCHAR(1000)) AS Description
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @tbl_id INT = OBJECT_ID('grac_new.assurance_category');
    DECLARE @id_col NVARCHAR(128), @code_col NVARCHAR(128),
            @name_col NVARCHAR(128), @desc_col NVARCHAR(128),
            @status_col NVARCHAR(128);

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @id_col = name FROM candidates
    WHERE name IN (N'assurance_category_id', N'category_id', N'id')
    ORDER BY CASE name
        WHEN N'assurance_category_id' THEN 1
        WHEN N'category_id'           THEN 2
        WHEN N'id'                    THEN 3
        ELSE 99 END;

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @code_col = name FROM candidates
    WHERE name IN (N'assurance_category_code', N'category_code', N'code')
    ORDER BY CASE name
        WHEN N'assurance_category_code' THEN 1
        WHEN N'category_code'           THEN 2
        WHEN N'code'                    THEN 3
        ELSE 99 END;

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @name_col = name FROM candidates
    WHERE name IN (N'assurance_category_name', N'category_name', N'name',
                   N'label', N'display_name')
    ORDER BY CASE name
        WHEN N'assurance_category_name' THEN 1
        WHEN N'category_name'           THEN 2
        WHEN N'name'                    THEN 3
        WHEN N'label'                   THEN 4
        WHEN N'display_name'            THEN 5
        ELSE 99 END;

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @desc_col = name FROM candidates
    WHERE name IN (N'description', N'notes', N'remarks');

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @status_col = name FROM candidates
    WHERE name IN (N'status', N'is_active', N'active_flag');

    IF @id_col IS NULL OR @name_col IS NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT)     AS Id,
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
        FROM grac_new.assurance_category';

    IF @status_col = N'status'
        SET @sql = @sql + N' WHERE ' + QUOTENAME(@status_col) + N' = N''Active''';
    ELSE IF @status_col IN (N'is_active', N'active_flag')
        SET @sql = @sql + N' WHERE ' + QUOTENAME(@status_col) + N' = 1';

    SET @sql = @sql + N' ORDER BY ' + QUOTENAME(@name_col) + N';';

    EXEC sp_executesql @sql;
END
GO

PRINT '072 sp_org_assurance_admin_category_list installed.';
GO
