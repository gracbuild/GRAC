-- =====================================================================
-- 273 MSP organization -- Managed Service Provider tenant
--
-- WHAT THIS CREATES
--   organization_code        MSP
--   organization_name        Managed Service Provider
--   industry / entity_type   IT Services / Other
--   country                  India
--
--   plus, for that organisation:
--     organization_metadata_value  the Organization Setup attribute set
--     organization_business_function  IT, Operations, Compliance, Risk
--     organization_division / department / location  a starter structure
--     organization_role            Admin (from the provisioning proc) and
--                                  the four standard non-admin roles
--     organization_employee        the Organisation GRAC Admin sign-in
--     organization_employee_role   admin -> Admin role
--     organization_role_menu_permission  full rights on every active menu
--     feature_flag                 every active 'screen.%' flag ON
--     user_organization_map        home-organisation row for the admin
--     risk_likelihood / impact / matrix / category  default 5x5 framework
--
-- NOTHING IS HAND-ROLLED THAT A PROC ALREADY DOES
--   Section 2 saves the organisation through
--     dbo.pm_manage_practice_repository @p_entity_type='organization-setup'
--   which is the exact path the Organization Setup screen uses, so the
--   metadata attribute typing (Lookup / Boolean / Json), the release
--   subscription handling and the record_status wiring are the product's,
--   not this script's.
--
--   Section 4 calls grac_practice.pm_create_organization_admin (034,
--   re-issued by 217), which creates the ORGANIZATION-scoped Admin role,
--   the admin employee with force_password_change = 1, the multi-role
--   map row, and then calls pm_grant_organization_default_access to grant
--   every active menu and turn on every active screen feature flag.
--
--   Section 6 calls grac_practice.sp_risk_scoring_seed_default (204) for
--   the per-organisation risk framework, because risk_likelihood_master,
--   risk_impact_master, risk_category_master and risk_matrix_cell are
--   org-scoped and therefore deliberately NOT in 272.
--
-- THE ADMIN PASSWORD
--   password_hash below is PBKDF2-HMAC-SHA256, 210000 iterations, 16-byte
--   salt, 32-byte key, in the "iterations.saltBase64.hashBase64" form that
--   PracticeManagement.Web/Security/PasswordHasher.cs writes and verifies.
--   Plaintext is Grac@123 -- the same UserProvisioning:DefaultPassword the
--   Web tier provisions with. pm_create_organization_admin sets
--   force_password_change = 1, so the first sign-in must change it, and
--   LoginController rejects the default as the new password.
--   Change @AdminPasswordHash below if this deployment uses a different
--   default; do NOT put a plaintext password in this file.
--
-- MENUS
--   pm_grant_organization_default_access grants whatever menu_master holds
--   when this script runs. 272 deliberately does not seed menu_master (its
--   final state belongs to the menu migration chain), so run the menu
--   migrations BEFORE this script or MSP's Admin gets an incomplete menu.
--   Re-running 273, or 217's backfill, tops the grants up later.
--
-- Re-runnable: yes. A second run updates the organisation in place and
-- inserts nothing else. It does NOT reset the admin password to the
-- default -- pm_create_organization_admin does that by design when it is
-- called for an existing account, which is why section 4 is skipped when
-- the admin employee already exists.
--
-- ASCII-only on purpose (sqlcmd codepage safety).
-- DEPENDS ON: 272 (masters), 002/deployment-02 (pm_manage_practice_repository),
--             034 + 217 (pm_create_organization_admin), 204 (risk seed),
--             and the menu migration chain for menu_master.
-- Rollback: database/273_msp_organization_setup_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- ---------------------------------------------------------------------
-- Prerequisite guard
-- ---------------------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (273): schema grac_practice is missing. Run base scripts first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('dbo.pm_manage_practice_repository','P') IS NULL
BEGIN
    PRINT 'ABORT (273): dbo.pm_manage_practice_repository missing. Run 002_practice_management_procedures.sql (or deployment/02) first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.pm_create_organization_admin','P') IS NULL
BEGIN
    PRINT 'ABORT (273): grac_practice.pm_create_organization_admin missing. Run 034_simplified_role_model.sql then 217_organization_default_access.sql.';
    SET @prereqs_ok = 0;
