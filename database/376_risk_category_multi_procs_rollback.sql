-- =====================================================================
-- 376 rollback -- drops the two new procedures and restores the three
-- re-issued ones to their exact pre-376 bodies:
--   * sp_risk_scoring_options_get -> 206's exact body (no RiskCategoryId).
--   * sp_risk_register_list       -> 265's exact body (no RiskCategoryNames).
--   * sp_risk_register_get        -> 265's exact body (no RiskCategoryNames).
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_risk_category_selection_set','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_risk_category_selection_set;
    PRINT '376 rollback: sp_risk_category_selection_set dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_risk_category_selection_get','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_risk_category_selection_get;
    PRINT '376 rollback: sp_risk_category_selection_get dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_risk_scoring_options_get','P') IS NULL
BEGIN PRINT 'ABORT (376 rollback): sp_risk_scoring_options_get missing.'; SET NOEXEC ON; END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_scoring_options_get
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 56040, 'sp_risk_scoring_options_get: organization_id is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.risk_matrix_cell
                    WHERE organization_id = @organization_id)
        EXEC grac_practice.sp_risk_scoring_seed_default
             @organization_id = @organization_id, @caller_display_name = N'auto-206';

    SELECT likelihood_code AS LikelihoodCode,
           likelihood_name AS LikelihoodName,
           level_value     AS LevelValue,
           descriptor      AS Descriptor
      FROM grac_practice.risk_likelihood_master
     WHERE organization_id = @organization_id AND status = N'Active'
     ORDER BY level_value;

    SELECT impact_code AS ImpactCode,
           impact_name AS ImpactName,
           level_value AS LevelValue,
           descriptor  AS Descriptor
      FROM grac_practice.risk_impact_master
     WHERE organization_id = @organization_id AND status = N'Active'
     ORDER BY level_value;

    SELECT category_code AS CategoryCode,
           category_name AS CategoryName,
           description   AS Description
      FROM grac_practice.risk_category_master
     WHERE organization_id = @organization_id AND status = N'Active'
     ORDER BY display_order, category_name;

    SELECT source_type_code   AS SourceTypeCode,
           source_name        AS SourceName,
           description        AS Description,
           source_centre_code AS SourceCentreCode
      FROM grac_practice.risk_source_master
     WHERE status = N'Active'
     ORDER BY display_order, source_name;

    SELECT likelihood_value AS LikelihoodValue,
           impact_value     AS ImpactValue,
           rating_code      AS RatingCode,
           rating_name      AS RatingName,
           rating_score     AS RatingScore,
           colour_hex       AS ColourHex
      FROM grac_practice.risk_matrix_cell
     WHERE organization_id = @organization_id
     ORDER BY likelihood_value, impact_value;
END;
GO

