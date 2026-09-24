-- =====================================================================
-- 267 dependency_type_master.is_dependency_mappable
--     Risk Analysis offers the SAME categories as Operationalize
--
-- WHAT 265/266 GOT WRONG
-- ----------------------
-- They read `dependency_type_master` as the source of truth for which
-- categories the dependency mapping table OFFERS. It is not. It is the
-- source of truth for which categories EXIST.
--
-- The Operationalize page has offered a fixed FIVE since migration 238:
--
--     const DEP_TABLE_CATEGORIES = ['Asset','Vendor','Person','Team','Committee'];
--
-- with this comment beside it:
--
--     "Tool and Application still exist in dependency_type_master (older
--      instances may still carry resolutions) but are not offered here"
--
-- So Risk Analysis rendered NINE categories -- Application, Tool,
-- Process and Location included -- against a page that offers five. The
-- instruction was to mirror Operationalize; showing four categories it
-- does not show is the opposite of mirroring it.
--
-- ---------------------------------------------------------------------
-- WHY A COLUMN AND NOT A SECOND LIST IN THE RISK CENTRE
-- ---------------------------------------------------------------------
-- The obvious fix is to copy those five names into risk-centre.js. That
-- would make the screens agree TODAY and guarantee they disagree later:
-- the next person to add or retire a category would find the list in
-- resolve-workspace.cshtml, change it, and never learn that a second
-- copy existed in the Risk Centre.
--
-- The distinction "exists" vs "is offered for mapping" is a property of
-- the CATEGORY, so it belongs on the category. This column makes it one,
-- and Risk Analysis then asks the database rather than holding an
-- opinion -- which is what 265's decision 1 was reaching for and got
-- wrong only in WHICH question it asked.
--
-- Seeded to exactly the five Operationalize offers, matched by name and
-- code so it lands correctly whichever the environment carries.
--
-- OPERATIONALIZE ITSELF IS NOT CHANGED BY THIS FILE.
-- Its JS keeps its own literal, and keeps working exactly as it does
-- today. Pointing it at this column is a one-line follow-up that would
-- remove the last duplicate; it is deliberately NOT done here, because
-- reflowing a working screen is a decision to take deliberately rather
-- than as a side effect of a Risk Centre fix. The sanity check at the
-- bottom asserts the column and that literal still agree, so the day
-- somebody edits one without the other, this file says so.
--
-- CONTENTS
--   1. is_dependency_mappable column + seed
--   2. fn_risk_practice_dependencies  REWRITE -- inherits offered only
--   3. sp_risk_mapping_get            REWRITE -- returns offered only
--   4. Clean up dependencies already inherited into hidden categories
--
-- ADDITIVE to the master. Idempotent. Safe to re-run.
-- ERROR CODE RANGE: reuses 266's (56683-56684); adds none.
-- Rollback: database/267_dependency_mappable_flag_rollback.sql
-- Depends:  002, 238 (the five-row decision), 265, 266
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF OBJECT_ID('grac_practice.dependency_type_master','U') IS NULL
BEGIN PRINT 'ABORT (267): dependency_type_master missing -- run 002 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.risk_dependency_map','U') IS NULL
BEGIN PRINT 'ABORT (267): risk_dependency_map missing -- run 265 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.sp_risk_mapping_get','P') IS NULL
BEGIN PRINT 'ABORT (267): sp_risk_mapping_get missing -- run 266 first.'; SET @ok = 0; END

