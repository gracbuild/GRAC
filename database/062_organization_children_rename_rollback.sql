-- =====================================================================
-- 062 Organization children rename -- ROLLBACK
--
-- Restores the pre-062 menu names. Only rows whose updated_by = 'seed-062'
-- are touched, so any manual rename after 062 is preserved.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

UPDATE grac_practice.menu_master
   SET menu_name  = N'Organization Administration',
       updated_by = 'rollback-062',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key  = N'organization-administration'
   AND updated_by = 'seed-062';

UPDATE grac_practice.menu_master
   SET menu_name  = N'Organization Dependencies',
       updated_by = 'rollback-062',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key  = N'organization-dependencies'
   AND updated_by = 'seed-062';

COMMIT TRAN;

SELECT menu_key, menu_name, menu_url, status, updated_by, updated_dt
FROM grac_practice.menu_master
WHERE menu_key IN (N'organization-administration', N'organization-dependencies');

PRINT '062 rollback complete.';
GO
