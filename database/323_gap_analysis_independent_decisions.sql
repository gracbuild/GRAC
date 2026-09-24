-- =====================================================================
-- 323 Gap Analysis: three independent decisions replace the mandatory
--     Remediation-possible / business-Risk Yes-No branching
--
-- REPORT: "Currently the flow is: Remediation Possible = Yes -> Generate
--     Task; = No -> Move to Exception; Risk = Yes -> Move to Risk
--     Candidate. I want to remove this conditional/branching logic
--     completely. Instead, provide three independent checkboxes --
--     Generate Task / Request Exception / Create Risk -- each working
--     independently, more than one selectable at the same time."
--     Also: "the existing Task creation flow -- when Task creation is
--     triggered, it appears that the Task is not actually being
--     created. Trace the complete flow and fix it."
--
-- BACKGROUND -- there is nothing new to build here, only branching to
-- remove
-- -------------------------------------------------------------------
-- custom_gap_analysis.recommend_task / recommend_exception /
-- recommend_risk are NOT new columns -- they are the ORIGINAL three
-- independent BIT flags from 156 (schema) / 157 (procs), plain
-- NOT NULL DEFAULT 0 with no mutual-exclusion constraint between them.
-- Migration 168 is what introduced remediation_possible /
-- business_risk_present (two mandatory CHAR(1) Yes/No columns) and had
-- sp_custom_gap_analysis_save derive the three legacy flags FROM the
-- two decisions (one Yes/No forced exactly one of Task/Exception; a
-- second, separate Yes/No gated Risk) -- and, symmetrically, derive the
-- two decisions back from the three flags when the two were not
-- supplied. That two-way derivation is the "conditional/branching
-- logic" being asked to go. 172 (risk trigger) and 252 (restoring 168
-- + 174 after a regression) both kept the same derivation; this
-- migration is the first to remove it.
--
-- So: no new table, no new column. sp_custom_gap_analysis_save (252's
-- body) is re-issued with the derivation deleted -- @recommend_task /
-- @recommend_exception / @recommend_risk become the direct, independent
-- inputs, each with its own auto-trigger, none conditioned on the
-- other two. @remediation_possible / @business_risk_present are kept
-- as accepted parameters (existing callers / historical rows are not
-- broken) but are no longer read to drive anything and are no longer
-- written to from the three flags -- COALESCEd so a value already on
-- the row survives untouched, and the UI no longer sends either one.
--
-- TASK-CREATION INVESTIGATION
-- ----------------------------
-- Traced Risk Analysis -> POST /gaps/{id}/analysis
-- (GapLifecycleService.SaveAnalysisAsync) -> sp_custom_gap_analysis_save
-- -> sp_custom_gap_task_create -> sp_task_open -> practice_task. Two
-- things found, both already fixed once in this codebase's history and
-- carried forward here rather than re-broken:
--
--   1. sp_custom_gap_analysis_save wraps the sp_custom_gap_task_create
--      call in TRY/CATCH and only PRINTs on failure (migration 174,
--      kept by 252) -- "best-effort", so a failed create is silent to
--      the API and the UI. That PRINT is invisible outside SSMS. This
--      migration captures success/error into two local variables per
--      artefact and returns them in a NEW second result set
--      (TaskCreated/TaskError/ExceptionCreated/ExceptionError/
--      RiskCreated/RiskError) so a real failure is now visible to the
--      API and, from there, the UI -- instead of the analysis silently
--      reporting success with no task to show for it.
--
--   2. sp_custom_gap_task_create itself was, once already (between
--      migrations 199 and 253), rerouted to raise an invisible Task
--      CANDIDATE instead of opening a real Task -- exactly today's
--      symptom ("Task creation triggered, but no Task appears
--      anywhere"). 253 fixed this by reverting the proc to call
--      sp_task_open directly. There is no migration after 253 that
--      touches sp_custom_gap_task_create, sp_task_list or
--      sp_task_center_counts, so nothing in this codebase's own history
--      should have undone 253 -- but a live database can be at any
--      point in its migration history, and this file cannot query it.
--      Section 1 below re-issues 253's exact proc bodies (byte-for-byte
--      the same CREATE OR ALTER) as a belt-and-suspenders guarantee: if
--      253 is already applied this is a no-op re-assertion; if it is
--      not, this migration brings the database to the same corrected
--      state either way. See gap_task_direct_and_task_centre_visibility.md.
--
-- SCOPE
--   1. sp_custom_gap_task_create      -- re-issued verbatim from 253
--                                         (direct task open, no change)
--   2. sp_custom_gap_analysis_save    -- 252's body, branching removed,
--                                         three independent triggers,
--                                         new TaskCreated/... result set
--   sp_custom_gap_analysis_get is UNCHANGED and NOT re-issued -- it
--   already projects RecommendTask/RecommendException/RecommendRisk
--   (168) and nothing about what they mean or how they are read
--   changes.
--
-- No schema change. No data migration -- recommend_task/exception/risk
-- already hold each row's history exactly as this migration will keep
-- writing them; remediation_possible/business_risk_present are left in
-- place, untouched, for any historical row that has them.
--
-- Rollback: 323_gap_analysis_independent_decisions_rollback.sql
-- (restores sp_custom_gap_analysis_save to 252's exact body;
-- sp_custom_gap_task_create is left as-is since this migration did not
-- change its body, only re-asserted it).
--
-- SAFE TO RE-RUN. Requires 156, 168, 249, 252, 253.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (323): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.custom_gap_analysis','U') IS NULL
BEGIN PRINT 'ABORT (323): custom_gap_analysis missing (run 156 first).'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.custom_gap_analysis','recommend_task') IS NULL
   OR COL_LENGTH('grac_practice.custom_gap_analysis','recommend_exception') IS NULL
   OR COL_LENGTH('grac_practice.custom_gap_analysis','recommend_risk') IS NULL
