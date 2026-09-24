-- =====================================================================
-- 315_operationalize_owner_status_filters.sql
--
-- PURPOSE
--   Add an Owner filter and a Status (Implementation Status) filter to
--   the Operationalize grid (Views/Practice/Partials/resolve.cshtml),
--   answering both the row filter itself AND the two dropdowns' option
--   lists, in the same round trip the grid already makes.
--
-- ---------------------------------------------------------------------
-- WHAT CHANGES IN sp_resolve_instance_list
-- ---------------------------------------------------------------------
--   1. Two new optional parameters, both NULL = no opinion (existing
--      callers -- risk-centre style drill-downs, any tooling -- are
--      unaffected):
--        @owner_employee_id     BIGINT
--        @implementation_status NVARCHAR(100)
--      ANDed into the existing WHERE clause exactly like @practice_id
--      was in 287 -- narrows rows, never widens who can see what. The
--      ownership test (@is_admin = 1 OR pi.primary_owner_id =
--      @caller_employee_id) still runs first and independently, so a
--      non-admin cannot use @owner_employee_id to reach someone else's
--      instances.
--
--   2. Two new result sets, appended after the row set:
--        Result set 2 -- distinct owners in scope (OwnerEmployeeId,
--                         OwnerName)
--        Result set 3 -- distinct implementation-status values in scope
--                         (ImplementationStatus)
--      Both use the SAME scope predicates as the row set (organisation,
--      retired visibility, ownership, practice / requirement drill-down)
--      but deliberately EXCLUDE @search, @owner_employee_id and
--      @implementation_status themselves -- a filter's own dropdown must
--      offer every value the caller could pick, not just the ones that
--      survive whatever is currently selected. Computed here, not
--      derived from the current page in the browser, because the grid
--      is paged: a value on page 3 must still appear in the dropdown
--      while the caller is looking at page 1.
--
--   This is the same shape sp_risk_mapping_get (266) uses for its
--   category result set -- the option list is a rule, and a rule
--   computed once in the procedure cannot drift from the rows it
--   describes.
--
-- ---------------------------------------------------------------------
-- WHY THIS IS SAFE FOR EXISTING CALLERS
-- ---------------------------------------------------------------------
--   Row set: two new columns... no -- two new PARAMETERS, both
--   defaulted, ANDed as "no opinion when NULL". No existing predicate,
--   join, projection column, ordering or paging changes. TotalRows
--   (290) is carried forward unchanged, still last in the projection.
--
--   The two new result sets are ADDITIONAL, not replacements.
--   ResolveWorkspaceService reads the row set with the same reader loop
--   it already has; a caller that never calls NextResultAsync() a
--   second and third time (i.e. code built before this migration) simply
--   never touches them, exactly like a caller that ignores TotalRows.
--
-- Re-runnable: yes (CREATE OR ALTER).
-- Rollback: database/315_operationalize_owner_status_filters_rollback.sql
--   (restores the 290 definition -- single result set, no owner/status
--   parameters).
-- DEPENDS ON: 287, 290 (whose combined shape this re-issues in full).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_resolve_instance_list','P') IS NULL
BEGIN
    PRINT 'ABORT (315): sp_resolve_instance_list missing. Run 141, 287 and 290 first.';
    RAISERROR('315_operationalize_owner_status_filters: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- Guard the 287 shape specifically, same check 290 used: reissuing over
-- a pre-287 version would silently drop @include_retired and the two
-- drill-down parameters this migration also depends on being present.
IF NOT EXISTS (
        SELECT 1
        FROM   sys.parameters
        WHERE  object_id = OBJECT_ID('grac_practice.sp_resolve_instance_list')
          AND  name      = '@organization_requirement_id')
BEGIN
    PRINT 'ABORT (315): sp_resolve_instance_list predates 287 (@organization_requirement_id missing). Run 287 and 290 first.';
    RAISERROR('315_operationalize_owner_status_filters: 287 has not been applied.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_resolve_instance_list -- re-issued from 290
--
-- IDENTICAL to 290 except:
--   * two new parameters, @owner_employee_id / @implementation_status
--   * two new predicates on the row set (marked below)
--   * two new result sets, appended after the row set (marked below)
-- =====================================================================
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

PRINT '315: sp_resolve_instance_list accepts @owner_employee_id / @implementation_status and returns owner/status option sets.';
GO

SET NOEXEC OFF;
GO
