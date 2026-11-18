-- 583 rollback  Audit Intelligence -- Audit Plan Recommendations
-- Sets the Audit Plan Recommendations menu Inactive and drops the 583
-- procedures. Kept: the recommendation, history and settings tables with
-- their data, and org_assurance_plan_item.universe_subject_id (engagements
-- stay linked to their Universe subjects).
-- The shared subject functions are read by
-- sp_org_assurance_universe_risk_intelligence as re-issued by 583: re-run
-- 581_audit_risk_intelligence.sql (its own body), then this rollback
-- again to drop the functions.
SET NOCOUNT ON;
GO
UPDATE grac_practice.menu_master
   SET status = N'Inactive', updated_by = 'rollback-583', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-audit-plan-recommendations';
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_plan_recommendation_history','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_plan_recommendation_history;
IF OBJECT_ID('grac_practice.sp_org_assurance_plan_recommendation_link','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_plan_recommendation_link;
IF OBJECT_ID('grac_practice.sp_org_assurance_plan_recommendation_action','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_plan_recommendation_action;
IF OBJECT_ID('grac_practice.sp_org_assurance_plan_recommendation_update','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_plan_recommendation_update;
IF OBJECT_ID('grac_practice.sp_org_assurance_plan_recommendation_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_plan_recommendation_list;
IF OBJECT_ID('grac_practice.sp_org_assurance_plan_recommendation_generate','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_plan_recommendation_generate;
IF OBJECT_ID('grac_practice.sp_org_assurance_plan_rec_setting_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_plan_rec_setting_save;
IF OBJECT_ID('grac_practice.sp_org_assurance_plan_rec_setting_get','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_plan_rec_setting_get;
IF OBJECT_ID('grac_practice.fn_org_assurance_universe_subject_audit') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_universe_subject_audit;
GO
-- The shared subject rules: dropped only once the risk intelligence
-- procedure no longer reads them (581 re-run).
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_risk_intelligence','P') IS NOT NULL
   AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_universe_risk_intelligence')) LIKE N'%fn_org_assurance_universe_subject_instances%'
BEGIN
    PRINT '583 rollback: run 581_audit_risk_intelligence.sql, then this rollback again to drop the shared subject functions.';
END
ELSE
BEGIN
    IF OBJECT_ID('grac_practice.fn_org_assurance_universe_subject_findings') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_universe_subject_findings;
    IF OBJECT_ID('grac_practice.fn_org_assurance_universe_subject_gaps') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_universe_subject_gaps;
    IF OBJECT_ID('grac_practice.fn_org_assurance_universe_subject_risks') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_universe_subject_risks;
    IF OBJECT_ID('grac_practice.fn_org_assurance_universe_subject_instances') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_universe_subject_instances;
    PRINT '583 rollback: shared subject functions dropped.';
END
GO
PRINT '583 rolled back: procedures dropped; menu Inactive; tables and the engagement link kept.';
GO
