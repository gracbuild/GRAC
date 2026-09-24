-- =====================================================================
-- 351 Practice Picker Statement/Requirement path -- ROLLBACK
--
-- Restores all four procedures to exactly the state 349 left them in:
--   sp_practice_picker_structures  -> 282's body (source_control_map only)
--   sp_practice_picker_controls    -> 349's body (direct FK OR 057, no
--                                     Statement branch)
--   sp_practice_picker_practices   -> 349's body (direct FK OR 057, risk-
--                                     scope params from 312, no Statement
--                                     branch)
--   sp_practice_picker_resolve     -> 282's body (Control path only)
--
-- AFTER RUNNING THIS a release that only has Statement/Requirement data
-- (no grac_new.source_control_map rows -- e.g. ISO 27001 on UAT) goes
-- back to showing "No source structures found" in the picker. That is
-- the exact symptom 351 was written to fix. Roll back only if the added
-- UNION branch itself turns out to be a problem (e.g. an unexpected
-- performance regression from the extra JOINs) -- not as a way to "undo"
-- any data, because 351 wrote no data and created no table or column.
--
-- Nothing else to undo. 351 added no table, no column, no data -- all
-- four procedures remain pure SELECTs throughout, exactly as before.
--
-- Re-runnable: yes.
-- ASCII-only on purpose.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_practice_picker_structures','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_practice_picker_controls','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_practice_picker_practices','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_practice_picker_resolve','P') IS NULL
BEGIN
    PRINT 'ABORT (351 rollback): one or more sp_practice_picker_* procedures missing. Nothing to undo.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- LEVEL 2 -- back to 282's body (source_control_map path only).
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_picker_structures
    @organization_id BIGINT,
    @release_id      BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @release_id IS NULL
        THROW 57002, 'sp_practice_picker_structures: organization_id and release_id are required.', 1;

    IF @release_id = -1
    BEGIN
        SELECT CAST(-1 AS BIGINT)   AS StructureNodeId,
               CAST(NULL AS BIGINT) AS ParentNodeId,
               1                    AS NodeLevel,
               CAST(NULL AS NVARCHAR(100)) AS NodeReference,
               N'Organization Defined Practices' AS NodeTitle,
               N'Organization Defined Practices' AS StructureName,
               COUNT(DISTINCT oc.organization_control_id) AS ControlCount
        FROM   grac_practice.organization_control oc
        WHERE  oc.organization_id = @organization_id
          AND  oc.control_code = N'ORG-PRACTICES'
          AND  oc.origin_type  = N'Organization'
          AND  oc.status = N'Active';
        RETURN;
    END

    SELECT n.structure_node_id                       AS StructureNodeId,
           n.parent_node_id                          AS ParentNodeId,
           n.node_level                              AS NodeLevel,
           n.node_reference                          AS NodeReference,
           n.node_title                              AS NodeTitle,
           COALESCE(NULLIF(n.node_reference, N'') + N' - ', N'')
               + n.node_title                        AS StructureName,
           COUNT(DISTINCT oc.organization_control_id) AS ControlCount
    FROM   grac_new.source_structure_node n
    JOIN   grac_new.source_control_map scm
           ON scm.structure_node_id = n.structure_node_id
          AND scm.status = N'Active'
    JOIN   grac_practice.organization_control oc
           ON oc.repository_control_id = scm.control_id
          AND oc.organization_id       = @organization_id
          AND oc.release_id            = @release_id
          AND oc.status                = N'Active'
    WHERE  n.release_id = @release_id
      AND  n.status     = N'Active'
    GROUP BY n.structure_node_id, n.parent_node_id, n.node_level,
             n.node_reference, n.node_title, n.display_order
    ORDER BY n.display_order, n.node_reference, n.node_title;
END
GO

