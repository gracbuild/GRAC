-- =====================================================================
-- tool_menu_restore_from_uat.sql  (2026-11-12)
--
-- Restores grac_practice.menu_master in grac_newphase from
-- grac_newphase_uat. Both databases must be on the same SQL Server.
--
-- MATCHED BY menu_key, NOT BY menu_id OR menu_name
--   * menu_id differs between the two databases, so it cannot be used.
--   * menu_name repeats ("Dashboard" exists under several modules), so it
--     cannot identify a row either.
--   * menu_key is UNIQUE (uq_pm_menu_key) and is the same in both.
--
-- WHAT IT CHANGES (target only; the UAT database is only read)
--   1. Backup first: grac_practice.menu_master_bak_<yyyymmdd_hhmmss>.
--   2. Every target row whose menu_key exists in UAT gets UAT's name, url,
--      display order, icon, module type, status and show_in_sidebar.
--      The row is UPDATED IN PLACE, so its menu_id -- and therefore every
--      role's menu permission -- is kept.
--   3. Keys in UAT but not in the target are inserted.
--   4. Parents are re-linked: the target parent is the target row whose
--      menu_key equals the UAT parent's menu_key.
--   5. Keys in the target but not in UAT are only LISTED (e.g. menus added
--      after UAT was copied, such as risk-methodology from 532). Set
--      @DeactivateExtra = 1 to make them Inactive instead. Nothing is
--      deleted.
--   6. Inserted menus get no permissions unless @GrantInsertedToAllRoles = 1
--      (full rights to every active role -- 274 Section 3's rule).
--
-- RUN
--   * @DryRun = 1 (default): shows what would change, changes nothing.
--   * Check the three result sets, then set @DryRun = 0 and run again.
--   * Users must sign out and back in afterwards: menu permissions are
--     read at sign-in.
--
-- UNDO
--   The backup table holds the previous rows. To restore them, update
--   menu_master from it by menu_id.
--
-- ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @SourceDb                SYSNAME = N'grac_newphase_uat';   -- read from
DECLARE @TargetDb                SYSNAME = N'grac_newphase';       -- restored
DECLARE @DryRun                  BIT     = 1;
DECLARE @DeactivateExtra         BIT     = 0;
DECLARE @GrantInsertedToAllRoles BIT     = 0;

IF DB_ID(@SourceDb) IS NULL OR DB_ID(@TargetDb) IS NULL
BEGIN
    RAISERROR('Source or target database not found on this server.', 16, 1);
    RETURN;
END

DECLARE @src NVARCHAR(300) = QUOTENAME(@SourceDb) + N'.grac_practice.menu_master';
DECLARE @dst NVARCHAR(300) = QUOTENAME(@TargetDb) + N'.grac_practice.menu_master';
DECLARE @perm NVARCHAR(300) = QUOTENAME(@TargetDb) + N'.grac_practice.organization_role_menu_permission';
DECLARE @role NVARCHAR(300) = QUOTENAME(@TargetDb) + N'.grac_practice.organization_role';
DECLARE @org  NVARCHAR(300) = QUOTENAME(@TargetDb) + N'.grac_practice.organization';
DECLARE @rsm  NVARCHAR(300) = QUOTENAME(@TargetDb) + N'.grac_practice.record_status_master';

-- show_in_sidebar is a later column; copy it only when both sides have it.
DECLARE @sidebar BIT =
    CASE WHEN COL_LENGTH(@src, 'show_in_sidebar') IS NOT NULL
          AND COL_LENGTH(@dst, 'show_in_sidebar') IS NOT NULL THEN 1 ELSE 0 END;

DECLARE @sql NVARCHAR(MAX);

-- ---------------------------------------------------------------------
-- Preview (always shown)
-- ---------------------------------------------------------------------
SET @sql = N'
SELECT N''1. Will be UPDATED (differs from UAT)'' AS Section_,
       d.menu_id AS TargetMenuId, d.menu_key AS MenuKey,
       d.menu_name AS TargetName, s.menu_name AS UatName,
       d.menu_url AS TargetUrl, s.menu_url AS UatUrl,
       dp.menu_key AS TargetParentKey, sp.menu_key AS UatParentKey,
       d.display_order AS TargetOrder, s.display_order AS UatOrder,
       d.status AS TargetStatus, s.status AS UatStatus
  FROM ' + @dst + N' d
  JOIN ' + @src + N' s  ON s.menu_key = d.menu_key
  LEFT JOIN ' + @dst + N' dp ON dp.menu_id = d.parent_menu_id
  LEFT JOIN ' + @src + N' sp ON sp.menu_id = s.parent_menu_id
 WHERE ISNULL(d.menu_name, N'''')   <> ISNULL(s.menu_name, N'''')
    OR ISNULL(d.menu_url, N'''')    <> ISNULL(s.menu_url, N'''')
    OR ISNULL(d.display_order, -1)  <> ISNULL(s.display_order, -1)
    OR ISNULL(d.icon_class, N'''')  <> ISNULL(s.icon_class, N'''')
    OR ISNULL(d.module_type, N'''') <> ISNULL(s.module_type, N'''')
    OR ISNULL(d.status, N'''')      <> ISNULL(s.status, N'''')
    OR ISNULL(dp.menu_key, N'''')   <> ISNULL(sp.menu_key, N'''')'
    + CASE WHEN @sidebar = 1 THEN N'
    OR ISNULL(d.show_in_sidebar, 1) <> ISNULL(s.show_in_sidebar, 1)' ELSE N'' END + N'
 ORDER BY d.menu_key;

SELECT N''2. Will be INSERTED (in UAT, not in target)'' AS Section_,
       s.menu_key AS MenuKey, s.menu_name AS UatName, s.menu_url AS UatUrl,
       sp.menu_key AS UatParentKey, s.status AS UatStatus
  FROM ' + @src + N' s
  LEFT JOIN ' + @src + N' sp ON sp.menu_id = s.parent_menu_id
 WHERE NOT EXISTS (SELECT 1 FROM ' + @dst + N' d WHERE d.menu_key = s.menu_key)
 ORDER BY s.menu_key;

SELECT N''3. Only in target (listed' + CASE WHEN @DeactivateExtra = 1 THEN N', will be set Inactive' ELSE N', left as they are' END + N')'' AS Section_,
       d.menu_id AS TargetMenuId, d.menu_key AS MenuKey, d.menu_name AS TargetName, d.status AS TargetStatus
  FROM ' + @dst + N' d
 WHERE NOT EXISTS (SELECT 1 FROM ' + @src + N' s WHERE s.menu_key = d.menu_key)
 ORDER BY d.menu_key;';
EXEC sys.sp_executesql @sql;

IF @DryRun = 1
BEGIN
    PRINT 'DRY RUN: nothing was changed. Check the three result sets, then set @DryRun = 0 and run again.';
    RETURN;
END

-- ---------------------------------------------------------------------
-- Backup
-- ---------------------------------------------------------------------
DECLARE @bak NVARCHAR(300) = QUOTENAME(@TargetDb) + N'.grac_practice.'
    + QUOTENAME(N'menu_master_bak_' + FORMAT(SYSDATETIME(), 'yyyyMMdd_HHmmss'));
SET @sql = N'SELECT * INTO ' + @bak + N' FROM ' + @dst + N';';
EXEC sys.sp_executesql @sql;
PRINT 'Backup written to ' + @bak;

-- ---------------------------------------------------------------------
-- Restore
-- ---------------------------------------------------------------------
SET @sql = N'
BEGIN TRAN;

-- 2. Matching keys: UAT values, in place (menu_id and permissions kept).
UPDATE d
   SET d.menu_name     = s.menu_name,
       d.menu_url      = s.menu_url,
       d.display_order = s.display_order,
       d.icon_class    = s.icon_class,
       d.module_type   = s.module_type,
       d.status        = s.status,'
    + CASE WHEN @sidebar = 1 THEN N'
       d.show_in_sidebar = s.show_in_sidebar,' ELSE N'' END + N'
       d.updated_by    = N''menu-restore-uat'',
       d.updated_dt    = SYSUTCDATETIME()
  FROM ' + @dst + N' d
  JOIN ' + @src + N' s ON s.menu_key = d.menu_key;
PRINT ''Rows updated: '' + CAST(@@ROWCOUNT AS NVARCHAR(20));

-- 3. Keys missing in the target (parent linked in step 4).
INSERT ' + @dst + N'
       (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status,'
    + CASE WHEN @sidebar = 1 THEN N' show_in_sidebar,' ELSE N'' END + N' entered_by, entered_dt)
SELECT s.menu_key, s.menu_name, s.menu_url, NULL, s.display_order, s.icon_class, s.module_type, s.status,'
    + CASE WHEN @sidebar = 1 THEN N' s.show_in_sidebar,' ELSE N'' END + N' N''menu-restore-uat'', SYSUTCDATETIME()
  FROM ' + @src + N' s
 WHERE NOT EXISTS (SELECT 1 FROM ' + @dst + N' d WHERE d.menu_key = s.menu_key);
PRINT ''Rows inserted: '' + CAST(@@ROWCOUNT AS NVARCHAR(20));

-- 4. Parents, by the parent''s menu_key.
UPDATE d
   SET d.parent_menu_id = dp.menu_id
  FROM ' + @dst + N' d
  JOIN ' + @src + N' s  ON s.menu_key = d.menu_key
  LEFT JOIN ' + @src + N' sp ON sp.menu_id = s.parent_menu_id
  LEFT JOIN ' + @dst + N' dp ON dp.menu_key = sp.menu_key
 WHERE ISNULL(d.parent_menu_id, -1) <> ISNULL(dp.menu_id, -1);
PRINT ''Parents re-linked: '' + CAST(@@ROWCOUNT AS NVARCHAR(20));
'
    + CASE WHEN @DeactivateExtra = 1 THEN N'
-- 5. Keys that are not in UAT: Inactive (not deleted).
UPDATE d
   SET d.status = N''Inactive'', d.updated_by = N''menu-restore-uat'', d.updated_dt = SYSUTCDATETIME()
  FROM ' + @dst + N' d
 WHERE NOT EXISTS (SELECT 1 FROM ' + @src + N' s WHERE s.menu_key = d.menu_key)
   AND d.status <> N''Inactive'';
PRINT ''Target-only rows set Inactive: '' + CAST(@@ROWCOUNT AS NVARCHAR(20));
' ELSE N'' END
    + CASE WHEN @GrantInsertedToAllRoles = 1 THEN N'
-- 6. Inserted menus: full rights to every active role.
DECLARE @active_rs INT = (SELECT TOP 1 record_status_id FROM ' + @rsm + N'
                           WHERE status_code = N''Active'' OR status_name = N''Active'' ORDER BY record_status_id);
INSERT ' + @perm + N'
       (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 1, 1, N''Active'', ISNULL(@active_rs, 1), N''menu-restore-uat'', SYSUTCDATETIME()
  FROM ' + @role + N' r
  JOIN ' + @org + N' o ON o.organization_id = r.organization_id
  JOIN ' + @dst + N' m ON m.entered_by = N''menu-restore-uat''
 WHERE o.status = N''Active'' AND r.status = N''Active''
   AND NOT EXISTS (SELECT 1 FROM ' + @perm + N' p WHERE p.role_id = r.role_id AND p.menu_id = m.menu_id);
PRINT ''Permission rows added for inserted menus: '' + CAST(@@ROWCOUNT AS NVARCHAR(20));
' ELSE N'' END + N'
COMMIT;';
EXEC sys.sp_executesql @sql;

-- ---------------------------------------------------------------------
-- Check: no difference left for matching keys.
-- ---------------------------------------------------------------------
SET @sql = N'
SELECT N''Rows still different from UAT (expect 0)'' AS Check_, COUNT(*) AS Result_
  FROM ' + @dst + N' d
  JOIN ' + @src + N' s  ON s.menu_key = d.menu_key
  LEFT JOIN ' + @dst + N' dp ON dp.menu_id = d.parent_menu_id
  LEFT JOIN ' + @src + N' sp ON sp.menu_id = s.parent_menu_id
 WHERE ISNULL(d.menu_name, N'''') <> ISNULL(s.menu_name, N'''')
    OR ISNULL(d.menu_url, N'''')  <> ISNULL(s.menu_url, N'''')
    OR ISNULL(d.status, N'''')    <> ISNULL(s.status, N'''')
    OR ISNULL(dp.menu_key, N'''') <> ISNULL(sp.menu_key, N'''');';
EXEC sys.sp_executesql @sql;
PRINT 'Menu restore complete. Users must sign out and back in.';
