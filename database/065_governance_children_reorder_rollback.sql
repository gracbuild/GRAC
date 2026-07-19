-- =====================================================================
-- 065 Governance sidebar reorder + Practices label refresh -- ROLLBACK
--
-- Restores the pre-065 state for the five Governance children:
--   organization-requirements menu_name -> 'Practices'  (was 051's label)
--   All five display_order values are left as 065 set them because 061
--   already put resolve at 120 and the rest were unchanged; there is no
--   earlier "correct" order to walk back to. If you need to undo the
--   entire chain, run rollbacks for 061 / 052 / 051 instead.
--
-- Only rows whose updated_by = 'seed-065' are touched.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

UPDATE grac_practice.menu_master
   SET menu_name  = N'Practices',
       updated_by = 'rollback-065',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key  = N'organization-requirements'
   AND updated_by = 'seed-065';

COMMIT TRAN;

SELECT menu_key, menu_name, menu_url, status, updated_by, updated_dt
FROM grac_practice.menu_master
WHERE menu_key = N'organization-requirements';

PRINT '065 rollback complete.';
GO
