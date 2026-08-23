/*
  Practice Management — Task Candidate (Phase 2) UAT diagnostics
  Runs after 12_UAT_Diagnostics_TaskCentreV2.sql. Verifies migrations
  197-200 (GRAC Task Centre Incremental Enhancement BRD v1.1).

  Read-only. Safe anywhere, any number of times.
  Docs: docs/task-centre-v2.md
*/
SET NOCOUNT ON;

PRINT '=== 197 schema ===';

SELECT 'task_candidate + history present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.task_candidate','U')        IS NOT NULL
             AND OBJECT_ID('grac_practice.task_candidate_history','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'practice_task <-> task_candidate link' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.practice_task','task_candidate_id') IS NOT NULL
             AND COL_LENGTH('grac_practice.task_candidate','approved_task_id')  IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

/* The dedupe index is what reconciles BRD §15 (one source -> many tasks)
   with idempotent auto-generation. Its filter MUST exclude NULL keys,
   otherwise manual additions would collide. */
SELECT 'dedupe index excludes NULL keys' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1 FROM sys.indexes
            WHERE name = 'ux_pm_task_candidate_source_dedupe'
              AND has_filter = 1
              AND filter_definition LIKE '%source_dedupe_key%')
           THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '=== 198 lifecycle procedures ===';

SELECT 'Phase 2 procedures present' AS Check_, ProcName, Result FROM (
    SELECT 'sp_task_candidate_create'        AS ProcName, CASE WHEN OBJECT_ID('grac_practice.sp_task_candidate_create','P')        IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
    UNION ALL SELECT 'sp_task_candidate_apply_sla',     CASE WHEN OBJECT_ID('grac_practice.sp_task_candidate_apply_sla','P')     IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_candidate_list',          CASE WHEN OBJECT_ID('grac_practice.sp_task_candidate_list','P')          IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_candidate_get',           CASE WHEN OBJECT_ID('grac_practice.sp_task_candidate_get','P')           IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_candidate_validate_save', CASE WHEN OBJECT_ID('grac_practice.sp_task_candidate_validate_save','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_candidate_approve',       CASE WHEN OBJECT_ID('grac_practice.sp_task_candidate_approve','P')       IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_candidate_discard',       CASE WHEN OBJECT_ID('grac_practice.sp_task_candidate_discard','P')       IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_candidate_counts',        CASE WHEN OBJECT_ID('grac_practice.sp_task_candidate_counts','P')        IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_source_items',            CASE WHEN OBJECT_ID('grac_practice.sp_task_source_items','P')            IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_source_sync',             CASE WHEN OBJECT_ID('grac_practice.sp_task_source_sync','P')             IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_source_action_state_get', CASE WHEN OBJECT_ID('grac_practice.sp_task_source_action_state_get','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
) x;

/* sp_task_candidate_create is called from inside three source procs that
   each emit their own result set. If it ever SELECTs, every one of those
   callers silently binds the wrong result set. The contract is OUTPUT. */
SELECT 'sp_task_candidate_create is OUTPUT-only' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_task_candidate_create')
                            AND name = '@task_candidate_id' AND is_output = 1)
             AND EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_task_candidate_create')
                            AND name = '@created' AND is_output = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '=== 199 source integrations ===';

/* Each rewrite must remain a strict superset — original parameters intact
   so no caller anywhere needs changing. */
SELECT 'source procs keep original parameters' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_custom_gap_task_create')
                            AND name = '@assigned_to_employee_id')
             AND EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_candidate_accept')
                            AND name = '@formal_risk_ref')
             AND EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_org_assurance_observation_accept')
                            AND name = '@notes')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'source procs gained the opt-out switch' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_candidate_accept')
                            AND name = '@raise_task_candidate')
             AND EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_org_assurance_observation_accept')
                            AND name = '@raise_task_candidate')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

/* 174 must NOT have been touched — the reroute happens at the seam. */
SELECT 'sp_custom_gap_analysis_save still calls the seam' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1 FROM sys.sql_modules m
            WHERE m.object_id = OBJECT_ID('grac_practice.sp_custom_gap_analysis_save')
              AND m.definition LIKE '%sp_custom_gap_task_create%')
           THEN 'PASS' ELSE 'REVIEW — the gap analysis proc no longer calls the seam' END AS Result;

