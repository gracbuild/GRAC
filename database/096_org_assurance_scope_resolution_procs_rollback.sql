-- =====================================================================
-- 096 Organization Assurance Scope Resolution procedures rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_scope_resolution_entity_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_scope_resolution_entity_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_scope_resolution_get','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_scope_resolution_get;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_scope_resolution_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_scope_resolution_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_scope_resolve','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_scope_resolve;
GO

PRINT '096 rollback complete.';
GO
