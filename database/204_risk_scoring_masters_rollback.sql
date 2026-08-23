-- =====================================================================
-- 204 Risk Centre — scoring masters ROLLBACK
--
-- Reverses 204_risk_scoring_masters.sql.
--
-- ORDER
--   1. Refuse to run while 205's tables still reference these masters.
--      risk_analysis and risk_register store the org's likelihood/impact
--      levels and rating codes; dropping the scale underneath them would
--      leave ratings nobody can interpret. Run 205's rollback first.
--   2. Drop sp_risk_scoring_seed_default.
--   3. Drop the five masters.
--
-- DATA LOSS WARNING: any likelihood/impact level, matrix cell or risk
-- category an organisation has customised is DROPPED. Re-running 204
-- restores only the shipped defaults, not local edits.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT '204-rollback: schema grac_practice missing — nothing to do.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Guard — 205 must go first
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.risk_analysis','U') IS NOT NULL
   OR OBJECT_ID('grac_practice.risk_register','U') IS NOT NULL
BEGIN
    PRINT 'ABORT (204-rollback): risk_analysis / risk_register still exist.';
    PRINT '                      Run 205_risk_register_schema_rollback.sql first,';
    PRINT '                      otherwise stored ratings lose the scale that defines them.';
    RAISERROR('204-rollback: 205 objects still present.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 2. Seed procedure
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_risk_scoring_seed_default','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_risk_scoring_seed_default;
GO

-- ---------------------------------------------------------------------
-- 3. Masters
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.risk_matrix_cell','U')       IS NOT NULL DROP TABLE grac_practice.risk_matrix_cell;
IF OBJECT_ID('grac_practice.risk_impact_master','U')     IS NOT NULL DROP TABLE grac_practice.risk_impact_master;
IF OBJECT_ID('grac_practice.risk_likelihood_master','U') IS NOT NULL DROP TABLE grac_practice.risk_likelihood_master;
IF OBJECT_ID('grac_practice.risk_category_master','U')   IS NOT NULL DROP TABLE grac_practice.risk_category_master;
IF OBJECT_ID('grac_practice.risk_source_master','U')     IS NOT NULL DROP TABLE grac_practice.risk_source_master;
GO

PRINT '204 Risk scoring masters rolled back.';
GO

SET NOEXEC OFF;
GO