IF @ok = 0
BEGIN
    RAISERROR('267_dependency_mappable_flag: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. The column
--
-- DEFAULT 0, then the five are switched on. Defaulting to 0 rather than
-- 1 is deliberate: a category added later should have to be offered
-- explicitly, the same way the Operationalize list has to be edited
-- explicitly. Silently exposing new categories is how the two screens
-- would drift again.
-- =====================================================================
IF COL_LENGTH('grac_practice.dependency_type_master','is_dependency_mappable') IS NULL
    ALTER TABLE grac_practice.dependency_type_master
        ADD is_dependency_mappable BIT NOT NULL
            CONSTRAINT df_pm_dep_type_mappable DEFAULT 0;
GO

-- The five, by name OR code, because environments differ in which of the
-- two carries the canonical casing. Idempotent: re-running only re-sets
-- the same rows to the same value.
UPDATE grac_practice.dependency_type_master
   SET is_dependency_mappable = 1,
       updated_by = N'seed-267',
       updated_dt = SYSUTCDATETIME()
 WHERE is_dependency_mappable = 0
   AND (dependency_type_name IN (N'Asset', N'Vendor', N'Person', N'Team', N'Committee')
     OR dependency_type_code IN (N'Asset', N'Vendor', N'Person', N'Team', N'Committee',
                                 N'ASSET', N'VENDOR', N'PERSON', N'TEAM', N'COMMITTEE'));
GO

-- And explicitly OFF for the four Operationalize retired, in case an
-- earlier hand-edit turned one on.
UPDATE grac_practice.dependency_type_master
   SET is_dependency_mappable = 0,
       updated_by = N'seed-267',
       updated_dt = SYSUTCDATETIME()
 WHERE is_dependency_mappable = 1
   AND dependency_type_name IN (N'Application', N'Tool', N'Process', N'Location');
GO

PRINT '267: categories offered for dependency mapping:';
GO
SELECT dependency_type_name AS OfferedCategory, display_order AS DisplayOrder
  FROM grac_practice.dependency_type_master
 WHERE is_active = 1 AND is_dependency_mappable = 1
 ORDER BY display_order, dependency_type_name;
GO

-- =====================================================================
-- 2. fn_risk_practice_dependencies   (REWRITE -- one predicate added)
--
-- 266's body with `AND dt.is_dependency_mappable = 1` on the category
-- join. Everything else is unchanged.
--
-- WHY INHERITANCE IS FILTERED TOO, NOT JUST THE DISPLAY
-- ----------------------------------------------------
-- Older practice instances still carry Application and Tool resolutions
-- (238's comment says so). Inheriting those while the screen renders no
-- Application or Tool section would put dependencies on the risk that
-- the user can neither see nor remove -- counted in the Scope column,
-- invisible in the panel, and impossible to explain.
--
-- A dependency the risk cannot show is worse than one it does not carry.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_risk_practice_dependencies
(
    @organization_id BIGINT,
    @practice_id     BIGINT
)
RETURNS TABLE
AS
RETURN
(
    SELECT r.dependency_type_id                  AS DependencyTypeId,
           MIN(dt.dependency_type_name)          AS DependencyTypeName,
           r.resolved_dependency_id              AS DependencyObjectId,
           MIN(r.resolved_dependency_name)       AS DependencyObjectName,
           MIN(pi.practice_instance_id)          AS PracticeInstanceId,
           MIN(r.resolution_id)                  AS ResolutionId
      FROM grac_practice.practice_instance pi
      JOIN grac_practice.practice_dependency_resolution r
        ON r.practice_instance_id = pi.practice_instance_id
       AND r.is_active = 1
      JOIN grac_practice.dependency_type_master dt
        ON dt.dependency_type_id = r.dependency_type_id
       AND dt.is_active = 1
       -- NEW in 267: only the categories Operationalize offers.
       AND dt.is_dependency_mappable = 1
     WHERE pi.practice_id      = @practice_id
       AND pi.organization_id  = @organization_id
       AND pi.status = N'Active'
       AND r.organization_id   = @organization_id
       AND r.resolved_dependency_id IS NOT NULL
     GROUP BY r.dependency_type_id, r.resolved_dependency_id
);
GO

-- =====================================================================
-- 3. sp_risk_mapping_get   (REWRITE -- one predicate in result set 2)
--
-- 266's body, with `AND dt.is_dependency_mappable = 1` on the category
-- result set. Result sets 1 and 3 are unchanged: practices are not
-- category-scoped, and a dependency already mapped is shown whatever its
-- category, so an inherited Application row from before this migration
-- is visible until section 4 clears it rather than silently orphaned.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_mapping_get
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56683, 'sp_risk_mapping_get: risk_register_id is required.', 1;

    DECLARE @org_id BIGINT, @primary_practice_id BIGINT;
    SELECT @org_id = organization_id
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56684, 'sp_risk_mapping_get: risk not found.', 1;

    SELECT @primary_practice_id = practice_id
      FROM grac_practice.risk_practice_map
     WHERE risk_register_id = @risk_register_id
       AND map_source_code  = N'Primary';

    -- ---- 1. Mapped practices -------------------------------------
    SELECT pm.risk_practice_map_id       AS RiskPracticeMapId,
           pm.practice_id                AS PracticeId,
           COALESCE(p.practice_name, pm.practice_name) AS PracticeName,
           COALESCE(p.practice_code, pm.practice_code) AS PracticeCode,
           pm.map_source_code            AS MapSourceCode,
           CAST(CASE WHEN pm.map_source_code = N'Primary' THEN 1 ELSE 0 END AS BIT) AS IsPrimary,
           pm.mapped_dt                  AS MappedDt,
           pm.mapped_by_employee_id      AS MappedByEmployeeId,
           e.employee_name               AS MappedByName,
           pm.remarks                    AS Remarks,
           (SELECT COUNT(*)
              FROM grac_practice.risk_dependency_map_source s
              JOIN grac_practice.risk_dependency_map m
                ON m.risk_dependency_map_id = s.risk_dependency_map_id
             WHERE m.risk_register_id = @risk_register_id
               AND s.practice_id      = pm.practice_id) AS DependencyCount
      FROM grac_practice.risk_practice_map pm
      LEFT JOIN grac_practice.practice p ON p.practice_id = pm.practice_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = pm.mapped_by_employee_id
     WHERE pm.risk_register_id = @risk_register_id
     ORDER BY CASE WHEN pm.map_source_code = N'Primary' THEN 0 ELSE 1 END,
              COALESCE(p.practice_name, pm.practice_name);

    -- ---- 2. The categories Operationalize OFFERS ------------------
    SELECT dt.dependency_type_id   AS DependencyTypeId,
           dt.dependency_type_code AS DependencyTypeCode,
           dt.dependency_type_name AS DependencyTypeName,
           dt.display_order        AS DisplayOrder,
           CAST(CASE WHEN sc.dependency_type_id IS NULL THEN 0 ELSE 1 END AS BIT) AS IsSelectable,
           (SELECT COUNT(*) FROM grac_practice.risk_dependency_map m
             WHERE m.risk_register_id   = @risk_register_id
               AND m.dependency_type_id = dt.dependency_type_id) AS MappedCount
      FROM grac_practice.dependency_type_master dt
      LEFT JOIN grac_practice.dependency_type_source_config sc
             ON sc.dependency_type_id = dt.dependency_type_id
            AND sc.status = N'Active'
     WHERE dt.is_active = 1
       -- NEW in 267. This one predicate is the whole difference between
       -- "every category that exists" and "the five this product offers".
       AND dt.is_dependency_mappable = 1
     ORDER BY dt.display_order, dt.dependency_type_name;

    -- ---- 3. Mapped dependencies, with provenance ------------------
    SELECT m.risk_dependency_map_id     AS RiskDependencyMapId,
           m.dependency_type_id         AS DependencyTypeId,
           COALESCE(dt.dependency_type_name, m.dependency_type_name) AS DependencyTypeName,
           m.dependency_object_id       AS DependencyObjectId,
           m.dependency_object_name     AS DependencyObjectName,
           m.first_mapped_dt            AS FirstMappedDt,
           m.remarks                    AS Remarks,

           CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                                   WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                                     AND s.source_kind_code = N'Direct')
                     THEN 1 ELSE 0 END AS BIT) AS IsDirect,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                                   WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                                     AND s.source_kind_code = N'PracticeDependency')
                     THEN 1 ELSE 0 END AS BIT) AS IsInherited,
           CAST(CASE WHEN @primary_practice_id IS NOT NULL
                      AND EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                                   WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                                     AND s.practice_id = @primary_practice_id)
                     THEN 1 ELSE 0 END AS BIT) AS FromPrimaryPractice,

           CASE
             WHEN EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                           WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                             AND s.source_kind_code = N'Direct')
              AND EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                           WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                             AND s.source_kind_code = N'PracticeDependency')
                  THEN N'DirectAndInherited'
             WHEN EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                           WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                             AND s.source_kind_code = N'Direct')
                  THEN N'Direct'
             WHEN @primary_practice_id IS NOT NULL
              AND EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                           WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                             AND s.practice_id = @primary_practice_id)
                  THEN N'Primary'
             ELSE N'Additional'
           END                          AS SourceLabel,

           (SELECT COUNT(*) FROM grac_practice.risk_dependency_map_source s
             WHERE s.risk_dependency_map_id = m.risk_dependency_map_id) AS SourceCount,

           (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX),
                       COALESCE(pp.practice_name, pm2.practice_name)), N', ')
              FROM grac_practice.risk_dependency_map_source s2
              LEFT JOIN grac_practice.practice pp ON pp.practice_id = s2.practice_id
              LEFT JOIN grac_practice.risk_practice_map pm2
                     ON pm2.risk_register_id = @risk_register_id
                    AND pm2.practice_id      = s2.practice_id
             WHERE s2.risk_dependency_map_id = m.risk_dependency_map_id
               AND s2.source_kind_code       = N'PracticeDependency') AS SourcePractices
      FROM grac_practice.risk_dependency_map m
      LEFT JOIN grac_practice.dependency_type_master dt
             ON dt.dependency_type_id = m.dependency_type_id
     WHERE m.risk_register_id = @risk_register_id
     ORDER BY dt.display_order, m.dependency_object_name;
