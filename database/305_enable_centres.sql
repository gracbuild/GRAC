-- =====================================================================
-- 305 Enable Gap Center / Task Center / Exception Centre
--
-- WHY THIS EXISTS
-- ---------------
-- The three centres are gated on TWO independent axes and a database
-- can fail either one on its own:
--
--   Axis 1 -- feature flag.
--       gaps.cshtml and tasks.cshtml probe
--           GET /practice/api/.../status?featureCode=screen.gaps|screen.tasks
--       which resolves through grac_practice.fn_pm_feature_enabled:
--           per-org feature_flag row  >  feature_flag_master.default_enabled (0)  >  0
--       No per-org row means OFF, and the screen renders its
--       "Ask a GRAC Admin to turn on ..." banner instead of the grid.
--       screen.exception-centre carries no client probe today but is
--       registered on the same axis, so it is handled here too.
--
--   Axis 2 -- menu permission.
--       PracticeAuthenticationService.LoadPermissionsAsync builds the
--       session permission set purely from
--       organization_role_menu_permission joined to an ACTIVE
--       menu_master row. No grant means the sidebar entry never appears
--       and the controller answers "no permission".
--
-- WHY 042 / 050 / 163 / 217 DO NOT ALREADY COVER IT
--       042 (tasks), 050 (gaps) and 163 (exception-centre) enabled only
--       the organisations that existed the day they ran.
--       217 / 223 closed that for organisations created afterwards, but
--       pm_grant_organization_default_access is INSERT-ONLY on purpose:
--       a feature_flag row already sitting at is_enabled = 0, or a
--       permission row already sitting at can_view = 0, is treated as an
--       operator decision and left alone.
--       This script is the explicit operator decision to the contrary --
--       it RAISES those rows, which is what "enable the centres" means.
--
-- SCOPE
--       Roles: Admin / ORG_ADMIN / GRAC_ADMIN -- the same three the 223
--       version of pm_grant_organization_default_access matches. Other
--       roles are untouched; grant them from the Role Access screen.
--       Organisations: @OrganizationId = NULL -> every ACTIVE org.
--                      @OrganizationId = <id> -> that org only.
--
-- MENU ROWS ARE NOT CREATED HERE
--       274_menu_master_seed.sql is the authoritative menu_master
--       snapshot and already carries 'tasks', 'gaps', 'exception-centre'
--       and their parent 'nav-oversight' as Active. This script only
--       re-raises status to 'Active' if something switched one off, so
--       it never diverges from 274. If a key is MISSING the script says
--       so and skips it -- run 274 (or 042 / 050 / 163) first.
--
-- Re-runnable: yes. A second run reports 0 changes.
-- Rollback: database/305_enable_centres_rollback.sql
-- DEPENDS ON: 041 (feature_flag + fn_pm_feature_enabled),
--             022 (menu_master, organization_role_menu_permission),
--             274 (menu snapshot).
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

-- ---------------------------------------------------------------------
-- Prerequisites -- same guard pattern as 217 / 281.
-- ---------------------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (305): schema grac_practice missing. Run base scripts first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN
    PRINT 'ABORT (305): feature_flag tables missing. Run 041_feature_flag.sql first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.fn_pm_feature_enabled','FN') IS NULL
BEGIN
    PRINT 'ABORT (305): fn_pm_feature_enabled missing. Run 041_feature_flag.sql first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN
    PRINT 'ABORT (305): menu_master / organization_role / organization_role_menu_permission missing. Run 022 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('305_enable_centres: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- Sections 1-4 share the two catalogue table variables, so they live in
-- one batch -- a table variable does not survive GO.
-- =====================================================================
DECLARE @OrganizationId BIGINT = NULL;   -- NULL = all active organizations

DECLARE @Codes TABLE(
    feature_code NVARCHAR(80)  NOT NULL PRIMARY KEY,
    feature_name NVARCHAR(200) NOT NULL,
    description  NVARCHAR(400) NOT NULL);
INSERT INTO @Codes(feature_code, feature_name, description) VALUES
    (N'screen.gaps',             N'Gap Center',       N'Gap Center screen gate (migration 050).'),
    (N'screen.tasks',            N'Task Center',      N'Task Center screen gate (migration 042).'),
    (N'screen.exception-centre', N'Exception Centre', N'Exception Centre screen gate (migration 163).');

-- 'nav-oversight' is the parent group the three centres hang under. A
-- child grant with no parent grant leaves the sidebar section collapsed
-- out of existence, so it is enabled alongside them.
DECLARE @Menus TABLE(menu_key NVARCHAR(120) NOT NULL PRIMARY KEY);   -- width matches menu_master.menu_key
INSERT INTO @Menus(menu_key) VALUES
    (N'nav-oversight'), (N'gaps'), (N'tasks'), (N'exception-centre');

-- ---------------------------------------------------------------------
-- BEFORE picture, so the run is auditable.
-- ---------------------------------------------------------------------
PRINT '--- 305 BEFORE: feature flags ---';
SELECT o.organization_id                                                    AS OrganizationId,
       o.organization_code                                                  AS Organization,
       c.feature_code                                                       AS FeatureCode,
       grac_practice.fn_pm_feature_enabled(o.organization_id, c.feature_code) AS EnabledNow
