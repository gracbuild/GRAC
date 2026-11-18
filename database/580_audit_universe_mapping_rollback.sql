-- 580 rollback  Audit Intelligence -- Framework & Practice Mapping
-- Drops the mapping procedures and function; sets the Framework & Practice
-- Mapping menu Inactive. Kept: org_assurance_universe_mapping with its
-- data (and its history rows in org_assurance_universe_history).
SET NOCOUNT ON;
GO
UPDATE grac_practice.menu_master
   SET status = N'Inactive', updated_by = 'rollback-580', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-audit-universe-mapping';
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_mapping_action','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_universe_mapping_action;
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_mapping_add','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_universe_mapping_add;
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_mapping_suggest','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_universe_mapping_suggest;
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_mapping_options','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_universe_mapping_options;
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_mapping_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_universe_mapping_list;
IF OBJECT_ID('grac_practice.fn_org_assurance_universe_mapping_ref') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_universe_mapping_ref;
GO
PRINT '580 rolled back: mapping procedures dropped; menu Inactive; table kept.';
GO
