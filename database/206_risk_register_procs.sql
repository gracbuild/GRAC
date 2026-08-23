-- =====================================================================
-- 206 Risk Centre — Initial Risk Analysis + Risk Register procedures
--     (Risk Candidate Analysis and Risk Register BRD §7, §8, §9, §10,
--      §11, §12, §15, §17, §24)
--
-- HOW THE BRD'S "SAME METHODOLOGY, TWO ROUTES" RULE IS MADE TRUE HERE
-- ------------------------------------------------------------------
-- §12: "The Custom Risk workflow shall use the same underlying risk
-- analysis framework as stream-originated candidates ... The only
-- difference shall be the entry route."
--
-- A rule like that is not kept by writing two careful procedures. It is
-- kept by having ONE procedure. So:
--
--   sp_risk_analysis_save    writes the analysis for BOTH routes
--   sp_risk_register_insert  writes the register row for BOTH routes,
--                            and owns the mandatory-field gate
--
--   Route A  sp_risk_analysis_save -> sp_risk_candidate_register
--                                       -> sp_risk_register_insert
--   Route B  sp_risk_custom_create -> sp_risk_analysis_save
--                                       -> sp_risk_register_insert
--
-- Neither route can score differently, use a different scale, or skip a
-- mandatory field, because neither route contains the code that would
-- let it. §24 rules 1 and 4 are structural, not procedural.
--
-- CONTENTS
--   1.  sp_risk_scoring_options_get       org's scale + categories + sources
--   2.  sp_risk_rating_resolve            (likelihood, impact) -> rating
--   3.  sp_risk_analysis_save             §7.1, versioned (§20), both routes
--   4.  sp_risk_analysis_get              current or named version
--   5.  sp_risk_analysis_history          §20 version list
--   6.  sp_risk_duplicate_check           §15
--   7.  sp_risk_candidate_assign          §6.2 analyst, -> UnderAnalysis
--   8.  sp_risk_candidate_clarify         §8C
--   9.  sp_risk_candidate_close_duplicate §15
--   10. sp_risk_register_insert           SHARED registration writer
--   11. sp_risk_candidate_register        §8A, Route A
--   12. sp_risk_custom_create             §4B / §11, Route B
--   13. sp_risk_register_list             §9, §23
--   14. sp_risk_register_get              §9.1 + §10 traceability
--   15. sp_risk_register_status_set       §17
--   16. sp_risk_register_owner_set        §18 Risk Owner
--   17. sp_risk_candidate_list  REWRITE   source-aware (was gap-only)
--   18. sp_risk_candidate_get   REWRITE   source-aware (was gap-only)
--   19. sp_risk_candidate_reject REWRITE  accepts the §16 statuses
--   20. sp_risk_candidate_withdraw REWRITE accepts the §16 statuses
--
-- 17-20 are STRICT SUPERSETS of their 170 definitions: same names, same
-- parameters in the same order, every original result-set column still
-- present. No existing caller changes.
--
-- WHAT IS DELIBERATELY NOT HERE — see docs/risk-centre.md
--   * The configurable approval GATE (§19). The outcome columns exist on
--     risk_analysis; the org-level "is approval required?" switch is
--     Phase B.
--   * Automatic treatment-task creation on registration. §22 is explicit
--     that "Risk registration itself shall not automatically imply that a
--     treatment task exists", so no proc here calls Task Centre. See the
--     conflict note on sp_risk_candidate_register.
--   * Notifications (§21) and dashboard aggregates (§23).
--
-- ERROR CODE RANGE: 56040-56199
-- Rollback: database/206_risk_register_procs_rollback.sql
-- Depends:  204_risk_scoring_masters.sql, 205_risk_register_schema.sql
-- Next:     207_risk_centre_source_wiring.sql
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.risk_analysis','U') IS NULL
BEGIN PRINT 'ABORT (206): risk_analysis missing — run 205_risk_register_schema.sql first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN PRINT 'ABORT (206): risk_register missing — run 205_risk_register_schema.sql first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.risk_matrix_cell','U') IS NULL
BEGIN PRINT 'ABORT (206): risk_matrix_cell missing — run 204_risk_scoring_masters.sql first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('206_risk_register_procs: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_risk_scoring_options_get   (BRD §7, §12, §13)
--
-- Everything the analysis form needs, in one round trip. Five result
-- sets in a fixed order — the API reads them positionally:
--   0 Likelihood   1 Impact   2 Categories   3 Sources   4 Matrix
--
-- If the organisation has no scale yet (created after 204 ran), it is
-- seeded on demand rather than returning empty lists and an unusable
-- form.
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

-- =====================================================================
-- 2. sp_risk_rating_resolve   (BRD §7.1 "Inherent Risk Rating")
--
-- The single place a rating is derived. Output parameters rather than a
-- result set so sp_risk_analysis_save can call it inline.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_rating_resolve
    @organization_id  BIGINT,
    @likelihood_value INT,
    @impact_value     INT,
    @rating_code      NVARCHAR(30)  OUTPUT,
    @rating_name      NVARCHAR(120) OUTPUT,
    @rating_score     INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @rating_code  = NULL;
    SET @rating_name  = NULL;
    SET @rating_score = NULL;

    IF @organization_id IS NULL
        THROW 56041, 'sp_risk_rating_resolve: organization_id is required.', 1;

    -- A partially scored analysis is legal while the analyst is still
    -- working (§7 lists the fields, §8 is where completeness is judged),
    -- so an unscored pair resolves to NULL rather than throwing.
    IF @likelihood_value IS NULL OR @impact_value IS NULL
        RETURN;

    SELECT @rating_code  = rating_code,
           @rating_name  = rating_name,
           @rating_score = rating_score
      FROM grac_practice.risk_matrix_cell
     WHERE organization_id  = @organization_id
       AND likelihood_value = @likelihood_value
       AND impact_value     = @impact_value;

    -- A scored pair with no matrix cell is a configuration error, not a
    -- data error: the organisation offered a level its matrix does not
    -- cover. Fail loudly — silently registering an unrated risk would
    -- breach §9.1.
    IF @rating_code IS NULL
        THROW 56042, 'sp_risk_rating_resolve: no matrix cell for this likelihood/impact pair. Check the organisation''s risk matrix configuration.', 1;
END;
GO

