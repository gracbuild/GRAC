/*
  Practice Management — Task Centre v2 UAT diagnostics
  Runs after 11_UAT_Diagnostics_EventScope.sql. Verifies migrations 192-196
  (GRAC Task Centre Incremental Enhancement BRD v1.1, 16 Aug 2026).

  Read-only. Safe to run against any environment, any number of times.
  Docs: docs/task-centre-v2.md
*/
SET NOCOUNT ON;

PRINT '=== 192 schema ===';

SELECT 'practice_task governance columns' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.practice_task','parent_task_id')            IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','is_mandatory_child')         IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','child_target_date')          IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','standard_sla_days')          IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','standard_due_at')            IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','approved_extended_due_at')   IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','sla_source_code')            IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','extension_status_code')      IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','requested_due_at')           IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','requested_priority')         IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','priority_change_status_code') IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','source_type_code')           IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','source_record_id')           IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','owner_source_code')          IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','completed_by_employee_id')   IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','completed_dt')               IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'new tables present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.task_activity','U')         IS NOT NULL
             AND OBJECT_ID('grac_practice.task_attachment','U')        IS NOT NULL
             AND OBJECT_ID('grac_practice.org_task_default_owner','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'exception_request is task-aware' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.exception_request','task_id')            IS NOT NULL
             AND COL_LENGTH('grac_practice.exception_request','due_at_original')     IS NOT NULL
             AND COL_LENGTH('grac_practice.exception_request','due_at_requested')    IS NOT NULL
             AND COL_LENGTH('grac_practice.exception_request','priority_original')   IS NOT NULL
             AND COL_LENGTH('grac_practice.exception_request','priority_requested')  IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.exception_request')
                            AND name = 'custom_gap_id' AND is_nullable = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

/* The widened CHECK must accept the two task request types. Probing the
   definition text is enough — actually inserting a probe row would leave
   rubbish behind in a UAT database. */
SELECT 'request_type_code CHECK widened' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1 FROM sys.check_constraints
            WHERE name = 'ck_pm_exception_request_type'
              AND definition LIKE '%TASK_SLA_EXTENSION%'
              AND definition LIKE '%TASK_PRIORITY_REDUCTION%')
           THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'one-pending-per-task indexes' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                          WHERE name = 'ux_pm_exception_request_task_sla_pending')
             AND EXISTS (SELECT 1 FROM sys.indexes
                          WHERE name = 'ux_pm_exception_request_task_prio_pending')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '=== 193 / 194 procedures ===';

SELECT 'Task Centre v2 procedures present' AS Check_, ProcName, Result FROM (
    SELECT 'fn_task_employee_by_name'            AS ProcName, CASE WHEN OBJECT_ID('grac_practice.fn_task_employee_by_name','FN')           IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
    UNION ALL SELECT 'sp_task_owner_resolve',              CASE WHEN OBJECT_ID('grac_practice.sp_task_owner_resolve','P')                IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_org_sla_match_for_priority',      CASE WHEN OBJECT_ID('grac_practice.sp_org_sla_match_for_priority','P')        IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_apply_sla',                  CASE WHEN OBJECT_ID('grac_practice.sp_task_apply_sla','P')                    IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_activity_add',               CASE WHEN OBJECT_ID('grac_practice.sp_task_activity_add','P')                 IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_attachment_add',             CASE WHEN OBJECT_ID('grac_practice.sp_task_attachment_add','P')               IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_attachment_get',             CASE WHEN OBJECT_ID('grac_practice.sp_task_attachment_get','P')               IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_priority_change',            CASE WHEN OBJECT_ID('grac_practice.sp_task_priority_change','P')              IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_priority_reduction_approve', CASE WHEN OBJECT_ID('grac_practice.sp_task_priority_reduction_approve','P')   IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_sla_extension_request_create',CASE WHEN OBJECT_ID('grac_practice.sp_task_sla_extension_request_create','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_sla_extension_approve',      CASE WHEN OBJECT_ID('grac_practice.sp_task_sla_extension_approve','P')        IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_child_create',               CASE WHEN OBJECT_ID('grac_practice.sp_task_child_create','P')                 IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_completion_eligibility',     CASE WHEN OBJECT_ID('grac_practice.sp_task_completion_eligibility','P')       IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_complete',                   CASE WHEN OBJECT_ID('grac_practice.sp_task_complete','P')                     IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_get',                        CASE WHEN OBJECT_ID('grac_practice.sp_task_get','P')                          IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_source_tasks',               CASE WHEN OBJECT_ID('grac_practice.sp_task_source_tasks','P')                 IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
) x;

/* sp_task_activity_add must NOT return a result set — several callers
   emit their own summary row afterwards and an extra leading result set
   would silently mis-bind every ADO.NET caller. The contract is the
   OUTPUT parameter. */
SELECT 'sp_task_activity_add returns via OUTPUT' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_task_activity_add')
                            AND name = '@task_activity_id' AND is_output = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '=== 195 read layer ===';

SELECT 'view exposes v2 columns' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task') AND name = 'sla_status_code')
             AND EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task') AND name = 'sla_timing_code')
             AND EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task') AND name = 'standard_due_at')
             AND EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task') AND name = 'approved_extended_due_at')
             AND EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task') AND name = 'is_eligible_for_completion')
             AND EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task') AND name = 'assigned_to_employee_name')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

/* 048 columns must survive — v2 is additive, not a replacement. */
SELECT 'view retains 048 columns' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task') AND name = 'task_number')
             AND EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task') AND name = 'related_entity_type_code')
             AND EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task') AND name = 'is_overdue')
             AND EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task') AND name = 'workflow_id')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'sp_task_list accepts v2 filters' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('grac_practice.sp_task_list') AND name = '@include_children')
             AND EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('grac_practice.sp_task_list') AND name = '@sla_status_code')
             AND EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('grac_practice.sp_task_list') AND name = '@source_type_code')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '=== 196 sp_task_open v3 ===';

