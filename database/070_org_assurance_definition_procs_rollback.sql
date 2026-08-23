-- =====================================================================
-- 070 Organization Assurance -- Stage 1 procedures rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_definition_version_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_definition_version_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_definition_history_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_definition_history_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_definition_retire','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_definition_retire;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_definition_activate','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_definition_activate;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_definition_approve','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_definition_approve;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_definition_submit','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_definition_submit;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_definition_transition','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_definition_transition;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_definition_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_definition_save;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_definition_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_definition_get;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_definition_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_definition_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_status_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_status_list;
GO

PRINT '070 rollback complete.';
GO
