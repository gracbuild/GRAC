-- =====================================================================
-- 095 Organization Assurance Scope Resolution schema rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_scope_resolution_entity','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_scope_resolution_entity;
GO
IF OBJECT_ID('grac_practice.org_assurance_scope_resolution','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_scope_resolution;
GO

PRINT '095 rollback complete.';
GO
