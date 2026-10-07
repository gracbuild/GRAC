-- =====================================================================
-- 423  Asset field option lists per organization
--      (Asset & Contract Management, Phase 2 increment 4)
--
-- REQUEST
-- -------
--   BRD v1.7 5.1.2 / 5.1.6 / 5.1.10: building, floor, room, zone, cost
--   centre, production line, clinical area, network zone, domain, ... are
--   "active values" of the organization, not platform constants; 5.2.5
--   "Lookup Source: approved master, filtered lookup ... or controlled
--   list". 421 seeded the BRD-enumerated lists globally; this increment
--   lets each organization maintain its own values. Plan in
--   docs/asset-contract-management.md.
--
-- WHAT THIS DOES
-- --------------
--   1. asset_option_list_master -- one row per OPTION: list in the field
--      dictionary: name, scope (GLOBAL_ONLY | ORG_EXTENSIBLE | ORG_ONLY)
--      and, for dependent lists, the parent dictionary field:
--        building -> site (organization_location), floor -> building,
--        room -> floor, zone -> site (BRD: "must belong to selected ...").
--      Scopes: lists the BRD enumerates are ORG_EXTENSIBLE (global
--      defaults from 421; an organization may add values, relabel or hide
--      a default for itself); lists the BRD leaves to the organization are
--      ORG_ONLY; yes/no style lists are GLOBAL_ONLY.
--   2. asset_field_option_org -- the organization's values. A row whose
--      value matches a global value overrides its label / order, or hides
--      it when Inactive. Values are never deleted (assets will store
--      them); retiring a value sets it Inactive, and a parent value with
--      active children cannot be retired.
--   3. fn_asset_field_options(@organization_id) -- the effective list
--      (global values not hidden + organization values, organization wins)
--      with each value's parent. Re-issued sp_asset_form_template_get and
--      sp_asset_form_template_readiness use it, so templates, preview and
--      (later) the Asset Register all see the same list.
--   4. Procedures: sp_asset_option_list_catalog, sp_asset_option_list_get,
--      sp_asset_option_org_save, sp_asset_option_org_override (relabel / reorder /
--      hide / reset a global default for one organization).
--   5. Menu "Option Lists" (asset-option-lists) under Asset & Contract;
--      Admin grant VIEW / ADD / EDIT (missing rows only).
--
-- NOT CHANGED: reference_option (global values stay exactly as 421 left
--   them), the dictionary, rules, valuation.
--
-- ERROR NUMBERS: 54270-54289
--   54270 list not found                 54271 list is not organization-maintained
--   54272 label required                 54273 value already exists in the list
--   54274 parent value required          54275 parent value not valid
--   54276 value not found                54277 value still has active child values
--   54278 not a global value of the list 54279 organization not found
--
-- ALSO EDITED: 274_menu_master_seed.sql, API (AssetConfig service /
--   controller / models), Web proxy, PracticeScreen.cs, Manage.cshtml,
--   new partial + script asset-option-lists, both appsettings.json.
-- DEPENDS ON: 420, 421, 422.
-- Rollback: 423_asset_option_lists_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.asset_field_definition','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_form_template_rule','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_valuation_config','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_cia_scale_level','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_location','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_location','location_name') IS NULL
BEGIN
    RAISERROR('ABORT (423): run 420, 421 and 422 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Tables
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_option_list_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_option_list_master (
        option_group     NVARCHAR(120) NOT NULL CONSTRAINT pk_pm_asset_option_list PRIMARY KEY,
        list_name        NVARCHAR(200) NOT NULL,
        scope_code       NVARCHAR(20)  NOT NULL
            CONSTRAINT ck_pm_asset_option_list_scope CHECK (scope_code IN (N'GLOBAL_ONLY', N'ORG_EXTENSIBLE', N'ORG_ONLY')),
        parent_field_key NVARCHAR(100) NULL,
        description      NVARCHAR(500) NULL,
        is_active        BIT           NOT NULL CONSTRAINT df_pm_asset_option_list_active DEFAULT 1,
        entered_by       NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_option_list_eby DEFAULT N'system',
        entered_dt       DATETIME2     NOT NULL CONSTRAINT df_pm_asset_option_list_edt DEFAULT SYSUTCDATETIME(),
        updated_by       NVARCHAR(100) NULL,
        updated_dt       DATETIME2     NULL
    );
    PRINT '423: asset_option_list_master created.';
END
GO

IF OBJECT_ID('grac_practice.asset_field_option_org','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_field_option_org (
        org_option_id   BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_option_org PRIMARY KEY,
        organization_id BIGINT        NOT NULL
            CONSTRAINT fk_pm_asset_option_org_org REFERENCES grac_practice.organization(organization_id),
        option_group    NVARCHAR(120) NOT NULL
            CONSTRAINT fk_pm_asset_option_org_list REFERENCES grac_practice.asset_option_list_master(option_group),
        option_value    NVARCHAR(160) NOT NULL,
        option_label    NVARCHAR(200) NOT NULL,
        parent_value    NVARCHAR(160) NULL,
        display_order   INT           NOT NULL CONSTRAINT df_pm_asset_option_org_order DEFAULT 0,
        status          NVARCHAR(30)  NOT NULL CONSTRAINT df_pm_asset_option_org_status DEFAULT N'Active'
            CONSTRAINT ck_pm_asset_option_org_status CHECK (status IN (N'Active', N'Inactive')),
        entered_by      NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_option_org_eby DEFAULT N'system',
        entered_dt      DATETIME2     NOT NULL CONSTRAINT df_pm_asset_option_org_edt DEFAULT SYSUTCDATETIME(),
        updated_by      NVARCHAR(100) NULL,
        updated_dt      DATETIME2     NULL,
        CONSTRAINT uq_pm_asset_option_org UNIQUE (organization_id, option_group, option_value)
    );
    CREATE INDEX ix_pm_asset_option_org_parent
        ON grac_practice.asset_field_option_org(organization_id, option_group, parent_value);
    PRINT '423: asset_field_option_org created.';
END
GO

-- =====================================================================
-- 2. List catalogue -- one row per OPTION: source in the dictionary.
--    Name = the first field's label using it; shared yes/no lists get
--    their own names. Insert-only.
-- =====================================================================
;WITH src AS (
    SELECT N'asset_field.' + SUBSTRING(d.lookup_source, 8, 100) AS option_group,
           SUBSTRING(d.lookup_source, 8, 100) AS list_key,
           MIN(d.display_label) AS first_label
      FROM grac_practice.asset_field_definition d
     WHERE d.lookup_source LIKE N'OPTION:%'
     GROUP BY d.lookup_source
)
MERGE grac_practice.asset_option_list_master AS t
USING (
    SELECT s.option_group,
           CASE s.list_key WHEN N'yes_no_unknown'    THEN N'Yes / No / Unknown'
                           WHEN N'yes_no_assessment' THEN N'Yes / No / Under Assessment'
                           WHEN N'yes_no_partial'    THEN N'Yes / No / Partially'
                           ELSE s.first_label END AS list_name,
           CASE WHEN s.list_key IN (N'yes_no_unknown', N'yes_no_assessment', N'yes_no_partial') THEN N'GLOBAL_ONLY'
                WHEN EXISTS (SELECT 1 FROM grac_practice.reference_option o WHERE o.option_group = s.option_group) THEN N'ORG_EXTENSIBLE'
                ELSE N'ORG_ONLY' END AS scope_code,
           CASE s.list_key WHEN N'building' THEN N'site'
                           WHEN N'floor'    THEN N'building'
                           WHEN N'room'     THEN N'floor'
                           WHEN N'zone'     THEN N'site' END AS parent_field_key
      FROM src s
) AS s
ON t.option_group = s.option_group
WHEN NOT MATCHED BY TARGET THEN
    INSERT (option_group, list_name, scope_code, parent_field_key, entered_by)
    VALUES (s.option_group, s.list_name, s.scope_code, s.parent_field_key, N'seed-423');
PRINT CONCAT('423: option lists catalogued: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 3. Effective options for an organization
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_asset_field_options (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    -- Global values the organization has not hidden or overridden.
    SELECT o.option_group AS OptionGroup, o.option_value AS OptionValue, o.option_label AS OptionLabel,
           o.display_order AS DisplayOrder, CAST(NULL AS NVARCHAR(160)) AS ParentValue, N'GLOBAL' AS Source
      FROM grac_practice.reference_option o
      JOIN grac_practice.asset_option_list_master m ON m.option_group = o.option_group AND m.is_active = 1
     WHERE o.status = N'Active'
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_option_org x
                        WHERE x.organization_id = @organization_id AND x.option_group = o.option_group
                          AND x.option_value = o.option_value)
    UNION ALL
    -- The organization's own values and overrides (not for GLOBAL_ONLY lists).
    SELECT x.option_group, x.option_value, x.option_label, x.display_order, x.parent_value,
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.reference_option g
                              WHERE g.option_group = x.option_group AND g.option_value = x.option_value)
                THEN N'OVERRIDE' ELSE N'ORG' END
      FROM grac_practice.asset_field_option_org x
      JOIN grac_practice.asset_option_list_master m ON m.option_group = x.option_group AND m.is_active = 1
     WHERE x.organization_id = @organization_id AND x.status = N'Active' AND m.scope_code <> N'GLOBAL_ONLY';
GO

-- =====================================================================
-- 4. Readers
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_option_list_catalog
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SELECT m.option_group AS OptionGroup, m.list_name AS ListName, m.scope_code AS ScopeCode,
           m.parent_field_key AS ParentFieldKey, pd.display_label AS ParentFieldLabel,
           (SELECT COUNT(*) FROM grac_practice.reference_option o
             WHERE o.option_group = m.option_group AND o.status = N'Active') AS GlobalCount,
           (SELECT COUNT(*) FROM grac_practice.asset_field_option_org x
             WHERE x.organization_id = @organization_id AND x.option_group = m.option_group AND x.status = N'Active') AS OrgCount,
           (SELECT COUNT(*) FROM grac_practice.fn_asset_field_options(@organization_id) e
             WHERE e.OptionGroup = m.option_group) AS EffectiveCount,
           (SELECT STRING_AGG(d.display_label, N', ') FROM grac_practice.asset_field_definition d
             WHERE d.lookup_source = N'OPTION:' + SUBSTRING(m.option_group, 13, 100)) AS UsedBy
      FROM grac_practice.asset_option_list_master m
      LEFT JOIN grac_practice.asset_field_definition pd ON pd.field_key = m.parent_field_key
     WHERE m.is_active = 1
       AND (@search IS NULL OR m.list_name LIKE N'%' + @search + N'%' OR m.option_group LIKE N'%' + @search + N'%')
     ORDER BY CASE m.scope_code WHEN N'ORG_ONLY' THEN 0 WHEN N'ORG_EXTENSIBLE' THEN 1 ELSE 2 END, m.list_name;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_option_list_get
    @organization_id BIGINT,
    @option_group    NVARCHAR(120)
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_option_list_master WHERE option_group = @option_group AND is_active = 1)
        THROW 54270, 'Option list not found.', 1;

    -- 1. The list
    SELECT m.option_group AS OptionGroup, m.list_name AS ListName, m.scope_code AS ScopeCode,
           m.parent_field_key AS ParentFieldKey, pd.display_label AS ParentFieldLabel
      FROM grac_practice.asset_option_list_master m
      LEFT JOIN grac_practice.asset_field_definition pd ON pd.field_key = m.parent_field_key
     WHERE m.option_group = @option_group;

    -- 2. Values: every global value (with this organization's override or
    --    hide state) plus the organization's own values, active or not.
    SELECT g.option_value AS OptionValue,
           COALESCE(x.option_label, g.option_label) AS OptionLabel,
           g.option_label AS GlobalLabel,
           COALESCE(x.display_order, g.display_order) AS DisplayOrder,
           x.parent_value AS ParentValue,
           CASE WHEN x.org_option_id IS NULL THEN N'GLOBAL'
                WHEN x.status = N'Inactive' THEN N'HIDDEN' ELSE N'OVERRIDE' END AS Source,
           x.org_option_id AS OrgOptionId,
           CASE WHEN x.status = N'Inactive' THEN N'Inactive' ELSE N'Active' END AS Status
      FROM grac_practice.reference_option g
      LEFT JOIN grac_practice.asset_field_option_org x
             ON x.organization_id = @organization_id AND x.option_group = g.option_group AND x.option_value = g.option_value
     WHERE g.option_group = @option_group AND g.status = N'Active'
    UNION ALL
    SELECT x.option_value, x.option_label, NULL, x.display_order, x.parent_value, N'ORG', x.org_option_id, x.status
      FROM grac_practice.asset_field_option_org x
     WHERE x.organization_id = @organization_id AND x.option_group = @option_group
       AND NOT EXISTS (SELECT 1 FROM grac_practice.reference_option g
                        WHERE g.option_group = x.option_group AND g.option_value = x.option_value AND g.status = N'Active')
     ORDER BY 4, 2;

    -- 3. Parent candidates for a dependent list.
    DECLARE @parent NVARCHAR(100) = (SELECT parent_field_key FROM grac_practice.asset_option_list_master WHERE option_group = @option_group);
    IF @parent = N'site'
        SELECT CAST(l.location_id AS NVARCHAR(160)) AS ParentValue, l.location_name AS ParentLabel
          FROM grac_practice.organization_location l
         WHERE l.organization_id = @organization_id AND l.status = N'Active'
         ORDER BY l.location_name;
    ELSE IF @parent IS NOT NULL
        SELECT e.OptionValue AS ParentValue, e.OptionLabel AS ParentLabel
          FROM grac_practice.fn_asset_field_options(@organization_id) e
         WHERE e.OptionGroup = N'asset_field.' + @parent
         ORDER BY e.DisplayOrder, e.OptionLabel;
    ELSE
        SELECT CAST(NULL AS NVARCHAR(160)) AS ParentValue, CAST(NULL AS NVARCHAR(200)) AS ParentLabel WHERE 1 = 0;
