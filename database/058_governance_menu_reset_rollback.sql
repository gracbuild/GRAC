-- =====================================================================
-- 058 Governance menu reset -- ROLLBACK
--
-- Restores the pre-058 Governance sidebar shape. Because 058 is
-- idempotent and mostly reasserts the 056 layout, rollback here just
-- reactivates any deactivated legacy row and removes the admin stub
-- inserted by 058. It does NOT undo migration 056 (use
-- 056_menu_repository_vs_source_statements_rollback.sql for that).
--
-- ASCII-only. Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

-- Reactivate any menu rows 058 forcibly Inactivated by name sweep.
UPDATE grac_practice.menu_master
   SET status     = N'Active',
       updated_by = 'rollback-058',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_name IN (N'Organization Controls', N'Organization Control')
   AND status    = N'Inactive'
   AND updated_by = 'seed-058';

-- Remove the admin stub row 058 inserted (only if 058 was the one that
-- inserted it -- entered_by = 'seed-058').
DELETE FROM grac_practice.menu_master
WHERE menu_key   = N'repository-subscriptions'
  AND entered_by = 'seed-058';

COMMIT TRAN;

SELECT menu_key, menu_name, menu_url, display_order, module_type, status
FROM grac_practice.menu_master
WHERE menu_key IN (N'organization-controls', N'source-statements', N'repository-subscriptions')
ORDER BY status DESC, display_order;

PRINT '058 rollback complete.';
GO
