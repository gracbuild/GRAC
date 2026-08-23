-- =====================================================================
-- 198 Task Candidate — lifecycle procedures ROLLBACK
--
-- Drops only what 198 created. 197's schema is untouched, so candidate
-- ROWS survive — run 197's rollback afterwards if you want them gone.
--
-- Run 199's rollback FIRST: the source integrations call
-- sp_task_candidate_create, and restoring their pre-Phase-2 bodies
-- removes that dependency before the proc disappears.
--
-- Order here: dependents before dependencies. sp_task_candidate_create
-- and _validate_save both call sp_task_candidate_apply_sla, so it goes
-- last.
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT '198-rollback: schema grac_practice missing — nothing to do.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.sp_task_candidate_counts','P')        IS NOT NULL DROP PROCEDURE grac_practice.sp_task_candidate_counts;
IF OBJECT_ID('grac_practice.sp_task_candidate_discard','P')       IS NOT NULL DROP PROCEDURE grac_practice.sp_task_candidate_discard;
IF OBJECT_ID('grac_practice.sp_task_candidate_approve','P')       IS NOT NULL DROP PROCEDURE grac_practice.sp_task_candidate_approve;
IF OBJECT_ID('grac_practice.sp_task_candidate_validate_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_task_candidate_validate_save;
IF OBJECT_ID('grac_practice.sp_task_candidate_get','P')           IS NOT NULL DROP PROCEDURE grac_practice.sp_task_candidate_get;
IF OBJECT_ID('grac_practice.sp_task_candidate_list','P')          IS NOT NULL DROP PROCEDURE grac_practice.sp_task_candidate_list;
IF OBJECT_ID('grac_practice.sp_task_candidate_create','P')        IS NOT NULL DROP PROCEDURE grac_practice.sp_task_candidate_create;
IF OBJECT_ID('grac_practice.sp_task_candidate_apply_sla','P')     IS NOT NULL DROP PROCEDURE grac_practice.sp_task_candidate_apply_sla;
GO

-- Warn about anything left stranded: a candidate that can no longer be
-- approved is work the organisation identified and would silently lose
-- track of.
IF OBJECT_ID('grac_practice.task_candidate','U') IS NOT NULL
    SELECT '198-rollback: candidates left unconvertible' AS Check_,
           status_code AS StatusCode,
           COUNT(*)    AS Rows_
      FROM grac_practice.task_candidate
     WHERE status_code IN (N'New', N'Validated')
     GROUP BY status_code;
GO

PRINT '198 Task Candidate lifecycle procedures rolled back.';
GO

SET NOEXEC OFF;
GO
