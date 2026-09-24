-- =====================================================================
-- 287 Resolve workspace -- restore a retired practice instance
--     (Practice Instance form slimming, stage 3 and last)
--
-- WHY
-- ---
-- 222 gave Resolve the profile save, the retirement act and the
-- dependency categories -- everything 139's sentence blocked on:
--
--     "Retiring an instance stays an explicit act on the Practice
--      Instances screen."
--
-- But retirement was a ONE-WAY DOOR. sp_resolve_instance_retire sets
-- status to Inactive and nothing anywhere could set it back. The only
-- route to a retired instance was the Practice Instances grid, whose
-- status filter could still find it -- so that screen could not be
-- withdrawn, and an instance archived by a stray click was archived for
-- good.
--
-- 139 is deliberately add-only precisely BECAUSE an instance carries
-- evidence, assurance history and open tasks. An act with those stakes
-- and no inverse is the sharp edge of that decision, not a cosmetic gap.
--
-- WHAT THIS ADDS
--   sp_resolve_instance_list      re-issued: + @include_retired
--   sp_resolve_instance_restore   the inverse of 222's retire
--
-- ---------------------------------------------------------------------
-- DECISION -- @include_retired DEFAULTS TO 0
-- ---------------------------------------------------------------------
-- Every existing caller passes six parameters and gets exactly the list
-- it got yesterday: active only. The Operationalize list is a work
-- queue, and one that silently starts including retired rows is worse
-- than one that cannot show them at all. Seeing them is a deliberate
-- act, so it is an opt-in flag behind a toggle on the screen.
--
-- ---------------------------------------------------------------------
-- WHY THE LIST PROCEDURE IS RE-ISSUED TOO
-- ---------------------------------------------------------------------
-- sp_resolve_instance_list carries
--
--     AND pi.status = N'Active'
--
-- and that is exactly what makes a retired instance unreachable. The
-- Operationalize list (Views/Practice/Partials/resolve.cshtml, line 151)
-- fetches /practice/api/workflow/resolve/instances, which runs this
-- procedure -- so retiring an instance drops it out of the only list
-- that shows instances, with nothing to bring it back into view.
--
-- It is NOT the generic gateway grid. 'resolve' stopped being a
-- practice.js screen at 140/141 and became its own partial; the
-- 'practice-operationalization' branch in 002 is a different screen
-- (the dependency workbench) and is not involved here.
--
-- ---------------------------------------------------------------------
-- DECISION -- OWNER SCOPING IS LEFT EXACTLY AS 141 WROTE IT
-- ---------------------------------------------------------------------
-- This list shows a non-admin only the instances they own:
--
--     AND (@is_admin = 1 OR pi.primary_owner_id = @caller_employee_id)
--
-- The Practice Instances grid (002's 'practice-instances' branch) has NO
-- owner predicate at all -- it is organisation-scoped only. So the two
-- screens disagree about whose instances a user may see, and the
-- question when retiring that screen is which of them is right.
--
-- It is this one, and no new mode was added, because "@is_admin" here
-- does not mean system administrator. WorkflowController stamps it from
-- the session's DATA SCOPE: GLOBAL or ORGANIZATION scope = 1, EMPLOYEE
-- scope = 0. So everybody whose data scope is organisation-wide ALREADY
-- sees every instance in the organisation through this procedure. The
-- only people who would lose an organisation-wide view are
-- employee-scoped users -- who, by the definition of their scope, were
-- never supposed to have one.
--
-- Retiring the Practice Instances grid therefore closes an
-- inconsistency rather than removing a capability. Nothing here needed
-- an "all instances" flag; the data scope already is one.
--
-- ---------------------------------------------------------------------
-- DECISION -- RESTORE MIRRORS RETIRE'S RULES EXACTLY
-- ---------------------------------------------------------------------
-- Same ownership test (@is_admin = 1 OR primary_owner_id = caller),
-- same "already in that state" refusal, same shape of result set. An
-- owner who can retire their own instance can restore it; an owner who
-- cannot see another's cannot resurrect it either.
--
-- ---------------------------------------------------------------------
-- DECISION -- RESTORE REBUILDS NOTHING
-- ---------------------------------------------------------------------
-- Retirement sets status and record_status_id and touches nothing else
-- -- obligations, dependencies, evidence and tasks are all left where
-- they were, which is what 222's confirmation text promises the user.
-- Restore therefore only has to put those two columns back. Re-deriving
-- anything would be inventing state the retirement never destroyed.
--
-- ERROR CODE RANGE: 52810-52819 (52600-52699 belong to 141 and 222,
--                   52700-52805 are taken elsewhere).
-- Re-runnable: yes (CREATE OR ALTER).
-- Rollback: database/287_resolve_instance_retired_visibility_rollback.sql
-- DEPENDS ON: 222 (sp_resolve_instance_retire, whose inverse this is).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_resolve_instance_retire','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_resolve_instance_list','P') IS NULL
BEGIN
    PRINT 'ABORT (287): sp_resolve_instance_retire / _list missing. Run 141 and 222 first.';
    RAISERROR('287_resolve_instance_retired_visibility: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_resolve_instance_list   -- re-issued from 141
--
-- IDENTICAL to 141's version except for the new parameter, the one line
-- of the WHERE clause it governs, and the ordering. The projection, both
-- OUTER APPLY progress blocks, the search predicate and the paging are
-- reproduced unchanged: this is a CREATE OR ALTER of the whole
-- procedure, and dropping any of them would silently remove a column
-- resolve.cshtml reads by name.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_instance_list
    @organization_id     BIGINT,
    @caller_employee_id  BIGINT       = NULL,
    @is_admin            BIT          = 0,
    @search              NVARCHAR(200) = N'',
    @page_number         INT          = 1,
    @page_size           INT          = 25,
    -- NEW in 287. 0 = active only, which is what every pre-287 caller
    -- gets without changing a line.
    @include_retired     BIT          = 0,
    -- NEW in 287. The drill-down filters the Practice Instances grid
    -- has and this list did not. Practices and Organization Requirements
    -- both carry a "Practice Instances" row action that navigates
    -- filtered by one of these; without them here, those two actions had
    -- nowhere to go but the screen this work is retiring.
    -- Both NULL = no opinion, so every existing caller is unaffected.
    @practice_id                 BIGINT = NULL,
    @organization_requirement_id BIGINT = NULL
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
      -- THE ONE CHANGED PREDICATE. Was: AND pi.status = N'Active'
      AND (@include_retired = 1 OR pi.status = N'Active')
      -- ANDed independently of the status test above, so opting into
      -- retired rows never widens WHOSE rows a non-admin can see.
      AND (@is_admin = 1 OR pi.primary_owner_id = @caller_employee_id)
      -- Drill-down. organization_requirement_id lives on practice, not on
      -- practice_instance, which is why this filters through p rather
      -- than pi -- the same join 002's practice-instances branch uses.
      AND (@practice_id IS NULL OR pi.practice_id = @practice_id)
      AND (@organization_requirement_id IS NULL
           OR p.organization_requirement_id = @organization_requirement_id)
      AND (@search = N''
           OR pi.instance_code LIKE N'%' + @search + N'%'
           OR pi.instance_name LIKE N'%' + @search + N'%'
           OR p.practice_code  LIKE N'%' + @search + N'%'
           OR p.practice_name  LIKE N'%' + @search + N'%')
    -- Active first when both are shown, so the work queue still reads as
    -- a work queue and retired rows collect below it rather than
    -- interleaving by code.
    ORDER  BY CASE WHEN pi.status = N'Active' THEN 0 ELSE 1 END,
              pi.instance_code
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- 2. sp_resolve_instance_restore
--
-- The inverse of 222's sp_resolve_instance_retire, guard for guard.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_instance_restore
    @practice_instance_id BIGINT,
    @caller_employee_id   BIGINT        = NULL,
    @is_admin             BIT           = 0,
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52810, 'sp_resolve_instance_restore: practice_instance_id is required.', 1;

    DECLARE @current_owner_id BIGINT, @current_status NVARCHAR(30), @practice_id BIGINT;
    SELECT @current_owner_id = primary_owner_id,
           @current_status   = status,
           @practice_id      = practice_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @current_status IS NULL
        THROW 52811, 'sp_resolve_instance_restore: instance not found.', 1;

    IF @is_admin = 0 AND ISNULL(@current_owner_id, -1) <> ISNULL(@caller_employee_id, -2)
        THROW 52812, 'sp_resolve_instance_restore: this practice instance belongs to another owner.', 1;

    IF @current_status = N'Active'
        THROW 52813, 'sp_resolve_instance_restore: this practice instance is already active.', 1;

    -- A restored instance immediately becomes assurance-eligible and
    -- starts appearing in work queues again. Doing that under a practice
    -- that is itself retired would put an orphan back into circulation,
    -- so it is refused with a message naming the actual blocker.
    IF EXISTS (SELECT 1 FROM grac_practice.practice
                WHERE practice_id = @practice_id AND status <> N'Active')
        THROW 52814, 'sp_resolve_instance_restore: the parent practice is not active. Restore the practice first.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM   grac_practice.record_status_master
        WHERE  status_code = N'Active' OR status_name = N'Active'
        ORDER  BY record_status_id
    );

    UPDATE grac_practice.practice_instance
       SET status           = N'Active',
           record_status_id = COALESCE(@active_record_status_id, record_status_id),
           updated_by       = @actor,
           updated_dt       = SYSUTCDATETIME()
     WHERE practice_instance_id = @practice_instance_id;

    SELECT CAST(1 AS BIT) AS Success,
           N'Practice instance restored.' AS Message,
           pi.status AS Status
    FROM   grac_practice.practice_instance pi
    WHERE  pi.practice_instance_id = @practice_instance_id;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '287 restore procedure exists' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_instance_restore','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- Retire is what this is the inverse of. If 222 were ever rolled back
-- without this, restore would be the only half of a pair.
SELECT '287 retire still present (the pair)' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_instance_retire','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL -- 222 has been rolled back' END AS Result;

SELECT '287 list takes @include_retired' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_instance_list')
                            AND name = '@include_retired')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- The default is what protects every existing caller. If this fails, the
