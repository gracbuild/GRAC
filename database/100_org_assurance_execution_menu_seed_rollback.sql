-- =====================================================================
-- 100 rollback -- org-assurance-executions menu / permissions / flag
-- =====================================================================
SET NOCOUNT ON;
GO

DELETE FROM grac_practice.feature_flag
WHERE feature_flag_id IN (
    SELECT feature_flag_id FROM grac_practice.feature_flag_master
    WHERE feature_code = N'screen.org-assurance-executions');

DELETE FROM grac_practice.organization_role_menu_permission
WHERE menu_id IN (
    SELECT menu_id FROM grac_practice.menu_master
    WHERE menu_key = N'org-assurance-executions');

DELETE FROM grac_practice.menu_master
WHERE menu_key = N'org-assurance-executions';

DELETE FROM grac_practice.feature_flag_master
WHERE feature_code = N'screen.org-assurance-executions';
GO

PRINT '100 org-assurance-executions menu rolled back.';
GO
