-- =====================================================================
-- 424  Asset taxonomy governance
--      (Asset & Contract Management, Phase 2 increment 5)
--
-- REQUEST
-- -------
--   BRD v1.7 4.1 (hierarchy Main Category -> Subcategory L1/L2 -> Asset
--   Type) and 5.2.3 (Asset Type master fields). Until now the three
--   taxonomy masters (002 / 239) held only code, name, order and an
--   active flag, were maintained by seed scripts only, and had no screen.
--   Plan in docs/asset-contract-management.md.
--
-- WHAT THIS DOES
-- --------------
--   1. Governance columns (added, all NULL-able or defaulted -- existing
--      rows and every existing reader keep working):
--        category    : description, sector, owner_name, standards,
--                      default_criticality_id, effective_from / _to,
--                      record_version            (BRD 4.1 Category row)
--        subcategory : parent_subcategory_id (L2 under an L1 of the same
--                      category), description, effective_from / _to,
--                      record_version            (BRD 4.1 Subcategory row)
--        asset type  : description, default_criticality_id,
--                      effective_from / _to, record_version (BRD 5.2.3)
--   2. asset_type_org_default -- per organization: Default Business Owner
--      Role and Default Technical/Support Group of an asset type (BRD
--      5.2.3). Roles and teams belong to an organization, so these cannot
--      live on the global type row.
--   3. fn_asset_taxonomy_selectable() -- the one definition of "may be
--      chosen now": active, inside its effective dates (UTC date), and
--      every ancestor likewise. Used by:
--        sp_get_asset_taxonomy_lookup (241, re-issued) -- the Add Asset
--          form and the template designer's pickers; an L2 subcategory is
--          labelled "L1 / L2";
--        sp_asset_form_template_create (420, re-issued) -- type check;
--        sp_org_dependency_assets_repository_manage (419, re-issued) --
--          category / subcategory / type checks. Only those three
--          conditions changed; the bodies are otherwise byte-for-byte the
--          419 / 420 versions.
--   4. Procedures: sp_asset_taxonomy_list (screen read),
--      sp_asset_taxonomy_category_save, sp_asset_taxonomy_subcategory_save,
--      sp_asset_taxonomy_type_save (global masters -- the Web tier allows
--      them to the platform administrator only), sp_asset_type_org_default_save
--      (organization defaults). Every write is audited in
--      practice_audit_trace with before / after JSON and is
--      concurrency-checked (record_version).
--   5. Menu "Asset Taxonomy" (asset-taxonomy) under Asset & Contract;
--      Admin grant VIEW / EDIT (EDIT covers the organization defaults only).
--
-- RULES (the BRD states the first three; the rest protect existing data)
--   * Asset Type Name is unique within its subcategory (5.2.3).
--   * Subcategory levels are L1 / L2 only (4.1): an L2's parent must be an
--     L1 of the same category, and a subcategory with children cannot
--     become an L2.
--   * Effective To may not be before Effective From.
--   * Category names are unique; subcategory names are unique under the
--     same category and parent.
--   * A subcategory cannot change category, and an asset type cannot
--     change subcategory, while assets or templates use it (assets store
--     the category / subcategory they were registered under).
--   * Nothing is deleted. Deactivating (or ending the effective dates of)
--     a node makes it and everything below it unselectable for new
--     choices; assets and templates already using it are untouched.
--
-- NOT DONE HERE (later phases, listed in the plan): template inheritance
--   from category / subcategory templates (5.2.1), Default Lifecycle
--   Profile (needs the Phase 4 asset lifecycle), make / model (Phase 3).
--
-- ERROR NUMBERS: 54280-54299
--   54280 category not found            54281 name required
--   54282 name already used             54283 Effective To before Effective From
--   54284 changed by someone else       54285 subcategory not found
--   54286 parent subcategory not valid  54287 cannot move -- in use
--   54288 asset type not found          54289 type name used in subcategory
--   54290 criticality not valid         54291 organization not found
--   54292 role not valid                54293 team not valid
--   54294 category not active           54295 subcategory not active
--
-- ALSO EDITED: 274_menu_master_seed.sql, API (AssetConfig service /
--   controller / models), Web proxy, PracticeScreen.cs, Manage.cshtml,
--   new partial + script asset-taxonomy, both appsettings.json.
--   272 needs no change: it seeds the masters' original columns only.
-- DEPENDS ON: 239, 241, 419, 420, 423.
-- Rollback: 424_asset_taxonomy_governance_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.dependency_asset_subcategory_master','U') IS NULL
   OR OBJECT_ID('grac_practice.dependency_asset_type_master','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_form_template','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_field_options') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_dependency_assets_repository_get','P') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','asset_type_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','asset_subcategory_id') IS NULL
   OR OBJECT_ID('grac_practice.organization_team','U') IS NULL
   OR OBJECT_ID('grac_practice.criticality_master','U') IS NULL
