-- =====================================================================
-- 376 Risk Category -- procedures, and the additive reads that show the
--     full set
--
--   1. sp_risk_category_selection_set   replace the set (REQUIRED, >= 1)
--   2. sp_risk_category_selection_get   the current set for one risk
--   3. sp_risk_scoring_options_get      RE-ISSUED (206) -- +RiskCategoryId
--   4. sp_risk_register_list            RE-ISSUED (265) -- +RiskCategoryNames
--   5. sp_risk_register_get             RE-ISSUED (265) -- +RiskCategoryNames
--
-- THIS IS 314's SHAPE, INCLUDING THE THING IT REFUSED TO BUILD
-- ---------------------------------------------------------------------
-- 314 considered wrapping sp_risk_register_assess so one call could
-- carry the id list, and rejected it in writing: reproducing 216's full
-- parameter list purely to pass it through would have to be
-- re-reproduced every time 216 gained a parameter. That reasoning holds
-- here too, so there is NO WRAPPER and sp_risk_register_assess is NOT
-- re-issued by this migration. The caller does two things: save the
-- analysis through sp_risk_register_assess as it always has (still
-- sending ONE @risk_category_code -- the first ticked category, by
-- display order, so the legacy column stays populated with something an
-- analyst actually chose), then call sp_risk_category_selection_set with
-- the whole list.
--
-- 314's REQUIRED rule, reused: at least one category, enforced HERE
-- (56757) rather than only in the browser, for the same reason 314 gives
-- for 56731 -- a rule that lives only in a form is not a rule. Unlike
-- Risk Type, this is not a NEW requirement: @risk_category_code has
-- always been required by sp_risk_register_assess (216), so no risk
-- that could save before this migration becomes unsavable after it --
-- 56757 can only ever fire if the analyst unticks every option, which the
-- form also disables Save for.
--
-- ORGANISATION SCOPING, SIMPLER THAN 314's
-- ---------------------------------------------------------------------
-- risk_category_master has no shared (organization_id NULL) rows at all
-- (204: organization_id BIGINT NOT NULL) -- unlike risk_type_master /
-- threat_master / vulnerability_master, which all mix seeded shared rows
-- with tenant-private ones. So the visibility check below is a plain
-- "belongs to this organisation", not the "shared OR mine" OR risk_type
-- needs. An id that fails it is DROPPED, not thrown on -- 314's reason:
-- it means the category was retired or belongs to another tenant, and
-- refusing an entire save over one stale chip would lose the analyst's
-- other work. If dropping leaves the set EMPTY, 56757 fires.
--
-- WHY RiskCategoryNames IS ADDITIVE, NOT A REPLACEMENT
-- ---------------------------------------------------------------------
-- sp_risk_register_list / sp_risk_register_get keep returning
-- RiskCategoryCode / RiskCategoryName exactly as before -- the legacy
-- scalar, "the first selected category" (see above). RiskCategoryNames
-- is a NEW column: every category currently mapped to the register row,
-- comma separated, worst -- no, alphabetical is wrong too -- ordered by
-- the master's own display_order so the grid reads in the same order the
-- analyst ticked them in the form. A caller on an older API build that
-- has not read this column yet is unaffected; RiskCategoryName alone
-- still shows a real value (the same one it always has), same
-- degrade-safely convention 372's CurrentStatusCode and 311's
-- LinkedPracticeCount both already use in this codebase.
--
-- Re-runnable: yes (CREATE OR ALTER).
-- Rollback: database/376_risk_category_multi_procs_rollback.sql
-- DEPENDS ON: 375 (the link tables), 206 (sp_risk_scoring_options_get),
--             265 (sp_risk_register_list / sp_risk_register_get).
-- ERROR CODE RANGE: 56755-56759 (56750-56754 and 56760-56799 free, but
--                    56755-56759 keeps this migration's codes together
--                    and clear of 313/314's 56730-56733).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF OBJECT_ID('grac_practice.risk_analysis_risk_category','U') IS NULL
   OR OBJECT_ID('grac_practice.risk_register_risk_category','U') IS NULL
BEGIN
    PRINT 'ABORT (376): the risk-category link tables are missing. Run 375 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.risk_category_master','U') IS NULL
BEGIN
    PRINT 'ABORT (376): risk_category_master missing. Run 204 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.sp_risk_scoring_options_get','P') IS NULL
