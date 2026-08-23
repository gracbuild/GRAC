-- =====================================================================
-- DIAGNOSTIC: which menu permissions does this user actually have, and
--             which screen is refusing them?
--
-- Read-only. Set @login_id to the failing email (or Employee Code) and
-- run the whole script.
--
-- WHEN TO USE THIS
-- ----------------
-- The user can sign in, but a screen answers "You do not have
-- permission to view <something>" -- or, on a build that predates the
-- Forbid() fix, "The practice service returned an invalid response",
-- which was the same denial arriving as an HTML error page.
--
-- HOW THE PERMISSION SET IS BUILT (PracticeAuthenticationService
-- .LoadPermissionsAsync)
--     organization_role_menu_permission
--       for role_id IN (organization_employee_role rows  UNION
--                       organization_employee.role_id)
--       joined to menu_master, both status = 'Active'
--   -> tokens "menu_key:VIEW", "menu_key:ADD", ...
--   -> stored in the session, checked by PermissionPolicy.IsAllowed
--
-- So a missing screen means one of: no role, the role has no row for
-- that menu, the row has can_view = 0, the row is Inactive, or the
-- menu_master row itself is Inactive. Section 3 separates them.
--
-- ASCII-only on purpose.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @login_id NVARCHAR(250) = N'REPLACE-WITH-THE-FAILING-EMAIL';

-- Optional: the menu_key the screen is asking for, e.g.
-- 'repository-subscriptions', 'organization-controls', 'practices'.
-- Leave NULL to report every menu.
DECLARE @menu_key NVARCHAR(120) = NULL;

DECLARE @employee_id BIGINT, @organization_id BIGINT, @primary_role_id BIGINT;
SELECT TOP (1) @employee_id = e.employee_id,
               @organization_id = e.organization_id,
               @primary_role_id = e.role_id
FROM grac_practice.organization_employee e
WHERE LOWER(LTRIM(RTRIM(e.email))) = LOWER(LTRIM(RTRIM(@login_id)))
   OR LOWER(e.employee_code) = LOWER(@login_id)
ORDER BY e.employee_id;

