-- =====================================================================
-- 574_org_registry_defaults_and_menus_rollback.sql
-- Reverses 574: the two added menus (and any grants on them), the
-- org-registry menu name, the Organizations 574 created (their Legal
-- Entities go back to unassigned), and every default 574 wrote that is
-- still the default it wrote (rows edited since keep their values).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
BEGIN TRAN;
DELETE p FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key IN (N'org-registry-people', N'org-registry-operations');
DELETE FROM grac_practice.menu_master WHERE menu_key IN (N'org-registry-people', N'org-registry-operations');
UPDATE grac_practice.menu_master SET menu_name = N'Organization Registry', display_order = 3,
       updated_by = N'rollback-574', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-registry';

UPDATE o SET registry_organization_id = NULL, updated_by = N'rollback-574', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.organization o
  JOIN grac_practice.registry_organization r ON r.registry_organization_id = o.registry_organization_id
 WHERE r.entered_by = N'seed-574';
DELETE FROM grac_practice.registry_organization WHERE entered_by = N'seed-574';

UPDATE grac_practice.organization SET entity_type = NULL WHERE updated_by = N'seed-574' AND entity_type = N'Other';
UPDATE grac_practice.organization_division SET unit_type = NULLIF(unit_type, N'Other'), is_operational = NULLIF(is_operational, N'Yes') WHERE updated_by = N'seed-574';
UPDATE grac_practice.organization_location
   SET location_code = CASE WHEN location_code = N'LOC-' + CAST(location_id AS NVARCHAR(20)) THEN NULL ELSE location_code END,
       customer_facing = NULLIF(customer_facing, N'No')
 WHERE updated_by = N'seed-574';
UPDATE grac_practice.organization_department SET department_type = NULLIF(department_type, N'Other') WHERE updated_by = N'seed-574';
UPDATE grac_practice.organization_business_function SET function_category = NULLIF(function_category, N'Other') WHERE updated_by = N'seed-574';
UPDATE grac_practice.organization_team
   SET team_code = CASE WHEN team_code = N'TEAM-' + CAST(team_id AS NVARCHAR(20)) THEN NULL ELSE team_code END,
       team_classification = NULLIF(team_classification, N'Other')
 WHERE updated_by = N'seed-574';
UPDATE grac_practice.organization_employee SET person_category = NULL, person_status = NULL WHERE updated_by = N'seed-574';
UPDATE grac_practice.organization_committee
   SET committee_code = CASE WHEN committee_code = N'COMM-' + CAST(committee_id AS NVARCHAR(20)) THEN NULL ELSE committee_code END,
       committee_type = NULLIF(committee_type, N'Other'), mandate = NULLIF(mandate, N'Not recorded')
 WHERE updated_by = N'seed-574';
UPDATE grac_practice.organization_committee_member
   SET membership_code = CASE WHEN membership_code = N'MEM-' + CAST(committee_member_id AS NVARCHAR(20)) THEN NULL ELSE membership_code END
 WHERE updated_by = N'seed-574';
UPDATE grac_practice.organization_dependency_process
   SET process_code = CASE WHEN process_code = N'PROC-' + CAST(process_id AS NVARCHAR(20)) THEN NULL ELSE process_code END,
       process_level = NULLIF(process_level, N'L1'), process_nature = NULLIF(process_nature, N'Core')
 WHERE updated_by = N'seed-574';
COMMIT;
GO
PRINT '574 rollback complete. Location state / country, Designation and in_scope_for_grac defaults are left as they are (indistinguishable from real values). Sign out and in again.';
GO