END

IF NOT EXISTS(SELECT 1 FROM grac_practice.record_status_master WHERE status_code = N'Active')
BEGIN
    PRINT 'ABORT (273): record_status_master has no Active row. Run 272_master_data_seed.sql first.';
    SET @prereqs_ok = 0;
END

IF NOT EXISTS(SELECT 1 FROM grac_practice.location_type_master WHERE location_type_code = N'HO')
BEGIN
    PRINT 'ABORT (273): location_type_master is not seeded. Run 272_master_data_seed.sql first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('273_msp_organization_setup: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

PRINT '273: provisioning the MSP organisation.';
GO

-- =====================================================================
-- 1 + 2. Organisation row and attributes, through the product's own
--        organization-setup save path.
--
--        $._security.isSystemAdmin is how the proc is told the caller may
--        create an organisation (it reads the flag off the payload, the
--        same way the Web gateway sets it for a PM_ADMIN session).
--        $.organization.id = 0 inserts; a real id updates in place, which
--        is what makes a re-run harmless.
-- =====================================================================
DECLARE @OrgCode    NVARCHAR(80)  = N'MSP';
DECLARE @OrgName    NVARCHAR(250) = N'Managed Service Provider';
DECLARE @Industry   NVARCHAR(120) = N'IT Services';
DECLARE @EntityType NVARCHAR(120) = N'Other';
DECLARE @Country    NVARCHAR(120) = N'India';

DECLARE @existing_org_id BIGINT =
    (SELECT organization_id FROM grac_practice.organization WHERE organization_code = @OrgCode);

DECLARE @payload NVARCHAR(MAX) = N'{
  "_security": { "isSystemAdmin": true },
  "organization": {
    "id": ' + CAST(ISNULL(@existing_org_id, 0) AS NVARCHAR(20)) + N',
    "code": "' + @OrgCode + N'",
    "name": "' + @OrgName + N'",
    "industry": "' + @Industry + N'",
    "entityType": "' + @EntityType + N'",
    "country": "' + @Country + N'",
    "status": "Active"
  },
  "attributes": {
    "entity_type": "Other",
    "deposit_taking_status": "Not Applicable",
    "asset_size_scale": "Medium",
    "regulatory_registration_type": "Other",
    "payment_aggregator_status": "No",
    "investment_advisor_status": "No",
    "cloud_adoption": "High",
    "stores_cardholder_data": false,
    "geographic_presence": ["India"],
    "business_functions": ["Information Technology", "Operations", "Compliance", "Risk Management"],
    "technology_landscape": ["Cloud Services", "Identity Platform", "Endpoint Management"]
  },
  "releaseIds": []
}';

EXEC dbo.pm_manage_practice_repository
     @p_entity_type = N'organization-setup',
     @p_action      = N'SAVE',
     @p_id          = 0,
     @p_payload     = @payload,
     @p_usr_id      = N'seed-273';
GO

-- =====================================================================
-- 3. Organisation structure -- business functions, division, departments,
--    locations, and the four standard non-admin roles.
--
--    The Admin role is NOT created here: pm_create_organization_admin
--    owns it (role_code ORG_ADMIN, data_scope ORGANIZATION) and forces
--    the scope back every time it runs. Creating a second 'Admin' here
--    would collide with uq_pm_org_role_name.
-- =====================================================================
DECLARE @org_id BIGINT =
    (SELECT organization_id FROM grac_practice.organization WHERE organization_code = N'MSP');
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
    WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);

IF @org_id IS NULL
    RAISERROR('273: organisation MSP was not created -- check the pm_manage_practice_repository output above.', 16, 1);
