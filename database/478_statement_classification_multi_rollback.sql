-- =====================================================================
-- 478_statement_classification_multi_rollback.sql
--
-- Reverses 478:
--   1. Re-issues, verbatim, sp_repository_copy_statements (395) and
--      sp_repo_build_source_view (391).
--   2. Rebuilds vw_repo_src_framework_statement the 391 way (every column
--      of grac_new.framework_statement, classification_id included, no
--      classifications), keeping the copies that were in step in step.
--   3. Drops organization_framework_statements.classification_ids /
--      classification_names and the two classification list functions,
--      and refreshes the modules that read the table.
--   Pending Statement changes get the 391 snapshot and hash back.
-- Control Management 079 is NOT reversed by this file.
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- 1. The 395 copy procedure (no classification columns).
CREATE OR ALTER PROCEDURE grac_practice.sp_repository_copy_statements
    @organization_id        BIGINT,
    @release_id             BIGINT,
    @refresh                BIT           = 0,
    @actor                  NVARCHAR(100) = N'system',
    @inserted               INT           = NULL OUTPUT,
    @updated                INT           = NULL OUTPUT,
    @framework_statement_id BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @not_updated_status_id INT = (
        SELECT TOP (1) applicability_status_id
        FROM grac_practice.applicability_status_master
        WHERE status_code = 'Not Updated' OR status_name = 'Not Updated');
    DECLARE @active_status_id INT = (
        SELECT TOP (1) record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'Active' OR status_name = 'Active');

    INSERT grac_practice.organization_framework_statements(
        organization_id, release_id, framework_statement_id,
        applicability_status_id, status_id, status, entered_by)
    SELECT @organization_id, @release_id, src.framework_statement_id,
           @not_updated_status_id, @active_status_id, N'Active', @actor
    FROM grac_practice.vw_repo_src_framework_statement src
    WHERE src.release_id = @release_id
      AND src.status = N'Active'
      AND (@framework_statement_id IS NULL OR src.framework_statement_id = @framework_statement_id)
      AND NOT EXISTS (
          SELECT 1 FROM grac_practice.organization_framework_statements x
          WHERE x.organization_id = @organization_id
            AND x.release_id = @release_id
            AND x.framework_statement_id = src.framework_statement_id);
    SET @inserted = @@ROWCOUNT;

    UPDATE ofs
    SET statement_reference   = src.statement_reference,
        statement_title       = src.statement_title,
        statement_text        = src.statement_text,
        display_order         = src.display_order,
        structure_node_id     = src.structure_node_id,
        org_structure_node_id = node.org_structure_node_id,
        source_version_hash   = src.content_hash,
        copied_dt             = SYSUTCDATETIME(),
        copied_by             = @actor
    FROM grac_practice.organization_framework_statements ofs
    JOIN grac_practice.vw_repo_src_framework_statement src
      ON src.framework_statement_id = ofs.framework_statement_id
    LEFT JOIN grac_practice.organization_statement_structure_node node
      ON node.organization_id = ofs.organization_id
     AND node.structure_node_id = src.structure_node_id
    WHERE ofs.organization_id = @organization_id
      AND ofs.release_id = @release_id
      AND ofs.source_type = N'Repository'
      AND (@framework_statement_id IS NULL OR ofs.framework_statement_id = @framework_statement_id)
      AND (ofs.copied_dt IS NULL
           OR @framework_statement_id IS NOT NULL
           OR (@refresh = 1
               AND (ofs.source_version_hash IS NULL
                    OR ofs.source_version_hash <> src.content_hash
                    OR ofs.org_structure_node_id IS NULL)));
    SET @updated = @@ROWCOUNT;
END
GO

-- 1b. The 391 view builder (no @exclude_columns).
CREATE OR ALTER PROCEDURE grac_practice.sp_repo_build_source_view
    @source_table NVARCHAR(256),
    @view_name    SYSNAME,
    @extra_select NVARCHAR(MAX) = NULL,
    @extra_from   NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @src_id INT = OBJECT_ID(@source_table, 'U');
    DECLARE @msg NVARCHAR(400);
    IF @src_id IS NULL
    BEGIN
        SET @msg = N'sp_repo_build_source_view: source table ' + @source_table + N' not found.';
        THROW 53911, @msg, 1;
    END

    DECLARE @select NVARCHAR(MAX), @hash NVARCHAR(MAX);
    SELECT @select = STRING_AGG(CAST(N'src.' + QUOTENAME(c.name) AS NVARCHAR(MAX)), N', ')
                     WITHIN GROUP (ORDER BY c.column_id)
    FROM sys.columns c
    WHERE c.object_id = @src_id
      AND c.name NOT IN (SELECT r.column_name FROM grac_practice.fn_repo_clone_reserved_columns() r);

    SELECT @hash = STRING_AGG(CAST(N'src.' + QUOTENAME(c.name) AS NVARCHAR(MAX)), N', ')
                   WITHIN GROUP (ORDER BY c.column_id)
    FROM sys.columns c
    WHERE c.object_id = @src_id
      AND c.name NOT IN (SELECT r.column_name FROM grac_practice.fn_repo_clone_reserved_columns() r)
      AND c.name NOT IN (N'entered_by', N'entered_dt', N'updated_by', N'updated_dt',
                         N'modified_by', N'modified_dt', N'created_by', N'created_dt')
      AND c.system_type_id NOT IN (189, 240, 241);

    DECLARE @sql NVARCHAR(MAX) = N'CREATE OR ALTER VIEW grac_practice.' + QUOTENAME(@view_name) + N'
