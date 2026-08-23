-- =====================================================================
-- 071 Organization Assurance -- Stage 1 menu seed rollback
--
-- Deactivates (does NOT hard-delete) the Stage 1 rows so historical
-- audit / permission traces stay intact. Mirrors the approach used by
-- 068 rollback.
-- =====================================================================
SET NOCOUNT ON;
GO

-- 1. Disable per-org feature flag rows.
IF OBJECT_ID('grac_practice.feature_flag','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.feature_flag_master','U') IS NOT NULL
BEGIN
    UPDATE ff
    SET is_enabled = 0,
        updated_by = 'rollback-071',
        updated_dt = SYSUTCDATETIME()
    FROM grac_practice.feature_flag ff
    JOIN grac_practice.feature_flag_master fm
         ON fm.feature_flag_id = ff.feature_flag_id
    WHERE fm.feature_code IN (N'screen.org-assurance-definitions');
END
GO

-- 2. Revoke Admin role permissions on the Stage 1 child.
IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
BEGIN
    UPDATE rmp
    SET status = N'Inactive',
        updated_by = 'rollback-071',
        updated_dt = SYSUTCDATETIME()
    FROM grac_practice.organization_role_menu_permission rmp
    JOIN grac_practice.menu_master m ON m.menu_id = rmp.menu_id
    WHERE m.menu_key IN (N'org-assurance-definitions');
END
GO

-- 3. Deactivate the child menu row itself.
IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
    UPDATE grac_practice.menu_master
       SET status = N'Inactive',
           updated_by = 'rollback-071',
           updated_dt = SYSUTCDATETIME()
     WHERE menu_key IN (N'org-assurance-definitions');
END
GO

-- 4. Deactivate feature flag masters (last so per-org rows updated first).
IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NOT NULL
BEGIN
    UPDATE grac_practice.feature_flag_master
       SET is_active = 0,
           updated_by = 'rollback-071',
           updated_dt = SYSUTCDATETIME()
     WHERE feature_code IN (N'screen.org-assurance-definitions');
END
GO

PRINT '071 rollback complete (rows deactivated, not deleted).';
GO
