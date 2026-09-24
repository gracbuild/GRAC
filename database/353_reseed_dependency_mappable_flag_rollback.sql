-- =====================================================================
-- 353 Re-seed dependency_type_master.is_dependency_mappable -- ROLLBACK
--
-- Sets the five categories back to is_dependency_mappable = 0, i.e.
-- back to the state this environment was actually found in. Does NOT
-- drop the is_dependency_mappable column -- that column belongs to 267,
-- not to this migration, and other procedures (fn_risk_practice_
-- dependencies, sp_risk_mapping_get) depend on it existing regardless
-- of what value the seed holds. Roll back only if re-enabling these
-- categories on Risk Analysis turns out to be undesirable for some
-- reason -- this reintroduces the exact "No dependency categories are
-- configured" symptom 353 was written to fix.
--
-- Re-runnable: yes.
-- ASCII-only on purpose.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF COL_LENGTH('grac_practice.dependency_type_master','is_dependency_mappable') IS NULL
BEGIN
    PRINT 'ABORT (353 rollback): dependency_type_master.is_dependency_mappable missing. Nothing to undo.';
    SET NOEXEC ON;
END
GO

UPDATE grac_practice.dependency_type_master
   SET is_dependency_mappable = 0,
       updated_by = N'reseed-353-rollback',
       updated_dt = SYSUTCDATETIME()
 WHERE is_dependency_mappable = 1
   AND dependency_type_name IN (N'Asset', N'Vendor', N'Person', N'Team', N'Committee');
GO

SELECT '353r-a all five categories are off again' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.dependency_type_master
                   WHERE is_dependency_mappable = 1
                     AND dependency_type_name IN (N'Asset', N'Vendor', N'Person', N'Team', N'Committee')) = 0
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '';
PRINT '353 rollback complete. Risk Analysis -> Impact Details will show';
PRINT '"No dependency categories are configured" again, for every';
PRINT 'organisation, exactly as this environment was found before 353.';
GO

SET NOEXEC OFF;
GO
