-- =====================================================================
-- 310 Risk Centre -- ONE COMMON RISK VERSION
--
-- WHAT THIS CHANGES
--   A risk gets a single version of its own, on risk_register, and the
--   ONLY thing that moves it is a completed acceptance:
--
--       registered            -> version 1
--       acceptance 1 saved    -> version 2
--       acceptance 2 saved    -> version 3
--
--   Inherent analysis, residual analysis and review do NOT touch it.
--
-- WHAT THIS DOES NOT CHANGE, AND WHY THAT MATTERS
--   risk_analysis.analysis_version and
--   risk_residual_analysis.residual_version are UNTOUCHED. They are not
--   competing risk versions -- they are the per-table history sequence
--   BRD 20 requires ("...must not be overwritten without retaining
--   historical versions"). Every save still writes a new row with the
--   next number, sp_risk_analysis_save and
--   sp_risk_residual_analysis_save are not re-issued by this file, and
--   the Analysis / Residual history tables still identify their retained
--   rows by that number.
--
--   What changes is that nothing calls those numbers "the risk version"
--   any more. The UI stops showing them outside those two history
--   tables; see docs/risk-centre.md.
--
-- BACK-FILL -- DERIVED FROM THE AUDIT TRAIL, NOT GUESSED
--   sp_risk_acceptance_save has written a 'RiskAccepted' row to
--   risk_register_history on every acceptance since 264. So:
--
--       risk_version = 1 + COUNT(history rows WHERE action_code =
--                                N'RiskAccepted')
--
--   A risk never accepted is version 1. One accepted twice is version 3.
--   Nothing is overwritten: the column is new, the history rows it is
--   counted from are read-only here, and no existing column is written.
--
-- ADDITIVE, PLUS TWO PROCEDURE RE-ISSUES
--   1. risk_register.risk_version      (new column, guarded, defaulted)
--   2. sp_risk_acceptance_save         re-issued from 298's body with
--                                      the increment injected
--   3. sp_risk_register_get            re-issued from 292's body with
--                                      RiskVersion injected
--
--   Both bodies were EXTRACTED from those files and had the additions
--   injected programmatically, never retyped -- the technique 292's own
--   header sets out, and for its reason: these are 140-line procedures
--   and a transcription slip would silently drop a column the UI reads
--   by name.
--
-- NOT RE-ISSUED ON PURPOSE
--   sp_risk_analysis_save (216), sp_risk_residual_analysis_save (263),
--   sp_risk_review_perform (299), sp_risk_register_list (264).
--   The register LIST does not show a version anywhere, so widening it
--   would be a re-issue with no reader -- and on this database that is a
--   risk taken for nothing.
--
-- BULK ACCEPT IS COVERED FOR FREE
--   sp_risk_bulk_accept and sp_risk_bulk_review both compose
--   sp_risk_acceptance_save (see 295, 298), so twelve risks accepted
--   together each advance by exactly one version, through the one
--   increment below. No second implementation.
--
-- ERROR CODES: none added.
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
-- Idempotent: guarded ALTER, one-shot guarded back-fill, CREATE OR ALTER
-- procedures. Safe to re-run -- the back-fill will not run twice.
--
-- DEPENDS ON: 205 (risk_register, risk_register_history),
--             264 (accepted_dt, the RiskAccepted history action),
--             292 (the sp_risk_register_get body re-issued here),
--             298 (the sp_risk_acceptance_save body re-issued here).
-- Rollback:   database/310_common_risk_version_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

-- ---------------------------------------------------------------------
-- Prerequisites. COLUMNS as well as objects: both procedures below are
-- re-issued bodies that read columns added by 261/264/292/293, and on a
-- database missing one, CREATE OR ALTER fails with Msg 207 while the
-- PRINTs after it still run -- a script that looks half-applied and
-- changed nothing.
-- ---------------------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (310): schema grac_practice missing. Run base scripts first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
   OR OBJECT_ID('grac_practice.risk_register_history','U') IS NULL
BEGIN
    PRINT 'ABORT (310): risk_register / risk_register_history missing. Run 205 first.';
    SET @prereqs_ok = 0;
END

IF COL_LENGTH('grac_practice.risk_register','accepted_dt') IS NULL
   OR COL_LENGTH('grac_practice.risk_register','next_review_date') IS NULL
   OR COL_LENGTH('grac_practice.risk_register','review_count') IS NULL
BEGIN
    PRINT 'ABORT (310): risk_register acceptance columns missing. Run 261 and 264 first.';
    SET @prereqs_ok = 0;
END

IF COL_LENGTH('grac_practice.risk_register','review_frequency_id') IS NULL
BEGIN
    PRINT 'ABORT (310): risk_register.review_frequency_id missing. Run 293 first.';
    PRINT '             The sp_risk_acceptance_save body re-issued here writes it.';
    SET @prereqs_ok = 0;
END

IF COL_LENGTH('grac_practice.risk_register','residual_analysis_id') IS NULL
   OR COL_LENGTH('grac_practice.risk_register','treatment_decided_by_employee_id') IS NULL
BEGIN
    PRINT 'ABORT (310): risk_register residual / treatment columns missing. Run 258 and 263 first.';
    PRINT '             The sp_risk_register_get body re-issued here reads them.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.fn_employee_role_names','FN') IS NULL
