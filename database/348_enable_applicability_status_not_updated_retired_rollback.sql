-- =====================================================================
-- 348 Enable "Not Updated" and "Retired" in the Applicability Status
--     lookup -- ROLLBACK
--
-- Sets is_active back to 0 for 'Not Updated' and 'Retired' in
-- applicability_status_master, restoring the state this database was in
-- before 348 ran. Included for symmetry with this repository's migration
-- convention -- running it puts the two choices back to missing from every
-- Applicability Status dropdown, which is the bug 348 exists to fix, so
-- there should be no ordinary reason to run this.
--
-- Re-runnable: yes. A second run makes no changes.
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.applicability_status_master','U') IS NULL
BEGIN
    PRINT 'ABORT (348 rollback): schema or applicability_status_master missing -- nothing to do.';
    SET NOEXEC ON;
END
GO

UPDATE grac_practice.applicability_status_master
   SET is_active = 0,
       updated_by = N'rollback-348',
       updated_dt = SYSUTCDATETIME()
 WHERE status_code IN (N'Not Updated', N'Retired')
   AND is_active <> 0;

PRINT '348 rollback: applicability_status_master rows disabled = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

SELECT status_code AS StatusCode_, status_name AS StatusName_, is_active AS IsActive_
FROM grac_practice.applicability_status_master
ORDER BY display_order;

PRINT '348 rollback complete.';
GO
SET NOEXEC OFF;
GO
