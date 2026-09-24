-- =====================================================================
-- 341_functional_user_flag.sql
--
-- WHAT THIS DOES
-- --------------
-- Introduces the "Functional User" classification on the user master
-- (grac_practice.organization_employee) and threads it through the two
-- procedures the Users form (Organization Setup) uses:
--
--   * organization_employee.is_functional_user  NEW column (BIT, default 0)
--   * sp_org_user_save   ALTERED -- reads $.isFunctionalUser, persists it
--   * sp_org_user_list   ALTERED -- returns IsFunctionalUser for the grid + edit
--
-- WHY A USER-LEVEL COLUMN
-- -----------------------
-- Functional User is a property of the person, used to decide who may be
-- picked as an OWNER anywhere in the app. Owner dropdowns read
-- organization_employee, so the flag lives there and is filtered at the
-- query, never in the browser. This migration only adds and persists the
-- flag; the owner-list filtering ships with the owner-lookup procedure.
--
-- WHAT THIS DOES NOT TOUCH
-- ------------------------
-- No role, permission, user_organization_map, password or authentication
-- behaviour changes. The two procs are reproduced verbatim from migration
-- 208 with the single new field added in three places (declare, insert,
-- update) and one new output column -- everything else is unchanged so a
-- CREATE OR ALTER keeps the live definition identical apart from the flag.
--
-- SAFE TO RE-RUN. Requires 208 (the procs this re-issues) and 133/032.
-- Rollback: database/341_functional_user_flag_rollback.sql
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;

IF OBJECT_ID('grac_practice.organization_employee','U') IS NULL
BEGIN
    PRINT 'ABORT (341): grac_practice.organization_employee missing. Run 009 first.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.sp_org_user_save','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_user_list','P') IS NULL
BEGIN
    PRINT 'ABORT (341): sp_org_user_save / sp_org_user_list missing. Run 208 first.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. The column. NOT NULL default 0 -- every existing user starts as a
--    normal (non-functional) user until an admin ticks the box.
-- ---------------------------------------------------------------------
IF COL_LENGTH('grac_practice.organization_employee','is_functional_user') IS NULL
BEGIN
    ALTER TABLE grac_practice.organization_employee
        ADD is_functional_user BIT NOT NULL
            CONSTRAINT df_pm_employee_is_functional_user DEFAULT 0;
    PRINT '341: organization_employee.is_functional_user added.';
END
ELSE
    PRINT '341: organization_employee.is_functional_user already present.';
GO

