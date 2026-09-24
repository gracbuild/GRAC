-- =====================================================================
-- 252 Restore the decision model on the gap analysis procs
--
-- BUG: "Procedure or function sp_custom_gap_analysis_save has too many
--      arguments specified." on saving Gap Analysis.
--
-- CAUSE: migration 249 rebuilt sp_custom_gap_analysis_save and
--      sp_custom_gap_analysis_get from 157's body (the pre-decision-model
--      version) instead of from 174's, which was the live one. Everything
--      168 -> 174 added to those two procs was silently dropped:
--
--        168  @remediation_possible / @business_risk_present params,
--             their Y/N validation, the legacy-flag derivation, the two
--             storage columns on MERGE, and the two projections on _get
--        172  Risk-candidate auto-trigger
--        173  terminal-invalid (Invalid / Duplicate) guard
--        174  Task + Exception auto-triggers, the auto-transition to
--             Delegated, and the SELECT CustomGapId result set
--
--      250 then re-emitted _get on top of 249's already-regressed body,
--      so it carries the same hole.
--
--      The API (GapLifecycleService.SaveAnalysisAsync) still sends
--      @remediation_possible and @business_risk_present -- 2 parameters
--      the proc no longer declares -- which is the "too many arguments"
--      error. GapLifecycleService.GetAnalysisAsync reads
--      r["RemediationPossible"] / r["BusinessRiskPresent"] unguarded, so
--      the Analysis tab read is broken in the same way.
--
-- FIX: re-emit both procs as the union of what each layer contributed:
--        _save = 174's body + 249's @preventive_action
--        _get  = 250's body + 168's RemediationPossible /
--                BusinessRiskPresent projections
--      No API or UI change is required -- both already speak this
--      contract; it is the database that regressed.
--
-- SAFE TO RE-RUN. Requires 156, 168, 174, 249, 250.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (252): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.custom_gap_analysis','U') IS NULL
BEGIN
    PRINT 'ABORT (252): custom_gap_analysis missing (run 156 first).';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.custom_gap_analysis','remediation_possible') IS NULL
BEGIN
    PRINT 'ABORT (252): custom_gap_analysis.remediation_possible missing (run 168 first).';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.custom_gap_analysis','preventive_action') IS NULL
BEGIN
    PRINT 'ABORT (252): custom_gap_analysis.preventive_action missing (run 249 first).';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_custom_gap_analysis_save
--
-- 174's body verbatim, with 249's @preventive_action added. The new
-- parameter keeps 249's position (immediately after
-- @recommended_action_summary) so the API's ordered parameter list is
-- unchanged, and keeps its COALESCE semantics: NULL means "no opinion"
-- and preserves whatever is stored.
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
    -- Migration 249: Corrective Action stays on
    -- recommended_action_summary above; this is the separate Preventive
    -- Action answer.
    @preventive_action        NVARCHAR(MAX) = NULL,
    @recommend_task           BIT           = NULL,
    @recommend_exception      BIT           = NULL,
    @recommend_risk           BIT           = NULL,
    -- Migration 168: sir's decision model. These take priority over the
    -- legacy recommend_* flags above and the legacy flags are derived
    -- from them for backward compatibility.
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
        preventive_action        = COALESCE(@preventive_action, tgt.preventive_action),
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
         @remediation_possible, @business_risk_present,
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

    -- ============ Auto-trigger: Task (remediation_possible='Y') =======
    -- Best-effort; analysis save stays durable even if task creation
    -- fails (retry by re-saving).
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

    -- The API opens a reader on this proc; keep the result set.
    SELECT @custom_gap_id AS CustomGapId;
END
GO
PRINT '252: sp_custom_gap_analysis_save restored (decision model + triggers + preventive_action).';
GO