BEGIN
    RAISERROR('ABORT (424): run 239, 241, 419, 420 and 423 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Governance columns
-- =====================================================================
IF COL_LENGTH('grac_practice.dependency_asset_category_master','description') IS NULL
    ALTER TABLE grac_practice.dependency_asset_category_master ADD description NVARCHAR(1000) NULL;
IF COL_LENGTH('grac_practice.dependency_asset_category_master','sector') IS NULL
    ALTER TABLE grac_practice.dependency_asset_category_master ADD sector NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.dependency_asset_category_master','owner_name') IS NULL
    ALTER TABLE grac_practice.dependency_asset_category_master ADD owner_name NVARCHAR(200) NULL;
IF COL_LENGTH('grac_practice.dependency_asset_category_master','standards') IS NULL
    ALTER TABLE grac_practice.dependency_asset_category_master ADD standards NVARCHAR(1000) NULL;
IF COL_LENGTH('grac_practice.dependency_asset_category_master','default_criticality_id') IS NULL
    ALTER TABLE grac_practice.dependency_asset_category_master ADD default_criticality_id INT NULL
        CONSTRAINT fk_pm_asset_category_criticality REFERENCES grac_practice.criticality_master(criticality_id);
IF COL_LENGTH('grac_practice.dependency_asset_category_master','effective_from') IS NULL
    ALTER TABLE grac_practice.dependency_asset_category_master ADD effective_from DATE NULL;
IF COL_LENGTH('grac_practice.dependency_asset_category_master','effective_to') IS NULL
    ALTER TABLE grac_practice.dependency_asset_category_master ADD effective_to DATE NULL;
IF COL_LENGTH('grac_practice.dependency_asset_category_master','record_version') IS NULL
    ALTER TABLE grac_practice.dependency_asset_category_master ADD record_version ROWVERSION NOT NULL;
GO

IF COL_LENGTH('grac_practice.dependency_asset_subcategory_master','parent_subcategory_id') IS NULL
    ALTER TABLE grac_practice.dependency_asset_subcategory_master ADD parent_subcategory_id INT NULL
        CONSTRAINT fk_pm_asset_subcategory_parent REFERENCES grac_practice.dependency_asset_subcategory_master(subcategory_id);
IF COL_LENGTH('grac_practice.dependency_asset_subcategory_master','description') IS NULL
    ALTER TABLE grac_practice.dependency_asset_subcategory_master ADD description NVARCHAR(1000) NULL;
IF COL_LENGTH('grac_practice.dependency_asset_subcategory_master','effective_from') IS NULL
    ALTER TABLE grac_practice.dependency_asset_subcategory_master ADD effective_from DATE NULL;
IF COL_LENGTH('grac_practice.dependency_asset_subcategory_master','effective_to') IS NULL
    ALTER TABLE grac_practice.dependency_asset_subcategory_master ADD effective_to DATE NULL;
IF COL_LENGTH('grac_practice.dependency_asset_subcategory_master','record_version') IS NULL
    ALTER TABLE grac_practice.dependency_asset_subcategory_master ADD record_version ROWVERSION NOT NULL;
GO

IF COL_LENGTH('grac_practice.dependency_asset_type_master','description') IS NULL
    ALTER TABLE grac_practice.dependency_asset_type_master ADD description NVARCHAR(1000) NULL;
IF COL_LENGTH('grac_practice.dependency_asset_type_master','default_criticality_id') IS NULL
    ALTER TABLE grac_practice.dependency_asset_type_master ADD default_criticality_id INT NULL
        CONSTRAINT fk_pm_asset_type_criticality REFERENCES grac_practice.criticality_master(criticality_id);
IF COL_LENGTH('grac_practice.dependency_asset_type_master','effective_from') IS NULL
    ALTER TABLE grac_practice.dependency_asset_type_master ADD effective_from DATE NULL;
IF COL_LENGTH('grac_practice.dependency_asset_type_master','effective_to') IS NULL
    ALTER TABLE grac_practice.dependency_asset_type_master ADD effective_to DATE NULL;
IF COL_LENGTH('grac_practice.dependency_asset_type_master','record_version') IS NULL
    ALTER TABLE grac_practice.dependency_asset_type_master ADD record_version ROWVERSION NOT NULL;
GO

IF OBJECT_ID('grac_practice.ck_pm_asset_category_effective','C') IS NULL
    ALTER TABLE grac_practice.dependency_asset_category_master WITH CHECK ADD CONSTRAINT ck_pm_asset_category_effective
        CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from);
IF OBJECT_ID('grac_practice.ck_pm_asset_subcategory_effective','C') IS NULL
    ALTER TABLE grac_practice.dependency_asset_subcategory_master WITH CHECK ADD CONSTRAINT ck_pm_asset_subcategory_effective
        CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from);
IF OBJECT_ID('grac_practice.ck_pm_asset_type_effective','C') IS NULL
    ALTER TABLE grac_practice.dependency_asset_type_master WITH CHECK ADD CONSTRAINT ck_pm_asset_type_effective
        CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from);
IF OBJECT_ID('grac_practice.ck_pm_asset_subcategory_not_self','C') IS NULL
    ALTER TABLE grac_practice.dependency_asset_subcategory_master WITH CHECK ADD CONSTRAINT ck_pm_asset_subcategory_not_self
        CHECK (parent_subcategory_id IS NULL OR parent_subcategory_id <> subcategory_id);
PRINT '424: governance columns ready.';
GO

-- =====================================================================
-- 2. Organization defaults of an asset type
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_type_org_default','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_type_org_default (
        organization_id        BIGINT        NOT NULL
            CONSTRAINT fk_pm_asset_type_org_default_org REFERENCES grac_practice.organization(organization_id),
        asset_type_id          INT           NOT NULL
            CONSTRAINT fk_pm_asset_type_org_default_type REFERENCES grac_practice.dependency_asset_type_master(asset_type_id),
        business_owner_role_id BIGINT        NULL
            CONSTRAINT fk_pm_asset_type_org_default_role REFERENCES grac_practice.organization_role(role_id),
        support_team_id        BIGINT        NULL
            CONSTRAINT fk_pm_asset_type_org_default_team REFERENCES grac_practice.organization_team(team_id),
        entered_by             NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_type_org_default_eby DEFAULT N'system',
        entered_dt             DATETIME2     NOT NULL CONSTRAINT df_pm_asset_type_org_default_edt DEFAULT SYSUTCDATETIME(),
        updated_by             NVARCHAR(100) NULL,
        updated_dt             DATETIME2     NULL,
        CONSTRAINT pk_pm_asset_type_org_default PRIMARY KEY (organization_id, asset_type_id)
    );
    PRINT '424: asset_type_org_default created.';
END
GO

