-- =====================================================================
-- 362 Team Member Selection -- Department -> Employee tree on Add/Edit Team
--
-- WHAT THIS ADDS
-- ---------------
-- A Team previously had no concept of individual members -- only a
-- single team_manager_id. This migration adds a many-to-many mapping
-- between organization_team and organization_employee so a Team can
-- carry a list of member employees, selected from a Department ->
-- Employee tree on the Add/Edit Team form.
--
-- WHY A NEW LOOKUP PROC INSTEAD OF EXTENDING THE SHARED /lookups UNION
-- ----------------------------------------------------------------------
-- The generic 'lookups' branch inside dbo.pm_get_practice_repository
-- (002, re-emitted whole by 300) is one big UNION ALL of 4-column
-- SELECTs (LookupKey, Value, Label, OrganizationId) feeding ~40 entity
-- types, including 'users-id' / 'employees-id' which the Team Manager /
-- Department Head / Reporting Officer pickers already use. Widening
-- every branch of that UNION to carry Department columns just to serve
-- one new tree would touch unrelated User/Team/Department dropdowns for
-- no reason and risks a column-count mismatch across ~40 SELECTs.
--
-- Instead this follows the project's own precedent for exactly this
-- situation -- migrations 241 (asset-taxonomy), 244 (connection-types),
-- 248 (implementation-status-id) and 342 (owners) -- a dedicated,
-- read-only "lookup entity" with its own small procedure, routed to by
-- PracticeRepositoryService.ResolveProcedureAsync the same way those
-- four already are. The shared users/users-id lists stay untouched.
--
-- WHY THE TABLE IS ADDED HERE BUT THE SAVE/LIST LOGIC IS NOT
-- -------------------------------------------------------------
-- organization_team_member is a brand-new object, so it belongs in its
-- own numbered migration. sp_org_team_save / sp_org_team_list already
-- exist (migration 133) and CREATE OR ALTER replaces a procedure whole,
-- so extending them means editing 133_org_party_and_team_type.sql
-- in place (same approach this branch already used for 133's Active/
-- Inactive status-restriction guard) rather than re-declaring a second,
-- competing definition here. Both files must be (re)run for Team Member
-- Selection to work end to end; 133 is safe to re-run (CREATE OR ALTER
-- is idempotent).
--
-- DUPLICATE-MAPPING PREVENTION
-- ------------------------------
-- uq_pm_team_member(team_id, employee_id) makes a duplicate mapping
-- impossible at the schema level, independent of however the save
-- procedure assembles its INSERTs.
--
-- ORG-SCOPING / ACTIVE-ONLY
-- ---------------------------
-- sp_get_team_department_employee_tree returns one row per (active
-- Department, active Employee) pair, across every organization the
-- caller is scoped to -- same shape as 342's sp_get_owners_lookup,
-- which deliberately returns every organization's rows and lets the UI
-- filter to the organization currently open (see 342's own header
-- note: "no scoping is duplicated here"). A Department with no active
-- employees still gets one row (Employee columns NULL) via the LEFT
-- JOIN, so it still shows in the tree as an expandable, empty branch
-- rather than silently disappearing.
--
-- Objects:
--   * grac_practice.organization_team_member          NEW (mapping table)
--   * grac_practice.sp_get_team_department_employee_tree  NEW (read-only lookup shim)
--
-- Depends on 002 (organization_team, organization_department,
-- organization_employee, record_status_master).
-- Rollback: database/362_team_member_selection_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.organization_team','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_department','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_employee','U') IS NULL
BEGIN
    RAISERROR('362: prerequisites missing. Run 002 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. organization_team_member -- Team <-> Employee mapping
-- =====================================================================
IF OBJECT_ID('grac_practice.organization_team_member','U') IS NULL
CREATE TABLE grac_practice.organization_team_member(
 team_member_id   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_organization_team_member PRIMARY KEY,
 team_id          BIGINT NOT NULL,
 employee_id      BIGINT NOT NULL,
 organization_id  BIGINT NOT NULL,
 status           NVARCHAR(30) NOT NULL CONSTRAINT df_pm_team_member_status DEFAULT 'Active',
 record_status_id INT NOT NULL,
 entered_by       NVARCHAR(100) NOT NULL CONSTRAINT df_pm_team_member_entered_by DEFAULT 'system',
 entered_dt       DATETIME2 NOT NULL CONSTRAINT df_pm_team_member_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by       NVARCHAR(100) NULL,
 updated_dt       DATETIME2 NULL,
 CONSTRAINT fk_pm_team_member_team FOREIGN KEY(team_id) REFERENCES grac_practice.organization_team(team_id),
 CONSTRAINT fk_pm_team_member_employee FOREIGN KEY(employee_id) REFERENCES grac_practice.organization_employee(employee_id),
 CONSTRAINT fk_pm_team_member_organization FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
 CONSTRAINT fk_pm_team_member_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
 -- A team cannot map the same employee twice -- schema-level duplicate guard.
 CONSTRAINT uq_pm_team_member UNIQUE(team_id, employee_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_team_member_team_id' AND object_id = OBJECT_ID('grac_practice.organization_team_member'))
    CREATE INDEX ix_pm_team_member_team_id ON grac_practice.organization_team_member(team_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_team_member_employee_id' AND object_id = OBJECT_ID('grac_practice.organization_team_member'))
    CREATE INDEX ix_pm_team_member_employee_id ON grac_practice.organization_team_member(employee_id);
GO

-- =====================================================================
-- 2. sp_get_team_department_employee_tree
--
--    Read-only feed for the Team Members tree. 7-parameter signature
--    mirrors the other lookup shims (241/244/248/342) so the generic
--    query path (ResolveProcedureAsync) can route to it the same way.
--    Parameters are accepted and ignored, same as sp_get_owners_lookup --
--    the UI filters to the currently-open organization client-side.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_get_team_department_employee_tree
    @p_entity_type NVARCHAR(100) = N'',
    @p_action      NVARCHAR(40)  = N'',
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = N'',
    @p_status      NVARCHAR(30)  = N'',
    @p_payload     NVARCHAR(MAX) = N'{}',
    @p_usr_id      NVARCHAR(200) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    -- Active-ness is read from record_status_id, NOT the text status
    -- column, on both sides of this query. 2026-09-20 live debugging
    -- found organization_department.status ('Active'/'Inactive') is not
    -- guaranteed to be in sync with record_status_id for every row (the
    -- monolith's UPDATE branch for 'departments' only overwrites status
    -- when the payload explicitly supplies one -- COALESCE(...,status) --
    -- so a row created outside that exact path can carry a stale/blank
    -- text status while record_status_id is correct). This mirrors the
    -- same, already-established record_status_id-based pattern used by
    -- sp_org_team_list / sp_practice_team_option_list for Teams.
    SELECT N'team-department-employees'          AS EntityType,
           d.department_id                       AS DepartmentId,
           d.department_code + N' - ' + d.department_name AS DepartmentName,
           d.organization_id                     AS OrganizationId,
           e.employee_id                         AS EmployeeId,
           e.employee_code                       AS EmployeeCode,
           e.employee_name                       AS EmployeeName
    FROM   grac_practice.organization_department d
    JOIN   grac_practice.record_status_master drs
           ON drs.record_status_id = d.record_status_id
          AND drs.status_code      = N'Active'
    LEFT   JOIN grac_practice.organization_employee e
           ON e.department_id     = d.department_id
          AND e.organization_id   = d.organization_id
          AND EXISTS (
                SELECT 1 FROM grac_practice.record_status_master ers
                WHERE  ers.record_status_id = e.record_status_id
                  AND  ers.status_code      = N'Active')
    ORDER  BY d.department_name, e.employee_name;
END
GO

-- =====================================================================
-- 3. sp_get_team_member_list
--
--    Read-only feed for the currently-selected members of ONE team, used
--    to pre-check the tree on Edit and to render the read-only member
--    list on View. @p_id is the team_id (the generic query path already
--    posts the record id as @p_id -- see sp_org_team_repository_get for
--    the same convention). Deliberately a SEPARATE procedure rather than
--    extra columns on sp_org_team_list: that procedure feeds the Teams
--    grid and every other Team read, and STRING_AGG-ing member names
--    into it would mean that screen breaks the moment migration 362 has
--    not yet been applied. This one degrades on its own -- an unapplied
--    362 simply returns zero rows, exactly like an empty team -- without
--    touching Team listing at all.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_get_team_member_list
    @p_entity_type NVARCHAR(100) = N'',
    @p_action      NVARCHAR(40)  = N'',
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = N'',
    @p_status      NVARCHAR(30)  = N'',
    @p_payload     NVARCHAR(MAX) = N'{}',
    @p_usr_id      NVARCHAR(200) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('grac_practice.organization_team_member','U') IS NULL
        RETURN;

    SELECT tm.team_id                AS TeamId,
           tm.employee_id            AS EmployeeId,
           CAST(tm.employee_id AS NVARCHAR(40)) AS Value,
           e.employee_code           AS EmployeeCode,
           e.employee_name           AS EmployeeName,
           e.employee_code + N' - ' + e.employee_name AS Label,
           e.department_id           AS DepartmentId
    FROM   grac_practice.organization_team_member tm
    JOIN   grac_practice.organization_employee e ON e.employee_id = tm.employee_id
    WHERE  (@p_id = 0 OR tm.team_id = @p_id)
    ORDER  BY e.employee_name;
END
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'organization_team_member table' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.organization_team_member','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'uq_pm_team_member unique constraint',
       CASE WHEN EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'uq_pm_team_member') THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_get_team_department_employee_tree',
       CASE WHEN OBJECT_ID('grac_practice.sp_get_team_department_employee_tree','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_get_team_member_list',
       CASE WHEN OBJECT_ID('grac_practice.sp_get_team_member_list','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;

PRINT '362 Team Member Selection: table + 2 lookup procedures ready.';
PRINT 'NEXT: re-run 133_org_party_and_team_type.sql (sp_org_team_save extended in';
PRINT '      place to accept and save memberIds -- sp_org_team_list is UNCHANGED,';
PRINT '      members are read back via sp_get_team_member_list above instead), then';
PRINT '      confirm PracticeRepositoryService maps team-department-employees /';
PRINT '      team-members, and LoginController.SupportingReads grants both :VIEW.';
GO

SET NOEXEC OFF;
GO
