-- =====================================================================
-- 467 SSO user auto-provisioning (Just-in-Time) with optional approval
--
-- WHY
-- ---
-- Until now single sign-on (466) let in only people who already had an
-- active GRAC employee row; anyone else was blocked. Change request
-- 2026-10-13: an organization may let a person its own Microsoft tenant /
-- Google domain has vouched for be CREATED in GRAC on their first SSO
-- sign-in, with a default role, and decide whether that new user is
-- active at once or waits for an administrator's approval.
--
-- WHAT
-- ----
-- 1. organization_sso_setting gets three settings (Organization
--    Administration -> Organization tab -> Single Sign-On card):
--      auto_create_users       1 = create unknown people on first SSO sign-in
--      default_role_id         the role every created user gets (required
--                              when auto_create_users = 1)
--      require_admin_approval  1 (default) = created as 'Pending Approval',
--                              cannot sign in until approved;
--                              0 = created Active and signed straight in
-- 2. sp_org_sso_setting_get / _save re-issued (466 bodies + the three
--    settings). Save also refuses a tenant id / email domain that another
--    auto-create organization already uses -- otherwise a new person could
--    match two organizations.
-- 3. sp_org_sso_provision_user (called by the API at SSO sign-in when no
--    active employee has the email). Finds the ONE organization whose
--    policy accepts the provider + tenant + domain and creates the
--    employee: name from the token, email, employee code from the email,
--    default role, no password (password_hash NULL -> password sign-in is
--    impossible), force_password_change 0. Audited as 'sso-provision'.
-- 4. sp_org_sso_user_approve -- Users tab "Approve" row action:
--    'Pending Approval' -> Active. Reject = the existing "Inactive" action.
-- 5. sp_org_user_list re-issued (341 body) with two display changes only:
--      Status           'Pending Approval' for a user waiting for approval
--                       (record status is Inactive underneath, so every
--                       existing Active filter / lookup / owner picker
--                       already leaves them out)
--      CredentialStatus 'Single sign-on' when the user has no password
--
-- A pending user has status = 'Pending Approval' and record status
-- Inactive. Sign-in needs status = 'Active', so nothing else in the
-- application can see or use a pending user until it is approved.
--
-- Requires 466, 341 (and 133/208/032 which those require). Re-runnable.
-- ASCII-only. Error codes 57470-57479.
-- Rollback: 467_sso_user_auto_provisioning_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.organization_sso_setting','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_user_list','P') IS NULL
   OR OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.user_organization_map','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','role_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','password_hash') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','party_type') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','force_password_change') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','is_functional_user') IS NULL
