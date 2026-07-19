/*
  Practice Management — Task-engine + feature-flag UAT diagnostics
  Runs after 07_UAT_Diagnostics_WorkflowLayer.sql. Verifies §12.1.3 + §7 (feature flags).

  Charter §5 forbids modifying existing files in database/deployment/;
  this new higher-numbered file is the extension.

  Charter §9: smoke-test coverage per work item.
*/
SET NOCOUNT ON;

--------------------------------------------------------------------
-- §12.1.3 Task engine smoke checks
--------------------------------------------------------------------
SELECT 'grac_practice.task_type_master' AS ObjectName,
       COUNT_BIG(1) AS RecordCount
FROM grac_practice.task_type_master;

SELECT 'Task types complete' AS Check_,
       CASE WHEN
           EXISTS (SELECT 1 FROM grac_practice.task_type_master WHERE type_code = N'Implementation')
       AND EXISTS (SELECT 1 FROM grac_practice.task_type_master WHERE type_code = N'Rectification')
       AND EXISTS (SELECT 1 FROM grac_practice.task_type_master WHERE type_code = N'AssignmentPending')
       THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'grac_practice.practice_task' AS ObjectName,
       COUNT_BIG(1) AS RecordCount
FROM grac_practice.practice_task;

SELECT 'vw_pm_practice_task view usable' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- All task procs present
SELECT 'sp_task_open present'         AS Check_, CASE WHEN OBJECT_ID('grac_practice.sp_task_open','P')            IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'sp_task_assign',      CASE WHEN OBJECT_ID('grac_practice.sp_task_assign','P')          IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_task_transition',  CASE WHEN OBJECT_ID('grac_practice.sp_task_transition','P')      IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_task_close',       CASE WHEN OBJECT_ID('grac_practice.sp_task_close','P')           IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_task_overdue_sweep',CASE WHEN OBJECT_ID('grac_practice.sp_task_overdue_sweep','P')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_task_list',        CASE WHEN OBJECT_ID('grac_practice.sp_task_list','P')            IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;

--------------------------------------------------------------------
-- §7 Feature-flag smoke checks
--------------------------------------------------------------------
SELECT 'grac_practice.feature_flag_master' AS ObjectName,
       COUNT_BIG(1) AS RecordCount
FROM grac_practice.feature_flag_master;

SELECT 'Task Center flag registered' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1 FROM grac_practice.feature_flag_master
           WHERE feature_code = N'screen.tasks' AND default_enabled = 0
       ) THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'fn_pm_feature_enabled default OFF' AS Check_,
       CASE grac_practice.fn_pm_feature_enabled(0, N'screen.tasks')
            WHEN 0 THEN 'PASS' ELSE 'FAIL' END AS Result;

--------------------------------------------------------------------
-- End-to-end idempotency probe:
--   Calling sp_task_overdue_sweep on an empty universe returns 0 and
--   is safe to re-run without side effects.
--------------------------------------------------------------------
DECLARE @moved INT;
EXEC grac_practice.sp_task_overdue_sweep @batch_size = 100, @escalated_count = @moved OUTPUT;
SELECT 'sp_task_overdue_sweep empty-run' AS Check_,
       CASE WHEN @moved >= 0 THEN 'PASS' ELSE 'FAIL' END AS Result,
       @moved AS EscalatedCount;

EXEC grac_practice.sp_task_overdue_sweep @batch_size = 100, @escalated_count = @moved OUTPUT;
SELECT 'sp_task_overdue_sweep second-run idempotent' AS Check_,
       CASE WHEN @moved = 0 THEN 'PASS' ELSE 'FAIL' END AS Result;
