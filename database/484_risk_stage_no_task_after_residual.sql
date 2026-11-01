-- =====================================================================
-- 484 Risk stage: a treated risk with no treatment task is not stuck
--     "In treatment" after its residual assessment
--
-- FOUND 2026-10-23 (SR, R-002, risk_register_id 38): Treat / Reduce was
-- chosen with "Generate a treatment task?" = No (418), residual was
-- assessed and the risk was ACCEPTED -- yet the Risk Register shows it
-- "In treatment".
--
-- WHY
--   vw_pm_risk_workflow_stage (299) tests, before ResidualDue and before
--   the acceptance branches:
--       Terminate/Treat/Transfer AND no treatment task at all -> InTreatment
--   That meant "the treatment task has not been raised yet" when every
--   treatment decision raised one (263). 418 made the task optional, so
--   with the task declined this branch matches forever and nothing after
--   it -- ResidualDue, AcceptanceDue, Accepted -- is ever reached.
--
-- FIX (one condition, nothing else in the view changes)
--   The branch now also needs residual_pending = 1. Before the residual
--   assessment a no-task treated risk still reads InTreatment (the
--   Residual page is reachable from InTreatment, as before); once the
--   residual is assessed it goes on to AcceptanceDue / Accepted, exactly
--   like a treated risk whose tasks are closed. Risks WITH treatment
--   tasks are unaffected (they never matched this branch).
--
-- CREATE OR ALTER keeps permissions; no drop. The view is read by
-- sp_risk_register_list / _get, sp_risk_acceptance_get and the risk
-- dashboard -- the stage column's name and values are unchanged.
-- Rollback: 484_risk_stage_no_task_after_residual_rollback.sql (299 view).
-- Idempotent. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage','V') IS NULL
   OR COL_LENGTH('grac_practice.risk_register','residual_pending') IS NULL
   OR COL_LENGTH('grac_practice.risk_register','treatment_option_code') IS NULL
   OR OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NULL
BEGIN
    RAISERROR('484 ABORT: vw_pm_risk_workflow_stage / risk_register residual and treatment columns missing -- run 258, 263, 299 first.', 16, 1);
    SET NOEXEC ON;
END
GO

EXEC sp_executesql N'
CREATE OR ALTER VIEW grac_practice.vw_pm_risk_workflow_stage AS
WITH tt AS (
    SELECT r.risk_register_id,
           -- Parents only. BRD 11: the parent owns the commitment, so a
           -- parent with two open children is ONE open treatment task.
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
         -- CHANGED IN 296. Tolerate is now decided ENTIRELY here, by a
         -- nested CASE, instead of falling through when it does not
         -- match.
         --
         -- 264 wrote this branch as "Tolerate AND accepted_dt IS NULL",
         -- which is right until the risk IS accepted -- after that it
         -- falls past Tolerate, past both InTreatment tests (Tolerate is
         -- in neither list) and lands on ResidualDue. Nothing ever
         -- clears residual_pending for a Tolerate risk, because a
         -- Tolerate risk never HAS a residual assessment -- that is the
         -- very reason this branch sits above that check. So every
         -- accepted Tolerate risk has been reading "ResidualDue",
         -- waiting forever on an assessment it will never receive.
         --
         -- Owning the option outright fixes that and the review case in
         -- one move: a Tolerate risk is AcceptanceDue or Accepted, and
         -- can no longer reach a branch that does not apply to it.
         WHEN r.treatment_option_code = N''Tolerate''
              THEN CASE WHEN r.accepted_dt IS NULL
                          OR r.status_code = N''Monitoring''
                         THEN N''AcceptanceDue''
                        ELSE N''Accepted'' END
         WHEN r.treatment_option_code IN (N''Terminate'', N''Treat'', N''Transfer'')
          AND ISNULL(tt.OpenCount, 0) > 0                      THEN N''InTreatment''
         -- CHANGED IN 484. "Option chosen, no treatment task yet" means
         -- the treatment is still to be raised -- but since 418 a task can
         -- be DECLINED, so with no task this branch held the risk at
         -- InTreatment for good, even once residual was assessed and the
         -- risk accepted. It now applies only until the residual
         -- assessment is done; after that the risk moves on to
         -- acceptance like any treated risk.
         WHEN r.treatment_option_code IN (N''Terminate'', N''Treat'', N''Transfer'')
          AND ISNULL(tt.TaskCount, 0) = 0
          AND ISNULL(r.residual_pending, 1) = 1                THEN N''InTreatment''
         WHEN ISNULL(r.residual_pending, 1) = 1                THEN N''ResidualDue''
         -- CHANGED IN 296. Acceptance REQUIRES a next review date
         -- (56601), so every accepted risk has one; a ready risk without
         -- one can only be a risk a review cleared, and it is waiting to
         -- be accepted again.
         WHEN r.accepted_dt IS NULL
           OR r.status_code = N''Monitoring''                   THEN N''AcceptanceDue''
         ELSE N''Accepted''
       END AS workflow_stage_code
  FROM grac_practice.risk_register r
  LEFT JOIN tt ON tt.risk_register_id = r.risk_register_id;';
GO

SELECT '484 view carries the residual condition' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage'))
                 LIKE '%TaskCount, 0) = 0%residual_pending, 1) = 1%InTreatment%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_;

-- Risks whose stage this changes: treated, no treatment task, residual done.
SELECT r.organization_id AS OrganizationId, r.risk_register_id AS RiskRegisterId, r.risk_number AS RiskNumber,
       r.status_code AS StatusCode, s.workflow_stage_code AS StageNow
FROM   grac_practice.risk_register r
JOIN   grac_practice.vw_pm_risk_workflow_stage s ON s.risk_register_id = r.risk_register_id
WHERE  r.treatment_option_code IN (N'Terminate', N'Treat', N'Transfer')
  AND  s.treatment_task_count = 0
  AND  ISNULL(r.residual_pending, 1) = 0
  AND  r.status_code NOT IN (N'Closed', N'Retired')
ORDER  BY r.organization_id, r.risk_register_id;

PRINT '484 complete. No API or Web change needed -- refresh the Risk Register.';
GO

SET NOEXEC OFF;
GO
