-- =====================================================================
-- 330 ROLLBACK -- Event Profile procedures
--
-- Drops the view, the matcher and the nine procedures 330 installed.
-- Drops nothing else: the tables are 329's, the profile rows are the
-- organisation's data.
--
-- Run 331's rollback BEFORE this one. 331's resolver calls
-- fn_pm_event_profile_matches; dropping the function first leaves
-- sp_event_obligation_raise referencing an object that does not exist,
-- which fails only when an event is next raised -- exactly the kind of
-- breakage a rollback is supposed to avoid.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_event_profile_preview_members','P')  IS NOT NULL DROP PROCEDURE grac_practice.sp_event_profile_preview_members;
GO
IF OBJECT_ID('grac_practice.sp_event_profile_delete','P')           IS NOT NULL DROP PROCEDURE grac_practice.sp_event_profile_delete;
GO
IF OBJECT_ID('grac_practice.sp_event_profile_set_status','P')       IS NOT NULL DROP PROCEDURE grac_practice.sp_event_profile_set_status;
GO
IF OBJECT_ID('grac_practice.sp_event_profile_save','P')             IS NOT NULL DROP PROCEDURE grac_practice.sp_event_profile_save;
GO
IF OBJECT_ID('grac_practice.sp_event_profile_get','P')              IS NOT NULL DROP PROCEDURE grac_practice.sp_event_profile_get;
GO
IF OBJECT_ID('grac_practice.sp_event_profile_list','P')             IS NOT NULL DROP PROCEDURE grac_practice.sp_event_profile_list;
GO
IF OBJECT_ID('grac_practice.sp_event_profile_dimension_values','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_event_profile_dimension_values;
GO
IF OBJECT_ID('grac_practice.sp_event_profile_dimension_list','P')   IS NOT NULL DROP PROCEDURE grac_practice.sp_event_profile_dimension_list;
GO
IF OBJECT_ID('grac_practice.fn_pm_event_profile_matches','IF')      IS NOT NULL DROP FUNCTION  grac_practice.fn_pm_event_profile_matches;
GO
IF OBJECT_ID('grac_practice.vw_pm_event_profile_subject_attribute','V') IS NOT NULL DROP VIEW grac_practice.vw_pm_event_profile_subject_attribute;
GO

SELECT '330 objects removed' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.fn_pm_event_profile_matches','IF') IS NULL
             AND OBJECT_ID('grac_practice.sp_event_profile_save','P') IS NULL
             AND OBJECT_ID('grac_practice.vw_pm_event_profile_subject_attribute','V') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '330 rollback complete.';
GO

SET NOEXEC OFF;
GO
