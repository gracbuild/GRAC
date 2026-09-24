-- =====================================================================
-- 311 Risk Centre -- LinkedPracticeCount on sp_risk_register_get
--
-- THE BUG
--   Risk Context on the View Risk page showed nothing under Linked
--   Practice where it should have shown "3 Practices".
--
--   MappedPracticeCount is COUNT(*) over risk_practice_map, and that
--   map's Primary row is DERIVED rather than written at registration:
--   sp_risk_mapping_sync_primary (262/266) turns
--   risk_register.linked_practice_id into a Primary map row, and the
--   ONLY caller is RiskCentreService.GetMappingAsync -- the read behind
--   GET /register/{id}/mapping.
--
--   The View Risk page renders Risk Context from GET /register/{id}
--   FIRST and mounts the scope panel (which triggers that derivation)
--   AFTERWARDS. So on the first view of a risk whose Primary row had
--   never been derived, the count really was 0 at the moment the section
--   rendered -- and Risk Context is not re-rendered when the panel
--   finishes. The plumbing was fine; the number was honest and useless.
--
-- THE FIX, IN SQL, ONCE
--   A new column that answers the question the UI is actually asking:
--   how many practices is this risk linked to. It is the map, plus the
--   risk's own linked practice when that practice is not in the map
--   yet -- correct before the derivation has ever run, and unchanged
--   after it.
--
--   Fixing it here rather than in the page means every reader gets the
--   same answer: the register detail drawer, the View Risk page, the
--   residual page and the acceptance page all read this procedure. The
--   alternative -- having the page re-render the cell once the mapping
--   panel loads -- would put a second definition of "how many
--   practices" in JavaScript and make the answer depend on whether a
--   panel happened to be mounted.
--
-- MappedPracticeCount IS UNCHANGED and keeps its name's meaning: rows
--   in risk_practice_map. The Existing Controls panel renders exactly
--   those rows, so a count that silently included a practice the panel
--   does not list would be wrong for that reader.
--
-- WHY A SEPARATE MIGRATION
--   310 is already applied. It is re-runnable, but a teammate who has
--   run it would have no reason to run it again, so the change goes in
--   its own numbered file -- which is also where a reader will look for
--   it.
--
-- ADDITIVE. One column on one read procedure. No table, no data, no
-- other procedure. sp_risk_mapping_sync_primary is deliberately NOT
-- called from here: a read procedure that writes is a read procedure
-- that deadlocks under load, and the derivation already happens where
-- it belongs.
--
-- The body below was EXTRACTED from 310 (the current owner) and had one
-- column injected programmatically, never retyped -- 292's technique,
-- for 292's reason: this is a 140-line procedure and a transcription
-- slip would silently drop a column the UI reads by name.
--
-- ASCII-only on purpose (sqlcmd codepage safety).
-- Re-runnable: yes (CREATE OR ALTER).
-- DEPENDS ON: 310 (the body re-issued here), 261 (risk_practice_map),
--             291 (fn_employee_role_names), 264 (the stage view).
-- Rollback:   database/311_linked_practice_count_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF OBJECT_ID('grac_practice.sp_risk_register_get','P') IS NULL
BEGIN
    PRINT 'ABORT (311): sp_risk_register_get missing. Run 310 first.';
    SET @prereqs_ok = 0;
END

IF COL_LENGTH('grac_practice.risk_register','risk_version') IS NULL
BEGIN
    PRINT 'ABORT (311): risk_register.risk_version missing. Run 310 first --';
    PRINT '             the body re-issued here selects it as RiskVersion.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.risk_practice_map','U') IS NULL
BEGIN
    PRINT 'ABORT (311): risk_practice_map missing. Run 261 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.fn_employee_role_names','FN') IS NULL
BEGIN
    PRINT 'ABORT (311): fn_employee_role_names missing. Run 291 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage','V') IS NULL
