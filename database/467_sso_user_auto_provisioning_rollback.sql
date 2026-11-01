-- =====================================================================
-- 467 SSO user auto-provisioning -- ROLLBACK
--
-- Drops sp_org_sso_provision_user / sp_org_sso_user_approve, puts
-- sp_org_sso_setting_get / _save back to their 466 bodies and
-- sp_org_user_list back to its 341 body, then drops the three
-- organization_sso_setting columns.
--
-- Users already created by SSO stay (they are ordinary employee rows).
-- A user still 'Pending Approval' stays unable to sign in (status is not
-- Active); approve them first, or set them Active / Inactive through the
-- Users form, before rolling back. The API treats the missing provisioning
-- procedure as "auto-create off" (SSO for unknown people is refused, as
-- in 466).
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_org_sso_user_approve','P')   IS NOT NULL DROP PROCEDURE grac_practice.sp_org_sso_user_approve;
IF OBJECT_ID('grac_practice.sp_org_sso_provision_user','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_sso_provision_user;
GO

-- 466 bodies (copied verbatim from 466_organization_sso_settings.sql)
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sso_setting_get
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    -- One row always (defaults = SSO off) so the screen needs no
    -- "not configured yet" branch.
    SELECT o.organization_id                                    AS OrganizationId,
           CAST(ISNULL(s.sso_enabled, 0)     AS BIT)            AS SsoEnabled,
           CAST(ISNULL(s.allow_microsoft, 0) AS BIT)            AS AllowMicrosoft,
           CAST(ISNULL(s.allow_google, 0)    AS BIT)            AS AllowGoogle,
           ISNULL(s.microsoft_tenant_ids, N'')                  AS MicrosoftTenantIds,
           ISNULL(s.allowed_email_domains, N'')                 AS AllowedEmailDomains,
           ISNULL(s.login_mode, N'SSO_AND_PASSWORD')            AS LoginMode,
           ISNULL(s.updated_by, s.entered_by)                   AS UpdatedBy,
           ISNULL(s.updated_dt, s.entered_dt)                   AS UpdatedDt
    FROM grac_practice.organization o
    LEFT JOIN grac_practice.organization_sso_setting s ON s.organization_id = o.organization_id
    WHERE o.organization_id = @organization_id;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_sso_setting_save
    @organization_id       BIGINT,
    @sso_enabled           BIT,
    @allow_microsoft       BIT,
    @allow_google          BIT,
    @microsoft_tenant_ids  NVARCHAR(1000) = NULL,
    @allowed_email_domains NVARCHAR(1000) = NULL,
    @login_mode            NVARCHAR(20)   = N'SSO_AND_PASSWORD',
    @actor                 NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 57466, 'Organization not found.', 1;

    SET @login_mode      = UPPER(LTRIM(RTRIM(ISNULL(@login_mode, N'SSO_AND_PASSWORD'))));
    SET @sso_enabled     = ISNULL(@sso_enabled, 0);
    SET @allow_microsoft = ISNULL(@allow_microsoft, 0);
    SET @allow_google    = ISNULL(@allow_google, 0);
    IF @login_mode NOT IN (N'SSO_AND_PASSWORD', N'SSO_ONLY')
        THROW 57467, 'Login mode must be SSO + Password or SSO Only.', 1;

    -- Lists: commas, semicolons, spaces or new lines all separate; stored
    -- trimmed, lower-case, de-duplicated, comma-joined.
    DECLARE @tenants NVARCHAR(1000), @domains NVARCHAR(1000);
    DECLARE @tenant_items TABLE (item NVARCHAR(200) PRIMARY KEY);
    DECLARE @domain_items TABLE (item NVARCHAR(200) PRIMARY KEY);

    INSERT @tenant_items(item)
    SELECT DISTINCT LOWER(LTRIM(RTRIM(value)))
    FROM STRING_SPLIT(REPLACE(REPLACE(REPLACE(REPLACE(ISNULL(@microsoft_tenant_ids, N''),
             CHAR(13), N','), CHAR(10), N','), N';', N','), N' ', N','), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    INSERT @domain_items(item)
    SELECT DISTINCT LOWER(LTRIM(RTRIM(REPLACE(value, N'@', N''))))
    FROM STRING_SPLIT(REPLACE(REPLACE(REPLACE(REPLACE(ISNULL(@allowed_email_domains, N''),
             CHAR(13), N','), CHAR(10), N','), N';', N','), N' ', N','), N',')
    WHERE LTRIM(RTRIM(REPLACE(value, N'@', N''))) <> N'';

    IF EXISTS (SELECT 1 FROM @tenant_items WHERE TRY_CONVERT(UNIQUEIDENTIFIER, item) IS NULL)
        THROW 57468, 'Each Microsoft Tenant ID must be a GUID (Directory (tenant) ID from Microsoft Entra).', 1;
    IF EXISTS (SELECT 1 FROM @domain_items
                WHERE item NOT LIKE N'%_._%' OR item LIKE N'%[^a-z0-9.-]%' OR item LIKE N'.%' OR item LIKE N'%.')
        THROW 57468, 'Each email domain must look like example.com.', 1;

    SELECT @tenants = STRING_AGG(item, N',') WITHIN GROUP (ORDER BY item) FROM @tenant_items;
    SELECT @domains = STRING_AGG(item, N',') WITHIN GROUP (ORDER BY item) FROM @domain_items;

    -- Only an ENABLED setting has to be complete; a disabled one may keep
    -- half-entered values for later.
    IF @sso_enabled = 1
    BEGIN
        IF @allow_microsoft = 0 AND @allow_google = 0
            THROW 57469, 'Select at least one sign-in provider (Microsoft or Google) to enable single sign-on.', 1;
        IF @allow_microsoft = 1 AND @tenants IS NULL
            THROW 57469, 'Enter the Microsoft Tenant ID of this organization to allow Microsoft sign-in.', 1;
        IF @allow_google = 1 AND @domains IS NULL
            THROW 57469, 'Enter the allowed email domain(s) to allow Google sign-in.', 1;
    END
    IF @login_mode = N'SSO_ONLY' AND @sso_enabled = 0
        THROW 57469, 'SSO Only needs single sign-on to be enabled.', 1;

    DECLARE @before NVARCHAR(MAX) =
        (SELECT sso_enabled, allow_microsoft, allow_google, microsoft_tenant_ids,
                allowed_email_domains, login_mode
         FROM grac_practice.organization_sso_setting
         WHERE organization_id = @organization_id
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRAN;
        UPDATE grac_practice.organization_sso_setting
           SET sso_enabled           = @sso_enabled,
               allow_microsoft       = @allow_microsoft,
               allow_google          = @allow_google,
               microsoft_tenant_ids  = @tenants,
               allowed_email_domains = @domains,
               login_mode            = @login_mode,
               updated_by            = ISNULL(@actor, N'system'),
               updated_dt            = SYSUTCDATETIME()
         WHERE organization_id = @organization_id;

        IF @@ROWCOUNT = 0
            INSERT grac_practice.organization_sso_setting
                (organization_id, sso_enabled, allow_microsoft, allow_google,
                 microsoft_tenant_ids, allowed_email_domains, login_mode, entered_by)
            VALUES (@organization_id, @sso_enabled, @allow_microsoft, @allow_google,
                    @tenants, @domains, @login_mode, ISNULL(@actor, N'system'));

        -- Audit Traceability: who changed an organization's sign-in policy.
        INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        SELECT N'organization-sso-setting', @organization_id,
               CASE WHEN @before IS NULL THEN N'CREATE' ELSE N'UPDATE' END,
               @before,
               (SELECT sso_enabled, allow_microsoft, allow_google, microsoft_tenant_ids,
                       allowed_email_domains, login_mode
                FROM grac_practice.organization_sso_setting
                WHERE organization_id = @organization_id
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
               N'Active', ISNULL(@actor, N'system');
    COMMIT;

    EXEC grac_practice.sp_org_sso_setting_get @organization_id;
END
GO

-- 341 body (copied verbatim from 341_functional_user_flag.sql)
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

IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'fk_pm_org_sso_default_role')
    ALTER TABLE grac_practice.organization_sso_setting DROP CONSTRAINT fk_pm_org_sso_default_role;
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = N'df_pm_org_sso_auto_create')
    ALTER TABLE grac_practice.organization_sso_setting DROP CONSTRAINT df_pm_org_sso_auto_create;
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = N'df_pm_org_sso_require_approval')
    ALTER TABLE grac_practice.organization_sso_setting DROP CONSTRAINT df_pm_org_sso_require_approval;
GO
IF COL_LENGTH('grac_practice.organization_sso_setting','auto_create_users') IS NOT NULL
    ALTER TABLE grac_practice.organization_sso_setting DROP COLUMN auto_create_users;
IF COL_LENGTH('grac_practice.organization_sso_setting','default_role_id') IS NOT NULL
    ALTER TABLE grac_practice.organization_sso_setting DROP COLUMN default_role_id;
IF COL_LENGTH('grac_practice.organization_sso_setting','require_admin_approval') IS NOT NULL
    ALTER TABLE grac_practice.organization_sso_setting DROP COLUMN require_admin_approval;
GO

SELECT '467-rollback removed' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_sso_provision_user','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_org_sso_user_approve','P') IS NULL
             AND COL_LENGTH('grac_practice.organization_sso_setting','auto_create_users') IS NULL
            THEN 'OK' ELSE 'STILL PRESENT' END AS Result;
GO
