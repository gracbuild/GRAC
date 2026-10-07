-- =====================================================================
-- tool_demo_db_02_keep_orgs.sql  --  step 2 of 2: keep two organizations
--
-- Run INSIDE grac_new_demo (the copy made by tool_demo_db_01_clone.sql).
-- It deletes every organization's data EXCEPT the ones in
-- @KeepOrganizationIds (default '1,9' = MSP and SD). Nothing else changes:
--   * schema, procedures, views, functions, triggers, security policy:
--     untouched (rows only);
--   * schema GRAC_New (Control Management / repository): never touched;
--   * master / global tables: kept -- a row is deleted only if it carries
--     an organization_id of another organization, or (below) it depended on
--     a row that was deleted. Global rows (organization_id NULL) stay.
--
-- HOW (no hand-written table list, so tables added later are covered)
--   A. Every table outside GRAC_New that has an organization_id column:
--      DELETE rows whose organization_id is set and not kept.
--   B. Cascade: rows left pointing at a deleted row are deleted too, FK by
--      FK, pass after pass until a pass deletes nothing. Only foreign keys
--      that were ENABLED and TRUSTED are followed -- for those SQL Server
--      guarantees there were no orphans before, so every orphan found was
--      made by step A and belongs to a removed organization (its practice
--      instance obligations, task children, history rows, ...).
--   To allow A before B, those foreign keys are switched off for the
--   duration and switched back on WITH CHECK at the end -- which proves the
--   result is consistent; if it is not, the whole run rolls back.
--   Triggers on the affected tables (e.g. the append-only audit triggers
--   that refuse DELETE) are disabled and re-enabled the same way. All of it
--   runs in ONE transaction.
--
-- SAFETY
--   * Refuses to run in any database but @TargetDatabase (grac_new_demo) --
--     it can never be run against UAT by mistake.
--   * @DryRun = 1 (default): does everything, prints what it deleted per
--     table, then ROLLS BACK. Set @DryRun = 0 and @ConfirmDatabase =
--     'grac_new_demo' to keep the result.
--   * Every kept organization id must exist, or it stops.
--
-- NOTES
--   * A FK from GRAC_New into the module's tables that would be left
--     dangling stops the run (nothing is deleted in GRAC_New).
--   * Untrusted / disabled FKs are not followed; they are listed at the end
--     with their orphan counts, so nothing is hidden.
--   * Large deletes grow the log; the demo DB is a copy, so set it to
--     SIMPLE recovery first if space is tight (ALTER DATABASE ... SET
--     RECOVERY SIMPLE).
-- ASCII-only. Single batch. Requires SQL Server 2017+ (STRING_SPLIT, STRING_AGG).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @KeepOrganizationIds NVARCHAR(400) = N'1,9';   -- MSP, SD
DECLARE @TargetDatabase      SYSNAME       = N'grac_new_demo';
DECLARE @DryRun              BIT           = 1;
DECLARE @ConfirmDatabase     SYSNAME       = N'';      -- type grac_new_demo when @DryRun = 0

DECLARE @CurrentDatabase SYSNAME = DB_NAME();   -- RAISERROR takes variables, not function calls
IF @CurrentDatabase <> @TargetDatabase
BEGIN
    RAISERROR('This script only runs in %s. Current database is %s -- nothing done.', 16, 1, @TargetDatabase, @CurrentDatabase) WITH NOWAIT;
    RETURN;
END
IF @DryRun = 0 AND ISNULL(@ConfirmDatabase, N'') <> DB_NAME()
BEGIN
    RAISERROR('@DryRun = 0 needs @ConfirmDatabase = ''%s''. Nothing done.', 16, 1, @TargetDatabase) WITH NOWAIT;
    RETURN;
END

DECLARE @keep TABLE (organization_id BIGINT PRIMARY KEY);
INSERT @keep (organization_id)
SELECT DISTINCT TRY_CONVERT(BIGINT, LTRIM(RTRIM(value)))
  FROM STRING_SPLIT(@KeepOrganizationIds, N',')
 WHERE TRY_CONVERT(BIGINT, LTRIM(RTRIM(value))) IS NOT NULL;

IF NOT EXISTS (SELECT 1 FROM @keep)
BEGIN
    RAISERROR('@KeepOrganizationIds has no valid id. Nothing done.', 16, 1) WITH NOWAIT;
    RETURN;
