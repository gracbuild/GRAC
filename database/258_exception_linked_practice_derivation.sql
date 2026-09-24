-- =====================================================================
-- 258 Exception requests resolve their own linked practice
--
-- BUG: "Map existing task" lists nothing, and a task created from the
--      analysis page does not come back ticked.
--
-- CAUSE, and it is 257's. sp_exception_practice_task_candidates scopes
-- the picker to exception_request.linked_practice_id -- as specified.
-- But nothing ever SET that column:
--
--   * sp_exception_request_create accepts @linked_practice_id and has
--     since 166, but sp_custom_gap_analysis_save -- the only thing that
--     raises a gap exception -- never passes it.
--   * The one place a value could be entered was the Approve modal's
--     "Linked practice" picker, and 257 removed that form block on the
--     instruction that linked practice should be DISPLAYED, not chosen.
--
-- So every auto-raised exception carries NULL, the candidates procedure
-- takes its "@practice_id IS NOT NULL" branch, and the grid is empty.
-- The new task inherits the same NULL and therefore cannot appear in the
-- list it was created from.
--
-- Removing the picker was right. The mistake was assuming a column that
-- a form used to fill would still be filled once the form was gone.
--
-- FIX. The practice is derivable, so derive it rather than ask:
--
--     exception_request.custom_gap_id
--       -> custom_gap.source_reference_type = 'PracticeInstance'
--          and .source_reference_id
--       -> practice_instance.practice_id
--
--   1. Backfill every existing exception whose practice can be resolved.
--   2. sp_exception_request_create derives it when the caller does not
--      supply one -- one place, so every caller benefits and nobody has
--      to remember to pass it.
--   3. sp_exception_practice_task_candidates derives at READ time too
--      when the stored value is still NULL. Belt and braces: a screen
--      that depends on a denormalised column should not go blank the
--      moment that column is missing.
--
-- An OrgAssuranceGap-sourced exception has no practice instance behind
-- it, so it stays NULL. The picker reports that honestly rather than
-- widening to every task in the organisation, which would answer a
-- different question than the one asked.
--
-- SAFE TO RE-RUN. Requires 161, 166, 257.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (258): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.exception_request','U') IS NULL
BEGIN PRINT 'ABORT (258): exception_request missing (run 161 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_exception_practice_task_candidates','P') IS NULL
BEGIN PRINT 'ABORT (258): sp_exception_practice_task_candidates missing (run 257 first).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('258_exception_linked_practice_derivation: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Backfill
--
-- Only fills what is NULL -- a practice somebody chose by hand before
-- 257 removed the picker is left exactly as it is.
-- =====================================================================
UPDATE r
   SET linked_practice_id = pi.practice_id,
       updated_by         = COALESCE(r.updated_by, N'migration-258'),
       updated_dt         = SYSUTCDATETIME()
  FROM grac_practice.exception_request r
  JOIN grac_practice.custom_gap g
       ON g.custom_gap_id = r.custom_gap_id
  JOIN grac_practice.practice_instance pi
       ON pi.practice_instance_id = g.source_reference_id
 WHERE r.linked_practice_id IS NULL
   AND g.source_reference_type = N'PracticeInstance'
   AND g.source_reference_id IS NOT NULL
   AND pi.practice_id IS NOT NULL;

PRINT CONCAT('258: backfilled linked_practice_id on ', @@ROWCOUNT, ' exception request(s).');
GO