AS
    -- Built by grac_practice.sp_repo_build_source_view (migration 391)
    -- from the columns ' + @source_table + N' had when it ran.
    -- Re-run 391 after a Control Management schema change.
    SELECT ' + @select + ISNULL(N',
           ' + @extra_select, N'') + N',
           HASHBYTES(''SHA2_256'',
               (SELECT ' + @hash + ISNULL(N', ' + @extra_select, N'') + N'
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)) AS content_hash
    FROM ' + @source_table + N' src' + ISNULL(N'
    ' + @extra_from, N'') + N';';
    EXEC sp_executesql @sql;
END
GO

-- =====================================================================
-- 2. Rebuild the statement view the 391 way, keeping in-step copies
-- =====================================================================
IF OBJECT_ID('tempdb..#pm478rb_in_step') IS NOT NULL DROP TABLE #pm478rb_in_step;
CREATE TABLE #pm478rb_in_step (org_statement_id BIGINT NOT NULL PRIMARY KEY);
-- The current (478) view is read once into a temp table, so it is never
-- inside a join (see 478, Msg 8711). A view that cannot be read is
-- skipped: copies then keep their hash and arrive through Repository
-- Updates.
IF OBJECT_ID('tempdb..#pm478rb_old') IS NOT NULL DROP TABLE #pm478rb_old;
CREATE TABLE #pm478rb_old (framework_statement_id BIGINT NOT NULL PRIMARY KEY, content_hash VARBINARY(64) NULL);
BEGIN TRY
    EXEC sp_executesql N'INSERT #pm478rb_old (framework_statement_id, content_hash)
        SELECT v.framework_statement_id, v.content_hash FROM grac_practice.vw_repo_src_framework_statement v;';
END TRY
BEGIN CATCH
    PRINT '478 rollback: the current statement view could not be read (' + ERROR_MESSAGE() + ').';
END CATCH
INSERT #pm478rb_in_step (org_statement_id)
SELECT ofs.org_statement_id
FROM   grac_practice.organization_framework_statements ofs
JOIN   #pm478rb_old src
       ON src.framework_statement_id = ofs.framework_statement_id
WHERE  ofs.source_type = N'Repository'
  AND  ofs.copied_dt IS NOT NULL
  AND  ofs.source_version_hash = src.content_hash;
DROP TABLE #pm478rb_old;

EXEC grac_practice.sp_repo_build_source_view
     @source_table = N'grac_new.framework_statement', @view_name = N'vw_repo_src_framework_statement';
GO

-- A new batch, so the statements below are compiled against the rebuilt
-- view, not the one this file found (a batch is compiled before it runs).
UPDATE ofs SET source_version_hash = src.content_hash
FROM   grac_practice.organization_framework_statements ofs
JOIN   #pm478rb_in_step i ON i.org_statement_id = ofs.org_statement_id
JOIN   grac_practice.vw_repo_src_framework_statement src
       ON src.framework_statement_id = ofs.framework_statement_id;
PRINT '478 rollback: statement copies kept in step = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE c
   SET new_snapshot_json = (SELECT s2.* FROM grac_practice.vw_repo_src_framework_statement s2
                             WHERE s2.framework_statement_id = c.source_key
                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       new_version_hash  = src.content_hash
FROM   grac_practice.organization_repository_change c
JOIN   grac_practice.vw_repo_src_framework_statement src
       ON src.framework_statement_id = c.source_key
WHERE  c.copy_code = N'Statement'
  AND  c.status = N'Pending'
  AND  c.change_action IN (N'Added', N'Changed');
DROP TABLE #pm478rb_in_step;
GO

-- =====================================================================
-- 3. The copy columns
-- =====================================================================
IF COL_LENGTH('grac_practice.organization_framework_statements','classification_ids') IS NOT NULL
    ALTER TABLE grac_practice.organization_framework_statements DROP COLUMN classification_ids;
IF COL_LENGTH('grac_practice.organization_framework_statements','classification_names') IS NOT NULL
    ALTER TABLE grac_practice.organization_framework_statements DROP COLUMN classification_names;
GO

-- The classification list functions (478 section 2b); nothing reads them
-- once the view is back in the 391 shape.
DROP FUNCTION IF EXISTS grac_practice.fn_repo_statement_classification_ids;
DROP FUNCTION IF EXISTS grac_practice.fn_repo_statement_classification_names;
GO

DECLARE @m NVARCHAR(600);
DECLARE pm478rb_mod CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT QUOTENAME(OBJECT_SCHEMA_NAME(d.referencing_id)) + N'.' + QUOTENAME(OBJECT_NAME(d.referencing_id))
    FROM   sys.sql_expression_dependencies d
    JOIN   sys.objects o ON o.object_id = d.referencing_id
    JOIN   sys.sql_modules sm ON sm.object_id = d.referencing_id
    WHERE  d.referenced_id = OBJECT_ID('grac_practice.organization_framework_statements')
      AND  o.type IN ('V', 'IF', 'TF', 'FN')
      AND  sm.is_schema_bound = 0;
OPEN pm478rb_mod;
FETCH NEXT FROM pm478rb_mod INTO @m;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY EXEC sys.sp_refreshsqlmodule @m; END TRY
    BEGIN CATCH PRINT '478 rollback: could not refresh ' + @m + ' -- ' + ERROR_MESSAGE(); END CATCH
    FETCH NEXT FROM pm478rb_mod INTO @m;
END
CLOSE pm478rb_mod;
DEALLOCATE pm478rb_mod;
GO

SELECT '478 rollback: statement view is the 391 shape' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.vw_repo_src_framework_statement','classification_ids') IS NULL
             AND COL_LENGTH('grac_practice.organization_framework_statements','classification_ids') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
GO
PRINT '478 rollback complete.';
GO
