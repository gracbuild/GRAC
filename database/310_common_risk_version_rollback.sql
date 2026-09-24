-- =====================================================================
-- 310 Risk Centre -- ONE COMMON RISK VERSION -- ROLLBACK
--
-- Undoes what 310 added, in dependency order:
--   1. sp_risk_acceptance_save  -> restored to 298's body (no increment)
--   2. sp_risk_register_get     -> restored to 292's body (no RiskVersion)
--   3. risk_register.risk_version + its CHECK constraint  -> dropped
--
-- WHAT THIS DELETES, SAID PLAINLY
--   risk_version is the only place the common version is stored, so
--   dropping the column discards it. That is cheap to lose and cheap to
--   rebuild: 310's back-fill derives it from the RiskAccepted rows in
--   risk_register_history, which this script does not touch, so
--   re-running 310 reproduces exactly the same numbers.
--
--   Setting @keep = 1 in section 3 below restores both PROCEDURES and
--   leaves the column and its values in place. Use that if anything
--   outside the Risk Centre has started reading risk_version.
--
--   NOTHING in the BRD 20 audit trail is affected either way.
--   analysis_version, residual_version, risk_analysis,
--   risk_residual_analysis and risk_register_history are not written by
--   310 and are not written here.
--
-- Re-runnable: yes.
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN
    PRINT 'ABORT (310 rollback): risk_register missing. Nothing to undo.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. sp_risk_acceptance_save -- 298's body, verbatim. No increment.
-- ---------------------------------------------------------------------
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
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
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
           N'Accepted'       AS StatusCode;
END;
GO

-- ---------------------------------------------------------------------
-- 2. sp_risk_register_get -- 292's body, verbatim. No RiskVersion.
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 3. The column. Dropped LAST -- both procedures above have to stop
--    referring to it first, or sp_risk_register_get would be left
--    selecting a column that no longer exists.
--
--    The DEFAULT and the CHECK are named constraints, so they are
--    dropped by name rather than discovered -- and they must go before
--    the column, which SQL Server will otherwise refuse.
-- ---------------------------------------------------------------------
-- THE ONE KNOB, AND IT LIVES IN THE BATCH THAT READS IT.
--
-- A variable cannot cross a GO. An earlier draft of this file declared
-- @KeepColumn in the header batch and re-declared it here, which meant
-- setting the header one changed nothing and the column was dropped
-- anyway -- a switch that looks like it works and does not.
--
-- Set this to 1 to keep risk_register.risk_version and its values while
-- still restoring both procedures.
DECLARE @keep BIT = 0;

IF @keep = 0 AND COL_LENGTH('grac_practice.risk_register','risk_version') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_risk_register_risk_version')
    BEGIN
        ALTER TABLE grac_practice.risk_register
            DROP CONSTRAINT ck_pm_risk_register_risk_version;
        PRINT '310 rollback: ck_pm_risk_register_risk_version dropped.';
    END

    IF EXISTS (SELECT 1 FROM sys.default_constraints
                WHERE name = 'df_pm_risk_register_risk_version')
    BEGIN
        ALTER TABLE grac_practice.risk_register
            DROP CONSTRAINT df_pm_risk_register_risk_version;
        PRINT '310 rollback: df_pm_risk_register_risk_version dropped.';
    END

    ALTER TABLE grac_practice.risk_register DROP COLUMN risk_version;
    PRINT '310 rollback: risk_register.risk_version dropped.';
END
ELSE IF @keep = 1
    PRINT '310 rollback: risk_version KEPT (@keep = 1). Procedures restored.';
ELSE
    PRINT '310 rollback: risk_register.risk_version already absent.';
GO

-- ---------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------
SELECT '310r-a sp_risk_acceptance_save no longer increments' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_acceptance_save'))
                 NOT LIKE '%risk_version            = risk_version + 1%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '310r-b sp_risk_register_get no longer returns RiskVersion',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_get'))
                 NOT LIKE '%AS RiskVersion%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '310r-c 292 AcceptedByRoleNames survived the restore',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_get'))
                 LIKE '%AS AcceptedByRoleNames%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '310r-d 298 @suppress_result survived the restore',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_acceptance_save'))
                 LIKE '%@suppress_result%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '310r-e acceptance history is intact',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.risk_register_history
                          WHERE action_code = N'RiskAccepted')
                 OR NOT EXISTS (SELECT 1 FROM grac_practice.risk_register
                                 WHERE accepted_dt IS NOT NULL)
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '310 rollback complete. Re-running 310 rebuilds the same version numbers';
PRINT 'from the RiskAccepted history rows, which were never touched.';
GO

SET NOEXEC OFF;
GO