BEGIN
    PRINT 'ABORT (311): vw_pm_risk_workflow_stage missing. Run 264 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('311_linked_practice_count: prerequisites missing -- see the PRINT messages above. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
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

        -- MIGRATION 310. THE ONE COMMON RISK VERSION.
        -- Not analysis_version and not residual_version: those are the
        -- BRD 20 history sequences of their own tables and still are.
        -- This is the risk's version, and only an acceptance moves it.
        r.risk_version          AS RiskVersion,

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
           -- THE ONLY ADDITION IN 292. Separate from
           -- AcceptedByName so no stored value gains a role
           -- suffix; the UI composes "Name - Role".
           grac_practice.fn_employee_role_names(r.accepted_by_employee_id)
                                     AS AcceptedByRoleNames,
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
        -- MIGRATION 311. HOW MANY PRACTICES THIS RISK IS LINKED TO.
        --
        -- NOT the same question as MappedPracticeCount above, which is
        -- literally "rows in risk_practice_map" and keeps that meaning.
        --
        -- The Primary row is DERIVED, not written at registration:
        -- sp_risk_mapping_sync_primary turns linked_practice_id into a
        -- Primary map row, and the only thing that calls it is
        -- GetMappingAsync -- the read behind /register/{id}/mapping. So
        -- a risk that has never had its scope panel opened has a linked
        -- practice and an EMPTY map, and a count of the map alone
        -- reports 0 for a risk that plainly shows a practice.
        --
        -- This counts the map plus the risk's own linked practice when
        -- that practice is not in the map yet, so the answer is right
        -- before the derivation has ever run and unchanged after it.
        (SELECT COUNT(*) FROM grac_practice.risk_practice_map pm
          WHERE pm.risk_register_id = r.risk_register_id)
        + CASE WHEN r.linked_practice_id IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_practice_map pm2
                                 WHERE pm2.risk_register_id = r.risk_register_id
                                   AND pm2.practice_id      = r.linked_practice_id)
               THEN 1 ELSE 0 END                          AS LinkedPracticeCount,
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

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '311-a returns LinkedPracticeCount' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_get'))
                 LIKE '%AS LinkedPracticeCount%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '311-b MappedPracticeCount still returned, unchanged in meaning',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_get'))
                 LIKE '%AS MappedPracticeCount%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '311-c 310 RiskVersion survived the re-issue',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_get'))
                 LIKE '%AS RiskVersion%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '311-d 292 AcceptedByRoleNames survived the re-issue',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_get'))
                 LIKE '%AS AcceptedByRoleNames%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '311-e still a read-only procedure (no INSERT/UPDATE/DELETE)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_get'))
                 NOT LIKE '%INSERT INTO%'
            AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_get'))
                 NOT LIKE '%UPDATE grac_practice%'
            THEN 'PASS' ELSE 'FAIL' END;

-- The two counts side by side, so the difference is visible on real
-- data: any row where they differ is a risk whose Primary map row has
-- not been derived yet.
SELECT r.risk_register_id  AS RiskId,
       r.risk_number       AS RiskNumber,
       r.linked_practice_id AS LinkedPracticeId,
       (SELECT COUNT(*) FROM grac_practice.risk_practice_map pm
         WHERE pm.risk_register_id = r.risk_register_id) AS MappedPracticeCount,
       (SELECT COUNT(*) FROM grac_practice.risk_practice_map pm
         WHERE pm.risk_register_id = r.risk_register_id)
       + CASE WHEN r.linked_practice_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_practice_map pm2
                                WHERE pm2.risk_register_id = r.risk_register_id
                                  AND pm2.practice_id      = r.linked_practice_id)
              THEN 1 ELSE 0 END                          AS LinkedPracticeCount
  FROM grac_practice.risk_register r
 ORDER BY r.risk_register_id;

PRINT '';
PRINT '311 complete. Risk Context can state the practice count before the';
PRINT 'scope panel has ever been opened. Next: rebuild the API and Web tiers.';
GO

SET NOEXEC OFF;
GO
