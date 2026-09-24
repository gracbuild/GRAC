-- =====================================================================
-- 295_risk_bulk_accept_rollback.sql
--
-- Reverts 295 by dropping sp_risk_bulk_accept.
--
-- NOTHING ELSE TO UNDO. 295 added one procedure. It created no table,
-- column, constraint or view, and it MODIFIED nothing -- every rule it
-- applies lives in sp_risk_acceptance_save, which it only calls.
--
-- DATA: nothing is deleted or reversed. Risks accepted through this
-- procedure stay accepted, with their accepter, dates, cadence and
-- 'RiskAccepted' history rows intact -- those were written by
-- sp_risk_acceptance_save and are indistinguishable from a single
-- acceptance, because that is what each of them was.
--
-- To un-accept a specific risk, change its status through the register;
-- there is no bulk un-accept and this file is not one.
--
-- AFTER RUNNING THIS: the Accept tab's bulk button will fail with
-- "Could not find stored procedure". Single acceptance is unaffected --
-- it never went through this procedure. Remove or hide the bulk control
-- if the tab is staying.
--
-- Re-runnable: yes. ASCII-only (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_risk_bulk_accept','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_risk_bulk_accept;
    PRINT '295 rollback: sp_risk_bulk_accept dropped.';
END
ELSE
    PRINT '295 rollback: sp_risk_bulk_accept was not present -- nothing to do.';
GO

SELECT '295 rollback: procedure is gone' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_bulk_accept','P') IS NULL
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

SELECT '295 rollback: single acceptance still works' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_acceptance_save','P') IS NOT NULL
            THEN 'PASS -- 264/293 untouched'
            ELSE '*** FAIL -- acceptance itself is missing' END AS Result;
GO
