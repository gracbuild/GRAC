-- =====================================================================
-- 424 rollback -- asset taxonomy governance
--
--   * removes the Asset Taxonomy menu row and its grants;
--   * restores the earlier bodies of sp_get_asset_taxonomy_lookup (241),
--     sp_asset_form_template_create (420) and
--     sp_org_dependency_assets_repository_manage (419), copied verbatim
--     below, so nothing else has to be re-run;
--   * drops the taxonomy procedures, both functions and
--     asset_type_org_default (organization defaults are lost);
--   * drops the governance columns (sector, owner, standards, default
--     criticality, effective dates, descriptions, record_version,
--     parent_subcategory_id -- level-2 subcategories become level 1).
--     Codes, names, order, active flags and every asset are untouched.
-- practice_audit_trace rows are immutable and stay as history.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DELETE p FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'asset-taxonomy';
DELETE FROM grac_practice.menu_master WHERE menu_key = N'asset-taxonomy';
PRINT '424 rollback: menu row removed.';
GO

-- ---------------------------------------------------------------------
-- Earlier bodies (241 / 420 / 419), verbatim
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_get_asset_taxonomy_lookup
    -- 7-parameter signature that matches every other query shim; the
    -- taxonomy is org-agnostic so the parameters are read and ignored.
    -- Without them the generic query path fails with "too many arguments".
    @p_entity_type   NVARCHAR(100) = N'',
    @p_action        NVARCHAR(40)  = N'',
    @p_id            BIGINT        = 0,
    @p_search        NVARCHAR(250) = N'',
    @p_status        NVARCHAR(30)  = N'',
    @p_payload       NVARCHAR(MAX) = N'{}',
    @p_usr_id        NVARCHAR(200) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    -- Same shape the master UNION uses: EntityType, Value, Label, Parent.
    -- Consumers can filter by EntityType and cascade off Parent.
    SELECT N'asset-categories'    AS EntityType,
           CAST(asset_category_id AS NVARCHAR(40)) AS Value,
           asset_category_name    AS Label,
           CAST(NULL AS BIGINT)   AS Parent
    FROM   grac_practice.dependency_asset_category_master
    WHERE  is_active = 1

    UNION ALL

    SELECT N'asset-subcategories',
           CAST(subcategory_id AS NVARCHAR(40)),
           subcategory_name,
           CAST(asset_category_id AS BIGINT)
    FROM   grac_practice.dependency_asset_subcategory_master
    WHERE  is_active = 1

    UNION ALL

    SELECT N'asset-types',
           CAST(t.asset_type_id AS NVARCHAR(40)),
           t.asset_type_name,
           CAST(t.subcategory_id AS BIGINT)
    FROM   grac_practice.dependency_asset_type_master t
    WHERE  t.is_active = 1

    ORDER  BY EntityType, Label;
