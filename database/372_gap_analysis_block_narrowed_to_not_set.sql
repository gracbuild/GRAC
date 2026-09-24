-- =====================================================================
-- 372 Gap Analysis: narrow the obligation-block to "Not Set" only
--
-- REQUEST
-- -------
-- Sir's follow-up on 367: "Not set mathram anu aa block nu
-- pariganikendathu. implemented/note implemented/partially implemeted
-- mark cheythal pinne ee message kanikenda avasyam illa. Onnum mark
-- cheyyatha enthenkilum undenkil mathre kanikendu" -- only "Not Set"
-- should count toward the Gap Analysis block; once an obligation is
-- marked Implemented, Not Implemented, or Partially Implemented, the
-- "Analysis is blocked until ... obligation(s) ... unresolved" message
-- must stop counting it. It should show only when at least one
-- obligation under the Practice is still completely unmarked (Not Set
-- / Not Started).
--
-- ROOT CAUSE
-- --------------------------------------------------------------------
-- 367's guard 55144 in sp_custom_gap_analysis_save blocks analysis when
-- ANY Active practice_gap_obligation child exists under the instance's
-- practice_gap -- Not Implemented, Partially Implemented, and Not
-- Started (Not Set) all count, because 367 deliberately broadened
-- practice_gap_obligation's Active set to "everything not yet
-- Implemented/N/A" (requirement #2 of 367, so the Failed Obligation(s)
-- strip shows the Practice's full unresolved picture). That same
-- broadened set is what 55144 checks, so it blocks on Not Implemented /
-- Partially Implemented too -- which is no longer wanted for the BLOCK
-- (the strip itself must keep showing them; only the block narrows).
--
-- Why this can't simply filter on practice_gap_obligation.
-- logged_status_code: that column is a SNAPSHOT, written only when a
-- child row is (re)inserted by sp_practice_gap_sync_for_instance's 3b
-- step. An obligation that transitions between two statuses that are
-- BOTH still in the broadened Active set (e.g. Not Started -> Partially
-- Implemented) does not trigger a retire+reinsert -- the same
-- practice_gap_obligation row stays Active and logged_status_code is
-- never refreshed. Filtering the 55144 guard on logged_status_code
-- alone would therefore keep blocking on a stale "Not Started" snapshot
-- even after the obligation has genuinely moved to Partially
-- Implemented. The guard instead joins fresh to
-- practice_instance_obligation / implementation_status_master for the
-- obligation's LIVE status, exactly as sp_practice_gap_sync_for_instance
-- itself already does when it builds @current.
--
-- THE FIX
-- --------------------------------------------------------------------
-- sp_custom_gap_linked_artefacts -- re-issued from 317's exact body
-- (unchanged since; 367 did not touch it). FailedObligations gets one
-- new additive column, CurrentStatusCode, via a LEFT JOIN to
-- practice_instance_obligation / implementation_status_master
-- (COALESCE'd to 'Not Started' the same way the sync proc does).
-- Task/Exception/Risk result sets, the FailedObligations column list
-- and ORDER BY (still worst LoggedStatusCode first, unchanged) are all
-- otherwise byte-identical to 317 -- the chip strip's own display
-- (status text, ordering) is explicitly OUT of scope for this change;
-- only the blocking criterion narrows.
--
-- sp_custom_gap_analysis_save -- re-issued from 367's exact body with
-- guard 55144 narrowed: instead of "any Active practice_gap_obligation
-- child exists", it now checks "any Active child whose LIVE status
-- (freshly joined, not the logged_status_code snapshot) is NULL / 'Not
-- Started'". Guard 55145 (Practice Operationalized) and every other
-- line of the proc are completely untouched.
--
-- WHAT THIS DOES NOT DO
--   * Does not change what obligations appear on the Failed
--     Obligation(s) strip, their displayed status text, or their sort
--     order -- that stays exactly as 367 left it (Not Implemented,
--     Partially Implemented, and Not Started/Not Set all still listed).
--   * Does not touch sp_practice_gap_sync_for_instance (367/356/245) --
--     which obligations are Active practice_gap_obligation children,
--     and when the gap itself opens/closes, is unchanged.
--   * Does not touch guard 55145 (Practice Operationalized) or any
--     other guard in sp_custom_gap_analysis_save.
--   * Does not touch sp_custom_gap_header / IsPracticeOperationalized
--     (325/367) -- unrelated to this change.
--
-- SCOPE
--   1. sp_custom_gap_linked_artefacts -- re-issued from 317, +
--      FailedObligations.CurrentStatusCode.
--   2. sp_custom_gap_analysis_save    -- re-issued from 367, guard
--      55144 narrowed to Not Started only.
--
-- No schema change. No data migration.
--
-- Rollback: 372_gap_analysis_block_narrowed_to_not_set_rollback.sql
-- (restores both procs to their exact pre-372 bodies: sp_custom_gap_
-- linked_artefacts to 317's, sp_custom_gap_analysis_save to 367's).
--
-- Depends on: 317 (sp_custom_gap_linked_artefacts + FailedObligations),
-- 367 (sp_custom_gap_analysis_save guards, broadened practice_gap_
-- obligation Active set), 243 (implementation_status_master / Not
-- Started vocabulary).
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (372): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_custom_gap_linked_artefacts','P') IS NULL
BEGIN PRINT 'ABORT (372): sp_custom_gap_linked_artefacts missing (run 317 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P') IS NULL
BEGIN PRINT 'ABORT (372): sp_custom_gap_analysis_save missing (run 367 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_gap_obligation','U') IS NULL
BEGIN PRINT 'ABORT (372): practice_gap_obligation missing (run 245 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NULL
BEGIN PRINT 'ABORT (372): practice_instance_obligation missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.implementation_status_master','U') IS NULL
BEGIN PRINT 'ABORT (372): implementation_status_master missing.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('372_gap_analysis_block_narrowed_to_not_set: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_custom_gap_linked_artefacts -- re-issued from 317's exact body.
--    Only change: FailedObligations gains CurrentStatusCode (a fresh,
--    live-joined status), alongside the existing snapshot
--    LoggedStatusCode. Task/Exception/Risk result sets untouched.
-- =====================================================================
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

    -- Failed Obligation(s) -- migration 317, extended by 372.
    -- LoggedStatusCode is the snapshot taken when this child row was
    -- (re)inserted (unchanged, still drives the ORDER BY below exactly
    -- as before -- the chip strip's display/order is out of scope for
    -- 372). CurrentStatusCode (372, additive) is a fresh, live-joined
    -- status, because logged_status_code does NOT get refreshed when an
    -- obligation moves between two statuses that are both still
    -- "Active" (e.g. Not Started -> Partially Implemented) without a
    -- retire+reinsert cycle in sp_practice_gap_sync_for_instance.
    -- sp_custom_gap_analysis_save's 55144 guard (372) reads
    -- CurrentStatusCode's same LEFT JOIN shape directly rather than
    -- this result set, but both use the identical live-status logic so
    -- they can never disagree about which obligations still block.
    SELECT pgo.practice_instance_obligation_id AS ObligationId,
           pgo.obligation_name                 AS ObligationName,
           pgo.obligation_type_code            AS ObligationTypeCode,
           pgo.logged_status_code              AS LoggedStatusCode,
           COALESCE(ims.status_code, N'Not Started') AS CurrentStatusCode,
           pgo.added_dt                        AS AddedDt
      FROM grac_practice.custom_gap cg
      JOIN grac_practice.practice_gap pg
           ON pg.practice_instance_id = cg.source_reference_id
      JOIN grac_practice.practice_gap_obligation pgo
           ON pgo.practice_gap_id = pg.practice_gap_id
          AND pgo.status         = N'Active'
      LEFT JOIN grac_practice.practice_instance_obligation pio
           ON pio.practice_instance_obligation_id = pgo.practice_instance_obligation_id
      LEFT JOIN grac_practice.implementation_status_master ims
           ON ims.implementation_status_id = pio.implementation_status_id
     WHERE cg.custom_gap_id          = @custom_gap_id
       AND cg.gap_source_module_code = N'Implementation'
       AND cg.source_reference_type  = N'PracticeInstance'
       AND cg.source_reference_id   IS NOT NULL
     ORDER BY CASE pgo.logged_status_code
                   WHEN N'Not Implemented'       THEN 1
                   WHEN N'Partially Implemented' THEN 2
                   ELSE 3 END,
              pgo.obligation_name;
