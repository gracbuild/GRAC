-- =====================================================================
-- 261 Risk mapping / treatment / acceptance / review schema ROLLBACK
--
-- Reverses 261_risk_treatment_mapping_schema.sql.
--
--   1. Drop the constraints and indexes 261 added to existing tables.
--   2. Drop the columns 261 added to risk_register, risk_analysis and
--      risk_residual_analysis.
--   3. Drop the three new tables, children before parents.
--
-- RUN THE LATER ROLLBACKS FIRST
-- -----------------------------
-- 262, 263 and 264 all reference the columns and tables this file drops.
-- Run 264-, 263- and 262-rollback before this one, or the procedures
-- they installed are left compiled against objects that no longer exist
-- and every Risk Register read fails at run time rather than at drop
-- time. This file refuses to run while sp_risk_practice_map (262) is
-- still present, so the mistake cannot be made silently.
--
-- WHAT IS *NOT* REVERSED
-- ----------------------
-- The linked_practice_id backfill in section 7 is NOT undone. Setting it
-- back to NULL would be wrong twice over: the value is derived from data
-- that is still there and still true, and this file cannot tell a row it
-- backfilled from one an analyst filled in afterwards. A correct
-- linked_practice_id is not damage, so it stays.
--
-- DATA LOSS WARNING
-- -----------------
--   * EVERY practice mapping and asset mapping on every risk is DROPPED,
--     including directly mapped assets. There is no other copy.
--   * Every treatment option decision, acceptance record and next review
--     date is DROPPED. risk_register_history keeps its free-text
--     'TreatmentDecided' / 'RiskAccepted' / 'RiskReviewed' rows, so the
--     narrative survives; the structured values do not.
--   * Treatment TASKS are not touched. They belong to Task Centre, which
--     this migration never modified. They are left in place, orphaned
--     from the risk that raised them but perfectly valid tasks.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN
    PRINT '261-rollback: risk_register missing -- nothing to do.';
    SET NOEXEC ON;
END
GO

-- Guard: refuse while a later migration's procedures still depend on us.
IF OBJECT_ID('grac_practice.sp_risk_practice_map','P')        IS NOT NULL
   OR OBJECT_ID('grac_practice.sp_risk_treatment_option_set','P') IS NOT NULL
   OR OBJECT_ID('grac_practice.sp_risk_acceptance_save','P')   IS NOT NULL
BEGIN
    PRINT 'ABORT (261-rollback): procedures from 262/263/264 are still installed.';
    PRINT '       Run 264_risk_acceptance_review_procs_rollback.sql,';
    PRINT '       then 263_risk_treatment_option_rollback.sql,';
    PRINT '       then 262_risk_mapping_procs_rollback.sql, then this file.';
    RAISERROR('261-rollback: later migrations must be rolled back first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Indexes and constraints on pre-existing tables
--
-- Indexes before columns: dropping a column that an index INCLUDEs
-- fails, and the error names the index rather than the column, which
-- sends the next person looking in the wrong file.
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE name = 'ix_pm_risk_register_treatment_option'
              AND object_id = OBJECT_ID('grac_practice.risk_register'))
    DROP INDEX ix_pm_risk_register_treatment_option ON grac_practice.risk_register;
GO
IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE name = 'ix_pm_risk_register_next_review'
              AND object_id = OBJECT_ID('grac_practice.risk_register'))
    DROP INDEX ix_pm_risk_register_next_review ON grac_practice.risk_register;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_risk_register_treatment_option')
    ALTER TABLE grac_practice.risk_register DROP CONSTRAINT ck_pm_risk_register_treatment_option;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_risk_analysis_treatment_option')
    ALTER TABLE grac_practice.risk_analysis DROP CONSTRAINT ck_pm_risk_analysis_treatment_option;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_risk_analysis_purpose')
    ALTER TABLE grac_practice.risk_analysis DROP CONSTRAINT ck_pm_risk_analysis_purpose;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_risk_residual_treatment_option')
    ALTER TABLE grac_practice.risk_residual_analysis DROP CONSTRAINT ck_pm_risk_residual_treatment_option;
GO

IF EXISTS (SELECT 1 FROM sys.foreign_keys
            WHERE name = 'fk_pm_risk_register_accepted_by'
              AND parent_object_id = OBJECT_ID('grac_practice.risk_register'))
    ALTER TABLE grac_practice.risk_register DROP CONSTRAINT fk_pm_risk_register_accepted_by;
GO
IF EXISTS (SELECT 1 FROM sys.foreign_keys
            WHERE name = 'fk_pm_risk_register_treatment_decider'
              AND parent_object_id = OBJECT_ID('grac_practice.risk_register'))
    ALTER TABLE grac_practice.risk_register DROP CONSTRAINT fk_pm_risk_register_treatment_decider;
GO

