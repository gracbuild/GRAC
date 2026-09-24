-- =====================================================================
-- 296_reviewed_risk_returns_to_acceptance_rollback.sql
--
-- Restores vw_pm_risk_workflow_stage to 264's definition: the two
-- AcceptanceDue branches stop testing next_review_date.
--
-- WHAT COMES BACK WITH IT -- BOTH DEFECTS
--   1. A reviewed risk -- status Monitoring, review date cleared,
--      accepted_dt still set from its last acceptance -- once again
--      reads stage 'Accepted' and appears on no work list: not on the
--      Review tab (no date), not on the Accept tab (accepted_dt is not
--      NULL).
--   2. Every ACCEPTED TOLERATE risk again reads 'ResidualDue', because
--      264's Tolerate branch is guarded by "accepted_dt IS NULL" and an
--      accepted one falls through to a residual check it can never
--      satisfy -- nothing clears residual_pending for a Tolerate risk.
--      Those risks disappear from the Accept tab's "Already accepted"
--      view and show a stage they can never leave.
--
--   Roll back only if 296 caused a worse problem than those two.
--
-- NO DATA CHANGE, IN EITHER DIRECTION. 296 wrote nothing; it changed how
-- a computed column is derived. Rolling back changes the derivation back
-- and touches no row. Any risk accepted through the Accept tab while 296
-- was in place stays accepted -- that was written by
-- sp_risk_acceptance_save, which this file does not touch.
--
-- ORDER: nothing else depends on 296. sp_risk_register_list,
-- sp_risk_register_get and sp_risk_acceptance_get join this view by
-- name and are unaffected by its body, so they need no re-issue.
--
-- Re-runnable: yes. ASCII-only (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
   OR OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NULL
BEGIN
    PRINT 'ABORT (296 rollback): prerequisites missing -- the view cannot be rebuilt.';
    RAISERROR('296 rollback: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage','V') IS NOT NULL
    DROP VIEW grac_practice.vw_pm_risk_workflow_stage;
GO

-- 264's definition, verbatim.
EXEC sp_executesql N'
CREATE VIEW grac_practice.vw_pm_risk_workflow_stage AS
WITH tt AS (
    SELECT r.risk_register_id,
           SUM(CASE WHEN v.parent_task_id IS NULL THEN 1 ELSE 0 END) AS TaskCount,
           SUM(CASE WHEN v.parent_task_id IS NULL
                     AND v.closed_at IS NULL
                     AND v.current_status_is_terminal = 0
                    THEN 1 ELSE 0 END)                               AS OpenCount
      FROM grac_practice.risk_register r
      JOIN grac_practice.vw_pm_practice_task v
        ON v.organization_id = r.organization_id
       AND ((v.source_type_code = N''RiskRegister''
             AND v.source_record_id = r.risk_register_id)
         OR (r.risk_candidate_id IS NOT NULL
             AND v.source_type_code = N''Risk''
             AND v.source_record_id = r.risk_candidate_id))
     GROUP BY r.risk_register_id
)
SELECT r.risk_register_id,
       r.organization_id,
       ISNULL(tt.TaskCount, 0) AS treatment_task_count,
       ISNULL(tt.OpenCount, 0) AS open_treatment_task_count,
       CAST(CASE WHEN r.next_review_date IS NOT NULL
                  AND r.next_review_date <= CAST(SYSUTCDATETIME() AS DATE)
                  AND r.status_code NOT IN (N''Closed'', N''Retired'')
                 THEN 1 ELSE 0 END AS BIT) AS is_review_due,
       CASE
         WHEN r.status_code IN (N''Closed'', N''Retired'')      THEN N''Closed''
         WHEN r.next_review_date IS NOT NULL
          AND r.next_review_date <= CAST(SYSUTCDATETIME() AS DATE)
                                                               THEN N''ReviewDue''
         WHEN ISNULL(r.analysis_pending, 1) = 1                THEN N''AnalysisDue''
         WHEN r.treatment_option_code IS NULL                  THEN N''TreatmentDue''
         WHEN r.treatment_option_code = N''Tolerate''
          AND r.accepted_dt IS NULL                            THEN N''AcceptanceDue''
         WHEN r.treatment_option_code IN (N''Terminate'', N''Treat'', N''Transfer'')
          AND ISNULL(tt.OpenCount, 0) > 0                      THEN N''InTreatment''
         WHEN r.treatment_option_code IN (N''Terminate'', N''Treat'', N''Transfer'')
          AND ISNULL(tt.TaskCount, 0) = 0                      THEN N''InTreatment''
         WHEN ISNULL(r.residual_pending, 1) = 1                THEN N''ResidualDue''
         WHEN r.accepted_dt IS NULL                            THEN N''AcceptanceDue''
         ELSE N''Accepted''
       END AS workflow_stage_code
  FROM grac_practice.risk_register r
  LEFT JOIN tt ON tt.risk_register_id = r.risk_register_id;';
GO

IF OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage','V') IS NULL
BEGIN
    PRINT '*** ABORT (296 rollback): the view was NOT recreated. Re-run 264.';
    RAISERROR('296 rollback: the view was dropped and not recreated.', 16, 1);
    SET NOEXEC ON;
END
GO

SELECT '296 rollback: view restored to 264' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage','V') IS NOT NULL
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

SELECT '296 rollback: the stranding defect is back' AS Check_,
       CONCAT((SELECT COUNT(*)
                 FROM grac_practice.risk_register r
                WHERE r.accepted_dt IS NOT NULL
                  AND r.next_review_date IS NULL
                  AND r.status_code NOT IN (N'Closed', N'Retired')),
              ' reviewed risk(s) are now on no work list again') AS Result;
GO

PRINT '296 rollback: vw_pm_risk_workflow_stage restored to 264. No rows were changed.';
GO

SET NOEXEC OFF;
GO
