-- =====================================================================
-- 220 GRAC Admin users -- Anoop P S, Saji P, Aparna M P
--
-- WHAT THIS PROVISIONS
--   Three sign-in accounts in organisation 4 that carry the same reach
--   as the admin@grac.local bootstrap login: every menu, every action,
--   every organisation.
--
--     anoop.ps@soffit.in    Anoop P S     employee_code ANOOP.PS
--     saji.p@soffit.in      Saji P        employee_code SAJI.P
--     aparna.mp@soffit.in   Aparna M P    employee_code APARNA.MP
--
-- WHAT admin@grac.local ACTUALLY IS
--   It is NOT a database account. It is the Web tier's ReviewLogin
--   (Web/appsettings.Development.json), which LoginController handles in
--   its own branch: session roles come from Security:RolePermissions
--   ["PM_ADMIN"] = "*:*", and DataScopeKey is hard-set to "GLOBAL".
--   Nothing in grac_practice backs it. A database user therefore cannot
--   BE that account -- it has to be given the equivalent, which is what
--   the three grants below do.
--
-- TWO GATES HAVE TO BE SATISFIED FOR "EVERY ORGANISATION"
--   They are checked by different code and neither implies the other:
--
--   1. data_scope = 'GLOBAL' on the role.
--      PracticeAuthenticationService.LoadEffectiveDataScopeAsync reads
--      it, LoginController stores it as DataScopeKey, and
--      OrganizationAccessContext.IsGlobalScope / IsOrganizationAllowed
--      short-circuit to "any org" on it. This is what makes the
--      organisation dropdown list every active organisation.
--
--   2. A grac_practice.user_organization_map row per organisation.
--      PracticeManagementGatewayController does NOT go through
--      IsGlobalScope. Lines 40 and 530 test
--      AllowedOrganizationIds().Contains(...) directly, and that list is
--      built by LoadAllowedOrganizationsAsync purely from
--      user_organization_map (plus the primary org). IsSystemAdmin()
--      there matches the literal role token "PM_ADMIN", which a database
--      session never carries -- its role tokens are menu permissions
--      such as "practices:VIEW". So without the map rows every
--      cross-organisation gateway call answers 403 no matter what
--      data_scope says.
--
--   Section 1 covers (1). Section 5 covers (2).
--
-- WHY A NEW ROLE AND NOT ORG 4's EXISTING 'Admin'
--   Two reasons, both structural:
--     a) pm_create_organization_admin (034, re-issued by 217) hunts for
--        role_name = 'Admin' and FORCES data_scope back to
--        'ORGANIZATION' every time it runs. A GLOBAL scope parked on
--        that role would be silently reverted the next time an
--        organisation admin is provisioned or credentials are resent.
--     b) Org 4's 'Admin' role is already held by the Organisation GRAC
--        Admin. Widening it to GLOBAL would hand that existing account
--        every other organisation's data as a side effect.
--   So these three get their own role, 'GRAC Admin' / role_code
--   'GRAC_ADMIN', which nothing else reads or rewrites.
--
--   TRADE-OFF, RECORDED DELIBERATELY: pm_grant_organization_default_access
--   tops up roles matching role_name 'Admin' OR role_code 'ORG_ADMIN'.
--   'GRAC_ADMIN' is outside that filter, so a menu_master row added by a
--   FUTURE module will not reach this role on its own. Re-run section 2
--   of this script (it is idempotent) after any migration that seeds new
--   menus. role_code 'ORG_ADMIN' could not be reused instead: index
--   ux_pm_org_role_code is UNIQUE(organization_id, role_code) and org 4
--   already carries it.
--
-- PASSWORDS
--   T-SQL cannot produce a value PasswordHasher.Verify accepts, so the
--   hashes below were generated offline with the exact parameters in
--   Web/Security/PasswordHasher.cs -- PBKDF2-HMAC-SHA256, 210000
--   iterations, 16-byte salt, 32-byte key, formatted
--   "<iterations>.<base64 salt>.<base64 hash>". Each account has its own
--   salt. They all encode the standard first-issue password:
--
--       Grac@123          (UserProvisioning:DefaultPassword)
--
--   force_password_change is set to 1, so LoginController.Index refuses
--   to open a session and redirects to ChangePassword on first sign-in.
--   The value above is a handover credential, not a stored secret; it
--   stops working the moment each user completes that screen.
--
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
--
-- Idempotent: every write is guarded on its natural key, and an account
-- that already exists is reported and left alone rather than rewritten.
--
-- DEPENDS ON: 002 (organization_employee, user_organization_map),
--             022 (menu_master, organization_role_menu_permission),
--             027 (role_code, organization_employee_role),
--             032/034 (data_scope, force_password_change),
--             133 + 208 (sp_org_user_save in its current shape),
--             217 (pm_grant_organization_default_access).
-- Rollback:   database/220_grac_admin_users_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

