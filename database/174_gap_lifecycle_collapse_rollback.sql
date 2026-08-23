-- Rollback for 174. Restores 173-body of analysis save, reactivates
-- the transitions we deactivated, and drops the Delegated state (only
-- if no gap is currently in Delegated -- else leave the state intact).
SET NOCOUNT ON;
GO

-- Reactivate the transitions.
DECLARE @active_rs INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
UPDATE grac_practice.gap_lifecycle_transition_master
   SET record_status_id = @active_rs
 WHERE action_code IN (
        N'PlanResolution', N'SendBackToValidation', N'SendBackToAnalysis',
        N'StartExecution', N'SendBackToPlanning', N'SubmitForVerification',
        N'SendBackToExecution', N'Approve', N'Reopen'
   );
GO

-- Delete Delegate transitions (three rows).
DELETE FROM grac_practice.gap_lifecycle_transition_master
 WHERE action_code = N'Delegate';
GO

-- Drop Delegated state ONLY if no gaps landed there (safety).
IF NOT EXISTS (
    SELECT 1 FROM grac_practice.custom_gap g
      JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
     WHERE s.state_code = N'Delegated')
    DELETE FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Delegated';
GO

IF OBJECT_ID('grac_practice.sp_custom_gap_linked_artefacts','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_custom_gap_linked_artefacts;
GO
IF OBJECT_ID('grac_practice.sp_custom_gap_task_create','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_custom_gap_task_create;
GO

-- Restore 173-body of sp_custom_gap_analysis_save (no task trigger, no
-- auto-delegate). Terminal-invalid guard preserved.
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
    IF EXISTS (
        SELECT 1 FROM grac_practice.custom_gap g
          JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
         WHERE g.custom_gap_id = @custom_gap_id
           AND s.is_terminal = 1 AND s.is_valid_terminal = 0)
        THROW 55142, 'sp_custom_gap_analysis_save: gap is in a terminal-invalid state.', 1;
    IF @remediation_possible IS NOT NULL AND @remediation_possible NOT IN ('Y','N')
        THROW 55140, 'sp_custom_gap_analysis_save: remediation_possible must be Y or N.', 1;
    IF @business_risk_present IS NOT NULL AND @business_risk_present NOT IN ('Y','N')
        THROW 55141, 'sp_custom_gap_analysis_save: business_risk_present must be Y or N.', 1;
    IF @remediation_possible IS NULL
        SET @remediation_possible = CASE WHEN @recommend_task = 1 THEN 'Y' WHEN @recommend_exception = 1 THEN 'N' ELSE 'N' END;
    IF @business_risk_present IS NULL
        SET @business_risk_present = CASE WHEN @recommend_risk = 1 THEN 'Y' ELSE 'N' END;
    SET @recommend_task      = CASE WHEN @remediation_possible = 'Y' THEN 1 ELSE 0 END;
    SET @recommend_exception = CASE WHEN @remediation_possible = 'N' THEN 1 ELSE 0 END;
    SET @recommend_risk      = CASE WHEN @business_risk_present = 'Y' THEN 1 ELSE 0 END;
    MERGE grac_practice.custom_gap_analysis AS tgt
    USING (SELECT @custom_gap_id AS custom_gap_id) AS src
    ON tgt.custom_gap_id = src.custom_gap_id
    WHEN MATCHED THEN UPDATE SET
        detection_method_code=@detection_method_code, detection_method_name=@detection_method_name,
        severity_code=@severity_code, severity_name=@severity_name,
        business_impact_code=@business_impact_code, business_impact_summary=@business_impact_summary,
        regulatory_impact_code=@regulatory_impact_code, regulatory_impact_summary=@regulatory_impact_summary,
        rca_required=@rca_required, rca_method_code=@rca_method_code, rca_summary=@rca_summary,
        recommended_action_summary=@recommended_action_summary,
        recommend_task=@recommend_task, recommend_exception=@recommend_exception, recommend_risk=@recommend_risk,
        remediation_possible=@remediation_possible, business_risk_present=@business_risk_present,
        analysed_by_employee_id=COALESCE(@analysed_by_employee_id, tgt.analysed_by_employee_id),
        analysed_on=COALESCE(tgt.analysed_on, SYSUTCDATETIME()),
        updated_by=@caller_display_name, updated_dt=SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (custom_gap_id, detection_method_code, detection_method_name,
         severity_code, severity_name, business_impact_code, business_impact_summary,
         regulatory_impact_code, regulatory_impact_summary, rca_required, rca_method_code, rca_summary,
         recommended_action_summary, recommend_task, recommend_exception, recommend_risk,
         remediation_possible, business_risk_present, analysed_by_employee_id, analysed_on, entered_by, entered_dt)
    VALUES
        (@custom_gap_id, @detection_method_code, @detection_method_name,
         @severity_code, @severity_name, @business_impact_code, @business_impact_summary,
         @regulatory_impact_code, @regulatory_impact_summary, @rca_required, @rca_method_code, @rca_summary,
         @recommended_action_summary, @recommend_task, @recommend_exception, @recommend_risk,
         @remediation_possible, @business_risk_present, @analysed_by_employee_id, SYSUTCDATETIME(),
         @caller_display_name, SYSUTCDATETIME());
    IF @severity_code IS NOT NULL AND LEN(LTRIM(RTRIM(@severity_code))) > 0
        UPDATE grac_practice.custom_gap
           SET severity_code = @severity_code, severity_name = COALESCE(@severity_name, severity_name),
               updated_by = @caller_display_name, updated_dt = SYSUTCDATETIME()
         WHERE custom_gap_id = @custom_gap_id;
    IF @remediation_possible = 'N'
    BEGIN
        BEGIN TRY EXEC grac_practice.sp_exception_request_create
            @custom_gap_id=@custom_gap_id, @request_title=NULL,
            @request_reason=@recommended_action_summary,
            @requested_by_employee_id=@analysed_by_employee_id,
            @caller_display_name=@caller_display_name;
        END TRY BEGIN CATCH
            DECLARE @msg_exc NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'exception auto-create warning: ', @msg_exc);
        END CATCH
    END
    IF @business_risk_present = 'Y'
    BEGIN
        BEGIN TRY EXEC grac_practice.sp_risk_candidate_create
            @custom_gap_id=@custom_gap_id, @candidate_title=NULL,
            @candidate_summary=@recommended_action_summary,
            @severity_code=@severity_code, @severity_name=@severity_name,
            @impact_summary=@business_impact_summary, @likelihood_summary=@regulatory_impact_summary,
            @requested_by_employee_id=@analysed_by_employee_id,
            @caller_display_name=@caller_display_name;
        END TRY BEGIN CATCH
            DECLARE @msg_risk NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'risk auto-create warning: ', @msg_risk);
        END CATCH
    END
    SELECT @custom_gap_id AS CustomGapId;
END
GO

PRINT '174 rollback complete.';
GO