END
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_create
    @organization_id            BIGINT,
    @asset_type_id              INT,
    @template_name              NVARCHAR(200),
    @change_reason              NVARCHAR(1000) = NULL,
    @template_owner_employee_id BIGINT         = NULL,
    @actor_employee_id          BIGINT         = NULL,
    @actor                      NVARCHAR(100)  = N'system',
    @out_template_id            BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @template_name = NULLIF(LTRIM(RTRIM(@template_name)), N'');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54200, 'Organization not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.dependency_asset_type_master WHERE asset_type_id = @asset_type_id AND is_active = 1)
        THROW 54201, 'Select an active asset type.', 1;
    IF @template_name IS NULL
        THROW 54204, 'Template name is required.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_form_template
                WHERE organization_id = @organization_id AND asset_type_id = @asset_type_id)
        THROW 54203, 'A template already exists for this asset type. Create a new version from it instead.', 1;

    -- Default owner: the acting employee, when they belong to the organization.
    IF @template_owner_employee_id IS NULL AND @actor_employee_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM grac_practice.organization_employee
                    WHERE employee_id = @actor_employee_id AND organization_id = @organization_id AND status = N'Active')
        SET @template_owner_employee_id = @actor_employee_id;
    IF @template_owner_employee_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_employee
         WHERE employee_id = @template_owner_employee_id AND organization_id = @organization_id AND status = N'Active')
        THROW 54206, 'Template owner must be an active employee of the organization.', 1;

    DECLARE @draft_id INT = grac_practice.fn_get_entity_status_id(N'AssetFormTemplate', N'DRAFT');
    DECLARE @to_status_id INT, @log_id BIGINT, @general_id BIGINT;

    BEGIN TRAN;

    INSERT grac_practice.asset_form_template
        (organization_id, asset_type_id, template_name, version_no, current_status_id, approval_required,
         template_owner_employee_id, change_reason, is_active_version, is_working_version, entered_by)
    VALUES
        (@organization_id, @asset_type_id, @template_name, 1, @draft_id, 1,
         @template_owner_employee_id, NULLIF(LTRIM(RTRIM(@change_reason)), N''), 0, 1, @actor);
    SET @out_template_id = SCOPE_IDENTITY();

    EXEC grac_practice.sp_pm_state_transition
         @entity_type = N'AssetFormTemplate', @entity_id = @out_template_id,
         @from_status_code = NULL, @to_status_code = N'DRAFT',
         @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
         @reason_code = N'CREATED', @reason_text = NULL,
         @to_status_id = @to_status_id OUTPUT, @transition_log_id = @log_id OUTPUT;

    INSERT grac_practice.asset_form_template_section
        (template_id, section_key, section_label, layout_columns, display_order, is_system, entered_by)
    VALUES (@out_template_id, N'GENERAL', N'General', 2, 10, 0, @actor);
    SET @general_id = SCOPE_IDENTITY();

    INSERT grac_practice.asset_form_template_section
        (template_id, section_key, section_label, layout_columns, display_order, is_system, entered_by)
    VALUES (@out_template_id, N'AUDIT_HISTORY', N'Audit History', 1, 9999, 1, @actor);

    -- The 5.1.17 baseline, visible and mandatory; auto / calculated ones read-only.
    INSERT grac_practice.asset_form_template_field
        (template_id, field_definition_id, section_id, display_order, is_visible, is_mandatory, is_read_only, entered_by)
    SELECT @out_template_id, d.field_definition_id, @general_id,
           ROW_NUMBER() OVER (ORDER BY g.display_order, d.display_order) * 10,
           1, 1, CASE WHEN dt.is_user_entered = 0 THEN 1 ELSE 0 END, @actor
      FROM grac_practice.asset_field_definition d
      JOIN grac_practice.asset_field_group_master g ON g.field_group_id = d.field_group_id
      JOIN grac_practice.asset_field_data_type_master dt ON dt.data_type_code = d.data_type_code
     WHERE d.is_system_mandatory = 1 AND d.status_code = N'ACTIVE' AND d.is_system_field = 0;

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, after_json, status, entered_by)
    VALUES (N'asset-form-template', @out_template_id, N'CREATE',
            (SELECT @organization_id AS organizationId, @asset_type_id AS assetTypeId, @template_name AS templateName,
                    1 AS versionNo FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);

    COMMIT;

    SELECT @out_template_id AS TemplateId;
END
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_org_dependency_assets_repository_manage
    @p_entity_type   NVARCHAR(100) = N'',
    @p_action        NVARCHAR(40)  = N'',
    @p_id            BIGINT        = 0,
    @p_search        NVARCHAR(250) = N'',
    @p_status        NVARCHAR(30)  = N'',
    @p_payload       NVARCHAR(MAX) = N'{}',
    @p_usr_id        NVARCHAR(200) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @p_action  = LTRIM(RTRIM(ISNULL(@p_action, N'')));
    SET @p_payload = ISNULL(NULLIF(@p_payload, N''), N'{}');
    SET @p_usr_id  = ISNULL(NULLIF(@p_usr_id, N''), N'system');
    SET @p_id      = ISNULL(@p_id, 0);

    -- 419 / D-1: legacy spellings are the generic RETIRE.
    IF @p_action IN (N'delete', N'inactive', N'deactivate') SET @p_action = N'RETIRE';

    -- Not a save: the monolith owns it (RETIRE and anything future),
    -- keeping its organization-access check intact.
    IF @p_action <> N'SAVE' AND @p_action <> N''
    BEGIN
        EXEC dbo.pm_manage_practice_repository
             @p_entity_type = N'dependency-assets', @p_action = @p_action, @p_id = @p_id,
             @p_search = @p_search, @p_status = @p_status,
             @p_payload = @p_payload, @p_usr_id = @p_usr_id;
        RETURN;
    END

    IF ISJSON(@p_payload) <> 1
        THROW 51130, 'Organization is required for Asset.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
         WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);

    -- Organization access -- the monolith's rule, verbatim in effect.
    DECLARE @is_system_admin BIT =
        CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload, N'$._security.isSystemAdmin'), N'false'))
                  IN (N'true', N'1', N'yes') THEN 1 ELSE 0 END;
    DECLARE @allowed_organizations TABLE (organization_id BIGINT PRIMARY KEY);
    INSERT @allowed_organizations (organization_id)
    SELECT DISTINCT organization_id
      FROM grac_practice.user_organization_map
     WHERE user_email = @p_usr_id AND status = N'Active' AND record_status_id = @active_record_status_id;
    INSERT @allowed_organizations (organization_id)
    SELECT DISTINCT e.organization_id
      FROM grac_practice.organization_employee e
     WHERE e.status = N'Active'
       AND (e.email = @p_usr_id OR e.employee_code = @p_usr_id)
       AND NOT EXISTS (SELECT 1 FROM @allowed_organizations a WHERE a.organization_id = e.organization_id);

    DECLARE @asset_org_id         BIGINT        = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload, N'$.organizationId'), N''));
    DECLARE @asset_name           NVARCHAR(220) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload, N'$.name'))), N'');
    DECLARE @asset_category_id    INT           = TRY_CONVERT(INT, NULLIF(JSON_VALUE(@p_payload, N'$.assetCategoryId'), N''));
    DECLARE @asset_subcategory_id INT           = TRY_CONVERT(INT, NULLIF(JSON_VALUE(@p_payload, N'$.assetSubcategoryId'), N''));
    DECLARE @asset_type_id        INT           = TRY_CONVERT(INT, NULLIF(JSON_VALUE(@p_payload, N'$.assetTypeId'), N''));
    DECLARE @asset_owner_id       BIGINT        = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload, N'$.ownerId'), N''));
    DECLARE @asset_location_id    BIGINT        = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload, N'$.locationId'), N''));
    DECLARE @asset_criticality_id INT           = TRY_CONVERT(INT, NULLIF(JSON_VALUE(@p_payload, N'$.criticalityId'), N''));
    DECLARE @purchase_dt          DATE          = TRY_CONVERT(DATE, NULLIF(JSON_VALUE(@p_payload, N'$.purchaseDate'), N''));
    DECLARE @warranty_expiry_dt   DATE          = TRY_CONVERT(DATE, NULLIF(JSON_VALUE(@p_payload, N'$.warrantyExpiryDate'), N''));
    DECLARE @amc_expiry_dt        DATE          = TRY_CONVERT(DATE, NULLIF(JSON_VALUE(@p_payload, N'$.amcExpiryDate'), N''));
    DECLARE @asset_remarks        NVARCHAR(MAX) = JSON_VALUE(@p_payload, N'$.remarks');

    -- Status: statusId wins, then a status code/name -- the monolith's
    -- @payload_record_status_id precedence -- else Active.
    DECLARE @asset_status_id INT = TRY_CONVERT(INT, NULLIF(JSON_VALUE(@p_payload, N'$.statusId'), N''));
    IF @asset_status_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.record_status_master WHERE record_status_id = @asset_status_id)
        SET @asset_status_id = NULL;
    IF @asset_status_id IS NULL
        SELECT TOP 1 @asset_status_id = record_status_id FROM grac_practice.record_status_master
         WHERE status_code = JSON_VALUE(@p_payload, N'$.status') OR status_name = JSON_VALUE(@p_payload, N'$.status');
    SET @asset_status_id = COALESCE(@asset_status_id, @active_record_status_id);
    DECLARE @asset_status_name NVARCHAR(30) = COALESCE(
        (SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id = @asset_status_id), N'Active');

    IF @asset_org_id IS NULL THROW 51130, 'Organization is required for Asset.', 1;
    IF @is_system_admin = 0
       AND NOT EXISTS (SELECT 1 FROM @allowed_organizations WHERE organization_id = @asset_org_id)
        THROW 51052, 'You do not have access to the selected organization.', 1;
    IF @asset_name IS NULL THROW 51131, 'Asset Name is required.', 1;
    IF @asset_category_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM grac_practice.dependency_asset_category_master
                       WHERE asset_category_id = @asset_category_id AND is_active = 1)
        THROW 51132, 'Asset Category is required.', 1;
    IF @asset_subcategory_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.dependency_asset_subcategory_master
         WHERE subcategory_id = @asset_subcategory_id AND asset_category_id = @asset_category_id AND is_active = 1)
        THROW 52726, 'The chosen Sub Category does not belong to the chosen Category.', 1;
    IF @asset_type_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.dependency_asset_type_master t
          JOIN grac_practice.dependency_asset_subcategory_master s ON s.subcategory_id = t.subcategory_id
         WHERE t.asset_type_id = @asset_type_id
           AND s.subcategory_id = COALESCE(@asset_subcategory_id, s.subcategory_id)
           AND s.asset_category_id = @asset_category_id
           AND t.is_active = 1 AND s.is_active = 1)
        THROW 52727, 'The chosen Asset Type does not belong to the chosen Sub Category.', 1;
    IF @asset_owner_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_employee
         WHERE employee_id = @asset_owner_id AND organization_id = @asset_org_id AND status = N'Active')
        THROW 51133, 'Selected Owner is not valid for this organization.', 1;
    IF @asset_location_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_location
         WHERE location_id = @asset_location_id AND organization_id = @asset_org_id AND status = N'Active')
        THROW 51134, 'Selected Location is not valid for this organization.', 1;
    IF @asset_criticality_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.criticality_master WHERE criticality_id = @asset_criticality_id AND is_active = 1)
        THROW 51135, 'Selected Criticality is not valid.', 1;

    IF @p_id > 0 AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_dependency_asset
         WHERE asset_id = @p_id AND organization_id = @asset_org_id)
        THROW 51054, 'Selected record was not found or is no longer available.', 1;

    DECLARE @new_id BIGINT = @p_id;

    BEGIN TRAN;

    IF @p_id = 0
    BEGIN
        INSERT grac_practice.organization_dependency_asset
            (organization_id, asset_name, asset_category_id, asset_subcategory_id, asset_type_id,
             owner_id, location_id, purchase_dt, warranty_expiry_dt, amc_expiry_dt,
             criticality_id, remarks, status, record_status_id, entered_by)
        VALUES
            (@asset_org_id, @asset_name, @asset_category_id, @asset_subcategory_id, @asset_type_id,
             @asset_owner_id, @asset_location_id, @purchase_dt, @warranty_expiry_dt, @amc_expiry_dt,
             @asset_criticality_id, @asset_remarks, @asset_status_name, @asset_status_id, @p_usr_id);
        SET @new_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_dependency_asset
           SET asset_name           = @asset_name,
               asset_category_id    = @asset_category_id,
               asset_subcategory_id = @asset_subcategory_id,
               asset_type_id        = @asset_type_id,
               owner_id             = @asset_owner_id,
               location_id          = @asset_location_id,
               purchase_dt          = @purchase_dt,
               warranty_expiry_dt   = @warranty_expiry_dt,
               amc_expiry_dt        = @amc_expiry_dt,
               criticality_id       = @asset_criticality_id,
               remarks              = @asset_remarks,
               status               = @asset_status_name,
               record_status_id     = @asset_status_id,
               updated_by           = @p_usr_id,
               updated_dt           = SYSUTCDATETIME()
         WHERE asset_id = @p_id AND organization_id = @asset_org_id;
    END

    -- Same audit row the monolith writes for every save.
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, after_json, status, entered_by)
    VALUES (N'dependency-assets', @new_id, N'SAVE', @p_payload, N'Active', @p_usr_id);

    COMMIT;

    SELECT CAST(1 AS BIT) AS Success,
           CASE WHEN @p_id = 0 THEN N'Asset created.' ELSE N'Asset updated.' END AS Message,
           @new_id AS SavedId, @new_id AS Id;
