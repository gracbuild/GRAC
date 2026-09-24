-- =====================================================================
-- 312 Practice Picker risk scope -- ROLLBACK
--
-- Restores sp_practice_picker_practices to 282's body: the four original
-- parameters, no AlreadyMappedToRisk, no risk-scoped exclusion.
--
-- AFTER RUNNING THIS the exclusion is back to being decided entirely by
-- whatever id list the caller sends in @exclude_practice_ids -- which on
-- the Risk Centre means the browser decides, and the database can no
-- longer answer "is this scoped to one risk?". That is what 312 exists
-- to fix; roll back only if the new parameters are themselves a problem.
--
-- The Web tier keeps working either way: it sends riskRegisterId as a
-- query argument, and a procedure without that parameter simply never
-- receives it -- the API stops binding it, so the call still succeeds
-- with the pre-312 behaviour.
--
-- Nothing else to undo. 312 added no table, no column, no data.
--
-- Re-runnable: yes.
-- ASCII-only on purpose.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_practice_picker_practices','P') IS NULL
BEGIN
    PRINT 'ABORT (312 rollback): sp_practice_picker_practices missing. Nothing to undo.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_practice_picker_practices
    @organization_id        BIGINT,
    @organization_control_id BIGINT,
    @search                 NVARCHAR(200) = NULL,
    @exclude_practice_ids   NVARCHAR(MAX) = NULL
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
           oc.control_code                      AS ControlCode
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
      AND  (@search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0
            OR p.practice_name LIKE N'%' + @search + N'%'
            OR p.practice_code LIKE N'%' + @search + N'%')
    ORDER BY p.practice_code, p.practice_name;
END
GO

SELECT '312r-a @risk_register_id removed' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.parameters
                              WHERE object_id = OBJECT_ID('grac_practice.sp_practice_picker_practices')
                                AND name = '@risk_register_id')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '312r-b AlreadyMappedToRisk removed',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))
                 NOT LIKE '%AlreadyMappedToRisk%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '312r-c 282 @exclude_practice_ids intact',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_practice_picker_practices')
                            AND name = '@exclude_practice_ids')
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '312 rollback complete. sp_practice_picker_practices is back to 282s body.';
GO

SET NOEXEC OFF;
GO
