-- =====================================================================
-- 172 sp_custom_gap_analysis_save -- add auto-trigger for Risk Centre
--
-- WHY THIS EXISTS SEPARATE FROM 168
-- ---------------------------------
-- Migration 168 introduced the two decision fields (remediation_possible,
-- business_risk_present) and the exception auto-trigger. The risk auto-
-- trigger was intentionally deferred because risk_candidate did not yet
-- exist. Now that 169 + 170 have created the Risk Centre schema + procs,
-- we can add the second auto-trigger.
--
-- BEHAVIOUR (unchanged from 168 except for the added block):
--   remediation_possible = 'N'  -> auto-create exception_request (168)
--   business_risk_present= 'Y'  -> auto-create risk_candidate (NEW)
--
-- Both triggers are idempotent (their create procs return the existing
-- id if a record already exists for the gap) and best-effort (wrapped in
-- TRY/CATCH so a downstream failure does not lose the analysis save).
--
-- Rollback: 172_gap_analysis_risk_trigger_rollback.sql (restores 168's
--           body of sp_custom_gap_analysis_save).
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_risk_candidate_create','P') IS NULL
BEGIN
    RAISERROR('172: sp_risk_candidate_create missing. Run 170 first.', 16, 1);
    SET NOEXEC ON;
END
GO

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
    -- NEW in 172. Fires when analyst says a business risk exists.
    -- Idempotent via sp_risk_candidate_create (returns existing id if a
    -- Pending/Accepted candidate already exists for this gap). Failures
    -- are best-effort -- analysis save must stay durable.
    IF @business_risk_present = 'Y'
    BEGIN
        BEGIN TRY
            EXEC grac_practice.sp_risk_candidate_create
                @custom_gap_id            = @custom_gap_id,
                @candidate_title          = NULL,   -- proc defaults to "Risk: <gap title>"
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

    SELECT @custom_gap_id AS CustomGapId;
END
GO

PRINT '172 gap analysis risk auto-trigger ready.';
GO
