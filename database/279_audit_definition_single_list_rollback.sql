-- =====================================================================
-- 279 One audit list -- ROLLBACK
--
-- Puts the three standalone list rows back in the sidebar as 276 left
-- them (Active, under Audit Definition, at step orders 10 / 20 / 30).
--
-- Nothing was deleted by 279, so nothing is recreated here -- the rows,
-- their ids and their permission grants were preserved throughout. This
-- only flips status back to 'Active'.
--
-- NOTE: 274_menu_master_seed.sql carries the 279 statuses too. Roll this
-- back and then re-run 274 and the rows are hidden again -- revert 274's
-- three status values as well if the intent is to keep them visible.
--
-- Re-runnable: yes. A second run reports 0 changes.
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (279 rollback): menu_master missing -- nothing to do.';
    SET NOEXEC ON;
END
GO

UPDATE grac_practice.menu_master
   SET status     = N'Active',
       updated_by = N'rollback-279',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'org-assurance-definitions',
                    N'org-assurance-scope-builder',
                    N'org-assurance-question-sets')
   AND status <> N'Active';

PRINT '279 rollback: standalone list menus restored = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

SELECT 'three list menus active again' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.menu_master
                   WHERE menu_key IN (N'org-assurance-definitions',
                                      N'org-assurance-scope-builder',
                                      N'org-assurance-question-sets')
                     AND status = N'Active') = 3
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT m.menu_key AS MenuKey, m.menu_name AS MenuName,
       m.display_order AS Ord, m.status AS Status
  FROM grac_practice.menu_master m
  JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
 WHERE p.menu_key = N'org-audit-definition'
 ORDER BY m.display_order;

PRINT '279 rollback complete.';
GO
SET NOEXEC OFF;
GO
