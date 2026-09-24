-- =====================================================================
-- 278 Audit setup procedures -- ROLLBACK
--
-- Drops the three procedures 278 created. No data is touched: these are
-- read/save wrappers, and the adoption rows they write live in the table
-- created by 277 (drop that with 277's rollback if you want the data
-- gone too -- run THIS script first, since the procs reference it).
--
-- Re-runnable: yes.
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_definition_question_set_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_definition_question_set_get;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_definition_question_set_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_definition_question_set_save;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_setup_status','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_setup_status;
GO

SELECT 'question set get proc removed'  AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_definition_question_set_get','P')  IS NULL THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'question set save proc removed' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_definition_question_set_save','P') IS NULL THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'setup status proc removed'      AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_setup_status','P')                 IS NULL THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '278 rollback complete.';
GO