END
GO
PRINT '424 rollback: lookup, template create and asset save restored.';
GO

IF OBJECT_ID('grac_practice.sp_asset_taxonomy_list','P') IS NOT NULL             DROP PROCEDURE grac_practice.sp_asset_taxonomy_list;
IF OBJECT_ID('grac_practice.sp_asset_taxonomy_category_save','P') IS NOT NULL    DROP PROCEDURE grac_practice.sp_asset_taxonomy_category_save;
IF OBJECT_ID('grac_practice.sp_asset_taxonomy_subcategory_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_asset_taxonomy_subcategory_save;
IF OBJECT_ID('grac_practice.sp_asset_taxonomy_type_save','P') IS NOT NULL        DROP PROCEDURE grac_practice.sp_asset_taxonomy_type_save;
IF OBJECT_ID('grac_practice.sp_asset_type_org_default_save','P') IS NOT NULL     DROP PROCEDURE grac_practice.sp_asset_type_org_default_save;
IF OBJECT_ID('grac_practice.fn_asset_taxonomy_selectable') IS NOT NULL           DROP FUNCTION grac_practice.fn_asset_taxonomy_selectable;
IF OBJECT_ID('grac_practice.fn_asset_make_code') IS NOT NULL                     DROP FUNCTION grac_practice.fn_asset_make_code;
IF OBJECT_ID('grac_practice.asset_type_org_default','U') IS NOT NULL             DROP TABLE grac_practice.asset_type_org_default;
PRINT '424 rollback: procedures, functions and organization defaults dropped.';
GO
IF OBJECT_ID('grac_practice.ck_pm_asset_category_effective') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_category_master DROP CONSTRAINT ck_pm_asset_category_effective;
IF OBJECT_ID('grac_practice.ck_pm_asset_subcategory_effective') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_subcategory_master DROP CONSTRAINT ck_pm_asset_subcategory_effective;
IF OBJECT_ID('grac_practice.ck_pm_asset_type_effective') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_type_master DROP CONSTRAINT ck_pm_asset_type_effective;
IF OBJECT_ID('grac_practice.ck_pm_asset_subcategory_not_self') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_subcategory_master DROP CONSTRAINT ck_pm_asset_subcategory_not_self;
IF OBJECT_ID('grac_practice.fk_pm_asset_category_criticality') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_category_master DROP CONSTRAINT fk_pm_asset_category_criticality;
IF OBJECT_ID('grac_practice.fk_pm_asset_subcategory_parent') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_subcategory_master DROP CONSTRAINT fk_pm_asset_subcategory_parent;
IF OBJECT_ID('grac_practice.fk_pm_asset_type_criticality') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_type_master DROP CONSTRAINT fk_pm_asset_type_criticality;
GO
IF COL_LENGTH('grac_practice.dependency_asset_category_master','description') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_category_master DROP COLUMN description;
IF COL_LENGTH('grac_practice.dependency_asset_category_master','sector') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_category_master DROP COLUMN sector;
IF COL_LENGTH('grac_practice.dependency_asset_category_master','owner_name') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_category_master DROP COLUMN owner_name;
IF COL_LENGTH('grac_practice.dependency_asset_category_master','standards') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_category_master DROP COLUMN standards;
IF COL_LENGTH('grac_practice.dependency_asset_category_master','default_criticality_id') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_category_master DROP COLUMN default_criticality_id;
IF COL_LENGTH('grac_practice.dependency_asset_category_master','effective_from') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_category_master DROP COLUMN effective_from;
IF COL_LENGTH('grac_practice.dependency_asset_category_master','effective_to') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_category_master DROP COLUMN effective_to;
IF COL_LENGTH('grac_practice.dependency_asset_category_master','record_version') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_category_master DROP COLUMN record_version;
IF COL_LENGTH('grac_practice.dependency_asset_subcategory_master','parent_subcategory_id') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_subcategory_master DROP COLUMN parent_subcategory_id;
IF COL_LENGTH('grac_practice.dependency_asset_subcategory_master','description') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_subcategory_master DROP COLUMN description;
IF COL_LENGTH('grac_practice.dependency_asset_subcategory_master','effective_from') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_subcategory_master DROP COLUMN effective_from;
IF COL_LENGTH('grac_practice.dependency_asset_subcategory_master','effective_to') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_subcategory_master DROP COLUMN effective_to;
IF COL_LENGTH('grac_practice.dependency_asset_subcategory_master','record_version') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_subcategory_master DROP COLUMN record_version;
IF COL_LENGTH('grac_practice.dependency_asset_type_master','description') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_type_master DROP COLUMN description;
IF COL_LENGTH('grac_practice.dependency_asset_type_master','default_criticality_id') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_type_master DROP COLUMN default_criticality_id;
IF COL_LENGTH('grac_practice.dependency_asset_type_master','effective_from') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_type_master DROP COLUMN effective_from;
IF COL_LENGTH('grac_practice.dependency_asset_type_master','effective_to') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_type_master DROP COLUMN effective_to;
IF COL_LENGTH('grac_practice.dependency_asset_type_master','record_version') IS NOT NULL ALTER TABLE grac_practice.dependency_asset_type_master DROP COLUMN record_version;
PRINT '424 rollback: governance columns dropped.';
GO