-- ---------------------------------------------------------------------
-- Prerequisite guard -- same pattern as 042 / 050 / 163 / 217.
-- ---------------------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (220): schema grac_practice missing. Run base scripts first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_employee','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.user_organization_map','U') IS NULL
BEGIN
    PRINT 'ABORT (220): core organisation tables missing. Run 002 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN
    PRINT 'ABORT (220): menu_master / organization_role_menu_permission missing. Run 022 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.organization_employee_role','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_role','role_code') IS NULL
BEGIN
    PRINT 'ABORT (220): organization_employee_role / organization_role.role_code missing. Run 027 first.';
    SET @prereqs_ok = 0;
END

IF COL_LENGTH('grac_practice.organization_role','data_scope') IS NULL
BEGIN
    PRINT 'ABORT (220): organization_role.data_scope missing. Run 032_ownership_role_model.sql first.';
    SET @prereqs_ok = 0;
END

IF COL_LENGTH('grac_practice.organization_employee','force_password_change') IS NULL
BEGIN
    PRINT 'ABORT (220): organization_employee.force_password_change missing. Run 032 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.sp_org_user_save','P') IS NULL
   OR OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_user_save','P')) NOT LIKE '%force_password_change%'
BEGIN
    PRINT 'ABORT (220): sp_org_user_save missing or predates 208. Run 133 then 208 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.pm_grant_organization_default_access','P') IS NULL
BEGIN
    PRINT 'ABORT (220): pm_grant_organization_default_access missing. Run 217 first.';
    SET @prereqs_ok = 0;
END

IF NOT EXISTS (SELECT 1 FROM grac_practice.organization
                WHERE organization_id = 4 AND status = N'Active')
BEGIN
    PRINT 'ABORT (220): organization_id 4 does not exist or is not Active. Check the target organisation before running.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('220_grac_admin_users: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- Sections 1-6 run as ONE batch: the role id resolved in section 1 is
-- carried by a local variable through to section 4, and locals do not
-- survive a GO.
-- =====================================================================
DECLARE @org_id      BIGINT        = 4;
-- Every row this script writes is stamped with this id -- it is the only
-- thing the rollback matches on, exactly as 217 uses 'seed-217'.
DECLARE @entered_by  NVARCHAR(100) = N'seed-220';

DECLARE @active_record_status_id INT = (
    SELECT TOP 1 record_status_id
    FROM grac_practice.record_status_master
    WHERE status_code = N'ACTIVE' OR status_name = N'Active'
    ORDER BY record_status_id
);
IF @active_record_status_id IS NULL
    THROW 53420, '220: no Active row in record_status_master. Run 003/008 first.', 1;

-- ---------------------------------------------------------------------
-- 1. The GLOBAL-scoped role.
--    CREATE if absent; if it is already there, force the two columns
--    that define what it is back to the intended values -- a re-run
--    should repair drift, not skip it.
-- ---------------------------------------------------------------------
DECLARE @role_id BIGINT;

SELECT TOP 1 @role_id = role_id
FROM grac_practice.organization_role
WHERE organization_id = @org_id
  AND (role_code = N'GRAC_ADMIN' OR role_name = N'GRAC Admin')
ORDER BY role_id;

IF @role_id IS NULL
BEGIN
    INSERT grac_practice.organization_role
        (organization_id, role_name, role_code, data_scope, description,
         status, record_status_id, entered_by, entered_dt)
    VALUES
        (@org_id, N'GRAC Admin', N'GRAC_ADMIN', N'GLOBAL',
         N'Cross-organisation GRAC administrator. Full menu rights, GLOBAL data scope.',
         N'Active', @active_record_status_id, @entered_by, SYSUTCDATETIME());
    SET @role_id = SCOPE_IDENTITY();
    PRINT '220: created role GRAC Admin (GRAC_ADMIN, GLOBAL).';
