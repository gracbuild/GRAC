-- =====================================================================
-- 392 Repository subscription copy model -- PHASE 2a (foundation)
--
-- Phase 2 repoints every reader of grac_new catalogue content to the
-- organization's own copy. Tracing the readers (2026-09-28) found three
-- more catalogues that reach organizations live, beyond 391's scope:
--
--   * Statement -> practice links: grac_new.framework_statement_requirement_map
--     + grac_new.requirement. Read at page load by the Practices fallback
--     (read-time import) and on every "Applicable" save.
--   * Controls: grac_new.control + source_control_map + control_requirement_map.
--     pm_get_practice_repository's organization-controls / control-applicability
--     branch re-INSERTs and re-UPDATEs organization_control from them on
--     every load, and sp_apply_practices_for_control imports practices from
--     them. Sir, 2026-09-28: controls join the copy + approval model in
--     this phase.
--
-- WHAT THIS FILE DOES (still no screen change)
-- --------------------------------------------
--   1. fn_repo_source_key -- a grac_new table's single-column key, from the
--      catalogue (391 did this inline for the obligation map only).
--   2. repository_copy_config gains handler_proc, and five new copy steps:
--        12 SourceControlMap        -> organization_source_control_map
--        14 Control                 -> organization_repository_control
--        16 ControlRequirementMap   -> organization_control_requirement_map
--        22 StatementRequirementMap -> organization_statement_requirement_map
--        24 Requirement             -> organization_repository_requirement
--      plus one handler step:
--        26 PracticeImport          -> sp_repository_practice_import
--      (organization_control itself stays the organization's working table;
--      organization_repository_control is the approved repository content
--      it is filled from.)
--   3. The organization reader layer: one inline function per copied
--      catalogue, fn_org_<grac_new table>(@organization_id), returning the
--      grac_new table's columns from the organization's copy. Phase 2b/2c
--      repoint a reader by replacing  grac_new.<t> x  with
--      grac_practice.fn_org_<t>(<organization id>) x  -- column names do
--      not change, so each repoint is a one-line diff per join.
--   4. sp_repository_copy_statements -- 391's inline statement block, moved
--      into its own handler (logic unchanged).
--   5. sp_repository_practice_import -- the ONE statement -> practice
--      import, reading only the organization's copies. Replaces the two
--      C# copies (read-time fallback and SaveStatementApplicabilityAsync),
--      which phase 2b deletes.
--   6. sp_repository_subscription_copy re-issued: non-generic steps now
--      dispatch through repository_copy_config.handler_proc, so a new
--      handler never needs this procedure changed again.
--   7. Backfill: every active subscription runs the new steps (@refresh=0).
--      The practice import creates, for every subscribed release, the
--      practices the Practices page would have created the first time it
--      was opened for that release. Existing practices are reused, never
--      duplicated (same organization-level dedup as today).
--
-- AFTER A CONTROL MANAGEMENT SCHEMA CHANGE: re-run 391 then 392 (392
-- re-creates the fn_org_* functions, which select t.* and must be rebound).
--
-- SAFE TO RE-RUN. Requires 391.
-- Rollback: 392_repository_copy_phase2_foundation_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- =====================================================================
-- 0. Prerequisites
-- =====================================================================
IF OBJECT_ID('grac_practice.repository_copy_config','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_repo_clone_sync','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_repo_clone_ensure_table','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_repo_build_source_view','P') IS NULL
   OR OBJECT_ID('grac_practice.organization_statement_structure_node','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_framework_statements','copied_dt') IS NULL
   OR OBJECT_ID('grac_practice.organization_requirement','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_statement_practice_mapping','U') IS NULL
   OR OBJECT_ID('grac_practice.implementation_status_master','U') IS NULL
BEGIN
    PRINT 'ABORT (392): run 391 first.';
    SET NOEXEC ON;
