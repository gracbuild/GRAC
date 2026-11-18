-- =====================================================================
-- 579  Risk Management: Workflow and Methodology straight under the root
--
-- REQUEST (2026-11-17)
--   "workflow and methedology settings nte under nnu matti risk
--    managenent leku matto"
--
-- WHAT THIS DOES (menu configuration only)
--   1. 'risk-settings' (Workflow) and 'risk-methodology' (Methodology)
--      move from the 'risk-centre-settings' group (533) to directly under
--      'risk-centre' (Risk Management), keeping their names, display
--      order (291 / 292, after Calendar 285) and keys -- so every role
--      permission on them carries over unchanged.
--   2. 'risk-centre-settings' is left with no children, so it is set
--      Inactive. Its row and permission rows are KEPT (the rollback
--      re-activates it).
--
-- RE-RUN NOTE: 533 moves the two rows back under the group. Run 579
--   again after re-running 533 (or 458 / 532, which 533 follows).
-- ALSO EDITED: 274_menu_master_seed.sql (rows + links), per convention.
-- DEPENDS ON: 533.
-- Rollback: 579_risk_settings_menu_flatten_rollback.sql
-- Re-runnable: yes. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'risk-centre')
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'risk-settings')
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'risk-methodology')
BEGIN
    PRINT 'ABORT (579): menu rows risk-centre / risk-settings / risk-methodology missing (383, 458, 532). Nothing was changed.';
    RAISERROR('579_risk_settings_menu_flatten: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

DECLARE @risk_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'risk-centre');

UPDATE grac_practice.menu_master
   SET parent_menu_id = @risk_id, display_order = 291, module_type = N'Risk Management',
       updated_by = 'seed-579', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'risk-settings';
PRINT '579: risk-settings (Workflow) under Risk Management = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE grac_practice.menu_master
   SET parent_menu_id = @risk_id, display_order = 292, module_type = N'Risk Management',
       updated_by = 'seed-579', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'risk-methodology';
PRINT '579: risk-methodology (Methodology) under Risk Management = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE grac_practice.menu_master
   SET status = N'Inactive', updated_by = 'seed-579', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'risk-centre-settings' AND status <> N'Inactive';
PRINT '579: risk-centre-settings (empty group) set Inactive = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

SELECT '579 Workflow + Methodology directly under Risk Management' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.menu_master m
                    JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
                   WHERE p.menu_key = N'risk-centre'
                     AND m.menu_key IN (N'risk-settings', N'risk-methodology')) = 2
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '579 empty Settings group hidden',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.menu_master
                              WHERE menu_key = N'risk-centre-settings' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END;
PRINT '579 complete. Users sign out and back in to see the menu change.';
GO
SET NOEXEC OFF;
GO
