/*
  Practice Management — Task Model extension UAT diagnostics
  Runs after 09_UAT_Diagnostics_ImplementationTask.sql. Verifies 048.
*/
SET NOCOUNT ON;

SELECT 'related_entity_type_master seeded' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.related_entity_type_master WHERE is_active = 1) >= 8
            THEN 'PASS' ELSE 'FAIL' END AS Result,
       (SELECT COUNT(*) FROM grac_practice.related_entity_type_master WHERE is_active = 1) AS ActiveCount;

SELECT 'Assurance + Custom task types present' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.task_type_master WHERE type_code = N'Assurance' AND is_active = 1)
             AND EXISTS (SELECT 1 FROM grac_practice.task_type_master WHERE type_code = N'Custom' AND is_active = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'practice_task extended columns present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.practice_task','related_entity_type_id')   IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','related_record_id')        IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','start_date')               IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','workflow_id')              IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','current_workflow_stage_id') IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','assurance_activity_id')    IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','task_number')              IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'sp_task_open v2 accepts new params' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1 FROM sys.parameters
           WHERE object_id = OBJECT_ID('grac_practice.sp_task_open')
             AND name = '@workflow_id')
           THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'vw_pm_practice_task exposes new columns' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('grac_practice.vw_pm_practice_task')
             AND name = 'task_number')
           THEN 'PASS' ELSE 'FAIL' END AS Result;

-- Distribution of task types (informational)
SELECT 'Task-type row counts' AS Report,
       tt.type_code, COUNT(t.task_id) AS RowCount_
FROM grac_practice.task_type_master tt
LEFT JOIN grac_practice.practice_task t ON t.task_type_id = tt.task_type_id
GROUP BY tt.type_code
ORDER BY tt.type_code;
