-- =====================================================================
-- 042 Task Center menu + permissions — ROLLBACK  (charter §9)
--
-- Reverses the seed done by 042_task_center_menu_seed.sql:
--   * Deletes organization_role_menu_permission rows for menu `tasks`
--   * Deletes menu_master row for `tasks`
--   * Turns OFF feature_flag rows for `screen.tasks`
--
-- Idempotent. Preserves feature_flag_master / feature_flag catalog rows
-- (those are dropped by 041_feature_flag_rollback.sql when the whole
-- registry is torn down).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (042-rollback): schema grac_practice missing.';
    RAISERROR('grac_practice schema missing', 16, 1);
    SET NOEXEC ON;
END
GO

-- Remove role-menu grants for the tasks menu (all orgs)
IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
    DELETE p
    FROM grac_practice.organization_role_menu_permission p
    JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
    WHERE m.menu_key = N'tasks';
END
GO

-- Remove the menu row
IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
    DELETE FROM grac_practice.menu_master WHERE menu_key = N'tasks';
GO

-- Turn OFF the feature flag per-org (keep the catalog row)
IF OBJECT_ID('grac_practice.feature_flag','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.feature_flag_master','U') IS NOT NULL
BEGIN
    UPDATE ff
    SET is_enabled = 0,
        notes      = N'Disabled by 042 rollback',
        updated_by = 'rollback-042',
        updated_dt = SYSUTCDATETIME()
    FROM grac_practice.feature_flag ff
    JOIN grac_practice.feature_flag_master m ON m.feature_flag_id = ff.feature_flag_id
    WHERE m.feature_code = N'screen.tasks';
END
GO

PRINT '042 Task Center menu + permissions rollback complete.';
GO

SET NOEXEC OFF;
GO
