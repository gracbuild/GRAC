-- Rollback for 168.
-- Restores sp_custom_gap_analysis_save to its 162-era signature and
-- drops the two decision columns + their check constraints.
SET NOCOUNT ON;
GO

-- Drop check constraints first.
IF EXISTS (SELECT 1 FROM sys.check_constraints
            WHERE name = 'ck_pm_custom_gap_analysis_remediation_possible')
    ALTER TABLE grac_practice.custom_gap_analysis
        DROP CONSTRAINT ck_pm_custom_gap_analysis_remediation_possible;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints
            WHERE name = 'ck_pm_custom_gap_analysis_business_risk_present')
    ALTER TABLE grac_practice.custom_gap_analysis
        DROP CONSTRAINT ck_pm_custom_gap_analysis_business_risk_present;
GO

-- Drop defaults + columns.
IF EXISTS (SELECT 1 FROM sys.default_constraints
            WHERE name = 'df_pm_custom_gap_analysis_remediation_possible')
    ALTER TABLE grac_practice.custom_gap_analysis
        DROP CONSTRAINT df_pm_custom_gap_analysis_remediation_possible;
GO
IF EXISTS (SELECT 1 FROM sys.default_constraints
            WHERE name = 'df_pm_custom_gap_analysis_business_risk_present')
    ALTER TABLE grac_practice.custom_gap_analysis
        DROP CONSTRAINT df_pm_custom_gap_analysis_business_risk_present;
GO
IF COL_LENGTH('grac_practice.custom_gap_analysis','remediation_possible') IS NOT NULL
    ALTER TABLE grac_practice.custom_gap_analysis DROP COLUMN remediation_possible;
GO
IF COL_LENGTH('grac_practice.custom_gap_analysis','business_risk_present') IS NOT NULL
    ALTER TABLE grac_practice.custom_gap_analysis DROP COLUMN business_risk_present;
GO

-- Rerun 162's version of sp_custom_gap_analysis_save (three-flag model).
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
    IF @severity_code IS NOT NULL AND LEN(LTRIM(RTRIM(@severity_code))) > 0
        UPDATE grac_practice.custom_gap
           SET severity_code = @severity_code,
               severity_name = COALESCE(@severity_name, severity_name),
               updated_by    = @caller_display_name,
               updated_dt    = SYSUTCDATETIME()
         WHERE custom_gap_id = @custom_gap_id;
    IF @recommend_exception = 1
    BEGIN
        BEGIN TRY
            EXEC grac_practice.sp_exception_request_create
                @custom_gap_id            = @custom_gap_id,
                @request_title            = NULL,
                @request_reason           = @recommended_action_summary,
                @requested_by_employee_id = @analysed_by_employee_id,
                @caller_display_name      = @caller_display_name;
        END TRY BEGIN CATCH
            DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_custom_gap_analysis_save: exception auto-create warning: ', @msg);
        END CATCH
    END
    SELECT @custom_gap_id AS CustomGapId;
END
GO

PRINT '168 rollback complete.';
GO
