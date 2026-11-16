-- =====================================================================
-- 514 ROLLBACK -- sp_repo_change_detect_step back to its 395 body.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_repo_change_detect_step
    @copy_code       NVARCHAR(40),
    @organization_id BIGINT,
    @release_id      BIGINT,
    @run_id          UNIQUEIDENTIFIER,
    @actor           NVARCHAR(100) = N'system',
    @raised          INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @raised = 0;

    DECLARE @view SYSNAME, @target SYSNAME, @pk SYSNAME, @key SYSNAME, @scope NVARCHAR(MAX),
            @label NVARCHAR(MAX), @generic BIT;
    SELECT @view = source_view, @target = target_table, @pk = org_pk_column, @key = key_column,
           @scope = scope_sql, @label = ISNULL(label_sql, N'CAST(NULL AS NVARCHAR(500))'),
           @generic = is_generic_clone
    FROM grac_practice.repository_copy_config
    WHERE copy_code = @copy_code AND status = N'Active';

    DECLARE @view_q   NVARCHAR(300) = N'grac_practice.' + QUOTENAME(@view);
    DECLARE @target_q NVARCHAR(300) = N'grac_practice.' + QUOTENAME(@target);
    -- Steps without a source view (PracticeImport) have nothing to detect.
    IF @view IS NULL OR OBJECT_ID(@view_q, 'V') IS NULL OR OBJECT_ID(@target_q, 'U') IS NULL RETURN;

    DECLARE @key_q NVARCHAR(300) = QUOTENAME(@key);
    DECLARE @pk_q  NVARCHAR(300) = QUOTENAME(@pk);
    -- organization_framework_statements holds custom rows and one row per
    -- release; everything else is one row per (organization, key).
    DECLARE @target_filter NVARCHAR(400) =
        CASE WHEN @copy_code = N'Statement'
             THEN N' AND t.source_type = N''Repository'' AND t.copied_dt IS NOT NULL'
             ELSE N'' END;
    DECLARE @release_match NVARCHAR(200) =
        CASE WHEN @copy_code = N'Statement' THEN N' AND t.release_id = @release_id' ELSE N'' END;
    DECLARE @retired_release NVARCHAR(100) =
        CASE WHEN COL_LENGTH(@target_q, 'release_id') IS NOT NULL THEN N't.release_id' ELSE N'NULL' END;

    DECLARE @params NVARCHAR(400) =
        N'@organization_id BIGINT, @release_id BIGINT, @copy_code NVARCHAR(40), @run_id UNIQUEIDENTIFIER, @actor NVARCHAR(100), @n INT OUTPUT';
    DECLARE @sql NVARCHAR(MAX), @n INT;

    DECLARE @already NVARCHAR(MAX) = N'
  AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_repository_change c
                  WHERE c.organization_id = @organization_id
                    AND c.copy_code = @copy_code
                    AND c.source_key = {key}
                    AND c.change_action = N''{action}''
                    AND c.status IN (N''Pending'', N''Approved'', N''Rejected'')
                    AND ISNULL(c.new_version_hash, 0x) = ISNULL({hash}, 0x))';

    IF @release_id IS NOT NULL
    BEGIN
        -- Added: an Active source row of this release the organization has no copy of.
        SET @sql = N'INSERT grac_practice.organization_repository_change(
    organization_id, release_id, copy_code, change_action, change_type, source_key, source_label,
    old_snapshot_json, new_snapshot_json, new_version_hash, status, detection_run_id, entered_by)