END
GO
IF OBJECT_ID('grac_new.control','U') IS NULL
   OR OBJECT_ID('grac_new.source_control_map','U') IS NULL
   OR OBJECT_ID('grac_new.control_requirement_map','U') IS NULL
   OR OBJECT_ID('grac_new.framework_statement_requirement_map','U') IS NULL
   OR OBJECT_ID('grac_new.requirement','U') IS NULL
   OR COL_LENGTH('grac_new.control','control_id') IS NULL
   OR COL_LENGTH('grac_new.control','status') IS NULL
   OR COL_LENGTH('grac_new.source_control_map','control_id') IS NULL
   OR COL_LENGTH('grac_new.source_control_map','structure_node_id') IS NULL
   OR COL_LENGTH('grac_new.source_control_map','release_id') IS NULL
   OR COL_LENGTH('grac_new.source_control_map','status') IS NULL
   OR COL_LENGTH('grac_new.control_requirement_map','control_id') IS NULL
   OR COL_LENGTH('grac_new.control_requirement_map','requirement_id') IS NULL
   OR COL_LENGTH('grac_new.control_requirement_map','status') IS NULL
   OR COL_LENGTH('grac_new.framework_statement_requirement_map','framework_statement_id') IS NULL
   OR COL_LENGTH('grac_new.framework_statement_requirement_map','requirement_id') IS NULL
   OR COL_LENGTH('grac_new.framework_statement_requirement_map','status') IS NULL
   OR COL_LENGTH('grac_new.requirement','requirement_id') IS NULL
   OR COL_LENGTH('grac_new.requirement','requirement_code') IS NULL
   OR COL_LENGTH('grac_new.requirement','requirement_name') IS NULL
   OR COL_LENGTH('grac_new.requirement','requirement_statement') IS NULL
   OR COL_LENGTH('grac_new.requirement','objective') IS NULL
   OR COL_LENGTH('grac_new.requirement','status') IS NULL
BEGIN
    PRINT 'ABORT (392): a grac_new table or column this migration reads is missing.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. fn_repo_source_key
-- =====================================================================
-- Single-column primary key of a table, else its identity column, else
-- NULL. Used for grac_new tables whose key name this repository never
-- references.
CREATE OR ALTER FUNCTION grac_practice.fn_repo_source_key(@object_id INT)
RETURNS SYSNAME
AS
BEGIN
    DECLARE @key SYSNAME, @pk_cols INT;
    SELECT @pk_cols = COUNT(*), @key = MAX(c.name)
    FROM sys.indexes i
    JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
    JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE i.object_id = @object_id
      AND i.is_primary_key = 1;
    IF ISNULL(@pk_cols, 0) <> 1
    BEGIN
        SET @key = NULL;
        SELECT @key = idc.name FROM sys.identity_columns idc WHERE idc.object_id = @object_id;
    END
    RETURN @key;
END
GO

-- =====================================================================
-- 2. repository_copy_config: handler_proc + new steps
-- =====================================================================
IF COL_LENGTH('grac_practice.repository_copy_config','handler_proc') IS NULL
BEGIN
    -- Non-generic steps: a grac_practice procedure with the signature
    --   (@organization_id BIGINT, @release_id BIGINT, @refresh BIT,
    --    @actor NVARCHAR(100), @inserted INT OUTPUT, @updated INT OUTPUT)
    ALTER TABLE grac_practice.repository_copy_config ADD handler_proc SYSNAME NULL;
    PRINT '392: repository_copy_config.handler_proc added.';
END
GO

DECLARE @scm_key  SYSNAME = grac_practice.fn_repo_source_key(OBJECT_ID('grac_new.source_control_map'));
DECLARE @crm_key  SYSNAME = grac_practice.fn_repo_source_key(OBJECT_ID('grac_new.control_requirement_map'));
DECLARE @fsrm_key SYSNAME = grac_practice.fn_repo_source_key(OBJECT_ID('grac_new.framework_statement_requirement_map'));
IF @scm_key IS NULL OR @crm_key IS NULL OR @fsrm_key IS NULL
BEGIN
    PRINT 'ABORT (392): a grac_new map table has no single-column key (source_control_map / control_requirement_map / framework_statement_requirement_map).';
    SET NOEXEC ON;
