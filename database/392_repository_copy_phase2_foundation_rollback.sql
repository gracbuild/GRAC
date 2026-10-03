-- =====================================================================
-- 392 rollback: removes the phase 2a foundation.
--   * fn_org_* reader functions, fn_repo_source_key
--   * sp_repository_practice_import, sp_repository_copy_statements
--   * the five copy tables and source views 392 added
--   * the 392 rows and handler_proc column of repository_copy_config
-- AFTER RUNNING THIS, RE-RUN 391: it restores 391's own
-- sp_repository_subscription_copy (inline statement block). 391 is safe
-- to re-run; its backfill only inserts what is missing.
-- Practices (organization_requirement) and statement mappings the 392
-- backfill created are KEPT: they are the same rows the Practices page
-- would have created, and practice instances may already hang off them.
-- ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
GO

-- Reader functions: drop every fn_org_* in grac_practice.
DECLARE @fn SYSNAME, @sql NVARCHAR(MAX);
DECLARE fn_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT o.name
    FROM sys.objects o
    WHERE o.schema_id = SCHEMA_ID('grac_practice')
      AND o.type IN ('IF', 'TF', 'FN')
      AND o.name LIKE N'fn[_]org[_]%';
OPEN fn_cursor;
FETCH NEXT FROM fn_cursor INTO @fn;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'DROP FUNCTION grac_practice.' + QUOTENAME(@fn) + N';';
    EXEC sp_executesql @sql;
    FETCH NEXT FROM fn_cursor INTO @fn;
END
CLOSE fn_cursor;
DEALLOCATE fn_cursor;
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_repository_practice_import;
DROP PROCEDURE IF EXISTS grac_practice.sp_repository_copy_statements;
DROP FUNCTION IF EXISTS grac_practice.fn_repo_source_key;
GO

DROP TABLE IF EXISTS grac_practice.organization_repository_requirement;
DROP TABLE IF EXISTS grac_practice.organization_statement_requirement_map;
DROP TABLE IF EXISTS grac_practice.organization_control_requirement_map;
DROP TABLE IF EXISTS grac_practice.organization_repository_control;
DROP TABLE IF EXISTS grac_practice.organization_source_control_map;
GO

DROP VIEW IF EXISTS grac_practice.vw_repo_src_requirement;
DROP VIEW IF EXISTS grac_practice.vw_repo_src_statement_requirement_map;
DROP VIEW IF EXISTS grac_practice.vw_repo_src_control_requirement_map;
DROP VIEW IF EXISTS grac_practice.vw_repo_src_control;
DROP VIEW IF EXISTS grac_practice.vw_repo_src_source_control_map;
GO

IF OBJECT_ID('grac_practice.repository_copy_config','U') IS NOT NULL
    DELETE grac_practice.repository_copy_config
    WHERE copy_code IN (N'SourceControlMap', N'Control', N'ControlRequirementMap',
                        N'StatementRequirementMap', N'Requirement', N'PracticeImport');
GO
IF COL_LENGTH('grac_practice.repository_copy_config','handler_proc') IS NOT NULL
    ALTER TABLE grac_practice.repository_copy_config DROP COLUMN handler_proc;
GO

PRINT '392 rolled back. Now re-run 391_repository_subscription_copy_phase1.sql.';
GO