-- =====================================================================
-- 3. What may be chosen now
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_asset_taxonomy_selectable ()
RETURNS TABLE
AS
RETURN
    WITH today AS (SELECT CAST(SYSUTCDATETIME() AS DATE) AS d),
    cat AS (
        SELECT c.asset_category_id
          FROM grac_practice.dependency_asset_category_master c
         CROSS JOIN today
         WHERE c.is_active = 1
           AND (c.effective_from IS NULL OR c.effective_from <= today.d)
           AND (c.effective_to   IS NULL OR c.effective_to   >= today.d)),
    sub AS (
        SELECT s.subcategory_id, s.asset_category_id, s.parent_subcategory_id
          FROM grac_practice.dependency_asset_subcategory_master s
          JOIN cat ON cat.asset_category_id = s.asset_category_id
         CROSS JOIN today
         WHERE s.is_active = 1
           AND (s.effective_from IS NULL OR s.effective_from <= today.d)
           AND (s.effective_to   IS NULL OR s.effective_to   >= today.d)
           AND (s.parent_subcategory_id IS NULL OR EXISTS (
                SELECT 1 FROM grac_practice.dependency_asset_subcategory_master p
                 WHERE p.subcategory_id = s.parent_subcategory_id AND p.is_active = 1
                   AND (p.effective_from IS NULL OR p.effective_from <= today.d)
                   AND (p.effective_to   IS NULL OR p.effective_to   >= today.d))))
    SELECT N'CATEGORY' AS NodeKind, cat.asset_category_id AS NodeId, CAST(NULL AS INT) AS ParentId,
           cat.asset_category_id AS CategoryId
      FROM cat
    UNION ALL
    SELECT N'SUBCATEGORY', sub.subcategory_id, sub.parent_subcategory_id, sub.asset_category_id
      FROM sub
    UNION ALL
    SELECT N'TYPE', t.asset_type_id, t.subcategory_id, sub.asset_category_id
      FROM grac_practice.dependency_asset_type_master t
      JOIN sub ON sub.subcategory_id = t.subcategory_id
     CROSS JOIN today
     WHERE t.is_active = 1
       AND (t.effective_from IS NULL OR t.effective_from <= today.d)
       AND (t.effective_to   IS NULL OR t.effective_to   >= today.d);
GO

-- A code from a name: upper-case letters and digits, other runs -> '_'.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_make_code (@text NVARCHAR(200), @max_len INT)
RETURNS NVARCHAR(160)
AS
BEGIN
    DECLARE @i INT = 1, @c NCHAR(1), @raw NVARCHAR(200) = UPPER(ISNULL(@text, N'')), @code NVARCHAR(200) = N'';
    WHILE @i <= LEN(@raw)
    BEGIN
        SET @c = SUBSTRING(@raw, @i, 1);
        SET @code = @code + CASE WHEN @c LIKE N'[A-Z0-9]' THEN @c
                                 WHEN RIGHT(@code, 1) = N'_' OR @code = N'' THEN N'' ELSE N'_' END;
        SET @i = @i + 1;
    END
    IF RIGHT(@code, 1) = N'_' SET @code = LEFT(@code, LEN(@code) - 1);
    RETURN LEFT(NULLIF(@code, N''), @max_len);
END
GO
PRINT '424: functions ready.';
GO

-- =====================================================================
-- 4. Screen read
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_taxonomy_list
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54291, 'Organization not found.', 1;

    DECLARE @sel TABLE (node_kind NVARCHAR(20), node_id INT, PRIMARY KEY (node_kind, node_id));
    INSERT @sel (node_kind, node_id) SELECT NodeKind, NodeId FROM grac_practice.fn_asset_taxonomy_selectable();

    -- 1. Categories (asset counts are this organization's)
    SELECT c.asset_category_id AS CategoryId, c.asset_category_code AS CategoryCode, c.asset_category_name AS CategoryName,
           c.description AS Description, c.sector AS Sector, c.owner_name AS OwnerName, c.standards AS Standards,
           c.default_criticality_id AS DefaultCriticalityId, cm.criticality_name AS DefaultCriticalityName,
           c.effective_from AS EffectiveFrom, c.effective_to AS EffectiveTo, c.is_active AS IsActive,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM @sel x WHERE x.node_kind = N'CATEGORY' AND x.node_id = c.asset_category_id)
                     THEN 1 ELSE 0 END AS BIT) AS IsSelectable,
           c.display_order AS DisplayOrder, CONVERT(BIGINT, c.record_version) AS RecordVersion,
           (SELECT COUNT(*) FROM grac_practice.dependency_asset_subcategory_master s
             WHERE s.asset_category_id = c.asset_category_id) AS SubcategoryCount,
           (SELECT COUNT(*) FROM grac_practice.organization_dependency_asset a
             WHERE a.organization_id = @organization_id AND a.asset_category_id = c.asset_category_id) AS AssetCount
      FROM grac_practice.dependency_asset_category_master c
      LEFT JOIN grac_practice.criticality_master cm ON cm.criticality_id = c.default_criticality_id
     ORDER BY c.display_order, c.asset_category_name;

    -- 2. Subcategories
    SELECT s.subcategory_id AS SubcategoryId, s.asset_category_id AS CategoryId,
           s.parent_subcategory_id AS ParentSubcategoryId, p.subcategory_name AS ParentSubcategoryName,
           CASE WHEN s.parent_subcategory_id IS NULL THEN 1 ELSE 2 END AS LevelNo,
           s.subcategory_code AS SubcategoryCode, s.subcategory_name AS SubcategoryName, s.description AS Description,
           s.effective_from AS EffectiveFrom, s.effective_to AS EffectiveTo, s.is_active AS IsActive,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM @sel x WHERE x.node_kind = N'SUBCATEGORY' AND x.node_id = s.subcategory_id)
                     THEN 1 ELSE 0 END AS BIT) AS IsSelectable,
           s.display_order AS DisplayOrder, CONVERT(BIGINT, s.record_version) AS RecordVersion,
           (SELECT COUNT(*) FROM grac_practice.dependency_asset_subcategory_master k
             WHERE k.parent_subcategory_id = s.subcategory_id) AS ChildCount,
           (SELECT COUNT(*) FROM grac_practice.dependency_asset_type_master t
             WHERE t.subcategory_id = s.subcategory_id) AS TypeCount,
           (SELECT COUNT(*) FROM grac_practice.organization_dependency_asset a
             WHERE a.organization_id = @organization_id AND a.asset_subcategory_id = s.subcategory_id) AS AssetCount
      FROM grac_practice.dependency_asset_subcategory_master s
      LEFT JOIN grac_practice.dependency_asset_subcategory_master p ON p.subcategory_id = s.parent_subcategory_id
     ORDER BY s.asset_category_id, ISNULL(p.display_order, s.display_order), ISNULL(p.subcategory_id, s.subcategory_id),
              CASE WHEN s.parent_subcategory_id IS NULL THEN 0 ELSE 1 END, s.display_order, s.subcategory_name;

    -- 3. Asset types, with this organization's defaults and usage
    SELECT t.asset_type_id AS AssetTypeId, t.subcategory_id AS SubcategoryId, s.asset_category_id AS CategoryId,
           t.asset_type_code AS AssetTypeCode, t.asset_type_name AS AssetTypeName, t.description AS Description,
           t.default_criticality_id AS DefaultCriticalityId, cm.criticality_name AS DefaultCriticalityName,
           COALESCE(cm.criticality_name, ccm.criticality_name) AS EffectiveCriticalityName,
           t.effective_from AS EffectiveFrom, t.effective_to AS EffectiveTo, t.is_active AS IsActive,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM @sel x WHERE x.node_kind = N'TYPE' AND x.node_id = t.asset_type_id)
                     THEN 1 ELSE 0 END AS BIT) AS IsSelectable,
           t.display_order AS DisplayOrder, CONVERT(BIGINT, t.record_version) AS RecordVersion,
           (SELECT COUNT(*) FROM grac_practice.organization_dependency_asset a
             WHERE a.organization_id = @organization_id AND a.asset_type_id = t.asset_type_id) AS AssetCount,
           (SELECT COUNT(*) FROM grac_practice.asset_form_template f
             WHERE f.organization_id = @organization_id AND f.asset_type_id = t.asset_type_id) AS TemplateCount,
           d.business_owner_role_id AS BusinessOwnerRoleId, r.role_name AS BusinessOwnerRoleName,
           d.support_team_id AS SupportTeamId, tm.team_name AS SupportTeamName
      FROM grac_practice.dependency_asset_type_master t
      JOIN grac_practice.dependency_asset_subcategory_master s ON s.subcategory_id = t.subcategory_id
      JOIN grac_practice.dependency_asset_category_master c ON c.asset_category_id = s.asset_category_id
      LEFT JOIN grac_practice.criticality_master cm  ON cm.criticality_id  = t.default_criticality_id
      LEFT JOIN grac_practice.criticality_master ccm ON ccm.criticality_id = c.default_criticality_id
      LEFT JOIN grac_practice.asset_type_org_default d ON d.organization_id = @organization_id AND d.asset_type_id = t.asset_type_id
      LEFT JOIN grac_practice.organization_role r ON r.role_id = d.business_owner_role_id
      LEFT JOIN grac_practice.organization_team tm ON tm.team_id = d.support_team_id
     ORDER BY t.subcategory_id, t.display_order, t.asset_type_name;

    -- 4. Criticality values
    SELECT criticality_id AS CriticalityId, criticality_name AS CriticalityName
      FROM grac_practice.criticality_master WHERE is_active = 1 ORDER BY display_order, criticality_name;

    -- 5. Organization roles and 6. teams (for the organization defaults)
    SELECT role_id AS RoleId, role_name AS RoleName
      FROM grac_practice.organization_role
     WHERE organization_id = @organization_id AND status = N'Active' ORDER BY role_name;
    SELECT team_id AS TeamId, team_name AS TeamName
      FROM grac_practice.organization_team
     WHERE organization_id = @organization_id AND status = N'Active' ORDER BY team_name;
