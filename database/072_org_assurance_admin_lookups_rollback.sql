-- =====================================================================
-- 072 Organization Assurance -- Admin lookup procs rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_admin_category_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_admin_category_list;
GO

PRINT '072 rollback complete.';
GO
