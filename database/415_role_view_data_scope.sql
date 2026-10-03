-- =====================================================================
-- 415 Role View Data Scope (Advanced Settings on Role Menu Permission)
--
-- WHAT AND WHY
-- ------------
-- The role matrix decides WHICH menus a role may View / Add / Edit /
-- Delete / Approve. This adds a second, role-level setting -- View Data
-- Scope -- that decides WHICH RECORDS a View shows:
--
--   ALL       All records. No restriction -- what every role did before
--             415. Every existing role gets it (column default), so no
--             existing user is restricted by this migration.
--   LOCATION  records of the reader's own location
--   TEAM      records assigned to the reader's teams
--   OWNER     only records the reader owns ("Assigned Owner")
--
-- The reader's location / teams / identity are read LIVE at query time;
-- nothing about a person is stored on the role.
--
-- A reader with several roles sees the UNION -- a record any of their
-- roles would show -- the same rule sign-in uses to merge the menu
-- permissions (MAX of can_*). Any role on ALL means unrestricted.
--
-- RELATIONSHIPS USED (existing; nothing duplicated)
--   reader -> location  organization_employee.location_id
--   reader -> teams     organization_team_member (active by
--                       record_status_id, the rule 362 established)
--   record -> owner     each table's own owner column (below)
--   record -> team      the owner's teams, and -- for a practice
--                       instance and what is linked to it -- the TEAM
--                       the instance was configured for
--                       (practice_dependency_resolution, 139)
--   record -> location  the owner's location, and an instance's LOCATION
--                       dependency where one is resolved
--
-- ENFORCEMENT: ONE ROW-LEVEL SECURITY POLICY
-- ------------------------------------------
-- Not a filter per screen and never in the browser. The API, for every
-- READ request, runs sp_pm_view_scope_session_set on each connection it
-- opens (Infrastructure.ViewScopeSession). For a reader whose roles are
-- not "All records" that writes the scope into SESSION_CONTEXT, and the
-- security policy pm_view_data_scope_policy then filters EVERY query of
-- the scoped tables on that connection -- list, get-by-id, dashboards,
-- views, any procedure. Changing a URL, a record id, or calling another
-- page's API cannot reach a row outside the scope: SQL does not return it.
--
--   table                       owner column                  extra link
--   practice_instance           primary_owner_id              its own TEAM / LOCATION
--   practice_task               assigned_to_employee_id       linked_instance_id
--   custom_gap                  owner_employee_id             source instance
--   exception_request           owner_employee_id
--   risk_register               risk_owner_employee_id
--   risk_candidate              assigned_analyst_employee_id
--   org_assurance_plan          owner_employee_id
--   org_assurance_execution     owner_employee_id
--   org_assurance_observation   assigned_owner_employee_id
--
-- Writes are NOT filtered (the API never sets the scope on a write):
-- write procedures keep seeing every row for their own syncs, roll-ups
-- and duplicate checks, and the Edit / Delete model is unchanged. A
-- record outside the scope cannot be opened, so it cannot be opened for
-- editing either. When SESSION_CONTEXT is empty (system work, writes,
-- workers, scripts, every "All records" reader) the predicate is true.
-- SESSION_CONTEXT is cleared by sp_reset_connection on pooled reuse.
--
-- CONTENTS
--   1. organization_role.view_data_scope   NOT NULL DEFAULT 'ALL' + CHECK
--   2. sp_role_view_data_scope_get / _save (Advanced Settings read/write)
--   3. sp_pm_view_scope_session_set        (called by the API per read)
--   4. fn_pm_view_scope_core + three column-shaped wrappers
--   5. security policy pm_view_data_scope_policy (SCHEMABINDING = OFF, so
--      later migrations may still alter these tables freely)
--
-- Requires SQL Server 2016+ (row-level security, SESSION_CONTEXT).
-- Re-runnable. ASCII-only. Error codes 57320-57322.
-- Rollback: 415_role_view_data_scope_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) < 13
BEGIN
    RAISERROR('415: row-level security needs SQL Server 2016 or later.', 16, 1);
    SET NOEXEC ON;
END
GO

