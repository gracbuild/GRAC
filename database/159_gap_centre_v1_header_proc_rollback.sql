SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.sp_custom_gap_header','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_custom_gap_header;
GO
PRINT '159 rollback complete.';
GO