END
ELSE
BEGIN
    -- Scope fragments, reused below. "Structure node of this release" is
    -- how source_control_map rows belong to a release (same rule as
    -- pm_get_practice_repository's repository_controls CTE: the map's own
    -- release_id, or NULL, and a node of the release).
    DECLARE @scm_in_release NVARCHAR(MAX) = N'(scm.release_id = @release_id OR scm.release_id IS NULL)
                     AND scm.status = N''Active''
                     AND EXISTS (SELECT 1 FROM grac_new.source_structure_node n
                                 WHERE n.structure_node_id = scm.structure_node_id
                                   AND n.release_id = @release_id)';

    MERGE grac_practice.repository_copy_config AS t
    USING (VALUES
        (N'SourceControlMap', 12, N'grac_new.source_control_map', N'vw_repo_src_source_control_map',
         N'organization_source_control_map', N'org_source_control_map_id', @scm_key,
         N'(src.release_id = @release_id OR src.release_id IS NULL)
           AND EXISTS (SELECT 1 FROM grac_new.source_structure_node n
                       WHERE n.structure_node_id = src.structure_node_id
                         AND n.release_id = @release_id)',
         CAST(1 AS BIT), CAST(NULL AS SYSNAME)),
        (N'Control', 14, N'grac_new.control', N'vw_repo_src_control',
         N'organization_repository_control', N'org_repository_control_id', N'control_id',
         N'EXISTS (SELECT 1 FROM grac_new.source_control_map scm
                   WHERE scm.control_id = src.control_id
                     AND ' + @scm_in_release + N')',
         CAST(1 AS BIT), CAST(NULL AS SYSNAME)),
        (N'ControlRequirementMap', 16, N'grac_new.control_requirement_map', N'vw_repo_src_control_requirement_map',
         N'organization_control_requirement_map', N'org_control_requirement_map_id', @crm_key,
         N'EXISTS (SELECT 1 FROM grac_new.source_control_map scm
                   WHERE scm.control_id = src.control_id
                     AND ' + @scm_in_release + N')',
         CAST(1 AS BIT), CAST(NULL AS SYSNAME)),
        (N'StatementRequirementMap', 22, N'grac_new.framework_statement_requirement_map', N'vw_repo_src_statement_requirement_map',
         N'organization_statement_requirement_map', N'org_statement_requirement_map_id', @fsrm_key,
         N'EXISTS (SELECT 1 FROM grac_new.framework_statement fs
                   WHERE fs.framework_statement_id = src.framework_statement_id
                     AND fs.release_id = @release_id)',
         CAST(1 AS BIT), CAST(NULL AS SYSNAME)),
        (N'Requirement', 24, N'grac_new.requirement', N'vw_repo_src_requirement',
         N'organization_repository_requirement', N'org_repository_requirement_id', N'requirement_id',
         N'EXISTS (SELECT 1 FROM grac_new.framework_statement_requirement_map m
                   JOIN grac_new.framework_statement fs
                     ON fs.framework_statement_id = m.framework_statement_id
                    AND fs.release_id = @release_id
                   WHERE m.requirement_id = src.requirement_id
                     AND m.status = N''Active'')
           OR EXISTS (SELECT 1 FROM grac_new.control_requirement_map crm
                      JOIN grac_new.source_control_map scm ON scm.control_id = crm.control_id
                      WHERE crm.requirement_id = src.requirement_id
                        AND crm.status = N''Active''
                        AND ' + @scm_in_release + N')',
         CAST(1 AS BIT), CAST(NULL AS SYSNAME)),
        (N'PracticeImport', 26, N'(organization copies)', N'(none)',
         N'organization_requirement', N'organization_requirement_id', N'repository_requirement_id',
         N'(handler)', CAST(0 AS BIT), N'sp_repository_practice_import')
    ) AS s(copy_code, copy_order, source_table, source_view, target_table, org_pk_column, key_column,
           scope_sql, is_generic_clone, handler_proc)
    ON t.copy_code = s.copy_code
    WHEN MATCHED THEN UPDATE SET
        copy_order = s.copy_order, source_table = s.source_table, source_view = s.source_view,
        target_table = s.target_table, org_pk_column = s.org_pk_column, key_column = s.key_column,
        scope_sql = s.scope_sql, is_generic_clone = s.is_generic_clone, handler_proc = s.handler_proc,
        status = N'Active', updated_by = N'migration-392', updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (copy_code, copy_order, source_table, source_view, target_table, org_pk_column, key_column,
         scope_sql, is_generic_clone, handler_proc, status, entered_by)
        VALUES (s.copy_code, s.copy_order, s.source_table, s.source_view, s.target_table, s.org_pk_column,
                s.key_column, s.scope_sql, s.is_generic_clone, s.handler_proc, N'Active', N'migration-392');

    UPDATE grac_practice.repository_copy_config
       SET handler_proc = N'sp_repository_copy_statements',
           updated_by = N'migration-392', updated_dt = SYSUTCDATETIME()
     WHERE copy_code = N'Statement'
       AND ISNULL(handler_proc, N'') <> N'sp_repository_copy_statements';

    PRINT '392: repository_copy_config: 5 copy steps + PracticeImport handler seeded.';
