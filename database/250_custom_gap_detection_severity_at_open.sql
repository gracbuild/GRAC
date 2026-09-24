-- =====================================================================
-- 250 Detection method + severity captured at Add-Gap time
--
-- CONTEXT
-- -------
-- The Add-Gap dialog on Gap Centre asks for title, priority, owner, due
-- date, remarks -- but not detection method or severity. Both are then
-- asked again inside the analysis card (severity as a read-only "auto"
-- field). For a Custom gap there is no "auto" source to derive from,
-- so the analysis form landed with a blank Severity select and an
-- "(auto)" label that pointed at nothing.
--
-- Sir asked for these two facts to be captured at Add-Gap time on a
-- Custom gap, and for the analysis card to show what the operator
-- entered instead of pretending to auto-derive. This migration:
--
--   1. Adds detection_method_code + detection_method_name to
--      grac_practice.custom_gap (severity_code / severity_name were
--      added in 109). Both nullable -- legacy rows and non-Custom
--      auto-opened gaps carry NULL and behave exactly as before.
--   2. Re-emits sp_custom_gap_open to accept the four new params and
--      persist them on INSERT. The existing severity-mirror step from
--      later procs still applies -- if analysis-save later provides
--      one, it overwrites.
--   3. Re-emits sp_custom_gap_header to project the two new columns so
--      the gap-detail page's applyAnalysisToForm fallback path (JS
--      reads state.gapHeader.severityCode / detectionMethodCode) has
--      values to show before analysis exists.
--   4. Re-emits sp_custom_gap_analysis_get so that when there is no
--      analysis row yet, or when the analysis row's fields are null,
--      the projection falls back to the gap-side values -- so the
--      "auto" fields on the analysis form are never blank when the
--      operator did answer them at Add.
--
-- SAFE TO RE-RUN. Requires 156, 185, 249.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (250): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
BEGIN
    PRINT 'ABORT (250): custom_gap missing (run 054 first).';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Columns
-- =====================================================================
IF COL_LENGTH('grac_practice.custom_gap','detection_method_code') IS NULL
BEGIN
    ALTER TABLE grac_practice.custom_gap
        ADD detection_method_code NVARCHAR(60) NULL;
    PRINT '250: custom_gap.detection_method_code added.';
END
GO

IF COL_LENGTH('grac_practice.custom_gap','detection_method_name') IS NULL
BEGIN
    ALTER TABLE grac_practice.custom_gap
        ADD detection_method_name NVARCHAR(200) NULL;
    PRINT '250: custom_gap.detection_method_name added.';
END
GO

-- =====================================================================
-- 2. sp_custom_gap_open -- accept detection + severity
--
-- Full re-emit of 055's body with four new optional params. Optional
-- and last so any older caller still binds; missing values behave
-- exactly like today (NULL, and analysis defaults kick in later).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_open
    @organization_id        BIGINT,
    @title                  NVARCHAR(250),
    @description            NVARCHAR(MAX) = NULL,
    @priority               NVARCHAR(30)  = N'Medium',
    @owner_employee_id      BIGINT        = NULL,
    @due_date               DATE          = NULL,
    @status                 NVARCHAR(30)  = N'Open',
    @remarks                NVARCHAR(1000) = NULL,
    @gap_type_code          NVARCHAR(60)  = N'Custom',
    @actor_employee_id      BIGINT        = NULL,
    -- Migration 250: captured at Add-Gap time. Optional; NULL means
    -- "no opinion" (existing behaviour: severity later gets derived).
    @severity_code          NVARCHAR(30)  = NULL,
    @severity_name          NVARCHAR(120) = NULL,
    @detection_method_code  NVARCHAR(60)  = NULL,
    @detection_method_name  NVARCHAR(200) = NULL,
    @custom_gap_id          BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @title IS NULL OR LTRIM(RTRIM(@title)) = N''
        THROW 54010, 'sp_custom_gap_open: organization_id and title are required.', 1;

    IF @priority NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @priority = N'Medium';

    IF @status NOT IN (N'Open', N'InProgress', N'Closed', N'Cancelled')
        SET @status = N'Open';

    -- Severity validated against the same four values every other
    -- write path uses. Blank / unknown falls back to priority so the
    -- gap still lands with some rank -- the same fallback 189's
    -- sp_custom_gap_apply_sla was using.
    IF @severity_code IS NOT NULL AND @severity_code NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @severity_code = NULL;
    IF @severity_code IS NULL
        SET @severity_code = @priority;
    IF @severity_name IS NULL
        SET @severity_name = @severity_code;

    INSERT INTO grac_practice.custom_gap
        (organization_id, gap_type_code, title, description, priority,
         owner_employee_id, due_date, status, remarks,
         severity_code, severity_name,
         detection_method_code, detection_method_name,
         entered_by, entered_dt)
    VALUES
        (@organization_id, ISNULL(@gap_type_code, N'Custom'),
         @title, @description, @priority,
         @owner_employee_id, @due_date, @status, @remarks,
         @severity_code, @severity_name,
         NULLIF(LTRIM(RTRIM(@detection_method_code)), N''),
         NULLIF(LTRIM(RTRIM(@detection_method_name)), N''),
         COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api'),
         SYSUTCDATETIME());

    SET @custom_gap_id = SCOPE_IDENTITY();
