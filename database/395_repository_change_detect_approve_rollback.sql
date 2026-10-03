-- =====================================================================
-- 395 rollback: removes change detection / approval.
--   * detection, apply, list and notification procedures
--   * organization_repository_change, organization_repository_change_notification
--   * repository_copy_config.label_sql
--   * sp_repo_clone_sync and sp_repository_copy_statements back to their
--     391 / 392 definitions
-- Decisions already applied to the copies stay applied (they are ordinary
-- copy rows); only the change history is dropped. Also revert the API /
-- Web changes of phase 3 (RepositoryChange* files, Program.cs worker
-- registration, practice.js / home-my-work.js additions).
-- ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_repository_change_notification_mark_read;
DROP PROCEDURE IF EXISTS grac_practice.sp_repository_change_notification_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_repository_change_counts;
DROP PROCEDURE IF EXISTS grac_practice.sp_repository_change_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_repository_change_apply;
DROP PROCEDURE IF EXISTS grac_practice.sp_repository_change_detect;
DROP PROCEDURE IF EXISTS grac_practice.sp_repo_change_detect_step;
GO
DROP TABLE IF EXISTS grac_practice.organization_repository_change_notification;
DROP TABLE IF EXISTS grac_practice.organization_repository_change;
GO
IF COL_LENGTH('grac_practice.repository_copy_config','label_sql') IS NOT NULL
    ALTER TABLE grac_practice.repository_copy_config DROP COLUMN label_sql;
GO

-- sp_repo_clone_sync as left by 391
CREATE OR ALTER PROCEDURE grac_practice.sp_repo_clone_sync
    @copy_code       NVARCHAR(40),
    @organization_id BIGINT,
    @release_id      BIGINT,
    @refresh         BIT = 0,
    @actor           NVARCHAR(100) = N'system',
    @key_value       BIGINT = NULL,
    @inserted        INT = NULL OUTPUT,
    @updated         INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @view SYSNAME, @target SYSNAME, @pk SYSNAME, @key SYSNAME, @scope NVARCHAR(MAX), @msg NVARCHAR(400);
    SELECT @view = source_view, @target = target_table, @pk = org_pk_column,
           @key = key_column, @scope = scope_sql
    FROM grac_practice.repository_copy_config
    WHERE copy_code = @copy_code AND is_generic_clone = 1 AND status = N'Active';
    IF @view IS NULL
    BEGIN
        SET @msg = N'sp_repo_clone_sync: no active generic copy_code ' + ISNULL(@copy_code, N'(null)') + N'.';
        THROW 53913, @msg, 1;
    END

    DECLARE @view_q   NVARCHAR(300) = N'grac_practice.' + QUOTENAME(@view);
    DECLARE @target_q NVARCHAR(300) = N'grac_practice.' + QUOTENAME(@target);
    DECLARE @view_id   INT = OBJECT_ID(@view_q, 'V');
    DECLARE @target_id INT = OBJECT_ID(@target_q, 'U');
    DECLARE @key_q NVARCHAR(300) = QUOTENAME(@key);

    DECLARE @cols NVARCHAR(MAX), @src_cols NVARCHAR(MAX), @set_cols NVARCHAR(MAX);
    SELECT @cols     = STRING_AGG(CAST(QUOTENAME(tc.name) AS NVARCHAR(MAX)), N', ')
                       WITHIN GROUP (ORDER BY tc.column_id),
           @src_cols = STRING_AGG(CAST(N'src.' + QUOTENAME(tc.name) AS NVARCHAR(MAX)), N', ')
                       WITHIN GROUP (ORDER BY tc.column_id),
           @set_cols = STRING_AGG(CAST(QUOTENAME(tc.name) + N' = src.' + QUOTENAME(tc.name) AS NVARCHAR(MAX)), N', ')
                       WITHIN GROUP (ORDER BY tc.column_id)
    FROM sys.columns tc
    JOIN sys.columns vc ON vc.object_id = @view_id AND vc.name = tc.name
    WHERE tc.object_id = @target_id
      AND tc.name <> @pk
      AND tc.name NOT IN (SELECT r.column_name FROM grac_practice.fn_repo_clone_reserved_columns() r);

    DECLARE @status_filter NVARCHAR(100) =
        CASE WHEN EXISTS (SELECT 1 FROM sys.columns WHERE object_id = @view_id AND name = N'status')
             THEN N' AND src.status = N''Active''' ELSE N'' END;

    DECLARE @params NVARCHAR(400) =
        N'@organization_id BIGINT, @release_id BIGINT, @actor NVARCHAR(100), @key_value BIGINT, @n INT OUTPUT';
    DECLARE @sql NVARCHAR(MAX);

    SET @updated = 0;
    IF @refresh = 1
    BEGIN
        SET @sql = N'UPDATE t SET ' + @set_cols + N',
       source_version_hash = src.content_hash,
       copied_dt = SYSUTCDATETIME(),
       copied_by = @actor
FROM ' + @target_q + N' t
JOIN ' + @view_q + N' src ON src.' + @key_q + N' = t.' + @key_q + N'
WHERE t.organization_id = @organization_id
  AND (' + @scope + N')
  AND (@key_value IS NULL OR src.' + @key_q + N' = @key_value)
  AND (t.source_version_hash IS NULL OR src.content_hash IS NULL
       OR t.source_version_hash <> src.content_hash);
SET @n = @@ROWCOUNT;';
        EXEC sp_executesql @sql, @params, @organization_id = @organization_id, @release_id = @release_id,
             @actor = @actor, @key_value = @key_value, @n = @updated OUTPUT;
    END

    SET @sql = N'INSERT ' + @target_q + N'(organization_id, lifecycle_status, source_version_hash, copied_dt, copied_by, ' + @cols + N')
SELECT @organization_id, N''Active'', src.content_hash, SYSUTCDATETIME(), @actor, ' + @src_cols + N'
FROM ' + @view_q + N' src
WHERE (' + @scope + N')' + @status_filter + N'
  AND (@key_value IS NULL OR src.' + @key_q + N' = @key_value)
  AND NOT EXISTS (SELECT 1 FROM ' + @target_q + N' t
                  WHERE t.organization_id = @organization_id
                    AND t.' + @key_q + N' = src.' + @key_q + N');
SET @n = @@ROWCOUNT;';
    SET @inserted = 0;
    EXEC sp_executesql @sql, @params, @organization_id = @organization_id, @release_id = @release_id,
         @actor = @actor, @key_value = @key_value, @n = @inserted OUTPUT;
END
GO

-- sp_repository_copy_statements as left by 392
CREATE OR ALTER PROCEDURE grac_practice.sp_repository_copy_statements
    @organization_id BIGINT,
    @release_id      BIGINT,
    @refresh         BIT           = 0,
    @actor           NVARCHAR(100) = N'system',
    @inserted        INT           = NULL OUTPUT,
    @updated         INT           = NULL OUTPUT
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
      AND (ofs.copied_dt IS NULL
           OR (@refresh = 1
               AND (ofs.source_version_hash IS NULL
                    OR ofs.source_version_hash <> src.content_hash
                    OR ofs.org_structure_node_id IS NULL)));
    SET @updated = @@ROWCOUNT;
END
GO

PRINT '395 rolled back.';
GO
