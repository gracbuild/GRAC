-- =====================================================================
-- 420 rollback -- Asset field dictionary + asset form templates
--
-- Removes everything 420 created: the menu rows and their grants, the
-- procedures, the AssetFormTemplate statuses / transition rules, and the
-- six tables (templates first, then the dictionary).
--
-- entity_state_transition_log is immutable (035 trigger), so the
-- AssetFormTemplate log rows -- and therefore their entity_status_master
-- rows, which the log references -- cannot be deleted once a template
-- has moved. This script deletes the status rows only when no log row
-- points at them and otherwise leaves them (inert without the tables).
-- practice_audit_trace rows ('asset-form-template') are immutable too
-- and stay as history.
--
-- Also revert the 274 / 272 / appsettings edits listed in 420's header
-- if this rollback is permanent.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DELETE p
  FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key IN (N'asset-field-dictionary', N'asset-form-templates', N'nav-asset-contract');
DELETE FROM grac_practice.menu_master WHERE menu_key IN (N'asset-field-dictionary', N'asset-form-templates');
DELETE FROM grac_practice.menu_master WHERE menu_key = N'nav-asset-contract';
PRINT '420 rollback: menu rows and grants removed.';
GO

DECLARE @p NVARCHAR(200);
DECLARE procs CURSOR LOCAL FAST_FORWARD FOR
    SELECT N'grac_practice.' + name FROM sys.procedures
     WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
       AND name IN ('sp_asset_field_group_list', 'sp_asset_field_definition_list',
                    'sp_asset_form_template_list', 'sp_asset_form_template_get',
                    'sp_asset_form_template_create', 'sp_asset_form_template_new_version',
                    'sp_asset_form_template_assert_editable', 'sp_asset_form_template_header_save',
                    'sp_asset_form_template_section_save', 'sp_asset_form_template_field_save',
                    'sp_asset_form_template_field_remove', 'sp_asset_form_template_readiness',
                    'sp_asset_form_template_transition');
OPEN procs;
FETCH NEXT FROM procs INTO @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC (N'DROP PROCEDURE ' + @p);
    FETCH NEXT FROM procs INTO @p;
END
CLOSE procs;
DEALLOCATE procs;
PRINT '420 rollback: procedures dropped.';
GO

DELETE FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'AssetFormTemplate';
DELETE s FROM grac_practice.entity_status_master s
 WHERE s.entity_type = N'AssetFormTemplate'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_log l
                    WHERE l.from_status_id = s.entity_status_id OR l.to_status_id = s.entity_status_id);
PRINT '420 rollback: AssetFormTemplate rules removed (statuses kept where history references them).';
GO

IF OBJECT_ID('grac_practice.asset_form_template_field','U')   IS NOT NULL DROP TABLE grac_practice.asset_form_template_field;
IF OBJECT_ID('grac_practice.asset_form_template_section','U') IS NOT NULL DROP TABLE grac_practice.asset_form_template_section;
IF OBJECT_ID('grac_practice.asset_form_template','U')         IS NOT NULL DROP TABLE grac_practice.asset_form_template;
IF OBJECT_ID('grac_practice.asset_field_definition','U')      IS NOT NULL DROP TABLE grac_practice.asset_field_definition;
IF OBJECT_ID('grac_practice.asset_field_data_type_master','U') IS NOT NULL DROP TABLE grac_practice.asset_field_data_type_master;
IF OBJECT_ID('grac_practice.asset_field_group_master','U')    IS NOT NULL DROP TABLE grac_practice.asset_field_group_master;
PRINT '420 rollback: tables dropped.';
GO
