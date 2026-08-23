-- =====================================================================
-- 154 My Acknowledgements menu seed -- ROLLBACK
-- =====================================================================
SET NOCOUNT ON;
GO
DECLARE @f_id INT = (SELECT feature_flag_id FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.my-acknowledgements');
IF @f_id IS NOT NULL
BEGIN
    DELETE FROM grac_practice.feature_flag WHERE feature_flag_id = @f_id;
    DELETE FROM grac_practice.feature_flag_master WHERE feature_flag_id = @f_id;
END
GO
DECLARE @menu_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'my-acknowledgements');
IF @menu_id IS NOT NULL DELETE FROM grac_practice.organization_role_menu_permission WHERE menu_id = @menu_id;
GO
DELETE FROM grac_practice.menu_master WHERE menu_key = N'my-acknowledgements';
GO
PRINT '154 rollback complete.';
GO
