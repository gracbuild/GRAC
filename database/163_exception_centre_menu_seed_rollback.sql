SET NOCOUNT ON;
GO
DECLARE @f INT = (SELECT feature_flag_id FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.exception-centre');
IF @f IS NOT NULL
BEGIN
    DELETE FROM grac_practice.feature_flag WHERE feature_flag_id = @f;
    DELETE FROM grac_practice.feature_flag_master WHERE feature_flag_id = @f;
END
GO
DECLARE @m BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'exception-centre');
IF @m IS NOT NULL DELETE FROM grac_practice.organization_role_menu_permission WHERE menu_id = @m;
GO
DELETE FROM grac_practice.menu_master WHERE menu_key = N'exception-centre';
GO
PRINT '163 rollback complete.';
GO
