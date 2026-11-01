/* Diagnostic: Task Edit / Task View shows "Failed to load: HTTP 404".
   The Api returns 404 for GET api/practice/tasks/{id} only when
   sp_task_get returns no header row (vw_pm_practice_task has no row).
   Set @task_id to the taskId in the page URL (task-edit?taskId=NNN). Read-only. */
SET NOCOUNT ON;
DECLARE @task_id BIGINT = 0;   -- <<< set this

PRINT '--- 1. base row ---';
SELECT task_id, task_number, organization_id, task_type_id, current_status_id, parent_task_id
  FROM grac_practice.practice_task WHERE task_id = @task_id;

PRINT '--- 2. inner-join targets of vw_pm_practice_task ---';
SELECT 'task_type_master'     AS join_table,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.task_type_master tt
                           JOIN grac_practice.practice_task t ON t.task_type_id = tt.task_type_id
                          WHERE t.task_id = @task_id) THEN 'PASS' ELSE 'FAIL' END AS result
UNION ALL
SELECT 'entity_status_master',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.entity_status_master s
                           JOIN grac_practice.practice_task t ON t.current_status_id = s.entity_status_id
                          WHERE t.task_id = @task_id) THEN 'PASS' ELSE 'FAIL' END;

PRINT '--- 3. view row (this is the header sp_task_get returns) ---';
SELECT COUNT(*) AS view_rows FROM grac_practice.vw_pm_practice_task WHERE task_id = @task_id;

PRINT '--- 4. migrations that re-issued sp_task_get ---';
SELECT CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_get')) LIKE '%InstanceEvidenceId%' THEN 'YES' ELSE 'NO' END AS has_482_body,
       (SELECT modify_date FROM sys.procedures WHERE object_id = OBJECT_ID('grac_practice.sp_task_get')) AS sp_task_get_modified;

PRINT '--- 5. run the proc exactly as the Api does ---';
EXEC grac_practice.sp_task_get @task_id = @task_id;