BEGIN
    PRINT 'ABORT (376): sp_risk_scoring_options_get missing. Run 206 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.sp_risk_register_list','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_risk_register_get','P') IS NULL
BEGIN
    PRINT 'ABORT (376): sp_risk_register_list / sp_risk_register_get missing. Run 206/265 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.risk_practice_map','U') IS NULL
   OR OBJECT_ID('grac_practice.risk_dependency_map','U') IS NULL
BEGIN
    PRINT 'ABORT (376): risk_practice_map / risk_dependency_map missing. Run 261/265 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('376_risk_category_multi_procs: prerequisites missing -- see the PRINT messages above. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_risk_category_selection_set
--
-- DELETE-then-INSERT, same reason 314 gives: the caller always sends
-- the complete list, and "what is here now" is the only question.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_category_selection_set
    @organization_id     BIGINT,
    @risk_analysis_id    BIGINT        = NULL,
    @risk_register_id    BIGINT        = NULL,
    @risk_category_ids   NVARCHAR(MAX) = NULL,   -- comma separated
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 56755, 'sp_risk_category_selection_set: organization_id is required.', 1;
    IF @risk_analysis_id IS NULL AND @risk_register_id IS NULL
        THROW 56756, 'sp_risk_category_selection_set: risk_analysis_id or risk_register_id is required.', 1;

    DECLARE @c TABLE(risk_category_id BIGINT PRIMARY KEY);

    -- Visible = belongs to this tenant. risk_category_master has no
    -- shared rows (204), so there is no "OR organization_id IS NULL"
    -- branch here the way 314's risk-type check needs.
    INSERT INTO @c(risk_category_id)
    SELECT DISTINCT m.risk_category_id
      FROM STRING_SPLIT(ISNULL(@risk_category_ids, N''), ',') s
      JOIN grac_practice.risk_category_master m
        ON m.risk_category_id = TRY_CAST(LTRIM(RTRIM(s.value)) AS BIGINT)
     WHERE LTRIM(RTRIM(s.value)) <> N''
       AND m.status = N'Active'
       AND m.organization_id = @organization_id;

    -- THE REQUIRED RULE. After validation, not before -- see the header.
    IF NOT EXISTS (SELECT 1 FROM @c)
        THROW 56757, 'sp_risk_category_selection_set: at least one risk category is required.', 1;

    BEGIN TRY
        BEGIN TRAN;

        IF @risk_analysis_id IS NOT NULL
        BEGIN
            DELETE FROM grac_practice.risk_analysis_risk_category
             WHERE risk_analysis_id = @risk_analysis_id;

            INSERT INTO grac_practice.risk_analysis_risk_category
                (risk_analysis_id, risk_category_id, entered_by)
            SELECT @risk_analysis_id, risk_category_id, @caller_display_name FROM @c;
        END

        IF @risk_register_id IS NOT NULL
        BEGIN
            DELETE FROM grac_practice.risk_register_risk_category
             WHERE risk_register_id = @risk_register_id;

            INSERT INTO grac_practice.risk_register_risk_category
                (risk_register_id, risk_category_id, entered_by)
            SELECT @risk_register_id, risk_category_id, @caller_display_name FROM @c;
        END

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT (SELECT COUNT(*) FROM @c) AS RiskCategoryCount;
END;
GO