END;
GO

-- =====================================================================
-- 4. Clear dependencies inherited into categories that are not offered
--
-- If 265/266 ran before this file, practices with legacy Application or
-- Tool resolutions have already pushed them onto risks. Those rows are
-- now unreachable: no category section renders for them, so they cannot
-- be seen or removed from the screen, while still counting in the Scope
-- column.
--
-- Only PURELY INHERITED rows are removed. Anything with a Direct
-- contribution was put there by a person, and deleting a human decision
-- to tidy up a schema change is not this file's business -- those are
-- counted and reported instead.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_dependency_map','U') IS NOT NULL
BEGIN
    DECLARE @kept_direct INT = 0, @removed INT = 0;

    SELECT @kept_direct = COUNT(*)
      FROM grac_practice.risk_dependency_map m
      JOIN grac_practice.dependency_type_master dt
        ON dt.dependency_type_id = m.dependency_type_id
     WHERE dt.is_dependency_mappable = 0
       AND EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                    WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                      AND s.source_kind_code = N'Direct');

    BEGIN TRY
        BEGIN TRAN;

        DELETE s
          FROM grac_practice.risk_dependency_map_source s
          JOIN grac_practice.risk_dependency_map m
            ON m.risk_dependency_map_id = s.risk_dependency_map_id
          JOIN grac_practice.dependency_type_master dt
            ON dt.dependency_type_id = m.dependency_type_id
         WHERE dt.is_dependency_mappable = 0
           AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source d
                            WHERE d.risk_dependency_map_id = m.risk_dependency_map_id
                              AND d.source_kind_code = N'Direct');

        DELETE m
          FROM grac_practice.risk_dependency_map m
          JOIN grac_practice.dependency_type_master dt
            ON dt.dependency_type_id = m.dependency_type_id
         WHERE dt.is_dependency_mappable = 0
           AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                            WHERE s.risk_dependency_map_id = m.risk_dependency_map_id);

        SET @removed = @@ROWCOUNT;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    PRINT CONCAT('267: removed ', @removed,
                 ' inherited dependency(ies) in categories that are not offered.');
    IF @kept_direct > 0
        PRINT CONCAT('267: KEPT ', @kept_direct,
                     ' directly-added dependency(ies) in non-offered categories -- ',
                     'a person put those there. They will not render until the category is offered.');
