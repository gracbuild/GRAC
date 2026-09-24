-- =====================================================================
-- 341_functional_user_flag_rollback.sql
--
-- Reverses 341: restores sp_org_user_save / sp_org_user_list to their
-- migration 208 bodies (no Functional User field) and then drops
-- organization_employee.is_functional_user with its default constraint.
--
-- The procedures are restored FIRST so that once the column is gone no
-- live definition still references it. Any stored is_functional_user
-- values are lost with the column, as a column drop implies.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;

-- 1. sp_org_user_save -- back to the 208 body.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_user_save
    @p_payload NVARCHAR(MAX),
    @p_id      BIGINT = 0,
    @p_usr_id  NVARCHAR(100) = 'system',
    @out_id    BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @active_record_status_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = 'Active');
    DECLARE @payload_record_status_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master
          WHERE status_code = JSON_VALUE(@p_payload,'$.status') OR status_name = JSON_VALUE(@p_payload,'$.status'));
    DECLARE @payload_record_status_id_from_id INT = TRY_CONVERT(INT, NULLIF(JSON_VALUE(@p_payload,'$.statusId'),''));
    SET @payload_record_status_id = COALESCE(@payload_record_status_id_from_id, @payload_record_status_id);

    DECLARE @employee_org_id      BIGINT        = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
    DECLARE @employee_code        NVARCHAR(80)  = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.employeeCode'))),'');
    DECLARE @employee_name        NVARCHAR(200) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.employeeName'))),'');
    DECLARE @employee_email       NVARCHAR(250) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.email'))),'');
    DECLARE @employee_password_hash NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.passwordHash'))),'');
    DECLARE @employee_role_id     BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.roleId'),''));
    DECLARE @employee_location_id BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.locationId'),''));
    DECLARE @employee_department_id BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.departmentId'),''));
    DECLARE @employee_function_id BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.businessFunctionId'),''));
    DECLARE @employee_reporting_officer_id BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.reportingOfficerId'),''));

    DECLARE @party_type        NVARCHAR(30) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.partyType'))),'');
    DECLARE @provider_vendor_id BIGINT      = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.providerVendorId'),''));
    DECLARE @engagement_start  DATE         = TRY_CONVERT(DATE,   NULLIF(JSON_VALUE(@p_payload,'$.engagementStartDate'),''));
    DECLARE @engagement_end    DATE         = TRY_CONVERT(DATE,   NULLIF(JSON_VALUE(@p_payload,'$.engagementEndDate'),''));
    SET @party_type = COALESCE(@party_type, N'Employee');

    DECLARE @force_password_change BIT =
        TRY_CONVERT(BIT, NULLIF(JSON_VALUE(@p_payload,'$.forcePasswordChange'),''));

    IF @employee_org_id IS NULL THROW 51047,'Organization is required for User / Employee.',1;
    IF @employee_code IS NULL   THROW 51048,'Employee Code is required.',1;
    IF @employee_name IS NULL   THROW 51049,'Employee Name is required.',1;
    IF @employee_email IS NULL  THROW 51148,'Email ID is required for User / Employee login.',1;
    IF EXISTS(SELECT 1 FROM grac_practice.organization_employee
               WHERE LOWER(LTRIM(RTRIM(email))) = LOWER(@employee_email) AND (@p_id = 0 OR employee_id <> @p_id))
        THROW 51149,'Employee Email ID already exists.',1;
    IF @p_id = 0 AND @employee_password_hash IS NULL
        THROW 51152,'Password is required when creating a User / Employee.',1;
    IF @employee_role_id IS NULL THROW 51150,'Role is required for User / Employee.',1;
    IF NOT EXISTS(SELECT 1 FROM grac_practice.organization_role
                   WHERE role_id = @employee_role_id AND organization_id = @employee_org_id AND status = 'Active')
        THROW 51151,'Selected Role is not valid for this organization.',1;
    IF @employee_location_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_location
                   WHERE location_id = @employee_location_id AND organization_id = @employee_org_id AND status = 'Active')
        THROW 51056,'Selected Location is not valid for this organization.',1;
    IF @employee_department_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_department
                   WHERE department_id = @employee_department_id AND organization_id = @employee_org_id AND status = 'Active')
        THROW 51050,'Selected Department is not valid for this organization.',1;
    IF @employee_function_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_business_function
                   WHERE business_function_id = @employee_function_id AND organization_id = @employee_org_id AND status = 'Active')
        THROW 51051,'Selected Business Function is not valid for this organization.',1;
    IF @employee_reporting_officer_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee
                   WHERE employee_id = @employee_reporting_officer_id AND organization_id = @employee_org_id AND status = 'Active')
        THROW 51054,'Selected Reporting Officer is not valid for this organization.',1;
    IF @p_id <> 0 AND @employee_reporting_officer_id = @p_id
        THROW 51055,'Reporting Officer cannot be the same employee.',1;

    IF @party_type NOT IN (N'Employee', N'ThirdParty')
        THROW 52300,'Personnel Type must be Employee or Third-party personnel.',1;

    IF @party_type = N'ThirdParty'
    BEGIN
        IF @provider_vendor_id IS NULL
            THROW 52301,'Provider is required for third-party personnel. Register the vendor first, then select it here.',1;
        IF NOT EXISTS(SELECT 1 FROM grac_practice.organization_dependency_vendor
                       WHERE vendor_id = @provider_vendor_id AND organization_id = @employee_org_id AND status = 'Active')
            THROW 52302,'Selected Provider is not a valid active vendor for this organization.',1;
    END
    ELSE
        SET @provider_vendor_id = NULL;

    IF @engagement_start IS NOT NULL AND @engagement_end IS NOT NULL AND @engagement_end < @engagement_start
        THROW 52303,'Engagement End Date cannot be earlier than Engagement Start Date.',1;

    IF @p_id = 0
    BEGIN
        INSERT grac_practice.organization_employee
            (organization_id, employee_code, employee_name, email, password_hash, role_id, designation,
             location_id, department, department_id, business_function_id, reporting_officer_id,
             party_type, provider_vendor_id, engagement_start_dt, engagement_end_dt,
             force_password_change,
             status, record_status_id, entered_by)
        SELECT @employee_org_id, @employee_code, @employee_name, @employee_email, @employee_password_hash,
               @employee_role_id, JSON_VALUE(@p_payload,'$.designation'),
               @employee_location_id, d.department_name, @employee_department_id, @employee_function_id,
               @employee_reporting_officer_id,
               @party_type, @provider_vendor_id, @engagement_start, @engagement_end,
               COALESCE(@force_password_change, 1),
               COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),
               COALESCE(@payload_record_status_id, @active_record_status_id), @p_usr_id
        FROM   (SELECT CAST(NULL AS NVARCHAR(200)) department_name) empty
        OUTER APPLY (SELECT department_name FROM grac_practice.organization_department
                      WHERE department_id = @employee_department_id) d;
        SET @out_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE e
           SET organization_id = @employee_org_id, employee_code = @employee_code, employee_name = @employee_name,
               email = @employee_email,
               password_hash = COALESCE(@employee_password_hash, e.password_hash),
               role_id = @employee_role_id,
               designation = JSON_VALUE(@p_payload,'$.designation'),
               location_id = @employee_location_id, department = d.department_name,
               department_id = @employee_department_id, business_function_id = @employee_function_id,
               reporting_officer_id = @employee_reporting_officer_id,
               party_type = @party_type, provider_vendor_id = @provider_vendor_id,
               engagement_start_dt = @engagement_start, engagement_end_dt = @engagement_end,
               force_password_change = COALESCE(@force_password_change, e.force_password_change),
               status = COALESCE(JSON_VALUE(@p_payload,'$.status'), e.status),
               record_status_id = COALESCE(@payload_record_status_id, e.record_status_id),
               updated_by = @p_usr_id, updated_dt = SYSUTCDATETIME()
        FROM   grac_practice.organization_employee e
        OUTER APPLY (SELECT department_name FROM grac_practice.organization_department
                      WHERE department_id = @employee_department_id) d
        WHERE  e.employee_id = @p_id;
        SET @out_id = @p_id;
    END

    IF @employee_email IS NOT NULL
        INSERT grac_practice.user_organization_map
            (user_email, organization_id, access_role, is_default, status, record_status_id, entered_by)
        SELECT @employee_email, @employee_org_id, 'Organization User', 0, 'Active', @active_record_status_id, @p_usr_id
        WHERE NOT EXISTS(SELECT 1 FROM grac_practice.user_organization_map
                          WHERE user_email = @employee_email AND organization_id = @employee_org_id);
