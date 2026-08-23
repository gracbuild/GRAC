-- =====================================================================
-- 131 People auto-raise -- ROLLBACK
--
-- Drops the triggers first: leaving them in place while the queue table is
-- gone would make every employee insert fail, which is far worse than the
-- bug 131 fixed.
--
-- The three ALTERED procedures are CREATE OR ALTER, so restoring them means
-- re-running their owning migrations:
--     128 + 129  -> sp_event_obligation_raise
--     124        -> sp_event_checklist_inbox_list
-- Order matters: 129 after 128.
--
-- WHAT YOU LOSE:
--   * employees created through the Employee form stop producing an
--     onboarding checklist automatically;
--   * the resolver goes back to reading organization_employee_role only, so
--     an employee whose role sits in organization_employee.role_id resolves
--     to SubjectScopeMissing and gets no checklist at all;
--   * obligation instances show 0 / 0 progress in the inbox again.
-- =====================================================================
SET NOCOUNT ON;
GO

-- 1. Triggers first.
IF OBJECT_ID('grac_practice.tr_pm_employee_role_autoraise','TR') IS NOT NULL
    DROP TRIGGER grac_practice.tr_pm_employee_role_autoraise;
GO
IF OBJECT_ID('grac_practice.tr_pm_employee_autoraise','TR') IS NOT NULL
    DROP TRIGGER grac_practice.tr_pm_employee_autoraise;
GO

-- 2. Drain proc + queue.
IF OBJECT_ID('grac_practice.sp_event_autoraise_drain','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_event_autoraise_drain;
GO

-- Report anything still unprocessed before dropping it -- these are events
-- that happened and were never turned into checklists.
IF OBJECT_ID('grac_practice.event_autoraise_queue','U') IS NOT NULL
BEGIN
    PRINT '--- Unprocessed queue entries about to be discarded ---';
    SELECT organization_id, subject_entity, subject_record_id, event_code,
           effective_date, status, attempt_count, last_error
    FROM   grac_practice.event_autoraise_queue
    WHERE  status IN (N'Pending', N'Failed')
    ORDER BY enqueued_dt;

    DROP TABLE grac_practice.event_autoraise_queue;
END
GO

-- 3. The role-source function. Dropped last because the procedures above
--    reference it; re-run 128/129/124 before or after, but do not leave
--    the altered procedures pointing at a missing function.
IF OBJECT_ID('grac_practice.fn_pm_employee_role_ids','IF') IS NOT NULL
    DROP FUNCTION grac_practice.fn_pm_employee_role_ids;
GO

PRINT '131 ROLLBACK: triggers, queue, drain proc and role function removed.';
PRINT '131 ROLLBACK: now re-run, in order:';
PRINT '    database\128_event_obligation_scope_procs.sql';
PRINT '    database\129_event_obligation_dedupe_procs.sql';
PRINT '    database\124_event_scope_mapping_procs.sql';
PRINT 'Until you do, sp_event_obligation_raise and sp_event_checklist_inbox_list';
PRINT 'still reference grac_practice.fn_pm_employee_role_ids and will fail.';
GO

SELECT 'triggers removed' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.tr_pm_employee_autoraise','TR') IS NULL
             AND OBJECT_ID('grac_practice.tr_pm_employee_role_autoraise','TR') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'queue dropped',
       CASE WHEN OBJECT_ID('grac_practice.event_autoraise_queue','U') IS NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'role function dropped',
       CASE WHEN OBJECT_ID('grac_practice.fn_pm_employee_role_ids','IF') IS NULL THEN 'PASS' ELSE 'FAIL' END;
GO