-- Every object and column read below.
IF OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_employee_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_team_member','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NULL
   OR OBJECT_ID('grac_practice.dependency_type_master','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','role_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','location_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance','primary_owner_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_task','assigned_to_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_task','linked_instance_id') IS NULL
   OR COL_LENGTH('grac_practice.custom_gap','owner_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.custom_gap','source_reference_type') IS NULL
   OR COL_LENGTH('grac_practice.custom_gap','source_reference_id') IS NULL
   OR COL_LENGTH('grac_practice.exception_request','owner_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.risk_register','risk_owner_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.risk_candidate','assigned_analyst_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_plan','owner_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_execution','owner_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_observation','assigned_owner_employee_id') IS NULL
BEGIN
    RAISERROR('415: prerequisites missing (027, 037, 054, 089, 098, 101, 109, 166, 205, 206, 362).', 16, 1);
    SET NOEXEC ON;
END
GO

-- The policy binds the functions below; drop it first so a re-run can
-- re-create them. Recreated in section 5.
IF EXISTS (SELECT 1 FROM sys.security_policies
            WHERE name = N'pm_view_data_scope_policy' AND schema_id = SCHEMA_ID(N'grac_practice'))
    DROP SECURITY POLICY grac_practice.pm_view_data_scope_policy;
GO

-- =====================================================================
-- 1. The setting
-- =====================================================================
IF COL_LENGTH('grac_practice.organization_role','view_data_scope') IS NULL
    ALTER TABLE grac_practice.organization_role
        ADD view_data_scope NVARCHAR(20) NOT NULL
            CONSTRAINT df_pm_org_role_view_data_scope DEFAULT N'ALL' WITH VALUES;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'ck_pm_org_role_view_data_scope')
    ALTER TABLE grac_practice.organization_role
        ADD CONSTRAINT ck_pm_org_role_view_data_scope
            CHECK (view_data_scope IN (N'ALL', N'LOCATION', N'TEAM', N'OWNER'));
GO

-- =====================================================================
-- 2. Read / write the setting (Role Menu Permission -> Advanced Settings)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_role_view_data_scope_get
    @organization_id BIGINT,
    @role_id         BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.role_id         AS RoleId,
           r.organization_id AS OrganizationId,
           r.view_data_scope AS ViewDataScope
      FROM grac_practice.organization_role r
     WHERE r.role_id = @role_id
       AND r.organization_id = @organization_id;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_role_view_data_scope_save
    @organization_id BIGINT,
    @role_id         BIGINT,
    @view_data_scope NVARCHAR(20),
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET @view_data_scope = UPPER(LTRIM(RTRIM(ISNULL(@view_data_scope, N''))));
    IF @view_data_scope NOT IN (N'ALL', N'LOCATION', N'TEAM', N'OWNER')
        THROW 57320, 'View Data Scope must be All records, Location, Team or Assigned Owner.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_role
                    WHERE role_id = @role_id AND organization_id = @organization_id)
        THROW 57321, 'The role does not belong to this organization.', 1;

    UPDATE grac_practice.organization_role
       SET view_data_scope = @view_data_scope,
           updated_by      = ISNULL(@actor, N'system'),
           updated_dt      = SYSUTCDATETIME()
     WHERE role_id = @role_id
       AND organization_id = @organization_id
       AND view_data_scope <> @view_data_scope;

    EXEC grac_practice.sp_role_view_data_scope_get @organization_id, @role_id;
END
GO

-- =====================================================================
-- 3. sp_pm_view_scope_session_set -- called by the API on each
--    connection of a READ request. Resolves the reader's roles the way
--    sign-in does (primary role + active organization_employee_role) and,
--    only when none of them is ALL, writes the scope into SESSION_CONTEXT.
--    Returns the effective scope: 'ALL', or e.g. ',TEAM,OWNER,'.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_pm_view_scope_session_set
    @employee_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @scopes TABLE (scope NVARCHAR(20) PRIMARY KEY);

    INSERT INTO @scopes (scope)
    SELECT DISTINCT r.view_data_scope
      FROM grac_practice.organization_role r
     WHERE r.role_id IN (SELECT er.role_id
                           FROM grac_practice.organization_employee_role er
                          WHERE er.employee_id = @employee_id
                            AND er.status = N'Active'
                         UNION
                         SELECT e.role_id
                           FROM grac_practice.organization_employee e
                          WHERE e.employee_id = @employee_id
                            AND e.role_id IS NOT NULL);

    -- No role, or any role on ALL: unrestricted, nothing is set.
    IF NOT EXISTS (SELECT 1 FROM @scopes)
       OR EXISTS (SELECT 1 FROM @scopes WHERE scope = N'ALL')
    BEGIN
        SELECT N'ALL' AS ViewDataScope;
        RETURN;
    END

    DECLARE @list NVARCHAR(100) = N','
        + (SELECT STRING_AGG(scope, N',') WITHIN GROUP (ORDER BY scope) FROM @scopes) + N',';
    DECLARE @location_id BIGINT =
        (SELECT e.location_id FROM grac_practice.organization_employee e WHERE e.employee_id = @employee_id);

    EXEC sys.sp_set_session_context @key = N'pm_view_scope',         @value = @list;
    EXEC sys.sp_set_session_context @key = N'pm_viewer_id',          @value = @employee_id;
    EXEC sys.sp_set_session_context @key = N'pm_viewer_location_id', @value = @location_id;

    SELECT @list AS ViewDataScope;
