-- =====================================================================
-- 259 Exception task picker: always show what is attached, and fall back
--     to the organization when no practice exists
--
-- SYMPTOM: "This exception has no practice behind it, so there are no
--          practice tasks to list" -- on an exception that already has
--          two tasks attached to it.
--
-- TWO FAULTS, both mine, both in 257's picker.
--
-- 1. ALREADY-LINKED TASKS COULD BE INVISIBLE.
--    sp_exception_practice_task_candidates filtered on the practice and
--    nothing else, so a task attached to the exception but outside that
--    practice -- or attached when no practice resolves at all -- never
--    appeared. The grid is a checkbox representation of the link set;
--    a link set it cannot display is a grid that cannot be trusted, and
--    the operator has no way to untick what it will not show.
--
--    Attached tasks are now returned ALWAYS, whatever the scope.
--
-- 2. NO PRACTICE MEANT NO LIST AT ALL.
--    258 derives the practice through
--        custom_gap.source_reference_type = 'PracticeInstance'
--    but a Custom gap -- one raised by hand through Add Gap -- has no
--    practice instance behind it, and custom_gap carries no other
--    practice column. For those the picker was permanently empty.
--
--    258's note said returning nothing was "honest". It is honest and
--    useless: the operator is told there is nothing to map when what is
--    true is that we could not work out where to look. The picker now
--    falls back to the organization's tasks and SAYS which scope it
--    used, so the operator can see the difference.
--
-- The scope is reported on the second result set as ScopeCode:
--     'Practice'      -- tasks under the exception's practice
--     'Organization'  -- no practice resolved; every task in the org
-- Attached tasks are included in both.
--
-- SAFE TO RE-RUN. Requires 257, 258.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (259): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.exception_request_task','U') IS NULL
BEGIN PRINT 'ABORT (259): exception_request_task missing (run 257 first).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('259_exception_task_candidates_scope: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_exception_practice_task_candidates
    @exception_request_id BIGINT,
    @search               NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @exception_request_id IS NULL
        THROW 55280, 'sp_exception_practice_task_candidates: exception_request_id is required.', 1;
    IF @search = N'' SET @search = NULL;

    DECLARE @org_id BIGINT, @practice_id BIGINT, @gap_id BIGINT;
    SELECT @org_id      = organization_id,
           @practice_id = linked_practice_id,
           @gap_id      = custom_gap_id
      FROM grac_practice.exception_request
     WHERE exception_request_id = @exception_request_id;

    IF @org_id IS NULL
        THROW 55281, 'sp_exception_practice_task_candidates: request not found.', 1;

    -- 258: derive from the gap's practice instance when the stored value
    -- is NULL. A Custom gap has no instance, so this can still come back
    -- NULL -- which is what the fallback below is for.
    IF @practice_id IS NULL AND @gap_id IS NOT NULL
        SELECT @practice_id = pi.practice_id
          FROM grac_practice.custom_gap g
          JOIN grac_practice.practice_instance pi
               ON pi.practice_instance_id = g.source_reference_id
         WHERE g.custom_gap_id = @gap_id
           AND g.source_reference_type = N'PracticeInstance';

    DECLARE @scope NVARCHAR(20) =
        CASE WHEN @practice_id IS NOT NULL THEN N'Practice' ELSE N'Organization' END;

    SELECT t.task_id              AS TaskId,
           t.task_number          AS TaskNumber,
           t.subject_title        AS TaskTitle,
           tt.type_code           AS TaskTypeCode,
           tt.type_name           AS TaskTypeName,
           s.status_code          AS TaskStatusCode,
           s.status_name          AS TaskStatusName,
           t.priority             AS Priority,
           t.sla_due_at           AS DueAt,
           e.employee_name        AS AssignedToName,
           CAST(CASE WHEN l.exception_request_task_id IS NOT NULL
                     THEN 1 ELSE 0 END AS BIT) AS IsLinked
      FROM grac_practice.practice_task t
      LEFT JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = t.assigned_to_employee_id
      -- Joined rather than EXISTS-ed so the same test drives both the
      -- IsLinked flag and the "always include attached" rule below --
      -- one definition, so they cannot disagree.
      LEFT JOIN grac_practice.exception_request_task l
             ON l.task_id              = t.task_id
            AND l.exception_request_id = @exception_request_id
            AND l.status               = N'Active'
     WHERE t.organization_id = @org_id
       AND t.parent_task_id IS NULL
       AND (
             -- in scope...
             @practice_id IS NULL                       -- org-wide fallback
             OR t.linked_practice_id = @practice_id     -- the practice
             -- ...or attached to this exception, wherever it lives. An
             -- attached task the grid will not show is one the operator
             -- cannot detach.
             OR l.exception_request_task_id IS NOT NULL
           )
       AND (@search IS NULL
            OR t.subject_title LIKE N'%' + @search + N'%'
            OR t.task_number   LIKE N'%' + @search + N'%')
     ORDER BY CASE WHEN l.exception_request_task_id IS NOT NULL THEN 0 ELSE 1 END,
              CASE WHEN s.status_code IN (N'Closed', N'Cancelled') THEN 1 ELSE 0 END,
              t.task_id DESC;

    -- Scope descriptor. The screen prints this, so an empty grid always
    -- says WHY it is empty and a full one says what it is showing.
    SELECT @practice_id            AS PracticeId,
           p.practice_code         AS PracticeCode,
           p.practice_name         AS PracticeName,
           @scope                  AS ScopeCode
      FROM (SELECT 1 AS x) dummy
      LEFT JOIN grac_practice.practice p ON p.practice_id = @practice_id;
