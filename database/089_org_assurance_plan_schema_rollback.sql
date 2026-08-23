-- =====================================================================
-- 089 Organization Assurance Plan schema rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_plan_item','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_plan_item;
GO
IF OBJECT_ID('grac_practice.org_assurance_plan','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_plan;
GO
IF OBJECT_ID('grac_practice.org_assurance_plan_status_master','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_plan_status_master;
GO

PRINT '089 rollback complete.';
GO
