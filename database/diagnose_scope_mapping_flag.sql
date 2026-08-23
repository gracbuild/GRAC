/*
  Quick diagnosis for: "Scoped Checklist Mapping is not yet enabled for
  this organization" on Practice/Index/workflow-scope-mapping.

  The partial calls __wfCommon.checkFeature(), which hits
  /practice/api/workflow-feature/status -> api/practice/feature-flags/status
  -> grac_practice.fn_pm_feature_enabled(@org, @code).

  fn_pm_feature_enabled resolves in two steps:
      1. per-organization grac_practice.feature_flag row (needs the master
         row to have is_active = 1)
      2. falls back to feature_flag_master.default_enabled

  125 sets default_enabled = 0, so if step 1 finds nothing the answer is 0
  and the screen hides itself. Run this to see which step is failing.
*/
SET NOCOUNT ON;

PRINT '--- 1. Is the master row there at all? (0 rows => 125 never ran) ---';
SELECT feature_flag_id, feature_code, feature_name, default_enabled, is_active, entered_by
FROM   grac_practice.feature_flag_master
WHERE  feature_code IN (N'screen.workflow-scope-mapping', N'screen.workflow-event-inbox');

PRINT '--- 2. Per-organization rows (0 rows => the enable block is missing) ---';
SELECT ff.organization_id, fm.feature_code, ff.is_enabled, ff.notes, ff.entered_by
FROM   grac_practice.feature_flag ff
JOIN   grac_practice.feature_flag_master fm ON fm.feature_flag_id = ff.feature_flag_id
WHERE  fm.feature_code IN (N'screen.workflow-scope-mapping', N'screen.workflow-event-inbox')
ORDER BY ff.organization_id, fm.feature_code;

PRINT '--- 3. What the API will actually return, per org ---';
SELECT o.organization_id,
       o.organization_name AS OrganizationName,
       fm.feature_code     AS FeatureCode,
       grac_practice.fn_pm_feature_enabled(o.organization_id, fm.feature_code) AS EffectiveEnabled
FROM   grac_practice.organization o
CROSS JOIN grac_practice.feature_flag_master fm
WHERE  o.status = N'Active'
  AND  fm.feature_code IN (N'screen.workflow-scope-mapping', N'screen.workflow-event-inbox')
ORDER BY o.organization_id, fm.feature_code;

PRINT '--- 4. Compare against a workflow screen that already works ---';
SELECT o.organization_id, fm.feature_code,
       grac_practice.fn_pm_feature_enabled(o.organization_id, fm.feature_code) AS EffectiveEnabled
FROM   grac_practice.organization o
CROSS JOIN grac_practice.feature_flag_master fm
WHERE  o.status = N'Active'
  AND  fm.feature_code = N'screen.workflow-event-mappings'
ORDER BY o.organization_id;

/*
  ------------------------------------------------------------------
  FIX -- pick one.

  (a) PREFERRED: re-run the corrected migration. It is MERGE-based and
      idempotent, and now includes the per-org enable block.

          sqlcmd -S <server> -d <db> -i database\125_event_scope_menu_seed.sql

  (b) Or enable in place, right now:
  ------------------------------------------------------------------
*/
-- MERGE grac_practice.feature_flag AS target
-- USING (
--     SELECT o.organization_id, fm.feature_flag_id
--     FROM   grac_practice.organization o
--     CROSS JOIN grac_practice.feature_flag_master fm
--     WHERE  o.status = N'Active'
--       AND  fm.feature_code IN (N'screen.workflow-scope-mapping',
--                                N'screen.workflow-event-inbox')
-- ) AS source
-- ON  target.organization_id = source.organization_id
-- AND target.feature_flag_id = source.feature_flag_id
-- WHEN MATCHED THEN UPDATE SET
--     is_enabled = 1, updated_by = 'hotfix', updated_dt = SYSUTCDATETIME()
-- WHEN NOT MATCHED THEN INSERT
--     (organization_id, feature_flag_id, is_enabled, notes, entered_by)
-- VALUES
--     (source.organization_id, source.feature_flag_id, 1, N'Enabled by hotfix', 'hotfix');
-- GO

/*
  If step 1 returned NO ROWS, migration 125 never ran -- run it first;
  the enable block alone cannot help because the master row it references
  does not exist yet.

  If step 3 shows EffectiveEnabled = 1 and the screen still hides, the
  cause is downstream of the flag. Check, in order:
    * browser devtools -> is /practice/api/workflow-feature/status returning
      200 with {"enabled":true}? A 403 means the session's allowed-orgs list
      does not include the selected organizationId.
    * is the menu row present and permitted?  (migration 125 section 3/4)
    * did the Web project actually rebuild? Views/Practice/Manage.cshtml has
      to contain "workflow-scope-mapping" in its workflowScreens set,
      otherwise the generic layout renders instead of the partial.
*/