-- =====================================================================
-- 3. sp_risk_analysis_save   (BRD §7, §7.1, §12, §20)
--
-- Writes one NEW version every time. Nothing is overwritten — §20.
--
-- BOTH ROUTES USE THIS PROC:
--   @risk_candidate_id supplied  -> scope 'Candidate' (Route A)
--   @risk_candidate_id NULL      -> scope 'Custom'    (Route B),
--                                   @organization_id then required
--
-- The candidate is moved to UnderAnalysis on first save so §16's status
-- model reflects reality without the analyst having to say so twice.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_analysis_save
    @risk_candidate_id      BIGINT        = NULL,
    @organization_id        BIGINT        = NULL,
    @risk_statement         NVARCHAR(1000),
    @risk_category_code     NVARCHAR(60)  = NULL,
    @risk_description       NVARCHAR(MAX) = NULL,
    @risk_cause             NVARCHAR(MAX) = NULL,
    @potential_consequence  NVARCHAR(MAX) = NULL,
    @existing_controls      NVARCHAR(MAX) = NULL,
    @likelihood_code        NVARCHAR(60)  = NULL,
    @impact_code            NVARCHAR(60)  = NULL,
    @risk_owner_employee_id BIGINT        = NULL,
    @business_unit          NVARCHAR(200) = NULL,
    @process_name           NVARCHAR(200) = NULL,
    @analyst_remarks        NVARCHAR(MAX) = NULL,
    @analysed_by_employee_id BIGINT       = NULL,
    @caller_display_name    NVARCHAR(100) = N'system',
    -- sp_risk_custom_create calls this proc mid-transaction and then
    -- emits its OWN result set. Without this switch the caller would
    -- receive two result sets and a client that reads the first would
    -- get the analysis where it expected the risk. Output parameters
    -- carry everything the internal caller needs, so it passes 1.
    @suppress_result        BIT           = 0,
    @risk_analysis_id       BIGINT        OUTPUT,
    @analysis_version       INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @risk_analysis_id = NULL;
    SET @analysis_version = NULL;

    IF @risk_statement IS NULL OR LEN(LTRIM(RTRIM(@risk_statement))) = 0
        THROW 56050, 'sp_risk_analysis_save: risk_statement is required.', 1;

    DECLARE @scope NVARCHAR(20) =
        CASE WHEN @risk_candidate_id IS NULL THEN N'Custom' ELSE N'Candidate' END;

    -- ---- Resolve the organisation -----------------------------------
    IF @scope = N'Candidate'
    BEGIN
        DECLARE @cand_status NVARCHAR(30);
        SELECT @organization_id = organization_id,
               @cand_status     = status_code
          FROM grac_practice.risk_candidate
         WHERE risk_candidate_id = @risk_candidate_id;

        IF @organization_id IS NULL
            THROW 56051, 'sp_risk_analysis_save: risk candidate not found.', 1;

        -- §8 lets an analyst revise; §16 does not let a closed candidate
        -- be re-analysed. Registered / Rejected / ClosedAsDuplicate /
        -- Withdrawn are terminal.
        IF @cand_status IN (N'Registered', N'Rejected', N'ClosedAsDuplicate', N'Withdrawn')
            THROW 56052, 'sp_risk_analysis_save: this candidate is closed and cannot be re-analysed.', 1;
    END
    ELSE
    BEGIN
        IF @organization_id IS NULL
            THROW 56053, 'sp_risk_analysis_save: organization_id is required for a custom risk analysis.', 1;
        IF NOT EXISTS(SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
            THROW 56054, 'sp_risk_analysis_save: organization not found.', 1;
    END

    -- ---- Resolve the scale (§7, §12 — one scale, both routes) -------
    DECLARE @likelihood_name NVARCHAR(200), @likelihood_value INT,
            @impact_name     NVARCHAR(200), @impact_value     INT;

    IF @likelihood_code IS NOT NULL AND LEN(LTRIM(RTRIM(@likelihood_code))) > 0
    BEGIN
        SELECT @likelihood_name = likelihood_name, @likelihood_value = level_value
          FROM grac_practice.risk_likelihood_master
         WHERE organization_id = @organization_id
           AND likelihood_code = @likelihood_code AND status = N'Active';
        IF @likelihood_value IS NULL
            THROW 56055, 'sp_risk_analysis_save: unknown likelihood_code for this organisation.', 1;
    END

    IF @impact_code IS NOT NULL AND LEN(LTRIM(RTRIM(@impact_code))) > 0
    BEGIN
        SELECT @impact_name = impact_name, @impact_value = level_value
          FROM grac_practice.risk_impact_master
         WHERE organization_id = @organization_id
           AND impact_code = @impact_code AND status = N'Active';
        IF @impact_value IS NULL
            THROW 56056, 'sp_risk_analysis_save: unknown impact_code for this organisation.', 1;
    END

    DECLARE @category_name NVARCHAR(200) = NULL;
    IF @risk_category_code IS NOT NULL AND LEN(LTRIM(RTRIM(@risk_category_code))) > 0
    BEGIN
        SELECT @category_name = category_name
          FROM grac_practice.risk_category_master
         WHERE organization_id = @organization_id
           AND category_code = @risk_category_code AND status = N'Active';
        IF @category_name IS NULL
            THROW 56057, 'sp_risk_analysis_save: unknown risk_category_code for this organisation.', 1;
    END

    DECLARE @rating_code NVARCHAR(30), @rating_name NVARCHAR(120), @rating_score INT;
    EXEC grac_practice.sp_risk_rating_resolve
         @organization_id  = @organization_id,
         @likelihood_value = @likelihood_value,
         @impact_value     = @impact_value,
         @rating_code      = @rating_code  OUTPUT,
         @rating_name      = @rating_name  OUTPUT,
         @rating_score     = @rating_score OUTPUT;

    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    DECLARE @next_version INT = 1;

    BEGIN TRY
        BEGIN TRAN;

        IF @scope = N'Candidate'
        BEGIN
            SELECT @next_version = ISNULL(MAX(analysis_version), 0) + 1
              FROM grac_practice.risk_analysis
             WHERE risk_candidate_id = @risk_candidate_id;

            -- Retire the previous version BEFORE inserting, so the
            -- filtered unique index never sees two current rows.
            UPDATE grac_practice.risk_analysis
               SET is_current = 0,
                   updated_by = @caller_display_name,
                   updated_dt = SYSUTCDATETIME()
             WHERE risk_candidate_id = @risk_candidate_id
               AND is_current = 1;
        END

        INSERT INTO grac_practice.risk_analysis
            (organization_id, analysis_scope_code, risk_candidate_id,
             analysis_version, is_current,
             risk_statement, risk_category_code, risk_category_name,
             risk_description, risk_cause, potential_consequence, existing_controls,
             likelihood_code, likelihood_name, likelihood_value,
             impact_code, impact_name, impact_value,
             inherent_rating_code, inherent_rating_name, inherent_rating_score,
             risk_owner_employee_id, business_unit, process_name, analyst_remarks,
             analysis_dt, analysed_by_employee_id,
             record_status_id, entered_by, entered_dt)
        VALUES
            (@organization_id, @scope, @risk_candidate_id,
             @next_version, 1,
             @risk_statement, @risk_category_code, @category_name,
             @risk_description, @risk_cause, @potential_consequence, @existing_controls,
             @likelihood_code, @likelihood_name, @likelihood_value,
             @impact_code, @impact_name, @impact_value,
             @rating_code, @rating_name, @rating_score,
             @risk_owner_employee_id, @business_unit, @process_name, @analyst_remarks,
             SYSUTCDATETIME(), @analysed_by_employee_id,
             @active_rs, @caller_display_name, SYSUTCDATETIME());

        SET @risk_analysis_id = SCOPE_IDENTITY();
        SET @analysis_version = @next_version;

        -- §16: analysis started -> Under Analysis. Only from the open
        -- statuses; a candidate already AnalysisCompleted stays there
        -- until the analyst decides again.
        IF @scope = N'Candidate'
        BEGIN
            UPDATE grac_practice.risk_candidate
               SET status_code = N'UnderAnalysis',
                   assigned_analyst_employee_id =
                       COALESCE(assigned_analyst_employee_id, @analysed_by_employee_id),
                   updated_by  = @caller_display_name,
                   updated_dt  = SYSUTCDATETIME()
             WHERE risk_candidate_id = @risk_candidate_id
               AND status_code IN (N'Pending', N'ClarificationRequired');

            INSERT INTO grac_practice.risk_candidate_history
                (risk_candidate_id, action_code, from_status_code, to_status_code,
                 remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
            VALUES
                (@risk_candidate_id, N'AnalysisSave', NULL, NULL,
                 CONCAT(N'Analysis v', CAST(@next_version AS NVARCHAR(10)),
                        N' saved. Rating: ', ISNULL(@rating_code, N'(unscored)')),
                 @analysed_by_employee_id, @caller_display_name,
                 @caller_display_name, SYSUTCDATETIME());
        END

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    IF ISNULL(@suppress_result, 0) = 0
        SELECT @risk_analysis_id AS RiskAnalysisId,
               @analysis_version AS AnalysisVersion,
               @rating_code      AS InherentRatingCode,
               @rating_name      AS InherentRatingName,
               @rating_score     AS InherentRatingScore;
END;
GO

-- =====================================================================
-- 4. sp_risk_analysis_get
--    Current version of a candidate's analysis, or one named version.
-- =====================================================================
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
        a.approval_status_code    AS ApprovalStatusCode
      FROM grac_practice.risk_analysis a
 LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = a.risk_owner_employee_id
 LEFT JOIN grac_practice.organization_employee an ON an.employee_id = a.analysed_by_employee_id
     WHERE (@risk_analysis_id IS NOT NULL AND a.risk_analysis_id = @risk_analysis_id)
        OR (@risk_analysis_id IS NULL
            AND a.risk_candidate_id = @risk_candidate_id
            AND a.is_current = 1);
END;
GO

-- =====================================================================
-- 5. sp_risk_analysis_history   (BRD §20)
--    "Risk analysis history shall be retained" — this is the read that
--    proves it.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_analysis_history
    @risk_candidate_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 56061, 'sp_risk_analysis_history: risk_candidate_id is required.', 1;

    SELECT
        a.risk_analysis_id      AS RiskAnalysisId,
        a.analysis_version      AS AnalysisVersion,
        a.is_current            AS IsCurrent,
        a.risk_statement        AS RiskStatement,
        a.likelihood_name       AS LikelihoodName,
        a.impact_name           AS ImpactName,
        a.inherent_rating_code  AS InherentRatingCode,
        a.inherent_rating_score AS InherentRatingScore,
        a.decision_code         AS DecisionCode,
        a.analysis_dt           AS AnalysisOn,
        e.employee_name         AS AnalysedByName,
        a.analyst_remarks       AS AnalystRemarks
      FROM grac_practice.risk_analysis a
 LEFT JOIN grac_practice.organization_employee e ON e.employee_id = a.analysed_by_employee_id
     WHERE a.risk_candidate_id = @risk_candidate_id
     ORDER BY a.analysis_version DESC;
END;
GO

-- =====================================================================
-- 6. sp_risk_duplicate_check   (BRD §15)
--
-- "Before registering a Risk Candidate or Custom Risk, the system should
-- provide duplicate-risk detection."
--
-- ADVISORY, NOT BLOCKING. §15 gives the analyst three outcomes —
-- continue with justification, link, or close as duplicate — so this
-- proc reports and never refuses. The decision is a human's.
--
-- Matching is a weighted score over the attributes §15 lists. Exact
-- source identity is the strongest signal (the same gap producing a
-- second risk is nearly always a re-raise), then title similarity, then
-- category and business context.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_duplicate_check
    @organization_id    BIGINT,
    @risk_title         NVARCHAR(300)  = NULL,
    @risk_statement     NVARCHAR(1000) = NULL,
    @risk_category_code NVARCHAR(60)   = NULL,
    @source_type_code   NVARCHAR(40)   = NULL,
    @source_record_id   BIGINT         = NULL,
    @business_unit      NVARCHAR(200)  = NULL,
    @exclude_risk_id    BIGINT         = NULL,
    @min_score          INT            = 30
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 56070, 'sp_risk_duplicate_check: organization_id is required.', 1;

    -- Normalised comparison keys. LIKE on a leading fragment is a poor
    -- man's similarity, but it is index-friendly and, crucially, it is
    -- explainable to an auditor — which a fuzzy score is not.
    DECLARE @title_key NVARCHAR(120) =
        CASE WHEN @risk_title IS NULL THEN NULL
             ELSE LEFT(LTRIM(RTRIM(LOWER(@risk_title))), 40) END;
    DECLARE @stmt_key NVARCHAR(200) =
        CASE WHEN @risk_statement IS NULL THEN NULL
             ELSE LEFT(LTRIM(RTRIM(LOWER(@risk_statement))), 60) END;

    SELECT TOP 20
        r.risk_register_id     AS RiskRegisterId,
        r.risk_number          AS RiskNumber,
        r.risk_title           AS RiskTitle,
        r.risk_statement       AS RiskStatement,
        r.risk_category_name   AS RiskCategoryName,
        r.source_type_code     AS SourceTypeCode,
        r.source_reference     AS SourceReference,
        r.status_code          AS StatusCode,
        r.inherent_rating_code AS InherentRatingCode,
        r.registered_dt        AS RegisteredOn,
        e.employee_name        AS RiskOwnerName,
        score.MatchScore       AS MatchScore,
        score.MatchReason      AS MatchReason
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.organization_employee e ON e.employee_id = r.risk_owner_employee_id
CROSS APPLY (
        SELECT
            (CASE WHEN @source_type_code IS NOT NULL AND @source_record_id IS NOT NULL
                   AND r.source_type_code = @source_type_code
                   AND r.source_record_id = @source_record_id            THEN 50 ELSE 0 END)
          + (CASE WHEN @title_key IS NOT NULL
                   AND LOWER(r.risk_title) LIKE @title_key + N'%'        THEN 30 ELSE 0 END)
          + (CASE WHEN @stmt_key IS NOT NULL
                   AND LOWER(r.risk_statement) LIKE @stmt_key + N'%'     THEN 25 ELSE 0 END)
          + (CASE WHEN @risk_category_code IS NOT NULL
                   AND r.risk_category_code = @risk_category_code        THEN 10 ELSE 0 END)
          + (CASE WHEN @business_unit IS NOT NULL
                   AND r.business_unit = @business_unit                  THEN  5 ELSE 0 END)
            AS MatchScore,
            CONCAT(
              CASE WHEN @source_type_code IS NOT NULL AND @source_record_id IS NOT NULL
                    AND r.source_type_code = @source_type_code
                    AND r.source_record_id = @source_record_id
                   THEN N'same source; ' ELSE N'' END,
              CASE WHEN @title_key IS NOT NULL
                    AND LOWER(r.risk_title) LIKE @title_key + N'%'
                   THEN N'similar title; ' ELSE N'' END,
              CASE WHEN @stmt_key IS NOT NULL
                    AND LOWER(r.risk_statement) LIKE @stmt_key + N'%'
                   THEN N'similar statement; ' ELSE N'' END,
              CASE WHEN @risk_category_code IS NOT NULL
                    AND r.risk_category_code = @risk_category_code
                   THEN N'same category; ' ELSE N'' END,
              CASE WHEN @business_unit IS NOT NULL
                    AND r.business_unit = @business_unit
                   THEN N'same business unit; ' ELSE N'' END)
            AS MatchReason
     ) AS score
     WHERE r.organization_id = @organization_id
       -- Retired and Closed risks are excluded: re-raising a risk that
       -- was deliberately closed is a legitimate act, not a duplicate.
       AND r.status_code NOT IN (N'Closed', N'Retired')
       AND (@exclude_risk_id IS NULL OR r.risk_register_id <> @exclude_risk_id)
       AND score.MatchScore >= ISNULL(@min_score, 30)
     ORDER BY score.MatchScore DESC, r.registered_dt DESC;
END;
GO

-- =====================================================================
-- 7. sp_risk_candidate_assign   (BRD §6.2, §16, §18)
--    Assign the Risk Analyst and move New -> Under Analysis.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_assign
    @risk_candidate_id   BIGINT,
    @analyst_employee_id BIGINT,
    @remark              NVARCHAR(MAX) = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 56080, 'sp_risk_candidate_assign: risk_candidate_id is required.', 1;
    IF @analyst_employee_id IS NULL
        THROW 56081, 'sp_risk_candidate_assign: analyst_employee_id is required.', 1;

    DECLARE @current NVARCHAR(30);
    SELECT @current = status_code FROM grac_practice.risk_candidate
     WHERE risk_candidate_id = @risk_candidate_id;
    IF @current IS NULL
        THROW 56082, 'sp_risk_candidate_assign: candidate not found.', 1;
    IF @current IN (N'Registered', N'Rejected', N'ClosedAsDuplicate', N'Withdrawn')
        THROW 56083, 'sp_risk_candidate_assign: this candidate is closed.', 1;

    DECLARE @to_status NVARCHAR(30) =
        CASE WHEN @current IN (N'Pending', N'ClarificationRequired')
             THEN N'UnderAnalysis' ELSE @current END;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_candidate
           SET assigned_analyst_employee_id = @analyst_employee_id,
               status_code = @to_status,
               updated_by  = @caller_display_name,
               updated_dt  = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id, N'Assign', @current, @to_status,
             @remark, @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_candidate_id AS RiskCandidateId, @to_status AS StatusCode;
END;
GO

-- =====================================================================
-- 8. sp_risk_candidate_clarify   (BRD §8C)
--
-- "Where information is insufficient, the candidate may be returned to
-- the relevant owner or analyst for additional information. The system
-- shall retain the complete analysis history."
--
-- The analysis versions are untouched — that is the retention §8C asks
-- for. Only the candidate's status and the outstanding question move.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_clarify
    @risk_candidate_id   BIGINT,
    @clarification_note  NVARCHAR(MAX),
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 56090, 'sp_risk_candidate_clarify: risk_candidate_id is required.', 1;
    IF @clarification_note IS NULL OR LEN(LTRIM(RTRIM(@clarification_note))) = 0
        THROW 56091, 'sp_risk_candidate_clarify: clarification_note is required.', 1;

    DECLARE @current NVARCHAR(30);
    SELECT @current = status_code FROM grac_practice.risk_candidate
     WHERE risk_candidate_id = @risk_candidate_id;
    IF @current IS NULL
        THROW 56092, 'sp_risk_candidate_clarify: candidate not found.', 1;
    IF @current IN (N'Registered', N'Rejected', N'ClosedAsDuplicate', N'Withdrawn')
        THROW 56093, 'sp_risk_candidate_clarify: this candidate is closed.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_candidate
           SET status_code                = N'ClarificationRequired',
               clarification_note         = @clarification_note,
               clarification_requested_dt = SYSUTCDATETIME(),
               updated_by                 = @caller_display_name,
               updated_dt                 = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        -- Record the decision on the analysis that prompted it, so the
        -- §20 trail shows WHICH version was found insufficient.
        UPDATE grac_practice.risk_analysis
           SET decision_code         = N'Clarify',
               decision_note         = @clarification_note,
               decision_dt           = SYSUTCDATETIME(),
               decision_by_employee_id = @actor_employee_id,
               updated_by            = @caller_display_name,
               updated_dt            = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id AND is_current = 1;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id, N'Clarify', @current, N'ClarificationRequired',
             @clarification_note, @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_candidate_id AS RiskCandidateId, N'ClarificationRequired' AS StatusCode;
END;
GO

-- =====================================================================
-- 9. sp_risk_candidate_close_duplicate   (BRD §15 option 3)
--
-- The candidate closes against a named register entry, so the closure
-- stays navigable — "this was already risk RSK-1-42" — rather than
-- decaying into an unverifiable reason string.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_close_duplicate
    @risk_candidate_id    BIGINT,
    @duplicate_of_risk_id BIGINT,
    @remark               NVARCHAR(MAX) = NULL,
    @actor_employee_id    BIGINT        = NULL,
    @caller_display_name  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 56100, 'sp_risk_candidate_close_duplicate: risk_candidate_id is required.', 1;
    IF @duplicate_of_risk_id IS NULL
        THROW 56101, 'sp_risk_candidate_close_duplicate: duplicate_of_risk_id is required.', 1;

    DECLARE @current NVARCHAR(30), @org_id BIGINT;
    SELECT @current = status_code, @org_id = organization_id
      FROM grac_practice.risk_candidate WHERE risk_candidate_id = @risk_candidate_id;
    IF @current IS NULL
        THROW 56102, 'sp_risk_candidate_close_duplicate: candidate not found.', 1;
    IF @current IN (N'Registered', N'Rejected', N'ClosedAsDuplicate', N'Withdrawn')
        THROW 56103, 'sp_risk_candidate_close_duplicate: this candidate is already closed.', 1;

    -- Cross-organisation duplication is meaningless and would leak one
    -- tenant's register into another's screen.
    IF NOT EXISTS (SELECT 1 FROM grac_practice.risk_register
                    WHERE risk_register_id = @duplicate_of_risk_id
                      AND organization_id  = @org_id)
        THROW 56104, 'sp_risk_candidate_close_duplicate: target risk not found in this organisation.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_candidate
           SET status_code          = N'ClosedAsDuplicate',
               duplicate_of_risk_id = @duplicate_of_risk_id,
               rejection_reason     = COALESCE(@remark, N'Closed as duplicate.'),
               rejected_by_employee_id = @actor_employee_id,
               rejected_dt          = SYSUTCDATETIME(),
               updated_by           = @caller_display_name,
               updated_dt           = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id, N'CloseDuplicate', @current, N'ClosedAsDuplicate',
             CONCAT(N'Duplicate of risk_register_id ',
                    CAST(@duplicate_of_risk_id AS NVARCHAR(20)),
                    CASE WHEN @remark IS NULL THEN N'' ELSE CONCAT(N'. ', @remark) END),
             @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_candidate_id AS RiskCandidateId, N'ClosedAsDuplicate' AS StatusCode;
END;
GO

-- =====================================================================
-- 10. sp_risk_register_insert   (SHARED — the only writer of a risk)
--
-- Both routes end here. This procedure owns:
--   * the §24 rule 1 gate — a completed analysis must exist;
--   * the mandatory-field gate that "completed" means;
--   * copying the assessment onto the authoritative record (§9);
--   * the §20 audit row.
--
-- MANDATORY FIELDS
-- ----------------
-- §7.1 lists what the analysis "shall support"; §25 says "Mandatory risk
-- analysis information must be completed before registration" without
-- enumerating it. The enumeration below is the smallest set that makes a
-- register entry meaningful under §9.1 — a risk you cannot rate, cannot
-- categorise or cannot assign has not been analysed in any useful sense:
--
--   risk_statement, risk_category_code, likelihood, impact,
--   inherent_rating (derived, so it is really a matrix-coverage check),
--   risk_owner_employee_id
--
-- If an organisation needs a different set, this is the one place to
-- change it — which is the point of routing both entry routes through
-- one procedure (§12).
--
-- NOT called directly by the API. Callers are 11 and 12.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_register_insert
    @risk_analysis_id     BIGINT,
    @risk_title           NVARCHAR(300),
    @source_type_code     NVARCHAR(40),
    @source_record_id     BIGINT        = NULL,
    @source_reference     NVARCHAR(200) = NULL,
    @source_description   NVARCHAR(MAX) = NULL,
    @source_centre_code   NVARCHAR(60)  = NULL,
    @risk_candidate_id    BIGINT        = NULL,
    @linked_asset_id      BIGINT        = NULL,
    @linked_vendor_id     BIGINT        = NULL,
    @linked_practice_id   BIGINT        = NULL,
    @linked_obligation_id BIGINT        = NULL,
    @linked_control_id    BIGINT        = NULL,
    @registered_by_employee_id BIGINT   = NULL,
    @caller_display_name  NVARCHAR(100) = N'system',
    @risk_register_id     BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @risk_register_id = NULL;

    IF @risk_analysis_id IS NULL
        THROW 56110, 'sp_risk_register_insert: risk_analysis_id is required — a risk cannot be registered without its analysis (BRD 24.1).', 1;
    IF @risk_title IS NULL OR LEN(LTRIM(RTRIM(@risk_title))) = 0
        THROW 56111, 'sp_risk_register_insert: risk_title is required.', 1;
    IF @source_type_code IS NULL OR LEN(LTRIM(RTRIM(@source_type_code))) = 0
        THROW 56112, 'sp_risk_register_insert: source_type_code is required — every registered risk shall have a defined source (BRD 24.7).', 1;

    DECLARE
        @org_id BIGINT, @scope NVARCHAR(20),
        @statement NVARCHAR(1000), @cat_code NVARCHAR(60), @cat_name NVARCHAR(200),
        @description NVARCHAR(MAX), @cause NVARCHAR(MAX),
        @consequence NVARCHAR(MAX), @controls NVARCHAR(MAX),
        @lk_code NVARCHAR(60), @lk_name NVARCHAR(200), @lk_value INT,
        @im_code NVARCHAR(60), @im_name NVARCHAR(200), @im_value INT,
        @rt_code NVARCHAR(30), @rt_name NVARCHAR(120), @rt_score INT,
        @owner_id BIGINT, @bu NVARCHAR(200), @proc_name NVARCHAR(200),
        @already_registered BIGINT;

    SELECT @org_id      = organization_id,
           @scope       = analysis_scope_code,
           @statement   = risk_statement,
           @cat_code    = risk_category_code,
           @cat_name    = risk_category_name,
           @description = risk_description,
           @cause       = risk_cause,
           @consequence = potential_consequence,
           @controls    = existing_controls,
           @lk_code     = likelihood_code,
           @lk_name     = likelihood_name,
           @lk_value    = likelihood_value,
           @im_code     = impact_code,
           @im_name     = impact_name,
           @im_value    = impact_value,
           @rt_code     = inherent_rating_code,
           @rt_name     = inherent_rating_name,
           @rt_score    = inherent_rating_score,
           @owner_id    = risk_owner_employee_id,
           @bu          = business_unit,
           @proc_name   = process_name,
           @already_registered = risk_register_id
      FROM grac_practice.risk_analysis
     WHERE risk_analysis_id = @risk_analysis_id;

    IF @org_id IS NULL
        THROW 56113, 'sp_risk_register_insert: analysis not found.', 1;
    IF @already_registered IS NOT NULL
        THROW 56114, 'sp_risk_register_insert: this analysis has already been registered.', 1;

    -- ---- The mandatory-field gate (§25) ------------------------------
    IF @statement IS NULL OR LEN(LTRIM(RTRIM(@statement))) = 0
        THROW 56115, 'sp_risk_register_insert: analysis is incomplete — risk statement is required.', 1;
    IF @cat_code IS NULL
        THROW 56116, 'sp_risk_register_insert: analysis is incomplete — risk category is required.', 1;
    IF @lk_value IS NULL
        THROW 56117, 'sp_risk_register_insert: analysis is incomplete — likelihood is required.', 1;
    IF @im_value IS NULL
        THROW 56118, 'sp_risk_register_insert: analysis is incomplete — impact is required.', 1;
    IF @rt_code IS NULL
        THROW 56119, 'sp_risk_register_insert: analysis is incomplete — inherent risk rating could not be resolved.', 1;
    IF @owner_id IS NULL
        THROW 56120, 'sp_risk_register_insert: analysis is incomplete — risk owner is required.', 1;

    -- ---- §24 rule 8, both halves -------------------------------------
    IF @source_type_code = N'Custom' AND @risk_candidate_id IS NOT NULL
        THROW 56121, 'sp_risk_register_insert: a Custom risk cannot carry a candidate (BRD 24.8).', 1;
    IF @source_type_code <> N'Custom' AND @scope = N'Custom'
        THROW 56122, 'sp_risk_register_insert: a custom-scoped analysis must register with source type Custom (BRD 24.8).', 1;

    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    INSERT INTO grac_practice.risk_register
        (organization_id,
         risk_title, risk_statement, risk_description,
         risk_category_code, risk_category_name,
         source_type_code, source_record_id, source_reference,
         source_description, source_centre_code,
         risk_candidate_id, risk_analysis_id,
         risk_owner_employee_id, business_unit, process_name,
         risk_cause, potential_consequence, existing_controls,
         likelihood_code, likelihood_name, likelihood_value,
         impact_code, impact_name, impact_value,
         inherent_rating_code, inherent_rating_name, inherent_rating_score,
         linked_asset_id, linked_vendor_id, linked_practice_id,
         linked_obligation_id, linked_control_id,
         status_code, registered_dt, registered_by_employee_id,
         record_status_id, entered_by, entered_dt)
    VALUES
        (@org_id,
         @risk_title, @statement, @description,
         @cat_code, @cat_name,
         @source_type_code, @source_record_id, @source_reference,
         @source_description, @source_centre_code,
         @risk_candidate_id, @risk_analysis_id,
         @owner_id, @bu, @proc_name,
         @cause, @consequence, @controls,
         @lk_code, @lk_name, @lk_value,
         @im_code, @im_name, @im_value,
         @rt_code, @rt_name, @rt_score,
         @linked_asset_id, @linked_vendor_id, @linked_practice_id,
         @linked_obligation_id, @linked_control_id,
         N'Active', SYSUTCDATETIME(), @registered_by_employee_id,
         @active_rs, @caller_display_name, SYSUTCDATETIME());

    SET @risk_register_id = SCOPE_IDENTITY();

    -- Close the §10 chain: Register -> Analysis -> Candidate -> Source.
    UPDATE grac_practice.risk_analysis
       SET risk_register_id = @risk_register_id,
           decision_code    = N'Register',
           decision_dt      = COALESCE(decision_dt, SYSUTCDATETIME()),
           decision_by_employee_id = COALESCE(decision_by_employee_id, @registered_by_employee_id),
           updated_by       = @caller_display_name,
           updated_dt       = SYSUTCDATETIME()
     WHERE risk_analysis_id = @risk_analysis_id;

    INSERT INTO grac_practice.risk_register_history
        (risk_register_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@risk_register_id, N'Register', NULL, N'Active',
         CONCAT(N'Registered from ', @source_type_code,
                CASE WHEN @source_reference IS NULL THEN N''
                     ELSE CONCAT(N' ', @source_reference) END,
                N'; analysis #', CAST(@risk_analysis_id AS NVARCHAR(20)),
                N'; inherent rating ', @rt_code),
         @registered_by_employee_id, @caller_display_name,
         @caller_display_name, SYSUTCDATETIME());
END;
GO

-- =====================================================================
-- 11. sp_risk_candidate_register   (BRD §8A — Route A)
--
-- "The candidate is determined to represent a valid risk. The system
-- shall create the corresponding Risk Register entry."
--
-- CONFLICT NOTE — TREATMENT TASKS
-- -------------------------------
-- 199's sp_risk_candidate_accept raises a Task Candidate on acceptance.
-- This BRD §22 says the opposite: "Risk registration itself shall not
-- automatically imply that a treatment task exists ... Once a risk has
-- been registered, the organisation MAY decide that treatment actions
-- are required."
--
-- So registration here raises nothing. The Task Centre path stays
-- available through Task Centre's own Candidates screen, where a human
-- decides. sp_risk_candidate_accept is left exactly as 199 wrote it so
-- organisations mid-flight on the legacy triage keep their behaviour;
-- it is superseded, not removed. See docs/risk-centre.md.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_register
    @risk_candidate_id    BIGINT,
    @risk_title           NVARCHAR(300) = NULL,
    @registration_note    NVARCHAR(MAX) = NULL,
    @registered_by_employee_id BIGINT   = NULL,
    @linked_asset_id      BIGINT        = NULL,
    @linked_vendor_id     BIGINT        = NULL,
    @linked_practice_id   BIGINT        = NULL,
    @linked_obligation_id BIGINT        = NULL,
    @linked_control_id    BIGINT        = NULL,
    @caller_display_name  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_candidate_id IS NULL
        THROW 56130, 'sp_risk_candidate_register: risk_candidate_id is required.', 1;

    DECLARE @current NVARCHAR(30), @cand_title NVARCHAR(300),
            @src_type NVARCHAR(40), @src_id BIGINT, @src_ref NVARCHAR(200),
            @src_desc NVARCHAR(MAX), @src_centre NVARCHAR(60);

    SELECT @current    = status_code,
           @cand_title = candidate_title,
           @src_type   = source_type_code,
           @src_id     = source_record_id,
           @src_ref    = source_reference,
           @src_desc   = source_description,
           @src_centre = source_centre_code
      FROM grac_practice.risk_candidate
     WHERE risk_candidate_id = @risk_candidate_id;

    IF @current IS NULL
        THROW 56131, 'sp_risk_candidate_register: candidate not found.', 1;
    IF @current IN (N'Registered', N'Rejected', N'ClosedAsDuplicate', N'Withdrawn')
        THROW 56132, 'sp_risk_candidate_register: this candidate is already closed.', 1;

    -- §24 rule 1. The analysis must exist before we look at anything
    -- else; sp_risk_register_insert then judges whether it is complete.
    DECLARE @analysis_id BIGINT =
        (SELECT risk_analysis_id FROM grac_practice.risk_analysis
          WHERE risk_candidate_id = @risk_candidate_id AND is_current = 1);
    IF @analysis_id IS NULL
        THROW 56133, 'sp_risk_candidate_register: no risk analysis exists for this candidate. Every risk entering the register must pass through an initial analysis (BRD 24.1).', 1;

    -- A candidate raised before 205 has no source. Registering it would
    -- breach §24 rule 7, and guessing would be worse than refusing.
    IF @src_type IS NULL
        THROW 56134, 'sp_risk_candidate_register: this candidate has no source type. Run 207_risk_centre_source_wiring.sql to backfill legacy candidates.', 1;

    DECLARE @new_risk_id BIGINT;
    DECLARE @title NVARCHAR(300) = COALESCE(NULLIF(LTRIM(RTRIM(@risk_title)), N''), @cand_title);

    BEGIN TRY
        BEGIN TRAN;

        EXEC grac_practice.sp_risk_register_insert
             @risk_analysis_id     = @analysis_id,
             @risk_title           = @title,
             @source_type_code     = @src_type,
             @source_record_id     = @src_id,
             @source_reference     = @src_ref,
             @source_description   = @src_desc,
             @source_centre_code   = @src_centre,
             @risk_candidate_id    = @risk_candidate_id,
             @linked_asset_id      = @linked_asset_id,
             @linked_vendor_id     = @linked_vendor_id,
             @linked_practice_id   = @linked_practice_id,
             @linked_obligation_id = @linked_obligation_id,
             @linked_control_id    = @linked_control_id,
             @registered_by_employee_id = @registered_by_employee_id,
             @caller_display_name  = @caller_display_name,
             @risk_register_id     = @new_risk_id OUTPUT;

        UPDATE grac_practice.risk_candidate
           SET status_code        = N'Registered',
               registered_risk_id = @new_risk_id,
               -- formal_risk_ref was 169's placeholder for "the id from
               -- the enterprise risk register". This is that register,
               -- so the placeholder finally gets its real value.
               formal_risk_ref    = (SELECT risk_number FROM grac_practice.risk_register
                                      WHERE risk_register_id = @new_risk_id),
               acceptance_note    = COALESCE(@registration_note, acceptance_note),
               accepted_by_employee_id = COALESCE(@registered_by_employee_id, accepted_by_employee_id),
               accepted_dt        = COALESCE(accepted_dt, SYSUTCDATETIME()),
               updated_by         = @caller_display_name,
               updated_dt         = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        UPDATE grac_practice.risk_analysis
           SET decision_note = COALESCE(@registration_note, decision_note)
         WHERE risk_analysis_id = @analysis_id;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id, N'Register', @current, N'Registered',
             CONCAT(N'Registered as risk_register_id ', CAST(@new_risk_id AS NVARCHAR(20)),
                    CASE WHEN @registration_note IS NULL THEN N''
                         ELSE CONCAT(N'. ', @registration_note) END),
             @registered_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_candidate_id AS RiskCandidateId,
           N'Registered'      AS StatusCode,
           @new_risk_id       AS RiskRegisterId,
           (SELECT risk_number FROM grac_practice.risk_register
             WHERE risk_register_id = @new_risk_id) AS RiskNumber;
END;
GO

-- =====================================================================
-- 12. sp_risk_custom_create   (BRD §4B, §11, §12 — Route B)
--
-- "Custom Risk Creation + Initial Risk Analysis -> Risk Register.
-- There shall therefore be no unnecessary intermediate Risk Candidate
-- stage for a custom risk." (§4B)
-- "The user shall not have to first create a separate candidate and then
-- reopen it for analysis." (§11)
--
-- One transaction, two writes, no candidate row. The analysis is created
-- by the SAME procedure Route A uses (§12), and registration goes
-- through the SAME writer — so a custom risk cannot bypass a mandatory
-- field that a stream risk cannot bypass.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_custom_create
    @organization_id        BIGINT,
    @risk_title             NVARCHAR(300),
    @risk_statement         NVARCHAR(1000),
    @risk_category_code     NVARCHAR(60),
    @likelihood_code        NVARCHAR(60),
    @impact_code            NVARCHAR(60),
    @risk_owner_employee_id BIGINT,
    @risk_description       NVARCHAR(MAX) = NULL,
    @risk_cause             NVARCHAR(MAX) = NULL,
    @potential_consequence  NVARCHAR(MAX) = NULL,
    @existing_controls      NVARCHAR(MAX) = NULL,
    @business_unit          NVARCHAR(200) = NULL,
    @process_name           NVARCHAR(200) = NULL,
    @analyst_remarks        NVARCHAR(MAX) = NULL,
    @linked_asset_id        BIGINT        = NULL,
    @linked_vendor_id       BIGINT        = NULL,
    @linked_practice_id     BIGINT        = NULL,
    @linked_obligation_id   BIGINT        = NULL,
    @linked_control_id      BIGINT        = NULL,
    @created_by_employee_id BIGINT        = NULL,
    @caller_display_name    NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 56140, 'sp_risk_custom_create: organization_id is required.', 1;
    IF @risk_title IS NULL OR LEN(LTRIM(RTRIM(@risk_title))) = 0
        THROW 56141, 'sp_risk_custom_create: risk_title is required.', 1;

    DECLARE @analysis_id BIGINT, @version INT, @new_risk_id BIGINT;

    BEGIN TRY
        BEGIN TRAN;

        -- §12: the same analysis writer as Route A. Its own validation
        -- covers statement, scale codes and category.
        EXEC grac_practice.sp_risk_analysis_save
             @risk_candidate_id      = NULL,          -- §4B: no candidate stage
             @organization_id        = @organization_id,
             @risk_statement         = @risk_statement,
             @risk_category_code     = @risk_category_code,
             @risk_description       = @risk_description,
             @risk_cause             = @risk_cause,
             @potential_consequence  = @potential_consequence,
             @existing_controls      = @existing_controls,
             @likelihood_code        = @likelihood_code,
             @impact_code            = @impact_code,
             @risk_owner_employee_id = @risk_owner_employee_id,
             @business_unit          = @business_unit,
             @process_name           = @process_name,
             @analyst_remarks        = @analyst_remarks,
             @analysed_by_employee_id = @created_by_employee_id,
             @caller_display_name    = @caller_display_name,
             @suppress_result        = 1,
             @risk_analysis_id       = @analysis_id OUTPUT,
             @analysis_version       = @version     OUTPUT;

        -- §24 rule 8: source type Custom, no candidate, no source record.
        EXEC grac_practice.sp_risk_register_insert
             @risk_analysis_id     = @analysis_id,
             @risk_title           = @risk_title,
             @source_type_code     = N'Custom',
             @source_record_id     = NULL,
             @source_reference     = NULL,
             @source_description   = @analyst_remarks,
             @source_centre_code   = NULL,
             @risk_candidate_id    = NULL,
             @linked_asset_id      = @linked_asset_id,
             @linked_vendor_id     = @linked_vendor_id,
             @linked_practice_id   = @linked_practice_id,
             @linked_obligation_id = @linked_obligation_id,
             @linked_control_id    = @linked_control_id,
             @registered_by_employee_id = @created_by_employee_id,
             @caller_display_name  = @caller_display_name,
             @risk_register_id     = @new_risk_id OUTPUT;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @new_risk_id  AS RiskRegisterId,
           @analysis_id  AS RiskAnalysisId,
           (SELECT risk_number FROM grac_practice.risk_register
             WHERE risk_register_id = @new_risk_id) AS RiskNumber;
END;
GO

-- =====================================================================
-- 13. sp_risk_register_list   (BRD §9, §23)
--
-- Filters mirror §23's "Risks by ..." list so the dashboard and the grid
-- share one read rather than drifting apart.
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
    @page_size        INT = 25
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
        COUNT(*) OVER ()        AS TotalRows
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.risk_owner_employee_id
 LEFT JOIN grac_practice.organization_employee rb ON rb.employee_id = r.registered_by_employee_id
     WHERE r.organization_id = @organization_id
       AND (@status_code      IS NULL OR r.status_code         = @status_code)
       AND (@source_type_code IS NULL OR r.source_type_code    = @source_type_code)
       AND (@category_code    IS NULL OR r.risk_category_code  = @category_code)
       AND (@rating_code      IS NULL OR r.inherent_rating_code= @rating_code)
       AND (@owner_employee_id IS NULL OR r.risk_owner_employee_id = @owner_employee_id)
       AND (@search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0
            OR r.risk_title     LIKE N'%' + @search + N'%'
            OR r.risk_statement LIKE N'%' + @search + N'%'
            OR r.risk_number    LIKE N'%' + @search + N'%')
     ORDER BY r.registered_dt DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- =====================================================================
-- 14. sp_risk_register_get   (BRD §9.1 + §10)
--
-- Returns the risk AND the whole traceability chain in one row, so the
-- detail screen can render §10's navigation
--   Risk Register -> Risk Analysis -> Risk Candidate -> Original Source
-- without three further round trips.
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
        r.linked_obligation_id  AS LinkedObligationId,
        r.linked_control_id     AS LinkedControlId,

        r.status_code           AS StatusCode,
        r.registered_dt         AS RegisteredOn,
        r.registered_by_employee_id AS RegisteredByEmployeeId,
        rb.employee_name        AS RegisteredByName,
        r.closed_dt             AS ClosedOn,
        cb.employee_name        AS ClosedByName,
        r.closure_reason        AS ClosureReason
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.risk_source_master  sm ON sm.source_type_code = r.source_type_code
 LEFT JOIN grac_practice.risk_candidate      c  ON c.risk_candidate_id = r.risk_candidate_id
 LEFT JOIN grac_practice.risk_analysis       a  ON a.risk_analysis_id  = r.risk_analysis_id
 LEFT JOIN grac_practice.organization_employee an ON an.employee_id = a.analysed_by_employee_id
 LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.risk_owner_employee_id
 LEFT JOIN grac_practice.organization_employee rb ON rb.employee_id = r.registered_by_employee_id
 LEFT JOIN grac_practice.organization_employee cb ON cb.employee_id = r.closed_by_employee_id
     WHERE r.risk_register_id = @risk_register_id;
END;
GO

-- =====================================================================
-- 15. sp_risk_register_status_set   (BRD §17)
--
-- Active / UnderTreatment / Accepted / Monitoring / Closed / Retired.
-- The CHECK on the table owns the vocabulary; this proc owns the two
-- rules the vocabulary alone cannot express — a closure needs a reason,
-- and a closed risk does not silently reopen without an audit row.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_register_status_set
    @risk_register_id    BIGINT,
    @status_code         NVARCHAR(30),
    @remark              NVARCHAR(MAX) = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_register_id IS NULL
        THROW 56170, 'sp_risk_register_status_set: risk_register_id is required.', 1;
    IF @status_code IS NULL
        THROW 56171, 'sp_risk_register_status_set: status_code is required.', 1;
    IF @status_code NOT IN (N'Active', N'UnderTreatment', N'Accepted',
                            N'Monitoring', N'Closed', N'Retired')
        THROW 56172, 'sp_risk_register_status_set: unknown status_code (BRD 17).', 1;

    DECLARE @current NVARCHAR(30);
    SELECT @current = status_code FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;
    IF @current IS NULL
        THROW 56173, 'sp_risk_register_status_set: risk not found.', 1;

    IF @status_code IN (N'Closed', N'Retired')
       AND (@remark IS NULL OR LEN(LTRIM(RTRIM(@remark))) = 0)
        THROW 56174, 'sp_risk_register_status_set: a reason is required to close or retire a risk.', 1;

    IF @current = @status_code
    BEGIN
        SELECT @risk_register_id AS RiskRegisterId, @current AS StatusCode;
        RETURN;
    END

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_register
           SET status_code    = @status_code,
               closure_reason = CASE WHEN @status_code IN (N'Closed', N'Retired')
                                     THEN @remark ELSE closure_reason END,
               closed_dt      = CASE WHEN @status_code IN (N'Closed', N'Retired')
                                     THEN SYSUTCDATETIME() ELSE NULL END,
               closed_by_employee_id = CASE WHEN @status_code IN (N'Closed', N'Retired')
                                            THEN @actor_employee_id ELSE NULL END,
               updated_by     = @caller_display_name,
               updated_dt     = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id;

        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_register_id,
             CASE WHEN @status_code IN (N'Closed', N'Retired') THEN N'Close' ELSE N'StatusChange' END,
             @current, @status_code,
             @remark, @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_register_id AS RiskRegisterId, @status_code AS StatusCode;
END;
GO

-- =====================================================================
-- 16. sp_risk_register_owner_set   (BRD §18 Risk Owner, §20)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_register_owner_set
    @risk_register_id    BIGINT,
    @owner_employee_id   BIGINT,
    @remark              NVARCHAR(MAX) = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_register_id IS NULL
        THROW 56180, 'sp_risk_register_owner_set: risk_register_id is required.', 1;
    IF @owner_employee_id IS NULL
        THROW 56181, 'sp_risk_register_owner_set: owner_employee_id is required.', 1;

    DECLARE @org_id BIGINT, @previous BIGINT;
    SELECT @org_id = organization_id, @previous = risk_owner_employee_id
      FROM grac_practice.risk_register WHERE risk_register_id = @risk_register_id;
    IF @org_id IS NULL
        THROW 56182, 'sp_risk_register_owner_set: risk not found.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                    WHERE employee_id = @owner_employee_id)
        THROW 56183, 'sp_risk_register_owner_set: employee not found.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_register
           SET risk_owner_employee_id = @owner_employee_id,
               updated_by = @caller_display_name,
               updated_dt = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id;

        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_register_id, N'OwnerChange', NULL, NULL,
             CONCAT(N'Risk owner changed from ',
                    ISNULL(CAST(@previous AS NVARCHAR(20)), N'(none)'),
                    N' to ', CAST(@owner_employee_id AS NVARCHAR(20)),
                    CASE WHEN @remark IS NULL THEN N'' ELSE CONCAT(N'. ', @remark) END),
             @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_register_id AS RiskRegisterId, @owner_employee_id AS RiskOwnerEmployeeId;
END;
GO

-- =====================================================================
-- 17. sp_risk_candidate_list   (REWRITE — strict superset of 170)
--
-- 170 did `JOIN grac_practice.custom_gap`. An INNER JOIN was correct
-- when Gap was the only possible source; after 205 it silently HIDES
-- every candidate raised by Assurance, Obligation, Asset, Vendor or
-- Event. That is the single most damaging line in the old proc, and it
-- is why this rewrite exists.
--
-- COMPATIBILITY: every 170 column survives with the same name and
-- position semantics. CustomGapId and GapTitle are still there, now
-- NULLable for non-gap sources.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_list
    @organization_id  BIGINT,
    @status_code      NVARCHAR(30) = NULL,
    @page_number      INT = 1,
    @page_size        INT = 25,
    @source_type_code NVARCHAR(40) = NULL   -- NEW, optional (§23 "by source")
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 55410, 'sp_risk_candidate_list: organization_id is required.', 1;
    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    SELECT
        r.risk_candidate_id         AS RiskCandidateId,
        r.organization_id           AS OrganizationId,
        r.custom_gap_id             AS CustomGapId,
        g.title                     AS GapTitle,
        r.candidate_title           AS CandidateTitle,
        r.severity_code             AS SeverityCode,
        r.status_code               AS StatusCode,
        r.requested_dt              AS RequestedOn,
        rq.employee_name            AS RequestedByName,
        r.accepted_dt               AS AcceptedOn,
        ac.employee_name            AS AcceptedByName,
        r.rejected_dt               AS RejectedOn,
        rj.employee_name            AS RejectedByName,
        r.formal_risk_ref           AS FormalRiskRef,
        (SELECT COUNT(*) FROM grac_practice.risk_candidate_attachment a
          WHERE a.risk_candidate_id = r.risk_candidate_id) AS AttachmentCount,
        -- ---- NEW in 206 ---------------------------------------------
        r.candidate_number          AS CandidateNumber,
        r.source_type_code          AS SourceTypeCode,
        sm.source_name              AS SourceName,
        r.source_record_id          AS SourceRecordId,
        r.source_reference          AS SourceReference,
        r.source_centre_code        AS SourceCentreCode,
        r.identified_dt             AS IdentifiedOn,
        r.assigned_analyst_employee_id AS AssignedAnalystEmployeeId,
        an.employee_name            AS AssignedAnalystName,
        r.registered_risk_id        AS RegisteredRiskId,
        rr.risk_number              AS RegisteredRiskNumber,
        r.duplicate_of_risk_id      AS DuplicateOfRiskId,
        cur.risk_analysis_id        AS CurrentAnalysisId,
        cur.analysis_version        AS CurrentAnalysisVersion,
        cur.inherent_rating_code    AS InherentRatingCode,
        COUNT(*) OVER ()            AS TotalRows
      FROM grac_practice.risk_candidate r
 LEFT JOIN grac_practice.custom_gap g            ON g.custom_gap_id = r.custom_gap_id
 LEFT JOIN grac_practice.risk_source_master sm   ON sm.source_type_code = r.source_type_code
 LEFT JOIN grac_practice.risk_register rr        ON rr.risk_register_id = r.registered_risk_id
 LEFT JOIN grac_practice.risk_analysis cur       ON cur.risk_candidate_id = r.risk_candidate_id
                                                AND cur.is_current = 1
 LEFT JOIN grac_practice.organization_employee rq ON rq.employee_id = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee ac ON ac.employee_id = r.accepted_by_employee_id
 LEFT JOIN grac_practice.organization_employee rj ON rj.employee_id = r.rejected_by_employee_id
 LEFT JOIN grac_practice.organization_employee an ON an.employee_id = r.assigned_analyst_employee_id
     WHERE r.organization_id = @organization_id
       AND (@status_code IS NULL OR r.status_code = @status_code)
       AND (@source_type_code IS NULL OR r.source_type_code = @source_type_code)
     ORDER BY r.requested_dt DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- =====================================================================
-- 18. sp_risk_candidate_get   (REWRITE — strict superset of 170)
--     Same INNER-JOIN fix as 17, plus the §6.2 / §10 fields.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_get
    @risk_candidate_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 55420, 'sp_risk_candidate_get: risk_candidate_id is required.', 1;

    SELECT
        r.risk_candidate_id         AS RiskCandidateId,
        r.organization_id           AS OrganizationId,
        r.custom_gap_id             AS CustomGapId,
        g.title                     AS GapTitle,
        r.candidate_title           AS CandidateTitle,
        r.candidate_summary         AS CandidateSummary,
        r.severity_code             AS SeverityCode,
        r.severity_name             AS SeverityName,
        r.impact_summary            AS ImpactSummary,
        r.likelihood_summary        AS LikelihoodSummary,
        r.status_code               AS StatusCode,
        r.requested_by_employee_id  AS RequestedByEmployeeId,
        rq.employee_name            AS RequestedByName,
        r.requested_dt              AS RequestedOn,
        r.accepted_by_employee_id   AS AcceptedByEmployeeId,
        ac.employee_name            AS AcceptedByName,
        r.accepted_dt               AS AcceptedOn,
        r.acceptance_note           AS AcceptanceNote,
        r.formal_risk_ref           AS FormalRiskRef,
        r.rejected_by_employee_id   AS RejectedByEmployeeId,
        rj.employee_name            AS RejectedByName,
        r.rejected_dt               AS RejectedOn,
        r.rejection_reason          AS RejectionReason,
        -- ---- NEW in 206 ---------------------------------------------
        r.candidate_number          AS CandidateNumber,
        r.source_type_code          AS SourceTypeCode,
        sm.source_name              AS SourceName,
        r.source_record_id          AS SourceRecordId,
        r.source_reference          AS SourceReference,
        r.source_description        AS SourceDescription,
        r.source_centre_code        AS SourceCentreCode,
        r.identified_dt             AS IdentifiedOn,
        r.business_unit             AS BusinessUnit,
        r.assigned_analyst_employee_id AS AssignedAnalystEmployeeId,
        an.employee_name            AS AssignedAnalystName,
        r.clarification_note        AS ClarificationNote,
        r.clarification_requested_dt AS ClarificationRequestedOn,
        r.registered_risk_id        AS RegisteredRiskId,
        rr.risk_number              AS RegisteredRiskNumber,
        r.duplicate_of_risk_id      AS DuplicateOfRiskId,
        dup.risk_number             AS DuplicateOfRiskNumber,
        cur.risk_analysis_id        AS CurrentAnalysisId,
        cur.analysis_version        AS CurrentAnalysisVersion,
        cur.inherent_rating_code    AS InherentRatingCode
      FROM grac_practice.risk_candidate r
 LEFT JOIN grac_practice.custom_gap g            ON g.custom_gap_id = r.custom_gap_id
 LEFT JOIN grac_practice.risk_source_master sm   ON sm.source_type_code = r.source_type_code
 LEFT JOIN grac_practice.risk_register rr        ON rr.risk_register_id = r.registered_risk_id
 LEFT JOIN grac_practice.risk_register dup       ON dup.risk_register_id = r.duplicate_of_risk_id
 LEFT JOIN grac_practice.risk_analysis cur       ON cur.risk_candidate_id = r.risk_candidate_id
                                                AND cur.is_current = 1
 LEFT JOIN grac_practice.organization_employee rq ON rq.employee_id = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee ac ON ac.employee_id = r.accepted_by_employee_id
 LEFT JOIN grac_practice.organization_employee rj ON rj.employee_id = r.rejected_by_employee_id
 LEFT JOIN grac_practice.organization_employee an ON an.employee_id = r.assigned_analyst_employee_id
     WHERE r.risk_candidate_id = @risk_candidate_id;
END;
GO

-- =====================================================================
-- 19. sp_risk_candidate_reject   (REWRITE — strict superset of 170)
--
-- 170 allowed rejection only from 'Pending'. §8B places the rejection
-- decision AFTER the analysis, so a candidate in UnderAnalysis,
-- ClarificationRequired or AnalysisCompleted must also be rejectable —
-- otherwise the only way to reject an analysed candidate is not to
-- analyse it, which inverts the BRD.
--
-- Parameters and result set are unchanged.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_reject
    @risk_candidate_id       BIGINT,
    @rejection_reason        NVARCHAR(MAX),
    @rejected_by_employee_id BIGINT,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 55440, 'sp_risk_candidate_reject: risk_candidate_id is required.', 1;
    IF @rejection_reason IS NULL OR LEN(LTRIM(RTRIM(@rejection_reason))) = 0
        THROW 55441, 'sp_risk_candidate_reject: rejection_reason is required.', 1;
    IF @rejected_by_employee_id IS NULL
        THROW 55442, 'sp_risk_candidate_reject: rejected_by_employee_id is required.', 1;

    DECLARE @current NVARCHAR(30);
    SELECT @current = status_code
      FROM grac_practice.risk_candidate WHERE risk_candidate_id = @risk_candidate_id;
    IF @current IS NULL
        THROW 55443, 'sp_risk_candidate_reject: candidate not found.', 1;
    IF @current NOT IN (N'Pending', N'UnderAnalysis', N'ClarificationRequired',
                        N'AnalysisCompleted', N'Accepted')
        THROW 55444, 'sp_risk_candidate_reject: this candidate is already closed.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_candidate
           SET status_code             = N'Rejected',
               rejected_by_employee_id = @rejected_by_employee_id,
               rejected_dt             = SYSUTCDATETIME(),
               rejection_reason        = @rejection_reason,
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        -- §8B decision recorded against the analysis that produced it,
        -- when there is one. §24 rule 5/6: the rejected candidate and its
        -- analysis both remain, for audit.
        UPDATE grac_practice.risk_analysis
           SET decision_code = N'Reject',
               decision_note = @rejection_reason,
               decision_dt   = SYSUTCDATETIME(),
               decision_by_employee_id = @rejected_by_employee_id,
               updated_by    = @caller_display_name,
               updated_dt    = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id AND is_current = 1;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id, N'Reject', @current, N'Rejected',
             @rejection_reason, @rejected_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_candidate_id AS RiskCandidateId, N'Rejected' AS StatusCode;
END;
GO

-- =====================================================================
-- 20. sp_risk_candidate_withdraw   (REWRITE — strict superset of 170)
--     Same widening as 19, same reason.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_withdraw
    @risk_candidate_id       BIGINT,
    @withdraw_reason         NVARCHAR(MAX) = NULL,
    @actor_employee_id       BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 55450, 'sp_risk_candidate_withdraw: risk_candidate_id is required.', 1;

    DECLARE @current NVARCHAR(30);
    SELECT @current = status_code
      FROM grac_practice.risk_candidate WHERE risk_candidate_id = @risk_candidate_id;
    IF @current IS NULL
        THROW 55451, 'sp_risk_candidate_withdraw: candidate not found.', 1;
    IF @current NOT IN (N'Pending', N'UnderAnalysis', N'ClarificationRequired',
                        N'AnalysisCompleted')
        THROW 55452, 'sp_risk_candidate_withdraw: this candidate is already closed.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_candidate
           SET status_code = N'Withdrawn',
               updated_by  = @caller_display_name,
               updated_dt  = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id, N'Withdraw', @current, N'Withdrawn',
             @withdraw_reason, @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_candidate_id AS RiskCandidateId, N'Withdrawn' AS StatusCode;
END;
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '206 procedures present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_scoring_options_get','P')   IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_rating_resolve','P')        IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_analysis_save','P')         IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_analysis_get','P')          IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_analysis_history','P')      IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_duplicate_check','P')       IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_candidate_assign','P')      IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_candidate_clarify','P')     IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_candidate_close_duplicate','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_register_insert','P')       IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_candidate_register','P')    IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_custom_create','P')         IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_register_list','P')         IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_register_get','P')          IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_register_status_set','P')   IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_register_owner_set','P')    IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT '170 procs keep their original parameters' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_candidate_list')
                            AND name = '@page_size')
             AND EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_candidate_reject')
                            AND name = '@rejected_by_employee_id')
             AND EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_candidate_withdraw')
                            AND name = '@withdraw_reason')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '206 Risk Register procedures installed. Next: 207_risk_centre_source_wiring.sql';
PRINT 'NOT WIRED (by design, see file header): treatment-task creation on registration (BRD 22),';
PRINT '            configurable approval gate (BRD 19), notifications (BRD 21), dashboard (BRD 23).';
GO

SET NOEXEC OFF;
GO
