-- =====================================================================
-- 041 Feature flag registry — ROLLBACK  (charter §9)
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 54150, 'PracticeManagement schema grac_practice is missing.', 1;
GO

IF OBJECT_ID('grac_practice.fn_pm_feature_enabled','FN') IS NOT NULL
    DROP FUNCTION grac_practice.fn_pm_feature_enabled;
GO

IF OBJECT_ID('grac_practice.feature_flag','U') IS NOT NULL
    DROP TABLE grac_practice.feature_flag;
GO

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NOT NULL
    DROP TABLE grac_practice.feature_flag_master;
GO

PRINT '041 feature-flag rollback complete.';