-- =====================================================================
-- 2. sp_risk_category_selection_get
--
-- The chips for one risk, read from the REGISTER link table -- the
-- current answer, which is what an edit form needs. Falls back to the
-- newest analysis version's set when the register set is empty, exactly
-- as 314's sp_risk_type_selection_get does and for the same three
-- reasons (see its header): the second of the caller's two writes
-- failing, a risk registered by a path not yet taught the link tables,
-- or a register row cleared by something else.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_category_selection_get
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56758, 'sp_risk_category_selection_get: risk_register_id is required.', 1;

    DECLARE @has_register BIT =
        CASE WHEN EXISTS (SELECT 1 FROM grac_practice.risk_register_risk_category
                           WHERE risk_register_id = @risk_register_id)
             THEN 1 ELSE 0 END;

    IF @has_register = 1
    BEGIN
        SELECT m.risk_category_id AS RiskCategoryId,
               m.category_code    AS CategoryCode,
               m.category_name    AS CategoryName,
               m.display_order    AS DisplayOrder,
               CAST(0 AS BIT)     AS FromAnalysisFallback
          FROM grac_practice.risk_register_risk_category x
          JOIN grac_practice.risk_category_master m
            ON m.risk_category_id = x.risk_category_id
         WHERE x.risk_register_id = @risk_register_id
         ORDER BY m.display_order, m.category_name;
        RETURN;
    END

    DECLARE @analysis_id BIGINT =
        (SELECT TOP 1 a.risk_analysis_id
           FROM grac_practice.risk_analysis a
          WHERE a.risk_register_id = @risk_register_id
          ORDER BY a.is_current DESC, a.analysis_version DESC);

    SELECT m.risk_category_id AS RiskCategoryId,
           m.category_code    AS CategoryCode,
           m.category_name    AS CategoryName,
           m.display_order    AS DisplayOrder,
           CAST(1 AS BIT)     AS FromAnalysisFallback
      FROM grac_practice.risk_analysis_risk_category x
      JOIN grac_practice.risk_category_master m
        ON m.risk_category_id = x.risk_category_id
     WHERE x.risk_analysis_id = @analysis_id
     ORDER BY m.display_order, m.category_name;
END;
GO

-- =====================================================================
-- 3. sp_risk_scoring_options_get -- RE-ISSUED from 206's exact body.
--    Only change: the Category result set gains RiskCategoryId, so the
--    form's multi-select combo can carry the id the new selection
--    procedures above key on, alongside the code/name every existing
--    reader (the single-select filters, sp_risk_register_assess's
--    legacy scalar) still uses unchanged.
-- =====================================================================
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

    -- 376: risk_category_id added, additive. Every existing consumer
    -- reads CategoryCode/CategoryName by name and is unaffected.
    SELECT risk_category_id AS RiskCategoryId,
           category_code    AS CategoryCode,
           category_name    AS CategoryName,
           description      AS Description
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
PRINT '376: sp_risk_scoring_options_get Category result set now also returns RiskCategoryId.';
GO

-- =====================================================================
-- 4. sp_risk_register_list -- RE-ISSUED from 265's exact body. Only
--    change: one new correlated-subquery column, RiskCategoryNames,
--    added in the exact same style as the MappedPracticeCount /
--    MappedDependencyCount columns already in this SELECT list.
-- =====================================================================
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
    -- NEW in 264. All default to NULL = "no opinion".
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
        -- ---- 216 ----------------------------------------------------
        r.analysis_pending      AS AnalysisPending,
        r.threat_name           AS ThreatName,
        r.vulnerability_name    AS VulnerabilityName,
        r.business_function_name AS BusinessFunctionName,
        -- ---- 258 ----------------------------------------------------
        r.residual_likelihood_name AS ResidualLikelihoodName,
        r.residual_impact_name     AS ResidualImpactName,
        r.residual_rating_code     AS ResidualRatingCode,
        r.residual_rating_name     AS ResidualRatingName,
        r.residual_rating_score    AS ResidualRatingScore,
        r.residual_assessed_dt     AS ResidualAssessedOn,
        r.residual_pending         AS ResidualPending,
        -- ---- 261 / 263 / 264 ----------------------------------------
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
        -- Counts for the mapping badges. Correlated subqueries in the
        -- SELECT list, not aggregates over a join -- a join would
        -- multiply the register rows and every score in the row would
        -- have to be wrapped in an aggregate to survive it.
        (SELECT COUNT(*) FROM grac_practice.risk_practice_map pm
          WHERE pm.risk_register_id = r.risk_register_id) AS MappedPracticeCount,
        (SELECT COUNT(*) FROM grac_practice.risk_dependency_map am
          WHERE am.risk_register_id = r.risk_register_id) AS MappedDependencyCount,
        -- 376: every category currently mapped to this risk, comma
        -- separated in the master's own display order -- the same order
        -- the analyst ticked them in on the Analysis form. NULL when the
        -- risk has no rows in risk_register_risk_category yet (a risk
        -- registered before 375's backfill matched nothing, or one whose
        -- code has since been retired) -- the caller falls back to
        -- RiskCategoryName, the legacy scalar, in that case.
        (SELECT STRING_AGG(cm.category_name, N', ') WITHIN GROUP (ORDER BY cm.display_order, cm.category_name)
           FROM grac_practice.risk_register_risk_category rc
           JOIN grac_practice.risk_category_master cm ON cm.risk_category_id = rc.risk_category_id
          WHERE rc.risk_register_id = r.risk_register_id) AS RiskCategoryNames,
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
PRINT '376: sp_risk_register_list now also returns RiskCategoryNames.';
GO