END
GO

-- =====================================================================
-- 5. Writers
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_option_org_save
    @organization_id BIGINT,
    @option_group    NVARCHAR(120),
    @org_option_id   BIGINT        = NULL,
    @option_value    NVARCHAR(160) = NULL,
    @option_label    NVARCHAR(200),
    @parent_value    NVARCHAR(160) = NULL,
    @display_order   INT           = NULL,
    @status          NVARCHAR(30)  = N'Active',
    @actor           NVARCHAR(100) = N'system',
    @out_org_option_id BIGINT      = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @option_label = NULLIF(LTRIM(RTRIM(@option_label)), N'');
    SET @option_value = NULLIF(LTRIM(RTRIM(@option_value)), N'');
    SET @parent_value = NULLIF(LTRIM(RTRIM(@parent_value)), N'');
    SET @status = CASE WHEN @status = N'Inactive' THEN N'Inactive' ELSE N'Active' END;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54279, 'Organization not found.', 1;
    DECLARE @scope NVARCHAR(20), @parent NVARCHAR(100);
    SELECT @scope = scope_code, @parent = parent_field_key
      FROM grac_practice.asset_option_list_master WHERE option_group = @option_group AND is_active = 1;
    IF @scope IS NULL THROW 54270, 'Option list not found.', 1;
    IF @scope = N'GLOBAL_ONLY' THROW 54271, 'This list is fixed for every organization and cannot be changed here.', 1;
    IF @option_label IS NULL THROW 54272, 'A label is required.', 1;

    IF @org_option_id IS NOT NULL
    BEGIN
        SELECT @option_value = option_value FROM grac_practice.asset_field_option_org
         WHERE org_option_id = @org_option_id AND organization_id = @organization_id AND option_group = @option_group;
        IF @@ROWCOUNT = 0 THROW 54276, 'Value not found in this list.', 1;
    END
    ELSE
    BEGIN
        -- A new value's code is derived from its label unless one is given.
        IF @option_value IS NULL
        BEGIN
            DECLARE @i INT = 1, @c NCHAR(1), @raw NVARCHAR(200) = UPPER(@option_label), @code NVARCHAR(160) = N'';
            WHILE @i <= LEN(@raw)
            BEGIN
                SET @c = SUBSTRING(@raw, @i, 1);
                SET @code = @code + CASE WHEN @c LIKE N'[A-Z0-9]' THEN @c
                                         WHEN RIGHT(@code, 1) = N'_' OR @code = N'' THEN N'' ELSE N'_' END;
                SET @i = @i + 1;
            END
            IF RIGHT(@code, 1) = N'_' SET @code = LEFT(@code, LEN(@code) - 1);
            SET @option_value = LEFT(NULLIF(@code, N''), 160);
            IF @option_value IS NULL THROW 54272, 'The label must contain letters or digits.', 1;
        END
        IF EXISTS (SELECT 1 FROM grac_practice.asset_field_option_org
                    WHERE organization_id = @organization_id AND option_group = @option_group AND option_value = @option_value)
            THROW 54273, 'That value already exists in this list for the organization.', 1;
        IF @scope = N'ORG_EXTENSIBLE' AND EXISTS (SELECT 1 FROM grac_practice.reference_option
                    WHERE option_group = @option_group AND option_value = @option_value AND status = N'Active')
            THROW 54273, 'That value is already a default of this list. Edit the default (relabel or hide) instead.', 1;
    END

    -- Dependent lists need a valid parent.
    IF @parent IS NOT NULL AND @status = N'Active'
    BEGIN
        IF @parent_value IS NULL THROW 54274, 'Choose the parent value this entry belongs to.', 1;
        IF @parent = N'site' AND NOT EXISTS (
            SELECT 1 FROM grac_practice.organization_location
             WHERE organization_id = @organization_id AND status = N'Active' AND CAST(location_id AS NVARCHAR(160)) = @parent_value)
            THROW 54275, 'The parent must be an active location of the organization.', 1;
        IF @parent <> N'site' AND NOT EXISTS (
            SELECT 1 FROM grac_practice.fn_asset_field_options(@organization_id) e
             WHERE e.OptionGroup = N'asset_field.' + @parent AND e.OptionValue = @parent_value)
            THROW 54275, 'The parent must be an active value of the parent list.', 1;
    END
    IF @parent IS NULL SET @parent_value = NULL;

    -- Retiring a value that others depend on would orphan them.
    IF @status = N'Inactive' AND EXISTS (
        SELECT 1 FROM grac_practice.asset_option_list_master child
          JOIN grac_practice.asset_field_option_org x
            ON x.option_group = child.option_group AND x.organization_id = @organization_id AND x.status = N'Active'
         WHERE child.parent_field_key = SUBSTRING(@option_group, 13, 100) AND x.parent_value = @option_value)
        THROW 54277, 'Other values still belong to this one. Retire or move them first.', 1;

    IF @display_order IS NULL
        SELECT @display_order = ISNULL(MAX(display_order), 0) + 10
          FROM grac_practice.asset_field_option_org WHERE organization_id = @organization_id AND option_group = @option_group;

    DECLARE @before NVARCHAR(MAX) = (
        SELECT option_label AS optionLabel, parent_value AS parentValue, display_order AS displayOrder, status
          FROM grac_practice.asset_field_option_org WHERE org_option_id = @org_option_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRAN;
    IF @org_option_id IS NULL
    BEGIN
        INSERT grac_practice.asset_field_option_org
            (organization_id, option_group, option_value, option_label, parent_value, display_order, status, entered_by)
        VALUES (@organization_id, @option_group, @option_value, @option_label, @parent_value, @display_order, @status, @actor);
        SET @out_org_option_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_field_option_org
           SET option_label = @option_label, parent_value = @parent_value, display_order = @display_order,
               status = @status, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE org_option_id = @org_option_id;
        SET @out_org_option_id = @org_option_id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-option-org', @out_org_option_id, CASE WHEN @org_option_id IS NULL THEN N'ADD' ELSE N'SAVE' END, @before,
            (SELECT @organization_id AS organizationId, @option_group AS optionGroup, @option_value AS optionValue,
                    @option_label AS optionLabel, @parent_value AS parentValue, @display_order AS displayOrder, @status AS status
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @out_org_option_id AS OrgOptionId, @option_value AS OptionValue;
END
GO

-- Relabel / reorder / hide a GLOBAL default for one organization, or
-- restore it (@reset = 1 removes the override row -- an override is
-- configuration, not data, so it may be deleted).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_option_org_override
    @organization_id BIGINT,
    @option_group    NVARCHAR(120),
    @option_value    NVARCHAR(160),
    @option_label    NVARCHAR(200) = NULL,
    @display_order   INT           = NULL,
    @hidden          BIT           = 0,
    @reset           BIT           = 0,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @option_label = NULLIF(LTRIM(RTRIM(@option_label)), N'');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54279, 'Organization not found.', 1;
    DECLARE @scope NVARCHAR(20) = (SELECT scope_code FROM grac_practice.asset_option_list_master
                                    WHERE option_group = @option_group AND is_active = 1);
    IF @scope IS NULL THROW 54270, 'Option list not found.', 1;
    IF @scope <> N'ORG_EXTENSIBLE' THROW 54271, 'Only lists with organization-adjustable defaults can be overridden.', 1;
    DECLARE @global_label NVARCHAR(200), @global_order INT;
    SELECT @global_label = option_label, @global_order = display_order FROM grac_practice.reference_option
     WHERE option_group = @option_group AND option_value = @option_value AND status = N'Active';
    IF @global_label IS NULL THROW 54278, 'That is not a default value of this list.', 1;

    DECLARE @existing BIGINT = (SELECT org_option_id FROM grac_practice.asset_field_option_org
                                 WHERE organization_id = @organization_id AND option_group = @option_group AND option_value = @option_value);
    DECLARE @before NVARCHAR(MAX) = (
        SELECT option_label AS optionLabel, display_order AS displayOrder, status
          FROM grac_practice.asset_field_option_org WHERE org_option_id = @existing FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRAN;
    IF ISNULL(@reset, 0) = 1
        DELETE grac_practice.asset_field_option_org WHERE org_option_id = @existing;
    ELSE IF @existing IS NULL
    BEGIN
        INSERT grac_practice.asset_field_option_org
            (organization_id, option_group, option_value, option_label, display_order, status, entered_by)
        VALUES (@organization_id, @option_group, @option_value, ISNULL(@option_label, @global_label),
                ISNULL(@display_order, @global_order), CASE WHEN ISNULL(@hidden, 0) = 1 THEN N'Inactive' ELSE N'Active' END, @actor);
        SET @existing = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE grac_practice.asset_field_option_org
           SET option_label = ISNULL(@option_label, option_label), display_order = ISNULL(@display_order, display_order),
               status = CASE WHEN ISNULL(@hidden, 0) = 1 THEN N'Inactive' ELSE N'Active' END,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE org_option_id = @existing;

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-option-org', ISNULL(@existing, 0),
            CASE WHEN ISNULL(@reset, 0) = 1 THEN N'OVERRIDE_RESET' WHEN ISNULL(@hidden, 0) = 1 THEN N'DEFAULT_HIDDEN' ELSE N'DEFAULT_OVERRIDE' END,
            @before,
            (SELECT @organization_id AS organizationId, @option_group AS optionGroup, @option_value AS optionValue,
                    @option_label AS optionLabel, @display_order AS displayOrder, @hidden AS hidden, @reset AS reset
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

-- =====================================================================
-- 6. Re-issued from 422: template option lists come from the
--    organization's effective list (fn_asset_field_options) and carry the
--    parent value; readiness checks the same list. Otherwise unchanged.
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
    -- 423: the organization's effective list (global defaults it has not
    -- hidden, its overrides and its own values), with each value's parent.
    SELECT d.field_definition_id AS FieldDefinitionId, o.OptionValue AS OptionValue, o.OptionLabel AS OptionLabel,
           o.DisplayOrder AS DisplayOrder, o.ParentValue AS ParentValue
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_form_template t ON t.template_id = f.template_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      CROSS APPLY grac_practice.fn_asset_field_options(t.organization_id) o
     WHERE f.template_id = @template_id AND t.organization_id = @organization_id
       AND d.lookup_source LIKE N'OPTION:%'
       AND o.OptionGroup = N'asset_field.' + SUBSTRING(d.lookup_source, 8, 100)

    UNION ALL

    -- 422: CIA rating fields (CONFIG:CIA_SCALE) list the levels of the
    -- organization's Active valuation configuration for their dimension.
    SELECT d.field_definition_id, CAST(l.score AS NVARCHAR(160)), CONCAT(l.score, N' - ', l.level_label), l.display_order,
           CAST(NULL AS NVARCHAR(160))
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_form_template t ON t.template_id = f.template_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      JOIN grac_practice.asset_valuation_config c ON c.organization_id = t.organization_id AND c.is_active_version = 1
      JOIN grac_practice.asset_cia_scale_level l
           ON l.config_id = c.config_id
          AND l.dimension_code = CASE d.field_key WHEN N'confidentiality_rating' THEN N'C'
                                                  WHEN N'integrity_rating' THEN N'I'
                                                  WHEN N'availability_rating' THEN N'A' END
     WHERE f.template_id = @template_id AND t.organization_id = @organization_id
       AND d.lookup_source = N'CONFIG:CIA_SCALE'
     ORDER BY 1, 4, 3;
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
           CONCAT(N'Field "', d.display_label, N'" has no option values yet -- add them under Asset & Contract > Option Lists.'), d.field_key
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
     WHERE f.template_id = @template_id AND d.lookup_source LIKE N'OPTION:%'
       -- 423: configured = the organization's effective list has a value.
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template t
                        CROSS APPLY grac_practice.fn_asset_field_options(t.organization_id) o
                        WHERE t.template_id = @template_id
                          AND o.OptionGroup = N'asset_field.' + SUBSTRING(d.lookup_source, 8, 100));

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'CONFIG_PENDING', N'WARNING',
           CONCAT(N'Field "', d.display_label, N'" takes its values from configuration (', d.lookup_source,
                  CASE WHEN d.lookup_source = N'CONFIG:CIA_SCALE'
                       THEN N') -- activate an Asset Valuation configuration for this organization.'
                       ELSE N') that is delivered in a later increment.' END), d.field_key
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
     WHERE f.template_id = @template_id AND d.lookup_source LIKE N'CONFIG:%'
       -- 422: CIA_SCALE is delivered once the organization has an Active
       -- valuation configuration.
       AND NOT (d.lookup_source = N'CONFIG:CIA_SCALE'
                AND EXISTS (SELECT 1 FROM grac_practice.asset_form_template t
                              JOIN grac_practice.asset_valuation_config c
                                ON c.organization_id = t.organization_id AND c.is_active_version = 1
                             WHERE t.template_id = @template_id));

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
PRINT '423: procedures created / re-issued.';
GO

-- =====================================================================
-- 7. Menu: Asset & Contract -> Option Lists (also carried in 274)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'asset-option-lists', N'Option Lists', N'Practice/Index/asset-option-lists', 354, N'list-ul', N'Asset & Contract')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-423', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-423');
PRINT CONCAT('423: menu row upserted: ', @@ROWCOUNT);
GO

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-423', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-asset-contract'
 WHERE c.menu_key = N'asset-option-lists' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