-- =====================================================================
-- 2. sp_custom_gap_analysis_get
--
-- 250's body (custom_gap fallback for detection method + severity, and
-- 249's PreventiveAction) with 168's RemediationPossible /
-- BusinessRiskPresent projections put back. Projection order matches
-- 168's, with PreventiveAction where 249 placed it.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_analysis_get
    @custom_gap_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @custom_gap_id IS NULL
        THROW 55120, 'sp_custom_gap_analysis_get: custom_gap_id is required.', 1;

    SELECT
        g.custom_gap_id             AS CustomGapId,
        -- Migration 250: fall back to the gap-side answer when the
        -- analysis row has not stored one of its own.
        COALESCE(a.detection_method_code, g.detection_method_code) AS DetectionMethodCode,
        COALESCE(a.detection_method_name, g.detection_method_name) AS DetectionMethodName,
        COALESCE(a.severity_code,         g.severity_code)         AS SeverityCode,
        COALESCE(a.severity_name,         g.severity_name)         AS SeverityName,
        a.business_impact_code      AS BusinessImpactCode,
        a.business_impact_summary   AS BusinessImpactSummary,
        a.regulatory_impact_code    AS RegulatoryImpactCode,
        a.regulatory_impact_summary AS RegulatoryImpactSummary,
        a.rca_required              AS RcaRequired,
        a.rca_method_code           AS RcaMethodCode,
        a.rca_summary               AS RcaSummary,
        a.recommended_action_summary AS RecommendedActionSummary,
        -- Migration 249
        a.preventive_action         AS PreventiveAction,
        a.recommend_task            AS RecommendTask,
        a.recommend_exception       AS RecommendException,
        a.recommend_risk            AS RecommendRisk,
        -- Migration 168 -- restored here; the API reads both unguarded.
        a.remediation_possible      AS RemediationPossible,
        a.business_risk_present     AS BusinessRiskPresent,
        a.analysed_by_employee_id   AS AnalysedByEmployeeId,
        a.analysed_on               AS AnalysedOn,
        a.entered_by                AS EnteredBy,
        a.entered_dt                AS EnteredDt,
        a.updated_by                AS UpdatedBy,
        a.updated_dt                AS UpdatedDt
    FROM       grac_practice.custom_gap          g
    LEFT  JOIN grac_practice.custom_gap_analysis a ON a.custom_gap_id = g.custom_gap_id
    WHERE      g.custom_gap_id = @custom_gap_id;
END
GO
PRINT '252: sp_custom_gap_analysis_get projects RemediationPossible + BusinessRiskPresent again.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 252 verification ===';

DECLARE @save NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P'));
DECLARE @get  NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_analysis_get','P'));

SELECT '252-a save accepts @remediation_possible' AS Check_,
       CASE WHEN @save LIKE '%@remediation_possible%'  THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '252-b save accepts @business_risk_present',
       CASE WHEN @save LIKE '%@business_risk_present%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '252-c save still accepts @preventive_action (249 kept)',
       CASE WHEN @save LIKE '%@preventive_action%'     THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '252-d save has terminal-invalid guard (173 kept)',
       CASE WHEN @save LIKE '%55142%'                  THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '252-e save auto-triggers task (174 kept)',
       CASE WHEN @save LIKE '%sp_custom_gap_task_create%'     THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '252-f save auto-triggers exception (174 kept)',
       CASE WHEN @save LIKE '%sp_exception_request_create%'   THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '252-g save auto-triggers risk (172 kept)',
       CASE WHEN @save LIKE '%sp_risk_candidate_create%'      THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '252-h save auto-delegates (174 kept)',
       CASE WHEN @save LIKE '%Auto-delegated after analysis save%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '252-i save returns CustomGapId result set',
       CASE WHEN @save LIKE '%AS CustomGapId%'         THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '252-j get projects RemediationPossible',
       CASE WHEN @get  LIKE '%RemediationPossible%'    THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '252-k get projects BusinessRiskPresent',
       CASE WHEN @get  LIKE '%BusinessRiskPresent%'    THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '252-l get keeps PreventiveAction (249 kept)',
       CASE WHEN @get  LIKE '%PreventiveAction%'       THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '252-m get keeps custom_gap fallback (250 kept)',
       CASE WHEN @get  LIKE '%COALESCE(a.detection_method_code, g.detection_method_code)%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- The API sends exactly these 21 parameters; the proc must declare them all.
SELECT '252-n save declares all 21 API parameters',
       CASE WHEN (SELECT COUNT(*) FROM sys.parameters
                   WHERE object_id = OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P')) = 21
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '252 complete. Gap Analysis save works again; 249/250 behaviour preserved.';
GO

SET NOEXEC OFF;
GO
