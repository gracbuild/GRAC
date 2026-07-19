-- =====================================================================
-- 050 Gap Center menu + feature flag  -- ROLLBACK
--
-- Reverses 050_gap_center_menu_seed.sql:
--   * Removes the `gaps` row from menu_master and its role-menu grants
--   * Moves `tasks` back to module_type = 'Practice Management'
--   * Removes screen.gaps rows from feature_flag and feature_flag_master
--
-- Safe to run even if 050 was never applied -- every step is guarded.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- 1. Remove Admin role grants on the gaps menu.
IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
    DELETE p
    FROM grac_practice.organization_role_menu_permission p
    JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
    WHERE m.menu_key = N'gaps';
END
GO

-- 2. Remove the gaps menu_master row entirely.
IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.menu_master WHERE menu_key = N'gaps';
END
GO

-- 3. Restore tasks to its previous module + display_order.
IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
    UPDATE grac_practice.menu_master
       SET module_type   = N'Practice Management',
           display_order = 225,
           updated_by    = 'rollback-050',
           updated_dt    = SYSUTCDATETIME()
     WHERE menu_key = N'tasks';
END
GO

-- 4. Remove per-org enable rows for screen.gaps, then remove the flag itself.
IF OBJECT_ID('grac_practice.feature_flag','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.feature_flag_master','U') IS NOT NULL
BEGIN
    DELETE ff
    FROM grac_practice.feature_flag ff
    JOIN grac_practice.feature_flag_master m ON m.feature_flag_id = ff.feature_flag_id
    WHERE m.feature_code = N'screen.gaps';

    DELETE FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.gaps';
END
GO

PRINT '050 Gap Center rollback complete.';
GO

SET NOEXEC OFF;
GO
