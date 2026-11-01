-- =====================================================================
-- 478_statement_classification_multi.sql
--
-- REQUEST (2026-10-18)
-- --------------------
--   Control Management 079 (079_statement_classification_multi.sql) made a
--   Source Statement's classification MULTI-select:
--     * GRAC_New.framework_statement_classification_map (statement ->
--       statement_classification, status Active / Inactive) is the only
--       source of truth;
--     * framework_statement.classification_id is RETIRED -- kept, holding
--       its old value, but never written or read again (a new statement
--       has NULL there, an edited one keeps a stale value).
--   Check what that does to Practice Management (applicability marking,
--   the copy into the organisation's tables, anything else) and fix it.
--
-- WHAT WAS CHECKED
-- ----------------
--   * Applicability marking (statement-applicability, bulk), Organization
--     Practices, Source Statements, Practice View, the practice picker,
--     Operationalize, reports: none of them read classification_id or
--     GRAC_New.statement_classification -- every query names its columns.
--     No change needed there.
--   * Custom Release authoring uses PM's own
--     grac_practice.custom_statement_classification (369) and never reads
--     the Control Management master. Not affected.
--   * The copy model (391/392/395) IS affected. vw_repo_src_framework_
--     statement is generated from EVERY column of grac_new.framework_
--     statement, so:
--       - it still carries the retired classification_id, which is part
--         of the statement's content_hash and of the snapshot Repository
--         Updates compares -- a frozen / NULL id, not the classification;
--       - a classification change in Control Management (now a junction
--         change) no longer changes the hash, so Repository Updates never
--         raises it and the organisation's copy never learns of it;
--       - if Control Management ever drops the retired column, the view
--         breaks and every statement subscribe, copy and detection fails.
--
-- WHAT THIS FILE DOES
-- -------------------
--   1. sp_repo_build_source_view (391) re-issued with an optional
--      @exclude_columns (comma list). Every existing call is unchanged.
--   2. organization_framework_statements gains classification_ids
--      ("1,5,9", the active ids, ordered by id -- Control Management's own
--      ClassificationIds format) and classification_names ("A, B", by
--      display order then name -- its Classification format).
--   3. vw_repo_src_framework_statement rebuilt: the retired
--      classification_id left out; classification_ids / classification_names
--      from the junction (Active links only) added, so they are part of the
--      content hash -- a classification change raises a "Changed"
--      statement in Repository Updates like any other content change.
--   4. sp_repository_copy_statements (395) re-issued: the copy carries the
--      two classification columns (subscribe, refresh and approval all use
--      this one procedure).
--   5. Re-baseline, the 473 way: statement copies that were IN STEP with
--      Control Management before the rebuild get their classifications and
--      the new hash directly, so the rebuilt hash alone does not raise a
--      "Changed" approval for every statement of every organisation.
--      Copies that were already behind keep their old hash and arrive
--      through the normal approval, classifications included. Pending
--      Statement changes get the rebuilt snapshot and hash, so detection
--      does not raise a second one for the same statement.
--   6. Views / functions over organization_framework_statements are
--      refreshed so the new columns are part of their metadata.
--   New functions: fn_repo_statement_classification_ids / _names (2b).
--
-- NOT CHANGED: no screen shows a repository statement's classification
--   today, so no UI or API change. Custom Release statements keep their
--   own single classification (369) -- a separate decision.
--
-- FIX (2026-10-18, first DEMO run): the first version built both
--   classification lists with two STRING_AGGs of different orders, which
--   SQL Server refuses at query time (Msg 8711) -- also when they sit in
--   separate APPLYs (second run), and with one STRING_AGG left on the
--   development database only (third run), and with FOR XML PATH + ORDER BY
--   (fourth run: the optimizer treats that as an ordered aggregate too and
--   merges it into a GROUP BY / FOR JSON over the view). The lists now come
--   from two scalar functions that are not inlined, so no ordering is in
--   the view's own scope, and
--   the in-step capture also reads the 391-shaped view, so re-running this
--   file repairs a database the first version left half-done.
--
-- ORDER: Control Management 079 first (the junction must exist). After
--   re-running 391 (its header: "Re-run 391 after a Control Management
--   schema change"), re-run this file: 391 rebuilds the statement view
--   without the classification columns.
-- DEPENDS ON: 391, 392, 395.
-- Rollback: 478_statement_classification_multi_rollback.sql
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;
IF OBJECT_ID('grac_practice.sp_repo_build_source_view','P') IS NULL
   OR OBJECT_ID('grac_practice.vw_repo_src_framework_statement','V') IS NULL
   OR OBJECT_ID('grac_practice.organization_framework_statements','U') IS NULL
BEGIN PRINT 'ABORT (478): the repository copy model is missing. Run 391 / 392 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.sp_repository_copy_statements','P') IS NULL
BEGIN PRINT 'ABORT (478): sp_repository_copy_statements missing. Run 395 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND (OBJECT_ID('GRAC_New.framework_statement_classification_map','U') IS NULL
                        OR OBJECT_ID('GRAC_New.statement_classification','U') IS NULL)
