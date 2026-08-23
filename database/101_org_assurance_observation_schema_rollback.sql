-- =====================================================================
-- 101 rollback -- Organization Assurance Observation schema
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_observation_history','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_observation_history;
GO
IF OBJECT_ID('grac_practice.org_assurance_observation_evidence','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_observation_evidence;
GO
IF OBJECT_ID('grac_practice.org_assurance_observation','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_observation;
GO
IF OBJECT_ID('grac_practice.org_assurance_observation_status_master','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_observation_status_master;
GO
IF OBJECT_ID('grac_practice.org_assurance_observation_severity_master','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_observation_severity_master;
GO

PRINT '101 Organization Assurance Observation schema rolled back.';
GO
