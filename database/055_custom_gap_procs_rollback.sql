-- 055 Custom Gap procedures -- ROLLBACK
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_custom_gap_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_custom_gap_list;
GO
IF OBJECT_ID('grac_practice.sp_custom_gap_open','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_custom_gap_open;
GO
IF OBJECT_ID('grac_practice.sp_custom_gap_close','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_custom_gap_close;
GO

PRINT '055 custom_gap procedures rollback complete.';
GO