BEGIN PRINT 'ABORT (478): GRAC_New.framework_statement_classification_map missing. Run Control Management 079 first (or this login cannot see it).'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 0
BEGIN
    RAISERROR('478_statement_classification_multi: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_repo_build_source_view (391 body + @exclude_columns)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_repo_build_source_view
    @source_table NVARCHAR(256),
    @view_name    SYSNAME,
    @extra_select NVARCHAR(MAX) = NULL,
    @extra_from   NVARCHAR(MAX) = NULL,
    -- 478: comma-separated source columns to leave out of the view and the
    -- hash (a column Control Management has retired). NULL = none.
    @exclude_columns NVARCHAR(MAX) = NULL
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
    DECLARE @excluded TABLE (column_name SYSNAME PRIMARY KEY);
    INSERT @excluded (column_name)
    SELECT DISTINCT LTRIM(RTRIM(x.value))
    FROM   STRING_SPLIT(ISNULL(@exclude_columns, N''), N',') x
    WHERE  LTRIM(RTRIM(x.value)) <> N'';

    SELECT @select = STRING_AGG(CAST(N'src.' + QUOTENAME(c.name) AS NVARCHAR(MAX)), N', ')
                     WITHIN GROUP (ORDER BY c.column_id)
    FROM sys.columns c
    WHERE c.object_id = @src_id
      AND c.name NOT IN (SELECT r.column_name FROM grac_practice.fn_repo_clone_reserved_columns() r)
      AND c.name NOT IN (SELECT e.column_name FROM @excluded e);

    SELECT @hash = STRING_AGG(CAST(N'src.' + QUOTENAME(c.name) AS NVARCHAR(MAX)), N', ')
                   WITHIN GROUP (ORDER BY c.column_id)
    FROM sys.columns c
    WHERE c.object_id = @src_id
      AND c.name NOT IN (SELECT r.column_name FROM grac_practice.fn_repo_clone_reserved_columns() r)
      AND c.name NOT IN (SELECT e.column_name FROM @excluded e)
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
-- 2. The organisation's copy carries the classifications
-- =====================================================================
IF COL_LENGTH('grac_practice.organization_framework_statements','classification_ids') IS NULL
BEGIN
    ALTER TABLE grac_practice.organization_framework_statements ADD classification_ids NVARCHAR(MAX) NULL;
    PRINT '478: organization_framework_statements.classification_ids added.';
END
IF COL_LENGTH('grac_practice.organization_framework_statements','classification_names') IS NULL
BEGIN
    ALTER TABLE grac_practice.organization_framework_statements ADD classification_names NVARCHAR(MAX) NULL;
    PRINT '478: organization_framework_statements.classification_names added.';
END
GO

-- =====================================================================
-- 2b. The classification lists, one statement at a time
--   ids   "1,5,9"  -- active links, by id (Control Management's
--                     ClassificationIds format)
--   names "A, B"   -- by display order, then name (its Classification
--                     format)
--   NULL when the statement has none. WITH INLINE = OFF (SQL Server 2019+;
--   older versions never inline) keeps each ordered STRING_AGG in its own
--   scope -- see the note at the view rebuild.
-- =====================================================================
DECLARE @inline NVARCHAR(40) =
    CASE WHEN CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) >= 15 THEN N'WITH INLINE = OFF' ELSE N'' END;

DECLARE @sql NVARCHAR(MAX) = N'
CREATE OR ALTER FUNCTION grac_practice.fn_repo_statement_classification_ids (@framework_statement_id BIGINT)
RETURNS NVARCHAR(MAX)
' + @inline + N'
AS
BEGIN
    -- 478: the statement''s active classification ids (Control Management 079).
    RETURN (SELECT STRING_AGG(CONVERT(NVARCHAR(20), m.statement_classification_id), N'','')
                       WITHIN GROUP (ORDER BY m.statement_classification_id)
            FROM   grac_new.framework_statement_classification_map m
            WHERE  m.framework_statement_id = @framework_statement_id
              AND  m.status = N''Active'');
END;';
EXEC sp_executesql @sql;

