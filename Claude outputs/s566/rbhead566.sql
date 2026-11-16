-- 566 rollback  Audit Engagements as a distinct record
-- Restores sp_org_assurance_plan_item_save / _list (565), start_execution /
-- my_audits_prepare / my_audit_list (555), sp_org_responsibility_holder_list
-- (553) and fn_org_assurance_engagement_progress (565); drops the engagement
-- procedures and functions; sets the Audit Engagements menu Inactive.
-- Kept: the new columns, the initiation master, the team table (data), and
-- org_assurance_plan_item.org_assurance_plan_id stays NULLable (independent
-- engagements have no plan; the 565 bodies simply do not list them).
SET NOCOUNT ON;
GO

UPDATE grac_practice.menu_master
   SET status = N'Inactive', updated_by = 'rollback-566', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-audit-engagements';
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_delete','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_delete;
IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_cancel','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_cancel;
IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_approve','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_approve;
IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_team_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_team_save;
IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_team_apply','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_team_apply;
IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_team_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_team_list;
IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_get','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_get;
IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_list;
IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_initiation_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_initiation_list;
GO

