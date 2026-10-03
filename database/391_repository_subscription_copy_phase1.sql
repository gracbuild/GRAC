-- =====================================================================
-- 391 Repository subscription copy model -- PHASE 1 (data only)
--
-- DESIGN
-- ------
--   docs/statement-subscription-copy-model-design.md (sir's decisions of
--   2026-09-28). Today an organization's statements, structure and
--   obligation catalogue are read LIVE from grac_new, so anything Control
--   Management adds or edits reaches every subscribed organization at
--   once. The target model copies them into grac_practice at subscribe
--   time; later repository changes arrive only through approval
--   (phase 3).
--
-- WHAT THIS PHASE DOES (no screen changes)
-- ----------------------------------------
--   1. Helpers (reused by phase 3 detection / apply):
--        fn_repo_column_type            -- a source column's exact type
--        fn_repo_clone_reserved_columns -- org-side column names
--        sp_repo_build_source_view      -- source view + content_hash
--        sp_repo_clone_ensure_table     -- org copy table from a view
--        sp_repo_clone_sync             -- insert / refresh one copy
--   2. repository_copy_config -- one row per copied object: source,
--      view, target, key and the scope predicate for one release.
--   3. Source views, each = the grac_new table's columns + content_hash
--      (SHA2_256 over the row as JSON, audit columns excluded):
--        vw_repo_src_structure_node, vw_repo_src_framework_statement,
--        vw_repo_src_obligation_map, vw_repo_src_obligation_evidence,
--        vw_repo_src_obligation (+ the 7 typed-detail JSON columns taken
--        from vw_pm_obligation_typed_detail, so the typed shape is the
--        one the Resolve screens already render).
--   4. Organization copy tables, typed from the source columns:
--        organization_statement_structure_node,
--        organization_obligation,
--        organization_obligation_requirement_map,
--        organization_obligation_evidence.
--      organization_framework_statements gains content columns
--      (statement_reference / _title / _text, display_order,
--      structure_node_id), org_structure_node_id, source_version_hash,
--      copied_dt, copied_by, lifecycle_status.
--   5. sp_repository_subscription_copy(@organization_id, @release_id,
--      @refresh, @actor, @suppress_result) -- the one "copy" routine.
--   6. Backfill: every active subscription is copied as it is today.
--
-- WHAT DELIBERATELY DID NOT CHANGE
-- --------------------------------
--   * Every reader still reads grac_new (phase 2 repoints them).
--   * The read-time statement sync and read-time practice import in
--     PracticeRepositoryService are untouched (phase 2 removes them and
--     moves the practice import into sp_repository_subscription_copy,
--     so that logic is moved once, not duplicated now).
--   * Master / lookup tables (obligation_type_master, evidence_type_master,
--     reference_option, event_type_master, sla_master) are not copied.
--
-- WHY THE TABLES ARE BUILT DYNAMICALLY
-- ------------------------------------
--   grac_new belongs to Control Management and its DDL is not in this
--   repository. Column names and types are therefore read from the live
--   catalogue (the same approach as 228/302), never guessed. After a
--   Control Management schema change, re-run this file: views are
--   rebuilt and new source columns are added to the copy tables.
--
-- CUT-OVER NOTE
-- -------------
--   Until phase 2 ships, organizations keep reading grac_new, so the
--   copy can fall behind. Immediately before phase 2 goes live run, per
--   organization:
--     EXEC grac_practice.sp_repository_subscription_copy
--          @organization_id = <id>, @refresh = 1, @actor = N'cutover';
--
-- SAFE TO RE-RUN. Requires 302 (vw_pm_obligation_typed_detail) and 347.
-- Rollback: 391_repository_subscription_copy_phase1_rollback.sql
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
IF OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_framework_statements','U') IS NULL
   OR OBJECT_ID('grac_practice.repository_subscription','U') IS NULL
   OR OBJECT_ID('grac_practice.applicability_status_master','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
   OR OBJECT_ID('grac_practice.vw_pm_obligation_typed_detail','V') IS NULL
   OR COL_LENGTH('grac_practice.organization_framework_statements','source_type') IS NULL
BEGIN
    PRINT 'ABORT (391): a grac_practice prerequisite is missing -- run 001, 302 and 347 first.';
    SET NOEXEC ON;
END
GO
IF OBJECT_ID('grac_new.release','U') IS NULL
   OR OBJECT_ID('grac_new.framework_statement','U') IS NULL
   OR OBJECT_ID('grac_new.source_structure_node','U') IS NULL
   OR OBJECT_ID('grac_new.requirement_obligation','U') IS NULL
   OR OBJECT_ID('grac_new.obligation_requirement_release_map','U') IS NULL
   OR OBJECT_ID('grac_new.requirement_obligation_evidence','U') IS NULL
BEGIN
    PRINT 'ABORT (391): a grac_new repository table is missing.';
    SET NOEXEC ON;
END
GO
-- Only the columns this migration names explicitly. Everything else is
-- read from the catalogue.
IF COL_LENGTH('grac_new.release','release_id') IS NULL
   OR COL_LENGTH('grac_new.framework_statement','framework_statement_id') IS NULL
   OR COL_LENGTH('grac_new.framework_statement','release_id') IS NULL
   OR COL_LENGTH('grac_new.framework_statement','structure_node_id') IS NULL
   OR COL_LENGTH('grac_new.framework_statement','statement_reference') IS NULL
   OR COL_LENGTH('grac_new.framework_statement','statement_title') IS NULL
   OR COL_LENGTH('grac_new.framework_statement','statement_text') IS NULL
   OR COL_LENGTH('grac_new.framework_statement','display_order') IS NULL
   OR COL_LENGTH('grac_new.framework_statement','status') IS NULL
   OR COL_LENGTH('grac_new.source_structure_node','structure_node_id') IS NULL
   OR COL_LENGTH('grac_new.source_structure_node','release_id') IS NULL
   OR COL_LENGTH('grac_new.source_structure_node','status') IS NULL
   OR COL_LENGTH('grac_new.requirement_obligation','obligation_id') IS NULL
   OR COL_LENGTH('grac_new.requirement_obligation','status') IS NULL
   OR COL_LENGTH('grac_new.obligation_requirement_release_map','obligation_id') IS NULL
   OR COL_LENGTH('grac_new.obligation_requirement_release_map','release_id') IS NULL
   OR COL_LENGTH('grac_new.obligation_requirement_release_map','status') IS NULL
   OR COL_LENGTH('grac_new.requirement_obligation_evidence','obligation_evidence_id') IS NULL
   OR COL_LENGTH('grac_new.requirement_obligation_evidence','status') IS NULL
BEGIN
    PRINT 'ABORT (391): a grac_new column this migration reads is missing.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Helpers
-- =====================================================================

-- 1a. Exact declared type of a column, as DDL text. NULL when the column
-- does not exist. rowversion becomes binary(8): a copy must hold the
-- value, not generate a new one.
CREATE OR ALTER FUNCTION grac_practice.fn_repo_column_type(@object_id INT, @column_name SYSNAME)
RETURNS NVARCHAR(200)
AS
BEGIN
    DECLARE @type NVARCHAR(200);
    SELECT @type =
        CASE
            WHEN c.system_type_id = 240 THEN TYPE_NAME(c.user_type_id)
            WHEN t.name IN (N'nvarchar', N'nchar')
                THEN t.name + N'(' + CASE WHEN c.max_length = -1 THEN N'MAX'
                                          ELSE CAST(c.max_length / 2 AS NVARCHAR(10)) END + N')'
            WHEN t.name IN (N'varchar', N'char', N'varbinary', N'binary')
                THEN t.name + N'(' + CASE WHEN c.max_length = -1 THEN N'MAX'
                                          ELSE CAST(c.max_length AS NVARCHAR(10)) END + N')'
            WHEN t.name IN (N'decimal', N'numeric')
                THEN t.name + N'(' + CAST(c.precision AS NVARCHAR(10)) + N','
                            + CAST(c.scale AS NVARCHAR(10)) + N')'
            WHEN t.name IN (N'datetime2', N'time', N'datetimeoffset')
                THEN t.name + N'(' + CAST(c.scale AS NVARCHAR(10)) + N')'
            WHEN t.name = N'timestamp' THEN N'binary(8)'
            ELSE t.name
        END
    FROM sys.columns c
    LEFT JOIN sys.types t ON t.user_type_id = c.system_type_id
    WHERE c.object_id = @object_id
      AND c.name = @column_name;
    RETURN @type;
END
GO

-- 1b. Column names owned by the organization side of every copy table.
-- A source column with one of these names is never copied.
CREATE OR ALTER FUNCTION grac_practice.fn_repo_clone_reserved_columns()
RETURNS TABLE
AS
RETURN
    SELECT v.column_name
    FROM (VALUES (N'organization_id'), (N'lifecycle_status'), (N'source_version_hash'),
                 (N'copied_dt'), (N'copied_by'), (N'content_hash')) AS v(column_name);
GO

-- 1c. Build grac_practice.<view> = every column of a grac_new table, plus
-- optional extra columns, plus content_hash. The hash leaves out audit
-- columns (a touch without a content change must not look like a change)
-- and types FOR JSON cannot serialise (rowversion, CLR, xml). Extra
-- columns join the hash under their alias, so a typed-detail or evidence
-- change counts as a content change of the obligation.
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

-- 1d. Create (or widen) grac_practice.<target> from a source view:
--   <org_pk_column> BIGINT IDENTITY PK, organization_id, lifecycle_status,
--   source_version_hash, copied_dt, copied_by, then every view column
--   (nullable, same type). Unique per (organization_id, key_column).
-- When the table exists, only view columns it lacks are added.
CREATE OR ALTER PROCEDURE grac_practice.sp_repo_clone_ensure_table
    @source_view   SYSNAME,
    @target_table  SYSNAME,
    @org_pk_column SYSNAME,
    @key_column    SYSNAME
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @view_id INT = OBJECT_ID(N'grac_practice.' + QUOTENAME(@source_view), 'V');
    DECLARE @target  NVARCHAR(300) = N'grac_practice.' + QUOTENAME(@target_table);
    DECLARE @msg NVARCHAR(400), @cols NVARCHAR(MAX), @sql NVARCHAR(MAX);
    IF @view_id IS NULL
    BEGIN
        SET @msg = N'sp_repo_clone_ensure_table: view grac_practice.' + @source_view + N' not found.';
        THROW 53912, @msg, 1;
    END

    IF OBJECT_ID(@target, 'U') IS NULL
    BEGIN
        SELECT @cols = STRING_AGG(CAST(QUOTENAME(c.name) + N' '
                                       + grac_practice.fn_repo_column_type(@view_id, c.name)
                                       + N' NULL' AS NVARCHAR(MAX)), N',
        ') WITHIN GROUP (ORDER BY c.column_id)
        FROM sys.columns c
        WHERE c.object_id = @view_id
          AND c.name <> @org_pk_column
          AND c.name NOT IN (SELECT r.column_name FROM grac_practice.fn_repo_clone_reserved_columns() r);

        SET @sql = N'CREATE TABLE ' + @target + N'(
        ' + QUOTENAME(@org_pk_column) + N' BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT ' + QUOTENAME(N'pk_pm_' + @target_table) + N' PRIMARY KEY,
        organization_id BIGINT NOT NULL
            CONSTRAINT ' + QUOTENAME(N'fk_pm_' + @target_table + N'_org') + N'
                REFERENCES grac_practice.organization(organization_id),
        lifecycle_status NVARCHAR(20) NOT NULL
            CONSTRAINT ' + QUOTENAME(N'df_pm_' + @target_table + N'_lifecycle') + N' DEFAULT N''Active'',
        source_version_hash VARBINARY(32) NULL,
        copied_dt DATETIME2 NOT NULL
            CONSTRAINT ' + QUOTENAME(N'df_pm_' + @target_table + N'_copied_dt') + N' DEFAULT SYSUTCDATETIME(),
        copied_by NVARCHAR(100) NOT NULL,
        ' + @cols + N'
    );';
        EXEC sp_executesql @sql;

        SET @sql = N'CREATE UNIQUE INDEX ' + QUOTENAME(N'uq_pm_' + @target_table + N'_key')
                 + N' ON ' + @target + N'(organization_id, ' + QUOTENAME(@key_column) + N')'
                 + N' WHERE ' + QUOTENAME(@key_column) + N' IS NOT NULL;';
        EXEC sp_executesql @sql;
        PRINT '391: created ' + @target + '.';
    END
    ELSE
    BEGIN
        SET @cols = NULL;
        SELECT @cols = STRING_AGG(CAST(QUOTENAME(c.name) + N' '
                                       + grac_practice.fn_repo_column_type(@view_id, c.name)
                                       + N' NULL' AS NVARCHAR(MAX)), N', ')
                       WITHIN GROUP (ORDER BY c.column_id)
        FROM sys.columns c
        WHERE c.object_id = @view_id
          AND c.name <> @org_pk_column
          AND c.name NOT IN (SELECT r.column_name FROM grac_practice.fn_repo_clone_reserved_columns() r)
          AND COL_LENGTH(@target, c.name) IS NULL;
        IF @cols IS NOT NULL
        BEGIN
            SET @sql = N'ALTER TABLE ' + @target + N' ADD ' + @cols + N';';
            EXEC sp_executesql @sql;
            PRINT '391: added new source columns to ' + @target + '.';
        END
    END
END
GO

-- =====================================================================
-- 2. repository_copy_config
-- =====================================================================
IF OBJECT_ID('grac_practice.repository_copy_config','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.repository_copy_config(
        copy_code        NVARCHAR(40)  NOT NULL
            CONSTRAINT pk_pm_repository_copy_config PRIMARY KEY,
        copy_order       INT           NOT NULL,
        source_table     NVARCHAR(256) NOT NULL,
        source_view      SYSNAME       NOT NULL,
        target_table     SYSNAME       NOT NULL,
        org_pk_column    SYSNAME       NOT NULL,
        key_column       SYSNAME       NOT NULL,
        -- Predicate on alias src. Parameters available: @organization_id,
        -- @release_id.
        scope_sql        NVARCHAR(MAX) NOT NULL,
        -- 1 = copied by sp_repo_clone_sync. 0 = organization_framework_statements,
        -- which predates the copy model and is filled by its own block.
        is_generic_clone BIT           NOT NULL,
        status           NVARCHAR(30)  NOT NULL
            CONSTRAINT df_pm_repository_copy_config_status DEFAULT N'Active',
        entered_by       NVARCHAR(100) NOT NULL,
        entered_dt       DATETIME2     NOT NULL
            CONSTRAINT df_pm_repository_copy_config_entered DEFAULT SYSUTCDATETIME(),
        updated_by       NVARCHAR(100) NULL,
        updated_dt       DATETIME2     NULL
    );
    PRINT '391: repository_copy_config created.';
END
GO

-- The obligation map's key is its own primary key, read from the catalogue
-- (its name is not referenced anywhere in this repository).
DECLARE @map_key SYSNAME, @pk_cols INT;
SELECT @pk_cols = COUNT(*), @map_key = MAX(c.name)
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID('grac_new.obligation_requirement_release_map')
  AND i.is_primary_key = 1;
IF ISNULL(@pk_cols, 0) <> 1
    SELECT @map_key = idc.name
    FROM sys.identity_columns idc
    WHERE idc.object_id = OBJECT_ID('grac_new.obligation_requirement_release_map');
IF @map_key IS NULL
BEGIN
    PRINT 'ABORT (391): grac_new.obligation_requirement_release_map has no single-column key.';
    SET NOEXEC ON;
END
ELSE
BEGIN
    MERGE grac_practice.repository_copy_config AS t
    USING (VALUES
        (N'StructureNode', 10, N'grac_new.source_structure_node', N'vw_repo_src_structure_node',
         N'organization_statement_structure_node', N'org_structure_node_id', N'structure_node_id',
         N'src.release_id = @release_id', CAST(1 AS BIT)),
        (N'Statement', 20, N'grac_new.framework_statement', N'vw_repo_src_framework_statement',
         N'organization_framework_statements', N'org_statement_id', N'framework_statement_id',
         N'src.release_id = @release_id', CAST(0 AS BIT)),
        (N'Obligation', 30, N'grac_new.requirement_obligation', N'vw_repo_src_obligation',
         N'organization_obligation', N'org_obligation_id', N'obligation_id',
         N'EXISTS (SELECT 1 FROM grac_new.obligation_requirement_release_map m
                   WHERE m.obligation_id = src.obligation_id
                     AND m.release_id = @release_id
                     AND m.status = N''Active'')', CAST(1 AS BIT)),
        (N'ObligationMap', 40, N'grac_new.obligation_requirement_release_map', N'vw_repo_src_obligation_map',
         N'organization_obligation_requirement_map', N'org_obligation_map_id', @map_key,
         N'src.release_id = @release_id', CAST(1 AS BIT)),
        -- Evidence in scope = the evidence ids the obligation's own copied
        -- EvidenceJson lists (direct and per-type links, as 302 resolves
        -- them), for obligations of this release.
        (N'ObligationEvidence', 50, N'grac_new.requirement_obligation_evidence', N'vw_repo_src_obligation_evidence',
         N'organization_obligation_evidence', N'org_obligation_evidence_id', N'obligation_evidence_id',
         N'EXISTS (SELECT 1
                   FROM grac_practice.organization_obligation oo
                   JOIN grac_practice.organization_obligation_requirement_map om
                     ON om.organization_id = oo.organization_id
                    AND om.obligation_id = oo.obligation_id
                    AND om.release_id = @release_id
                   CROSS APPLY OPENJSON(oo.evidence_json)
                        WITH (ObligationEvidenceId BIGINT ''$.ObligationEvidenceId'') j
                   WHERE oo.organization_id = @organization_id
                     AND j.ObligationEvidenceId = src.obligation_evidence_id)', CAST(1 AS BIT))
    ) AS s(copy_code, copy_order, source_table, source_view, target_table, org_pk_column, key_column, scope_sql, is_generic_clone)
    ON t.copy_code = s.copy_code
    WHEN MATCHED THEN UPDATE SET
        copy_order = s.copy_order, source_table = s.source_table, source_view = s.source_view,
        target_table = s.target_table, org_pk_column = s.org_pk_column, key_column = s.key_column,
        scope_sql = s.scope_sql, is_generic_clone = s.is_generic_clone, status = N'Active',
        updated_by = N'migration-391', updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (copy_code, copy_order, source_table, source_view, target_table, org_pk_column, key_column,
         scope_sql, is_generic_clone, status, entered_by)
        VALUES (s.copy_code, s.copy_order, s.source_table, s.source_view, s.target_table, s.org_pk_column,
                s.key_column, s.scope_sql, s.is_generic_clone, N'Active', N'migration-391');
    PRINT '391: repository_copy_config seeded (obligation map key = ' + @map_key + ').';
END
GO

-- =====================================================================
-- 3. Source views
-- =====================================================================
EXEC grac_practice.sp_repo_build_source_view
     @source_table = N'grac_new.source_structure_node', @view_name = N'vw_repo_src_structure_node';
EXEC grac_practice.sp_repo_build_source_view
     @source_table = N'grac_new.framework_statement', @view_name = N'vw_repo_src_framework_statement';
EXEC grac_practice.sp_repo_build_source_view
     @source_table = N'grac_new.obligation_requirement_release_map', @view_name = N'vw_repo_src_obligation_map';
EXEC grac_practice.sp_repo_build_source_view
     @source_table = N'grac_new.requirement_obligation_evidence', @view_name = N'vw_repo_src_obligation_evidence';
-- The typed detail comes from the view the Resolve screens already use,
-- so the copy holds exactly the JSON shape they render.
EXEC grac_practice.sp_repo_build_source_view
     @source_table = N'grac_new.requirement_obligation',
     @view_name    = N'vw_repo_src_obligation',
     @extra_select = N'td.StateRulesJson AS state_rules_json,
           td.ExecutionSpecsJson AS execution_specs_json,
           td.AssuranceSpecsJson AS assurance_specs_json,
           td.EventResponsesJson AS event_responses_json,
           td.ConstraintRulesJson AS constraint_rules_json,
           td.RetentionSpecsJson AS retention_specs_json,
           td.EvidenceJson AS evidence_json',
     @extra_from   = N'LEFT JOIN grac_practice.vw_pm_obligation_typed_detail td ON td.ObligationId = src.obligation_id';
PRINT '391: source views built.';
GO

-- =====================================================================
-- 4. Organization copy tables
-- =====================================================================
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_org_structure_node_release'
                 AND object_id = OBJECT_ID('grac_practice.organization_statement_structure_node'))
    CREATE INDEX ix_pm_org_structure_node_release
        ON grac_practice.organization_statement_structure_node(organization_id, release_id);
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_org_obligation_map_release'
                 AND object_id = OBJECT_ID('grac_practice.organization_obligation_requirement_map'))
    CREATE INDEX ix_pm_org_obligation_map_release
        ON grac_practice.organization_obligation_requirement_map(organization_id, release_id, obligation_id);