END
GO

-- =====================================================================
-- 5. Writers -- global masters (platform administrator only; the Web
--    proxy enforces that) and the organization defaults.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_taxonomy_category_save
    @category_id             INT            = NULL,
    @category_name           NVARCHAR(160),
    @description             NVARCHAR(1000) = NULL,
    @sector                  NVARCHAR(120)  = NULL,
    @owner_name              NVARCHAR(200)  = NULL,
    @standards               NVARCHAR(1000) = NULL,
    @default_criticality_id  INT            = NULL,
    @effective_from          DATE           = NULL,
    @effective_to            DATE           = NULL,
    @is_active               BIT            = 1,
    @display_order           INT            = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @out_category_id         INT            = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @category_name = NULLIF(LTRIM(RTRIM(@category_name)), N'');
    SET @is_active = ISNULL(@is_active, 1);

    DECLARE @rv BIGINT, @before NVARCHAR(MAX);
    IF @category_id IS NOT NULL
    BEGIN
        SELECT @rv = CONVERT(BIGINT, record_version) FROM grac_practice.dependency_asset_category_master
         WHERE asset_category_id = @category_id;
        IF @rv IS NULL THROW 54280, 'Asset category not found.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54284, 'This entry was changed by someone else. Reload and try again.', 1;
    END
    IF @category_name IS NULL THROW 54281, 'A name is required.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.dependency_asset_category_master
                WHERE asset_category_name = @category_name AND asset_category_id <> ISNULL(@category_id, -1))
        THROW 54282, 'Another category already has this name.', 1;
    IF @effective_from IS NOT NULL AND @effective_to IS NOT NULL AND @effective_to < @effective_from
        THROW 54283, 'Effective To cannot be before Effective From.', 1;
    IF @default_criticality_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.criticality_master WHERE criticality_id = @default_criticality_id AND is_active = 1)
        THROW 54290, 'Select an active criticality.', 1;

    SET @before = (SELECT asset_category_name AS name, description, sector, owner_name AS ownerName, standards,
                          default_criticality_id AS defaultCriticalityId, effective_from AS effectiveFrom,
                          effective_to AS effectiveTo, is_active AS isActive, display_order AS displayOrder
                     FROM grac_practice.dependency_asset_category_master WHERE asset_category_id = @category_id
                      FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRAN;
    IF @category_id IS NULL
    BEGIN
        DECLARE @base NVARCHAR(160) = ISNULL(grac_practice.fn_asset_make_code(@category_name, 54), N'CATEGORY'),
                @code NVARCHAR(160), @n INT = 1;
        SET @code = @base;
        WHILE EXISTS (SELECT 1 FROM grac_practice.dependency_asset_category_master WHERE asset_category_code = @code)
        BEGIN
            SET @n = @n + 1;
            SET @code = @base + N'_' + CAST(@n AS NVARCHAR(10));
        END
        IF @display_order IS NULL
            SELECT @display_order = ISNULL(MAX(display_order), 0) + 10 FROM grac_practice.dependency_asset_category_master;
        INSERT grac_practice.dependency_asset_category_master
            (asset_category_code, asset_category_name, display_order, is_active, description, sector, owner_name,
             standards, default_criticality_id, effective_from, effective_to, entered_by)
        VALUES (@code, @category_name, @display_order, @is_active, NULLIF(LTRIM(RTRIM(@description)), N''),
                NULLIF(LTRIM(RTRIM(@sector)), N''), NULLIF(LTRIM(RTRIM(@owner_name)), N''),
                NULLIF(LTRIM(RTRIM(@standards)), N''), @default_criticality_id, @effective_from, @effective_to, @actor);
        SET @out_category_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.dependency_asset_category_master
           SET asset_category_name = @category_name, display_order = ISNULL(@display_order, display_order),
               is_active = @is_active, description = NULLIF(LTRIM(RTRIM(@description)), N''),
               sector = NULLIF(LTRIM(RTRIM(@sector)), N''), owner_name = NULLIF(LTRIM(RTRIM(@owner_name)), N''),
               standards = NULLIF(LTRIM(RTRIM(@standards)), N''), default_criticality_id = @default_criticality_id,
               effective_from = @effective_from, effective_to = @effective_to,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE asset_category_id = @category_id;
        SET @out_category_id = @category_id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-taxonomy-category', @out_category_id, CASE WHEN @category_id IS NULL THEN N'ADD' ELSE N'SAVE' END, @before,
            (SELECT @category_name AS name, @description AS description, @sector AS sector, @owner_name AS ownerName,
                    @standards AS standards, @default_criticality_id AS defaultCriticalityId,
                    @effective_from AS effectiveFrom, @effective_to AS effectiveTo, @is_active AS isActive,
                    @display_order AS displayOrder FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_taxonomy_subcategory_save
    @subcategory_id          INT            = NULL,
    @category_id             INT,
    @parent_subcategory_id   INT            = NULL,
    @subcategory_name        NVARCHAR(200),
    @description             NVARCHAR(1000) = NULL,
    @effective_from          DATE           = NULL,
    @effective_to            DATE           = NULL,
    @is_active               BIT            = 1,
    @display_order           INT            = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @out_subcategory_id      INT            = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @subcategory_name = NULLIF(LTRIM(RTRIM(@subcategory_name)), N'');
    SET @is_active = ISNULL(@is_active, 1);

    DECLARE @rv BIGINT, @old_category INT, @old_parent INT, @before NVARCHAR(MAX);
    IF @subcategory_id IS NOT NULL
    BEGIN
        SELECT @rv = CONVERT(BIGINT, record_version), @old_category = asset_category_id, @old_parent = parent_subcategory_id
          FROM grac_practice.dependency_asset_subcategory_master WHERE subcategory_id = @subcategory_id;
        IF @rv IS NULL THROW 54285, 'Subcategory not found.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54284, 'This entry was changed by someone else. Reload and try again.', 1;
    END
    IF NOT EXISTS (SELECT 1 FROM grac_practice.dependency_asset_category_master WHERE asset_category_id = @category_id)
        THROW 54280, 'Asset category not found.', 1;
    IF ISNULL(@old_category, -1) <> @category_id AND NOT EXISTS (
        SELECT 1 FROM grac_practice.dependency_asset_category_master WHERE asset_category_id = @category_id AND is_active = 1)
        THROW 54294, 'Select an active category.', 1;
    IF @subcategory_name IS NULL THROW 54281, 'A name is required.', 1;
    IF @effective_from IS NOT NULL AND @effective_to IS NOT NULL AND @effective_to < @effective_from
        THROW 54283, 'Effective To cannot be before Effective From.', 1;

    -- L1 / L2 only (BRD 4.1).
    IF @parent_subcategory_id IS NOT NULL
    BEGIN
        IF @parent_subcategory_id = ISNULL(@subcategory_id, -1)
           OR NOT EXISTS (SELECT 1 FROM grac_practice.dependency_asset_subcategory_master
                           WHERE subcategory_id = @parent_subcategory_id AND asset_category_id = @category_id
                             AND parent_subcategory_id IS NULL)
            THROW 54286, 'The parent must be a level-1 subcategory of the same category.', 1;
        IF @subcategory_id IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.dependency_asset_subcategory_master
                                                    WHERE parent_subcategory_id = @subcategory_id)
            THROW 54286, 'This subcategory has level-2 subcategories below it, so it cannot become level 2.', 1;
        IF ISNULL(@old_parent, -1) <> @parent_subcategory_id AND NOT EXISTS (
            SELECT 1 FROM grac_practice.dependency_asset_subcategory_master WHERE subcategory_id = @parent_subcategory_id AND is_active = 1)
            THROW 54295, 'Select an active parent subcategory.', 1;
    END
    IF EXISTS (SELECT 1 FROM grac_practice.dependency_asset_subcategory_master
                WHERE asset_category_id = @category_id AND subcategory_name = @subcategory_name
                  AND ISNULL(parent_subcategory_id, -1) = ISNULL(@parent_subcategory_id, -1)
                  AND subcategory_id <> ISNULL(@subcategory_id, -1))
        THROW 54282, 'Another subcategory at this place already has this name.', 1;

    -- Assets store the category and subcategory they were registered under.
    IF @subcategory_id IS NOT NULL AND @old_category <> @category_id
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.dependency_asset_subcategory_master WHERE parent_subcategory_id = @subcategory_id)
           OR EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                       WHERE a.asset_subcategory_id = @subcategory_id
                          OR a.asset_type_id IN (SELECT t.asset_type_id FROM grac_practice.dependency_asset_type_master t
                                                  WHERE t.subcategory_id = @subcategory_id))
           OR EXISTS (SELECT 1 FROM grac_practice.asset_form_template f
                        JOIN grac_practice.dependency_asset_type_master t ON t.asset_type_id = f.asset_type_id
                       WHERE t.subcategory_id = @subcategory_id)
            THROW 54287, 'This subcategory is in use (assets, templates or level-2 subcategories), so it cannot move to another category.', 1;
    END

    SET @before = (SELECT asset_category_id AS categoryId, parent_subcategory_id AS parentSubcategoryId,
                          subcategory_name AS name, description, effective_from AS effectiveFrom, effective_to AS effectiveTo,
                          is_active AS isActive, display_order AS displayOrder
                     FROM grac_practice.dependency_asset_subcategory_master WHERE subcategory_id = @subcategory_id
                      FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRAN;
    IF @subcategory_id IS NULL
    BEGIN
        DECLARE @base NVARCHAR(160) = ISNULL(grac_practice.fn_asset_make_code(@subcategory_name, 74), N'SUBCATEGORY'),
                @code NVARCHAR(160), @n INT = 1;
        SET @code = @base;
        WHILE EXISTS (SELECT 1 FROM grac_practice.dependency_asset_subcategory_master WHERE subcategory_code = @code)
        BEGIN
            SET @n = @n + 1;
            SET @code = @base + N'_' + CAST(@n AS NVARCHAR(10));
        END
        IF @display_order IS NULL
            SELECT @display_order = ISNULL(MAX(display_order), 0) + 10
              FROM grac_practice.dependency_asset_subcategory_master WHERE asset_category_id = @category_id;
        INSERT grac_practice.dependency_asset_subcategory_master
            (asset_category_id, subcategory_code, subcategory_name, display_order, is_active, parent_subcategory_id,
             description, effective_from, effective_to, entered_by)
        VALUES (@category_id, @code, @subcategory_name, @display_order, @is_active, @parent_subcategory_id,
                NULLIF(LTRIM(RTRIM(@description)), N''), @effective_from, @effective_to, @actor);
        SET @out_subcategory_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.dependency_asset_subcategory_master
           SET asset_category_id = @category_id, parent_subcategory_id = @parent_subcategory_id,
               subcategory_name = @subcategory_name, description = NULLIF(LTRIM(RTRIM(@description)), N''),
               effective_from = @effective_from, effective_to = @effective_to, is_active = @is_active,
               display_order = ISNULL(@display_order, display_order), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE subcategory_id = @subcategory_id;
        SET @out_subcategory_id = @subcategory_id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-taxonomy-subcategory', @out_subcategory_id, CASE WHEN @subcategory_id IS NULL THEN N'ADD' ELSE N'SAVE' END, @before,
            (SELECT @category_id AS categoryId, @parent_subcategory_id AS parentSubcategoryId, @subcategory_name AS name,
                    @description AS description, @effective_from AS effectiveFrom, @effective_to AS effectiveTo,
                    @is_active AS isActive, @display_order AS displayOrder FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_taxonomy_type_save
    @asset_type_id           INT            = NULL,
    @subcategory_id          INT,
    @asset_type_name         NVARCHAR(200),
    @description             NVARCHAR(1000) = NULL,
    @default_criticality_id  INT            = NULL,
    @effective_from          DATE           = NULL,
    @effective_to            DATE           = NULL,
    @is_active               BIT            = 1,
    @display_order           INT            = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @out_asset_type_id       INT            = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @asset_type_name = NULLIF(LTRIM(RTRIM(@asset_type_name)), N'');
    SET @is_active = ISNULL(@is_active, 1);

    DECLARE @rv BIGINT, @old_sub INT, @before NVARCHAR(MAX);
    IF @asset_type_id IS NOT NULL
    BEGIN
        SELECT @rv = CONVERT(BIGINT, record_version), @old_sub = subcategory_id
          FROM grac_practice.dependency_asset_type_master WHERE asset_type_id = @asset_type_id;
        IF @rv IS NULL THROW 54288, 'Asset type not found.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54284, 'This entry was changed by someone else. Reload and try again.', 1;
    END
    IF NOT EXISTS (SELECT 1 FROM grac_practice.dependency_asset_subcategory_master WHERE subcategory_id = @subcategory_id)
        THROW 54285, 'Subcategory not found.', 1;
    IF ISNULL(@old_sub, -1) <> @subcategory_id AND NOT EXISTS (
        SELECT 1 FROM grac_practice.dependency_asset_subcategory_master WHERE subcategory_id = @subcategory_id AND is_active = 1)
        THROW 54295, 'Select an active subcategory.', 1;
    IF @asset_type_name IS NULL THROW 54281, 'A name is required.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.dependency_asset_type_master
                WHERE subcategory_id = @subcategory_id AND asset_type_name = @asset_type_name
                  AND asset_type_id <> ISNULL(@asset_type_id, -1))
        THROW 54289, 'Asset Type Name must be unique within its subcategory.', 1;
    IF @effective_from IS NOT NULL AND @effective_to IS NOT NULL AND @effective_to < @effective_from
        THROW 54283, 'Effective To cannot be before Effective From.', 1;
    IF @default_criticality_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.criticality_master WHERE criticality_id = @default_criticality_id AND is_active = 1)
        THROW 54290, 'Select an active criticality.', 1;
    IF @asset_type_id IS NOT NULL AND @old_sub <> @subcategory_id
       AND (EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset WHERE asset_type_id = @asset_type_id)
            OR EXISTS (SELECT 1 FROM grac_practice.asset_form_template WHERE asset_type_id = @asset_type_id))
        THROW 54287, 'This asset type is used by assets or templates, so it cannot move to another subcategory.', 1;

    SET @before = (SELECT subcategory_id AS subcategoryId, asset_type_name AS name, description,
                          default_criticality_id AS defaultCriticalityId, effective_from AS effectiveFrom,
                          effective_to AS effectiveTo, is_active AS isActive, display_order AS displayOrder
                     FROM grac_practice.dependency_asset_type_master WHERE asset_type_id = @asset_type_id
                      FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRAN;
    IF @asset_type_id IS NULL
    BEGIN
        DECLARE @base NVARCHAR(160) = N'TYPE_' + ISNULL(grac_practice.fn_asset_make_code(@asset_type_name, 69), N'ASSET'),
                @code NVARCHAR(160), @n INT = 1;
        SET @code = @base;
        WHILE EXISTS (SELECT 1 FROM grac_practice.dependency_asset_type_master WHERE asset_type_code = @code)
        BEGIN
            SET @n = @n + 1;
            SET @code = @base + N'_' + CAST(@n AS NVARCHAR(10));
        END
        IF @display_order IS NULL
            SELECT @display_order = ISNULL(MAX(display_order), 0) + 10
              FROM grac_practice.dependency_asset_type_master WHERE subcategory_id = @subcategory_id;
        INSERT grac_practice.dependency_asset_type_master
            (subcategory_id, asset_type_code, asset_type_name, display_order, is_active, description,
             default_criticality_id, effective_from, effective_to, entered_by)
        VALUES (@subcategory_id, @code, @asset_type_name, @display_order, @is_active, NULLIF(LTRIM(RTRIM(@description)), N''),
                @default_criticality_id, @effective_from, @effective_to, @actor);
        SET @out_asset_type_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.dependency_asset_type_master
           SET subcategory_id = @subcategory_id, asset_type_name = @asset_type_name,
               description = NULLIF(LTRIM(RTRIM(@description)), N''), default_criticality_id = @default_criticality_id,
               effective_from = @effective_from, effective_to = @effective_to, is_active = @is_active,
               display_order = ISNULL(@display_order, display_order), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE asset_type_id = @asset_type_id;
        SET @out_asset_type_id = @asset_type_id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-taxonomy-type', @out_asset_type_id, CASE WHEN @asset_type_id IS NULL THEN N'ADD' ELSE N'SAVE' END, @before,
            (SELECT @subcategory_id AS subcategoryId, @asset_type_name AS name, @description AS description,
                    @default_criticality_id AS defaultCriticalityId, @effective_from AS effectiveFrom,
                    @effective_to AS effectiveTo, @is_active AS isActive, @display_order AS displayOrder
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

-- Both NULL clears the organization's defaults for the type.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_type_org_default_save
    @organization_id        BIGINT,
    @asset_type_id          INT,
    @business_owner_role_id BIGINT        = NULL,
    @support_team_id        BIGINT        = NULL,
    @actor                  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54291, 'Organization not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.dependency_asset_type_master WHERE asset_type_id = @asset_type_id)
        THROW 54288, 'Asset type not found.', 1;
    IF @business_owner_role_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role
         WHERE role_id = @business_owner_role_id AND organization_id = @organization_id AND status = N'Active')
        THROW 54292, 'The business owner role must be an active role of the organization.', 1;
    IF @support_team_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_team
         WHERE team_id = @support_team_id AND organization_id = @organization_id AND status = N'Active')
        THROW 54293, 'The support group must be an active team of the organization.', 1;

    DECLARE @before NVARCHAR(MAX) = (
        SELECT business_owner_role_id AS businessOwnerRoleId, support_team_id AS supportTeamId
          FROM grac_practice.asset_type_org_default
         WHERE organization_id = @organization_id AND asset_type_id = @asset_type_id
           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRAN;
    IF @business_owner_role_id IS NULL AND @support_team_id IS NULL
        DELETE grac_practice.asset_type_org_default
         WHERE organization_id = @organization_id AND asset_type_id = @asset_type_id;
    ELSE IF EXISTS (SELECT 1 FROM grac_practice.asset_type_org_default
                     WHERE organization_id = @organization_id AND asset_type_id = @asset_type_id)
        UPDATE grac_practice.asset_type_org_default
           SET business_owner_role_id = @business_owner_role_id, support_team_id = @support_team_id,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE organization_id = @organization_id AND asset_type_id = @asset_type_id;
    ELSE
        INSERT grac_practice.asset_type_org_default
            (organization_id, asset_type_id, business_owner_role_id, support_team_id, entered_by)
        VALUES (@organization_id, @asset_type_id, @business_owner_role_id, @support_team_id, @actor);

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-type-org-default', @asset_type_id,
            CASE WHEN @business_owner_role_id IS NULL AND @support_team_id IS NULL THEN N'CLEAR' ELSE N'SAVE' END, @before,
            (SELECT @organization_id AS organizationId, @business_owner_role_id AS businessOwnerRoleId,
                    @support_team_id AS supportTeamId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO
PRINT '424: taxonomy procedures created.';
GO

-- =====================================================================
-- 6. Re-issued from 241: the lookup lists only what may be chosen now.
--    Same 7-parameter signature and 4-column shape; an L2 subcategory is
--    labelled "L1 / L2" and still carries its category as Parent.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_get_asset_taxonomy_lookup
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

    SELECT N'asset-categories'    AS EntityType,
           CAST(c.asset_category_id AS NVARCHAR(40)) AS Value,
           c.asset_category_name  AS Label,
           CAST(NULL AS BIGINT)   AS Parent
      FROM grac_practice.dependency_asset_category_master c
      JOIN grac_practice.fn_asset_taxonomy_selectable() f ON f.NodeKind = N'CATEGORY' AND f.NodeId = c.asset_category_id

    UNION ALL

    SELECT N'asset-subcategories',
           CAST(s.subcategory_id AS NVARCHAR(40)),
           CASE WHEN p.subcategory_id IS NULL THEN s.subcategory_name
                ELSE p.subcategory_name + N' / ' + s.subcategory_name END,
           CAST(s.asset_category_id AS BIGINT)
      FROM grac_practice.dependency_asset_subcategory_master s
      JOIN grac_practice.fn_asset_taxonomy_selectable() f ON f.NodeKind = N'SUBCATEGORY' AND f.NodeId = s.subcategory_id
      LEFT JOIN grac_practice.dependency_asset_subcategory_master p ON p.subcategory_id = s.parent_subcategory_id

    UNION ALL

    SELECT N'asset-types',
           CAST(t.asset_type_id AS NVARCHAR(40)),
           t.asset_type_name,
           CAST(t.subcategory_id AS BIGINT)
      FROM grac_practice.dependency_asset_type_master t
      JOIN grac_practice.fn_asset_taxonomy_selectable() f ON f.NodeKind = N'TYPE' AND f.NodeId = t.asset_type_id

     ORDER BY EntityType, Label;
END
GO

-- =====================================================================
-- 7. Re-issued from 420: sp_asset_form_template_create -- only the asset
--    type check changed (selectable now, not just active).
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
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_taxonomy_selectable() WHERE NodeKind = N'TYPE' AND NodeId = @asset_type_id)
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
PRINT '424: sp_asset_form_template_create re-issued.';
GO

-- =====================================================================
-- 8. Re-issued from 419: sp_org_dependency_assets_repository_manage --
--    only the category / subcategory / type checks changed (selectable
--    now, not just active). Messages and error numbers are unchanged.
-- =====================================================================
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
       OR NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_taxonomy_selectable()
                       WHERE NodeKind = N'CATEGORY' AND NodeId = @asset_category_id)
        THROW 51132, 'Asset Category is required.', 1;
    IF @asset_subcategory_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.fn_asset_taxonomy_selectable()
         WHERE NodeKind = N'SUBCATEGORY' AND NodeId = @asset_subcategory_id AND CategoryId = @asset_category_id)
        THROW 52726, 'The chosen Sub Category does not belong to the chosen Category.', 1;
    IF @asset_type_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.fn_asset_taxonomy_selectable() f
         WHERE f.NodeKind = N'TYPE' AND f.NodeId = @asset_type_id
           AND f.ParentId = COALESCE(@asset_subcategory_id, f.ParentId)
           AND f.CategoryId = @asset_category_id)
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
PRINT '424: sp_org_dependency_assets_repository_manage re-issued.';
GO

