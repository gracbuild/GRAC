-- =====================================================================
-- 421 rollback -- option lists, conditional rules, evaluation engine
--
--   * drops the rule / evaluate procedures and the two rule tables;
--   * deletes the asset_field.* option rows 421 seeded (entered_by
--     'seed-421');
--   * puts the 13 corrected dictionary rows back to their 420 type /
--     source (only rows 421 changed: updated_by = 'seed-421');
--   * re-issue the 420 bodies of sp_asset_form_template_get,
--     sp_asset_form_template_readiness, sp_asset_form_template_new_version
--     and sp_asset_form_template_field_remove by re-running
--     420_asset_form_templates.sql afterwards (it is re-runnable; its
--     seeds are insert-only and skip existing rows).
-- practice_audit_trace rows are immutable and stay as history.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_asset_form_template_rule_save','P') IS NOT NULL   DROP PROCEDURE grac_practice.sp_asset_form_template_rule_save;
IF OBJECT_ID('grac_practice.sp_asset_form_template_rule_remove','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_asset_form_template_rule_remove;
IF OBJECT_ID('grac_practice.sp_asset_form_template_evaluate','P') IS NOT NULL    DROP PROCEDURE grac_practice.sp_asset_form_template_evaluate;
IF OBJECT_ID('grac_practice.asset_form_template_rule_condition','U') IS NOT NULL DROP TABLE grac_practice.asset_form_template_rule_condition;
IF OBJECT_ID('grac_practice.asset_form_template_rule','U') IS NOT NULL           DROP TABLE grac_practice.asset_form_template_rule;
PRINT '421 rollback: rule objects dropped.';
GO

DELETE FROM grac_practice.reference_option
 WHERE option_group LIKE N'asset[_]field.%' AND entered_by = N'seed-421';
PRINT CONCAT('421 rollback: option rows removed: ', @@ROWCOUNT);
GO

UPDATE d
   SET data_type_code = N'LOOKUP', lookup_source = N'OPTION:' + d.field_key,
       definition_version = CASE WHEN d.definition_version > 1 THEN d.definition_version - 1 ELSE 1 END,
       updated_by = N'rollback-421', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.asset_field_definition d
 WHERE d.updated_by = N'seed-421'
   AND d.field_key IN (N'hardware_revision', N'purchase_order_number', N'finance_asset_number', N'bios_uefi_version',
                       N'log_source_monitoring_identifier', N'import_batch_job_id', N'rack', N'cabinet_bay',
                       N'entitlement_sku', N'support_hours', N'confidentiality_rating', N'integrity_rating',
                       N'availability_rating');
PRINT CONCAT('421 rollback: dictionary rows restored: ', @@ROWCOUNT, '. Now re-run 420_asset_form_templates.sql.');
GO
