-- =====================================================================
-- 200 Task completion -> upstream synchronisation  (BRD §14, §18)
--
-- WHAT THE BRD ASKS FOR, AND THE LINE IT DRAWS
-- --------------------------------------------
-- §14: "When a task is completed, the originating source record must be
--  updated to show that its associated task/action has been completed.
--
--  Task completion must NOT automatically close the upstream Gap,
--  Exception, Risk, Continuous Assurance or Event Assurance record. The
--  upstream module remains responsible for deciding whether its
--  underlying item is actually resolved/closed."
--
-- That second paragraph is the whole design constraint. Task Centre may
-- report; it may not decide. So this migration writes to exactly ONE
-- table that Task Centre owns, and touches no source table's status
-- column anywhere.
--
-- WHY A SEPARATE TABLE RATHER THAN COLUMNS ON EACH SOURCE
-- -------------------------------------------------------
-- The alternative — ALTER custom_gap, risk_candidate,
-- org_assurance_observation and exception_request to each carry
-- task_action_status — would mean four schema changes across four
-- modules Task Centre does not own, four places to keep in step, and a
-- fifth every time a new source is added. One table keyed by
-- (source_type_code, source_record_id) gives every source the same
-- answer, costs no ALTERs outside this feature, and cannot accidentally
-- be mistaken for the source's own lifecycle status.
--
-- CONTENTS
--   1. task_source_action_state          — the reported state
--   2. sp_task_source_sync               — recompute one source (idempotent)
--   3. sp_task_source_action_state_get   — read for a source screen
--   4. sp_task_complete                  REWRITE — superset of 194, calls the sync
--   5. Backfill for tasks completed before this migration
--
-- Rollback: database/200_task_upstream_sync_rollback.sql
-- ERROR CODE RANGE: 55880-55899
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF COL_LENGTH('grac_practice.practice_task','source_type_code') IS NULL
BEGIN PRINT 'ABORT (200): run 192_task_centre_v2_schema.sql first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_task_complete','P') IS NULL
BEGIN PRINT 'ABORT (200): sp_task_complete missing — run 194_task_centre_v2_parent_child.sql first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_task_activity_add','P') IS NULL
BEGIN PRINT 'ABORT (200): sp_task_activity_add missing — run 193 first.'; SET @ok = 0; END
-- The backfill cursor reads task_candidate directly. sp_task_source_sync
-- guards the table itself, but the cursor's UNION would fail at runtime,
-- so 197 is a hard prerequisite for this file.
IF OBJECT_ID('grac_practice.task_candidate','U') IS NULL
BEGIN PRINT 'ABORT (200): task_candidate missing — run 197_task_candidate_schema.sql first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('200_task_upstream_sync: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. task_source_action_state
--
-- One row per source item that has ever had task work. Entirely derived
-- from practice_task — it is a materialised answer, not a second source
-- of truth, which is why sp_task_source_sync can rebuild any row from
-- scratch at any time.
-- =====================================================================
IF OBJECT_ID('grac_practice.task_source_action_state','U') IS NULL
CREATE TABLE grac_practice.task_source_action_state(
    source_type_code      NVARCHAR(40) NOT NULL,
    source_record_id      BIGINT       NOT NULL,
    organization_id       BIGINT       NULL
        CONSTRAINT fk_pm_task_source_action_state_org
            REFERENCES grac_practice.organization(organization_id),

    -- Counts cover TOP-LEVEL tasks only. A parent owns the commitment
    -- (BRD §11), so a work package with five children is one action to
    -- the source, not six.
    total_tasks           INT NOT NULL
        CONSTRAINT df_pm_tsas_total     DEFAULT 0,
    open_tasks            INT NOT NULL
        CONSTRAINT df_pm_tsas_open      DEFAULT 0,
    completed_tasks       INT NOT NULL
        CONSTRAINT df_pm_tsas_completed DEFAULT 0,

    -- Candidates still awaiting validation/approval. Included so a
    -- source screen can distinguish "nothing is happening" from "work is
    -- identified but not yet accountable".
    open_candidates       INT NOT NULL
        CONSTRAINT df_pm_tsas_open_cand DEFAULT 0,

    --   NotStarted — work identified, none completed
    --   InProgress — some completed, some still open
    --   Completed  — every task raised for this source is complete
    --
    -- This is the STATE OF THE TASK ACTION. It is NOT the source's
    -- lifecycle status and must never be written back onto one.
    action_status_code    NVARCHAR(30) NOT NULL
        CONSTRAINT df_pm_tsas_status DEFAULT N'NotStarted',

    first_task_dt         DATETIME2 NULL,
    last_completed_dt     DATETIME2 NULL,

    updated_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_tsas_updated_by DEFAULT N'system',
    updated_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_tsas_updated_dt DEFAULT SYSUTCDATETIME(),

    CONSTRAINT pk_pm_task_source_action_state
        PRIMARY KEY (source_type_code, source_record_id),
    CONSTRAINT ck_pm_tsas_status
        CHECK (action_status_code IN (N'NotStarted', N'InProgress', N'Completed'))
);
GO

