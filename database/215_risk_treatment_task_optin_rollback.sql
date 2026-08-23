-- =====================================================================
-- 215 Risk treatment task opt-in ROLLBACK
--
-- Reverses 215_risk_treatment_task_optin.sql.
--
--   1. Drop 215's two procedures.
--   2. Narrow the two source_type_code CHECKs back to 192/197's list.
--
-- STEP 2 CAN FAIL, AND THAT IS CORRECT
-- ------------------------------------
-- Narrowing a CHECK is not the harmless inverse of widening one. If any
-- treatment task or task candidate was raised with source_type_code =
-- 'RiskRegister', the original constraint cannot be restored without
-- either deleting that work or orphaning it.
--
-- So this script REFUSES step 2 while such rows exist, leaves the wider
-- CHECK in place, and prints what to inspect. A permanently slightly-wide
-- CHECK is a trivial cost; silently deleting somebody's remediation
-- tasks to tidy a constraint is not.
--
-- Treatment tasks themselves are NOT deleted by this rollback under any
-- circumstances — they belong to Task Centre, not to Risk Centre.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT '215-rollback: schema grac_practice missing — nothing to do.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Procedures
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_risk_treatment_task_list','P')  IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_treatment_task_list;
IF OBJECT_ID('grac_practice.sp_risk_treatment_task_raise','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_treatment_task_raise;
GO

-- ---------------------------------------------------------------------
-- 2. Narrow the CHECKs, if and only if it is safe
-- ---------------------------------------------------------------------
DECLARE @task_rows INT = 0, @cand_rows INT = 0;

IF COL_LENGTH('grac_practice.practice_task','source_type_code') IS NOT NULL
    SELECT @task_rows = COUNT(*) FROM grac_practice.practice_task
     WHERE source_type_code = N'RiskRegister';

IF OBJECT_ID('grac_practice.task_candidate','U') IS NOT NULL
    SELECT @cand_rows = COUNT(*) FROM grac_practice.task_candidate
     WHERE source_type_code = N'RiskRegister';

IF @task_rows > 0 OR @cand_rows > 0
BEGIN
    PRINT '215-rollback: source CHECKs LEFT WIDE.';
    PRINT CONCAT('              practice_task rows with RiskRegister:  ', @task_rows);
    PRINT CONCAT('              task_candidate rows with RiskRegister: ', @cand_rows);
    PRINT '              Narrowing the constraint would orphan real remediation work.';
    PRINT '              Inspect with:';
    PRINT '                SELECT * FROM grac_practice.task_candidate WHERE source_type_code = N''RiskRegister'';';
    PRINT '                SELECT * FROM grac_practice.practice_task  WHERE source_type_code = N''RiskRegister'';';
    PRINT '              Re-home or close them, then re-run this script.';
END
ELSE
BEGIN
    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_source_type')
        ALTER TABLE grac_practice.practice_task DROP CONSTRAINT ck_pm_practice_task_source_type;

    ALTER TABLE grac_practice.practice_task WITH NOCHECK
        ADD CONSTRAINT ck_pm_practice_task_source_type
            CHECK (source_type_code IS NULL
                OR source_type_code IN (N'Gap', N'Exception', N'Risk',
                                        N'ContinuousAssurance', N'EventAssurance',
                                        N'Custom'));

    IF OBJECT_ID('grac_practice.task_candidate','U') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_task_candidate_source_type')
            ALTER TABLE grac_practice.task_candidate DROP CONSTRAINT ck_pm_task_candidate_source_type;

        ALTER TABLE grac_practice.task_candidate WITH NOCHECK
            ADD CONSTRAINT ck_pm_task_candidate_source_type
                CHECK (source_type_code IN (N'Gap', N'Exception', N'Risk',
                                            N'ContinuousAssurance', N'EventAssurance',
                                            N'Custom'));
    END

    PRINT '215-rollback: source CHECKs narrowed back to the 192/197 vocabulary.';
END
GO

PRINT '215 Risk treatment task opt-in rolled back.';
GO

SET NOEXEC OFF;
GO
