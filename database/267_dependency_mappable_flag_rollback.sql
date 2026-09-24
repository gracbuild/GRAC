-- =====================================================================
-- 267 dependency-mappable flag ROLLBACK
--
-- Restores 266's unfiltered behaviour: Risk Analysis goes back to
-- offering every active category in dependency_type_master, which is
-- nine on a stock database and does NOT match the Operationalize page.
--
-- That is what rolling this file back means, so it is stated plainly
-- rather than buried: you are re-introducing the mismatch 267 fixed.
--
-- WHAT IS NOT REVERSED
-- --------------------
-- Section 4 of 267 deleted dependencies that had been inherited into
-- non-offered categories. They are NOT restored -- they came from
-- practice_dependency_resolution, so re-mapping the practice brings them
-- straight back. Nothing is lost that the source cannot regenerate.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

PRINT '267-rollback: RE-RUN 266_risk_dependency_procs.sql after this file.';
PRINT '              It restores fn_risk_practice_dependencies and';
PRINT '              sp_risk_mapping_get without the is_dependency_mappable';
PRINT '              filter. Both are CREATE OR ALTER and idempotent.';
GO

-- The column goes last: 266's bodies do not reference it, so once they
-- are back it is unused. Dropping it while 267's bodies are still
-- installed would leave them failing on a missing column, so this
-- refuses until 266 has been re-run.
IF EXISTS (SELECT 1 FROM sys.sql_modules
            WHERE object_id IN (OBJECT_ID('grac_practice.fn_risk_practice_dependencies'),
                                OBJECT_ID('grac_practice.sp_risk_mapping_get'))
              AND definition LIKE '%is_dependency_mappable%')
BEGIN
    PRINT 'ABORT (267-rollback): fn_risk_practice_dependencies and/or sp_risk_mapping_get';
    PRINT '       still hold 267 bodies that filter on is_dependency_mappable.';
    PRINT '       Re-run 266_risk_dependency_procs.sql, then run this file again.';
    PRINT '       The column has been LEFT IN PLACE so the Risk Analysis scope panel keeps working.';
    RAISERROR('267-rollback: re-run 266 before dropping the column.', 16, 1);
    SET NOEXEC ON;
END
GO

IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'df_pm_dep_type_mappable')
    ALTER TABLE grac_practice.dependency_type_master DROP CONSTRAINT df_pm_dep_type_mappable;
GO

IF COL_LENGTH('grac_practice.dependency_type_master','is_dependency_mappable') IS NOT NULL
    ALTER TABLE grac_practice.dependency_type_master DROP COLUMN is_dependency_mappable;
GO

SELECT '267 rollback complete' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.dependency_type_master','is_dependency_mappable') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '267-rollback done. Risk Analysis once again offers every active category,';
PRINT '     which is MORE than the Operationalize page offers.';
GO

SET NOEXEC OFF;
GO
