-- =====================================================================
-- 419  Asset tab stabilisation (Settings -> Dependencies -> Assets)
--
-- REQUEST
-- -------
--   Phase 0 of the Asset & Contract Management enhancement
--   (docs/asset-contract-management.md). Before the existing Assets tab
--   is extended, three defects found while tracing it are fixed:
--
--   D-1  Asset row -> "Inactive" failed with "Organization is required."
--        The gateway sends @p_action = 'RETIRE' with an empty payload.
--        241's shim only recognised 'delete' / 'inactive' / 'deactivate',
--        so RETIRE fell through to the SAVE path.
--   D-2  Editing an asset wiped its Sub Category and Asset Type.
--        The monolith list (dbo.pm_get_practice_repository, 404) never
--        returned asset_subcategory_id / asset_type_id, so the Edit form
--        opened with both blank and the shim's UPDATE wrote NULL.
--   D-3  The shim skipped the organization-access check and the Owner /
--        Location / Criticality checks the monolith applies, and used
--        error numbers (52723-52725) the field-error map does not know.
--
-- WHAT THIS DOES
-- --------------
--   1. Re-issues grac_practice.sp_org_dependency_assets_repository_manage:
--        * any action other than SAVE ('' is SAVE) is delegated to
--          dbo.pm_manage_practice_repository -- the same split the users /
--          teams / locations shims use -- so RETIRE runs the monolith's
--          generic retire WITH its organization-access check. The legacy
--          'delete' / 'inactive' / 'deactivate' spellings are mapped to
--          RETIRE first.
--        * SAVE applies the monolith's organization-access rule (51052),
--          its validation and error numbers (51130-51135), plus the
--          taxonomy-chain checks 241 introduced (52726 / 52727), in one
--          transaction, and writes the same practice_audit_trace row the
--          monolith writes.
--        * an UPDATE must target an asset of the same organization; it
--          can no longer move an asset to another organization.
--   2. NEW grac_practice.sp_org_dependency_assets_repository_get -- the
--      monolith's dependency-assets list projection, unchanged column for
--      column, plus AssetSubcategoryId / AssetSubcategory / AssetTypeId /
--      AssetType / LifecycleStatus. practice.js already reads
--      assetSubcategoryId / assetTypeId off the record (parentField
--      cascade), so the Edit form now opens populated.
--
-- NOT CHANGED: the monolith procedures, the vendor path (traced -- save
--   and retire both work), the table, the UI.
-- ALSO EDITED: Api/Services/PracticeRepositoryService.cs
--   (ResolveProcedureAsync routes the dependency-assets QUERY to the new
--   get shim; field-error map gains 52726 / 52727).
-- DEPENDS ON: 239, 241, 404.
-- Rollback: 419_asset_vendor_stabilization_rollback.sql (restores 241's
--   shim body and drops the get shim).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.organization_dependency_asset','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','asset_subcategory_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','asset_type_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','lifecycle_status') IS NULL
   OR OBJECT_ID('dbo.pm_manage_practice_repository','P') IS NULL
   OR OBJECT_ID('grac_practice.dependency_asset_subcategory_master','U') IS NULL