ELSE
BEGIN
    -- 3a. Business functions
    INSERT grac_practice.organization_business_function
        (organization_id, function_code, function_name, owner_name, criticality, status, entered_by)
    SELECT @org_id, s.function_code, s.function_name, s.owner_name, s.criticality, N'Active', N'seed-273'
    FROM (VALUES
        (N'IT',   N'Information Technology', N'IT Head',              N'Critical'),
        (N'OPS',  N'Service Operations',     N'Service Delivery Head',N'Critical'),
        (N'COMP', N'Compliance',             N'Compliance Head',      N'High'),
        (N'RISK', N'Risk Management',        N'Risk Head',            N'High')
    ) s(function_code, function_name, owner_name, criticality)
    WHERE NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_business_function b
        WHERE b.organization_id = @org_id AND b.function_code = s.function_code);

    -- 3b. Division
    INSERT grac_practice.organization_division
        (organization_id, division_code, division_name, description, status, record_status_id, entered_by)
    SELECT @org_id, s.division_code, s.division_name, s.description, N'Active', @active_rs, N'seed-273'
    FROM (VALUES
        (N'MSP-SVC', N'Managed Services', N'Delivery of managed services to client organisations.')
    ) s(division_code, division_name, description)
    WHERE NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_division d
        WHERE d.organization_id = @org_id AND d.division_code = s.division_code);

    -- 3c. Departments
    INSERT grac_practice.organization_department
        (organization_id, department_code, department_name, description, status, record_status_id, entered_by)
    SELECT @org_id, s.department_code, s.department_name, s.description, N'Active', @active_rs, N'seed-273'
    FROM (VALUES
        (N'IT',      N'Information Technology', N'Infrastructure, applications and end-user support.'),
        (N'INFOSEC', N'Information Security',   N'Security operations, monitoring and incident response.'),
        (N'SVCDEL',  N'Service Delivery',       N'Client-facing managed service delivery.'),
        (N'COMP',    N'Compliance',             N'Regulatory and contractual compliance.'),
        (N'HR',      N'Human Resources',        N'People, onboarding and offboarding.')
    ) s(department_code, department_name, description)
    WHERE NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_department d
        WHERE d.organization_id = @org_id AND d.department_code = s.department_code);

    -- 3d. Locations
    INSERT grac_practice.organization_location
        (organization_id, location_name, location_type_id, region, remarks, status, record_status_id, entered_by)
    SELECT @org_id, s.location_name, lt.location_type_id, s.region, s.remarks, N'Active', @active_rs, N'seed-273'
    FROM (VALUES
        (N'MSP Head Office',                N'HO',     N'India', N'Registered office.'),
        (N'MSP Network Operations Centre',  N'DC',     N'India', N'24x7 NOC / SOC floor.'),
        (N'MSP Disaster Recovery Site',     N'DR',     N'India', N'Secondary site for continuity testing.')
    ) s(location_name, type_code, region, remarks)
    JOIN grac_practice.location_type_master lt ON lt.location_type_code = s.type_code
    WHERE NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_location l
        WHERE l.organization_id = @org_id AND l.location_name = s.location_name);

    -- 3e. Non-admin roles (same set deployment/03 seeds for every org).
    INSERT grac_practice.organization_role
        (organization_id, role_name, role_code, description, status, record_status_id, entered_by)
    SELECT @org_id, s.role_name, s.role_code, s.description, N'Active', @active_rs, N'seed-273'
    FROM (VALUES
        (N'Compliance Owner', N'COMPLIANCE_OWNER', N'Compliance owner responsible for controls, requirements, practices, and evidence.'),
        (N'Evidence Owner',   N'EVIDENCE_OWNER',   N'Evidence owner responsible for evidence collection and updates.'),
        (N'Reviewer',         N'REVIEWER',         N'Reviewer with read and review-oriented access.'),
        (N'Viewer',           N'VIEWER',           N'Read-only user.')
    ) s(role_name, role_code, description)
    WHERE NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role r
        WHERE r.organization_id = @org_id AND LOWER(r.role_name) = LOWER(s.role_name));

    -- 3f. Viewer gets read-only rights on every active menu, mirroring the
    --     Viewer grant in deployment/03. Insert-only.
    INSERT grac_practice.organization_role_menu_permission
        (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
         status, record_status_id, entered_by)
    SELECT r.role_id, m.menu_id, 1, 0, 0, 0, 0, N'Active', @active_rs, N'seed-273'
    FROM grac_practice.organization_role r
    CROSS JOIN grac_practice.menu_master m
    WHERE r.organization_id = @org_id
      AND r.role_name = N'Viewer'
      AND r.status = N'Active'
      AND m.status = N'Active'
      AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission p
        WHERE p.role_id = r.role_id AND p.menu_id = m.menu_id);
