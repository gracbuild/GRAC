-- =====================================================================
-- 287 ROLLBACK -- retired instance visibility and restore
--
-- Drops sp_resolve_instance_restore and puts sp_resolve_instance_list
-- back to 141's shape: six parameters, active rows only.
--
-- READ THIS BEFORE RUNNING IT
--   This re-opens the hole 287 closed. A retired instance disappears
--   from the Operationalize list again and nothing can restore it. Its
--   evidence, obligations and history all survive -- retirement only
--   ever changed two columns -- but there is no route back to them.
--
--   If migration 288 has already withdrawn the Practice Instances
--   screen, roll that back too, or retired instances become entirely
--   unreachable. The count at the bottom says how many rows that is on
--   this database.
--
-- The list procedure is restored by reproducing 141's body, NOT by
-- re-running 141 -- that file also creates five other procedures, and
-- re-running it would silently revert 222's re-issue of
-- sp_resolve_instance_detail as well.
--
-- Re-runnable: yes.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_resolve_instance_restore','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_resolve_instance_restore;
GO

-- ---- sp_resolve_instance_list, exactly as 141 left it ---------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_instance_list
    @organization_id     BIGINT,
    @caller_employee_id  BIGINT       = NULL,
    @is_admin            BIT          = 0,
    @search              NVARCHAR(200) = N'',
    @page_number         INT          = 1,
    @page_size           INT          = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 52600, 'sp_resolve_instance_list: organization_id is required.', 1;

    IF @is_admin = 0 AND @caller_employee_id IS NULL
        THROW 52601, 'sp_resolve_instance_list: caller_employee_id is required for a non-admin caller.', 1;

    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    IF @search IS NULL SET @search = N'';

    DECLARE @offset INT = (@page_number - 1) * @page_size;

    SELECT
        pi.practice_instance_id      AS PracticeInstanceId,
        pi.instance_code             AS InstanceCode,
        pi.instance_name             AS InstanceName,
        p.practice_id                AS PracticeId,
        p.practice_code              AS PracticeCode,
        p.practice_name              AS PracticeName,
        pi.primary_owner_id          AS OwnerEmployeeId,
        COALESCE(owner_emp.employee_name, pi.primary_owner) AS OwnerName,
        COALESCE(dept.department_name, pi.department)       AS Department,
        pi.criticality               AS Criticality,
        COALESCE(ims.status_name, pi.implementation_status) AS ImplementationStatus,
        pi.status                    AS Status,
        ob.TotalObligations          AS TotalObligations,
        ob.AdoptedObligations        AS AdoptedObligations,
        dep.TotalDependencies        AS TotalDependencies,
        dep.ResolvedDependencies     AS ResolvedDependencies
    FROM   grac_practice.practice_instance pi
    JOIN   grac_practice.practice p
           ON p.practice_id = pi.practice_id
    LEFT   JOIN grac_practice.organization_employee owner_emp
           ON owner_emp.employee_id = pi.primary_owner_id
    LEFT   JOIN grac_practice.organization_department dept
           ON dept.department_id = pi.department_id
    LEFT   JOIN grac_practice.implementation_status_master ims
           ON ims.implementation_status_id = pi.implementation_status_id
    OUTER  APPLY (
        SELECT COUNT(*) AS TotalObligations,
               SUM(CASE WHEN a.practice_instance_obligation_id IS NOT NULL THEN 1 ELSE 0 END) AS AdoptedObligations
        FROM (
            SELECT DISTINCT orm.obligation_id
            FROM   grac_practice.practice pp
            JOIN   grac_practice.organization_requirement req
                   ON req.organization_requirement_id = pp.organization_requirement_id
            LEFT   JOIN GRAC_New.requirement repo_req
                   ON repo_req.requirement_code = req.requirement_code AND repo_req.status = N'Active'
            JOIN   GRAC_New.obligation_requirement_release_map orm
                   ON orm.requirement_id = COALESCE(req.repository_requirement_id, repo_req.requirement_id)
                  AND orm.status = N'Active'
            JOIN   GRAC_New.requirement_obligation ro
                   ON ro.obligation_id = orm.obligation_id AND ro.status = N'Active'
            WHERE  pp.practice_id = pi.practice_id
              AND  EXISTS (SELECT 1 FROM grac_practice.repository_subscription s
                            WHERE s.organization_id = pi.organization_id
                              AND s.release_id = orm.release_id
                              AND s.status = N'Active')
        ) o
        LEFT JOIN grac_practice.practice_instance_obligation a
               ON a.practice_instance_id = pi.practice_instance_id
              AND a.obligation_id        = o.obligation_id
              AND a.status               = N'Active'
    ) ob
    OUTER  APPLY (
        SELECT COUNT(DISTINCT d.dependency_type_id) AS TotalDependencies,
               COUNT(DISTINCT r.dependency_type_id) AS ResolvedDependencies
        FROM   grac_practice.practice_instance_dependency d
        LEFT   JOIN grac_practice.practice_dependency_resolution r
               ON r.practice_instance_id = d.practice_instance_id
              AND r.dependency_type_id   = d.dependency_type_id
              AND r.is_active            = 1
        WHERE  d.practice_instance_id = pi.practice_instance_id
          AND  d.status = N'Active'
    ) dep
    WHERE  pi.organization_id = @organization_id
      AND  pi.status = N'Active'
      AND (@is_admin = 1 OR pi.primary_owner_id = @caller_employee_id)
      AND (@search = N''
           OR pi.instance_code LIKE N'%' + @search + N'%'
           OR pi.instance_name LIKE N'%' + @search + N'%'
           OR p.practice_code  LIKE N'%' + @search + N'%'
           OR p.practice_name  LIKE N'%' + @search + N'%')
    ORDER  BY pi.instance_code
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

SELECT '287 rollback: restore procedure dropped' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_instance_restore','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- 222's retire must be untouched -- 287 never edited it, and if it is
-- missing then 222 was rolled back independently.
SELECT '287 rollback: 222 retire untouched' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_instance_retire','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL -- 222 has been rolled back separately' END AS Result;

SELECT '287 rollback: list back to six parameters' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.parameters
                              WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_instance_list')
                                AND name = '@include_retired')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- The cost of this rollback, stated in rows rather than left implicit.
SELECT '287 rollback: instances left stranded' AS Check_,
       CAST((SELECT COUNT(*) FROM grac_practice.practice_instance
              WHERE status <> N'Active') AS NVARCHAR(20))
       + ' retired instance(s) can no longer be restored' AS Result;

PRINT '287 rollback complete.';
PRINT '     WARNING: retirement is a one-way door again.';
PRINT '     Roll back 288 too if the Practice Instances screen has been withdrawn.';
GO
