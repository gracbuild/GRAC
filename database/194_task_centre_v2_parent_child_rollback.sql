-- =====================================================================
-- 194 Task Centre v2 — parent/child + SLA extension ROLLBACK
--
-- Drops only what 194 created. 193's procedures and 192's schema are
-- untouched; run their rollbacks afterwards if you are unwinding the
-- whole phase (order: 195 -> 194 -> 193 -> 192).
--
-- DATA NOTE
--   Existing parent/child links live in practice_task.parent_task_id and
--   are NOT cleared here — dropping a procedure must not silently
--   restructure data. If you also run 192's rollback the column goes
--   away and the children become ordinary top-level Custom tasks.
--
--   Pending TASK_SLA_EXTENSION requests stay in exception_request. With
--   sp_task_sla_extension_approve gone they can no longer be approved,
--   only rejected via sp_exception_request_reject. Resolve them before
--   rolling back if that matters.
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT '194-rollback: schema grac_practice missing — nothing to do.';
    SET NOEXEC ON;
END
GO

-- Dependents first: sp_task_complete calls sp_task_completion_eligibility.
IF OBJECT_ID('grac_practice.sp_task_complete','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_complete;
IF OBJECT_ID('grac_practice.sp_task_completion_eligibility','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_completion_eligibility;
IF OBJECT_ID('grac_practice.sp_task_child_create','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_child_create;
IF OBJECT_ID('grac_practice.sp_task_sla_extension_approve','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_sla_extension_approve;
IF OBJECT_ID('grac_practice.sp_task_sla_extension_request_create','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_sla_extension_request_create;
GO

-- Report what is left behind so the operator is not surprised.
IF COL_LENGTH('grac_practice.practice_task','parent_task_id') IS NOT NULL
    SELECT '194-rollback: surviving child tasks' AS Check_, COUNT(*) AS Rows_
      FROM grac_practice.practice_task WHERE parent_task_id IS NOT NULL;

IF COL_LENGTH('grac_practice.exception_request','task_id') IS NOT NULL
    SELECT '194-rollback: pending task SLA extension requests' AS Check_, COUNT(*) AS Rows_
      FROM grac_practice.exception_request
     WHERE request_type_code = N'TASK_SLA_EXTENSION' AND status_code = N'Pending';
GO

PRINT '194 Task Centre v2 parent/child + extension procedures rolled back.';
GO

SET NOEXEC OFF;
GO
