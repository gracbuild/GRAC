-- =====================================================================
-- 133 Organization setup -- personnel type on users, sourcing type on teams
--
-- WHAT THIS ADDS
-- -------------
-- User Management: is this person an employee, or third-party personnel?
--   A third-party user must name the PROVIDER that supplies them.
-- Team Management: is this an in-house team or a vendor-managed one?
--   A vendor-managed team must name the VENDOR delivering it.
--
-- Team Manager is left exactly as it is -- the column, the validation and
-- the grid column all already exist and already answer "who leads this
-- team". Adding a second near-identical people field would leave an
-- auditor asking which of the two is actually accountable.
--
-- WHY THE PROVIDER IS MANDATORY FOR THIRD-PARTY PERSONNEL
-- ------------------------------------------------------
-- A third-party account with no named provider is an accountability gap:
-- nobody owns the contract that governs the person's access, and there is
-- no vendor record to terminate against when the engagement ends. Under
-- ISO 27002:2022 supplier-relationship controls that is a finding on its
-- own. The CHECK constraint makes it impossible to record one.
--
-- WHY THE VOCABULARY LIVES IN PROCEDURES, NOT NEW MASTER TABLES
-- ------------------------------------------------------------
-- Two values each, fixed by the schema CHECK. Migration 093 established
-- the pattern for exactly this case -- sp_org_assurance_trigger_type_list
-- returns a small FROM (VALUES ...) set. Two more master tables would need
-- seeding, rollback and referential upkeep for four rows that cannot change
-- without a code change anyway. The list procedures below are the single
-- source of the labels, so the UI never hardcodes them.
--
-- WHY users AND teams MOVE OUT OF dbo.pm_manage_practice_repository
-- ----------------------------------------------------------------
-- That procedure is 2,003 lines covering 40-plus entity types, and
-- CREATE OR ALTER can only replace it whole. Extending it in place would
-- mean copying all 2,003 lines into this migration, most of which cannot
-- be meaningfully reviewed here, and would leave two copies with no clear
-- authority. So the two entity types this feature touches get their own
-- procedures, reproducing the existing validation exactly and adding the
-- new fields. The remaining entity types stay where they are. The gateway
-- routes 'users' and 'teams' to these; everything else is untouched.
--
-- Objects:
--   * grac_practice.organization_employee  (+ party_type, provider_vendor_id,
--                                             engagement_start_dt, engagement_end_dt)
--   * grac_practice.organization_team      (+ team_type, vendor_id)
--   * sp_org_personnel_type_list  NEW
--   * sp_org_team_type_list       NEW
--   * sp_org_user_save / sp_org_user_list  NEW
--   * sp_org_team_save / sp_org_team_list  NEW
--
-- ERROR CODES: 52300-52319. Checked against every THROW in the repo: 514xx
--              belongs to migration 009, and 51xxx, 520xx, 521xx, 522xx and
--              527xx are all taken. The monolith owns 51047-51152.
-- Rollback: 133_org_party_and_team_type_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.organization_employee','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_team','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_dependency_vendor','U') IS NULL
BEGIN
    RAISERROR('133: prerequisites missing (organization_employee / organization_team / organization_dependency_vendor).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. organization_employee -- personnel type + provider
-- =====================================================================
IF COL_LENGTH('grac_practice.organization_employee','party_type') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD party_type NVARCHAR(30) NULL;
GO

IF COL_LENGTH('grac_practice.organization_employee','provider_vendor_id') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD provider_vendor_id BIGINT NULL;
GO

-- An engagement window matters more for third parties than for employees:
-- an external account that outlives its contract is the single most common
-- access finding, and this product already carries a Dormant Account
-- Disablement obligation that has nothing to measure without an end date.
IF COL_LENGTH('grac_practice.organization_employee','engagement_start_dt') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD engagement_start_dt DATE NULL;
GO

IF COL_LENGTH('grac_practice.organization_employee','engagement_end_dt') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD engagement_end_dt DATE NULL;
GO

-- Everyone recorded before this migration was entered through a form that
-- only accepted employees, so that is what they are.
IF COL_LENGTH('grac_practice.organization_employee','party_type') IS NOT NULL
    EXEC('UPDATE grac_practice.organization_employee
             SET party_type = N''Employee'' WHERE party_type IS NULL;');
GO

IF COL_LENGTH('grac_practice.organization_employee','party_type') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'df_pm_employee_party_type')
    EXEC('ALTER TABLE grac_practice.organization_employee
              ADD CONSTRAINT df_pm_employee_party_type DEFAULT N''Employee'' FOR party_type;');
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_employee_party_type')
    EXEC('ALTER TABLE grac_practice.organization_employee
              ADD CONSTRAINT ck_pm_employee_party_type CHECK (
                  party_type IS NULL OR party_type IN (N''Employee'', N''ThirdParty''));');
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_employee_provider_vendor')
    ALTER TABLE grac_practice.organization_employee
        ADD CONSTRAINT fk_pm_employee_provider_vendor
            FOREIGN KEY (provider_vendor_id)
            REFERENCES grac_practice.organization_dependency_vendor(vendor_id);
GO

-- The accountability rule, enforced where it cannot be bypassed:
-- third-party personnel must name a provider; an employee must not.
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_employee_provider_required')
    EXEC('ALTER TABLE grac_practice.organization_employee
              ADD CONSTRAINT ck_pm_employee_provider_required CHECK (
                  party_type IS NULL
               OR (party_type = N''ThirdParty'' AND provider_vendor_id IS NOT NULL)
               OR (party_type = N''Employee''   AND provider_vendor_id IS NULL));');
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_employee_engagement_dates')
    EXEC('ALTER TABLE grac_practice.organization_employee
              ADD CONSTRAINT ck_pm_employee_engagement_dates CHECK (
                  engagement_end_dt IS NULL OR engagement_start_dt IS NULL
               OR engagement_end_dt >= engagement_start_dt);');
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_employee_party_type'
                 AND object_id = OBJECT_ID('grac_practice.organization_employee'))
    CREATE INDEX ix_pm_employee_party_type
        ON grac_practice.organization_employee(organization_id, party_type, status)
        INCLUDE (employee_code, employee_name, provider_vendor_id, engagement_end_dt);
GO


-- =====================================================================
-- 2. organization_team -- sourcing type + vendor
-- =====================================================================
IF COL_LENGTH('grac_practice.organization_team','team_type') IS NULL
    ALTER TABLE grac_practice.organization_team ADD team_type NVARCHAR(30) NULL;
GO

IF COL_LENGTH('grac_practice.organization_team','vendor_id') IS NULL
    ALTER TABLE grac_practice.organization_team ADD vendor_id BIGINT NULL;
GO

IF COL_LENGTH('grac_practice.organization_team','team_type') IS NOT NULL
    EXEC('UPDATE grac_practice.organization_team
             SET team_type = N''InHouse'' WHERE team_type IS NULL;');
GO

IF COL_LENGTH('grac_practice.organization_team','team_type') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'df_pm_team_team_type')
    EXEC('ALTER TABLE grac_practice.organization_team
              ADD CONSTRAINT df_pm_team_team_type DEFAULT N''InHouse'' FOR team_type;');
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_team_team_type')
    EXEC('ALTER TABLE grac_practice.organization_team
              ADD CONSTRAINT ck_pm_team_team_type CHECK (
                  team_type IS NULL OR team_type IN (N''InHouse'', N''Vendor''));');
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_team_vendor')
    ALTER TABLE grac_practice.organization_team
        ADD CONSTRAINT fk_pm_team_vendor
            FOREIGN KEY (vendor_id)
            REFERENCES grac_practice.organization_dependency_vendor(vendor_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_team_vendor_required')
    EXEC('ALTER TABLE grac_practice.organization_team
              ADD CONSTRAINT ck_pm_team_vendor_required CHECK (
                  team_type IS NULL
               OR (team_type = N''Vendor''  AND vendor_id IS NOT NULL)
               OR (team_type = N''InHouse'' AND vendor_id IS NULL));');
GO

COMMIT TRAN;
GO


-- =====================================================================
-- 3. Vocabulary. Single source of the labels the UI renders.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_personnel_type_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Code, Label, Description, DisplayOrder
    FROM (VALUES
        (N'Employee',   N'Employee',
         N'On the organisation''s payroll and governed by an employment contract.', 1),
        (N'ThirdParty', N'Third-party personnel',
         N'Contractor, vendor staff, consultant or auditor supplied under a contract with their provider.', 2)
    ) v(Code, Label, Description, DisplayOrder)
    ORDER BY DisplayOrder;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_team_type_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Code, Label, Description, DisplayOrder
    FROM (VALUES
        (N'InHouse', N'In-house',
         N'Staffed by the organisation''s own employees.', 1),
        (N'Vendor',  N'Vendor-managed',
         N'Delivered by a vendor''s personnel under contract. Accountability stays with the team manager.', 2)
    ) v(Code, Label, Description, DisplayOrder)
    ORDER BY DisplayOrder;
END;
GO


-- =====================================================================
-- 4. sp_org_user_save
--    Reproduces the 'users' branch of dbo.pm_manage_practice_repository
--    verbatim -- same JSON keys, same THROW numbers and messages, same
--    user_organization_map side effect -- then adds the new fields.
--    Existing THROW numbers are kept so any caller matching on them, and
--    anyone reading a support ticket, still sees the same code.
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

    -- ---- original validation, unchanged ----
    IF @employee_org_id IS NULL THROW 51047,'Organization is required for User / Employee.',1;
    IF @employee_code IS NULL   THROW 51048,'Employee Code is required.',1;
    IF @employee_name IS NULL   THROW 51049,'Employee Name is required.',1;
    IF @employee_email IS NULL  THROW 51148,'Email ID is required for User / Employee login.',1;
    IF EXISTS(SELECT 1 FROM grac_practice.organization_employee
               WHERE LOWER(LTRIM(RTRIM(email))) = LOWER(@employee_email) AND (@p_id = 0 OR employee_id <> @p_id))
        THROW 51149,'Employee Email ID already exists.',1;
    IF @p_id = 0 AND @employee_password_hash IS NULL THROW 51152,'Password is required when creating a User / Employee.',1;
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
             status, record_status_id, entered_by)
        SELECT @employee_org_id, @employee_code, @employee_name, @employee_email, @employee_password_hash,
               @employee_role_id, JSON_VALUE(@p_payload,'$.designation'),
               @employee_location_id, d.department_name, @employee_department_id, @employee_function_id,
               @employee_reporting_officer_id,
               @party_type, @provider_vendor_id, @engagement_start, @engagement_end,
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
-- 5. sp_org_user_list -- the 'users' read branch + the new columns
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
-- 6. sp_org_team_save -- the 'teams' write branch + the new fields
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_team_save
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

    DECLARE @team_org_id       BIGINT        = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
    DECLARE @team_name         NVARCHAR(200) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
    DECLARE @team_manager_id   BIGINT        = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.teamManagerId'),''));
    DECLARE @team_department_id BIGINT       = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.parentDepartmentId'),''));
    DECLARE @team_status_id    INT           = COALESCE(@payload_record_status_id, @active_record_status_id);
    DECLARE @team_status_name  NVARCHAR(30)  =
        COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id = @team_status_id),'Active');

    -- ---- status restriction (2026-09-20 change request) ----
    -- Same guard as Location/Department: a NEW status may only be Active
    -- or Inactive going forward; a team already sitting on a legacy status
    -- (Retired/Draft/Disposed/...) is left alone as long as this save does
    -- not actually change its status. @current_record_status_id is NULL on
    -- INSERT, so a brand-new row (status hidden on the Add form, defaults
    -- Active) is always checked too.
    DECLARE @current_record_status_id INT =
        CASE WHEN @p_id <> 0 THEN (SELECT record_status_id FROM grac_practice.organization_team WHERE team_id = @p_id) END;
    IF @team_status_id <> ISNULL(@current_record_status_id, -1)
       AND NOT EXISTS (SELECT 1 FROM grac_practice.record_status_master
                         WHERE record_status_id = @team_status_id AND status_code IN ('Active','Inactive'))
        THROW 51079, 'Team status can only be set to Active or Inactive.', 1;

    -- ---- 133 additions ----
    DECLARE @team_type NVARCHAR(30) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.teamType'))),'');
    DECLARE @team_vendor_id BIGINT  = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.vendorId'),''));
    SET @team_type = COALESCE(@team_type, N'InHouse');

    -- ---- original validation, unchanged ----
    IF @team_org_id IS NULL THROW 51068,'Organization is required for Team.',1;
    IF @team_name IS NULL   THROW 51069,'Team Name is required.',1;
    IF @team_manager_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee
                   WHERE employee_id = @team_manager_id AND organization_id = @team_org_id AND status = 'Active')
        THROW 51070,'Selected Team Manager is not valid for this organization.',1;
    IF @team_department_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_department
                   WHERE department_id = @team_department_id AND organization_id = @team_org_id AND status = 'Active')
        THROW 51071,'Selected Parent Department is not valid for this organization.',1;

    -- ---- 133 validation ----
    IF @team_type NOT IN (N'InHouse', N'Vendor')
        THROW 52310,'Team Type must be In-house or Vendor-managed.',1;

    IF @team_type = N'Vendor'
    BEGIN
        IF @team_vendor_id IS NULL
            THROW 52311,'Vendor is required for a vendor-managed team. Register the vendor first, then select it here.',1;
        IF NOT EXISTS(SELECT 1 FROM grac_practice.organization_dependency_vendor
                       WHERE vendor_id = @team_vendor_id AND organization_id = @team_org_id AND status = 'Active')
            THROW 52312,'Selected Vendor is not a valid active vendor for this organization.',1;
    END
    ELSE
        SET @team_vendor_id = NULL;

    -- ---- Team Members (change request 2026-09-20) ----
    -- @p_payload.memberIds is a JSON array of organization_employee ids
    -- picked from the Department -> Employee tree, e.g. [3,7,11].
    -- Missing entirely means "leave existing members untouched" (so any
    -- caller that does not send this key can never wipe membership); an
    -- explicit empty array [] means "clear all members" -- the UI always
    -- posts the full current tree selection, not a diff.
    --
    -- Guarded by OBJECT_ID so a database that has not yet run migration
    -- 362 keeps saving Teams exactly as before -- member selection simply
    -- has no effect until 362 is deployed, the same degrade-the-feature
    -- rule the migration-134/241/244/248/342 shims already use.
    DECLARE @member_ids_json NVARCHAR(MAX) = NULL;
    IF OBJECT_ID('grac_practice.organization_team_member','U') IS NOT NULL
    BEGIN
        SET @member_ids_json = JSON_QUERY(@p_payload, '$.memberIds');
        IF @member_ids_json IS NOT NULL AND ISJSON(@member_ids_json) <> 1
            THROW 51082, 'Team Members selection is not a valid list.', 1;
    END

    -- Only organization-matching, currently Active employees are staged --
    -- silently dropping anything else (a stale checkbox for an employee
    -- deactivated after the form loaded, or from another organization)
    -- rather than failing the whole Team save over it. This is also what
    -- keeps employees from other organizations, or inactive employees,
    -- out of a Team's membership even if a payload somehow named one.
    DECLARE @valid_member_ids TABLE (employee_id BIGINT PRIMARY KEY);
    IF @member_ids_json IS NOT NULL
        INSERT @valid_member_ids (employee_id)
        SELECT DISTINCT e.employee_id
        FROM   OPENJSON(@member_ids_json) WITH (employee_id BIGINT '$') j
        JOIN   grac_practice.organization_employee e
               ON e.employee_id     = j.employee_id
              AND e.organization_id = @team_org_id
              AND e.status          = N'Active';

    IF @p_id = 0
    BEGIN
        INSERT grac_practice.organization_team
            (organization_id, team_name, team_manager_id, parent_department_id,
             team_type, vendor_id, remarks, status, record_status_id, entered_by)
        VALUES
            (@team_org_id, @team_name, @team_manager_id, @team_department_id,
             @team_type, @team_vendor_id, JSON_VALUE(@p_payload,'$.remarks'),
             @team_status_name, @team_status_id, @p_usr_id);
        SET @out_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_team
           SET organization_id = @team_org_id, team_name = @team_name,
               team_manager_id = @team_manager_id, parent_department_id = @team_department_id,
               team_type = @team_type, vendor_id = @team_vendor_id,
               remarks = JSON_VALUE(@p_payload,'$.remarks'),
               status = @team_status_name, record_status_id = @team_status_id,
               updated_by = @p_usr_id, updated_dt = SYSUTCDATETIME()
         WHERE team_id = @p_id;
        SET @out_id = @p_id;
    END

    -- Replace the member set with whatever was just validated above -- a
    -- clean replace-per-save that cannot itself create a duplicate
    -- mapping. uq_pm_team_member is a second, schema-level guard on top
    -- of this. No-ops (both branches already NULL) when 362 has not run,
    -- or when the caller did not send memberIds at all.
    IF @member_ids_json IS NOT NULL
    BEGIN
        DELETE FROM grac_practice.organization_team_member WHERE team_id = @out_id;
        INSERT grac_practice.organization_team_member
            (team_id, employee_id, organization_id, status, record_status_id, entered_by)
        SELECT @out_id, v.employee_id, @team_org_id, N'Active', @active_record_status_id, @p_usr_id
        FROM   @valid_member_ids v;
    END
END;
GO


-- =====================================================================
-- 7. sp_org_team_list -- the 'teams' read branch + the new columns
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_team_list
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

    SELECT t.team_id Id, t.organization_id OrganizationId, t.team_name Name,
           t.team_manager_id TeamManagerId, COALESCE(m.employee_name,'') TeamManager,
           t.parent_department_id ParentDepartmentId, COALESCE(d.department_name,'') ParentDepartment,
           -- 133
           t.team_type TeamType,
           CASE t.team_type WHEN N'Vendor' THEN N'Vendor-managed' ELSE N'In-house' END TeamTypeLabel,
           t.vendor_id VendorId, COALESCE(v.vendor_name,'') Vendor,
           t.remarks Remarks, t.record_status_id StatusId, rs.status_name Status
    FROM       grac_practice.organization_team t
    JOIN       grac_practice.record_status_master rs ON rs.record_status_id = t.record_status_id
    LEFT JOIN  grac_practice.organization_employee m ON m.employee_id = t.team_manager_id
    LEFT JOIN  grac_practice.organization_department d ON d.department_id = t.parent_department_id
    LEFT JOIN  grac_practice.organization_dependency_vendor v ON v.vendor_id = t.vendor_id
    WHERE      (@p_id = 0 OR t.team_id = @p_id)
      AND      (@organization_id IS NULL OR t.organization_id = @organization_id)
      AND      (@p_status = '' OR t.record_status_id = @filter_record_status_id)
      AND      (@p_search = '' OR t.team_name LIKE '%'+@p_search+'%'
                               OR ISNULL(m.employee_name,'') LIKE '%'+@p_search+'%'
                               OR ISNULL(d.department_name,'') LIKE '%'+@p_search+'%'
                               OR ISNULL(v.vendor_name,'') LIKE '%'+@p_search+'%')
    ORDER BY   t.team_name
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO


-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'employee.party_type'          AS Check_, CASE WHEN COL_LENGTH('grac_practice.organization_employee','party_type')          IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'employee.provider_vendor_id',   CASE WHEN COL_LENGTH('grac_practice.organization_employee','provider_vendor_id') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'employee.engagement_end_dt',    CASE WHEN COL_LENGTH('grac_practice.organization_employee','engagement_end_dt')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'team.team_type',                CASE WHEN COL_LENGTH('grac_practice.organization_team','team_type')              IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'team.vendor_id',                CASE WHEN COL_LENGTH('grac_practice.organization_team','vendor_id')              IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'provider-required CHECK',       CASE WHEN EXISTS (SELECT 1 FROM sys.check_constraints WHERE name='ck_pm_employee_provider_required') THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'vendor-required CHECK',         CASE WHEN EXISTS (SELECT 1 FROM sys.check_constraints WHERE name='ck_pm_team_vendor_required')       THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_org_user_save',              CASE WHEN OBJECT_ID('grac_practice.sp_org_user_save','P')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_org_user_list',              CASE WHEN OBJECT_ID('grac_practice.sp_org_user_list','P')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_org_team_save',              CASE WHEN OBJECT_ID('grac_practice.sp_org_team_save','P')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_org_team_list',              CASE WHEN OBJECT_ID('grac_practice.sp_org_team_list','P')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_org_personnel_type_list',    CASE WHEN OBJECT_ID('grac_practice.sp_org_personnel_type_list','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_org_team_type_list',         CASE WHEN OBJECT_ID('grac_practice.sp_org_team_type_list','P')      IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;

PRINT '--- Vocabulary the UI must render (do not hardcode these strings) ---';
EXEC grac_practice.sp_org_personnel_type_list;
EXEC grac_practice.sp_org_team_type_list;

PRINT '133 Personnel type + team sourcing type deployed.';
PRINT 'NEXT: route the users / teams entity types to these procedures in the gateway,';
PRINT '      and add the fields to wwwroot/js/practice.js.';
GO

SET NOEXEC OFF;
GO