SET @sql = N'
CREATE OR ALTER FUNCTION grac_practice.fn_repo_statement_classification_names (@framework_statement_id BIGINT)
RETURNS NVARCHAR(MAX)
' + @inline + N'
AS
BEGIN
    -- 478: the statement''s active classification names (Control Management 079).
    RETURN (SELECT STRING_AGG(CAST(c.classification_name AS NVARCHAR(MAX)), N'', '')
                       WITHIN GROUP (ORDER BY c.display_order, c.classification_name)
            FROM   grac_new.framework_statement_classification_map m
            JOIN   grac_new.statement_classification c
                   ON c.statement_classification_id = m.statement_classification_id
            WHERE  m.framework_statement_id = @framework_statement_id
              AND  m.status = N''Active'');
END;';
EXEC sp_executesql @sql;
PRINT '478: fn_repo_statement_classification_ids / _names created' + CASE WHEN @inline <> N'' THEN N' (not inlined).' ELSE N'.' END;
GO

-- =====================================================================
-- 3 + 5. Rebuild the statement view and re-baseline the copies
--   Four batches. SQL Server compiles a whole batch before it runs it, so
--   a statement that names the view is compiled against the view as it is
--   when the batch STARTS. On development the first 478 run had left a
--   view that cannot be compiled into a query (Msg 8711), and every later
--   run failed while compiling this section -- before anything in it ran,
--   so that view was never replaced. Each batch below therefore names the
--   view only after the batch before it has rebuilt it, or through
--   dynamic SQL. The temp tables belong to the session, so they carry
--   from batch to batch.
-- =====================================================================
IF OBJECT_ID('tempdb..#pm478_ok') IS NOT NULL DROP TABLE #pm478_ok;
IF OBJECT_ID('tempdb..#pm478_in_step') IS NOT NULL DROP TABLE #pm478_in_step;
CREATE TABLE #pm478_in_step (org_statement_id BIGINT NOT NULL PRIMARY KEY);

-- Copies that match Control Management, before the view learns about the
-- classifications. Same filter as 395's detection. Read twice so a re-run
-- is safe whatever state the view is in:
--   (a) the view as it is now -- on a re-run that is the 478 shape, and
--       copies kept in step by the first run match it (dynamic + TRY: a
--       view that cannot be read is skipped, not fatal);
--   (b) the view rebuilt the 391 way (every column, no classifications)
--       -- the hash every copy was stamped with before 478.
BEGIN TRY
    EXEC sp_executesql N'
    SELECT v.framework_statement_id, v.content_hash
    INTO   #pm478_cur
    FROM   grac_practice.vw_repo_src_framework_statement v;
    INSERT #pm478_in_step (org_statement_id)
    SELECT ofs.org_statement_id
    FROM   grac_practice.organization_framework_statements ofs
    JOIN   #pm478_cur src
           ON src.framework_statement_id = ofs.framework_statement_id
    WHERE  ofs.source_type = N''Repository''
      AND  ofs.copied_dt IS NOT NULL
      AND  ofs.source_version_hash = src.content_hash;';
END TRY
BEGIN CATCH
    PRINT '478: the current statement view could not be read (' + ERROR_MESSAGE() + ') -- using the 391 shape only.';
END CATCH

EXEC grac_practice.sp_repo_build_source_view
     @source_table = N'grac_new.framework_statement', @view_name = N'vw_repo_src_framework_statement';
PRINT '478: statement view rebuilt the 391 way (baseline).';
GO

-- 3b. (b) -- compiled now, against the 391-shaped view.
INSERT #pm478_in_step (org_statement_id)
SELECT ofs.org_statement_id
FROM   grac_practice.organization_framework_statements ofs
JOIN   grac_practice.vw_repo_src_framework_statement src
       ON src.framework_statement_id = ofs.framework_statement_id
