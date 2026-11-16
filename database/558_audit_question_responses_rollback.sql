-- =====================================================================
-- 558 ROLLBACK -- drops the response procedures. KEPT: the table
-- org_assurance_execution_response (answers given stay readable) and the
-- findings raised from it (ordinary observations). Deploy the pre-558 Api
-- and Web with it. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_execution_response_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_execution_response_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_execution_response_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_execution_response_save;
GO
PRINT '558 rolled back (procedures). Table kept.';
GO
