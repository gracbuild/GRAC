-- =====================================================================
-- 191 rollback -- restore "Resolve" label
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

UPDATE grac_practice.menu_master
   SET menu_name = N'Resolve',
       updated_by = 'rollback-191',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'resolve';

COMMIT TRAN;
GO

SELECT menu_key, menu_name FROM grac_practice.menu_master WHERE menu_key = N'resolve';
PRINT '191 rolled back -- label restored to Resolve.';
GO