GO

-- 4b. organization_framework_statements: content columns, typed exactly
-- as in grac_new.framework_statement.
DECLARE @fs_id INT = OBJECT_ID('grac_new.framework_statement', 'U');
DECLARE @col SYSNAME, @type NVARCHAR(200), @sql NVARCHAR(MAX), @msg NVARCHAR(400);
DECLARE col_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT v.column_name
    FROM (VALUES (N'statement_reference'), (N'statement_title'), (N'statement_text'),
                 (N'display_order'), (N'structure_node_id')) AS v(column_name);
OPEN col_cursor;
FETCH NEXT FROM col_cursor INTO @col;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF COL_LENGTH('grac_practice.organization_framework_statements', @col) IS NULL
    BEGIN
        SET @type = grac_practice.fn_repo_column_type(@fs_id, @col);
        IF @type IS NULL
        BEGIN
            SET @msg = N'391: cannot read the type of grac_new.framework_statement.' + @col + N'.';
            THROW 53915, @msg, 1;
        END
        SET @sql = N'ALTER TABLE grac_practice.organization_framework_statements ADD '
                 + QUOTENAME(@col) + N' ' + @type + N' NULL;';
        EXEC sp_executesql @sql;
        PRINT '391: organization_framework_statements.' + @col + ' added.';
    END
    FETCH NEXT FROM col_cursor INTO @col;
