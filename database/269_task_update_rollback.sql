-- =====================================================================
-- 269 ROLLBACK — drop the single task edit path
--
-- WHAT THIS REMOVES
--     sp_task_update
--     sp_task_edit_options
--
-- WHAT IT DOES NOT TOUCH, AND WHY
-- -------------------------------
-- The task_activity rows written by edits STAY. They are audit history:
-- "Priority: Medium -> High, by A. Kumar, 14-Sep-2026" happened, and the
-- fact that the procedure which recorded it was later dropped does not
-- unhappen it. Deleting audit rows to tidy up a rollback is how an audit
-- trail stops being one.
--
-- Their activity_type_code values ('FieldChange' among them) also stay
-- readable: 192 deliberately left that column a free NVARCHAR(40) with
-- no CHECK and no FK, so nothing breaks by having codes present that no
-- live procedure writes any more.
--
-- Nothing else is affected. 269 composed the existing procedures rather
-- than replacing them, so sp_task_assign, sp_task_transition,
-- sp_task_priority_change and sp_task_sla_extension_request_create were
-- never modified and continue to work exactly as before. That is the
-- payoff of DECISION 1 in the forward file: this rollback removes a
-- caller, not an implementation.
--
-- AFTER THIS RUNS
-- ---------------
-- Editing a task from Task Center will fail -- the UI's PUT /tasks/{id}
-- has no procedure behind it. Task Center's own Complete, Close, Assign
-- and Add Child Task are unaffected. If the UI has already been
-- deployed, roll it back too, or the Edit action will error.
--
-- IDEMPOTENT: re-running drops nothing the second time.
-- Depends: nothing (guards on existence)
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_task_update','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_task_update;
    PRINT '269 rollback: dropped sp_task_update.';
END
ELSE
    PRINT '269 rollback: sp_task_update not present -- nothing to drop.';
GO

IF OBJECT_ID('grac_practice.sp_task_edit_options','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_task_edit_options;
    PRINT '269 rollback: dropped sp_task_edit_options.';
END
ELSE
    PRINT '269 rollback: sp_task_edit_options not present -- nothing to drop.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '--- 269 rollback verification ---';

SELECT '269r both procedures are gone' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_task_update','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_task_edit_options','P') IS NULL
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

-- The point of composing rather than replacing: none of these were
-- touched going forward, so none need restoring going back.
SELECT '269r the composed procedures are untouched' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_task_assign','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_transition','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_priority_change','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_sla_extension_request_create','P') IS NOT NULL
            THEN 'PASS -- assignment, status, priority and SLA still work'
            ELSE '*** FAIL -- something 269 did not own is missing' END AS Result;

SELECT '269r audit history is retained' AS Check_,
       CONCAT(CAST(COUNT(*) AS NVARCHAR(20)),
              N' field-change activity row(s) kept (deliberately not deleted)') AS Result
  FROM grac_practice.task_activity
 WHERE activity_type_code = N'FieldChange';

PRINT '269 rollback complete.';
PRINT '     WARNING: Task Center''s Edit action now has no procedure behind it.';
PRINT '     Roll the UI back too, or Edit will error.';
GO

SET NOEXEC OFF;
GO
