/*
  Practice Management — Implementation Task UAT diagnostics
  Runs after 08_UAT_Diagnostics_TaskEngine.sql. Verifies Q13/Q14/Q15
  (043_practice_instance_impl_status.sql + 043_open_implementation_task_proc.sql).
*/
SET NOCOUNT ON;

SELECT 'implementation_status_master new values present' AS Check_,
       CASE WHEN
           EXISTS (SELECT 1 FROM grac_practice.implementation_status_master WHERE status_code = N'Not Implemented')
       AND EXISTS (SELECT 1 FROM grac_practice.implementation_status_master WHERE status_code = N'Partially Implemented')
       AND EXISTS (SELECT 1 FROM grac_practice.implementation_status_master WHERE status_code = N'Implemented')
       AND EXISTS (SELECT 1 FROM grac_practice.implementation_status_master WHERE status_code = N'N/A')
       THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'practice_instance.implementation_status_id column present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.practice_instance', 'implementation_status_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- FK on practice_instance.implementation_status_id — name-agnostic.
-- Canonical name is fk_pm_practice_instance_implementation_status (from
-- migration 008). Migration 043 v2 reuses that FK and cleans up any
-- duplicate fk_pm_practice_instance_impl_status left by 043 v1.
SELECT 'FK on practice_instance.implementation_status_id present (any name)' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1
           FROM sys.foreign_keys fk
           JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
           JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
           WHERE fk.parent_object_id = OBJECT_ID('grac_practice.practice_instance')
             AND c.name = 'implementation_status_id')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Exactly one FK on implementation_status_id (no duplicate)' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM sys.foreign_keys fk
                  JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
                  JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
                  WHERE fk.parent_object_id = OBJECT_ID('grac_practice.practice_instance')
                    AND c.name = 'implementation_status_id') = 1
            THEN 'PASS' ELSE 'FAIL — rerun 043 to clean up duplicate' END AS Result,
       (SELECT COUNT(*) FROM sys.foreign_keys fk
        JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
        JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
        WHERE fk.parent_object_id = OBJECT_ID('grac_practice.practice_instance')
          AND c.name = 'implementation_status_id') AS FKCount;

SELECT 'Supporting index ix_pm_practice_instance_impl_status present' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                         WHERE name = 'ix_pm_practice_instance_impl_status'
                           AND object_id = OBJECT_ID('grac_practice.practice_instance'))
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'sp_practice_instance_open_implementation_task installed' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_instance_open_implementation_task','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Every practice_instance has implementation_status_id' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance WHERE implementation_status_id IS NULL)
            THEN 'PASS' ELSE 'FAIL (' + CAST((SELECT COUNT(*) FROM grac_practice.practice_instance WHERE implementation_status_id IS NULL) AS NVARCHAR(10)) + ' NULL rows)' END AS Result;

-- Distribution snapshot
SELECT ims.status_code AS Status, COUNT(*) AS PracticeInstanceCount
FROM grac_practice.practice_instance pi
JOIN grac_practice.implementation_status_master ims ON ims.implementation_status_id = pi.implementation_status_id
GROUP BY ims.status_code
ORDER BY MIN(ims.display_order);
