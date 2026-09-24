-- =====================================================================
-- Diagnostic: gap 1 -- why no Task and no Risk were created
--
-- Nothing to edit. The gap id is set from what you already found:
--   custom_gap_id = 1, "Maintain topic-specific policies-ISM", org 2, Open
--
-- Environment is already ruled out. All six procedures are deployed, the
-- save procedure carries both decision parameters and all three
-- triggers, risk_source_master has an Active 'Gap' row, task_type_master
-- has an active 'Rectification', and the Task lifecycle is seeded. The
-- gap has an organization and a title, so neither trigger can fail on
-- 53720 / 56201.
--
-- What is left is per-gap, and section 1 below decides it.
--
-- READ-ONLY. Nothing here writes.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @custom_gap_id BIGINT = 1;

PRINT '===== 1. Did the decision answers actually store as Y? =====';
PRINT '      remediation_possible = Y is what fires the Task trigger.';
PRINT '      business_risk_present = Y is what fires the Risk trigger.';
PRINT '      Anything other than Y here means the UI did not send what';
PRINT '      you selected -- a frontend problem, not the triggers.';

IF NOT EXISTS (SELECT 1 FROM grac_practice.custom_gap_analysis
                WHERE custom_gap_id = @custom_gap_id)
    SELECT 'NO ANALYSIS ROW AT ALL for this gap -- the save never reached the table.' AS Finding;
ELSE
    SELECT a.custom_gap_id,
           a.remediation_possible   AS RemediationPossible,
           CASE WHEN a.remediation_possible = 'Y' THEN 'Task trigger SHOULD have run'
                WHEN a.remediation_possible = 'N' THEN 'Exception trigger runs instead -- no Task by design'
                ELSE 'NOT ANSWERED -- neither trigger runs' END          AS TaskVerdict,
           a.business_risk_present  AS BusinessRiskPresent,
           CASE WHEN a.business_risk_present = 'Y' THEN 'Risk trigger SHOULD have run'
                ELSE 'Not Y -- Risk trigger does not run' END            AS RiskVerdict,
           a.recommend_task,
           a.recommend_risk,
           a.recommend_exception,
           a.analysed_by_employee_id,
           a.analysed_on
    FROM   grac_practice.custom_gap_analysis a
    WHERE  a.custom_gap_id = @custom_gap_id;

PRINT '';
PRINT '===== 2. What exists downstream for this gap =====';
PRINT '      If these are NOT zero, the artefacts were created and the';
PRINT '      problem is visibility in the Centres, not creation.';
SELECT 'Task (practice_task, subject CustomGap)' AS Artefact,
       COUNT(*)                                  AS Rows_
FROM   grac_practice.practice_task
WHERE  subject_entity_type = N'CustomGap'
  AND  subject_entity_id   = @custom_gap_id
UNION ALL
SELECT 'Risk candidate', COUNT(*)
FROM   grac_practice.risk_candidate    WHERE custom_gap_id = @custom_gap_id
UNION ALL
SELECT 'Exception request', COUNT(*)
FROM   grac_practice.exception_request WHERE custom_gap_id = @custom_gap_id;

PRINT '';
PRINT '===== 3. If a Task row DOES exist, why the Centre may not show it =====';
SELECT t.task_id,
       t.subject_entity_type,
       t.subject_entity_id,
       t.organization_id,
       t.assigned_to_employee_id,
       t.closed_at,
       CASE WHEN t.closed_at IS NOT NULL THEN 'Closed -- Task Centre hides it by default'
            WHEN t.assigned_to_employee_id IS NULL THEN 'Unassigned -- may not appear in a "my tasks" view'
            ELSE 'Open and assigned' END AS Note
FROM   grac_practice.practice_task t
WHERE  t.subject_entity_type = N'CustomGap'
  AND  t.subject_entity_id   = @custom_gap_id;

PRINT '';
PRINT '===== 4. If a Risk candidate DOES exist, the same question =====';
-- The column is status_code, not status (169_risk_centre_schema.sql);
-- source_type_code was added later, by 207.
SELECT c.risk_candidate_id,
       c.organization_id,
       c.source_type_code,
       c.status_code,
       c.candidate_title,
       c.requested_by_employee_id,
       c.requested_dt
FROM   grac_practice.risk_candidate c
WHERE  c.custom_gap_id = @custom_gap_id;
GO
