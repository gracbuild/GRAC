-- =====================================================================
-- 078 Organization Assurance Question Sets menu seed rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.feature_flag','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.feature_flag_master','U') IS NOT NULL
BEGIN
    UPDATE ff
    SET is_enabled = 0, updated_by = 'rollback-078', updated_dt = SYSUTCDATETIME()
    FROM grac_practice.feature_flag ff
    JOIN grac_practice.feature_flag_master fm ON fm.feature_flag_id = ff.feature_flag_id
    WHERE fm.feature_code IN (N'screen.org-assurance-question-sets');
END
GO

IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
BEGIN
    UPDATE rmp
    SET status = N'Inactive', updated_by = 'rollback-078', updated_dt = SYSUTCDATETIME()
    FROM grac_practice.organization_role_menu_permission rmp
    JOIN grac_practice.menu_master m ON m.menu_id = rmp.menu_id
    WHERE m.menu_key IN (N'org-assurance-question-sets');
END
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
    UPDATE grac_practice.menu_master
       SET status = N'Inactive', updated_by = 'rollback-078', updated_dt = SYSUTCDATETIME()
     WHERE menu_key IN (N'org-assurance-question-sets');
END
GO

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NOT NULL
BEGIN
    UPDATE grac_practice.feature_flag_master
       SET is_active = 0, updated_by = 'rollback-078', updated_dt = SYSUTCDATETIME()
     WHERE feature_code IN (N'screen.org-assurance-question-sets');
END
GO

PRINT '078 rollback complete.';
GO