-- ---------------------------------------------------------------------
-- LEVEL 3 -- back to 349's body (direct FK OR 057, no Statement branch).
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_picker_controls
    @organization_id   BIGINT,
    @release_id        BIGINT,
    @structure_node_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @structure_node_id IS NULL
        THROW 57003, 'sp_practice_picker_controls: organization_id and structure_node_id are required.', 1;

    IF @structure_node_id = -1
    BEGIN
        SELECT oc.organization_control_id  AS OrganizationControlId,
               oc.control_code             AS ControlCode,
               oc.control_name             AS ControlName,
               oc.applicability_status     AS ApplicabilityStatus,
               COUNT(DISTINCT p.practice_id) AS PracticeCount
        FROM   grac_practice.organization_control oc
        LEFT JOIN grac_practice.organization_requirement q
               ON q.status = N'Active'
              AND (
                    q.organization_control_id = oc.organization_control_id
                    OR EXISTS (
                        SELECT 1
                        FROM   grac_practice.organization_control_requirement ocr
                        WHERE  ocr.organization_control_id     = oc.organization_control_id
                          AND  ocr.organization_requirement_id = q.organization_requirement_id
                          AND  ocr.status = N'Active'
                    )
              )
        LEFT JOIN grac_practice.practice p
               ON p.organization_requirement_id = q.organization_requirement_id
              AND p.organization_id = @organization_id
              AND p.status = N'Active'
        WHERE  oc.organization_id = @organization_id
          AND  oc.control_code = N'ORG-PRACTICES'
          AND  oc.origin_type  = N'Organization'
          AND  oc.status = N'Active'
        GROUP BY oc.organization_control_id, oc.control_code,
                 oc.control_name, oc.applicability_status;
        RETURN;
    END

    SELECT oc.organization_control_id                AS OrganizationControlId,
           oc.control_code                           AS ControlCode,
           oc.control_name                           AS ControlName,
           oc.applicability_status                   AS ApplicabilityStatus,
           COUNT(DISTINCT p.practice_id)             AS PracticeCount
    FROM   grac_new.source_control_map scm
    JOIN   grac_practice.organization_control oc
           ON oc.repository_control_id = scm.control_id
          AND oc.organization_id       = @organization_id
          AND oc.status                = N'Active'
          AND (@release_id IS NULL OR oc.release_id = @release_id)
    LEFT JOIN grac_practice.organization_requirement q
           ON q.status = N'Active'
          AND (
                q.organization_control_id = oc.organization_control_id
                OR EXISTS (
                    SELECT 1
                    FROM   grac_practice.organization_control_requirement ocr
                    WHERE  ocr.organization_control_id     = oc.organization_control_id
                      AND  ocr.organization_requirement_id = q.organization_requirement_id
                      AND  ocr.status = N'Active'
                )
          )
    LEFT JOIN grac_practice.practice p
           ON p.organization_requirement_id = q.organization_requirement_id
          AND p.organization_id = @organization_id
          AND p.status = N'Active'
    WHERE  scm.structure_node_id = @structure_node_id
      AND  scm.status = N'Active'
    GROUP BY oc.organization_control_id, oc.control_code,
             oc.control_name, oc.applicability_status
    ORDER BY oc.control_code, oc.control_name;
END
GO

-- ---------------------------------------------------------------------
-- LEVEL 4 -- back to 349's body (direct FK OR 057, risk-scope params
-- from 312 retained, no Statement branch).
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_picker_practices
    @organization_id         BIGINT,
    @organization_control_id BIGINT,
    @search                  NVARCHAR(200) = NULL,
    @exclude_practice_ids    NVARCHAR(MAX) = NULL,
    @risk_register_id        BIGINT        = NULL,
    @include_already_mapped  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @organization_control_id IS NULL
        THROW 57004, 'sp_practice_picker_practices: organization_id and organization_control_id are required.', 1;

    DECLARE @excluded TABLE(practice_id BIGINT PRIMARY KEY);
    IF @exclude_practice_ids IS NOT NULL AND LEN(LTRIM(RTRIM(@exclude_practice_ids))) > 0
        INSERT INTO @excluded(practice_id)
        SELECT DISTINCT TRY_CONVERT(BIGINT, LTRIM(RTRIM(value)))
        FROM   STRING_SPLIT(@exclude_practice_ids, ',')
        WHERE  TRY_CONVERT(BIGINT, LTRIM(RTRIM(value))) IS NOT NULL;

    SELECT p.practice_id                        AS PracticeId,
           p.practice_code                      AS PracticeCode,
           p.practice_name                      AS PracticeName,
           p.applicability_status               AS ApplicabilityStatus,
           q.organization_requirement_id        AS OrganizationRequirementId,
           oc.organization_control_id           AS OrganizationControlId,
           oc.control_code                      AS ControlCode,
           CAST(CASE WHEN @risk_register_id IS NOT NULL
                      AND EXISTS (SELECT 1
                                    FROM grac_practice.risk_practice_map pm
                                   WHERE pm.organization_id  = @organization_id
                                     AND pm.risk_register_id = @risk_register_id
                                     AND pm.practice_id      = p.practice_id)
                     THEN 1 ELSE 0 END AS BIT) AS AlreadyMappedToRisk,
           (SELECT TOP 1 pm2.map_source_code
              FROM grac_practice.risk_practice_map pm2
             WHERE pm2.organization_id  = @organization_id
               AND pm2.risk_register_id = @risk_register_id
               AND pm2.practice_id      = p.practice_id) AS MapSourceCode
    FROM   grac_practice.organization_control oc
    JOIN   grac_practice.organization_requirement q
           ON q.status = N'Active'
          AND (
                q.organization_control_id = oc.organization_control_id
                OR EXISTS (
                    SELECT 1
                    FROM   grac_practice.organization_control_requirement ocr
                    WHERE  ocr.organization_control_id     = oc.organization_control_id
                      AND  ocr.organization_requirement_id = q.organization_requirement_id
                      AND  ocr.status = N'Active'
                )
          )
    JOIN   grac_practice.practice p
           ON p.organization_requirement_id = q.organization_requirement_id
          AND p.organization_id = @organization_id
          AND p.status = N'Active'
    WHERE  oc.organization_control_id = @organization_control_id
      AND  oc.organization_id = @organization_id
      AND  oc.status = N'Active'
      AND  NOT EXISTS (SELECT 1 FROM @excluded x WHERE x.practice_id = p.practice_id)
      AND  (@risk_register_id IS NULL
            OR @include_already_mapped = 1
            OR NOT EXISTS (SELECT 1
                             FROM grac_practice.risk_practice_map pm
                            WHERE pm.organization_id  = @organization_id
                              AND pm.risk_register_id = @risk_register_id
                              AND pm.practice_id      = p.practice_id))
      AND  (@search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0
            OR p.practice_name LIKE N'%' + @search + N'%'
            OR p.practice_code LIKE N'%' + @search + N'%')
    ORDER BY p.practice_code, p.practice_name;