END
GO

-- =====================================================================
-- 3. Source views and copy tables for the new steps
-- =====================================================================
EXEC grac_practice.sp_repo_build_source_view
     @source_table = N'grac_new.source_control_map', @view_name = N'vw_repo_src_source_control_map';
EXEC grac_practice.sp_repo_build_source_view
     @source_table = N'grac_new.control', @view_name = N'vw_repo_src_control';
EXEC grac_practice.sp_repo_build_source_view
     @source_table = N'grac_new.control_requirement_map', @view_name = N'vw_repo_src_control_requirement_map';
EXEC grac_practice.sp_repo_build_source_view
     @source_table = N'grac_new.framework_statement_requirement_map', @view_name = N'vw_repo_src_statement_requirement_map';
EXEC grac_practice.sp_repo_build_source_view
     @source_table = N'grac_new.requirement', @view_name = N'vw_repo_src_requirement';
PRINT '392: source views built.';
GO

DECLARE @view SYSNAME, @target SYSNAME, @pk SYSNAME, @key SYSNAME;
DECLARE copy_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT source_view, target_table, org_pk_column, key_column
    FROM grac_practice.repository_copy_config
    WHERE is_generic_clone = 1 AND status = N'Active'
    ORDER BY copy_order;
OPEN copy_cursor;
FETCH NEXT FROM copy_cursor INTO @view, @target, @pk, @key;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC grac_practice.sp_repo_clone_ensure_table
         @source_view = @view, @target_table = @target, @org_pk_column = @pk, @key_column = @key;
    FETCH NEXT FROM copy_cursor INTO @view, @target, @pk, @key;
END
CLOSE copy_cursor;
DEALLOCATE copy_cursor;
GO

-- =====================================================================
-- 4. Organization reader layer: fn_org_<grac_new table>(@organization_id)
-- =====================================================================
-- 4a. Generic copies: one function per copy table, named after the
-- grac_new table it stands in for. Built from repository_copy_config so
-- a future copy step gets its function by re-running this file.
DECLARE @source NVARCHAR(256), @target SYSNAME, @fn SYSNAME, @sql NVARCHAR(MAX);
DECLARE fn_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT source_table, target_table
    FROM grac_practice.repository_copy_config
    WHERE is_generic_clone = 1 AND status = N'Active'
    ORDER BY copy_order;
