-- ============================================================================
-- 057 Rollback -- drops mapping table and helper SPs.
-- ============================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_apply_practices_for_control','P')   IS NOT NULL
    DROP PROCEDURE grac_practice.sp_apply_practices_for_control;
GO
IF OBJECT_ID('grac_practice.sp_unapply_practices_for_control','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_unapply_practices_for_control;
GO
IF OBJECT_ID('grac_practice.organization_control_requirement','U') IS NOT NULL
    DROP TABLE grac_practice.organization_control_requirement;
GO

PRINT '057 rollback complete.';
GO
