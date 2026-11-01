-- =====================================================================
-- 458  Settings -> Risk Settings (menu row)
--
-- REQUEST (2026-10-08)
-- --------------------
--   Risk Candidate and Risk Register showed a settings (gear) icon at the
--   right of the page that opened the Risk Centre settings modal. Make it
--   a menu under Settings and remove it from those pages.
--
-- WHAT THIS DOES (menu configuration only)
-- ----------------------------------------
--   1. Adds menu row 'risk-settings' ("Risk Settings",
--      Practice/Index/risk-settings) under nav-organization (the
--      "Settings" root), display_order 265 -- straight after Risk
--      Acceptance Approval Authority (260), its sibling risk setting.
--   2. Grants full menu permissions on it to every active role in every
--      active organisation, as 383 did for the Risk Management submenus
--      and 274 Section 3 does for every row. The gear was visible to every
--      user of the risk pages, so this keeps who can reach the settings
--      unchanged; narrow it in Role Menu Permissions if wanted.
--
-- NOT DONE
-- --------
--   * No change to the settings themselves, org_risk_config, its procs or
--     the /practice/api/risk-centre/config endpoints. The page
--     (Partials/risk-settings.cshtml + js/RiskCentre/risk-settings.js) is
--     the old modal's form and code, moved.
--   * No feature_flag row: the sidebar does not gate on flags.
--
-- ALSO EDITED: 274_menu_master_seed.sql (Section 1 row + Section 2 link),
--   per this project's convention, so a re-run of 274 keeps the row.
--
-- DEPENDS ON: 022 (menu_master, organization_role_menu_permission),
--   052 (nav-organization).
-- Rollback: 458_risk_settings_menu_rollback.sql
-- Re-runnable: yes. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (458): grac_practice.menu_master missing.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN PRINT 'ABORT (458): organization_role_menu_permission missing.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-organization')
BEGIN PRINT 'ABORT (458): nav-organization (Settings) menu row missing. Run 052 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 0
BEGIN
    RAISERROR('458_risk_settings_menu: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. The menu row under Settings.
-- ---------------------------------------------------------------------
DECLARE @settings_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-organization');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'risk-settings', N'Risk Settings', N'Practice/Index/risk-settings', 265, N'sliders')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @settings_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Organization',
    status = N'Active', updated_by = 'seed-458', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @settings_id, src.display_order,
     src.icon_class, N'Organization', N'Active', 'seed-458');
PRINT '458: risk-settings menu row upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- 2. Menu permissions -- every active role in every active organisation.
-- ---------------------------------------------------------------------
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 1, 1,
       N'Active', @active_rs, N'seed-458', SYSUTCDATETIME()
FROM   grac_practice.organization_role r
JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
JOIN   grac_practice.menu_master m ON m.menu_key = N'risk-settings'
WHERE  o.status = N'Active' AND r.status = N'Active'
  AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission p
        WHERE p.role_id = r.role_id AND p.menu_id = m.menu_id);
PRINT '458: risk-settings permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------
SELECT '458 risk-settings sits under Settings and is Active' AS Check_,
       CASE WHEN EXISTS (
              SELECT 1 FROM grac_practice.menu_master m
              JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
              WHERE m.menu_key = N'risk-settings' AND p.menu_key = N'nav-organization'
                AND m.status = N'Active' AND m.menu_url = N'Practice/Index/risk-settings')
            THEN 'PASS' ELSE 'FAIL' END AS Result_;

SELECT '458 roles granted on risk-settings' AS Check_,
       COUNT(*) AS Result_
FROM   grac_practice.organization_role_menu_permission p
JOIN   grac_practice.menu_master m ON m.menu_id = p.menu_id
WHERE  m.menu_key = N'risk-settings';
GO
PRINT '458 complete.';
GO