-- =====================================================================
-- 9. Menu: Asset & Contract -> Asset Taxonomy (also carried in 274)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'asset-taxonomy', N'Asset Taxonomy', N'Practice/Index/asset-taxonomy', 355, N'sitemap', N'Asset & Contract')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-424', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-424');
PRINT CONCAT('424: menu row upserted: ', @@ROWCOUNT);
GO

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-424', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-asset-contract'
 WHERE c.menu_key = N'asset-taxonomy' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
GO

-- Admin: VIEW + EDIT. EDIT covers the organization defaults; the global
-- masters are changed by the platform administrator only (Web proxy).
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 0, 1, 0, 0, N'Active', @active_rs, N'seed-424', SYSUTCDATETIME()
  FROM grac_practice.organization_role r
  JOIN grac_practice.menu_master m ON m.menu_key = N'asset-taxonomy'
 WHERE r.role_name = N'Admin' AND r.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('424: Admin grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '424-a governance columns present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.dependency_asset_category_master','record_version') IS NOT NULL
             AND COL_LENGTH('grac_practice.dependency_asset_subcategory_master','parent_subcategory_id') IS NOT NULL
             AND COL_LENGTH('grac_practice.dependency_asset_type_master','default_criticality_id') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_type_org_default','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '424-b functions + procedures present',
       CASE WHEN OBJECT_ID('grac_practice.fn_asset_taxonomy_selectable') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_make_code') IS NOT NULL
             AND (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_taxonomy_list', 'sp_asset_taxonomy_category_save', 'sp_asset_taxonomy_subcategory_save',
                                'sp_asset_taxonomy_type_save', 'sp_asset_type_org_default_save')) = 5 THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '424-c lookup / template create / asset save use the selectable set (re-issued)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_get_asset_taxonomy_lookup')) LIKE '%fn_asset_taxonomy_selectable%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_form_template_create')) LIKE '%fn_asset_taxonomy_selectable%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_dependency_assets_repository_manage')) LIKE '%fn_asset_taxonomy_selectable%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '424-d existing active taxonomy still selectable (nothing hidden by this migration)',
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.dependency_asset_type_master t
                  JOIN grac_practice.dependency_asset_subcategory_master s ON s.subcategory_id = t.subcategory_id
                  JOIN grac_practice.dependency_asset_category_master c ON c.asset_category_id = s.asset_category_id
                 WHERE t.is_active = 1 AND s.is_active = 1 AND c.is_active = 1 AND s.parent_subcategory_id IS NULL
                   AND t.effective_from IS NULL AND t.effective_to IS NULL AND s.effective_from IS NULL
                   AND s.effective_to IS NULL AND c.effective_from IS NULL AND c.effective_to IS NULL
                   AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_taxonomy_selectable() f
                                    WHERE f.NodeKind = N'TYPE' AND f.NodeId = t.asset_type_id))
             AND NOT EXISTS (
                SELECT 1 FROM grac_practice.dependency_asset_category_master c
                 WHERE c.is_active = 1 AND c.effective_from IS NULL AND c.effective_to IS NULL
                   AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_taxonomy_selectable() f
                                    WHERE f.NodeKind = N'CATEGORY' AND f.NodeId = c.asset_category_id))
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '424-e no duplicate asset type names within a subcategory (existing data)',
       CASE WHEN NOT EXISTS (SELECT subcategory_id, asset_type_name FROM grac_practice.dependency_asset_type_master
                              GROUP BY subcategory_id, asset_type_name HAVING COUNT(*) > 1)
            THEN 'PASS' ELSE 'CHECK -- rename the duplicates on the Asset Taxonomy screen' END