SELECT 'sp_task_open v3 params' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('grac_practice.sp_task_open') AND name = '@source_type_code')
             AND EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('grac_practice.sp_task_open') AND name = '@resolve_owner')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'sp_task_open retains all 048 params' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM sys.parameters
                   WHERE object_id = OBJECT_ID('grac_practice.sp_task_open')
                     AND name IN ('@organization_id','@task_type_code','@subject_entity_type',
                                  '@subject_entity_id','@subject_title','@subject_description',
                                  '@linked_release_id','@linked_control_id','@linked_practice_id',
                                  '@linked_instance_id','@priority','@criticality','@origin_code',
                                  '@assigned_to_employee_id','@actor_employee_id','@actor_role_code',
                                  '@correlation_id','@related_entity_type_code','@related_record_id',
                                  '@start_date','@target_date','@workflow_id',
                                  '@current_workflow_stage_id','@assurance_activity_id','@task_id')) = 25
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '=== data health ===';

/* Backfill from 192: every task that had a due date should now carry a
   standard commitment, otherwise the SLA split has holes. */
SELECT 'tasks with sla_due_at but no standard_due_at (expect 0)' AS Check_,
       COUNT(*) AS Rows_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS Result
  FROM grac_practice.practice_task
 WHERE sla_due_at IS NOT NULL AND standard_due_at IS NULL;

/* The core invariant: sla_due_at = COALESCE(approved_extended, standard). */
SELECT 'tasks violating the effective-due invariant (expect 0)' AS Check_,
       COUNT(*) AS Rows_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'REVIEW' END AS Result
  FROM grac_practice.practice_task
 WHERE standard_due_at IS NOT NULL
   AND sla_due_at <> COALESCE(approved_extended_due_at, standard_due_at);

/* BRD §11: a child may never carry its own approved extension. */
SELECT 'child tasks with an independent extension (expect 0)' AS Check_,
       COUNT(*) AS Rows_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS Result
  FROM grac_practice.practice_task c
  JOIN grac_practice.practice_task p ON p.task_id = c.parent_task_id
 WHERE c.approved_extended_due_at IS NOT NULL
   AND (p.approved_extended_due_at IS NULL
        OR c.approved_extended_due_at <> p.approved_extended_due_at);

/* BRD §11: a child inherits the parent priority. */
SELECT 'child tasks whose priority diverges from the parent (expect 0)' AS Check_,
       COUNT(*) AS Rows_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS Result
  FROM grac_practice.practice_task c
  JOIN grac_practice.practice_task p ON p.task_id = c.parent_task_id
 WHERE c.closed_at IS NULL AND c.priority <> p.priority;

/* Single-level rule. */
SELECT 'grandchild tasks (expect 0)' AS Check_,
       COUNT(*) AS Rows_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS Result
  FROM grac_practice.practice_task c
  JOIN grac_practice.practice_task p ON p.task_id = c.parent_task_id
 WHERE p.parent_task_id IS NOT NULL;

/* An orphaned Pending marker means a request was resolved without
   releasing the task — the operator would be stuck unable to retry. */
SELECT 'tasks marked Pending with no matching Pending request (expect 0)' AS Check_,
       COUNT(*) AS Rows_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS Result
  FROM grac_practice.practice_task t
 WHERE (t.extension_status_code = N'Pending'
        AND NOT EXISTS (SELECT 1 FROM grac_practice.exception_request r
                         WHERE r.task_id = t.task_id
                           AND r.request_type_code = N'TASK_SLA_EXTENSION'
                           AND r.status_code = N'Pending'))
    OR (t.priority_change_status_code = N'Pending'
        AND NOT EXISTS (SELECT 1 FROM grac_practice.exception_request r
                         WHERE r.task_id = t.task_id
                           AND r.request_type_code = N'TASK_PRIORITY_REDUCTION'
                           AND r.status_code = N'Pending'));

/* Informational: how much of the estate is running on the org SLA policy
   versus the legacy task-type default. A high TYPE_DEFAULT count means
   SLA masters have not been configured for those priorities yet. */
SELECT 'SLA provenance spread' AS Check_,
       ISNULL(sla_source_code, N'(none)') AS SlaSourceCode,
       COUNT(*) AS Tasks_
  FROM grac_practice.practice_task
 GROUP BY sla_source_code
 ORDER BY COUNT(*) DESC;

/* Informational: owner ladder effectiveness. A large MANUAL bucket means
   ownership master data is thin, not that the ladder is broken. */
SELECT 'owner resolution spread' AS Check_,
       ISNULL(owner_source_code, N'(none)') AS OwnerSourceCode,
       COUNT(*) AS Tasks_
  FROM grac_practice.practice_task
 GROUP BY owner_source_code
 ORDER BY COUNT(*) DESC;

PRINT '12_UAT_Diagnostics_TaskCentreV2 complete.';
