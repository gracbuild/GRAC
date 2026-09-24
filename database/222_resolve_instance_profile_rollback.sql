-- =====================================================================
-- 222 Resolve instance profile -- ROLLBACK
--
-- Undoes database/222_resolve_instance_profile.sql:
--   1. Restores grac_practice.sp_resolve_instance_detail to the exact
--      141_resolve_workspace_procs.sql body (no BusinessFunctionId /
--      BusinessFunction / OwnerDepartmentId columns).
--   2. Drops the four procedures 222 introduced.
--
-- ORDER MATTERS the other way round from most rollbacks: the detail
-- procedure is restored FIRST, because a Web tier still running the 222
-- build reads those columns, and leaving the new procedures in place
-- while the detail feed has already lost them is the one combination
-- that fails on read rather than on write.
--
-- NO DATA IS UNDONE. 222 writes nothing on deploy. Profile edits,
-- retirements and dependency-category changes made through it are
-- ordinary rows in practice_instance and practice_instance_dependency,
-- indistinguishable from the same change made on the Practice Instances
-- screen -- which is the point of stage 2, and not something a rollback
-- should try to guess at.
--
-- REVERT THE APP FIRST. The Resolve workspace posts to
-- /resolve/profile, /resolve/retire and /resolve/dependency-types; with
-- the procedures dropped those answer 500 until the Api build that knows
-- about them is rolled back too.
--
-- ASCII-only on purpose (see the forward script header).
-- Idempotent: safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (222 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.practice_instance','U') IS NULL
BEGIN
    PRINT 'ABORT (222 rollback): practice_instance missing.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_resolve_instance_detail -- back to the 141 body.
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
        pi.status                AS Status
    FROM   grac_practice.practice_instance pi
    JOIN   grac_practice.practice p ON p.practice_id = pi.practice_id
    JOIN   grac_practice.organization o ON o.organization_id = pi.organization_id
    LEFT   JOIN grac_practice.organization_employee owner_emp
           ON owner_emp.employee_id = pi.primary_owner_id
    LEFT   JOIN grac_practice.organization_department dept
           ON dept.department_id = pi.department_id
    LEFT   JOIN grac_practice.frequency_master ef ON ef.frequency_id = pi.execution_frequency_id
    LEFT   JOIN grac_practice.frequency_master af ON af.frequency_id = pi.assurance_frequency_id
    LEFT   JOIN grac_practice.implementation_status_master ims
           ON ims.implementation_status_id = pi.implementation_status_id
    WHERE  pi.practice_instance_id = @practice_instance_id;
END
GO

PRINT '222 rollback: sp_resolve_instance_detail restored to the 141 body.';
GO

-- =====================================================================
-- 2. Drop what 222 introduced.
-- =====================================================================
IF OBJECT_ID('grac_practice.sp_resolve_dependency_type_save','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_resolve_dependency_type_save;
    PRINT '222 rollback: sp_resolve_dependency_type_save dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_resolve_dependency_type_list','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_resolve_dependency_type_list;
    PRINT '222 rollback: sp_resolve_dependency_type_list dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_resolve_instance_retire','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_resolve_instance_retire;
    PRINT '222 rollback: sp_resolve_instance_retire dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_resolve_instance_profile_save','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_resolve_instance_profile_save;
    PRINT '222 rollback: sp_resolve_instance_profile_save dropped.';
END
GO

-- =====================================================================
-- 3. Verification
-- =====================================================================
PRINT '=== 222 rollback verification ===';

SELECT 'sp_resolve_instance_detail is the 141 body' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_instance_detail','P'))
                 LIKE '%BusinessFunctionId%'
            THEN 'FAIL -- still carries the 222 columns' ELSE 'PASS' END AS Result
UNION ALL
SELECT '222 procedures removed',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_instance_profile_save','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_resolve_instance_retire','P')       IS NULL
             AND OBJECT_ID('grac_practice.sp_resolve_dependency_type_list','P')  IS NULL
             AND OBJECT_ID('grac_practice.sp_resolve_dependency_type_save','P')  IS NULL
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '222 Resolve instance profile rollback complete.';
PRINT 'The Practice Instances screen was never removed, so instance profile,';
PRINT 'owner and retirement remain editable there.';
GO

SET NOEXEC OFF;
GO
