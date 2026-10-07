-- =====================================================================
-- 435 rollback -- Contract coverage and entitlements
--
--   * restores the earlier bodies of fn_asset_master_lookup and
--     fn_asset_stored_values (428), sp_asset_register_save (431),
--     sp_asset_lifecycle_transition (429) and the 434 contract procedures
--     fn_asset_contract_readiness, sp_asset_contract_version_create,
--     sp_asset_contract_version_check, sp_asset_contract_version_compare,
--     sp_asset_contract_get, sp_asset_contract_version_get (verbatim below);
--   * drops the coverage procedures and functions;
--   * drops asset_contract_coverage, asset_contract_entitlement,
--     asset_coverage_requirement and asset_coverage_settings (every
--     coverage line, entitlement and requirement is lost).
-- practice_audit_trace rows stay as history. Re-runnable. ASCII-only.
-- NOTE: a Primary support contract already stored on an asset stays; the
-- restored 431 save refuses changes to that field until 435 is re-applied.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

-- fn_asset_master_lookup (428) body, verbatim
CREATE OR ALTER FUNCTION grac_practice.fn_asset_master_lookup (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT N'MASTER:ASSET_CATEGORY' AS Source, CAST(c.asset_category_id AS NVARCHAR(160)) AS Value,
           c.asset_category_name AS Label, CAST(NULL AS NVARCHAR(160)) AS ParentValue
      FROM grac_practice.fn_asset_taxonomy_selectable() f
      JOIN grac_practice.dependency_asset_category_master c ON c.asset_category_id = f.NodeId
     WHERE f.NodeKind = N'CATEGORY'
    UNION ALL
    SELECT N'MASTER:ASSET_SUBCATEGORY', CAST(s.subcategory_id AS NVARCHAR(160)),
           CASE WHEN p.subcategory_id IS NULL THEN s.subcategory_name ELSE p.subcategory_name + N' / ' + s.subcategory_name END,
           CAST(s.asset_category_id AS NVARCHAR(160))
      FROM grac_practice.fn_asset_taxonomy_selectable() f
      JOIN grac_practice.dependency_asset_subcategory_master s ON s.subcategory_id = f.NodeId
      LEFT JOIN grac_practice.dependency_asset_subcategory_master p ON p.subcategory_id = s.parent_subcategory_id
     WHERE f.NodeKind = N'SUBCATEGORY'
    UNION ALL
    SELECT N'MASTER:ASSET_TYPE', CAST(t.asset_type_id AS NVARCHAR(160)), t.asset_type_name, CAST(t.subcategory_id AS NVARCHAR(160))
      FROM grac_practice.fn_asset_taxonomy_selectable() f
      JOIN grac_practice.dependency_asset_type_master t ON t.asset_type_id = f.NodeId
     WHERE f.NodeKind = N'TYPE'
    UNION ALL
    SELECT N'MASTER:ORGANIZATION', CAST(o.organization_id AS NVARCHAR(160)), o.organization_name, NULL
      FROM grac_practice.organization o WHERE o.organization_id = @organization_id
    UNION ALL
    SELECT N'MASTER:LOCATION', CAST(l.location_id AS NVARCHAR(160)), l.location_name, NULL
      FROM grac_practice.organization_location l WHERE l.organization_id = @organization_id AND l.status = N'Active'
    UNION ALL
    SELECT N'MASTER:EMPLOYEE', CAST(e.employee_id AS NVARCHAR(160)), e.employee_name, NULL
      FROM grac_practice.organization_employee e WHERE e.organization_id = @organization_id AND e.status = N'Active'
    UNION ALL
    SELECT N'MASTER:TEAM', CAST(t.team_id AS NVARCHAR(160)), t.team_name, NULL
      FROM grac_practice.organization_team t WHERE t.organization_id = @organization_id AND t.status = N'Active'
    UNION ALL
    SELECT N'MASTER:EMPLOYEE_OR_TEAM', N'E:' + CAST(e.employee_id AS NVARCHAR(150)), e.employee_name, NULL
      FROM grac_practice.organization_employee e WHERE e.organization_id = @organization_id AND e.status = N'Active'
    UNION ALL
    SELECT N'MASTER:EMPLOYEE_OR_TEAM', N'T:' + CAST(t.team_id AS NVARCHAR(150)), t.team_name + N' (team)', NULL
      FROM grac_practice.organization_team t WHERE t.organization_id = @organization_id AND t.status = N'Active'
    UNION ALL
    SELECT N'MASTER:DEPARTMENT', CAST(d.department_id AS NVARCHAR(160)), d.department_name, NULL
      FROM grac_practice.organization_department d WHERE d.organization_id = @organization_id AND d.status = N'Active'
    UNION ALL
    SELECT N'MASTER:DIVISION', CAST(d.division_id AS NVARCHAR(160)), d.division_name, NULL
      FROM grac_practice.organization_division d WHERE d.organization_id = @organization_id AND d.status = N'Active'
    UNION ALL
    SELECT N'MASTER:VENDOR', CAST(v.vendor_id AS NVARCHAR(160)), v.vendor_name, NULL
      FROM grac_practice.organization_dependency_vendor v WHERE v.organization_id = @organization_id AND v.status = N'Active'
    UNION ALL
    SELECT N'MASTER:PROCESS', CAST(p.process_id AS NVARCHAR(160)), p.process_name, NULL
      FROM grac_practice.organization_dependency_process p WHERE p.organization_id = @organization_id AND p.status = N'Active'
    UNION ALL
    SELECT N'MASTER:PRACTICE', CAST(p.practice_id AS NVARCHAR(160)), p.practice_name, NULL
      FROM grac_practice.practice p WHERE p.organization_id = @organization_id AND p.status = N'Active'
    UNION ALL
    SELECT N'MASTER:CRITICALITY', CAST(c.criticality_id AS NVARCHAR(160)), c.criticality_name, NULL
      FROM grac_practice.criticality_master c WHERE c.is_active = 1
    UNION ALL
    SELECT N'MASTER:ASSET_FORM_TEMPLATE', CAST(t.template_id AS NVARCHAR(160)), CONCAT(t.template_name, N' v', t.version_no),
           CAST(t.asset_type_id AS NVARCHAR(160))
      FROM grac_practice.asset_form_template t WHERE t.organization_id = @organization_id AND t.is_active_version = 1
    UNION ALL
    SELECT N'MASTER:MAKE', CAST(m.make_id AS NVARCHAR(160)), m.make_name, NULL
      FROM grac_practice.asset_make m
     WHERE m.status = N'Active' AND (m.organization_id IS NULL OR m.organization_id = @organization_id)
    UNION ALL
    SELECT N'MASTER:MODEL', CAST(d.model_id AS NVARCHAR(160)),
           CONCAT(d.model_name, CASE WHEN d.variant IS NULL THEN N'' ELSE N' ' + d.variant END,
                  CASE WHEN d.model_number IS NULL THEN N'' ELSE N' (' + d.model_number + N')' END),
           CAST(d.make_id AS NVARCHAR(160))
      FROM grac_practice.asset_model d
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = d.current_status_id
     WHERE s.status_code = N'APPROVED' AND (d.organization_id IS NULL OR d.organization_id = @organization_id)
    UNION ALL
    SELECT N'MASTER:FIRMWARE', CAST(r.release_id AS NVARCHAR(160)),
           CONCAT(p.product_name, N' ', r.version, CASE WHEN r.build IS NULL THEN N'' ELSE N' build ' + r.build END),
           CAST(p.publisher_make_id AS NVARCHAR(160))
      FROM grac_practice.asset_firmware_release r
      JOIN grac_practice.asset_firmware_product p ON p.product_id = r.product_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
     WHERE s.status_code NOT IN (N'DRAFT', N'WITHDRAWN') AND (r.organization_id IS NULL OR r.organization_id = @organization_id)
    UNION ALL
    SELECT N'MASTER:OS_RELEASE', CAST(r.release_id AS NVARCHAR(160)),
           CONCAT(p.product_name, CASE WHEN r.edition IS NULL THEN N'' ELSE N' ' + r.edition END, N' ', r.version,
                  CASE WHEN r.architecture IS NULL THEN N'' ELSE N' ' + r.architecture END),
           CAST(p.publisher_make_id AS NVARCHAR(160))
      FROM grac_practice.asset_os_release r
      JOIN grac_practice.asset_os_product p ON p.product_id = r.product_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
     WHERE s.status_code <> N'DRAFT' AND (r.organization_id IS NULL OR r.organization_id = @organization_id);
GO

-- fn_asset_stored_values (428) body, verbatim
CREATE OR ALTER FUNCTION grac_practice.fn_asset_stored_values (@asset_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT d.field_definition_id AS FieldDefinitionId, d.field_key AS FieldKey, c.val AS Value
      FROM grac_practice.organization_dependency_asset a
     CROSS APPLY (VALUES
        (N'asset_id',             CAST(a.asset_id AS NVARCHAR(MAX))),
        (N'asset_name',           CAST(a.asset_name AS NVARCHAR(MAX))),
        (N'asset_category_id',    CAST(a.asset_category_id AS NVARCHAR(MAX))),
        (N'asset_subcategory_id', CAST(a.asset_subcategory_id AS NVARCHAR(MAX))),
        (N'asset_type_id',        CAST(a.asset_type_id AS NVARCHAR(MAX))),
        (N'organization_id',      CAST(a.organization_id AS NVARCHAR(MAX))),
        (N'location_id',          CAST(a.location_id AS NVARCHAR(MAX))),
        (N'owner_id',             CAST(a.owner_id AS NVARCHAR(MAX))),
        (N'purchase_dt',          CONVERT(NVARCHAR(MAX), a.purchase_dt, 23)),
        (N'warranty_expiry_dt',   CONVERT(NVARCHAR(MAX), a.warranty_expiry_dt, 23)),
        (N'amc_expiry_dt',        CONVERT(NVARCHAR(MAX), a.amc_expiry_dt, 23)),
        (N'criticality_id',       CAST(a.criticality_id AS NVARCHAR(MAX))),
        (N'remarks',              CAST(a.remarks AS NVARCHAR(MAX))),
        (N'entered_by',           CAST(a.entered_by AS NVARCHAR(MAX))),
        (N'entered_dt',           CONVERT(NVARCHAR(MAX), a.entered_dt, 126)),
        (N'updated_by',           CAST(a.updated_by AS NVARCHAR(MAX))),
        (N'updated_dt',           CONVERT(NVARCHAR(MAX), a.updated_dt, 126))
     ) AS c(column_name, val)
      JOIN grac_practice.asset_field_definition d ON d.storage_kind = N'COLUMN' AND d.column_name = c.column_name
     WHERE a.asset_id = @asset_id AND c.val IS NOT NULL
    UNION ALL
    SELECT v.field_definition_id, d.field_key, v.value_text
      FROM grac_practice.asset_field_value v
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id
     WHERE v.asset_id = @asset_id
    UNION ALL
    SELECT d.field_definition_id, d.field_key, s.status_code
      FROM grac_practice.organization_dependency_asset a
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
      JOIN grac_practice.asset_field_definition d ON d.field_key = N'asset_status'
     WHERE a.asset_id = @asset_id;
GO

-- fn_asset_contract_readiness (434) body, verbatim
CREATE OR ALTER FUNCTION grac_practice.fn_asset_contract_readiness (@version_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT CAST(N'MISSING_ROLE' AS NVARCHAR(30)) AS WarningCode, r.role_code AS RoleCode,
           CAST(CONCAT(N'No validated ', r.role_name, N' contact is effective on ', CONVERT(NVARCHAR(10), d.on_date, 23), N'.')
                AS NVARCHAR(400)) AS Warning
      FROM grac_practice.asset_contract_version v
     CROSS APPLY (SELECT ISNULL(v.effective_start, CAST(SYSUTCDATETIME() AS DATE)) AS on_date) d
      JOIN grac_practice.asset_contract_contact_role r ON r.is_mandatory = 1 AND r.is_active = 1
     WHERE v.version_id = @version_id
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_contact m
                         JOIN grac_practice.organization_employee e ON e.employee_id = m.employee_id
                        WHERE m.contract_id = v.contract_id AND m.role_code = r.role_code AND m.status = N'ACTIVE'
                          AND (m.version_id IS NULL OR m.version_id = v.version_id)
                          AND m.effective_start <= d.on_date
                          AND ISNULL(m.effective_end, CAST('9999-12-31' AS DATE)) >= d.on_date
                          AND e.status = N'Active')
    UNION ALL
    SELECT CAST(N'INACTIVE_USER' AS NVARCHAR(30)), m.role_code,
           CAST(CONCAT(e.employee_name, N' (', r.role_name, N') is not an active user of the contract vendor.') AS NVARCHAR(400))
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.asset_contract c ON c.contract_id = v.contract_id
      JOIN grac_practice.asset_contract_contact m
        ON m.contract_id = v.contract_id AND (m.version_id IS NULL OR m.version_id = v.version_id)
      JOIN grac_practice.asset_contract_contact_role r ON r.role_code = m.role_code
      JOIN grac_practice.organization_employee e ON e.employee_id = m.employee_id
     WHERE v.version_id = @version_id AND m.status IN (N'ACTIVE', N'PENDING_VALIDATION')
       AND ISNULL(m.effective_end, CAST('9999-12-31' AS DATE)) >= CAST(SYSUTCDATETIME() AS DATE)
       AND (e.status <> N'Active' OR ISNULL(e.provider_vendor_id, -1) <> c.vendor_id)
    UNION ALL
    SELECT CAST(N'PENDING_VALIDATION' AS NVARCHAR(30)), m.role_code,
           CAST(CONCAT(e.employee_name, N' (', r.role_name, N') is pending validation and will not be part of the approved version.')
                AS NVARCHAR(400))
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.asset_contract_contact m
        ON m.contract_id = v.contract_id AND (m.version_id IS NULL OR m.version_id = v.version_id)
      JOIN grac_practice.asset_contract_contact_role r ON r.role_code = m.role_code
      JOIN grac_practice.organization_employee e ON e.employee_id = m.employee_id
     WHERE v.version_id = @version_id AND m.status = N'PENDING_VALIDATION';
GO

-- sp_asset_register_save (431) body, verbatim
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_register_save
    @organization_id         BIGINT,
    @asset_id                BIGINT         = NULL,
    @asset_type_id           INT            = NULL,
    @values_json             NVARCHAR(MAX)  = N'{}',
    @hidden_decisions_json   NVARCHAR(MAX)  = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @out_asset_id            BIGINT         = NULL OUTPUT,
    @out_result              NVARCHAR(20)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    IF ISJSON(ISNULL(@values_json, N'')) <> 1 SET @values_json = N'{}';
    IF ISJSON(ISNULL(@hidden_decisions_json, N'')) <> 1 SET @hidden_decisions_json = N'{}';
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54950, 'Organization not found.', 1;

    -- ---------------------------------------------------------- the record
    DECLARE @found BIT = 0, @rv BIGINT, @old_type INT, @template_id BIGINT;
    IF @asset_id IS NOT NULL
    BEGIN
        SELECT @found = 1, @rv = CONVERT(BIGINT, record_version), @old_type = asset_type_id, @template_id = template_id
          FROM grac_practice.organization_dependency_asset
         WHERE asset_id = @asset_id AND organization_id = @organization_id;
        IF @found = 0 THROW 54951, 'Asset not found for this organization.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54952, 'This asset was changed by someone else. Reload it and try again.', 1;
        IF @old_type IS NOT NULL AND @asset_type_id IS NOT NULL AND @asset_type_id <> @old_type
            THROW 54953, 'The asset type of a registered asset cannot change.', 1;
        SET @asset_type_id = ISNULL(@old_type, @asset_type_id);
    END
    IF @asset_type_id IS NULL
       OR (ISNULL(@old_type, -1) <> @asset_type_id
           AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_taxonomy_selectable() WHERE NodeKind = N'TYPE' AND NodeId = @asset_type_id))
        THROW 54954, 'Select an asset type that is active and in effect.', 1;

    -- Template: the version the asset was registered with, else the Active one (5.2.1).
    IF @template_id IS NULL
        SELECT @template_id = template_id FROM grac_practice.asset_form_template
         WHERE organization_id = @organization_id AND asset_type_id = @asset_type_id AND is_active_version = 1;
    IF @template_id IS NULL
        THROW 54955, 'This asset type has no Active form template. Activate one on Asset Form Templates first.', 1;

    DECLARE @sub_id INT, @cat_id INT;
    SELECT @sub_id = t.subcategory_id, @cat_id = s.asset_category_id
      FROM grac_practice.dependency_asset_type_master t
      JOIN grac_practice.dependency_asset_subcategory_master s ON s.subcategory_id = t.subcategory_id
     WHERE t.asset_type_id = @asset_type_id;

    -- ---------------------------------------------------------- template fields
    DECLARE @tf TABLE (
        field_definition_id INT PRIMARY KEY, field_key NVARCHAR(100) NOT NULL UNIQUE, label NVARCHAR(200) NOT NULL,
        data_type NVARCHAR(30) NOT NULL, lookup_source NVARCHAR(100) NULL, storage_kind NVARCHAR(10) NOT NULL,
        column_name NVARCHAR(128) NULL, editable BIT NOT NULL, default_value NVARCHAR(400) NULL,
        hidden_behavior NVARCHAR(10) NOT NULL, is_multi BIT NOT NULL);
    INSERT @tf
    SELECT d.field_definition_id, d.field_key, d.display_label, d.data_type_code, d.lookup_source, d.storage_kind, d.column_name,
           CASE WHEN dt.is_user_entered = 1 AND f.is_read_only = 0 AND d.storage_kind <> N'SYSTEM' AND d.is_system_field = 0
                 AND ISNULL(d.column_name, N'') NOT IN (N'organization_id', N'asset_type_id', N'asset_subcategory_id', N'asset_category_id')
                THEN 1 ELSE 0 END,
           f.default_value, f.hidden_value_behavior,
           CASE WHEN d.data_type_code IN (N'MULTI_SELECT', N'MULTI_USER') THEN 1 ELSE 0 END
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      JOIN grac_practice.asset_field_data_type_master dt ON dt.data_type_code = d.data_type_code
     WHERE f.template_id = @template_id;

    -- ---------------------------------------------------------- stored, submitted, effective
    DECLARE @stored TABLE (field_key NVARCHAR(100) PRIMARY KEY, val NVARCHAR(MAX) NULL);
    IF @asset_id IS NOT NULL
        INSERT @stored (field_key, val) SELECT FieldKey, Value FROM grac_practice.fn_asset_stored_values(@asset_id);

    DECLARE @sub TABLE (field_key NVARCHAR(100) PRIMARY KEY, val NVARCHAR(MAX) NULL);
    INSERT @sub (field_key, val)
    SELECT j.[key],
           CASE WHEN j.[type] = 4 THEN CASE WHEN EXISTS (SELECT 1 FROM OPENJSON(j.[value])) THEN j.[value] END
                WHEN j.[type] = 0 THEN NULL
                ELSE NULLIF(LTRIM(RTRIM(j.[value])), N'') END
      FROM OPENJSON(@values_json) j
      -- OPENJSON's [key] is Latin1_General_BIN2; compare in the database collation (Msg 468).
      JOIN @tf t ON t.field_key = j.[key] COLLATE DATABASE_DEFAULT AND t.editable = 1;
    -- New asset: template defaults for fields not supplied.
    IF @asset_id IS NULL
        INSERT @sub (field_key, val)
        SELECT t.field_key, t.default_value FROM @tf t
         WHERE t.editable = 1 AND t.default_value IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @sub s WHERE s.field_key = t.field_key);

    DECLARE @eff TABLE (field_key NVARCHAR(100) PRIMARY KEY, val NVARCHAR(MAX) NULL, submitted BIT NOT NULL);
    INSERT @eff (field_key, val, submitted)
    SELECT t.field_key,
           CASE WHEN s.field_key IS NOT NULL THEN s.val ELSE st.val END,
           CASE WHEN s.field_key IS NOT NULL AND ISNULL(s.val, N'') <> ISNULL(st.val, N'') THEN 1 ELSE 0 END
      FROM @tf t
      LEFT JOIN @sub s ON s.field_key = t.field_key
      LEFT JOIN @stored st ON st.field_key = t.field_key;
    -- Taxonomy and legal entity follow the asset type and the organization.
    UPDATE e SET val = CASE t.column_name WHEN N'asset_type_id' THEN CAST(@asset_type_id AS NVARCHAR(40))
                                          WHEN N'asset_subcategory_id' THEN CAST(@sub_id AS NVARCHAR(40))
                                          WHEN N'asset_category_id' THEN CAST(@cat_id AS NVARCHAR(40))
                                          ELSE CAST(@organization_id AS NVARCHAR(40)) END
      FROM @eff e JOIN @tf t ON t.field_key = e.field_key
     WHERE t.column_name IN (N'asset_type_id', N'asset_subcategory_id', N'asset_category_id', N'organization_id');

    -- ---------------------------------------------------------- rules (5.1.14)
    DECLARE @eval_json NVARCHAR(MAX) = N'{' + ISNULL((
        SELECT STRING_AGG(CAST(CONCAT(N'"', STRING_ESCAPE(e.field_key, 'json'), N'":',
                    CASE WHEN t.is_multi = 1 AND ISJSON(e.val) = 1 THEN e.val
                         ELSE N'"' + STRING_ESCAPE(e.val, 'json') + N'"' END) AS NVARCHAR(MAX)), N',')
          FROM @eff e JOIN @tf t ON t.field_key = e.field_key
         WHERE e.val IS NOT NULL), N'') + N'}';
    DECLARE @ev TABLE (field_key NVARCHAR(100) PRIMARY KEY, is_visible INT NOT NULL, is_mandatory INT NOT NULL);
    INSERT @ev (field_key, is_visible, is_mandatory)
    SELECT FieldKey, IsVisible, IsMandatory FROM grac_practice.fn_asset_form_evaluate(@template_id, @eval_json);

    DECLARE @issues TABLE (severity NVARCHAR(10) NOT NULL, field_key NVARCHAR(100) NULL, message NVARCHAR(500) NOT NULL);

    -- Hidden fields holding a value (5.1.14): RETAIN keeps it; CLEAR / MIGRATE need a decision.
    DECLARE @decisions TABLE (field_key NVARCHAR(100) PRIMARY KEY, decision NVARCHAR(10) NOT NULL);
    INSERT @decisions (field_key, decision)
    SELECT j.[key], UPPER(j.[value]) FROM OPENJSON(@hidden_decisions_json) j WHERE UPPER(j.[value]) IN (N'RETAIN', N'CLEAR');
    INSERT @issues (severity, field_key, message)
    SELECT N'DECISION', t.field_key,
           CONCAT(N'"', t.label, N'" is hidden by the form rules but holds a value. Choose whether to keep it or clear it.')
      FROM @tf t
      JOIN @ev v ON v.field_key = t.field_key AND v.is_visible = 0
      JOIN @stored st ON st.field_key = t.field_key AND st.val IS NOT NULL
     WHERE t.editable = 1 AND t.hidden_behavior IN (N'CLEAR', N'MIGRATE')
       AND NOT EXISTS (SELECT 1 FROM @decisions d WHERE d.field_key = t.field_key);
    -- Hidden fields: never take a newly typed value; keep or clear the stored one.
    UPDATE e
       SET val = CASE WHEN ISNULL(d.decision, CASE WHEN t.hidden_behavior = N'RETAIN' THEN N'RETAIN' END) = N'CLEAR' THEN NULL ELSE st.val END,
           submitted = CASE WHEN ISNULL(d.decision, N'') = N'CLEAR' AND st.val IS NOT NULL THEN 1 ELSE 0 END
      FROM @eff e
      JOIN @tf t ON t.field_key = e.field_key AND t.editable = 1
      JOIN @ev v ON v.field_key = e.field_key AND v.is_visible = 0
      LEFT JOIN @stored st ON st.field_key = e.field_key
      LEFT JOIN @decisions d ON d.field_key = e.field_key;

    -- ---------------------------------------------------------- mandatory
    INSERT @issues (severity, field_key, message)
    SELECT N'ERROR', t.field_key, CONCAT(N'"', t.label, N'" is required.')
      FROM @tf t
      JOIN @ev v ON v.field_key = t.field_key AND v.is_visible = 1 AND v.is_mandatory = 1
      JOIN @eff e ON e.field_key = t.field_key
     WHERE t.editable = 1 AND e.val IS NULL;

    -- ---------------------------------------------------------- data types (changed values)
    INSERT @issues (severity, field_key, message)
    SELECT N'ERROR', t.field_key,
           CONCAT(N'"', t.label, N'" ', CASE
               WHEN t.data_type IN (N'DECIMAL', N'CURRENCY') THEN N'must be a number.'
               WHEN t.data_type = N'PERCENT' THEN N'must be a number from 0 to 100.'
               WHEN t.data_type = N'QUANTITY_UNIT' THEN N'must start with a number (for example "12 months").'
               WHEN t.data_type = N'DATE' THEN N'must be a date (yyyy-mm-dd).'
               WHEN t.data_type = N'YES_NO' THEN N'must be Yes or No.'
               ELSE N'is not valid.' END)
      FROM @tf t JOIN @eff e ON e.field_key = t.field_key
     WHERE t.editable = 1 AND e.submitted = 1 AND e.val IS NOT NULL
       AND (   (t.data_type IN (N'DECIMAL', N'CURRENCY') AND TRY_CONVERT(DECIMAL(38, 6), e.val) IS NULL)
            OR (t.data_type = N'PERCENT' AND ISNULL(TRY_CONVERT(DECIMAL(38, 6), e.val), -1) NOT BETWEEN 0 AND 100)
            OR (t.data_type = N'QUANTITY_UNIT' AND TRY_CONVERT(DECIMAL(38, 6), LEFT(e.val, CHARINDEX(N' ', e.val + N' ') - 1)) IS NULL)
            OR (t.data_type = N'DATE' AND TRY_CONVERT(DATE, e.val, 23) IS NULL)
            OR (t.data_type = N'YES_NO' AND e.val NOT IN (N'Yes', N'No')));

    -- ---------------------------------------------------------- lookup values (changed values)
    DECLARE @elems TABLE (field_key NVARCHAR(100) NOT NULL, elem NVARCHAR(400) NOT NULL);
    INSERT @elems (field_key, elem)
    SELECT e.field_key, LEFT(LTRIM(RTRIM(a.[value])), 400)
      FROM @eff e JOIN @tf t ON t.field_key = e.field_key
     CROSS APPLY OPENJSON(CASE WHEN t.is_multi = 1 AND ISJSON(e.val) = 1 THEN e.val
                               ELSE N'["' + STRING_ESCAPE(e.val, 'json') + N'"]' END) a
     WHERE t.editable = 1 AND e.submitted = 1 AND e.val IS NOT NULL AND t.lookup_source IS NOT NULL
       AND a.[value] IS NOT NULL AND LTRIM(RTRIM(a.[value])) <> N'';

    INSERT @issues (severity, field_key, message)
    SELECT DISTINCT N'ERROR', t.field_key,
           CASE WHEN t.lookup_source = N'MASTER:CONTRACT'
                THEN CONCAT(N'"', t.label, N'" is linked once contracts are available (Phase 5); leave it empty for now.')
                ELSE CONCAT(N'"', t.label, N'" has a value that is not in its list: ', x.elem, N'.') END
      FROM @elems x JOIN @tf t ON t.field_key = x.field_key
     WHERE t.lookup_source NOT IN (N'MASTER:COUNTRY', N'MASTER:CURRENCY')
       AND t.lookup_source NOT LIKE N'STATE:%'
       AND NOT (t.lookup_source LIKE N'OPTION:%' AND EXISTS (
                SELECT 1 FROM grac_practice.fn_asset_field_options(@organization_id) o
                 WHERE o.OptionGroup = N'asset_field.' + SUBSTRING(t.lookup_source, 8, 100) AND o.OptionValue = x.elem))
       AND NOT (t.lookup_source LIKE N'MASTER:%' AND t.lookup_source <> N'MASTER:CONTRACT' AND EXISTS (
                SELECT 1 FROM grac_practice.fn_asset_master_lookup(@organization_id) m
                 WHERE m.Source = t.lookup_source AND m.Value = x.elem))
       -- CIA ratings: the levels of the Active valuation configuration (same mapping as 422 / 423 template get).
       AND NOT (t.lookup_source = N'CONFIG:CIA_SCALE' AND EXISTS (
                SELECT 1 FROM grac_practice.asset_valuation_config c
                  JOIN grac_practice.asset_cia_scale_level l ON l.config_id = c.config_id
                 WHERE c.organization_id = @organization_id AND c.is_active_version = 1
                   AND CAST(l.score AS NVARCHAR(160)) = x.elem
                   AND l.dimension_code = CASE t.field_key WHEN N'confidentiality_rating' THEN N'C'
                                                           WHEN N'integrity_rating' THEN N'I'
                                                           WHEN N'availability_rating' THEN N'A' END));

    -- ---------------------------------------------------------- cross-field rules (5.1 / 5.1.16)
    DECLARE @num TABLE (field_key NVARCHAR(100) PRIMARY KEY, n DECIMAL(38, 6) NULL, d DATE NULL);
    INSERT @num (field_key, n, d)
    SELECT e.field_key,
           TRY_CONVERT(DECIMAL(38, 6), CASE WHEN t.data_type = N'QUANTITY_UNIT' THEN LEFT(e.val, CHARINDEX(N' ', e.val + N' ') - 1) ELSE e.val END),
           CASE WHEN t.data_type = N'DATE' THEN TRY_CONVERT(DATE, e.val, 23) END
      FROM @eff e JOIN @tf t ON t.field_key = e.field_key WHERE e.val IS NOT NULL;

    INSERT @issues (severity, field_key, message)
    SELECT r.severity, r.field_key, r.message
      FROM grac_practice.asset_field_validation_rule r
      JOIN @eff e ON e.field_key = r.field_key
      JOIN @num a ON a.field_key = r.field_key
      LEFT JOIN @eff eo ON eo.field_key = r.other_field_key
      LEFT JOIN @num b ON b.field_key = r.other_field_key
      LEFT JOIN @stored st ON st.field_key = r.field_key
     WHERE r.is_active = 1
       AND (e.submitted = 1 OR ISNULL(eo.submitted, 0) = 1)
       AND (   (r.rule_code = N'NOT_FUTURE'       AND a.d > @today)
            OR (r.rule_code = N'ON_OR_AFTER'      AND a.d < b.d)
            OR (r.rule_code = N'AFTER'            AND a.d <= b.d)
            OR (r.rule_code = N'NON_NEGATIVE'     AND a.n < 0)
            OR (r.rule_code = N'POSITIVE'         AND a.n <= 0)
            OR (r.rule_code = N'NOT_GREATER_THAN' AND a.n > b.n)
            OR (r.rule_code = N'NOT_BELOW_STORED' AND a.n < TRY_CONVERT(DECIMAL(38, 6), st.val)));

    -- Model must belong to the selected make and asset type (5.1.16).
    DECLARE @model_val NVARCHAR(MAX) = (SELECT val FROM @eff WHERE field_key = N'model'),
            @make_val  NVARCHAR(MAX) = (SELECT val FROM @eff WHERE field_key = N'manufacturer_make');
    DECLARE @model_id BIGINT = TRY_CONVERT(BIGINT, @model_val), @m_make INT, @m_type INT;
    IF @model_id IS NOT NULL
    BEGIN
        SELECT @m_make = make_id, @m_type = asset_type_id FROM grac_practice.asset_model WHERE model_id = @model_id;
        IF @m_type IS NOT NULL AND @m_type <> @asset_type_id
            INSERT @issues (severity, field_key, message) VALUES (N'ERROR', N'model', N'The selected model belongs to a different asset type.');
        IF @m_make IS NOT NULL AND (@make_val IS NULL OR TRY_CONVERT(INT, @make_val) <> @m_make)
            INSERT @issues (severity, field_key, message) VALUES (N'ERROR', N'model', N'The selected model does not belong to the selected make.');
    END

    -- Serial uniqueness within make / model: warning (no blocking policy configured).
    DECLARE @serial NVARCHAR(MAX) = (SELECT val FROM @eff WHERE field_key = N'serial_number' AND submitted = 1);
    IF @serial IS NOT NULL AND EXISTS (
        SELECT 1 FROM grac_practice.asset_field_value sv
          JOIN grac_practice.asset_field_definition sd ON sd.field_definition_id = sv.field_definition_id AND sd.field_key = N'serial_number'
          JOIN grac_practice.organization_dependency_asset a2 ON a2.asset_id = sv.asset_id AND a2.organization_id = @organization_id
          LEFT JOIN grac_practice.asset_field_value mv ON mv.asset_id = sv.asset_id
               AND mv.field_definition_id = (SELECT field_definition_id FROM grac_practice.asset_field_definition WHERE field_key = N'model')
          LEFT JOIN grac_practice.asset_field_value kv ON kv.asset_id = sv.asset_id
               AND kv.field_definition_id = (SELECT field_definition_id FROM grac_practice.asset_field_definition WHERE field_key = N'manufacturer_make')
         WHERE sv.value_text = @serial AND sv.asset_id <> ISNULL(@asset_id, -1)
           AND ISNULL(mv.value_text, N'') = ISNULL(@model_val, N'') AND ISNULL(kv.value_text, N'') = ISNULL(@make_val, N''))
        INSERT @issues (severity, field_key, message)
        VALUES (N'WARNING', N'serial_number', N'Another asset of this make and model already has this serial number.');

    -- 430: installed firmware / OS (5.1.16 "approved mapping or explicit exception", 4.8)
    -- An ERROR unless an active technology exception covers the asset (or its
    -- model) and the version; it was a warning in 428 until exceptions existed (D14, D19).
    DECLARE @fw BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'firmware_version' AND submitted = 1)),
            @os BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'operating_system' AND submitted = 1));
    DECLARE @hw_rev NVARCHAR(400) = LEFT((SELECT val FROM @eff WHERE field_key = N'hardware_revision'), 400);
    IF @fw IS NOT NULL AND @model_id IS NOT NULL
       AND grac_practice.fn_asset_tech_compatible(@organization_id, N'FIRMWARE', @fw, @asset_type_id, @model_id, @hw_rev) = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_tech_exception_active(@organization_id, @asset_id, @model_id, N'FIRMWARE', @fw))
        INSERT @issues (severity, field_key, message)
        VALUES (N'ERROR', N'firmware_version', N'This firmware has no approved compatibility record for the model. Choose a compatible release, or save without it and request a technology exception on the Technology tab.');
    IF @os IS NOT NULL AND @model_id IS NOT NULL
       AND grac_practice.fn_asset_tech_compatible(@organization_id, N'OS', @os, @asset_type_id, @model_id, NULL) = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_tech_exception_active(@organization_id, @asset_id, @model_id, N'OS', @os))
        INSERT @issues (severity, field_key, message)
        VALUES (N'ERROR', N'operating_system', N'This operating system has no approved compatibility record for the model. Choose a compatible release, or save without it and request a technology exception on the Technology tab.');

    -- Asset name is unique in the organization (existing constraint uq_pm_org_asset_name).
    DECLARE @name NVARCHAR(220) = LEFT((SELECT val FROM @eff WHERE field_key = N'asset_name'), 220);
    IF @name IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset
                                      WHERE organization_id = @organization_id AND asset_name = @name AND asset_id <> ISNULL(@asset_id, -1))
        INSERT @issues (severity, field_key, message) VALUES (N'ERROR', N'asset_name', N'Another asset in this organization already has this name.');

    -- ---------------------------------------------------------- stop or write
    IF EXISTS (SELECT 1 FROM @issues WHERE severity IN (N'ERROR', N'DECISION'))
    BEGIN
        SET @out_result = CASE WHEN EXISTS (SELECT 1 FROM @issues WHERE severity = N'ERROR') THEN N'INVALID' ELSE N'NEEDS_DECISION' END;
        SET @out_asset_id = @asset_id;
        SELECT severity AS Severity, field_key AS FieldKey, message AS Message FROM @issues
         ORDER BY CASE severity WHEN N'ERROR' THEN 0 WHEN N'DECISION' THEN 1 ELSE 2 END, field_key;
        RETURN;
    END

    DECLARE @col TABLE (column_name NVARCHAR(128) PRIMARY KEY, val NVARCHAR(MAX) NULL);
    INSERT @col (column_name, val)
    SELECT t.column_name, e.val FROM @tf t JOIN @eff e ON e.field_key = t.field_key
     WHERE t.storage_kind = N'COLUMN' AND t.editable = 1;
    DECLARE @in_tpl TABLE (column_name NVARCHAR(128) PRIMARY KEY);
    INSERT @in_tpl (column_name) SELECT column_name FROM @col;

    DECLARE @active_rs INT = (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
                               WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
    DECLARE @draft_id INT = grac_practice.fn_get_entity_status_id(N'Asset', N'DRAFT');
    DECLARE @before NVARCHAR(MAX) = (SELECT field_key AS fieldKey, val AS value FROM @stored FOR JSON PATH);
    DECLARE @to_status_id INT, @log_id BIGINT;

    BEGIN TRAN;
    IF @asset_id IS NULL
    BEGIN
        INSERT grac_practice.organization_dependency_asset
            (organization_id, asset_name, asset_category_id, asset_subcategory_id, asset_type_id, owner_id, location_id,
             purchase_dt, warranty_expiry_dt, amc_expiry_dt, criticality_id, remarks, status, record_status_id,
             lifecycle_status, template_id, current_status_id, entered_by)
        SELECT @organization_id, @name, @cat_id, @sub_id, @asset_type_id,
               TRY_CONVERT(BIGINT, (SELECT val FROM @col WHERE column_name = N'owner_id')),
               TRY_CONVERT(BIGINT, (SELECT val FROM @col WHERE column_name = N'location_id')),
               TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'purchase_dt'), 23),
               TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'warranty_expiry_dt'), 23),
               TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'amc_expiry_dt'), 23),
               TRY_CONVERT(INT, (SELECT val FROM @col WHERE column_name = N'criticality_id')),
               (SELECT val FROM @col WHERE column_name = N'remarks'),
               N'Active', ISNULL(@active_rs, 1), p.legacy_lifecycle_status, @template_id, @draft_id, @actor
          FROM grac_practice.asset_lifecycle_status_phase p WHERE p.status_code = N'DRAFT';
        SET @out_asset_id = SCOPE_IDENTITY();
        EXEC grac_practice.sp_pm_state_transition
             @entity_type = N'Asset', @entity_id = @out_asset_id,
             @from_status_code = NULL, @to_status_code = N'DRAFT',
             @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
             @reason_code = N'REGISTERED', @reason_text = NULL,
             @to_status_id = @to_status_id OUTPUT, @transition_log_id = @log_id OUTPUT;
    END
    ELSE
    BEGIN
        -- Only columns whose field is on the template change.
        UPDATE a
           SET asset_name = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'asset_name') THEN @name ELSE a.asset_name END,
               asset_category_id = @cat_id, asset_subcategory_id = @sub_id, asset_type_id = @asset_type_id,
               owner_id = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'owner_id')
                               THEN TRY_CONVERT(BIGINT, (SELECT val FROM @col WHERE column_name = N'owner_id')) ELSE a.owner_id END,
               location_id = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'location_id')
                                  THEN TRY_CONVERT(BIGINT, (SELECT val FROM @col WHERE column_name = N'location_id')) ELSE a.location_id END,
               purchase_dt = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'purchase_dt')
                                  THEN TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'purchase_dt'), 23) ELSE a.purchase_dt END,
               warranty_expiry_dt = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'warranty_expiry_dt')
                                         THEN TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'warranty_expiry_dt'), 23) ELSE a.warranty_expiry_dt END,
               amc_expiry_dt = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'amc_expiry_dt')
                                    THEN TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'amc_expiry_dt'), 23) ELSE a.amc_expiry_dt END,
               criticality_id = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'criticality_id')
                                     THEN TRY_CONVERT(INT, (SELECT val FROM @col WHERE column_name = N'criticality_id')) ELSE a.criticality_id END,
               remarks = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'remarks')
                              THEN (SELECT val FROM @col WHERE column_name = N'remarks') ELSE a.remarks END,
               template_id = @template_id,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
          FROM grac_practice.organization_dependency_asset a
         WHERE a.asset_id = @asset_id;
        SET @out_asset_id = @asset_id;
    END

    -- VALUE fields on the template: clear the empty ones, upsert the rest.
    DELETE v
      FROM grac_practice.asset_field_value v
      JOIN @tf t ON t.field_definition_id = v.field_definition_id AND t.storage_kind = N'VALUE' AND t.editable = 1
      JOIN @eff e ON e.field_key = t.field_key
     WHERE v.asset_id = @out_asset_id AND e.val IS NULL;
    MERGE grac_practice.asset_field_value AS tgt
    USING (
        SELECT t.field_definition_id, e.val,
               TRY_CONVERT(DECIMAL(38, 6), CASE WHEN t.data_type = N'QUANTITY_UNIT' THEN LEFT(e.val, CHARINDEX(N' ', e.val + N' ') - 1) ELSE e.val END) AS n,
               CASE WHEN t.data_type = N'DATE' THEN TRY_CONVERT(DATE, e.val, 23) END AS d,
               CASE WHEN t.lookup_source LIKE N'MASTER:%' AND t.is_multi = 0 THEN TRY_CONVERT(BIGINT, e.val) END AS r
          FROM @tf t JOIN @eff e ON e.field_key = t.field_key
         WHERE t.storage_kind = N'VALUE' AND t.editable = 1 AND e.val IS NOT NULL
    ) AS src
    ON tgt.asset_id = @out_asset_id AND tgt.field_definition_id = src.field_definition_id
    WHEN MATCHED AND tgt.value_text <> src.val THEN
        UPDATE SET value_text = src.val, value_number = src.n, value_date = src.d, value_ref = src.r,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (asset_id, field_definition_id, value_text, value_number, value_date, value_ref, entered_by)
        VALUES (@out_asset_id, src.field_definition_id, src.val, src.n, src.d, src.r, @actor);

    -- 430: installed firmware / OS history (BRD 4.6) when the form changes them.
    DECLARE @fw_old BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @stored WHERE field_key = N'firmware_version')),
            @fw_new BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'firmware_version')),
            @os_old BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @stored WHERE field_key = N'operating_system')),
            @os_new BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'operating_system'));
    DECLARE @patch_old NVARCHAR(100) = LEFT((SELECT val FROM @stored WHERE field_key = N'os_build_patch_level'), 100),
            @patch_new NVARCHAR(100) = LEFT((SELECT val FROM @eff WHERE field_key = N'os_build_patch_level'), 100);
    DECLARE @fw_on_tpl BIT = CASE WHEN EXISTS (SELECT 1 FROM @tf WHERE field_key = N'firmware_version' AND editable = 1) THEN 1 ELSE 0 END,
            @os_on_tpl BIT = CASE WHEN EXISTS (SELECT 1 FROM @tf WHERE field_key = N'operating_system' AND editable = 1) THEN 1 ELSE 0 END;
    DECLARE @inst_id BIGINT, @form_source NVARCHAR(100) = N'Asset form';
    IF @fw_on_tpl = 1 AND @fw_new IS NOT NULL AND ISNULL(@fw_old, -1) <> @fw_new
    BEGIN
        EXEC grac_practice.sp_asset_tech_install_apply
             @organization_id = @organization_id, @asset_id = @out_asset_id, @kind = N'FIRMWARE', @release_id = @fw_new,
             @installed_date = @today, @source = @form_source, @update_value = 0, @actor = @actor,
             @out_installation_id = @inst_id OUTPUT;
    END
    ELSE IF @fw_on_tpl = 1 AND @fw_new IS NULL AND @fw_old IS NOT NULL
        UPDATE grac_practice.asset_firmware_installation SET is_current = 0 WHERE asset_id = @out_asset_id AND is_current = 1;
    IF @os_on_tpl = 1 AND @os_new IS NOT NULL AND (ISNULL(@os_old, -1) <> @os_new OR ISNULL(@patch_old, N'') <> ISNULL(@patch_new, N''))
    BEGIN
        EXEC grac_practice.sp_asset_tech_install_apply
             @organization_id = @organization_id, @asset_id = @out_asset_id, @kind = N'OS', @release_id = @os_new,
             @build_patch_level = @patch_new, @installed_date = @today, @source = @form_source, @update_value = 0,
             @actor = @actor, @out_installation_id = @inst_id OUTPUT;
    END
    ELSE IF @os_on_tpl = 1 AND @os_new IS NULL AND @os_old IS NOT NULL
        UPDATE grac_practice.asset_os_installation SET is_current = 0 WHERE asset_id = @out_asset_id AND is_current = 1;

    -- 431: ownership / custody / location history and the acknowledgement it raises (5.3.2).
    DECLARE @assign_source NVARCHAR(100) = N'Asset form';
    EXEC grac_practice.sp_asset_assignment_snapshot
         @organization_id = @organization_id, @asset_id = @out_asset_id, @source = @assign_source,
         @raise_acknowledgement = 1, @actor = @actor;

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-register', @out_asset_id, CASE WHEN @asset_id IS NULL THEN N'ADD' ELSE N'SAVE' END,
            CASE WHEN @asset_id IS NULL THEN NULL ELSE @before END,
            (SELECT @template_id AS templateId,
                    (SELECT e.field_key AS fieldKey, e.val AS value FROM @eff e WHERE e.submitted = 1 FOR JSON PATH) AS changedValues
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SET @out_result = N'SAVED';
    SELECT severity AS Severity, field_key AS FieldKey, message AS Message FROM @issues ORDER BY field_key;
END
GO

-- sp_asset_lifecycle_transition (429) body, verbatim
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_lifecycle_transition
    @organization_id         BIGINT,
    @asset_id                BIGINT,
    @to_status_code          NVARCHAR(60),
    @reason_text             NVARCHAR(1000) = NULL,
    @reference_text          NVARCHAR(400)  = NULL,
    @evidence_text           NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @out_change_id           BIGINT         = NULL OUTPUT,
    @out_result              NVARCHAR(20)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @to_status_code = UPPER(LTRIM(RTRIM(ISNULL(@to_status_code, N''))));
    SET @reason_text = NULLIF(LTRIM(RTRIM(@reason_text)), N'');
    SET @reference_text = NULLIF(LTRIM(RTRIM(@reference_text)), N'');
    SET @evidence_text = NULLIF(LTRIM(RTRIM(@evidence_text)), N'');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54970, 'Organization not found.', 1;

    DECLARE @found BIT = 0, @rv BIGINT, @from NVARCHAR(60), @template_id BIGINT, @owner_id BIGINT;
    SELECT @found = 1, @rv = CONVERT(BIGINT, a.record_version), @from = COALESCE(cs.status_code, ls.status_code),
           @template_id = a.template_id, @owner_id = a.owner_id
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
     WHERE a.asset_id = @asset_id AND a.organization_id = @organization_id;
    IF @found = 0 THROW 54971, 'Asset not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54972, 'This asset was changed by someone else. Reload it and try again.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_lifecycle_change WHERE asset_id = @asset_id AND change_status = N'PENDING_APPROVAL')
        THROW 54973, 'A lifecycle change for this asset is awaiting approval. Approve, reject or cancel it first.', 1;
    IF @from IN (N'DISPOSED', N'ARCHIVED') AND @to_status_code = N'ACTIVE'
        THROW 54975, 'A disposed or archived asset cannot return to Active (BRD 5.4.3 / 19.9). Register a replacement asset instead.', 1;

    DECLARE @rule_id INT, @req_reason BIT, @req_approval BIT, @ref_label NVARCHAR(200), @req_evidence BIT,
            @req_form BIT, @req_owner BIT;
    SELECT TOP 1 @rule_id = r.transition_rule_id, @req_reason = r.requires_reason, @req_approval = r.requires_approval,
           @ref_label = g.reference_label, @req_evidence = g.requires_evidence, @req_form = g.requires_registered_form,
           @req_owner = g.requires_owner
      FROM grac_practice.entity_state_transition_rule r
      JOIN grac_practice.asset_lifecycle_transition_gate g ON g.transition_rule_id = r.transition_rule_id
     WHERE r.entity_type = N'Asset' AND r.is_active = 1 AND r.actor_role_code IS NULL
       AND r.from_status_code = @from AND r.to_status_code = @to_status_code;
    IF @rule_id IS NULL
    BEGIN
        DECLARE @allowed NVARCHAR(1000) = (
            SELECT STRING_AGG(s.status_name, N', ') WITHIN GROUP (ORDER BY s.display_order)
              FROM grac_practice.entity_state_transition_rule r
              JOIN grac_practice.asset_lifecycle_transition_gate g ON g.transition_rule_id = r.transition_rule_id
              JOIN grac_practice.entity_status_master s ON s.entity_type = N'Asset' AND s.status_code = r.to_status_code
             WHERE r.entity_type = N'Asset' AND r.is_active = 1 AND r.actor_role_code IS NULL AND r.from_status_code = @from);
        DECLARE @from_name NVARCHAR(120) = (SELECT status_name FROM grac_practice.entity_status_master
                                             WHERE entity_type = N'Asset' AND status_code = @from);
        DECLARE @target_name NVARCHAR(120) = (SELECT status_name FROM grac_practice.entity_status_master
                                               WHERE entity_type = N'Asset' AND status_code = @to_status_code);
        DECLARE @msg NVARCHAR(2048) = CONCAT(N'This asset cannot move from ', ISNULL(@from_name, @from), N' to ',
            ISNULL(@target_name, @to_status_code), N'. Configured moves: ', ISNULL(@allowed, N'none'), N'.');
        THROW 54974, @msg, 1;
    END

    IF @req_form = 1 AND @template_id IS NULL
        THROW 54979, 'Open the asset and save it on its form template first, so its required fields are validated.', 1;
    IF @req_owner = 1 AND @owner_id IS NULL
        THROW 54980, 'Set the asset owner first (identity, owner and source validation).', 1;
    IF @req_reason = 1 AND @reason_text IS NULL
        THROW 54976, 'A reason is required for this change.', 1;
    IF @ref_label IS NOT NULL AND @reference_text IS NULL
    BEGIN
        DECLARE @ref_msg NVARCHAR(400) = CONCAT(N'Enter the ', LOWER(@ref_label), N'.');
        THROW 54977, @ref_msg, 1;
    END
    IF @req_evidence = 1 AND @evidence_text IS NULL
        THROW 54978, 'Evidence is required for this change (document number, report or link).', 1;

    DECLARE @log_id BIGINT;
    BEGIN TRAN;
    IF @req_approval = 1
    BEGIN
        INSERT grac_practice.asset_lifecycle_change
            (organization_id, asset_id, transition_rule_id, from_status_code, to_status_code, change_status,
             reason_text, reference_text, evidence_text, requested_by, requested_by_employee_id)
        VALUES (@organization_id, @asset_id, @rule_id, @from, @to_status_code, N'PENDING_APPROVAL',
                @reason_text, @reference_text, @evidence_text, @actor, @actor_employee_id);
        SET @out_change_id = SCOPE_IDENTITY();
        SET @out_result = N'PENDING_APPROVAL';
    END
    ELSE
    BEGIN
        EXEC grac_practice.sp_asset_lifecycle_apply
             @organization_id = @organization_id, @asset_id = @asset_id,
             @from_status_code = @from, @to_status_code = @to_status_code,
             @reason_code = N'LIFECYCLE', @reason_text = @reason_text,
             @actor_employee_id = @actor_employee_id, @actor = @actor, @out_log_id = @log_id OUTPUT;
        INSERT grac_practice.asset_lifecycle_change
            (organization_id, asset_id, transition_rule_id, from_status_code, to_status_code, change_status,
             reason_text, reference_text, evidence_text, requested_by, requested_by_employee_id, transition_log_id)
        VALUES (@organization_id, @asset_id, @rule_id, @from, @to_status_code, N'COMPLETED',
                @reason_text, @reference_text, @evidence_text, @actor, @actor_employee_id, @log_id);
        SET @out_change_id = SCOPE_IDENTITY();
        SET @out_result = N'COMPLETED';
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-lifecycle', @asset_id, CASE WHEN @req_approval = 1 THEN N'REQUEST' ELSE N'TRANSITION' END,
            (SELECT @from AS statusCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @out_change_id AS changeId, @to_status_code AS toStatusCode, @out_result AS result,
                    @reason_text AS reason, @reference_text AS reference, @evidence_text AS evidence, @log_id AS transitionLogId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @out_change_id AS ChangeId, @out_result AS Result,
           CASE WHEN @out_result = N'COMPLETED' THEN @to_status_code ELSE @from END AS StatusCode;
END
GO

-- sp_asset_contract_version_create (434) body, verbatim
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_version_create
    @organization_id   BIGINT,
    @contract_id       BIGINT,
    @version_type      NVARCHAR(20),
    @change_summary    NVARCHAR(2000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @version_type = UPPER(LTRIM(RTRIM(ISNULL(@version_type, N''))));
    SET @change_summary = NULLIF(LTRIM(RTRIM(@change_summary)), N'');

    DECLARE @found BIT = 0, @status NVARCHAR(20);
    SELECT @found = 1, @status = contract_status FROM grac_practice.asset_contract
     WHERE contract_id = @contract_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54511, 'Contract not found for this organization.', 1;
    EXEC grac_practice.sp_asset_contract_sync @organization_id = @organization_id, @contract_id = @contract_id, @actor = @actor;
    SELECT @status = contract_status FROM grac_practice.asset_contract WHERE contract_id = @contract_id;
    IF @status = N'TERMINATED'
        THROW 54520, 'The contract is terminated; its versions are kept for history only.', 1;
    IF @version_type NOT IN (N'INITIAL', N'RENEWAL', N'AMENDMENT', N'EXTENSION', N'VARIATION', N'CORRECTION', N'TERMINATION')
        THROW 54521, 'Select the version type.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_contract_version v
                 JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
                WHERE v.contract_id = @contract_id AND s.status_code IN (N'DRAFT', N'IN_REVIEW', N'PENDING_APPROVAL'))
        THROW 54522, 'The contract already has a version in progress; finish or withdraw it first.', 1;

    -- Base: the Active version, else the latest approved / ended one.
    DECLARE @base BIGINT = (SELECT TOP 1 v.version_id FROM grac_practice.asset_contract_version v
                              JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
                             WHERE v.contract_id = @contract_id AND s.status_code IN (N'ACTIVE', N'APPROVED', N'EXPIRED', N'SUPERSEDED')
                             ORDER BY CASE WHEN s.status_code = N'ACTIVE' THEN 0 ELSE 1 END, v.effective_start DESC, v.version_no DESC);
    IF @version_type = N'INITIAL' AND @base IS NOT NULL
        THROW 54521, 'The contract already has an approved version; choose renewal, amendment, extension, variation, correction or termination.', 1;
    IF @version_type <> N'INITIAL' AND @base IS NULL
        THROW 54521, 'The contract has no approved version yet; add an Initial version.', 1;
    IF @version_type <> N'INITIAL' AND @change_summary IS NULL
        THROW 54523, 'Enter the change summary / reason (required for every version after the initial one).', 1;
    -- Source of the copied terms: the base, or for a new Initial version the latest (rejected) draft.
    DECLARE @src BIGINT = ISNULL(@base, (SELECT TOP 1 version_id FROM grac_practice.asset_contract_version
                                          WHERE contract_id = @contract_id ORDER BY version_no DESC));
    DECLARE @no INT = ISNULL((SELECT MAX(version_no) FROM grac_practice.asset_contract_version WHERE contract_id = @contract_id), 0) + 1;
    DECLARE @version_id BIGINT;

    BEGIN TRAN;
    INSERT grac_practice.asset_contract_version
        (contract_id, organization_id, version_no, version_type, current_status_id, effective_start, effective_end, notice_date,
         decision_date, termination_date, contract_value, currency_code, tax_details, payment_terms, po_reference, invoice_reference,
         cost_allocation, renewal_terms, service_scope, sla_terms, support_hours, response_time, resolution_time, service_visits,
         contract_owner_id, procurement_owner_id, change_summary, created_by_employee_id, supersedes_version_id, entered_by)
    SELECT @contract_id, @organization_id, @no, @version_type, grac_practice.fn_get_entity_status_id(N'ContractVersion', N'DRAFT'),
           CASE @version_type WHEN N'RENEWAL' THEN DATEADD(DAY, 1, s.effective_end) WHEN N'TERMINATION' THEN NULL ELSE s.effective_start END,
           CASE WHEN @version_type IN (N'RENEWAL', N'TERMINATION') THEN NULL ELSE s.effective_end END,
           CASE WHEN @version_type IN (N'RENEWAL', N'TERMINATION') THEN NULL ELSE s.notice_date END,
           CASE WHEN @version_type IN (N'RENEWAL', N'TERMINATION') THEN NULL ELSE s.decision_date END,
           NULL, s.contract_value, s.currency_code, s.tax_details, s.payment_terms,
           CASE WHEN @version_type = N'RENEWAL' THEN NULL ELSE s.po_reference END,
           CASE WHEN @version_type = N'RENEWAL' THEN NULL ELSE s.invoice_reference END,
           s.cost_allocation, s.renewal_terms, s.service_scope, s.sla_terms, s.support_hours, s.response_time, s.resolution_time,
           s.service_visits, s.contract_owner_id, s.procurement_owner_id, @change_summary, @actor_employee_id, @base, @actor
      FROM grac_practice.asset_contract_version s
     WHERE s.version_id = @src;
    SET @version_id = SCOPE_IDENTITY();
    EXEC grac_practice.sp_asset_contract_version_move @version_id = @version_id, @from_code = NULL, @to_code = N'DRAFT',
         @reason_code = @version_type, @reason_text = @change_summary, @actor_employee_id = @actor_employee_id, @actor = @actor;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-contract-version', @version_id, N'CREATE', NULL,
            (SELECT @contract_id AS contractId, @no AS versionNo, @version_type AS versionType, @base AS supersedesVersionId,
                    @change_summary AS changeSummary FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @version_id AS VersionId, N'CREATED' AS Result;
END
GO

-- sp_asset_contract_version_check (434) body, verbatim
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_version_check
    @version_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @c BIGINT, @type NVARCHAR(20), @start DATE, @eff_end DATE, @term DATE, @value DECIMAL(18,2), @cur NVARCHAR(3),
            @owner BIGINT, @summary NVARCHAR(2000), @base BIGINT, @msg NVARCHAR(400), @other INT;
    SELECT @c = contract_id, @type = version_type, @start = effective_start, @eff_end = effective_end, @term = termination_date,
           @value = contract_value, @cur = currency_code, @owner = contract_owner_id, @summary = change_summary,
           @base = supersedes_version_id
      FROM grac_practice.asset_contract_version WHERE version_id = @version_id;

    IF @type = N'TERMINATION' AND @term IS NULL
        THROW 54547, 'Set the termination date of the termination version.', 1;
    IF @start IS NULL OR (@type <> N'TERMINATION' AND @eff_end IS NULL)
        THROW 54547, 'Set the effective start and end dates of the version.', 1;
    IF @owner IS NULL
        THROW 54547, 'Select the internal contract owner.', 1;
    IF @type <> N'INITIAL' AND @summary IS NULL
        THROW 54523, 'Enter the change summary / reason (required for every version after the initial one).', 1;
    IF (@value IS NULL AND @cur IS NOT NULL) OR (@value IS NOT NULL AND @cur IS NULL)
        THROW 54527, 'Enter the contract value together with its currency.', 1;
    IF @base IS NOT NULL AND @start < (SELECT effective_start FROM grac_practice.asset_contract_version WHERE version_id = @base)
        THROW 54534, 'The version cannot start before the version it replaces.', 1;

    SET @other = NULL;
    SELECT TOP 1 @other = x.version_no
      FROM grac_practice.asset_contract_version x
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = x.current_status_id
     WHERE x.contract_id = @c AND x.version_id <> @version_id AND x.version_type = N'TERMINATION'
       AND s.status_code IN (N'APPROVED', N'TERMINATED')
       AND (@type = N'TERMINATION' OR x.effective_start <= ISNULL(@eff_end, @start))
     ORDER BY x.effective_start;
    IF @other IS NOT NULL
    BEGIN
        SET @msg = CONCAT(N'Termination version ', @other, N' ends the contract on or before this version.');
        THROW 54533, @msg, 1;
    END

    -- Only one applicable version per date (no approved overlap is configured): an approved / active
    -- version other than the one this version replaces may not share a date with it.
    IF @type <> N'TERMINATION'
    BEGIN
        SET @other = NULL;
        SELECT TOP 1 @other = x.version_no
          FROM grac_practice.asset_contract_version x
          JOIN grac_practice.entity_status_master s ON s.entity_status_id = x.current_status_id
         WHERE x.contract_id = @c AND x.version_id <> @version_id AND x.version_id <> ISNULL(@base, -1)
           AND x.version_type <> N'TERMINATION' AND s.status_code IN (N'APPROVED', N'ACTIVE')
           AND x.effective_start <= @eff_end AND ISNULL(x.effective_end, CAST('9999-12-31' AS DATE)) >= @start
         ORDER BY x.effective_start;
        IF @other IS NOT NULL
        BEGIN
            SET @msg = CONCAT(N'The effective dates overlap version ', @other, N', which is approved or active. Only one version may apply on a date.');
            THROW 54532, @msg, 1;
        END
    END
END
GO

-- sp_asset_contract_version_compare (434) body, verbatim
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_version_compare
    @organization_id   BIGINT,
    @version_a         BIGINT,
    @version_b         BIGINT,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ca BIGINT = (SELECT contract_id FROM grac_practice.asset_contract_version WHERE version_id = @version_a AND organization_id = @organization_id),
            @cb BIGINT = (SELECT contract_id FROM grac_practice.asset_contract_version WHERE version_id = @version_b AND organization_id = @organization_id);
    IF @ca IS NULL OR @cb IS NULL OR @ca <> @cb OR @version_a = @version_b
        THROW 54543, 'Select two different versions of the same contract.', 1;

    SELECT c.contract_id AS ContractId, c.contract_number AS ContractNumber, c.contract_name AS ContractName,
           va.version_no AS VersionANo, vb.version_no AS VersionBNo,
           COALESCE((SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id = @actor_employee_id), @actor) AS GeneratedBy,
           SYSUTCDATETIME() AS GeneratedAt
      FROM grac_practice.asset_contract c
      JOIN grac_practice.asset_contract_version va ON va.version_id = @version_a
      JOIN grac_practice.asset_contract_version vb ON vb.version_id = @version_b
     WHERE c.contract_id = @ca;

    ;WITH f AS (
        SELECT x.version_id, k.FieldKey, k.Label, k.Ord, k.Val
          FROM grac_practice.asset_contract_version x
          JOIN grac_practice.asset_contract c ON c.contract_id = x.contract_id
          JOIN grac_practice.organization_dependency_vendor vd ON vd.vendor_id = c.vendor_id
          JOIN grac_practice.entity_status_master s ON s.entity_status_id = x.current_status_id
          LEFT JOIN grac_practice.organization_employee o1 ON o1.employee_id = x.contract_owner_id
          LEFT JOIN grac_practice.organization_employee o2 ON o2.employee_id = x.procurement_owner_id
         CROSS APPLY (VALUES
            (N'versionType',      N'Version type',          10, CAST(x.version_type AS NVARCHAR(2000))),
            (N'status',           N'Status',                20, CAST(s.status_name AS NVARCHAR(2000))),
            (N'effectiveStart',   N'Effective start',       30, CONVERT(NVARCHAR(10), x.effective_start, 23)),
            (N'effectiveEnd',     N'Effective end',         40, CONVERT(NVARCHAR(10), x.effective_end, 23)),
            (N'noticeDate',       N'Notice date',           50, CONVERT(NVARCHAR(10), x.notice_date, 23)),
            (N'decisionDate',     N'Decision date',         60, CONVERT(NVARCHAR(10), x.decision_date, 23)),
            (N'terminationDate',  N'Termination date',      70, CONVERT(NVARCHAR(10), x.termination_date, 23)),
            (N'contractValue',    N'Contract value',        80, CONVERT(NVARCHAR(40), x.contract_value)),
            (N'currencyCode',     N'Currency',              90, CAST(x.currency_code AS NVARCHAR(2000))),
            (N'taxDetails',       N'Tax',                  100, CAST(x.tax_details AS NVARCHAR(2000))),
            (N'paymentTerms',     N'Payment terms',        110, CAST(x.payment_terms AS NVARCHAR(2000))),
            (N'poReference',      N'PO reference',         120, CAST(x.po_reference AS NVARCHAR(2000))),
            (N'invoiceReference', N'Invoice reference',    130, CAST(x.invoice_reference AS NVARCHAR(2000))),
            (N'costAllocation',   N'Cost allocation',      140, CAST(x.cost_allocation AS NVARCHAR(2000))),
            (N'renewalTerms',     N'Renewal terms',        150, CAST(x.renewal_terms AS NVARCHAR(2000))),
            (N'serviceScope',     N'Service scope',        160, CAST(x.service_scope AS NVARCHAR(2000))),
            (N'slaTerms',         N'SLA',                  170, CAST(x.sla_terms AS NVARCHAR(2000))),
            (N'supportHours',     N'Support hours',        180, CAST(x.support_hours AS NVARCHAR(2000))),
            (N'responseTime',     N'Response time',        190, CAST(x.response_time AS NVARCHAR(2000))),
            (N'resolutionTime',   N'Resolution time',      200, CAST(x.resolution_time AS NVARCHAR(2000))),
            (N'serviceVisits',    N'Visits',               210, CAST(x.service_visits AS NVARCHAR(2000))),
            (N'contractOwner',    N'Contract owner',       220, CAST(o1.employee_name AS NVARCHAR(2000))),
            (N'procurementOwner', N'Procurement owner',    230, CAST(o2.employee_name AS NVARCHAR(2000))),
            (N'vendor',           N'Vendor',               240, CAST(COALESCE(x.vendor_name_snapshot, vd.vendor_name) AS NVARCHAR(2000))),
            (N'changeSummary',    N'Change summary',       250, CAST(x.change_summary AS NVARCHAR(2000)))
         ) k(FieldKey, Label, Ord, Val)
         WHERE x.version_id IN (@version_a, @version_b))
    SELECT a.FieldKey, a.Label, a.Val AS ValueA, b.Val AS ValueB,
           CASE WHEN ISNULL(a.Val, N'') COLLATE Latin1_General_BIN2 = ISNULL(b.Val, N'') COLLATE Latin1_General_BIN2 THEN 0 ELSE 1 END AS Changed
      FROM f a
      JOIN f b ON b.FieldKey = a.FieldKey AND b.version_id = @version_b
     WHERE a.version_id = @version_a
     ORDER BY a.Ord;

    ;WITH ca AS (SELECT RoleCode, RoleName, EmployeeId, ContactName, IsPrimary FROM grac_practice.fn_asset_contract_version_contacts(@version_a)),
          cb AS (SELECT RoleCode, RoleName, EmployeeId, ContactName, IsPrimary FROM grac_practice.fn_asset_contract_version_contacts(@version_b))
    SELECT COALESCE(ca.RoleCode, cb.RoleCode) AS RoleCode, COALESCE(ca.RoleName, cb.RoleName) AS RoleName,
           COALESCE(ca.ContactName, cb.ContactName) AS ContactName, ca.IsPrimary AS PrimaryInA, cb.IsPrimary AS PrimaryInB,
           CASE WHEN ca.EmployeeId IS NULL THEN N'ADDED' WHEN cb.EmployeeId IS NULL THEN N'REMOVED'
                WHEN ca.IsPrimary <> cb.IsPrimary THEN N'CHANGED' ELSE N'SAME' END AS ChangeType
      FROM ca
      FULL OUTER JOIN cb ON cb.RoleCode = ca.RoleCode AND cb.EmployeeId = ca.EmployeeId
     ORDER BY RoleName, ContactName;
END
GO

-- sp_asset_contract_get (434) body, verbatim
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_get
    @organization_id   BIGINT,
    @contract_id       BIGINT,
    @actor_employee_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract WHERE contract_id = @contract_id AND organization_id = @organization_id)
        THROW 54511, 'Contract not found for this organization.', 1;
    EXEC grac_practice.sp_asset_contract_sync @organization_id = @organization_id, @contract_id = @contract_id;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @open BIGINT = (SELECT TOP 1 v.version_id FROM grac_practice.asset_contract_version v
                              JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
                             WHERE v.contract_id = @contract_id AND s.status_code IN (N'DRAFT', N'IN_REVIEW', N'PENDING_APPROVAL')
                             ORDER BY v.version_no DESC);

    SELECT c.contract_id AS ContractId, c.contract_number AS ContractNumber, c.contract_name AS ContractName,
           c.contract_type AS ContractType, ISNULL(opt.OptionLabel, c.contract_type) AS ContractTypeLabel,
           c.parent_contract_id AS ParentContractId, p.contract_number AS ParentContractNumber, p.contract_name AS ParentContractName,
           c.vendor_id AS VendorId, vd.vendor_name AS VendorName, vd.status AS VendorStatus, c.description AS Description,
           c.contract_status AS ContractStatus, CONVERT(BIGINT, c.record_version) AS RecordVersion,
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_contract_version x WHERE x.contract_id = c.contract_id AND x.approval_dt IS NOT NULL)
                THEN 1 ELSE 0 END AS IdentityLocked,
           cv.version_id AS CurrentVersionId, cv.version_no AS CurrentVersionNo, cv.version_type AS CurrentVersionType,
           cs.status_code AS CurrentVersionStatus, cv.effective_start AS EffectiveStart, cv.effective_end AS EffectiveEnd,
           cv.notice_date AS NoticeDate, cv.decision_date AS DecisionDate, cv.termination_date AS TerminationDate,
           cv.contract_value AS ContractValue, cv.currency_code AS CurrencyCode, cv.payment_terms AS PaymentTerms,
           cv.support_hours AS SupportHours, cv.sla_terms AS SlaTerms, cv.renewal_terms AS RenewalTerms,
           o1.employee_name AS ContractOwnerName, o2.employee_name AS ProcurementOwnerName,
           @open AS OpenVersionId, ov.version_no AS OpenVersionNo, os.status_code AS OpenVersionStatus,
           c.entered_by AS EnteredBy, c.entered_dt AS EnteredDt
      FROM grac_practice.asset_contract c
      JOIN grac_practice.organization_dependency_vendor vd ON vd.vendor_id = c.vendor_id
      LEFT JOIN grac_practice.asset_contract p ON p.contract_id = c.parent_contract_id
      LEFT JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
      LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = cv.current_status_id
      LEFT JOIN grac_practice.organization_employee o1 ON o1.employee_id = cv.contract_owner_id
      LEFT JOIN grac_practice.organization_employee o2 ON o2.employee_id = cv.procurement_owner_id
      LEFT JOIN grac_practice.asset_contract_version ov ON ov.version_id = @open
      LEFT JOIN grac_practice.entity_status_master os ON os.entity_status_id = ov.current_status_id
      OUTER APPLY (SELECT TOP 1 o.OptionLabel FROM grac_practice.fn_asset_field_options(@organization_id) o
                    WHERE o.OptionGroup = N'asset_field.coverage_type' AND o.OptionValue = c.contract_type) opt
     WHERE c.contract_id = @contract_id;

    SELECT v.version_id AS VersionId, v.version_no AS VersionNo, v.version_label AS VersionLabel, v.version_type AS VersionType,
           s.status_code AS StatusCode, s.status_name AS StatusName, v.effective_start AS EffectiveStart, v.effective_end AS EffectiveEnd,
           v.contract_value AS ContractValue, v.currency_code AS CurrencyCode, v.change_summary AS ChangeSummary,
           v.entered_by AS CreatedBy, ce.employee_name AS CreatedByName, v.entered_dt AS CreatedDt,
           se.employee_name AS SubmittedByName, v.submitted_dt AS SubmittedDt, re.employee_name AS ReviewedByName, v.reviewed_dt AS ReviewedDt,
           ae.employee_name AS ApprovedByName, v.approved_by AS ApprovedBy, v.approval_dt AS ApprovalDt,
           sv.version_no AS SupersedesVersionNo, bv.version_no AS SupersededByVersionNo, v.decision_note AS DecisionNote,
           CASE WHEN @actor_employee_id IS NOT NULL AND v.submitted_by_employee_id = @actor_employee_id THEN 1 ELSE 0 END AS ActorIsSubmitter,
           CONVERT(BIGINT, v.record_version) AS RecordVersion
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
      LEFT JOIN grac_practice.organization_employee ce ON ce.employee_id = v.created_by_employee_id
      LEFT JOIN grac_practice.organization_employee se ON se.employee_id = v.submitted_by_employee_id
      LEFT JOIN grac_practice.organization_employee re ON re.employee_id = v.reviewed_by_employee_id
      LEFT JOIN grac_practice.organization_employee ae ON ae.employee_id = v.approved_by_employee_id
      LEFT JOIN grac_practice.asset_contract_version sv ON sv.version_id = v.supersedes_version_id
      LEFT JOIN grac_practice.asset_contract_version bv ON bv.version_id = v.superseded_by_version_id
     WHERE v.contract_id = @contract_id
     ORDER BY v.version_no DESC;

    SELECT m.mapping_id AS MappingId, m.version_id AS VersionId, xv.version_no AS VersionNo, m.employee_id AS EmployeeId,
           e.employee_name AS ContactName, e.email AS ContactEmail, e.status AS ContactStatus, m.role_code AS RoleCode,
           r.role_name AS RoleName, r.is_mandatory AS RoleMandatory, m.is_primary AS IsPrimary, m.effective_start AS EffectiveStart,
           m.effective_end AS EffectiveEnd, m.status AS Status,
           CASE WHEN m.status = N'PENDING_VALIDATION' THEN N'PENDING'
                WHEN m.status = N'INACTIVE' OR m.effective_end < @today THEN N'ENDED'
                WHEN m.effective_start > @today THEN N'FUTURE' ELSE N'CURRENT' END AS EffectiveState,
           m.preferred_channel AS PreferredChannel, m.notification_participation AS NotificationParticipation, m.notes AS Notes,
           ce.employee_name AS CreatedByName, m.entered_dt AS CreatedDt, ve.employee_name AS ValidatedByName, m.validated_dt AS ValidatedDt,
           m.end_reason AS EndReason,
           CASE WHEN @actor_employee_id IS NOT NULL AND m.created_by_employee_id = @actor_employee_id THEN 1 ELSE 0 END AS ActorIsCreator,
           CONVERT(BIGINT, m.record_version) AS RecordVersion
      FROM grac_practice.asset_contract_contact m
      JOIN grac_practice.asset_contract_contact_role r ON r.role_code = m.role_code
      JOIN grac_practice.organization_employee e ON e.employee_id = m.employee_id
      LEFT JOIN grac_practice.asset_contract_version xv ON xv.version_id = m.version_id
      LEFT JOIN grac_practice.organization_employee ce ON ce.employee_id = m.created_by_employee_id
      LEFT JOIN grac_practice.organization_employee ve ON ve.employee_id = m.validated_by_employee_id
     WHERE m.contract_id = @contract_id
     ORDER BY CASE WHEN m.status = N'INACTIVE' THEN 1 ELSE 0 END, r.display_order, m.is_primary DESC, m.effective_start DESC;

    SELECT d.document_id AS DocumentId, d.version_id AS VersionId, v.version_no AS VersionNo, d.document_type AS DocumentType,
           d.title AS Title, d.reference_text AS ReferenceText, d.status AS Status, d.entered_by AS AddedBy, d.entered_dt AS AddedDt,
           d.removed_by AS RemovedBy, d.removed_dt AS RemovedDt
      FROM grac_practice.asset_contract_document d
      JOIN grac_practice.asset_contract_version v ON v.version_id = d.version_id
     WHERE d.contract_id = @contract_id
     ORDER BY v.version_no DESC, d.entered_dt DESC;

    SELECT l.transition_log_id AS TransitionLogId, v.version_id AS VersionId, v.version_no AS VersionNo,
           fs.status_name AS FromStatus, ts.status_name AS ToStatus, l.reason_code AS ReasonCode, l.reason_text AS ReasonText,
           emp.employee_name AS ActorName, l.transitioned_at AS TransitionedAt
      FROM grac_practice.entity_state_transition_log l
      JOIN grac_practice.asset_contract_version v ON v.version_id = l.entity_id
      LEFT JOIN grac_practice.entity_status_master fs ON fs.entity_status_id = l.from_status_id
      JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = l.to_status_id
      LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id = l.actor_employee_id
     WHERE l.entity_type = N'ContractVersion' AND v.contract_id = @contract_id
     ORDER BY l.transitioned_at DESC, l.transition_log_id DESC;

    SELECT w.WarningCode, w.RoleCode, w.Warning
      FROM grac_practice.fn_asset_contract_readiness(@open) w
     WHERE @open IS NOT NULL;

    SELECT v.version_id AS VersionId, v.version_no AS VersionNo, s.role_name AS RoleName, s.contact_name AS ContactName,
           s.contact_email AS ContactEmail, s.vendor_name AS VendorName, s.is_primary AS IsPrimary, s.preferred_channel AS PreferredChannel,
           s.notification_participation AS NotificationParticipation, s.effective_start AS EffectiveStart, s.effective_end AS EffectiveEnd
      FROM grac_practice.asset_contract_version_contact s
      JOIN grac_practice.asset_contract_version v ON v.version_id = s.version_id
      JOIN grac_practice.asset_contract_contact_role r ON r.role_code = s.role_code
     WHERE v.contract_id = @contract_id
     ORDER BY v.version_no DESC, r.display_order, s.is_primary DESC, s.contact_name;