-- =====================================================================
-- 2. sp_exception_request_create -- derive when not supplied
--
-- 166's body with one added step. Everything else is verbatim: the
-- duplicate guard, the column list, the history row.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_create
    @custom_gap_id            BIGINT,
    @request_title            NVARCHAR(300) = NULL,
    @request_reason           NVARCHAR(MAX) = NULL,
    @requested_by_employee_id BIGINT        = NULL,
    @exception_type_code      NVARCHAR(60)  = NULL,
    @justification            NVARCHAR(MAX) = NULL,
    @risk_impact              NVARCHAR(MAX) = NULL,
    @owner_employee_id        BIGINT        = NULL,
    @linked_practice_id       BIGINT        = NULL,
    @linked_requirement_ref   NVARCHAR(200) = NULL,
    @caller_display_name      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @custom_gap_id IS NULL
        THROW 55200, 'sp_exception_request_create: custom_gap_id is required.', 1;

    DECLARE @org_id BIGINT, @gap_title NVARCHAR(250);
    SELECT @org_id = organization_id, @gap_title = title
      FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id;
    IF @org_id IS NULL
        THROW 55201, 'sp_exception_request_create: custom_gap not found.', 1;

    -- 258: SubmittedForApproval joins the "already open" set. Without it
    -- a request sitting with the approver would not block a second one
    -- being raised for the same gap -- a hole 257 opened by adding the
    -- status without revisiting this guard.
    DECLARE @existing_id BIGINT =
        (SELECT TOP 1 exception_request_id
           FROM grac_practice.exception_request
          WHERE custom_gap_id = @custom_gap_id
            AND status_code IN (N'Pending', N'SubmittedForApproval', N'Approved')
          ORDER BY exception_request_id DESC);
    IF @existing_id IS NOT NULL
    BEGIN
        SELECT @existing_id AS ExceptionRequestId, CAST(0 AS BIT) AS Created;
        RETURN;
    END

    DECLARE @type_id INT = NULL;
    IF @exception_type_code IS NOT NULL AND LEN(LTRIM(RTRIM(@exception_type_code))) > 0
    BEGIN
        SELECT @type_id = exception_type_id FROM grac_practice.exception_type_master
         WHERE exception_type_code = @exception_type_code;
        IF @type_id IS NULL
            THROW 55202, 'sp_exception_request_create: unknown exception_type_code.', 1;
    END

    -- 258: derive the practice when the caller did not name one. The
    -- analysis screen scopes its task picker to this value, and the only
    -- form that used to populate it was removed by 257.
    IF @linked_practice_id IS NULL
        SELECT @linked_practice_id = pi.practice_id
          FROM grac_practice.custom_gap g
          JOIN grac_practice.practice_instance pi
               ON pi.practice_instance_id = g.source_reference_id
         WHERE g.custom_gap_id = @custom_gap_id
           AND g.source_reference_type = N'PracticeInstance';

    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
    DECLARE @title NVARCHAR(300) = COALESCE(@request_title, N'Exception: ' + @gap_title);
    DECLARE @new_id BIGINT;

    BEGIN TRY
        BEGIN TRAN;

        INSERT INTO grac_practice.exception_request
            (organization_id, custom_gap_id,
             request_title, request_reason,
             exception_type_id, justification, risk_impact,
             owner_employee_id,
             linked_practice_id, linked_requirement_ref,
             status_code,
             requested_by_employee_id, requested_dt,
             record_status_id, entered_by, entered_dt)
        VALUES
            (@org_id, @custom_gap_id,
             @title, @request_reason,
             @type_id, @justification, @risk_impact,
             @owner_employee_id,
             @linked_practice_id, @linked_requirement_ref,
             N'Pending',
             @requested_by_employee_id, SYSUTCDATETIME(),
             @active_rs, @caller_display_name, SYSUTCDATETIME());

        SET @new_id = SCOPE_IDENTITY();

        INSERT INTO grac_practice.exception_request_history
            (exception_request_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@new_id, N'Create', NULL, N'Pending',
             @request_reason, @requested_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK; THROW; END CATCH

    SELECT @new_id AS ExceptionRequestId, CAST(1 AS BIT) AS Created;
END
GO
PRINT '258: sp_exception_request_create derives linked_practice_id.';
GO

-- =====================================================================
-- 3. sp_exception_practice_task_candidates -- derive at read time
--
-- 257's body, except the practice is resolved rather than read straight
-- off the column. A picker that empties itself because a denormalised
-- value was never written is indistinguishable, to the operator, from a
-- practice that genuinely has no tasks.
-- =====================================================================
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

    -- 258: fall back to the gap's practice instance when the column is
    -- still NULL (a row 258's backfill could not resolve, or one raised
    -- by an older create procedure).
    IF @practice_id IS NULL AND @gap_id IS NOT NULL
        SELECT @practice_id = pi.practice_id
          FROM grac_practice.custom_gap g
          JOIN grac_practice.practice_instance pi
               ON pi.practice_instance_id = g.source_reference_id
         WHERE g.custom_gap_id = @gap_id
           AND g.source_reference_type = N'PracticeInstance';

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
           CAST(CASE WHEN EXISTS (
                    SELECT 1 FROM grac_practice.exception_request_task l
                     WHERE l.exception_request_id = @exception_request_id
                       AND l.task_id = t.task_id
                       AND l.status = N'Active')
                THEN 1 ELSE 0 END AS BIT) AS IsLinked
      FROM grac_practice.practice_task t
      LEFT JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = t.assigned_to_employee_id
     WHERE t.organization_id = @org_id
       AND @practice_id IS NOT NULL
       AND t.linked_practice_id = @practice_id
       AND t.parent_task_id IS NULL
       AND (@search IS NULL
            OR t.subject_title LIKE N'%' + @search + N'%'
            OR t.task_number   LIKE N'%' + @search + N'%')
     ORDER BY CASE WHEN s.status_code IN (N'Closed', N'Cancelled') THEN 1 ELSE 0 END,
              t.task_id DESC;

    -- Second result set: what the picker is scoped to. The screen shows
    -- this so an empty grid says WHICH practice had no tasks, or that no
    -- practice could be resolved at all.
    SELECT @practice_id                AS PracticeId,
           p.practice_code             AS PracticeCode,
           p.practice_name             AS PracticeName
      FROM (SELECT 1 AS x) dummy
      LEFT JOIN grac_practice.practice p ON p.practice_id = @practice_id;
END
GO
PRINT '258: sp_exception_practice_task_candidates resolves the practice.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 258 verification ===';

DECLARE @cr NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_exception_request_create','P'));
DECLARE @cd NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_exception_practice_task_candidates','P'));

SELECT '258-a create derives the practice' AS Check_,
       CASE WHEN @cr LIKE '%source_reference_type = N''PracticeInstance''%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '258-b create still de-duplicates per gap',
       CASE WHEN @cr LIKE '%SubmittedForApproval%' AND @cr LIKE '%Created%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '258-c candidates falls back when the column is NULL',
       CASE WHEN @cd LIKE '%@practice_id IS NULL AND @gap_id IS NOT NULL%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '258-d candidates still flags already-linked tasks',
       CASE WHEN @cd LIKE '%AS IsLinked%' THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- How many exceptions can now name a practice? ---';

SELECT
    COUNT_BIG(*)                                                   AS TotalRequests,
    SUM(CASE WHEN linked_practice_id IS NOT NULL THEN 1 ELSE 0 END) AS WithPractice,
    SUM(CASE WHEN linked_practice_id IS NULL     THEN 1 ELSE 0 END) AS WithoutPractice
  FROM grac_practice.exception_request;

PRINT '';
PRINT 'Rows still without a practice are normally OrgAssuranceGap-sourced:';
PRINT 'there is no practice instance behind them to derive one from.';

SELECT g.source_reference_type AS GapSourceReferenceType,
       COUNT_BIG(*)            AS RequestsWithoutPractice
  FROM grac_practice.exception_request r
  LEFT JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.custom_gap_id
 WHERE r.linked_practice_id IS NULL
 GROUP BY g.source_reference_type;

PRINT '';
PRINT '258 complete.';
GO

SET NOEXEC OFF;
GO
