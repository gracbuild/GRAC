-- =====================================================================
-- 157 Gap Centre v1 -- lifecycle + analysis + downstream link procs
--
-- Introduces the Gap Centre v1 lifecycle engine on top of the existing
-- custom_gap surface. Every existing proc (sp_custom_gap_list / _save /
-- _start / _submit_remediation / _verify / _close_lifecycle / _reopen /
-- _merge / _history_list / _observation_* / _action_*) STAYS INTACT --
-- rolling 157 does not touch any 112-created proc.
--
-- NEW PROCEDURES
-- --------------
--   sp_custom_gap_lifecycle_transition     the config-driven engine
--   sp_custom_gap_lifecycle_states         list configured states
--   sp_custom_gap_lifecycle_actions        list allowed actions from a given state
--   sp_custom_gap_analysis_get             fetch the 1:1 analysis record
--   sp_custom_gap_analysis_save            upsert the analysis record
--   sp_custom_gap_downstream_link_add      link a Task / Exception / Risk
--   sp_custom_gap_downstream_link_cancel   soft-cancel a link
--   sp_custom_gap_downstream_link_list     list active + cancelled links for a gap
--
-- KEEPING status IN SYNC
-- ----------------------
-- The legacy custom_gap.status column is preserved. The transition
-- proc mirrors the new lifecycle_state_code onto status using this map:
--     New / Validation / Analysis / ResolutionPlanning -> Open
--     Execution / Verification                         -> InProgress
--     Closed                                           -> Closed
--     Invalid / Duplicate                              -> Cancelled
-- so every existing sp_custom_gap_list / dashboard / CSV report keeps
-- reading legal status values without a code change.
--
-- ERROR CODE RANGE: 55100-55199  (existing 55000-55099 belongs to 112).
--
-- DEPENDS ON: 054, 109, 110, 112, 156. Rollback: 157_gap_centre_v1_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.gap_lifecycle_state_master','U') IS NULL
   OR OBJECT_ID('grac_practice.gap_lifecycle_transition_master','U') IS NULL
   OR OBJECT_ID('grac_practice.custom_gap_analysis','U') IS NULL
   OR OBJECT_ID('grac_practice.custom_gap_downstream_link','U') IS NULL