BEGIN PRINT 'ABORT (323): recommend_task/exception/risk missing (run 156 first).'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.custom_gap_analysis','remediation_possible') IS NULL
   OR COL_LENGTH('grac_practice.custom_gap_analysis','business_risk_present') IS NULL
BEGIN PRINT 'ABORT (323): remediation_possible/business_risk_present missing (run 168 first).'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.custom_gap_analysis','preventive_action') IS NULL
BEGIN PRINT 'ABORT (323): preventive_action missing (run 249 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_task_open','P') IS NULL
BEGIN PRINT 'ABORT (323): sp_task_open missing (run 196 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_exception_request_create','P') IS NULL
BEGIN PRINT 'ABORT (323): sp_exception_request_create missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_risk_candidate_create','P') IS NULL
BEGIN PRINT 'ABORT (323): sp_risk_candidate_create missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.task_type_master','U') IS NULL
BEGIN PRINT 'ABORT (323): task_type_master missing (run 037 first).'; SET @ok = 0; END
ELSE IF NOT EXISTS (SELECT 1 FROM grac_practice.task_type_master WHERE type_code = N'Rectification')
BEGIN PRINT 'ABORT (323): task type Rectification missing (run 037 first).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('323_gap_analysis_independent_decisions: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_custom_gap_task_create -- re-issued verbatim from 253
--
-- Byte-for-byte the same body as 253 (direct sp_task_open call, gap
-- priority carried through, superset TaskCandidateId/TaskId/Created
-- result set, idempotent one-open-task-per-gap). Re-applied here only
-- as a guarantee that whatever this database's migration history
-- actually is, it ends up on the corrected proc -- see the
-- TASK-CREATION INVESTIGATION note above. Nothing about this proc's
-- behaviour is changing.
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

    -- Idempotent per gap: one open task per gap.
    DECLARE @existing_id BIGINT =
        (SELECT TOP 1 task_id
           FROM grac_practice.practice_task
          WHERE subject_entity_type = N'CustomGap'
            AND subject_entity_id   = @custom_gap_id
            AND closed_at IS NULL
          ORDER BY task_id DESC);
    IF @existing_id IS NOT NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT) AS TaskCandidateId,
               @existing_id         AS TaskId,
               CAST(0 AS BIT)       AS Created;
        RETURN;
    END

    DECLARE @org_id BIGINT, @gap_title NVARCHAR(250),
            @gap_priority NVARCHAR(30), @summary NVARCHAR(MAX);

    SELECT @org_id       = organization_id,
           @gap_title    = title,
           @gap_priority = priority
      FROM grac_practice.custom_gap
     WHERE custom_gap_id = @custom_gap_id;

    IF @org_id IS NULL
        THROW 55501, 'sp_custom_gap_task_create: custom_gap not found.', 1;

    SELECT @summary = recommended_action_summary
      FROM grac_practice.custom_gap_analysis WHERE custom_gap_id = @custom_gap_id;

    -- Carried from 199: the gap's own priority drives the task. Anything
    -- outside the four valid values falls back to Medium.
    IF @gap_priority NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @gap_priority = N'Medium';

    -- T-SQL: EXEC parameters can't take expressions; precompute the title.
    DECLARE @task_id    BIGINT;
    DECLARE @task_title NVARCHAR(250) = LEFT(CONCAT(N'Gap task: ', @gap_title), 250);
    BEGIN TRY
        EXEC grac_practice.sp_task_open
            @organization_id         = @org_id,
            @task_type_code          = N'Rectification',
            @subject_entity_type     = N'CustomGap',
            @subject_entity_id       = @custom_gap_id,
            @subject_title           = @task_title,
            @subject_description     = @summary,
            @priority                = @gap_priority,
            @origin_code             = N'Custom',
            @assigned_to_employee_id = @assigned_to_employee_id,
            @actor_employee_id       = @assigned_to_employee_id,
            @task_id                 = @task_id OUTPUT;
    END TRY
    BEGIN CATCH
        DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
        THROW 55502, @msg, 1;
    END CATCH

    SELECT CAST(NULL AS BIGINT) AS TaskCandidateId,
           @task_id             AS TaskId,
           CAST(1 AS BIT)       AS Created;
