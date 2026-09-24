-- =====================================================================
-- 288 ROLLBACK -- bring the Practice Instances screen back
--
-- Sets the menu row Active again. Nothing else has to be undone: 288
-- hid a row, it did not delete one, so the menu_id and every permission
-- grant were never lost and are still attached.
--
-- WHEN YOU ACTUALLY NEED THIS
--   Not for cosmetic regret. The screen's only remaining behavioural
--   difference is that its list has NO owner predicate, so it shows
--   employee-scoped users every instance in the organisation, which
--   sp_resolve_instance_list deliberately does not. If an
--   employee-scoped role turns out to need that view, this rollback
--   restores it -- but the better fix is a permission, because bringing
--   the whole screen back also brings back an edit form whose every
--   field is owned somewhere else.
--
--   Roll this back BEFORE 287 if you are unwinding both: 287 owns the
--   restore procedure and the drill-down filters, and with 288 already
--   rolled back the old screen can reach retired instances through its
--   own status filter in the meantime.
--
-- ALSO EDIT: 274_menu_master_seed.sql if this rollback is meant to
--            stick -- that snapshot MERGEs with UPDATE and will re-apply
--            whichever status it carries on its next run.
--
-- Re-runnable: yes.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (288 rollback): grac_practice.menu_master missing.';
    RAISERROR('288 rollback: menu_master missing.', 16, 1);
END
GO

UPDATE grac_practice.menu_master
   SET status     = N'Active',
       updated_by = N'rollback-288',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'practice-instances'
   AND status <> N'Active';

PRINT '288 rollback: Practice Instances menu restored = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

SELECT '288 rollback: Practice Instances is visible' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'practice-instances' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- The grants were never dropped, so nothing needs rebuilding. This
-- reports the count so that is visible rather than assumed.
SELECT '288 rollback: permission grants intact' AS Check_,
       CAST((SELECT COUNT(*)
               FROM grac_practice.organization_role_menu_permission p
               JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
              WHERE m.menu_key = N'practice-instances') AS NVARCHAR(20))
       + ' grant(s) still attached' AS Result;

PRINT '288 rollback complete.';
PRINT '     REMEMBER: 274_menu_master_seed.sql decides the status on its next run.';
GO
