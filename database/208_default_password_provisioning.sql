-- =====================================================================
-- 208 Default password provisioning + forced first-login change
--
-- THE DEFECT THIS CLOSES
-- ----------------------
-- Adding a user from Organization Setup failed with:
--     "The practice database operation failed. SQL error 51152."
-- 51152 is sp_org_user_save's own THROW -- "Password is required when
-- creating a User / Employee." The Users form declared Password as an
-- OPTIONAL field (practice.js: password("password","Password") defaults
-- required=false), and the Web gateway only produces a passwordHash when
-- a non-blank password is present. Leave the box empty and the payload
-- carries no hash, so the create hits the THROW. Edits were unaffected
-- because the rule is guarded by @p_id = 0.
--
-- THE DECISION
-- ------------
-- The Password box is being REMOVED from the Users form entirely. Every
-- new user is provisioned with a single configured default password, and
-- is required to replace it at first sign-in before any session is
-- issued. Nobody types another person's password into a form, and no
-- account can transact while it still holds the shared default.
--
-- WHY THE HASH STILL ARRIVES FROM THE APPLICATION
-- -----------------------------------------------
-- It would be neater to default the password inside this procedure. It is
-- not possible: password_hash holds PBKDF2-SHA256 in the encoded form
-- "iterations.salt.hash" produced by PracticeManagement.Web.Security.
-- PasswordHasher, and T-SQL cannot produce a matching value. So the Web
-- tier hashes the configured default (UserProvisioning:DefaultPassword)
-- and sends it as $.passwordHash, exactly as the org-admin OTP flow in
-- migration 034 already does. THROW 51152 is deliberately KEPT as the
-- backstop for any caller that reaches the procedure directly.
--
-- >>> DEPLOY ORDER MATTERS <<<
-- Deploy PracticeManagement.Web together with this migration. This script
-- alone does not fix the defect -- the gateway change is what stops the
-- payload arriving without a hash.
--
-- WHY force_password_change IS NOT A NEW COLUMN
-- ---------------------------------------------
-- Migration 032 already added organization_employee.force_password_change
-- (BIT NOT NULL DEFAULT 0) and migration 034 already sets it to 1 for
-- auto-provisioned org admins. Nothing has ever read it -- the login path
-- in PracticeLoginService never selected the column. This migration makes
-- it writable through the normal user save and readable by the grid; the
-- Web tier supplies the enforcement that was missing.
--
-- Objects:
--   * sp_org_user_save          ALTERED -- honours $.forcePasswordChange
--   * sp_org_user_list          ALTERED -- exposes ForcePasswordChange +
--                                          CredentialStatus
--   * sp_org_user_set_password  NEW     -- first-login password change
--
-- ERROR CODES: 52320-52322. 52300-52303 belong to 133 (users) and
--              52310-52312 to 133 (teams); 52320+ is the next free block
--              in that migration's reserved 52300-52319 neighbourhood.
-- Depends on 032 (force_password_change), 133 (sp_org_user_save/list).
-- Rollback: 208_default_password_provisioning_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_org_user_save','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_user_list','P') IS NULL
BEGIN
    RAISERROR('208: prerequisites missing (run 133_org_party_and_team_type.sql first).', 16, 1);
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.organization_employee','force_password_change') IS NULL
BEGIN
    RAISERROR('208: organization_employee.force_password_change missing (run 032_ownership_role_model.sql first).', 16, 1);
    SET NOEXEC ON;
END
GO


