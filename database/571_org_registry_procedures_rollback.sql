-- =====================================================================
-- 571_org_registry_procedures_rollback.sql -- drops the procedures 571 created.
-- =====================================================================
SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.sp_orgreg_lookups','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_lookups;
IF OBJECT_ID('grac_practice.sp_orgreg_summary','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_summary;
IF OBJECT_ID('grac_practice.sp_orgreg_organizations_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_organizations_list;
IF OBJECT_ID('grac_practice.sp_orgreg_organizations_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_organizations_save;
IF OBJECT_ID('grac_practice.sp_orgreg_legal_entities_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_legal_entities_list;
IF OBJECT_ID('grac_practice.sp_orgreg_legal_entities_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_legal_entities_save;
IF OBJECT_ID('grac_practice.sp_orgreg_units_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_units_list;
IF OBJECT_ID('grac_practice.sp_orgreg_units_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_units_save;
IF OBJECT_ID('grac_practice.sp_orgreg_locations_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_locations_list;
IF OBJECT_ID('grac_practice.sp_orgreg_locations_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_locations_save;
IF OBJECT_ID('grac_practice.sp_orgreg_departments_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_departments_list;
IF OBJECT_ID('grac_practice.sp_orgreg_departments_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_departments_save;
IF OBJECT_ID('grac_practice.sp_orgreg_functions_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_functions_list;
IF OBJECT_ID('grac_practice.sp_orgreg_functions_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_functions_save;
IF OBJECT_ID('grac_practice.sp_orgreg_teams_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_teams_list;
IF OBJECT_ID('grac_practice.sp_orgreg_teams_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_teams_save;
IF OBJECT_ID('grac_practice.sp_orgreg_people_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_people_list;
IF OBJECT_ID('grac_practice.sp_orgreg_people_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_people_save;
IF OBJECT_ID('grac_practice.sp_orgreg_committees_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_committees_list;
IF OBJECT_ID('grac_practice.sp_orgreg_committees_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_committees_save;
IF OBJECT_ID('grac_practice.sp_orgreg_committee_members_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_committee_members_list;
IF OBJECT_ID('grac_practice.sp_orgreg_committee_members_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_committee_members_save;
IF OBJECT_ID('grac_practice.sp_orgreg_processes_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_processes_list;
IF OBJECT_ID('grac_practice.sp_orgreg_processes_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_processes_save;
IF OBJECT_ID('grac_practice.sp_orgreg_products_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_products_list;
IF OBJECT_ID('grac_practice.sp_orgreg_products_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_products_save;
IF OBJECT_ID('grac_practice.sp_orgreg_channels_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_channels_list;
IF OBJECT_ID('grac_practice.sp_orgreg_channels_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_orgreg_channels_save;
GO
PRINT '571 rollback complete.';
GO
