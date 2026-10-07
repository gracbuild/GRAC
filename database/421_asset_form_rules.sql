-- =====================================================================
-- 421  Asset form templates -- option lists, conditional rules, preview
--      (Asset & Contract Management, Phase 2 increment 2)
--
-- REQUEST
-- -------
--   BRD v1.7 sections 5.1.14-5.1.15 (dynamic form and conditional logic),
--   5.2.7 (conditional visibility and mandatory rules) and 5.2.17 (form
--   preview and testing). Continues 420; plan in
--   docs/asset-contract-management.md.
--
-- WHAT THIS DOES
-- --------------
--   1. Option lists. The dictionary's OPTION:<name> lookup sources are
--      served from the existing global reference_option table, group
--      'asset_field.<name>'. 201 values for the 40 lists whose values the
--      BRD enumerates are seeded verbatim (insert-only). Lists the BRD
--      leaves to the organization (building, floor, room, zone, cost
--      centre, network zone, domain, ...) are NOT invented: the readiness
--      report keeps warning until they are configured.
--   2. Dictionary corrections. Ten fields the 420 seed typed as LOOKUP
--      are free-text identifiers in the BRD ("Text / ERP lookup", "Text /
--      job lookup", ...): hardware revision, PO number, finance asset
--      number, BIOS/UEFI version, log source id, import batch id, rack,
--      cabinet/bay, entitlement/SKU, support hours. They become TEXT with
--      no lookup source; definition_version is incremented and the change
--      is written to practice_audit_trace. The CIA rating fields point at
--      CONFIG:CIA_SCALE (served by the CIA configuration, next increment).
--      Only rows still carrying the 420 seed values are touched.
--   3. Conditional rules (5.2.7), per template version:
--        asset_form_template_rule            target field + action
--                                            SHOW | REQUIRE | SHOW_AND_REQUIRE
--        asset_form_template_rule_condition  source field, operator, value,
--                                            group_no (conditions in one
--                                            group are ANDed; groups are ORed)
--      Operators: EQ, NEQ, IN, NOT_IN, EMPTY, NOT_EMPTY, GT, GTE, LT, LTE,
--      DATE_BEFORE_TODAY, DATE_AFTER_TODAY, DATE_WITHIN_DAYS. IN / NOT_IN
--      take a '|'-separated list. A rule cannot target a system-mandatory
--      field (it would weaken it), a field cannot drive itself, and a rule
--      that would close a dependency loop is refused (circular detection).
--   4. sp_asset_form_template_evaluate -- the single evaluation engine.
--      Given sample values it returns each field's effective visible /
--      mandatory state. The Preview tab uses it now; the Asset Register,
--      API and imports will call the same procedure (5.1.14 "imports and
--      APIs execute the same rules").
--   5. Re-issued from 420: sp_asset_form_template_get (adds rules,
--      conditions and option lists), sp_asset_form_template_readiness
--      (adds rule checks and CONFIG:/OPTION: pending warnings),
--      sp_asset_form_template_new_version (copies rules).
--
-- SEMANTICS (documented because the BRD is silent):
--   * A field with one or more active SHOW rules is visible only while at
--     least one of them is true; otherwise its static Visible flag applies.
--   * A field is mandatory when its static flag is set OR any REQUIRE rule
--     is true -- but never while it is hidden (a hidden field cannot be
--     filled; its stored value follows hidden_value_behavior).
--   * Values supplied for a field that is itself hidden still count as
--     inputs to other rules.
--
-- ERROR NUMBERS (continuing 420's 54200-54249):
--   54230 rule would create a circular dependency   54231 invalid rule target
--   54232 invalid rule action                       54233 rule needs a condition
--   54234 condition source not on the template      54235 field cannot drive itself
--   54236 unknown operator                          54237 comparison value required
--   54238 comparison value not a number / days      54239 rule not found
--
-- ALSO EDITED: 272_master_data_seed.sql (option rows; corrected
--   dictionary rows), API (AssetConfigService/Controller/Models), Web
--   proxy, asset-form-templates.cshtml / .js.
-- DEPENDS ON: 420.
-- Rollback: 421_asset_form_rules_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.asset_form_template','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_form_template_field','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_field_definition','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_form_template_assert_editable','P') IS NULL
   OR COL_LENGTH('grac_practice.asset_form_template','is_working_version') IS NULL
   OR COL_LENGTH('grac_practice.asset_form_template_field','hidden_value_behavior') IS NULL
   OR OBJECT_ID('grac_practice.reference_option','U') IS NULL
BEGIN
    RAISERROR('ABORT (421): run 420_asset_form_templates.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Option lists (BRD-enumerated values only)
-- =====================================================================
MERGE grac_practice.reference_option AS t
USING (VALUES
    (N'asset_field.record_source', N'MANUAL', N'Manual', 10),
    (N'asset_field.record_source', N'IMPORT', N'Import', 20),
    (N'asset_field.record_source', N'DISCOVERY', N'Discovery', 30),
    (N'asset_field.record_source', N'ERP', N'ERP', 40),
    (N'asset_field.record_source', N'API', N'API', 50),
    (N'asset_field.location_type', N'PHYSICAL', N'Physical', 10),
    (N'asset_field.location_type', N'VIRTUAL', N'Virtual', 20),
    (N'asset_field.location_type', N'MOBILE', N'Mobile', 30),
    (N'asset_field.location_type', N'CLOUD', N'Cloud', 40),
    (N'asset_field.mobility_status', N'FIXED', N'Fixed', 10),
    (N'asset_field.mobility_status', N'PORTABLE', N'Portable', 20),
    (N'asset_field.mobility_status', N'MOBILE', N'Mobile', 30),
    (N'asset_field.mobility_status', N'POOL', N'Pool', 40),
    (N'asset_field.mobility_status', N'TEMPORARILY_ASSIGNED', N'Temporarily Assigned', 50),
    (N'asset_field.acquisition_method', N'PURCHASE', N'Purchase', 10),
    (N'asset_field.acquisition_method', N'LEASE', N'Lease', 20),
    (N'asset_field.acquisition_method', N'RENTAL', N'Rental', 30),
    (N'asset_field.acquisition_method', N'DONATION', N'Donation', 40),
    (N'asset_field.acquisition_method', N'TRANSFER', N'Transfer', 50),
    (N'asset_field.acquisition_method', N'SUBSCRIPTION', N'Subscription', 60),
    (N'asset_field.capex_opex', N'CAPEX', N'CapEx', 10),
    (N'asset_field.capex_opex', N'OPEX', N'OpEx', 20),
    (N'asset_field.yes_no_unknown', N'YES', N'Yes', 10),
    (N'asset_field.yes_no_unknown', N'NO', N'No', 20),
    (N'asset_field.yes_no_unknown', N'UNKNOWN', N'Unknown', 30),
    (N'asset_field.yes_no_assessment', N'YES', N'Yes', 10),
    (N'asset_field.yes_no_assessment', N'NO', N'No', 20),
    (N'asset_field.yes_no_assessment', N'UNDER_ASSESSMENT', N'Under Assessment', 30),
    (N'asset_field.yes_no_partial', N'YES', N'Yes', 10),
    (N'asset_field.yes_no_partial', N'NO', N'No', 20),
    (N'asset_field.yes_no_partial', N'PARTIALLY', N'Partially', 30),
    (N'asset_field.environmental_impact', N'ENERGY', N'Energy', 10),
    (N'asset_field.environmental_impact', N'EMISSIONS', N'Emissions', 20),
    (N'asset_field.environmental_impact', N'WASTE', N'Waste', 30),
    (N'asset_field.environmental_impact', N'SPILL', N'Spill', 40),
    (N'asset_field.environmental_impact', N'RESOURCE', N'Resource', 50),
    (N'asset_field.encryption_status', N'ENABLED', N'Enabled', 10),
    (N'asset_field.encryption_status', N'PARTIAL', N'Partial', 20),
    (N'asset_field.encryption_status', N'DISABLED', N'Disabled', 30),
    (N'asset_field.encryption_status', N'UNKNOWN', N'Unknown', 40),
    (N'asset_field.encryption_method', N'DISK', N'Disk', 10),
    (N'asset_field.encryption_method', N'FILE', N'File', 20),
    (N'asset_field.encryption_method', N'DATABASE', N'Database', 30),
    (N'asset_field.encryption_method', N'APPLICATION', N'Application', 40),
    (N'asset_field.encryption_method', N'TRANSPORT', N'Transport', 50),
    (N'asset_field.backup_status', N'SUCCESS', N'Success', 10),
    (N'asset_field.backup_status', N'FAILURE', N'Failure', 20),
    (N'asset_field.backup_status', N'NOT_CONFIGURED', N'Not Configured', 30),
    (N'asset_field.backup_status', N'UNKNOWN', N'Unknown', 40),
    (N'asset_field.remote_access_method', N'VPN', N'VPN', 10),
    (N'asset_field.remote_access_method', N'ZTNA', N'ZTNA', 20),
    (N'asset_field.remote_access_method', N'RDP_GATEWAY', N'RDP Gateway', 30),
    (N'asset_field.remote_access_method', N'VENDOR_TUNNEL', N'Vendor Tunnel', 40),
    (N'asset_field.remote_access_method', N'OTHER', N'Other', 50),
    (N'asset_field.calibration_basis', N'SCHEDULED_DATE', N'Scheduled Date', 10),
    (N'asset_field.calibration_basis', N'APPROVED_COMPLETION_DATE', N'Approved Completion Date', 20),
    (N'asset_field.calibration_basis', N'USAGE', N'Usage', 30),
    (N'asset_field.calibration_basis', N'MANUFACTURER', N'Manufacturer', 40),
    (N'asset_field.maintenance_basis', N'CALENDAR', N'Calendar', 10),
    (N'asset_field.maintenance_basis', N'COMPLETION_DATE', N'Completion Date', 20),
    (N'asset_field.maintenance_basis', N'USAGE', N'Usage', 30),
    (N'asset_field.maintenance_basis', N'RUN_HOURS', N'Run-hours', 40),
    (N'asset_field.maintenance_basis', N'MANUFACTURER', N'Manufacturer', 50),
    (N'asset_field.usage_meter_type', N'ODOMETER', N'Odometer', 10),
    (N'asset_field.usage_meter_type', N'RUN_HOURS', N'Run-hours', 20),
    (N'asset_field.usage_meter_type', N'CYCLES', N'Cycles', 30),
    (N'asset_field.usage_meter_type', N'PRODUCTION_QUANTITY', N'Production Quantity', 40),
    (N'asset_field.patient_use_classification', N'DIRECT_PATIENT_USE', N'Direct Patient Use', 10),
    (N'asset_field.patient_use_classification', N'DIAGNOSTIC', N'Diagnostic', 20),
    (N'asset_field.patient_use_classification', N'MONITORING', N'Monitoring', 30),
    (N'asset_field.patient_use_classification', N'THERAPEUTIC', N'Therapeutic', 40),
    (N'asset_field.patient_use_classification', N'SUPPORT', N'Support', 50),
    (N'asset_field.patient_safety_classification', N'CRITICAL', N'Critical', 10),
    (N'asset_field.patient_safety_classification', N'HIGH', N'High', 20),
    (N'asset_field.patient_safety_classification', N'MEDIUM', N'Medium', 30),
    (N'asset_field.patient_safety_classification', N'LOW', N'Low', 40),
    (N'asset_field.medical_gas_connection', N'OXYGEN', N'Oxygen', 10),
    (N'asset_field.medical_gas_connection', N'AIR', N'Air', 20),
    (N'asset_field.medical_gas_connection', N'VACUUM', N'Vacuum', 30),
    (N'asset_field.medical_gas_connection', N'OTHER', N'Other', 40),
    (N'asset_field.validation_status', N'NOT_VALIDATED', N'Not Validated', 10),
    (N'asset_field.validation_status', N'VALID', N'Valid', 20),
    (N'asset_field.validation_status', N'DUE', N'Due', 30),
    (N'asset_field.validation_status', N'FAILED', N'Failed', 40),
    (N'asset_field.validation_status', N'CONDITIONAL', N'Conditional', 50),
    (N'asset_field.recall_status', N'NONE', N'None', 10),
    (N'asset_field.recall_status', N'UNDER_REVIEW', N'Under Review', 20),
    (N'asset_field.recall_status', N'RECALLED', N'Recalled', 30),
    (N'asset_field.recall_status', N'CORRECTIVE_ACTION', N'Corrective Action', 40),
    (N'asset_field.recall_status', N'CLOSED', N'Closed', 50),
    (N'asset_field.fuel_type', N'PETROL', N'Petrol', 10),
    (N'asset_field.fuel_type', N'DIESEL', N'Diesel', 20),
    (N'asset_field.fuel_type', N'ELECTRIC', N'Electric', 30),
    (N'asset_field.fuel_type', N'HYBRID', N'Hybrid', 40),
    (N'asset_field.fuel_type', N'GAS', N'Gas', 50),
    (N'asset_field.fuel_type', N'OTHER', N'Other', 60),
    (N'asset_field.odometer_unit', N'KM', N'km', 10),
    (N'asset_field.odometer_unit', N'MILES', N'miles', 20),
    (N'asset_field.privacy_assessment_status', N'NOT_ASSESSED', N'Not Assessed', 10),
    (N'asset_field.privacy_assessment_status', N'PENDING', N'Pending', 20),
    (N'asset_field.privacy_assessment_status', N'APPROVED', N'Approved', 30),
    (N'asset_field.privacy_assessment_status', N'CONDITIONAL', N'Conditional', 40),
    (N'asset_field.privacy_assessment_status', N'NON_COMPLIANT', N'Non-Compliant', 50),
    (N'asset_field.personal_data_categories', N'NAME', N'Name', 10),
    (N'asset_field.personal_data_categories', N'CONTACT', N'Contact', 20),
    (N'asset_field.personal_data_categories', N'IDENTIFIER', N'Identifier', 30),
    (N'asset_field.personal_data_categories', N'FINANCIAL', N'Financial', 40),
    (N'asset_field.personal_data_categories', N'HEALTH', N'Health', 50),
    (N'asset_field.personal_data_categories', N'BIOMETRIC', N'Biometric', 60),
    (N'asset_field.personal_data_categories', N'LOCATION', N'Location', 70),
    (N'asset_field.data_subject_categories', N'EMPLOYEES', N'Employees', 10),
    (N'asset_field.data_subject_categories', N'CUSTOMERS', N'Customers', 20),
    (N'asset_field.data_subject_categories', N'PATIENTS', N'Patients', 30),
    (N'asset_field.data_subject_categories', N'VENDORS', N'Vendors', 40),
    (N'asset_field.data_subject_categories', N'VISITORS', N'Visitors', 50),
    (N'asset_field.data_subject_categories', N'CHILDREN', N'Children', 60),
    (N'asset_field.data_subject_categories', N'OTHER', N'Other', 70),
    (N'asset_field.processing_operations', N'STORE', N'Store', 10),
    (N'asset_field.processing_operations', N'PROCESS', N'Process', 20),
    (N'asset_field.processing_operations', N'RECEIVE', N'Receive', 30),
    (N'asset_field.processing_operations', N'GENERATE', N'Generate', 40),
    (N'asset_field.processing_operations', N'DISPLAY', N'Display', 50),
    (N'asset_field.processing_operations', N'TRANSMIT', N'Transmit', 60),
    (N'asset_field.processing_operations', N'BACK_UP', N'Back Up', 70),
    (N'asset_field.processing_operations', N'DELETE', N'Delete', 80),
    (N'asset_field.dpia_pia_status', N'NOT_STARTED', N'Not Started', 10),
    (N'asset_field.dpia_pia_status', N'IN_PROGRESS', N'In Progress', 20),
    (N'asset_field.dpia_pia_status', N'APPROVED', N'Approved', 30),
    (N'asset_field.dpia_pia_status', N'REJECTED', N'Rejected', 40),
    (N'asset_field.dpia_pia_status', N'EXPIRED', N'Expired', 50),
    (N'asset_field.masking_method', N'STATIC', N'Static', 10),
    (N'asset_field.masking_method', N'DYNAMIC', N'Dynamic', 20),
    (N'asset_field.masking_method', N'TOKENIZATION', N'Tokenization', 30),
    (N'asset_field.masking_method', N'PSEUDONYMIZATION', N'Pseudonymization', 40),
    (N'asset_field.masking_method', N'ANONYMIZATION', N'Anonymization', 50),
    (N'asset_field.masking_method', N'PARTIAL_MASK', N'Partial Mask', 60),
    (N'asset_field.masking_method', N'REDACTION', N'Redaction', 70),
    (N'asset_field.masking_method', N'OBFUSCATION', N'Obfuscation', 80),
    (N'asset_field.masking_method', N'ENCRYPTION_BASED', N'Encryption-based', 90),
    (N'asset_field.masking_method', N'CUSTOM', N'Custom', 100),
    (N'asset_field.masking_coverage', N'PRODUCTION', N'Production', 10),
    (N'asset_field.masking_coverage', N'NON_PRODUCTION', N'Non-production', 20),
    (N'asset_field.masking_coverage', N'REPORTS', N'Reports', 30),
    (N'asset_field.masking_coverage', N'EXPORTS', N'Exports', 40),
    (N'asset_field.masking_coverage', N'LOGS', N'Logs', 50),
    (N'asset_field.masking_coverage', N'BACKUPS', N'Backups', 60),
    (N'asset_field.retention_trigger', N'CREATION', N'Creation', 10),
    (N'asset_field.retention_trigger', N'CLOSURE', N'Closure', 20),
    (N'asset_field.retention_trigger', N'EMPLOYMENT_END', N'Employment End', 30),
    (N'asset_field.retention_trigger', N'CONTRACT_END', N'Contract End', 40),
    (N'asset_field.retention_trigger', N'LAST_ACTIVITY', N'Last Activity', 50),
    (N'asset_field.coverage_type', N'WARRANTY', N'Warranty', 10),
    (N'asset_field.coverage_type', N'AMC', N'AMC', 20),
    (N'asset_field.coverage_type', N'CMC', N'CMC', 30),
    (N'asset_field.coverage_type', N'LICENCE', N'Licence', 40),
    (N'asset_field.coverage_type', N'INSURANCE', N'Insurance', 50),
    (N'asset_field.coverage_type', N'CALIBRATION', N'Calibration', 60),
    (N'asset_field.coverage_type', N'MANAGED_SERVICE', N'Managed Service', 70),
    (N'asset_field.coverage_type', N'CUSTOM', N'Custom', 80),
    (N'asset_field.decommission_reason', N'OBSOLETE', N'Obsolete', 10),
    (N'asset_field.decommission_reason', N'UNSUPPORTED', N'Unsupported', 20),
    (N'asset_field.decommission_reason', N'DAMAGED', N'Damaged', 30),
    (N'asset_field.decommission_reason', N'REPLACED', N'Replaced', 40),
    (N'asset_field.decommission_reason', N'LOST', N'Lost', 50),
    (N'asset_field.decommission_reason', N'SOLD', N'Sold', 60),
    (N'asset_field.data_backup_retention_decision', N'RETAIN', N'Retain', 10),
    (N'asset_field.data_backup_retention_decision', N'MIGRATE', N'Migrate', 20),
    (N'asset_field.data_backup_retention_decision', N'ARCHIVE', N'Archive', 30),
    (N'asset_field.data_backup_retention_decision', N'DELETE', N'Delete', 40),
    (N'asset_field.data_backup_retention_decision', N'NOT_APPLICABLE', N'Not Applicable', 50),
    (N'asset_field.sanitization_method', N'CLEAR', N'Clear', 10),
    (N'asset_field.sanitization_method', N'PURGE', N'Purge', 20),
    (N'asset_field.sanitization_method', N'CRYPTOGRAPHIC_ERASE', N'Cryptographic Erase', 30),
    (N'asset_field.sanitization_method', N'DEGAUSS', N'Degauss', 40),
    (N'asset_field.sanitization_method', N'PHYSICAL_DESTRUCTION', N'Physical Destruction', 50),
    (N'asset_field.disposal_method', N'RETURN', N'Return', 10),
    (N'asset_field.disposal_method', N'RESALE', N'Resale', 20),
    (N'asset_field.disposal_method', N'DONATION', N'Donation', 30),
    (N'asset_field.disposal_method', N'RECYCLE', N'Recycle', 40),
    (N'asset_field.disposal_method', N'SCRAP', N'Scrap', 50),
    (N'asset_field.disposal_method', N'DESTROY', N'Destroy', 60),
    (N'asset_field.disposal_method', N'TRANSFER', N'Transfer', 70),
    (N'asset_field.approval_status', N'DRAFT', N'Draft', 10),
    (N'asset_field.approval_status', N'SUBMITTED', N'Submitted', 20),
    (N'asset_field.approval_status', N'PENDING_APPROVAL', N'Pending Approval', 30),
    (N'asset_field.approval_status', N'APPROVED', N'Approved', 40),
    (N'asset_field.approval_status', N'REJECTED', N'Rejected', 50),
    (N'asset_field.approval_status', N'RETURNED', N'Returned', 60),
    (N'asset_field.data_confidence', N'VERIFIED', N'Verified', 10),
    (N'asset_field.data_confidence', N'PROBABLE', N'Probable', 20),
    (N'asset_field.data_confidence', N'UNVERIFIED', N'Unverified', 30),
    (N'asset_field.data_confidence', N'STALE', N'Stale', 40),
    (N'asset_field.data_confidence', N'CONFLICTING', N'Conflicting', 50),
    (N'asset_field.sync_status', N'NOT_APPLICABLE', N'Not Applicable', 10),
    (N'asset_field.sync_status', N'PENDING', N'Pending', 20),
    (N'asset_field.sync_status', N'SYNCHRONIZED', N'Synchronized', 30),
    (N'asset_field.sync_status', N'WARNING', N'Warning', 40),
    (N'asset_field.sync_status', N'FAILED', N'Failed', 50),
    (N'asset_field.asset_valuation_method', N'MAXIMUM', N'Maximum', 10),
    (N'asset_field.asset_valuation_method', N'WEIGHTED_AVERAGE', N'Weighted Average', 20),
    (N'asset_field.asset_valuation_method', N'SUMMATION', N'Summation', 30)
) AS s(option_group, option_value, option_label, display_order)
ON t.option_group = s.option_group AND t.option_value = s.option_value
WHEN NOT MATCHED BY TARGET THEN
    INSERT (option_group, option_value, option_label, display_order, status, entered_by)
    VALUES (s.option_group, s.option_value, s.option_label, s.display_order, N'Active', N'seed-421');
PRINT CONCAT('421: asset option values inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 2. Dictionary corrections (only rows still holding the 420 seed value)
-- =====================================================================
DECLARE @fix TABLE (field_key NVARCHAR(100) PRIMARY KEY, new_type NVARCHAR(30) NOT NULL, new_source NVARCHAR(100) NULL, old_source NVARCHAR(100) NULL);
INSERT @fix (field_key, new_type, new_source, old_source) VALUES
    (N'hardware_revision',                N'TEXT',   NULL,                N'OPTION:hardware_revision'),
    (N'purchase_order_number',            N'TEXT',   NULL,                N'OPTION:purchase_order_number'),
    (N'finance_asset_number',             N'TEXT',   NULL,                N'OPTION:finance_asset_number'),
    (N'bios_uefi_version',                N'TEXT',   NULL,                N'OPTION:bios_uefi_version'),
    (N'log_source_monitoring_identifier', N'TEXT',   NULL,                N'OPTION:log_source_monitoring_identifier'),
    (N'import_batch_job_id',              N'TEXT',   NULL,                N'OPTION:import_batch_job_id'),
    (N'rack',                             N'TEXT',   NULL,                N'OPTION:rack'),
    (N'cabinet_bay',                      N'TEXT',   NULL,                N'OPTION:cabinet_bay'),
    (N'entitlement_sku',                  N'TEXT',   NULL,                N'OPTION:entitlement_sku'),
    (N'support_hours',                    N'TEXT',   NULL,                N'OPTION:support_hours'),
    (N'confidentiality_rating',           N'LOOKUP', N'CONFIG:CIA_SCALE', N'OPTION:confidentiality_rating'),
    (N'integrity_rating',                 N'LOOKUP', N'CONFIG:CIA_SCALE', N'OPTION:integrity_rating'),
    (N'availability_rating',              N'LOOKUP', N'CONFIG:CIA_SCALE', N'OPTION:availability_rating');

DECLARE @changed TABLE (field_definition_id INT, field_key NVARCHAR(100), old_type NVARCHAR(30), old_source NVARCHAR(100),
                        new_type NVARCHAR(30), new_source NVARCHAR(100), new_version INT);
UPDATE d
   SET data_type_code = f.new_type, lookup_source = f.new_source,
       definition_version = d.definition_version + 1,
       updated_by = N'seed-421', updated_dt = SYSUTCDATETIME()
OUTPUT inserted.field_definition_id, inserted.field_key, deleted.data_type_code, deleted.lookup_source,
       inserted.data_type_code, inserted.lookup_source, inserted.definition_version
  INTO @changed
  FROM grac_practice.asset_field_definition d
  JOIN @fix f ON f.field_key = d.field_key
 WHERE ISNULL(d.lookup_source, N'') = ISNULL(f.old_source, N'');

INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
SELECT N'asset-field-definition', c.field_definition_id, N'DEFINITION_CORRECTED',
       (SELECT c.old_type AS dataTypeCode, c.old_source AS lookupSource FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       (SELECT c.new_type AS dataTypeCode, c.new_source AS lookupSource, c.new_version AS definitionVersion,
               N'421: BRD types this field as a free-text identifier / CIA scale value' AS reason
           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       N'Active', N'seed-421'
  FROM @changed c;
-- PRINT accepts scalar expressions only (Msg 1046 on a subquery), so the
-- count goes through a variable.
DECLARE @corrected_count INT = (SELECT COUNT(*) FROM @changed);
PRINT CONCAT('421: dictionary definitions corrected: ', @corrected_count);
GO

-- =====================================================================
-- 3. Rule tables
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_form_template_rule','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_form_template_rule (
        rule_id                    BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_form_rule PRIMARY KEY,
        template_id                BIGINT        NOT NULL
            CONSTRAINT fk_pm_asset_form_rule_template REFERENCES grac_practice.asset_form_template(template_id),
        rule_name                  NVARCHAR(200) NOT NULL,
        target_field_definition_id INT           NOT NULL
            CONSTRAINT fk_pm_asset_form_rule_target REFERENCES grac_practice.asset_field_definition(field_definition_id),
        action_code                NVARCHAR(20)  NOT NULL
            CONSTRAINT ck_pm_asset_form_rule_action CHECK (action_code IN (N'SHOW', N'REQUIRE', N'SHOW_AND_REQUIRE')),
        display_order              INT           NOT NULL CONSTRAINT df_pm_asset_form_rule_order DEFAULT 0,
        is_active                  BIT           NOT NULL CONSTRAINT df_pm_asset_form_rule_active DEFAULT 1,
        entered_by                 NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_form_rule_eby DEFAULT N'system',
        entered_dt                 DATETIME2     NOT NULL CONSTRAINT df_pm_asset_form_rule_edt DEFAULT SYSUTCDATETIME(),
        updated_by                 NVARCHAR(100) NULL,
        updated_dt                 DATETIME2     NULL
    );
    CREATE INDEX ix_pm_asset_form_rule_template ON grac_practice.asset_form_template_rule(template_id, target_field_definition_id);
    PRINT '421: asset_form_template_rule created.';
END
GO

IF OBJECT_ID('grac_practice.asset_form_template_rule_condition','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_form_template_rule_condition (
        condition_id               BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_form_rule_cond PRIMARY KEY,
        rule_id                    BIGINT        NOT NULL
            CONSTRAINT fk_pm_asset_form_rule_cond_rule REFERENCES grac_practice.asset_form_template_rule(rule_id) ON DELETE CASCADE,
        group_no                   INT           NOT NULL CONSTRAINT df_pm_asset_form_rule_cond_grp DEFAULT 1,
        source_field_definition_id INT           NOT NULL
            CONSTRAINT fk_pm_asset_form_rule_cond_src REFERENCES grac_practice.asset_field_definition(field_definition_id),
        operator_code              NVARCHAR(30)  NOT NULL
            CONSTRAINT ck_pm_asset_form_rule_cond_op CHECK (operator_code IN (N'EQ', N'NEQ', N'IN', N'NOT_IN', N'EMPTY', N'NOT_EMPTY',
                N'GT', N'GTE', N'LT', N'LTE', N'DATE_BEFORE_TODAY', N'DATE_AFTER_TODAY', N'DATE_WITHIN_DAYS')),
        compare_value              NVARCHAR(400) NULL,
        display_order              INT           NOT NULL CONSTRAINT df_pm_asset_form_rule_cond_order DEFAULT 0
    );
    CREATE INDEX ix_pm_asset_form_rule_cond_rule ON grac_practice.asset_form_template_rule_condition(rule_id, group_no);
    PRINT '421: asset_form_template_rule_condition created.';
END
GO

-- =====================================================================
-- 4. Rule writers
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_rule_save
    @organization_id            BIGINT,
    @template_id                BIGINT,
    @rule_id                    BIGINT        = NULL,
    @rule_name                  NVARCHAR(200),
    @target_field_definition_id INT,
    @action_code                NVARCHAR(20),
    @conditions_json            NVARCHAR(MAX),
    @is_active                  BIT           = 1,
    @display_order              INT           = NULL,
    @actor                      NVARCHAR(100) = N'system',
    @out_rule_id                BIGINT        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @rule_name = NULLIF(LTRIM(RTRIM(@rule_name)), N'');
    SET @action_code = UPPER(LTRIM(RTRIM(ISNULL(@action_code, N''))));
    SET @is_active = ISNULL(@is_active, 1);

    EXEC grac_practice.sp_asset_form_template_assert_editable
         @organization_id = @organization_id, @template_id = @template_id;

    IF @rule_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.asset_form_template_rule WHERE rule_id = @rule_id AND template_id = @template_id)
        THROW 54239, 'Rule not found on this template.', 1;
    IF @action_code NOT IN (N'SHOW', N'REQUIRE', N'SHOW_AND_REQUIRE')
        THROW 54232, 'Choose what the rule does: show, require, or show and require.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template_field
                    WHERE template_id = @template_id AND field_definition_id = @target_field_definition_id)
        THROW 54231, 'The rule target must be a field on this template.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_field_definition
                WHERE field_definition_id = @target_field_definition_id AND is_system_mandatory = 1)
        THROW 54231, 'A rule cannot target a system-mandatory field; it is always visible and mandatory.', 1;

    IF @rule_name IS NULL
        SELECT @rule_name = CONCAT(CASE @action_code WHEN N'SHOW' THEN N'Show ' WHEN N'REQUIRE' THEN N'Require ' ELSE N'Show and require ' END,
                                   display_label)
          FROM grac_practice.asset_field_definition WHERE field_definition_id = @target_field_definition_id;

    DECLARE @cond TABLE (group_no INT NOT NULL, source_field_definition_id INT NULL, operator_code NVARCHAR(30) NULL,
                         compare_value NVARCHAR(400) NULL, display_order INT NOT NULL);
    IF ISJSON(ISNULL(@conditions_json, N'')) = 1
        INSERT @cond (group_no, source_field_definition_id, operator_code, compare_value, display_order)
        SELECT ISNULL(TRY_CONVERT(INT, j.groupNo), 1), TRY_CONVERT(INT, j.sourceFieldDefinitionId),
               UPPER(LTRIM(RTRIM(j.operatorCode))), NULLIF(LTRIM(RTRIM(j.compareValue)), N''),
               ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) * 10
          FROM OPENJSON(@conditions_json)
               WITH (groupNo NVARCHAR(20) '$.groupNo', sourceFieldDefinitionId NVARCHAR(20) '$.sourceFieldDefinitionId',
                     operatorCode NVARCHAR(30) '$.operatorCode', compareValue NVARCHAR(400) '$.compareValue') j;

    IF NOT EXISTS (SELECT 1 FROM @cond)
        THROW 54233, 'A rule needs at least one condition.', 1;
    IF EXISTS (SELECT 1 FROM @cond c WHERE c.source_field_definition_id IS NULL
                  OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template_field f
                                  WHERE f.template_id = @template_id AND f.field_definition_id = c.source_field_definition_id))
        THROW 54234, 'Every condition must test a field that is on this template.', 1;
    IF EXISTS (SELECT 1 FROM @cond WHERE source_field_definition_id = @target_field_definition_id)
        THROW 54235, 'A field cannot control its own visibility or requirement.', 1;
    IF EXISTS (SELECT 1 FROM @cond WHERE ISNULL(operator_code, N'') NOT IN (N'EQ', N'NEQ', N'IN', N'NOT_IN', N'EMPTY', N'NOT_EMPTY',
                N'GT', N'GTE', N'LT', N'LTE', N'DATE_BEFORE_TODAY', N'DATE_AFTER_TODAY', N'DATE_WITHIN_DAYS'))
        THROW 54236, 'Unknown comparison operator.', 1;
    IF EXISTS (SELECT 1 FROM @cond WHERE compare_value IS NULL
                AND operator_code NOT IN (N'EMPTY', N'NOT_EMPTY', N'DATE_BEFORE_TODAY', N'DATE_AFTER_TODAY'))
        THROW 54237, 'Enter the value to compare against.', 1;
    IF EXISTS (SELECT 1 FROM @cond WHERE operator_code IN (N'GT', N'GTE', N'LT', N'LTE')
                AND TRY_CONVERT(DECIMAL(38, 6), compare_value) IS NULL)
        THROW 54238, 'Greater-than / less-than comparisons need a number.', 1;
    IF EXISTS (SELECT 1 FROM @cond WHERE operator_code = N'DATE_WITHIN_DAYS'
                AND (TRY_CONVERT(INT, compare_value) IS NULL OR TRY_CONVERT(INT, compare_value) < 0))
        THROW 54238, '"Within days" needs a whole number of days.', 1;

    -- Circular dependency: adding edges source -> target closes a loop when
    -- the target already reaches one of the sources through other rules.
    DECLARE @edges TABLE (source_id INT NOT NULL, target_id INT NOT NULL);
    INSERT @edges (source_id, target_id)
    SELECT DISTINCT c.source_field_definition_id, r.target_field_definition_id
      FROM grac_practice.asset_form_template_rule r
      JOIN grac_practice.asset_form_template_rule_condition c ON c.rule_id = r.rule_id
     WHERE r.template_id = @template_id AND r.is_active = 1
       AND (@rule_id IS NULL OR r.rule_id <> @rule_id);

    IF @is_active = 1
    BEGIN
        DECLARE @reach TABLE (field_id INT PRIMARY KEY);
        DECLARE @added INT = 1, @guard INT = 0;
        INSERT @reach (field_id) VALUES (@target_field_definition_id);
        WHILE @added > 0 AND @guard < 500
        BEGIN
            INSERT @reach (field_id)
            SELECT DISTINCT e.target_id FROM @edges e
              JOIN @reach r ON r.field_id = e.source_id
             WHERE NOT EXISTS (SELECT 1 FROM @reach x WHERE x.field_id = e.target_id);
            SET @added = @@ROWCOUNT;
            SET @guard = @guard + 1;
        END
        IF EXISTS (SELECT 1 FROM @cond c JOIN @reach r ON r.field_id = c.source_field_definition_id)
            THROW 54230, 'This rule would create a circular dependency: the target field already controls one of its own conditions.', 1;
    END

    IF @display_order IS NULL
        SELECT @display_order = ISNULL(MAX(display_order), 0) + 10
          FROM grac_practice.asset_form_template_rule WHERE template_id = @template_id;

    DECLARE @before NVARCHAR(MAX) = CASE WHEN @rule_id IS NULL THEN NULL ELSE (
        SELECT r.rule_name AS ruleName, r.target_field_definition_id AS targetFieldDefinitionId, r.action_code AS actionCode,
               r.is_active AS isActive,
               (SELECT c.group_no AS groupNo, c.source_field_definition_id AS sourceFieldDefinitionId,
                       c.operator_code AS operatorCode, c.compare_value AS compareValue
                  FROM grac_practice.asset_form_template_rule_condition c WHERE c.rule_id = r.rule_id
                 ORDER BY c.group_no, c.display_order FOR JSON PATH) AS conditions
          FROM grac_practice.asset_form_template_rule r WHERE r.rule_id = @rule_id
           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END;

    BEGIN TRAN;
    IF @rule_id IS NULL
    BEGIN
        INSERT grac_practice.asset_form_template_rule
            (template_id, rule_name, target_field_definition_id, action_code, display_order, is_active, entered_by)
        VALUES (@template_id, @rule_name, @target_field_definition_id, @action_code, @display_order, @is_active, @actor);
        SET @out_rule_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_form_template_rule
           SET rule_name = @rule_name, target_field_definition_id = @target_field_definition_id,
               action_code = @action_code, display_order = @display_order, is_active = @is_active,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE rule_id = @rule_id;
        DELETE grac_practice.asset_form_template_rule_condition WHERE rule_id = @rule_id;
        SET @out_rule_id = @rule_id;
    END

    INSERT grac_practice.asset_form_template_rule_condition
        (rule_id, group_no, source_field_definition_id, operator_code, compare_value, display_order)
    SELECT @out_rule_id, group_no, source_field_definition_id, operator_code, compare_value, display_order FROM @cond;

    UPDATE grac_practice.asset_form_template SET updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE template_id = @template_id;

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-form-template', @template_id, CASE WHEN @rule_id IS NULL THEN N'RULE_ADD' ELSE N'RULE_SAVE' END, @before,
            (SELECT @out_rule_id AS ruleId, @rule_name AS ruleName, @target_field_definition_id AS targetFieldDefinitionId,
                    @action_code AS actionCode, @is_active AS isActive, JSON_QUERY(@conditions_json) AS conditions
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @out_rule_id AS RuleId;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_rule_remove
    @organization_id BIGINT,
    @template_id     BIGINT,
    @rule_id         BIGINT,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');

    EXEC grac_practice.sp_asset_form_template_assert_editable
         @organization_id = @organization_id, @template_id = @template_id;

    DECLARE @before NVARCHAR(MAX) = (
        SELECT r.rule_name AS ruleName, r.target_field_definition_id AS targetFieldDefinitionId, r.action_code AS actionCode,
               (SELECT c.group_no AS groupNo, c.source_field_definition_id AS sourceFieldDefinitionId,
                       c.operator_code AS operatorCode, c.compare_value AS compareValue
                  FROM grac_practice.asset_form_template_rule_condition c WHERE c.rule_id = r.rule_id FOR JSON PATH) AS conditions
          FROM grac_practice.asset_form_template_rule r
         WHERE r.rule_id = @rule_id AND r.template_id = @template_id
           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    IF @before IS NULL RETURN;   -- already gone: idempotent

    BEGIN TRAN;
    DELETE grac_practice.asset_form_template_rule WHERE rule_id = @rule_id AND template_id = @template_id;  -- conditions cascade
    UPDATE grac_practice.asset_form_template SET updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE template_id = @template_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-form-template', @template_id, N'RULE_REMOVE', @before,
            (SELECT @rule_id AS ruleId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
    COMMIT;
END
GO

-- Removing a field that a rule uses would leave the rule dangling: the
-- 420 field-remove proc is re-issued with that guard.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_field_remove
    @organization_id     BIGINT,
    @template_id         BIGINT,
    @field_definition_id INT,
    @actor               NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');

    EXEC grac_practice.sp_asset_form_template_assert_editable
         @organization_id = @organization_id, @template_id = @template_id;

    IF EXISTS (SELECT 1 FROM grac_practice.asset_field_definition
                WHERE field_definition_id = @field_definition_id AND is_system_mandatory = 1)
        THROW 54218, 'A system-mandatory field cannot be removed from a template.', 1;

    IF EXISTS (SELECT 1 FROM grac_practice.asset_form_template_rule r
                WHERE r.template_id = @template_id
                  AND (r.target_field_definition_id = @field_definition_id
                       OR EXISTS (SELECT 1 FROM grac_practice.asset_form_template_rule_condition c
                                   WHERE c.rule_id = r.rule_id AND c.source_field_definition_id = @field_definition_id)))
        THROW 54231, 'A conditional rule uses this field. Remove or change that rule first.', 1;

    DECLARE @before NVARCHAR(MAX) = (
        SELECT section_id AS sectionId, display_order AS displayOrder, is_visible AS isVisible, is_mandatory AS isMandatory
          FROM grac_practice.asset_form_template_field
         WHERE template_id = @template_id AND field_definition_id = @field_definition_id
           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    IF @before IS NULL RETURN;   -- already absent: idempotent

    BEGIN TRAN;
    DELETE grac_practice.asset_form_template_field
     WHERE template_id = @template_id AND field_definition_id = @field_definition_id;
    UPDATE grac_practice.asset_form_template SET updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE template_id = @template_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-form-template', @template_id, N'FIELD_REMOVE', @before,
            (SELECT @field_definition_id AS fieldDefinitionId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
    COMMIT;
END
GO

-- =====================================================================
-- 5. Evaluation engine (5.1.14 / 5.2.17). Read-only.
--    @values_json: {"field_key": "value", ...}; a multi-value field is a
--    JSON array or a '|'-separated string.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_evaluate
    @organization_id BIGINT,
    @template_id     BIGINT,
    @values_json     NVARCHAR(MAX) = N'{}'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template
                    WHERE template_id = @template_id AND organization_id = @organization_id)
        THROW 54202, 'Asset form template not found for this organization.', 1;
    IF ISJSON(ISNULL(@values_json, N'')) <> 1 SET @values_json = N'{}';

    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @raw TABLE (field_key NVARCHAR(100) NOT NULL, val NVARCHAR(MAX) NULL, val_type INT NOT NULL);
    INSERT @raw (field_key, val, val_type)
    SELECT j.[key], j.[value], j.[type] FROM OPENJSON(@values_json) j;

    DECLARE @elem TABLE (field_key NVARCHAR(100) NOT NULL, elem NVARCHAR(400) NOT NULL);
    INSERT @elem (field_key, elem)
    SELECT r.field_key, LEFT(LTRIM(RTRIM(a.[value])), 400)
      FROM @raw r CROSS APPLY OPENJSON(r.val) a
     WHERE r.val_type = 4 AND a.[value] IS NOT NULL AND LTRIM(RTRIM(a.[value])) <> N'';
    INSERT @elem (field_key, elem)
    SELECT r.field_key, LEFT(LTRIM(RTRIM(s.[value])), 400)
      FROM @raw r CROSS APPLY STRING_SPLIT(ISNULL(r.val, N''), N'|') s
     WHERE r.val_type IN (1, 2, 3) AND LTRIM(RTRIM(s.[value])) <> N'';

    -- One row per condition with its outcome.
    DECLARE @cond TABLE (rule_id BIGINT NOT NULL, group_no INT NOT NULL, ok INT NOT NULL);
    INSERT @cond (rule_id, group_no, ok)
    SELECT c.rule_id, c.group_no,
           CASE c.operator_code
             WHEN N'EQ'        THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e WHERE e.field_key = d.field_key AND e.elem = c.compare_value) THEN 1 ELSE 0 END
             WHEN N'NEQ'       THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e WHERE e.field_key = d.field_key AND e.elem = c.compare_value) THEN 0 ELSE 1 END
             WHEN N'IN'        THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e
                                                       JOIN STRING_SPLIT(ISNULL(c.compare_value, N''), N'|') l ON LTRIM(RTRIM(l.[value])) = e.elem
                                                      WHERE e.field_key = d.field_key) THEN 1 ELSE 0 END
             WHEN N'NOT_IN'    THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e
                                                       JOIN STRING_SPLIT(ISNULL(c.compare_value, N''), N'|') l ON LTRIM(RTRIM(l.[value])) = e.elem
                                                      WHERE e.field_key = d.field_key) THEN 0 ELSE 1 END
             WHEN N'EMPTY'     THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e WHERE e.field_key = d.field_key) THEN 0 ELSE 1 END
             WHEN N'NOT_EMPTY' THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e WHERE e.field_key = d.field_key) THEN 1 ELSE 0 END
             WHEN N'GT'  THEN CASE WHEN nv.num >  TRY_CONVERT(DECIMAL(38, 6), c.compare_value) THEN 1 ELSE 0 END
             WHEN N'GTE' THEN CASE WHEN nv.num >= TRY_CONVERT(DECIMAL(38, 6), c.compare_value) THEN 1 ELSE 0 END
             WHEN N'LT'  THEN CASE WHEN nv.num <  TRY_CONVERT(DECIMAL(38, 6), c.compare_value) THEN 1 ELSE 0 END
             WHEN N'LTE' THEN CASE WHEN nv.num <= TRY_CONVERT(DECIMAL(38, 6), c.compare_value) THEN 1 ELSE 0 END
             WHEN N'DATE_BEFORE_TODAY' THEN CASE WHEN nv.dt < @today THEN 1 ELSE 0 END
             WHEN N'DATE_AFTER_TODAY'  THEN CASE WHEN nv.dt > @today THEN 1 ELSE 0 END
             WHEN N'DATE_WITHIN_DAYS'  THEN CASE WHEN nv.dt >= @today
                                                  AND nv.dt <= DATEADD(DAY, ISNULL(TRY_CONVERT(INT, c.compare_value), 0), @today) THEN 1 ELSE 0 END
             ELSE 0 END
      FROM grac_practice.asset_form_template_rule r
      JOIN grac_practice.asset_form_template_rule_condition c ON c.rule_id = r.rule_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = c.source_field_definition_id
      OUTER APPLY (SELECT TOP (1) TRY_CONVERT(DECIMAL(38, 6), e.elem) AS num, TRY_CONVERT(DATE, e.elem) AS dt
                     FROM @elem e WHERE e.field_key = d.field_key) nv
     WHERE r.template_id = @template_id AND r.is_active = 1;

    -- A group holds when all its conditions hold; a rule when any group does.
    DECLARE @group TABLE (rule_id BIGINT NOT NULL, group_no INT NOT NULL, ok INT NOT NULL);
    INSERT @group (rule_id, group_no, ok)
    SELECT rule_id, group_no, MIN(ok) FROM @cond GROUP BY rule_id, group_no;

    DECLARE @rule TABLE (rule_id BIGINT PRIMARY KEY, ok INT NOT NULL);
    INSERT @rule (rule_id, ok)
    SELECT rule_id, MAX(ok) FROM @group GROUP BY rule_id;

    DECLARE @state TABLE (field_definition_id INT PRIMARY KEY, has_show INT NOT NULL, show_ok INT NOT NULL, require_ok INT NOT NULL,
                          fired NVARCHAR(MAX) NULL);
    INSERT @state (field_definition_id, has_show, show_ok, require_ok, fired)
    SELECT r.target_field_definition_id,
           MAX(CASE WHEN r.action_code IN (N'SHOW', N'SHOW_AND_REQUIRE') THEN 1 ELSE 0 END),
           MAX(CASE WHEN r.action_code IN (N'SHOW', N'SHOW_AND_REQUIRE') THEN x.ok ELSE 0 END),
           MAX(CASE WHEN r.action_code IN (N'REQUIRE', N'SHOW_AND_REQUIRE') THEN x.ok ELSE 0 END),
           STRING_AGG(CASE WHEN x.ok = 1 THEN r.rule_name END, N'; ')
      FROM grac_practice.asset_form_template_rule r
      JOIN @rule x ON x.rule_id = r.rule_id
     WHERE r.template_id = @template_id AND r.is_active = 1
     GROUP BY r.target_field_definition_id;

    SELECT f.field_definition_id AS FieldDefinitionId, d.field_key AS FieldKey, d.display_label AS DisplayLabel,
           f.section_id AS SectionId,
           eff.is_visible AS IsVisible,
           CASE WHEN eff.is_visible = 1 AND (f.is_mandatory = 1 OR ISNULL(s.require_ok, 0) = 1) THEN 1 ELSE 0 END AS IsMandatory,
           CASE WHEN ISNULL(s.has_show, 0) = 1 THEN 1 ELSE 0 END AS VisibilityByRule,
           s.fired AS RulesFired,
           CASE WHEN EXISTS (SELECT 1 FROM @raw v WHERE v.field_key = d.field_key) THEN 1 ELSE 0 END AS ValueSupplied
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      JOIN grac_practice.asset_form_template_section x ON x.section_id = f.section_id
      LEFT JOIN @state s ON s.field_definition_id = f.field_definition_id
      CROSS APPLY (SELECT CASE WHEN ISNULL(s.has_show, 0) = 1 THEN s.show_ok ELSE CAST(f.is_visible AS INT) END AS is_visible) eff
     WHERE f.template_id = @template_id
     ORDER BY x.display_order, f.display_order;
END
GO

-- =====================================================================
-- 6. Re-issued from 420 (rules, conditions, option lists, rule checks,
--    rules copied into new versions). Bodies otherwise identical to 420.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_get
    @organization_id BIGINT,
    @template_id     BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Header (empty when the template is not this organization's).
    SELECT t.template_id AS TemplateId, t.organization_id AS OrganizationId,
           t.asset_type_id AS AssetTypeId, at.asset_type_name AS AssetTypeName,
           sc.subcategory_name AS SubcategoryName, ac.asset_category_name AS CategoryName,
           t.template_name AS TemplateName, t.version_no AS VersionNo,
           s.status_code AS StatusCode, s.status_name AS StatusName,
           t.approval_required AS ApprovalRequired,
           t.template_owner_employee_id AS TemplateOwnerEmployeeId, o.employee_name AS TemplateOwnerName,
           t.effective_from AS EffectiveFrom, t.effective_to AS EffectiveTo,
           t.change_reason AS ChangeReason, t.source_template_id AS SourceTemplateId,
           src.version_no AS SourceVersionNo,
           t.submitted_by AS SubmittedBy, t.submitted_dt AS SubmittedDt,
           t.approved_by AS ApprovedBy, t.approved_dt AS ApprovedDt,
           t.activated_by AS ActivatedBy, t.activated_dt AS ActivatedDt, t.retired_dt AS RetiredDt,
           CONVERT(BIGINT, t.record_version) AS RecordVersion,
           t.entered_by AS EnteredBy, t.entered_dt AS EnteredDt, t.updated_by AS UpdatedBy, t.updated_dt AS UpdatedDt
      FROM grac_practice.asset_form_template t
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
      JOIN grac_practice.dependency_asset_type_master at ON at.asset_type_id = t.asset_type_id
      JOIN grac_practice.dependency_asset_subcategory_master sc ON sc.subcategory_id = at.subcategory_id
      JOIN grac_practice.dependency_asset_category_master ac ON ac.asset_category_id = sc.asset_category_id
      LEFT JOIN grac_practice.organization_employee o ON o.employee_id = t.template_owner_employee_id
      LEFT JOIN grac_practice.asset_form_template src ON src.template_id = t.source_template_id
     WHERE t.template_id = @template_id AND t.organization_id = @organization_id;

    -- 2. Sections.
    SELECT x.section_id AS SectionId, x.section_key AS SectionKey, x.section_label AS SectionLabel,
           x.tab_label AS TabLabel, x.layout_columns AS LayoutColumns, x.display_order AS DisplayOrder,
           x.is_system AS IsSystem, x.is_active AS IsActive,
           (SELECT COUNT(*) FROM grac_practice.asset_form_template_field f WHERE f.section_id = x.section_id) AS FieldCount
      FROM grac_practice.asset_form_template_section x
      JOIN grac_practice.asset_form_template t ON t.template_id = x.template_id
     WHERE x.template_id = @template_id AND t.organization_id = @organization_id
     ORDER BY x.display_order, x.section_label;

    -- 3. Fields, with their dictionary definition.
    SELECT f.template_field_id AS TemplateFieldId, f.field_definition_id AS FieldDefinitionId,
           d.field_key AS FieldKey, d.display_label AS DisplayLabel, g.group_code AS GroupCode, g.group_name AS GroupName,
           d.data_type_code AS DataTypeCode, d.lookup_source AS LookupSource, d.storage_kind AS StorageKind,
           d.is_system_mandatory AS IsSystemMandatory, d.sensitivity_code AS BaselineSensitivity,
           d.status_code AS DefinitionStatus,
           f.section_id AS SectionId, f.display_order AS DisplayOrder,
           f.is_visible AS IsVisible, f.is_mandatory AS IsMandatory, f.is_read_only AS IsReadOnly,
           f.default_value AS DefaultValue, f.help_text AS HelpText, f.placeholder_text AS PlaceholderText,
           f.hidden_value_behavior AS HiddenValueBehavior, f.sensitivity_override AS SensitivityOverride,
           f.include_in_import_export AS IncludeInImportExport, f.is_searchable AS IsSearchable,
           f.evidence_required AS EvidenceRequired
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_form_template t ON t.template_id = f.template_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      JOIN grac_practice.asset_field_group_master g ON g.field_group_id = d.field_group_id
      JOIN grac_practice.asset_form_template_section x ON x.section_id = f.section_id
     WHERE f.template_id = @template_id AND t.organization_id = @organization_id
     ORDER BY x.display_order, f.display_order, d.display_label;

    -- 4. Status history (immutable framework log).
    SELECT l.transition_log_id AS TransitionLogId, fs.status_name AS FromStatus, ts.status_name AS ToStatus,
           l.actor_employee_id AS ActorEmployeeId, e.employee_name AS ActorName,
           l.reason_code AS ReasonCode, l.reason_text AS ReasonText, l.transitioned_at AS TransitionedAt
      FROM grac_practice.entity_state_transition_log l
      JOIN grac_practice.asset_form_template t ON t.template_id = l.entity_id
      LEFT JOIN grac_practice.entity_status_master fs ON fs.entity_status_id = l.from_status_id
      JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = l.to_status_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = l.actor_employee_id
     WHERE l.entity_type = N'AssetFormTemplate' AND l.entity_id = @template_id
       AND t.organization_id = @organization_id
     ORDER BY l.transitioned_at DESC, l.transition_log_id DESC;

    -- 5. Conditional rules (421).
    SELECT r.rule_id AS RuleId, r.rule_name AS RuleName, r.target_field_definition_id AS TargetFieldDefinitionId,
           d.field_key AS TargetFieldKey, d.display_label AS TargetLabel, r.action_code AS ActionCode,
           r.display_order AS DisplayOrder, r.is_active AS IsActive
      FROM grac_practice.asset_form_template_rule r
      JOIN grac_practice.asset_form_template t ON t.template_id = r.template_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = r.target_field_definition_id
     WHERE r.template_id = @template_id AND t.organization_id = @organization_id
     ORDER BY r.display_order, r.rule_id;

    -- 6. Rule conditions (421).
    SELECT c.condition_id AS ConditionId, c.rule_id AS RuleId, c.group_no AS GroupNo,
           c.source_field_definition_id AS SourceFieldDefinitionId, d.field_key AS SourceFieldKey,
           d.display_label AS SourceLabel, c.operator_code AS OperatorCode, c.compare_value AS CompareValue
      FROM grac_practice.asset_form_template_rule_condition c
      JOIN grac_practice.asset_form_template_rule r ON r.rule_id = c.rule_id
      JOIN grac_practice.asset_form_template t ON t.template_id = r.template_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = c.source_field_definition_id
     WHERE r.template_id = @template_id AND t.organization_id = @organization_id
     ORDER BY c.rule_id, c.group_no, c.display_order;

    -- 7. Option values for the template's OPTION: fields (421).
    SELECT d.field_definition_id AS FieldDefinitionId, o.option_value AS OptionValue, o.option_label AS OptionLabel,
           o.display_order AS DisplayOrder
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_form_template t ON t.template_id = f.template_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      JOIN grac_practice.reference_option o
           ON d.lookup_source LIKE N'OPTION:%'
          AND o.option_group = N'asset_field.' + SUBSTRING(d.lookup_source, 8, 100)
          AND o.status = N'Active'
     WHERE f.template_id = @template_id AND t.organization_id = @organization_id
     ORDER BY d.field_definition_id, o.display_order, o.option_label;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_readiness
    @organization_id   BIGINT,
    @template_id       BIGINT,
    @suppress_result   BIT = 0,
    @out_error_count   INT = NULL OUTPUT,
    @out_warning_count INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @issues TABLE (
        check_code NVARCHAR(60)  NOT NULL,
        severity   NVARCHAR(10)  NOT NULL,
        message    NVARCHAR(400) NOT NULL,
        field_key  NVARCHAR(100) NULL);

    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template
                    WHERE template_id = @template_id AND organization_id = @organization_id)
        THROW 54202, 'Asset form template not found for this organization.', 1;

    -- Baseline: every active system-mandatory field present, visible, mandatory.
    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'BASELINE_MISSING', N'ERROR',
           CONCAT(N'System-mandatory field "', d.display_label, N'" is not on the form.'), d.field_key
      FROM grac_practice.asset_field_definition d
     WHERE d.is_system_mandatory = 1 AND d.status_code = N'ACTIVE' AND d.is_system_field = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template_field f
                        WHERE f.template_id = @template_id AND f.field_definition_id = d.field_definition_id);

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'BASELINE_WEAKENED', N'ERROR',
           CONCAT(N'System-mandatory field "', d.display_label, N'" must stay visible and mandatory.'), d.field_key
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
     WHERE f.template_id = @template_id AND d.is_system_mandatory = 1
       AND (f.is_visible = 0 OR f.is_mandatory = 0);

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'RETIRED_DEFINITION', N'ERROR',
           CONCAT(N'Field "', d.display_label, N'" is retired in the dictionary; remove it.'), d.field_key
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
     WHERE f.template_id = @template_id AND d.status_code <> N'ACTIVE';

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'INACTIVE_SECTION', N'ERROR',
           CONCAT(N'Field "', d.display_label, N'" is placed in an inactive section.'), d.field_key
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      JOIN grac_practice.asset_form_template_section x ON x.section_id = f.section_id
     WHERE f.template_id = @template_id AND x.is_active = 0;

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'HIDDEN_MANDATORY', CASE WHEN f.default_value IS NULL THEN N'ERROR' ELSE N'WARNING' END,
           CONCAT(N'Field "', d.display_label, N'" is mandatory but hidden',
                  CASE WHEN f.default_value IS NULL THEN N' and has no default value.' ELSE N'; its default value will be used.' END),
           d.field_key
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
     WHERE f.template_id = @template_id AND f.is_mandatory = 1 AND f.is_visible = 0
       AND d.is_system_mandatory = 0;

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'READONLY_MANDATORY', N'WARNING',
           CONCAT(N'Field "', d.display_label, N'" is mandatory and read-only with no default; users cannot fill it.'), d.field_key
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      JOIN grac_practice.asset_field_data_type_master dt ON dt.data_type_code = d.data_type_code
     WHERE f.template_id = @template_id AND f.is_mandatory = 1 AND f.is_read_only = 1
       AND f.default_value IS NULL AND dt.is_user_entered = 1;

    -- 421: an OPTION: list counts as configured once it has an Active
    -- value; CONFIG: sources are served by configuration screens that
    -- arrive with the CIA / criticality increment.
    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'OPTIONS_PENDING', N'WARNING',
           CONCAT(N'Field "', d.display_label, N'" has no option values configured yet.'), d.field_key
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
     WHERE f.template_id = @template_id AND d.lookup_source LIKE N'OPTION:%'
       AND NOT EXISTS (SELECT 1 FROM grac_practice.reference_option o
                        WHERE o.option_group = N'asset_field.' + SUBSTRING(d.lookup_source, 8, 100) AND o.status = N'Active');

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'CONFIG_PENDING', N'WARNING',
           CONCAT(N'Field "', d.display_label, N'" takes its values from configuration (', d.lookup_source,
                  N') that is delivered in a later increment.'), d.field_key
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
     WHERE f.template_id = @template_id AND d.lookup_source LIKE N'CONFIG:%';

    -- 421: conditional rules.
    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'RULE_TARGET_MISSING', N'ERROR', CONCAT(N'Rule "', r.rule_name, N'" targets a field that is not on the form.'), d.field_key
      FROM grac_practice.asset_form_template_rule r
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = r.target_field_definition_id
     WHERE r.template_id = @template_id AND r.is_active = 1
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template_field f
                        WHERE f.template_id = @template_id AND f.field_definition_id = r.target_field_definition_id);

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'RULE_SOURCE_MISSING', N'ERROR', CONCAT(N'Rule "', r.rule_name, N'" tests "', d.display_label, N'", which is not on the form.'), d.field_key
      FROM grac_practice.asset_form_template_rule r
      JOIN grac_practice.asset_form_template_rule_condition c ON c.rule_id = r.rule_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = c.source_field_definition_id
     WHERE r.template_id = @template_id AND r.is_active = 1
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template_field f
                        WHERE f.template_id = @template_id AND f.field_definition_id = c.source_field_definition_id);

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'RULE_NO_CONDITION', N'ERROR', CONCAT(N'Rule "', r.rule_name, N'" has no conditions.'), NULL
      FROM grac_practice.asset_form_template_rule r
     WHERE r.template_id = @template_id AND r.is_active = 1
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template_rule_condition c WHERE c.rule_id = r.rule_id);

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'RULE_ON_BASELINE', N'ERROR', CONCAT(N'Rule "', r.rule_name, N'" targets a system-mandatory field.'), d.field_key
      FROM grac_practice.asset_form_template_rule r
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = r.target_field_definition_id
     WHERE r.template_id = @template_id AND r.is_active = 1 AND d.is_system_mandatory = 1;

    INSERT @issues (check_code, severity, message, field_key)
    SELECT DISTINCT N'RULE_SOURCE_HIDDEN', N'WARNING',
           CONCAT(N'"', d.display_label, N'" drives a rule but is hidden on the form; users cannot set it.'), d.field_key
      FROM grac_practice.asset_form_template_rule r
      JOIN grac_practice.asset_form_template_rule_condition c ON c.rule_id = r.rule_id
      JOIN grac_practice.asset_form_template_field f ON f.template_id = r.template_id AND f.field_definition_id = c.source_field_definition_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = c.source_field_definition_id
     WHERE r.template_id = @template_id AND r.is_active = 1 AND f.is_visible = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template_rule r2
                        WHERE r2.template_id = r.template_id AND r2.is_active = 1
                          AND r2.target_field_definition_id = c.source_field_definition_id
                          AND r2.action_code IN (N'SHOW', N'SHOW_AND_REQUIRE'));

    -- Loop check over the whole rule graph (rule saves already refuse
    -- loops; this catches data written any other way).
    DECLARE @edges TABLE (source_id INT NOT NULL, target_id INT NOT NULL);
    INSERT @edges (source_id, target_id)
    SELECT DISTINCT c.source_field_definition_id, r.target_field_definition_id
      FROM grac_practice.asset_form_template_rule r
      JOIN grac_practice.asset_form_template_rule_condition c ON c.rule_id = r.rule_id
     WHERE r.template_id = @template_id AND r.is_active = 1;
    DECLARE @walk TABLE (start_id INT NOT NULL, field_id INT NOT NULL, PRIMARY KEY (start_id, field_id));
    INSERT @walk (start_id, field_id) SELECT DISTINCT target_id, target_id FROM @edges;
    DECLARE @added INT = 1, @guard INT = 0;
    WHILE @added > 0 AND @guard < 500
    BEGIN
        INSERT @walk (start_id, field_id)
        SELECT DISTINCT w.start_id, e.target_id
          FROM @walk w JOIN @edges e ON e.source_id = w.field_id
         WHERE NOT EXISTS (SELECT 1 FROM @walk x WHERE x.start_id = w.start_id AND x.field_id = e.target_id);
        SET @added = @@ROWCOUNT;
        SET @guard = @guard + 1;
    END
    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'RULE_CIRCULAR', N'ERROR', CONCAT(N'"', d.display_label, N'" depends on itself through its rules.'), d.field_key
      FROM grac_practice.asset_field_definition d
     WHERE EXISTS (SELECT 1 FROM @edges e JOIN @walk w ON w.field_id = e.source_id AND w.start_id = e.target_id
                    WHERE e.target_id = d.field_definition_id);

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'EMPTY_SECTION', N'WARNING', CONCAT(N'Section "', x.section_label, N'" has no fields and will be hidden.'), NULL
      FROM grac_practice.asset_form_template_section x
     WHERE x.template_id = @template_id AND x.is_active = 1 AND x.is_system = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template_field f WHERE f.section_id = x.section_id);

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'OWNER_MISSING', N'ERROR', N'Template owner is required.', NULL
      FROM grac_practice.asset_form_template t
     WHERE t.template_id = @template_id AND t.template_owner_employee_id IS NULL;

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'REASON_MISSING', N'ERROR', N'Change reason is required for a new version.', NULL
      FROM grac_practice.asset_form_template t
     WHERE t.template_id = @template_id AND t.version_no > 1
       AND NULLIF(LTRIM(RTRIM(t.change_reason)), N'') IS NULL;

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'ASSET_TYPE_INACTIVE', N'ERROR', N'The asset type is no longer active.', NULL
      FROM grac_practice.asset_form_template t
      JOIN grac_practice.dependency_asset_type_master at ON at.asset_type_id = t.asset_type_id
     WHERE t.template_id = @template_id AND at.is_active = 0;

    SELECT @out_error_count   = COUNT(CASE WHEN severity = N'ERROR' THEN 1 END),
           @out_warning_count = COUNT(CASE WHEN severity = N'WARNING' THEN 1 END)
      FROM @issues;

    IF ISNULL(@suppress_result, 0) = 1 RETURN;

    SELECT check_code AS CheckCode, severity AS Severity, message AS Message, field_key AS FieldKey
      FROM @issues
     ORDER BY CASE severity WHEN N'ERROR' THEN 0 ELSE 1 END, check_code, field_key;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_new_version
    @organization_id    BIGINT,
    @source_template_id BIGINT,
    @change_reason      NVARCHAR(1000),
    @actor_employee_id  BIGINT        = NULL,
    @actor              NVARCHAR(100) = N'system',
    @out_template_id    BIGINT        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @change_reason = NULLIF(LTRIM(RTRIM(@change_reason)), N'');

    DECLARE @asset_type_id INT, @next_version INT, @working_version INT;
    SELECT @asset_type_id = asset_type_id
      FROM grac_practice.asset_form_template
     WHERE template_id = @source_template_id AND organization_id = @organization_id;
    IF @asset_type_id IS NULL
        THROW 54202, 'Asset form template not found for this organization.', 1;
    IF @change_reason IS NULL
        THROW 54208, 'A change reason is required for a new version.', 1;

    SELECT @working_version = version_no FROM grac_practice.asset_form_template
     WHERE organization_id = @organization_id AND asset_type_id = @asset_type_id AND is_working_version = 1;
    IF @working_version IS NOT NULL
    BEGIN
        DECLARE @msg_working NVARCHAR(300) = CONCAT(N'Version ', @working_version,
            N' of this template is still being worked on (Draft, Testing, Pending Approval or Approved). Finish or retire it first.');
        THROW 54207, @msg_working, 1;
    END

    SELECT @next_version = MAX(version_no) + 1 FROM grac_practice.asset_form_template
     WHERE organization_id = @organization_id AND asset_type_id = @asset_type_id;

    DECLARE @draft_id INT = grac_practice.fn_get_entity_status_id(N'AssetFormTemplate', N'DRAFT');
    DECLARE @to_status_id INT, @log_id BIGINT;
    DECLARE @section_map TABLE (old_section_id BIGINT PRIMARY KEY, new_section_id BIGINT NOT NULL);

    BEGIN TRAN;

    INSERT grac_practice.asset_form_template
        (organization_id, asset_type_id, template_name, version_no, current_status_id, approval_required,
         template_owner_employee_id, change_reason, source_template_id, is_active_version, is_working_version, entered_by)
    SELECT organization_id, asset_type_id, template_name, @next_version, @draft_id, approval_required,
           template_owner_employee_id, @change_reason, template_id, 0, 1, @actor
      FROM grac_practice.asset_form_template
     WHERE template_id = @source_template_id;
    SET @out_template_id = SCOPE_IDENTITY();

    EXEC grac_practice.sp_pm_state_transition
         @entity_type = N'AssetFormTemplate', @entity_id = @out_template_id,
         @from_status_code = NULL, @to_status_code = N'DRAFT',
         @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
         @reason_code = N'NEW_VERSION', @reason_text = @change_reason,
         @to_status_id = @to_status_id OUTPUT, @transition_log_id = @log_id OUTPUT;

    -- Copy sections, keeping old -> new ids (MERGE is the only INSERT form
    -- whose OUTPUT can see source columns).
    MERGE grac_practice.asset_form_template_section AS t
    USING (SELECT section_id, section_key, section_label, tab_label, layout_columns, display_order, is_system, is_active
             FROM grac_practice.asset_form_template_section WHERE template_id = @source_template_id) AS s
    ON 1 = 0
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (template_id, section_key, section_label, tab_label, layout_columns, display_order, is_system, is_active, entered_by)
        VALUES (@out_template_id, s.section_key, s.section_label, s.tab_label, s.layout_columns, s.display_order, s.is_system, s.is_active, @actor)
    OUTPUT s.section_id, inserted.section_id INTO @section_map (old_section_id, new_section_id);

    INSERT grac_practice.asset_form_template_field
        (template_id, field_definition_id, section_id, display_order, is_visible, is_mandatory, is_read_only,
         default_value, help_text, placeholder_text, hidden_value_behavior, sensitivity_override,
         include_in_import_export, is_searchable, evidence_required, entered_by)
    SELECT @out_template_id, f.field_definition_id, m.new_section_id, f.display_order, f.is_visible, f.is_mandatory, f.is_read_only,
           f.default_value, f.help_text, f.placeholder_text, f.hidden_value_behavior, f.sensitivity_override,
           f.include_in_import_export, f.is_searchable, f.evidence_required, @actor
      FROM grac_practice.asset_form_template_field f
      JOIN @section_map m ON m.old_section_id = f.section_id
     WHERE f.template_id = @source_template_id;

    -- 421: conditional rules travel with the version.
    DECLARE @rule_map TABLE (old_rule_id BIGINT PRIMARY KEY, new_rule_id BIGINT NOT NULL);
    MERGE grac_practice.asset_form_template_rule AS t
    USING (SELECT rule_id, rule_name, target_field_definition_id, action_code, display_order, is_active
             FROM grac_practice.asset_form_template_rule WHERE template_id = @source_template_id) AS s
    ON 1 = 0
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (template_id, rule_name, target_field_definition_id, action_code, display_order, is_active, entered_by)
        VALUES (@out_template_id, s.rule_name, s.target_field_definition_id, s.action_code, s.display_order, s.is_active, @actor)
    OUTPUT s.rule_id, inserted.rule_id INTO @rule_map (old_rule_id, new_rule_id);

    INSERT grac_practice.asset_form_template_rule_condition
        (rule_id, group_no, source_field_definition_id, operator_code, compare_value, display_order)
    SELECT m.new_rule_id, c.group_no, c.source_field_definition_id, c.operator_code, c.compare_value, c.display_order
      FROM grac_practice.asset_form_template_rule_condition c
      JOIN @rule_map m ON m.old_rule_id = c.rule_id;

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, after_json, status, entered_by)
    VALUES (N'asset-form-template', @out_template_id, N'NEW_VERSION',
            (SELECT @source_template_id AS sourceTemplateId, @next_version AS versionNo, @change_reason AS changeReason
               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);

    COMMIT;

    SELECT @out_template_id AS TemplateId, @next_version AS VersionNo;
END
GO

PRINT '421: procedures created / re-issued.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '421-a option values seeded (>= 201 in asset_field.*)' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.reference_option WHERE option_group LIKE N'asset[_]field.%') >= 201
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '421-b no free-text identifier still typed as a lookup',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_definition
                              WHERE field_key IN (N'hardware_revision', N'purchase_order_number', N'finance_asset_number', N'bios_uefi_version',
                                                  N'log_source_monitoring_identifier', N'import_batch_job_id', N'rack', N'cabinet_bay',
                                                  N'entitlement_sku', N'support_hours')
                                AND data_type_code <> N'TEXT') THEN 'PASS' ELSE 'CHECK (operator-edited rows are left alone)' END
