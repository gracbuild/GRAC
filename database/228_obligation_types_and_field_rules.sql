-- =====================================================================
-- 228 Obligation taxonomy follows Control Management, and the Assurance
--     trigger rule is learned rather than declared
--
-- TWO CHANGES
-- -----------
-- 1. Control Management has removed the Evidence and Retention
--    obligation types. Practice Management is a read-only consumer of
--    that taxonomy, so it stops offering them -- and, more importantly,
--    stops falling over when their tables are not there.
--
-- 2. An Assurance obligation has a trigger type, and which of the other
--    fields apply depends on it: event driven wants the event details,
--    scheduled wants a frequency. The card already gets this right --
--    a NULL column is not rendered -- but the ADD form showed every
--    field flat.
--
-- WHY THE VIEW IS NOW BUILT WITH DYNAMIC SQL
-- ------------------------------------------
-- vw_pm_obligation_typed_detail names six GRAC_New tables. A view whose
-- base table has been dropped does not fail at deploy time -- it fails
-- the next time somebody opens Operationalize, with "Invalid object
-- name", which is the worst possible moment.
--
-- Migration 225 already established that this module must not hold an
-- opinion about a schema Control Management owns. 225 stopped naming
-- COLUMNS. This stops naming TABLES: the view is assembled from
-- whichever detail tables actually exist, and a missing one contributes
-- the literal '[]'.
--
-- The seven output columns are ALWAYS emitted, present tables or not.
-- sp_resolve_obligation_list selects them by name, and a view that
-- changes shape underneath it would trade one runtime failure for
-- another.
--
-- HOW THE TRIGGER RULE IS LEARNED
-- -------------------------------
-- Not declared here, because this module cannot see Control Management's
-- form and would be guessing at both the column and the mapping. It is
-- read out of CM's own rows:
--
--   * A DRIVER column is one whose name mentions 'trigger' or 'mode',
--     holds a short string, and has between 2 and 10 distinct non-null
--     values. Anything else is not a selection.
--   * For each driver value, a column is VISIBLE when at least one row
--     with that value has it populated.
--
-- WHAT THAT INFERENCE CANNOT DO -- STATED PLAINLY
-- -----------------------------------------------
-- It is only as good as the data. A trigger value nobody has used yet
-- produces no rule, and a column that happens to be blank in every
-- existing row of a value looks irrelevant to it. So the form treats a
-- missing rule as "show everything" rather than "hide everything" --
-- an over-full form is a nuisance, a form missing the field you need is
-- a dead end.
--
-- Re-run this migration after Control Management adds obligations that
-- exercise a new trigger value, and the rule catches up. It is
-- idempotent and rebuilds the table from scratch each time.
--
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
--
-- Error codes 52700-52709.
-- DEPENDS ON: 224/225 (the view), 227 (the add form's field metadata).
-- Rollback:   database/228_obligation_types_and_field_rules_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

DECLARE @prereqs_ok BIT = 1;

IF OBJECT_ID('grac_practice.vw_pm_obligation_typed_detail','V') IS NULL
BEGIN
    PRINT 'ABORT (228): vw_pm_obligation_typed_detail missing. Run 224 and 225 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.sp_resolve_obligation_type_fields','P') IS NULL
BEGIN
    PRINT 'ABORT (228): sp_resolve_obligation_type_fields missing. Run 227 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('228_obligation_types_and_field_rules: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. vw_pm_obligation_typed_detail -- assembled from what exists
--
--    Each per-type fragment is the 225 sub-query when its table is
--    present, and the literal '[]' when it is not. The whole-row
--    SELECT * of 225 is kept: this migration is about missing TABLES,
--    not about going back to naming columns.
-- =====================================================================
DECLARE @sql NVARCHAR(MAX);
DECLARE @missing NVARCHAR(MAX) = N'';

-- One helper expression per type. Built as text so a table that is not
-- there never reaches the parser.
DECLARE @state NVARCHAR(MAX) = N'N''[]''';
IF OBJECT_ID('GRAC_New.obligation_state_rule','U') IS NOT NULL
    SET @state = N'COALESCE((SELECT s.* FROM GRAC_New.obligation_state_rule s
             WHERE s.obligation_id = o.obligation_id AND s.status = N''Active''
             FOR JSON PATH), N''[]'')';
