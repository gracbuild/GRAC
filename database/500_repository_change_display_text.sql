-- =====================================================================
-- 500_repository_change_display_text.sql
--
-- THE COMPLAINT
-- -------------
-- Repository Updates (Practice/Index/repository-updates, migration 395)
-- lists one row per difference Control Management made to a subscribed
-- release, and "Details" opens a field-by-field diff of the stored
-- snapshots. That diff is unreadable:
--   * the Field column shows raw database column names
--     (statement_reference, node_sort_order, is_mandatory, ...);
--   * every foreign key shows its number -- control_id 418,
--     requirement_id 1902, framework_statement_id 7731 -- so the
--     approver cannot tell WHICH control or practice is meant;
--   * plumbing columns (hashes, copied_by, lifecycle_status, the copy
--     row's own primary key) sit in the list as though they mattered;
--   * the 7 typed-detail JSON columns print as one long line.
-- The person approving the change is the release owner or an
-- organization admin, not a DBA.
--
-- WHY IT IS LIKE THAT
-- -------------------
-- old_snapshot_json / new_snapshot_json are written by
-- sp_repo_change_detect_step as "SELECT t2.* ... FOR JSON PATH" over the
-- organization copy table and the grac_new source view. That is the
-- right thing to store -- it is the row as it was detected -- but it is
-- the raw row, and the page rendered it as-is in JavaScript.
--
-- grac_new belongs to Control Management and its DDL is not in this
-- repository (see 391), so the readable names cannot be hard-coded in
-- the browser. They have to be resolved where the data is.
--
-- WHAT THIS DOES
-- --------------
-- 1. repository_change_field_config -- one row per snapshot field name,
--    seeded with:
--      * is_hidden for the plumbing columns,
--      * display_label for the names that do not read well on their own,
--      * lookup_table / lookup_key / lookup_text_sql for the id columns,
--        so 418 becomes "A.5.1 - Information security policies".
--    Only the columns migrations 391/392/395 already depend on are
--    seeded as lookups; nothing is assumed about grac_new beyond that,
--    and any seeded row whose table or key column is not present is
--    switched to Inactive by the sweep at the end of this file.
-- 2. fn_repo_field_label -- the generic fallback for every field that has
--    no display_label: underscores to spaces, a trailing " id" dropped,
--    first letter capitalised.
-- 3. sp_repository_change_display(@organization_id, @change_id) -- the
--    resolved field list for ONE change: label, raw old/new value and
--    the resolved old/new text. Read lazily when Details is opened, so
--    the list query is untouched.
--
-- Nothing already stored is rewritten, and detection, approval and the
-- list are not changed. This is display only.
--
-- SAFE TO RE-RUN. Requires 391, 392 and 395.
-- Rollback: 500_repository_change_display_text_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.organization_repository_change','U') IS NULL
   OR OBJECT_ID('grac_practice.repository_copy_config','U') IS NULL
   OR COL_LENGTH('grac_practice.repository_copy_config','org_pk_column') IS NULL
BEGIN
    PRINT 'ABORT (500): run 391, 392 and 395 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. repository_change_field_config
-- =====================================================================
IF OBJECT_ID('grac_practice.repository_change_field_config','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.repository_change_field_config(
        field_name      NVARCHAR(128) NOT NULL
            CONSTRAINT pk_pm_repo_change_field_config PRIMARY KEY,
        display_label   NVARCHAR(200) NULL,
        is_hidden       BIT NOT NULL
            CONSTRAINT df_pm_repo_change_field_hidden DEFAULT 0,
        -- Schema-qualified table the value points at, its key column and
        -- a text expression over the alias x. All three, or none.
        lookup_table    NVARCHAR(256) NULL,
        lookup_key      NVARCHAR(128) NULL,
        lookup_text_sql NVARCHAR(MAX) NULL,
        -- NULL / Json / Bit / Date -- how the page should render it.
        value_kind      NVARCHAR(20)  NULL,
        display_order   INT NOT NULL
            CONSTRAINT df_pm_repo_change_field_order DEFAULT 500,
        status          NVARCHAR(20) NOT NULL
            CONSTRAINT df_pm_repo_change_field_status DEFAULT N'Active',
        entered_by      NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_repo_change_field_entered_by DEFAULT N'system',
        entered_dt      DATETIME2 NOT NULL
            CONSTRAINT df_pm_repo_change_field_entered DEFAULT SYSUTCDATETIME(),
        updated_by      NVARCHAR(100) NULL,
        updated_dt      DATETIME2 NULL
    );
    PRINT '500: repository_change_field_config created.';
END
GO

-- =====================================================================
-- 2. Seed
-- =====================================================================
-- Every lookup below names only tables and columns that migrations
-- 391/392/395 already read (label_sql, scope_sql, sp_repository_change_list).
MERGE grac_practice.repository_change_field_config AS t
USING (VALUES
    -- --- plumbing: never shown -------------------------------------
    -- The first row types every nullable column of the derived table
    -- explicitly, the same way 392 does.
    (N'organization_id', CAST(NULL AS NVARCHAR(200)), CAST(1 AS BIT),
     CAST(NULL AS NVARCHAR(256)), CAST(NULL AS NVARCHAR(128)), CAST(NULL AS NVARCHAR(MAX)),
     CAST(NULL AS NVARCHAR(20)), 900),
    (N'lifecycle_status',       NULL, CAST(1 AS BIT), NULL, NULL, NULL, NULL, 900),
    (N'source_version_hash',    NULL, CAST(1 AS BIT), NULL, NULL, NULL, NULL, 900),
    (N'content_hash',           NULL, CAST(1 AS BIT), NULL, NULL, NULL, NULL, 900),
    (N'copied_dt',              NULL, CAST(1 AS BIT), NULL, NULL, NULL, NULL, 900),
    (N'copied_by',              NULL, CAST(1 AS BIT), NULL, NULL, NULL, NULL, 900),
    (N'entered_by',             NULL, CAST(1 AS BIT), NULL, NULL, NULL, NULL, 900),
    (N'entered_dt',             NULL, CAST(1 AS BIT), NULL, NULL, NULL, NULL, 900),
    (N'updated_by',             NULL, CAST(1 AS BIT), NULL, NULL, NULL, NULL, 900),
    (N'updated_dt',             NULL, CAST(1 AS BIT), NULL, NULL, NULL, NULL, 900),
    (N'modified_by',            NULL, CAST(1 AS BIT), NULL, NULL, NULL, NULL, 900),
    (N'modified_dt',            NULL, CAST(1 AS BIT), NULL, NULL, NULL, NULL, 900),

    -- --- id columns resolved to text -------------------------------
    (N'control_id',              N'Control',          CAST(0 AS BIT),
     N'grac_new.control', N'control_id',
     N'CONCAT(x.control_code, N'' - '', x.control_name)', NULL, 60),
    (N'structure_node_id',       N'Source structure', CAST(0 AS BIT),
     N'grac_new.source_structure_node', N'structure_node_id',
     N'CONCAT(x.node_reference, N'' '', x.node_title)', NULL, 50),
    (N'parent_structure_node_id',N'Parent structure', CAST(0 AS BIT),
     N'grac_new.source_structure_node', N'structure_node_id',
     N'CONCAT(x.node_reference, N'' '', x.node_title)', NULL, 55),
    (N'requirement_id',          N'Practice',         CAST(0 AS BIT),
     N'grac_new.requirement', N'requirement_id',
     N'CONCAT(x.requirement_code, N'' - '', x.requirement_name)', NULL, 70),
    (N'framework_statement_id',  N'Source statement', CAST(0 AS BIT),
     N'grac_new.framework_statement', N'framework_statement_id',
     N'CONCAT(x.statement_reference, N'' - '', x.statement_title)', NULL, 40),
    (N'obligation_id',           N'Obligation',       CAST(0 AS BIT),
     N'grac_new.requirement_obligation', N'obligation_id',
     N'COALESCE(NULLIF(LTRIM(RTRIM(x.obligation_name)), N''''), LEFT(x.obligation_text, 200))', NULL, 80),
    (N'release_id',              N'Release',          CAST(0 AS BIT),
     N'grac_new.release', N'release_id', N'x.version_no', NULL, 20),
    (N'artifact_id',             N'Framework',        CAST(0 AS BIT),
     N'grac_new.artifact', N'artifact_id',
     N'CONCAT(x.artifact_code, N'' - '', x.artifact_name)', NULL, 15),
    (N'authority_id',            N'Publisher',        CAST(0 AS BIT),
     N'grac_new.authority', N'authority_id',
     N'CONCAT(x.authority_code, N'' - '', x.authority_name)', NULL, 10),
    (N'evidence_type_id',        N'Evidence type',    CAST(0 AS BIT),
     N'grac_practice.evidence_type_master', N'evidence_type_id',
     N'CONCAT(x.evidence_type_code, N'' - '', x.evidence_type_name)', NULL, 85),
    (N'owner_id',                N'Owner',            CAST(0 AS BIT),
     N'grac_practice.organization_employee', N'employee_id', N'x.employee_name', NULL, 88),
    (N'owner_employee_id',       N'Owner',            CAST(0 AS BIT),
     N'grac_practice.organization_employee', N'employee_id', N'x.employee_name', NULL, 88),

    -- --- the 7 typed-detail JSON columns (391) ---------------------
    (N'state_rules_json',        N'State rules',               CAST(0 AS BIT), NULL, NULL, NULL, N'Json', 800),
    (N'execution_specs_json',    N'Execution specifications',  CAST(0 AS BIT), NULL, NULL, NULL, N'Json', 801),
    (N'assurance_specs_json',    N'Assurance specifications',  CAST(0 AS BIT), NULL, NULL, NULL, N'Json', 802),
    (N'event_responses_json',    N'Event responses',           CAST(0 AS BIT), NULL, NULL, NULL, N'Json', 803),
    (N'constraint_rules_json',   N'Constraint rules',          CAST(0 AS BIT), NULL, NULL, NULL, N'Json', 804),
    (N'retention_specs_json',    N'Retention specifications',  CAST(0 AS BIT), NULL, NULL, NULL, N'Json', 805),
    (N'evidence_json',           N'Evidence',                  CAST(0 AS BIT), NULL, NULL, NULL, N'Json', 806),

    -- --- names worth a better label --------------------------------
    (N'node_reference',          N'Reference',            CAST(0 AS BIT), NULL, NULL, NULL, NULL, 21),
    (N'node_title',              N'Title',                CAST(0 AS BIT), NULL, NULL, NULL, NULL, 22),
    (N'statement_reference',     N'Statement reference',  CAST(0 AS BIT), NULL, NULL, NULL, NULL, 21),
    (N'statement_title',         N'Statement title',      CAST(0 AS BIT), NULL, NULL, NULL, NULL, 22),
    (N'statement_text',          N'Statement text',       CAST(0 AS BIT), NULL, NULL, NULL, NULL, 23),
    (N'control_code',            N'Control code',         CAST(0 AS BIT), NULL, NULL, NULL, NULL, 21),
    (N'control_name',            N'Control name',         CAST(0 AS BIT), NULL, NULL, NULL, NULL, 22),
    (N'requirement_code',        N'Practice code',        CAST(0 AS BIT), NULL, NULL, NULL, NULL, 21),
    (N'requirement_name',        N'Practice name',        CAST(0 AS BIT), NULL, NULL, NULL, NULL, 22),
    (N'obligation_name',         N'Obligation name',      CAST(0 AS BIT), NULL, NULL, NULL, NULL, 21),
    (N'obligation_text',         N'Obligation text',      CAST(0 AS BIT), NULL, NULL, NULL, NULL, 23),
    (N'obligation_type_code',    N'Obligation type',      CAST(0 AS BIT), NULL, NULL, NULL, NULL, 24),
    (N'status',                  N'Status',               CAST(0 AS BIT), NULL, NULL, NULL, NULL, 30),
    (N'display_order',           N'Display order',        CAST(0 AS BIT), NULL, NULL, NULL, NULL, 31)
) AS s(field_name, display_label, is_hidden, lookup_table, lookup_key, lookup_text_sql, value_kind, display_order)
ON t.field_name = s.field_name
WHEN MATCHED THEN UPDATE SET
    display_label = s.display_label, is_hidden = s.is_hidden,
    lookup_table = s.lookup_table, lookup_key = s.lookup_key,
    lookup_text_sql = s.lookup_text_sql, value_kind = s.value_kind,
    display_order = s.display_order, status = N'Active',
    updated_by = N'migration-500', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (field_name, display_label, is_hidden, lookup_table, lookup_key, lookup_text_sql,
     value_kind, display_order, status, entered_by)
    VALUES (s.field_name, s.display_label, s.is_hidden, s.lookup_table, s.lookup_key,
            s.lookup_text_sql, s.value_kind, s.display_order, N'Active', N'migration-500');
GO

-- A lookup whose table or key column is not in THIS database is parked,
-- not deleted: re-running this file reactivates it if the object arrives.
UPDATE c
   SET status = N'Inactive', updated_by = N'migration-500', updated_dt = SYSUTCDATETIME()
FROM grac_practice.repository_change_field_config c
WHERE c.lookup_table IS NOT NULL
  AND c.status = N'Active'
  AND (OBJECT_ID(c.lookup_table) IS NULL
       OR COL_LENGTH(c.lookup_table, c.lookup_key) IS NULL);
GO
PRINT '500: repository_change_field_config seeded.';
GO

-- =====================================================================
-- 3. fn_repo_field_label -- generic fallback label
-- =====================================================================
-- node_sort_order -> "Node sort order"; scope_id -> "Scope" (a trailing
-- " id" is dropped because an unresolved id still reads better without
-- it); a trailing "_json" is dropped the same way.
CREATE OR ALTER FUNCTION grac_practice.fn_repo_field_label(@field_name NVARCHAR(128))
RETURNS NVARCHAR(200)
AS
BEGIN
    DECLARE @s NVARCHAR(200) = LTRIM(RTRIM(ISNULL(@field_name, N'')));
    IF @s = N'' RETURN N'';
    SET @s = REPLACE(@s, N'_', N' ');
    IF LEN(@s) > 5 AND RIGHT(@s, 5) = N' json' SET @s = LEFT(@s, LEN(@s) - 5);
    IF LEN(@s) > 3 AND RIGHT(@s, 3) = N' id' SET @s = LEFT(@s, LEN(@s) - 3);
    SET @s = LTRIM(RTRIM(@s));
    IF @s = N'' RETURN LTRIM(RTRIM(ISNULL(@field_name, N'')));
    RETURN UPPER(LEFT(@s, 1)) + SUBSTRING(@s, 2, 199);
END
GO
PRINT '500: fn_repo_field_label created.';
GO

-- =====================================================================
-- 4. sp_repository_change_display -- the readable detail of one change
-- =====================================================================
-- Reads the stored snapshots only. Lookups read the CURRENT name of the
-- referenced item, which is what the approver needs to recognise it.
-- A Changed row returns only the fields that actually differ, as the
-- page already did.
CREATE OR ALTER PROCEDURE grac_practice.sp_repository_change_display
    @organization_id BIGINT,
    @change_id       BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @change_id IS NULL
        THROW 53931, 'organizationId and changeId are required.', 1;

    DECLARE @copy_code NVARCHAR(40), @action NVARCHAR(20),
            @old NVARCHAR(MAX), @new NVARCHAR(MAX);
    SELECT @copy_code = c.copy_code,
           @action    = c.change_action,
           @old       = c.old_snapshot_json,
           @new       = c.new_snapshot_json
    FROM grac_practice.organization_repository_change c
    WHERE c.change_id = @change_id
      AND c.organization_id = @organization_id;

    IF @copy_code IS NULL
        THROW 53932, 'This repository update was not found for the organization.', 1;

    -- The copy row's own primary key is never worth showing.
    DECLARE @pk NVARCHAR(128);
    SELECT @pk = org_pk_column FROM grac_practice.repository_copy_config WHERE copy_code = @copy_code;

    CREATE TABLE #repo_change_fields(
        field_name NVARCHAR(128) NOT NULL PRIMARY KEY,
        old_value  NVARCHAR(MAX) NULL,
        new_value  NVARCHAR(MAX) NULL,
        old_type   INT NULL,
        new_type   INT NULL,
        old_text   NVARCHAR(400) NULL,
        new_text   NVARCHAR(400) NULL
    );

    -- OPENJSON without a schema: one row per property of the snapshot
    -- object. type 4 = array, 5 = object (the typed-detail columns).
    INSERT #repo_change_fields(field_name, old_value, new_value, old_type, new_type)
    SELECT COALESCE(o.[key], n.[key]), o.[value], n.[value], o.[type], n.[type]
    FROM (SELECT [key], [value], [type] FROM OPENJSON(ISNULL(@old, N'{}'))) o
    FULL OUTER JOIN (SELECT [key], [value], [type] FROM OPENJSON(ISNULL(@new, N'{}'))) n
        ON n.[key] = o.[key];

    DELETE f
    FROM #repo_change_fields f
    LEFT JOIN grac_practice.repository_change_field_config cf
           ON cf.field_name = f.field_name
    WHERE ISNULL(cf.is_hidden, 0) = 1
       OR f.field_name = @pk
       OR f.field_name LIKE N'org[_]%'
       OR f.field_name LIKE N'%[_]hash';

    -- Changed: only the fields that moved (NULL-safe comparison).
    IF @action = N'Changed'
        DELETE f FROM #repo_change_fields f
        WHERE NOT EXISTS (SELECT f.old_value EXCEPT SELECT f.new_value);

    -- Resolve the id columns, one statement per distinct lookup target.
    DECLARE @tbl NVARCHAR(256), @key NVARCHAR(128), @text NVARCHAR(MAX), @names NVARCHAR(MAX);
    DECLARE @sql NVARCHAR(MAX);
    DECLARE lookup_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT cf.lookup_table, cf.lookup_key, cf.lookup_text_sql,
               STRING_AGG(QUOTENAME(f.field_name, N''''), N',')
        FROM grac_practice.repository_change_field_config cf
        JOIN #repo_change_fields f ON f.field_name = cf.field_name
        WHERE cf.status = N'Active'
          AND cf.lookup_table IS NOT NULL
          AND cf.lookup_key   IS NOT NULL
          AND cf.lookup_text_sql IS NOT NULL
          AND ISNULL(cf.value_kind, N'') <> N'Json'
          AND OBJECT_ID(cf.lookup_table) IS NOT NULL
        GROUP BY cf.lookup_table, cf.lookup_key, cf.lookup_text_sql;

    OPEN lookup_cursor;
    FETCH NEXT FROM lookup_cursor INTO @tbl, @key, @text, @names;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'
UPDATE f
   SET old_text = CASE WHEN f.old_value IS NULL THEN NULL ELSE
           (SELECT TOP (1) LEFT(' + @text + N', 400) FROM ' + @tbl + N' x
             WHERE x.' + QUOTENAME(@key) + N' = TRY_CAST(f.old_value AS BIGINT)) END,
       new_text = CASE WHEN f.new_value IS NULL THEN NULL ELSE
           (SELECT TOP (1) LEFT(' + @text + N', 400) FROM ' + @tbl + N' x
             WHERE x.' + QUOTENAME(@key) + N' = TRY_CAST(f.new_value AS BIGINT)) END
FROM #repo_change_fields f
WHERE f.field_name IN (' + @names + N');';
        -- A lookup expression naming a column this database does not have
        -- must not break the whole detail view: that field keeps its id.
        BEGIN TRY
            EXEC sp_executesql @sql;
        END TRY
        BEGIN CATCH
        END CATCH
        FETCH NEXT FROM lookup_cursor INTO @tbl, @key, @text, @names;
    END
    CLOSE lookup_cursor;
    DEALLOCATE lookup_cursor;

    SELECT f.field_name AS FieldName,
           COALESCE(cf.display_label, grac_practice.fn_repo_field_label(f.field_name)) AS FieldLabel,
           COALESCE(cf.value_kind,
                    CASE WHEN f.old_type IN (4, 5) OR f.new_type IN (4, 5) THEN N'Json' END) AS ValueKind,
           f.old_value AS OldValue,
           f.new_value AS NewValue,
           f.old_text  AS OldText,
           f.new_text  AS NewText,
           ISNULL(cf.display_order, 500) AS DisplayOrder
    FROM #repo_change_fields f
    LEFT JOIN grac_practice.repository_change_field_config cf
           ON cf.field_name = f.field_name
    ORDER BY ISNULL(cf.display_order, 500), f.field_name;

    DROP TABLE #repo_change_fields;
END
GO
PRINT '500: sp_repository_change_display created.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '--- 500 verification ---';
SELECT CASE WHEN OBJECT_ID('grac_practice.repository_change_field_config','U') IS NULL
            THEN 'MISSING' ELSE 'ok' END AS field_config_table,
       CASE WHEN OBJECT_ID('grac_practice.fn_repo_field_label','FN') IS NULL
            THEN 'MISSING' ELSE 'ok' END AS label_function,
       CASE WHEN OBJECT_ID('grac_practice.sp_repository_change_display','P') IS NULL
            THEN 'MISSING' ELSE 'ok' END AS display_procedure;
SELECT status, COUNT(*) AS rows_seeded,
       SUM(CASE WHEN lookup_table IS NOT NULL THEN 1 ELSE 0 END) AS lookups
FROM grac_practice.repository_change_field_config
GROUP BY status;
SELECT field_name, lookup_table, lookup_key
FROM grac_practice.repository_change_field_config
WHERE status = N'Inactive'
ORDER BY field_name;
PRINT '500: done.';
GO