END
IF EXISTS (SELECT 1 FROM @keep k WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization o WHERE o.organization_id = k.organization_id))
BEGIN
    SELECT k.organization_id AS MissingOrganizationId FROM @keep k
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization o WHERE o.organization_id = k.organization_id);
    RAISERROR('A kept organization id does not exist in grac_practice.organization. Nothing done.', 16, 1) WITH NOWAIT;
    RETURN;
END

PRINT '=== Organizations kept ===';
SELECT o.organization_id, o.organization_code, o.organization_name
  FROM grac_practice.organization o JOIN @keep k ON k.organization_id = o.organization_id
 ORDER BY o.organization_id;

-- Keep list as a literal for the dynamic statements below (ids only).
DECLARE @keepList NVARCHAR(MAX) = (SELECT STRING_AGG(CONVERT(NVARCHAR(30), organization_id), N',') FROM @keep);

/* ------------------------------------------------------------------ */
/* Scope: user tables outside GRAC_New                                 */
/* ------------------------------------------------------------------ */
IF OBJECT_ID('tempdb..#scope') IS NOT NULL DROP TABLE #scope;
CREATE TABLE #scope (object_id INT PRIMARY KEY, qname NVARCHAR(400) NOT NULL, has_org BIT NOT NULL);
INSERT #scope (object_id, qname, has_org)
SELECT t.object_id, QUOTENAME(s.name) + N'.' + QUOTENAME(t.name),
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND c.name = N'organization_id') THEN 1 ELSE 0 END
  FROM sys.tables t
  JOIN sys.schemas s ON s.schema_id = t.schema_id
 WHERE t.is_ms_shipped = 0
   AND LOWER(s.name) <> N'grac_new';

-- Foreign keys touching the scope.
IF OBJECT_ID('tempdb..#fk') IS NOT NULL DROP TABLE #fk;
CREATE TABLE #fk (
    fk_id INT PRIMARY KEY, fk_name SYSNAME NOT NULL,
    child_id INT NOT NULL, child_q NVARCHAR(400) NOT NULL,
    parent_id INT NOT NULL, parent_q NVARCHAR(400) NOT NULL,
    child_in_scope BIT NOT NULL, was_trusted BIT NOT NULL,
    match_sql NVARCHAR(MAX) NULL, notnull_sql NVARCHAR(MAX) NULL);
INSERT #fk (fk_id, fk_name, child_id, child_q, parent_id, parent_q, child_in_scope, was_trusted)
SELECT f.object_id, f.name,
       f.parent_object_id, QUOTENAME(SCHEMA_NAME(ct.schema_id)) + N'.' + QUOTENAME(ct.name),
       f.referenced_object_id, QUOTENAME(SCHEMA_NAME(pt.schema_id)) + N'.' + QUOTENAME(pt.name),
       CASE WHEN EXISTS (SELECT 1 FROM #scope x WHERE x.object_id = f.parent_object_id) THEN 1 ELSE 0 END,
       CASE WHEN f.is_not_trusted = 0 THEN 1 ELSE 0 END
  FROM sys.foreign_keys f
  JOIN sys.tables ct ON ct.object_id = f.parent_object_id
  JOIN sys.tables pt ON pt.object_id = f.referenced_object_id
 WHERE f.is_disabled = 0
   AND EXISTS (SELECT 1 FROM #scope x WHERE x.object_id = f.referenced_object_id);

UPDATE f SET
    match_sql = (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), N'p.' + QUOTENAME(pc.name) + N' = c.' + QUOTENAME(cc.name)), N' AND ')
                   FROM sys.foreign_key_columns k
                   JOIN sys.columns cc ON cc.object_id = k.parent_object_id AND cc.column_id = k.parent_column_id
                   JOIN sys.columns pc ON pc.object_id = k.referenced_object_id AND pc.column_id = k.referenced_column_id
                  WHERE k.constraint_object_id = f.fk_id),
    notnull_sql = (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), N'c.' + QUOTENAME(cc.name) + N' IS NOT NULL'), N' AND ')
                     FROM sys.foreign_key_columns k
                     JOIN sys.columns cc ON cc.object_id = k.parent_object_id AND cc.column_id = k.parent_column_id
                    WHERE k.constraint_object_id = f.fk_id)
  FROM #fk f;

-- Triggers on scope tables that are enabled now (re-enabled by name later).
IF OBJECT_ID('tempdb..#trig') IS NOT NULL DROP TABLE #trig;
CREATE TABLE #trig (trigger_q NVARCHAR(400) NOT NULL, table_q NVARCHAR(400) NOT NULL);
INSERT #trig (trigger_q, table_q)
SELECT QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(tr.name), x.qname
  FROM sys.triggers tr
  JOIN sys.objects o ON o.object_id = tr.object_id
  JOIN #scope x ON x.object_id = tr.parent_id
 WHERE tr.is_disabled = 0 AND tr.parent_class = 1;

