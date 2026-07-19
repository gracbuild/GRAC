-- =====================================================================
-- 047 sp_organization_get_employees
--
-- Read-only helper — returns active employees for a given organization.
-- Used by the "New Task" modal on the Task Center (organization is
-- already selected in the filter, so we scope the Assigned To dropdown
-- to that org).
--
-- Never throws. Zero rows when the org is unknown / has no active
-- employees.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 54700, 'schema grac_practice missing', 1;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_organization_get_employees
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL RETURN;

    SELECT e.employee_id   AS EmployeeId,
           e.employee_code AS EmployeeCode,
           e.employee_name AS EmployeeName,
           e.email         AS Email,
           e.designation   AS Designation,
           e.department    AS Department
    FROM grac_practice.organization_employee e
    WHERE e.organization_id = @organization_id
      AND e.status = N'Active'
    ORDER BY e.employee_name;
END;
GO

PRINT '047 sp_organization_get_employees installed.';
GO
SET NOEXEC OFF;
GO