IF OBJECT_ID('grac_practice.sp_risk_register_list','P') IS NULL
BEGIN PRINT 'ABORT (376 rollback): sp_risk_register_list missing.'; SET NOEXEC ON; END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_register_list
    @organization_id  BIGINT,
    @status_code      NVARCHAR(30) = NULL,
    @source_type_code NVARCHAR(40) = NULL,
    @category_code    NVARCHAR(60) = NULL,
    @rating_code      NVARCHAR(30) = NULL,
    @owner_employee_id BIGINT      = NULL,
    @search           NVARCHAR(200) = NULL,
    @page_number      INT = 1,
    @page_size        INT = 25,
    @analysis_pending BIT = NULL,
    @residual_rating_code NVARCHAR(30) = NULL,
    @residual_pending     BIT          = NULL,
    @treatment_option_code NVARCHAR(30)  = NULL,
    @workflow_stage_code   NVARCHAR(30)  = NULL,
    @review_due            BIT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 56150, 'sp_risk_register_list: organization_id is required.', 1;
    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    SELECT
        r.risk_register_id      AS RiskRegisterId,
        r.risk_number           AS RiskNumber,
        r.organization_id       AS OrganizationId,
        r.risk_title            AS RiskTitle,
        r.risk_statement        AS RiskStatement,
        r.risk_category_code    AS RiskCategoryCode,
        r.risk_category_name    AS RiskCategoryName,
        r.source_type_code      AS SourceTypeCode,
        r.source_record_id      AS SourceRecordId,
        r.source_reference      AS SourceReference,
        r.source_centre_code    AS SourceCentreCode,
        r.risk_candidate_id     AS RiskCandidateId,
        r.risk_analysis_id      AS RiskAnalysisId,
        r.risk_owner_employee_id AS RiskOwnerEmployeeId,
        ow.employee_name        AS RiskOwnerName,
        r.business_unit         AS BusinessUnit,
        r.likelihood_name       AS LikelihoodName,
        r.impact_name           AS ImpactName,
        r.inherent_rating_code  AS InherentRatingCode,
        r.inherent_rating_name  AS InherentRatingName,
        r.inherent_rating_score AS InherentRatingScore,
        r.status_code           AS StatusCode,
        r.registered_dt         AS RegisteredOn,
        rb.employee_name        AS RegisteredByName,
        r.analysis_pending      AS AnalysisPending,
        r.threat_name           AS ThreatName,
        r.vulnerability_name    AS VulnerabilityName,
        r.business_function_name AS BusinessFunctionName,
        r.residual_likelihood_name AS ResidualLikelihoodName,
        r.residual_impact_name     AS ResidualImpactName,
        r.residual_rating_code     AS ResidualRatingCode,
        r.residual_rating_name     AS ResidualRatingName,
        r.residual_rating_score    AS ResidualRatingScore,
        r.residual_assessed_dt     AS ResidualAssessedOn,
        r.residual_pending         AS ResidualPending,
        r.treatment_option_code    AS TreatmentOptionCode,
        r.treatment_option_name    AS TreatmentOptionName,
        r.treatment_task_id        AS TreatmentTaskId,
        r.accepted_dt              AS AcceptedOn,
        COALESCE(ab.employee_name, r.accepted_by_name) AS AcceptedByName,
        r.next_review_date         AS NextReviewDate,
        r.last_reviewed_dt         AS LastReviewedOn,
        r.review_count             AS ReviewCount,
        st.workflow_stage_code     AS WorkflowStageCode,
        st.open_treatment_task_count AS OpenTreatmentTaskCount,
        st.treatment_task_count      AS TreatmentTaskCount,
        st.is_review_due             AS IsReviewDue,
        (SELECT COUNT(*) FROM grac_practice.risk_practice_map pm
          WHERE pm.risk_register_id = r.risk_register_id) AS MappedPracticeCount,
        (SELECT COUNT(*) FROM grac_practice.risk_dependency_map am
          WHERE am.risk_register_id = r.risk_register_id) AS MappedDependencyCount,
        COUNT(*) OVER ()        AS TotalRows
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.risk_owner_employee_id
 LEFT JOIN grac_practice.organization_employee rb ON rb.employee_id = r.registered_by_employee_id
 LEFT JOIN grac_practice.organization_employee ab ON ab.employee_id = r.accepted_by_employee_id
 LEFT JOIN grac_practice.vw_pm_risk_workflow_stage st ON st.risk_register_id = r.risk_register_id
     WHERE r.organization_id = @organization_id
       AND (@status_code      IS NULL OR r.status_code         = @status_code)
       AND (@source_type_code IS NULL OR r.source_type_code    = @source_type_code)
       AND (@category_code    IS NULL OR r.risk_category_code  = @category_code)
       AND (@rating_code      IS NULL OR r.inherent_rating_code= @rating_code)
       AND (@owner_employee_id IS NULL OR r.risk_owner_employee_id = @owner_employee_id)
       AND (@analysis_pending IS NULL OR r.analysis_pending    = @analysis_pending)
       AND (@residual_rating_code IS NULL OR r.residual_rating_code = @residual_rating_code)
       AND (@residual_pending     IS NULL OR r.residual_pending     = @residual_pending)
       AND (@treatment_option_code IS NULL OR r.treatment_option_code = @treatment_option_code)
       AND (@workflow_stage_code   IS NULL OR st.workflow_stage_code  = @workflow_stage_code)
       AND (@review_due            IS NULL OR st.is_review_due        = @review_due)
       AND (@search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0
            OR r.risk_title     LIKE N'%' + @search + N'%'
            OR r.risk_statement LIKE N'%' + @search + N'%'
            OR r.risk_number    LIKE N'%' + @search + N'%')
     ORDER BY r.registered_dt DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

IF OBJECT_ID('grac_practice.sp_risk_register_get','P') IS NULL
BEGIN PRINT 'ABORT (376 rollback): sp_risk_register_get missing.'; SET NOEXEC ON; END
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

PRINT '376 rollback complete. sp_risk_scoring_options_get, sp_risk_register_list';
PRINT 'and sp_risk_register_get restored to their pre-376 (206/265) bodies; the';
PRINT 'two new category-selection procedures are dropped. 375''s link tables and';
PRINT 'backfill are untouched -- roll back 375 separately if they should go too.';
GO
