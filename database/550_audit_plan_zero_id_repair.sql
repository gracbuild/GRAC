-- =====================================================================
-- 550  Audit plan with id 0 -- renumber it; stop identities starting at 0
--
-- SYMPTOM (2026-11-14, sir)
--   Audit Plans: opening a plan's slots answered "HTTP 404" and the plan's
--   3-dot Add Item said "Pick a plan first." The plan list returned
--   {"planId":0, ...}: the first plan in organization 9 was stored with
--   org_assurance_plan_id = 0. Every screen treats 0 as "no id" (the page
--   read row.planId || row.PlanId -> undefined -> /plans/undefined/items,
--   which the Api route {id:long} answers 404), and the Api rejects 0 too
--   (plan item save: PlanId <= 0).
--
-- WHY 0
--   192_practice_data_reset.sql reseeds emptied tables with
--   DBCC CHECKIDENT (..., RESEED, 0). On a table that has had rows, the
--   next insert gets 1. On a table that has NEVER had a row since it was
--   created (org_assurance_plan here), SQL Server gives the FIRST insert
--   the reseed value itself -- 0. The application's insert procedures
--   never write an id (they read SCOPE_IDENTITY()).
--
-- WHAT THIS DOES
--   1. Reports every grac_practice table that holds a row with identity
--      value 0 (read-only).
--   2. org_assurance_plan: a row with id 0 is copied to the next free id
--      (IDENTITY_INSERT), its children (every foreign key that references
--      the plan -- org_assurance_plan_item) are repointed, the old row is
--      deleted, and the identity is reseeded to the highest id. The plan
--      code is unique per organization, so the old row's code is parked
--      first and the copy is written with the original code (fix after the
--      first run, 2026-11-14: the copy took the parked code and hit
--      uq_pm_oa_plan_code). One transaction: a failure changes nothing.
--   3. Every EMPTY grac_practice identity table whose identity was reseeded
--      to 0 (sys.identity_columns.last_value = 0) is reseeded to 1, so its
--      first row is 1 (or 2 if it had rows before), never 0.
--   ALSO EDITED: 192_practice_data_reset.sql -- RESEED 1 when the table has
--   never had a row (last_value NULL or 0), RESEED 0 otherwise.
--
-- NOT CHANGED: any other table's id-0 rows (section 1 lists them; they
--   need their own repair, as _diag_renumber_exception_request_zero_id.sql
--   did for exception_request).
-- Re-runnable (a second run finds nothing to do). ASCII-only.
-- Rollback: none -- the renumbered plan is the same plan; the old id 0
--   cannot be restored and nothing references it any more.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.org_assurance_plan','U') IS NULL
BEGIN
    PRINT 'ABORT (550): org_assurance_plan missing (run 089). Nothing was changed.';
    RAISERROR('550_audit_plan_zero_id_repair: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Report: identity tables holding an id-0 row
-- =====================================================================
DECLARE @rep NVARCHAR(MAX) = N'';
SELECT @rep = @rep
     + CASE WHEN @rep = N'' THEN N'' ELSE N' UNION ALL ' END
     + N'SELECT N''' + t.name + N''' AS TableName, COUNT(*) AS ZeroIdRows FROM grac_practice.'
     + QUOTENAME(t.name) + N' WHERE ' + QUOTENAME(ic.name) + N' = 0 HAVING COUNT(*) > 0'
  FROM sys.identity_columns ic
  JOIN sys.tables t ON t.object_id = ic.object_id
 WHERE SCHEMA_NAME(t.schema_id) = N'grac_practice';
PRINT '=== 550.1 tables with an id-0 row (before repair) ===';
IF @rep <> N'' EXEC sp_executesql @rep;
GO

-- =====================================================================
-- 2. Renumber the id-0 audit plan
-- =====================================================================
IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan WHERE org_assurance_plan_id = 0)
BEGIN
    DECLARE @NewId BIGINT = (SELECT ISNULL(MAX(org_assurance_plan_id), 0) + 1
                               FROM grac_practice.org_assurance_plan);
    DECLARE @Code  NVARCHAR(80) = (SELECT plan_code FROM grac_practice.org_assurance_plan
                                    WHERE org_assurance_plan_id = 0);
    DECLARE @cols NVARCHAR(MAX), @sel NVARCHAR(MAX), @children NVARCHAR(MAX) = N'', @sql NVARCHAR(MAX);

    SELECT @cols = STRING_AGG(QUOTENAME(c.name), N', ') WITHIN GROUP (ORDER BY c.column_id)
      FROM sys.columns c
     WHERE c.object_id = OBJECT_ID('grac_practice.org_assurance_plan')
       AND c.is_identity = 0 AND c.is_computed = 0;
    -- the copy's SELECT list: same columns, but plan_code is the original
    -- code (the old row's code is parked first, so the two never clash)
    SELECT @sel = STRING_AGG(CASE WHEN c.name = N'plan_code' THEN N'@code' ELSE QUOTENAME(c.name) END, N', ')
                  WITHIN GROUP (ORDER BY c.column_id)
      FROM sys.columns c
     WHERE c.object_id = OBJECT_ID('grac_practice.org_assurance_plan')
       AND c.is_identity = 0 AND c.is_computed = 0;

    -- every foreign key column that points at the plan
    SELECT @children = @children
         + N'UPDATE ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + N'.'
         + QUOTENAME(OBJECT_NAME(fk.parent_object_id))
         + N' SET ' + QUOTENAME(pc.name) + N' = @n WHERE ' + QUOTENAME(pc.name) + N' = 0;' + CHAR(10)
      FROM sys.foreign_keys fk
      JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
      JOIN sys.columns pc ON pc.object_id = fk.parent_object_id AND pc.column_id = fkc.parent_column_id
     WHERE fk.referenced_object_id = OBJECT_ID('grac_practice.org_assurance_plan');

    PRINT '550.2: plan ' + @Code + ' id 0 -> ' + CAST(@NewId AS NVARCHAR(20));
    PRINT '550.2: children:' + CHAR(10) + @children;

    BEGIN TRAN;
        -- park the old row's code (uq organization_id + plan_code)
        UPDATE grac_practice.org_assurance_plan
           SET plan_code = LEFT(@Code, 70) + N'~550'
         WHERE org_assurance_plan_id = 0;

        SET @sql = N'SET IDENTITY_INSERT grac_practice.org_assurance_plan ON;' + CHAR(10)
                 + N'INSERT INTO grac_practice.org_assurance_plan (org_assurance_plan_id, ' + @cols + N')' + CHAR(10)
                 + N'SELECT @n, ' + @sel + N' FROM grac_practice.org_assurance_plan WHERE org_assurance_plan_id = 0;' + CHAR(10)
                 + N'SET IDENTITY_INSERT grac_practice.org_assurance_plan OFF;';
        EXEC sp_executesql @sql, N'@n BIGINT, @code NVARCHAR(80)', @n = @NewId, @code = @Code;

        IF @children <> N'' EXEC sp_executesql @children, N'@n BIGINT', @n = @NewId;

        DELETE FROM grac_practice.org_assurance_plan WHERE org_assurance_plan_id = 0;
    COMMIT;

    DBCC CHECKIDENT ('grac_practice.org_assurance_plan', RESEED) WITH NO_INFOMSGS;
    PRINT '550.2: renumbered.';
END
ELSE
    PRINT '550.2: no audit plan with id 0.';
GO

-- =====================================================================
-- 3. Empty tables reseeded to 0 -> 1 (their first row would be 0)
-- =====================================================================
DECLARE @t SYSNAME, @n INT = 0, @q NVARCHAR(MAX), @rows BIGINT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT t.name
      FROM sys.identity_columns ic
      JOIN sys.tables t ON t.object_id = ic.object_id
     WHERE SCHEMA_NAME(t.schema_id) = N'grac_practice'
       AND CONVERT(BIGINT, ic.last_value) = 0
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
PRINT '550.3: empty tables reseeded to 1 = ' + CAST(@n AS NVARCHAR(20));
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '550 no audit plan with id 0' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan WHERE org_assurance_plan_id = 0)
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
PRINT '550 complete. No Api restart needed; reload Audit Plans.';
GO
SET NOEXEC OFF;
GO
