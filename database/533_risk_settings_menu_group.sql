-- =====================================================================
-- 533  Risk Management -> Settings (menu restructure)
--
-- REQUEST (2026-11-13)
-- --------------------
--   The risk configuration pages sat under the organisation-wide Settings
--   menu. Sir: put them under Risk Management in a Settings group of
--   their own, with two menus -- Workflow Settings and Risk Methodology --
--   and fold Risk Acceptance Approval Authority into Workflow Settings
--   ("athu risk settings nte page leku thanne mattikoode?").
--
-- WHAT THIS DOES (menu configuration only)
-- ----------------------------------------
--   1. Adds group row 'risk-centre-settings' ("Settings", url '#') under
--      'risk-centre' (Risk Management) at 289, after Calendar (285).
--      A three-level menu like Assurance -> Audit Configuration (276).
--   2. 'risk-settings' (458) is renamed "Workflow" and moves under the
--      group at 291. Key and url are unchanged, so the role permissions
--      on it stay as they are. (Its page title stays Workflow Settings.)
--   3. 'risk-methodology' (532) is renamed "Methodology" and moves under
--      the group at 292. Its ORG_ADMIN / GRAC_ADMIN grant is unchanged.
--      (Its page title stays Risk Methodology.) Sir, 2026-11-13: the
--      submenus read "Workflow" and "Methodology" -- the group already
--      says Settings and the root Risk Management.
--   4. 'risk-acceptance-authority' (271) is set Inactive: its grid is
--      now a section of the Workflow Settings page. The row and its
--      permission rows are KEPT (the rollback re-activates it).
--      The page's API (/risk-centre/acceptance-authority) checks session
--      and organisation only, not this menu, so the section keeps working.
--   5. Grants the group, with VIEW only, to every role that can view
--      either child. A role that sees neither child gets no empty group.
--
-- NOT DONE
-- --------
--   * No change to org_risk_config, org_risk_acceptance_authority, the
--     methodology tables, their procedures or any API.
--
-- RE-RUN NOTE: 458 and 532 re-parent their rows to 'nav-organization'
--   when re-run. Run 533 again after either of them.
--
-- ALSO EDITED: 274_menu_master_seed.sql (rows + links), per convention.
-- DEPENDS ON: 022, 052, 271, 383, 458, 532.
-- Rollback: 533_risk_settings_menu_group_rollback.sql
-- Re-runnable: yes. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @missing NVARCHAR(MAX) = N'';
IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
    SET @missing += N' table grac_practice.menu_master (022);';
IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
    SET @missing += N' table grac_practice.organization_role_menu_permission (022);';
IF @missing = N''
BEGIN
    IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'risk-centre')
        SET @missing += N' menu risk-centre (383);';
    IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'risk-settings')
        SET @missing += N' menu risk-settings (458);';
    IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'risk-methodology')
        SET @missing += N' menu risk-methodology (532);';
END
IF @missing <> N''
BEGIN
    PRINT 'ABORT (533): missing --' + @missing + ' Nothing was changed.';
    RAISERROR('533_risk_settings_menu_group: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. The group row under Risk Management.
-- ---------------------------------------------------------------------
DECLARE @risk_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'risk-centre');
MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'risk-centre-settings', N'Settings', N'#', 289, N'gear')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @risk_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Risk Management',
    status = N'Active', updated_by = 'seed-533', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @risk_id, src.display_order,
     src.icon_class, N'Risk Management', N'Active', 'seed-533');
PRINT '533: risk-centre-settings group upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- 2-4. Move the two pages under it; retire the acceptance-authority row.
-- ---------------------------------------------------------------------
DECLARE @group_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'risk-centre-settings');

UPDATE grac_practice.menu_master
   SET menu_name = N'Workflow', parent_menu_id = @group_id, display_order = 291,
       module_type = N'Risk Management', status = N'Active',
       updated_by = 'seed-533', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'risk-settings';
PRINT '533: risk-settings -> Workflow = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE grac_practice.menu_master
   SET menu_name = N'Methodology', parent_menu_id = @group_id, display_order = 292,
       module_type = N'Risk Management', status = N'Active',
       updated_by = 'seed-533', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'risk-methodology';
PRINT '533: risk-methodology -> Methodology = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE grac_practice.menu_master
   SET status = N'Inactive', updated_by = 'seed-533', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'risk-acceptance-authority' AND status <> N'Inactive';
PRINT '533: risk-acceptance-authority set Inactive = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- 5. Group permission: VIEW for every role that can view a child.
-- ---------------------------------------------------------------------
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT DISTINCT p.role_id, g.menu_id, 1, 0, 0, 0, 0,
       N'Active', @active_rs, N'seed-533', SYSUTCDATETIME()
FROM   grac_practice.organization_role_menu_permission p
JOIN   grac_practice.menu_master c ON c.menu_id = p.menu_id
                                  AND c.menu_key IN (N'risk-settings', N'risk-methodology')
JOIN   grac_practice.menu_master g ON g.menu_key = N'risk-centre-settings'
WHERE  p.can_view = 1 AND p.status = N'Active'
  AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission x
                   WHERE x.role_id = p.role_id AND x.menu_id = g.menu_id);
PRINT '533: risk-centre-settings permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------
SELECT '533 Settings group under Risk Management' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master m
                           JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
                          WHERE m.menu_key = N'risk-centre-settings' AND p.menu_key = N'risk-centre'
                            AND m.status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '533 Workflow + Methodology under the group',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.menu_master m
                    JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
                   WHERE p.menu_key = N'risk-centre-settings' AND m.status = N'Active'
                     AND ((m.menu_key = N'risk-settings'    AND m.menu_name = N'Workflow')
                       OR  (m.menu_key = N'risk-methodology' AND m.menu_name = N'Methodology'))) = 2
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '533 Risk Acceptance Approval Authority menu inactive',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.menu_master
                              WHERE menu_key = N'risk-acceptance-authority' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END;
PRINT '533 complete. Deploy Web; users sign out and back in to see the new menu.';
GO
SET NOEXEC OFF;
GO