END
GO

-- =====================================================================
-- 4. The predicate -- ONE definition of "may this reader see the record"
--    (owner, linked practice instance, location), and three wrappers that
--    only adapt it to each table's columns.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_pm_view_scope_core
(
    @owner_employee_id    BIGINT,
    @practice_instance_id BIGINT,
    @location_id          BIGINT
)
RETURNS TABLE
AS
RETURN
SELECT 1 AS fn_result
 WHERE SESSION_CONTEXT(N'pm_view_scope') IS NULL
    -- Assigned Owner
    OR (CHARINDEX(N',OWNER,', CAST(SESSION_CONTEXT(N'pm_view_scope') AS NVARCHAR(100))) > 0
        AND @owner_employee_id = CAST(SESSION_CONTEXT(N'pm_viewer_id') AS BIGINT))
    -- Team: the owner shares an active team with the reader, or the
    -- record's practice instance was configured for one of the reader's
    -- active teams.
    OR (CHARINDEX(N',TEAM,', CAST(SESSION_CONTEXT(N'pm_view_scope') AS NVARCHAR(100))) > 0
        AND (   (@owner_employee_id IS NOT NULL AND EXISTS (
                    SELECT 1
                      FROM grac_practice.organization_team_member vm
                      JOIN grac_practice.record_status_master vs
                        ON vs.record_status_id = vm.record_status_id AND vs.status_code = N'Active'
                      JOIN grac_practice.organization_team_member om
                        ON om.team_id = vm.team_id
                      JOIN grac_practice.record_status_master os
                        ON os.record_status_id = om.record_status_id AND os.status_code = N'Active'
                     WHERE vm.employee_id = CAST(SESSION_CONTEXT(N'pm_viewer_id') AS BIGINT)
                       AND om.employee_id = @owner_employee_id))
             OR (@practice_instance_id IS NOT NULL AND EXISTS (
                    SELECT 1
                      FROM grac_practice.practice_dependency_resolution r
                      JOIN grac_practice.dependency_type_master dt
                        ON dt.dependency_type_id = r.dependency_type_id
                       AND (dt.dependency_type_code = N'TEAM' OR dt.dependency_type_name = N'Team')
                      JOIN grac_practice.organization_team_member vm
                        ON vm.team_id = r.resolved_dependency_id
                      JOIN grac_practice.record_status_master vs
                        ON vs.record_status_id = vm.record_status_id AND vs.status_code = N'Active'
                     WHERE r.practice_instance_id = @practice_instance_id
                       AND r.is_active = 1
                       AND vm.employee_id = CAST(SESSION_CONTEXT(N'pm_viewer_id') AS BIGINT)))))
    -- Location: the record's own location, its owner's location, or its
    -- practice instance's resolved LOCATION, equals the reader's.
    OR (CHARINDEX(N',LOCATION,', CAST(SESSION_CONTEXT(N'pm_view_scope') AS NVARCHAR(100))) > 0
        AND SESSION_CONTEXT(N'pm_viewer_location_id') IS NOT NULL
        AND (   @location_id = CAST(SESSION_CONTEXT(N'pm_viewer_location_id') AS BIGINT)
             OR (@owner_employee_id IS NOT NULL AND EXISTS (
                    SELECT 1
                      FROM grac_practice.organization_employee oe
                     WHERE oe.employee_id = @owner_employee_id
                       AND oe.location_id = CAST(SESSION_CONTEXT(N'pm_viewer_location_id') AS BIGINT)))
             OR (@practice_instance_id IS NOT NULL AND EXISTS (
                    SELECT 1
                      FROM grac_practice.practice_dependency_resolution r
                      JOIN grac_practice.dependency_type_master dt
                        ON dt.dependency_type_id = r.dependency_type_id
                       AND (dt.dependency_type_code = N'LOCATION' OR dt.dependency_type_name = N'Location')
                     WHERE r.practice_instance_id = @practice_instance_id
                       AND r.is_active = 1
                       AND r.resolved_dependency_id = CAST(SESSION_CONTEXT(N'pm_viewer_location_id') AS BIGINT)))));
