-- =====================================================================
-- 214 Risk dashboard procedures ROLLBACK
--
-- Reverses 214_risk_dashboard_procs.sql.
--
-- CLEAN ROLLBACK, NO DATA LOSS. 214 is read-only: it added two
-- procedures and modified nothing. Dropping them removes the Dashboard
-- tab's data source; the Candidates and Risk Register tabs are
-- unaffected because they read their own procs.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT '214-rollback: schema grac_practice missing — nothing to do.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.sp_risk_candidate_ageing','P')  IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_ageing;
IF OBJECT_ID('grac_practice.sp_risk_dashboard_counts','P')  IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_dashboard_counts;
GO

PRINT '214 Risk dashboard procedures rolled back.';
GO

SET NOEXEC OFF;
GO
