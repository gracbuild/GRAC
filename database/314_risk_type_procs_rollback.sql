-- =====================================================================
-- 314 Risk Type procedures -- ROLLBACK
--
-- Drops the three procedures 314 created:
--   sp_risk_type_list
--   sp_risk_type_selection_set
--   sp_risk_type_selection_get
--
-- NO DATA IS TOUCHED. 313's master and both link tables, and every
-- selection stored in them, are left exactly as they are -- run 313's
-- rollback for those, and run this one FIRST so the procedures are not
-- left referring to tables that have gone.
--
-- NOTHING ELSE IS RESTORED, because 314 re-issued nothing.
-- sp_risk_register_assess, sp_risk_analysis_save and sp_risk_review_perform
-- were never edited -- that was the point of building the selection as a
-- second call rather than a wrapper -- so there is no earlier body to put
-- back.
--
-- AFTER RUNNING THIS the API's risk-type calls will fail with "Could not
-- find stored procedure". If the API tier is still deployed, roll the Web
-- and API tiers back too, or the Analysis and Review forms will refuse
-- to save (the required rule lives in the procedure that is now gone).
--
-- Re-runnable: yes.
-- ASCII-only on purpose.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_risk_type_selection_set','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_risk_type_selection_set;
    PRINT '314 rollback: sp_risk_type_selection_set dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_risk_type_selection_get','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_risk_type_selection_get;
    PRINT '314 rollback: sp_risk_type_selection_get dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_risk_type_list','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_risk_type_list;
    PRINT '314 rollback: sp_risk_type_list dropped.';
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '314r-a sp_risk_type_list gone' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_type_list','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '314r-b sp_risk_type_selection_set gone',
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_type_selection_set','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '314r-c sp_risk_type_selection_get gone',
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_type_selection_get','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- The data survives this rollback on purpose.
SELECT '314r-d 313s tables are untouched',
       CASE WHEN OBJECT_ID('grac_practice.risk_type_master','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_analysis_risk_type','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_register_risk_type','U') IS NOT NULL
            THEN 'PASS' ELSE 'CHECK -- 313 may already have been rolled back' END
UNION ALL
-- 314 never re-issued the assess path; it must still be there.
SELECT '314r-e sp_risk_register_assess still present',
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_register_assess','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '314 rollback complete. The stored selections are still in 313s link';
PRINT 'tables -- re-running 314 makes them readable again with no data loss.';
GO

SET NOEXEC OFF;
GO
