-- =====================================================================
-- 281 UAT: enable Audit Management for an organization
--
-- THE ACTUAL CAUSE OF "Audit Management is not yet enabled for this
-- organization."
--   That banner is NOT a menu-permission problem. The screen calls
--       GET /practice/api/workflow-feature/status?featureCode=...&organizationId=...
--   which resolves through grac_practice.fn_pm_feature_enabled, whose
--   precedence is:
--       per-org feature_flag row  >  feature_flag_master.default_enabled  >  0
--   The org-assurance screens ship with default_enabled = 0, so a fresh
--   UAT database shows the banner until a per-org row turns them on.
--   Menu rows and role grants are a separate axis and are handled in
--   section 3 below.
--
-- WHICH SCREENS ARE ACTUALLY GATED
--   Only three of the Audit Management screens check a flag:
--       screen.org-assurance-definitions
--       screen.org-assurance-question-sets
--       screen.org-assurance-plans
--   Scope Builder, Evidence / Workflow / Scoring Config, Triggers,
--   Scope Resolution, Executions and Observations have no feature check
--   -- they are reached through a definition, so gating the definition
--   screen already gates them. They are listed in @Codes anyway so a
--   later flag added to one of them is covered without editing this
--   script.
--
-- SCOPE SWITCH
--   @OrganizationId = NULL  -> every ACTIVE organization (UAT default)
--   @OrganizationId = <id>  -> that organization only
--
-- Re-runnable: yes. A second run reports 0 changes.
-- Rollback: database/281_uat_enable_audit_management_rollback.sql
-- DEPENDS ON: 041 (feature_flag + fn_pm_feature_enabled),
--             276 (Audit Management menu group).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

-- ---------------------------------------------------------------------
-- Scope. Change this one value to target a single organization.
-- ---------------------------------------------------------------------
DECLARE @OrganizationId BIGINT = NULL;   -- NULL = all active organizations

-- ---------------------------------------------------------------------
-- Prerequisites
-- ---------------------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN PRINT 'ABORT (281): feature_flag tables missing. Run 041 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.fn_pm_feature_enabled','FN') IS NULL
BEGIN PRINT 'ABORT (281): fn_pm_feature_enabled missing. Run 041 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('281_uat_enable_audit_management: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END

-- ---------------------------------------------------------------------
-- The feature codes this module uses.
-- ---------------------------------------------------------------------
DECLARE @Codes TABLE(feature_code NVARCHAR(80) PRIMARY KEY, feature_name NVARCHAR(200));
INSERT INTO @Codes(feature_code, feature_name) VALUES
    (N'screen.org-assurance-definitions'     , N'Audit Definitions'),
    (N'screen.org-assurance-question-sets'   , N'Audit Question Sets'),
    (N'screen.org-assurance-plans'           , N'Audit Plans'),
    (N'screen.org-assurance-scope-builder'   , N'Audit Scope Builder'),
    (N'screen.org-assurance-evidence-config' , N'Audit Evidence Config'),
    (N'screen.org-assurance-workflow-config' , N'Audit Workflow Config'),
    (N'screen.org-assurance-scoring-config'  , N'Audit Scoring Config'),
    (N'screen.org-assurance-triggers'        , N'Audit Triggers'),
    (N'screen.org-assurance-scope-resolution', N'Audit Scope Resolution'),
    (N'screen.org-assurance-executions'      , N'Audit Executions'),
    (N'screen.org-assurance-observations'    , N'Audit Observations');

-- ---------------------------------------------------------------------
-- BEFORE picture, so the run is auditable.
-- ---------------------------------------------------------------------
PRINT '--- 281 BEFORE ---';
SELECT o.organization_code AS Organization,
       c.feature_code      AS FeatureCode,
       grac_practice.fn_pm_feature_enabled(o.organization_id, c.feature_code) AS EnabledNow
FROM   grac_practice.organization o
CROSS JOIN @Codes c
WHERE  o.status = N'Active'
   AND (@OrganizationId IS NULL OR o.organization_id = @OrganizationId)
   AND c.feature_code IN (N'screen.org-assurance-definitions',
                          N'screen.org-assurance-question-sets',
                          N'screen.org-assurance-plans')
ORDER BY o.organization_code, c.feature_code;

-- =====================================================================
-- 1. Make sure every code exists in the master catalogue.
--    default_enabled stays 0 -- enabling is a per-org decision, and
--    flipping the global default would switch the module on for every
--    tenant including ones that have not been onboarded.
-- =====================================================================
INSERT INTO grac_practice.feature_flag_master
    (feature_code, feature_name, description, category, default_enabled, is_active, entered_by)
