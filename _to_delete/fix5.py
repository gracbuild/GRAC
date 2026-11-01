path = "database/192_practice_data_reset.sql"
with open(path, "r", encoding="utf-8") as f:
    c = f.read()

# ---- 1. extra DROP guard for the new temp table (leftover-from-previous-run list) ----
old1 = "IF OBJECT_ID('tempdb..#ignore_fk')   IS NOT NULL DROP TABLE #ignore_fk;"
assert c.count(old1) == 1, "anchor1"
new1 = old1 + "\nIF OBJECT_ID('tempdb..#ignore_fk_check') IS NOT NULL DROP TABLE #ignore_fk_check;"
c = c.replace(old1, new1, 1)

# ---- 2. one more scalar variable for the check-constraint cursor ----
old2 = """        @blockers   INT = 0,
        @cycles     INT = 0,"""
assert c.count(old2) == 1, "anchor2"
new2 = """        @blockers   INT = 0,
        @cycles     INT = 0,
        @chk        SYSNAME,"""
c = c.replace(old2, new2, 1)

# ---- 3. the #ignore_fk_check temp table itself, right after #ignore_fk ----
old3 = """CREATE TABLE #ignore_fk
(
    constraint_object_id INT           NOT NULL PRIMARY KEY,
    fk_name              SYSNAME       NOT NULL,
    parent_table         SYSNAME       NOT NULL,
    referenced_table     SYSNAME       NOT NULL,
    null_stmt            NVARCHAR(MAX) NOT NULL
);

DECLARE @breakPass INT = 0, @broke INT = 0;"""
assert c.count(old3) == 1, "anchor3"
new3 = """CREATE TABLE #ignore_fk
(
    constraint_object_id INT           NOT NULL PRIMARY KEY,
    fk_name              SYSNAME       NOT NULL,
    parent_table         SYSNAME       NOT NULL,
    referenced_table     SYSNAME       NOT NULL,
    null_stmt            NVARCHAR(MAX) NOT NULL
);

/* A column being broken out of a cycle can be tied, by a CHECK constraint on
   the SAME row, to another column that is not part of the cycle at all --
   e.g. risk_candidate.registered_risk_id (the cycle column) is required
   NOT NULL whenever risk_candidate.status_code = 'Registered'
   (ck_pm_risk_candidate_registered_link). Nulling the cycle column alone
   would fail that CHECK even though the row is seconds away from being
   deleted outright (delete_mode = UNCONDITIONAL) or was never going to keep
   that column's value anyway (FILTERED/FILTERED_RESET rows that survive are
   never the ones a cycle-breaking UPDATE touches, because the UPDATE only
   ever runs during ALL/CATALOGUE/ORG_RETAIN's shared cycle-breaking step,
   on rows about to be deleted). So: any CHECK constraint on the parent
   table whose definition mentions one of the columns a #ignore_fk entry is
   about to NULL gets NOCHECK'd immediately before that UPDATE runs, and
   re-enabled (without revalidating -- the rows it would be validating are
   already gone) right after. Same transactional safety net as the trigger
   disable above: constraint DDL rolls back with everything else. */
CREATE TABLE #ignore_fk_check
(
    check_object_id INT     NOT NULL PRIMARY KEY,
    table_name      SYSNAME NOT NULL,
    check_name      SYSNAME NOT NULL
);

DECLARE @breakPass INT = 0, @broke INT = 0;"""
c = c.replace(old3, new3, 1)

# ---- 4. populate #ignore_fk_check once #ignore_fk is final, and show it in the plan ----
old4 = """IF EXISTS (SELECT 1 FROM #ignore_fk)
BEGIN
    PRINT 'Cycle-breaking pointer columns that will be set to NULL before the deletes:';
    SELECT fk_name,
           parent_table     = N'grac_practice.' + parent_table,
           referenced_table = N'grac_practice.' + referenced_table,
           null_stmt
    FROM #ignore_fk
    ORDER BY parent_table, fk_name;
END"""
assert c.count(old4) == 1, "anchor4"
new4 = """IF EXISTS (SELECT 1 FROM #ignore_fk)
BEGIN
    PRINT 'Cycle-breaking pointer columns that will be set to NULL before the deletes:';
    SELECT fk_name,
           parent_table     = N'grac_practice.' + parent_table,
           referenced_table = N'grac_practice.' + referenced_table,
           null_stmt
    FROM #ignore_fk
    ORDER BY parent_table, fk_name;

    /* Any CHECK constraint that mentions one of the columns being nulled
       above has to come off for that same UPDATE, or a row whose other
       column(s) require this one to be non-null will fail the check even
       though the row is on its way out. Matched by a plain substring
       search on sys.check_constraints.definition against the column name
       -- loose rather than exact, which only risks disabling one check too
       many (harmless: it is re-enabled, unvalidated, moments later, inside
       the same transaction, with nothing else writing to the table), never
       too few. */
    INSERT INTO #ignore_fk_check (check_object_id, table_name, check_name)
    SELECT DISTINCT cc.object_id, t.name, cc.name
    FROM #ignore_fk ifk
    JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = ifk.constraint_object_id
    JOIN sys.columns col ON col.object_id = fkc.parent_object_id
                        AND col.column_id = fkc.parent_column_id
    JOIN sys.check_constraints cc ON cc.parent_object_id = fkc.parent_object_id
    JOIN sys.tables t ON t.object_id = cc.parent_object_id
    WHERE cc.definition LIKE N'%' + col.name + N'%';

    IF EXISTS (SELECT 1 FROM #ignore_fk_check)
    BEGIN
        PRINT 'CHECK constraints that reference those columns, taken offline for the same UPDATEs:';
        SELECT check_name, on_table = N'grac_practice.' + table_name
        FROM #ignore_fk_check
        ORDER BY table_name, check_name;
    END
END"""
c = c.replace(old4, new4, 1)