END;
GO

-- 2. sp_org_user_list -- back to the 208 body.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_user_list
    @p_id            BIGINT        = 0,
    @organization_id BIGINT        = NULL,
    @p_status        NVARCHAR(30)  = '',
    @p_search        NVARCHAR(200) = '',
    @p_page_number   INT           = 1,
    @p_page_size     INT           = 25
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @page_size INT = ISNULL(NULLIF(@p_page_size,0),25);
    DECLARE @offset    INT = (ISNULL(NULLIF(@p_page_number,0),1) - 1) * @page_size;
    DECLARE @filter_record_status_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master
          WHERE status_code = @p_status OR status_name = @p_status);

    SELECT e.employee_id Id, e.organization_id OrganizationId,
           e.employee_code EmployeeCode, e.employee_name EmployeeName,
           e.email Email, e.designation Designation,
           e.location_id LocationId, loc.location_name Location,
           e.department Department, e.department_id DepartmentId, d.department_name DepartmentName,
           e.business_function_id BusinessFunctionId, bf.function_name BusinessFunction,
           e.reporting_officer_id ReportingOfficerId, COALESCE(ro.employee_name,'') ReportingOfficer,
           e.role_id RoleId, COALESCE(role.role_name,'') RoleName,
           e.party_type PartyType,
           CASE e.party_type WHEN N'ThirdParty' THEN N'Third-party personnel'
                             ELSE N'Employee' END PersonnelType,
           e.provider_vendor_id ProviderVendorId, COALESCE(pv.vendor_name,'') Provider,
           e.engagement_start_dt EngagementStartDate,
           e.engagement_end_dt EngagementEndDate,
           CAST(CASE WHEN e.party_type = N'ThirdParty'
                      AND e.engagement_end_dt IS NOT NULL
                      AND e.engagement_end_dt < CAST(SYSUTCDATETIME() AS DATE)
                     THEN 1 ELSE 0 END AS BIT) EngagementExpired,
           CAST(ISNULL(e.force_password_change,0) AS BIT) ForcePasswordChange,
           CASE WHEN ISNULL(e.force_password_change,0) = 1
                THEN N'Default password'
                ELSE N'Password set' END CredentialStatus,
           rs.status_name Status
    FROM       grac_practice.organization_employee e
    JOIN       grac_practice.record_status_master rs ON rs.record_status_id = e.record_status_id
    LEFT JOIN  grac_practice.organization_location loc ON loc.location_id = e.location_id
    LEFT JOIN  grac_practice.organization_department d ON d.department_id = e.department_id
    LEFT JOIN  grac_practice.organization_business_function bf ON bf.business_function_id = e.business_function_id
    LEFT JOIN  grac_practice.organization_employee ro ON ro.employee_id = e.reporting_officer_id
    LEFT JOIN  grac_practice.organization_role role ON role.role_id = e.role_id
    LEFT JOIN  grac_practice.organization_dependency_vendor pv ON pv.vendor_id = e.provider_vendor_id
    WHERE      (@p_id = 0 OR e.employee_id = @p_id)
      AND      (@organization_id IS NULL OR e.organization_id = @organization_id)
      AND      (@p_status = '' OR e.record_status_id = @filter_record_status_id)
      AND      (@p_search = '' OR e.employee_code LIKE '%'+@p_search+'%'
                               OR e.employee_name LIKE '%'+@p_search+'%'
                               OR ISNULL(e.email,'') LIKE '%'+@p_search+'%'
                               OR ISNULL(pv.vendor_name,'') LIKE '%'+@p_search+'%')
    ORDER BY   e.employee_name
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- 3. Drop the column (default constraint first).
IF COL_LENGTH('grac_practice.organization_employee','is_functional_user') IS NOT NULL
BEGIN
    IF OBJECT_ID('grac_practice.df_pm_employee_is_functional_user','D') IS NOT NULL
        ALTER TABLE grac_practice.organization_employee
            DROP CONSTRAINT df_pm_employee_is_functional_user;
    ALTER TABLE grac_practice.organization_employee DROP COLUMN is_functional_user;
    PRINT '341 rollback: organization_employee.is_functional_user dropped.';
END
GO
