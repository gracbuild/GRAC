-- =====================================================================
-- 087 Organization Assurance Scoring procedures rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_scoring_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_scoring_save;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_scoring_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_scoring_get;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_scoring_model_type_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_scoring_model_type_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_admin_scoring_model_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_admin_scoring_model_list;
GO

PRINT '087 rollback complete.';
GO