SELECT @organization_id, @release_id, @copy_code, N''Added'', @copy_code + N''Added'', src.' + @key_q + N',
       LEFT(' + REPLACE(@label, N'{a}', N'src') + N', 500),
       NULL,
       (SELECT s2.* FROM ' + @view_q + N' s2 WHERE s2.' + @key_q + N' = src.' + @key_q + N'
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       src.content_hash, N''Pending'', @run_id, @actor
FROM ' + @view_q + N' src
WHERE (' + @scope + N')
  AND src.status = N''Active''
  AND NOT EXISTS (SELECT 1 FROM ' + @target_q + N' t
                  WHERE t.organization_id = @organization_id
                    AND t.' + @key_q + N' = src.' + @key_q + @target_filter + @release_match + N')'
  + REPLACE(REPLACE(REPLACE(@already, N'{key}', N'src.' + @key_q), N'{action}', N'Added'), N'{hash}', N'src.content_hash') + N';
SET @n = @@ROWCOUNT;';
        SET @n = 0;
        EXEC sp_executesql @sql, @params, @organization_id = @organization_id, @release_id = @release_id,
             @copy_code = @copy_code, @run_id = @run_id, @actor = @actor, @n = @n OUTPUT;
        SET @raised = @raised + ISNULL(@n, 0);

        -- Changed: a copy whose source (still Active, still in this
        -- release) now hashes differently.
        SET @sql = N'INSERT grac_practice.organization_repository_change(
    organization_id, release_id, copy_code, change_action, change_type, source_key, source_label,
    old_snapshot_json, new_snapshot_json, new_version_hash, status, detection_run_id, entered_by)
SELECT @organization_id, @release_id, @copy_code, N''Changed'', @copy_code + N''Changed'', src.' + @key_q + N',
       LEFT(' + REPLACE(@label, N'{a}', N'src') + N', 500),
       (SELECT t2.* FROM ' + @target_q + N' t2 WHERE t2.' + @pk_q + N' = t.' + @pk_q + N'
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       (SELECT s2.* FROM ' + @view_q + N' s2 WHERE s2.' + @key_q + N' = src.' + @key_q + N'
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       src.content_hash, N''Pending'', @run_id, @actor
FROM ' + @target_q + N' t
JOIN ' + @view_q + N' src ON src.' + @key_q + N' = t.' + @key_q + N'
WHERE t.organization_id = @organization_id' + @target_filter + @release_match + N'
  AND (' + @scope + N')
  AND src.status = N''Active''
  AND t.lifecycle_status = N''Active''
  AND t.source_version_hash IS NOT NULL
  AND src.content_hash IS NOT NULL
  AND t.source_version_hash <> src.content_hash'
  + REPLACE(REPLACE(REPLACE(@already, N'{key}', N'src.' + @key_q), N'{action}', N'Changed'), N'{hash}', N'src.content_hash') + N';
SET @n = @@ROWCOUNT;';
        SET @n = 0;
        EXEC sp_executesql @sql, @params, @organization_id = @organization_id, @release_id = @release_id,
             @copy_code = @copy_code, @run_id = @run_id, @actor = @actor, @n = @n OUTPUT;
        SET @raised = @raised + ISNULL(@n, 0);
    END
    ELSE
    BEGIN
        -- Retired: a copy row whose source no longer exists as Active.
        SET @sql = N'INSERT grac_practice.organization_repository_change(
    organization_id, release_id, copy_code, change_action, change_type, source_key, source_label,
    old_snapshot_json, new_snapshot_json, new_version_hash, status, detection_run_id, entered_by)
SELECT @organization_id, ' + @retired_release + N', @copy_code, N''Retired'', @copy_code + N''Retired'', t.' + @key_q + N',
       LEFT(' + REPLACE(@label, N'{a}', N't') + N', 500),
       (SELECT t2.* FROM ' + @target_q + N' t2 WHERE t2.' + @pk_q + N' = t.' + @pk_q + N'
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       NULL, NULL, N''Pending'', @run_id, @actor
FROM ' + @target_q + N' t
WHERE t.organization_id = @organization_id' + @target_filter + N'
  AND t.lifecycle_status = N''Active''
  AND NOT EXISTS (SELECT 1 FROM ' + @view_q + N' src
                  WHERE src.' + @key_q + N' = t.' + @key_q + N'
                    AND src.status = N''Active'')'
  + REPLACE(REPLACE(REPLACE(@already, N'{key}', N't.' + @key_q), N'{action}', N'Retired'), N'{hash}', N'CAST(NULL AS VARBINARY(32))') + N';
SET @n = @@ROWCOUNT;';
        SET @n = 0;
        EXEC sp_executesql @sql, @params, @organization_id = @organization_id, @release_id = @release_id,
             @copy_code = @copy_code, @run_id = @run_id, @actor = @actor, @n = @n OUTPUT;
        SET @raised = @raised + ISNULL(@n, 0);
    END
END
GO
PRINT '514 rollback complete.';
GO
