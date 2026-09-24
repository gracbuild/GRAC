-- =====================================================================
-- 241 Asset taxonomy procs -- save shim + lookup
--
-- WHY
-- ---
-- 239 gave organization_dependency_asset two new columns
-- (asset_subcategory_id, asset_type_id). The Add Asset form on
-- Practice/Index/organization-dependencies needs to
--
--   * receive the taxonomy on load so the Sub Category and Asset Type
--     dropdowns can cascade off the picked Asset Category, and
--   * persist those two ids on Save.
--
-- The save side lives in the pm_manage_practice_repository monolith,
-- and reissuing that ~1600-line procedure to add two JSON reads is more
-- risk than the task deserves. Instead this migration adds a save shim
-- for entity 'dependency-assets' -- ResolveProcedureAsync (see the C#
-- service, migration 134 wired the same for users / teams) will pick
-- the shim when it exists and fall back to the monolith otherwise.
--
-- The lookup side is a separate small proc that returns all three
-- taxonomy tables in a single call. The Web layer will expose it as
-- /practice/api/practice-management-master/asset-taxonomy and the
-- Add Asset form will fetch it once during initialisation.
--
-- SAFE TO RE-RUN. Requires 239. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.organization_dependency_asset','U') IS NULL
    OR COL_LENGTH('grac_practice.organization_dependency_asset','asset_subcategory_id') IS NULL
BEGIN
    PRINT 'ABORT (241): 239 has not been run -- taxonomy columns missing.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Save shim for dependency-assets