END
ELSE
BEGIN
    UPDATE grac_practice.organization_role
       SET role_name  = N'GRAC Admin',
           role_code  = N'GRAC_ADMIN',
           data_scope = N'GLOBAL',
           status     = N'Active',
           updated_by = @entered_by,
           updated_dt = SYSUTCDATETIME()
     WHERE role_id = @role_id;
    PRINT '220: role GRAC Admin already present -- scope and status reasserted.';
END

-- ---------------------------------------------------------------------
-- 2. Full menu rights for that role.
--
--    Same shape as pm_grant_organization_default_access step 1a, but it
--    cannot call that proc: the proc filters on role_name 'Admin' /
--    role_code 'ORG_ADMIN' and would never see this role. Unlike the
--    proc this block also RAISES existing rows to 1 -- 217 is
--    insert-only because an operator's deliberate 0 must survive, while
--    here a 0 can only be drift: nothing else writes to this role.
--
--    Re-run this section after any migration that seeds new menus.
-- ---------------------------------------------------------------------
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT @role_id, m.menu_id, 1, 1, 1, 1, 1,
       N'Active', @active_record_status_id, @entered_by, SYSUTCDATETIME()
FROM grac_practice.menu_master m
WHERE m.status = N'Active'
  AND NOT EXISTS (
        SELECT 1
        FROM grac_practice.organization_role_menu_permission p
        WHERE p.role_id = @role_id
          AND p.menu_id = m.menu_id
  );

PRINT '220: menu permission rows inserted for GRAC Admin -- ' + CAST(@@ROWCOUNT AS NVARCHAR(10));

UPDATE p
   SET p.can_view = 1, p.can_add = 1, p.can_edit = 1,
       p.can_delete = 1, p.can_approve = 1,
       p.status = N'Active',
       p.updated_by = @entered_by,
       p.updated_dt = SYSUTCDATETIME()
FROM grac_practice.organization_role_menu_permission p
JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
WHERE p.role_id = @role_id
  AND m.status = N'Active'
  AND (p.can_view = 0 OR p.can_add = 0 OR p.can_edit = 0
       OR p.can_delete = 0 OR p.can_approve = 0 OR p.status <> N'Active');

PRINT '220: menu permission rows raised to full rights -- ' + CAST(@@ROWCOUNT AS NVARCHAR(10));

-- ---------------------------------------------------------------------
-- 3. The three accounts.
--
--    Created through grac_practice.sp_org_user_save rather than a direct
--    INSERT so they are written exactly the way the Users screen writes
--    one: same validation, same defaults, same department denormalisation,
--    same party_type handling, and the same user_organization_map side
--    effect for the home organisation.
--
--    A WHILE loop over a table variable, not a cursor -- three rows, and
--    the proc needs an OUTPUT parameter per call.
-- ---------------------------------------------------------------------
DECLARE @people TABLE (
    seq           INT IDENTITY(1,1) PRIMARY KEY,
    employee_code NVARCHAR(80),
    employee_name NVARCHAR(200),
    email         NVARCHAR(250),
    password_hash NVARCHAR(500)
);

-- PBKDF2-HMAC-SHA256, 210000 iterations, per-account salt. Plaintext: Grac@123
INSERT @people (employee_code, employee_name, email, password_hash) VALUES
    (N'ANOOP.PS',  N'Anoop P S',  N'anoop.ps@soffit.in',
     N'210000.Fr2ENKW4YoQOhmNiEsqF0w==.J6OsLmLTnpINWfwt63wkBXApoFFI9G8p9ujlfRXAq4U='),
    (N'SAJI.P',    N'Saji P',     N'saji.p@soffit.in',
     N'210000.FGyX4IhrB7tEorTg+aeG4g==.85xh3J60FkDRO4WCTMBRnHWEtmu6hKIMj8s/FAGNdFw='),
    (N'APARNA.MP', N'Aparna M P', N'aparna.mp@soffit.in',
     N'210000.g6a4t15C2tTOML4a5D2xTw==.socca8kFBFVABg3Gz6YtrmRxm+OjmcRWj3nll9B87ZY=');

