-- =====================================================================
-- 174 Gap lifecycle collapse -- 9 states -> 4 states + Task auto-trigger
--
-- SIR'S SIMPLIFICATION (approved)
-- -------------------------------
-- Once analysis auto-creates the downstream trilogy (Task + Exception +
-- Risk), the intermediate governance states are vestigial. Real work
-- happens in Task/Exception/Risk Centres; Gap Centre only needs to
-- capture "raised, validated, analysed, delegated" states plus the two
-- negatives (Invalid, Duplicate).
--
-- NEW LIFECYCLE (5 states active + 4 dormant for historical rows):
--   Active states:
--     New          -> just raised
--     Validation   -> reviewer looking, not yet decided
--     Analysis     -> analyst is working the analysis form
--     Delegated    -> analysis saved, downstream artefacts owned by
--                     Task Centre / Exception Centre / Risk Centre
--                     (terminal, is_valid_terminal=1)
--     Invalid      -> terminal-invalid (unchanged)
--     Duplicate    -> terminal-invalid (unchanged)
--
--   Dormant states (kept for historical gaps stuck there; no new
--   transitions lead here):
--     ResolutionPlanning, Execution, Verification, Closed
--
-- TASK AUTO-TRIGGER
-- -----------------
-- Fills the third leg of the trilogy: when analyst answers
--   remediation_possible = 'Y'
-- the save proc creates a practice_task via sp_task_open
-- (task_type='Rectification', subject_entity_type='CustomGap').
-- Idempotent per gap.
--
-- CHANGES
-- -------
--   1. Add 'Delegated' state.
--   2. Add 'Delegate' action from New/Validation/Analysis -> Delegated.
--   3. Deactivate obsolete transitions (record_status_id -> Inactive).
--   4. New sp_custom_gap_task_create (idempotent).
--   5. Extend sp_custom_gap_analysis_save with task auto-trigger +
--      auto-transition to Delegated after all triggers succeed.
--
-- ROLLBACK: 174_gap_lifecycle_collapse_rollback.sql
-- ERROR RANGE: 55500-55519
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @active_rs   INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
DECLARE @inactive_rs INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Inactive');
IF @active_rs IS NULL OR @inactive_rs IS NULL
BEGIN
    RAISERROR('174: record_status_master.Active/Inactive missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. New state: Delegated (terminal, VALID terminal)
-- ---------------------------------------------------------------------
DECLARE @active_rs INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
IF NOT EXISTS(SELECT 1 FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Delegated')
    INSERT INTO grac_practice.gap_lifecycle_state_master
        (state_code, state_name, description, sort_order, is_terminal, is_valid_terminal,
         status, record_status_id, entered_by)
    VALUES
        (N'Delegated', N'Delegated',
         N'Analysis saved; downstream tasks / exceptions / risk candidates own remediation from here. Terminal from Gap Centre.',
         35, 1, 1, N'Active', @active_rs, N'seed-174');
GO

-- ---------------------------------------------------------------------
-- 2. New transitions: Delegate (from New / Validation / Analysis)
-- ---------------------------------------------------------------------
DECLARE @active_rs  INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
DECLARE @s_new      INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'New');
DECLARE @s_val      INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Validation');
DECLARE @s_ana      INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Analysis');
DECLARE @s_del      INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Delegated');

;WITH new_trans(from_state_id, to_state_id, action_code, action_name, description, remark_required) AS (
    SELECT * FROM (VALUES
        (@s_new, @s_del, N'Delegate', N'Delegate', N'Analysis saved -- downstream artefacts own remediation.', 0),
        (@s_val, @s_del, N'Delegate', N'Delegate', N'Analysis saved -- downstream artefacts own remediation.', 0),
        (@s_ana, @s_del, N'Delegate', N'Delegate', N'Analysis saved -- downstream artefacts own remediation.', 0)
    ) v(from_state_id, to_state_id, action_code, action_name, description, remark_required)
)
INSERT INTO grac_practice.gap_lifecycle_transition_master
    (from_state_id, to_state_id, action_code, action_name, description, remark_required,
     record_status_id, entered_by, entered_dt)
SELECT n.from_state_id, n.to_state_id, n.action_code, n.action_name, n.description, n.remark_required,
       @active_rs, N'seed-174', SYSUTCDATETIME()
  FROM new_trans n
 WHERE NOT EXISTS (
    SELECT 1 FROM grac_practice.gap_lifecycle_transition_master t
     WHERE t.from_state_id = n.from_state_id
       AND t.action_code   = n.action_code);
GO

-- ---------------------------------------------------------------------
-- 3. Deactivate obsolete transitions -- these lifecycle states are now
--    dormant. Kept in the master (historical gaps stuck there stay
--    resolvable) but hidden from the "Available Actions" UI.
--
--    Actions listed in sp_custom_gap_lifecycle_actions filter on
--    record_status='Active', so flipping the transition row to Inactive
--    removes it from the UI without breaking existing gap rows.
-- ---------------------------------------------------------------------
DECLARE @inactive_rs INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Inactive');

-- gap_lifecycle_transition_master has only entered_by / entered_dt --
-- no updated_by / updated_dt columns per 156 schema. Just flip status.
UPDATE grac_practice.gap_lifecycle_transition_master
   SET record_status_id = @inactive_rs
 WHERE action_code IN (
        N'PlanResolution',
        N'SendBackToValidation',
        N'SendBackToAnalysis',
        N'StartExecution',
        N'SendBackToPlanning',
        N'SubmitForVerification',
        N'SendBackToExecution',
        N'Approve',
        N'Reopen'
   );
GO

-- ---------------------------------------------------------------------
-- 4. sp_custom_gap_task_create -- idempotent task auto-trigger.
--    Same shape as sp_exception_request_create / sp_risk_candidate_create.
-- ---------------------------------------------------------------------
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
        SELECT @existing_id AS TaskId, CAST(0 AS BIT) AS Created;
        RETURN;
    END

    DECLARE @org_id BIGINT, @gap_title NVARCHAR(250), @summary NVARCHAR(MAX);
    SELECT @org_id = organization_id, @gap_title = title
      FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id;
    IF @org_id IS NULL
        THROW 55501, 'sp_custom_gap_task_create: custom_gap not found.', 1;

    SELECT @summary = recommended_action_summary
      FROM grac_practice.custom_gap_analysis WHERE custom_gap_id = @custom_gap_id;

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
            @priority                = N'Medium',
            @origin_code             = N'Custom',
            @assigned_to_employee_id = @assigned_to_employee_id,
            @actor_employee_id       = @assigned_to_employee_id,
            @task_id                 = @task_id OUTPUT;
    END TRY
    BEGIN CATCH
        DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
        THROW 55502, @msg, 1;
    END CATCH

    SELECT @task_id AS TaskId, CAST(1 AS BIT) AS Created;
END
GO

-- ---------------------------------------------------------------------
-- 5. REWRITE sp_custom_gap_analysis_save
--    - Adds task auto-trigger when remediation_possible='Y'
--    - After all downstream triggers (Exception / Risk / Task) succeed,
--      auto-transitions the gap to 'Delegated' (only from New/Validation/
--      Analysis; if already Delegated, stay put; if Invalid/Duplicate,
--      the guard from 173 rejected earlier).
--    - Preserves the terminal-invalid guard from 173.
-- ---------------------------------------------------------------------
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
    @recommend_task           BIT           = NULL,
    @recommend_exception      BIT           = NULL,
    @recommend_risk           BIT           = NULL,
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

    IF @remediation_possible IS NOT NULL AND @remediation_possible NOT IN ('Y','N')
        THROW 55140, 'sp_custom_gap_analysis_save: remediation_possible must be Y or N.', 1;
    IF @business_risk_present IS NOT NULL AND @business_risk_present NOT IN ('Y','N')
        THROW 55141, 'sp_custom_gap_analysis_save: business_risk_present must be Y or N.', 1;

    IF @remediation_possible IS NULL
        SET @remediation_possible =
            CASE WHEN @recommend_task = 1      THEN 'Y'
                 WHEN @recommend_exception = 1 THEN 'N'
                 ELSE 'N' END;
    IF @business_risk_present IS NULL
        SET @business_risk_present =
            CASE WHEN @recommend_risk = 1 THEN 'Y' ELSE 'N' END;

    SET @recommend_task      = CASE WHEN @remediation_possible = 'Y' THEN 1 ELSE 0 END;
    SET @recommend_exception = CASE WHEN @remediation_possible = 'N' THEN 1 ELSE 0 END;
    SET @recommend_risk      = CASE WHEN @business_risk_present = 'Y' THEN 1 ELSE 0 END;

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
        recommend_task           = @recommend_task,
        recommend_exception      = @recommend_exception,
        recommend_risk           = @recommend_risk,
        remediation_possible     = @remediation_possible,
        business_risk_present    = @business_risk_present,
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
         @recommend_task, @recommend_exception, @recommend_risk,
         @remediation_possible, @business_risk_present,
         @analysed_by_employee_id, SYSUTCDATETIME(),
         @caller_display_name, SYSUTCDATETIME());

    IF @severity_code IS NOT NULL AND LEN(LTRIM(RTRIM(@severity_code))) > 0
        UPDATE grac_practice.custom_gap
           SET severity_code = @severity_code,
               severity_name = COALESCE(@severity_name, severity_name),
               updated_by    = @caller_display_name,
               updated_dt    = SYSUTCDATETIME()
         WHERE custom_gap_id = @custom_gap_id;

    -- ============ Auto-trigger: Task (remediation_possible='Y') =======
    -- Full trilogy now. Best-effort; analysis save stays durable even
    -- if task creation fails (retry by re-saving).
    IF @remediation_possible = 'Y'
    BEGIN
        BEGIN TRY
            EXEC grac_practice.sp_custom_gap_task_create
                @custom_gap_id           = @custom_gap_id,
                @assigned_to_employee_id = @analysed_by_employee_id,
                @caller_display_name     = @caller_display_name;
        END TRY
        BEGIN CATCH
            DECLARE @msg_task NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_custom_gap_analysis_save: task auto-create warning: ', @msg_task);
        END CATCH
    END

    -- ============ Auto-trigger: Exception request =====================
    IF @remediation_possible = 'N'
    BEGIN
        BEGIN TRY
            EXEC grac_practice.sp_exception_request_create
                @custom_gap_id            = @custom_gap_id,
                @request_title            = NULL,
                @request_reason           = @recommended_action_summary,
                @requested_by_employee_id = @analysed_by_employee_id,
                @caller_display_name      = @caller_display_name;
        END TRY
        BEGIN CATCH
            DECLARE @msg_exc NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_custom_gap_analysis_save: exception auto-create warning: ', @msg_exc);
        END CATCH
    END

    -- ============ Auto-trigger: Risk candidate ========================
    IF @business_risk_present = 'Y'
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
        END TRY
        BEGIN CATCH
            DECLARE @msg_risk NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_custom_gap_analysis_save: risk auto-create warning: ', @msg_risk);
        END CATCH
    END

    -- ============ Auto-transition to Delegated ========================
    -- After downstream artefacts (if any) are set up, park the gap in
    -- Delegated so the Gap Centre stops surfacing it as active work.
    -- Only transitions from New/Validation/Analysis; skips if already
    -- Delegated (idempotent re-save) or in any other state.
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

    SELECT @custom_gap_id AS CustomGapId;