GO

CREATE OR ALTER FUNCTION grac_practice.fn_pm_view_scope_owner (@owner_employee_id BIGINT)
RETURNS TABLE
AS
RETURN
SELECT c.fn_result FROM grac_practice.fn_pm_view_scope_core(@owner_employee_id, NULL, NULL) c;
GO

CREATE OR ALTER FUNCTION grac_practice.fn_pm_view_scope_owner_instance
    (@owner_employee_id BIGINT, @practice_instance_id BIGINT)
RETURNS TABLE
AS
RETURN
SELECT c.fn_result FROM grac_practice.fn_pm_view_scope_core(@owner_employee_id, @practice_instance_id, NULL) c;
GO

-- custom_gap names its practice instance only when the source is one.
CREATE OR ALTER FUNCTION grac_practice.fn_pm_view_scope_gap
    (@owner_employee_id BIGINT, @source_reference_type NVARCHAR(60), @source_reference_id BIGINT)
RETURNS TABLE
AS
RETURN
SELECT c.fn_result
  FROM grac_practice.fn_pm_view_scope_core(
           @owner_employee_id,
           CASE WHEN @source_reference_type = N'PracticeInstance' THEN @source_reference_id END,
           NULL) c;
GO

-- =====================================================================
-- 5. The policy
-- =====================================================================
CREATE SECURITY POLICY grac_practice.pm_view_data_scope_policy
    ADD FILTER PREDICATE grac_practice.fn_pm_view_scope_owner_instance(primary_owner_id, practice_instance_id)
        ON grac_practice.practice_instance,
    ADD FILTER PREDICATE grac_practice.fn_pm_view_scope_owner_instance(assigned_to_employee_id, linked_instance_id)
        ON grac_practice.practice_task,
    ADD FILTER PREDICATE grac_practice.fn_pm_view_scope_gap(owner_employee_id, source_reference_type, source_reference_id)
        ON grac_practice.custom_gap,
    ADD FILTER PREDICATE grac_practice.fn_pm_view_scope_owner(owner_employee_id)
        ON grac_practice.exception_request,
    ADD FILTER PREDICATE grac_practice.fn_pm_view_scope_owner(risk_owner_employee_id)
        ON grac_practice.risk_register,
    ADD FILTER PREDICATE grac_practice.fn_pm_view_scope_owner(assigned_analyst_employee_id)
        ON grac_practice.risk_candidate,
    ADD FILTER PREDICATE grac_practice.fn_pm_view_scope_owner(owner_employee_id)
        ON grac_practice.org_assurance_plan,
    ADD FILTER PREDICATE grac_practice.fn_pm_view_scope_owner(owner_employee_id)
        ON grac_practice.org_assurance_execution,
    ADD FILTER PREDICATE grac_practice.fn_pm_view_scope_owner(assigned_owner_employee_id)
        ON grac_practice.org_assurance_observation
    WITH (STATE = ON, SCHEMABINDING = OFF);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '415-a every existing role is All records' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.organization_role WHERE view_data_scope IS NULL)
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '415-b policy on, nine tables',
       CASE WHEN (SELECT COUNT(*)
                    FROM sys.security_predicates sp
                    JOIN sys.security_policies p ON p.object_id = sp.object_id
                   WHERE p.name = N'pm_view_data_scope_policy' AND p.is_enabled = 1) = 9
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '415-c no scope in this session -> nothing filtered',
       CASE WHEN SESSION_CONTEXT(N'pm_view_scope') IS NULL
             AND (SELECT COUNT_BIG(*) FROM grac_practice.fn_pm_view_scope_core(NULL, NULL, NULL)) = 1
            THEN 'PASS' ELSE 'FAIL' END;
GO

SELECT view_data_scope AS ViewDataScope, COUNT(*) AS Roles
  FROM grac_practice.organization_role
 GROUP BY view_data_scope;
GO

PRINT 'Migration 415_role_view_data_scope applied. Deploy the matching Api and Web builds.';
GO

SET NOEXEC OFF;
GO