BEGIN
    PRINT 'ABORT (310): fn_employee_role_names missing. Run 291 first.';
    PRINT '             sp_risk_register_get returns AcceptedByRoleNames from it (292).';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage','V') IS NULL
BEGIN
    PRINT 'ABORT (310): vw_pm_risk_workflow_stage missing. Run 264 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.risk_practice_map','U') IS NULL
BEGIN
    PRINT 'ABORT (310): risk_practice_map missing. Run 261 first.';
    PRINT '             sp_risk_register_get counts it as MappedPracticeCount.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('310_common_risk_version: prerequisites missing -- see the PRINT messages above. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. risk_register.risk_version
--
-- NOT NULL with a default of 1, so every existing row is immediately
-- valid and every future INSERT that does not name the column (every
-- caller today) opens at version 1 -- which is the rule.
-- =====================================================================
IF COL_LENGTH('grac_practice.risk_register','risk_version') IS NULL
BEGIN
    ALTER TABLE grac_practice.risk_register
        ADD risk_version INT NOT NULL
            CONSTRAINT df_pm_risk_register_risk_version DEFAULT 1;
    PRINT '310: risk_register.risk_version added (default 1).';
END
ELSE
    PRINT '310: risk_register.risk_version already present -- left alone.';
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_risk_register_risk_version')
BEGIN
    ALTER TABLE grac_practice.risk_register
        ADD CONSTRAINT ck_pm_risk_register_risk_version CHECK (risk_version >= 1);
    PRINT '310: ck_pm_risk_register_risk_version added.';
END
GO

-- =====================================================================
-- 2. Back-fill, ONCE.
--
-- Guarded on "every row is still at the default", so re-running this
-- file cannot double-count a risk whose version has since moved. A
-- database where any risk is already past 1 has been back-filled (or
-- accepted since), and the count would then be added on top of it.
-- =====================================================================
IF COL_LENGTH('grac_practice.risk_register','risk_version') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM grac_practice.risk_register WHERE risk_version > 1)
    BEGIN
        UPDATE r
           SET r.risk_version = 1 + h.Accepted
          FROM grac_practice.risk_register r
         CROSS APPLY (SELECT COUNT(*) AS Accepted
                        FROM grac_practice.risk_register_history x
                       WHERE x.risk_register_id = r.risk_register_id
                         AND x.action_code = N'RiskAccepted') AS h
         WHERE h.Accepted > 0;

        PRINT '310: back-fill applied -- risk_version = 1 + prior RiskAccepted history rows.';
    END
    ELSE
        PRINT '310: back-fill SKIPPED -- at least one risk is already past version 1.';
END
GO

