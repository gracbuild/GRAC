-- =====================================================================
-- 162 Exception Centre procs -- ROLLBACK
-- Drops the 8 Exception Centre procs. Restores sp_custom_gap_analysis_save
-- to the 157 version (no auto-trigger).
-- =====================================================================
SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.sp_exception_request_attachment_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_exception_request_attachment_list;
GO
IF OBJECT_ID('grac_practice.sp_exception_request_attachment_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_exception_request_attachment_get;
GO
IF OBJECT_ID('grac_practice.sp_exception_request_attachment_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_exception_request_attachment_save;
GO
IF OBJECT_ID('grac_practice.sp_exception_request_reject','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_exception_request_reject;
GO
IF OBJECT_ID('grac_practice.sp_exception_request_approve','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_exception_request_approve;
GO
IF OBJECT_ID('grac_practice.sp_exception_request_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_exception_request_get;
GO
IF OBJECT_ID('grac_practice.sp_exception_request_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_exception_request_list;
GO
IF OBJECT_ID('grac_practice.sp_exception_request_create','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_exception_request_create;
GO

-- Restore sp_custom_gap_analysis_save (157's version, no auto-trigger).
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
        detection_method_code    = @detection_method_code, detection_method_name = @detection_method_name,
        severity_code = @severity_code, severity_name = @severity_name,
        business_impact_code = @business_impact_code, business_impact_summary = @business_impact_summary,
        regulatory_impact_code = @regulatory_impact_code, regulatory_impact_summary = @regulatory_impact_summary,
        rca_required = @rca_required, rca_method_code = @rca_method_code, rca_summary = @rca_summary,
        recommended_action_summary = @recommended_action_summary,
        recommend_task = @recommend_task, recommend_exception = @recommend_exception, recommend_risk = @recommend_risk,
        analysed_by_employee_id = COALESCE(@analysed_by_employee_id, tgt.analysed_by_employee_id),
        analysed_on = COALESCE(tgt.analysed_on, SYSUTCDATETIME()),
        updated_by = @caller_display_name, updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (custom_gap_id, detection_method_code, detection_method_name, severity_code, severity_name,
         business_impact_code, business_impact_summary, regulatory_impact_code, regulatory_impact_summary,
         rca_required, rca_method_code, rca_summary, recommended_action_summary,
         recommend_task, recommend_exception, recommend_risk,
         analysed_by_employee_id, analysed_on, entered_by, entered_dt)
    VALUES
        (@custom_gap_id, @detection_method_code, @detection_method_name, @severity_code, @severity_name,
         @business_impact_code, @business_impact_summary, @regulatory_impact_code, @regulatory_impact_summary,
         @rca_required, @rca_method_code, @rca_summary, @recommended_action_summary,
         @recommend_task, @recommend_exception, @recommend_risk,
         @analysed_by_employee_id, SYSUTCDATETIME(), @caller_display_name, SYSUTCDATETIME());
    IF @severity_code IS NOT NULL AND LEN(LTRIM(RTRIM(@severity_code))) > 0
        UPDATE grac_practice.custom_gap
           SET severity_code = @severity_code, severity_name = COALESCE(@severity_name, severity_name),
               updated_by = @caller_display_name, updated_dt = SYSUTCDATETIME()
         WHERE custom_gap_id = @custom_gap_id;
    SELECT @custom_gap_id AS CustomGapId;
END
GO
PRINT '162 rollback complete.';
GO