DECLARE @seq INT = 1, @max_seq INT = (SELECT MAX(seq) FROM @people);
DECLARE @code NVARCHAR(80), @name NVARCHAR(200), @email NVARCHAR(250), @hash NVARCHAR(500);
DECLARE @employee_id BIGINT, @payload NVARCHAR(MAX), @out_id BIGINT;
DECLARE @existing_org_id BIGINT;

WHILE @seq <= @max_seq
BEGIN
    SELECT @code = employee_code, @name = employee_name,
           @email = email, @hash = password_hash
    FROM @people WHERE seq = @seq;

    -- Email is unique across the whole table, not per organisation
    -- (sp_org_user_save THROWs 51149 on any duplicate), so the lookup is
    -- deliberately not filtered by organisation -- and the organisation
    -- it lands in has to be read back, because a match in a DIFFERENT
    -- organisation is a conflict, not a hit.
    SET @employee_id = NULL;
    SET @existing_org_id = NULL;
    SELECT TOP 1 @employee_id = employee_id, @existing_org_id = organization_id
    FROM grac_practice.organization_employee
    WHERE LOWER(LTRIM(RTRIM(email))) = LOWER(@email)
    ORDER BY employee_id;

    IF @employee_id IS NULL
    BEGIN
        -- sp_org_user_save also THROWs 51149 on a duplicate email, so the
        -- lookup above is the idempotency guard, not a race guard.
        SET @payload =
            N'{"organizationId":' + CAST(@org_id AS NVARCHAR(20)) +
            N',"employeeCode":"' + @code + N'"' +
            N',"employeeName":"' + @name + N'"' +
            N',"email":"' + @email + N'"' +
            N',"passwordHash":"' + @hash + N'"' +
            N',"roleId":' + CAST(@role_id AS NVARCHAR(20)) +
            N',"designation":"GRAC Administrator"' +
            N',"partyType":"Employee"' +
            N',"forcePasswordChange":1' +
            N',"status":"Active"}';

        SET @out_id = NULL;
        EXEC grac_practice.sp_org_user_save
             @p_payload = @payload,
             @p_id      = 0,
             @p_usr_id  = @entered_by,
             @out_id    = @out_id OUTPUT;

        SET @employee_id = @out_id;
        SET @existing_org_id = @org_id;
        PRINT '220: created employee ' + @email + ' -- employee_id ' + CAST(@employee_id AS NVARCHAR(20));
    END
    ELSE
    BEGIN
        -- Left as found on purpose. Overwriting would reset a password
        -- the user may already have changed, and could move the row to
        -- another organisation. Sections 4 and 5 still run for them, so a
        -- pre-existing account still ends up with the role and the
        -- organisation access.
        PRINT '220: employee ' + @email + ' already exists (employee_id '
              + CAST(@employee_id AS NVARCHAR(20)) + ') -- row left unchanged.';
    END

    -- -----------------------------------------------------------------
    -- 4. Role assignment.
    --    BOTH places, deliberately. organization_employee.role_id is what
    --    the Users form writes and what migration 131 found the event
    --    resolver reading; organization_employee_role is the M:N map
    --    LoadPermissionsAsync unions over. A row in only one of them is
    --    the exact defect 131 documented.
    --
    --    Skipped when a pre-existing account lives in another
    --    organisation: sp_org_user_save enforces "the role must belong to
    --    the employee's organisation" (THROW 51151), and writing a role
    --    from organisation 4 onto an employee of organisation 7 would put
    --    a row in the table that the application's own save path would
    --    reject. That is an operator decision, not something a migration
    --    should force.
    -- -----------------------------------------------------------------
    IF @employee_id IS NOT NULL AND @existing_org_id <> @org_id
        PRINT '220: WARNING -- ' + @email + ' already exists in organization_id '
              + CAST(@existing_org_id AS NVARCHAR(20)) + ', not ' + CAST(@org_id AS NVARCHAR(20))
              + '. Role NOT assigned. Move or rename that account, then re-run.';

    IF @employee_id IS NOT NULL AND @existing_org_id = @org_id
    BEGIN
        UPDATE grac_practice.organization_employee
           SET role_id    = @role_id,
               updated_by = @entered_by,
               updated_dt = SYSUTCDATETIME()
         WHERE employee_id = @employee_id
           AND ISNULL(role_id, -1) <> @role_id;

        INSERT grac_practice.organization_employee_role
            (employee_id, role_id, status, record_status_id, entered_by, entered_dt)
        SELECT @employee_id, @role_id, N'Active', @active_record_status_id,
               @entered_by, SYSUTCDATETIME()
        WHERE NOT EXISTS (
            SELECT 1 FROM grac_practice.organization_employee_role er
            WHERE er.employee_id = @employee_id AND er.role_id = @role_id
        );

        UPDATE grac_practice.organization_employee_role
           SET status = N'Active', updated_by = @entered_by, updated_dt = SYSUTCDATETIME()
         WHERE employee_id = @employee_id AND role_id = @role_id AND status <> N'Active';
    END

    SET @seq = @seq + 1;