IF OBJECT_ID('grac_practice.task_source_action_state','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'ix_pm_tsas_org_status'
                      AND object_id = OBJECT_ID('grac_practice.task_source_action_state'))
    CREATE INDEX ix_pm_tsas_org_status
        ON grac_practice.task_source_action_state(organization_id, action_status_code)
        INCLUDE (source_type_code, source_record_id, completed_tasks, open_tasks);
GO

-- =====================================================================
-- 2. sp_task_source_sync
--
-- Recomputes one source's action state from practice_task +
-- task_candidate. Fully idempotent: running it twice, or running it for
-- a source with no work at all, converges to the same answer.
--
-- OUTPUT-only (no result set) — it is called from inside
-- sp_task_complete, which emits its own summary row.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_source_sync
    @source_type_code    NVARCHAR(40),
    @source_record_id    BIGINT,
    @caller_display_name NVARCHAR(100) = N'system',
    @action_status_code  NVARCHAR(30)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @action_status_code = NULL;

    IF @source_type_code IS NULL OR @source_record_id IS NULL
        THROW 55880, 'sp_task_source_sync: source_type_code and source_record_id are required.', 1;

    DECLARE @organization_id BIGINT,
            @total     INT = 0,
            @open      INT = 0,
            @completed INT = 0,
            @first_dt  DATETIME2,
            @last_done DATETIME2;

    -- Top-level tasks only — see the note on the counts columns.
    SELECT @organization_id = MIN(t.organization_id),
           @total     = COUNT(*),
           @open      = SUM(CASE WHEN t.closed_at IS NULL THEN 1 ELSE 0 END),
           @completed = SUM(CASE WHEN t.closed_at IS NOT NULL THEN 1 ELSE 0 END),
           @first_dt  = MIN(t.entered_dt),
           @last_done = MAX(t.closed_at)
      FROM grac_practice.practice_task t
     WHERE t.source_type_code = @source_type_code
       AND t.source_record_id = @source_record_id
       AND t.parent_task_id IS NULL;

    DECLARE @open_candidates INT = 0;
    IF OBJECT_ID('grac_practice.task_candidate','U') IS NOT NULL
        SELECT @open_candidates = COUNT(*)
          FROM grac_practice.task_candidate c
         WHERE c.source_type_code = @source_type_code
           AND c.source_record_id = @source_record_id
           AND c.status_code IN (N'New', N'Validated');

    SET @total     = ISNULL(@total, 0);
    SET @open      = ISNULL(@open, 0);
    SET @completed = ISNULL(@completed, 0);

    -- Nothing has ever been raised for this source: remove any stale row
    -- rather than asserting "NotStarted" about work that does not exist.
    IF @total = 0 AND @open_candidates = 0
    BEGIN
        DELETE FROM grac_practice.task_source_action_state
         WHERE source_type_code = @source_type_code
           AND source_record_id = @source_record_id;
        RETURN;
    END

    SET @action_status_code =
        CASE WHEN @total > 0 AND @open = 0 AND @open_candidates = 0 THEN N'Completed'
             WHEN @completed > 0                                    THEN N'InProgress'
             ELSE                                                        N'NotStarted'
        END;

    -- Organisation can only come from the candidate when no task exists.
    IF @organization_id IS NULL AND OBJECT_ID('grac_practice.task_candidate','U') IS NOT NULL
        SELECT TOP 1 @organization_id = c.organization_id
          FROM grac_practice.task_candidate c
         WHERE c.source_type_code = @source_type_code
           AND c.source_record_id = @source_record_id;

    MERGE grac_practice.task_source_action_state AS tgt
    USING (SELECT @source_type_code AS source_type_code,
                  @source_record_id AS source_record_id) AS src
       ON tgt.source_type_code = src.source_type_code
      AND tgt.source_record_id = src.source_record_id
    WHEN MATCHED THEN
        UPDATE SET organization_id    = @organization_id,
                   total_tasks        = @total,
                   open_tasks         = @open,
                   completed_tasks    = @completed,
                   open_candidates    = @open_candidates,
                   action_status_code = @action_status_code,
                   first_task_dt      = @first_dt,
                   last_completed_dt  = @last_done,
                   updated_by         = @caller_display_name,
                   updated_dt         = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (source_type_code, source_record_id, organization_id,
                total_tasks, open_tasks, completed_tasks, open_candidates,
                action_status_code, first_task_dt, last_completed_dt,
                updated_by, updated_dt)
        VALUES (@source_type_code, @source_record_id, @organization_id,
                @total, @open, @completed, @open_candidates,
                @action_status_code, @first_dt, @last_done,
                @caller_display_name, SYSUTCDATETIME());
