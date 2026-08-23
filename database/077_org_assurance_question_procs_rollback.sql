-- =====================================================================
-- 077 Organization Assurance Question procedures rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_question_delete','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_question_delete;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_question_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_question_save;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_question_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_question_get;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_question_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_question_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_question_set_delete','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_question_set_delete;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_question_set_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_question_set_save;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_question_set_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_question_set_get;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_question_set_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_question_set_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_admin_question_type_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_admin_question_type_list;
GO

PRINT '077 rollback complete.';
GO