SELECT c.feature_code, c.feature_name,
       N'Audit Management screen gate.', N'Screen', 0, 1, N'seed-281'
FROM   @Codes c
WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.feature_flag_master m
                    WHERE m.feature_code = c.feature_code);

PRINT '281: feature_flag_master rows added = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

-- =====================================================================
-- 2. Turn the flags ON for the in-scope organizations.
--    MERGE so an existing row that is OFF is raised to ON rather than
--    duplicated (uq_pm_feature_flag_org_feature would reject a second).
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
    notes      = N'Enabled for UAT by 281',
    updated_by = N'seed-281',
    updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (organization_id, feature_flag_id, is_enabled, notes, entered_by)
VALUES
    (s.organization_id, s.feature_flag_id, 1, N'Enabled for UAT by 281', N'seed-281');

PRINT '281: per-organization flags enabled = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 3. Menu visibility -- the OTHER axis.
--    A flag makes the screen work; a grant makes it appear in the
--    sidebar. Give every ACTIVE role of the in-scope organizations
--    can_view on every ACTIVE Audit Management menu. View only: this
--    script is about making the module reachable in UAT, not about
--    handing out add / edit / delete / approve.
-- =====================================================================
DECLARE @OrganizationId BIGINT = NULL;   -- keep in step with the value above

IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
         WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    MERGE grac_practice.organization_role_menu_permission AS t
    USING (
        SELECT r.role_id, m.menu_id, @active_record_status_id AS record_status_id
        FROM   grac_practice.organization_role r
        JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
        CROSS JOIN grac_practice.menu_master m
        WHERE  r.status = N'Active'
          AND  o.status = N'Active'
          AND (@OrganizationId IS NULL OR o.organization_id = @OrganizationId)
          AND  m.status = N'Active'
          AND  m.module_type = N'Audit Management'
    ) AS s
    ON t.role_id = s.role_id AND t.menu_id = s.menu_id
    WHEN MATCHED AND (t.can_view = 0 OR t.status <> N'Active') THEN UPDATE SET
        can_view   = 1,
        status     = N'Active',
        updated_by = N'seed-281',
        updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
         status, record_status_id, entered_by)
    VALUES
        (s.role_id, s.menu_id, 1, 0, 0, 0, 0,
         N'Active', s.record_status_id, N'seed-281');

    PRINT '281: menu view grants added / raised = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END
ELSE
    PRINT '281: menu tables missing -- skipped section 3.';
GO

-- =====================================================================
-- 4. AFTER picture + verification
-- =====================================================================
DECLARE @OrganizationId BIGINT = NULL;   -- keep in step with the value above

PRINT '--- 281 AFTER ---';
SELECT o.organization_code AS Organization,
       c.code              AS FeatureCode,
       grac_practice.fn_pm_feature_enabled(o.organization_id, c.code) AS EnabledNow
FROM   grac_practice.organization o
CROSS JOIN (VALUES (N'screen.org-assurance-definitions'),
                   (N'screen.org-assurance-question-sets'),
                   (N'screen.org-assurance-plans')) AS c(code)
WHERE  o.status = N'Active'
   AND (@OrganizationId IS NULL OR o.organization_id = @OrganizationId)
ORDER BY o.organization_code, c.code;

SELECT 'Every in-scope org has the gated screens ON' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1
                  FROM grac_practice.organization o
                  CROSS JOIN (VALUES (N'screen.org-assurance-definitions'),
                                     (N'screen.org-assurance-question-sets'),
                                     (N'screen.org-assurance-plans')) AS c(code)
                 WHERE o.status = N'Active'
                   AND (@OrganizationId IS NULL OR o.organization_id = @OrganizationId)
                   AND grac_practice.fn_pm_feature_enabled(o.organization_id, c.code) = 0)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Audit Management menus visible to at least one role' AS Check_,
       CASE WHEN EXISTS (
                SELECT 1
                  FROM grac_practice.organization_role_menu_permission p
                  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
                 WHERE m.module_type = N'Audit Management'
                   AND m.status = N'Active'
                   AND p.can_view = 1 AND p.status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '281 UAT Audit Management enablement complete.';
PRINT 'If the banner persists: sign out and back in -- the sidebar and';
PRINT 'the org list are read into the session at sign-in.';
GO
SET NOEXEC OFF;
GO
