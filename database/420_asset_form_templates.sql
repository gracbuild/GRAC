-- =====================================================================
-- 420  Asset field dictionary + asset form templates
--      (Asset & Contract Management, Phase 2 increment 1)
--
-- REQUEST
-- -------
--   BRD "Compliance Asset & Contract Management Workflow Specification"
--   v1.7, sections 5.1 (Asset Registration Data Dictionary) and 5.2
--   (Asset Type Form Designer). docs/asset-contract-management.md has the
--   gap analysis and the phase plan this migration belongs to.
--
-- WHAT THIS DOES
-- --------------
--   1. Field dictionary (GLOBAL, platform-controlled -- decision D1):
--        asset_field_group_master      the 14 dictionary groups (5.1.1-5.1.13, 5.1.18)
--        asset_field_data_type_master  the supported data types
--        asset_field_definition        270 field definitions, seeded from the
--                                      BRD tables verbatim (label, validation
--                                      text, description), plus the two
--                                      legacy Assets-tab columns (AMC expiry,
--                                      Remarks) so no existing value is
--                                      orphaned. storage_kind says where a
--                                      value lives: COLUMN = an existing
--                                      organization_dependency_asset column
--                                      (column_name), VALUE = the typed value
--                                      store added with the Asset Register
--                                      (Phase 4), SYSTEM = maintained by the
--                                      application, never entered on a form.
--      The BRD 5.1.17 "All assets" baseline (identification, category/
--      type, legal entity, owner, status, criticality, source) is marked
--      is_system_mandatory: a template must carry those fields, visible and
--      mandatory, and cannot remove or weaken them (5.2.1, 5.2.21).
--
--   2. Asset form templates (PER ORGANIZATION):
--        asset_form_template           one row per version of one asset
--                                      type's form for one organization
--        asset_form_template_section   tabs / sections and their layout
--        asset_form_template_field     the selected dictionary fields and
--                                      their per-template properties (5.2.5)
--      Duplicate prevention: UNIQUE (template, field).
--      Version control: UNIQUE (org, asset type, version_no); at most ONE
--      Active version and ONE working version (Draft / Testing / Pending
--      Approval / Approved) per org + asset type, by filtered unique index.
--      Optimistic concurrency: record_version ROWVERSION; every child edit
--      touches the template row so a stale transition is refused (54205).
--
--   3. Template lifecycle on the state-machine framework (035), entity type
--      'AssetFormTemplate': Draft -> Testing -> Pending Approval -> Approved
--      -> Active -> Retired (5.2.18). Every move is logged immutably by
--      sp_pm_state_transition (entity_state_transition_log +
--      practice_audit_trace). Segregation of duties: the submitter cannot
--      approve (5.2.19). Activating a version retires the previous Active
--      one in the same transaction; existing assets keep the version they
--      were registered with (enforced when the Asset Register lands).
--
--   4. Procedures (API: /api/practice/asset-config, AssetConfigController):
--        sp_asset_field_group_list, sp_asset_field_definition_list,
--        sp_asset_form_template_list, sp_asset_form_template_get,
--        sp_asset_form_template_create, sp_asset_form_template_new_version,
--        sp_asset_form_template_header_save, sp_asset_form_template_section_save,
--        sp_asset_form_template_field_save, sp_asset_form_template_field_remove,
--        sp_asset_form_template_readiness, sp_asset_form_template_transition,
--        sp_asset_form_template_assert_editable (shared Draft + concurrency guard)
--
--   5. Menu: a new root "Asset & Contract" (nav-asset-contract, order 350,
--      between Audit Assurance 300 and Policies & Documents 400) with
--      "Field Dictionary" (asset-field-dictionary) and "Asset Form
--      Templates" (asset-form-templates). Grants: the 'Admin' role of every
--      organization gets VIEW / ADD / EDIT / APPROVE (no DELETE) on the two
--      screens, missing rows only (416 convention).
--
-- NOT IN THIS INCREMENT (Phase 2.2): conditional visibility / mandatory
--   rules, lookup option lists, CIA / valuation / criticality
--   configuration, checklist / contract / recurrence mappings, template
--   migration of existing assets. The dictionary rows already carry the
--   lookup source codes those increments read.
--
-- ERROR NUMBERS: 54200-54249
--   54200 organization not found          54201 asset type not active
--   54202 template not found              54203 template already exists for the type
--   54204 template name required          54205 changed by someone else (concurrency)
--   54206 owner not an active employee    54207 a working version already exists
--   54208 change reason required          54210 only a Draft can be edited
--   54211 effective dates out of order    54212 section label required
--   54213 system section is fixed         54214 duplicate section key
--   54215 section still holds fields      54216 dictionary field not placeable
--   54217 section not valid for template  54218 system-mandatory field cannot be weakened
--   54219 sensitivity cannot be reduced   54220 submitter cannot approve
--   54221 invalid property value          54222 reason required for this move
--   54223 readiness errors block the move 54224 approval required
--   54225 effective-from in the future
--   (illegal status moves: framework 53520 -> HTTP 409)
--
-- ALSO EDITED: 274_menu_master_seed.sql (the three menu rows and their
--   parent links), 272_master_data_seed.sql (the two global masters and
--   the dictionary, insert-only), Web appsettings (PM_ORG_ADMIN grants).
-- DEPENDS ON: 035 (state machine), 239/240 (asset taxonomy), 274 (menu).
-- Rollback: 420_asset_form_templates_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.entity_status_master','U') IS NULL
   OR OBJECT_ID('grac_practice.entity_state_transition_rule','U') IS NULL
   OR OBJECT_ID('grac_practice.entity_state_transition_log','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_pm_state_transition','P') IS NULL
BEGIN PRINT 'ABORT (420): state-machine framework missing. Run 035 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.dependency_asset_type_master','U') IS NULL
   OR OBJECT_ID('grac_practice.dependency_asset_subcategory_master','U') IS NULL
   OR COL_LENGTH('grac_practice.dependency_asset_type_master','asset_type_name') IS NULL
   OR COL_LENGTH('grac_practice.dependency_asset_subcategory_master','subcategory_name') IS NULL
BEGIN PRINT 'ABORT (420): asset taxonomy missing. Run 239/240 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_employee','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','employee_name') IS NULL
   OR OBJECT_ID('grac_practice.practice_audit_trace','U') IS NULL
   OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN PRINT 'ABORT (420): core organization / menu tables missing.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('420_asset_form_templates: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Dictionary tables
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_field_group_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_field_group_master (
        field_group_id INT           IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_field_group PRIMARY KEY,
        group_code     NVARCHAR(60)  NOT NULL CONSTRAINT uq_pm_asset_field_group_code UNIQUE,
        group_name     NVARCHAR(150) NOT NULL,
        brd_section    NVARCHAR(20)  NULL,
        display_order  INT           NOT NULL CONSTRAINT df_pm_asset_field_group_order DEFAULT 0,
        is_active      BIT           NOT NULL CONSTRAINT df_pm_asset_field_group_active DEFAULT 1,
        entered_by     NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_field_group_eby DEFAULT N'system',
        entered_dt     DATETIME2     NOT NULL CONSTRAINT df_pm_asset_field_group_edt DEFAULT SYSUTCDATETIME(),
        updated_by     NVARCHAR(100) NULL,
        updated_dt     DATETIME2     NULL
    );
    PRINT '420: asset_field_group_master created.';
END
GO

IF OBJECT_ID('grac_practice.asset_field_data_type_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_field_data_type_master (
        data_type_code NVARCHAR(30)  NOT NULL CONSTRAINT pk_pm_asset_field_data_type PRIMARY KEY,
        data_type_name NVARCHAR(100) NOT NULL,
        is_user_entered BIT          NOT NULL CONSTRAINT df_pm_asset_field_dt_user DEFAULT 1,
        display_order  INT           NOT NULL CONSTRAINT df_pm_asset_field_dt_order DEFAULT 0,
        is_active      BIT           NOT NULL CONSTRAINT df_pm_asset_field_dt_active DEFAULT 1,
        entered_by     NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_field_dt_eby DEFAULT N'system',
        entered_dt     DATETIME2     NOT NULL CONSTRAINT df_pm_asset_field_dt_edt DEFAULT SYSUTCDATETIME()
    );
    PRINT '420: asset_field_data_type_master created.';
END
GO

IF OBJECT_ID('grac_practice.asset_field_definition','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_field_definition (
        field_definition_id  INT            IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_field_definition PRIMARY KEY,
        field_key            NVARCHAR(100)  NOT NULL CONSTRAINT uq_pm_asset_field_definition_key UNIQUE,
        display_label        NVARCHAR(200)  NOT NULL,
        field_group_id       INT            NOT NULL
            CONSTRAINT fk_pm_asset_field_definition_group REFERENCES grac_practice.asset_field_group_master(field_group_id),
        data_type_code       NVARCHAR(30)   NOT NULL
            CONSTRAINT fk_pm_asset_field_definition_type REFERENCES grac_practice.asset_field_data_type_master(data_type_code),
        lookup_source        NVARCHAR(100)  NULL,
        validation_rule_text NVARCHAR(1000) NULL,
        description          NVARCHAR(1000) NULL,
        is_system_mandatory  BIT            NOT NULL CONSTRAINT df_pm_asset_field_def_sysman DEFAULT 0,
        is_system_field      BIT            NOT NULL CONSTRAINT df_pm_asset_field_def_sysfld DEFAULT 0,
        storage_kind         NVARCHAR(10)   NOT NULL
            CONSTRAINT ck_pm_asset_field_definition_storage CHECK (storage_kind IN (N'COLUMN', N'VALUE', N'SYSTEM')),
        column_name          NVARCHAR(128)  NULL,
        sensitivity_code     NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_asset_field_def_sens DEFAULT N'INTERNAL'
            CONSTRAINT ck_pm_asset_field_definition_sens CHECK (sensitivity_code IN (N'PUBLIC', N'INTERNAL', N'CONFIDENTIAL', N'RESTRICTED')),
        display_order        INT            NOT NULL CONSTRAINT df_pm_asset_field_def_order DEFAULT 0,
        definition_version   INT            NOT NULL CONSTRAINT df_pm_asset_field_def_ver DEFAULT 1,
        effective_from       DATE           NOT NULL CONSTRAINT df_pm_asset_field_def_from DEFAULT CAST(SYSUTCDATETIME() AS DATE),
        effective_to         DATE           NULL,
        status_code          NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_asset_field_def_status DEFAULT N'ACTIVE'
            CONSTRAINT ck_pm_asset_field_definition_status CHECK (status_code IN (N'ACTIVE', N'RETIRED')),
        is_custom            BIT            NOT NULL CONSTRAINT df_pm_asset_field_def_custom DEFAULT 0,
        entered_by           NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_field_def_eby DEFAULT N'system',
        entered_dt           DATETIME2      NOT NULL CONSTRAINT df_pm_asset_field_def_edt DEFAULT SYSUTCDATETIME(),
        updated_by           NVARCHAR(100)  NULL,
        updated_dt           DATETIME2      NULL,
        CONSTRAINT ck_pm_asset_field_definition_column CHECK (storage_kind <> N'COLUMN' OR column_name IS NOT NULL),
        CONSTRAINT ck_pm_asset_field_definition_dates  CHECK (effective_to IS NULL OR effective_to >= effective_from)
    );
    CREATE INDEX ix_pm_asset_field_definition_group
        ON grac_practice.asset_field_definition(field_group_id, display_order);
    PRINT '420: asset_field_definition created.';
END
GO

-- =====================================================================
-- 2. Template tables
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_form_template','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_form_template (
        template_id                BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_form_template PRIMARY KEY,
        organization_id            BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_form_template_org REFERENCES grac_practice.organization(organization_id),
        asset_type_id              INT            NOT NULL
            CONSTRAINT fk_pm_asset_form_template_type REFERENCES grac_practice.dependency_asset_type_master(asset_type_id),
        template_name              NVARCHAR(200)  NOT NULL,
        version_no                 INT            NOT NULL,
        current_status_id          INT            NOT NULL
            CONSTRAINT fk_pm_asset_form_template_status REFERENCES grac_practice.entity_status_master(entity_status_id),
        approval_required          BIT            NOT NULL CONSTRAINT df_pm_asset_form_template_appr DEFAULT 1,
        template_owner_employee_id BIGINT         NULL
            CONSTRAINT fk_pm_asset_form_template_owner REFERENCES grac_practice.organization_employee(employee_id),
        effective_from             DATE           NULL,
        effective_to               DATE           NULL,
        change_reason              NVARCHAR(1000) NULL,
        source_template_id         BIGINT         NULL
            CONSTRAINT fk_pm_asset_form_template_source REFERENCES grac_practice.asset_form_template(template_id),
        is_active_version          BIT            NOT NULL CONSTRAINT df_pm_asset_form_template_act DEFAULT 0,
        is_working_version         BIT            NOT NULL CONSTRAINT df_pm_asset_form_template_wrk DEFAULT 1,
        submitted_by               NVARCHAR(100)  NULL,
        submitted_dt               DATETIME2      NULL,
        approved_by                NVARCHAR(100)  NULL,
        approved_dt                DATETIME2      NULL,
        activated_by               NVARCHAR(100)  NULL,
        activated_dt               DATETIME2      NULL,
        retired_dt                 DATETIME2      NULL,
        record_version             ROWVERSION     NOT NULL,
        entered_by                 NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_form_template_eby DEFAULT N'system',
        entered_dt                 DATETIME2      NOT NULL CONSTRAINT df_pm_asset_form_template_edt DEFAULT SYSUTCDATETIME(),
        updated_by                 NVARCHAR(100)  NULL,
        updated_dt                 DATETIME2      NULL,
        CONSTRAINT uq_pm_asset_form_template_version UNIQUE (organization_id, asset_type_id, version_no),
        CONSTRAINT ck_pm_asset_form_template_dates CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from),
        CONSTRAINT ck_pm_asset_form_template_flags CHECK (NOT (is_active_version = 1 AND is_working_version = 1))
    );
    CREATE UNIQUE INDEX ux_pm_asset_form_template_one_active
        ON grac_practice.asset_form_template(organization_id, asset_type_id)
        WHERE is_active_version = 1;
    CREATE UNIQUE INDEX ux_pm_asset_form_template_one_working
        ON grac_practice.asset_form_template(organization_id, asset_type_id)
        WHERE is_working_version = 1;
    CREATE INDEX ix_pm_asset_form_template_org_status
        ON grac_practice.asset_form_template(organization_id, current_status_id);
    PRINT '420: asset_form_template created.';
END
GO

IF OBJECT_ID('grac_practice.asset_form_template_section','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_form_template_section (
        section_id     BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_form_section PRIMARY KEY,
        template_id    BIGINT        NOT NULL
            CONSTRAINT fk_pm_asset_form_section_template REFERENCES grac_practice.asset_form_template(template_id),
        section_key    NVARCHAR(60)  NOT NULL,
        section_label  NVARCHAR(150) NOT NULL,
        tab_label      NVARCHAR(150) NULL,
        layout_columns TINYINT       NOT NULL CONSTRAINT df_pm_asset_form_section_cols DEFAULT 2
            CONSTRAINT ck_pm_asset_form_section_cols CHECK (layout_columns IN (1, 2)),
        display_order  INT           NOT NULL CONSTRAINT df_pm_asset_form_section_order DEFAULT 0,
        is_system      BIT           NOT NULL CONSTRAINT df_pm_asset_form_section_sys DEFAULT 0,
        is_active      BIT           NOT NULL CONSTRAINT df_pm_asset_form_section_active DEFAULT 1,
        entered_by     NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_form_section_eby DEFAULT N'system',
        entered_dt     DATETIME2     NOT NULL CONSTRAINT df_pm_asset_form_section_edt DEFAULT SYSUTCDATETIME(),
        updated_by     NVARCHAR(100) NULL,
        updated_dt     DATETIME2     NULL,
        CONSTRAINT uq_pm_asset_form_section_key UNIQUE (template_id, section_key)
    );
    PRINT '420: asset_form_template_section created.';