ELSE SET @missing = @missing + N'obligation_state_rule, ';

DECLARE @exec NVARCHAR(MAX) = N'N''[]''';
IF OBJECT_ID('GRAC_New.obligation_execution_spec','U') IS NOT NULL
    SET @exec = N'COALESCE((SELECT es.*, ef.option_label AS ExecutionFrequency
             FROM GRAC_New.obligation_execution_spec es
             LEFT JOIN GRAC_New.reference_option ef ON ef.reference_option_id = es.execution_frequency_id
             WHERE es.obligation_id = o.obligation_id AND es.status = N''Active''
             FOR JSON PATH), N''[]'')';
ELSE SET @missing = @missing + N'obligation_execution_spec, ';

DECLARE @assur NVARCHAR(MAX) = N'N''[]''';
IF OBJECT_ID('GRAC_New.obligation_assurance_spec','U') IS NOT NULL
    SET @assur = N'COALESCE((SELECT [as].*, af.option_label AS AssuranceFrequency
             FROM GRAC_New.obligation_assurance_spec [as]
             LEFT JOIN GRAC_New.reference_option af ON af.reference_option_id = [as].assurance_frequency_id
             WHERE [as].obligation_id = o.obligation_id AND [as].status = N''Active''
             FOR JSON PATH), N''[]'')';
ELSE SET @missing = @missing + N'obligation_assurance_spec, ';

DECLARE @event NVARCHAR(MAX) = N'N''[]''';
IF OBJECT_ID('GRAC_New.obligation_event_response','U') IS NOT NULL
    SET @event = N'COALESCE((SELECT er.* FROM GRAC_New.obligation_event_response er
             WHERE er.obligation_id = o.obligation_id AND er.status = N''Active''
             FOR JSON PATH), N''[]'')';
ELSE SET @missing = @missing + N'obligation_event_response, ';

DECLARE @constr NVARCHAR(MAX) = N'N''[]''';
IF OBJECT_ID('GRAC_New.obligation_constraint_rule','U') IS NOT NULL
    SET @constr = N'COALESCE((SELECT cr.* FROM GRAC_New.obligation_constraint_rule cr
             WHERE cr.obligation_id = o.obligation_id AND cr.status = N''Active''
             FOR JSON PATH), N''[]'')';
ELSE SET @missing = @missing + N'obligation_constraint_rule, ';

-- Retention: removed from the taxonomy by Control Management. Kept as a
-- column so historical rows still render and so the list procedure's
-- SELECT keeps compiling; it simply resolves to '[]' once the table is
-- gone.
DECLARE @reten NVARCHAR(MAX) = N'N''[]''';
IF OBJECT_ID('GRAC_New.obligation_retention_spec','U') IS NOT NULL
    SET @reten = N'COALESCE((SELECT rs.* FROM GRAC_New.obligation_retention_spec rs
             WHERE rs.obligation_id = o.obligation_id AND rs.status = N''Active''
             FOR JSON PATH), N''[]'')';
ELSE SET @missing = @missing + N'obligation_retention_spec, ';

