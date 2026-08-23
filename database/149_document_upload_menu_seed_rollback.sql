-- =====================================================================
-- 149 Document Upload menu seed -- ROLLBACK
--
-- Removes the menu row, the role grants, and the feature flag rows
-- inserted by 149. Data in document_upload / document_upload_file is
-- untouched -- roll 146/147/148 first (or after) if you need to drop
-- the underlying data.
-- =====================================================================
SET NOCOUNT ON;
GO

-- 1. Feature flag rows (per-org) then master ------------------------
DECLARE @doc_feature_id INT =
    (SELECT feature_flag_id FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.document-uploads');

IF @doc_feature_id IS NOT NULL
BEGIN
    DELETE FROM grac_practice.feature_flag WHERE feature_flag_id = @doc_feature_id;
    DELETE FROM grac_practice.feature_flag_master WHERE feature_flag_id = @doc_feature_id;
END
GO

-- 2. Role permissions on the document-uploads menu ------------------
DECLARE @menu_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'document-uploads');

IF @menu_id IS NOT NULL
    DELETE FROM grac_practice.organization_role_menu_permission WHERE menu_id = @menu_id;
GO

-- 3. Menu row --------------------------------------------------------
DELETE FROM grac_practice.menu_master WHERE menu_key = N'document-uploads';
GO

PRINT '149 rollback complete.';
GO