-- =====================================================================
-- 3. sp_risk_acceptance_save -- THE ONE INCREMENT POINT
--
-- 298's body, with four additions and nothing else:
--   * DECLARE @new_version
--   * risk_version = risk_version + 1 in the UPDATE
--   * read the new value back, and name it in the RiskAccepted history
--     remark so the audit trail says which version the acceptance made
--   * RiskVersion on the result set
--
-- Everything else -- the 56600-56608 validations, @suppress_result, the
-- TRY/CATCH with its ROLLBACK, the 293 review_frequency_id write -- is
-- 298's, byte for byte.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_acceptance_save
    @risk_register_id        BIGINT,
    @next_review_date        DATE,
    @accepted_by_employee_id BIGINT        = NULL,
    @accepted_date           DATE          = NULL,   -- NULL = today
    @acceptance_note         NVARCHAR(MAX) = NULL,
    @actor_employee_id       BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N'system',
    -- NEW in 293. NULL = not recorded, which is what every
    -- pre-293 caller sends and what a Custom / Event-driven
    -- acceptance legitimately has.
    @review_frequency_id     INT           = NULL,
    -- NEW in 298. The same device sp_risk_analysis_save (206) and
    -- sp_risk_treatment_option_set (263) already carry.
    --
    -- This procedure is called BOTH directly by the API -- which needs
    -- the result set -- and from inside sp_risk_bulk_review and
    -- sp_risk_bulk_accept, which return reports of their own. Without
    -- this, the inner call's SELECT becomes a result set of the OUTER
    -- procedure and the caller reading "the first result set" gets an
    -- acceptance row where it expected an Outcome column.
    --
    -- 294 and 295 tried to solve that with INSERT ... EXEC. That was
    -- wrong: SQL Server forbids a procedure called inside INSERT ... EXEC
    -- from issuing ROLLBACK, and the CATCH below does exactly that -- so
    -- every genuine refusal (56604-56608) was replaced by "Cannot use the
    -- ROLLBACK statement within an INSERT-EXEC statement", destroying the
    -- reason the caller needed to report.
    @suppress_result         BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56600, 'sp_risk_acceptance_save: risk_register_id is required.', 1;

    -- Validation case 10. See the header for why this is a THROW.
    IF @next_review_date IS NULL
        THROW 56601, 'sp_risk_acceptance_save: a next review date is required. Without one this risk would never return for review.', 1;

    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    IF @next_review_date <= @today
        THROW 56602, 'sp_risk_acceptance_save: the next review date must be in the future.', 1;

    DECLARE @org_id BIGINT, @status NVARCHAR(30), @analysis_pending BIT,
            @option_code NVARCHAR(30), @residual_pending BIT,
            @owner BIGINT, @risk_number NVARCHAR(60);

    SELECT @org_id           = organization_id,
           @status           = status_code,
           @analysis_pending = analysis_pending,
           @option_code      = treatment_option_code,
           @residual_pending = residual_pending,
           @owner            = risk_owner_employee_id,
           @risk_number      = risk_number
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56603, 'sp_risk_acceptance_save: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56604, 'sp_risk_acceptance_save: this risk is closed or retired -- reopen it before accepting it.', 1;

    -- Accepting a risk nobody has scored is accepting an unknown
    -- quantity. section 19's whole apparatus exists to make the rating
    -- trustworthy before decisions rest on it.
    IF ISNULL(@analysis_pending, 1) = 1
        THROW 56605, 'sp_risk_acceptance_save: complete the risk analysis before accepting this risk.', 1;

    -- A treatment decision must exist. Acceptance is the endpoint of two
    -- routes -- Tolerate, or treatment-then-residual -- and a risk that
    -- has taken neither has not reached it.
    IF @option_code IS NULL
        THROW 56606, 'sp_risk_acceptance_save: choose a treatment option before accepting this risk.', 1;

    DECLARE @accept_by BIGINT = COALESCE(@accepted_by_employee_id, @owner, @actor_employee_id);
    DECLARE @accept_name NVARCHAR(240) = NULL;

    IF @accept_by IS NOT NULL
    BEGIN
        DECLARE @emp_org BIGINT;
        SELECT @emp_org = organization_id, @accept_name = employee_name
          FROM grac_practice.organization_employee
         WHERE employee_id = @accept_by;

        IF @emp_org IS NULL
            THROW 56607, 'sp_risk_acceptance_save: the accepting employee was not found.', 1;
        IF @emp_org <> @org_id
            THROW 56608, 'sp_risk_acceptance_save: the accepting employee belongs to a different organisation.', 1;
    END

    DECLARE @new_version INT;

    DECLARE @accepted_on DATETIME2 =
        CASE WHEN @accepted_date IS NULL THEN SYSUTCDATETIME()
             ELSE CAST(@accepted_date AS DATETIME2) END;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_register
           SET accepted_by_employee_id = @accept_by,
               accepted_by_name        = @accept_name,
               accepted_dt             = @accepted_on,
               acceptance_note         = @acceptance_note,
               next_review_date        = @next_review_date,
               -- NEW in 293. What the date above was derived
               -- from; the date itself remains the authority.
               review_frequency_id     = @review_frequency_id,
               status_code             = N'Accepted',
               -- MIGRATION 310. THE ONLY PLACE THE RISK VERSION MOVES.
               -- Inside the same transaction as the acceptance itself,
               -- so a rolled-back acceptance cannot leave the version
               -- advanced past it.
               risk_version            = risk_version + 1,
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id;

        -- Read back rather than computed: the UPDATE above is the
        -- authority, and re-deriving the number here would be a second
        -- definition of it.
        SELECT @new_version = risk_version
          FROM grac_practice.risk_register
         WHERE risk_register_id = @risk_register_id;

        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_register_id, N'RiskAccepted', @status, N'Accepted',
             CONCAT(N'Risk accepted by ', ISNULL(@accept_name, N'(unnamed)'),
                    N' on ', CONVERT(NVARCHAR(10), @accepted_on, 23),
                    N'. Next review ', CONVERT(NVARCHAR(10), @next_review_date, 23), N'.',
                    CASE WHEN @option_code = N'Tolerate'
                         THEN N' Route: Tolerate / Accept (no treatment work).'
                         WHEN ISNULL(@residual_pending, 1) = 0
                         THEN N' Route: treated, residual assessed.'
                         ELSE N' Route: treated.' END,
                    CONCAT(N' Risk version ', CAST(@new_version AS NVARCHAR(12)), N'.'),
                    CASE WHEN @acceptance_note IS NULL THEN N''
                         ELSE CONCAT(N' ', @acceptance_note) END),
             @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    IF ISNULL(@suppress_result, 0) = 1
        RETURN;

    SELECT @risk_register_id AS RiskRegisterId,
           @risk_number      AS RiskNumber,
           @accept_by        AS AcceptedByEmployeeId,
           @accept_name      AS AcceptedByName,
           @accepted_on      AS AcceptedOn,
           @next_review_date AS NextReviewDate,
           @new_version      AS RiskVersion,
           N'Accepted'       AS StatusCode;
