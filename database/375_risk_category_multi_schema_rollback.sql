-- =====================================================================
-- 375 rollback -- drops both risk-category link tables and their index.
-- Nothing else this migration touched (risk_category_master, risk_
-- analysis, risk_register) is altered.
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.risk_analysis_risk_category','U') IS NOT NULL
BEGIN
    DROP TABLE grac_practice.risk_analysis_risk_category;
    PRINT '375 rollback: risk_analysis_risk_category dropped.';
END
GO

IF OBJECT_ID('grac_practice.risk_register_risk_category','U') IS NOT NULL
BEGIN
    -- The index drops with the table; no separate DROP INDEX needed.
    DROP TABLE grac_practice.risk_register_risk_category;
    PRINT '375 rollback: risk_register_risk_category dropped.';
END
GO

PRINT '375 rollback complete. The legacy risk_category_code / risk_category_name';
PRINT 'columns on risk_analysis and risk_register were never touched by 375, so';
PRINT 'every risk keeps showing exactly the single category it showed before.';
GO
