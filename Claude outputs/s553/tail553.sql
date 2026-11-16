
-- =====================================================================
-- 4. The "role-responsibilities" lookup (gateway shim shape, as 361's
--    sp_get_time_zone_lookup)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_get_role_responsibility_lookup
    @p_entity_type NVARCHAR(100) = 'role-responsibilities',
    @p_action      NVARCHAR(30)  = 'QUERY',
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = '',
    @p_status      NVARCHAR(30)  = '',
    @p_payload     NVARCHAR(MAX) = '{}',
    @p_usr_id      NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SELECT N'role-responsibilities'                     AS LookupKey,
           CAST(role_responsibility_id AS NVARCHAR(40)) AS Value,
           responsibility_name                          AS Label,
           responsibility_code                          AS Code,
           CAST(NULL AS BIGINT)                         AS ParentId
      FROM grac_practice.role_responsibility_master
     WHERE is_active = 1
     ORDER BY display_order, responsibility_name;
END;
GO

-- =====================================================================
-- 5. sp_org_responsibility_holder_list -- people whose role carries a
--    responsibility (AUDITOR for the engagement's Assigned Auditor)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_responsibility_holder_list
    @organization_id     BIGINT,
    @responsibility_code NVARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR NULLIF(LTRIM(RTRIM(@responsibility_code)), N'') IS NULL
        THROW 55100, 'organization_id and responsibility_code are required.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    SELECT e.employee_id   AS EmployeeId,
           e.employee_code AS EmployeeCode,
           e.employee_name AS EmployeeName,
           e.designation   AS Designation,
           r.role_id       AS RoleId,
           r.role_name     AS RoleName
    FROM grac_practice.organization_employee e
    JOIN grac_practice.organization_role r
         ON r.role_id = e.role_id
    WHERE e.organization_id  = @organization_id
      AND e.status           = N'Active'
      AND e.record_status_id = @active_record_status_id
      AND r.record_status_id = @active_record_status_id
      AND EXISTS (SELECT 1
                    FROM grac_practice.organization_role_responsibility x
                    JOIN grac_practice.role_responsibility_master m
                         ON m.role_responsibility_id = x.role_responsibility_id
                   WHERE x.role_id = r.role_id
                     AND x.is_active = 1
                     AND m.is_active = 1
                     AND m.responsibility_code = @responsibility_code)
    ORDER BY e.employee_name, e.employee_id;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '553 tables and seed' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.organization_role_responsibility','U') IS NOT NULL
             AND EXISTS (SELECT 1 FROM grac_practice.role_responsibility_master WHERE responsibility_code = N'AUDITOR')
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '553 role save / list carry responsibilities',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_role_save')) LIKE '%responsibilityIds%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_role_list')) LIKE '%ResponsibilityIds%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '553 lookup and holder list',
       CASE WHEN OBJECT_ID('grac_practice.sp_get_role_responsibility_lookup','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_responsibility_holder_list','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;
PRINT '553 complete. Restart the Api and publish Web; give the auditor roles the Auditor responsibility in Role Master.';
GO
SET NOEXEC OFF;
GO
