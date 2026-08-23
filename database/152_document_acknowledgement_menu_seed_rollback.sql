-- =====================================================================
-- 152 Document Acknowledgement menu seed -- ROLLBACK
-- =====================================================================
SET NOCOUNT ON;
GO

DECLARE @ack_feature_id INT =
    (SELECT feature_flag_id FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.document-acknowledgements');
IF @ack_feature_id IS NOT NULL
BEGIN
    DELETE FROM grac_practice.feature_flag WHERE feature_flag_id = @ack_feature_id;
    DELETE FROM grac_practice.feature_flag_master WHERE feature_flag_id = @ack_feature_id;
END
GO

DECLARE @menu_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'document-acknowledgements');
IF @menu_id IS NOT NULL
    DELETE FROM grac_practice.organization_role_menu_permission WHERE menu_id = @menu_id;
GO

DELETE FROM grac_practice.menu_master WHERE menu_key = N'document-acknowledgements';
GO

PRINT '152 rollback complete.';
GO
