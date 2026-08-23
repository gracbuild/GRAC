-- =====================================================================
-- 080 Organization Assurance Evidence procedures rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_evidence_config_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_evidence_config_save;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_evidence_config_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_evidence_config_get;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_collection_method_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_collection_method_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_evidence_type_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_evidence_type_list;
GO

PRINT '080 rollback complete.';
GO