END
GO

PRINT '273: organisation structure done.';
GO

-- =====================================================================
-- 4. Organisation GRAC Admin.
--
--    Skipped entirely when the account already exists, because
--    pm_create_organization_admin resets password_hash and
--    force_password_change on an existing account by design (that is its
--    "resend credentials" behaviour) and a re-run of this migration must
--    not silently push MSP's admin back to the default password.
--    To deliberately reset it, run the EXEC below by hand.
-- =====================================================================
DECLARE @org_id BIGINT =
    (SELECT organization_id FROM grac_practice.organization WHERE organization_code = N'MSP');
DECLARE @AdminEmail NVARCHAR(250) = N'msp.admin@grac.in';
DECLARE @AdminName  NVARCHAR(200) = N'MSP GRAC Admin';

-- PBKDF2-HMAC-SHA256, 210000 iterations, per-account salt. Plaintext: Grac@123
DECLARE @AdminPasswordHash NVARCHAR(500) =
    N'210000.EGNCLbnpn7n6ODBOnLizTg==.vVyGi/3SdVTgRNufbwfUwvrjdvnFSga7jdnnmfG4wzI=';

IF @org_id IS NULL
    RAISERROR('273: organisation MSP not found; admin provisioning skipped.', 16, 1);
ELSE IF EXISTS (
    SELECT 1 FROM grac_practice.organization_employee
    WHERE organization_id = @org_id AND LOWER(email) = LOWER(@AdminEmail))
    PRINT '273: MSP admin already exists -- provisioning skipped so the password is not reset.';
ELSE
    EXEC grac_practice.pm_create_organization_admin
         @organization_id = @org_id,
         @admin_email     = @AdminEmail,
         @admin_name      = @AdminName,
         @password_hash   = @AdminPasswordHash,
         @entered_by      = N'seed-273';
GO

-- =====================================================================
-- 5. Home-organisation map row.
--
--    PracticeManagementGatewayController builds its allowed-organisation
--    list from user_organization_map (plus the employee's primary org) and
--    does not consult data_scope, so the map row is what keeps the admin
--    working on every gateway call. pm_create_organization_admin does not
--    write one -- sp_org_user_save does -- so it is added here.
-- =====================================================================
DECLARE @org_id BIGINT =
    (SELECT organization_id FROM grac_practice.organization WHERE organization_code = N'MSP');
DECLARE @AdminEmail NVARCHAR(250) = N'msp.admin@grac.in';
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
    WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);

IF @org_id IS NOT NULL
   AND NOT EXISTS (
        SELECT 1 FROM grac_practice.user_organization_map
        WHERE user_email = @AdminEmail AND organization_id = @org_id)
    INSERT grac_practice.user_organization_map
        (user_email, organization_id, access_role, is_default, status, record_status_id, entered_by)
    VALUES(@AdminEmail, @org_id, N'Admin', 1, N'Active', @active_rs, N'seed-273');
GO

PRINT '273: admin and organisation access done.';
GO

-- =====================================================================
-- 6. Per-organisation risk scoring framework (5 likelihood levels,
--    5 impact levels, 25 matrix cells, default categories).
--    Idempotent and non-destructive inside the proc itself.
-- =====================================================================
IF OBJECT_ID('grac_practice.sp_risk_scoring_seed_default','P') IS NULL
    PRINT '273: sp_risk_scoring_seed_default absent (run 204) -- risk framework skipped.';
ELSE
BEGIN
    DECLARE @risk_org_id BIGINT =
        (SELECT organization_id FROM grac_practice.organization WHERE organization_code = N'MSP');
    IF @risk_org_id IS NOT NULL
        EXEC grac_practice.sp_risk_scoring_seed_default
             @organization_id     = @risk_org_id,
             @caller_display_name = N'seed-273';
END
GO

PRINT '273: risk framework done.';
GO

-- =====================================================================
-- VERIFICATION
-- =====================================================================
PRINT '=== 273 verification ===';

DECLARE @org_id BIGINT =
    (SELECT organization_id FROM grac_practice.organization WHERE organization_code = N'MSP');

