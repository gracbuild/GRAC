-- =====================================================================
-- 417  Risk title on the candidate Risk assessment
--
-- REQUEST (2026-10-03)
-- --------------------
--   The Risk assessment form (Risk Candidate -> Assessment) asks for the
--   Risk title. Until now a registered risk always took the CANDIDATE's
--   title (sp_risk_candidate_register: COALESCE(@risk_title, candidate
--   title) with @risk_title never sent), and a candidate title is the
--   wording of whatever raised it (a gap, an exception ...), which is
--   often not an apt title for the risk.
--
-- WHAT THIS DOES
-- --------------
--   1. risk_analysis.risk_title NVARCHAR(300) NULL -- the title the
--      analyst proposes for the risk, kept with the assessment so a
--      "Save assessment" without registering does not lose it.
--   2. sp_risk_analysis_title_set -- writes it on one assessment row.
--      Called by the API right after sp_risk_analysis_save when the
--      request carries a title (the same "save, then decorate the new
--      row" shape as the threat/vulnerability selection, 286), so
--      sp_risk_analysis_save -- long and load-bearing -- is NOT re-issued.
--   3. sp_risk_analysis_get -- 216's body re-issued with RiskTitle
--      appended (strict superset; every existing column unchanged).
--
--   Registration is unchanged in SQL: sp_risk_candidate_register already
--   takes @risk_title and falls back to the candidate title when it is
--   empty. The UI now sends the assessment's title.
--
-- NOT CHANGED: business function. The form no longer asks for it (the
--   Risk Analysis page records it under Impact Details, 386), and no
--   procedure required it: sp_risk_analysis_save accepts NULL and
--   sp_risk_register_insert's completeness checks never included it.
--
-- DEPLOY WITH the matching Api + Web build. An Api deployed ahead of this
-- script still saves and reads assessments (the title write is skipped
-- when the procedure is missing; RiskTitle is read only if returned).
-- Rollback: 417_risk_assessment_title_rollback.sql
-- Re-runnable. ASCII-only.
-- DEPENDS ON: 205 (risk_analysis), 216 (sp_risk_analysis_get).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.risk_analysis','U') IS NULL
   OR COL_LENGTH('grac_practice.risk_analysis','business_function_name') IS NULL
BEGIN
    RAISERROR('417_risk_assessment_title: risk_analysis (205/216) is missing. Run 216 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Column
-- ---------------------------------------------------------------------
IF COL_LENGTH('grac_practice.risk_analysis','risk_title') IS NULL
    ALTER TABLE grac_practice.risk_analysis ADD risk_title NVARCHAR(300) NULL;
PRINT '417: risk_analysis.risk_title present.';
GO

-- ---------------------------------------------------------------------
-- 2. Writer
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_analysis_title_set
    @risk_analysis_id    BIGINT,
    @risk_title          NVARCHAR(300),
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_analysis_id IS NULL
        THROW 56970, 'sp_risk_analysis_title_set: risk_analysis_id is required.', 1;

    UPDATE grac_practice.risk_analysis
       SET risk_title = NULLIF(LTRIM(RTRIM(@risk_title)), N''),
           updated_by = @caller_display_name,
           updated_dt = SYSUTCDATETIME()
     WHERE risk_analysis_id = @risk_analysis_id;

    IF @@ROWCOUNT = 0
        THROW 56971, 'sp_risk_analysis_title_set: assessment not found.', 1;
END;
GO

-- ---------------------------------------------------------------------
-- 3. Reader -- 216's sp_risk_analysis_get, RiskTitle appended
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_analysis_get
    @risk_candidate_id BIGINT = NULL,
    @risk_analysis_id  BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_candidate_id IS NULL AND @risk_analysis_id IS NULL
        THROW 56060, 'sp_risk_analysis_get: risk_candidate_id or risk_analysis_id is required.', 1;

    SELECT
        a.risk_analysis_id        AS RiskAnalysisId,
        a.organization_id         AS OrganizationId,
        a.analysis_scope_code     AS AnalysisScopeCode,
        a.risk_candidate_id       AS RiskCandidateId,
        a.risk_register_id        AS RiskRegisterId,
        a.analysis_version        AS AnalysisVersion,
        a.is_current              AS IsCurrent,
        a.risk_statement          AS RiskStatement,
        a.risk_category_code      AS RiskCategoryCode,
        a.risk_category_name      AS RiskCategoryName,
        a.risk_description        AS RiskDescription,
        a.risk_cause              AS RiskCause,
        a.potential_consequence   AS PotentialConsequence,
        a.existing_controls       AS ExistingControls,
        a.likelihood_code         AS LikelihoodCode,
        a.likelihood_name         AS LikelihoodName,
        a.likelihood_value        AS LikelihoodValue,
        a.impact_code             AS ImpactCode,
        a.impact_name             AS ImpactName,
        a.impact_value            AS ImpactValue,
        a.inherent_rating_code    AS InherentRatingCode,
        a.inherent_rating_name    AS InherentRatingName,
        a.inherent_rating_score   AS InherentRatingScore,
        a.risk_owner_employee_id  AS RiskOwnerEmployeeId,
        ow.employee_name          AS RiskOwnerName,
        a.business_unit           AS BusinessUnit,
        a.process_name            AS ProcessName,
        a.analyst_remarks         AS AnalystRemarks,
        a.analysis_dt             AS AnalysisOn,
        a.analysed_by_employee_id AS AnalysedByEmployeeId,
        an.employee_name          AS AnalysedByName,
        a.decision_code           AS DecisionCode,
        a.decision_note           AS DecisionNote,
        a.decision_dt             AS DecisionOn,
        a.approval_status_code    AS ApprovalStatusCode,
        -- ---- NEW in 216 ---------------------------------------------
        a.threat_id               AS ThreatId,
        a.threat_name             AS ThreatName,
        a.threat_description      AS ThreatDescription,
        a.vulnerability_id        AS VulnerabilityId,
        a.vulnerability_name      AS VulnerabilityName,
        a.vulnerability_description AS VulnerabilityDescription,
        a.business_function_id    AS BusinessFunctionId,
        a.business_function_name  AS BusinessFunctionName,
        -- ---- NEW in 417 ---------------------------------------------
        a.risk_title              AS RiskTitle
      FROM grac_practice.risk_analysis a
 LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = a.risk_owner_employee_id
 LEFT JOIN grac_practice.organization_employee an ON an.employee_id = a.analysed_by_employee_id
     WHERE (@risk_analysis_id IS NOT NULL AND a.risk_analysis_id = @risk_analysis_id)
        OR (@risk_analysis_id IS NULL
            AND a.risk_candidate_id = @risk_candidate_id
            AND a.is_current = 1);
END;
GO

-- ---------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------
SELECT '417-a risk_analysis.risk_title exists' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.risk_analysis','risk_title') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '417-b sp_risk_analysis_title_set exists',
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_analysis_title_set','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '417-c sp_risk_analysis_get returns RiskTitle',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_analysis_get')) LIKE '%AS RiskTitle%'
            THEN 'PASS' ELSE 'FAIL' END;
GO
PRINT '417 complete.';
GO
SET NOEXEC OFF;
GO
