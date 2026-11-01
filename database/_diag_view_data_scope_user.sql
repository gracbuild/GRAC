-- =====================================================================
-- DIAGNOSTIC: a role set to View Data Scope = Assigned Owner (OWNER)
--             still sees every record.
--
-- Read-only (session context is set and cleared on THIS connection
-- only; no table is written). Set @login_id to the user's email or
-- Employee Code, run the whole script, read sections 1-4.
--
-- How the scope works (migration 415, docs/view-data-scope.md):
--   the API runs grac_practice.sp_pm_view_scope_session_set for the
--   reader on every READ connection; unless one of the reader's roles is
--   ALL it writes SESSION_CONTEXT, and the row-level security policy
--   grac_practice.pm_view_data_scope_policy filters ONLY these nine
--   tables: practice_instance, practice_task, custom_gap,
--   exception_request, risk_register, risk_candidate,
--   org_assurance_plan, org_assurance_execution,
--   org_assurance_observation.
--   Any other list (Organization Practices, Control Statements,
--   Standards & Frameworks, Assets, ...) is NOT covered by the scope.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @login_id NVARCHAR(250) = N'REPLACE-WITH-THE-USER-EMAIL';
DECLARE @employee_id BIGINT =
    (SELECT TOP 1 employee_id FROM grac_practice.organization_employee
      WHERE LOWER(email) = LOWER(@login_id) OR LOWER(employee_code) = LOWER(@login_id));

PRINT '=== 1. The user ===';
SELECT e.employee_id, e.organization_id, e.employee_code, e.employee_name, e.email, e.role_id, e.location_id
  FROM grac_practice.organization_employee e WHERE e.employee_id = @employee_id;

-- Every role the scope procedure considers. ONE role on ALL makes the
-- user unrestricted (union rule) -- the usual cause.
PRINT '=== 2. Roles and their View Data Scope ===';
SELECT src.source, r.role_id, r.role_name, r.view_data_scope, r.status
  FROM (SELECT N'organization_employee.role_id' AS source, e.role_id
          FROM grac_practice.organization_employee e
         WHERE e.employee_id = @employee_id AND e.role_id IS NOT NULL
        UNION ALL
        SELECT N'organization_employee_role (Active)', er.role_id
          FROM grac_practice.organization_employee_role er
         WHERE er.employee_id = @employee_id AND er.status = N'Active') src
  JOIN grac_practice.organization_role r ON r.role_id = src.role_id;

PRINT '=== 3. Security policy state (is_enabled must be 1) ===';
SELECT p.name, p.is_enabled, COUNT(pr.target_object_id) AS filtered_tables
  FROM sys.security_policies p
  LEFT JOIN sys.security_predicates pr ON pr.object_id = p.object_id
 WHERE p.name = N'pm_view_data_scope_policy'
 GROUP BY p.name, p.is_enabled;

-- What this user would see vs everything, table by table. The first
-- EXEC prints the scope the API would apply ("ALL" = unrestricted).
PRINT '=== 4. Rows visible with the user''s scope vs all rows ===';
DECLARE @scoped TABLE (tbl SYSNAME, visible INT);
EXEC grac_practice.sp_pm_view_scope_session_set @employee_id = @employee_id;
INSERT @scoped SELECT N'practice_instance',         COUNT(*) FROM grac_practice.practice_instance;
INSERT @scoped SELECT N'practice_task',             COUNT(*) FROM grac_practice.practice_task;
INSERT @scoped SELECT N'custom_gap',                COUNT(*) FROM grac_practice.custom_gap;
INSERT @scoped SELECT N'exception_request',         COUNT(*) FROM grac_practice.exception_request;
INSERT @scoped SELECT N'risk_register',             COUNT(*) FROM grac_practice.risk_register;
INSERT @scoped SELECT N'risk_candidate',            COUNT(*) FROM grac_practice.risk_candidate;
INSERT @scoped SELECT N'org_assurance_plan',        COUNT(*) FROM grac_practice.org_assurance_plan;
INSERT @scoped SELECT N'org_assurance_execution',   COUNT(*) FROM grac_practice.org_assurance_execution;
INSERT @scoped SELECT N'org_assurance_observation', COUNT(*) FROM grac_practice.org_assurance_observation;
-- Clear the scope again for this connection.
EXEC sys.sp_set_session_context @key = N'pm_view_scope',         @value = NULL;
EXEC sys.sp_set_session_context @key = N'pm_viewer_id',          @value = NULL;
EXEC sys.sp_set_session_context @key = N'pm_viewer_location_id', @value = NULL;

SELECT s.tbl, s.visible AS visible_to_user,
       CASE s.tbl
         WHEN N'practice_instance'         THEN (SELECT COUNT(*) FROM grac_practice.practice_instance)
         WHEN N'practice_task'             THEN (SELECT COUNT(*) FROM grac_practice.practice_task)
         WHEN N'custom_gap'                THEN (SELECT COUNT(*) FROM grac_practice.custom_gap)
         WHEN N'exception_request'         THEN (SELECT COUNT(*) FROM grac_practice.exception_request)
         WHEN N'risk_register'             THEN (SELECT COUNT(*) FROM grac_practice.risk_register)
         WHEN N'risk_candidate'            THEN (SELECT COUNT(*) FROM grac_practice.risk_candidate)
         WHEN N'org_assurance_plan'        THEN (SELECT COUNT(*) FROM grac_practice.org_assurance_plan)
         WHEN N'org_assurance_execution'   THEN (SELECT COUNT(*) FROM grac_practice.org_assurance_execution)
         WHEN N'org_assurance_observation' THEN (SELECT COUNT(*) FROM grac_practice.org_assurance_observation)
       END AS all_rows
  FROM @scoped s;
-- Reading the result:
--   section 2 has a role on ALL           -> the union rule makes the user unrestricted.
--   section 3 is_enabled = 0 / no row     -> the policy is off or 415 is not deployed.
--   visible_to_user < all_rows here, but
--   the screen still shows everything     -> that screen reads a table outside the nine
--                                            (see the header), or the API caches the user
--                                            as unrestricted for up to 60 s after a change.
