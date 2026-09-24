-- =====================================================================
-- 263 Risk treatment option ROLLBACK
--
-- Reverses 263_risk_treatment_option.sql.
--
--   1. Drop 263's own procedures.
--   2. RESTORE sp_risk_residual_analysis_save to its 258 definition.
--   3. Optionally clear the treatment_task_id stamps.
--
-- STEP 2 IS THE ONE THAT MATTERS
-- ------------------------------
-- 263 REWROTE sp_risk_residual_analysis_save, which existed before it.
-- Dropping it would leave the API calling a procedure that is gone, and
-- every residual save would fail with "Could not find stored procedure"
-- rather than anything diagnostic.
--
-- The fix is the same one 258's rollback gives for 216: re-run the file
-- that owned the previous definition. 258 is CREATE OR ALTER throughout
-- and idempotent, so re-running it is safe.
--
-- This file does NOT drop that procedure -- deliberately. Leaving 263's
-- version standing until 258 is re-run keeps residual saves working
-- (with a gate that no longer has procedures behind it, which is
-- harmless: the gate reads vw_pm_practice_task directly). Dropping it
-- would create a window with no procedure at all.
--
-- WHAT IS *NOT* REVERSED
-- ----------------------
--   * TASKS. Every treatment task 263 opened stays in Task Centre,
--     open, owned and due. They are valid tasks that people are working
--     on; deleting them because a migration was rolled back would
--     destroy real work. They keep source_type_code = 'RiskRegister',
--     so 215's sp_risk_treatment_task_list still finds and shows them.
--   * Status changes. Risks moved to UnderTreatment or Monitoring stay
--     there. Those are §17 statuses that predate this migration and the
--     transitions were correct when they happened.
--   * treatment_option_code values. They are 261's column and 261's
--     rollback drops it.
--
-- The only optional cleanup is the treatment_task_id stamp, at the
-- bottom, commented out. Read the note there before running it.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN
    PRINT '263-rollback: risk_register missing -- nothing to do.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. 263's own procedures
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_risk_treatment_sync','P')        IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_treatment_sync;
IF OBJECT_ID('grac_practice.sp_risk_treatment_state','P')       IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_treatment_state;
IF OBJECT_ID('grac_practice.sp_risk_treatment_option_set','P')  IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_treatment_option_set;
IF OBJECT_ID('grac_practice.sp_risk_treatment_task_ensure','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_treatment_task_ensure;
GO

-- ---------------------------------------------------------------------
-- 2. The rewritten procedure
-- ---------------------------------------------------------------------
PRINT '263-rollback: RE-RUN 258_risk_residual_analysis.sql now.';
PRINT '              It restores sp_risk_residual_analysis_save to its';
PRINT '              pre-263 definition (no treatment gate, no treatment';
PRINT '              option parameters). It is CREATE OR ALTER and';
PRINT '              idempotent, so re-running it is safe.';
PRINT '';
PRINT '              Until you do, the procedure keeps 263''s body. That';
PRINT '              body still WORKS -- its gate reads vw_pm_practice_task';
PRINT '              directly and needs none of the procedures dropped';
PRINT '              above -- but it will refuse a residual assessment';
PRINT '              while a treatment task is open, which is 263''s rule,';
PRINT '              not 258''s.';
GO

-- Fails loudly if 263's version is still installed AFTER the operator
-- says they have re-run 258, which is the only way to catch a re-run
-- that silently did not happen.
IF EXISTS (SELECT 1 FROM sys.sql_modules
            WHERE object_id = OBJECT_ID('grac_practice.sp_risk_residual_analysis_save')
              AND definition LIKE '%skip_treatment_gate%')
    PRINT '263-rollback: sp_risk_residual_analysis_save STILL holds 263''s body. Re-run 258.';
ELSE
    PRINT '263-rollback: sp_risk_residual_analysis_save is back to its 258 body.';
GO

-- ---------------------------------------------------------------------
-- 3. OPTIONAL: clear the treatment_task_id stamps
--
-- COMMENTED OUT ON PURPOSE. The stamp is 261's column and 261's rollback
-- drops it wholesale, so this is only useful when rolling back 263
-- ALONE and intending to stay there.
--
-- Clearing it does not delete any task. It only makes Risk Centre forget
-- which task it raised -- after which 215's manual raise would create a
-- SECOND task for a risk that already has one open. That is why it is
-- not the default.
--
-- UPDATE grac_practice.risk_register
--    SET treatment_task_id = NULL,
--        updated_by = N'rollback-263',
--        updated_dt = SYSUTCDATETIME()
--  WHERE treatment_task_id IS NOT NULL;
-- ---------------------------------------------------------------------

SELECT '263 rollback complete' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_treatment_option_set','P')  IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_treatment_task_ensure','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_treatment_state','P')       IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_treatment_sync','P')        IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '263-rollback done. Treatment TASKS were deliberately left in place --';
PRINT '     see the header. Re-run 258 if you have not already.';
GO

SET NOEXEC OFF;
GO