UNION ALL
SELECT '421-c rule tables present',
       CASE WHEN OBJECT_ID('grac_practice.asset_form_template_rule','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_form_template_rule_condition','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '421-d rule / evaluate procedures present',
       CASE WHEN (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_form_template_rule_save', 'sp_asset_form_template_rule_remove',
                                'sp_asset_form_template_evaluate')) = 3 THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '421-e get returns rules (re-issued)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_form_template_get')) LIKE '%asset_form_template_rule_condition%'
            THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build)
--   1. Open a Draft "Laptop" template -> Rules tab -> Add rule:
--      target "Calibration frequency", Show and require, condition
--      "Calibration required" EQ YES. Saved.
--   2. Add rule target "Calibration required" with a condition on
--      "Calibration frequency" -> refused (54230, circular).
--   3. Rule targeting "Asset name" -> refused (54231).
--   4. Remove "Calibration required" from the form -> refused (54231,
--      a rule uses it).
--   5. Preview tab: Calibration required = Yes -> Calibration frequency
--      visible + mandatory; = No -> hidden, not mandatory.
--   6. Readiness: OPTIONS_PENDING only for lists without values (e.g.
--      Building); Personal data processed shows its Yes/No/Unknown list.
--   7. New version from an Active version -> rules are copied.
-- =====================================================================
SET NOEXEC OFF;
GO