END

-- ---------------------------------------------------------------------
-- 5. Access to every active organisation.
--
--    LoadAllowedOrganizationsAsync matches user_organization_map on
--    LOWER(user_email) IN (email, employee_code), so one row per
--    (email, organisation) is all that is needed. The unique index
--    uq_pm_user_org_email_org(user_email, organization_id) is what the
--    NOT EXISTS guard protects.
--
--    sp_org_user_save already wrote the org 4 row for accounts it
--    created; that row is left alone and only the missing ones are added.
--
--    NOTE: this is a snapshot. An organisation created AFTER this script
--    runs is covered by data_scope GLOBAL for screen-level scope, but
--    NOT by the gateway's AllowedOrganizationIds check -- re-run this
--    section, or add the row, when a new organisation is onboarded.
-- ---------------------------------------------------------------------
INSERT grac_practice.user_organization_map
    (user_email, organization_id, access_role, is_default,
     status, record_status_id, entered_by, entered_dt)
SELECT p.email, o.organization_id, N'GRAC Admin',
       CASE WHEN o.organization_id = @org_id THEN 1 ELSE 0 END,
       N'Active', @active_record_status_id, @entered_by, SYSUTCDATETIME()
FROM @people p
CROSS JOIN grac_practice.organization o
WHERE o.status = N'Active'
  AND NOT EXISTS (
        SELECT 1 FROM grac_practice.user_organization_map m
        WHERE LOWER(m.user_email) = LOWER(p.email)
          AND m.organization_id = o.organization_id
  );

PRINT '220: organisation access rows inserted -- ' + CAST(@@ROWCOUNT AS NVARCHAR(10));

-- An existing map row that was retired would silently drop that
-- organisation from the allowed list, so reassert status on the three.
UPDATE m
   SET m.status = N'Active', m.updated_by = @entered_by, m.updated_dt = SYSUTCDATETIME()
FROM grac_practice.user_organization_map m
JOIN @people p ON LOWER(m.user_email) = LOWER(p.email)
JOIN grac_practice.organization o ON o.organization_id = m.organization_id
WHERE o.status = N'Active' AND m.status <> N'Active';

PRINT '220: organisation access rows reactivated -- ' + CAST(@@ROWCOUNT AS NVARCHAR(10));

-- ---------------------------------------------------------------------
-- 6. Screen feature flags for every organisation.
--
--    fn_pm_feature_enabled resolves per-org row > master default (0) > 0,
--    so an organisation with no feature_flag rows renders its "not
--    available" banner regardless of role. Cross-organisation access is
--    not worth much if switching organisation lands on that banner.
--
--    Reusing 217's proc rather than repeating its INSERT. @organization_id
--    = NULL is its documented "every active organisation" mode.
--
--    SIDE EFFECT, STATED: the same call also tops up each organisation's
--    OWN Admin role with any menu it is missing. That is 217's designed
--    behaviour and is insert-only, but it is a change beyond these three
--    users -- drop this section if that is not wanted, and enable the
--    screen.* flags for the organisations concerned another way.
-- ---------------------------------------------------------------------
DECLARE @menus_granted INT = 0, @flags_enabled INT = 0;

EXEC grac_practice.pm_grant_organization_default_access
     @organization_id = NULL,
     @entered_by      = @entered_by,
     @menus_granted   = @menus_granted OUTPUT,
     @flags_enabled   = @flags_enabled OUTPUT;

PRINT '220: pm_grant_organization_default_access -- menus ' + CAST(@menus_granted AS NVARCHAR(10))
      + ', flags ' + CAST(@flags_enabled AS NVARCHAR(10));
GO

-- =====================================================================
-- 7. Verification -- read these before handing the credentials over.
-- =====================================================================
PRINT '=== 220 verification ===';

