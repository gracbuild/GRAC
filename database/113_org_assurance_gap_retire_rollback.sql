-- =====================================================================
-- 113 rollback -- best-effort restore of menu row + feature flag.
-- Tables and their data cannot be resurrected here; if a full restore
-- is required, restore from a database backup taken before 113 ran.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

IF NOT EXISTS (SELECT 1 FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.org-assurance-gaps')
    INSERT INTO grac_practice.feature_flag_master
        (feature_code, feature_name, description, category, default_enabled, entered_by)
    VALUES
        (N'screen.org-assurance-gaps',
         N'Assurance Gaps',
         N'Restored by 113 rollback.',
         N'Screen', 0, 'rollback-113');
GO

IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-assurance-gaps')
BEGIN
    DECLARE @nav_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance');
    INSERT INTO grac_practice.menu_master
        (menu_key, menu_name, menu_url, display_order, icon_class, module_type,
         status, parent_menu_id, entered_by)
    VALUES
        (N'org-assurance-gaps', N'Gaps', N'Practice/org-assurance-gaps',
         471, N'clipboard-list-check', N'Assurance', N'Active', @nav_id, 'rollback-113');
END
GO

COMMIT TRAN;
GO

PRINT '113 rollback complete (menu + feature flag restored; tables NOT restored).';
GO
