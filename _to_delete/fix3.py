import sys

path = r"database/192_practice_data_reset.sql"
with open(path, "r", encoding="utf-8") as f:
    c = f.read()

old = """    /* Still stuck: park every all-nullable FK inside the unresolved
       group, NULL those columns at delete time, and re-level. */
    INSERT INTO #ignore_fk (constraint_object_id, fk_name, parent_table, referenced_table, null_stmt)
    SELECT fk.object_id,
           fk.name,
           pt.name,
           rt.name,
           N'UPDATE grac_practice.' + QUOTENAME(pt.name) + N' SET '
             + STUFF((SELECT N', ' + QUOTENAME(c.name) + N' = NULL'
                      FROM sys.foreign_key_columns fkc
                      JOIN sys.columns c ON c.object_id = fkc.parent_object_id
                                        AND c.column_id = fkc.parent_column_id
                      WHERE fkc.constraint_object_id = fk.object_id
                      ORDER BY fkc.constraint_column_id
                      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') + N';'
    FROM sys.foreign_keys fk
    JOIN sys.tables pt ON pt.object_id = fk.parent_object_id
    JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id
    WHERE fk.parent_object_id     IN (SELECT object_id FROM #target WHERE lvl IS NULL)
      AND fk.referenced_object_id IN (SELECT object_id FROM #target WHERE lvl IS NULL)
      AND fk.parent_object_id <> fk.referenced_object_id
      AND fk.object_id NOT IN (SELECT constraint_object_id FROM #ignore_fk)
      AND NOT EXISTS (SELECT 1                                   -- every FK column must be nullable
                      FROM sys.foreign_key_columns fkc
                      JOIN sys.columns c ON c.object_id = fkc.parent_object_id
                                        AND c.column_id = fkc.parent_column_id
                      WHERE fkc.constraint_object_id = fk.object_id
                        AND c.is_nullable = 0);

    SET @broke = @@ROWCOUNT;"""

assert c.count(old) == 1, f"anchor found {c.count(old)} times"

new = """    /* Still stuck: of the FKs connecting two currently-unresolved tables,
       park only the ones that are ACTUALLY on a cycle -- i.e. the other
       table has a real FK pointing back to this one, so the pair is
       genuinely mutual (A -> B and B -> A). "Both ends are stuck" alone is
       not enough: a table can be stuck purely as collateral damage from
       something else it references being caught in an unrelated cycle
       (e.g. risk_analysis/risk_register/risk_candidate/risk_residual_analysis
       cycle among themselves, and organization_employee is a dead end they
       all also point to -- organization_employee itself has no cycle, but
       it cannot level until those stuck tables do, so without this check it
       would be swept in and have role_id/provider_vendor_id blanket-NULLed
       across the whole table for no reason, which then fails
       ck_pm_employee_provider_required for any ThirdParty row). Requiring a
       mutual FK pair is what distinguishes a genuine 2-table cycle from a
       table that merely sits downstream of one. */
    INSERT INTO #ignore_fk (constraint_object_id, fk_name, parent_table, referenced_table, null_stmt)
    SELECT fk.object_id,
           fk.name,
           pt.name,
           rt.name,
           N'UPDATE grac_practice.' + QUOTENAME(pt.name) + N' SET '
             + STUFF((SELECT N', ' + QUOTENAME(c.name) + N' = NULL'
                      FROM sys.foreign_key_columns fkc
                      JOIN sys.columns c ON c.object_id = fkc.parent_object_id
                                        AND c.column_id = fkc.parent_column_id
                      WHERE fkc.constraint_object_id = fk.object_id
                      ORDER BY fkc.constraint_column_id
                      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') + N';'
    FROM sys.foreign_keys fk
    JOIN sys.tables pt ON pt.object_id = fk.parent_object_id
    JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id
    WHERE fk.parent_object_id     IN (SELECT object_id FROM #target WHERE lvl IS NULL)
      AND fk.referenced_object_id IN (SELECT object_id FROM #target WHERE lvl IS NULL)
      AND fk.parent_object_id <> fk.referenced_object_id
      AND fk.object_id NOT IN (SELECT constraint_object_id FROM #ignore_fk)
      AND NOT EXISTS (SELECT 1                                   -- every FK column must be nullable
                      FROM sys.foreign_key_columns fkc
                      JOIN sys.columns c ON c.object_id = fkc.parent_object_id
                                        AND c.column_id = fkc.parent_column_id
                      WHERE fkc.constraint_object_id = fk.object_id
                        AND c.is_nullable = 0)
      AND EXISTS (SELECT 1                                       -- genuinely mutual: the other
                  FROM sys.foreign_keys fk2                       -- table has a real FK back to
                  WHERE fk2.parent_object_id     = fk.referenced_object_id   -- this one, closing an
                    AND fk2.referenced_object_id = fk.parent_object_id);     -- actual 2-table loop

    SET @broke = @@ROWCOUNT;"""

c = c.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(c)
print("edit 15 (mutual-FK cycle check) applied")
