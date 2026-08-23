-- =====================================================================
-- 079 Organization Assurance Evidence schema rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_evidence_config','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_evidence_config;
GO

PRINT '079 rollback complete.';
GO
