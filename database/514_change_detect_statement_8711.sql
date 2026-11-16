-- =====================================================================
-- 514  Change detection: Msg 8711 on the Statement step
--
-- REPORTED (2026-11-04)
--   EXEC grac_practice.sp_repository_change_detect  ->
--   Msg 8711 "Multiple ordered aggregate functions in the same scope have
--   mutually incompatible orderings."
--   diagnose_change_detect_8711.sql: only copy step 'Statement', Added /
--   Changed pass, every organization and release.  All other steps, and
--   Statement's Retired pass, run.  SQL Server 16 (2022), compat 160; the
--   478 classification functions are NOT inlined.
--
-- CAUSE
--   vw_repo_src_framework_statement (478) carries two ordered lists --
--   classification ids (by id) and names (by display order, name).  The
--   Added and Changed queries of sp_repo_change_detect_step read that view
--   inside one large statement: a FOR JSON snapshot of the row, its hash,
--   a join to the copy table.  The optimizer folds the view's ordered
--   aggregates into that statement and refuses the plan.  478 met the same
--   error on the development database and solved its own re-baseline by
--   reading the view into a temp table first ("the updates below then
--   never put the view inside a bigger plan"); the detection step was not
--   given the same treatment, and the plan UAT now picks fails.
--
-- FIX (sp_repo_change_detect_step, 395 body)
--   Added and Changed first copy the in-scope Active source rows into #src
--   (SELECT ... INTO, indexed on the key), then run exactly as before
--   against #src.  Same rows, same columns, same JSON, same hash -- only
--   the view is read on its own.  Applied to every copy step, not only
--   Statement: one code path, and the obligation view (ordered evidence
--   JSON) cannot hit the same plan later.  The Retired pass is unchanged.
--   Each sp_executesql call is its own scope, so #src never outlives the
--   query that made it.
--
-- SAFE TO RE-RUN. Requires 395.
-- Rollback: 514_change_detect_statement_8711_rollback.sql (395 body).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_repo_change_detect_step','P') IS NULL
   OR OBJECT_ID('grac_practice.repository_copy_config','U') IS NULL
   OR COL_LENGTH('grac_practice.repository_copy_config','label_sql') IS NULL
   OR OBJECT_ID('grac_practice.organization_repository_change','U') IS NULL
BEGIN
    PRINT 'ABORT (514): run 395 first. Nothing was changed.';
    SET NOEXEC ON;
END
GO

-- sp_repo_change_detect_step (395 body; Added / Changed read #src)
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
        -- 514: the in-scope source rows are read into #src first, and the
        -- INSERT reads #src -- see the migration header (Msg 8711).
        SET @sql = N'SELECT src.* INTO #src FROM ' + @view_q + N' src
WHERE (' + @scope + N')
  AND src.status = N''Active'';
CREATE CLUSTERED INDEX ix_src_key ON #src(' + @key_q + N');
INSERT grac_practice.organization_repository_change(
    organization_id, release_id, copy_code, change_action, change_type, source_key, source_label,
    old_snapshot_json, new_snapshot_json, new_version_hash, status, detection_run_id, entered_by)
SELECT @organization_id, @release_id, @copy_code, N''Added'', @copy_code + N''Added'', src.' + @key_q + N',
       LEFT(' + REPLACE(@label, N'{a}', N'src') + N', 500),
       NULL,
       (SELECT s2.* FROM #src s2 WHERE s2.' + @key_q + N' = src.' + @key_q + N'
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       src.content_hash, N''Pending'', @run_id, @actor
FROM #src src
WHERE NOT EXISTS (SELECT 1 FROM ' + @target_q + N' t
                  WHERE t.organization_id = @organization_id
                    AND t.' + @key_q + N' = src.' + @key_q + @target_filter + @release_match + N')'
  + REPLACE(REPLACE(REPLACE(@already, N'{key}', N'src.' + @key_q), N'{action}', N'Added'), N'{hash}', N'src.content_hash') + N';
SET @n = @@ROWCOUNT;';
        SET @n = 0;
        EXEC sp_executesql @sql, @params, @organization_id = @organization_id, @release_id = @release_id,
             @copy_code = @copy_code, @run_id = @run_id, @actor = @actor, @n = @n OUTPUT;
        SET @raised = @raised + ISNULL(@n, 0);

        -- Changed: a copy whose source (still Active, still in this
        -- release) now hashes differently.  514: read through #src, as above.
        SET @sql = N'SELECT src.* INTO #src FROM ' + @view_q + N' src
WHERE (' + @scope + N')
  AND src.status = N''Active'';
CREATE CLUSTERED INDEX ix_src_key ON #src(' + @key_q + N');
INSERT grac_practice.organization_repository_change(
    organization_id, release_id, copy_code, change_action, change_type, source_key, source_label,
    old_snapshot_json, new_snapshot_json, new_version_hash, status, detection_run_id, entered_by)
SELECT @organization_id, @release_id, @copy_code, N''Changed'', @copy_code + N''Changed'', src.' + @key_q + N',
       LEFT(' + REPLACE(@label, N'{a}', N'src') + N', 500),
       (SELECT t2.* FROM ' + @target_q + N' t2 WHERE t2.' + @pk_q + N' = t.' + @pk_q + N'
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       (SELECT s2.* FROM #src s2 WHERE s2.' + @key_q + N' = src.' + @key_q + N'
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       src.content_hash, N''Pending'', @run_id, @actor
FROM ' + @target_q + N' t
JOIN #src src ON src.' + @key_q + N' = t.' + @key_q + N'
WHERE t.organization_id = @organization_id' + @target_filter + @release_match + N'
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

-- Verification: the step reads through #src, and a full detection run
-- for every organization completes.  The run is rolled back, so it adds
-- nothing to Repository Updates -- run sp_repository_change_detect (or let
-- the worker run) afterwards for real.
SELECT N'514-a step reads #src' AS [Check],
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_repo_change_detect_step')) LIKE '%INTO #src%'
            THEN N'PASS' ELSE N'FAIL' END AS Result;
GO
SET XACT_ABORT OFF;
DECLARE @ok NVARCHAR(10) = N'PASS', @why NVARCHAR(4000) = NULL, @r INT, @nn INT;
BEGIN TRANSACTION;
BEGIN TRY
    EXEC grac_practice.sp_repository_change_detect
         @actor = N'verify-514', @raised_count = @r OUTPUT, @notified_count = @nn OUTPUT,
         @suppress_result = 1;
END TRY
BEGIN CATCH
    SELECT @ok = N'FAIL', @why = CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE());
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
SELECT N'514-b full detection run (rolled back)' AS [Check], @ok AS Result,
       @r AS WouldRaise, @why AS Error;
GO

PRINT '514 complete. Now run EXEC grac_practice.sp_repository_change_detect (or let the worker run).';
GO
SET NOEXEC OFF;
GO