END;
GO

-- =====================================================================
-- 4. sp_risk_register_get -- return the common version
--
-- 292's body with ONE column injected. Every screen that reads a risk
-- reads this procedure, so this is the only place the new version has to
-- be surfaced for the register, the View Risk page, the residual page
-- and the acceptance page alike.
--
-- MappedPracticeCount was already here (265): "Linked Practice: 3
-- Practices" needed no schema or procedure change at all, only a UI that
-- reads the count the procedure has been returning all along.
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
-- 5. Verification. PASS/FAIL, so a green run is provable rather than
--    assumed.
-- =====================================================================
SELECT '310-a risk_version column exists' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.risk_register','risk_version') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '310-b every risk is at version 1 or higher',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.risk_register WHERE risk_version < 1)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '310-c sp_risk_acceptance_save increments risk_version',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_acceptance_save'))
                 LIKE '%risk_version            = risk_version + 1%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '310-d sp_risk_register_get returns RiskVersion',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_get'))
                 LIKE '%AS RiskVersion%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '310-e sp_risk_register_get still returns AcceptedByRoleNames (292)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_get'))
                 LIKE '%AS AcceptedByRoleNames%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '310-f sp_risk_register_get still returns MappedPracticeCount',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_get'))
                 LIKE '%AS MappedPracticeCount%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '310-g sp_risk_acceptance_save kept @suppress_result (298)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_acceptance_save'))
                 LIKE '%@suppress_result%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- The point of the whole migration: the two history sequences are still
-- generated by their own procedures, which this file did not touch.
SELECT '310-h analysis_version still assigned by its own proc',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_analysis_save'))
                 LIKE '%MAX(analysis_version)%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '310-i residual_version still assigned by its own proc',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_residual_analysis_save'))
                 LIKE '%MAX(residual_version)%'
            THEN 'PASS' ELSE 'FAIL' END;

-- What the back-fill produced, so the numbers can be eyeballed against
-- the acceptance history they came from.
SELECT r.risk_register_id                AS RiskId,
       r.risk_number                     AS RiskNumber,
       r.risk_version                     AS RiskVersion,
       (SELECT COUNT(*) FROM grac_practice.risk_register_history x
         WHERE x.risk_register_id = r.risk_register_id
           AND x.action_code = N'RiskAccepted') AS PriorAcceptances,
       r.status_code                      AS StatusCode
  FROM grac_practice.risk_register r
 ORDER BY r.risk_version DESC, r.risk_register_id;

PRINT '';
PRINT '310 complete. The risk carries ONE version, and only an acceptance moves it.';
PRINT 'analysis_version and residual_version are untouched -- they remain the';
PRINT 'per-table BRD 20 history sequences and are still shown in the two';
PRINT 'history tables. Next: rebuild the API and Web tiers.';
GO

SET NOEXEC OFF;
GO
