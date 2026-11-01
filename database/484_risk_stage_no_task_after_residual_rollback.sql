-- =====================================================================
-- 484_risk_stage_no_task_after_residual_rollback.sql
-- Restores the 299 vw_pm_risk_workflow_stage body verbatim (as CREATE OR
-- ALTER). A treated risk with no treatment task reads InTreatment again
-- even after residual / acceptance. SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
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
         WHEN r.treatment_option_code IN (N''Terminate'', N''Treat'', N''Transfer'')
          AND ISNULL(tt.TaskCount, 0) = 0                      THEN N''InTreatment''
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

SELECT '484 rollback' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage')) NOT LIKE '%CHANGED IN 484%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
GO
