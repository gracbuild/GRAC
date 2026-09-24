-- =====================================================================
-- 236 Drop the instance-level frequency columns from the detail proc
--
-- WHY
-- ---
-- Phase 2 of retiring the instance-wide cadence (see 235's header). The
-- Operationalize page's facts strip stopped showing Execution and
-- Assurance frequency for the instance, so the detail procedure has no
-- reader for the two columns it was projecting -- and the app-tier record
-- (ResolveInstanceDetail) has dropped the corresponding fields.
--
-- WHAT IT DOES
-- ------------
-- Re-emits sp_resolve_instance_detail with 222's body verbatim apart
-- from two mechanical removals:
--
--   * the two SELECT projections
--         ef.frequency_name AS ExecutionFrequency,
--         af.frequency_name AS AssuranceFrequency,
--   * the two LEFT JOINs to frequency_master that fed them.
--
-- The two anchors are asserted count-1 in the build script, so a future
-- edit to 222's body would fail loudly here instead of drifting silently.
--
-- WHAT IT DOES NOT DO
-- -------------------
-- Nothing else changes: same parameters, same shape apart from the two
-- gone columns, same ownership checks. The four instance columns
-- (execution_frequency_id, assurance_frequency_id, frequency_id,
-- frequency_type) stay -- the Calendar page's assurance-schedule
-- generator still reads them and Configure still populates them. That
-- rewiring is Phase 3.
--
-- SAFE TO RE-RUN. Requires 222.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (236): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.sp_resolve_instance_detail','P') IS NULL
BEGIN
    PRINT 'ABORT (236): sp_resolve_instance_detail missing -- run 222 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_resolve_instance_detail -- 222's body minus the two frequency lines
-- =====================================================================
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
    LEFT   JOIN grac_practice.implementation_status_master ims
           ON ims.implementation_status_id = pi.implementation_status_id
    WHERE  pi.practice_instance_id = @practice_instance_id;
END
GO
PRINT '236: sp_resolve_instance_detail no longer projects instance-level frequency.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 236 verification ===';

SELECT 'ExecutionFrequency projection removed' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_instance_detail','P'))
                 NOT LIKE '%AS ExecutionFrequency,%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'AssuranceFrequency projection removed',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_instance_detail','P'))
                 NOT LIKE '%AS AssuranceFrequency,%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'frequency_master join removed',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_instance_detail','P'))
                 NOT LIKE '%grac_practice.frequency_master%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Non-frequency projections must still be there. If a mechanical
-- extraction ever removed too much, this catches it before anything
-- shipped a broken detail response.
SELECT 'AssuranceMode still projected',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_instance_detail','P'))
                 LIKE '%AS AssuranceMode%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'BusinessFunction still projected (222 columns intact)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_instance_detail','P'))
                 LIKE '%AS BusinessFunction%' THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '236 complete. Ship PracticeManagement.Api and PracticeManagement.Web with it.';
GO

SET NOEXEC OFF;
GO