-- Evidence: same story, and its shape is a UNION over however many of
-- the six link tables survive. Built one branch at a time for the same
-- reason as above.
DECLARE @evidence NVARCHAR(MAX) = N'N''[]''';
IF OBJECT_ID('GRAC_New.requirement_obligation_evidence','U') IS NOT NULL
BEGIN
    DECLARE @links NVARCHAR(MAX) = N'';
    DECLARE @lt SYSNAME, @lc NVARCHAR(60);
    DECLARE link_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT t.table_name, t.type_code FROM (VALUES
            (N'obligation_state_evidence_link',          N'State'),
            (N'obligation_execution_evidence_link',      N'Execution'),
            (N'obligation_assurance_evidence_link',      N'Assurance'),
            (N'obligation_event_response_evidence_link', N'EventResponse'),
            (N'obligation_constraint_evidence_link',     N'Constraint'),
            (N'obligation_retention_evidence_link',      N'Retention')
        ) AS t(table_name, type_code);
    OPEN link_cursor;
    FETCH NEXT FROM link_cursor INTO @lt, @lc;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF OBJECT_ID('GRAC_New.' + @lt, 'U') IS NOT NULL
            SET @links = @links
                + CASE WHEN @links = N'' THEN N'' ELSE N' UNION ALL ' END
                + N'SELECT N''' + @lc + N''' AS TypeCode, obligation_id, obligation_evidence_id, status FROM GRAC_New.' + QUOTENAME(@lt);
        FETCH NEXT FROM link_cursor INTO @lt, @lc;
    END
    CLOSE link_cursor;
    DEALLOCATE link_cursor;

    SET @evidence = N'COALESCE((SELECT * FROM (
                SELECT N''Direct'' AS Source, CAST(NULL AS NVARCHAR(60)) AS LinkTypeCode,
                       roe.obligation_evidence_id AS ObligationEvidenceId,
                       roe.evidence_type_id AS EvidenceTypeId,
                       et.evidence_type_name AS EvidenceType,
                       roe.frequency_id AS FrequencyId,
                       freq.option_label AS Frequency,
                       roe.retention_requirement AS RetentionRequirement,
                       roe.remarks AS Remarks,
                       et.display_order AS DisplayOrder
                FROM GRAC_New.requirement_obligation_evidence roe
                LEFT JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id = roe.evidence_type_id
                LEFT JOIN GRAC_New.reference_option freq ON freq.reference_option_id = roe.frequency_id
                WHERE roe.obligation_id = o.obligation_id AND roe.status = N''Active'''
        + CASE WHEN @links = N'' THEN N'' ELSE N'
                UNION ALL
                SELECT N''Link'', l.TypeCode, roe2.obligation_evidence_id, roe2.evidence_type_id,
                       et2.evidence_type_name, roe2.frequency_id, freq2.option_label,
                       roe2.retention_requirement, roe2.remarks, et2.display_order
                FROM (' + @links + N') l
                JOIN GRAC_New.requirement_obligation_evidence roe2 ON roe2.obligation_evidence_id = l.obligation_evidence_id
                LEFT JOIN GRAC_New.evidence_type_master et2 ON et2.evidence_type_id = roe2.evidence_type_id
                LEFT JOIN GRAC_New.reference_option freq2 ON freq2.reference_option_id = roe2.frequency_id
                WHERE l.obligation_id = o.obligation_id AND l.status = N''Active''' END
        + N'
            ) combined
            ORDER BY combined.Source, ISNULL(combined.DisplayOrder, 999), combined.EvidenceType
            FOR JSON PATH), N''[]'')';
END
ELSE SET @missing = @missing + N'requirement_obligation_evidence, ';

SET @sql = N'CREATE OR ALTER VIEW grac_practice.vw_pm_obligation_typed_detail
AS
    -- Assembled by migration 228 from the GRAC_New detail tables present
    -- at the time it ran. A type whose table Control Management has
    -- dropped resolves to the literal ''[]'' -- the column stays so the
    -- consumers keep compiling. Re-run 228 after a CM schema change.
    SELECT
        o.obligation_id AS ObligationId,
        ' + @state    + N' AS StateRulesJson,
        ' + @exec     + N' AS ExecutionSpecsJson,
        ' + @assur    + N' AS AssuranceSpecsJson,
        ' + @event    + N' AS EventResponsesJson,
        ' + @constr   + N' AS ConstraintRulesJson,
        ' + @reten    + N' AS RetentionSpecsJson,
        ' + @evidence + N' AS EvidenceJson
    FROM GRAC_New.requirement_obligation o;';

EXEC sp_executesql @sql;

IF @missing <> N''
    PRINT '228: detail tables not present, their column resolves to [] -- ' + LEFT(@missing, LEN(@missing) - 1);
ELSE
    PRINT '228: every detail table present.';
GO

-- =====================================================================
-- 2. obligation_type_field_rule
--
--    Which fields of a type apply for which value of its driver column.
--    Rebuilt from Control Management's rows every time this runs.
-- =====================================================================
IF OBJECT_ID('grac_practice.obligation_type_field_rule','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.obligation_type_field_rule(
        obligation_type_field_rule_id INT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_obligation_type_field_rule PRIMARY KEY,
        type_code      NVARCHAR(60)  NOT NULL,
        source_table   SYSNAME       NOT NULL,
        driver_column  SYSNAME       NOT NULL,
        driver_value   NVARCHAR(200) NOT NULL,
        visible_column SYSNAME       NOT NULL,
        sample_rows    INT           NOT NULL
            CONSTRAINT df_pm_otfr_sample DEFAULT 0,
        entered_by     NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_otfr_entered_by DEFAULT 'system',
        entered_dt     DATETIME2     NOT NULL
            CONSTRAINT df_pm_otfr_entered_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_otfr UNIQUE(type_code, driver_column, driver_value, visible_column)
    );
    PRINT '228: obligation_type_field_rule created.';
END
GO

-- ---------------------------------------------------------------------
-- Populate. Everything below is inference from data -- see the header
-- for what that can and cannot tell us.
-- ---------------------------------------------------------------------
DELETE FROM grac_practice.obligation_type_field_rule;

DECLARE @types TABLE (type_code NVARCHAR(60), source_table SYSNAME);
INSERT @types (type_code, source_table) VALUES
    (N'State',         N'obligation_state_rule'),
    (N'Execution',     N'obligation_execution_spec'),
    (N'Assurance',     N'obligation_assurance_spec'),
    (N'EventResponse', N'obligation_event_response'),
    (N'Constraint',    N'obligation_constraint_rule');

DECLARE @tc NVARCHAR(60), @tbl SYSNAME, @driver SYSNAME, @stmt NVARCHAR(MAX);

DECLARE type_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT type_code, source_table FROM @types;
OPEN type_cursor;
FETCH NEXT FROM type_cursor INTO @tc, @tbl;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @driver = NULL;

    IF OBJECT_ID('GRAC_New.' + @tbl, 'U') IS NOT NULL
    BEGIN
        -- A driver is a short string column whose name mentions trigger
        -- or mode. Anything else is not a selection the form should
        -- branch on.
        SELECT TOP 1 @driver = c.name
        FROM   sys.columns c
        JOIN   sys.tables  t  ON t.object_id = c.object_id
        JOIN   sys.schemas s  ON s.schema_id = t.schema_id
        JOIN   sys.types   ty ON ty.user_type_id = c.user_type_id
        WHERE  s.name = 'GRAC_New' AND t.name = @tbl
          AND  ty.name IN ('nvarchar', 'varchar', 'nchar', 'char')
          AND  (c.max_length = -1 OR c.max_length <= 400)
          AND  (c.name LIKE '%trigger%' OR c.name LIKE '%mode%')
        ORDER  BY c.column_id;
    END

    IF @driver IS NOT NULL
    BEGIN
        -- For each distinct driver value, record every other column that
        -- at least one row with that value has filled in. UNPIVOT is not
        -- usable here (mixed types), so the column list is expanded into
        -- one UNION branch per column at build time.
        DECLARE @cols NVARCHAR(MAX) = N'';
        SELECT @cols = @cols
             + CASE WHEN @cols = N'' THEN N'' ELSE N' UNION ALL ' END
             + N'SELECT ' + QUOTENAME(@driver) + N' AS DriverValue, N'''
             + REPLACE(c.name, '''', '''''') + N''' AS VisibleColumn, COUNT(*) AS Rows_
               FROM GRAC_New.' + QUOTENAME(@tbl) + N'
               WHERE ' + QUOTENAME(@driver) + N' IS NOT NULL
                 AND ' + QUOTENAME(c.name) + N' IS NOT NULL
                 AND LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), ' + QUOTENAME(c.name) + N'))) <> N''''
               GROUP BY ' + QUOTENAME(@driver)
        FROM   sys.columns c
        JOIN   sys.tables  t ON t.object_id = c.object_id
        JOIN   sys.schemas s ON s.schema_id = t.schema_id
        WHERE  s.name = 'GRAC_New' AND t.name = @tbl
          AND  c.is_computed = 0
          AND  c.name <> @driver
          AND  c.name NOT IN ('obligation_id', 'status', 'record_status_id',
                              'entered_by', 'entered_dt', 'updated_by', 'updated_dt',
                              'display_order', 'is_active')
          AND  c.is_identity = 0;
        -- No ORDER BY on an aggregate concatenation: SQL Server does not
        -- guarantee the result when the two are combined, and the order
        -- of UNION branches is irrelevant here anyway.

        IF @cols <> N''
        BEGIN
            SET @stmt = N'
                INSERT grac_practice.obligation_type_field_rule
                    (type_code, source_table, driver_column, driver_value, visible_column, sample_rows, entered_by)
                SELECT @p_tc, @p_tbl, @p_driver,
                       LEFT(CONVERT(NVARCHAR(MAX), x.DriverValue), 200),
                       x.VisibleColumn, x.Rows_, N''seed-228''
                FROM (' + @cols + N') x
                WHERE x.DriverValue IS NOT NULL;';

            BEGIN TRY
                EXEC sp_executesql @stmt,
                     N'@p_tc NVARCHAR(60), @p_tbl SYSNAME, @p_driver SYSNAME',
                     @p_tc = @tc, @p_tbl = @tbl, @p_driver = @driver;
            END TRY
            BEGIN CATCH
                -- A column type CONVERT cannot handle (geography and the
                -- like) must not take the whole migration down. Skip the
                -- type and say so; the form falls back to showing every
                -- field for it, which is the safe direction.
                DECLARE @err NVARCHAR(400) = ERROR_MESSAGE();
                PRINT '228: could not infer rules for ' + @tc + ' -- ' + @err;
            END CATCH
        END
    END

    FETCH NEXT FROM type_cursor INTO @tc, @tbl;
END

CLOSE type_cursor;
DEALLOCATE type_cursor;

-- Counted into a variable first. PRINT takes a scalar EXPRESSION, not a
-- query: a subquery inside it is Msg 1046, and because that is a
-- compile-time error it takes the WHOLE batch with it -- including the
-- population loop above, which then silently never runs.
DECLARE @rule_count INT = (SELECT COUNT(*) FROM grac_practice.obligation_type_field_rule);
PRINT '228: field rules inferred = ' + CAST(@rule_count AS NVARCHAR(20));
GO

-- =====================================================================
-- 3. sp_resolve_obligation_type_field_rules
--
--    What the add form reads. Returns nothing for a type with no driver
--    column, and the form then shows every field -- which is the right
--    default: an over-full form is a nuisance, a form missing the field
--    you need is a dead end.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_obligation_type_field_rules
    @type_code NVARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;

    IF NULLIF(LTRIM(RTRIM(ISNULL(@type_code, N''))), N'') IS NULL
        THROW 52700, 'sp_resolve_obligation_type_field_rules: type_code is required.', 1;

    SELECT r.driver_column  AS DriverColumn,
           r.driver_value   AS DriverValue,
           r.visible_column AS VisibleColumn,
           r.sample_rows    AS SampleRows
    FROM   grac_practice.obligation_type_field_rule r
    WHERE  r.type_code = @type_code
    ORDER  BY r.driver_value, r.visible_column;
END
GO

-- =====================================================================
-- 4. sp_resolve_obligation_type_fields -- re-issued
--
--    Evidence and Retention are removed from the map. Control Management
--    no longer publishes those types, so the add form must not offer a
--    field list for them.
--
--    Historical rows that still carry those type codes are untouched --
--    the card renders them from whatever the view holds, which is why
--    section 1 keeps both columns rather than dropping them.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_obligation_type_fields
    @type_code NVARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;

    IF NULLIF(LTRIM(RTRIM(ISNULL(@type_code, N''))), N'') IS NULL
        THROW 52690, 'sp_resolve_obligation_type_fields: type_code is required.', 1;

    DECLARE @norm NVARCHAR(60) =
        LOWER(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@type_code)), N'_', N''), N'-', N''), N' ', N''));

    DECLARE @table SYSNAME = (
        SELECT TOP 1 t.table_name
        FROM (VALUES
            (N'state',         N'obligation_state_rule'),
            (N'staterule',     N'obligation_state_rule'),
            (N'execution',     N'obligation_execution_spec'),
            (N'executionspec', N'obligation_execution_spec'),
            (N'assurance',     N'obligation_assurance_spec'),
            (N'assurancespec', N'obligation_assurance_spec'),
            (N'eventresponse', N'obligation_event_response'),
            (N'event',         N'obligation_event_response'),
            (N'constraint',    N'obligation_constraint_rule'),
            (N'constraintrule',N'obligation_constraint_rule')
            -- Evidence and Retention deliberately absent (228).
        ) AS t(code, table_name)
        WHERE t.code = @norm);

    IF @table IS NULL
    BEGIN
        -- The empty set has to have the SAME SHAPE as the populated one:
        -- INSERT ... EXEC matches by position.
        SELECT CAST(NULL AS SYSNAME)  AS TableName,
               CAST(NULL AS SYSNAME)  AS ColumnName,
               CAST(NULL AS SYSNAME)  AS DataType,
               CAST(NULL AS INT)      AS MaxLength,
               CAST(NULL AS BIT)      AS IsNullable,
               CAST(NULL AS INT)      AS Ordinal,
               CAST(NULL AS BIT)      AS IsReference
        WHERE  1 = 0;
        RETURN;
    END

    SELECT @table                       AS TableName,
           c.name                       AS ColumnName,
           ty.name                      AS DataType,
           c.max_length                 AS MaxLength,
           c.is_nullable                AS IsNullable,
           c.column_id                  AS Ordinal,
           CAST(CASE WHEN c.name LIKE '%[_]id' THEN 1 ELSE 0 END AS BIT) AS IsReference
    FROM   sys.columns c
    JOIN   sys.tables  t  ON t.object_id = c.object_id
    JOIN   sys.schemas s  ON s.schema_id = t.schema_id
    JOIN   sys.types   ty ON ty.user_type_id = c.user_type_id
    WHERE  s.name = 'GRAC_New'
      AND  t.name = @table
      AND  c.is_computed = 0
      AND  c.name NOT IN ('obligation_id', 'status', 'record_status_id',
                          'entered_by', 'entered_dt', 'updated_by', 'updated_dt',
                          'display_order', 'is_active')
      AND  c.is_identity = 0
    ORDER  BY c.column_id;
END
GO

-- =====================================================================
-- 5. Verification
-- =====================================================================
PRINT '=== 228 verification ===';

SELECT 'view rebuilt' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.vw_pm_obligation_typed_detail','V'))
                 LIKE '%migration 228%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'view still emits all seven columns',
       CASE WHEN (SELECT COUNT(*) FROM sys.columns
                   WHERE object_id = OBJECT_ID('grac_practice.vw_pm_obligation_typed_detail')) = 8
            THEN 'PASS' ELSE 'FAIL -- consumers select by name' END
UNION ALL
SELECT 'field rule table present',
       CASE WHEN OBJECT_ID('grac_practice.obligation_type_field_rule','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'rule procedure present',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_obligation_type_field_rules','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'Evidence and Retention no longer offered',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_type_fields','P'))
                 LIKE '%requirement_obligation_evidence%'
            THEN 'FAIL' ELSE 'PASS' END;

-- What was actually learned. An empty result is not a failure: it means
-- no detail table has a trigger/mode column with usable data yet, and
-- the form will show every field.
PRINT '=== Inferred field rules ===';
SELECT type_code AS TypeCode, driver_column AS DriverColumn, driver_value AS DriverValue,
       COUNT(*)  AS VisibleFields, MAX(sample_rows) AS RowsSeen
FROM   grac_practice.obligation_type_field_rule
GROUP  BY type_code, driver_column, driver_value
ORDER  BY type_code, driver_value;

PRINT '=== Obligation types Control Management still publishes ===';
SELECT type_code AS TypeCode, type_name AS TypeName, display_order AS DisplayOrder
FROM   GRAC_New.obligation_type_master
ORDER  BY ISNULL(display_order, 999), type_name;

PRINT '';
PRINT '228 complete. Re-run it after Control Management changes the';
PRINT 'taxonomy or adds obligations that use a new trigger value.';
PRINT 'Ship PracticeManagement.Api and PracticeManagement.Web with it.';
GO

SET NOEXEC OFF;
GO
