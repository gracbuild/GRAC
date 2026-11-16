-- =====================================================================
-- 539 ROLLBACK -- puts Workflow Config, Scoring Config, Triggers and
-- Scope Resolution back under Audit Configuration (status 'Active').
-- Nothing was deleted, so this only flips status. Revert the four 274
-- status values too if the rows should stay visible after a 274 re-run.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
UPDATE grac_practice.menu_master
   SET status     = N'Active',
       updated_by = N'rollback-539',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'org-assurance-workflow-config',
                    N'org-assurance-scoring-config',
                    N'org-assurance-triggers',
                    N'org-assurance-scope-resolution')
   AND status <> N'Active';
PRINT '539 rollback: configuration sub-menus restored = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO
