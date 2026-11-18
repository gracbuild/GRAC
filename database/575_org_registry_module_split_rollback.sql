-- =====================================================================
-- 575_org_registry_module_split_rollback.sql
-- Reverses 575: removes 'org-registry-structure' (and its grants) and the
-- grants 575 copied; puts 'org-registry-people' / '-operations' back under
-- the 'Organization' group hidden from the sidebar, and 'org-registry'
-- back to "Organization Structure" (574 state). Re-run 571 from before
-- 575 only if you also roll the Api / Web back. Idempotent. ASCII only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
BEGIN TRAN;
DELETE p FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'org-registry-structure'
    OR (m.menu_key IN (N'org-registry-people', N'org-registry-operations') AND p.entered_by = N'seed-575');
PRINT CONCAT('575 rollback: grants removed: ', @@ROWCOUNT);
DELETE FROM grac_practice.menu_master WHERE menu_key = N'org-registry-structure';
UPDATE c SET parent_menu_id = p.menu_id, updated_by = N'rollback-575', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c JOIN grac_practice.menu_master p ON p.menu_key = N'Organization'
 WHERE c.menu_key IN (N'org-registry-people', N'org-registry-operations');
UPDATE grac_practice.menu_master
   SET display_order = CASE menu_key WHEN N'org-registry-people' THEN 2 ELSE 3 END,
       updated_by = N'rollback-575', updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'org-registry-people', N'org-registry-operations');
UPDATE grac_practice.menu_master SET menu_name = N'Organization Structure', display_order = 1,
       updated_by = N'rollback-575', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-registry';
COMMIT;
GO
IF COL_LENGTH('grac_practice.menu_master','show_in_sidebar') IS NOT NULL
    EXEC sp_executesql N'
        UPDATE grac_practice.menu_master SET show_in_sidebar = 0, updated_by = N''rollback-575'', updated_dt = SYSUTCDATETIME()
         WHERE menu_key IN (N''org-registry-people'', N''org-registry-operations'') AND show_in_sidebar = 1;';
GO
PRINT '575 rollback complete. Sign out and in again.';
GO