END
GO
PRINT '259: task picker always shows attached tasks and falls back to org scope.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 259 verification ===';

DECLARE @cd NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_exception_practice_task_candidates','P'));

SELECT '259-a attached tasks are always in scope' AS Check_,
       CASE WHEN @cd LIKE '%OR l.exception_request_task_id IS NOT NULL%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '259-b org-wide fallback when no practice resolves',
       CASE WHEN @cd LIKE '%@practice_id IS NULL%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '259-c scope is reported to the caller',
       CASE WHEN @cd LIKE '%AS ScopeCode%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '259-d 258 derivation retained',
       CASE WHEN @cd LIKE '%source_reference_type = N''PracticeInstance''%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '259-e attached tasks sort first',
       CASE WHEN @cd LIKE '%ORDER BY CASE WHEN l.exception_request_task_id%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- Which scope will each exception request use? ---';
PRINT 'Organization means no practice could be resolved -- normally a';
PRINT 'Custom gap, which has no practice instance behind it.';

SELECT CASE WHEN COALESCE(r.linked_practice_id, pi.practice_id) IS NOT NULL
            THEN N'Practice' ELSE N'Organization' END AS ScopeCode,
       COALESCE(g.source_reference_type, N'(none)')   AS GapSourceReferenceType,
       COUNT_BIG(*)                                   AS Requests
  FROM grac_practice.exception_request r
  LEFT JOIN grac_practice.custom_gap g
         ON g.custom_gap_id = r.custom_gap_id
  LEFT JOIN grac_practice.practice_instance pi
         ON pi.practice_instance_id = g.source_reference_id
        AND g.source_reference_type = N'PracticeInstance'
 GROUP BY CASE WHEN COALESCE(r.linked_practice_id, pi.practice_id) IS NOT NULL
               THEN N'Practice' ELSE N'Organization' END,
          COALESCE(g.source_reference_type, N'(none)');

PRINT '';
PRINT '--- Attached tasks that the pre-259 picker could not show ---';
PRINT 'Non-zero here means 259 was needed: these were linked but invisible.';

SELECT COUNT_BIG(*) AS AttachedButOutOfPracticeScope
  FROM grac_practice.exception_request_task l
  JOIN grac_practice.exception_request r
       ON r.exception_request_id = l.exception_request_id
  JOIN grac_practice.practice_task t
       ON t.task_id = l.task_id
 WHERE l.status = N'Active'
   AND (r.linked_practice_id IS NULL
        OR t.linked_practice_id IS NULL
        OR t.linked_practice_id <> r.linked_practice_id);

PRINT '';
PRINT '259 complete.';
GO

SET NOEXEC OFF;
GO
