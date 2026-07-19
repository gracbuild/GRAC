-- =====================================================================
-- 064 Top-level sidebar reorder + audit-trace promotion -- ROLLBACK
--
-- Restores the pre-064 top-level order and puts audit-trace back under
-- the nav-administration parent (matches the 051 / 052 layout).
--
-- Only rows whose updated_by = 'seed-064' are touched, so any later
-- manual change is preserved.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

-- Restore nav-* display orders to their 052-seeded values.
UPDATE grac_practice.menu_master
   SET display_order = 100,
       updated_by    = 'rollback-064',
       updated_dt    = SYSUTCDATETIME()
 WHERE menu_key  = N'nav-governance'
   AND updated_by = 'seed-064';

UPDATE grac_practice.menu_master
   SET display_order = 400,
       updated_by    = 'rollback-064',
       updated_dt    = SYSUTCDATETIME()
 WHERE menu_key  = N'nav-oversight'
   AND updated_by = 'seed-064';

UPDATE grac_practice.menu_master
   SET display_order = 450,
       updated_by    = 'rollback-064',
       updated_dt    = SYSUTCDATETIME()
 WHERE menu_key  = N'nav-assurance'
   AND updated_by = 'seed-064';

UPDATE grac_practice.menu_master
   SET display_order = 200,
       updated_by    = 'rollback-064',
       updated_dt    = SYSUTCDATETIME()
 WHERE menu_key  = N'nav-organization'
   AND updated_by = 'seed-064';

-- Put audit-trace back under nav-administration at its 051 display_order (520).
DECLARE @admin_parent_id BIGINT = (
    SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-administration'
);

UPDATE grac_practice.menu_master
   SET parent_menu_id = @admin_parent_id,
       display_order  = 520,
       module_type    = N'Administration',
       updated_by     = 'rollback-064',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key  = N'audit-trace'
   AND updated_by = 'seed-064';

COMMIT TRAN;

SELECT menu_key, menu_name, menu_url, parent_menu_id, display_order, module_type, status
FROM grac_practice.menu_master
WHERE menu_key IN (N'nav-governance', N'nav-oversight', N'nav-assurance',
                   N'nav-organization', N'audit-trace')
ORDER BY display_order;

PRINT '064 rollback complete.';
GO
