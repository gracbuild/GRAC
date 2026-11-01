-- _diag_task_recurring_evidence.sql  (READ-ONLY; SSMS against the Practice Management DB)
-- "Complete task does not list the recurring evidence" (482) -- where does
-- the chain stop? Set @task_number (as shown in Task Board, e.g. T-4-23).
SET NOCOUNT ON;
DECLARE @task_number NVARCHAR(50) = N'T-4-23';

-- 0. Is 482 installed?  All four must be YES.
SELECT N'0 482 installed' AS Step,
       CASE WHEN COL_LENGTH('grac_practice.evidence_link','instance_evidence_id') IS NOT NULL THEN N'YES' ELSE N'NO' END AS LinkColumn,
       CASE WHEN OBJECT_ID('grac_practice.practice_task_evidence_response','U') IS NOT NULL THEN N'YES' ELSE N'NO' END AS ResponseTable,
       CASE WHEN OBJECT_ID('grac_practice.fn_pm_task_recurring_evidence') IS NOT NULL THEN N'YES' ELSE N'NO' END AS RecurringFn,
       CASE WHEN OBJECT_ID('grac_practice.sp_task_recurring_evidence_list','P') IS NOT NULL THEN N'YES' ELSE N'NO' END AS ListProc;

DECLARE @task_id BIGINT, @org BIGINT;
SELECT @task_id = task_id, @org = organization_id FROM grac_practice.practice_task WHERE task_number = @task_number;

-- 1. The task: source must be Schedule, source_record_id = the occurrence.
SELECT N'1 task' AS Step, t.task_id, t.organization_id, t.task_number, t.source_type_code, t.source_record_id,
       t.linked_instance_id, t.closed_at
FROM   grac_practice.practice_task t WHERE t.task_id = @task_id;

-- 2. The occurrence: practice_instance_obligation_id NULL = an
--    instance-level schedule rule (no obligation to take evidence from).
SELECT N'2 occurrence' AS Step, x.occurrence_task_id, x.schedule_rule_id, x.occurrence_date,
       x.practice_instance_id, x.practice_instance_obligation_id,
       pio.obligation_id, pio.obligation_name, pio.status AS obligation_status
FROM   grac_practice.practice_task t
JOIN   grac_practice.schedule_occurrence_task x ON x.occurrence_task_id = t.source_record_id
LEFT   JOIN grac_practice.practice_instance_obligation pio
       ON pio.practice_instance_obligation_id = x.practice_instance_obligation_id
WHERE  t.task_id = @task_id;

-- 3. Every evidence row of the instance, with its cadence and whether it
--    belongs to the occurrence's obligation. Listed on Complete Task only
--    when BelongsToObligation = YES and EvidenceCadence = Recurring.
SELECT N'3 instance evidence' AS Step, e.evidence_id, e.status, e.source_obligation_id,
       e.source_practice_instance_obligation_id,
       COALESCE(NULLIF(LTRIM(RTRIM(e.evidence_name)), N''), et.evidence_type_name) AS EvidenceName,
       cad.EvidenceCadence, cad.CadenceSource,
       CASE WHEN (pio.obligation_id IS NOT NULL AND e.source_obligation_id = pio.obligation_id)
              OR e.source_practice_instance_obligation_id = pio.practice_instance_obligation_id
            THEN N'YES' ELSE N'NO' END AS BelongsToObligation
FROM   grac_practice.practice_task t
JOIN   grac_practice.schedule_occurrence_task x ON x.occurrence_task_id = t.source_record_id
LEFT   JOIN grac_practice.practice_instance_obligation pio
       ON pio.practice_instance_obligation_id = x.practice_instance_obligation_id
JOIN   grac_practice.practice_instance_evidence e ON e.practice_instance_id = x.practice_instance_id
LEFT   JOIN grac_practice.evidence_type_master et ON et.evidence_type_id = e.evidence_type_id
LEFT   JOIN grac_practice.vw_pm_instance_evidence_cadence cad ON cad.evidence_id = e.evidence_id
WHERE  t.task_id = @task_id
ORDER  BY e.source_obligation_id, e.evidence_id;

-- 4. What the Complete Task dialog receives (needs 482).
IF OBJECT_ID('grac_practice.sp_task_recurring_evidence_list','P') IS NOT NULL AND @task_id IS NOT NULL
    EXEC grac_practice.sp_task_recurring_evidence_list @task_id = @task_id, @organization_id = @org;
