SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.sp_custom_gap_materialize_for_instance','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_custom_gap_materialize_for_instance;
GO
PRINT '160 rollback complete.';
GO
