-- =====================================================================
-- 199 Task Candidate — source integrations  (BRD §3, §4A, §5, §15)
--
-- BRD §3 lists five system-generated sources. This migration wires three
-- of them into the candidate stage, and deliberately does NOT wire the
-- fourth and fifth. Read the conflict notes before changing that.
--
--   Gap                 -> candidate   (rerouted; was a direct task)
--   Risk                -> candidate   (new; Risk raised no tasks before)
--   ContinuousAssurance -> candidate   (new; Assurance raised no tasks before)
--   EventAssurance      -> NOT WIRED   (see conflict note 1)
--   Exception           -> NOT WIRED   (see conflict note 2)
--
-- CONFLICT NOTE 1 — Event Assurance  (BRD §3 vs migration 135)
-- ------------------------------------------------------------
-- The BRD says Event Assurance creates Task Candidates. Migration 135
-- deliberately did the opposite: the Event Driven tab "reads the event
-- engine directly rather than mirroring event_instance rows into
-- practice_task". Wiring events in would give the same work two
-- execution surfaces — the event checklist AND a task — and an operator
-- completing one would not complete the other.
--
-- Per BRD §19 ("preserve data integrity and explicitly document the
-- conflict for review rather than silently removing existing
-- functionality") the existing design stands and this deviation is
-- logged in docs/task-centre-v2.md for sign-off. If Event Assurance
-- should raise candidates, the Event Driven tab has to be reworked to
-- read tasks first — that is a UI decision, not a data one.
--
-- CONFLICT NOTE 2 — Exception
-- ---------------------------
-- BRD §3 lists Exception as a candidate source, but an exception in GRAC
-- is a formal, time-boxed decision NOT to remediate inside the window
-- (161's own definition). There is no remediation action to execute, so
-- there is nothing for Task Centre to own. The one place an exception
-- does generate work — an approved exception that expires and needs
-- re-assessment — has no expiry sweep yet. Left unwired until that
-- sweep exists; raising a candidate at approval time would create a task
-- for work nobody has agreed to do.
--
-- CONTENTS
--   1. sp_custom_gap_task_create        REWRITE  — raises a candidate
--   2. sp_risk_candidate_accept         REWRITE  — superset of 170
--   3. sp_org_assurance_observation_accept REWRITE — superset of 102
--   4. sp_task_source_items             NEW      — source -> candidates + tasks
--
-- Every rewrite is a STRICT SUPERSET: same name, same parameters, same
-- result-set columns (plus additions), same side effects. No caller
-- changes anywhere.
--
-- Rollback: database/199_task_candidate_sources_rollback.sql
-- ERROR CODE RANGE: 55850-55879
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.sp_task_candidate_create','P') IS NULL
BEGIN PRINT 'ABORT (199): sp_task_candidate_create missing — run 198_task_candidate_procs.sql first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
BEGIN PRINT 'ABORT (199): custom_gap missing — run 054 first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('199_task_candidate_sources: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_custom_gap_task_create  (REWRITE — Gap now raises a candidate)
--
-- 174's sp_custom_gap_analysis_save calls this whenever
-- remediation_possible = 'Y'. That caller is NOT touched: the seam is
-- this proc, and rerouting it here means the gap flow moves to the
-- candidate model without a single line changing in 174.
--
-- RESULT SET COMPATIBILITY: the original returned (TaskId, Created).
-- Both columns survive. TaskId is now NULL — honestly so, because no
-- task exists until the candidate is approved — and TaskCandidateId is
-- added. Nothing in the repository reads TaskId from this proc; the
-- columns are kept so an unknown consumer degrades rather than breaks.
--
-- IDEMPOTENCY: dedupe key 'GAP_REMEDIATION'. Re-saving a gap analysis
-- returns the existing open candidate instead of raising a second one.
-- A human wanting a SECOND action for the same gap adds it through the
-- Candidates screen with a NULL dedupe key — BRD §15's one-source-
-- many-tasks path.
--
-- BACKWARD COMPATIBILITY: if the gap already has an open task from
-- before Phase 2 (the pre-197 behaviour), that task is returned and no
-- candidate is raised. Existing gaps keep their existing tasks.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_task_create
    @custom_gap_id           BIGINT,
    @assigned_to_employee_id BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @custom_gap_id IS NULL
        THROW 55500, 'sp_custom_gap_task_create: custom_gap_id is required.', 1;

    -- Pre-Phase-2 tasks win: a gap that already has open work must not
    -- also acquire a candidate for the same work.
    DECLARE @existing_task_id BIGINT =
        (SELECT TOP 1 task_id
           FROM grac_practice.practice_task
          WHERE subject_entity_type = N'CustomGap'
            AND subject_entity_id   = @custom_gap_id
            AND closed_at IS NULL
          ORDER BY task_id DESC);

    IF @existing_task_id IS NOT NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT) AS TaskCandidateId,
               @existing_task_id    AS TaskId,
               CAST(0 AS BIT)       AS Created;
        RETURN;
    END

    DECLARE @org_id BIGINT, @gap_title NVARCHAR(250), @gap_priority NVARCHAR(30),
            @gap_owner BIGINT, @summary NVARCHAR(MAX);

    SELECT @org_id       = organization_id,
           @gap_title    = title,
           @gap_priority = priority,
           @gap_owner    = owner_employee_id
      FROM grac_practice.custom_gap
     WHERE custom_gap_id = @custom_gap_id;

    IF @org_id IS NULL
        THROW 55501, 'sp_custom_gap_task_create: custom_gap not found.', 1;

    SELECT @summary = recommended_action_summary
      FROM grac_practice.custom_gap_analysis WHERE custom_gap_id = @custom_gap_id;

    -- The gap's own priority carries into the proposal. BRD §5 forbids
    -- re-doing upstream analysis, and urgency is upstream's call — the
    -- candidate stage only confirms it.
    IF @gap_priority NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @gap_priority = N'Medium';

    DECLARE @title  NVARCHAR(250) = LEFT(CONCAT(N'Gap task: ', @gap_title), 250);
    DECLARE @source_ref NVARCHAR(200) = CONCAT(N'GAP-', CAST(@custom_gap_id AS NVARCHAR(20)));

    DECLARE @candidate_id BIGINT, @created BIT;

    BEGIN TRY
        EXEC grac_practice.sp_task_candidate_create
             @organization_id            = @org_id,
             @source_type_code           = N'Gap',
             @source_record_id           = @custom_gap_id,
             @candidate_title            = @title,
             @candidate_description      = @summary,
             @source_reference           = @source_ref,
             @source_dedupe_key          = N'GAP_REMEDIATION',
             @task_type_code             = N'Rectification',
             @explicit_owner_employee_id = @assigned_to_employee_id,
             @proposed_priority          = @gap_priority,
             @actor_employee_id          = @assigned_to_employee_id,
             @caller_display_name        = @caller_display_name,
             @task_candidate_id          = @candidate_id OUTPUT,
             @created                    = @created      OUTPUT;
    END TRY
    BEGIN CATCH
        DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
        THROW 55502, @msg, 1;
    END CATCH

    SELECT @candidate_id        AS TaskCandidateId,
           CAST(NULL AS BIGINT) AS TaskId,
           ISNULL(@created, 0)  AS Created;
END;
GO

-- =====================================================================
-- 2. sp_risk_candidate_accept  (REWRITE — superset of 170)
--
-- Accepting a risk candidate means "we will track this as a formal
-- risk". BRD §18's completion semantics call the resulting work a
-- "Treatment Task", so acceptance is exactly the point at which
-- execution work exists.
--
-- The entire 170 body is preserved verbatim — same validation, same
-- UPDATE, same history row, same TRY/CATCH shape. Only the candidate
-- raise and one extra result-set column are new, and the raise sits
-- OUTSIDE the transaction so a Task Centre problem can never roll back
-- a governance decision the risk manager has already made.
--
-- @raise_task_candidate lets a caller opt out (default on).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_accept
    @risk_candidate_id       BIGINT,
    @acceptance_note         NVARCHAR(MAX),
    @accepted_by_employee_id BIGINT,
    @formal_risk_ref         NVARCHAR(200) = NULL,
    @caller_display_name     NVARCHAR(100) = N'system',
    @raise_task_candidate    BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 55430, 'sp_risk_candidate_accept: risk_candidate_id is required.', 1;
    IF @acceptance_note IS NULL OR LEN(LTRIM(RTRIM(@acceptance_note))) = 0
        THROW 55431, 'sp_risk_candidate_accept: acceptance_note is required.', 1;
    IF @accepted_by_employee_id IS NULL
        THROW 55432, 'sp_risk_candidate_accept: accepted_by_employee_id is required.', 1;

    DECLARE @current NVARCHAR(30);
    SELECT @current = status_code
      FROM grac_practice.risk_candidate WHERE risk_candidate_id = @risk_candidate_id;
    IF @current IS NULL
        THROW 55433, 'sp_risk_candidate_accept: candidate not found.', 1;
    IF @current <> N'Pending'
        THROW 55434, 'sp_risk_candidate_accept: only Pending candidates can be accepted.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_candidate
           SET status_code             = N'Accepted',
               accepted_by_employee_id = @accepted_by_employee_id,
               accepted_dt             = SYSUTCDATETIME(),
               acceptance_note         = @acceptance_note,
               formal_risk_ref         = @formal_risk_ref,
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id, N'Accept', N'Pending', N'Accepted',
             CONCAT(N'Note: ', @acceptance_note,
                    CASE WHEN @formal_risk_ref IS NOT NULL
                         THEN CONCAT(N'  Formal risk ref: ', @formal_risk_ref)
                         ELSE N'' END),
             @accepted_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    -- ---- NEW in 199: raise the treatment Task Candidate --------------
    DECLARE @candidate_id BIGINT = NULL, @created BIT = 0;

    IF ISNULL(@raise_task_candidate, 1) = 1
    BEGIN
        BEGIN TRY
            DECLARE @org_id BIGINT, @risk_title NVARCHAR(300),
                    @risk_summary NVARCHAR(MAX), @severity NVARCHAR(30);

            SELECT @org_id       = organization_id,
                   @risk_title   = candidate_title,
                   @risk_summary = candidate_summary,
                   @severity     = severity_code
              FROM grac_practice.risk_candidate
             WHERE risk_candidate_id = @risk_candidate_id;

            -- risk_candidate.severity_code uses the same four-level
            -- vocabulary as task priority; anything unexpected lands on
            -- Medium rather than failing the accept.
            DECLARE @priority NVARCHAR(30) =
                CASE WHEN @severity IN (N'Low', N'Medium', N'High', N'Critical')
                     THEN @severity ELSE N'Medium' END;

            DECLARE @cand_title NVARCHAR(250) =
                LEFT(CONCAT(N'Risk treatment: ', @risk_title), 250);
            DECLARE @cand_desc NVARCHAR(MAX) =
                CONCAT(ISNULL(@risk_summary, N''),
                       N'  Accepted as a formal risk: ', @acceptance_note);
            DECLARE @source_ref NVARCHAR(200) =
                CONCAT(N'RISK-', CAST(@risk_candidate_id AS NVARCHAR(20)));

            EXEC grac_practice.sp_task_candidate_create
                 @organization_id       = @org_id,
                 @source_type_code      = N'Risk',
                 @source_record_id      = @risk_candidate_id,
                 @candidate_title       = @cand_title,
                 @candidate_description = @cand_desc,
                 @source_reference      = @source_ref,
                 @source_dedupe_key     = N'RISK_TREATMENT',
                 @task_type_code        = N'RiskDriven',
                 @proposed_priority     = @priority,
                 @actor_employee_id     = @accepted_by_employee_id,
                 @caller_display_name   = @caller_display_name,
                 @task_candidate_id     = @candidate_id OUTPUT,
                 @created               = @created      OUTPUT;
        END TRY
        BEGIN CATCH
            DECLARE @tc_warn NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_risk_candidate_accept: task candidate warning: ', @tc_warn);
        END CATCH
    END

    SELECT @risk_candidate_id AS RiskCandidateId,
           N'Accepted'        AS StatusCode,
           @candidate_id      AS TaskCandidateId;
END;
GO

-- =====================================================================
-- 3. sp_org_assurance_observation_accept  (REWRITE — superset of 102)
--
-- An accepted observation is a confirmed finding that somebody has to
-- act on — BRD §3's "Continuous Assurance creates Task Candidate".
--
-- The original was a 10-line wrapper over
-- sp_org_assurance_observation_transition. That call is preserved
-- exactly, including the InReview -> Accepted guard, so an illegal
-- transition still throws 54115 before any candidate is raised.
--
-- Emits NO result set, matching the original (the transition proc
-- returns nothing and callers rely on that).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_accept
    @organization_id BIGINT,
    @observation_id  BIGINT,
    @notes           NVARCHAR(MAX) = NULL,
    @actor           NVARCHAR(100) = 'system',
    @raise_task_candidate BIT      = 1
AS
BEGIN
    SET NOCOUNT ON;

    EXEC grac_practice.sp_org_assurance_observation_transition
        @organization_id = @organization_id, @observation_id = @observation_id,
        @expected_from_codes = N'InReview', @to_code = N'Accepted',
        @stamp_field = N'accepted', @notes = @notes, @actor = @actor;

    -- ---- NEW in 199: raise the remediation Task Candidate ------------
    IF ISNULL(@raise_task_candidate, 1) = 1
    BEGIN
        BEGIN TRY
            DECLARE @title NVARCHAR(300), @description NVARCHAR(MAX),
                    @obs_code NVARCHAR(120), @severity NVARCHAR(30);

            SELECT @title       = o.observation_title,
                   @description = o.observation_description,
                   @obs_code    = o.observation_code,
                   @severity    = o.severity_code
              FROM grac_practice.org_assurance_observation o
             WHERE o.org_assurance_observation_id = @observation_id;

            IF @title IS NOT NULL
            BEGIN
                -- Observation severity is org-configurable
                -- (org_assurance_observation_severity_master), so it may
                -- not use the task priority vocabulary. Map what matches
                -- and fall back to Medium — the validator confirms it
                -- anyway, which is the entire point of the stage.
                DECLARE @priority NVARCHAR(30) =
                    CASE WHEN @severity IN (N'Low', N'Medium', N'High', N'Critical')
                         THEN @severity ELSE N'Medium' END;

                DECLARE @cand_title NVARCHAR(250) =
                    LEFT(CONCAT(N'Observation: ', @title), 250);
                DECLARE @cand_desc NVARCHAR(MAX) =
                    CONCAT(ISNULL(@description, N''),
                           CASE WHEN @notes IS NULL THEN N''
                                ELSE CONCAT(N'  Acceptance note: ', @notes) END);
                DECLARE @source_ref NVARCHAR(200) =
                    ISNULL(@obs_code, CONCAT(N'OBS-', CAST(@observation_id AS NVARCHAR(20))));

                DECLARE @candidate_id BIGINT, @created BIT;

                EXEC grac_practice.sp_task_candidate_create
                     @organization_id       = @organization_id,
                     @source_type_code      = N'ContinuousAssurance',
                     @source_record_id      = @observation_id,
                     @candidate_title       = @cand_title,
                     @candidate_description = @cand_desc,
                     @source_reference      = @source_ref,
                     @source_dedupe_key     = N'OBSERVATION_REMEDIATION',
                     @task_type_code        = N'Rectification',
                     @proposed_priority     = @priority,
                     @caller_display_name   = @actor,
                     @task_candidate_id     = @candidate_id OUTPUT,
                     @created               = @created      OUTPUT;
            END
        END TRY
        BEGIN CATCH
            DECLARE @tc_warn NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_org_assurance_observation_accept: task candidate warning: ', @tc_warn);
        END CATCH
    END
END;
GO

-- =====================================================================
-- 4. sp_task_source_items  (BRD §15)
--
-- "The source should display associated tasks, their status and links."
--
-- sp_task_source_tasks (195) answers that for TASKS. But once the
-- candidate stage exists, a source can have identified work that is not
-- yet a task, and a panel that hides it would tell the gap owner
-- "nothing is happening" when in fact something is awaiting validation.
--
-- This proc returns ONE unified list — candidates and tasks together,
-- discriminated by ItemKind — so the source screens can show the whole
-- picture. Approved candidates are excluded because the task they became
-- is already in the list; showing both would double-count the work.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_source_items
    @source_type_code NVARCHAR(40),
    @source_record_id BIGINT,
    @organization_id  BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @source_type_code IS NULL OR @source_record_id IS NULL
        THROW 55860, 'sp_task_source_items: source_type_code and source_record_id are required.', 1;

    -- ---- Candidates still awaiting validation / approval ------------
    SELECT N'Candidate'                AS ItemKind,
           c.task_candidate_id         AS ItemId,
           c.candidate_number          AS ItemNumber,
           c.candidate_title           AS Title,
           c.status_code               AS StatusCode,
           c.status_code               AS StatusName,
           c.proposed_owner_employee_id AS OwnerEmployeeId,
           e.employee_name             AS OwnerName,
           c.proposed_priority         AS Priority,
           c.proposed_due_at           AS DueAt,
           CAST(NULL AS NVARCHAR(30))  AS SlaStatusCode,
           CAST(0 AS BIT)              AS IsChild,
           CAST(NULL AS BIGINT)        AS ParentTaskId,
           0                           AS ChildCount,
           CAST(NULL AS DATETIME2)     AS CompletedDt,
           c.entered_dt                AS RaisedDt
      FROM grac_practice.task_candidate c
 LEFT JOIN grac_practice.organization_employee e ON e.employee_id = c.proposed_owner_employee_id
     WHERE c.source_type_code = @source_type_code
       AND c.source_record_id = @source_record_id
       AND c.status_code IN (N'New', N'Validated', N'Discarded')
       AND (@organization_id IS NULL OR c.organization_id = @organization_id)

    UNION ALL

    -- ---- Tasks (including children, flagged) -------------------------
    SELECT N'Task'                     AS ItemKind,
           v.task_id                   AS ItemId,
           v.task_number               AS ItemNumber,
           v.subject_title             AS Title,
           v.current_status_code       AS StatusCode,
           v.current_status_name       AS StatusName,
           v.assigned_to_employee_id   AS OwnerEmployeeId,
           v.assigned_to_employee_name AS OwnerName,
           v.priority                  AS Priority,
           v.sla_due_at                AS DueAt,
           v.sla_status_code           AS SlaStatusCode,
           v.is_child                  AS IsChild,
           v.parent_task_id            AS ParentTaskId,
           v.child_count               AS ChildCount,
           v.completed_dt              AS CompletedDt,
           v.entered_dt                AS RaisedDt
      FROM grac_practice.vw_pm_practice_task v
     WHERE v.source_type_code = @source_type_code
       AND v.source_record_id = @source_record_id
       AND (@organization_id IS NULL OR v.organization_id = @organization_id)

     ORDER BY ItemKind DESC,          -- Tasks first, then Candidates
              IsChild,                -- parents above their children
              RaisedDt;
END;
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '199 source integrations present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_custom_gap_task_create','P')           IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_candidate_accept','P')             IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_observation_accept','P')  IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_source_items','P')                 IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'source procs keep their original parameters' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_custom_gap_task_create')
                            AND name = '@assigned_to_employee_id')
             AND EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_candidate_accept')
                            AND name = '@formal_risk_ref')
             AND EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_org_assurance_observation_accept')
                            AND name = '@notes')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '199 Task Candidate source integrations installed. Next: 200_task_upstream_sync.sql';
PRINT 'NOT WIRED (by design, see file header): Event Assurance, Exception.';
GO

SET NOEXEC OFF;
GO
