-- =====================================================================
-- 349 Practice Picker direct-control-link -- ROLLBACK
--
-- Restores sp_practice_picker_controls to 282's body and
-- sp_practice_picker_practices to 312's body: both go back to reading
-- ONLY the 057 organization_control_requirement link table, not the
-- direct organization_requirement.organization_control_id FK.
--
-- AFTER RUNNING THIS a requirement whose direct FK is set but that has
-- no 057 link row goes back to being invisible to the picker -- which
-- is the exact symptom 349 was written to fix (PCI-DSS 7.2 / AC-002:
-- Governance's Practices grid shows 2, the picker shows 0). Roll back
-- only if the OR'd two-path match itself turns out to be a problem.
--
-- Nothing else to undo. 349 added no table, no column, no data --
-- both procedures remain pure SELECTs throughout.
--
-- Re-runnable: yes.
-- ASCII-only on purpose.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_practice_picker_controls','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_practice_picker_practices','P') IS NULL
BEGIN
    PRINT 'ABORT (349 rollback): sp_practice_picker_controls / _practices missing. Nothing to undo.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- LEVEL 3 -- back to 282's body (057 link table only).
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
        LEFT JOIN grac_practice.organization_control_requirement ocr
               ON ocr.organization_control_id = oc.organization_control_id
              AND ocr.status = N'Active'
        LEFT JOIN grac_practice.organization_requirement q
               ON q.organization_requirement_id = ocr.organization_requirement_id
              AND q.status = N'Active'
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
    LEFT JOIN grac_practice.organization_control_requirement ocr
           ON ocr.organization_control_id = oc.organization_control_id
          AND ocr.status = N'Active'
    LEFT JOIN grac_practice.organization_requirement q
           ON q.organization_requirement_id = ocr.organization_requirement_id
          AND q.status = N'Active'
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
-- LEVEL 4 -- back to 312's body (057 link table only, risk-scope
-- parameters retained since 312 is not what this migration rolls back).
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
    FROM   grac_practice.organization_control_requirement ocr
    JOIN   grac_practice.organization_control oc
           ON oc.organization_control_id = ocr.organization_control_id
          AND oc.organization_id = @organization_id
          AND oc.status = N'Active'
    JOIN   grac_practice.organization_requirement q
           ON q.organization_requirement_id = ocr.organization_requirement_id
          AND q.status = N'Active'
    JOIN   grac_practice.practice p
           ON p.organization_requirement_id = q.organization_requirement_id
          AND p.organization_id = @organization_id
          AND p.status = N'Active'
    WHERE  ocr.organization_control_id = @organization_control_id
      AND  ocr.status = N'Active'
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

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '349r-a sp_practice_picker_controls back to 057-only' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_controls'))
                 NOT LIKE '%q.organization_control_id = oc.organization_control_id%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '349r-b sp_practice_picker_practices back to 057-only',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))
                 NOT LIKE '%q.organization_control_id = oc.organization_control_id%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '349r-c 312s risk-scope parameters still present',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_practice_picker_practices')
                            AND name = '@risk_register_id')
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '349 rollback complete. Both procedures are back to reading only the';
PRINT '057 organization_control_requirement link table.';
GO

SET NOEXEC OFF;
GO
