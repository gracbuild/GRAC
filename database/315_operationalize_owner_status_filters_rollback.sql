-- =====================================================================
-- 315_operationalize_owner_status_filters_rollback.sql
--
-- Reverts 315 by re-issuing sp_resolve_instance_list exactly as 290
-- left it -- same parameters, same predicates, same single result set,
-- without the owner/status filter parameters or the owner/status option
-- result sets.
--
-- The text below is a verbatim copy of the procedure from
-- 290_resolve_instance_list_total_rows.sql, so rolling 315 back
-- restores 290's definition rather than an approximation of it.
--
-- CONSEQUENCE OF RUNNING THIS
--   The Operationalize grid's Owner and Status filters have nothing to
--   call. resolve.cshtml must be rolled back with it (or its two new
--   selects hidden) -- a caller that still sends
--   @owner_employee_id / @implementation_status to this 290 shape will
--   get "too many arguments specified" (SQL error 8144), the same
--   failure any parameter drift between tiers produces.
--
-- Re-runnable: yes (CREATE OR ALTER).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_instance_list
    @organization_id     BIGINT,
    @caller_employee_id  BIGINT       = NULL,
    @is_admin            BIT          = 0,
    @search              NVARCHAR(200) = N'',
    @page_number         INT          = 1,
    @page_size           INT          = 25,
    @include_retired     BIT          = 0,
    @practice_id                 BIGINT = NULL,
    @organization_requirement_id BIGINT = NULL
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
    IF @include_retired IS NULL SET @include_retired = 0;

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
        dep.ResolvedDependencies     AS ResolvedDependencies,
        COUNT(*) OVER ()             AS TotalRows
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
      AND (@include_retired = 1 OR pi.status = N'Active')
      AND (@is_admin = 1 OR pi.primary_owner_id = @caller_employee_id)
      AND (@practice_id IS NULL OR pi.practice_id = @practice_id)
      AND (@organization_requirement_id IS NULL
           OR p.organization_requirement_id = @organization_requirement_id)
      AND (@search = N''
           OR pi.instance_code LIKE N'%' + @search + N'%'
           OR pi.instance_name LIKE N'%' + @search + N'%'
           OR p.practice_code  LIKE N'%' + @search + N'%'
           OR p.practice_name  LIKE N'%' + @search + N'%')
    ORDER  BY CASE WHEN pi.status = N'Active' THEN 0 ELSE 1 END,
              pi.instance_code
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

PRINT '315 rollback: sp_resolve_instance_list restored to the 290 definition (no owner/status filters or option sets).';
GO