END
GO

IF OBJECT_ID('grac_practice.asset_form_template_field','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_form_template_field (
        template_field_id        BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_form_field PRIMARY KEY,
        template_id              BIGINT        NOT NULL
            CONSTRAINT fk_pm_asset_form_field_template REFERENCES grac_practice.asset_form_template(template_id),
        field_definition_id      INT           NOT NULL
            CONSTRAINT fk_pm_asset_form_field_def REFERENCES grac_practice.asset_field_definition(field_definition_id),
        section_id               BIGINT        NOT NULL
            CONSTRAINT fk_pm_asset_form_field_section REFERENCES grac_practice.asset_form_template_section(section_id),
        display_order            INT           NOT NULL CONSTRAINT df_pm_asset_form_field_order DEFAULT 0,
        is_visible               BIT           NOT NULL CONSTRAINT df_pm_asset_form_field_vis DEFAULT 1,
        is_mandatory             BIT           NOT NULL CONSTRAINT df_pm_asset_form_field_man DEFAULT 0,
        is_read_only             BIT           NOT NULL CONSTRAINT df_pm_asset_form_field_ro DEFAULT 0,
        default_value            NVARCHAR(400) NULL,
        help_text                NVARCHAR(500) NULL,
        placeholder_text         NVARCHAR(200) NULL,
        hidden_value_behavior    NVARCHAR(10)  NOT NULL CONSTRAINT df_pm_asset_form_field_hvb DEFAULT N'RETAIN'
            CONSTRAINT ck_pm_asset_form_field_hvb CHECK (hidden_value_behavior IN (N'RETAIN', N'CLEAR', N'MIGRATE')),
        sensitivity_override     NVARCHAR(20)  NULL
            CONSTRAINT ck_pm_asset_form_field_sens CHECK (sensitivity_override IS NULL
                OR sensitivity_override IN (N'PUBLIC', N'INTERNAL', N'CONFIDENTIAL', N'RESTRICTED')),
        include_in_import_export BIT           NOT NULL CONSTRAINT df_pm_asset_form_field_imp DEFAULT 1,
        is_searchable            BIT           NOT NULL CONSTRAINT df_pm_asset_form_field_srch DEFAULT 0,
        evidence_required        BIT           NOT NULL CONSTRAINT df_pm_asset_form_field_evd DEFAULT 0,
        entered_by               NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_form_field_eby DEFAULT N'system',
        entered_dt               DATETIME2     NOT NULL CONSTRAINT df_pm_asset_form_field_edt DEFAULT SYSUTCDATETIME(),
        updated_by               NVARCHAR(100) NULL,
        updated_dt               DATETIME2     NULL,
        CONSTRAINT uq_pm_asset_form_field UNIQUE (template_id, field_definition_id)
    );
    CREATE INDEX ix_pm_asset_form_field_section
        ON grac_practice.asset_form_template_field(section_id, display_order);
    PRINT '420: asset_form_template_field created.';
END
GO

-- =====================================================================
-- 3. Seeds -- groups, data types, dictionary (insert-only on natural
--    keys: a row an operator corrected survives a re-run).
-- =====================================================================
MERGE grac_practice.asset_field_group_master AS t
USING (VALUES
    (N'IDENTIFICATION',          N'Identification',                                 N'5.1.1',   10),
    (N'ORGANIZATION_LOCATION',   N'Organization and Location',                      N'5.1.2',   20),
    (N'OWNERSHIP',               N'Ownership and Responsibility',                   N'5.1.3',   30),
    (N'PROCUREMENT_FINANCE',     N'Procurement and Financial Details',              N'5.1.4',   40),
    (N'COMPLIANCE_RISK',         N'Compliance, Risk and Classification',            N'5.1.5',   50),
    (N'TECHNICAL_CYBER',         N'Technical and Cybersecurity Details',            N'5.1.6',   60),
    (N'MAINTENANCE_CALIBRATION', N'Maintenance, Calibration and Equipment Details', N'5.1.7',   70),
    (N'BIOMEDICAL',              N'Biomedical and Clinical Equipment Details',      N'5.1.8',   80),
    (N'VEHICLE',                 N'Vehicle Details',                                N'5.1.9',   90),
    (N'PRIVACY',                 N'Privacy and Personal Data Details',              N'5.1.10', 100),
    (N'CONTRACT_COVERAGE',       N'Contract, Coverage and Service Details',         N'5.1.11', 110),
    (N'DISPOSAL',                N'Disposal and Retirement Details',                N'5.1.12', 120),
    (N'AUDIT_INTEGRATION',       N'Audit and Integration Metadata',                 N'5.1.13', 130),
    (N'CIA_VALUATION',           N'Asset Value and CIA Valuation',                  N'5.1.18', 140)
) AS s(group_code, group_name, brd_section, display_order)
ON t.group_code = s.group_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (group_code, group_name, brd_section, display_order, entered_by)
    VALUES (s.group_code, s.group_name, s.brd_section, s.display_order, N'seed-420');
PRINT CONCAT('420: dictionary groups inserted: ', @@ROWCOUNT);
GO

MERGE grac_practice.asset_field_data_type_master AS t
USING (VALUES
    (N'TEXT',          N'Text',                       1,  10),
    (N'MULTILINE',     N'Multiline text',             1,  20),
    (N'DECIMAL',       N'Number',                     1,  30),
    (N'CURRENCY',      N'Amount and currency',        1,  40),
    (N'PERCENT',       N'Percentage',                 1,  50),
    (N'QUANTITY_UNIT', N'Quantity with unit',         1,  60),
    (N'DATE',          N'Date',                       1,  70),
    (N'DATETIME',      N'Date and time',              0,  80),
    (N'YES_NO',        N'Yes / No',                   1,  90),
    (N'TRI_STATE',     N'Yes / No / third value',     1, 100),
    (N'LOOKUP',        N'Single-select lookup',       1, 110),
    (N'MULTI_SELECT',  N'Multi-select lookup',        1, 120),
    (N'USER',          N'User',                       1, 130),
    (N'MULTI_USER',    N'Multiple users',             1, 140),
    (N'TEAM',          N'Team',                       1, 150),
    (N'USER_OR_TEAM',  N'User or team',               1, 160),
    (N'VENDOR',        N'Vendor',                     1, 170),
    (N'CONTRACT',      N'Contract',                   1, 180),
    (N'MAKE',          N'Asset make',                 1, 190),
    (N'MODEL',         N'Asset model',                1, 200),
    (N'FIRMWARE',      N'Firmware release',           1, 210),
    (N'OS_RELEASE',    N'Operating-system release',   1, 220),
    (N'IP_ADDRESS',    N'IP address',                 1, 230),
    (N'IP_LIST',       N'IP address list',            1, 240),
    (N'ATTACHMENT',    N'Attachment / evidence link', 1, 250),
    (N'APPROVAL_REF',  N'Approval reference',         0, 260),
    (N'AUTO',          N'Auto-generated',             0, 270),
    (N'CALCULATED',    N'Calculated',                 0, 280),
    (N'SYSTEM',        N'System-maintained',          0, 290)
) AS s(data_type_code, data_type_name, is_user_entered, display_order)
ON t.data_type_code = s.data_type_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (data_type_code, data_type_name, is_user_entered, display_order, entered_by)
    VALUES (s.data_type_code, s.data_type_name, s.is_user_entered, s.display_order, N'seed-420');
PRINT CONCAT('420: data types inserted: ', @@ROWCOUNT);
GO

