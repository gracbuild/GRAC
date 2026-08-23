-- =====================================================================
-- 086 Organization Assurance Scoring schema rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_scoring_band','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_scoring_band;
GO
IF OBJECT_ID('grac_practice.org_assurance_scoring_config','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_scoring_config;
GO

PRINT '086 rollback complete.';
GO
