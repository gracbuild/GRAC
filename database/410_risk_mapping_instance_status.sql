-- =====================================================================
-- 410 Risk Treatment -- Existing Controls grid: practice instance status
--
-- WHAT AND WHY
-- ------------
-- The Risk Treatment page's Existing Controls section listed each mapped
-- practice instance as a full card (facts, dependencies, tasks). With
-- several controls mapped the page grew very long, so the section is now
-- a grid -- Practice / Practice Instance, Tasks, Status, Actions -- and a
-- row click opens the same card in a popup.
--
-- The grid's Status column is the practice INSTANCE's implementation
-- status. sp_risk_mapping_get (387) did not return it, so this adds one
-- column to its first result set:
--
--   PracticeInstanceStatus = COALESCE(ims.status_name, pi.implementation_status)
--
-- -- exactly the expression the Operationalize grid shows (315), so the
-- two screens can never show different words for one instance.
--
-- Only change: one LEFT JOIN (implementation_status_master) and one
-- projected column. The body is otherwise 387's, verbatim. Adding a
-- trailing column leaves every existing reader of the result set as it
-- was.
--
-- Re-runnable. ASCII only. Depends on 387 and 346/242
-- (practice_instance.implementation_status_id).
-- Rollback: 410_risk_mapping_instance_status_rollback.sql (387 body).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_risk_mapping_get','P') IS NULL
   OR COL_LENGTH('grac_practice.risk_practice_map','practice_instance_id') IS NULL
BEGIN
    PRINT 'ABORT (410): sp_risk_mapping_get / risk_practice_map.practice_instance_id missing (run 387 first).';
    SET NOEXEC ON;
END
GO

-- The re-issued body reads these columns; guard them rather than let the
-- CREATE fail half way.
IF COL_LENGTH('grac_practice.practice_instance','implementation_status_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance','implementation_status') IS NULL
   OR COL_LENGTH('grac_practice.implementation_status_master','status_name') IS NULL
   OR COL_LENGTH('grac_practice.risk_practice_map','practice_instance_name') IS NULL
BEGIN
    PRINT 'ABORT (410): practice_instance implementation status columns missing (run 242 / 346 first).';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_risk_mapping_get (387 body + PracticeInstanceStatus)
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
           -- 387: counted per INSTANCE when the row is instance-level, so
           -- two instances of one practice report their own numbers.
           (SELECT COUNT(*)
              FROM grac_practice.risk_dependency_map_source s
              JOIN grac_practice.risk_dependency_map m
                ON m.risk_dependency_map_id = s.risk_dependency_map_id
             WHERE m.risk_register_id = @risk_register_id
               AND s.practice_id      = pm.practice_id
               AND (pm.practice_instance_id IS NULL
                    OR s.practice_instance_id = pm.practice_instance_id)) AS DependencyCount,
           -- 387: the mapped practice INSTANCE (NULL on a row not yet
           -- expanded -- see sp_risk_practice_map_expand_instances).
           pm.practice_instance_id       AS PracticeInstanceId,
           COALESCE(pi.instance_name, pm.practice_instance_name) AS PracticeInstanceName,
           COALESCE(pi.instance_code, pm.practice_instance_code) AS PracticeInstanceCode,
           -- 410: the mapped instance's implementation status -- the same
           -- value and the same expression the Operationalize grid shows
           -- and filters on (315). NULL on a practice-level row.
           COALESCE(ims.status_name, pi.implementation_status) AS PracticeInstanceStatus
      FROM grac_practice.risk_practice_map pm
      LEFT JOIN grac_practice.practice p ON p.practice_id = pm.practice_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = pm.mapped_by_employee_id
      LEFT JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = pm.practice_instance_id
      LEFT JOIN grac_practice.implementation_status_master ims
             ON ims.implementation_status_id = pi.implementation_status_id
     WHERE pm.risk_register_id = @risk_register_id
     ORDER BY CASE WHEN pm.map_source_code = N'Primary' THEN 0 ELSE 1 END,
              COALESCE(p.practice_name, pm.practice_name),
              COALESCE(pi.instance_name, pm.practice_instance_name);

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

           -- 387: the name comes from a TOP 1 lookup, not a join -- a
           -- practice can now sit on the risk once per instance, and a
           -- join would repeat its name once per row. The name is resolved
           -- in the derived table (OUTER APPLY) so STRING_AGG aggregates a
           -- plain column: an aggregate over an expression that contains a
           -- subquery is Msg 130.
           (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), s2.practice_name), N', ')
              FROM (SELECT d.practice_id,
                           COALESCE(pp.practice_name, fb.practice_name) AS practice_name
                      FROM (SELECT DISTINCT sx.practice_id
                              FROM grac_practice.risk_dependency_map_source sx
                             WHERE sx.risk_dependency_map_id = m.risk_dependency_map_id
                               AND sx.source_kind_code       = N'PracticeDependency') d
                      LEFT JOIN grac_practice.practice pp ON pp.practice_id = d.practice_id
                      OUTER APPLY (SELECT TOP 1 pm2.practice_name
                                     FROM grac_practice.risk_practice_map pm2
                                    WHERE pm2.risk_register_id = @risk_register_id
                                      AND pm2.practice_id      = d.practice_id
                                    ORDER BY pm2.risk_practice_map_id) fb) s2) AS SourcePractices
      FROM grac_practice.risk_dependency_map m
      LEFT JOIN grac_practice.dependency_type_master dt
             ON dt.dependency_type_id = m.dependency_type_id
     WHERE m.risk_register_id = @risk_register_id
     ORDER BY dt.display_order, m.dependency_object_name;
END;
GO
PRINT '410: sp_risk_mapping_get now returns PracticeInstanceStatus.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '410-a sp_risk_mapping_get returns PracticeInstanceStatus' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_mapping_get','P'))
                 LIKE '%AS PracticeInstanceStatus%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '410-b sp_risk_mapping_get still returns PracticeInstanceId (387 body intact)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_mapping_get','P'))
                 LIKE '%AS PracticeInstanceId%'
            THEN 'PASS' ELSE 'FAIL' END;
GO

SET NOEXEC OFF;
GO
PRINT 'Migration 410_risk_mapping_instance_status applied. Restart the API.';
GO