END
GO

-- ---------------------------------------------------------------------
-- 6. sp_custom_gap_linked_artefacts -- one-shot read for the UI's
--    "Linked artefacts" chip strip on the Analysis tab. Returns the
--    active Task / Exception / Risk artefacts owned by the gap (a
--    single row per artefact type; blank if none).
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_linked_artefacts
    @custom_gap_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @custom_gap_id IS NULL
        THROW 55510, 'sp_custom_gap_linked_artefacts: custom_gap_id is required.', 1;

    -- Task
    SELECT TOP 1
        N'Task'                     AS ArtefactType,
        t.task_id                   AS ArtefactId,
        t.subject_title             AS Title,
        s.status_code               AS StatusCode
      FROM grac_practice.practice_task t
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
     WHERE t.subject_entity_type = N'CustomGap'
       AND t.subject_entity_id   = @custom_gap_id
     ORDER BY t.task_id DESC;

    -- Exception
    SELECT TOP 1
        N'Exception'                AS ArtefactType,
        e.exception_request_id      AS ArtefactId,
        e.request_title             AS Title,
        e.status_code               AS StatusCode
      FROM grac_practice.exception_request e
     WHERE e.custom_gap_id = @custom_gap_id
     ORDER BY e.exception_request_id DESC;

    -- Risk
    SELECT TOP 1
        N'RiskCandidate'            AS ArtefactType,
        r.risk_candidate_id         AS ArtefactId,
        r.candidate_title           AS Title,
        r.status_code               AS StatusCode
      FROM grac_practice.risk_candidate r
     WHERE r.custom_gap_id = @custom_gap_id
     ORDER BY r.risk_candidate_id DESC;
END
GO

PRINT '174 gap lifecycle collapse ready.';
GO
