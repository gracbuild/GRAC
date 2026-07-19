-- =====================================================================
-- 061 Operations group dissolve -- ROLLBACK
--
-- Restores the pre-061 Operations sidebar state:
--   * resolve back under nav-operations at display_order 330.
--   * dependency-{applications,tools,vendors,assets,processes} back to Active.
--   * nav-operations parent back to Active.
--
-- Only rows whose updated_by = 'seed-061' are touched -- migrations that
-- run afterwards keep their changes.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

DECLARE @ops_parent_id BIGINT = (
    SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-operations'
);

-- Reactivate nav-operations first so the reparented resolve row can land
-- on a valid parent.
UPDATE grac_practice.menu_master
   SET status     = N'Active',
       updated_by = 'rollback-061',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key  = N'nav-operations'
   AND updated_by = 'seed-061';

-- Refresh parent id in case the row was reactivated in this txn.
SET @ops_parent_id = (
    SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-operations'
);

-- Reparent resolve back to Operations.
UPDATE grac_practice.menu_master
   SET parent_menu_id = @ops_parent_id,
       module_type    = N'Operations',
       display_order  = 330,
       status         = N'Active',
       updated_by     = 'rollback-061',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key  = N'resolve'
   AND updated_by = 'seed-061';

-- Reactivate the five dependency sidebar entries.
UPDATE grac_practice.menu_master
   SET status     = N'Active',
       updated_by = 'rollback-061',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (
        N'dependency-applications',
        N'dependency-tools',
        N'dependency-vendors',
        N'dependency-assets',
        N'dependency-processes')
   AND updated_by = 'seed-061';

COMMIT TRAN;

SELECT menu_key, menu_name, menu_url, parent_menu_id, display_order, status
FROM grac_practice.menu_master
WHERE menu_key IN (N'resolve',
                   N'dependency-applications', N'dependency-tools',
                   N'dependency-vendors',      N'dependency-assets',
                   N'dependency-processes',    N'nav-operations');

PRINT '061 rollback complete.';
GO
