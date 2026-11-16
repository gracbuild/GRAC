-- =====================================================================
-- 549 ROLLBACK -- puts Audit Configuration back in the sidebar (status
-- 'Active'). Nothing was deleted, so this only flips status. Revert the
-- 274 status value too if the row should stay visible after a 274
-- re-run. The Web mapping (org-audit-configuration -> org-audit-
-- definition) can stay; it only widens who may open the page.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
UPDATE grac_practice.menu_master
   SET status     = N'Active',
       updated_by = N'rollback-549',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-audit-configuration'
   AND status <> N'Active';
PRINT '549 rollback: Audit Configuration restored = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO
