-- =====================================================================
-- 117 Role-holder helper SPs for the hybrid role+employee ownership
-- model introduced in 115.
--
-- Depends on organization_role + organization_employee.role_id
-- (already present in the base schema).
--
-- SPs (all CREATE OR ALTER, so re-run is safe):
--   sp_org_role_holders_list             org, role -> current holders
--   sp_org_role_primary_holder_pick      org, role -> first active holder
--                                         (used by save SPs to auto-fill
--                                         the employee snapshot when the
--                                         caller supplies only role_id)
--
-- The pre-existing sp_org_assurance_organization_role_list (from 084)
-- already returns "role_id, role_name" for a given org, so we do NOT
-- redefine it here -- it is reused by every module that needs a role
-- dropdown (Definition, Observation, Gap Center, Execution, Plan).
--
-- Rollback: 117_org_role_holder_helper_procs_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.organization_role','U')    IS NULL
   OR OBJECT_ID('grac_practice.organization_employee','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','role_id') IS NULL
BEGIN
    RAISERROR('117: prerequisites missing (organization_role / organization_employee.role_id).', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_org_role_holders_list
--   Returns active employees currently holding a role in an org.
--   Ordered by employee_name so the "primary" holder is deterministic.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_role_holders_list
    @organization_id BIGINT,
    @role_id         BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @role_id IS NULL
        THROW 55100, 'organization_id and role_id are required.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    SELECT e.employee_id   AS EmployeeId,
           e.employee_code  AS EmployeeCode,
           e.employee_name  AS EmployeeName,
           e.email          AS Email,
           e.designation    AS Designation,
           e.department     AS Department,
           r.role_id        AS RoleId,
           r.role_name      AS RoleName
    FROM grac_practice.organization_employee e
    JOIN grac_practice.organization_role r
         ON r.role_id = e.role_id
    WHERE e.organization_id  = @organization_id
      AND e.role_id          = @role_id
      AND e.status           = N'Active'
      AND e.record_status_id = @active_record_status_id
    ORDER BY e.employee_name, e.employee_id;
END
GO

-- =====================================================================
-- sp_org_role_primary_holder_pick
--   Returns exactly one row (or none if no active holder) -- used by
--   save SPs to snapshot the current-holder employee when the caller
--   supplied only a role_id.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_role_primary_holder_pick
    @organization_id      BIGINT,
    @role_id              BIGINT,
    @employee_id_out      BIGINT        OUTPUT,
    @employee_name_out    NVARCHAR(240) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @employee_id_out   = NULL;
    SET @employee_name_out = NULL;
    IF @organization_id IS NULL OR @role_id IS NULL RETURN;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    SELECT TOP 1
        @employee_id_out   = e.employee_id,
        @employee_name_out = e.employee_name
    FROM grac_practice.organization_employee e
    WHERE e.organization_id  = @organization_id
      AND e.role_id          = @role_id
      AND e.status           = N'Active'
      AND e.record_status_id = @active_record_status_id
    ORDER BY e.employee_name, e.employee_id;
END
GO

PRINT '117 role-holder helper procedures deployed.';
GO
