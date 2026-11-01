-- =====================================================================
-- 466 Organization-wise Single Sign-On settings
--
-- WHY
-- ---
-- Single sign-on (2026-10-12, docs/single-sign-on.md) first shipped with
-- ONE Microsoft tenant in appsettings, so every organization shared one
-- identity setup. GRAC hosts many client organizations, each with its
-- own Microsoft Entra tenant / Google Workspace domain, and each must
-- decide for itself whether its people may (or must) use SSO.
--
-- WHAT
-- ----
-- The app credentials stay in configuration (Sso:Microsoft:ClientId /
-- ClientSecret, Sso:Google:ClientId / ClientSecret -- secrets never go
-- in the database). The Microsoft app becomes multi-tenant; WHICH tenant
-- and WHICH email domains may sign in to WHICH organization is the
-- per-organization policy stored here, edited from Organization Administration ->
-- Organization tab -> "Single Sign-On".
--
--   organization_sso_setting (one row per organization; no row = SSO off)
--     sso_enabled            1 = this organization's people may use SSO
--     allow_microsoft        Microsoft (Entra ID) button accepted
--     allow_google           Google button accepted
--     microsoft_tenant_ids   allowed Entra tenant ids (GUIDs, comma list).
--                            The token's tid must be one of them.
--     allowed_email_domains  allowed email domains (comma list). Required
--                            when Google is allowed (Google has no tenant);
--                            optional extra check for Microsoft.
--     login_mode             SSO_AND_PASSWORD | SSO_ONLY. SSO_ONLY blocks
--                            the password form for this organization.
--
-- ENFORCED AT SIGN-IN by the API (PracticeAuthenticationService), against
-- the organization of the employee the email matched:
--   SSO      : enabled, provider allowed, tid in the tenant list
--              (Microsoft), email domain in the domain list (when set).
--   Password : refused when sso_enabled = 1 AND login_mode = SSO_ONLY.
-- The configuration-verified ReviewLogin admin is not an employee row and
-- is never affected, so a mis-configured organization can always be
-- corrected by the GRAC platform admin.
--
-- CONTENTS
--   1. grac_practice.organization_sso_setting
--   2. sp_org_sso_setting_get  (defaults when the organization has no row)
--   3. sp_org_sso_setting_save (validates, normalizes the lists, audits to
--      practice_audit_trace entity 'organization-sso-setting')
--
-- Re-runnable. ASCII-only. Error codes 57466-57469.
-- Rollback: 466_organization_sso_settings_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_audit_trace','U') IS NULL
BEGIN
    RAISERROR('466: prerequisites missing (001).', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. The setting
-- =====================================================================
IF OBJECT_ID('grac_practice.organization_sso_setting','U') IS NULL
CREATE TABLE grac_practice.organization_sso_setting(
    organization_id        BIGINT         NOT NULL
        CONSTRAINT pk_pm_org_sso_setting PRIMARY KEY
        CONSTRAINT fk_pm_org_sso_setting_org REFERENCES grac_practice.organization(organization_id),
    sso_enabled            BIT            NOT NULL CONSTRAINT df_pm_org_sso_enabled   DEFAULT 0,
    allow_microsoft        BIT            NOT NULL CONSTRAINT df_pm_org_sso_microsoft DEFAULT 0,
    allow_google           BIT            NOT NULL CONSTRAINT df_pm_org_sso_google    DEFAULT 0,
    microsoft_tenant_ids   NVARCHAR(1000) NULL,
    allowed_email_domains  NVARCHAR(1000) NULL,
    login_mode             NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_org_sso_login_mode DEFAULT N'SSO_AND_PASSWORD',
    entered_by             NVARCHAR(100)  NOT NULL,
    entered_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_org_sso_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by             NVARCHAR(100)  NULL,
    updated_dt             DATETIME2      NULL,
    CONSTRAINT ck_pm_org_sso_login_mode CHECK (login_mode IN (N'SSO_AND_PASSWORD', N'SSO_ONLY'))
);
GO

-- =====================================================================
-- 2. Read
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
           ISNULL(s.updated_by, s.entered_by)                   AS UpdatedBy,
           ISNULL(s.updated_dt, s.entered_dt)                   AS UpdatedDt
    FROM grac_practice.organization o
    LEFT JOIN grac_practice.organization_sso_setting s ON s.organization_id = o.organization_id
    WHERE o.organization_id = @organization_id;
END
GO

-- =====================================================================
-- 3. Write
-- =====================================================================
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

SELECT '466 organization SSO settings' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.organization_sso_setting','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_sso_setting_get','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_sso_setting_save','P') IS NOT NULL
            THEN 'OK' ELSE 'MISSING' END AS Result;
GO
SET NOEXEC OFF;
GO
