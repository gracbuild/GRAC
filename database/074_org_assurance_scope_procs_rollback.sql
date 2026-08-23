-- =====================================================================
-- 074 Organization Assurance Scope procedures rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_scope_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_scope_save;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_scope_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_scope_get;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_scope_dimension_values','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_scope_dimension_values;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_scope_dimension_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_scope_dimension_list;
GO

PRINT '074 rollback complete.';
GO
