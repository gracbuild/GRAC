-- =====================================================================
-- 083 Organization Assurance Workflow schema rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_workflow_stage','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_workflow_stage;
GO
IF OBJECT_ID('grac_practice.org_assurance_workflow_config','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_workflow_config;
GO

PRINT '083 rollback complete.';
GO