-- 7a. The accounts, exactly as the sign-in query sees them. Every column
--     here is one of the predicates in PracticeAuthenticationService:
--     a row must appear, employee_status Active, record_status Active,
--     and password_hash_state 'present'.
SELECT e.employee_id,
       e.organization_id,
       e.employee_code,
       e.employee_name,
       e.email,
       e.status                  AS employee_status,
       rs.status_name            AS record_status,
       r.role_name,
       r.role_code,
       r.data_scope,
       e.force_password_change,
       CASE WHEN LEN(LTRIM(RTRIM(ISNULL(e.password_hash,N'')))) > 0
            THEN 'present' ELSE 'MISSING' END AS password_hash_state,
       LEN(e.password_hash) - LEN(REPLACE(e.password_hash, '.', '')) AS dot_count
FROM grac_practice.organization_employee e
LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id = e.record_status_id
LEFT JOIN grac_practice.organization_role r     ON r.role_id = e.role_id
WHERE LOWER(e.email) IN (N'anoop.ps@soffit.in', N'saji.p@soffit.in', N'aparna.mp@soffit.in')
ORDER BY e.email;

-- 7b. Menu coverage. Granted must equal ActiveMenus, or a screen is
--     missing from their navigation.
SELECT 'GRAC Admin menu coverage' AS Check_,
       (SELECT COUNT(*) FROM grac_practice.menu_master WHERE status = N'Active') AS ActiveMenus,
       COUNT(p.role_menu_permission_id) AS Granted,
       CASE WHEN COUNT(p.role_menu_permission_id)
                 = (SELECT COUNT(*) FROM grac_practice.menu_master WHERE status = N'Active')
            THEN 'PASS' ELSE 'REVIEW -- re-run section 2' END AS Result
FROM grac_practice.organization_role r
LEFT JOIN grac_practice.organization_role_menu_permission p
       ON p.role_id = r.role_id AND p.status = N'Active' AND p.can_view = 1
WHERE r.organization_id = 4 AND r.role_code = N'GRAC_ADMIN'
GROUP BY r.role_id;

-- 7c. Organisation coverage. Orgs must equal ActiveOrgs for all three.
SELECT m.user_email,
       COUNT(DISTINCT m.organization_id) AS Orgs,
       (SELECT COUNT(*) FROM grac_practice.organization WHERE status = N'Active') AS ActiveOrgs,
       CASE WHEN COUNT(DISTINCT m.organization_id)
                 = (SELECT COUNT(*) FROM grac_practice.organization WHERE status = N'Active')
            THEN 'PASS' ELSE 'REVIEW -- re-run section 5' END AS Result
FROM grac_practice.user_organization_map m
JOIN grac_practice.organization o
  ON o.organization_id = m.organization_id AND o.status = N'Active'
WHERE m.status = N'Active'
  AND LOWER(m.user_email) IN (N'anoop.ps@soffit.in', N'saji.p@soffit.in', N'aparna.mp@soffit.in')
GROUP BY m.user_email
ORDER BY m.user_email;

-- 7d. Role assignment present in BOTH places (see section 4).
SELECT e.email,
       CASE WHEN e.role_id = r.role_id THEN 'YES' ELSE 'NO' END  AS employee_role_id_set,
       CASE WHEN er.employee_role_id IS NOT NULL THEN 'YES' ELSE 'NO' END AS employee_role_map_row
FROM grac_practice.organization_employee e
CROSS JOIN (SELECT TOP 1 role_id FROM grac_practice.organization_role
             WHERE organization_id = 4 AND role_code = N'GRAC_ADMIN' ORDER BY role_id) r
LEFT JOIN grac_practice.organization_employee_role er
       ON er.employee_id = e.employee_id AND er.role_id = r.role_id AND er.status = N'Active'
WHERE LOWER(e.email) IN (N'anoop.ps@soffit.in', N'saji.p@soffit.in', N'aparna.mp@soffit.in')
ORDER BY e.email;

PRINT '';
PRINT '220 GRAC Admin users complete.';
PRINT 'Hand over: sign in with the email address and Grac@123 -- the';
PRINT 'change-password screen appears before any session is issued.';
PRINT 'If sign-in fails, run database/_diag_user_login.sql with the email.';
GO

SET NOEXEC OFF;
GO