END
CLOSE col_cursor;
DEALLOCATE col_cursor;
GO

IF COL_LENGTH('grac_practice.organization_framework_statements','org_structure_node_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.organization_framework_statements
        ADD org_structure_node_id BIGINT NULL
            CONSTRAINT fk_pm_ofs_org_structure_node
                REFERENCES grac_practice.organization_statement_structure_node(org_structure_node_id);
    PRINT '391: organization_framework_statements.org_structure_node_id added.';
END
GO
IF COL_LENGTH('grac_practice.organization_framework_statements','source_version_hash') IS NULL
    ALTER TABLE grac_practice.organization_framework_statements ADD source_version_hash VARBINARY(32) NULL;
IF COL_LENGTH('grac_practice.organization_framework_statements','copied_dt') IS NULL
    ALTER TABLE grac_practice.organization_framework_statements ADD copied_dt DATETIME2 NULL;
IF COL_LENGTH('grac_practice.organization_framework_statements','copied_by') IS NULL
    ALTER TABLE grac_practice.organization_framework_statements ADD copied_by NVARCHAR(100) NULL;
IF COL_LENGTH('grac_practice.organization_framework_statements','lifecycle_status') IS NULL
    ALTER TABLE grac_practice.organization_framework_statements
        ADD lifecycle_status NVARCHAR(20) NOT NULL
            CONSTRAINT df_pm_ofs_lifecycle_status DEFAULT N'Active';
GO

-- =====================================================================
-- 5. sp_repo_clone_sync -- one generic copy for one config row
-- =====================================================================
--   @refresh = 0 : insert rows the organization does not have yet.
--   @refresh = 1 : also overwrite existing rows whose hash differs.
--   @key_value   : restrict to one source key (phase 3 item apply).
-- Only Active source rows are inserted. Nothing is deleted or retired
-- here -- a retirement is a phase 3 approval.
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

-- =====================================================================
-- 6. sp_repository_subscription_copy -- the one "copy" routine
-- =====================================================================
--   @release_id NULL = every active repository subscription of the org.
--   @refresh    0    = fill: insert what is missing, and fill statement
--                      rows that were never copied (created by the
--                      read-time sync). Existing copies are not touched.
--               1    = also re-snapshot every copy whose hash differs
--                      (cut-over only; after phase 3, changes go through
--                      approval instead).
-- One transaction per release when called outside a transaction; inside
-- a caller's transaction it joins it.
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

    DECLARE @not_updated_status_id INT = (
        SELECT TOP (1) applicability_status_id
        FROM grac_practice.applicability_status_master
        WHERE status_code = 'Not Updated' OR status_name = 'Not Updated');
    DECLARE @active_status_id INT = (
        SELECT TOP (1) record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'Active' OR status_name = 'Active');

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
    DECLARE @rid BIGINT, @code NVARCHAR(40), @generic BIT, @ins INT, @upd INT;

    BEGIN TRY
        DECLARE release_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT release_id FROM @releases ORDER BY release_id;
        OPEN release_cursor;
        FETCH NEXT FROM release_cursor INTO @rid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @own_tran = 1 BEGIN TRANSACTION;

            DECLARE step_cursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT copy_code, is_generic_clone
                FROM grac_practice.repository_copy_config
                WHERE status = N'Active'
                ORDER BY copy_order;
            OPEN step_cursor;
            FETCH NEXT FROM step_cursor INTO @code, @generic;
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
                ELSE IF @code = N'Statement'
                BEGIN
                    -- Same insert the read-time sync does today (phase 2
                    -- removes that one, leaving this as the only path).
                    INSERT grac_practice.organization_framework_statements(
                        organization_id, release_id, framework_statement_id,
                        applicability_status_id, status_id, status, entered_by)
                    SELECT @organization_id, @rid, src.framework_statement_id,
                           @not_updated_status_id, @active_status_id, N'Active', @actor
                    FROM grac_practice.vw_repo_src_framework_statement src
                    WHERE src.release_id = @rid
                      AND src.status = N'Active'
                      AND NOT EXISTS (
                          SELECT 1 FROM grac_practice.organization_framework_statements x
                          WHERE x.organization_id = @organization_id
                            AND x.release_id = @rid
                            AND x.framework_statement_id = src.framework_statement_id);
                    SET @ins = @@ROWCOUNT;

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
                      AND ofs.release_id = @rid
                      AND ofs.source_type = N'Repository'
                      AND (ofs.copied_dt IS NULL
                           OR (@refresh = 1
                               AND (ofs.source_version_hash IS NULL
                                    OR ofs.source_version_hash <> src.content_hash
                                    OR ofs.org_structure_node_id IS NULL)));
                    SET @upd = @@ROWCOUNT;
                END

                INSERT @result(release_id, copy_code, inserted, updated) VALUES (@rid, @code, @ins, @upd);
                FETCH NEXT FROM step_cursor INTO @code, @generic;
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
-- 7. Backfill -- every active repository subscription, as it is today
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
         @actor = N'migration-391', @suppress_result = 1;
    SET @orgs = @orgs + 1;
    FETCH NEXT FROM org_cursor INTO @org;
END
CLOSE org_cursor;
DEALLOCATE org_cursor;
PRINT '391: backfill copied ' + CAST(@orgs AS VARCHAR(12)) + ' organization(s).';
GO

-- =====================================================================
-- 8. Verification
-- =====================================================================
-- 8a. Copy row counts per subscribed organization.
SELECT o.organization_id AS OrganizationId,
       (SELECT COUNT(*) FROM grac_practice.organization_statement_structure_node x
         WHERE x.organization_id = o.organization_id) AS StructureNodes,
       (SELECT COUNT(*) FROM grac_practice.organization_framework_statements x
         WHERE x.organization_id = o.organization_id AND x.copied_dt IS NOT NULL) AS StatementsCopied,
       (SELECT COUNT(*) FROM grac_practice.organization_obligation x
         WHERE x.organization_id = o.organization_id) AS Obligations,
       (SELECT COUNT(*) FROM grac_practice.organization_obligation_requirement_map x
         WHERE x.organization_id = o.organization_id) AS ObligationMaps,
       (SELECT COUNT(*) FROM grac_practice.organization_obligation_evidence x
         WHERE x.organization_id = o.organization_id) AS ObligationEvidence
FROM grac_practice.organization o
WHERE EXISTS (SELECT 1 FROM grac_practice.repository_subscription s
              WHERE s.organization_id = o.organization_id AND s.status = 'Active')
ORDER BY o.organization_id;

-- 8b. Expect 0 rows: a repository statement row of an active subscription
-- that still has no content. A row whose framework_statement_id no longer
-- exists in grac_new shows here -- report it, do not delete it.
SELECT ofs.organization_id AS OrganizationId, ofs.release_id AS ReleaseId,
       ofs.framework_statement_id AS FrameworkStatementId
FROM grac_practice.organization_framework_statements ofs
JOIN grac_practice.repository_subscription s
  ON s.organization_id = ofs.organization_id AND s.release_id = ofs.release_id
 AND s.status = 'Active' AND ISNULL(s.subscription_status, 'Active') = 'Active'
WHERE ofs.source_type = N'Repository'
  AND ofs.copied_dt IS NULL;

-- 8c. Expect 0 rows: an active grac_new statement of a subscribed release
-- the organization has no copy of.
SELECT s.organization_id AS OrganizationId, src.release_id AS ReleaseId,
       src.framework_statement_id AS FrameworkStatementId
FROM grac_practice.repository_subscription s
JOIN grac_practice.vw_repo_src_framework_statement src
  ON src.release_id = s.release_id AND src.status = N'Active'
WHERE s.status = 'Active' AND ISNULL(s.subscription_status, 'Active') = 'Active'
  AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_framework_statements ofs
                  WHERE ofs.organization_id = s.organization_id
                    AND ofs.release_id = s.release_id
                    AND ofs.framework_statement_id = src.framework_statement_id
                    AND ofs.copied_dt IS NOT NULL);

-- 8d. Config as seeded.
SELECT copy_code, copy_order, source_table, source_view, target_table, key_column, is_generic_clone
FROM grac_practice.repository_copy_config
ORDER BY copy_order;
GO

PRINT '391 complete.';
GO
