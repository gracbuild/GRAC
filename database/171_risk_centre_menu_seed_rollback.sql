SET NOCOUNT ON;
GO
-- Detach permissions, then menu, then feature flag rows -- retain the
-- feature_flag_master row itself so operators can re-enable later.
DECLARE @menu_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'risk-centre');
IF @menu_id IS NOT NULL
BEGIN
    DELETE FROM grac_practice.organization_role_menu_permission WHERE menu_id = @menu_id;
    DELETE FROM grac_practice.menu_master WHERE menu_id = @menu_id;
END
GO
DECLARE @f INT = (SELECT feature_flag_id FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.risk-centre');
IF @f IS NOT NULL
    DELETE FROM grac_practice.feature_flag WHERE feature_flag_id = @f;
GO
PRINT '171 rollback complete.';
GO
