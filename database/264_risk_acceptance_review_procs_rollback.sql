-- =====================================================================
-- 264 Risk acceptance / calendar / review ROLLBACK
--
-- Reverses 264_risk_acceptance_review_procs.sql.
--
--   1. Drop 264's own procedures.
--   2. Drop vw_pm_risk_workflow_stage.
--   3. RESTORE sp_risk_register_list and sp_risk_register_get to their
--      258 definitions.
--
-- STEP 3 IS THE ONE THAT MATTERS, AND IT HAS A TRAP STEP 2 CREATES
-- ----------------------------------------------------------------
-- 264 REWROTE both register read procedures, and both of them JOIN
-- vw_pm_risk_workflow_stage. Dropping the view while 264's bodies are
-- still installed leaves every Risk Register list and detail read
-- failing with "Invalid object name".
--
-- So the ORDER here is: procedures, then the instruction to re-run 258,
-- and the VIEW LAST -- with a guard that refuses to drop it while 264's
-- bodies are still in place. Getting this backwards produces a Risk
-- Register that looks broken for reasons the error message does not
-- explain, which is exactly the failure 258's own rollback header warns
-- about.
--
-- WHAT IS *NOT* REVERSED
-- ----------------------
--   * Acceptance records, review dates and review counts. They are 261's
--     columns and 261's rollback drops them. Until then they are real
--     decisions that people made and are left intact.
--   * Status changes. A risk moved to Accepted or Monitoring stays
--     there; both are §17 statuses that predate this migration.
--   * risk_analysis rows written by reviews. They are ordinary versioned
--     analyses -- 216 would have produced identical rows -- and only
--     their analysis_purpose_code = 'Review' stamp marks them, which is
--     261's column.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN
    PRINT '264-rollback: risk_register missing -- nothing to do.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. 264's own procedures
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_risk_review_perform','P')   IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_review_perform;
IF OBJECT_ID('grac_practice.sp_risk_review_calendar','P')  IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_review_calendar;
IF OBJECT_ID('grac_practice.sp_risk_review_due_list','P')  IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_review_due_list;
IF OBJECT_ID('grac_practice.sp_risk_acceptance_get','P')   IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_acceptance_get;
IF OBJECT_ID('grac_practice.sp_risk_acceptance_save','P')  IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_acceptance_save;
GO

-- ---------------------------------------------------------------------
-- 2. The rewritten read procedures
-- ---------------------------------------------------------------------
PRINT '264-rollback: RE-RUN 258_risk_residual_analysis.sql NOW, before';
PRINT '              continuing. It restores sp_risk_register_list and';
PRINT '              sp_risk_register_get to their pre-264 definitions,';
PRINT '              which do NOT reference vw_pm_risk_workflow_stage.';
PRINT '              It is CREATE OR ALTER and idempotent.';
PRINT '';
PRINT '              The view drop below REFUSES until you have done so.';
GO

-- ---------------------------------------------------------------------
-- 3. The view -- last, and only once nothing depends on it
--
-- The guard reads sys.sql_modules rather than sys.sql_expression_
-- dependencies because the latter is unreliable for views referenced
-- inside procedures that were created before the view existed.
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.sql_modules
            WHERE object_id IN (OBJECT_ID('grac_practice.sp_risk_register_list'),
                                OBJECT_ID('grac_practice.sp_risk_register_get'))
              AND definition LIKE '%vw_pm_risk_workflow_stage%')
BEGIN
    PRINT 'ABORT (264-rollback): sp_risk_register_list and/or sp_risk_register_get';
    PRINT '       still hold 264 bodies that JOIN vw_pm_risk_workflow_stage.';
    PRINT '       Re-run 258_risk_residual_analysis.sql, then run this file again.';
    PRINT '       The view has been LEFT IN PLACE so the Risk Register keeps working.';
    RAISERROR('264-rollback: re-run 258 before dropping the workflow stage view.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage','V') IS NOT NULL
    DROP VIEW grac_practice.vw_pm_risk_workflow_stage;
GO

SELECT '264 rollback complete' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_acceptance_save','P')     IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_review_due_list','P')     IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_review_calendar','P')     IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_review_perform','P')      IS NULL
             AND OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage','V')   IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '264-rollback done. Acceptance and review DATA is untouched --';
PRINT '     run 261-rollback to drop the columns that hold it.';
GO

SET NOEXEC OFF;
GO
