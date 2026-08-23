/*
  Practice Management — Task notification (Phase 3) UAT diagnostics
  Runs after 13_UAT_Diagnostics_TaskCandidate.sql. Verifies migrations
  201-202 (GRAC Task Centre Incremental Enhancement BRD v1.1 §13).

  Read-only. Safe anywhere, any number of times.
  Docs: docs/task-centre-v2.md
*/
SET NOCOUNT ON;

PRINT '=== 201 schema ===';

SELECT 'task_notification_outbox present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.task_notification_outbox','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

/* The dedupe key MUST include due_at_key. Without it an approved SLA
   extension could never re-arm the notification sequence — a task warned
   about in January would stay silent after being extended to June, which
   is precisely when a reminder matters most. */
SELECT 'dedupe key includes due_at_key' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1
             FROM sys.indexes i
             JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
             JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            WHERE i.name = 'ux_pm_task_notification_dedupe'
              AND i.is_unique = 1
              AND c.name = 'due_at_key')
           THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '=== 202 procedures ===';

SELECT 'Phase 3 procedures present' AS Check_, ProcName, Result FROM (
    SELECT 'sp_task_notification_enqueue' AS ProcName, CASE WHEN OBJECT_ID('grac_practice.sp_task_notification_enqueue','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
    UNION ALL SELECT 'sp_task_notification_sweep',  CASE WHEN OBJECT_ID('grac_practice.sp_task_notification_sweep','P')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_notification_list',   CASE WHEN OBJECT_ID('grac_practice.sp_task_notification_list','P')   IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_notification_mark',   CASE WHEN OBJECT_ID('grac_practice.sp_task_notification_mark','P')   IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
    UNION ALL SELECT 'sp_task_notification_counts', CASE WHEN OBJECT_ID('grac_practice.sp_task_notification_counts','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
) x;

/* sp_task_notification_enqueue is called in a loop by the sweep, which
   returns its own OUTPUT values. If it ever SELECTs, the sweep's caller
   binds the wrong result set. */
SELECT 'enqueue is OUTPUT-only' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_task_notification_enqueue')
                            AND name = '@enqueued' AND is_output = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

/* Phase 3 must not have touched 037. */
SELECT 'sp_task_overdue_sweep still present and separate' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_task_overdue_sweep','P') IS NOT NULL
             AND NOT EXISTS (
                 SELECT 1 FROM sys.sql_modules m
                  WHERE m.object_id = OBJECT_ID('grac_practice.sp_task_overdue_sweep')
                    AND m.definition LIKE '%task_notification_outbox%')
            THEN 'PASS' ELSE 'REVIEW — 037 appears to have been modified' END AS Result;

PRINT '=== configuration readiness ===';

/* Without notify roles the sweep still notifies task owners, but no
   management escalation happens. Worth knowing before concluding that
   notifications "do not work". */
SELECT 'organisations with notify roles configured' AS Check_,
       COUNT(DISTINCT organization_id) AS Organisations_,
       CASE WHEN COUNT(*) = 0
            THEN 'INFO — no notify roles configured; only task owners will be notified'
            ELSE 'PASS' END AS Result
  FROM grac_practice.org_sla_config_notify_role
 WHERE is_active = 1;

SELECT 'notify roles by event' AS Check_,
       notify_event_code AS NotifyEventCode,
       COUNT(*)          AS Roles_
  FROM grac_practice.org_sla_config_notify_role
 WHERE is_active = 1
 GROUP BY notify_event_code;

/* A task with no matched SLA master falls back to the 75/100 defaults.
   Not a fault, but it means the organisation's tuned thresholds are not
   being applied to those tasks. */
SELECT 'open tasks with no matched SLA master' AS Check_,
       COUNT(*) AS Tasks_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS'
            ELSE 'INFO — these use the default 75%/100% thresholds' END AS Result
  FROM grac_practice.practice_task
 WHERE closed_at IS NULL
   AND parent_task_id IS NULL
   AND sla_due_at IS NOT NULL
   AND sla_master_id IS NULL;

PRINT '=== outbox health ===';

SELECT 'outbox by status' AS Check_,
       status_code AS StatusCode, COUNT(*) AS Rows_
  FROM grac_practice.task_notification_outbox
 GROUP BY status_code;

SELECT 'outbox by event' AS Check_,
       notify_event_code AS NotifyEventCode, COUNT(*) AS Rows_
  FROM grac_practice.task_notification_outbox
 GROUP BY notify_event_code;

/* Configured roles nobody holds. A governance gap, not a delivery
   problem — the escalation path is broken at the org-chart level. */
SELECT 'unroutable obligations (role has no active holder)' AS Check_,
       COUNT(*) AS Rows_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS'
            ELSE 'REVIEW — these roles have no active holder' END AS Result
  FROM grac_practice.task_notification_outbox
 WHERE recipient_employee_id IS NULL;

SELECT 'unroutable roles in detail' AS Check_,
       role_name AS RoleName, COUNT(*) AS Obligations_
  FROM grac_practice.task_notification_outbox
 WHERE recipient_employee_id IS NULL
 GROUP BY role_name
 ORDER BY COUNT(*) DESC;

/* Duplicates would mean the dedupe index is missing or bypassed — and a
   timer-driven sweeper would then flood the outbox. */
SELECT 'duplicate obligations (expect 0)' AS Check_,
       COUNT(*) AS Rows_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS Result
  FROM (
        SELECT task_id, notify_event_code, due_at_key, recipient_employee_id
          FROM grac_practice.task_notification_outbox
         GROUP BY task_id, notify_event_code, due_at_key, recipient_employee_id
        HAVING COUNT(*) > 1
       ) d;

/* Obligations recorded against a due date the task no longer has. Not an
   error — it is the audit trail of a superseded commitment, typically an
   approved SLA extension. Counted so the number is explainable. */
SELECT 'obligations against superseded due dates' AS Check_,
       COUNT(*) AS Rows_,
       'INFO — usually approved SLA extensions; the trail is intentional' AS Result
  FROM grac_practice.task_notification_outbox n
  JOIN grac_practice.practice_task t ON t.task_id = n.task_id
 WHERE t.sla_due_at IS NOT NULL
   AND n.due_at_key <> t.sla_due_at;

/* Pending obligations with no email address cannot be delivered by any
   future email dispatcher. Worth surfacing now rather than at send time. */
SELECT 'pending obligations with no recipient email' AS Check_,
       COUNT(*) AS Rows_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS'
            ELSE 'REVIEW — employee records are missing email addresses' END AS Result
  FROM grac_practice.task_notification_outbox
 WHERE status_code = N'Pending'
   AND recipient_employee_id IS NOT NULL
   AND (recipient_email IS NULL OR LTRIM(RTRIM(recipient_email)) = '');

SELECT 'sweep errors parked in the audit trace' AS Check_,
       COUNT(*) AS Rows_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'REVIEW' END AS Result
  FROM grac_practice.practice_audit_trace
 WHERE action_type = N'NOTIFY_SWEEP_ERROR';

PRINT '14_UAT_Diagnostics_TaskNotification complete.';
PRINT 'Run a sweep by hand with:';
PRINT '  DECLARE @n INT, @t INT;';
PRINT '  EXEC grac_practice.sp_task_notification_sweep @enqueued_count=@n OUTPUT, @task_count=@t OUTPUT;';
PRINT '  SELECT @n AS Enqueued, @t AS TasksScanned;';
PRINT 'NOTE: nothing DELIVERS these obligations yet — see "Deferred to Phase 4" in docs/task-centre-v2.md.';