WHERE  ofs.source_type = N'Repository'
  AND  ofs.copied_dt IS NOT NULL
  AND  ofs.source_version_hash = src.content_hash
  AND  NOT EXISTS (SELECT 1 FROM #pm478_in_step i WHERE i.org_statement_id = ofs.org_statement_id);
DECLARE @in_step INT = (SELECT COUNT(*) FROM #pm478_in_step);
PRINT '478: statement copies in step before the rebuild = ' + CAST(@in_step AS NVARCHAR(20));
GO

-- 3c. The view with classifications.

-- The two lists come from scalar functions (below), not from an APPLY.
-- Any ordered concatenation written into the view -- STRING_AGG ...
-- WITHIN GROUP, or FOR XML PATH with ORDER BY, which the optimizer also
-- treats as an ordered aggregate -- is merged into the query that reads
-- the view, and next to the view's own FOR JSON hash, a FOR JSON over the
-- view or a GROUP BY, SQL Server refuses the plan with Msg 8711 ("multiple
-- ordered aggregate functions ... incompatible orderings"). Seen on the
-- development database, not on UAT: it depends on the plan. A scalar
-- function that is not inlined keeps its ordering in its own scope.
EXEC grac_practice.sp_repo_build_source_view
     @source_table    = N'grac_new.framework_statement',
     @view_name       = N'vw_repo_src_framework_statement',
     @extra_select    = N'grac_practice.fn_repo_statement_classification_ids(src.framework_statement_id) AS classification_ids,
           grac_practice.fn_repo_statement_classification_names(src.framework_statement_id) AS classification_names',
     @exclude_columns = N'classification_id';
-- The view must be readable before anything relies on it. If it is not,
-- put the 391 shape back (copies keep working) and stop.
BEGIN TRY
    -- Every row and every column, so a failure the optimizer only meets on
    -- a full read is met here too.
    EXEC sp_executesql N'DECLARE @c INT;
        SELECT @c = CHECKSUM_AGG(CHECKSUM(v.content_hash, v.classification_ids, v.classification_names))
        FROM grac_practice.vw_repo_src_framework_statement v;
        -- and the shape that failed on development: a join + GROUP BY over it
        SELECT @c = COUNT(*) FROM (
            SELECT ofs.organization_id, COUNT(*) AS n,
                   SUM(CASE WHEN ofs.source_version_hash <> v.content_hash THEN 1 ELSE 0 END) AS behind
            FROM   grac_practice.organization_framework_statements ofs
            JOIN   grac_practice.vw_repo_src_framework_statement v
                   ON v.framework_statement_id = ofs.framework_statement_id
            GROUP  BY ofs.organization_id) x;
        -- and a FOR JSON over it (the pending-change refresh)
        DECLARE @j NVARCHAR(MAX) = (SELECT TOP (50) v.* FROM grac_practice.vw_repo_src_framework_statement v
                                    FOR JSON PATH);';
END TRY
BEGIN CATCH
    DECLARE @why NVARCHAR(2048) = ERROR_MESSAGE();
    EXEC grac_practice.sp_repo_build_source_view
         @source_table = N'grac_new.framework_statement', @view_name = N'vw_repo_src_framework_statement';
    PRINT '478: the rebuilt statement view could not be read; the 391 shape was put back. ' + @why;
    THROW 53990, 'ABORT (478): the statement view with classifications could not be read -- nothing was re-baselined. See the message above.', 1;
END CATCH
PRINT '478: vw_repo_src_framework_statement rebuilt (classification_id out, classification_ids / classification_names in).';
CREATE TABLE #pm478_ok (ok BIT NOT NULL);
GO

-- 3d. Re-baseline -- only when 3c succeeded.
IF OBJECT_ID('tempdb..#pm478_ok') IS NULL
BEGIN
    PRINT '478: re-baseline skipped -- the statement view was not rebuilt (see 53990 above).';
    IF OBJECT_ID('tempdb..#pm478_in_step') IS NOT NULL DROP TABLE #pm478_in_step;
    RETURN;
END

-- Read the rebuilt view once, into a temp table, and re-baseline from that
-- copy. The updates below then never put the view inside a bigger plan
-- (UPDATE ... FROM, FOR JSON), which is where Msg 8711 was raised on the
-- development database. Same columns, same order, same values.
IF OBJECT_ID('tempdb..#pm478_src') IS NOT NULL DROP TABLE #pm478_src;
SELECT v.* INTO #pm478_src FROM grac_practice.vw_repo_src_framework_statement v;
CREATE UNIQUE CLUSTERED INDEX ix_pm478_src ON #pm478_src(framework_statement_id);

DECLARE @n INT;
UPDATE ofs
   SET classification_ids   = src.classification_ids,
       classification_names = src.classification_names,
       source_version_hash  = src.content_hash
FROM   grac_practice.organization_framework_statements ofs
JOIN   #pm478_in_step i ON i.org_statement_id = ofs.org_statement_id
JOIN   #pm478_src src
       ON src.framework_statement_id = ofs.framework_statement_id;
SET @n = @@ROWCOUNT;
PRINT '478: statement copies given their classifications (kept in step) = ' + CAST(@n AS NVARCHAR(20));

-- Pending Statement changes: the rebuilt snapshot and hash, so 395 does
-- not raise a second change for the same statement (its "already raised"
-- test compares the hash).
UPDATE c
   SET new_snapshot_json = (SELECT s2.* FROM #pm478_src s2
                             WHERE s2.framework_statement_id = c.source_key
                             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       new_version_hash  = src.content_hash
FROM   grac_practice.organization_repository_change c
JOIN   #pm478_src src
       ON src.framework_statement_id = c.source_key
WHERE  c.copy_code = N'Statement'
  AND  c.status = N'Pending'
  AND  c.change_action IN (N'Added', N'Changed');
PRINT '478: pending statement changes refreshed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

DROP TABLE #pm478_in_step;
DROP TABLE #pm478_src;
DROP TABLE #pm478_ok;
GO

-- =====================================================================
-- 4. sp_repository_copy_statements (395 body + the two columns)
-- =====================================================================
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
        -- 478: the statement's classifications (Control Management 079,
        -- many per statement), ids and names as the source view carries them.
        classification_ids    = src.classification_ids,
        classification_names  = src.classification_names,
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

-- =====================================================================
-- 6. Refresh modules that read organization_framework_statements, so a
--    SELECT * / t.* among them knows the new columns (the 473 way, for
--    every dependent view and function rather than one by name).
-- =====================================================================
DECLARE @m NVARCHAR(600), @refreshed INT = 0;
DECLARE pm478_mod CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT QUOTENAME(OBJECT_SCHEMA_NAME(d.referencing_id)) + N'.' + QUOTENAME(OBJECT_NAME(d.referencing_id))
    FROM   sys.sql_expression_dependencies d
    JOIN   sys.objects o ON o.object_id = d.referencing_id
    JOIN   sys.sql_modules sm ON sm.object_id = d.referencing_id
    WHERE  d.referenced_id = OBJECT_ID('grac_practice.organization_framework_statements')
      AND  o.type IN ('V', 'IF', 'TF', 'FN')
      AND  sm.is_schema_bound = 0;
OPEN pm478_mod;
FETCH NEXT FROM pm478_mod INTO @m;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC sys.sp_refreshsqlmodule @m;
        SET @refreshed = @refreshed + 1;
    END TRY
    BEGIN CATCH
        PRINT '478: could not refresh ' + @m + ' -- ' + ERROR_MESSAGE();
    END CATCH
    FETCH NEXT FROM pm478_mod INTO @m;
END
CLOSE pm478_mod;
DEALLOCATE pm478_mod;
PRINT '478: dependent views / functions refreshed = ' + CAST(@refreshed AS NVARCHAR(20));
GO

-- =====================================================================
-- 7. Verification
-- =====================================================================
SELECT '478 statement view: classification_id out, classifications in' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.vw_repo_src_framework_statement','classification_id')    IS NULL
             AND COL_LENGTH('grac_practice.vw_repo_src_framework_statement','classification_ids')   IS NOT NULL
             AND COL_LENGTH('grac_practice.vw_repo_src_framework_statement','classification_names') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '478 organisation copy carries the classifications',
       CASE WHEN COL_LENGTH('grac_practice.organization_framework_statements','classification_ids')   IS NOT NULL
             AND COL_LENGTH('grac_practice.organization_framework_statements','classification_names') IS NOT NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_repository_copy_statements')) LIKE '%classification_ids%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '478 sp_repo_build_source_view takes @exclude_columns',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_repo_build_source_view')
                            AND name = '@exclude_columns')
            THEN 'PASS' ELSE 'FAIL' END;
GO

-- Per organisation: repository statement copies, how many carry a
-- classification, and how many are behind Control Management (they will
-- appear in Repository Updates at the next detection run).
-- (from a temp copy of the view, for the reason given in section 3 + 5)
IF OBJECT_ID('tempdb..#pm478_v') IS NOT NULL DROP TABLE #pm478_v;
SELECT v.framework_statement_id, v.content_hash
INTO   #pm478_v
FROM   grac_practice.vw_repo_src_framework_statement v;

SELECT ofs.organization_id,
       Copies             = COUNT(*),
       WithClassification = SUM(CASE WHEN ofs.classification_ids IS NOT NULL THEN 1 ELSE 0 END),
       BehindRepository   = SUM(CASE WHEN ofs.source_version_hash <> src.content_hash THEN 1 ELSE 0 END)
FROM   grac_practice.organization_framework_statements ofs
JOIN   #pm478_v src
       ON src.framework_statement_id = ofs.framework_statement_id
WHERE  ofs.source_type = N'Repository' AND ofs.copied_dt IS NOT NULL
GROUP  BY ofs.organization_id
ORDER  BY ofs.organization_id;

DROP TABLE #pm478_v;
GO

PRINT '478 complete.';
GO