-- Operationalize work queue has started showing retired rows to people
-- who never asked for them.
SELECT '287 @include_retired defaults to 0' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_instance_list')
                            AND name = '@include_retired'
                            AND has_default_value = 1
                            AND default_value = 0)
            THEN 'PASS' ELSE 'FAIL -- existing callers would see retired rows' END AS Result;

-- resolve.cshtml reads all sixteen columns by name, so the re-issue must
-- not have dropped one.
SELECT '287 list still returns 16 columns' AS Check_,
       CASE WHEN (SELECT COUNT(*)
                    FROM sys.dm_exec_describe_first_result_set(
                         N'EXEC grac_practice.sp_resolve_instance_list @organization_id = 1, @is_admin = 1', NULL, 0)
                   WHERE is_hidden = 0) = 16
            THEN 'PASS' ELSE 'CHECK -- column count changed, compare against 141' END AS Result;

SELECT '287 instances now restorable' AS Check_,
       CAST((SELECT COUNT(*) FROM grac_practice.practice_instance
              WHERE status <> N'Active') AS NVARCHAR(20))
       + ' retired instance(s) can now be brought back' AS Result;

PRINT '287 practice instance restore installed.';
PRINT '     Mirrors 222 retire: same ownership test, same state guard.';
PRINT '     Refuses when the parent practice is itself inactive (52814).';
PRINT '     Smoke test:';
PRINT '       EXEC grac_practice.sp_resolve_instance_restore @practice_instance_id = <id>, @is_admin = 1;';
GO
SET NOEXEC OFF;
GO
