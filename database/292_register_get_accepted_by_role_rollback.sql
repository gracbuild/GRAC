-- =====================================================================
-- 292_register_get_accepted_by_role_rollback.sql
--
-- Re-issues sp_risk_register_get exactly as 265 left it, without
-- AcceptedByRoleNames. The text below is a verbatim extract from
-- 265_risk_dependency_mapping_schema.sql.
--
-- Leaves fn_employee_role_names in place -- 291 owns it, and the
-- dependency Person picker still calls it. Roll 291 back for that.
--
-- CONSEQUENCE: acceptance displays fall back to the bare name.
-- Re-runnable: yes. ASCII-only (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_register_get
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_register_id IS NULL
        THROW 56160, 'sp_risk_register_get: risk_register_id is required.', 1;

    SELECT
        r.risk_register_id      AS RiskRegisterId,
        r.risk_number           AS RiskNumber,
        r.organization_id       AS OrganizationId,
        r.risk_title            AS RiskTitle,
        r.risk_statement        AS RiskStatement,
        r.risk_description      AS RiskDescription,
        r.risk_category_code    AS RiskCategoryCode,
        r.risk_category_name    AS RiskCategoryName,

        r.source_type_code      AS SourceTypeCode,
        sm.source_name          AS SourceName,
        r.source_record_id      AS SourceRecordId,
        r.source_reference      AS SourceReference,
        r.source_description    AS SourceDescription,
        r.source_centre_code    AS SourceCentreCode,

        r.risk_candidate_id     AS RiskCandidateId,
        c.candidate_number      AS CandidateNumber,
        c.candidate_title       AS CandidateTitle,
        c.custom_gap_id         AS CustomGapId,
        r.risk_analysis_id      AS RiskAnalysisId,
        a.analysis_version      AS AnalysisVersion,
        a.analysis_dt           AS AnalysisOn,
        an.employee_name        AS AnalysedByName,

        r.risk_owner_employee_id AS RiskOwnerEmployeeId,
        ow.employee_name        AS RiskOwnerName,
        r.business_unit         AS BusinessUnit,
        r.process_name          AS ProcessName,
        r.risk_cause            AS RiskCause,
        r.potential_consequence AS PotentialConsequence,
        r.existing_controls     AS ExistingControls,

        r.likelihood_code       AS LikelihoodCode,
        r.likelihood_name       AS LikelihoodName,
        r.likelihood_value      AS LikelihoodValue,
        r.impact_code           AS ImpactCode,
        r.impact_name           AS ImpactName,
        r.impact_value          AS ImpactValue,
        r.inherent_rating_code  AS InherentRatingCode,
        r.inherent_rating_name  AS InherentRatingName,
        r.inherent_rating_score AS InherentRatingScore,

        r.linked_asset_id       AS LinkedAssetId,
        r.linked_vendor_id      AS LinkedVendorId,
        r.linked_practice_id    AS LinkedPracticeId,
        lp.practice_name        AS LinkedPracticeName,
        r.linked_obligation_id  AS LinkedObligationId,
        r.linked_control_id     AS LinkedControlId,

        r.status_code           AS StatusCode,
        r.registered_dt         AS RegisteredOn,
        r.registered_by_employee_id AS RegisteredByEmployeeId,
        rb.employee_name        AS RegisteredByName,
        r.closed_dt             AS ClosedOn,
        cb.employee_name        AS ClosedByName,
        r.closure_reason        AS ClosureReason,
        -- ---- 216 ----------------------------------------------------
        r.analysis_pending      AS AnalysisPending,
        r.threat_id             AS ThreatId,
        r.threat_name           AS ThreatName,
        r.threat_description    AS ThreatDescription,
        r.vulnerability_id      AS VulnerabilityId,
        r.vulnerability_name    AS VulnerabilityName,
        r.vulnerability_description AS VulnerabilityDescription,
        r.business_function_id  AS BusinessFunctionId,
        r.business_function_name AS BusinessFunctionName,
        cur.approval_status_code AS AnalysisApprovalStatusCode,
        -- ---- 258 ----------------------------------------------------
        r.residual_analysis_id      AS ResidualAnalysisId,
        res.residual_version        AS ResidualVersion,
        r.residual_likelihood_code  AS ResidualLikelihoodCode,
        r.residual_likelihood_name  AS ResidualLikelihoodName,
        r.residual_likelihood_value AS ResidualLikelihoodValue,
        r.residual_impact_code      AS ResidualImpactCode,
        r.residual_impact_name      AS ResidualImpactName,
        r.residual_impact_value     AS ResidualImpactValue,
        r.residual_rating_code      AS ResidualRatingCode,
        r.residual_rating_name      AS ResidualRatingName,
        r.residual_rating_score     AS ResidualRatingScore,
        r.residual_assessed_dt      AS ResidualAssessedOn,
        r.residual_pending          AS ResidualPending,
        res.treatment_summary       AS ResidualTreatmentSummary,
        res.residual_controls       AS ResidualControls,
        res.analyst_remarks         AS ResidualRemarks,
        rab.employee_name           AS ResidualAssessedByName,
        -- ---- 261 / 263 / 264 ----------------------------------------
        r.treatment_option_code     AS TreatmentOptionCode,
        r.treatment_option_name     AS TreatmentOptionName,
        r.treatment_decided_dt      AS TreatmentDecidedOn,
        td.employee_name            AS TreatmentDecidedByName,
        r.treatment_task_id         AS TreatmentTaskId,
        r.accepted_by_employee_id   AS AcceptedByEmployeeId,
        COALESCE(ab.employee_name, r.accepted_by_name) AS AcceptedByName,
        r.accepted_dt               AS AcceptedOn,
        r.acceptance_note           AS AcceptanceNote,
        r.next_review_date          AS NextReviewDate,
        r.last_reviewed_dt          AS LastReviewedOn,
        r.review_count              AS ReviewCount,
        st.workflow_stage_code      AS WorkflowStageCode,
        st.open_treatment_task_count AS OpenTreatmentTaskCount,
        st.treatment_task_count      AS TreatmentTaskCount,
        st.is_review_due             AS IsReviewDue,
        (SELECT COUNT(*) FROM grac_practice.risk_practice_map pm
          WHERE pm.risk_register_id = r.risk_register_id) AS MappedPracticeCount,
        (SELECT COUNT(*) FROM grac_practice.risk_dependency_map am
          WHERE am.risk_register_id = r.risk_register_id) AS MappedDependencyCount
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.risk_source_master  sm ON sm.source_type_code = r.source_type_code
 LEFT JOIN grac_practice.risk_candidate      c  ON c.risk_candidate_id = r.risk_candidate_id
 LEFT JOIN grac_practice.risk_analysis       a  ON a.risk_analysis_id  = r.risk_analysis_id
 LEFT JOIN grac_practice.practice            lp ON lp.practice_id      = r.linked_practice_id
 OUTER APPLY (SELECT TOP 1 x.approval_status_code
                FROM grac_practice.risk_analysis x
               WHERE x.risk_register_id = r.risk_register_id
                 AND x.is_current = 1
               ORDER BY x.analysis_version DESC) AS cur
 LEFT JOIN grac_practice.risk_residual_analysis res
        ON res.risk_residual_analysis_id = r.residual_analysis_id
 LEFT JOIN grac_practice.organization_employee rab ON rab.employee_id = res.assessed_by_employee_id
 LEFT JOIN grac_practice.organization_employee an ON an.employee_id = a.analysed_by_employee_id
 LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.risk_owner_employee_id
 LEFT JOIN grac_practice.organization_employee rb ON rb.employee_id = r.registered_by_employee_id
 LEFT JOIN grac_practice.organization_employee cb ON cb.employee_id = r.closed_by_employee_id
 LEFT JOIN grac_practice.organization_employee ab ON ab.employee_id = r.accepted_by_employee_id
 LEFT JOIN grac_practice.organization_employee td ON td.employee_id = r.treatment_decided_by_employee_id
 LEFT JOIN grac_practice.vw_pm_risk_workflow_stage st ON st.risk_register_id = r.risk_register_id
     WHERE r.risk_register_id = @risk_register_id;
END;
GO

PRINT '292 rollback: sp_risk_register_get restored to the 265 definition.';
GO
