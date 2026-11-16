-- =====================================================================
-- 557  Engagement and execution with id 0 -- renumber them
--
-- SYMPTOM (2026-11-14, sir)
--   My Audits: the 3-dot of an In-progress audit said "No actions
--   available". GET my-audits returned planItemId 0 and executionId 0: the
--   first engagement (org_assurance_plan_item) and the first execution
--   (org_assurance_execution) of the database were stored with id 0 --
--   the cause 550 describes (a table that never had a row, reseeded to 0
--   by 192 before 550's fix, gives its FIRST insert the id 0). Screens
--   treat 0 as "no id".
--
-- WHAT THIS DOES
--   1. Reports every grac_practice identity table with an id-0 row.
--   2. For org_assurance_plan_item, org_assurance_execution and
--      org_assurance_observation (added the same evening): an id-0
--      row is moved to the next free id, in ONE transaction per table:
--        * every reference is found -- each foreign key that points at the
--          table, and each column of the same name elsewhere in
--          grac_practice (soft references with no foreign key, e.g.
--          org_assurance_scope_resolution.execution_id for executions,
--          custom_gap_observation.org_assurance_observation_id for
--          observations -- org_assurance_..._id names in any table, the
--          generic execution_id only in org_assurance_* tables);
--        * those foreign keys are paused (NOCHECK), the row is copied out,
--          deleted, inserted again with the new id (IDENTITY_INSERT) --
--          so unique codes never clash --, every reference is repointed,
--          and the foreign keys are switched back on (re-validated when
--          they were trusted before);
--        * the identity is reseeded to the highest id.
--   3. Empty identity tables reseeded to 1 -- those at 0 AND those that
--      have never had a row (last_value NULL): a never-used table that 192
--      reseeded to 0 can still report NULL and give its first row 0 (the
--      observation table did). RESEED 1 on an empty table is always safe:
--      its next row is 1 (never used) or 2.
--   A failure rolls the table's move back; nothing half-done.
-- Re-runnable (a second run finds nothing to do). ASCII-only.
-- Rollback: none -- the renumbered rows are the same rows.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.org_assurance_plan_item','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_execution','U') IS NULL
BEGIN
    PRINT 'ABORT (557): audit plan / execution tables missing. Nothing was changed.';
    RAISERROR('557_audit_zero_id_repair: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Report: identity tables holding an id-0 row (before)
-- =====================================================================
DECLARE @rep NVARCHAR(MAX) = N'';
SELECT @rep = @rep
     + CASE WHEN @rep = N'' THEN N'' ELSE N' UNION ALL ' END
     + N'SELECT N''' + t.name + N''' AS TableName, COUNT(*) AS ZeroIdRows FROM grac_practice.'
     + QUOTENAME(t.name) + N' WHERE ' + QUOTENAME(ic.name) + N' = 0 HAVING COUNT(*) > 0'
  FROM sys.identity_columns ic
  JOIN sys.tables t ON t.object_id = ic.object_id
 WHERE SCHEMA_NAME(t.schema_id) = N'grac_practice';
PRINT '=== 557.1 tables with an id-0 row (before repair) ===';
IF @rep <> N'' EXEC sp_executesql @rep;
GO

-- =====================================================================
-- 2. Move an id-0 row of each table to a new id
--    @targets: table, its id column, and the column names that refer to
--    it without a foreign key (comma list).
-- =====================================================================
DECLARE @targets TABLE (ord INT PRIMARY KEY, tbl SYSNAME, idcol SYSNAME, softcols NVARCHAR(400));
INSERT INTO @targets VALUES
    (1, N'org_assurance_plan_item', N'org_assurance_plan_item_id', N'org_assurance_plan_item_id'),
    (2, N'org_assurance_execution', N'org_assurance_execution_id', N'org_assurance_execution_id,execution_id'),
    -- added 2026-11-14 (Observations: "Failed to load observation: HTTP 404"
    -- -- the first finding raised from an answer got id 0)
    (3, N'org_assurance_observation', N'org_assurance_observation_id', N'org_assurance_observation_id');

DECLARE @ord INT = 1, @tbl SYSNAME, @idcol SYSNAME, @soft NVARCHAR(400),
        @obj INT, @new BIGINT, @cols NVARCHAR(MAX), @refs NVARCHAR(MAX), @off NVARCHAR(MAX),
        @on NVARCHAR(MAX), @sql NVARCHAR(MAX), @q NVARCHAR(MAX), @has BIT;

WHILE @ord <= (SELECT MAX(ord) FROM @targets)
BEGIN
    SELECT @tbl = tbl, @idcol = idcol, @soft = softcols FROM @targets WHERE ord = @ord;
    SET @obj = OBJECT_ID(N'grac_practice.' + @tbl);

    SET @q = N'SELECT @h = CASE WHEN EXISTS (SELECT 1 FROM grac_practice.' + QUOTENAME(@tbl)
           + N' WHERE ' + QUOTENAME(@idcol) + N' = 0) THEN 1 ELSE 0 END,'
           + N' @m = ISNULL(MAX(' + QUOTENAME(@idcol) + N'), 0) + 1 FROM grac_practice.' + QUOTENAME(@tbl) + N';';
    EXEC sp_executesql @q, N'@h BIT OUTPUT, @m BIGINT OUTPUT', @h = @has OUTPUT, @m = @new OUTPUT;

    IF @has = 0
        PRINT '557.2: ' + @tbl + ' -- no id-0 row.';
    ELSE
    BEGIN
        -- the columns copied (not the identity, not computed)
        SELECT @cols = STRING_AGG(QUOTENAME(c.name), N', ') WITHIN GROUP (ORDER BY c.column_id)
          FROM sys.columns c
         WHERE c.object_id = @obj AND c.is_identity = 0 AND c.is_computed = 0;

        -- references: foreign key columns pointing at the table, plus
        -- same-named columns elsewhere in grac_practice (soft references)
        ;WITH r AS (
            SELECT fk.parent_object_id AS obj, pc.name AS col
              FROM sys.foreign_keys fk
              JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
              JOIN sys.columns pc ON pc.object_id = fk.parent_object_id AND pc.column_id = fkc.parent_column_id
             WHERE fk.referenced_object_id = @obj
            UNION
            SELECT c.object_id, c.name
              FROM sys.columns c
              JOIN sys.tables t ON t.object_id = c.object_id
             WHERE SCHEMA_NAME(t.schema_id) = N'grac_practice'
               -- a specific org_assurance_..._id column in any table (e.g.
               -- custom_gap_observation); the generic "execution_id" only in
               -- the audit tables
               AND (c.name LIKE N'org[_]assurance[_]%' OR t.name LIKE N'org[_]assurance[_]%')
               AND c.object_id <> @obj
               AND c.is_computed = 0
               AND c.name IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@soft, N','))
        )
        SELECT @refs = STRING_AGG(CONVERT(NVARCHAR(MAX),
                   N'UPDATE ' + QUOTENAME(OBJECT_SCHEMA_NAME(obj)) + N'.' + QUOTENAME(OBJECT_NAME(obj))
                 + N' SET ' + QUOTENAME(col) + N' = @n WHERE ' + QUOTENAME(col) + N' = 0;'), CHAR(10))
          FROM r;

        -- pause / restore the foreign keys that point at the table
        SELECT @off = STRING_AGG(CONVERT(NVARCHAR(MAX),
                   N'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + N'.'
                 + QUOTENAME(OBJECT_NAME(fk.parent_object_id)) + N' NOCHECK CONSTRAINT ' + QUOTENAME(fk.name) + N';'), CHAR(10)),
               @on  = STRING_AGG(CONVERT(NVARCHAR(MAX),
                   N'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + N'.'
                 + QUOTENAME(OBJECT_NAME(fk.parent_object_id))
                 + CASE WHEN fk.is_not_trusted = 0 THEN N' WITH CHECK' ELSE N'' END
                 + N' CHECK CONSTRAINT ' + QUOTENAME(fk.name) + N';'), CHAR(10))
          FROM sys.foreign_keys fk
         WHERE fk.referenced_object_id = @obj AND fk.is_disabled = 0;

        PRINT '557.2: ' + @tbl + ' id 0 -> ' + CAST(@new AS NVARCHAR(20));
        PRINT '557.2: references:' + CHAR(10) + ISNULL(@refs, N'(none)');

        SET @sql = ISNULL(@off, N'') + CHAR(10)
                 + N'SELECT ' + @cols + N' INTO #row557 FROM grac_practice.' + QUOTENAME(@tbl)
                 + N' WHERE ' + QUOTENAME(@idcol) + N' = 0;' + CHAR(10)
                 + N'DELETE FROM grac_practice.' + QUOTENAME(@tbl) + N' WHERE ' + QUOTENAME(@idcol) + N' = 0;' + CHAR(10)
                 + N'SET IDENTITY_INSERT grac_practice.' + QUOTENAME(@tbl) + N' ON;' + CHAR(10)
                 + N'INSERT INTO grac_practice.' + QUOTENAME(@tbl) + N' (' + QUOTENAME(@idcol) + N', ' + @cols + N')'
                 + N' SELECT @n, ' + @cols + N' FROM #row557;' + CHAR(10)
                 + N'SET IDENTITY_INSERT grac_practice.' + QUOTENAME(@tbl) + N' OFF;' + CHAR(10)
                 + ISNULL(@refs, N'') + CHAR(10)
                 + ISNULL(@on, N'') + CHAR(10)
                 + N'DROP TABLE #row557;';

        BEGIN TRAN;
            EXEC sp_executesql @sql, N'@n BIGINT', @n = @new;
        COMMIT;

        SET @q = N'DBCC CHECKIDENT (''grac_practice.' + @tbl + N''', RESEED) WITH NO_INFOMSGS;';
        EXEC sp_executesql @q;
        PRINT '557.2: ' + @tbl + ' renumbered.';
    END
    SET @ord += 1;
END
GO

-- =====================================================================
-- 3. Empty tables reseeded to 0 -> 1 (550 step 3, again)
-- =====================================================================
DECLARE @t SYSNAME, @n INT = 0, @q NVARCHAR(MAX), @rows BIGINT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT t.name
      FROM sys.identity_columns ic
      JOIN sys.tables t ON t.object_id = ic.object_id
     WHERE SCHEMA_NAME(t.schema_id) = N'grac_practice'
       AND (ic.last_value IS NULL OR CONVERT(BIGINT, ic.last_value) = 0)
     ORDER BY t.name;
OPEN c; FETCH NEXT FROM c INTO @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @q = N'SELECT @r = COUNT_BIG(1) FROM grac_practice.' + QUOTENAME(@t) + N';';
    EXEC sp_executesql @q, N'@r BIGINT OUTPUT', @r = @rows OUTPUT;
    IF @rows = 0
    BEGIN
        SET @q = N'DBCC CHECKIDENT (''grac_practice.' + @t + N''', RESEED, 1) WITH NO_INFOMSGS;';
        EXEC sp_executesql @q;
        SET @n += 1;
    END
    FETCH NEXT FROM c INTO @t;
END
CLOSE c; DEALLOCATE c;
PRINT '557.3: empty tables reseeded to 1 = ' + CAST(@n AS NVARCHAR(20));
GO

-- =====================================================================
-- Verification (and the report again: anything still at 0)
-- =====================================================================
SELECT '557 no engagement / execution / observation with id 0' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan_item WHERE org_assurance_plan_item_id = 0)
             AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution WHERE org_assurance_execution_id = 0)
             AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_observation WHERE org_assurance_observation_id = 0)
            THEN 'PASS' ELSE 'FAIL' END AS Result_;

DECLARE @rep NVARCHAR(MAX) = N'';
SELECT @rep = @rep
     + CASE WHEN @rep = N'' THEN N'' ELSE N' UNION ALL ' END
     + N'SELECT N''' + t.name + N''' AS TableName, COUNT(*) AS ZeroIdRows FROM grac_practice.'
     + QUOTENAME(t.name) + N' WHERE ' + QUOTENAME(ic.name) + N' = 0 HAVING COUNT(*) > 0'
  FROM sys.identity_columns ic
  JOIN sys.tables t ON t.object_id = ic.object_id
 WHERE SCHEMA_NAME(t.schema_id) = N'grac_practice';
PRINT '=== 557 tables still with an id-0 row (after) ===';
IF @rep <> N'' EXEC sp_executesql @rep;
PRINT '557 complete. No Api restart needed; reload My Audits / Observations.';
GO
SET NOEXEC OFF;
GO