UNION ALL
SELECT '424-f menu row Active under Asset & Contract',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-asset-contract'
                          WHERE c.menu_key = N'asset-taxonomy' AND c.status = N'Active') THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build; re-login for the menu grant)
--   As the platform administrator (PM_ADMIN):
--   1. Asset & Contract -> Asset Taxonomy shows the categories; select one
--      to see its subcategories (L2 indented under L1) and asset types.
--   2. Edit a category: set Sector, Owner, Standards, Default Criticality
--      and Effective From / To; save; reopen -- values kept; an Effective
--      To before Effective From is refused (54283).
--   3. Add an L2 subcategory under an L1; try to put it under an L2 or
--      under a subcategory of another category -- refused (54286).
--   4. Add an asset type; add a second one with the same name in the same
--      subcategory -- refused (54289).
--   5. Set an asset type's Effective To to yesterday: Settings ->
--      Dependencies -> Assets -> Add no longer offers it, Asset Form
--      Templates -> New no longer accepts it (54201), saving an asset with
--      it is refused (52727); assets already using it still open.
--   6. Open the same category in two tabs, save both -- the second is
--      refused (54284, HTTP 409).
--   As an organization Admin:
--   7. The screen is read-only for the global masters; Organization
--      defaults on an asset type (Business Owner Role, Support Group)
--      save for this organization only.
-- =====================================================================