BEGIN
    RAISERROR('467: prerequisites missing (466, 341, 208, 133, 032).', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. The three settings
-- =====================================================================
IF COL_LENGTH('grac_practice.organization_sso_setting','auto_create_users') IS NULL
    ALTER TABLE grac_practice.organization_sso_setting
        ADD auto_create_users BIT NOT NULL CONSTRAINT df_pm_org_sso_auto_create DEFAULT 0 WITH VALUES;
GO
IF COL_LENGTH('grac_practice.organization_sso_setting','default_role_id') IS NULL
    ALTER TABLE grac_practice.organization_sso_setting
        ADD default_role_id BIGINT NULL
            CONSTRAINT fk_pm_org_sso_default_role REFERENCES grac_practice.organization_role(role_id);
GO
IF COL_LENGTH('grac_practice.organization_sso_setting','require_admin_approval') IS NULL
    ALTER TABLE grac_practice.organization_sso_setting
        ADD require_admin_approval BIT NOT NULL CONSTRAINT df_pm_org_sso_require_approval DEFAULT 1 WITH VALUES;
GO

-- =====================================================================
-- 2. Read / write (466 bodies + the three settings)
-- =====================================================================
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
           -- 467
           CAST(ISNULL(s.auto_create_users, 0) AS BIT)          AS AutoCreateUsers,
           s.default_role_id                                    AS DefaultRoleId,
           r.role_name                                          AS DefaultRoleName,
           CAST(ISNULL(s.require_admin_approval, 1) AS BIT)     AS RequireAdminApproval,
           ISNULL(s.updated_by, s.entered_by)                   AS UpdatedBy,
           ISNULL(s.updated_dt, s.entered_dt)                   AS UpdatedDt
    FROM grac_practice.organization o
    LEFT JOIN grac_practice.organization_sso_setting s ON s.organization_id = o.organization_id
    LEFT JOIN grac_practice.organization_role r ON r.role_id = s.default_role_id
    WHERE o.organization_id = @organization_id;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_sso_setting_save
    @organization_id        BIGINT,
    @sso_enabled            BIT,
    @allow_microsoft        BIT,
    @allow_google           BIT,
    @microsoft_tenant_ids   NVARCHAR(1000) = NULL,
    @allowed_email_domains  NVARCHAR(1000) = NULL,
    @login_mode             NVARCHAR(20)   = N'SSO_AND_PASSWORD',
    @actor                  NVARCHAR(100)  = N'system',
    -- 467. NULL = caller predates 467: keep the stored value.
    @auto_create_users      BIT            = NULL,
    @default_role_id        BIGINT         = NULL,
    @require_admin_approval BIT            = NULL
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

    -- 467: an omitted setting keeps what is stored (or the column default).
    IF @auto_create_users IS NULL
        SELECT @auto_create_users = auto_create_users, @default_role_id = default_role_id,
               @require_admin_approval = require_admin_approval
        FROM grac_practice.organization_sso_setting WHERE organization_id = @organization_id;
    SET @auto_create_users      = ISNULL(@auto_create_users, 0);
    SET @require_admin_approval = ISNULL(@require_admin_approval, 1);
    IF @default_role_id <= 0 SET @default_role_id = NULL;

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

    -- ---- 467 validation ----
    IF @auto_create_users = 1
    BEGIN
        IF @sso_enabled = 0
            THROW 57470, 'Auto-create users needs single sign-on to be enabled.', 1;
        IF @default_role_id IS NULL
            THROW 57471, 'Select the default role for new users.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_role
                        WHERE role_id = @default_role_id AND organization_id = @organization_id AND status = N'Active')
            THROW 57471, 'The default role must be an active role of this organization.', 1;
        -- A new person must match exactly ONE organization.
        IF @allow_microsoft = 1 AND EXISTS (
                SELECT 1
                FROM grac_practice.organization_sso_setting s
                CROSS APPLY STRING_SPLIT(ISNULL(s.microsoft_tenant_ids, N''), N',') t
                WHERE s.organization_id <> @organization_id
                  AND s.sso_enabled = 1 AND s.auto_create_users = 1 AND s.allow_microsoft = 1
                  AND t.value IN (SELECT item FROM @tenant_items))
            THROW 57472, 'Another organization already auto-creates users for this Microsoft Tenant ID.', 1;
        IF EXISTS (
                SELECT 1
                FROM grac_practice.organization_sso_setting s
                CROSS APPLY STRING_SPLIT(ISNULL(s.allowed_email_domains, N''), N',') d
                WHERE s.organization_id <> @organization_id
                  AND s.sso_enabled = 1 AND s.auto_create_users = 1
                  AND d.value IN (SELECT item FROM @domain_items))
            THROW 57472, 'Another organization already auto-creates users for this email domain.', 1;
    END
    ELSE IF @default_role_id IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role
                          WHERE role_id = @default_role_id AND organization_id = @organization_id)
        THROW 57471, 'The default role must be a role of this organization.', 1;

    DECLARE @before NVARCHAR(MAX) =
        (SELECT sso_enabled, allow_microsoft, allow_google, microsoft_tenant_ids,
                allowed_email_domains, login_mode,
                auto_create_users, default_role_id, require_admin_approval
         FROM grac_practice.organization_sso_setting
         WHERE organization_id = @organization_id
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRAN;
        UPDATE grac_practice.organization_sso_setting
           SET sso_enabled            = @sso_enabled,
               allow_microsoft        = @allow_microsoft,
               allow_google           = @allow_google,
               microsoft_tenant_ids   = @tenants,
               allowed_email_domains  = @domains,
               login_mode             = @login_mode,
               auto_create_users      = @auto_create_users,
               default_role_id        = @default_role_id,
               require_admin_approval = @require_admin_approval,
               updated_by             = ISNULL(@actor, N'system'),
               updated_dt             = SYSUTCDATETIME()
         WHERE organization_id = @organization_id;

        IF @@ROWCOUNT = 0
            INSERT grac_practice.organization_sso_setting
                (organization_id, sso_enabled, allow_microsoft, allow_google,
                 microsoft_tenant_ids, allowed_email_domains, login_mode,
                 auto_create_users, default_role_id, require_admin_approval, entered_by)
            VALUES (@organization_id, @sso_enabled, @allow_microsoft, @allow_google,
                    @tenants, @domains, @login_mode,
                    @auto_create_users, @default_role_id, @require_admin_approval, ISNULL(@actor, N'system'));

        -- Audit Traceability: who changed an organization's sign-in policy.
        INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        SELECT N'organization-sso-setting', @organization_id,
               CASE WHEN @before IS NULL THEN N'CREATE' ELSE N'UPDATE' END,
               @before,
               (SELECT sso_enabled, allow_microsoft, allow_google, microsoft_tenant_ids,
                       allowed_email_domains, login_mode,
                       auto_create_users, default_role_id, require_admin_approval
                FROM grac_practice.organization_sso_setting
                WHERE organization_id = @organization_id
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
               N'Active', ISNULL(@actor, N'system');
    COMMIT;

    EXEC grac_practice.sp_org_sso_setting_get @organization_id;
END
GO

-- =====================================================================
-- 3. Create a user on first SSO sign-in
--
-- Called by the API ONLY after Microsoft / Google authenticated the
-- person and the Web tier checked the token (issuer = token tenant;
-- Google email verified). Returns one row:
--   Result  EXISTS           an employee with this email exists but is not
--                            active (Inactive / rejected) -- stays blocked
--           PENDING          already created, still waiting for approval
--           NOT_ELIGIBLE     no organization auto-creates for this
--                            provider / tenant / domain
--           AMBIGUOUS        more than one does (should not happen: the
--                            save refuses overlaps) -- nothing created
--           CREATED_PENDING  created, waiting for approval
--           CREATED_ACTIVE   created and active -- sign the person in
--   EmployeeId, OrganizationId
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sso_provision_user
    @email        NVARCHAR(250),
    @display_name NVARCHAR(200) = NULL,
    @provider     NVARCHAR(40),
    @tenant_id    NVARCHAR(64)  = NULL,
    @subject      NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @email     = LOWER(LTRIM(RTRIM(ISNULL(@email, N''))));
    SET @tenant_id = LOWER(LTRIM(RTRIM(@tenant_id)));
    IF CHARINDEX(N'@', @email) < 2
    BEGIN
        SELECT N'NOT_ELIGIBLE' AS Result, CAST(NULL AS BIGINT) AS EmployeeId, CAST(NULL AS BIGINT) AS OrganizationId;
        RETURN;
    END
    DECLARE @local  NVARCHAR(250) = LEFT(@email, CHARINDEX(N'@', @email) - 1);
    DECLARE @domain NVARCHAR(250) = SUBSTRING(@email, CHARINDEX(N'@', @email) + 1, 250);

    BEGIN TRAN;
        -- Email is unique across GRAC (sp_org_user_save 51149). Locked so
        -- two first sign-ins at the same moment cannot both create.
        DECLARE @existing_id BIGINT, @existing_status NVARCHAR(30), @existing_org BIGINT;
        SELECT TOP (1) @existing_id = employee_id, @existing_status = status, @existing_org = organization_id
        FROM grac_practice.organization_employee WITH (UPDLOCK, HOLDLOCK)
        WHERE LOWER(LTRIM(RTRIM(email))) = @email
        ORDER BY employee_id;
        IF @existing_id IS NOT NULL
        BEGIN
            COMMIT;
            SELECT CASE WHEN @existing_status = N'Pending Approval' THEN N'PENDING' ELSE N'EXISTS' END AS Result,
                   @existing_id AS EmployeeId, @existing_org AS OrganizationId;
            RETURN;
        END

        -- The organization whose SSO policy accepts this person.
        DECLARE @candidates TABLE (organization_id BIGINT PRIMARY KEY, default_role_id BIGINT, require_admin_approval BIT);
        INSERT @candidates (organization_id, default_role_id, require_admin_approval)
        SELECT s.organization_id, s.default_role_id, s.require_admin_approval
        FROM grac_practice.organization_sso_setting s
        JOIN grac_practice.organization_role r
          ON r.role_id = s.default_role_id AND r.organization_id = s.organization_id AND r.status = N'Active'
        WHERE s.sso_enabled = 1
          AND s.auto_create_users = 1
          AND (
                (@provider = N'Microsoft' AND s.allow_microsoft = 1 AND @tenant_id IS NOT NULL
                 AND EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(s.microsoft_tenant_ids, N''), N',') t WHERE t.value = @tenant_id))
             OR (@provider = N'Google' AND s.allow_google = 1)
              )
          AND (
                (@provider = N'Microsoft' AND ISNULL(s.allowed_email_domains, N'') = N'')
             OR EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(s.allowed_email_domains, N''), N',') d WHERE d.value = @domain)
              );

        DECLARE @count INT = (SELECT COUNT(*) FROM @candidates);
        IF @count <> 1
        BEGIN
            COMMIT;
            SELECT CASE WHEN @count = 0 THEN N'NOT_ELIGIBLE' ELSE N'AMBIGUOUS' END AS Result,
                   CAST(NULL AS BIGINT) AS EmployeeId, CAST(NULL AS BIGINT) AS OrganizationId;
            RETURN;
        END

        DECLARE @org BIGINT, @role BIGINT, @approval BIT;
        SELECT @org = organization_id, @role = default_role_id, @approval = require_admin_approval FROM @candidates;

        -- Employee code from the email's local part, unique in the organization.
        DECLARE @base NVARCHAR(70) = LEFT(NULLIF(@local, N''), 70);
        SET @base = ISNULL(@base, N'user');
        DECLARE @code NVARCHAR(80) = @base, @n INT = 1;
        WHILE EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE organization_id = @org AND employee_code = @code)
        BEGIN
            SET @n += 1;
            SET @code = @base + N'-' + CAST(@n AS NVARCHAR(10));
        END

        DECLARE @name NVARCHAR(200) = LEFT(COALESCE(NULLIF(LTRIM(RTRIM(@display_name)), N''), @local), 200);
        DECLARE @status NVARCHAR(30) = CASE WHEN @approval = 1 THEN N'Pending Approval' ELSE N'Active' END;
        DECLARE @record_status_id INT =
            (SELECT record_status_id FROM grac_practice.record_status_master
              WHERE status_code = CASE WHEN @approval = 1 THEN N'Inactive' ELSE N'Active' END);
        DECLARE @active_record_status_id INT =
            (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
        DECLARE @actor NVARCHAR(100) = LEFT(N'sso:' + @email, 100);

        INSERT grac_practice.organization_employee
            (organization_id, employee_code, employee_name, email, password_hash, role_id,
             party_type, force_password_change, is_functional_user,
             status, record_status_id, entered_by)
        VALUES (@org, @code, @name, @email, NULL, @role,
                N'Employee', 0, 0,
                @status, @record_status_id, @actor);
        DECLARE @employee_id BIGINT = SCOPE_IDENTITY();

        -- Same side effect as sp_org_user_save.
        INSERT grac_practice.user_organization_map
            (user_email, organization_id, access_role, is_default, status, record_status_id, entered_by)
        SELECT @email, @org, 'Organization User', 0, 'Active', @active_record_status_id, @actor
        WHERE NOT EXISTS (SELECT 1 FROM grac_practice.user_organization_map
                           WHERE user_email = @email AND organization_id = @org);

        INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, after_json, status, entered_by)
        VALUES (N'sso-provision', @employee_id, N'CREATE',
                (SELECT @org AS organizationId, @email AS email, @name AS name, @code AS employeeCode,
                        @role AS roleId, @status AS status, @provider AS provider,
                        @tenant_id AS tenantId, @subject AS subject
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                N'Active', @actor);
    COMMIT;

    SELECT CASE WHEN @approval = 1 THEN N'CREATED_PENDING' ELSE N'CREATED_ACTIVE' END AS Result,
           @employee_id AS EmployeeId, @org AS OrganizationId;
END
GO

-- =====================================================================
-- 4. Approve a user waiting for approval (Users tab row action)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sso_user_approve
    @organization_id BIGINT,
    @employee_id     BIGINT,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                    WHERE employee_id = @employee_id AND organization_id = @organization_id
                      AND status = N'Pending Approval')
        THROW 57473, 'This user is not waiting for approval.', 1;

    DECLARE @active_record_status_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    BEGIN TRAN;
        UPDATE grac_practice.organization_employee
           SET status = N'Active', record_status_id = @active_record_status_id,
               updated_by = ISNULL(@actor, N'system'), updated_dt = SYSUTCDATETIME()
         WHERE employee_id = @employee_id AND organization_id = @organization_id;

        INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        VALUES (N'sso-provision', @employee_id, N'APPROVE',
                N'{"status":"Pending Approval"}', N'{"status":"Active"}',
                N'Active', ISNULL(@actor, N'system'));
    COMMIT;

    SELECT @employee_id AS EmployeeId, N'Active' AS Status;