PRINT '=== 200 upstream sync ===';

SELECT 'task_source_action_state present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.task_source_action_state','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '=== data health ===';

/* BRD §5: an Approved candidate must point at the task it became, and
   nothing else may. The CHECK enforces it; this proves it holds. */
SELECT 'approved candidates without a task (expect 0)' AS Check_,
       COUNT(*) AS Rows_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS Result
  FROM grac_practice.task_candidate
 WHERE status_code = N'Approved' AND approved_task_id IS NULL;

/* The link must agree in both directions. */
SELECT 'candidate/task back-references disagreeing (expect 0)' AS Check_,
       COUNT(*) AS Rows_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS Result
  FROM grac_practice.task_candidate c
  JOIN grac_practice.practice_task  t ON t.task_id = c.approved_task_id
 WHERE ISNULL(t.task_candidate_id, -1) <> c.task_candidate_id;

/* Duplicate open candidates for the same source AND key would mean the
   dedupe index is missing or the generators are bypassing it. */
SELECT 'duplicate open candidates per source+key (expect 0)' AS Check_,
       COUNT(*) AS Rows_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS Result
  FROM (
        SELECT source_type_code, source_record_id, source_dedupe_key
          FROM grac_practice.task_candidate
         WHERE source_dedupe_key IS NOT NULL
           AND status_code IN (N'New', N'Validated')
         GROUP BY source_type_code, source_record_id, source_dedupe_key
        HAVING COUNT(*) > 1
       ) d;

/* An approved candidate whose task has a different source than the
   candidate did would break BRD §15 navigation in both directions. */
SELECT 'approved tasks whose source differs from the candidate (expect 0)' AS Check_,
       COUNT(*) AS Rows_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS Result
  FROM grac_practice.task_candidate c
  JOIN grac_practice.practice_task  t ON t.task_id = c.approved_task_id
 WHERE ISNULL(t.source_type_code, N'') <> c.source_type_code
    OR ISNULL(t.source_record_id, -1)  <> c.source_record_id;

/* §14: the reported state must match reality. A mismatch means
   sp_task_source_sync has not run for that source — re-running 200 or
   calling the proc directly repairs it. */
SELECT 'source action state out of step with tasks (expect 0)' AS Check_,
       COUNT(*) AS Rows_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'REVIEW' END AS Result
  FROM grac_practice.task_source_action_state s
 CROSS APPLY (
        SELECT COUNT(*) AS Total,
               SUM(CASE WHEN t.closed_at IS NULL THEN 1 ELSE 0 END) AS Open_
          FROM grac_practice.practice_task t
         WHERE t.source_type_code = s.source_type_code
           AND t.source_record_id = s.source_record_id
           AND t.parent_task_id IS NULL
       ) live
 WHERE live.Total <> s.total_tasks
    OR ISNULL(live.Open_, 0) <> s.open_tasks;

/* Informational: where identified work currently sits. A large
   New/unowned bucket means the owner ladder has thin master data to work
   with, not that anything is broken. */
SELECT 'candidates by status' AS Check_,
       status_code AS StatusCode,
       COUNT(*)    AS Candidates_,
       SUM(CASE WHEN proposed_owner_employee_id IS NULL THEN 1 ELSE 0 END) AS Unowned_
  FROM grac_practice.task_candidate
 GROUP BY status_code
 ORDER BY COUNT(*) DESC;

SELECT 'candidates by source' AS Check_,
       source_type_code AS SourceTypeCode,
       COUNT(*)         AS Candidates_
  FROM grac_practice.task_candidate
 GROUP BY source_type_code
 ORDER BY COUNT(*) DESC;

SELECT 'source action state' AS Check_,
       source_type_code   AS SourceTypeCode,
       action_status_code AS ActionStatusCode,
       COUNT(*)           AS Sources_
  FROM grac_practice.task_source_action_state
 GROUP BY source_type_code, action_status_code
 ORDER BY source_type_code, action_status_code;

PRINT '13_UAT_Diagnostics_TaskCandidate complete.';
PRINT 'NOT WIRED by design: Event Assurance, Exception. See conflicts 4 and 5 in docs/task-centre-v2.md.';
