/*
  =====================================================================
  Asset Category Assurance -- end-to-end check

  Run this AFTER:
      ControlManagement\database\042_asset_event_types_activate.sql
      PracticeManagement\database\138_asset_category_assurance_menu_seed.sql

  It walks the chain in the order it actually resolves. The FIRST step
  that comes back empty is the cause; everything after it is noise.

      1. Did 138 run?            menu + feature flag
      2. Did 042 run?            admin ASSET event types, Active, gerund
      3. Categories to configure
      4. Admin authored an asset obligation?
      5. Is this organization subscribed to the release carrying it?
      6. What the view returns   <- the screen shows exactly this
      7. What the screen's proc returns
      8. Custom checklists saved so far

  Set @org before running.
  =====================================================================
*/
SET NOCOUNT ON;

DECLARE @org BIGINT = 4;   -- <<< change me

PRINT '=== 1. Screen registered? (138) ===============================';
SELECT m.menu_key, m.menu_name, m.menu_url, p.menu_key AS ParentKey, m.status
FROM   grac_practice.menu_master m
LEFT   JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
WHERE  m.menu_key = N'asset-category-assurance';
-- 0 rows => 138 never ran.

SELECT fm.feature_code, fm.is_active, fm.default_enabled,
       grac_practice.fn_pm_feature_enabled(@org, fm.feature_code) AS EffectiveEnabledForOrg
FROM   grac_practice.feature_flag_master fm
WHERE  fm.feature_code = N'screen.asset-category-assurance';
-- EffectiveEnabledForOrg = 0 => the screen renders "not yet enabled".

PRINT '=== 2. Admin ASSET event types (042) ==========================';
SELECT c.event_code AS EventCode, c.event_name AS EventName,
       p.event_code AS ParentCode, p.status AS ParentStatus, c.status AS Status
FROM   GRAC_New.event_type_master c
LEFT   JOIN GRAC_New.event_type_master p ON p.event_type_id = c.parent_event_type_id
WHERE  c.event_code LIKE N'ASSET%'
ORDER  BY c.display_order;
/*
  MUST show ASSET_COMMISSIONING and ASSET_DECOMMISSIONING, both Active,
  with ParentStatus Active too.

  Still seeing ASSET_COMMISSIONED / ASSET_DECOMMISSIONED (past tense)?
  042 has not run. The screen will list nothing, because the view joins
  admin on event_code and the practice side uses the gerund form.
*/

PRINT '=== 3. Asset categories available to configure ================';
SELECT asset_category_id AS AssetCategoryId, asset_category_code AS Code,
       asset_category_name AS Name, is_active AS IsActive
FROM   grac_practice.dependency_asset_category_master
ORDER  BY display_order;
-- 002 seeds 8. If empty, the category dropdown will be empty.

PRINT '=== 4. Did anyone author an asset obligation in Admin? ========';
SELECT o.obligation_id      AS ObligationId,
       o.obligation_code    AS ObligationCode,
       et.event_code        AS EventCode,
       spec.trigger_mode    AS TriggerMode,
       spec.status          AS SpecStatus
FROM   GRAC_New.obligation_assurance_spec spec
JOIN   GRAC_New.requirement_obligation o  ON o.obligation_id = spec.obligation_id
JOIN   GRAC_New.event_type_master et      ON et.event_type_id = spec.event_type_id
WHERE  spec.trigger_mode = N'EventDriven'
  AND  et.event_code LIKE N'ASSET%';
/*
  0 rows is the most common reason the screen is empty and NOT a bug.
  Nobody has yet created an obligation whose assurance is event driven
  on an asset event. Do that in GRAC-ADMIN first:
      Obligation -> Assurance -> Trigger Mode = Event Driven
                              -> Event Type   = Asset / Commissioning
  then publish it in a release.
*/

PRINT '=== 5. Is this organization subscribed to that release? =======';
SELECT s.subscription_id, s.release_id, s.status
FROM   grac_practice.repository_subscription s
WHERE  s.organization_id = @org
ORDER  BY s.release_id;
-- The obligation only counts if it rides a release this org subscribes to.

PRINT '=== 6. What the view returns for this organization ============';
SELECT event_type_code AS EventCode, COUNT(*) AS ObligationCount,
       SUM(CAST(is_subscribed AS INT)) AS SubscribedCount
FROM   grac_practice.vw_pm_event_driven_obligation
WHERE  organization_id = @org
GROUP  BY event_type_code
ORDER  BY event_type_code;
/*
  This is the screen's source of truth.
    * PEOPLE_* rows but no ASSET_* rows  -> step 2 or step 4 is the cause.
    * ASSET_* present but SubscribedCount = 0 -> step 5; the screen hides
      unsubscribed obligations unless "include unsubscribed" is on.
*/

PRINT '=== 7. Exactly what the screen calls ==========================';
DECLARE @cat INT = (SELECT TOP 1 asset_category_id
                    FROM grac_practice.dependency_asset_category_master
                    WHERE is_active = 1 ORDER BY display_order);

PRINT '--- Commissioning ---';
EXEC grac_practice.sp_event_obligation_mapping_list
     @organization_id         = @org,
     @event_type_code         = N'ASSET_COMMISSIONING',
     @scope_dimension         = N'ASSET_CATEGORY',
     @scope_asset_category_id = @cat;

PRINT '--- Decommissioning ---';
EXEC grac_practice.sp_event_obligation_mapping_list
     @organization_id         = @org,
     @event_type_code         = N'ASSET_DECOMMISSIONING',
     @scope_dimension         = N'ASSET_CATEGORY',
     @scope_asset_category_id = @cat;

PRINT '=== 8. Custom checklists saved against asset categories =======';
SELECT c.checklist_id, c.event_type_code AS EventCode,
       c.scope_asset_category_id AS AssetCategoryId,
       cat.asset_category_name   AS CategoryName,
       c.is_scope_managed        AS ScopeManaged
FROM   grac_practice.checklist c
LEFT   JOIN grac_practice.dependency_asset_category_master cat
       ON cat.asset_category_id = c.scope_asset_category_id
WHERE  c.organization_id = @org
  AND  c.scope_dimension = N'ASSET_CATEGORY'
ORDER  BY c.event_type_code, c.scope_asset_category_id;
-- Empty until you add a checklist on the screen. Not an error.

/*
  =====================================================================
  READING THE RESULT

  Step 1 empty  -> run 138.
  Step 2 wrong  -> run 042 (ControlManagement).
  Step 4 empty  -> nothing to show. Author an asset obligation in Admin.
                   This is configuration, not a defect.
  Step 6 empty while 4 has rows -> the release is not subscribed (step 5),
                   or the obligation's requirement is not Active for this
                   organization.
  Steps 1-6 fine but the page is blank -> front end. Check devtools:
      * GET .../practice-management-gateway/lookups?organizationId=<org>
        must return rows with LookupKey = 'asset-categories'.
      * GET .../api/practice/workflow/scope/obligation-mappings...
        a 400 usually means a query parameter went out as "undefined".
      * Views/Practice/Manage.cshtml must contain "asset-category-assurance"
        in workflowScreens, and the Web project must have been rebuilt.
  =====================================================================
*/
