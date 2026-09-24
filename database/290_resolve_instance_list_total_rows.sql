-- =====================================================================
-- 290_resolve_instance_list_total_rows.sql
--
-- PURPOSE
--   Add COUNT(*) OVER () AS TotalRows to sp_resolve_instance_list so the
--   Operationalize grid can page properly.
--
-- ---------------------------------------------------------------------
-- WHY -- THE GRID IS LOSING ROWS TODAY
-- ---------------------------------------------------------------------
-- This procedure has paged since 141:
--
--     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
--     IF @page_size > 200 SET @page_size = 200;
--
-- but Views/Practice/Partials/resolve.cshtml has no pager. It works
-- around the absence by asking for one big page:
--
--     + '&pageSize=200',        -- resolve.cshtml
--
-- and the clamp above quietly cuts anything larger back to 200. So 200
-- is a hard ceiling on both sides. An organisation with 201 practice
-- instances has one that no filter, sort or scroll will reveal -- and
-- because Operationalize is a work queue, an instance nobody can see is
-- an instance nobody actions.
--
-- The grid cannot simply be given a pager either, because this
-- procedure returns no total. Without one the UI cannot draw a row
-- range, and cannot tell a full last page from a page with more behind
-- it -- which is precisely the guess that
-- docs/grid-and-pagination-standard.md exists to remove.
--
-- ---------------------------------------------------------------------
-- WHY COUNT(*) OVER () AND NOT A SECOND RESULT SET
-- ---------------------------------------------------------------------
-- Every other paged procedure in this schema returns the total the same
-- way -- a window function, last in the projection, evaluated over the
-- filtered set before OFFSET/FETCH trims it. Matching that shape means
-- ResolveWorkspaceService reads it with the same single reader loop it
-- already has, and pm-grid consumes it with no special case. A second
-- result set would need a NextResult() and would make this the only
-- paged list in the module that pages differently.
--
-- ---------------------------------------------------------------------
-- WHY THIS IS SAFE FOR EXISTING CALLERS
-- ---------------------------------------------------------------------
-- Purely additive: one extra column, appended last. Callers read by
-- name (reader["PracticeInstanceId"] and friends), so a column they do
-- not ask for is invisible to them. No parameter, predicate, join,
-- ordering or paging behaviour changes -- the whole point is that the
-- rows this returns are byte-for-byte what 287 returned, plus a count.
--
-- Everything else in the body is reproduced verbatim from 287. This is
-- a CREATE OR ALTER of the entire procedure, so anything dropped here
-- would silently disappear from the live definition -- including the
-- OUTER APPLY progress blocks and the drill-down filters that
-- resolve.cshtml reads by name.
--
-- Re-runnable: yes (CREATE OR ALTER).
-- Rollback: database/290_resolve_instance_list_total_rows_rollback.sql
-- DEPENDS ON: 287 (whose version of this procedure it re-issues).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_resolve_instance_list','P') IS NULL
BEGIN
    PRINT 'ABORT (290): sp_resolve_instance_list missing. Run 141 and 287 first.';
    RAISERROR('290_resolve_instance_list_total_rows: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- Guard the 287 shape specifically. Re-issuing over 141's version would
-- silently reintroduce @include_retired and the two drill-down
-- parameters, which is fine -- but it would also mean 287's WHERE clause
-- had never run, and that is worth knowing before this overwrites it.
IF NOT EXISTS (
        SELECT 1
        FROM   sys.parameters
        WHERE  object_id = OBJECT_ID('grac_practice.sp_resolve_instance_list')
          AND  name      = '@include_retired')
BEGIN
    PRINT 'ABORT (290): sp_resolve_instance_list predates 287 (@include_retired missing). Run 287 first.';
    RAISERROR('290_resolve_instance_list_total_rows: 287 has not been applied.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_resolve_instance_list -- re-issued from 287
--
-- IDENTICAL to 287 except for the single TotalRows column marked below.
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
    @organization_requirement_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Reproduced exactly as 287 wrote it. Tempting to add "OR
    -- @organization_id <= 0" here, but that would newly THROW where the
    -- procedure previously returned an empty set, and 290 is supposed to
    -- add a column and change nothing else.
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
        -- THE ONLY ADDITION IN 290. Counted over the filtered set, so it
        -- is the total the WHERE clause matched, not the page size and
        -- not the table. Last in the projection to match every other
        -- paged procedure in this schema.
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

PRINT '290: sp_resolve_instance_list now returns TotalRows.';
GO

SET NOEXEC OFF;
GO
