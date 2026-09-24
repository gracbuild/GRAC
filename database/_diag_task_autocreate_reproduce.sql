-- =====================================================================
-- _diag_task_autocreate_reproduce.sql
--
-- Gap Analysis / Risk Analysis stopped auto-creating Tasks.
--
-- ROOT-CAUSE MECHANISM (already confirmed):
--   sp_custom_gap_analysis_save fires the Task / Risk / Exception
--   triggers inside BEST-EFFORT BEGIN TRY / BEGIN CATCH blocks that only
--   PRINT the error. Both the Gap page and the Risk page ultimately open a
--   task through grac_practice.sp_task_open, whose INSERT and
--   sp_pm_state_transition calls run INSIDE its transaction and are NOT
--   guarded -- so if one throws, sp_custom_gap_task_create rethrows 55502,
--   and the save's CATCH swallows it. The save still reports success, and
--   no Task/Risk appears.
--
-- This script runs the two triggers OUTSIDE that swallowing CATCH so the
-- REAL error (number / message / failing proc / line) is shown.
--
-- >>> IT WRITES: it creates exactly what a successful analysis save would
-- >>> (one Task + one Risk candidate) for the gap you name. Run it on the
-- >>> gap that FAILED, and READ THE MESSAGES PANE as well as the grids.
--
-- HOW TO USE: set @gap_id below to a gap whose analysis was saved but
-- produced no Task. @analyst is passed NULL on purpose (that is what the
-- save passes when custom_gap_analysis.analysed_by_employee_id is NULL) --
-- if the NULL is the cause, a real id would hide it.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @gap_id  BIGINT = 1;      -- <<< SET ME to the failing gap
DECLARE @analyst BIGINT = NULL;   -- leave NULL to mirror the save exactly

IF @gap_id IS NULL
BEGIN
    SELECT 'Set @gap_id at the top of this script.' AS Note;
    RETURN;
END

-- Context for the gap, so a "not found" is obvious.
SELECT g.custom_gap_id, g.organization_id, g.title, g.priority,
       a.analysed_by_employee_id, a.remediation_possible, a.business_risk_present
FROM   grac_practice.custom_gap g
LEFT   JOIN grac_practice.custom_gap_analysis a ON a.custom_gap_id = g.custom_gap_id
WHERE  g.custom_gap_id = @gap_id;

PRINT '========== TASK TRIGGER (sp_custom_gap_task_create) ==========';
BEGIN TRY
    EXEC grac_practice.sp_custom_gap_task_create
         @custom_gap_id           = @gap_id,
         @assigned_to_employee_id = @analyst,
         @caller_display_name     = N'diagnostic';
    PRINT 'Task trigger completed without error.';
END TRY
BEGIN CATCH
    SELECT 'TASK TRIGGER FAILED' AS Trigger_,
           ERROR_NUMBER()  AS ErrorNumber,
           ERROR_MESSAGE() AS ErrorMessage,
           ERROR_PROCEDURE() AS FailedIn,
           ERROR_LINE()    AS AtLine;
END CATCH

PRINT '';
PRINT '========== RISK TRIGGER (sp_risk_candidate_create) ==========';
BEGIN TRY
    EXEC grac_practice.sp_risk_candidate_create
         @custom_gap_id            = @gap_id,
         @candidate_title          = NULL,
         @candidate_summary        = N'Reproduced from _diag_task_autocreate_reproduce.sql',
         @severity_code            = NULL,
         @severity_name            = NULL,
         @impact_summary           = NULL,
         @likelihood_summary       = NULL,
         @requested_by_employee_id = @analyst,
         @caller_display_name      = N'diagnostic';
    PRINT 'Risk trigger completed without error.';
END TRY
BEGIN CATCH
    SELECT 'RISK TRIGGER FAILED' AS Trigger_,
           ERROR_NUMBER()  AS ErrorNumber,
           ERROR_MESSAGE() AS ErrorMessage,
           ERROR_PROCEDURE() AS FailedIn,
           ERROR_LINE()    AS AtLine;
END CATCH

PRINT '';
PRINT '========== WHAT EXISTS NOW FOR THIS GAP ==========';
SELECT 'Task (practice_task)' AS Artefact, COUNT(*) AS Rows_
FROM   grac_practice.practice_task
WHERE  subject_entity_type = N'CustomGap' AND subject_entity_id = @gap_id
UNION ALL
SELECT 'Risk candidate', COUNT(*)
FROM   grac_practice.risk_candidate    WHERE custom_gap_id = @gap_id
UNION ALL
SELECT 'Exception request', COUNT(*)
FROM   grac_practice.exception_request WHERE custom_gap_id = @gap_id;
GO