GO

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 0, N'Active', @active_rs, N'seed-423', SYSUTCDATETIME()
  FROM grac_practice.organization_role r
  JOIN grac_practice.menu_master m ON m.menu_key = N'asset-option-lists'
 WHERE r.role_name = N'Admin' AND r.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('423: Admin grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '423-a tables present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_option_list_master','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_field_option_org','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '423-b every OPTION: list catalogued',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_definition d
                              WHERE d.lookup_source LIKE N'OPTION:%'
                                AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_option_list_master m
                                                 WHERE m.option_group = N'asset_field.' + SUBSTRING(d.lookup_source, 8, 100)))
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '423-c dependent lists wired (building/floor/room/zone)',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.asset_option_list_master WHERE parent_field_key IS NOT NULL) = 4
            THEN 'PASS' ELSE 'CHECK' END
UNION ALL
SELECT '423-d function + procedures present',
       CASE WHEN OBJECT_ID('grac_practice.fn_asset_field_options') IS NOT NULL
             AND (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_option_list_catalog', 'sp_asset_option_list_get',
                                'sp_asset_option_org_save', 'sp_asset_option_org_override')) = 4 THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '423-e template get uses the organization list (re-issued)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_form_template_get')) LIKE '%fn_asset_field_options%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '423-f menu row Active under Asset & Contract',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-asset-contract'
                          WHERE c.menu_key = N'asset-option-lists' AND c.status = N'Active') THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build; re-login for the menu grant)
--   1. Asset & Contract -> Option Lists: organization-only lists first
--      (Building, Floor, Room, Zone, Cost centre, ...), then lists with
--      defaults, then fixed Yes/No lists.
--   2. Building: Add "Block A" -> refused without a site (54274); pick a
--      location -> saved. Floor "Ground" under Block A; Room "Server Room"
--      under Ground.
--   3. Retire Block A -> refused (54277, Ground belongs to it).
--   4. Fuel type: hide "Gas" and relabel "Petrol" as "Petrol / Gasoline"
--      -> the list shows HIDDEN / OVERRIDE; Reset restores the default.
--   5. Yes / No / Unknown: no edit actions (fixed list, 54271 via API).
--   6. Asset Form Templates: a template with Building shows its values in
--      Preview / rule pickers; readiness no longer warns for Building.
--   7. A second organization does not see the first one's values.
-- =====================================================================
SET NOEXEC OFF;
GO