END
GO

-- sp_asset_contract_version_get (434) body, verbatim
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_version_get
    @organization_id   BIGINT,
    @version_id        BIGINT,
    @actor_employee_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @c BIGINT = (SELECT contract_id FROM grac_practice.asset_contract_version
                          WHERE version_id = @version_id AND organization_id = @organization_id);
    IF @c IS NULL THROW 54519, 'Contract version not found for this organization.', 1;
    EXEC grac_practice.sp_asset_contract_sync @organization_id = @organization_id, @contract_id = @c;

    SELECT v.version_id AS VersionId, v.contract_id AS ContractId, c.contract_number AS ContractNumber, c.contract_name AS ContractName,
           v.version_no AS VersionNo, v.version_label AS VersionLabel, v.version_type AS VersionType, s.status_code AS StatusCode,
           s.status_name AS StatusName, v.effective_start AS EffectiveStart, v.effective_end AS EffectiveEnd, v.notice_date AS NoticeDate,
           v.decision_date AS DecisionDate, v.termination_date AS TerminationDate, v.contract_value AS ContractValue,
           v.currency_code AS CurrencyCode, v.tax_details AS TaxDetails, v.payment_terms AS PaymentTerms, v.po_reference AS PoReference,
           v.invoice_reference AS InvoiceReference, v.cost_allocation AS CostAllocation, v.renewal_terms AS RenewalTerms,
           v.service_scope AS ServiceScope, v.sla_terms AS SlaTerms, v.support_hours AS SupportHours, v.response_time AS ResponseTime,
           v.resolution_time AS ResolutionTime, v.service_visits AS ServiceVisits,
           v.contract_owner_id AS ContractOwnerId, o1.employee_name AS ContractOwnerName,
           v.procurement_owner_id AS ProcurementOwnerId, o2.employee_name AS ProcurementOwnerName,
           COALESCE(v.vendor_name_snapshot, vd.vendor_name) AS VendorName, v.change_summary AS ChangeSummary,
           v.entered_by AS CreatedBy, ce.employee_name AS CreatedByName, v.entered_dt AS CreatedDt,
           se.employee_name AS SubmittedByName, v.submitted_dt AS SubmittedDt, re.employee_name AS ReviewedByName, v.reviewed_dt AS ReviewedDt,
           ae.employee_name AS ApprovedByName, v.approved_by AS ApprovedBy, v.approval_dt AS ApprovalDt, v.decision_note AS DecisionNote,
           sv.version_no AS SupersedesVersionNo, bv.version_no AS SupersededByVersionNo, v.activated_dt AS ActivatedDt, v.closed_dt AS ClosedDt,
           CASE WHEN @actor_employee_id IS NOT NULL AND v.submitted_by_employee_id = @actor_employee_id THEN 1 ELSE 0 END AS ActorIsSubmitter,
           CONVERT(BIGINT, v.record_version) AS RecordVersion
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.asset_contract c ON c.contract_id = v.contract_id
      JOIN grac_practice.organization_dependency_vendor vd ON vd.vendor_id = c.vendor_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
      LEFT JOIN grac_practice.organization_employee o1 ON o1.employee_id = v.contract_owner_id
      LEFT JOIN grac_practice.organization_employee o2 ON o2.employee_id = v.procurement_owner_id
      LEFT JOIN grac_practice.organization_employee ce ON ce.employee_id = v.created_by_employee_id
      LEFT JOIN grac_practice.organization_employee se ON se.employee_id = v.submitted_by_employee_id
      LEFT JOIN grac_practice.organization_employee re ON re.employee_id = v.reviewed_by_employee_id
      LEFT JOIN grac_practice.organization_employee ae ON ae.employee_id = v.approved_by_employee_id
      LEFT JOIN grac_practice.asset_contract_version sv ON sv.version_id = v.supersedes_version_id
      LEFT JOIN grac_practice.asset_contract_version bv ON bv.version_id = v.superseded_by_version_id
     WHERE v.version_id = @version_id;

    SELECT k.MappingId, k.RoleCode, k.RoleName, k.IsPrimary, k.EmployeeId, k.ContactName, k.ContactEmail, k.VendorName,
           k.PreferredChannel, k.NotificationParticipation, k.EffectiveStart, k.EffectiveEnd, k.Source, k.MappingStatus
      FROM grac_practice.fn_asset_contract_version_contacts(@version_id) k
     ORDER BY k.RoleName, k.IsPrimary DESC, k.ContactName;

    SELECT d.document_id AS DocumentId, d.document_type AS DocumentType, d.title AS Title, d.reference_text AS ReferenceText,
           d.status AS Status, d.entered_by AS AddedBy, d.entered_dt AS AddedDt, d.removed_by AS RemovedBy, d.removed_dt AS RemovedDt
      FROM grac_practice.asset_contract_document d
     WHERE d.version_id = @version_id
     ORDER BY d.entered_dt DESC;

    SELECT l.transition_log_id AS TransitionLogId, fs.status_name AS FromStatus, ts.status_name AS ToStatus, l.reason_code AS ReasonCode,
           l.reason_text AS ReasonText, emp.employee_name AS ActorName, l.transitioned_at AS TransitionedAt
      FROM grac_practice.entity_state_transition_log l
      LEFT JOIN grac_practice.entity_status_master fs ON fs.entity_status_id = l.from_status_id
      JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = l.to_status_id
      LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id = l.actor_employee_id
     WHERE l.entity_type = N'ContractVersion' AND l.entity_id = @version_id
     ORDER BY l.transitioned_at DESC, l.transition_log_id DESC;

    SELECT w.WarningCode, w.RoleCode, w.Warning
      FROM grac_practice.fn_asset_contract_readiness(@version_id) w
      JOIN grac_practice.asset_contract_version v ON v.version_id = @version_id
     WHERE v.approval_dt IS NULL;