END
GO
PRINT '250: sp_custom_gap_open accepts detection + severity.';
GO

-- =====================================================================
-- 3. sp_custom_gap_header -- project the two new columns
--
-- 185's body re-emitted with DetectionMethodCode + DetectionMethodName
-- added to the projection. The API reader is guarded on HasColumn so a
-- pre-250 database still binds; a 250-ready database gets the values
-- populated for the JS "sevFromHeader" fallback that fills the
-- analysis form when no analysis row exists yet.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_header
    @custom_gap_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @custom_gap_id IS NULL
        THROW 55160, 'sp_custom_gap_header: custom_gap_id is required.', 1;

    SELECT
        g.custom_gap_id            AS CustomGapId,
        g.organization_id          AS OrganizationId,
        g.title                    AS Title,
        g.description              AS Description,
        g.status                   AS StatusCode,
        g.priority                 AS Priority,
        g.severity_code            AS SeverityCode,
        g.severity_name            AS SeverityName,
        -- Migration 250: exposed on the header so the analysis form
        -- can pre-populate "auto" fields from the values the operator
        -- entered at Add Gap. Nullable -- absent on non-Custom gaps
        -- and on legacy rows.
        g.detection_method_code    AS DetectionMethodCode,
        g.detection_method_name    AS DetectionMethodName,
        g.owner_display_name       AS OwnerName,
        g.owner_employee_id        AS OwnerEmployeeId,
        g.due_date                 AS DueDate,
        s.state_code               AS LifecycleStateCode,
        s.state_name               AS LifecycleStateName,
        s.is_terminal              AS LifecycleIsTerminal,
        s.is_valid_terminal        AS LifecycleIsValidTerminal,
        g.gap_source_module_code   AS SourceModuleCode,
        g.duplicate_of_gap_id      AS DuplicateOfGapId,
        p.title                    AS DuplicateOfGapTitle,
        g.invalid_reason           AS InvalidReason,
        g.sla_master_id            AS SlaMasterId,
        g.sla_master_name          AS SlaMasterName,
        g.sla_days_effective       AS SlaDaysEffective,
        g.sla_source_code          AS SlaSourceCode,
        CAST(CASE WHEN EXISTS (
                SELECT 1 FROM grac_practice.exception_request er
                WHERE er.custom_gap_id     = g.custom_gap_id
                  AND er.request_type_code = N'SLA_CANDIDATE'
                  AND er.status_code       = N'Pending')
             THEN 1 ELSE 0 END AS BIT)  AS SlaOverridePending
      FROM grac_practice.custom_gap g
 LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
 LEFT JOIN grac_practice.custom_gap p                 ON p.custom_gap_id      = g.duplicate_of_gap_id
     WHERE g.custom_gap_id = @custom_gap_id;
END
GO
PRINT '250: sp_custom_gap_header projects DetectionMethod fields.';
GO

-- =====================================================================
-- 4. sp_custom_gap_analysis_get -- fall back to custom_gap values
--
-- 249's body re-emitted, but every "auto"-natured projection now
-- COALESCEs onto the parent custom_gap row. Detection method + severity
-- captured at Add-Gap time become the first paint of the analysis form
-- even before the analyst types anything.
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
        -- analysis row has not stored one of its own. The analysis
        -- form ends up showing the operator's Add-Gap choice instead
        -- of a blank "(auto)" field.
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
    FROM       grac_practice.custom_gap          g
    LEFT  JOIN grac_practice.custom_gap_analysis a ON a.custom_gap_id = g.custom_gap_id
    WHERE      g.custom_gap_id = @custom_gap_id;
END
GO
PRINT '250: sp_custom_gap_analysis_get falls back to custom_gap for detection + severity.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 250 verification ===';

SELECT '250-a detection_method_code column added' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.custom_gap','detection_method_code') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '250-b detection_method_name column added',
       CASE WHEN COL_LENGTH('grac_practice.custom_gap','detection_method_name') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '250-c open proc accepts @severity_code + @detection_method_code',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_open','P')) LIKE '%@severity_code%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_open','P')) LIKE '%@detection_method_code%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '250-d header proc projects DetectionMethodCode',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_header','P')) LIKE '%DetectionMethodCode%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '250-e analysis-get COALESCEs onto custom_gap',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_analysis_get','P'))
                 LIKE '%COALESCE(a.severity_code,%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Regression: 249's Preventive column must still be in the projection.
SELECT '250-f regression: PreventiveAction still projected',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_analysis_get','P')) LIKE '%PreventiveAction%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '250 complete. Add Gap captures detection + severity, analysis form pre-fills from them.';
GO

SET NOEXEC OFF;
GO