-- Field definitions. Columns: field_key, display_label, group_code,
-- data_type_code, lookup_source, validation_rule_text (BRD "Validation /
-- Mandatory Rule"), description (BRD "Description / Logic"),
-- is_system_mandatory, is_system_field, storage_kind, column_name,
-- sensitivity_code, display_order.
MERGE grac_practice.asset_field_definition AS t
USING (
    SELECT v.field_key, v.display_label, g.field_group_id, v.data_type_code, v.lookup_source,
           v.validation_rule_text, v.description, v.is_system_mandatory, v.is_system_field,
           v.storage_kind, v.column_name, v.sensitivity_code, v.display_order
      FROM (VALUES
    (N'asset_id', N'Asset ID', N'IDENTIFICATION', N'AUTO', NULL, N'Required; unique; read-only', N'System-generated primary identifier for the asset record.', 1, 0, N'COLUMN', N'asset_id', N'INTERNAL', 10),
    (N'asset_name', N'Asset name', N'IDENTIFICATION', N'TEXT', NULL, N'Required; 3-150 characters', N'Clear business-facing name used to identify the asset.', 1, 0, N'COLUMN', N'asset_name', N'INTERNAL', 20),
    (N'main_category', N'Main category', N'IDENTIFICATION', N'LOOKUP', N'MASTER:ASSET_CATEGORY', N'Required; active values only', N'Selects the top-level asset category and drives applicable rules.', 1, 0, N'COLUMN', N'asset_category_id', N'INTERNAL', 30),
    (N'subcategory', N'Subcategory', N'IDENTIFICATION', N'LOOKUP', N'MASTER:ASSET_SUBCATEGORY', N'Required; must belong to main category', N'Provides the next classification level and filters asset types.', 1, 0, N'COLUMN', N'asset_subcategory_id', N'INTERNAL', 40),
    (N'asset_type', N'Asset type', N'IDENTIFICATION', N'LOOKUP', N'MASTER:ASSET_TYPE', N'Required; active values only; must belong to subcategory', N'Defines the specific asset type and applicable field template.', 1, 0, N'COLUMN', N'asset_type_id', N'INTERNAL', 50),
    (N'asset_template', N'Asset template', N'IDENTIFICATION', N'LOOKUP', N'MASTER:ASSET_FORM_TEMPLATE', N'Optional; active templates for selected asset type', N'Applies reusable defaults, checklist mappings and recurrence settings.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
    (N'asset_tag', N'Asset tag', N'IDENTIFICATION', N'TEXT', NULL, N'Required where tagging applies; unique', N'Organization-assigned physical or logical tag.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
    (N'serial_number', N'Serial number', N'IDENTIFICATION', N'TEXT', NULL, N'Format configurable; duplicate warning; uniqueness may be make/model scoped', N'Manufacturer-issued serial number used for traceability.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
    (N'barcode', N'Barcode', N'IDENTIFICATION', N'TEXT', NULL, N'Unique when provided', N'Barcode value used for scanning and inventory operations.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
    (N'qr_code', N'QR code', N'IDENTIFICATION', N'TEXT', NULL, N'Unique; linked to Asset ID', N'QR value generated or recorded for rapid asset lookup.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
    (N'rfid_number', N'RFID number', N'IDENTIFICATION', N'TEXT', NULL, N'Unique when provided', N'RFID tag identifier used for automated tracking.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
    (N'manufacturer_make', N'Manufacturer / Make', N'IDENTIFICATION', N'MAKE', N'MASTER:MAKE', N'Required for manufactured assets; active approved make', N'Identifies the original equipment or product manufacturer.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
    (N'model', N'Model', N'IDENTIFICATION', N'MODEL', N'MASTER:MODEL', N'Required where applicable; must belong to selected make and asset type', N'References the approved model record and lifecycle dates.', 0, 0, N'VALUE', NULL, N'INTERNAL', 130),
    (N'model_family_series', N'Model family / series', N'IDENTIFICATION', N'CALCULATED', NULL, N'Derived from model; editable only by catalog administrator', N'Groups related models for reporting and lifecycle planning.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 140),
    (N'hardware_revision', N'Hardware revision', N'IDENTIFICATION', N'LOOKUP', N'OPTION:hardware_revision', N'Optional; required where compatibility depends on revision', N'Records chassis, board or hardware revision.', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
    (N'version', N'Version', N'IDENTIFICATION', N'TEXT', NULL, N'Optional; configurable format', N'General hardware, software or product version where a catalog object is not applicable.', 0, 0, N'VALUE', NULL, N'INTERNAL', 160),
    (N'manufacture_date', N'Manufacture date', N'IDENTIFICATION', N'DATE', NULL, N'Cannot be a future date', N'Date on which the asset was manufactured.', 0, 0, N'VALUE', NULL, N'INTERNAL', 170),
    (N'country_of_origin', N'Country of origin', N'IDENTIFICATION', N'LOOKUP', N'MASTER:COUNTRY', N'Optional; active country values only', N'Country in which the asset or product was manufactured.', 0, 0, N'VALUE', NULL, N'INTERNAL', 180),
    (N'asset_status', N'Asset status', N'IDENTIFICATION', N'LOOKUP', N'STATE:ASSET', N'Required; valid transition only', N'Current lifecycle state controlled by the configured workflow.', 1, 0, N'SYSTEM', NULL, N'INTERNAL', 190),
    (N'record_source', N'Record source', N'IDENTIFICATION', N'LOOKUP', N'OPTION:record_source', N'Required; Manual, Import, Discovery, ERP, API or other configured source', N'Identifies the originating system or process.', 1, 0, N'VALUE', NULL, N'INTERNAL', 200),
    (N'source_record_identifier', N'Source record identifier', N'IDENTIFICATION', N'TEXT', NULL, N'Required for integrated/imported records; unique per source', N'External key used to reconcile and synchronize the asset.', 0, 0, N'VALUE', NULL, N'INTERNAL', 210),
    (N'legal_entity', N'Legal entity', N'ORGANIZATION_LOCATION', N'LOOKUP', N'MASTER:ORGANIZATION', N'Required; authorized active entities only', N'Identifies the legal entity that owns or controls the asset.', 1, 0, N'COLUMN', N'organization_id', N'INTERNAL', 10),
    (N'business_unit', N'Business unit', N'ORGANIZATION_LOCATION', N'LOOKUP', N'MASTER:DIVISION', N'Required; must belong to legal entity', N'Maps the asset to the responsible business unit.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
    (N'department', N'Department', N'ORGANIZATION_LOCATION', N'LOOKUP', N'MASTER:DEPARTMENT', N'Required; active department belonging to business unit', N'Identifies the department using or managing the asset.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
    (N'cost_centre', N'Cost centre', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:cost_centre', N'Valid active finance code', N'Links acquisition and operating costs to the responsible cost centre.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
    (N'process_supported', N'Process supported', N'ORGANIZATION_LOCATION', N'MULTI_SELECT', N'MASTER:PROCESS', N'At least one value for critical assets', N'Links the asset to supported business or operational processes.', 0, 0, N'VALUE', NULL, N'INTERNAL', 50),
    (N'service_supported', N'Service supported', N'ORGANIZATION_LOCATION', N'MULTI_SELECT', N'OPTION:service_supported', N'Recommended for service-related assets', N'Links the asset to business or technology services.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
    (N'site', N'Site', N'ORGANIZATION_LOCATION', N'LOOKUP', N'MASTER:LOCATION', N'Required for physical assets; active sites only', N'Specifies the site where the asset is located.', 0, 0, N'COLUMN', N'location_id', N'INTERNAL', 70),
    (N'building', N'Building', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:building', N'Must belong to selected site', N'Identifies the building containing the asset.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
    (N'floor', N'Floor', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:floor', N'Must belong to selected building', N'Identifies the applicable floor.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
    (N'room', N'Room', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:room', N'Must belong to selected floor', N'Identifies the room or controlled area.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
    (N'rack', N'Rack', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:rack', N'Required for rack-mounted equipment', N'Records rack identifier.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
    (N'cabinet_bay', N'Cabinet / Bay', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:cabinet_bay', N'Required where applicable', N'Records cabinet, bay or enclosure.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
    (N'production_line', N'Production line', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:production_line', N'Required for line-specific manufacturing assets', N'Identifies the production line supported by the asset.', 0, 0, N'VALUE', NULL, N'INTERNAL', 130),
    (N'clinical_area', N'Clinical area', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:clinical_area', N'Required for clinical/biomedical assets where applicable', N'Identifies ICU, ward, theatre, radiology, laboratory or other clinical area.', 0, 0, N'VALUE', NULL, N'INTERNAL', 140),
    (N'zone', N'Zone', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:zone', N'Optional; must belong to selected site/location', N'Records safety, security, environmental or operational zone.', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
    (N'exact_installation_location', N'Exact installation location', N'ORGANIZATION_LOCATION', N'MULTILINE', NULL, N'Required for fixed equipment', N'Records rack unit, bay, bed, line position, coordinates or precise location.', 0, 0, N'VALUE', NULL, N'INTERNAL', 160),
    (N'location_type', N'Location type', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:location_type', N'Required; Physical, Virtual, Mobile, Cloud or other configured value', N'Determines applicable location and mobility controls.', 0, 0, N'VALUE', NULL, N'INTERNAL', 170),
    (N'mobility_status', N'Mobility status', N'ORGANIZATION_LOCATION', N'LOOKUP', N'OPTION:mobility_status', N'Required for portable/mobile assets', N'Indicates fixed, portable, mobile, pool or temporarily assigned status.', 0, 0, N'VALUE', NULL, N'INTERNAL', 180),
    (N'storage_location', N'Storage location', N'ORGANIZATION_LOCATION', N'LOOKUP', N'MASTER:LOCATION', N'Required when lifecycle status is In Storage', N'Identifies the controlled storage location.', 0, 0, N'VALUE', NULL, N'INTERNAL', 190),
    (N'business_owner', N'Business owner', N'OWNERSHIP', N'USER', N'MASTER:EMPLOYEE', N'Required for business- critical assets; active user', N'Accountable business representative for value and use.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
    (N'asset_owner', N'Asset owner', N'OWNERSHIP', N'USER', N'MASTER:EMPLOYEE', N'Required; active user', N'Person accountable for lifecycle, risk and compliance.', 1, 0, N'COLUMN', N'owner_id', N'INTERNAL', 20),
    (N'technical_owner', N'Technical owner', N'OWNERSHIP', N'USER_OR_TEAM', N'MASTER:EMPLOYEE_OR_TEAM', N'Required for technical assets', N'Responsible for technical configuration and support.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
    (N'custodian', N'Custodian', N'OWNERSHIP', N'USER_OR_TEAM', N'MASTER:EMPLOYEE_OR_TEAM', N'Required when custody is assigned', N'Responsible for day-to-day possession and safeguarding.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
    (N'operator', N'Operator', N'OWNERSHIP', N'MULTI_USER', N'MASTER:EMPLOYEE', N'Active and authorized users only', N'Lists personnel authorized to operate the asset.', 0, 0, N'VALUE', NULL, N'INTERNAL', 50),
    (N'maintenance_owner', N'Maintenance owner', N'OWNERSHIP', N'USER_OR_TEAM', N'MASTER:EMPLOYEE_OR_TEAM', N'Required when maintenance is applicable', N'Accountable for maintenance planning and completion.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
    (N'calibration_owner', N'Calibration owner', N'OWNERSHIP', N'USER_OR_TEAM', N'MASTER:EMPLOYEE_OR_TEAM', N'Required when calibration is applicable', N'Accountable for calibration scheduling, evidence and closure.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
    (N'compliance_owner', N'Compliance owner', N'OWNERSHIP', N'USER', N'MASTER:EMPLOYEE', N'Required for regulated or controlled assets', N'Monitors applicable obligations, evidence and exceptions.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
    (N'privacy_owner', N'Privacy owner', N'OWNERSHIP', N'USER', N'MASTER:EMPLOYEE', N'Required when personal data is processed', N'Accountable for privacy assessment and safeguards.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
    (N'information_security_owner', N'Information security owner', N'OWNERSHIP', N'USER_OR_TEAM', N'MASTER:EMPLOYEE_OR_TEAM', N'Required for security-critical assets', N'Accountable for security baseline, monitoring and remediation.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
    (N'vendor', N'Vendor', N'OWNERSHIP', N'VENDOR', N'MASTER:VENDOR', N'Approved and active vendor only', N'Identifies the supplying or contracted vendor.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
    (N'service_provider', N'Service provider', N'OWNERSHIP', N'VENDOR', N'MASTER:VENDOR', N'Required for externally supported assets', N'Identifies the organization providing support or managed service.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
    (N'support_group', N'Support group', N'OWNERSHIP', N'TEAM', N'MASTER:TEAM', N'Required for supported operational assets', N'Team responsible for incident, request and maintenance handling.', 0, 0, N'VALUE', NULL, N'INTERNAL', 130),
    (N'assignment_start_date', N'Assignment start date', N'OWNERSHIP', N'DATE', NULL, N'Cannot be after assignment end date', N'Effective date for the current ownership or custody assignment.', 0, 0, N'VALUE', NULL, N'INTERNAL', 140),
    (N'assignment_end_date', N'Assignment end date', N'OWNERSHIP', N'DATE', NULL, N'Optional; must follow assignment start date', N'End date retained in ownership history.', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
    (N'acquisition_method', N'Acquisition method', N'PROCUREMENT_FINANCE', N'LOOKUP', N'OPTION:acquisition_method', N'Required; Purchase, Lease, Rental, Donation, Transfer, Subscription or configured value', N'Defines how the asset was acquired.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 10),
    (N'purchase_date', N'Purchase date', N'PROCUREMENT_FINANCE', N'DATE', NULL, N'Cannot be a future date', N'Date the asset was purchased or contractually acquired.', 0, 0, N'COLUMN', N'purchase_dt', N'CONFIDENTIAL', 20),
    (N'purchase_order_number', N'Purchase order number', N'PROCUREMENT_FINANCE', N'LOOKUP', N'OPTION:purchase_order_number', N'Required for purchased assets; valid reference', N'Links the asset to the approved purchase order.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 30),
    (N'invoice_number', N'Invoice number', N'PROCUREMENT_FINANCE', N'TEXT', NULL, N'Required where invoiced; duplicate warning', N'Supplier invoice reference for financial traceability.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 40),
    (N'purchase_cost', N'Purchase cost', N'PROCUREMENT_FINANCE', N'CURRENCY', NULL, N'Non-negative; currency required', N'Original acquisition cost, with tax treatment defined by configuration.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 50),
    (N'currency', N'Currency', N'PROCUREMENT_FINANCE', N'LOOKUP', N'MASTER:CURRENCY', N'Required when cost is entered; ISO currency code', N'Currency used for purchase and financial reporting.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 60),
    (N'capex_opex', N'CapEx / OpEx', N'PROCUREMENT_FINANCE', N'LOOKUP', N'OPTION:capex_opex', N'Required; approved values only', N'Classifies the financial treatment of expenditure.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 70),
    (N'capitalization_date', N'Capitalization date', N'PROCUREMENT_FINANCE', N'DATE', NULL, N'Required for capitalized assets; not before purchase date unless approved', N'Date the asset enters the fixed-asset register.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 80),
    (N'finance_asset_number', N'Finance asset number', N'PROCUREMENT_FINANCE', N'LOOKUP', N'OPTION:finance_asset_number', N'Unique when provided', N'Fixed-asset identifier in the finance/ERP system.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 90),
    (N'warranty_start_date', N'Warranty start date', N'PROCUREMENT_FINANCE', N'DATE', NULL, N'Must be on or before warranty expiry', N'Date from which warranty coverage begins.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 100),
    (N'warranty_expiry_date', N'Warranty expiry date', N'PROCUREMENT_FINANCE', N'DATE', NULL, N'Must be after warranty start date', N'Triggers expiry notifications and renewal or support review.', 0, 0, N'COLUMN', N'warranty_expiry_dt', N'CONFIDENTIAL', 110),
    (N'expected_useful_life', N'Expected useful life', N'PROCUREMENT_FINANCE', N'QUANTITY_UNIT', NULL, N'Positive value; category default allowed', N'Expected operational life used for planning and depreciation.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 120),
    (N'depreciation_method', N'Depreciation method', N'PROCUREMENT_FINANCE', N'LOOKUP', N'OPTION:depreciation_method', N'Required for capitalized assets', N'Defines the approved accounting depreciation method.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 130),
    (N'depreciation_rate', N'Depreciation rate', N'PROCUREMENT_FINANCE', N'PERCENT', NULL, N'Non-negative; required when method uses a rate', N'Rate applied by the selected depreciation method.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 140),
    (N'residual_value', N'Residual value', N'PROCUREMENT_FINANCE', N'CURRENCY', NULL, N'Non-negative; cannot exceed purchase cost', N'Estimated value remaining at the end of useful life.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 150),
    (N'lease_rental_start_date', N'Lease / rental start date', N'PROCUREMENT_FINANCE', N'DATE', NULL, N'Required for leased/rented assets', N'Start date of lease or rental possession.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 160),
    (N'lease_rental_end_date', N'Lease / rental end date', N'PROCUREMENT_FINANCE', N'DATE', NULL, N'Must follow start date', N'Triggers return, renewal or purchase-option workflow.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 170),
    (N'budget_owner', N'Budget owner', N'PROCUREMENT_FINANCE', N'USER', N'MASTER:EMPLOYEE', N'Required where configured', N'Person accountable for budget and renewal decisions.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 180),
    (N'applicable_standards', N'Applicable standards', N'COMPLIANCE_RISK', N'MULTI_SELECT', N'MASTER:PRACTICE', N'Active frameworks, obligations and practices only', N'Links the asset to applicable standards, regulations and practices.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
    (N'risk_classification', N'Risk classification', N'COMPLIANCE_RISK', N'LOOKUP', N'OPTION:risk_classification', N'Required; approved risk scale', N'Sets the asset risk level and drives control frequency.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
    (N'criticality', N'Criticality', N'COMPLIANCE_RISK', N'LOOKUP', N'MASTER:CRITICALITY', N'Required; approved criticality scale', N'Rates business, operational, safety or service impact.', 1, 0, N'COLUMN', N'criticality_id', N'INTERNAL', 30),
    (N'confidentiality_classification', N'Confidentiality classification', N'COMPLIANCE_RISK', N'LOOKUP', N'OPTION:confidentiality_classification', N'Required for information-processing assets', N'Defines protection required against unauthorized disclosure.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
    (N'integrity_requirement', N'Integrity requirement', N'COMPLIANCE_RISK', N'LOOKUP', N'OPTION:integrity_requirement', N'Required for information-processing assets', N'Defines tolerance for unauthorized or accidental modification.', 0, 0, N'VALUE', NULL, N'INTERNAL', 50),
    (N'availability_requirement', N'Availability requirement', N'COMPLIANCE_RISK', N'LOOKUP', N'OPTION:availability_requirement', N'Required for service-supporting assets', N'Defines uptime, recovery and continuity expectations.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
    (N'personal_data_processed', N'Personal data processed', N'COMPLIANCE_RISK', N'TRI_STATE', N'OPTION:yes_no_unknown', N'Required', N'Yes or Unknown triggers privacy fields, assessment and controls.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
    (N'special_category_or_health_data_processed', N'Special-category or health data processed', N'COMPLIANCE_RISK', N'TRI_STATE', N'OPTION:yes_no_unknown', N'Required when personal data processed is Yes/Unknown', N'Triggers enhanced privacy and security requirements.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
    (N'children_data_processed', N'Children data processed', N'COMPLIANCE_RISK', N'TRI_STATE', N'OPTION:yes_no_unknown', N'Required when personal data processed is Yes/Unknown', N'Triggers child-data and consent/authorization review.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
    (N'environmental_impact', N'Environmental impact', N'COMPLIANCE_RISK', N'MULTI_SELECT', N'OPTION:environmental_impact', N'Required for assets with environmental aspects', N'Records energy, emissions, waste, spill or resource impacts.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
    (N'safety_hazard', N'Safety hazard', N'COMPLIANCE_RISK', N'MULTI_SELECT', N'OPTION:safety_hazard', N'Required for machinery and safety-relevant assets', N'Identifies hazards and drives inspections and controls.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
    (N'patient_safety_impact', N'Patient safety impact', N'COMPLIANCE_RISK', N'LOOKUP', N'OPTION:patient_safety_impact', N'Required for clinical or biomedical assets', N'Classifies potential impact on patient safety and care.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
    (N'calibration_required', N'Calibration required', N'COMPLIANCE_RISK', N'YES_NO', NULL, N'Required', N'When Yes, calibration schedule and evidence fields become mandatory.', 0, 0, N'VALUE', NULL, N'INTERNAL', 130),
    (N'preventive_maintenance_required', N'Preventive maintenance required', N'COMPLIANCE_RISK', N'YES_NO', NULL, N'Required', N'When Yes, maintenance schedule fields become mandatory.', 0, 0, N'VALUE', NULL, N'INTERNAL', 140),
    (N'statutory_inspection_required', N'Statutory inspection required', N'COMPLIANCE_RISK', N'YES_NO', NULL, N'Required', N'Triggers statutory inspection schedules and evidence.', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
    (N'certification_required', N'Certification required', N'COMPLIANCE_RISK', N'YES_NO', NULL, N'Required', N'Triggers certificate tracking, expiry and renewal workflow.', 0, 0, N'VALUE', NULL, N'INTERNAL', 160),
    (N'licence_required', N'Licence required', N'COMPLIANCE_RISK', N'YES_NO', NULL, N'Required', N'Triggers licence details, expiry alerts and use restrictions.', 0, 0, N'VALUE', NULL, N'INTERNAL', 170),
    (N'insurance_required', N'Insurance required', N'COMPLIANCE_RISK', N'YES_NO', NULL, N'Required', N'Triggers insurance policy and expiry management.', 0, 0, N'VALUE', NULL, N'INTERNAL', 180),
    (N'amc_required', N'AMC required', N'COMPLIANCE_RISK', N'YES_NO', NULL, N'Required', N'Triggers annual maintenance contract coverage tracking.', 0, 0, N'VALUE', NULL, N'INTERNAL', 190),
    (N'cmc_required', N'CMC required', N'COMPLIANCE_RISK', N'YES_NO', NULL, N'Required', N'Triggers comprehensive maintenance contract coverage tracking.', 0, 0, N'VALUE', NULL, N'INTERNAL', 200),
    (N'exception_status', N'Exception status', N'COMPLIANCE_RISK', N'LOOKUP', N'OPTION:exception_status', N'Controlled values; approval required for Approved', N'Records whether the asset operates under an approved exception.', 0, 0, N'VALUE', NULL, N'INTERNAL', 210),
    (N'exception_expiry_date', N'Exception expiry date', N'COMPLIANCE_RISK', N'DATE', NULL, N'Required for approved time-bound exceptions', N'Triggers reminders, escalation and reassessment.', 0, 0, N'VALUE', NULL, N'INTERNAL', 220),
    (N'compliance_status', N'Compliance status', N'COMPLIANCE_RISK', N'CALCULATED', NULL, N'System-calculated; manual override requires approval', N'Overall compliance result derived from applicable tasks, evidence and exceptions.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 230),
    (N'operating_system', N'Operating system', N'TECHNICAL_CYBER', N'OS_RELEASE', N'MASTER:OS_RELEASE', N'Required for computing assets; approved compatible values', N'References operating-system family, edition, version and lifecycle record.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
    (N'os_build_patch_level', N'OS build / patch level', N'TECHNICAL_CYBER', N'TEXT', NULL, N'Format configurable; required where OS applies', N'Records installed build and patch level.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
    (N'firmware_version', N'Firmware version', N'TECHNICAL_CYBER', N'FIRMWARE', N'MASTER:FIRMWARE', N'Required where firmware applies; approved compatible values', N'References installed firmware and lifecycle record.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
    (N'bios_uefi_version', N'BIOS / UEFI version', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:bios_uefi_version', N'Required for managed computing assets where applicable', N'Records platform firmware version.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
    (N'ip_address', N'IP address', N'TECHNICAL_CYBER', N'IP_ADDRESS', NULL, N'Valid IPv4 or IPv6; duplicate warning', N'Records assigned network address.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 50),
    (N'secondary_ip_addresses', N'Secondary IP addresses', N'TECHNICAL_CYBER', N'IP_LIST', NULL, N'Valid IPv4/IPv6; duplicate warning', N'Records additional interfaces or addresses.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 60),
    (N'mac_address', N'MAC address', N'TECHNICAL_CYBER', N'TEXT', NULL, N'Valid MAC format; duplicate warning', N'Records physical network-interface address.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 70),
    (N'hostname', N'Hostname', N'TECHNICAL_CYBER', N'TEXT', NULL, N'Valid naming convention; unique within domain', N'Network hostname used for discovery and management.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 80),
    (N'domain', N'Domain', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:domain', N'Approved directory or DNS domain values only', N'Identifies domain association.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
    (N'installed_software', N'Installed software', N'TECHNICAL_CYBER', N'MULTI_SELECT', N'OPTION:installed_software', N'Approved catalogue values; discovery sync allowed', N'Lists installed applications for licence and security review.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
    (N'encryption_status', N'Encryption status', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:encryption_status', N'Required for data-storing assets', N'Records whether required encryption is enabled, partial, disabled or unknown.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
    (N'encryption_method', N'Encryption method', N'TECHNICAL_CYBER', N'MULTI_SELECT', N'OPTION:encryption_method', N'Required when encryption status is enabled/partial', N'Records disk, file, database, application or transport encryption.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
    (N'antivirus_status', N'Antivirus status', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:antivirus_status', N'Required for supported endpoints and servers', N'Records deployment, health and reporting state.', 0, 0, N'VALUE', NULL, N'INTERNAL', 130),
    (N'edr_xdr_status', N'EDR/XDR status', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:edr_xdr_status', N'Required for supported endpoints and servers', N'Records endpoint detection and response onboarding and health.', 0, 0, N'VALUE', NULL, N'INTERNAL', 140),
    (N'backup_requirement', N'Backup requirement', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:backup_requirement', N'Required for data-bearing or service assets', N'Defines backup requirement and policy tier.', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
    (N'backup_status', N'Backup status', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:backup_status', N'Required when backup is required', N'Records success, failure, not configured or unknown state.', 0, 0, N'VALUE', NULL, N'INTERNAL', 160),
    (N'recovery_tier_rto', N'Recovery tier / RTO', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:recovery_tier_rto', N'Required for critical service assets', N'Defines recovery time expectation.', 0, 0, N'VALUE', NULL, N'INTERNAL', 170),
    (N'rpo', N'RPO', N'TECHNICAL_CYBER', N'QUANTITY_UNIT', NULL, N'Required where backup/recovery applies', N'Defines maximum acceptable data-loss period.', 0, 0, N'VALUE', NULL, N'INTERNAL', 180),
    (N'network_zone', N'Network zone', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:network_zone', N'Approved zones only', N'Maps asset to network security segment.', 0, 0, N'VALUE', NULL, N'INTERNAL', 190),
    (N'internet_exposure', N'Internet exposure', N'TECHNICAL_CYBER', N'TRI_STATE', N'OPTION:yes_no_unknown', N'Required for network-connected assets', N'Indicates direct or indirect public exposure.', 0, 0, N'VALUE', NULL, N'INTERNAL', 200),
    (N'remote_access_enabled', N'Remote access enabled', N'TECHNICAL_CYBER', N'YES_NO', NULL, N'Required; approval reference when Yes', N'Indicates whether remote administrative or user access is permitted.', 0, 0, N'VALUE', NULL, N'INTERNAL', 210),
    (N'remote_access_method', N'Remote access method', N'TECHNICAL_CYBER', N'MULTI_SELECT', N'OPTION:remote_access_method', N'Required when remote access enabled', N'Records VPN, ZTNA, RDP gateway, vendor tunnel or other method.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 220),
    (N'privileged_access_present', N'Privileged access present', N'TECHNICAL_CYBER', N'YES_NO', NULL, N'Required for managed technical assets', N'Indicates whether privileged credentials or administration exist.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 230),
    (N'mfa_required', N'MFA required', N'TECHNICAL_CYBER', N'YES_NO', NULL, N'Required when remote or privileged access exists', N'Defines authentication requirement.', 0, 0, N'VALUE', NULL, N'INTERNAL', 240),
    (N'logging_monitoring_required', N'Logging / monitoring required', N'TECHNICAL_CYBER', N'YES_NO', NULL, N'Required for security-relevant assets', N'Determines monitoring onboarding and evidence requirements.', 0, 0, N'VALUE', NULL, N'INTERNAL', 250),
    (N'log_source_monitoring_identifier', N'Log source / monitoring identifier', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:log_source_monitoring_identifier', N'Required when logging is enabled', N'Links the asset to SIEM, monitoring or telemetry source.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 260),
    (N'vulnerability_scanning_applicable', N'Vulnerability scanning applicable', N'TECHNICAL_CYBER', N'YES_NO', NULL, N'Required for technical assets', N'Determines vulnerability assessment scope.', 0, 0, N'VALUE', NULL, N'INTERNAL', 270),
    (N'last_vulnerability_scan_date', N'Last vulnerability scan date', N'TECHNICAL_CYBER', N'DATE', NULL, N'Cannot be future date', N'Latest completed scan date.', 0, 0, N'VALUE', NULL, N'INTERNAL', 280),
    (N'data_storage_capability', N'Data storage capability', N'TECHNICAL_CYBER', N'LOOKUP', N'OPTION:data_storage_capability', N'Required', N'Identifies whether and how the asset stores business or personal data.', 0, 0, N'VALUE', NULL, N'INTERNAL', 290),
    (N'cloud_resource_identifier', N'Cloud resource identifier', N'TECHNICAL_CYBER', N'TEXT', NULL, N'Unique per cloud tenant/subscription when provided', N'Stores resource ID or ARN for cloud assets.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 300),
    (N'integration_identifier', N'Integration identifier', N'TECHNICAL_CYBER', N'TEXT', NULL, N'Unique per source system and asset', N'Stores external-system key used for synchronization.', 0, 0, N'VALUE', NULL, N'INTERNAL', 310),
    (N'calibration_frequency', N'Calibration frequency', N'MAINTENANCE_CALIBRATION', N'QUANTITY_UNIT', NULL, N'Required when calibration required; positive value', N'Defines interval used to calculate calibration due dates.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
    (N'calibration_basis', N'Calibration basis', N'MAINTENANCE_CALIBRATION', N'LOOKUP', N'OPTION:calibration_basis', N'Required when calibration required', N'Scheduled date, approved completion date, usage or manufacturer basis.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
    (N'last_calibration_date', N'Last calibration date', N'MAINTENANCE_CALIBRATION', N'DATE', NULL, N'Cannot be a future date', N'Date of latest approved calibration activity.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
    (N'next_calibration_date', N'Next calibration date', N'MAINTENANCE_CALIBRATION', N'CALCULATED', NULL, N'Must follow last calibration date; override requires approval', N'Calculated from approved date and configured frequency.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 40),
    (N'calibration_status', N'Calibration status', N'MAINTENANCE_CALIBRATION', N'CALCULATED', NULL, N'System calculated; override controlled', N'N/A, Valid, Due Soon, Overdue or Failed.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 50),
    (N'calibration_certificate_number', N'Calibration certificate number', N'MAINTENANCE_CALIBRATION', N'TEXT', NULL, N'Required after successful calibration; unique where applicable', N'Certificate reference for traceability.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
    (N'calibration_certificate_expiry', N'Calibration certificate expiry', N'MAINTENANCE_CALIBRATION', N'DATE', NULL, N'Must follow certificate issue date', N'Drives evidence-expiry notifications.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
    (N'calibration_service_provider', N'Calibration service provider', N'MAINTENANCE_CALIBRATION', N'VENDOR', N'MASTER:VENDOR', N'Approved provider only', N'Organization performing calibration.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
    (N'maintenance_frequency', N'Maintenance frequency', N'MAINTENANCE_CALIBRATION', N'QUANTITY_UNIT', NULL, N'Required when maintenance required; positive value', N'Defines preventive maintenance interval.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
    (N'maintenance_basis', N'Maintenance basis', N'MAINTENANCE_CALIBRATION', N'LOOKUP', N'OPTION:maintenance_basis', N'Required when maintenance required', N'Calendar, completion date, usage, run-hours or manufacturer basis.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
    (N'last_maintenance_date', N'Last maintenance date', N'MAINTENANCE_CALIBRATION', N'DATE', NULL, N'Cannot be a future date', N'Date of latest approved maintenance activity.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
    (N'next_maintenance_date', N'Next maintenance date', N'MAINTENANCE_CALIBRATION', N'CALCULATED', NULL, N'Must follow last maintenance date; override requires approval', N'Calculated from approved date and frequency.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 120),
    (N'maintenance_status', N'Maintenance status', N'MAINTENANCE_CALIBRATION', N'CALCULATED', NULL, N'System calculated', N'Not Due, Due Soon, Overdue, In Progress or Completed.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 130),
    (N'usage_meter_type', N'Usage meter type', N'MAINTENANCE_CALIBRATION', N'LOOKUP', N'OPTION:usage_meter_type', N'Required for usage-based equipment', N'Odometer, run-hours, cycles, production quantity or configured unit.', 0, 0, N'VALUE', NULL, N'INTERNAL', 140),
    (N'current_meter_reading', N'Current meter reading', N'MAINTENANCE_CALIBRATION', N'DECIMAL', NULL, N'Non-negative; cannot be lower than previous reading without approved reset', N'Current usage value for scheduling.', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
    (N'measurement_range', N'Measurement range', N'MAINTENANCE_CALIBRATION', N'TEXT', NULL, N'Minimum cannot exceed maximum; unit required', N'Certified operating or measurement range.', 0, 0, N'VALUE', NULL, N'INTERNAL', 160),
    (N'accuracy', N'Accuracy', N'MAINTENANCE_CALIBRATION', N'TEXT', NULL, N'Unit or percentage required', N'Specified measurement accuracy.', 0, 0, N'VALUE', NULL, N'INTERNAL', 170),
    (N'tolerance', N'Tolerance', N'MAINTENANCE_CALIBRATION', N'TEXT', NULL, N'Unit or percentage required', N'Permitted process or measurement tolerance.', 0, 0, N'VALUE', NULL, N'INTERNAL', 180),
    (N'operating_instructions', N'Operating instructions', N'MAINTENANCE_CALIBRATION', N'ATTACHMENT', NULL, N'Required for controlled equipment', N'Links approved operating instructions or manufacturer manual.', 0, 0, N'VALUE', NULL, N'INTERNAL', 190),
    (N'safety_instructions', N'Safety instructions', N'MAINTENANCE_CALIBRATION', N'ATTACHMENT', NULL, N'Required where safety hazards exist', N'Links approved safe-use, shutdown and emergency instructions.', 0, 0, N'VALUE', NULL, N'INTERNAL', 200),
    (N'equipment_licence_number', N'Equipment licence number', N'MAINTENANCE_CALIBRATION', N'TEXT', NULL, N'Required when licence is required; unique as applicable', N'Regulatory or operational equipment licence reference.', 0, 0, N'VALUE', NULL, N'INTERNAL', 210),
    (N'equipment_licence_expiry', N'Equipment licence expiry', N'MAINTENANCE_CALIBRATION', N'DATE', NULL, N'Required when licence has validity period', N'Triggers licence renewal and restriction workflow.', 0, 0, N'VALUE', NULL, N'INTERNAL', 220),
    (N'inspection_frequency', N'Inspection frequency', N'MAINTENANCE_CALIBRATION', N'QUANTITY_UNIT', NULL, N'Required when statutory inspection required', N'Defines recurring inspection interval.', 0, 0, N'VALUE', NULL, N'INTERNAL', 230),
    (N'last_inspection_date', N'Last inspection date', N'MAINTENANCE_CALIBRATION', N'DATE', NULL, N'Cannot be future date', N'Date of latest approved inspection.', 0, 0, N'VALUE', NULL, N'INTERNAL', 240),
    (N'next_inspection_date', N'Next inspection date', N'MAINTENANCE_CALIBRATION', N'CALCULATED', NULL, N'Must follow last inspection date; override controlled', N'Drives inspection tasks and reminders.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 250),
    (N'biomedical_device_class', N'Biomedical device class', N'BIOMEDICAL', N'LOOKUP', N'OPTION:biomedical_device_class', N'Required for regulated biomedical equipment; configured jurisdiction values', N'Regulatory device classification.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
    (N'clinical_department', N'Clinical department', N'BIOMEDICAL', N'LOOKUP', N'MASTER:DEPARTMENT', N'Required for deployed clinical equipment', N'Department accountable for clinical use.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
    (N'patient_use_classification', N'Patient-use classification', N'BIOMEDICAL', N'LOOKUP', N'OPTION:patient_use_classification', N'Required for biomedical equipment', N'Classifies direct patient use, diagnostic, monitoring, therapeutic or support use.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
    (N'patient_safety_classification', N'Patient safety classification', N'BIOMEDICAL', N'LOOKUP', N'OPTION:patient_safety_classification', N'Required; approved scale', N'Critical, High, Medium or Low patient-safety impact.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
    (N'life_support_equipment', N'Life-support equipment', N'BIOMEDICAL', N'YES_NO', NULL, N'Required', N'Identifies equipment essential to sustaining life.', 0, 0, N'VALUE', NULL, N'INTERNAL', 50),
    (N'electrical_safety_category', N'Electrical safety category', N'BIOMEDICAL', N'LOOKUP', N'OPTION:electrical_safety_category', N'Required where electrical safety applies', N'Records approved electrical safety class/category.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
    (N'electrical_safety_test_required', N'Electrical safety test required', N'BIOMEDICAL', N'YES_NO', NULL, N'Required', N'Triggers test frequency and evidence.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
    (N'last_electrical_safety_test', N'Last electrical safety test', N'BIOMEDICAL', N'DATE', NULL, N'Cannot be future date', N'Date of most recent approved electrical safety test.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
    (N'next_electrical_safety_test', N'Next electrical safety test', N'BIOMEDICAL', N'CALCULATED', NULL, N'Must follow last test', N'Drives recurring safety test task.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 90),
    (N'sterilization_disinfection_required', N'Sterilization / disinfection required', N'BIOMEDICAL', N'YES_NO', NULL, N'Required for reusable patient-contact equipment', N'Triggers decontamination controls and evidence.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
    (N'sterilization_method', N'Sterilization method', N'BIOMEDICAL', N'MULTI_SELECT', N'OPTION:sterilization_method', N'Required when sterilization is required', N'Approved sterilization or disinfection method.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
    (N'biomedical_engineer', N'Biomedical engineer', N'BIOMEDICAL', N'USER_OR_TEAM', N'MASTER:EMPLOYEE_OR_TEAM', N'Required for maintained biomedical assets', N'Responsible biomedical engineering contact.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
    (N'oem_service_authorization_required', N'OEM service authorization required', N'BIOMEDICAL', N'YES_NO', NULL, N'Required', N'Controls assignment to approved service providers.', 0, 0, N'VALUE', NULL, N'INTERNAL', 130),
    (N'medical_gas_connection', N'Medical gas connection', N'BIOMEDICAL', N'LOOKUP', N'OPTION:medical_gas_connection', N'Required where medical gas is used', N'Records oxygen, air, vacuum or other connection.', 0, 0, N'VALUE', NULL, N'INTERNAL', 140),
    (N'software_as_medical_device_component', N'Software as medical device component', N'BIOMEDICAL', N'YES_NO', NULL, N'Required where embedded/standalone clinical software applies', N'Triggers software lifecycle and validation controls. clinical software applies', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
    (N'validation_status', N'Validation status', N'BIOMEDICAL', N'LOOKUP', N'OPTION:validation_status', N'Required for validated clinical equipment', N'Not Validated, Valid, Due, Failed or Conditional.', 0, 0, N'VALUE', NULL, N'INTERNAL', 160),
    (N'recall_status', N'Recall status', N'BIOMEDICAL', N'LOOKUP', N'OPTION:recall_status', N'Controlled values', N'None, Under Review, Recalled, Corrective Action or Closed.', 0, 0, N'VALUE', NULL, N'INTERNAL', 170),
    (N'condemnation_category', N'Condemnation category', N'BIOMEDICAL', N'LOOKUP', N'OPTION:condemnation_category', N'Required when condemnation is initiated', N'Reason and classification for retirement/condemnation.', 0, 0, N'VALUE', NULL, N'INTERNAL', 180),
    (N'registration_number', N'Registration number', N'VEHICLE', N'TEXT', NULL, N'Required; valid regional format; unique', N'Official vehicle registration identifier.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
    (N'registration_date', N'Registration date', N'VEHICLE', N'DATE', NULL, N'Cannot be future date', N'Date vehicle was registered.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
    (N'registration_expiry', N'Registration expiry', N'VEHICLE', N'DATE', NULL, N'Must follow registration date where applicable', N'Triggers renewal notifications and restricted-use rules.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
    (N'chassis_vin', N'Chassis / VIN', N'VEHICLE', N'TEXT', NULL, N'Required; unique; format configurable', N'Manufacturer vehicle identification number.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
    (N'engine_motor_number', N'Engine / motor number', N'VEHICLE', N'TEXT', NULL, N'Required where applicable; unique', N'Engine or traction-motor identifier.', 0, 0, N'VALUE', NULL, N'INTERNAL', 50),
    (N'insurance_policy_number', N'Insurance policy number', N'VEHICLE', N'TEXT', NULL, N'Required when insurance required', N'Links vehicle to insurance policy or contract.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
    (N'insurance_expiry', N'Insurance expiry', N'VEHICLE', N'DATE', NULL, N'Required when insurance required', N'Triggers renewal and compliance status updates.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
    (N'fitness_certificate_number', N'Fitness certificate number', N'VEHICLE', N'TEXT', NULL, N'Required where legally applicable', N'Statutory fitness certificate reference.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
    (N'fitness_certificate_expiry', N'Fitness certificate expiry', N'VEHICLE', N'DATE', NULL, N'Required where legally applicable', N'Tracks statutory fitness validity and renewal.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
    (N'pollution_certificate_number', N'Pollution certificate number', N'VEHICLE', N'TEXT', NULL, N'Required where legally applicable', N'Emissions certificate reference.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
    (N'pollution_certificate_expiry', N'Pollution certificate expiry', N'VEHICLE', N'DATE', NULL, N'Required where legally applicable', N'Tracks emissions certificate validity.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
    (N'permit_number', N'Permit number', N'VEHICLE', N'TEXT', NULL, N'Required for permit-controlled vehicles', N'Operational or jurisdictional permit reference.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
    (N'permit_expiry', N'Permit expiry', N'VEHICLE', N'DATE', NULL, N'Required for permit-controlled vehicles', N'Tracks permit validity.', 0, 0, N'VALUE', NULL, N'INTERNAL', 130),
    (N'road_tax_expiry', N'Road tax expiry', N'VEHICLE', N'DATE', NULL, N'Required where applicable', N'Tracks road-tax validity.', 0, 0, N'VALUE', NULL, N'INTERNAL', 140),
    (N'fuel_type', N'Fuel type', N'VEHICLE', N'LOOKUP', N'OPTION:fuel_type', N'Required; approved values only', N'Petrol, diesel, electric, hybrid, gas or other fuel type.', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
    (N'battery_capacity', N'Battery capacity', N'VEHICLE', N'QUANTITY_UNIT', NULL, N'Required for electric/hybrid assets where applicable', N'Rated traction-battery capacity.', 0, 0, N'VALUE', NULL, N'INTERNAL', 160),
    (N'assigned_driver', N'Assigned driver', N'VEHICLE', N'USER', N'MASTER:EMPLOYEE', N'Active user with valid authorization', N'Current authorized driver.', 0, 0, N'VALUE', NULL, N'INTERNAL', 170),
    (N'driver_licence_expiry', N'Driver licence expiry', N'VEHICLE', N'CALCULATED', NULL, N'Required when driver is assigned', N'Used to validate driver authorization.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 180),
    (N'odometer_reading', N'Odometer reading', N'VEHICLE', N'DECIMAL', NULL, N'Non-negative; cannot be lower than previous reading', N'Current distance used for usage-based servicing.', 0, 0, N'VALUE', NULL, N'INTERNAL', 190),
    (N'odometer_unit', N'Odometer unit', N'VEHICLE', N'LOOKUP', N'OPTION:odometer_unit', N'Required; km or miles', N'Unit for distance readings.', 0, 0, N'VALUE', NULL, N'INTERNAL', 200),
    (N'service_interval', N'Service interval', N'VEHICLE', N'QUANTITY_UNIT', NULL, N'Positive value; distance or time unit required', N'Defines next vehicle service trigger.', 0, 0, N'VALUE', NULL, N'INTERNAL', 210),
    (N'last_service_date', N'Last service date', N'VEHICLE', N'DATE', NULL, N'Cannot be future date', N'Date of latest approved service.', 0, 0, N'VALUE', NULL, N'INTERNAL', 220),
    (N'next_service_due', N'Next service due', N'VEHICLE', N'CALCULATED', NULL, N'Must follow last date/reading', N'Next service date or odometer threshold.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 230),
    (N'telematics_identifier', N'Telematics identifier', N'VEHICLE', N'TEXT', NULL, N'Unique when provided', N'Links vehicle to tracking or telematics platform.', 0, 0, N'VALUE', NULL, N'INTERNAL', 240),
    (N'fuel_card_number', N'Fuel card number', N'VEHICLE', N'TEXT', NULL, N'Unique; restricted visibility', N'Links vehicle to fuel-card control.', 0, 0, N'VALUE', NULL, N'RESTRICTED', 250),
    (N'dpdp_applicable', N'DPDP applicable', N'PRIVACY', N'TRI_STATE', N'OPTION:yes_no_assessment', N'Required for digital personal-data assets', N'Records India DPDP applicability assessment.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 10),
    (N'gdpr_applicable', N'GDPR applicable', N'PRIVACY', N'TRI_STATE', N'OPTION:yes_no_assessment', N'Required where EU personal data may be processed', N'Records GDPR applicability assessment.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 20),
    (N'privacy_assessment_status', N'Privacy assessment status', N'PRIVACY', N'LOOKUP', N'OPTION:privacy_assessment_status', N'Required when personal data is Yes/Unknown', N'Not Assessed, Pending, Approved, Conditional or Non-Compliant.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 30),
    (N'personal_data_categories', N'Personal data categories', N'PRIVACY', N'MULTI_SELECT', N'OPTION:personal_data_categories', N'Required when personal data processed', N'Name, contact, identifier, financial, health, biometric, location and configured categories.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 40),
    (N'data_subject_categories', N'Data subject categories', N'PRIVACY', N'MULTI_SELECT', N'OPTION:data_subject_categories', N'Required when personal data processed', N'Employees, customers, patients, vendors, visitors, children and other subjects.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 50),
    (N'processing_operations', N'Processing operations', N'PRIVACY', N'MULTI_SELECT', N'OPTION:processing_operations', N'Required when personal data processed', N'Store, process, receive, generate, display, transmit, back up or delete.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 60),
    (N'processing_activity', N'Processing activity', N'PRIVACY', N'LOOKUP', N'OPTION:processing_activity', N'Required when personal data processed', N'Links asset to the relevant processing activity/register.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 70),
    (N'processing_purpose', N'Processing purpose', N'PRIVACY', N'MULTILINE', NULL, N'Required when personal data processed', N'Approved purpose for the supported processing.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 80),
    (N'high_risk_processing', N'High-risk processing', N'PRIVACY', N'TRI_STATE', N'OPTION:yes_no_assessment', N'Required', N'Flags processing requiring enhanced assessment.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 90),
    (N'dpia_pia_required', N'DPIA / PIA required', N'PRIVACY', N'YES_NO', NULL, N'Required for applicable privacy assets', N'Determines formal assessment workflow.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 100),
    (N'dpia_pia_status', N'DPIA / PIA status', N'PRIVACY', N'LOOKUP', N'OPTION:dpia_pia_status', N'Required when assessment is required', N'Not Started, In Progress, Approved, Rejected or Expired.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 110),
    (N'masking_applicable', N'Masking applicable', N'PRIVACY', N'TRI_STATE', N'OPTION:yes_no_assessment', N'Required when personal data processed', N'Determines whether masking control is required.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 120),
    (N'masking_implemented', N'Masking implemented', N'PRIVACY', N'TRI_STATE', N'OPTION:yes_no_partial', N'Required when masking applicable', N'Records implementation status.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 130),
    (N'masking_method', N'Masking method', N'PRIVACY', N'MULTI_SELECT', N'OPTION:masking_method', N'Required when implemented/partial', N'Static, Dynamic, Tokenization, Pseudonymization, Anonymization, Partial Mask, Redaction, Obfuscation, Encryption-based or Custom.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 140),
    (N'masking_coverage', N'Masking coverage', N'PRIVACY', N'MULTI_SELECT', N'OPTION:masking_coverage', N'Required when masking applies', N'Production, non-production, reports, exports, logs and backups.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 150),
    (N'encryption_required', N'Encryption required', N'PRIVACY', N'YES_NO', NULL, N'Required when personal data processed', N'Defines encryption control requirement.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 160),
    (N'encryption_implemented', N'Encryption implemented', N'PRIVACY', N'TRI_STATE', N'OPTION:yes_no_partial', N'Required when encryption required', N'Records implementation status and drives privacy compliance.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 170),
    (N'retention_policy', N'Retention policy', N'PRIVACY', N'LOOKUP', N'OPTION:retention_policy', N'Required when personal data processed', N'Links approved retention schedule.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 180),
    (N'retention_period', N'Retention period', N'PRIVACY', N'QUANTITY_UNIT', NULL, N'Required when retention applies; positive value', N'Duration for retaining personal data.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 190),
    (N'retention_trigger', N'Retention trigger', N'PRIVACY', N'LOOKUP', N'OPTION:retention_trigger', N'Required when retention applies', N'Creation, closure, employment end, contract end, last activity or configured trigger.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 200),
    (N'auto_purge_enabled', N'Auto-purge enabled', N'PRIVACY', N'YES_NO', NULL, N'Required where supported', N'Indicates automated deletion or archival.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 210),
    (N'legal_hold_status', N'Legal hold status', N'PRIVACY', N'YES_NO', NULL, N'Required', N'Prevents deletion while approved legal hold is active.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 220),
    (N'third_party_access', N'Third-party access', N'PRIVACY', N'YES_NO', NULL, N'Required', N'Indicates processor/vendor access to personal data.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 230),
    (N'processor_third_party', N'Processor / third party', N'PRIVACY', N'VENDOR', N'MASTER:VENDOR', N'Required when third-party access is Yes', N'Identifies external processor or recipient.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 240),
    (N'cross_border_transfer', N'Cross-border transfer', N'PRIVACY', N'TRI_STATE', N'OPTION:yes_no_assessment', N'Required when third party or external hosting applies', N'Triggers country and transfer-control assessment.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 250),
    (N'transfer_countries', N'Transfer countries', N'PRIVACY', N'MULTI_SELECT', N'MASTER:COUNTRY', N'Required when cross-border transfer is Yes', N'Countries where data is transferred or accessed.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 260),
    (N'deletion_sanitization_required', N'Deletion / sanitization required', N'PRIVACY', N'YES_NO', NULL, N'Required for personal-data-bearing assets', N'Triggers disposal privacy controls.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 270),
    (N'privacy_review_date', N'Privacy review date', N'PRIVACY', N'DATE', NULL, N'Required when privacy applies', N'Next scheduled privacy review.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 280),
    (N'residual_privacy_risk', N'Residual privacy risk', N'PRIVACY', N'LOOKUP', N'OPTION:residual_privacy_risk', N'Required after privacy assessment', N'Approved residual-risk level.', 0, 0, N'VALUE', NULL, N'CONFIDENTIAL', 290),
    (N'primary_support_contract', N'Primary support contract', N'CONTRACT_COVERAGE', N'CONTRACT', N'MASTER:CONTRACT', N'Required when contract coverage exists', N'Links the asset to its primary warranty, support, AMC or CMC agreement.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
    (N'coverage_type', N'Coverage type', N'CONTRACT_COVERAGE', N'LOOKUP', N'OPTION:coverage_type', N'Required with contract mapping', N'Warranty, AMC, CMC, licence, insurance, calibration, managed service or custom.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
    (N'coverage_start_date', N'Coverage start date', N'CONTRACT_COVERAGE', N'DATE', NULL, N'Must not follow coverage end date', N'Asset-specific coverage start.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
    (N'coverage_end_date', N'Coverage end date', N'CONTRACT_COVERAGE', N'DATE', NULL, N'Must follow coverage start date', N'Drives expiry and uncovered status.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
    (N'coverage_status', N'Coverage status', N'CONTRACT_COVERAGE', N'CALCULATED', NULL, N'System calculated', N'Covered, Expiring, Expired, Uncovered, Suspended or Excluded.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 50),
    (N'entitlement_sku', N'Entitlement / SKU', N'CONTRACT_COVERAGE', N'LOOKUP', N'OPTION:entitlement_sku', N'Required where entitlement applies', N'Purchased service or licence entitlement.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
    (N'service_level', N'Service level', N'CONTRACT_COVERAGE', N'LOOKUP', N'OPTION:service_level', N'Must be valid for selected contract', N'Applicable service tier or SLA.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
    (N'support_hours', N'Support hours', N'CONTRACT_COVERAGE', N'LOOKUP', N'OPTION:support_hours', N'Optional', N'Applicable support window.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
    (N'contract_exclusion_reason', N'Contract exclusion reason', N'CONTRACT_COVERAGE', N'MULTILINE', NULL, N'Required when coverage status is Excluded', N'Explains why asset is not covered.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
    (N'vendor_support_reference', N'Vendor support reference', N'CONTRACT_COVERAGE', N'TEXT', NULL, N'Optional', N'Vendor portal, entitlement or service reference.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
    (N'decommission_request_date', N'Decommission request date', N'DISPOSAL', N'DATE', NULL, N'Required when retirement initiated', N'Date retirement workflow began.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
    (N'decommission_reason', N'Decommission reason', N'DISPOSAL', N'LOOKUP', N'OPTION:decommission_reason', N'Required', N'Obsolete, unsupported, damaged, replaced, lost, sold or configured reason.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
    (N'dependency_review_completed', N'Dependency review completed', N'DISPOSAL', N'YES_NO', NULL, N'Required before disposal approval', N'Confirms service, contract, data and integration dependencies reviewed.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
    (N'data_backup_retention_decision', N'Data backup / retention decision', N'DISPOSAL', N'LOOKUP', N'OPTION:data_backup_retention_decision', N'Required for data-bearing assets', N'Retain, migrate, archive, delete or not applicable.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
    (N'sanitization_required', N'Sanitization required', N'DISPOSAL', N'YES_NO', NULL, N'Required', N'Determines secure erasure or media destruction workflow.', 0, 0, N'VALUE', NULL, N'INTERNAL', 50),
    (N'sanitization_method', N'Sanitization method', N'DISPOSAL', N'LOOKUP', N'OPTION:sanitization_method', N'Required when sanitization required', N'Clear, purge, cryptographic erase, degauss, physical destruction or approved method.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
    (N'sanitization_date', N'Sanitization date', N'DISPOSAL', N'DATE', NULL, N'Cannot be future date', N'Date sanitization completed.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
    (N'sanitization_evidence', N'Sanitization evidence', N'DISPOSAL', N'ATTACHMENT', NULL, N'Required when sanitization required', N'Certificate, tool log or verification evidence.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
    (N'licence_access_revoked', N'Licence/access revoked', N'DISPOSAL', N'YES_NO', NULL, N'Required for technical/software assets', N'Confirms access, certificates and entitlements removed.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
    (N'disposal_method', N'Disposal method', N'DISPOSAL', N'LOOKUP', N'OPTION:disposal_method', N'Required', N'Return, resale, donation, recycle, scrap, destroy or transfer.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
    (N'disposal_vendor', N'Disposal vendor', N'DISPOSAL', N'VENDOR', N'MASTER:VENDOR', N'Required for third-party disposal', N'Approved disposal/recycling vendor.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
    (N'disposal_certificate_number', N'Disposal certificate number', N'DISPOSAL', N'TEXT', NULL, N'Required where certificate issued', N'Certificate reference.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
    (N'disposal_date', N'Disposal date', N'DISPOSAL', N'DATE', NULL, N'Cannot precede approval date', N'Date physical or logical disposal completed.', 0, 0, N'VALUE', NULL, N'INTERNAL', 130),
    (N'final_approval', N'Final approval', N'DISPOSAL', N'APPROVAL_REF', NULL, N'Required before Disposed status', N'Authorized disposal approval.', 0, 0, N'VALUE', NULL, N'INTERNAL', 140),
    (N'archive_date', N'Archive date', N'DISPOSAL', N'DATE', NULL, N'Must be on or after disposal date', N'Date record moved to archived lifecycle status.', 0, 0, N'VALUE', NULL, N'INTERNAL', 150),
    (N'created_by', N'Created by', N'AUDIT_INTEGRATION', N'SYSTEM', NULL, N'Required; read-only', N'User or integration that created the record.', 0, 1, N'COLUMN', N'entered_by', N'INTERNAL', 10),
    (N'created_date_time', N'Created date/time', N'AUDIT_INTEGRATION', N'DATETIME', NULL, N'Required; read-only', N'Record creation timestamp in tenant time zone/UTC storage.', 0, 1, N'COLUMN', N'entered_dt', N'INTERNAL', 20),
    (N'last_modified_by', N'Last modified by', N'AUDIT_INTEGRATION', N'SYSTEM', NULL, N'Required; read-only', N'Actor responsible for latest change.', 0, 1, N'COLUMN', N'updated_by', N'INTERNAL', 30),
    (N'last_modified_date_time', N'Last modified date/time', N'AUDIT_INTEGRATION', N'DATETIME', NULL, N'Required; read-only', N'Latest modification timestamp.', 0, 1, N'COLUMN', N'updated_dt', N'INTERNAL', 40),
    (N'record_version', N'Record version', N'AUDIT_INTEGRATION', N'SYSTEM', NULL, N'Required; incremented on change', N'Supports optimistic concurrency and audit reconstruction.', 0, 1, N'SYSTEM', NULL, N'INTERNAL', 50),
    (N'approval_status', N'Approval status', N'AUDIT_INTEGRATION', N'LOOKUP', N'OPTION:approval_status', N'Controlled by workflow', N'Draft, Submitted, Pending Approval, Approved, Rejected or Returned.', 0, 0, N'VALUE', NULL, N'INTERNAL', 60),
    (N'data_confidence', N'Data confidence', N'AUDIT_INTEGRATION', N'LOOKUP', N'OPTION:data_confidence', N'Required for discovered/imported data', N'Verified, Probable, Unverified, Stale or Conflicting.', 0, 0, N'VALUE', NULL, N'INTERNAL', 70),
    (N'last_verified_date', N'Last verified date', N'AUDIT_INTEGRATION', N'DATE', NULL, N'Required for governed catalog/critical data', N'Date record was last validated.', 0, 0, N'VALUE', NULL, N'INTERNAL', 80),
    (N'verified_by', N'Verified by', N'AUDIT_INTEGRATION', N'USER', N'MASTER:EMPLOYEE', N'Required when verified', N'Accountable verifier.', 0, 0, N'VALUE', NULL, N'INTERNAL', 90),
    (N'sync_status', N'Sync status', N'AUDIT_INTEGRATION', N'LOOKUP', N'OPTION:sync_status', N'Required for integrated records', N'Not Applicable, Pending, Synchronized, Warning or Failed.', 0, 0, N'VALUE', NULL, N'INTERNAL', 100),
    (N'last_synchronization_time', N'Last synchronization time', N'AUDIT_INTEGRATION', N'DATETIME', NULL, N'Read-only for integrations', N'Latest successful or attempted synchronization.', 0, 0, N'VALUE', NULL, N'INTERNAL', 110),
    (N'import_batch_job_id', N'Import batch / job ID', N'AUDIT_INTEGRATION', N'LOOKUP', N'OPTION:import_batch_job_id', N'Required for imported records', N'Links record to import and per-record result.', 0, 0, N'VALUE', NULL, N'INTERNAL', 120),
    (N'audit_event_count_link', N'Audit event count / link', N'AUDIT_INTEGRATION', N'CALCULATED', NULL, N'Read-only', N'Opens immutable event history.', 0, 1, N'SYSTEM', NULL, N'INTERNAL', 130),
    (N'confidentiality_rating', N'Confidentiality Rating', N'CIA_VALUATION', N'LOOKUP', N'OPTION:confidentiality_rating', N'Required for information-processing assets', N'Impact if information is disclosed.', 0, 0, N'VALUE', NULL, N'INTERNAL', 10),
    (N'integrity_rating', N'Integrity Rating', N'CIA_VALUATION', N'LOOKUP', N'OPTION:integrity_rating', N'Required for information-processing assets', N'Impact if information or process is altered.', 0, 0, N'VALUE', NULL, N'INTERNAL', 20),
    (N'availability_rating', N'Availability Rating', N'CIA_VALUATION', N'LOOKUP', N'OPTION:availability_rating', N'Required for information-processing assets', N'Impact if unavailable when required.', 0, 0, N'VALUE', NULL, N'INTERNAL', 30),
    (N'asset_valuation_method', N'Asset Valuation Method', N'CIA_VALUATION', N'LOOKUP', N'OPTION:asset_valuation_method', N'Required for information-processing assets', N'Maximum, Weighted Average or Summation.', 0, 0, N'VALUE', NULL, N'INTERNAL', 40),
    (N'asset_value_score', N'Asset Value Score', N'CIA_VALUATION', N'CALCULATED', NULL, N'System-calculated; read-only', N'Calculated CIA-based score.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 50),
    (N'asset_value_category', N'Asset Value Category', N'CIA_VALUATION', N'CALCULATED', NULL, N'System-calculated; read-only', N'Low, Medium, High or Critical.', 0, 0, N'SYSTEM', NULL, N'INTERNAL', 60),
    (N'amc_expiry_date', N'AMC expiry date (legacy)', N'CONTRACT_COVERAGE', N'DATE', NULL, N'Optional', N'Carried from the original Assets tab (organization_dependency_asset.amc_expiry_dt). Superseded by contract coverage records in Phase 5; kept so existing values stay visible.', 0, 0, N'COLUMN', N'amc_expiry_dt', N'INTERNAL', 900),
    (N'remarks', N'Remarks', N'IDENTIFICATION', N'MULTILINE', NULL, N'Optional', N'Carried from the original Assets tab (organization_dependency_asset.remarks).', 0, 0, N'COLUMN', N'remarks', N'INTERNAL', 900)
      ) AS v(field_key, display_label, group_code, data_type_code, lookup_source,
             validation_rule_text, description, is_system_mandatory, is_system_field,
             storage_kind, column_name, sensitivity_code, display_order)
      JOIN grac_practice.asset_field_group_master g ON g.group_code = v.group_code
) AS s
ON t.field_key = s.field_key
WHEN NOT MATCHED BY TARGET THEN
    INSERT (field_key, display_label, field_group_id, data_type_code, lookup_source,
            validation_rule_text, description, is_system_mandatory, is_system_field,
            storage_kind, column_name, sensitivity_code, display_order, entered_by)
    VALUES (s.field_key, s.display_label, s.field_group_id, s.data_type_code, s.lookup_source,
            s.validation_rule_text, s.description, s.is_system_mandatory, s.is_system_field,
            s.storage_kind, s.column_name, s.sensitivity_code, s.display_order, N'seed-420');
PRINT CONCAT('420: field definitions inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 4. Template lifecycle on the state-machine framework (035)
-- =====================================================================
MERGE grac_practice.entity_status_master AS t
USING (VALUES
    (N'AssetFormTemplate', N'DRAFT',            N'Draft',            10, 0, 1, N'Editable configuration; unavailable for asset registration.'),
    (N'AssetFormTemplate', N'TESTING',          N'Testing',          20, 0, 0, N'Locked baseline under scenario validation.'),
    (N'AssetFormTemplate', N'PENDING_APPROVAL', N'Pending Approval', 30, 0, 0, N'Submitted with change summary and readiness report.'),
    (N'AssetFormTemplate', N'APPROVED',         N'Approved',         40, 0, 0, N'Authorized version ready for activation.'),
    (N'AssetFormTemplate', N'ACTIVE',           N'Active',           50, 0, 0, N'Default version for new assets of the type.'),
    (N'AssetFormTemplate', N'RETIRED',          N'Retired',          60, 1, 0, N'Unavailable for new assets; kept for history and existing records.')
) AS s(entity_type, status_code, status_name, display_order, is_terminal, is_initial, description)
ON t.entity_type = s.entity_type AND t.status_code = s.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, status_code, status_name, display_order, is_terminal, is_initial, description, entered_by)
    VALUES (s.entity_type, s.status_code, s.status_name, s.display_order, s.is_terminal, s.is_initial, s.description, N'seed-420');
PRINT CONCAT('420: AssetFormTemplate statuses inserted: ', @@ROWCOUNT);
GO

MERGE grac_practice.entity_state_transition_rule AS t
USING (VALUES
    (CAST(NULL AS NVARCHAR(60)), N'DRAFT',     0, 0, N'Create a draft version.'),
    (N'DRAFT',            N'TESTING',          0, 0, N'Lock the draft for testing.'),
    (N'DRAFT',            N'RETIRED',          1, 0, N'Discard a draft.'),
    (N'TESTING',          N'DRAFT',            1, 0, N'Return to draft for changes.'),
    (N'TESTING',          N'PENDING_APPROVAL', 0, 0, N'Submit for approval.'),
    (N'TESTING',          N'APPROVED',         0, 0, N'Approve without review (template does not require approval).'),
    (N'PENDING_APPROVAL', N'APPROVED',         0, 1, N'Approve the version.'),
    (N'PENDING_APPROVAL', N'DRAFT',            1, 0, N'Return or reject to draft.'),
    (N'APPROVED',         N'ACTIVE',           0, 0, N'Activate for new asset registrations.'),
    (N'APPROVED',         N'RETIRED',          1, 0, N'Withdraw an approved version.'),
    (N'ACTIVE',           N'RETIRED',          1, 0, N'Retire, or superseded by a newer active version.')
) AS s(from_status_code, to_status_code, requires_reason, requires_approval, description)
ON t.entity_type = N'AssetFormTemplate'
   AND ISNULL(t.from_status_code, N'__NULL__') = ISNULL(s.from_status_code, N'__NULL__')
   AND t.to_status_code = s.to_status_code
   AND t.actor_role_code IS NULL
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, from_status_code, to_status_code, actor_role_code, requires_reason, requires_approval, description, entered_by)
    VALUES (N'AssetFormTemplate', s.from_status_code, s.to_status_code, NULL, s.requires_reason, s.requires_approval, s.description, N'seed-420');
PRINT CONCAT('420: AssetFormTemplate transition rules inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 5. Dictionary readers
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_field_group_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT g.field_group_id AS FieldGroupId, g.group_code AS GroupCode, g.group_name AS GroupName,
           g.brd_section AS BrdSection, g.display_order AS DisplayOrder,
           (SELECT COUNT(*) FROM grac_practice.asset_field_definition d
             WHERE d.field_group_id = g.field_group_id AND d.status_code = N'ACTIVE') AS FieldCount
      FROM grac_practice.asset_field_group_master g
     WHERE g.is_active = 1
     ORDER BY g.display_order, g.group_name;
    SELECT data_type_code AS DataTypeCode, data_type_name AS DataTypeName, is_user_entered AS IsUserEntered
      FROM grac_practice.asset_field_data_type_master
     WHERE is_active = 1
     ORDER BY display_order;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_field_definition_list
    @group_code       NVARCHAR(60)  = NULL,
    @data_type_code   NVARCHAR(30)  = NULL,
    @sensitivity_code NVARCHAR(20)  = NULL,
    @search           NVARCHAR(200) = NULL,
    @placeable_only   BIT           = 0,
    @include_retired  BIT           = 0,
    @page_number      INT           = 1,
    @page_size        INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @page_number = CASE WHEN ISNULL(@page_number, 0) < 1 THEN 1 ELSE @page_number END;
    SET @page_size   = CASE WHEN ISNULL(@page_size, 0) < 1 THEN 25 WHEN @page_size > 500 THEN 500 ELSE @page_size END;
    SET @search      = NULLIF(LTRIM(RTRIM(@search)), N'');

    SELECT d.field_definition_id AS FieldDefinitionId, d.field_key AS FieldKey, d.display_label AS DisplayLabel,
           g.group_code AS GroupCode, g.group_name AS GroupName, g.brd_section AS BrdSection,
           d.data_type_code AS DataTypeCode, dt.data_type_name AS DataTypeName,
           d.lookup_source AS LookupSource, d.validation_rule_text AS ValidationRule, d.description AS Description,
           d.is_system_mandatory AS IsSystemMandatory, d.is_system_field AS IsSystemField,
           d.storage_kind AS StorageKind, d.column_name AS ColumnName, d.sensitivity_code AS SensitivityCode,
           d.status_code AS StatusCode, d.definition_version AS DefinitionVersion,
           d.effective_from AS EffectiveFrom, d.effective_to AS EffectiveTo,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_field_definition d
      JOIN grac_practice.asset_field_group_master g ON g.field_group_id = d.field_group_id
      JOIN grac_practice.asset_field_data_type_master dt ON dt.data_type_code = d.data_type_code
     WHERE (@group_code IS NULL OR g.group_code = @group_code)
       AND (@data_type_code IS NULL OR d.data_type_code = @data_type_code)
       AND (@sensitivity_code IS NULL OR d.sensitivity_code = @sensitivity_code)
       AND (@include_retired = 1 OR d.status_code = N'ACTIVE')
       AND (@placeable_only = 0 OR d.is_system_field = 0)
       AND (@search IS NULL
            OR d.field_key LIKE N'%' + @search + N'%'
            OR d.display_label LIKE N'%' + @search + N'%'
            OR d.description LIKE N'%' + @search + N'%')
     ORDER BY g.display_order, d.display_order, d.display_label
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- 6. Template readers
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_list
    @organization_id BIGINT,
    @asset_type_id   INT           = NULL,
    @status_code     NVARCHAR(60)  = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @page_number = CASE WHEN ISNULL(@page_number, 0) < 1 THEN 1 ELSE @page_number END;
    SET @page_size   = CASE WHEN ISNULL(@page_size, 0) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    SET @search      = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @status_code = NULLIF(LTRIM(RTRIM(@status_code)), N'');

    SELECT t.template_id AS TemplateId, t.organization_id AS OrganizationId,
           t.asset_type_id AS AssetTypeId, at.asset_type_name AS AssetTypeName,
           sc.subcategory_name AS SubcategoryName, ac.asset_category_name AS CategoryName,
           t.template_name AS TemplateName, t.version_no AS VersionNo,
           s.status_code AS StatusCode, s.status_name AS StatusName,
           t.approval_required AS ApprovalRequired,
           t.effective_from AS EffectiveFrom, t.effective_to AS EffectiveTo,
           t.template_owner_employee_id AS TemplateOwnerEmployeeId, o.employee_name AS TemplateOwnerName,
           (SELECT COUNT(*) FROM grac_practice.asset_form_template_field f WHERE f.template_id = t.template_id) AS FieldCount,
           COALESCE(t.updated_dt, t.entered_dt) AS LastChangedDt,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_form_template t
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
      JOIN grac_practice.dependency_asset_type_master at ON at.asset_type_id = t.asset_type_id
      JOIN grac_practice.dependency_asset_subcategory_master sc ON sc.subcategory_id = at.subcategory_id
      JOIN grac_practice.dependency_asset_category_master ac ON ac.asset_category_id = sc.asset_category_id
      LEFT JOIN grac_practice.organization_employee o ON o.employee_id = t.template_owner_employee_id
     WHERE t.organization_id = @organization_id
       AND (@asset_type_id IS NULL OR t.asset_type_id = @asset_type_id)
       AND (@status_code IS NULL OR s.status_code = @status_code)
       AND (@search IS NULL
            OR t.template_name LIKE N'%' + @search + N'%'
            OR at.asset_type_name LIKE N'%' + @search + N'%'
            OR sc.subcategory_name LIKE N'%' + @search + N'%'
            OR ac.asset_category_name LIKE N'%' + @search + N'%')
     ORDER BY ac.asset_category_name, sc.subcategory_name, at.asset_type_name, t.version_no DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

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
END
GO

-- =====================================================================
-- 7. Publish-readiness (5.2.17). Callers that only need the error count
--    pass @suppress_result = 1 (never INSERT ... EXEC this proc).
-- =====================================================================
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

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'OPTIONS_PENDING', N'WARNING',
           CONCAT(N'Field "', d.display_label, N'" uses a configurable option list; options are configured in a later release.'), d.field_key
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
     WHERE f.template_id = @template_id AND d.lookup_source LIKE N'OPTION:%' AND f.is_visible = 1;

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

-- =====================================================================
-- 8. Template writers
-- =====================================================================
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

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, after_json, status, entered_by)
    VALUES (N'asset-form-template', @out_template_id, N'NEW_VERSION',
            (SELECT @source_template_id AS sourceTemplateId, @next_version AS versionNo, @change_reason AS changeReason
               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);

    COMMIT;

    SELECT @out_template_id AS TemplateId, @next_version AS VersionNo;
END
GO

-- Shared guard: template exists for the org, is a Draft, and (optionally)
-- has not changed since the caller read it.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_assert_editable
    @organization_id         BIGINT,
    @template_id             BIGINT,
    @expected_record_version BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @status NVARCHAR(60), @rv BIGINT;
    SELECT @status = s.status_code, @rv = CONVERT(BIGINT, t.record_version)
      FROM grac_practice.asset_form_template t
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
     WHERE t.template_id = @template_id AND t.organization_id = @organization_id;
    IF @status IS NULL
        THROW 54202, 'Asset form template not found for this organization.', 1;
    IF @status <> N'DRAFT'
        THROW 54210, 'Only a Draft version can be changed. Return it to Draft or create a new version.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54205, 'This template was changed by someone else. Reload it and try again.', 1;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_header_save
    @organization_id            BIGINT,
    @template_id                BIGINT,
    @template_name              NVARCHAR(200),
    @approval_required          BIT            = 1,
    @template_owner_employee_id BIGINT         = NULL,
    @effective_from             DATE           = NULL,
    @effective_to               DATE           = NULL,
    @change_reason              NVARCHAR(1000) = NULL,
    @expected_record_version    BIGINT         = NULL,
    @actor                      NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @template_name = NULLIF(LTRIM(RTRIM(@template_name)), N'');

    EXEC grac_practice.sp_asset_form_template_assert_editable
         @organization_id = @organization_id, @template_id = @template_id,
         @expected_record_version = @expected_record_version;

    IF @template_name IS NULL THROW 54204, 'Template name is required.', 1;
    IF @effective_from IS NOT NULL AND @effective_to IS NOT NULL AND @effective_to < @effective_from
        THROW 54211, 'Effective To cannot be before Effective From.', 1;
    IF @template_owner_employee_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_employee
         WHERE employee_id = @template_owner_employee_id AND organization_id = @organization_id AND status = N'Active')
        THROW 54206, 'Template owner must be an active employee of the organization.', 1;

    DECLARE @before NVARCHAR(MAX) = (
        SELECT template_name AS templateName, approval_required AS approvalRequired,
               template_owner_employee_id AS templateOwnerEmployeeId, effective_from AS effectiveFrom,
               effective_to AS effectiveTo, change_reason AS changeReason
          FROM grac_practice.asset_form_template WHERE template_id = @template_id
           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRAN;
    UPDATE grac_practice.asset_form_template
       SET template_name = @template_name,
           approval_required = ISNULL(@approval_required, 1),
           template_owner_employee_id = @template_owner_employee_id,
           effective_from = @effective_from,
           effective_to = @effective_to,
           change_reason = NULLIF(LTRIM(RTRIM(@change_reason)), N''),
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE template_id = @template_id AND organization_id = @organization_id;

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-form-template', @template_id, N'HEADER_SAVE', @before,
            (SELECT @template_name AS templateName, @approval_required AS approvalRequired,
                    @template_owner_employee_id AS templateOwnerEmployeeId, @effective_from AS effectiveFrom,
                    @effective_to AS effectiveTo, @change_reason AS changeReason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_section_save
    @organization_id BIGINT,
    @template_id     BIGINT,
    @section_id      BIGINT        = NULL,
    @section_label   NVARCHAR(150),
    @tab_label       NVARCHAR(150) = NULL,
    @layout_columns  TINYINT       = 2,
    @display_order   INT           = NULL,
    @is_active       BIT           = 1,
    @actor           NVARCHAR(100) = N'system',
    @out_section_id  BIGINT        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @section_label = NULLIF(LTRIM(RTRIM(@section_label)), N'');
    SET @tab_label = NULLIF(LTRIM(RTRIM(@tab_label)), N'');
    SET @layout_columns = ISNULL(@layout_columns, 2);
    SET @is_active = ISNULL(@is_active, 1);

    EXEC grac_practice.sp_asset_form_template_assert_editable
         @organization_id = @organization_id, @template_id = @template_id;

    IF @section_label IS NULL THROW 54212, 'Section label is required.', 1;
    IF @layout_columns NOT IN (1, 2) THROW 54221, 'Layout must be one or two columns.', 1;

    DECLARE @is_system BIT, @key NVARCHAR(60);
    IF @section_id IS NOT NULL
    BEGIN
        SELECT @is_system = is_system FROM grac_practice.asset_form_template_section
         WHERE section_id = @section_id AND template_id = @template_id;
        IF @is_system IS NULL THROW 54217, 'Section not found on this template.', 1;
        IF @is_system = 1 THROW 54213, 'System sections are fixed and cannot be changed.', 1;
        IF @is_active = 0 AND EXISTS (SELECT 1 FROM grac_practice.asset_form_template_field WHERE section_id = @section_id)
            THROW 54215, 'Move or remove the fields in this section before deactivating it.', 1;
    END
    ELSE
    BEGIN
        -- Stable key from the label: upper-case letters/digits, others -> '_'.
        DECLARE @i INT = 1, @c NCHAR(1), @raw NVARCHAR(150) = UPPER(@section_label);
        SET @key = N'';
        WHILE @i <= LEN(@raw)
        BEGIN
            SET @c = SUBSTRING(@raw, @i, 1);
            SET @key = @key + CASE WHEN @c LIKE N'[A-Z0-9]' THEN @c
                                   WHEN RIGHT(@key, 1) = N'_' OR @key = N'' THEN N'' ELSE N'_' END;
            SET @i = @i + 1;
        END
        SET @key = LEFT(NULLIF(@key, N''), 60);
        IF @key IS NULL SET @key = CONCAT(N'SECTION_', ABS(CHECKSUM(NEWID())) % 100000);
        IF RIGHT(@key, 1) = N'_' SET @key = LEFT(@key, LEN(@key) - 1);
        IF EXISTS (SELECT 1 FROM grac_practice.asset_form_template_section WHERE template_id = @template_id AND section_key = @key)
            THROW 54214, 'A section with this name already exists on the template.', 1;
    END

    IF @display_order IS NULL
        SELECT @display_order = ISNULL(MAX(display_order), 0) + 10
          FROM grac_practice.asset_form_template_section
         WHERE template_id = @template_id AND is_system = 0;

    BEGIN TRAN;
    IF @section_id IS NULL
    BEGIN
        INSERT grac_practice.asset_form_template_section
            (template_id, section_key, section_label, tab_label, layout_columns, display_order, is_system, is_active, entered_by)
        VALUES (@template_id, @key, @section_label, @tab_label, @layout_columns, @display_order, 0, @is_active, @actor);
        SET @out_section_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_form_template_section
           SET section_label = @section_label, tab_label = @tab_label, layout_columns = @layout_columns,
               display_order = @display_order, is_active = @is_active,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE section_id = @section_id;
        SET @out_section_id = @section_id;
    END

    UPDATE grac_practice.asset_form_template SET updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE template_id = @template_id;

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, after_json, status, entered_by)
    VALUES (N'asset-form-template', @template_id, N'SECTION_SAVE',
            (SELECT @out_section_id AS sectionId, @section_label AS sectionLabel, @tab_label AS tabLabel,
                    @layout_columns AS layoutColumns, @display_order AS displayOrder, @is_active AS isActive
               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @out_section_id AS SectionId;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_field_save
    @organization_id          BIGINT,
    @template_id              BIGINT,
    @field_definition_id      INT,
    @section_id               BIGINT,
    @display_order            INT           = NULL,
    @is_visible               BIT           = 1,
    @is_mandatory             BIT           = 0,
    @is_read_only             BIT           = 0,
    @default_value            NVARCHAR(400) = NULL,
    @help_text                NVARCHAR(500) = NULL,
    @placeholder_text         NVARCHAR(200) = NULL,
    @hidden_value_behavior    NVARCHAR(10)  = N'RETAIN',
    @sensitivity_override     NVARCHAR(20)  = NULL,
    @include_in_import_export BIT           = 1,
    @is_searchable            BIT           = 0,
    @evidence_required        BIT           = 0,
    @actor                    NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @hidden_value_behavior = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@hidden_value_behavior)), N''), N'RETAIN'));
    SET @sensitivity_override = UPPER(NULLIF(LTRIM(RTRIM(@sensitivity_override)), N''));
    SET @default_value = NULLIF(LTRIM(RTRIM(@default_value)), N'');
    SET @help_text = NULLIF(LTRIM(RTRIM(@help_text)), N'');
    SET @placeholder_text = NULLIF(LTRIM(RTRIM(@placeholder_text)), N'');

    EXEC grac_practice.sp_asset_form_template_assert_editable
         @organization_id = @organization_id, @template_id = @template_id;

    DECLARE @sys_mandatory BIT, @sys_field BIT, @def_status NVARCHAR(20), @baseline NVARCHAR(20), @user_entered BIT;
    SELECT @sys_mandatory = d.is_system_mandatory, @sys_field = d.is_system_field, @def_status = d.status_code,
           @baseline = d.sensitivity_code, @user_entered = dt.is_user_entered
      FROM grac_practice.asset_field_definition d
      JOIN grac_practice.asset_field_data_type_master dt ON dt.data_type_code = d.data_type_code
     WHERE d.field_definition_id = @field_definition_id;
    IF @def_status IS NULL OR @def_status <> N'ACTIVE' OR @sys_field = 1
        THROW 54216, 'This dictionary field cannot be placed on a form (unknown, retired or system-maintained).', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template_section
                    WHERE section_id = @section_id AND template_id = @template_id AND is_active = 1 AND is_system = 0)
        THROW 54217, 'Choose an active, non-system section of this template.', 1;

    IF @sys_mandatory = 1 AND (ISNULL(@is_visible, 1) = 0 OR ISNULL(@is_mandatory, 0) = 0)
        THROW 54218, 'A system-mandatory field must stay visible and mandatory.', 1;

    IF @hidden_value_behavior NOT IN (N'RETAIN', N'CLEAR', N'MIGRATE')
        THROW 54221, 'Hidden-value behaviour must be RETAIN, CLEAR or MIGRATE.', 1;

    IF @sensitivity_override IS NOT NULL
    BEGIN
        IF @sensitivity_override NOT IN (N'PUBLIC', N'INTERNAL', N'CONFIDENTIAL', N'RESTRICTED')
            THROW 54221, 'Unknown sensitivity classification.', 1;
        DECLARE @rank_new INT = CASE @sensitivity_override WHEN N'PUBLIC' THEN 1 WHEN N'INTERNAL' THEN 2 WHEN N'CONFIDENTIAL' THEN 3 ELSE 4 END;
        DECLARE @rank_base INT = CASE @baseline WHEN N'PUBLIC' THEN 1 WHEN N'INTERNAL' THEN 2 WHEN N'CONFIDENTIAL' THEN 3 ELSE 4 END;
        IF @rank_new < @rank_base
            THROW 54219, 'A template can raise a field''s sensitivity but cannot lower it below the dictionary baseline.', 1;
        IF @rank_new = @rank_base SET @sensitivity_override = NULL;
    END

    -- Auto / calculated / system values are never typed in.
    IF @user_entered = 0 SET @is_read_only = 1;

    IF @display_order IS NULL
        SELECT @display_order = COALESCE(
                 (SELECT display_order FROM grac_practice.asset_form_template_field
                   WHERE template_id = @template_id AND field_definition_id = @field_definition_id AND section_id = @section_id),
                 (SELECT ISNULL(MAX(display_order), 0) + 10 FROM grac_practice.asset_form_template_field WHERE section_id = @section_id));

    DECLARE @before NVARCHAR(MAX) = (
        SELECT section_id AS sectionId, display_order AS displayOrder, is_visible AS isVisible, is_mandatory AS isMandatory,
               is_read_only AS isReadOnly, default_value AS defaultValue, hidden_value_behavior AS hiddenValueBehavior,
               sensitivity_override AS sensitivityOverride
          FROM grac_practice.asset_form_template_field
         WHERE template_id = @template_id AND field_definition_id = @field_definition_id
           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRAN;

    UPDATE grac_practice.asset_form_template_field
       SET section_id = @section_id, display_order = @display_order,
           is_visible = ISNULL(@is_visible, 1), is_mandatory = ISNULL(@is_mandatory, 0), is_read_only = ISNULL(@is_read_only, 0),
           default_value = @default_value, help_text = @help_text, placeholder_text = @placeholder_text,
           hidden_value_behavior = @hidden_value_behavior, sensitivity_override = @sensitivity_override,
           include_in_import_export = ISNULL(@include_in_import_export, 1), is_searchable = ISNULL(@is_searchable, 0),
           evidence_required = ISNULL(@evidence_required, 0),
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE template_id = @template_id AND field_definition_id = @field_definition_id;

    IF @@ROWCOUNT = 0
        INSERT grac_practice.asset_form_template_field
            (template_id, field_definition_id, section_id, display_order, is_visible, is_mandatory, is_read_only,
             default_value, help_text, placeholder_text, hidden_value_behavior, sensitivity_override,
             include_in_import_export, is_searchable, evidence_required, entered_by)
        VALUES
            (@template_id, @field_definition_id, @section_id, @display_order, ISNULL(@is_visible, 1), ISNULL(@is_mandatory, 0), ISNULL(@is_read_only, 0),
             @default_value, @help_text, @placeholder_text, @hidden_value_behavior, @sensitivity_override,
             ISNULL(@include_in_import_export, 1), ISNULL(@is_searchable, 0), ISNULL(@evidence_required, 0), @actor);

    UPDATE grac_practice.asset_form_template SET updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE template_id = @template_id;

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-form-template', @template_id, CASE WHEN @before IS NULL THEN N'FIELD_ADD' ELSE N'FIELD_SAVE' END, @before,
            (SELECT @field_definition_id AS fieldDefinitionId, @section_id AS sectionId, @display_order AS displayOrder,
                    @is_visible AS isVisible, @is_mandatory AS isMandatory, @is_read_only AS isReadOnly,
                    @default_value AS defaultValue, @hidden_value_behavior AS hiddenValueBehavior,
                    @sensitivity_override AS sensitivityOverride FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

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
-- 9. Lifecycle transition (5.2.18)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_transition
    @organization_id         BIGINT,
    @template_id             BIGINT,
    @to_status_code          NVARCHAR(60),
    @reason_text             NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @to_status_code = UPPER(LTRIM(RTRIM(ISNULL(@to_status_code, N''))));
    SET @reason_text = NULLIF(LTRIM(RTRIM(@reason_text)), N'');

    DECLARE @from NVARCHAR(60), @rv BIGINT, @asset_type_id INT, @approval_required BIT,
            @submitted_by NVARCHAR(100), @effective_from DATE, @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    SELECT @from = s.status_code, @rv = CONVERT(BIGINT, t.record_version), @asset_type_id = t.asset_type_id,
           @approval_required = t.approval_required, @submitted_by = t.submitted_by, @effective_from = t.effective_from
      FROM grac_practice.asset_form_template t
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
     WHERE t.template_id = @template_id AND t.organization_id = @organization_id;

    IF @from IS NULL THROW 54202, 'Asset form template not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54205, 'This template was changed by someone else. Reload it and try again.', 1;

    DECLARE @reason_code NVARCHAR(60) = CASE
        WHEN @to_status_code = N'DRAFT'            THEN N'RETURNED'
        WHEN @to_status_code = N'RETIRED'          THEN N'RETIRED'
        WHEN @to_status_code = N'TESTING'          THEN N'SUBMITTED_FOR_TEST'
        WHEN @to_status_code = N'PENDING_APPROVAL' THEN N'SUBMITTED'
        WHEN @to_status_code = N'APPROVED'         THEN N'APPROVED'
        WHEN @to_status_code = N'ACTIVE'           THEN N'ACTIVATED'
        ELSE NULL END;
    IF @to_status_code IN (N'DRAFT', N'RETIRED') AND @reason_text IS NULL
        THROW 54222, 'A reason is required to return or retire a template version.', 1;

    -- Publication gates: the template must be ready.
    IF @to_status_code IN (N'TESTING', N'PENDING_APPROVAL', N'APPROVED', N'ACTIVE')
    BEGIN
        DECLARE @errors INT = 0, @warnings INT = 0;
        EXEC grac_practice.sp_asset_form_template_readiness
             @organization_id = @organization_id, @template_id = @template_id, @suppress_result = 1,
             @out_error_count = @errors OUTPUT, @out_warning_count = @warnings OUTPUT;
        IF @errors > 0
        BEGIN
            DECLARE @msg_ready NVARCHAR(300) = CONCAT(N'The template is not ready: ', @errors,
                N' blocking issue(s). Open the readiness report and resolve them first.');
            THROW 54223, @msg_ready, 1;
        END
    END

    IF @from = N'TESTING' AND @to_status_code = N'APPROVED' AND @approval_required = 1
        THROW 54224, 'This template requires approval. Submit it for approval instead.', 1;
    IF @from = N'PENDING_APPROVAL' AND @to_status_code = N'APPROVED' AND @submitted_by = @actor
        THROW 54220, 'Segregation of duties: the person who submitted this version cannot approve it.', 1;
    IF @to_status_code = N'ACTIVE' AND @effective_from IS NOT NULL AND @effective_from > @today
        THROW 54225, 'Effective From is in the future. Activation is immediate; clear the date or set it to today or earlier.', 1;

    DECLARE @to_status_id INT, @log_id BIGINT, @prev_active_id BIGINT, @prev_from DATE,
            @retired_status_id INT, @prev_log BIGINT;

    BEGIN TRAN;

    EXEC grac_practice.sp_pm_state_transition
         @entity_type = N'AssetFormTemplate', @entity_id = @template_id,
         @from_status_code = @from, @to_status_code = @to_status_code,
         @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
         @reason_code = @reason_code, @reason_text = @reason_text,
         @to_status_id = @to_status_id OUTPUT, @transition_log_id = @log_id OUTPUT;

    IF @to_status_code = N'ACTIVE'
    BEGIN
        SET @effective_from = ISNULL(@effective_from, @today);

        -- Supersede the current Active version first (one-active index).
        SELECT @prev_active_id = template_id, @prev_from = effective_from
          FROM grac_practice.asset_form_template
         WHERE organization_id = @organization_id AND asset_type_id = @asset_type_id
           AND is_active_version = 1 AND template_id <> @template_id;
        IF @prev_active_id IS NOT NULL
        BEGIN
            DECLARE @supersede_reason NVARCHAR(1000) = CONCAT(N'Superseded by template #', @template_id, N'.');
            EXEC grac_practice.sp_pm_state_transition
                 @entity_type = N'AssetFormTemplate', @entity_id = @prev_active_id,
                 @from_status_code = N'ACTIVE', @to_status_code = N'RETIRED',
                 @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
                 @reason_code = N'SUPERSEDED', @reason_text = @supersede_reason,
                 @to_status_id = @retired_status_id OUTPUT, @transition_log_id = @prev_log OUTPUT;
            UPDATE grac_practice.asset_form_template
               SET current_status_id = @retired_status_id, is_active_version = 0, is_working_version = 0,
                   effective_to = CASE WHEN DATEADD(DAY, -1, @effective_from) < ISNULL(@prev_from, @effective_from)
                                       THEN ISNULL(@prev_from, @effective_from)
                                       ELSE DATEADD(DAY, -1, @effective_from) END,
                   retired_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE template_id = @prev_active_id;
        END

        UPDATE grac_practice.asset_form_template
           SET current_status_id = @to_status_id, is_working_version = 0, is_active_version = 1,
               effective_from = @effective_from, activated_by = @actor, activated_dt = SYSUTCDATETIME(),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE template_id = @template_id;
    END
    ELSE IF @to_status_code = N'RETIRED'
        UPDATE grac_practice.asset_form_template
           SET current_status_id = @to_status_id, is_working_version = 0, is_active_version = 0,
               effective_to = CASE WHEN @from = N'ACTIVE' THEN ISNULL(effective_to, @today) ELSE effective_to END,
               retired_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE template_id = @template_id;
    ELSE
        UPDATE grac_practice.asset_form_template
           SET current_status_id = @to_status_id, is_working_version = 1, is_active_version = 0,
               submitted_by = CASE WHEN @to_status_code = N'PENDING_APPROVAL' THEN @actor
                                   WHEN @to_status_code = N'DRAFT' THEN NULL ELSE submitted_by END,
               submitted_dt = CASE WHEN @to_status_code = N'PENDING_APPROVAL' THEN SYSUTCDATETIME()
                                   WHEN @to_status_code = N'DRAFT' THEN NULL ELSE submitted_dt END,
               approved_by  = CASE WHEN @to_status_code = N'APPROVED' THEN @actor
                                   WHEN @to_status_code = N'DRAFT' THEN NULL ELSE approved_by END,
               approved_dt  = CASE WHEN @to_status_code = N'APPROVED' THEN SYSUTCDATETIME()
                                   WHEN @to_status_code = N'DRAFT' THEN NULL ELSE approved_dt END,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE template_id = @template_id;

    COMMIT;

    SELECT @template_id AS TemplateId, @to_status_code AS StatusCode, @prev_active_id AS SupersededTemplateId;
END
GO
PRINT '420: procedures created.';
GO

-- =====================================================================
-- 10. Menu: Asset & Contract root + two configuration screens.
--     (Also carried in 274_menu_master_seed.sql -- the snapshot is
--     authoritative and applied with UPDATE.)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'nav-asset-contract',     N'Asset & Contract',     CAST(NULL AS NVARCHAR(400)),          350, N'boxes-stacked', N'Asset & Contract'),
    (N'asset-field-dictionary', N'Field Dictionary',     N'Practice/Index/asset-field-dictionary', 351, N'book',          N'Asset & Contract'),
    (N'asset-form-templates',   N'Asset Form Templates', N'Practice/Index/asset-form-templates',   352, N'table-list',    N'Asset & Contract')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name
               OR ISNULL(t.menu_url, N'') <> ISNULL(s.menu_url, N'')
               OR t.display_order <> s.display_order
               OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type
               OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order,
    icon_class = s.icon_class, module_type = s.module_type, status = N'Active',
    updated_by = N'seed-420', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-420');
PRINT CONCAT('420: menu rows upserted: ', @@ROWCOUNT);
GO

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-420', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-asset-contract'
 WHERE c.menu_key IN (N'asset-field-dictionary', N'asset-form-templates')
   AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
UPDATE grac_practice.menu_master
   SET parent_menu_id = NULL, updated_by = N'seed-420', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'nav-asset-contract' AND parent_menu_id IS NOT NULL;
PRINT '420: menu parents wired.';
GO

-- Grants: every Active 'Admin' role -- VIEW / ADD / EDIT / APPROVE, no
-- DELETE (nothing on these screens deletes). Missing rows only, so a
-- re-run never re-grants a right someone removed in Role Master.
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1,
       CASE WHEN m.menu_key = N'nav-asset-contract' THEN 0 ELSE 1 END,
       CASE WHEN m.menu_key = N'nav-asset-contract' THEN 0 ELSE 1 END,
       0,
       CASE WHEN m.menu_key = N'asset-form-templates' THEN 1 ELSE 0 END,
       N'Active', @active_rs, N'seed-420', SYSUTCDATETIME()
  FROM grac_practice.organization_role r
  JOIN grac_practice.menu_master m
       ON m.menu_key IN (N'nav-asset-contract', N'asset-field-dictionary', N'asset-form-templates')
 WHERE r.role_name = N'Admin' AND r.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('420: Admin grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '420-a dictionary seeded (>= 270 fields, 14 groups)' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.asset_field_definition) >= 270
             AND (SELECT COUNT(*) FROM grac_practice.asset_field_group_master) >= 14
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '420-b baseline = 10 system-mandatory fields',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.asset_field_definition
                   WHERE is_system_mandatory = 1 AND status_code = N'ACTIVE') = 10 THEN 'PASS' ELSE 'CHECK' END
UNION ALL
SELECT '420-c every COLUMN field maps to a real organization_dependency_asset column',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_definition d
                              WHERE d.storage_kind = N'COLUMN'
                                AND COL_LENGTH('grac_practice.organization_dependency_asset', d.column_name) IS NULL)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '420-d AssetFormTemplate: 6 statuses, 11 transitions',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.entity_status_master WHERE entity_type = N'AssetFormTemplate') = 6
             AND (SELECT COUNT(*) FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'AssetFormTemplate' AND is_active = 1) = 11
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '420-e menu root + two children Active and wired',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.menu_master c
                    JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-asset-contract'
                   WHERE c.menu_key IN (N'asset-field-dictionary', N'asset-form-templates') AND c.status = N'Active') = 2
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '420-f thirteen procedures present',
       CASE WHEN (SELECT COUNT(*) FROM sys.procedures
                   WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                     AND name IN ('sp_asset_field_group_list', 'sp_asset_field_definition_list',
                                  'sp_asset_form_template_list', 'sp_asset_form_template_get',
                                  'sp_asset_form_template_create', 'sp_asset_form_template_new_version',
                                  'sp_asset_form_template_assert_editable', 'sp_asset_form_template_header_save',
                                  'sp_asset_form_template_section_save', 'sp_asset_form_template_field_save',
                                  'sp_asset_form_template_field_remove', 'sp_asset_form_template_readiness',
                                  'sp_asset_form_template_transition')) = 13
            THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build; users re-login for the new
-- menu grants)
--   1. Asset & Contract -> Field Dictionary: 14 groups, 270+ fields;
--      filter by group / data type / sensitivity; search "calibration".
--   2. Asset Form Templates -> New template for "Laptop": Draft v1 with
--      the 10 baseline fields in "General".
--   3. Remove "Asset name" -> refused (54218). Untick its Mandatory ->
--      refused (54218).
--   4. Add section "Technical"; add Hostname, Operating system, Encryption
--      status into it; add Hostname again -> updates the same row (no
--      duplicate).
--   5. Clear the template owner -> readiness shows OWNER_MISSING; Submit
--      for testing -> refused (54223). Set owner -> Testing.
--   6. Submit for approval as user A; approve as user A -> refused (54220);
--      approve as user B -> Approved; Activate -> Active, effective today.
--   7. New version (reason required) -> Draft v2; a second New version ->
--      refused (54207). Take v2 to Active -> v1 becomes Retired with
--      effective-to set; History tab lists every move with actor/reason.
--   8. Edit a Testing/Active version via the API -> refused (54210).
-- =====================================================================
SET NOEXEC OFF;
GO
