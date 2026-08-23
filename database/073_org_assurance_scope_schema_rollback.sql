-- =====================================================================
-- 073 Organization Assurance Scope schema rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_scope_condition_value','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_scope_condition_value;
GO
IF OBJECT_ID('grac_practice.org_assurance_scope_condition','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_scope_condition;
GO
IF OBJECT_ID('grac_practice.org_assurance_scope_group','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_scope_group;
GO
IF OBJECT_ID('grac_practice.org_assurance_scope_dimension_master','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_scope_dimension_master;
GO

PRINT '073 rollback complete.';
GO
