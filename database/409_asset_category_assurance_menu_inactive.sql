-- =====================================================================
-- 409_asset_category_assurance_menu_inactive.sql
--
-- Retires the "Asset Category Assurance" sidebar menu
-- (Practice/Index/asset-category-assurance).
--
-- WHY
--   Asset checklists are now configured on Event Profiles as Asset
--   Profiles (407): Location / Asset Category / Sub Category / Type,
--   with Configure Checklists offering Commissioning / Decommissioning.
--   Obligations ticked there reach the raise automatically, so the
--   category-only screen is no longer needed. "Your own checklists"
--   (custom questions) are intentionally not carried over -- confirmed
--   with sir: obligations are the only checklist source going forward.
--
-- WHAT
--   * grac_practice.menu_master.status -> 'Inactive' for menu_key
--     'asset-category-assurance'. Nothing else: menu_key, url, parent,
--     display_order and role permissions are untouched, so the rollback
--     is a single status flip.
--   * 274_menu_master_seed.sql carries the same status, so a re-run of
--     the snapshot does not switch it back on.
--
-- NOT CHANGED
--   Existing ASSET_CATEGORY decisions in event_obligation_applicability
--   are left exactly as they are and still take part in the asset raise
--   (sp_event_obligation_raise, 343/407). The report at the end lists
--   them per organization so they can be re-created on Asset Profiles
--   and then deactivated.
--
-- Idempotent and re-runnable. ASCII-only.
-- Rollback: 409_asset_category_assurance_menu_inactive_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (409): grac_practice.menu_master is missing.';
    RETURN;
END
GO

UPDATE grac_practice.menu_master
   SET status     = N'Inactive',
       updated_by = 'seed-409',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'asset-category-assurance'
   AND status  <> N'Inactive';
PRINT CONCAT('409: asset-category-assurance menu rows set Inactive: ', @@ROWCOUNT);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '409-a asset-category-assurance menu is Inactive' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'asset-category-assurance')
             AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master
                              WHERE menu_key = N'asset-category-assurance'
                                AND status  <> N'Inactive')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '409-b event-profiles menu still Active',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'event-profiles' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END;
GO

-- Information: Asset Category decisions that still fire on the asset
-- raise. Re-create these on an Asset Profile (Asset Category = the same
-- category), then set them Inactive, so every asset checklist is managed
-- in one place.
IF OBJECT_ID('grac_practice.event_obligation_applicability','U') IS NOT NULL
    SELECT a.organization_id              AS OrganizationId,
           ac.asset_category_name         AS AssetCategory,
           a.event_type_code              AS EventCode,
           COUNT(1)                       AS ActiveDecisions,
           SUM(CASE WHEN a.is_applicable = 1 THEN 1 ELSE 0 END) AS Applicable
    FROM   grac_practice.event_obligation_applicability a
    LEFT JOIN grac_practice.dependency_asset_category_master ac
           ON ac.asset_category_id = a.scope_asset_category_id
    WHERE  a.scope_dimension = N'ASSET_CATEGORY'
      AND  a.status          = N'Active'
    GROUP BY a.organization_id, ac.asset_category_name, a.event_type_code
    ORDER BY a.organization_id, ac.asset_category_name, a.event_type_code;
GO

PRINT 'Migration 409_asset_category_assurance_menu_inactive applied. Users re-login to refresh the sidebar.';
GO