IF OBJECT_ID('tempdb..#log') IS NOT NULL DROP TABLE #log;
CREATE TABLE #log (step NVARCHAR(20) NOT NULL, table_q NVARCHAR(400) NOT NULL, rows_deleted BIGINT NOT NULL);

DECLARE @sql NVARCHAR(MAX), @q NVARCHAR(400), @n BIGINT, @pass INT, @passRows BIGINT, @fkName SYSNAME,
        @childQ NVARCHAR(400), @parentQ NVARCHAR(400), @match NVARCHAR(MAX), @nn NVARCHAR(MAX), @trusted BIT;

BEGIN TRY
    BEGIN TRANSACTION;

    -- Switch off the FKs touching the scope and the scope's triggers.
    DECLARE c0 CURSOR LOCAL FAST_FORWARD FOR SELECT fk_name, child_q FROM #fk;
    OPEN c0; FETCH NEXT FROM c0 INTO @fkName, @childQ;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'ALTER TABLE ' + @childQ + N' NOCHECK CONSTRAINT ' + QUOTENAME(@fkName) + N';';
        EXEC (@sql);
        FETCH NEXT FROM c0 INTO @fkName, @childQ;
    END
    CLOSE c0; DEALLOCATE c0;

    DECLARE c1 CURSOR LOCAL FAST_FORWARD FOR SELECT trigger_q, table_q FROM #trig;
    OPEN c1; FETCH NEXT FROM c1 INTO @q, @childQ;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'DISABLE TRIGGER ' + @q + N' ON ' + @childQ + N';';
        EXEC (@sql);
        FETCH NEXT FROM c1 INTO @q, @childQ;
    END
    CLOSE c1; DEALLOCATE c1;

    -- A. Rows of the other organizations.
    DECLARE c2 CURSOR LOCAL FAST_FORWARD FOR SELECT qname FROM #scope WHERE has_org = 1 ORDER BY qname;
    OPEN c2; FETCH NEXT FROM c2 INTO @q;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'DELETE FROM ' + @q + N' WHERE organization_id IS NOT NULL AND organization_id NOT IN (' + @keepList + N'); SET @n = @@ROWCOUNT;';
        EXEC sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @n OUTPUT;
        IF @n > 0 INSERT #log VALUES (N'A organization', @q, @n);
        FETCH NEXT FROM c2 INTO @q;
    END
    CLOSE c2; DEALLOCATE c2;

    -- B. Cascade over trusted FKs inside the scope until nothing moves.
    SET @pass = 0;
    WHILE 1 = 1
    BEGIN
        SET @pass += 1;
        SET @passRows = 0;
        DECLARE c3 CURSOR LOCAL FAST_FORWARD FOR
            SELECT child_q, parent_q, match_sql, notnull_sql FROM #fk
             WHERE child_in_scope = 1 AND was_trusted = 1;
        OPEN c3; FETCH NEXT FROM c3 INTO @childQ, @parentQ, @match, @nn;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @sql = N'DELETE c FROM ' + @childQ + N' c WHERE ' + @nn
                     + N' AND NOT EXISTS (SELECT 1 FROM ' + @parentQ + N' p WHERE ' + @match + N'); SET @n = @@ROWCOUNT;';
            EXEC sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @n OUTPUT;
            IF @n > 0
            BEGIN
                INSERT #log VALUES (N'B cascade', @childQ, @n);
                SET @passRows += @n;
            END
            FETCH NEXT FROM c3 INTO @childQ, @parentQ, @match, @nn;
        END
        CLOSE c3; DEALLOCATE c3;
        IF @passRows = 0 BREAK;
        IF @pass >= 100 THROW 60001, 'Cascade did not settle after 100 passes -- stopped, nothing kept.', 1;
    END

    -- GRAC_New rows pointing into the module must not be left dangling.
    DECLARE c4 CURSOR LOCAL FAST_FORWARD FOR
        SELECT fk_name, child_q, parent_q, match_sql, notnull_sql FROM #fk WHERE child_in_scope = 0 AND was_trusted = 1;
    OPEN c4; FETCH NEXT FROM c4 INTO @fkName, @childQ, @parentQ, @match, @nn;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'SELECT @n = COUNT_BIG(*) FROM ' + @childQ + N' c WHERE ' + @nn
                 + N' AND NOT EXISTS (SELECT 1 FROM ' + @parentQ + N' p WHERE ' + @match + N');';
        EXEC sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @n OUTPUT;
        IF @n > 0
        BEGIN
            DECLARE @msg NVARCHAR(2048) = CONCAT(N'GRAC_New table ', @childQ, N' has ', @n, N' row(s) pointing at deleted module rows (FK ', @fkName, N'). GRAC_New is not changed by this script -- stopped, nothing kept.');
            THROW 60002, @msg, 1;
        END
        FETCH NEXT FROM c4 INTO @fkName, @childQ, @parentQ, @match, @nn;
    END
    CLOSE c4; DEALLOCATE c4;

    -- Back on: trusted FKs WITH CHECK (validates the result), the rest as they were.
    DECLARE c5 CURSOR LOCAL FAST_FORWARD FOR SELECT fk_name, child_q, was_trusted FROM #fk;
    OPEN c5; FETCH NEXT FROM c5 INTO @fkName, @childQ, @trusted;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'ALTER TABLE ' + @childQ
                 + CASE WHEN @trusted = 1 THEN N' WITH CHECK CHECK CONSTRAINT ' ELSE N' CHECK CONSTRAINT ' END
                 + QUOTENAME(@fkName) + N';';
        EXEC (@sql);
        FETCH NEXT FROM c5 INTO @fkName, @childQ, @trusted;
    END
    CLOSE c5; DEALLOCATE c5;

    DECLARE c6 CURSOR LOCAL FAST_FORWARD FOR SELECT trigger_q, table_q FROM #trig;
    OPEN c6; FETCH NEXT FROM c6 INTO @q, @childQ;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'ENABLE TRIGGER ' + @q + N' ON ' + @childQ + N';';
        EXEC (@sql);
        FETCH NEXT FROM c6 INTO @q, @childQ;
    END
    CLOSE c6; DEALLOCATE c6;

    PRINT '=== Rows deleted, per table ===';
    SELECT table_q AS TableName, step AS Step, SUM(rows_deleted) AS RowsDeleted
      FROM #log GROUP BY table_q, step ORDER BY step, table_q;
    SELECT SUM(rows_deleted) AS TotalRowsDeleted FROM #log;

    IF @DryRun = 1
    BEGIN
        ROLLBACK TRANSACTION;
        PRINT 'DRY RUN -- everything above was rolled back. Set @DryRun = 0 and @ConfirmDatabase to keep it.';
    END
    ELSE
    BEGIN
        COMMIT TRANSACTION;
        PRINT 'COMMITTED.';
    END
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;   -- FKs and triggers come back with it
    THROW;