END
GO
PRINT '323: sp_custom_gap_task_create re-asserted (253 body, direct task open).';
GO

-- =====================================================================
-- 2. sp_custom_gap_analysis_save -- three independent decisions
--
-- 252's body with:
--   * The two-way remediation_possible/business_risk_present <->
--     recommend_task/recommend_exception/recommend_risk derivation
--     DELETED. @recommend_task/@recommend_exception/@recommend_risk are
--     now the direct inputs (default 0), each independently driving its
--     own auto-trigger -- any combination, including all three or none.
--   * @remediation_possible/@business_risk_present kept as accepted
--     parameters for callers that still pass them, but only COALESCEd
--     onto whatever the row already has -- never read to drive a
--     trigger, never derived from the three flags. The UI sends NULL
--     for both from now on, so in practice these two columns simply
--     stop changing.
--   * Best-effort TRY/CATCH around each trigger now also records
--     success/failure into local variables, returned in a NEW second
--     result set (TaskCreated/TaskError/ExceptionCreated/
--     ExceptionError/RiskCreated/RiskError) -- see the TASK-CREATION
--     INVESTIGATION note above. The PRINT diagnostics are kept
--     alongside for anyone watching from SSMS.
--   * Terminal-invalid guard (173), preventive_action (249), auto-
--     delegate (174), and the CustomGapId result set are all otherwise
--     unchanged from 252.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_analysis_save
    @custom_gap_id            BIGINT,
    @detection_method_code    NVARCHAR(60)  = NULL,
    @detection_method_name    NVARCHAR(200) = NULL,
    @severity_code            NVARCHAR(30)  = NULL,
    @severity_name            NVARCHAR(120) = NULL,
    @business_impact_code     NVARCHAR(30)  = NULL,
    @business_impact_summary  NVARCHAR(MAX) = NULL,
    @regulatory_impact_code   NVARCHAR(30)  = NULL,
    @regulatory_impact_summary NVARCHAR(MAX) = NULL,
    @rca_required             BIT           = 0,
    @rca_method_code          NVARCHAR(60)  = NULL,
    @rca_summary              NVARCHAR(MAX) = NULL,
    @recommended_action_summary NVARCHAR(MAX) = NULL,
    -- Migration 249: Corrective Action stays on
    -- recommended_action_summary above; this is the separate Preventive
    -- Action answer.
    @preventive_action        NVARCHAR(MAX) = NULL,
    -- Migration 323: these three are now the direct, independent
    -- decisions -- "Generate Task" / "Request Exception" / "Create
    -- Risk" on the Analysis tab bind straight to these three
    -- parameters/columns. Any combination is valid.
    @recommend_task           BIT           = 0,
    @recommend_exception      BIT           = 0,
    @recommend_risk           BIT           = 0,
    -- Migration 168, retired by 323: no longer read to drive anything.
    -- Kept only so a caller that still sends a value does not error,
    -- and so the columns remain queryable for historical rows.
    @remediation_possible     CHAR(1)       = NULL,
    @business_risk_present    CHAR(1)       = NULL,
    @analysed_by_employee_id  BIGINT        = NULL,
    @caller_display_name      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @custom_gap_id IS NULL
        THROW 55121, 'sp_custom_gap_analysis_save: custom_gap_id is required.', 1;
    IF NOT EXISTS(SELECT 1 FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id)
        THROW 55122, 'sp_custom_gap_analysis_save: custom_gap not found.', 1;

    -- Terminal-invalid guard (from 173).
    IF EXISTS (
        SELECT 1
          FROM grac_practice.custom_gap g
          JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
         WHERE g.custom_gap_id = @custom_gap_id
           AND s.is_terminal = 1 AND s.is_valid_terminal = 0)
        THROW 55142, 'sp_custom_gap_analysis_save: gap is in a terminal-invalid state (e.g., Invalid/Duplicate); analysis is not applicable.', 1;

    -- Still validated if a caller passes one, but no longer required and
    -- no longer used to compute @recommend_task/@recommend_exception/
    -- @recommend_risk (migration 323 -- see header).
    IF @remediation_possible IS NOT NULL AND @remediation_possible NOT IN ('Y','N')
        THROW 55140, 'sp_custom_gap_analysis_save: remediation_possible must be Y or N.', 1;
    IF @business_risk_present IS NOT NULL AND @business_risk_present NOT IN ('Y','N')
        THROW 55141, 'sp_custom_gap_analysis_save: business_risk_present must be Y or N.', 1;

    SET @recommend_task      = ISNULL(@recommend_task, 0);
    SET @recommend_exception = ISNULL(@recommend_exception, 0);
    SET @recommend_risk      = ISNULL(@recommend_risk, 0);

    MERGE grac_practice.custom_gap_analysis AS tgt
    USING (SELECT @custom_gap_id AS custom_gap_id) AS src
    ON tgt.custom_gap_id = src.custom_gap_id
    WHEN MATCHED THEN UPDATE SET
        detection_method_code    = @detection_method_code,
        detection_method_name    = @detection_method_name,
        severity_code            = @severity_code,
        severity_name            = @severity_name,
        business_impact_code     = @business_impact_code,
        business_impact_summary  = @business_impact_summary,
        regulatory_impact_code   = @regulatory_impact_code,
        regulatory_impact_summary= @regulatory_impact_summary,
        rca_required             = @rca_required,
        rca_method_code          = @rca_method_code,
        rca_summary              = @rca_summary,
        recommended_action_summary = @recommended_action_summary,
        preventive_action        = COALESCE(@preventive_action, tgt.preventive_action),
        recommend_task           = @recommend_task,
        recommend_exception      = @recommend_exception,
        recommend_risk           = @recommend_risk,
        -- Migration 323: no longer derived -- preserved as-is unless a
        -- caller explicitly still sends one (none do, after this
        -- migration's UI change).
        remediation_possible     = COALESCE(@remediation_possible, tgt.remediation_possible),
        business_risk_present    = COALESCE(@business_risk_present, tgt.business_risk_present),
        analysed_by_employee_id  = COALESCE(@analysed_by_employee_id, tgt.analysed_by_employee_id),
        analysed_on              = COALESCE(tgt.analysed_on, SYSUTCDATETIME()),
        updated_by               = @caller_display_name,
        updated_dt               = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (custom_gap_id, detection_method_code, detection_method_name,
         severity_code, severity_name,
         business_impact_code, business_impact_summary,
         regulatory_impact_code, regulatory_impact_summary,
         rca_required, rca_method_code, rca_summary,
         recommended_action_summary,
         preventive_action,
         recommend_task, recommend_exception, recommend_risk,
         remediation_possible, business_risk_present,
         analysed_by_employee_id, analysed_on,
         entered_by, entered_dt)
    VALUES
        (@custom_gap_id, @detection_method_code, @detection_method_name,
         @severity_code, @severity_name,
         @business_impact_code, @business_impact_summary,
         @regulatory_impact_code, @regulatory_impact_summary,
         @rca_required, @rca_method_code, @rca_summary,
         @recommended_action_summary,
         @preventive_action,
         @recommend_task, @recommend_exception, @recommend_risk,
         -- No prior row to preserve on insert; fall back to the
         -- columns' own historical default ('N').
         ISNULL(@remediation_possible, 'N'), ISNULL(@business_risk_present, 'N'),
         @analysed_by_employee_id, SYSUTCDATETIME(),
         @caller_display_name, SYSUTCDATETIME());

    -- Mirror severity onto the gap itself so existing severity-based
    -- filters keep working. Only overwrite when the caller passed one.
    IF @severity_code IS NOT NULL AND LEN(LTRIM(RTRIM(@severity_code))) > 0
        UPDATE grac_practice.custom_gap
           SET severity_code = @severity_code,
               severity_name = COALESCE(@severity_name, severity_name),
               updated_by    = @caller_display_name,
               updated_dt    = SYSUTCDATETIME()
         WHERE custom_gap_id = @custom_gap_id;

    -- Migration 323: success/failure of each best-effort trigger is
    -- captured here and returned below, instead of only PRINTed and
    -- lost -- see the TASK-CREATION INVESTIGATION note above.
    DECLARE @task_created      BIT = 0, @task_error      NVARCHAR(4000) = NULL;
    DECLARE @exception_created BIT = 0, @exception_error NVARCHAR(4000) = NULL;
    DECLARE @risk_created      BIT = 0, @risk_error      NVARCHAR(4000) = NULL;

    -- ============ Auto-trigger: Task (recommend_task = 1) =============
    -- Independent of the other two. Best-effort; analysis save stays
    -- durable even if task creation fails (retry by re-saving, or by
    -- re-ticking Generate Task and saving again -- sp_custom_gap_task_
    -- create is idempotent per gap).
    IF @recommend_task = 1
    BEGIN
        BEGIN TRY
            EXEC grac_practice.sp_custom_gap_task_create
                @custom_gap_id           = @custom_gap_id,
                @assigned_to_employee_id = @analysed_by_employee_id,
                @caller_display_name     = @caller_display_name;
            SET @task_created = 1;
        END TRY
        BEGIN CATCH
            SET @task_error = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_custom_gap_analysis_save: task auto-create warning: ', @task_error);
        END CATCH
    END

    -- ============ Auto-trigger: Exception request ======================
    -- Independent of the other two (previously only fired when
    -- remediation_possible = 'N', i.e. mutually exclusive with Task).
    IF @recommend_exception = 1
    BEGIN
        BEGIN TRY
            EXEC grac_practice.sp_exception_request_create
                @custom_gap_id            = @custom_gap_id,
                @request_title            = NULL,
                @request_reason           = @recommended_action_summary,
                @requested_by_employee_id = @analysed_by_employee_id,
                @caller_display_name      = @caller_display_name;
            SET @exception_created = 1;
        END TRY
        BEGIN CATCH
            SET @exception_error = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_custom_gap_analysis_save: exception auto-create warning: ', @exception_error);
        END CATCH
    END

    -- ============ Auto-trigger: Risk candidate =========================
    -- Independent of the other two (previously its own separate Yes/No,
    -- unchanged in spirit -- just no longer named business_risk_present).
    IF @recommend_risk = 1
    BEGIN
        BEGIN TRY
            EXEC grac_practice.sp_risk_candidate_create
                @custom_gap_id            = @custom_gap_id,
                @candidate_title          = NULL,
                @candidate_summary        = @recommended_action_summary,
                @severity_code            = @severity_code,
                @severity_name            = @severity_name,
                @impact_summary           = @business_impact_summary,
                @likelihood_summary       = @regulatory_impact_summary,
                @requested_by_employee_id = @analysed_by_employee_id,
                @caller_display_name      = @caller_display_name;
            SET @risk_created = 1;
        END TRY
        BEGIN CATCH
            SET @risk_error = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_custom_gap_analysis_save: risk auto-create warning: ', @risk_error);
        END CATCH
    END

    -- ============ Auto-transition to Delegated ========================
    -- Unchanged from 252/174. After downstream artefacts (if any) are
    -- set up, park the gap in Delegated so the Gap Centre stops
    -- surfacing it as active work. Only transitions from
    -- New/Validation/Analysis; skips if already Delegated (idempotent
    -- re-save) or in any other state.
    BEGIN TRY
        DECLARE @current_state_code NVARCHAR(60);
        SELECT @current_state_code = s.state_code
          FROM grac_practice.custom_gap g
          JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
         WHERE g.custom_gap_id = @custom_gap_id;

        IF @current_state_code IN (N'New', N'Validation', N'Analysis')
        BEGIN
            EXEC grac_practice.sp_custom_gap_lifecycle_transition
                @custom_gap_id       = @custom_gap_id,
                @action_code         = N'Delegate',
                @remark              = N'Auto-delegated after analysis save.',
                @caller_employee_id  = @analysed_by_employee_id,
                @caller_display_name = @caller_display_name;
        END
    END TRY
    BEGIN CATCH
        DECLARE @msg_del NVARCHAR(4000) = ERROR_MESSAGE();
        PRINT CONCAT(N'sp_custom_gap_analysis_save: auto-delegate warning: ', @msg_del);
    END CATCH

    -- The API opens a reader on this proc; keep the result set.
    SELECT @custom_gap_id AS CustomGapId;

    -- Migration 323: second result set -- per-artefact outcome, so a
    -- caller that cares (the Web API does, from now on) can tell a
    -- silently-failed trigger from one that was simply never requested.
    SELECT
        @task_created      AS TaskCreated,      @task_error      AS TaskError,
        @exception_created AS ExceptionCreated, @exception_error AS ExceptionError,
        @risk_created      AS RiskCreated,      @risk_error      AS RiskError;
END
GO
PRINT '323: sp_custom_gap_analysis_save -- three independent decisions, branching removed, outcomes surfaced.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 323 verification ===';

DECLARE @save NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P'));
DECLARE @task NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_task_create','P'));

SELECT '323-a save no longer derives remediation_possible from recommend_task' AS Check_,
       CASE WHEN @save NOT LIKE '%CASE WHEN @recommend_task = 1      THEN ''Y''%' THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '323-b save no longer derives recommend_task from remediation_possible',
       CASE WHEN @save NOT LIKE '%CASE WHEN @remediation_possible = ''Y'' THEN 1%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '323-c task trigger keyed on recommend_task directly',
       CASE WHEN @save LIKE '%IF @recommend_task = 1%' AND @save LIKE '%sp_custom_gap_task_create%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '323-d exception trigger keyed on recommend_exception directly',
       CASE WHEN @save LIKE '%IF @recommend_exception = 1%' AND @save LIKE '%sp_exception_request_create%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '323-e risk trigger keyed on recommend_risk directly',
       CASE WHEN @save LIKE '%IF @recommend_risk = 1%' AND @save LIKE '%sp_risk_candidate_create%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '323-f save still guards terminal-invalid (173 kept)',
       CASE WHEN @save LIKE '%55142%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '323-g save still auto-delegates (174 kept)',
       CASE WHEN @save LIKE '%Auto-delegated after analysis save%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '323-h save returns the new TaskCreated/TaskError result set',
       CASE WHEN @save LIKE '%AS TaskCreated%' AND @save LIKE '%AS TaskError%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '323-i save still returns CustomGapId result set',
       CASE WHEN @save LIKE '%AS CustomGapId%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '323-j task_create still opens a Task directly (sp_task_open, no candidate)',
       CASE WHEN @task LIKE '%sp_task_open%' AND @task NOT LIKE '%sp_task_candidate_create%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '323-k save declares all 21 parameters (unchanged count from 252)',
       CASE WHEN (SELECT COUNT(*) FROM sys.parameters
                   WHERE object_id = OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P')) = 21
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '323 complete. Generate Task / Request Exception / Create Risk now save and trigger independently;';
PRINT 'a failed auto-create is now visible in the second result set instead of only a server-side PRINT.';
GO

SET NOEXEC OFF;
GO