END
GO

-- ---------------------------------------------------------------------
-- EDIT MODE -- back to 282's body (Control path only).
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_picker_resolve
    @organization_id BIGINT,
    @practice_id     BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @practice_id IS NULL
        THROW 57005, 'sp_practice_picker_resolve: organization_id and practice_id are required.', 1;

    SELECT TOP (1)
           p.practice_id                  AS PracticeId,
           p.practice_code                AS PracticeCode,
           p.practice_name                AS PracticeName,
           oc.organization_control_id     AS OrganizationControlId,
           oc.control_code                AS ControlCode,
           oc.control_name                AS ControlName,
           n.structure_node_id            AS StructureNodeId,
           n.node_title                   AS NodeTitle,
           COALESCE(NULLIF(n.node_reference, N'') + N' - ', N'')
               + n.node_title             AS StructureName,
           oc.release_id                  AS ReleaseId,
           COALESCE(a.artifact_code + N' ' + r.version_no,
                    a.artifact_name + N' ' + r.version_no,
                    r.version_no)         AS FrameworkName
    FROM   grac_practice.practice p
    JOIN   grac_practice.organization_requirement q
           ON q.organization_requirement_id = p.organization_requirement_id
    JOIN   grac_practice.organization_control_requirement ocr
           ON ocr.organization_requirement_id = q.organization_requirement_id
          AND ocr.status = N'Active'
    JOIN   grac_practice.organization_control oc
           ON oc.organization_control_id = ocr.organization_control_id
          AND oc.organization_id = @organization_id
          AND oc.status = N'Active'
    LEFT JOIN grac_new.source_control_map scm
           ON scm.control_id = oc.repository_control_id
          AND scm.status = N'Active'
    LEFT JOIN grac_new.source_structure_node n
           ON n.structure_node_id = scm.structure_node_id
          AND n.release_id = oc.release_id
          AND n.status = N'Active'
    LEFT JOIN grac_new.release r  ON r.release_id  = oc.release_id
    LEFT JOIN grac_new.artifact a ON a.artifact_id = COALESCE(oc.artifact_id, r.artifact_id)
    WHERE  p.practice_id = @practice_id
      AND  p.organization_id = @organization_id
      AND  p.status = N'Active'
    ORDER BY n.structure_node_id, oc.organization_control_id;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '351r-a sp_practice_picker_structures back to source_control_map only' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_structures'))
                 NOT LIKE '%organization_framework_statements%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '351r-b sp_practice_picker_controls back to 349 (no Statement branch)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_controls'))
                 NOT LIKE '%organization_framework_statements%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '351r-c sp_practice_picker_practices back to 349 (no negative-id branch)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))
                 NOT LIKE '%IF @organization_control_id < 0%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '351r-d sp_practice_picker_practices still supports risk-scope params (312)',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_practice_picker_practices')
                            AND name = '@risk_register_id')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '351r-e sp_practice_picker_resolve back to Control path only',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_resolve'))
                 NOT LIKE '%organization_framework_statements%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '351 rollback complete. All four procedures are back to the exact';
PRINT 'state 349 left them in -- Control/source_control_map path only.';
PRINT 'A release that has only Statement/Requirement data (no';
PRINT 'source_control_map rows) will show an empty picker again.';
GO

SET NOEXEC OFF;
GO