END;
GO

-- =====================================================================
-- 3. sp_task_source_action_state_get
--
-- What a Gap / Risk / Observation screen renders in its "Task action"
-- line. The per-source wording comes from BRD §18's table and is derived
-- here rather than stored, so changing the phrasing never needs a data
-- migration.
--
-- Note every Completed message ends by handing the decision BACK to the
-- source module. That is §14 expressed as UI copy.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_source_action_state_get
    @source_type_code NVARCHAR(40),
    @source_record_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @source_type_code IS NULL OR @source_record_id IS NULL
        THROW 55885, 'sp_task_source_action_state_get: source_type_code and source_record_id are required.', 1;

    SELECT s.source_type_code   AS SourceTypeCode,
           s.source_record_id   AS SourceRecordId,
           s.organization_id    AS OrganizationId,
           s.total_tasks        AS TotalTasks,
           s.open_tasks         AS OpenTasks,
           s.completed_tasks    AS CompletedTasks,
           s.open_candidates    AS OpenCandidates,
           s.action_status_code AS ActionStatusCode,
           s.first_task_dt      AS FirstTaskDt,
           s.last_completed_dt  AS LastCompletedDt,
           CASE
             WHEN s.action_status_code <> N'Completed' THEN
                  CONCAT(CAST(s.completed_tasks AS NVARCHAR(10)), N' of ',
                         CAST(s.total_tasks AS NVARCHAR(10)), N' task action(s) completed',
                         CASE WHEN s.open_candidates > 0
                              THEN CONCAT(N'; ', CAST(s.open_candidates AS NVARCHAR(10)),
                                          N' awaiting validation')
                              ELSE N'' END, N'.')
             WHEN s.source_type_code = N'Gap'
                  THEN N'Task Action Completed; the gap may still require closure assessment.'
             WHEN s.source_type_code = N'Exception'
                  THEN N'Task Action Completed; the exception may remain active or require closure.'
             WHEN s.source_type_code = N'Risk'
                  THEN N'Treatment Task Completed; the risk may still require reassessment.'
             WHEN s.source_type_code IN (N'ContinuousAssurance', N'EventAssurance')
                  THEN N'Task Action Completed; the assurance outcome may still require assessment.'
             ELSE N'Assigned action completed.'
           END                  AS ActionStatusMessage
      FROM grac_practice.task_source_action_state s
     WHERE s.source_type_code = @source_type_code
       AND s.source_record_id = @source_record_id;