FROM   grac_practice.organization o
CROSS JOIN @Codes c
WHERE  o.status = N'Active'
   AND (@OrganizationId IS NULL OR o.organization_id = @OrganizationId)
ORDER BY o.organization_code, c.feature_code;

PRINT '--- 305 BEFORE: menu rows ---';
SELECT k.menu_key                       AS MenuKey,
       ISNULL(m.menu_name, N'(missing)') AS MenuName,
       ISNULL(m.status,   N'(missing)') AS Status_
FROM   @Menus k
LEFT JOIN grac_practice.menu_master m ON m.menu_key = k.menu_key
ORDER BY k.menu_key;

-- =====================================================================
-- 1. Catalogue -- make sure the three codes exist in feature_flag_master.
--    default_enabled stays 0: enabling is a per-organisation decision,
--    and flipping the global default would switch the centres on for
--    tenants that have not been onboarded yet.
-- =====================================================================
INSERT INTO grac_practice.feature_flag_master
    (feature_code, feature_name, description, category, default_enabled, is_active, entered_by)
SELECT c.feature_code, c.feature_name, c.description, N'Screen', 0, 1, N'seed-305'
FROM   @Codes c
WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.feature_flag_master m
                    WHERE m.feature_code = c.feature_code);

PRINT '305: feature_flag_master rows added = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

-- A code that exists but was retired (is_active = 0) never resolves,
-- whatever the per-org row says -- fn_pm_feature_enabled filters on it.
UPDATE m
SET    is_active  = 1,
       updated_by = N'seed-305',
       updated_dt = SYSUTCDATETIME()
FROM   grac_practice.feature_flag_master m
JOIN   @Codes c ON c.feature_code = m.feature_code
WHERE  m.is_active = 0;

PRINT '305: retired master rows reactivated = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

-- =====================================================================
-- 2. Per-organisation flags -- ON.
--    MERGE, not INSERT: an existing row sitting at 0 is RAISED to 1.
--    uq_pm_feature_flag_org_feature would reject a second row anyway.
-- =====================================================================
MERGE grac_practice.feature_flag AS t
USING (
    SELECT o.organization_id, m.feature_flag_id
    FROM   grac_practice.organization o
    CROSS JOIN @Codes c
    JOIN   grac_practice.feature_flag_master m ON m.feature_code = c.feature_code
    WHERE  o.status = N'Active'
      AND (@OrganizationId IS NULL OR o.organization_id = @OrganizationId)
) AS s
ON  t.organization_id = s.organization_id
AND t.feature_flag_id = s.feature_flag_id
WHEN MATCHED AND t.is_enabled = 0 THEN UPDATE SET
    is_enabled = 1,
    notes      = N'Enabled by 305',
    updated_by = N'seed-305',
    updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN INSERT
    (organization_id, feature_flag_id, is_enabled, notes, entered_by)
VALUES
    (s.organization_id, s.feature_flag_id, 1, N'Enabled by 305', N'seed-305');

PRINT '305: per-organization flags enabled = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

-- =====================================================================
-- 3. Menu rows -- re-raise status only. Never INSERT: 274 owns the
--    snapshot and a row invented here would be reverted by its MERGE.
-- =====================================================================
UPDATE m
SET    status     = N'Active',
       updated_by = N'seed-305',
       updated_dt = SYSUTCDATETIME()
FROM   grac_practice.menu_master m
JOIN   @Menus k ON k.menu_key = m.menu_key
WHERE  m.status <> N'Active';

PRINT '305: menu rows reactivated = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

IF EXISTS (SELECT 1 FROM @Menus k
            WHERE NOT EXISTS (SELECT 1 FROM grac_practice.menu_master m
                               WHERE m.menu_key = k.menu_key))
BEGIN
    PRINT '305 WARNING: one or more menu keys are missing from menu_master.';
    PRINT '             Run 274_menu_master_seed.sql (or 042 / 050 / 163) and re-run 305.';
    SELECT k.menu_key AS MissingMenuKey
    FROM   @Menus k
    WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.menu_master m
                        WHERE m.menu_key = k.menu_key);
END

-- =====================================================================
-- 4. Menu permissions -- the administrator roles get full rights on the
--    four rows. An existing row that is OFF is RAISED; a row that does
--    not exist is created. Nothing is deleted.
-- =====================================================================
DECLARE @active_record_status_id INT = (
    SELECT TOP 1 record_status_id
    FROM   grac_practice.record_status_master
    WHERE  status_code = 'ACTIVE' OR status_name = 'Active'
    ORDER BY record_status_id);
IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