OPEN fn_cursor;
FETCH NEXT FROM fn_cursor INTO @source, @target;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @fn = N'fn_org_' + PARSENAME(@source, 1);
    SET @sql = N'CREATE OR ALTER FUNCTION grac_practice.' + QUOTENAME(@fn) + N'(@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    -- Migration 392: the organization''s copy of ' + @source + N',
    -- same column names. Re-created by re-running 392.
    SELECT t.*
    FROM grac_practice.' + QUOTENAME(@target) + N' t
    WHERE t.organization_id = @organization_id;';
    EXEC sp_executesql @sql;
    FETCH NEXT FROM fn_cursor INTO @source, @target;
END
CLOSE fn_cursor;
DEALLOCATE fn_cursor;
PRINT '392: fn_org_* reader functions created.';
GO

-- 4b. Statements are not a generic copy (organization_framework_statements
-- predates the copy model), so its function is written out: the
-- grac_new.framework_statement columns readers use, from the copy.
-- status is the organization row's status (Active unless the organization
-- retired the row); lifecycle_status carries an approved repository
-- retirement (phase 3).
CREATE OR ALTER FUNCTION grac_practice.fn_org_framework_statement(@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT ofs.framework_statement_id,
           ofs.release_id,
           ofs.structure_node_id,
           ofs.statement_reference,
           ofs.statement_title,
           ofs.statement_text,
           ofs.display_order,
           ofs.status,
           ofs.lifecycle_status,
           ofs.org_statement_id,
           ofs.organization_id
    FROM grac_practice.organization_framework_statements ofs
    WHERE ofs.organization_id = @organization_id
      AND ofs.source_type = N'Repository'
      AND ofs.copied_dt IS NOT NULL;
GO

-- =====================================================================
-- 5. sp_repository_copy_statements -- 391's statement block as a handler
-- =====================================================================
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

-- =====================================================================
-- 6. sp_repository_practice_import -- the one statement -> practice import
-- =====================================================================
-- Same two steps the read-time Practices fallback and the Applicable save
-- run today (organization-level dedup by repository_requirement_id /
-- requirement_code; one mapping row per statement and practice), but
-- reading the organization's copies only.
--   @framework_statement_id NULL = every statement of the release (copy).
--   @framework_statement_id set  = that statement only (Applicable save).
--   @refresh has no effect: a practice is the organization's own record
--   once created; content changes arrive through phase 3 approval.
--   @inserted = practices created, @updated = statement mappings added.
CREATE OR ALTER PROCEDURE grac_practice.sp_repository_practice_import
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
    SET @actor = ISNULL(NULLIF(LTRIM(RTRIM(@actor)), N''), N'system');

    DECLARE @active_record_status_id INT = (
        SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = 'Active');
    DECLARE @not_updated_status_id INT = (
        SELECT TOP (1) applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code = 'Not Updated');
    DECLARE @not_started_status_id INT = (
        SELECT TOP (1) implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = 'Not Started');

    -- Step 1: one organization practice per repository practice.
    ;WITH statement_practices AS (
        SELECT ofs.org_statement_id,
               q.requirement_id repository_requirement_id,
               q.requirement_code,
               q.requirement_name,
               q.requirement_statement,
               q.objective
        FROM grac_practice.organization_framework_statements ofs
        JOIN grac_practice.fn_org_framework_statement_requirement_map(@organization_id) fsrm
          ON fsrm.framework_statement_id = ofs.framework_statement_id
         AND fsrm.status = N'Active'
        JOIN grac_practice.fn_org_requirement(@organization_id) q
          ON q.requirement_id = fsrm.requirement_id
         AND q.status = N'Active'
        WHERE ofs.organization_id = @organization_id
          AND ofs.release_id = @release_id
          AND ofs.status = N'Active'
          AND ofs.source_type = N'Repository'
          AND (@framework_statement_id IS NULL OR ofs.framework_statement_id = @framework_statement_id)
    ),
    distinct_practices AS (
        SELECT repository_requirement_id, requirement_code, requirement_name, requirement_statement, objective,
               org_statement_id first_org_statement_id,
               ROW_NUMBER() OVER (PARTITION BY repository_requirement_id ORDER BY org_statement_id) row_no
        FROM statement_practices
    )
    INSERT grac_practice.organization_requirement(
        organization_id, org_statement_id, origin_type, repository_requirement_id, organization_control_id,
        requirement_code, requirement_name, requirement_statement, objective,
        applicability_status, applicability_status_id, implementation_status, implementation_status_id,
        status, record_status_id, entered_by)
    SELECT @organization_id, c.first_org_statement_id, 'Repository', c.repository_requirement_id, NULL,
           c.requirement_code, c.requirement_name, c.requirement_statement, c.objective,
           'Not Updated', @not_updated_status_id, 'Not Started', @not_started_status_id,
           'Active', @active_record_status_id, @actor
    FROM distinct_practices c
    WHERE c.row_no = 1
      AND NOT EXISTS (
          SELECT 1 FROM grac_practice.organization_requirement existing
          WHERE existing.organization_id = @organization_id
            AND existing.status = 'Active'
            AND (existing.requirement_code = c.requirement_code
                 OR existing.repository_requirement_id = c.repository_requirement_id));
    SET @inserted = @@ROWCOUNT;

    -- Step 2: link every statement to its (new or reused) practice.
    ;WITH statement_practices AS (
        SELECT ofs.org_statement_id,
               ofs.framework_statement_id,
               ofs.release_id,
               q.requirement_id repository_requirement_id,
               q.requirement_code
        FROM grac_practice.organization_framework_statements ofs
        JOIN grac_practice.fn_org_framework_statement_requirement_map(@organization_id) fsrm
          ON fsrm.framework_statement_id = ofs.framework_statement_id
         AND fsrm.status = N'Active'
        JOIN grac_practice.fn_org_requirement(@organization_id) q
          ON q.requirement_id = fsrm.requirement_id
         AND q.status = N'Active'
        WHERE ofs.organization_id = @organization_id
          AND ofs.release_id = @release_id
          AND ofs.status = N'Active'
          AND ofs.source_type = N'Repository'
          AND (@framework_statement_id IS NULL OR ofs.framework_statement_id = @framework_statement_id)
    )
    INSERT grac_practice.organization_statement_practice_mapping(
        organization_id, org_statement_id, framework_statement_id, repository_requirement_id,
        org_practice_id, release_id, status, record_status_id, entered_by)
    SELECT DISTINCT @organization_id, sp.org_statement_id, sp.framework_statement_id, sp.repository_requirement_id,
           op.organization_requirement_id, sp.release_id, 'Active', @active_record_status_id, @actor
    FROM statement_practices sp
    JOIN grac_practice.organization_requirement op
      ON op.organization_id = @organization_id
     AND op.status = 'Active'
     AND (op.repository_requirement_id = sp.repository_requirement_id
          OR (op.repository_requirement_id IS NULL AND op.requirement_code = sp.requirement_code))
    WHERE NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_statement_practice_mapping m
        WHERE m.organization_id = @organization_id
          AND m.org_statement_id = sp.org_statement_id
          AND m.org_practice_id = op.organization_requirement_id);
    SET @updated = @@ROWCOUNT;