-- =====================================================================
-- 1. sp_org_user_save
--    133's body, unchanged, plus the forcePasswordChange handling. The
--    133 comments are preserved so the two versions stay diff-able.
-- =====================================================================
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
             status, record_status_id, entered_by)
        SELECT @employee_org_id, @employee_code, @employee_name, @employee_email, @employee_password_hash,
               @employee_role_id, JSON_VALUE(@p_payload,'$.designation'),
               @employee_location_id, d.department_name, @employee_department_id, @employee_function_id,
               @employee_reporting_officer_id,
               @party_type, @provider_vendor_id, @engagement_start, @engagement_end,
               -- 208: a new account holds the shared default until its owner
               -- replaces it, so the default is 1, not 0.
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
               -- 208: an ordinary edit (name, role, location) must not clear a
               -- pending forced change, so an absent key leaves the flag as is.
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

    -- Original side effect, preserved.
    IF @employee_email IS NOT NULL
        INSERT grac_practice.user_organization_map
            (user_email, organization_id, access_role, is_default, status, record_status_id, entered_by)
        SELECT @employee_email, @employee_org_id, 'Organization User', 0, 'Active', @active_record_status_id, @p_usr_id
        WHERE NOT EXISTS(SELECT 1 FROM grac_practice.user_organization_map
                          WHERE user_email = @employee_email AND organization_id = @employee_org_id);
END;
GO


-- =====================================================================
-- 2. sp_org_user_list -- 133's body plus the credential state
--
--    An account still holding the shared default is an open door: the
--    password is known to everyone who has read the config. Showing it
--    only in a report nobody runs is how these accounts survive for
--    years, so it goes on the grid next to Status -- the same argument
--    133 made for EngagementExpired.
-- =====================================================================
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
-- 3. sp_org_user_set_password
--    The first-login change. Called by PracticeManagement.Web after it
--    has re-verified the current password and hashed the new one.
--
--    WHY THIS IS NOT sp_org_user_save WITH A passwordHash
--    ----------------------------------------------------
--    The user changing their own password is not an administrator and
--    holds no session yet -- LoginController blocks the session until the
--    change completes. Routing this through the entity save would mean
--    granting the pre-session caller the users-save path, with its
--    organization, role and personnel-type rewriting. This procedure can
--    only touch two columns of one row, which is all the flow needs.
--
--    The procedure does NOT verify the old password: the Web tier holds
--    the PBKDF2 implementation and has already done so. It does refuse to
--    act on an inactive employee, so a disabled account cannot be
--    reactivated through the change-password screen.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_user_set_password
    @employee_id   BIGINT,
    @password_hash NVARCHAR(500),
    @entered_by    NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @employee_id IS NULL OR @employee_id <= 0
        THROW 52320,'A user must be identified before the password can be changed.',1;
    IF LEN(ISNULL(@password_hash, N'')) = 0
        THROW 52321,'A password hash is required.',1;
    IF NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee
                   WHERE employee_id = @employee_id AND status = N'Active')
        THROW 52322,'This account is not active. Contact your administrator.',1;

    UPDATE grac_practice.organization_employee
       SET password_hash         = @password_hash,
           force_password_change = 0,
           updated_by            = @entered_by,
           updated_dt            = SYSUTCDATETIME()
     WHERE employee_id = @employee_id;

    SELECT CAST(1 AS BIT) Success, @employee_id EmployeeId;
END;
GO


-- =====================================================================
-- 4. Verification
-- =====================================================================
SELECT 'sp_org_user_save'          Object,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_user_save','P')         IS NOT NULL THEN 'PASS' ELSE 'FAIL' END Result
UNION ALL SELECT 'sp_org_user_list',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_user_list','P')         IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_org_user_set_password',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_user_set_password','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'force_password_change column',
       CASE WHEN COL_LENGTH('grac_practice.organization_employee','force_password_change') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;
GO

PRINT '--- Accounts still holding a default password ---';
SELECT e.organization_id, e.employee_code, e.employee_name, e.email, e.status
  FROM grac_practice.organization_employee e
 WHERE ISNULL(e.force_password_change,0) = 1
 ORDER BY e.organization_id, e.employee_name;
GO

PRINT '208 Default password provisioning deployed.';
PRINT 'NEXT: deploy PracticeManagement.Web -- this script alone does not fix SQL error 51152.';
PRINT '      Set UserProvisioning:DefaultPassword in appsettings before creating users.';
GO

SET NOEXEC OFF;
GO