IF @employee_id IS NULL
BEGIN
    -- The commonest cause by far: the script was run as shipped, with the
    -- placeholder still in @login_id. Say so plainly rather than sending
    -- the reader off to diagnose a sign-in that is working fine.
    IF @login_id = N'REPLACE-WITH-THE-FAILING-EMAIL'
    BEGIN
        PRINT '@login_id is still the placeholder.';
        PRINT 'Edit the DECLARE @login_id line near the top of this script -- set it to the';
        PRINT 'email (or Employee Code) of the user you are diagnosing -- and run it again.';
    END
    ELSE
    BEGIN
        PRINT 'No organization_employee row matches ''' + @login_id + '''.';
        PRINT 'If that user can sign in, the id typed here is not the one they sign in with';
        PRINT '(check for a different domain, a trailing space, or employee_code vs email).';
        PRINT 'If they cannot sign in either, run database/_diag_user_login.sql -- that is a';
        PRINT 'sign-in problem, not a permission problem.';
    END

    -- Either way, show what accounts actually exist so the right value can
    -- be copied straight out of this result set.
    PRINT '';
    PRINT '=== Twenty most recent accounts, for reference ===';
    SELECT TOP (20)
           e.employee_id, e.organization_id, o.organization_name,
           e.employee_code, e.employee_name, e.email,
           e.status AS employee_status, e.entered_by, e.entered_dt
    FROM grac_practice.organization_employee e
    LEFT JOIN grac_practice.organization o ON o.organization_id = e.organization_id
    ORDER BY e.employee_id DESC;

    RETURN;
END

PRINT '=== 1. Identity ===';
SELECT e.employee_id, e.employee_code, e.employee_name, e.email,
       e.organization_id, o.organization_name,
       e.status AS employee_status,
       e.role_id AS primary_role_id,
       r.role_name AS primary_role_name,
       r.role_code AS primary_role_code,
       r.data_scope AS primary_role_scope
FROM grac_practice.organization_employee e
LEFT JOIN grac_practice.organization o ON o.organization_id = e.organization_id
LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id
WHERE e.employee_id = @employee_id;

-- =====================================================================
-- 2. Every role the permission loader will union over.
--    Empty here means no permissions at all, whatever the grants say.
-- =====================================================================
PRINT '=== 2. Roles in the union ===';
SELECT r.role_id, r.role_name, r.role_code, r.data_scope, r.status AS role_status,
       'organization_employee_role (M:N)' AS Source
FROM grac_practice.organization_employee_role er
JOIN grac_practice.organization_role r ON r.role_id = er.role_id
WHERE er.employee_id = @employee_id AND er.status = 'Active'
UNION
SELECT r.role_id, r.role_name, r.role_code, r.data_scope, r.status,
       'organization_employee.role_id (primary)'
FROM grac_practice.organization_role r
WHERE r.role_id = @primary_role_id;

-- =====================================================================
-- 3. Menu-by-menu verdict.
--    Grant = what the session will carry. A menu with Grant 'NONE' is a
--    screen this user cannot open.
-- =====================================================================
PRINT '=== 3. Menus and the resulting grant ===';
WITH user_roles AS (
    SELECT er.role_id FROM grac_practice.organization_employee_role er
     WHERE er.employee_id = @employee_id AND er.status = 'Active'
    UNION
    SELECT @primary_role_id WHERE @primary_role_id IS NOT NULL
),
effective AS (
    SELECT m.menu_id,
           m.menu_key,
           m.menu_name,
           m.status AS menu_status,
           MAX(CASE WHEN p.status = 'Active' THEN CAST(p.can_view    AS INT) ELSE 0 END) AS can_view,
           MAX(CASE WHEN p.status = 'Active' THEN CAST(p.can_add     AS INT) ELSE 0 END) AS can_add,
           MAX(CASE WHEN p.status = 'Active' THEN CAST(p.can_edit    AS INT) ELSE 0 END) AS can_edit,
           MAX(CASE WHEN p.status = 'Active' THEN CAST(p.can_delete  AS INT) ELSE 0 END) AS can_delete,
           MAX(CASE WHEN p.status = 'Active' THEN CAST(p.can_approve AS INT) ELSE 0 END) AS can_approve,
           COUNT(p.role_menu_permission_id) AS permission_rows
    FROM grac_practice.menu_master m
    LEFT JOIN grac_practice.organization_role_menu_permission p
           ON p.menu_id = m.menu_id
          AND p.role_id IN (SELECT role_id FROM user_roles)
    GROUP BY m.menu_id, m.menu_key, m.menu_name, m.status
)
SELECT menu_key,
       menu_name,
       menu_status,
       permission_rows,
       can_view, can_add, can_edit, can_delete, can_approve,
       CASE WHEN menu_status <> 'Active'                       THEN 'menu_master row is not Active'
            WHEN permission_rows = 0                           THEN 'NONE -- no permission row for any of this user''s roles'
            WHEN can_view = 0                                  THEN 'NONE -- row exists but can_view = 0 (or the row is Inactive)'
            ELSE 'VIEW granted' END                            AS Verdict
FROM effective
WHERE @menu_key IS NULL OR menu_key = @menu_key
ORDER BY CASE WHEN menu_status <> 'Active' OR can_view = 0 THEN 0 ELSE 1 END, menu_key;

-- =====================================================================
-- 4. Organisations the gateway will accept.
--    PracticeManagementGatewayController tests
--    AllowedOrganizationIds().Contains(requestedOrganizationId), and
--    that list is user_organization_map plus the home organisation --
--    data_scope GLOBAL does NOT widen it. An organisation missing here
--    answers 403 "You do not have access to the selected organization."
-- =====================================================================
PRINT '=== 4. Organisation access ===';
SELECT o.organization_id,
       o.organization_name,
       o.status AS organization_status,
       CASE WHEN o.organization_id = @organization_id THEN 'YES (home organisation)'
            WHEN m.user_organization_map_id IS NOT NULL AND m.status = 'Active' THEN 'YES (user_organization_map)'
            WHEN m.user_organization_map_id IS NOT NULL THEN 'NO -- map row exists but status = ' + m.status
            ELSE 'NO -- no map row' END AS Allowed
FROM grac_practice.organization o
LEFT JOIN grac_practice.user_organization_map m
       ON m.organization_id = o.organization_id
      AND LOWER(m.user_email) IN (LOWER(@login_id),
                                  (SELECT LOWER(email) FROM grac_practice.organization_employee WHERE employee_id = @employee_id),
                                  (SELECT LOWER(employee_code) FROM grac_practice.organization_employee WHERE employee_id = @employee_id))
WHERE o.status = 'Active'
ORDER BY o.organization_id;

-- =====================================================================
-- 5. Screen feature flags for the home organisation.
--    A screen whose flag resolves to 0 renders its "not available"
--    banner regardless of permission.
-- =====================================================================
PRINT '=== 5. Screen feature flags (home organisation) ===';
IF OBJECT_ID('grac_practice.fn_pm_feature_enabled','FN') IS NOT NULL
    SELECT fm.feature_code,
           grac_practice.fn_pm_feature_enabled(@organization_id, fm.feature_code) AS Enabled
    FROM grac_practice.feature_flag_master fm
    WHERE fm.is_active = 1 AND fm.feature_code LIKE 'screen.%'
    ORDER BY fm.feature_code;
ELSE
    PRINT 'fn_pm_feature_enabled not present -- run 041_feature_flag.sql.';

PRINT '';
PRINT 'READING THE RESULT';
PRINT '------------------';
PRINT 'Section 2 empty      -> the user has no role. Assign one; both';
PRINT '                        organization_employee.role_id and the';
PRINT '                        organization_employee_role row.';
PRINT 'Section 3 Verdict    -> the exact reason a screen is refused.';
PRINT '                        Fix from Organization > Role Menu Permissions,';
PRINT '                        or re-run section 2 of';
PRINT '                        database/220_grac_admin_users.sql for the';
PRINT '                        GRAC Admin role.';
PRINT 'Section 4 shows NO   -> the screen opens but the gateway answers 403';
PRINT '                        on that organisation. Add the';
PRINT '                        user_organization_map row (220 section 5).';
PRINT 'Section 5 shows 0    -> the screen renders its "not available"';
PRINT '                        banner. Run';
PRINT '                        pm_grant_organization_default_access.';
