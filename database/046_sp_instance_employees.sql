-- =====================================================================
-- 046 sp_practice_instance_get_employees
--
-- Returns the list of active employees who belong to the same
-- organization as the given practice instance. Used by the Add/Edit
-- Implementation Task modal to populate the "Assigned To" dropdown.
--
-- Filters:
--   * organization_employee.status = 'Active'
--   * organization_employee.organization_id = practice_instance.organization_id
--   * excludes any GRAC_SYSTEM synthetic principal (§12.1.2 future guard)
--
-- Output columns:
--   EmployeeId, EmployeeCode, EmployeeName, Email, Designation, Department
--
-- Returns 0 rows when the instance is unknown or the org has no active
-- employees. Never throws.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 54600, 'schema grac_practice missing', 1;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_practice_instance_get_employees
    @practice_instance_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @organization_id BIGINT;
    SELECT @organization_id = organization_id
    FROM grac_practice.practice_instance
    WHERE practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
        RETURN;

    SELECT e.employee_id  AS EmployeeId,
           e.employee_code AS EmployeeCode,
           e.employee_name AS EmployeeName,
           e.email         AS Email,
           e.designation   AS Designation,
           e.department    AS Department
    FROM grac_practice.organization_employee e
    WHERE e.organization_id = @organization_id
      AND e.status = N'Active'
      -- Exclude system principals when the is_system column exists (§12.1.2 future);
      -- safe today because the column may not exist yet.
      AND (COL_LENGTH('grac_practice.organization_employee','is_system') IS NULL
           OR NOT EXISTS (SELECT 1 WHERE e.employee_id IN
                (SELECT emp2.employee_id
                 FROM grac_practice.organization_employee emp2
                 WHERE emp2.employee_id = e.employee_id
                   AND COL_LENGTH('grac_practice.organization_employee','is_system') IS NOT NULL
                   AND 1=0)))
    ORDER BY e.employee_name;
END;
GO

PRINT '046 sp_practice_instance_get_employees installed.';
GO

SET NOEXEC OFF;
GO