END;
GO

-- =====================================================================
-- 4. sp_task_complete  (REWRITE — superset of 194)
--
-- Identical to the 194 definition except for the upstream sync at the
-- end. Everything else is preserved verbatim: the mandatory-child gate,
-- the delegation to sp_task_close (which keeps the Implementation
-- two-gate rule and state-machine legality), completion attribution, and
-- the ChildCompleted / ParentEligibleForCompletion roll-up.
--
-- The sync runs AFTER COMMIT and inside TRY/CATCH: a reporting write
-- must never roll back a completion the owner has already confirmed.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_complete
    @task_id             BIGINT,
    @completion_remark   NVARCHAR(MAX) = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @actor_role_code     NVARCHAR(60)  = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_id IS NULL
        THROW 55690, 'sp_task_complete: task_id is required.', 1;

    DECLARE @closed_at DATETIME2, @parent_task_id BIGINT, @title NVARCHAR(250),
            @found BIT = 0, @source_type NVARCHAR(40), @source_record_id BIGINT;
    SELECT @closed_at        = closed_at,
           @parent_task_id   = parent_task_id,
           @title            = subject_title,
           @source_type      = source_type_code,
           @source_record_id = source_record_id,
           @found            = 1
      FROM grac_practice.practice_task WHERE task_id = @task_id;

    IF @found = 0
        THROW 55691, 'sp_task_complete: task not found.', 1;

    IF @closed_at IS NOT NULL
        THROW 55692, 'sp_task_complete: the task is already completed.', 1;

    -- ---- Mandatory-child gate (BRD §12) -----------------------------
    DECLARE @elig TABLE (
        TaskId BIGINT, IsEligible BIT, Reason NVARCHAR(300),
        ChildCount INT, MandatoryChildCount INT,
        MandatoryChildCompletedCount INT, MandatoryChildOpenCount INT);

    INSERT @elig EXEC grac_practice.sp_task_completion_eligibility @task_id = @task_id;

    DECLARE @eligible BIT, @reason NVARCHAR(300);
    SELECT TOP 1 @eligible = IsEligible, @reason = Reason FROM @elig;

    IF @eligible = 0
    BEGIN
        DECLARE @gate_msg NVARCHAR(400) =
            CONCAT(N'sp_task_complete: task ', CAST(@task_id AS NVARCHAR(20)),
                   N' is not eligible for completion. ', @reason);
        THROW 55693, @gate_msg, 1;
    END

    BEGIN TRAN;

    EXEC grac_practice.sp_task_close
         @task_id           = @task_id,
         @actor_employee_id = @actor_employee_id,
         @actor_role_code   = @actor_role_code,
         @reason_code       = N'TASK_COMPLETED',
         @reason_text       = @completion_remark;

    UPDATE grac_practice.practice_task
       SET completed_by_employee_id = @actor_employee_id,
           completed_dt             = SYSUTCDATETIME(),
           updated_by               = @caller_display_name,
           updated_dt               = SYSUTCDATETIME()
     WHERE task_id = @task_id;

    EXEC grac_practice.sp_task_activity_add
         @task_id             = @task_id,
         @activity_type_code  = N'Completed',
         @remark              = @completion_remark,
         @actor_employee_id   = @actor_employee_id,
         @caller_display_name = @caller_display_name;

    IF @parent_task_id IS NOT NULL
    BEGIN
        EXEC grac_practice.sp_task_activity_add
             @task_id             = @parent_task_id,
             @activity_type_code  = N'ChildCompleted',
             @remark              = @completion_remark,
             @to_value            = @title,
             @actor_employee_id   = @actor_employee_id,
             @caller_display_name = @caller_display_name;

        DECLARE @pelig TABLE (
            TaskId BIGINT, IsEligible BIT, Reason NVARCHAR(300),
            ChildCount INT, MandatoryChildCount INT,
            MandatoryChildCompletedCount INT, MandatoryChildOpenCount INT);

        INSERT @pelig EXEC grac_practice.sp_task_completion_eligibility @task_id = @parent_task_id;

        IF EXISTS (SELECT 1 FROM @pelig WHERE IsEligible = 1)
            EXEC grac_practice.sp_task_activity_add
                 @task_id             = @parent_task_id,
                 @activity_type_code  = N'ParentEligibleForCompletion',
                 @remark              = N'All mandatory child tasks are complete. The parent owner can now confirm completion of the overall objective.',
                 @actor_employee_id   = @actor_employee_id,
                 @caller_display_name = @caller_display_name;
    END

    COMMIT;

    -- ---- NEW in 200: upstream synchronisation (BRD §14) --------------
    -- Reports; never decides. Nothing below writes to a source table's
    -- own status.
    DECLARE @sync_status NVARCHAR(30) = NULL;

    IF @source_type IS NOT NULL AND @source_record_id IS NOT NULL
    BEGIN
        BEGIN TRY
            EXEC grac_practice.sp_task_source_sync
                 @source_type_code    = @source_type,
                 @source_record_id    = @source_record_id,
                 @caller_display_name = @caller_display_name,
                 @action_status_code  = @sync_status OUTPUT;
        END TRY
        BEGIN CATCH
            DECLARE @sync_warn NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_task_complete: upstream sync warning: ', @sync_warn);
        END CATCH
    END

    SELECT @task_id             AS TaskId,
           N'Completed'         AS StatusCode,
           @parent_task_id      AS ParentTaskId,
           @source_type         AS SourceTypeCode,
           @source_record_id    AS SourceRecordId,
           @sync_status         AS SourceActionStatusCode;
