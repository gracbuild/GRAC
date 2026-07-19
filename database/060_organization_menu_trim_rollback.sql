-- =====================================================================
-- 060 Organization sidebar trim -- ROLLBACK
--
-- Reactivates the six sidebar children that 060 hid and restores
-- organization-dependencies to its pre-060 shape (Inactive wrapper as
-- set by 051). Only rows whose updated_by = 'seed-060' are touched.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

UPDATE grac_practice.menu_master
   SET status     = N'Active',
       updated_by = 'rollback-060',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (
        N'organization-metadata',
        N'locations',
        N'departments',
        N'business-functions',
        N'teams',
        N'committees')
   AND updated_by = 'seed-060';

UPDATE grac_practice.menu_master
   SET status         = N'Inactive',
       parent_menu_id = NULL,
       updated_by     = 'rollback-060',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key  = N'organization-dependencies'
   AND updated_by = 'seed-060';

COMMIT TRAN;

SELECT menu_key, menu_name, menu_url, parent_menu_id, display_order, status
FROM grac_practice.menu_master
WHERE menu_key IN (N'organization-metadata', N'locations', N'departments',
                   N'business-functions', N'teams', N'committees',
                   N'organization-dependencies');

PRINT '060 rollback complete.';
GO
