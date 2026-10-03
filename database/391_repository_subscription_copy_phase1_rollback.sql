-- =====================================================================
-- 391 rollback: removes the phase 1 copy model.
--   * sp_repository_subscription_copy and the copy helpers
--   * the five vw_repo_src_* views
--   * the four organization copy tables and repository_copy_config
--   * the columns 391 added to organization_framework_statements
-- Nothing reads any of these yet (phase 2 is not deployed), so no screen
-- changes. The copied data is lost; re-running 391 rebuilds it.
-- Also revert the 391 edit in PracticeRepositoryService.cs
-- (CopyRepositorySubscriptionsAsync call); it is harmless when left,
-- because it skips when the procedure does not exist.
-- ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_repository_subscription_copy;
DROP PROCEDURE IF EXISTS grac_practice.sp_repo_clone_sync;
DROP PROCEDURE IF EXISTS grac_practice.sp_repo_clone_ensure_table;
DROP PROCEDURE IF EXISTS grac_practice.sp_repo_build_source_view;
GO

DROP VIEW IF EXISTS grac_practice.vw_repo_src_obligation;
DROP VIEW IF EXISTS grac_practice.vw_repo_src_obligation_evidence;
DROP VIEW IF EXISTS grac_practice.vw_repo_src_obligation_map;
DROP VIEW IF EXISTS grac_practice.vw_repo_src_framework_statement;
DROP VIEW IF EXISTS grac_practice.vw_repo_src_structure_node;
GO

DROP TABLE IF EXISTS grac_practice.organization_obligation_evidence;
DROP TABLE IF EXISTS grac_practice.organization_obligation_requirement_map;
DROP TABLE IF EXISTS grac_practice.organization_obligation;
GO

-- organization_framework_statements: FK and default first, then columns.
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_ofs_org_structure_node')
    ALTER TABLE grac_practice.organization_framework_statements DROP CONSTRAINT fk_pm_ofs_org_structure_node;
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'df_pm_ofs_lifecycle_status')
    ALTER TABLE grac_practice.organization_framework_statements DROP CONSTRAINT df_pm_ofs_lifecycle_status;
GO
DECLARE @col SYSNAME, @sql NVARCHAR(MAX);
DECLARE col_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT v.column_name
    FROM (VALUES (N'org_structure_node_id'), (N'source_version_hash'), (N'copied_dt'), (N'copied_by'),
                 (N'lifecycle_status'), (N'statement_reference'), (N'statement_title'),
                 (N'statement_text'), (N'display_order'), (N'structure_node_id')) AS v(column_name);
OPEN col_cursor;
FETCH NEXT FROM col_cursor INTO @col;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF COL_LENGTH('grac_practice.organization_framework_statements', @col) IS NOT NULL
    BEGIN
        SET @sql = N'ALTER TABLE grac_practice.organization_framework_statements DROP COLUMN ' + QUOTENAME(@col) + N';';
        EXEC sp_executesql @sql;
    END
    FETCH NEXT FROM col_cursor INTO @col;
END
CLOSE col_cursor;
DEALLOCATE col_cursor;
GO

DROP TABLE IF EXISTS grac_practice.organization_statement_structure_node;
DROP TABLE IF EXISTS grac_practice.repository_copy_config;
GO

DROP FUNCTION IF EXISTS grac_practice.fn_repo_clone_reserved_columns;
DROP FUNCTION IF EXISTS grac_practice.fn_repo_column_type;
GO

PRINT '391 rolled back.';
GO