BEGIN
    RAISERROR('ABORT (419): run 123, 239 and 241 first (asset lifecycle / taxonomy columns or monolith missing).', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Save shim
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
PRINT '419: sp_org_dependency_assets_repository_manage re-issued (RETIRE delegated, access + validation aligned).';
GO

-- =====================================================================
-- 2. List shim -- the monolith projection plus the taxonomy columns.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_dependency_assets_repository_get
    @p_entity_type   NVARCHAR(100) = N'',
    @p_action        NVARCHAR(40)  = N'QUERY',
    @p_id            BIGINT        = 0,
    @p_search        NVARCHAR(250) = N'',
    @p_status        NVARCHAR(30)  = N'',
    @p_payload       NVARCHAR(MAX) = N'{}',
    @p_usr_id        NVARCHAR(200) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET @p_payload = ISNULL(NULLIF(@p_payload, N''), N'{}');
    SET @p_search  = ISNULL(@p_search, N'');
    SET @p_status  = ISNULL(@p_status, N'');
    SET @p_id      = ISNULL(@p_id, 0);
    IF ISJSON(@p_payload) <> 1 SET @p_payload = N'{}';

    DECLARE @organization_id BIGINT = TRY_CONVERT(BIGINT, JSON_VALUE(@p_payload, N'$.organizationId'));
    DECLARE @page_number INT = ISNULL(NULLIF(TRY_CONVERT(INT, JSON_VALUE(@p_payload, N'$.pageNumber')), 0), 1);
    DECLARE @page_size   INT = ISNULL(NULLIF(TRY_CONVERT(INT, JSON_VALUE(@p_payload, N'$.pageSize')), 0), 25);
    IF @page_number < 1 SET @page_number = 1;
    IF @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
         WHERE status_code = N'Active' ORDER BY record_status_id);
    DECLARE @filter_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
         WHERE status_code = @p_status OR status_name = @p_status ORDER BY record_status_id);

    -- Organization access -- same rule as the monolith's query path.
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
    IF @organization_id IS NOT NULL AND @is_system_admin = 0
       AND NOT EXISTS (SELECT 1 FROM @allowed_organizations WHERE organization_id = @organization_id)
        THROW 51052, 'You do not have access to the selected organization.', 1;
    IF @organization_id IS NULL AND @is_system_admin = 0
        SET @organization_id = -1;

    SELECT a.asset_id Id, a.organization_id OrganizationId, a.asset_name Name,
           a.asset_category_id AssetCategoryId, ac.asset_category_name AssetCategory,
           a.asset_subcategory_id AssetSubcategoryId, COALESCE(sc.subcategory_name, N'') AssetSubcategory,
           a.asset_type_id AssetTypeId, COALESCE(at.asset_type_name, N'') AssetType,
           a.owner_id OwnerId, COALESCE(o.employee_name, N'') Owner,
           a.location_id LocationId, COALESCE(l.location_name, N'') Location,
           a.purchase_dt PurchaseDate, a.warranty_expiry_dt WarrantyExpiryDate, a.amc_expiry_dt AmcExpiryDate,
           a.criticality_id CriticalityId, COALESCE(cm.criticality_name, N'') Criticality,
           a.lifecycle_status LifecycleStatus,
           a.remarks Remarks, a.record_status_id StatusId, rs.status_name Status,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.organization_dependency_asset a
      JOIN grac_practice.record_status_master rs ON rs.record_status_id = a.record_status_id
      JOIN grac_practice.dependency_asset_category_master ac ON ac.asset_category_id = a.asset_category_id
      LEFT JOIN grac_practice.dependency_asset_subcategory_master sc ON sc.subcategory_id = a.asset_subcategory_id
      LEFT JOIN grac_practice.dependency_asset_type_master at ON at.asset_type_id = a.asset_type_id
      LEFT JOIN grac_practice.organization_employee o ON o.employee_id = a.owner_id
      LEFT JOIN grac_practice.organization_location l ON l.location_id = a.location_id
      LEFT JOIN grac_practice.criticality_master cm ON cm.criticality_id = a.criticality_id
     WHERE (@p_id = 0 OR a.asset_id = @p_id)
       AND (@organization_id IS NULL OR a.organization_id = @organization_id)
       AND (@p_status = N'' OR a.record_status_id = @filter_record_status_id)
       AND (@p_search = N''
            OR a.asset_name LIKE N'%' + @p_search + N'%'
            OR ac.asset_category_name LIKE N'%' + @p_search + N'%'
            OR ISNULL(sc.subcategory_name, N'') LIKE N'%' + @p_search + N'%'
            OR ISNULL(at.asset_type_name, N'') LIKE N'%' + @p_search + N'%'
            OR ISNULL(o.employee_name, N'') LIKE N'%' + @p_search + N'%'
            OR ISNULL(l.location_name, N'') LIKE N'%' + @p_search + N'%')
     ORDER BY a.asset_name
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '419: sp_org_dependency_assets_repository_get created.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '419-a save shim present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_dependency_assets_repository_manage','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '419-b list shim present',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_dependency_assets_repository_get','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '419-c save shim delegates RETIRE to the monolith',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_dependency_assets_repository_manage'))
                 LIKE '%EXEC dbo.pm_manage_practice_repository%' THEN 'PASS' ELSE 'FAIL' END;
GO

-- UAT (run through the UI after deploying the API build):
--   1. Settings -> Dependencies -> Assets: Edit an asset that has a Sub
--      Category and Asset Type -> both are pre-selected; Save -> both kept.
--   2. 3-dot -> Inactive on an asset -> row shows Inactive (no
--      "Organization is required" error).
--   3. Save with an Owner from another organization -> field error on Owner.
--   4. Vendors tab: add / edit / inactive unchanged.

SET NOEXEC OFF;
GO
