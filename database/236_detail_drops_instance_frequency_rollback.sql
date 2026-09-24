-- =====================================================================
-- 236 Drop the instance-level frequency columns from the detail proc -- ROLLBACK
--
-- Restores 222's sp_resolve_instance_detail verbatim: ExecutionFrequency
-- and AssuranceFrequency come back with their two frequency_master joins.
--
-- Rolling this back on its own is safe -- the UI does not read those two
-- columns any more, so they simply travel unused. Combined with a full
-- Phase 1 rollback (235), the app tier would still not display them
-- because the app-tier record fields were removed alongside 236.
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (236 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.practice_instance','U') IS NULL
BEGIN
    PRINT 'ABORT (236 rollback): practice_instance missing (run 001 first).';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_instance_detail
    @practice_instance_id BIGINT,
    @organization_id      BIGINT = NULL,
    @caller_employee_id   BIGINT = NULL,
    @is_admin             BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52602, 'sp_resolve_instance_detail: practice_instance_id is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance
                    WHERE practice_instance_id = @practice_instance_id
                      AND (@organization_id IS NULL OR organization_id = @organization_id))
        THROW 52603, 'sp_resolve_instance_detail: instance not found for this organization.', 1;

    -- The list already hides instances the caller does not own, but the
    -- workspace is reachable by URL. Without this check, changing one
    -- number in the address bar opens a colleague's instance -- and the
    -- obligation and dependency endpoints hang off whatever opens here.
    IF @is_admin = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance
                        WHERE practice_instance_id = @practice_instance_id
                          AND primary_owner_id = @caller_employee_id)
        THROW 52619, 'sp_resolve_instance_detail: this practice instance belongs to another owner.', 1;

    SELECT
        pi.practice_instance_id  AS PracticeInstanceId,
        pi.organization_id       AS OrganizationId,
        o.organization_name      AS OrganizationName,
        pi.instance_code         AS InstanceCode,
        pi.instance_name         AS InstanceName,
        p.practice_id            AS PracticeId,
        p.practice_code          AS PracticeCode,
        p.practice_name          AS PracticeName,
        pi.primary_owner_id      AS OwnerEmployeeId,
        COALESCE(owner_emp.employee_name, pi.primary_owner) AS OwnerName,
        COALESCE(dept.department_name, pi.department)       AS Department,
        ef.frequency_name        AS ExecutionFrequency,
        af.frequency_name        AS AssuranceFrequency,
        pi.assurance_mode        AS AssuranceMode,
        pi.criticality           AS Criticality,
        COALESCE(ims.status_name, pi.implementation_status) AS ImplementationStatus,
        pi.status                AS Status,
        -- 222 additions.
        pi.department_id         AS OwnerDepartmentId,
        pi.business_function_id  AS BusinessFunctionId,
        bf.function_name         AS BusinessFunction
    FROM   grac_practice.practice_instance pi
    JOIN   grac_practice.practice p ON p.practice_id = pi.practice_id
    JOIN   grac_practice.organization o ON o.organization_id = pi.organization_id
    LEFT   JOIN grac_practice.organization_employee owner_emp
           ON owner_emp.employee_id = pi.primary_owner_id
    LEFT   JOIN grac_practice.organization_department dept
           ON dept.department_id = pi.department_id
    LEFT   JOIN grac_practice.organization_business_function bf
           ON bf.business_function_id = pi.business_function_id
    LEFT   JOIN grac_practice.frequency_master ef ON ef.frequency_id = pi.execution_frequency_id
    LEFT   JOIN grac_practice.frequency_master af ON af.frequency_id = pi.assurance_frequency_id
    LEFT   JOIN grac_practice.implementation_status_master ims
           ON ims.implementation_status_id = pi.implementation_status_id
    WHERE  pi.practice_instance_id = @practice_instance_id;
END
GO
PRINT '236 rollback: sp_resolve_instance_detail restored to 222 shape.';
GO

PRINT '=== 236 rollback verification ===';
SELECT 'ExecutionFrequency projection back' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_instance_detail','P'))
                 LIKE '%AS ExecutionFrequency,%' THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'AssuranceFrequency projection back',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_instance_detail','P'))
                 LIKE '%AS AssuranceFrequency,%' THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '236 rollback complete.';
GO

SET NOEXEC OFF;
GO
