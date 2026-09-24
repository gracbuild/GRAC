-- =====================================================================
-- 274 menu_master snapshot + full permissions -- ROLLBACK
--
-- Removes what 274 CREATED:
--   1. organization_role_menu_permission rows it inserted
--      (entered_by = 'seed-274'), plus every permission row pointing at a
--      menu 274 created -- otherwise the menu delete would fail on the FK.
--   2. menu_master rows it inserted (entered_by = 'seed-274'), after
--      clearing parent_menu_id on any child that points at one of them.
--
-- WHAT CANNOT BE RESTORED, AND WHY
--   274 is a snapshot applied with UPDATE, so two of its effects have no
--   "before" recorded anywhere:
--
--   a) Menu rows that ALREADY existed and were brought in line with the
--      sheet (updated_by = 'seed-274'). Their previous menu_name, url,
--      display_order, icon, module_type, status and parent are gone. This
--      script leaves them at the snapshot values and lists them at the
--      end so you can see exactly which rows are affected.
--
--   b) Permission rows that already existed and were RAISED to full
--      rights by section 3b (updated_by = 'seed-274'). Their previous
--      flag combination is gone. If the intent is to put the read-only
--      roles back, re-seed them deliberately: deployment/03 grants
--      'Viewer' can_view only, and 273 does the same for MSP.
--
--   If either matters, restore from the backup taken before 274 rather
--   than from this script.
--
-- Re-runnable: yes. A second run finds nothing to delete.
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (274 rollback): schema or menu_master missing -- nothing to do.';
    SET NOEXEC ON;
END
GO

BEGIN TRANSACTION;

-- ---------------------------------------------------------------------
-- 1. Detach children of the menus this script created, so the delete in
--    step 3 cannot fail on the self-referencing FK. A child that 274 did
--    NOT create keeps its own row and simply becomes a root.
-- ---------------------------------------------------------------------
UPDATE child
SET    parent_menu_id = NULL,
       updated_by     = N'rollback-274',
       updated_dt     = SYSUTCDATETIME()
FROM   grac_practice.menu_master child
JOIN   grac_practice.menu_master parent ON parent.menu_id = child.parent_menu_id
WHERE  parent.entered_by = N'seed-274';

PRINT '274 rollback: child menus detached = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

-- ---------------------------------------------------------------------
-- 2. Permission rows.
--    2a: every row pointing at a menu 274 created -- whoever inserted it.
--    2b: rows 274 itself inserted against menus that survive.
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
BEGIN
    DELETE p
    FROM   grac_practice.organization_role_menu_permission p
    JOIN   grac_practice.menu_master m ON m.menu_id = p.menu_id
    WHERE  m.entered_by = N'seed-274';

    PRINT '274 rollback: permission rows on removed menus deleted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

    DELETE FROM grac_practice.organization_role_menu_permission
    WHERE entered_by = N'seed-274';

    PRINT '274 rollback: permission rows inserted by 274 deleted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

-- ---------------------------------------------------------------------
-- 3. The menu rows 274 created.
-- ---------------------------------------------------------------------
DELETE FROM grac_practice.menu_master
WHERE entered_by = N'seed-274';

PRINT '274 rollback: menu rows deleted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

COMMIT TRANSACTION;
GO

-- =====================================================================
-- VERIFICATION -- and the honest list of what stays changed
-- =====================================================================
SELECT 'Menu rows created by 274 still present' AS Check_,
       COUNT(*) AS Count_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS Result_
FROM grac_practice.menu_master WHERE entered_by = N'seed-274';

SELECT 'Permission rows created by 274 still present' AS Check_,
       COUNT(*) AS Count_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS Result_
FROM grac_practice.organization_role_menu_permission WHERE entered_by = N'seed-274';

SELECT 'Pre-existing menu rows left at snapshot values (not restorable here)' AS Check_,
       menu_key AS MenuKey_, menu_name AS MenuName_, status AS Status_
FROM grac_practice.menu_master
WHERE updated_by = N'seed-274'
ORDER BY menu_key;

SELECT 'Pre-existing permission rows left at full rights (not restorable here)' AS Check_,
       COUNT(*) AS Count_
FROM grac_practice.organization_role_menu_permission
WHERE updated_by = N'seed-274';

PRINT '274 rollback complete.';
GO

SET NOEXEC OFF;
GO
