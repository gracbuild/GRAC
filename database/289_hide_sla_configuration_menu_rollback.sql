-- =====================================================================
-- 289 ROLLBACK -- bring the SLA Configuration menu back
--
-- Sets the menu row Active again. Nothing else to undo: 289 hid a row,
-- it did not delete one, so the menu_id and every permission grant were
-- never lost.
--
-- WHEN YOU WILL NEED THIS
--   Sooner than with 288, and for a real reason. Nothing supersedes the
--   SLA Configuration screen -- it is the only place that adopts Control
--   Management SLA masters and tunes warning / escalation thresholds and
--   notify roles. Its data is still read by gap SLA matching (184) and
--   Task Centre due dates (195).
--
--   So run this the moment any of the following is true:
--     * a new SLA master is published by Control Management and needs
--       adopting;
--     * a warning or escalation threshold has to change;
--     * notify roles need adding or removing.
--
--   In the meantime the route /Practice/org-sla-config still resolves,
--   so an administrator with the link can reach the screen without this
--   rollback -- that is the escape hatch, not a substitute for it.
--
-- ALSO EDIT: 274_menu_master_seed.sql if this rollback is meant to
--            stick -- that snapshot MERGEs with UPDATE and re-applies
--            whichever status it carries on its next run.
--
-- Re-runnable: yes.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (289 rollback): grac_practice.menu_master missing.';
    RAISERROR('289 rollback: menu_master missing.', 16, 1);
END
GO

UPDATE grac_practice.menu_master
   SET status     = N'Active',
       updated_by = N'rollback-289',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-sla-config'
   AND status <> N'Active';

PRINT '289 rollback: SLA Configuration menu restored = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

SELECT '289 rollback: SLA Configuration is visible' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'org-sla-config' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT '289 rollback: permission grants intact' AS Check_,
       CAST((SELECT COUNT(*)
               FROM grac_practice.organization_role_menu_permission p
               JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
              WHERE m.menu_key = N'org-sla-config') AS NVARCHAR(20))
       + ' grant(s) still attached' AS Result;

PRINT '289 rollback complete.';
PRINT '     REMEMBER: 274_menu_master_seed.sql decides the status on its next run.';
GO