-- ---------------------------------------------------------------------
-- 2. sp_org_user_save -- 208 body + $.isFunctionalUser
-- ---------------------------------------------------------------------
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

    -- ---- 133 additions ----
    DECLARE @party_type        NVARCHAR(30) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.partyType'))),'');
    DECLARE @provider_vendor_id BIGINT      = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.providerVendorId'),''));
    DECLARE @engagement_start  DATE         = TRY_CONVERT(DATE,   NULLIF(JSON_VALUE(@p_payload,'$.engagementStartDate'),''));
    DECLARE @engagement_end    DATE         = TRY_CONVERT(DATE,   NULLIF(JSON_VALUE(@p_payload,'$.engagementEndDate'),''));
    -- A caller that predates 133 sends no partyType; treat that as Employee
    -- so the older form keeps working unchanged.
    SET @party_type = COALESCE(@party_type, N'Employee');

    -- ---- 208 addition ----
    -- NULL means "the caller did not express an opinion". A create then
    -- defaults to 1 (the row is being given the shared default password),
    -- and an update leaves the existing flag alone. An explicit 0 or 1 is
    -- always honoured -- that is how sp_org_user_set_password's Web-tier
    -- sibling and any future admin reset can drive the flag through the
    -- normal save path.
    DECLARE @force_password_change BIT =
        TRY_CONVERT(BIT, NULLIF(JSON_VALUE(@p_payload,'$.forcePasswordChange'),''));

    -- ---- 341 addition ----
    -- Functional User classification. NULL = caller did not express an
    -- opinion: a create defaults to 0 (a normal user), an update leaves the
    -- stored flag alone. The Users form serialises a checkbox as a JSON
    -- boolean (true/false), so parse both that and 1/0 -- TRY_CONVERT(BIT,...)
    -- alone returns NULL for the string 'true', which would silently drop the
    -- tick.
    DECLARE @is_functional_user_raw NVARCHAR(10) =
        LOWER(NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.isFunctionalUser'))),''));
    DECLARE @is_functional_user BIT =
        CASE @is_functional_user_raw
            WHEN 'true'  THEN 1  WHEN '1' THEN 1
            WHEN 'false' THEN 0  WHEN '0' THEN 0
            ELSE NULL END;

    -- ---- original validation, unchanged ----
    IF @employee_org_id IS NULL THROW 51047,'Organization is required for User / Employee.',1;
    IF @employee_code IS NULL   THROW 51048,'Employee Code is required.',1;
    IF @employee_name IS NULL   THROW 51049,'Employee Name is required.',1;
    IF @employee_email IS NULL  THROW 51148,'Email ID is required for User / Employee login.',1;
    IF EXISTS(SELECT 1 FROM grac_practice.organization_employee
               WHERE LOWER(LTRIM(RTRIM(email))) = LOWER(@employee_email) AND (@p_id = 0 OR employee_id <> @p_id))
        THROW 51149,'Employee Email ID already exists.',1;
    -- KEPT as a backstop. The browser no longer collects a password; the
    -- Web gateway substitutes the hash of the configured default. Reaching
    -- this THROW now means the gateway was bypassed or is out of date.
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

    -- ---- 133 validation ----
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
        -- An employee with a provider is a contradiction; clear it rather than
        -- letting the CHECK reject an otherwise valid save.
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
             is_functional_user,
             status, record_status_id, entered_by)
        SELECT @employee_org_id, @employee_code, @employee_name, @employee_email, @employee_password_hash,
               @employee_role_id, JSON_VALUE(@p_payload,'$.designation'),
               @employee_location_id, d.department_name, @employee_department_id, @employee_function_id,
               @employee_reporting_officer_id,
               @party_type, @provider_vendor_id, @engagement_start, @engagement_end,
               -- 208: a new account holds the shared default until its owner
               -- replaces it, so the default is 1, not 0.
               COALESCE(@force_password_change, 1),
               -- 341: a new user is a normal user unless the box was ticked.
               COALESCE(@is_functional_user, 0),
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
               -- 208: an ordinary edit (name, role, location) must not clear a
               -- pending forced change, so an absent key leaves the flag as is.
               force_password_change = COALESCE(@force_password_change, e.force_password_change),
               -- 341: same "absent key leaves it alone" contract.
               is_functional_user = COALESCE(@is_functional_user, e.is_functional_user),
               status = COALESCE(JSON_VALUE(@p_payload,'$.status'), e.status),
               record_status_id = COALESCE(@payload_record_status_id, e.record_status_id),
               updated_by = @p_usr_id, updated_dt = SYSUTCDATETIME()
        FROM   grac_practice.organization_employee e
        OUTER APPLY (SELECT department_name FROM grac_practice.organization_department
                      WHERE department_id = @employee_department_id) d
        WHERE  e.employee_id = @p_id;
        SET @out_id = @p_id;
    END

    -- Original side effect, preserved.
    IF @employee_email IS NOT NULL
        INSERT grac_practice.user_organization_map
            (user_email, organization_id, access_role, is_default, status, record_status_id, entered_by)
        SELECT @employee_email, @employee_org_id, 'Organization User', 0, 'Active', @active_record_status_id, @p_usr_id
        WHERE NOT EXISTS(SELECT 1 FROM grac_practice.user_organization_map
                          WHERE user_email = @employee_email AND organization_id = @employee_org_id);
END;
GO

-- ---------------------------------------------------------------------
-- 3. sp_org_user_list -- 208 body + IsFunctionalUser output
-- ---------------------------------------------------------------------
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
           -- 133
           e.party_type PartyType,
           CASE e.party_type WHEN N'ThirdParty' THEN N'Third-party personnel'
                             ELSE N'Employee' END PersonnelType,
           e.provider_vendor_id ProviderVendorId, COALESCE(pv.vendor_name,'') Provider,
           e.engagement_start_dt EngagementStartDate,
           e.engagement_end_dt EngagementEndDate,
           -- Surfaced so an expired external account is visible in the grid
           -- rather than only in a report nobody runs.
           CAST(CASE WHEN e.party_type = N'ThirdParty'
                      AND e.engagement_end_dt IS NOT NULL
                      AND e.engagement_end_dt < CAST(SYSUTCDATETIME() AS DATE)
                     THEN 1 ELSE 0 END AS BIT) EngagementExpired,
           -- 208
           CAST(ISNULL(e.force_password_change,0) AS BIT) ForcePasswordChange,
           CASE WHEN ISNULL(e.force_password_change,0) = 1
                THEN N'Default password'
                ELSE N'Password set' END CredentialStatus,
           -- 341: the Functional User flag, for the grid and the edit form.
           CAST(ISNULL(e.is_functional_user,0) AS BIT) IsFunctionalUser,
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

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 341 verification ===';
SELECT '341 column present' Check_,
       CASE WHEN COL_LENGTH('grac_practice.organization_employee','is_functional_user') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END Result
UNION ALL
SELECT '341 save reads isFunctionalUser',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_user_save','P')) LIKE '%$.isFunctionalUser%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '341 list returns IsFunctionalUser',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_user_list','P')) LIKE '%IsFunctionalUser%'
            THEN 'PASS' ELSE 'FAIL' END;
GO
