-- =====================================================================
-- 465_operationalize_framework_filter_rollback.sql
-- Restores sp_resolve_instance_list to its 394 body (drops the
-- @release_id Framework filter). ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
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
    @organization_requirement_id BIGINT = NULL,
    -- NEW in 315. Both NULL = no opinion, so every existing caller
    -- (risk-centre drill-downs, tooling, older API binaries that never
    -- pass them) sees exactly the rows it saw before.
    @owner_employee_id     BIGINT        = NULL,
    @implementation_status NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 52600, 'sp_resolve_instance_list: organization_id is required.', 1;

    -- A non-admin with no employee id would otherwise see everything.
    IF @is_admin = 0 AND @caller_employee_id IS NULL
        THROW 52601, 'sp_resolve_instance_list: caller_employee_id is required for a non-admin caller.', 1;

    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    IF @search IS NULL SET @search = N'';
    IF @include_retired IS NULL SET @include_retired = 0;
    IF @owner_employee_id IS NOT NULL AND @owner_employee_id <= 0 SET @owner_employee_id = NULL;
    IF @implementation_status IS NOT NULL AND LTRIM(RTRIM(@implementation_status)) = N''
        SET @implementation_status = NULL;

    DECLARE @offset INT = (@page_number - 1) * @page_size;

    -- ---- 1. The page of instances -------------------------------
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
            LEFT   JOIN grac_practice.fn_org_requirement(@organization_id) repo_req
                   ON repo_req.requirement_code = req.requirement_code AND repo_req.status = N'Active'
            JOIN   grac_practice.fn_org_obligation_requirement_release_map(@organization_id) orm
                   ON orm.requirement_id = COALESCE(req.repository_requirement_id, repo_req.requirement_id)
                  AND orm.status = N'Active'
            JOIN   grac_practice.fn_org_requirement_obligation(@organization_id) ro
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
      -- NEW in 315. NULL = no opinion.
      AND (@owner_employee_id IS NULL OR pi.primary_owner_id = @owner_employee_id)
      AND (@implementation_status IS NULL
           OR COALESCE(ims.status_name, pi.implementation_status) = @implementation_status)
      AND (@search = N''
           OR pi.instance_code LIKE N'%' + @search + N'%'
           OR pi.instance_name LIKE N'%' + @search + N'%'
           OR p.practice_code  LIKE N'%' + @search + N'%'
           OR p.practice_name  LIKE N'%' + @search + N'%')
    ORDER  BY CASE WHEN pi.status = N'Active' THEN 0 ELSE 1 END,
              pi.instance_code
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;

    -- ---- 2. Owner options, in scope -------------------------------
    -- Same scope as the row set, WITHOUT @search / @owner_employee_id /
    -- @implementation_status: the dropdown must offer every owner the
    -- caller could filter to, including one whose only instance sits on
    -- a page not currently loaded.
    SELECT DISTINCT
        pi.primary_owner_id AS OwnerEmployeeId,
        COALESCE(owner_emp.employee_name, pi.primary_owner) AS OwnerName
    FROM   grac_practice.practice_instance pi
    JOIN   grac_practice.practice p
           ON p.practice_id = pi.practice_id
    LEFT   JOIN grac_practice.organization_employee owner_emp
           ON owner_emp.employee_id = pi.primary_owner_id
    WHERE  pi.organization_id = @organization_id
      AND (@include_retired = 1 OR pi.status = N'Active')
      AND (@is_admin = 1 OR pi.primary_owner_id = @caller_employee_id)
      AND (@practice_id IS NULL OR pi.practice_id = @practice_id)
      AND (@organization_requirement_id IS NULL
           OR p.organization_requirement_id = @organization_requirement_id)
      AND pi.primary_owner_id IS NOT NULL
    ORDER BY OwnerName;

    -- ---- 3. Status options, in scope -------------------------------
    -- Free text today (see docs/organization-practices-implementation-
    -- status.md -- pi.implementation_status can hold a legacy value with
    -- no row in implementation_status_master, e.g. the pre-045 default
    -- "Not Started"), so the option list is read off the data rather
    -- than off the master table -- a fixed master list would silently
    -- omit any value the master does not carry.
    SELECT DISTINCT
        COALESCE(ims.status_name, pi.implementation_status) AS ImplementationStatus
    FROM   grac_practice.practice_instance pi
    JOIN   grac_practice.practice p
           ON p.practice_id = pi.practice_id
    LEFT   JOIN grac_practice.implementation_status_master ims
           ON ims.implementation_status_id = pi.implementation_status_id
    WHERE  pi.organization_id = @organization_id
      AND (@include_retired = 1 OR pi.status = N'Active')
      AND (@is_admin = 1 OR pi.primary_owner_id = @caller_employee_id)
      AND (@practice_id IS NULL OR pi.practice_id = @practice_id)
      AND (@organization_requirement_id IS NULL
           OR p.organization_requirement_id = @organization_requirement_id)
      AND COALESCE(ims.status_name, pi.implementation_status) IS NOT NULL
    ORDER BY ImplementationStatus;
END
GO