END
GO

-- =====================================================================
-- 7. sp_repository_subscription_copy -- re-issued with handler dispatch
-- =====================================================================
-- Unchanged from 391 except: a non-generic step runs its handler_proc
-- (dynamic EXEC, fixed signature) instead of an inline block.
CREATE OR ALTER PROCEDURE grac_practice.sp_repository_subscription_copy
    @organization_id BIGINT,
    @release_id      BIGINT        = NULL,
    @refresh         BIT           = 0,
    @actor           NVARCHAR(100) = N'system',
    @suppress_result BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53914, 'sp_repository_subscription_copy: organization not found.', 1;

    SET @actor = ISNULL(NULLIF(LTRIM(RTRIM(@actor)), N''), N'system');
    SET @refresh = ISNULL(@refresh, 0);

    DECLARE @result TABLE(release_id BIGINT, copy_code NVARCHAR(40), inserted INT, updated INT);
    DECLARE @releases TABLE(release_id BIGINT PRIMARY KEY);
    INSERT @releases(release_id)
    SELECT DISTINCT s.release_id
    FROM grac_practice.repository_subscription s
    JOIN grac_new.release r ON r.release_id = s.release_id
    WHERE s.organization_id = @organization_id
      AND s.status = 'Active'
      AND ISNULL(s.subscription_status, 'Active') = 'Active'
      AND (@release_id IS NULL OR s.release_id = @release_id);

    DECLARE @own_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    DECLARE @rid BIGINT, @code NVARCHAR(40), @generic BIT, @handler SYSNAME, @ins INT, @upd INT;
    DECLARE @handler_sql NVARCHAR(MAX), @msg NVARCHAR(400);
    DECLARE @handler_params NVARCHAR(300) =
        N'@o BIGINT, @r BIGINT, @f BIT, @a NVARCHAR(100), @i INT OUTPUT, @u INT OUTPUT';

    BEGIN TRY
        DECLARE release_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT release_id FROM @releases ORDER BY release_id;
        OPEN release_cursor;
        FETCH NEXT FROM release_cursor INTO @rid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @own_tran = 1 BEGIN TRANSACTION;

            DECLARE step_cursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT copy_code, is_generic_clone, handler_proc
                FROM grac_practice.repository_copy_config
                WHERE status = N'Active'
                ORDER BY copy_order;
            OPEN step_cursor;
            FETCH NEXT FROM step_cursor INTO @code, @generic, @handler;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @ins = 0, @upd = 0;
                IF @generic = 1
                BEGIN
                    EXEC grac_practice.sp_repo_clone_sync
                         @copy_code = @code, @organization_id = @organization_id, @release_id = @rid,
                         @refresh = @refresh, @actor = @actor,
                         @inserted = @ins OUTPUT, @updated = @upd OUTPUT;
                END
                ELSE
                BEGIN
                    IF @handler IS NULL
                       OR OBJECT_ID(N'grac_practice.' + QUOTENAME(@handler), 'P') IS NULL
                    BEGIN
                        SET @msg = N'sp_repository_subscription_copy: copy step ' + @code
                                 + N' has no handler procedure.';
                        THROW 53916, @msg, 1;
                    END
                    SET @handler_sql = N'EXEC grac_practice.' + QUOTENAME(@handler)
                        + N' @organization_id = @o, @release_id = @r, @refresh = @f, @actor = @a,'
                        + N' @inserted = @i OUTPUT, @updated = @u OUTPUT;';
                    EXEC sp_executesql @handler_sql, @handler_params,
                         @o = @organization_id, @r = @rid, @f = @refresh, @a = @actor,
                         @i = @ins OUTPUT, @u = @upd OUTPUT;
                END

                INSERT @result(release_id, copy_code, inserted, updated) VALUES (@rid, @code, @ins, @upd);
                FETCH NEXT FROM step_cursor INTO @code, @generic, @handler;
            END
            CLOSE step_cursor;
            DEALLOCATE step_cursor;

            IF @own_tran = 1 COMMIT TRANSACTION;
            FETCH NEXT FROM release_cursor INTO @rid;
        END
        CLOSE release_cursor;
        DEALLOCATE release_cursor;
    END TRY
    BEGIN CATCH
        IF @own_tran = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    IF ISNULL(@suppress_result, 0) = 0
        SELECT release_id AS ReleaseId, copy_code AS CopyCode, inserted AS Inserted, updated AS Updated
        FROM @result
        ORDER BY release_id, copy_code;
