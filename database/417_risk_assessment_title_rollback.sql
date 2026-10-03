-- =====================================================================
-- 417 rollback -- sp_risk_analysis_get back to 216's body (verbatim),
-- sp_risk_analysis_title_set dropped, risk_analysis.risk_title dropped.
-- Titles already proposed on assessments are lost; titles already
-- written to registered risks (risk_register.risk_title) are kept.
-- Deploy with the Api build from before 417. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

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
        a.business_function_name  AS BusinessFunctionName
      FROM grac_practice.risk_analysis a
 LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = a.risk_owner_employee_id
 LEFT JOIN grac_practice.organization_employee an ON an.employee_id = a.analysed_by_employee_id
     WHERE (@risk_analysis_id IS NOT NULL AND a.risk_analysis_id = @risk_analysis_id)
        OR (@risk_analysis_id IS NULL
            AND a.risk_candidate_id = @risk_candidate_id
            AND a.is_current = 1);
END;
GO

IF OBJECT_ID('grac_practice.sp_risk_analysis_title_set','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_risk_analysis_title_set;
GO

IF COL_LENGTH('grac_practice.risk_analysis','risk_title') IS NOT NULL
    ALTER TABLE grac_practice.risk_analysis DROP COLUMN risk_title;
GO

SELECT '417 rollback' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.risk_analysis','risk_title') IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_analysis_title_set','P') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_analysis_get')) NOT LIKE '%AS RiskTitle%'
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
PRINT '417 rolled back.';
GO