-- =====================================================================
-- 5. sp_risk_register_get -- RE-ISSUED from 265's exact body. Same one
--    additive column as sp_risk_register_list above, same reason.
-- =====================================================================
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
          WHERE am.risk_register_id = r.risk_register_id) AS MappedDependencyCount,
        -- 376: same additive column as sp_risk_register_list, same
        -- reason -- see that procedure's comment above.
        (SELECT STRING_AGG(cm.category_name, N', ') WITHIN GROUP (ORDER BY cm.display_order, cm.category_name)
           FROM grac_practice.risk_register_risk_category rc
           JOIN grac_practice.risk_category_master cm ON cm.risk_category_id = rc.risk_category_id
          WHERE rc.risk_register_id = r.risk_register_id) AS RiskCategoryNames
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
PRINT '376: sp_risk_register_get now also returns RiskCategoryNames.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '376-a sp_risk_category_selection_set exists' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_category_selection_set','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '376-b sp_risk_category_selection_get exists',
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_category_selection_get','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '376-c the required rule (56757) is in the set proc',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_category_selection_set'))
                 LIKE '%56757%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '376-d ids are validated against this tenant only (no shared-row branch)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_category_selection_set'))
                 LIKE '%m.organization_id = @organization_id%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '376-e the set proc writes BOTH link tables',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_category_selection_set'))
                 LIKE '%risk_analysis_risk_category%'
            AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_category_selection_set'))
                 LIKE '%risk_register_risk_category%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '376-f the get proc falls back to the analysis set',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_category_selection_get'))
                 LIKE '%FromAnalysisFallback%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '376-g sp_risk_scoring_options_get now projects RiskCategoryId',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_scoring_options_get'))
                 LIKE '%risk_category_id AS RiskCategoryId%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '376-h sp_risk_register_list now projects RiskCategoryNames',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_list'))
                 LIKE '%AS RiskCategoryNames%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '376-i sp_risk_register_get now projects RiskCategoryNames',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_get'))
                 LIKE '%AS RiskCategoryNames%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '376-j sp_risk_register_list still projects MappedDependencyCount (265 regression check)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_list'))
                 LIKE '%AS MappedDependencyCount%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '376-k sp_risk_register_get still projects ResidualAssessedByName (265 regression check)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_get'))
                 LIKE '%AS ResidualAssessedByName%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- 376 must not have touched the assess path. This is the whole point of
-- there being no wrapper -- see the header, and 314's own -h check.
SELECT '376-l sp_risk_register_assess was NOT re-issued here',
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_register_assess','P') IS NOT NULL
            THEN 'PASS' ELSE 'CHECK -- it should still exist, untouched' END;

PRINT '';
PRINT '--- Diagnostic: categories the multi-select will show, in the order it';
PRINT '    will show them (one organisation, the first that has any registered) ---';
DECLARE @sample_org BIGINT = (SELECT TOP 1 organization_id FROM grac_practice.risk_category_master ORDER BY organization_id);
IF @sample_org IS NOT NULL
    SELECT risk_category_id AS RiskCategoryId, category_code AS CategoryCode,
           category_name AS CategoryName, display_order AS DisplayOrder
      FROM grac_practice.risk_category_master
     WHERE organization_id = @sample_org AND status = N'Active'
     ORDER BY display_order, category_name;

PRINT '';
PRINT '376 complete. The list / set / get procedures exist, and';
PRINT 'sp_risk_scoring_options_get / sp_risk_register_list / sp_risk_register_get';
PRINT 'are re-issued with additive columns only. sp_risk_register_assess is';
PRINT 'UNCHANGED -- the caller makes two calls: assess as before (still sending';
PRINT 'one risk_category_code), then sp_risk_category_selection_set with the';
PRINT 'full id list. Next: the API service + controller, then the form.';
GO

SET NOEXEC OFF;
GO
