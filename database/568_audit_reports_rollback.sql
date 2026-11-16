-- 568 rollback  Audit Reports
-- Drops the report procedures and fn_org_assurance_engagement_roles; sets
-- the Audit Reports menu Inactive. Kept: the tables (templates, reports,
-- sections, issued versions, history) with their data.
SET NOCOUNT ON;
GO
UPDATE grac_practice.menu_master
   SET status = N'Inactive', updated_by = 'rollback-568', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-audit-reports';
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_report_action','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_report_action;
IF OBJECT_ID('grac_practice.sp_org_assurance_report_section_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_report_section_save;
IF OBJECT_ID('grac_practice.sp_org_assurance_report_get','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_report_get;
IF OBJECT_ID('grac_practice.sp_org_assurance_report_data_json','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_report_data_json;
IF OBJECT_ID('grac_practice.sp_org_assurance_report_create','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_report_create;
IF OBJECT_ID('grac_practice.sp_org_assurance_report_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_report_list;
IF OBJECT_ID('grac_practice.sp_org_assurance_report_template_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_report_template_save;
IF OBJECT_ID('grac_practice.sp_org_assurance_report_template_get','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_report_template_get;
IF OBJECT_ID('grac_practice.sp_org_assurance_report_template_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_report_template_list;
IF OBJECT_ID('grac_practice.sp_org_assurance_report_section_master_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_report_section_master_list;
IF OBJECT_ID('grac_practice.fn_org_assurance_engagement_roles') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_engagement_roles;
GO
PRINT '568 rolled back: report procedures dropped; Audit Reports menu Inactive; tables kept.';
GO
