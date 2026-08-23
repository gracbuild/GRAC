-- =====================================================================
-- 092 Organization Assurance Trigger schema rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_trigger_config','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_trigger_config;
GO

PRINT '092 rollback complete.';
GO
