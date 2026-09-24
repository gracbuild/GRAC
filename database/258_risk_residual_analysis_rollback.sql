-- =====================================================================
-- 258 Residual Risk Analysis ROLLBACK
--
-- Reverses 258_risk_residual_analysis.sql.
--
--   1. Drop 258's own procedures.
--   2. RESTORE sp_risk_register_list and sp_risk_register_get to their
--      216 definitions.
--   3. Drop the FK, the indexes and the residual columns on
--      risk_register.
--   4. Drop grac_practice.risk_residual_analysis.
--
-- Step 2 is the part that matters, and it is the same trap 216's
-- rollback called out: 258 REWROTE two procedures that existed before
-- it. Dropping them would leave the API calling something that no longer
-- exists; the fix is to re-run 216, which is CREATE OR ALTER and
-- idempotent.
--
-- ORDER MATTERS. The FK on risk_register.residual_analysis_id points at
-- risk_residual_analysis, so the constraint goes before the table. The
-- two procedures that SELECT the residual columns are replaced before
-- those columns are dropped, so nothing is left compiled against a
-- column that has gone.
--
-- DATA LOSS WARNING
-- -----------------
--   * EVERY residual risk assessment, of every version, on every risk,
--     is DROPPED. There is no other copy — the register's residual_*
--     columns are dropped in the same run.
--   * The inherent rating is NOT touched. Nothing in 216's path is
--     modified by 258, so nothing in it is modified here.
--   * risk_register_history keeps its 'ResidualAssessed' rows. They are
--     free text in a generic audit table and remain readable; only the
--     structured assessments are gone.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN
    PRINT '258-rollback: risk_register missing — nothing to do.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. 258's own procedures
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_risk_residual_analysis_history','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_residual_analysis_history;
IF OBJECT_ID('grac_practice.sp_risk_residual_analysis_get','P')     IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_residual_analysis_get;
IF OBJECT_ID('grac_practice.sp_risk_residual_analysis_save','P')    IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_residual_analysis_save;
GO

PRINT '258-rollback: re-run 216_risk_threat_vulnerability_assessment.sql to';
PRINT '              restore sp_risk_register_list and sp_risk_register_get';
PRINT '              to their pre-258 definitions. It is CREATE OR ALTER and';
PRINT '              idempotent, so re-running it is safe.';
PRINT '              DO THIS BEFORE the column drops below, or run this whole';
PRINT '              file and then 216 — either order leaves the two procs';
PRINT '              correct, because a proc is only bound at execution.';
GO

-- ---------------------------------------------------------------------
-- 2. Foreign key and indexes on risk_register
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.foreign_keys
            WHERE name = 'fk_pm_risk_register_residual'
              AND parent_object_id = OBJECT_ID('grac_practice.risk_register'))
    ALTER TABLE grac_practice.risk_register DROP CONSTRAINT fk_pm_risk_register_residual;
GO

IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE name = 'ix_pm_risk_register_residual_pending'
              AND object_id = OBJECT_ID('grac_practice.risk_register'))
    DROP INDEX ix_pm_risk_register_residual_pending ON grac_practice.risk_register;
GO

IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE name = 'ix_pm_risk_register_residual_rating'
              AND object_id = OBJECT_ID('grac_practice.risk_register'))
    DROP INDEX ix_pm_risk_register_residual_rating ON grac_practice.risk_register;
GO

-- ---------------------------------------------------------------------
-- 3. Residual columns on risk_register
--
-- residual_pending carries a DEFAULT constraint, and SQL Server refuses
-- to drop a column while a default is bound to it (error 5074). The
-- constraint is looked up by parent/column rather than by name so a
-- deployment that ended up with an auto-named default is still cleaned.
-- ---------------------------------------------------------------------
DECLARE @df SYSNAME, @sql NVARCHAR(400);
SELECT @df = dc.name
  FROM sys.default_constraints dc
  JOIN sys.columns c ON c.object_id = dc.parent_object_id
                    AND c.column_id = dc.parent_column_id
 WHERE dc.parent_object_id = OBJECT_ID('grac_practice.risk_register')
   AND c.name = 'residual_pending';
IF @df IS NOT NULL
BEGIN
    SET @sql = N'ALTER TABLE grac_practice.risk_register DROP CONSTRAINT ' + QUOTENAME(@df) + N';';
    EXEC sp_executesql @sql;
END
GO

IF COL_LENGTH('grac_practice.risk_register','residual_pending')          IS NOT NULL ALTER TABLE grac_practice.risk_register DROP COLUMN residual_pending;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_assessed_dt')      IS NOT NULL ALTER TABLE grac_practice.risk_register DROP COLUMN residual_assessed_dt;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_rating_score')     IS NOT NULL ALTER TABLE grac_practice.risk_register DROP COLUMN residual_rating_score;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_rating_name')      IS NOT NULL ALTER TABLE grac_practice.risk_register DROP COLUMN residual_rating_name;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_rating_code')      IS NOT NULL ALTER TABLE grac_practice.risk_register DROP COLUMN residual_rating_code;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_impact_value')     IS NOT NULL ALTER TABLE grac_practice.risk_register DROP COLUMN residual_impact_value;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_impact_name')      IS NOT NULL ALTER TABLE grac_practice.risk_register DROP COLUMN residual_impact_name;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_impact_code')      IS NOT NULL ALTER TABLE grac_practice.risk_register DROP COLUMN residual_impact_code;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_likelihood_value') IS NOT NULL ALTER TABLE grac_practice.risk_register DROP COLUMN residual_likelihood_value;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_likelihood_name')  IS NOT NULL ALTER TABLE grac_practice.risk_register DROP COLUMN residual_likelihood_name;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_likelihood_code')  IS NOT NULL ALTER TABLE grac_practice.risk_register DROP COLUMN residual_likelihood_code;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_analysis_id')      IS NOT NULL ALTER TABLE grac_practice.risk_register DROP COLUMN residual_analysis_id;
GO

-- ---------------------------------------------------------------------
-- 4. The table
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.risk_residual_analysis','U') IS NOT NULL
    DROP TABLE grac_practice.risk_residual_analysis;
GO

SELECT '258 rollback complete' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.risk_residual_analysis','U') IS NULL
             AND COL_LENGTH('grac_practice.risk_register','residual_rating_code') IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_residual_analysis_save','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '258-rollback done. Re-run 216_risk_threat_vulnerability_assessment.sql';
PRINT 'if you have not already — sp_risk_register_list and sp_risk_register_get';
PRINT 'still hold 258 definitions until you do, and they reference dropped columns.';
GO
