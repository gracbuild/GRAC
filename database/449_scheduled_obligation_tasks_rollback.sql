-- =====================================================================
-- 449 ROLLBACK -- scheduled obligation tasks
--
-- Removes the generator and the occurrence ledger, restores 438's
-- sp_task_centre_source_counts and 438's source vocabulary (WITH NOCHECK,
-- so tasks already raised with source 'Schedule' stay in place and keep
-- their history -- they are ordinary Task Centre tasks). The task type is
-- removed only when no task uses it.
-- Turn the worker pass off first (TaskNotification:
-- ScheduledObligationTasksEnabled=false) or roll back the Api.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_schedule_obligation_tasks_generate','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_schedule_obligation_tasks_generate;
GO
IF OBJECT_ID('grac_practice.schedule_occurrence_task','U') IS NOT NULL
    DROP TABLE grac_practice.schedule_occurrence_task;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints
            WHERE name = 'ck_pm_practice_task_source_type' AND definition LIKE '%Schedule''%')
BEGIN
    ALTER TABLE grac_practice.practice_task DROP CONSTRAINT ck_pm_practice_task_source_type;
    ALTER TABLE grac_practice.practice_task WITH NOCHECK
        ADD CONSTRAINT ck_pm_practice_task_source_type
            CHECK (source_type_code IS NULL
                OR source_type_code IN (N'Gap', N'Exception', N'Risk',
                                        N'RiskRegister',
                                        N'ContinuousAssurance', N'EventAssurance',
                                        N'Custom',
                                        N'Asset'));
    PRINT '449 rollback: source vocabulary restored to 438.';
END
GO

DELETE tt
  FROM grac_practice.task_type_master tt
 WHERE tt.type_code = N'ScheduledObligation'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.practice_task t WHERE t.task_type_id = tt.task_type_id);
PRINT CONCAT('449 rollback: task type removed: ', @@ROWCOUNT);
GO

-- 438's sp_task_centre_source_counts, verbatim.
CREATE OR ALTER PROCEDURE grac_practice.sp_task_centre_source_counts
    @organization_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Result set 1 -- the filterable vocabulary, in dropdown order.
    ;WITH vocab(SourceTypeCode, DisplayOrder) AS (
        SELECT N'Gap',                 1 UNION ALL
        SELECT N'Exception',           2 UNION ALL
        SELECT N'Risk',                3 UNION ALL
        SELECT N'RiskRegister',        4 UNION ALL
        SELECT N'ContinuousAssurance', 5 UNION ALL
        SELECT N'EventAssurance',      6 UNION ALL
        SELECT N'Custom',              7 UNION ALL
        SELECT N'Asset',               8                                               -- 438
    )
    SELECT v.SourceTypeCode,
           v.DisplayOrder,
           (SELECT COUNT_BIG(*)
              FROM grac_practice.practice_task t
             WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
               AND t.parent_task_id IS NULL
               AND t.source_type_code = v.SourceTypeCode) AS TaskCount
    FROM   vocab v
    ORDER  BY v.DisplayOrder;

    -- Result set 2 -- totals, so the dropdown can label "All sources"
    -- and the caller can see how many rows carry no source at all.
    SELECT
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND t.parent_task_id IS NULL) AS TotalCount,
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND t.parent_task_id IS NULL
            AND t.source_type_code IS NULL) AS UnsourcedCount;
END
GO
PRINT '438: sp_task_centre_source_counts re-issued.';
GO

SELECT '449 rollback' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_schedule_obligation_tasks_generate','P') IS NULL
             AND OBJECT_ID('grac_practice.schedule_occurrence_task','U') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_centre_source_counts')) NOT LIKE '%N''Schedule''%'
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
SET NOEXEC OFF;
GO
