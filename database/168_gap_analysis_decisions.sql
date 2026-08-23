-- =====================================================================
-- 168 Gap analysis decision rework
--
-- Sir's re-modelled analysis flow:
--   Old (156-162): three optional booleans -- recommend_task /
--                  recommend_exception / recommend_risk. Overlapping,
--                  ambiguous, and easy to leave blank.
--   New:           two MANDATORY Yes/No decisions --
--                    remediation_possible  ('Y'/'N')
--                    business_risk_present ('Y'/'N')
--
-- Downstream routing (matches sir's spec):
--     remediation_possible = 'Y' -> Task Centre (recommend_task=1)
--     remediation_possible = 'N' -> Exception Centre (recommend_exception=1)
--     business_risk_present= 'Y' -> Risk Centre (recommend_risk=1)
--     business_risk_present= 'N' -> nothing
--
-- We KEEP the three legacy recommend_* columns to avoid breaking any
-- existing consumer (Gap Centre downstream_link seeders, reports, etc.),
-- and populate them from the decisions inside sp_custom_gap_analysis_save
-- so both new and old code stay coherent.
--
-- Rollback: 168_gap_analysis_decisions_rollback.sql
--
-- Error range: 55140-55149 (decision validation)
-- =====================================================================
SET NOCOUNT ON;
GO

-- ---------------------------------------------------------------------
-- 1. Add the two decision columns to custom_gap_analysis (idempotent).
--    NOT NULL with default 'N' so existing rows adopt the safe "no
--    remediation / no risk" position; new rows must explicitly answer.
-- ---------------------------------------------------------------------
IF COL_LENGTH('grac_practice.custom_gap_analysis','remediation_possible') IS NULL
BEGIN
    ALTER TABLE grac_practice.custom_gap_analysis
        ADD remediation_possible CHAR(1) NOT NULL
            CONSTRAINT df_pm_custom_gap_analysis_remediation_possible DEFAULT 'N',
            business_risk_present CHAR(1) NOT NULL
            CONSTRAINT df_pm_custom_gap_analysis_business_risk_present DEFAULT 'N';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_custom_gap_analysis_remediation_possible')
    ALTER TABLE grac_practice.custom_gap_analysis
        ADD CONSTRAINT ck_pm_custom_gap_analysis_remediation_possible
            CHECK (remediation_possible IN ('Y','N'));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_custom_gap_analysis_business_risk_present')
    ALTER TABLE grac_practice.custom_gap_analysis
        ADD CONSTRAINT ck_pm_custom_gap_analysis_business_risk_present
            CHECK (business_risk_present IN ('Y','N'));
GO

-- ---------------------------------------------------------------------
-- 2. Backfill from any pre-existing legacy flags so historic rows carry
--    a sensible decision value (helps analytics + list filters).
--      recommend_task=1        -> remediation_possible='Y'
--      recommend_exception=1   -> remediation_possible='N'
--      recommend_risk=1        -> business_risk_present='Y'
--    Rows with none of the three keep the defaults ('N', 'N').
-- ---------------------------------------------------------------------
UPDATE grac_practice.custom_gap_analysis
   SET remediation_possible =
         CASE WHEN recommend_task = 1      THEN 'Y'
              WHEN recommend_exception = 1 THEN 'N'
              ELSE remediation_possible END,
       business_risk_present =
         CASE WHEN recommend_risk = 1 THEN 'Y'
              ELSE business_risk_present END
 WHERE remediation_possible = 'N' AND business_risk_present = 'N'
   AND (recommend_task = 1 OR recommend_exception = 1 OR recommend_risk = 1);
GO

-- ---------------------------------------------------------------------
-- 3. REWRITE sp_custom_gap_analysis_save
--    New parameters:  @remediation_possible, @business_risk_present
--    Legacy parameters (@recommend_task/@recommend_exception/@recommend_risk)
--    are retained for callers not yet updated -- if the new params are
--    NULL we fall back to the legacy ones. Otherwise the new params win
--    and we DERIVE the legacy flags from them so downstream consumers
--    keep working.
--
--    Auto-trigger for Exception Centre now fires on
--        remediation_possible='N'
--    (previously: recommend_exception=1). Risk auto-trigger will be
--    added in migration 172 after risk_candidate schema exists.
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
    @recommend_task           BIT           = NULL,     -- legacy; derived when NULL
    @recommend_exception      BIT           = NULL,     -- legacy; derived when NULL
    @recommend_risk           BIT           = NULL,     -- legacy; derived when NULL
    @remediation_possible     CHAR(1)       = NULL,     -- NEW
    @business_risk_present    CHAR(1)       = NULL,     -- NEW
    @analysed_by_employee_id  BIGINT        = NULL,
    @caller_display_name      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @custom_gap_id IS NULL
        THROW 55121, 'sp_custom_gap_analysis_save: custom_gap_id is required.', 1;
    IF NOT EXISTS(SELECT 1 FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id)
        THROW 55122, 'sp_custom_gap_analysis_save: custom_gap not found.', 1;

    -- Decision resolution: prefer the new fields when supplied; otherwise
    -- fall back to legacy flags for backward compat with older callers.
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

    -- Mirror to legacy flags so existing consumers stay coherent.
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

    -- Mirror severity onto the gap header when supplied.
    IF @severity_code IS NOT NULL AND LEN(LTRIM(RTRIM(@severity_code))) > 0
        UPDATE grac_practice.custom_gap
           SET severity_code = @severity_code,
               severity_name = COALESCE(@severity_name, severity_name),
               updated_by    = @caller_display_name,
               updated_dt    = SYSUTCDATETIME()
         WHERE custom_gap_id = @custom_gap_id;

    -- ============ Auto-trigger: Exception request =====================
    -- Fires when analyst decides remediation is NOT possible. Idempotent
    -- (sp_exception_request_create returns existing row for the same gap
    -- if one is already there). Best-effort; analysis save stays durable
    -- even if exception create fails.
    IF @remediation_possible = 'N'
    BEGIN
        BEGIN TRY
            EXEC grac_practice.sp_exception_request_create
                @custom_gap_id            = @custom_gap_id,
                @request_title            = NULL,           -- proc defaults to "Exception: <gap title>"
                @request_reason           = @recommended_action_summary,
                @requested_by_employee_id = @analysed_by_employee_id,
                @caller_display_name      = @caller_display_name;
        END TRY
        BEGIN CATCH
            DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_custom_gap_analysis_save: exception auto-create warning: ', @msg);
        END CATCH
    END

    -- Risk Centre auto-trigger arrives in migration 172 (once
    -- risk_candidate schema is in place).

    SELECT @custom_gap_id AS CustomGapId;
END
GO

-- =====================================================================
-- 4. REWRITE sp_custom_gap_analysis_get -- return the two new columns
--    so the UI can prefill the Yes/No dropdowns from persisted state.
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
        a.remediation_possible      AS RemediationPossible,
        a.business_risk_present     AS BusinessRiskPresent,
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

PRINT '168 gap analysis decisions ready.';
GO
