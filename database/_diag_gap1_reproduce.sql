-- =====================================================================
-- Reproduce the swallowed error for gap 1
--
-- >>> THIS WRITES. It creates exactly what a successful analysis save
-- >>> would have created -- one Task and one Risk candidate for gap 1.
-- >>> Run it on UAT, on the gap that failed. Nothing to edit.
--
-- WHY THIS IS THE NEXT STEP
--   Everything checkable has been checked and passes: all six procedures
--   deployed, the save procedure carries both decision parameters and
--   all three triggers, risk_source_master has an Active 'Gap' row,
--   task_type_master has an active 'Rectification', the Task lifecycle is
--   seeded, and gap 1 has an organization (2) and a title. The stored
--   answers are Y / Y, so both triggers DID run. Both produced nothing,
--   and sp_custom_gap_analysis_save's CATCH only PRINTs the reason:
--
--       BEGIN CATCH
--           PRINT CONCAT(N'... auto-create warning: ', ERROR_MESSAGE());
--       END CATCH
--
--   Called directly, as below, there is no CATCH in the way and SQL
--   Server raises the real error instead.
--
--   @assigned_to_employee_id / @requested_by_employee_id are passed as
--   NULL on purpose: that is what the save passed, because
--   custom_gap_analysis.analysed_by_employee_id is NULL on this row.
--   Reproducing with a real employee id would hide the failure if the
--   NULL is what causes it.
--
-- READ THE MESSAGES PANE, not just the results grid -- a PRINT from
-- deeper in the call stack shows up there.
-- =====================================================================
SET NOCOUNT ON;

PRINT '========== TASK TRIGGER ==========';
BEGIN TRY
    EXEC grac_practice.sp_custom_gap_task_create
         @custom_gap_id           = 1,
         @assigned_to_employee_id = NULL,
         @caller_display_name     = N'diagnostic';
    PRINT 'Task trigger completed without error.';
END TRY
BEGIN CATCH
    -- Re-reported rather than re-thrown, so the risk trigger below still
    -- runs and we learn about both in one pass.
    SELECT 'TASK TRIGGER FAILED'   AS Trigger_,
           ERROR_NUMBER()          AS ErrorNumber,
           ERROR_MESSAGE()         AS ErrorMessage,
           ERROR_PROCEDURE()       AS FailedIn,
           ERROR_LINE()            AS AtLine;
END CATCH

PRINT '';
PRINT '========== RISK TRIGGER ==========';
BEGIN TRY
    EXEC grac_practice.sp_risk_candidate_create
         @custom_gap_id            = 1,
         @candidate_title          = NULL,
         @candidate_summary        = N'Reproduced from _diag_gap1_reproduce.sql',
         @severity_code            = NULL,
         @severity_name            = NULL,
         @impact_summary           = NULL,
         @likelihood_summary       = NULL,
         @requested_by_employee_id = NULL,
         @caller_display_name      = N'diagnostic';
    PRINT 'Risk trigger completed without error.';
END TRY
BEGIN CATCH
    SELECT 'RISK TRIGGER FAILED'   AS Trigger_,
           ERROR_NUMBER()          AS ErrorNumber,
           ERROR_MESSAGE()         AS ErrorMessage,
           ERROR_PROCEDURE()       AS FailedIn,
           ERROR_LINE()            AS AtLine;
END CATCH

PRINT '';
PRINT '========== WHAT EXISTS NOW ==========';
SELECT 'Task (practice_task)' AS Artefact, COUNT(*) AS Rows_
FROM   grac_practice.practice_task
WHERE  subject_entity_type = N'CustomGap' AND subject_entity_id = 1
UNION ALL
SELECT 'Risk candidate', COUNT(*)
FROM   grac_practice.risk_candidate    WHERE custom_gap_id = 1
UNION ALL
SELECT 'Exception request', COUNT(*)
FROM   grac_practice.exception_request WHERE custom_gap_id = 1;
GO