END
GO

-- =====================================================================
-- 5. sp_org_user_list -- 341 body; Status and CredentialStatus display
--    the two 467 states. Nothing else changed.
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
           CASE WHEN e.password_hash IS NULL THEN N'Single sign-on'      -- 467: created by SSO, no password
                WHEN ISNULL(e.force_password_change,0) = 1
                THEN N'Default password'
                ELSE N'Password set' END CredentialStatus,
           -- 341: the Functional User flag, for the grid and the edit form.
           CAST(ISNULL(e.is_functional_user,0) AS BIT) IsFunctionalUser,
           -- 467: a user created by SSO and waiting for approval.
           CASE WHEN e.status = N'Pending Approval' THEN N'Pending Approval'
                ELSE rs.status_name END Status
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

SELECT '467 SSO auto-provisioning' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.organization_sso_setting','auto_create_users') IS NOT NULL
             AND COL_LENGTH('grac_practice.organization_sso_setting','default_role_id') IS NOT NULL
             AND COL_LENGTH('grac_practice.organization_sso_setting','require_admin_approval') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_sso_provision_user','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_sso_user_approve','P') IS NOT NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_user_list','P')) LIKE N'%Pending Approval%'
            THEN 'OK' ELSE 'MISSING' END AS Result;
GO
SET NOEXEC OFF;
GO
