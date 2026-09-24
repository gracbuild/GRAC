-- =====================================================================
-- 229 The driver's value list, not just the values that had rules
--
-- WHAT 228 GOT WRONG
-- ------------------
-- 228 learned the Assurance trigger rule from Control Management's rows
-- and found exactly one:
--
--     Assurance | trigger_mode | EventDriven | 6 fields | 3 rows seen
--
-- That is correct -- three obligations exist and all three are event
-- driven. The mistake was on the other side of the wire: the add form
-- built its trigger dropdown from the values that HAD rules, so it
-- offered EventDriven and nothing else. A user who wanted a scheduled
-- assurance obligation had no way to say so.
--
-- The inference told the truth ("this is what the data shows") and the
-- form read it as the whole truth ("this is what exists"). Those are
-- different claims, and only the first one was ever justified.
--
-- WHAT THIS ADDS
-- --------------
--   1. A marker row per distinct driver value, so a value with no
--      populated companion columns is still a value the form can offer.
--      visible_column = N'' means "this value exists; nothing learned
--      about which fields it governs".
--   2. Values read from the column's CHECK constraint, when it has one.
--      A constraint lists what is ALLOWED, which is exactly the question
--      the data cannot answer -- it only shows what has been USED.
--   3. sp_resolve_obligation_type_field_rules returns the value list as
--      a second result set, so the form stops inferring it from rules.
--
-- The inference moves into grac_practice.sp_pm_infer_obligation_field_rules
-- so it can be re-run on its own -- after Control Management adds a
-- scheduled obligation, say -- without re-running a migration. 228's
-- inline block is superseded; re-running 228 afterwards is harmless but
-- would leave the marker rows out again, so call the procedure instead.
--
-- STILL NOT GUESSED
-- -----------------
-- If neither the data nor a CHECK constraint yields more than one value,
-- the form falls back to a free-text box rather than a one-item dropdown.
-- Better to let somebody type 'Scheduled' than to pretend it does not
-- exist.
--
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
--
-- Idempotent: rebuilds the rule table from scratch on every run.
--
-- Error codes 52700-52709 (shared with 228).
-- DEPENDS ON: 228.
-- Rollback:   database/229_obligation_driver_values_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

IF OBJECT_ID('grac_practice.obligation_type_field_rule','U') IS NULL
BEGIN
    PRINT 'ABORT (229): obligation_type_field_rule missing. Run 228 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_pm_infer_obligation_field_rules
