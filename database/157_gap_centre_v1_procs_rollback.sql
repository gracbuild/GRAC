-- =====================================================================
-- 157 Gap Centre v1 procs -- ROLLBACK
-- Drops the 8 new procs and the helper function. Existing 112 procs
-- are untouched.
-- =====================================================================
SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.sp_custom_gap_downstream_link_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_custom_gap_downstream_link_list;
GO
IF OBJECT_ID('grac_practice.sp_custom_gap_downstream_link_cancel','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_custom_gap_downstream_link_cancel;
GO
IF OBJECT_ID('grac_practice.sp_custom_gap_downstream_link_add','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_custom_gap_downstream_link_add;
GO
IF OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_custom_gap_analysis_save;
GO
IF OBJECT_ID('grac_practice.sp_custom_gap_analysis_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_custom_gap_analysis_get;
GO
IF OBJECT_ID('grac_practice.sp_custom_gap_lifecycle_transition','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_custom_gap_lifecycle_transition;
GO
IF OBJECT_ID('grac_practice.sp_custom_gap_lifecycle_actions','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_custom_gap_lifecycle_actions;
GO
IF OBJECT_ID('grac_practice.sp_custom_gap_lifecycle_states','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_custom_gap_lifecycle_states;
GO
IF OBJECT_ID('grac_practice.fn_gap_lifecycle_to_status','FN') IS NOT NULL
    DROP FUNCTION grac_practice.fn_gap_lifecycle_to_status;
GO
PRINT '157 rollback complete.';
GO
