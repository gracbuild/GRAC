-- 567 rollback  Test Working Papers
-- Restores sp_org_assurance_execution_transition (099 body: Submit no
-- longer needs the working papers); drops the working paper procedures and
-- functions; sets the Workpapers menu Inactive and Observations back to 470.
-- Kept: the tables (questions, working papers, activity, masters) and the
-- new execution / observation columns, with their data. The 558 answers
-- were never changed.
SET NOCOUNT ON;
GO

UPDATE grac_practice.menu_master
   SET status = N'Inactive', updated_by = 'rollback-567', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-workpapers';
UPDATE grac_practice.menu_master
   SET display_order = 470, updated_by = 'rollback-567', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-assurance-observations';
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_observation_finding_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_observation_finding_save;
IF OBJECT_ID('grac_practice.sp_org_assurance_observation_finding_get','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_observation_finding_get;
IF OBJECT_ID('grac_practice.sp_org_assurance_wp_raise_finding','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_wp_raise_finding;
IF OBJECT_ID('grac_practice.sp_org_assurance_execution_conclusion_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_execution_conclusion_save;
IF OBJECT_ID('grac_practice.sp_org_assurance_wp_question_conclude','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_wp_question_conclude;
IF OBJECT_ID('grac_practice.sp_org_assurance_working_paper_action','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_working_paper_action;
IF OBJECT_ID('grac_practice.sp_org_assurance_working_paper_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_working_paper_save;
IF OBJECT_ID('grac_practice.sp_org_assurance_wp_question_assign','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_wp_question_assign;
IF OBJECT_ID('grac_practice.sp_org_assurance_wp_activity_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_wp_activity_list;
IF OBJECT_ID('grac_practice.sp_org_assurance_wp_overview','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_wp_overview;
IF OBJECT_ID('grac_practice.sp_org_assurance_wp_execution_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_wp_execution_list;
IF OBJECT_ID('grac_practice.sp_org_assurance_execution_score_refresh','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_execution_score_refresh;
IF OBJECT_ID('grac_practice.sp_org_assurance_wp_question_sync','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_wp_question_sync;
IF OBJECT_ID('grac_practice.sp_org_assurance_wp_log','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_wp_log;
IF OBJECT_ID('grac_practice.sp_org_assurance_observation_origin_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_observation_origin_list;
IF OBJECT_ID('grac_practice.sp_org_assurance_testing_method_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_testing_method_list;
IF OBJECT_ID('grac_practice.fn_org_assurance_wp_question_state') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_wp_question_state;
IF OBJECT_ID('grac_practice.fn_org_assurance_wp_roles') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_wp_roles;
GO

