-- =====================================================================
-- 249 custom_gap_analysis.preventive_action
--
-- The Gap Center analysis form was carrying one action textarea
-- ("Recommended Action Summary") for both the "fix this specific gap"
-- answer and the "so this class of gap does not recur" answer. Sir
-- asked for these to be separated:
--
--   * Corrective Action  -- what fixes THIS gap.  Stays on the existing
--                            custom_gap_analysis.recommended_action_summary
--                            column (only the UI label changes to
--                            "Corrective Action").
--   * Preventive Action  -- change to controls / process so this class
--                            of gap does not recur.  This is the new
--                            column added below.
--
-- The RCA Method dropdown is retired from the UI in the same pass. The
-- column is left in place so a rollback that re-adds the picker still
-- reads its stored value.
--
-- SAFE TO RE-RUN. Requires 156 (custom_gap_analysis table).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (249): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.custom_gap_analysis','U') IS NULL
BEGIN
    PRINT 'ABORT (249): custom_gap_analysis missing (run 156 first).';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Column addition
-- =====================================================================
IF COL_LENGTH('grac_practice.custom_gap_analysis','preventive_action') IS NULL
BEGIN
    ALTER TABLE grac_practice.custom_gap_analysis
        ADD preventive_action NVARCHAR(MAX) NULL;
    PRINT '249: custom_gap_analysis.preventive_action added.';
END
GO

-- =====================================================================
-- 2. sp_custom_gap_analysis_get -- add PreventiveAction to projection
--
-- Full re-emit of 157's body with the new column added. Keeping the
-- projection order stable (PreventiveAction goes immediately after
-- RecommendedActionSummary) matches how the API reader appends it.
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
        -- Migration 249: new column, separate answer to
        -- "so this class of gap does not recur".
        a.preventive_action         AS PreventiveAction,
        a.recommend_task            AS RecommendTask,
        a.recommend_exception       AS RecommendException,
        a.recommend_risk            AS RecommendRisk,
        a.analysed_by_employee_id   AS AnalysedByEmployeeId,
        a.analysed_on               AS AnalysedOn,
        a.entered_by                AS EnteredBy,
        a.entered_dt                AS EnteredDt,
        a.updated_by                AS UpdatedBy,
        a.updated_dt                AS UpdatedDt
    FROM  grac_practice.custom_gap_analysis a
    WHERE a.custom_gap_id = @custom_gap_id;
END
GO
PRINT '249: sp_custom_gap_analysis_get projects PreventiveAction.';
GO

-- =====================================================================
-- 3. sp_custom_gap_analysis_save -- accept @preventive_action
--
-- Body from 157 with one new parameter and its column plumbing on the
-- UPDATE + INSERT clauses. Nothing else on the procedure changes.
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
    -- Migration 249: optional and last so any older caller's payload
    -- still binds unchanged. NULL means "no opinion" and the MERGE
    -- COALESCE-preserves the stored value.
    @preventive_action        NVARCHAR(MAX) = NULL,
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
        preventive_action        = COALESCE(@preventive_action, tgt.preventive_action),
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
         preventive_action,
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
         @preventive_action,
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
END
GO
PRINT '249: sp_custom_gap_analysis_save accepts @preventive_action.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 249 verification ===';

SELECT '249-a preventive_action column added' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.custom_gap_analysis','preventive_action') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '249-b get proc projects PreventiveAction',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_analysis_get','P'))
                 LIKE '%PreventiveAction%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '249-c save proc accepts @preventive_action',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P'))
                 LIKE '%@preventive_action%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Regression guard: 157's Corrective (still stored on
-- recommended_action_summary) plumbing must be intact.
SELECT '249-d regression: recommended_action_summary still plumbed',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_analysis_get','P')) LIKE '%RecommendedActionSummary%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P')) LIKE '%@recommended_action_summary%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '249 complete. Preventive Action textarea is live end-to-end.';
GO

SET NOEXEC OFF;
GO