--
--    228's inline population, made callable and extended with the two
--    sources of driver VALUES. Re-run it whenever Control Management's
--    obligation data changes; it truncates and rebuilds.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_pm_infer_obligation_field_rules
AS
BEGIN
    SET NOCOUNT ON;

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

        IF @driver IS NOT NULL
        BEGIN
            -- ---- 1a. Every distinct value the data uses, whether or not
            --          anything can be learned about it.
            SET @stmt = N'
                INSERT grac_practice.obligation_type_field_rule
                    (type_code, source_table, driver_column, driver_value, visible_column, sample_rows, entered_by)
                SELECT @p_tc, @p_tbl, @p_driver,
                       LEFT(CONVERT(NVARCHAR(MAX), d.' + QUOTENAME(@driver) + N'), 200),
                       N'''', COUNT(*), N''infer-229''
                FROM   GRAC_New.' + QUOTENAME(@tbl) + N' d
                WHERE  d.' + QUOTENAME(@driver) + N' IS NOT NULL
                  AND  LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), d.' + QUOTENAME(@driver) + N'))) <> N''''
                GROUP  BY d.' + QUOTENAME(@driver) + N';';

            BEGIN TRY
                EXEC sp_executesql @stmt,
                     N'@p_tc NVARCHAR(60), @p_tbl SYSNAME, @p_driver SYSNAME',
                     @p_tc = @tc, @p_tbl = @tbl, @p_driver = @driver;
            END TRY
            BEGIN CATCH
                DECLARE @e1 NVARCHAR(400) = ERROR_MESSAGE();
                PRINT '229: could not read driver values for ' + @tc + ' -- ' + @e1;
            END CATCH

            -- ---- 1b. Values the column ALLOWS, from its CHECK
            --          constraint. The data says what has been used; a
            --          constraint says what may be. Only the second can
            --          offer a value nobody has chosen yet.
            --
            --          The definition is parsed for quoted literals --
            --          crude, but a CHECK is either a simple IN / OR list
            --          (in which case this is exact) or something this
            --          has no business interpreting (in which case it
            --          finds nothing and no harm is done).
            DECLARE @check_def NVARCHAR(MAX) = (
                SELECT TOP 1 cc.definition
                FROM   sys.check_constraints cc
                JOIN   sys.columns c ON c.object_id = cc.parent_object_id
                                    AND c.column_id = cc.parent_column_id
                JOIN   sys.tables  t ON t.object_id = cc.parent_object_id
                JOIN   sys.schemas s ON s.schema_id = t.schema_id
                WHERE  s.name = 'GRAC_New' AND t.name = @tbl AND c.name = @driver);

            IF @check_def IS NOT NULL
            BEGIN
                DECLARE @pos INT = 1, @open INT, @close INT, @lit NVARCHAR(200);
                WHILE 1 = 1
                BEGIN
                    SET @open = CHARINDEX(N'''', @check_def, @pos);
                    IF @open = 0 BREAK;
                    SET @close = CHARINDEX(N'''', @check_def, @open + 1);
                    IF @close = 0 BREAK;
                    SET @lit = SUBSTRING(@check_def, @open + 1, @close - @open - 1);
                    SET @pos = @close + 1;

                    IF NULLIF(LTRIM(RTRIM(@lit)), N'') IS NOT NULL
                       AND NOT EXISTS (SELECT 1 FROM grac_practice.obligation_type_field_rule r
                                        WHERE r.type_code     = @tc
                                          AND r.driver_column = @driver
                                          AND r.driver_value  = @lit
                                          AND r.visible_column = N'')
                        INSERT grac_practice.obligation_type_field_rule
                            (type_code, source_table, driver_column, driver_value, visible_column, sample_rows, entered_by)
                        VALUES (@tc, @tbl, @driver, @lit, N'', 0, N'check-229');
                END
            END

            -- ---- 1c. Which columns each value actually governs. This is
            --          228's inference, unchanged.
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

            IF @cols <> N''
            BEGIN
                SET @stmt = N'
                    INSERT grac_practice.obligation_type_field_rule
                        (type_code, source_table, driver_column, driver_value, visible_column, sample_rows, entered_by)
                    SELECT @p_tc, @p_tbl, @p_driver,
                           LEFT(CONVERT(NVARCHAR(MAX), x.DriverValue), 200),
                           x.VisibleColumn, x.Rows_, N''infer-229''
                    FROM (' + @cols + N') x
                    WHERE x.DriverValue IS NOT NULL;';

                BEGIN TRY
                    EXEC sp_executesql @stmt,
                         N'@p_tc NVARCHAR(60), @p_tbl SYSNAME, @p_driver SYSNAME',
                         @p_tc = @tc, @p_tbl = @tbl, @p_driver = @driver;
                END TRY
                BEGIN CATCH
                    DECLARE @e2 NVARCHAR(400) = ERROR_MESSAGE();
                    PRINT '229: could not infer rules for ' + @tc + ' -- ' + @e2;
                END CATCH
            END
        END

        FETCH NEXT FROM type_cursor INTO @tc, @tbl;
    END

    CLOSE type_cursor;
    DEALLOCATE type_cursor;
END
GO

-- =====================================================================
-- 2. sp_resolve_obligation_type_field_rules -- re-issued
--
--    Two result sets now:
--      1. the rules      (visible_column <> '')
--      2. the driver's known values, and whether each carries a rule
--
--    The form reads the second for its dropdown. It used to derive that
--    list from the first, which is how it ended up offering exactly the
--    one value the data happened to contain.
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
      AND  r.visible_column <> N''
    ORDER  BY r.driver_value, r.visible_column;

    SELECT r.driver_column AS DriverColumn,
           r.driver_value  AS DriverValue,
           MAX(r.sample_rows) AS SampleRows,
           -- A value with no rule is offered all the same; the form then
           -- shows every field for it, which is the safe direction.
           CAST(CASE WHEN EXISTS (
                    SELECT 1 FROM grac_practice.obligation_type_field_rule r2
                    WHERE r2.type_code      = r.type_code
                      AND r2.driver_column  = r.driver_column
                      AND r2.driver_value   = r.driver_value
                      AND r2.visible_column <> N'')
                THEN 1 ELSE 0 END AS BIT) AS HasRule
    FROM   grac_practice.obligation_type_field_rule r
    WHERE  r.type_code = @type_code
    GROUP  BY r.type_code, r.driver_column, r.driver_value
    ORDER  BY r.driver_value;
END
GO

-- =====================================================================
-- 3. Run it.
-- =====================================================================
EXEC grac_practice.sp_pm_infer_obligation_field_rules;

DECLARE @rules  INT = (SELECT COUNT(*) FROM grac_practice.obligation_type_field_rule WHERE visible_column <> N'');
DECLARE @values INT = (SELECT COUNT(*) FROM grac_practice.obligation_type_field_rule WHERE visible_column  = N'');
PRINT '229: field rules = ' + CAST(@rules AS NVARCHAR(20))
    + ', driver values = ' + CAST(@values AS NVARCHAR(20));
GO

-- =====================================================================
-- 4. Verification
-- =====================================================================
PRINT '=== 229 verification ===';

SELECT 'inference procedure present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_pm_infer_obligation_field_rules','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'rules procedure returns two result sets',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_type_field_rules','P'))
                 LIKE '%HasRule%'
            THEN 'PASS' ELSE 'FAIL' END;

-- The list the form will now offer. A value with HasRule = 0 is one
-- nothing has been learned about -- it is still offered, and every field
-- shows for it.
PRINT '=== Driver values the form will offer ===';
SELECT r.type_code     AS TypeCode,
       r.driver_column AS DriverColumn,
       r.driver_value  AS DriverValue,
       MAX(r.sample_rows) AS RowsSeen,
       MAX(CASE WHEN r.visible_column <> N'' THEN 1 ELSE 0 END) AS HasRule,
       MAX(r.entered_by)  AS LearnedFrom
FROM   grac_practice.obligation_type_field_rule r
GROUP  BY r.type_code, r.driver_column, r.driver_value
ORDER  BY r.type_code, r.driver_value;

PRINT '';
PRINT 'IF A VALUE IS STILL MISSING';
PRINT '---------------------------';
PRINT 'Neither the data nor a CHECK constraint knows about it. The add';
PRINT 'form falls back to a free-text box when it has fewer than two';
PRINT 'values, so the obligation can still be created -- and once one';
PRINT 'exists in Control Management, EXEC';
PRINT 'grac_practice.sp_pm_infer_obligation_field_rules and it appears.';
PRINT '';
PRINT '229 complete. Ship PracticeManagement.Web with it -- no Api change.';
GO

SET NOEXEC OFF;
GO
