-- _diag_risk_workflow_stage.sql  (READ-ONLY; SSMS against the Practice Management DB)
-- "Why does this risk show <stage>?" -- e.g. a risk that was Accepted now
-- reads "In treatment" or "Treatment option due". The stage is not stored:
-- vw_pm_risk_workflow_stage (299) works it out every time from the columns
-- below, testing the branches IN THIS ORDER and stopping at the first match:
--   1 Closed            status Closed / Retired
--   2 ReviewDue         next_review_date reached
--   3 AnalysisDue       analysis_pending = 1
--   4 TreatmentDue      treatment_option_code IS NULL   ("Treatment option due")
--   5 Tolerate          AcceptanceDue / Accepted
--   6 InTreatment       Terminate/Treat/Transfer AND an OPEN treatment task
--   7 InTreatment       Terminate/Treat/Transfer AND NO treatment task at all
--   8 ResidualDue       residual_pending = 1
--   9 AcceptanceDue     accepted_dt NULL or status Monitoring
--  10 Accepted
-- Set @risk_number (as shown in the Risk Register). Risk numbers repeat
-- across organisations, so set @organization_id as well when step 0 lists
-- more than one match (or set @risk_register_id directly).
SET NOCOUNT ON;
DECLARE @risk_number      NVARCHAR(50) = N'';
DECLARE @organization_id  BIGINT       = NULL;
DECLARE @risk_register_id BIGINT       = NULL;

-- 0. Every risk this picks. Exactly one row is needed for the steps below.
SELECT N'0 match' AS Step, r.risk_register_id, r.organization_id, o.organization_name, r.risk_number, r.status_code
FROM   grac_practice.risk_register r
LEFT   JOIN grac_practice.organization o ON o.organization_id = r.organization_id
WHERE  (@risk_register_id IS NOT NULL AND r.risk_register_id = @risk_register_id)
   OR  (@risk_register_id IS NULL AND r.risk_number = @risk_number
        AND (@organization_id IS NULL OR r.organization_id = @organization_id));

DECLARE @rid BIGINT, @matches INT;
SELECT @matches = COUNT(*), @rid = MAX(r.risk_register_id)
FROM   grac_practice.risk_register r
WHERE  (@risk_register_id IS NOT NULL AND r.risk_register_id = @risk_register_id)
   OR  (@risk_register_id IS NULL AND r.risk_number = @risk_number
        AND (@organization_id IS NULL OR r.organization_id = @organization_id));
IF @matches <> 1
BEGIN
    PRINT CONCAT(N'Step 0 found ', @matches, N' risk(s). Set @organization_id (or @risk_register_id) from step 0 so exactly one is picked, then run again.');
    SET @rid = NULL;
END

-- 1. The columns the stage is computed from, the stage, and which branch decided it.
SELECT N'1 stage' AS Step, r.risk_register_id, r.risk_number, r.status_code,
       r.next_review_date, r.analysis_pending, r.treatment_option_code, r.treatment_decided_dt,
       r.residual_pending, r.accepted_dt, s.treatment_task_count, s.open_treatment_task_count,
       s.workflow_stage_code,
       CASE
         WHEN r.status_code IN (N'Closed', N'Retired') THEN N'1 closed / retired'
         WHEN r.next_review_date IS NOT NULL AND r.next_review_date <= CAST(SYSUTCDATETIME() AS DATE) THEN N'2 review date reached'
         WHEN ISNULL(r.analysis_pending, 1) = 1 THEN N'3 analysis pending'
         WHEN r.treatment_option_code IS NULL THEN N'4 NO treatment option on the risk'
         WHEN r.treatment_option_code = N'Tolerate' THEN N'5 Tolerate'
         WHEN r.treatment_option_code IN (N'Terminate', N'Treat', N'Transfer') AND s.open_treatment_task_count > 0
              THEN N'6 an OPEN treatment task (see step 2)'
         WHEN r.treatment_option_code IN (N'Terminate', N'Treat', N'Transfer') AND s.treatment_task_count = 0
              THEN N'7 treatment option chosen but NO treatment task exists'
         WHEN ISNULL(r.residual_pending, 1) = 1 THEN N'8 residual analysis pending'
         WHEN r.accepted_dt IS NULL OR r.status_code = N'Monitoring' THEN N'9 awaiting (re-)acceptance'
         ELSE N'10 accepted' END AS DecidedBy
FROM   grac_practice.risk_register r
JOIN   grac_practice.vw_pm_risk_workflow_stage s ON s.risk_register_id = r.risk_register_id
WHERE  r.risk_register_id = @rid;

-- 2. The risk's treatment tasks (the ones the view counts: parents only).
SELECT N'2 treatment task' AS Step, v.task_id, v.task_number, v.subject_title, v.source_type_code,
       v.parent_task_id, v.current_status_code, v.current_status_is_terminal, v.closed_at
FROM   grac_practice.risk_register r
JOIN   grac_practice.vw_pm_practice_task v
       ON v.organization_id = r.organization_id
      AND ((v.source_type_code = N'RiskRegister' AND v.source_record_id = r.risk_register_id)
        OR (r.risk_candidate_id IS NOT NULL AND v.source_type_code = N'Risk' AND v.source_record_id = r.risk_candidate_id))
WHERE  r.risk_register_id = @rid
ORDER  BY v.task_id;

-- 3. The risk's history, oldest first -- what happened after the acceptance.
SELECT N'3 history' AS Step, h.entered_dt, h.action_code, h.from_status_code, h.to_status_code,
       h.actor_display_name, h.remark
FROM   grac_practice.risk_register_history h
WHERE  h.risk_register_id = @rid
ORDER  BY h.entered_dt, h.history_id;
