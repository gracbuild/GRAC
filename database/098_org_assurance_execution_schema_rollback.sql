-- =====================================================================
-- 098 rollback -- Organization Assurance Execution schema
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_execution_entity','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_execution_entity;
GO

IF OBJECT_ID('grac_practice.org_assurance_execution','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_execution;
GO

IF OBJECT_ID('grac_practice.org_assurance_execution_status_master','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_execution_status_master;
GO

PRINT '098 Organization Assurance Execution schema rolled back.';
GO
