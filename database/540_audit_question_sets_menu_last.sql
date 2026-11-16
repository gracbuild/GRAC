-- =====================================================================
-- 540 Audit menu order -- Question Sets last
--
-- REQUEST (2026-11-13, sir)
--   "Audit Definition, Audit Configuration, Plans, Executions and
--    Observations kazhinjitu question set nte menu itta mathi"
--
-- Under nav-assurance the order becomes (display_order):
--   Dashboard 439, Audit Definition 440, Audit Configuration 450,
--   Audit Plans 466, Executions 469, Observations 470,
--   Question Sets 475   (was 445, between Definition and Configuration)
-- Only org-assurance-question-sets.display_order changes. 274 edited.
-- Re-runnable. Rollback: 540_audit_question_sets_menu_last_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

UPDATE grac_practice.menu_master
   SET display_order = 475,
       updated_by    = N'seed-540',
       updated_dt    = SYSUTCDATETIME()
 WHERE menu_key = N'org-assurance-question-sets'
   AND display_order <> 475;
PRINT '540: Question Sets moved last = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

SELECT m.menu_key AS MenuKey, m.menu_name AS MenuName, m.display_order AS Ord, m.status AS Status
  FROM grac_practice.menu_master m
  JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
 WHERE p.menu_key = N'nav-assurance' AND m.status = N'Active'
 ORDER BY m.display_order;
PRINT '540 complete. Users sign out and back in to see the menu change.';
GO