END
GO

-- =====================================================================
-- 8. Backfill the new steps for every active subscription
-- =====================================================================
DECLARE @org BIGINT, @orgs INT = 0;
DECLARE org_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT s.organization_id
    FROM grac_practice.repository_subscription s
    JOIN grac_new.release r ON r.release_id = s.release_id
    WHERE s.status = 'Active'
      AND ISNULL(s.subscription_status, 'Active') = 'Active';
OPEN org_cursor;
FETCH NEXT FROM org_cursor INTO @org;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC grac_practice.sp_repository_subscription_copy
         @organization_id = @org, @release_id = NULL, @refresh = 0,
         @actor = N'migration-392', @suppress_result = 1;
    SET @orgs = @orgs + 1;
    FETCH NEXT FROM org_cursor INTO @org;
END
CLOSE org_cursor;
DEALLOCATE org_cursor;
PRINT '392: backfill ran for ' + CAST(@orgs AS VARCHAR(12)) + ' organization(s).';
GO

-- =====================================================================
-- 9. Verification
-- =====================================================================
-- 9a. New copy row counts per subscribed organization.
SELECT o.organization_id AS OrganizationId,
       (SELECT COUNT(*) FROM grac_practice.organization_source_control_map x
         WHERE x.organization_id = o.organization_id) AS SourceControlMaps,
       (SELECT COUNT(*) FROM grac_practice.organization_repository_control x
         WHERE x.organization_id = o.organization_id) AS Controls,
       (SELECT COUNT(*) FROM grac_practice.organization_control_requirement_map x
         WHERE x.organization_id = o.organization_id) AS ControlRequirementMaps,
       (SELECT COUNT(*) FROM grac_practice.organization_statement_requirement_map x
         WHERE x.organization_id = o.organization_id) AS StatementRequirementMaps,
       (SELECT COUNT(*) FROM grac_practice.organization_repository_requirement x
         WHERE x.organization_id = o.organization_id) AS Requirements,
       (SELECT COUNT(*) FROM grac_practice.organization_requirement x
         WHERE x.organization_id = o.organization_id AND x.status = 'Active'
           AND x.origin_type = 'Repository') AS RepositoryPractices