BEGIN
    RAISERROR('157: run 156 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- Helper: map lifecycle_state_code -> legacy custom_gap.status value
-- Deployed as an inline function so both the transition proc and any
-- future proc can call it without duplicating the mapping.
-- =====================================================================
IF OBJECT_ID('grac_practice.fn_gap_lifecycle_to_status','FN') IS NOT NULL
    DROP FUNCTION grac_practice.fn_gap_lifecycle_to_status;
GO
CREATE FUNCTION grac_practice.fn_gap_lifecycle_to_status(@state_code NVARCHAR(60))
RETURNS NVARCHAR(30)
AS
BEGIN
    RETURN CASE @state_code
        WHEN N'New'                  THEN N'Open'
        WHEN N'Validation'           THEN N'Open'
        WHEN N'Analysis'             THEN N'Open'
        WHEN N'ResolutionPlanning'   THEN N'Open'
        WHEN N'Execution'            THEN N'InProgress'
        WHEN N'Verification'         THEN N'InProgress'
        WHEN N'Closed'               THEN N'Closed'
        WHEN N'Invalid'              THEN N'Cancelled'
        WHEN N'Duplicate'            THEN N'Cancelled'
        ELSE                              N'Open'
    END;
END
GO

-- =====================================================================
-- 1. sp_custom_gap_lifecycle_states
--    Config lookup for UI dropdowns / stepper renderers.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_lifecycle_states
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.lifecycle_state_id AS LifecycleStateId,
           s.state_code         AS StateCode,
           s.state_name         AS StateName,
           s.description        AS Description,
           s.sort_order         AS SortOrder,
           s.is_terminal        AS IsTerminal,
           s.is_valid_terminal  AS IsValidTerminal
      FROM grac_practice.gap_lifecycle_state_master s
      JOIN grac_practice.record_status_master r ON r.record_status_id = s.record_status_id
     WHERE r.status_code = N'Active'
     ORDER BY s.sort_order, s.state_name;
END
GO

-- =====================================================================
-- 2. sp_custom_gap_lifecycle_actions
--    "What can I do from state X?" -- feeds the 3-dot menu.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_lifecycle_actions
    @from_state_code NVARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;
    IF @from_state_code IS NULL OR LEN(LTRIM(RTRIM(@from_state_code))) = 0
        THROW 55100, 'sp_custom_gap_lifecycle_actions: from_state_code is required.', 1;

    SELECT t.action_code        AS ActionCode,
           t.action_name        AS ActionName,
           t.description        AS Description,
           t.remark_required    AS RemarkRequired,
           tt.state_code        AS ToStateCode,
           tt.state_name        AS ToStateName
      FROM grac_practice.gap_lifecycle_transition_master t
      JOIN grac_practice.gap_lifecycle_state_master fs ON fs.lifecycle_state_id = t.from_state_id
      JOIN grac_practice.gap_lifecycle_state_master tt ON tt.lifecycle_state_id = t.to_state_id
      JOIN grac_practice.record_status_master r ON r.record_status_id = t.record_status_id
     WHERE r.status_code = N'Active'
       AND fs.state_code = @from_state_code
     ORDER BY t.action_name;
END
GO

-- =====================================================================
-- 3. sp_custom_gap_lifecycle_transition
--
-- The engine. Validates the (from, action) is allowed against the
-- transition master, then updates:
--     custom_gap.lifecycle_state_id     -> to_state_id
--     custom_gap.status                 -> mapped legacy value
--     custom_gap.updated_by/_dt         -> audit stamps
--     custom_gap.duplicate_of_gap_id    -> when action moves to Duplicate
--     custom_gap.invalid_reason         -> when action moves to Invalid
-- and inserts a history row via the existing 112 sp_custom_gap_history_*
-- machinery (custom_gap_history table).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_lifecycle_transition
    @custom_gap_id          BIGINT,
    @action_code            NVARCHAR(60),
    @remark                 NVARCHAR(MAX) = NULL,
    @duplicate_of_gap_id    BIGINT        = NULL,   -- required when action -> Duplicate
    @invalid_reason         NVARCHAR(1000) = NULL,  -- required when action -> Invalid
    @caller_employee_id     BIGINT        = NULL,
    @caller_display_name    NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @custom_gap_id IS NULL
        THROW 55101, 'sp_custom_gap_lifecycle_transition: custom_gap_id is required.', 1;
    IF @action_code IS NULL OR LEN(LTRIM(RTRIM(@action_code))) = 0
        THROW 55102, 'sp_custom_gap_lifecycle_transition: action_code is required.', 1;

    DECLARE @current_state_id INT;
    SELECT @current_state_id = lifecycle_state_id
      FROM grac_practice.custom_gap
     WHERE custom_gap_id = @custom_gap_id;
    IF NOT EXISTS(SELECT 1 FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id)
        THROW 55103, 'sp_custom_gap_lifecycle_transition: custom_gap not found.', 1;

    -- If the gap has never been through v1 lifecycle yet, treat its
    -- current state as 'New' for transition lookup purposes.
    IF @current_state_id IS NULL
        SELECT @current_state_id = lifecycle_state_id
          FROM grac_practice.gap_lifecycle_state_master
         WHERE state_code = N'New';

    IF @current_state_id IS NULL
        THROW 55104, 'sp_custom_gap_lifecycle_transition: state master missing the New state (run 158 seed).', 1;

    -- Resolve the target state via the transition master.
    DECLARE @to_state_id INT, @to_state_code NVARCHAR(60), @remark_required BIT;
    SELECT @to_state_id     = t.to_state_id,
           @to_state_code   = tt.state_code,
           @remark_required = t.remark_required
      FROM grac_practice.gap_lifecycle_transition_master t
      JOIN grac_practice.gap_lifecycle_state_master tt ON tt.lifecycle_state_id = t.to_state_id
      JOIN grac_practice.record_status_master r ON r.record_status_id = t.record_status_id
     WHERE r.status_code = N'Active'
       AND t.from_state_id = @current_state_id
       AND t.action_code   = @action_code;

    IF @to_state_id IS NULL
        THROW 55105, 'sp_custom_gap_lifecycle_transition: action is not allowed from the current state.', 1;

    IF @remark_required = 1 AND (@remark IS NULL OR LEN(LTRIM(RTRIM(@remark))) = 0)
        THROW 55106, 'sp_custom_gap_lifecycle_transition: this action requires a remark.', 1;

    IF @to_state_code = N'Duplicate' AND @duplicate_of_gap_id IS NULL
        THROW 55107, 'sp_custom_gap_lifecycle_transition: duplicate_of_gap_id is required when marking as Duplicate.', 1;
    IF @to_state_code = N'Duplicate' AND @duplicate_of_gap_id = @custom_gap_id
        THROW 55108, 'sp_custom_gap_lifecycle_transition: a gap cannot be a duplicate of itself.', 1;
    IF @to_state_code = N'Duplicate'
       AND NOT EXISTS(SELECT 1 FROM grac_practice.custom_gap WHERE custom_gap_id = @duplicate_of_gap_id)
        THROW 55109, 'sp_custom_gap_lifecycle_transition: duplicate_of_gap_id does not exist.', 1;
    IF @to_state_code = N'Invalid' AND (@invalid_reason IS NULL OR LEN(LTRIM(RTRIM(@invalid_reason))) = 0)
        THROW 55110, 'sp_custom_gap_lifecycle_transition: invalid_reason is required when marking as Invalid.', 1;

    DECLARE @legacy_status NVARCHAR(30) = grac_practice.fn_gap_lifecycle_to_status(@to_state_code);
    DECLARE @from_state_code NVARCHAR(60) =
        (SELECT state_code FROM grac_practice.gap_lifecycle_state_master WHERE lifecycle_state_id = @current_state_id);

    -- Snapshot the org id + prior legacy status BEFORE the update so the
    -- history row records the true from/to.
    DECLARE @organization_id BIGINT, @prior_status NVARCHAR(30);
    SELECT @organization_id = organization_id,
           @prior_status    = status
      FROM grac_practice.custom_gap
     WHERE custom_gap_id = @custom_gap_id;

    BEGIN TRAN;

    UPDATE grac_practice.custom_gap
       SET lifecycle_state_id   = @to_state_id,
           status               = @legacy_status,
           duplicate_of_gap_id  = CASE WHEN @to_state_code = N'Duplicate' THEN @duplicate_of_gap_id ELSE duplicate_of_gap_id END,
           invalid_reason       = CASE WHEN @to_state_code = N'Invalid'   THEN @invalid_reason      ELSE invalid_reason END,
           updated_by           = @caller_display_name,
           updated_dt           = SYSUTCDATETIME()
     WHERE custom_gap_id = @custom_gap_id;

    -- History: schema per migration 110 --
    --   (custom_gap_id, organization_id, action_code,
    --    from_status_code, to_status_code, reason_text,
    --    actor_display_name, entered_by, entered_dt).
    -- We store the lifecycle state transition in from_status_code /
    -- to_status_code (state names not legacy status) so the audit log
    -- reads in Gap Centre v1 vocabulary.
    IF OBJECT_ID('grac_practice.custom_gap_history','U') IS NOT NULL
    BEGIN
        INSERT INTO grac_practice.custom_gap_history
            (custom_gap_id, organization_id, action_code,
             from_status_code, to_status_code, reason_text,
             actor_display_name, entered_by, entered_dt)
        VALUES
            (@custom_gap_id, @organization_id, @action_code,
             @from_state_code, @to_state_code, @remark,
             @caller_display_name, @caller_display_name, SYSUTCDATETIME());
    END

    COMMIT;

    SELECT @custom_gap_id  AS CustomGapId,
           @from_state_code AS FromStateCode,
           @to_state_code   AS ToStateCode,
           @legacy_status   AS StatusCode;
END
GO

-- =====================================================================
-- 4. sp_custom_gap_analysis_get
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_analysis_get
    @custom_gap_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @custom_gap_id IS NULL
        THROW 55120, 'sp_custom_gap_analysis_get: custom_gap_id is required.', 1;

    SELECT
        a.custom_gap_id             AS CustomGapId,
        a.detection_method_code     AS DetectionMethodCode,
        a.detection_method_name     AS DetectionMethodName,
        a.severity_code             AS SeverityCode,
        a.severity_name             AS SeverityName,
        a.business_impact_code      AS BusinessImpactCode,
        a.business_impact_summary   AS BusinessImpactSummary,
        a.regulatory_impact_code    AS RegulatoryImpactCode,
        a.regulatory_impact_summary AS RegulatoryImpactSummary,
        a.rca_required              AS RcaRequired,
        a.rca_method_code           AS RcaMethodCode,
        a.rca_summary               AS RcaSummary,
        a.recommended_action_summary AS RecommendedActionSummary,
        a.recommend_task            AS RecommendTask,
        a.recommend_exception       AS RecommendException,
        a.recommend_risk            AS RecommendRisk,
        a.analysed_by_employee_id   AS AnalysedByEmployeeId,
        a.analysed_on               AS AnalysedOn,
        a.entered_by                AS EnteredBy,
        a.entered_dt                AS EnteredDt,
        a.updated_by                AS UpdatedBy,
        a.updated_dt                AS UpdatedDt
      FROM grac_practice.custom_gap_analysis a
     WHERE a.custom_gap_id = @custom_gap_id;
END
GO

-- =====================================================================
-- 5. sp_custom_gap_analysis_save
--    Idempotent upsert. Does NOT change lifecycle_state_id -- callers
--    that want to advance the gap to the Analysis state should invoke
--    sp_custom_gap_lifecycle_transition explicitly (action 'Analyse').
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
    @recommend_task           BIT           = 0,
    @recommend_exception      BIT           = 0,
    @recommend_risk           BIT           = 0,
    @analysed_by_employee_id  BIGINT        = NULL,
    @caller_display_name      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @custom_gap_id IS NULL
        THROW 55121, 'sp_custom_gap_analysis_save: custom_gap_id is required.', 1;
    IF NOT EXISTS(SELECT 1 FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id)
        THROW 55122, 'sp_custom_gap_analysis_save: custom_gap not found.', 1;

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

    SELECT @custom_gap_id AS CustomGapId;
END
GO

-- =====================================================================
-- 6. sp_custom_gap_downstream_link_add
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_downstream_link_add
    @custom_gap_id           BIGINT,
    @artefact_type_code      NVARCHAR(30),         -- Task | Exception | RiskCandidate
    @artefact_id             BIGINT        = NULL,
    @external_ref            NVARCHAR(200) = NULL,
    @title                   NVARCHAR(300) = NULL,
    @initiated_by_employee_id BIGINT       = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @custom_gap_id IS NULL
        THROW 55130, 'sp_custom_gap_downstream_link_add: custom_gap_id is required.', 1;
    IF @artefact_type_code IS NULL OR @artefact_type_code NOT IN (N'Task', N'Exception', N'RiskCandidate')
        THROW 55131, 'sp_custom_gap_downstream_link_add: artefact_type_code must be Task, Exception or RiskCandidate.', 1;
    IF @artefact_id IS NULL AND (@external_ref IS NULL OR LEN(LTRIM(RTRIM(@external_ref))) = 0)
        THROW 55132, 'sp_custom_gap_downstream_link_add: provide artefact_id or external_ref.', 1;
    IF NOT EXISTS(SELECT 1 FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id)
        THROW 55133, 'sp_custom_gap_downstream_link_add: custom_gap not found.', 1;

    INSERT INTO grac_practice.custom_gap_downstream_link
        (custom_gap_id, artefact_type_code, artefact_id, external_ref, title,
         link_status_code, initiated_by_employee_id, initiated_dt,
         entered_by, entered_dt)
    VALUES
        (@custom_gap_id, @artefact_type_code, @artefact_id, @external_ref, @title,
         N'Active', @initiated_by_employee_id, SYSUTCDATETIME(),
         @caller_display_name, SYSUTCDATETIME());

    SELECT SCOPE_IDENTITY() AS LinkId;
END
GO

-- =====================================================================
-- 7. sp_custom_gap_downstream_link_cancel
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_downstream_link_cancel
    @link_id                BIGINT,
    @reason                 NVARCHAR(1000),
    @cancelled_by_employee_id BIGINT      = NULL,
    @caller_display_name    NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @link_id IS NULL
        THROW 55140, 'sp_custom_gap_downstream_link_cancel: link_id is required.', 1;
    IF @reason IS NULL OR LEN(LTRIM(RTRIM(@reason))) = 0
        THROW 55141, 'sp_custom_gap_downstream_link_cancel: reason is required.', 1;

    UPDATE grac_practice.custom_gap_downstream_link
       SET link_status_code       = N'Cancelled',
           cancelled_by_employee_id = @cancelled_by_employee_id,
           cancelled_dt           = SYSUTCDATETIME(),
           cancellation_reason    = @reason
     WHERE link_id = @link_id
       AND link_status_code = N'Active';

    IF @@ROWCOUNT = 0
        THROW 55142, 'sp_custom_gap_downstream_link_cancel: link not found or already cancelled.', 1;

    SELECT @link_id AS LinkId;
END
GO

-- =====================================================================
-- 8. sp_custom_gap_downstream_link_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_downstream_link_list
    @custom_gap_id BIGINT,
    @include_cancelled BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @custom_gap_id IS NULL
        THROW 55150, 'sp_custom_gap_downstream_link_list: custom_gap_id is required.', 1;

    SELECT
        l.link_id               AS LinkId,
        l.custom_gap_id         AS CustomGapId,
        l.artefact_type_code    AS ArtefactTypeCode,
        l.artefact_id           AS ArtefactId,
        l.external_ref          AS ExternalRef,
        l.title                 AS Title,
        l.link_status_code      AS LinkStatusCode,
        l.initiated_by_employee_id AS InitiatedByEmployeeId,
        l.initiated_dt          AS InitiatedOn,
        l.cancelled_by_employee_id AS CancelledByEmployeeId,
        l.cancelled_dt          AS CancelledOn,
        l.cancellation_reason   AS CancellationReason
      FROM grac_practice.custom_gap_downstream_link l
     WHERE l.custom_gap_id = @custom_gap_id
       AND (@include_cancelled = 1 OR l.link_status_code = N'Active')
     ORDER BY l.initiated_dt DESC;
END
GO

-- End 157 =============================================================