END CATCH;

/* ------------------------------------------------------------------ */
/* Report                                                              */
/* ------------------------------------------------------------------ */
PRINT '=== Organizations now in the database ===';
SELECT organization_id, organization_code, organization_name, status FROM grac_practice.organization ORDER BY organization_id;

-- Untrusted FKs were not followed; show any orphans they have (pre-existing
-- or new) so nothing is hidden. Usually empty.
DECLARE @rep TABLE (fk_name SYSNAME, child_q NVARCHAR(400), orphan_rows BIGINT);
DECLARE c7 CURSOR LOCAL FAST_FORWARD FOR
    SELECT fk_name, child_q, parent_q, match_sql, notnull_sql FROM #fk WHERE was_trusted = 0;
OPEN c7; FETCH NEXT FROM c7 INTO @fkName, @childQ, @parentQ, @match, @nn;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'SELECT @n = COUNT_BIG(*) FROM ' + @childQ + N' c WHERE ' + @nn
             + N' AND NOT EXISTS (SELECT 1 FROM ' + @parentQ + N' p WHERE ' + @match + N');';
    EXEC sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @n OUTPUT;
    INSERT @rep VALUES (@fkName, @childQ, @n);
    FETCH NEXT FROM c7 INTO @fkName, @childQ, @parentQ, @match, @nn;
END
CLOSE c7; DEALLOCATE c7;
IF EXISTS (SELECT 1 FROM @rep WHERE orphan_rows > 0)
BEGIN
    PRINT '>>> Untrusted foreign keys with orphan rows (not followed by this script):';
    SELECT * FROM @rep WHERE orphan_rows > 0 ORDER BY child_q;
END
ELSE PRINT 'No orphan rows behind untrusted foreign keys.';