-- The DEFAULT on review_count is a named constraint and must go before
-- the column it defaults.
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'df_pm_risk_register_review_count')
    ALTER TABLE grac_practice.risk_register DROP CONSTRAINT df_pm_risk_register_review_count;
GO

-- ---------------------------------------------------------------------
-- 2. Columns, reverse order of addition
-- ---------------------------------------------------------------------
IF COL_LENGTH('grac_practice.risk_residual_analysis','treatment_option_name') IS NOT NULL
    ALTER TABLE grac_practice.risk_residual_analysis DROP COLUMN treatment_option_name;
GO
IF COL_LENGTH('grac_practice.risk_residual_analysis','treatment_option_code') IS NOT NULL
    ALTER TABLE grac_practice.risk_residual_analysis DROP COLUMN treatment_option_code;
GO

IF COL_LENGTH('grac_practice.risk_analysis','analysis_purpose_code') IS NOT NULL
    ALTER TABLE grac_practice.risk_analysis DROP COLUMN analysis_purpose_code;
GO
IF COL_LENGTH('grac_practice.risk_analysis','treatment_option_name') IS NOT NULL
    ALTER TABLE grac_practice.risk_analysis DROP COLUMN treatment_option_name;
GO
IF COL_LENGTH('grac_practice.risk_analysis','treatment_option_code') IS NOT NULL
    ALTER TABLE grac_practice.risk_analysis DROP COLUMN treatment_option_code;
GO

IF COL_LENGTH('grac_practice.risk_register','review_count') IS NOT NULL
    ALTER TABLE grac_practice.risk_register DROP COLUMN review_count;
GO
IF COL_LENGTH('grac_practice.risk_register','last_reviewed_dt') IS NOT NULL
    ALTER TABLE grac_practice.risk_register DROP COLUMN last_reviewed_dt;
GO
IF COL_LENGTH('grac_practice.risk_register','next_review_date') IS NOT NULL
    ALTER TABLE grac_practice.risk_register DROP COLUMN next_review_date;
GO
IF COL_LENGTH('grac_practice.risk_register','acceptance_note') IS NOT NULL
    ALTER TABLE grac_practice.risk_register DROP COLUMN acceptance_note;
GO
IF COL_LENGTH('grac_practice.risk_register','accepted_dt') IS NOT NULL
    ALTER TABLE grac_practice.risk_register DROP COLUMN accepted_dt;
GO
IF COL_LENGTH('grac_practice.risk_register','accepted_by_name') IS NOT NULL
    ALTER TABLE grac_practice.risk_register DROP COLUMN accepted_by_name;
GO
IF COL_LENGTH('grac_practice.risk_register','accepted_by_employee_id') IS NOT NULL
    ALTER TABLE grac_practice.risk_register DROP COLUMN accepted_by_employee_id;
GO
IF COL_LENGTH('grac_practice.risk_register','treatment_task_id') IS NOT NULL
    ALTER TABLE grac_practice.risk_register DROP COLUMN treatment_task_id;
GO
IF COL_LENGTH('grac_practice.risk_register','treatment_decided_by_employee_id') IS NOT NULL
    ALTER TABLE grac_practice.risk_register DROP COLUMN treatment_decided_by_employee_id;
GO
IF COL_LENGTH('grac_practice.risk_register','treatment_decided_dt') IS NOT NULL
    ALTER TABLE grac_practice.risk_register DROP COLUMN treatment_decided_dt;
GO
IF COL_LENGTH('grac_practice.risk_register','treatment_option_name') IS NOT NULL
    ALTER TABLE grac_practice.risk_register DROP COLUMN treatment_option_name;
GO
IF COL_LENGTH('grac_practice.risk_register','treatment_option_code') IS NOT NULL
    ALTER TABLE grac_practice.risk_register DROP COLUMN treatment_option_code;
GO

-- ---------------------------------------------------------------------
-- 3. The new tables -- child first, the FK points that way
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.risk_asset_map_source','U') IS NOT NULL
    DROP TABLE grac_practice.risk_asset_map_source;
GO
IF OBJECT_ID('grac_practice.risk_asset_map','U') IS NOT NULL
    DROP TABLE grac_practice.risk_asset_map;
GO
IF OBJECT_ID('grac_practice.risk_practice_map','U') IS NOT NULL
    DROP TABLE grac_practice.risk_practice_map;
GO

SELECT '261 rollback complete' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.risk_practice_map','U')     IS NULL
             AND OBJECT_ID('grac_practice.risk_asset_map','U')        IS NULL
             AND OBJECT_ID('grac_practice.risk_asset_map_source','U') IS NULL
             AND COL_LENGTH('grac_practice.risk_register','treatment_option_code') IS NULL
             AND COL_LENGTH('grac_practice.risk_register','next_review_date')      IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '261-rollback done. linked_practice_id was deliberately left populated --';
PRINT '     see the header. Re-run 258 if sp_risk_register_list/_get need';
PRINT '     restoring to their pre-264 definitions.';
GO

SET NOEXEC OFF;
GO