SELECT 'Organisation row' AS Check_,
       CASE WHEN @org_id IS NULL THEN 'FAIL' ELSE 'PASS' END AS Result_,
       @org_id AS OrganizationId;

SELECT o.organization_id, o.organization_code, o.organization_name,
       o.industry, o.entity_type, o.country, o.status
FROM grac_practice.organization o
WHERE o.organization_code = N'MSP';

SELECT 'Metadata attribute values' AS Check_, COUNT(*) AS Count_,
       CASE WHEN COUNT(*) >= 11 THEN 'PASS' ELSE 'REVIEW' END AS Result_
FROM grac_practice.organization_metadata_value WHERE organization_id = @org_id;

SELECT 'Business functions' AS Check_, COUNT(*) AS Count_,
       CASE WHEN COUNT(*) >= 4 THEN 'PASS' ELSE 'REVIEW' END AS Result_
FROM grac_practice.organization_business_function WHERE organization_id = @org_id;

SELECT 'Divisions' AS Check_, COUNT(*) AS Count_,
       CASE WHEN COUNT(*) >= 1 THEN 'PASS' ELSE 'REVIEW' END AS Result_
FROM grac_practice.organization_division WHERE organization_id = @org_id;

SELECT 'Departments' AS Check_, COUNT(*) AS Count_,
       CASE WHEN COUNT(*) >= 5 THEN 'PASS' ELSE 'REVIEW' END AS Result_
FROM grac_practice.organization_department WHERE organization_id = @org_id;

SELECT 'Locations' AS Check_, COUNT(*) AS Count_,
       CASE WHEN COUNT(*) >= 3 THEN 'PASS' ELSE 'REVIEW' END AS Result_
FROM grac_practice.organization_location WHERE organization_id = @org_id;

SELECT 'Roles (Admin + 4)' AS Check_, COUNT(*) AS Count_,
       CASE WHEN COUNT(*) >= 5 THEN 'PASS' ELSE 'REVIEW' END AS Result_
FROM grac_practice.organization_role WHERE organization_id = @org_id;

SELECT 'Admin employee with a password hash' AS Check_,
       COUNT(*) AS Count_,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS Result_
FROM grac_practice.organization_employee e
WHERE e.organization_id = @org_id
  AND LOWER(e.email) = N'msp.admin@grac.in'
  AND LEN(LTRIM(RTRIM(ISNULL(e.password_hash, N'')))) > 0;

SELECT 'Admin menu grants' AS Check_, COUNT(*) AS Count_,
       CASE WHEN COUNT(*) > 0 THEN 'PASS' ELSE 'FAIL -- run the menu migrations then re-run 273' END AS Result_
FROM grac_practice.organization_role_menu_permission p
JOIN grac_practice.organization_role r ON r.role_id = p.role_id
WHERE r.organization_id = @org_id
  AND (r.role_name = N'Admin' OR r.role_code = N'ORG_ADMIN');

SELECT 'Screen feature flags enabled' AS Check_, COUNT(*) AS Count_,
       CASE WHEN COUNT(*) > 0 THEN 'PASS' ELSE 'REVIEW' END AS Result_
FROM grac_practice.feature_flag ff
JOIN grac_practice.feature_flag_master fm ON fm.feature_flag_id = ff.feature_flag_id
WHERE ff.organization_id = @org_id AND ff.is_enabled = 1 AND fm.feature_code LIKE N'screen.%';

SELECT 'user_organization_map row' AS Check_, COUNT(*) AS Count_,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'REVIEW' END AS Result_
FROM grac_practice.user_organization_map
WHERE organization_id = @org_id AND user_email = N'msp.admin@grac.in';

IF OBJECT_ID('grac_practice.risk_matrix_cell','U') IS NOT NULL
    SELECT 'Risk matrix cells (5x5)' AS Check_, COUNT(*) AS Count_,
           CASE WHEN COUNT(*) >= 25 THEN 'PASS' ELSE 'REVIEW' END AS Result_
    FROM grac_practice.risk_matrix_cell WHERE organization_id = @org_id;

PRINT '273 MSP organisation setup complete.';
PRINT 'Sign in as msp.admin@grac.in with the default password; the first sign-in forces a change.';
GO

SET NOEXEC OFF;
GO
