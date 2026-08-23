-- =====================================================================
-- 106 rollback -- org-assurance-gaps menu / permissions / flag
-- =====================================================================
SET NOCOUNT ON;
GO
DELETE FROM grac_practice.feature_flag
WHERE feature_flag_id IN (SELECT feature_flag_id FROM grac_practice.feature_flag_master
                          WHERE feature_code = N'screen.org-assurance-gaps');
DELETE FROM grac_practice.organization_role_menu_permission
WHERE menu_id IN (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'org-assurance-gaps');
DELETE FROM grac_practice.menu_master WHERE menu_key = N'org-assurance-gaps';
DELETE FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.org-assurance-gaps';
GO
PRINT '106 org-assurance-gaps menu rolled back.';
GO