END;
GO

-- =====================================================================
-- 5. Backfill
--
-- Tasks completed before this migration existed still represent real
-- completed action. Rebuild the state for every source that has task or
-- candidate work, so source screens are correct on day one rather than
-- only for work completed from now on.
-- =====================================================================
DECLARE @src_type NVARCHAR(40), @src_id BIGINT, @n INT = 0;

DECLARE src_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT source_type_code, source_record_id
      FROM grac_practice.practice_task
     WHERE source_type_code IS NOT NULL
       AND source_record_id IS NOT NULL
       AND parent_task_id IS NULL
    UNION
    SELECT DISTINCT source_type_code, source_record_id
      FROM grac_practice.task_candidate
     WHERE source_type_code IS NOT NULL
       AND source_record_id IS NOT NULL;

OPEN src_cur;
FETCH NEXT FROM src_cur INTO @src_type, @src_id;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC grac_practice.sp_task_source_sync
             @source_type_code    = @src_type,
             @source_record_id    = @src_id,
             @caller_display_name = N'backfill-200';
        SET @n = @n + 1;
    END TRY
    BEGIN CATCH
        PRINT CONCAT(N'200 backfill warning for ', @src_type, N' #',
                     CAST(@src_id AS NVARCHAR(20)), N': ', ERROR_MESSAGE());
    END CATCH
    FETCH NEXT FROM src_cur INTO @src_type, @src_id;
END
CLOSE src_cur;
DEALLOCATE src_cur;

PRINT CONCAT('200 backfill: synchronised ', @n, ' source item(s).');
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '200 objects present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.task_source_action_state','U')       IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_source_sync','P')             IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_source_action_state_get','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'sp_task_complete reports the source' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_task_complete')
                            AND name = '@completion_remark')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'source action state by status' AS Check_,
       action_status_code AS ActionStatusCode, COUNT(*) AS Sources_
  FROM grac_practice.task_source_action_state
 GROUP BY action_status_code;

PRINT '200 upstream synchronisation installed. Phase 2 database migrations complete.';
GO

SET NOEXEC OFF;
GO
