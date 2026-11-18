-- 582 rollback  Audit Intelligence -- RBIA
-- Drops the RBIA procedures and function; sets the RBIA Configuration and
-- RBIA Assessment menus Inactive. Kept: every RBIA table with its data
-- (methodology versions, assessments, answers, scores, snapshots, history).
SET NOCOUNT ON;
GO
UPDATE grac_practice.menu_master
   SET status = N'Inactive', updated_by = 'rollback-582', updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'org-audit-rbia-config', N'org-audit-rbia-assessment');
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_rbia_assessment_action','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_rbia_assessment_action;
IF OBJECT_ID('grac_practice.sp_org_assurance_rbia_assessment_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_rbia_assessment_save;
IF OBJECT_ID('grac_practice.sp_org_assurance_rbia_assessment_get','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_rbia_assessment_get;
IF OBJECT_ID('grac_practice.sp_org_assurance_rbia_assessment_create','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_rbia_assessment_create;
IF OBJECT_ID('grac_practice.sp_org_assurance_rbia_assessment_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_rbia_assessment_list;
IF OBJECT_ID('grac_practice.sp_org_assurance_rbia_assessment_compute','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_rbia_assessment_compute;
IF OBJECT_ID('grac_practice.sp_org_assurance_rbia_methodology_discard','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_rbia_methodology_discard;
IF OBJECT_ID('grac_practice.sp_org_assurance_rbia_methodology_publish','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_rbia_methodology_publish;
IF OBJECT_ID('grac_practice.sp_org_assurance_rbia_methodology_draft','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_rbia_methodology_draft;
IF OBJECT_ID('grac_practice.sp_org_assurance_rbia_methodology_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_rbia_methodology_save;
IF OBJECT_ID('grac_practice.sp_org_assurance_rbia_methodology_get','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_rbia_methodology_get;
IF OBJECT_ID('grac_practice.sp_org_assurance_rbia_methodology_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_rbia_methodology_list;
IF OBJECT_ID('grac_practice.fn_org_assurance_rbia_subject_current') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_rbia_subject_current;
GO
PRINT '582 rolled back: RBIA procedures dropped; menus Inactive; tables kept.';
GO
