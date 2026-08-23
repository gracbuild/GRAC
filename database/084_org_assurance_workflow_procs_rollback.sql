-- =====================================================================
-- 084 Organization Assurance Workflow procedures rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_workflow_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_workflow_save;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_workflow_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_workflow_get;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_organization_role_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_organization_role_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_workflow_stage_type_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_workflow_stage_type_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_admin_workflow_template_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_admin_workflow_template_list;
GO

PRINT '084 rollback complete.';
GO