--
-- Signature mirrors the monolith's asset section (params observed in
-- 002 around line 3976). The C# service passes the same names and
-- values; the shim reads the same JSON keys plus the two new ones and
-- writes the two new columns alongside them.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_dependency_assets_repository_manage
    -- 7-parameter signature that the C# service passes to every shim
    -- (see PracticeRepositoryService.ExecuteAsync, migration 134's shim
    -- signature). Unused positional params are here so calling this proc
    -- via the same generic path does not fail with "too many arguments".
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

    IF @p_action IS NULL OR LTRIM(RTRIM(@p_action)) = N''
        THROW 52720, 'sp_org_dependency_assets_repository_manage: action is required.', 1;

    -- Common lookups.
    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM   grac_practice.record_status_master
        WHERE  status_code = N'ACTIVE' OR status_name = N'Active'
        ORDER  BY record_status_id
    );
    DECLARE @inactive_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM   grac_practice.record_status_master
        WHERE  status_code = N'INACTIVE' OR status_name = N'Inactive'
        ORDER  BY record_status_id
    );

    -- 'delete' behaves like the monolith: soft delete via status.
    IF @p_action IN (N'delete', N'inactive', N'deactivate')
    BEGIN
        IF @p_id IS NULL OR @p_id <= 0
            THROW 52721, 'sp_org_dependency_assets_repository_manage: id is required for delete.', 1;

        UPDATE grac_practice.organization_dependency_asset
           SET status           = N'Inactive',
               record_status_id = COALESCE(@inactive_record_status_id, record_status_id),
               updated_by       = @p_usr_id,
               updated_dt       = SYSUTCDATETIME()
         WHERE asset_id = @p_id;

        SELECT CAST(1 AS BIT) AS Success, N'Asset deactivated.' AS Message;
        RETURN;
    END

    -- Save / update.
    IF @p_payload IS NULL OR ISJSON(@p_payload) <> 1
        THROW 52722, 'sp_org_dependency_assets_repository_manage: payload must be a JSON object.', 1;

    DECLARE @asset_org_id           BIGINT        = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload, N'$.organizationId'), N''));
    DECLARE @asset_name             NVARCHAR(220) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload, N'$.name'))), N'');
    DECLARE @asset_category_id      INT           = TRY_CONVERT(INT, NULLIF(JSON_VALUE(@p_payload, N'$.assetCategoryId'), N''));
    DECLARE @asset_subcategory_id   INT           = TRY_CONVERT(INT, NULLIF(JSON_VALUE(@p_payload, N'$.assetSubcategoryId'), N''));
    DECLARE @asset_type_id          INT           = TRY_CONVERT(INT, NULLIF(JSON_VALUE(@p_payload, N'$.assetTypeId'), N''));
    DECLARE @asset_owner_id         BIGINT        = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload, N'$.ownerId'), N''));
    DECLARE @asset_location_id      BIGINT        = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload, N'$.locationId'), N''));
    DECLARE @asset_criticality_id   INT           = TRY_CONVERT(INT, NULLIF(JSON_VALUE(@p_payload, N'$.criticalityId'), N''));
    DECLARE @purchase_dt            DATE          = TRY_CONVERT(DATE, NULLIF(JSON_VALUE(@p_payload, N'$.purchaseDate'), N''));
    DECLARE @warranty_expiry_dt     DATE          = TRY_CONVERT(DATE, NULLIF(JSON_VALUE(@p_payload, N'$.warrantyExpiryDate'), N''));
    DECLARE @amc_expiry_dt          DATE          = TRY_CONVERT(DATE, NULLIF(JSON_VALUE(@p_payload, N'$.amcExpiryDate'), N''));
    DECLARE @asset_remarks          NVARCHAR(MAX) = JSON_VALUE(@p_payload, N'$.remarks');
    DECLARE @asset_status_id        INT           = TRY_CONVERT(INT, NULLIF(JSON_VALUE(@p_payload, N'$.statusId'), N''));
    DECLARE @asset_status_name      NVARCHAR(80)  = COALESCE(NULLIF(JSON_VALUE(@p_payload, N'$.status'), N''), N'Active');

    -- The generic 7-parameter shim signature has no @p_organization_id;
    -- callers thread the organization through the payload, and that is
    -- what the monolith reads too.

    -- Same validation the monolith applies, plus the two new masters.
    IF @asset_org_id IS NULL OR @asset_org_id <= 0
        THROW 52723, 'Organization is required.', 1;
    IF @asset_name IS NULL
        THROW 52724, 'Asset name is required.', 1;
    IF @asset_category_id IS NULL
        OR NOT EXISTS (SELECT 1 FROM grac_practice.dependency_asset_category_master
                        WHERE asset_category_id = @asset_category_id AND is_active = 1)
        THROW 52725, 'A valid Asset Category is required.', 1;

    -- The new columns are nullable. When supplied they must belong to
    -- the taxonomy chain, so a Firewall cannot end up under Vehicles.
    IF @asset_subcategory_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.dependency_asset_subcategory_master
         WHERE subcategory_id    = @asset_subcategory_id
           AND asset_category_id = @asset_category_id
           AND is_active         = 1)
        THROW 52726, 'The chosen Sub Category does not belong to the chosen Category.', 1;

    IF @asset_type_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.dependency_asset_type_master t
         JOIN  grac_practice.dependency_asset_subcategory_master s
               ON s.subcategory_id = t.subcategory_id
         WHERE t.asset_type_id      = @asset_type_id
           AND s.subcategory_id     = COALESCE(@asset_subcategory_id, s.subcategory_id)
           AND s.asset_category_id  = @asset_category_id
           AND t.is_active          = 1
           AND s.is_active          = 1)
        THROW 52727, 'The chosen Asset Type does not belong to the chosen Sub Category.', 1;

    IF @asset_status_id IS NULL SET @asset_status_id = @active_record_status_id;

    IF @p_id IS NULL OR @p_id = 0
    BEGIN
        INSERT grac_practice.organization_dependency_asset
            (organization_id, asset_name, asset_category_id, asset_subcategory_id, asset_type_id,
             owner_id, location_id, purchase_dt, warranty_expiry_dt, amc_expiry_dt,
             criticality_id, remarks, status, record_status_id, entered_by)
        VALUES
            (@asset_org_id, @asset_name, @asset_category_id, @asset_subcategory_id, @asset_type_id,
             @asset_owner_id, @asset_location_id, @purchase_dt, @warranty_expiry_dt, @amc_expiry_dt,
             @asset_criticality_id, @asset_remarks, @asset_status_name, @asset_status_id, @p_usr_id);

        SET @p_id = SCOPE_IDENTITY();

        SELECT CAST(1 AS BIT) AS Success, N'Asset created.' AS Message, @p_id AS SavedId;
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_dependency_asset
           SET organization_id       = @asset_org_id,
               asset_name            = @asset_name,
               asset_category_id     = @asset_category_id,
               asset_subcategory_id  = @asset_subcategory_id,
               asset_type_id         = @asset_type_id,
               owner_id              = @asset_owner_id,
               location_id           = @asset_location_id,
               purchase_dt           = @purchase_dt,
               warranty_expiry_dt    = @warranty_expiry_dt,
               amc_expiry_dt         = @amc_expiry_dt,
               criticality_id        = @asset_criticality_id,
               remarks               = @asset_remarks,
               status                = @asset_status_name,
               record_status_id      = @asset_status_id,
               updated_by            = @p_usr_id,
               updated_dt            = SYSUTCDATETIME()
         WHERE asset_id = @p_id;

        SELECT CAST(1 AS BIT) AS Success, N'Asset updated.' AS Message, @p_id AS SavedId;
    END
END
GO
PRINT '241: sp_org_dependency_assets_repository_manage ready.';
GO

-- =====================================================================
-- 2. Lookup proc -- returns categories, subcategories and asset types
--    as one 4-column result the loadLookups pattern can absorb.
--
-- The 4th column carries the parent id (category id for subcategories,
-- subcategory id for asset types), matching how practice.js already
-- reads a parent-scoped value from lookup rows.
-- =====================================================================
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
PRINT '241: sp_get_asset_taxonomy_lookup ready.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 241 verification ===';

SELECT 'save shim present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_dependency_assets_repository_manage','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'lookup proc present',
       CASE WHEN OBJECT_ID('grac_practice.sp_get_asset_taxonomy_lookup','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;

-- Row counts by entity, to prove the seed reached the lookup.
PRINT '';
PRINT '=== Lookup row counts by entity ===';
EXEC grac_practice.sp_get_asset_taxonomy_lookup;

PRINT '';
PRINT '241 complete. Rebuild PracticeManagement.Api and PracticeManagement.Web with it.';
GO

SET NOEXEC OFF;
GO