FROM grac_practice.organization o
WHERE EXISTS (SELECT 1 FROM grac_practice.repository_subscription s
              WHERE s.organization_id = o.organization_id AND s.status = 'Active')
ORDER BY o.organization_id;

-- 9b. Expect 0 rows: a copied statement -> practice link with no active
-- organization mapping row (the import missed it).
SELECT ofs.organization_id AS OrganizationId, ofs.release_id AS ReleaseId,
       ofs.framework_statement_id AS FrameworkStatementId, fsrm.requirement_id AS RequirementId
FROM grac_practice.organization_framework_statements ofs
JOIN grac_practice.organization_statement_requirement_map fsrm
  ON fsrm.organization_id = ofs.organization_id
 AND fsrm.framework_statement_id = ofs.framework_statement_id
 AND fsrm.status = N'Active'
JOIN grac_practice.organization_repository_requirement q
  ON q.organization_id = ofs.organization_id
 AND q.requirement_id = fsrm.requirement_id
 AND q.status = N'Active'
WHERE ofs.status = N'Active'
  AND ofs.source_type = N'Repository'
  AND NOT EXISTS (
      SELECT 1
      FROM grac_practice.organization_statement_practice_mapping m
      JOIN grac_practice.organization_requirement op ON op.organization_requirement_id = m.org_practice_id
      WHERE m.organization_id = ofs.organization_id
        AND m.org_statement_id = ofs.org_statement_id
        AND (op.repository_requirement_id = q.requirement_id OR op.requirement_code = q.requirement_code));

-- 9c. Config as seeded.
SELECT copy_code, copy_order, source_table, target_table, key_column, is_generic_clone, handler_proc
FROM grac_practice.repository_copy_config
ORDER BY copy_order;
GO

PRINT '392 complete.';
GO
