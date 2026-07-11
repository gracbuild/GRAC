/*
  Practice Management deployment script
  File: 04_Post_Deployment_Verification.sql
  Generated: 2026-06-20
  Purpose: Post deployment verification
  Execution: run scripts in numeric order against the target database.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
PRINT 'PracticeManagement post-deployment verification';

SELECT 'schema' CheckName, COUNT(1) RecordCount FROM sys.schemas WHERE name='grac_practice';
SELECT 'tables' CheckName, COUNT(1) RecordCount FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id WHERE s.name='grac_practice';
SELECT 'procedures' CheckName, COUNT(1) RecordCount FROM sys.procedures WHERE schema_id=SCHEMA_ID('dbo') AND name IN ('pm_get_practice_repository','pm_manage_practice_repository');

SELECT 'menu_master' TableName, COUNT(1) RecordCount FROM grac_practice.menu_master;
SELECT 'active_menu_master' TableName, COUNT(1) RecordCount FROM grac_practice.menu_master WHERE status='Active';
SELECT 'record_status_master' TableName, COUNT(1) RecordCount FROM grac_practice.record_status_master;
SELECT 'applicability_status_master' TableName, COUNT(1) RecordCount FROM grac_practice.applicability_status_master;
SELECT 'subscription_status_master' TableName, COUNT(1) RecordCount FROM grac_practice.subscription_status_master;
SELECT 'implementation_status_master' TableName, COUNT(1) RecordCount FROM grac_practice.implementation_status_master;
SELECT 'criticality_master' TableName, COUNT(1) RecordCount FROM grac_practice.criticality_master;
SELECT 'frequency_master' TableName, COUNT(1) RecordCount FROM grac_practice.frequency_master;
SELECT 'assurance_type_master' TableName, COUNT(1) RecordCount FROM grac_practice.assurance_type_master;
SELECT 'dependency_type_master' TableName, COUNT(1) RecordCount FROM grac_practice.dependency_type_master;
SELECT 'dependency_type_source_config' TableName, COUNT(1) RecordCount FROM grac_practice.dependency_type_source_config;
SELECT 'collection_method_master' TableName, COUNT(1) RecordCount FROM grac_practice.collection_method_master;
SELECT 'evidence_alignment_status_master' TableName, COUNT(1) RecordCount FROM grac_practice.evidence_alignment_status_master;
SELECT 'location_type_master' TableName, COUNT(1) RecordCount FROM grac_practice.location_type_master;
SELECT 'hosting_type_master' TableName, COUNT(1) RecordCount FROM grac_practice.dependency_hosting_type_master;
SELECT 'license_type_master' TableName, COUNT(1) RecordCount FROM grac_practice.dependency_license_type_master;
SELECT 'asset_category_master' TableName, COUNT(1) RecordCount FROM grac_practice.dependency_asset_category_master;
SELECT 'service_category_master' TableName, COUNT(1) RecordCount FROM grac_practice.dependency_service_category_master;
SELECT 'security_role' TableName, COUNT(1) RecordCount FROM grac_practice.security_role;
SELECT 'security_permission' TableName, COUNT(1) RecordCount FROM grac_practice.security_permission;
SELECT 'security_role_permission' TableName, COUNT(1) RecordCount FROM grac_practice.security_role_permission;

SELECT menu_key, menu_name, module_type, status
FROM grac_practice.menu_master
WHERE menu_key IN ('resolve','workbench-applications','workbench-tools','workbench-vendors','workbench-assets','workbench-processes','workbench-locations')
ORDER BY display_order;

SELECT assurance_type_code, assurance_type_name, is_active
FROM grac_practice.assurance_type_master
ORDER BY display_order;

SELECT dependency_type_id, dependency_type_name, is_active
FROM grac_practice.dependency_type_master
ORDER BY display_order, dependency_type_id;

SELECT dependency_type_id, source_table_name, id_column_name, display_column_name, organization_filter_column, status_filter_column, status
FROM grac_practice.dependency_type_source_config
ORDER BY dependency_type_id;
GO