END
GO

PRINT '435 rollback: earlier bodies restored.';
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_asset_coverage_config_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_coverage_gaps;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_coverage_asset_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_asset_search;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_coverage_settings_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_coverage_requirement_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_coverage_remove;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_coverage_bulk_add;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_coverage_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_entitlement_remove;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_entitlement_save;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_coverage_gaps;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_coverage_summary;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_coverage_status;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_coverage_line_view;
PRINT '435 rollback: coverage procedures and functions dropped.';
GO

DROP TABLE IF EXISTS grac_practice.asset_contract_coverage;
DROP TABLE IF EXISTS grac_practice.asset_contract_entitlement;
DROP TABLE IF EXISTS grac_practice.asset_coverage_requirement;
DROP TABLE IF EXISTS grac_practice.asset_coverage_settings;
PRINT '435 rollback: tables removed.';
GO

SELECT '435 rollback: coverage objects gone, earlier bodies restored' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_contract_coverage','U') IS NULL
             AND OBJECT_ID('grac_practice.fn_asset_coverage_gaps') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_register_save')) NOT LIKE '%fn_asset_coverage_gaps%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_lifecycle_transition')) NOT LIKE '%THROW 54560%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_asset_stored_values')) NOT LIKE '%coverage_status%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_contract_version_create')) NOT LIKE '%asset_contract_coverage%'
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