MERGE grac_practice.organization_role_menu_permission AS t
USING (
    SELECT r.role_id, m.menu_id, @active_record_status_id AS record_status_id
    FROM   grac_practice.organization_role r
    JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
    CROSS JOIN @Menus k
    JOIN   grac_practice.menu_master m ON m.menu_key = k.menu_key
    WHERE  r.status = N'Active'
      AND  o.status = N'Active'
      AND (@OrganizationId IS NULL OR o.organization_id = @OrganizationId)
      AND  m.status = N'Active'
      AND (r.role_name = N'Admin' OR r.role_code = N'ORG_ADMIN' OR r.role_code = N'GRAC_ADMIN')
) AS s
ON t.role_id = s.role_id AND t.menu_id = s.menu_id
-- Any of the five off, or the row parked Inactive, is topped up to the
-- full admin grant -- the same five flags 251 guarantees for this role
-- set. Restricting an administrator on these screens is done by giving
-- the user a different role, not by half-granting Admin.
WHEN MATCHED AND (t.can_view = 0 OR t.can_add = 0 OR t.can_edit = 0
                  OR t.can_delete = 0 OR t.can_approve = 0
                  OR t.status <> N'Active') THEN UPDATE SET
    can_view    = 1,
    can_add     = 1,
    can_edit    = 1,
    can_delete  = 1,
    can_approve = 1,
    status      = N'Active',
    updated_by  = N'seed-305',
    updated_dt  = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN INSERT
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by)
VALUES
    (s.role_id, s.menu_id, 1, 1, 1, 1, 1,
     N'Active', s.record_status_id, N'seed-305');

PRINT '305: menu grants added / raised = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 5. AFTER picture + verification
-- =====================================================================
DECLARE @OrganizationId BIGINT = NULL;   -- keep in step with the value above

PRINT '--- 305 AFTER ---';
SELECT o.organization_id                                              AS OrganizationId,
       o.organization_code                                            AS Organization,
       c.code                                                         AS FeatureCode,
       grac_practice.fn_pm_feature_enabled(o.organization_id, c.code) AS EnabledNow
FROM   grac_practice.organization o
CROSS JOIN (VALUES (N'screen.gaps'), (N'screen.tasks'), (N'screen.exception-centre')) AS c(code)
WHERE  o.status = N'Active'
   AND (@OrganizationId IS NULL OR o.organization_id = @OrganizationId)
ORDER BY o.organization_code, c.code;

SELECT 'Every in-scope org has all three centre flags ON' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1
                FROM   grac_practice.organization o
                CROSS JOIN (VALUES (N'screen.gaps'), (N'screen.tasks'), (N'screen.exception-centre')) AS c(code)
                WHERE  o.status = N'Active'
                  AND (@OrganizationId IS NULL OR o.organization_id = @OrganizationId)
                  AND  grac_practice.fn_pm_feature_enabled(o.organization_id, c.code) = 0)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'The three centre menus are Active' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1
                FROM   (VALUES (N'gaps'), (N'tasks'), (N'exception-centre')) AS k(menu_key)
                WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.menu_master m
                                    WHERE m.menu_key = k.menu_key AND m.status = N'Active'))
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'No in-scope org left without an admin can_view on a centre' AS Check_,
       COUNT(*) AS OrgCount,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS Result
FROM   grac_practice.organization o
WHERE  o.status = N'Active'
  AND (@OrganizationId IS NULL OR o.organization_id = @OrganizationId)
  AND  EXISTS (
        SELECT 1
        FROM   grac_practice.menu_master m
        WHERE  m.status = N'Active'
          AND  m.menu_key IN (N'gaps', N'tasks', N'exception-centre')
          AND  NOT EXISTS (
                SELECT 1
                FROM   grac_practice.organization_role_menu_permission p
                JOIN   grac_practice.organization_role r ON r.role_id = p.role_id
                WHERE  r.organization_id = o.organization_id
                  AND  r.status = N'Active'
                  AND (r.role_name = N'Admin' OR r.role_code = N'ORG_ADMIN' OR r.role_code = N'GRAC_ADMIN')
                  AND  p.menu_id = m.menu_id
                  AND  p.can_view = 1
                  AND  p.status = N'Active'));

SELECT 'Centre grants per organisation' AS Check_,
       o.organization_id   AS OrganizationId,
       o.organization_code AS Organization,
       m.menu_key          AS MenuKey,
       MAX(CAST(p.can_view AS INT)) AS CanView
FROM   grac_practice.organization o
JOIN   grac_practice.organization_role r
       ON r.organization_id = o.organization_id
      AND r.status = N'Active'
      AND (r.role_name = N'Admin' OR r.role_code = N'ORG_ADMIN' OR r.role_code = N'GRAC_ADMIN')
JOIN   grac_practice.organization_role_menu_permission p
       ON p.role_id = r.role_id
      AND p.status = N'Active'
JOIN   grac_practice.menu_master m
       ON m.menu_id = p.menu_id
      AND m.menu_key IN (N'gaps', N'tasks', N'exception-centre')
WHERE  o.status = N'Active'
   AND (@OrganizationId IS NULL OR o.organization_id = @OrganizationId)
GROUP BY o.organization_id, o.organization_code, m.menu_key
ORDER BY o.organization_id, m.menu_key;

PRINT '305 Gap / Task / Exception Centre enablement complete.';
PRINT 'Sign out and back in -- the sidebar and the permission set are';
PRINT 'read into the session at sign-in, so an open session still shows';
PRINT 'the old menu.';
GO

SET NOEXEC OFF;
GO