END
GO
PRINT '372: sp_custom_gap_linked_artefacts FailedObligations now also returns CurrentStatusCode.';
GO

-- =====================================================================
-- 2. sp_custom_gap_analysis_save -- re-issued from 367's exact body.
--    Only change: guard 55144 narrowed from "any Active
--    practice_gap_obligation child" to "any Active child whose LIVE
--    status is Not Set / Not Started". Guard 55145 (Operationalized)
--    and everything else is byte-identical to 367.
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
    @preventive_action        NVARCHAR(MAX) = NULL,
    @recommend_task           BIT           = 0,
    @recommend_exception      BIT           = 0,
    @recommend_risk           BIT           = 0,
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

    -- Migration 324: terminal-VALID guard -- the missing counterpart to
    -- 173's guard above. Blocks re-analysis once the gap has already
    -- reached Delegated/"Analysed" (is_terminal = 1 AND is_valid_terminal
    -- = 1). A gap that has never been through the lifecycle yet has
    -- lifecycle_state_id = NULL, which this LEFT JOIN + IS NULL check
    -- never matches -- a first analysis is not blocked by this guard.
    IF EXISTS (
        SELECT 1
          FROM grac_practice.custom_gap g
          LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
         WHERE g.custom_gap_id = @custom_gap_id
           AND s.is_terminal = 1 AND s.is_valid_terminal = 1)
        THROW 55143, 'sp_custom_gap_analysis_save: this gap has already been analysed; re-analysis is not allowed. Open it in View mode to see the saved analysis.', 1;

    -- =================================================================
    -- Migration 367 (guard scope), narrowed by 372 (guard 55144's
    -- criterion): for a gap materialized from a Practice Instance
    -- (Implementation source), Analysis is blocked until (a) every
    -- obligation currently displayed under the gap has been assessed --
    -- i.e. none remain Not Set / Not Started -- and (b) the Practice
    -- Instance has been Operationalized. Scoped strictly to
    -- gap_source_module_code = 'Implementation' AND source_reference_
    -- type = 'PracticeInstance' -- a Custom/Assurance/Exception/Risk-
    -- sourced gap is never subject to either guard.
    -- =================================================================
    DECLARE @src_module NVARCHAR(30), @src_type NVARCHAR(60), @src_instance_id BIGINT;
    SELECT @src_module      = g.gap_source_module_code,
           @src_type        = g.source_reference_type,
           @src_instance_id = g.source_reference_id
      FROM grac_practice.custom_gap g
     WHERE g.custom_gap_id = @custom_gap_id;

    IF @src_module = N'Implementation' AND @src_type = N'PracticeInstance' AND @src_instance_id IS NOT NULL
    BEGIN
        -- (a) 372: narrowed from "any Active practice_gap_obligation
        -- child exists" to "any Active child whose LIVE status is Not
        -- Set / Not Started". Not Implemented and Partially Implemented
        -- no longer block analysis (per business-rule change) -- they
        -- remain visible, unchanged, on the Failed Obligation(s) strip
        -- (317/372's CurrentStatusCode). logged_status_code is only a
        -- snapshot taken when the child row was (re)inserted and does
        -- NOT track a later status change between two statuses that are
        -- both still Active (e.g. Not Started -> Partially Implemented)
        -- without a retire+reinsert cycle, so this guard reads a
        -- freshly-joined LIVE status instead of relying on it.
        IF EXISTS (
            SELECT 1
              FROM grac_practice.practice_gap pg
              JOIN grac_practice.practice_gap_obligation pgo
                   ON pgo.practice_gap_id = pg.practice_gap_id
                  AND pgo.status          = N'Active'
              LEFT JOIN grac_practice.practice_instance_obligation pio
                   ON pio.practice_instance_obligation_id = pgo.practice_instance_obligation_id
              LEFT JOIN grac_practice.implementation_status_master ims
                   ON ims.implementation_status_id = pio.implementation_status_id
             WHERE pg.practice_instance_id = @src_instance_id
               AND COALESCE(ims.status_code, N'Not Started') = N'Not Started')
            THROW 55144, 'sp_custom_gap_analysis_save: one or more obligations displayed under this gap have not been assessed yet (Not Set); assess them before this gap can be analysed.', 1;

        -- (b) the Practice Instance must be Operationalized. Same live
        -- dependency-resolution computation as dbo.pm_get_practice_
        -- repository / PracticeRepositoryService.QueryResolveFallbackAsync
        -- (the rule the user confirmed) -- never the dormant practice_
        -- operationalization table. Unchanged by 372.
        DECLARE @total_dep_categories INT, @resolved_dep_count INT, @is_operationalized BIT;

        SELECT @total_dep_categories = COUNT(DISTINCT d.dependency_type_id)
          FROM grac_practice.practice_instance_dependency d
         WHERE d.practice_instance_id = @src_instance_id
           AND d.status               = N'Active'
           AND d.dependency_type_id  IS NOT NULL;

        SELECT @resolved_dep_count = COUNT(*)
          FROM grac_practice.practice_dependency_resolution r
         WHERE r.practice_instance_id = @src_instance_id
           AND r.is_active            = 1;

        SET @is_operationalized = CASE
            WHEN EXISTS (
                     SELECT 1
                       FROM grac_practice.practice_instance pi
                       LEFT JOIN grac_practice.record_status_master prs ON prs.record_status_id = pi.record_status_id
                      WHERE pi.practice_instance_id = @src_instance_id
                        AND (pi.status IN (N'Inactive', N'Retired') OR prs.status_code IN (N'Inactive', N'Retired')))
                THEN 0
            WHEN ISNULL(@total_dep_categories, 0) = 0                          THEN 0
            WHEN ISNULL(@resolved_dep_count, 0) >= ISNULL(@total_dep_categories, 0) THEN 1
            ELSE 0
        END;

        IF @is_operationalized = 0
            THROW 55145, 'sp_custom_gap_analysis_save: the related Practice has not been Operationalized yet; analysis is not allowed until it is.', 1;
    END

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

    DECLARE @task_created      BIT = 0, @task_error      NVARCHAR(4000) = NULL;
    DECLARE @exception_created BIT = 0, @exception_error NVARCHAR(4000) = NULL;
    DECLARE @risk_created      BIT = 0, @risk_error      NVARCHAR(4000) = NULL;

    -- ============ Auto-trigger: Task (recommend_task = 1) =============
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
    -- 324 fix: LEFT JOIN + NULL treated as 'New' (see 324's header --
    -- the INNER JOIN this block used from 174 through 323 silently
    -- skipped the whole block for any gap with a NULL lifecycle_state_id,
    -- which is why the status never reached Analysed). Outcome captured
    -- instead of only PRINTed.
    DECLARE @current_state_code NVARCHAR(60);
    SELECT @current_state_code = s.state_code
      FROM grac_practice.custom_gap g
      LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
     WHERE g.custom_gap_id = @custom_gap_id;

    IF @current_state_code IS NULL SET @current_state_code = N'New';

    DECLARE @lifecycle_transitioned BIT = 0, @lifecycle_error NVARCHAR(4000) = NULL;
    IF @current_state_code IN (N'New', N'Validation', N'Analysis')
    BEGIN
        BEGIN TRY
            EXEC grac_practice.sp_custom_gap_lifecycle_transition
                @custom_gap_id       = @custom_gap_id,
                @action_code         = N'Delegate',
                @remark              = N'Auto-delegated after analysis save.',
                @caller_employee_id  = @analysed_by_employee_id,
                @caller_display_name = @caller_display_name;
            SET @lifecycle_transitioned = 1;
        END TRY
        BEGIN CATCH
            SET @lifecycle_error = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_custom_gap_analysis_save: auto-delegate warning: ', @lifecycle_error);
        END CATCH
    END

    -- Fresh post-transition state (whether or not the block above ran or
    -- succeeded) -- read once, after every write above, so the second
    -- result set reports what the database actually holds now.
    DECLARE @final_state_code NVARCHAR(60), @final_state_name NVARCHAR(120);
    SELECT @final_state_code = s.state_code, @final_state_name = s.state_name
      FROM grac_practice.custom_gap g
      LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
     WHERE g.custom_gap_id = @custom_gap_id;
    IF @final_state_code IS NULL SET @final_state_code = N'New';
    IF @final_state_name IS NULL SET @final_state_name = N'New';

    -- The API opens a reader on this proc; keep the result set.
    SELECT @custom_gap_id AS CustomGapId;

    SELECT
        @task_created      AS TaskCreated,      @task_error      AS TaskError,
        @exception_created AS ExceptionCreated, @exception_error AS ExceptionError,
        @risk_created      AS RiskCreated,      @risk_error      AS RiskError,
        @lifecycle_transitioned AS LifecycleTransitioned, @lifecycle_error AS LifecycleError,
        @final_state_code       AS LifecycleStateCode,    @final_state_name AS LifecycleStateName;
END
GO
PRINT '372: sp_custom_gap_analysis_save now blocks analysis only on Not Set / Not Started obligations.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 372 verification ===';

DECLARE @la   NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_linked_artefacts','P'));
DECLARE @ansv NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P'));

SELECT '372-a linked_artefacts FailedObligations now projects CurrentStatusCode' AS Check_,
       CASE WHEN @la LIKE '%COALESCE(ims.status_code, N''Not Started'') AS CurrentStatusCode%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '372-b linked_artefacts still projects LoggedStatusCode (317 regression check)',
       CASE WHEN @la LIKE '%pgo.logged_status_code              AS LoggedStatusCode%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '372-c linked_artefacts Task/Exception/Risk result sets still present (317/174 regression check)',
       CASE WHEN @la LIKE '%N''Task''%ArtefactType%' AND @la LIKE '%N''Exception''%ArtefactType%' AND @la LIKE '%N''RiskCandidate''%ArtefactType%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '372-d analysis_save guard 55144 now checks live Not Started only',
       CASE WHEN @ansv LIKE '%55144%'
             AND @ansv LIKE '%COALESCE(ims.status_code, N''Not Started'') = N''Not Started''%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '372-e analysis_save guard 55144 now LEFT JOINs the live obligation/status tables',
       CASE WHEN @ansv LIKE '%LEFT JOIN grac_practice.practice_instance_obligation pio%'
             AND @ansv LIKE '%LEFT JOIN grac_practice.implementation_status_master ims%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '372-f analysis_save still guards Operationalized (55145, unchanged by 372)',
       CASE WHEN @ansv LIKE '%55145%' AND @ansv LIKE '%@is_operationalized = 0%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '372-g analysis_save still guards terminal-invalid (55142) and re-analysis (55143)',
       CASE WHEN @ansv LIKE '%55142%' AND @ansv LIKE '%55143%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '372-h analysis_save still returns CustomGapId + Lifecycle* result set (324 regression check)',
       CASE WHEN @ansv LIKE '%AS CustomGapId%' AND @ansv LIKE '%AS LifecycleStateCode%' THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- Diagnostic: open practice_gap rows, how many Active obligations sit under';
PRINT '    each, and how many of those now still block analysis (live Not Started) ---';
SELECT pg.practice_gap_id, pi.instance_code, pi.instance_name,
       pg.gap_status,
       COUNT(*) AS ActiveObligationCount,
       SUM(CASE WHEN COALESCE(ims.status_code, N'Not Started') = N'Not Started' THEN 1 ELSE 0 END) AS StillBlockingCount,
       SUM(CASE WHEN COALESCE(ims.status_code, N'Not Started') IN (N'Not Implemented', N'Partially Implemented') THEN 1 ELSE 0 END) AS NoLongerBlockingCount
  FROM grac_practice.practice_gap pg
  JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = pg.practice_instance_id
  JOIN grac_practice.practice_gap_obligation pgo
       ON pgo.practice_gap_id = pg.practice_gap_id AND pgo.status = N'Active'
  LEFT JOIN grac_practice.practice_instance_obligation pio
       ON pio.practice_instance_obligation_id = pgo.practice_instance_obligation_id
  LEFT JOIN grac_practice.implementation_status_master ims
       ON ims.implementation_status_id = pio.implementation_status_id
 WHERE pg.gap_status = N'Open'
 GROUP BY pg.practice_gap_id, pi.instance_code, pi.instance_name, pg.gap_status
 ORDER BY pg.practice_gap_id DESC;

PRINT '';
PRINT 'A nonzero NoLongerBlockingCount above, with StillBlockingCount = 0, means that';
PRINT 'gap''s Analysis is now unblocked by this migration alone (no obligation save';
PRINT 'required) -- the guard reads live status on every call, not a cached value.';

PRINT '';
PRINT '372 complete. Gap Analysis is now blocked only while at least one obligation';
PRINT 'under the Practice is completely unmarked (Not Set / Not Started). Marking an';
PRINT 'obligation Implemented, Not Implemented, or Partially Implemented no longer';
PRINT 'blocks analysis by itself. The Failed Obligation(s) strip is unchanged -- it';
PRINT 'still lists every unresolved obligation, including Not Implemented and';
PRINT 'Partially Implemented. API/UI changes (GapLifecycleModels.CurrentStatusCode,';
PRINT 'GapLifecycleService, gap-detail.js) ship alongside this migration.';
GO

SET NOEXEC OFF;
GO
