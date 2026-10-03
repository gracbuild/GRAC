-- =====================================================================
-- _diag_person_location_department.sql  (read-only diagnostic)
--
-- Impact Details -> Person: the Location / Department filters are built
-- from each person's organization_employee.location_id / department_id.
-- If both filters show only "All", run this for the organisation:
--   * 1st result: how many active persons have a location / department.
--     All zero => the filters are empty because the data is NULL.
--   * 2nd result: the exact rows the API's dependency-options query now
--     returns for Person (same columns, same correlated lookups). If this
--     fails, the API query fails the same way.
-- Set @org to the organisation you are testing. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
DECLARE @org BIGINT = 1;

SELECT COUNT(*)                                             AS active_persons,
       SUM(CASE WHEN location_id   IS NOT NULL THEN 1 ELSE 0 END) AS with_location,
       SUM(CASE WHEN department_id IS NOT NULL THEN 1 ELSE 0 END) AS with_department
  FROM grac_practice.organization_employee
 WHERE organization_id = @org AND status = N'Active';

SELECT TOP 50
       CAST(employee_id AS NVARCHAR(40))   [Value],
       CAST(employee_name AS NVARCHAR(300)) [Label],
       [grac_practice].[organization_employee].[location_id] LocationId,
       (SELECT TOP 1 ol.location_name FROM grac_practice.organization_location ol
         WHERE ol.location_id=[grac_practice].[organization_employee].[location_id]) LocationName,
       [grac_practice].[organization_employee].[department_id] DepartmentId,
       (SELECT TOP 1 od.department_name FROM grac_practice.organization_department od
         WHERE od.department_id=[grac_practice].[organization_employee].[department_id]) DepartmentName
  FROM [grac_practice].[organization_employee]
 WHERE organization_id = @org AND status = N'Active'
 ORDER BY employee_name;
