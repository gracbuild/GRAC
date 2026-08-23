-- =====================================================================
-- 107 rollback -- Gap Center junction schema
--   Drops the junction table AND restores prior menu labels/order.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_gap_observation','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_gap_observation;
GO

IF EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-assurance-gaps')
BEGIN
    UPDATE grac_practice.menu_master
    SET menu_name     = N'Gaps',
        display_order = 471,
        updated_by    = 'rollback-107',
        updated_dt    = SYSUTCDATETIME()
    WHERE menu_key = N'org-assurance-gaps';
END
GO

IF EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-assurance-observations')
BEGIN
    UPDATE grac_practice.menu_master
    SET display_order = 470,
        updated_by    = 'rollback-107',
        updated_dt    = SYSUTCDATETIME()
    WHERE menu_key = N'org-assurance-observations';
END
GO

PRINT '107 Gap Center junction schema rolled back.';
GO