# ---- 5. disable before brk_cur runs, re-enable right after ----
old5 = """/* 6a. Break the FK cycles first -- these are nullable pointer columns, so
       clearing them destroys no information the deletes were not about to
       remove anyway. */
IF EXISTS (SELECT 1 FROM #ignore_fk)
BEGIN
    DECLARE brk_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT parent_table, null_stmt FROM #ignore_fk ORDER BY parent_table, fk_name;

    OPEN brk_cur;
    FETCH NEXT FROM brk_cur INTO @tbl, @sql;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC sp_executesql @sql;
        PRINT '  [cycle] grac_practice.' + @tbl + ' -- pointer column(s) cleared on '
            + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' row(s)';
        FETCH NEXT FROM brk_cur INTO @tbl, @sql;
    END

    CLOSE brk_cur;
    DEALLOCATE brk_cur;
END"""
assert c.count(old5) == 1, "anchor5"
new5 = """/* 6a. Break the FK cycles first -- these are nullable pointer columns, so
       clearing them destroys no information the deletes were not about to
       remove anyway. Any CHECK constraint standing in the way of that
       nulling comes off first and goes back on right after -- see the
       #ignore_fk_check comment above for why. */
IF EXISTS (SELECT 1 FROM #ignore_fk_check)
BEGIN
    DECLARE chk_off CURSOR LOCAL FAST_FORWARD FOR
        SELECT table_name, check_name FROM #ignore_fk_check ORDER BY table_name, check_name;

    OPEN chk_off;
    FETCH NEXT FROM chk_off INTO @tbl, @chk;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'ALTER TABLE grac_practice.' + QUOTENAME(@tbl)
                 + N' NOCHECK CONSTRAINT ' + QUOTENAME(@chk) + N';';
        EXEC sp_executesql @sql;
        PRINT '  [check off] ' + @chk + ' on grac_practice.' + @tbl;
        FETCH NEXT FROM chk_off INTO @tbl, @chk;
    END

    CLOSE chk_off;
    DEALLOCATE chk_off;
END

IF EXISTS (SELECT 1 FROM #ignore_fk)
BEGIN
    DECLARE brk_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT parent_table, null_stmt FROM #ignore_fk ORDER BY parent_table, fk_name;

    OPEN brk_cur;
    FETCH NEXT FROM brk_cur INTO @tbl, @sql;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC sp_executesql @sql;
        PRINT '  [cycle] grac_practice.' + @tbl + ' -- pointer column(s) cleared on '
            + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' row(s)';
        FETCH NEXT FROM brk_cur INTO @tbl, @sql;
    END

    CLOSE brk_cur;
    DEALLOCATE brk_cur;
END

/* Put the CHECK constraints back right away -- WITHOUT revalidating
   (WITH NOCHECK on the re-enable): the rows that would have failed are
   either already gone, in the case of a table processed earlier in level
   order, or about to be deleted outright a few statements from now in 6b,
   so there is nothing left to validate against. */
IF EXISTS (SELECT 1 FROM #ignore_fk_check)
BEGIN
    DECLARE chk_on CURSOR LOCAL FAST_FORWARD FOR
        SELECT table_name, check_name FROM #ignore_fk_check ORDER BY table_name, check_name;

    OPEN chk_on;
    FETCH NEXT FROM chk_on INTO @tbl, @chk;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'ALTER TABLE grac_practice.' + QUOTENAME(@tbl)
                 + N' WITH NOCHECK CHECK CONSTRAINT ' + QUOTENAME(@chk) + N';';
        EXEC sp_executesql @sql;
        PRINT '  [check on] ' + @chk + ' on grac_practice.' + @tbl;
        FETCH NEXT FROM chk_on INTO @tbl, @chk;
    END

    CLOSE chk_on;
    DEALLOCATE chk_on;
END"""
c = c.replace(old5, new5, 1)

# ---- 6. final cleanup DROP list ----
old6 = "DROP TABLE #trig;\nDROP TABLE #ignore_fk;\nDROP TABLE #target;"
assert c.count(old6) == 1, "anchor6"
new6 = "DROP TABLE #trig;\nDROP TABLE #ignore_fk;\nDROP TABLE #ignore_fk_check;\nDROP TABLE #target;"
c = c.replace(old6, new6, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(c)
print("edit 16 (CHECK-constraint-aware cycle breaking) applied")
