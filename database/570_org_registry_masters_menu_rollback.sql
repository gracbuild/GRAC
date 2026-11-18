-- =====================================================================
-- 570_org_registry_masters_menu_rollback.sql
-- Reverses 570: the org-registry menu row, the Legal Entities rename, the
-- location types / designations 570 added (only where nothing uses them),
-- the controlled values, and sp_org_organization_list back to 518.
-- =====================================================================
SET NOCOUNT ON;
GO
DELETE p FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id WHERE m.menu_key = N'org-registry';
DELETE FROM grac_practice.menu_master WHERE menu_key = N'org-registry';
UPDATE grac_practice.menu_master SET menu_name = N'Organizations', updated_by = N'rollback-570', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'organizations';
GO
DELETE lt FROM grac_practice.location_type_master lt
 WHERE lt.entered_by = N'seed-570'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_location l WHERE l.location_type_id = lt.location_type_id);
DELETE d FROM grac_practice.committee_designation_master d
 WHERE d.entered_by = N'seed-570'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_committee_member m WHERE m.designation_id = d.designation_id);
GO
IF OBJECT_ID('grac_practice.org_registry_master_value','U') IS NOT NULL
    DELETE FROM grac_practice.org_registry_master_value WHERE entered_by = N'seed-570';
GO
PRINT '570 rollback: re-run 518_organization_list_spoc_email.sql to restore sp_org_organization_list without the hierarchy columns.';
GO
