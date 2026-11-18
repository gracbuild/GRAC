-- =====================================================================
-- 572_org_registry_sample_data_rollback.sql
-- Deletes exactly the rows 572 inserted (entered_by = 'seed-572'), in
-- reverse dependency order. Rows 572 only adopted or filled in are left
-- as they are. If anything else has since come to point at a sample row,
-- the delete fails and the whole rollback is undone (XACT_ABORT).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRAN;
DELETE FROM grac_practice.organization_channel_product WHERE entered_by = N'seed-572';
DELETE FROM grac_practice.organization_channel_process WHERE entered_by = N'seed-572';
DELETE FROM grac_practice.organization_process_risk_category WHERE entered_by = N'seed-572';
UPDATE grac_practice.organization SET registry_organization_id = NULL WHERE registry_organization_id IN (SELECT registry_organization_id FROM grac_practice.registry_organization WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization SET parent_organization_id = NULL WHERE parent_organization_id IN (SELECT organization_id FROM grac_practice.organization WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization SET entity_owner_employee_id = NULL WHERE entity_owner_employee_id IN (SELECT employee_id FROM grac_practice.organization_employee WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_division SET parent_division_id = NULL WHERE parent_division_id IN (SELECT division_id FROM grac_practice.organization_division WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_division SET primary_location_id = NULL WHERE primary_location_id IN (SELECT location_id FROM grac_practice.organization_location WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_division SET head_employee_id = NULL WHERE head_employee_id IN (SELECT employee_id FROM grac_practice.organization_employee WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_location SET division_id = NULL WHERE division_id IN (SELECT division_id FROM grac_practice.organization_division WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_location SET parent_location_id = NULL WHERE parent_location_id IN (SELECT location_id FROM grac_practice.organization_location WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_location SET location_head_id = NULL WHERE location_head_id IN (SELECT employee_id FROM grac_practice.organization_employee WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_department SET parent_department_id = NULL WHERE parent_department_id IN (SELECT department_id FROM grac_practice.organization_department WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_department SET primary_division_id = NULL WHERE primary_division_id IN (SELECT division_id FROM grac_practice.organization_division WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_department SET head_employee_id = NULL WHERE head_employee_id IN (SELECT employee_id FROM grac_practice.organization_employee WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_department SET primary_business_function_id = NULL WHERE primary_business_function_id IN (SELECT business_function_id FROM grac_practice.organization_business_function WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_business_function SET parent_function_id = NULL WHERE parent_function_id IN (SELECT business_function_id FROM grac_practice.organization_business_function WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_business_function SET owner_employee_id = NULL WHERE owner_employee_id IN (SELECT employee_id FROM grac_practice.organization_employee WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_business_function SET accountable_department_id = NULL WHERE accountable_department_id IN (SELECT department_id FROM grac_practice.organization_department WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_business_function SET executive_sponsor_employee_id = NULL WHERE executive_sponsor_employee_id IN (SELECT employee_id FROM grac_practice.organization_employee WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_team SET parent_department_id = NULL WHERE parent_department_id IN (SELECT department_id FROM grac_practice.organization_department WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_team SET primary_function_id = NULL WHERE primary_function_id IN (SELECT business_function_id FROM grac_practice.organization_business_function WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_team SET division_id = NULL WHERE division_id IN (SELECT division_id FROM grac_practice.organization_division WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_team SET team_manager_id = NULL WHERE team_manager_id IN (SELECT employee_id FROM grac_practice.organization_employee WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_employee SET department_id = NULL WHERE department_id IN (SELECT department_id FROM grac_practice.organization_department WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_employee SET business_function_id = NULL WHERE business_function_id IN (SELECT business_function_id FROM grac_practice.organization_business_function WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_employee SET primary_team_id = NULL WHERE primary_team_id IN (SELECT team_id FROM grac_practice.organization_team WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_employee SET division_id = NULL WHERE division_id IN (SELECT division_id FROM grac_practice.organization_division WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_employee SET location_id = NULL WHERE location_id IN (SELECT location_id FROM grac_practice.organization_location WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_employee SET reporting_officer_id = NULL WHERE reporting_officer_id IN (SELECT employee_id FROM grac_practice.organization_employee WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_employee SET functional_reporting_to_id = NULL WHERE functional_reporting_to_id IN (SELECT employee_id FROM grac_practice.organization_employee WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_committee SET chairperson_id = NULL WHERE chairperson_id IN (SELECT employee_id FROM grac_practice.organization_employee WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_committee SET secretary_id = NULL WHERE secretary_id IN (SELECT employee_id FROM grac_practice.organization_employee WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_dependency_process SET parent_process_id = NULL WHERE parent_process_id IN (SELECT process_id FROM grac_practice.organization_dependency_process WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_dependency_process SET business_function_id = NULL WHERE business_function_id IN (SELECT business_function_id FROM grac_practice.organization_business_function WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_dependency_process SET owning_department_id = NULL WHERE owning_department_id IN (SELECT department_id FROM grac_practice.organization_department WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_dependency_process SET process_owner_id = NULL WHERE process_owner_id IN (SELECT employee_id FROM grac_practice.organization_employee WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_dependency_process SET accountable_executive_id = NULL WHERE accountable_executive_id IN (SELECT employee_id FROM grac_practice.organization_employee WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_dependency_process SET primary_product_id = NULL WHERE primary_product_id IN (SELECT product_service_id FROM grac_practice.organization_product_service WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_dependency_process SET primary_channel_id = NULL WHERE primary_channel_id IN (SELECT channel_id FROM grac_practice.organization_delivery_channel WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_dependency_process SET primary_division_id = NULL WHERE primary_division_id IN (SELECT division_id FROM grac_practice.organization_division WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_product_service SET owning_function_id = NULL WHERE owning_function_id IN (SELECT business_function_id FROM grac_practice.organization_business_function WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_product_service SET owning_department_id = NULL WHERE owning_department_id IN (SELECT department_id FROM grac_practice.organization_department WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_product_service SET product_owner_id = NULL WHERE product_owner_id IN (SELECT employee_id FROM grac_practice.organization_employee WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_delivery_channel SET owning_function_id = NULL WHERE owning_function_id IN (SELECT business_function_id FROM grac_practice.organization_business_function WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_delivery_channel SET channel_owner_id = NULL WHERE channel_owner_id IN (SELECT employee_id FROM grac_practice.organization_employee WHERE entered_by = N'seed-572');
UPDATE grac_practice.organization_delivery_channel SET primary_division_id = NULL WHERE primary_division_id IN (SELECT division_id FROM grac_practice.organization_division WHERE entered_by = N'seed-572');
DELETE b FROM grac_practice.organization_channel_process b JOIN grac_practice.organization_dependency_process p ON p.process_id = b.process_id WHERE p.entered_by = N'seed-572';
DELETE b FROM grac_practice.organization_process_risk_category b JOIN grac_practice.organization_dependency_process p ON p.process_id = b.process_id WHERE p.entered_by = N'seed-572';
DELETE b FROM grac_practice.organization_channel_product b JOIN grac_practice.organization_product_service p ON p.product_service_id = b.product_service_id WHERE p.entered_by = N'seed-572';
DELETE FROM grac_practice.organization_committee_member WHERE entered_by = N'seed-572';
DELETE FROM grac_practice.organization_delivery_channel WHERE entered_by = N'seed-572';
DELETE FROM grac_practice.organization_dependency_process WHERE entered_by = N'seed-572';
DELETE FROM grac_practice.organization_product_service WHERE entered_by = N'seed-572';
DELETE FROM grac_practice.organization_committee WHERE entered_by = N'seed-572';
DELETE FROM grac_practice.organization_employee WHERE entered_by = N'seed-572';
DELETE FROM grac_practice.organization_team WHERE entered_by = N'seed-572';
DELETE FROM grac_practice.organization_business_function WHERE entered_by = N'seed-572';
DELETE FROM grac_practice.organization_department WHERE entered_by = N'seed-572';
DELETE FROM grac_practice.organization_location WHERE entered_by = N'seed-572';
DELETE FROM grac_practice.organization_division WHERE entered_by = N'seed-572';
DELETE FROM grac_practice.organization WHERE entered_by = N'seed-572';
DELETE FROM grac_practice.registry_organization WHERE entered_by = N'seed-572';
COMMIT;
PRINT '572 rollback complete.';
GO
