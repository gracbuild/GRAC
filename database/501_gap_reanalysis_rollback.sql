-- =====================================================================
-- 501_gap_reanalysis_rollback.sql
--
-- Undoes 501_gap_reanalysis.sql:
--   * sp_custom_gap_analysis_save is restored to 372's exact body
--     (no @reanalyse parameter, the 324 guard unconditional again).
--   * the three re-analysis columns are dropped from
--     custom_gap_analysis.
--
-- After this, an analysed gap is locked again as it was before 501 and
-- the Gap Analysis page's Re-analyse option fails with 55143 (the Api
-- binds @reanalyse only when the procedure declares it, so the page
-- degrades rather than erroring on every save).
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- 372's body, byte for byte.
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
PRINT '501 rollback: sp_custom_gap_analysis_save restored to 372.';
GO

-- Dropped after the procedure stops reading them.
IF COL_LENGTH('grac_practice.custom_gap_analysis','last_reanalysed_by_employee_id') IS NOT NULL
BEGIN
    ALTER TABLE grac_practice.custom_gap_analysis DROP COLUMN last_reanalysed_by_employee_id;
    PRINT '501 rollback: last_reanalysed_by_employee_id dropped.';
END
GO
IF COL_LENGTH('grac_practice.custom_gap_analysis','last_reanalysed_on') IS NOT NULL
BEGIN
    ALTER TABLE grac_practice.custom_gap_analysis DROP COLUMN last_reanalysed_on;
    PRINT '501 rollback: last_reanalysed_on dropped.';
END
GO
IF COL_LENGTH('grac_practice.custom_gap_analysis','reanalysis_count') IS NOT NULL
BEGIN
    IF OBJECT_ID('grac_practice.df_pm_custom_gap_analysis_reanalysis_count','D') IS NOT NULL
        ALTER TABLE grac_practice.custom_gap_analysis
            DROP CONSTRAINT df_pm_custom_gap_analysis_reanalysis_count;
    ALTER TABLE grac_practice.custom_gap_analysis DROP COLUMN reanalysis_count;
    PRINT '501 rollback: reanalysis_count dropped.';
END
GO

PRINT '--- 501 rollback verification ---';
SELECT CASE WHEN COL_LENGTH('grac_practice.custom_gap_analysis','reanalysis_count') IS NULL
            THEN 'gone' ELSE 'STILL THERE' END AS reanalysis_count,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_custom_gap_analysis_save')
                            AND name = '@reanalyse')
            THEN 'STILL THERE' ELSE 'gone' END AS reanalyse_parameter;
PRINT '501 rollback: done.';
GO