END
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '267 flag present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.dependency_type_master','is_dependency_mappable') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- The whole point of the file: Risk Analysis offers exactly what
-- Operationalize offers. The five names are the literal from
-- resolve-workspace.cshtml's DEP_TABLE_CATEGORIES; if somebody edits
-- that list without updating this column, this check fails and names the
-- disagreement rather than letting the two screens drift silently.
SELECT '267 offered set matches Operationalize DEP_TABLE_CATEGORIES' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT dependency_type_name FROM grac_practice.dependency_type_master
                 WHERE is_active = 1 AND is_dependency_mappable = 1
                EXCEPT
                SELECT v FROM (VALUES (N'Asset'), (N'Vendor'), (N'Person'), (N'Team'), (N'Committee')) x(v))
             AND NOT EXISTS (
                SELECT v FROM (VALUES (N'Asset'), (N'Vendor'), (N'Person'), (N'Team'), (N'Committee')) x(v)
                EXCEPT
                SELECT dependency_type_name FROM grac_practice.dependency_type_master
                 WHERE is_active = 1 AND is_dependency_mappable = 1)
            THEN 'PASS' ELSE 'FAIL -- see the list printed above' END AS Result;

SELECT '267 inheritance is filtered to the offered set' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.fn_risk_practice_dependencies')
                            AND definition LIKE '%is_dependency_mappable = 1%')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT '267 no unreachable inherited dependencies remain' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.risk_dependency_map m
                  JOIN grac_practice.dependency_type_master dt
                    ON dt.dependency_type_id = m.dependency_type_id
                 WHERE dt.is_dependency_mappable = 0
                   AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                                    WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                                      AND s.source_kind_code = N'Direct'))
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '267 Dependency-mappable flag installed.';
PRINT '     Risk Analysis now offers Asset, Vendor, Person, Team, Committee --';
PRINT '     the same five the Operationalize dependency table offers.';
PRINT '     Operationalize itself is unchanged; its JS still holds its own literal.';
GO

SET NOEXEC OFF;
GO
