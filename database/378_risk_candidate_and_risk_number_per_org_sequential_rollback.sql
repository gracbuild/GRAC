-- =====================================================================
-- 378 ROLLBACK -- candidate_number / risk_number back to PERSISTED
-- COMPUTED columns (RC-<org>-<id> / RSK-<org>-<id>), sp_risk_candidate_
-- create and sp_risk_register_insert back to their pre-378 bodies
--
-- Restores exactly what 205 originally defined:
--   risk_candidate.candidate_number = CONCAT('RC-', organization_id,
--       '-', risk_candidate_id) PERSISTED
--   risk_register.risk_number       = CONCAT('RSK-', organization_id,
--       '-', risk_register_id) PERSISTED
-- and reverts the two stored procedures to 207's and 354's bodies,
-- read directly off those two files (not reconstructed from memory) to
-- guarantee an exact match -- no candidate_number/risk_number
-- generation block, no candidate_number/risk_number column in either
-- INSERT.
--
-- Order matters: the UNIQUE constraints and the index must go before
-- the physical columns they depend on can be dropped; the computed
-- columns are re-added, then the index is rebuilt on top of them.
--
-- Depends on: 378_risk_candidate_and_risk_number_per_org_sequential.sql
-- Re-runnable: yes. A second run makes no changes.
-- Contains the section-sign and em-dash characters already present in
-- 207/354's own comments and THROW messages -- reproduced verbatim,
-- not introduced by this file (same as 378's own note).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.risk_candidate','U') IS NULL
   OR OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN
    RAISERROR('378 rollback: risk_candidate/risk_register missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Drop what 378 added: the two UNIQUE constraints, then the index,
--    then the physical columns.
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.key_constraints
            WHERE name = 'uq_pm_risk_candidate_number'
              AND parent_object_id = OBJECT_ID('grac_practice.risk_candidate'))
    ALTER TABLE grac_practice.risk_candidate DROP CONSTRAINT uq_pm_risk_candidate_number;
GO

IF EXISTS (SELECT 1 FROM sys.key_constraints
            WHERE name = 'uq_pm_risk_register_number'
              AND parent_object_id = OBJECT_ID('grac_practice.risk_register'))
    ALTER TABLE grac_practice.risk_register DROP CONSTRAINT uq_pm_risk_register_number;
GO

IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE name = 'ix_pm_risk_register_number'
              AND object_id = OBJECT_ID('grac_practice.risk_register'))
    DROP INDEX ix_pm_risk_register_number ON grac_practice.risk_register;
GO

IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('grac_practice.risk_candidate')
              AND name = 'candidate_number'
              AND is_computed = 0)
    ALTER TABLE grac_practice.risk_candidate DROP COLUMN candidate_number;
GO

IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('grac_practice.risk_register')
              AND name = 'risk_number'
              AND is_computed = 0)
    ALTER TABLE grac_practice.risk_register DROP COLUMN risk_number;
GO

-- =====================================================================
-- 2. Re-add both columns exactly as 205 defined them.
-- =====================================================================
IF COL_LENGTH('grac_practice.risk_candidate','candidate_number') IS NULL
    ALTER TABLE grac_practice.risk_candidate ADD candidate_number AS
        (CONCAT('RC-', CAST(organization_id AS NVARCHAR(20)), '-',
                       CAST(risk_candidate_id AS NVARCHAR(20)))) PERSISTED;
GO

IF COL_LENGTH('grac_practice.risk_register','risk_number') IS NULL
    ALTER TABLE grac_practice.risk_register ADD risk_number AS
        (CONCAT('RSK-', CAST(organization_id AS NVARCHAR(20)), '-',
                        CAST(risk_register_id AS NVARCHAR(20)))) PERSISTED;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_register_number'
                  AND object_id = OBJECT_ID('grac_practice.risk_register'))
    CREATE INDEX ix_pm_risk_register_number ON grac_practice.risk_register(risk_number);
GO

-- =====================================================================
-- 3. sp_risk_candidate_create -- 207's exact body (no candidate_number
--    generation, no candidate_number in the INSERT).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_create
    -- ---- 170's parameters, in 170's order ---------------------------
    @custom_gap_id            BIGINT        = NULL,   -- was required
    @candidate_title          NVARCHAR(300) = NULL,
    @candidate_summary        NVARCHAR(MAX) = NULL,
    @severity_code            NVARCHAR(30)  = NULL,
    @severity_name            NVARCHAR(120) = NULL,
    @impact_summary           NVARCHAR(MAX) = NULL,
    @likelihood_summary       NVARCHAR(MAX) = NULL,
    @requested_by_employee_id BIGINT        = NULL,
    @caller_display_name      NVARCHAR(100) = N'system',
    -- ---- NEW in 207 (BRD §6.2, §13) ---------------------------------
    @organization_id          BIGINT        = NULL,   -- required when no gap
    @source_type_code         NVARCHAR(40)  = NULL,   -- derived from the gap when omitted
    @source_record_id         BIGINT        = NULL,
    @source_reference         NVARCHAR(200) = NULL,
    @source_description       NVARCHAR(MAX) = NULL,
    @identified_dt            DATETIME2     = NULL,
    @business_unit            NVARCHAR(200) = NULL,
    @assigned_analyst_employee_id BIGINT    = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @org_id       BIGINT = @organization_id,
            @gap_title    NVARCHAR(250),
            @gap_severity NVARCHAR(30),
            @src_centre   NVARCHAR(60);

    -- ---- Resolve the gap, if one was given --------------------------
    IF @custom_gap_id IS NOT NULL
    BEGIN
        DECLARE @gap_org BIGINT;
        SELECT @gap_org      = organization_id,
               @gap_title    = title,
               @gap_severity = severity_code
          FROM grac_practice.custom_gap
         WHERE custom_gap_id = @custom_gap_id;

        IF @gap_org IS NULL
            THROW 55401, 'sp_risk_candidate_create: custom_gap not found.', 1;

        SET @org_id = COALESCE(@org_id, @gap_org);

        -- Derivation. Only fills what the caller did not supply, so an
        -- Exception Centre raising a gap-backed candidate can still say
        -- 'Exception' and keep the gap link.
        IF @source_type_code IS NULL
        BEGIN
            SET @source_type_code = N'Gap';
            SET @source_record_id = COALESCE(@source_record_id, @custom_gap_id);
            SET @source_reference = COALESCE(@source_reference,
                                             CONCAT(N'GAP-', CAST(@custom_gap_id AS NVARCHAR(20))));
        END
    END

    -- ---- Validate the source (BRD §24 rule 7 at intake) -------------
    IF @custom_gap_id IS NULL AND @source_type_code IS NULL
        THROW 56200, 'sp_risk_candidate_create: either custom_gap_id or source_type_code is required — a candidate must know where it came from (BRD 6.1).', 1;

    IF @org_id IS NULL
        THROW 56201, 'sp_risk_candidate_create: organization_id is required when no custom_gap_id is supplied.', 1;

    SELECT @src_centre = source_centre_code
      FROM grac_practice.risk_source_master
     WHERE source_type_code = @source_type_code AND status = N'Active';

    IF NOT EXISTS (SELECT 1 FROM grac_practice.risk_source_master
                    WHERE source_type_code = @source_type_code AND status = N'Active')
        THROW 56202, 'sp_risk_candidate_create: unknown or inactive source_type_code. Add it to grac_practice.risk_source_master first (BRD 13).', 1;

    -- §4B is explicit that a custom risk has NO candidate stage. Letting
    -- one exist would create a second, unanalysed path into the register.
    IF @source_type_code = N'Custom'
        THROW 56203, 'sp_risk_candidate_create: Custom risks do not use the candidate stage — call sp_risk_custom_create (BRD 4B).', 1;

    -- ---- Idempotency (generalised from 170's per-gap rule) ----------
    -- Open statuses plus Registered: a source that already produced a
    -- registered risk must not silently raise a second candidate for the
    -- same thing. Rejected / Withdrawn / ClosedAsDuplicate do NOT block —
    -- if the condition recurs after being dismissed, that is new
    -- information and deserves a fresh candidate.
    IF @source_record_id IS NOT NULL
    BEGIN
        DECLARE @existing_id BIGINT =
            (SELECT TOP 1 risk_candidate_id
               FROM grac_practice.risk_candidate
              WHERE source_type_code = @source_type_code
                AND source_record_id = @source_record_id
                AND status_code IN (N'Pending', N'UnderAnalysis',
                                    N'ClarificationRequired', N'AnalysisCompleted',
                                    N'Accepted', N'Registered')
              ORDER BY risk_candidate_id DESC);
        IF @existing_id IS NOT NULL
        BEGIN
            SELECT @existing_id AS RiskCandidateId, CAST(0 AS BIT) AS Created;
            RETURN;
        END
    END

    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    DECLARE @title NVARCHAR(300) =
        COALESCE(@candidate_title,
                 CASE WHEN @gap_title IS NOT NULL THEN N'Risk: ' + @gap_title END,
                 CASE WHEN @source_reference IS NOT NULL THEN N'Risk: ' + @source_reference END,
                 CONCAT(N'Risk from ', @source_type_code));

    DECLARE @severity NVARCHAR(30) = COALESCE(@severity_code, @gap_severity);
    DECLARE @new_id   BIGINT;

    BEGIN TRY
        BEGIN TRAN;

        INSERT INTO grac_practice.risk_candidate
            (organization_id, custom_gap_id,
             candidate_title, candidate_summary,
             severity_code, severity_name,
             impact_summary, likelihood_summary,
             status_code,
             source_type_code, source_record_id, source_reference,
             source_description, source_centre_code,
             identified_dt, business_unit, assigned_analyst_employee_id,
             requested_by_employee_id, requested_dt,
             record_status_id, entered_by, entered_dt)
        VALUES
            (@org_id, @custom_gap_id,
             @title, @candidate_summary,
             @severity, @severity_name,
             @impact_summary, @likelihood_summary,
             N'Pending',                                   -- BRD §16 "New"
             @source_type_code, @source_record_id, @source_reference,
             COALESCE(@source_description, @candidate_summary),
             @src_centre,
             COALESCE(@identified_dt, SYSUTCDATETIME()),
             @business_unit, @assigned_analyst_employee_id,
             @requested_by_employee_id, SYSUTCDATETIME(),
             @active_rs, @caller_display_name, SYSUTCDATETIME());

        SET @new_id = SCOPE_IDENTITY();

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@new_id, N'Create', NULL, N'Pending',
             CONCAT(N'Raised from ', @source_type_code,
                    CASE WHEN @source_reference IS NULL THEN N''
                         ELSE CONCAT(N' ', @source_reference) END,
                    CASE WHEN @candidate_summary IS NULL THEN N''
                         ELSE CONCAT(N'. ', @candidate_summary) END),
             @requested_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @new_id AS RiskCandidateId, CAST(1 AS BIT) AS Created;
END;
GO

-- =====================================================================
-- 4. sp_risk_register_insert -- 354's exact body (no risk_number
--    generation, no risk_number in the INSERT).
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
        THROW 56110, 'sp_risk_register_insert: risk_analysis_id is required — a risk cannot be registered without its assessment (BRD 24.1).', 1;
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
        @threat_id INT, @threat_name NVARCHAR(400), @threat_desc NVARCHAR(MAX),
        @vuln_id INT, @vuln_name NVARCHAR(400), @vuln_desc NVARCHAR(MAX),
        @bf_id BIGINT, @bf_name NVARCHAR(200),
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
           @threat_id   = threat_id,
           @threat_name = threat_name,
           @threat_desc = threat_description,
           @vuln_id     = vulnerability_id,
           @vuln_name   = vulnerability_name,
           @vuln_desc   = vulnerability_description,
           @bf_id       = business_function_id,
           @bf_name     = business_function_name,
           @already_registered = risk_register_id
      FROM grac_practice.risk_analysis
     WHERE risk_analysis_id = @risk_analysis_id;

    IF @org_id IS NULL
        THROW 56113, 'sp_risk_register_insert: assessment not found.', 1;
    IF @already_registered IS NOT NULL
        THROW 56114, 'sp_risk_register_insert: this assessment has already been registered.', 1;

    -- 354: derive linked_practice_id when the caller did not name one
    -- and this risk's source is a Gap. source_record_id is the
    -- custom_gap_id whichever route supplied it -- sp_risk_candidate_
    -- register forwards the candidate's own source_record_id here
    -- unchanged (Route A), and a direct/custom caller that names a Gap
    -- source on the register itself lands here too (Route B, 206) --
    -- so one check covers both of 261's routes at once. Org-scoped,
    -- same as 261's backfill, so a gap and instance that happen to
    -- share an id under a different organisation can never match.
    IF @linked_practice_id IS NULL
       AND @source_type_code = N'Gap'
       AND @source_record_id IS NOT NULL
        SELECT @linked_practice_id = pi.practice_id
          FROM grac_practice.custom_gap g
          JOIN grac_practice.practice_instance pi
               ON pi.practice_instance_id = g.source_reference_id
         WHERE g.custom_gap_id        = @source_record_id
           AND g.source_reference_type = N'PracticeInstance'
           AND pi.organization_id      = @org_id;

    -- ---- The mandatory-field gate (the five stage-1 fields) ---------
    -- 56116 (category), 56117 (likelihood), 56118 (impact) and 56119
    -- (rating) are RETIRED by 216: those belong to stage 2 now. The
    -- numbers are not reused, so an old log line still means what it
    -- said.
    IF @statement IS NULL OR LEN(LTRIM(RTRIM(@statement))) = 0
        THROW 56115, 'sp_risk_register_insert: assessment is incomplete — risk statement is required.', 1;
    IF @threat_id IS NULL
        THROW 56410, 'sp_risk_register_insert: assessment is incomplete — a threat is required.', 1;
    IF @vuln_id IS NULL
        THROW 56411, 'sp_risk_register_insert: assessment is incomplete — a vulnerability is required.', 1;
    IF @owner_id IS NULL
        THROW 56120, 'sp_risk_register_insert: assessment is incomplete — risk owner is required.', 1;

    IF @source_type_code = N'Custom' AND @risk_candidate_id IS NOT NULL
        THROW 56121, 'sp_risk_register_insert: a Custom risk cannot carry a candidate (BRD 24.8).', 1;
    IF @source_type_code <> N'Custom' AND @scope = N'Custom'
        THROW 56122, 'sp_risk_register_insert: a custom-scoped assessment must register with source type Custom (BRD 24.8).', 1;

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
         threat_id, threat_name, threat_description,
         vulnerability_id, vulnerability_name, vulnerability_description,
         business_function_id, business_function_name, analysis_pending,
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
         @threat_id, @threat_name, @threat_desc,
         @vuln_id, @vuln_name, @vuln_desc,
         @bf_id, @bf_name,
         CASE WHEN @rt_code IS NULL THEN 1 ELSE 0 END,
         @linked_asset_id, @linked_vendor_id, @linked_practice_id,
         @linked_obligation_id, @linked_control_id,
         N'Active', SYSUTCDATETIME(), @registered_by_employee_id,
         @active_rs, @caller_display_name, SYSUTCDATETIME());

    SET @risk_register_id = SCOPE_IDENTITY();

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
                N'; assessment #', CAST(@risk_analysis_id AS NVARCHAR(20)),
                CASE WHEN @rt_code IS NULL
                     THEN N'; rating pending analysis'
                     ELSE CONCAT(N'; inherent rating ', @rt_code) END),
         @registered_by_employee_id, @caller_display_name,
         @caller_display_name, SYSUTCDATETIME());
END;
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '378 rollback-a candidate_number is computed again' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.computed_columns
                           WHERE object_id = OBJECT_ID('grac_practice.risk_candidate')
                             AND name = 'candidate_number')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '378 rollback-b risk_number is computed again',
       CASE WHEN EXISTS (SELECT 1 FROM sys.computed_columns
                           WHERE object_id = OBJECT_ID('grac_practice.risk_register')
                             AND name = 'risk_number')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '378 rollback-c uq_pm_risk_candidate_number removed',
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.key_constraints
                               WHERE name = 'uq_pm_risk_candidate_number')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '378 rollback-d uq_pm_risk_register_number removed',
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.key_constraints
                               WHERE name = 'uq_pm_risk_register_number')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '378 rollback-e ix_pm_risk_register_number present',
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                           WHERE name = 'ix_pm_risk_register_number'
                             AND object_id = OBJECT_ID('grac_practice.risk_register'))
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '378 rollback-f sp_risk_candidate_create compiled',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_candidate_create','P')) IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '378 rollback-g sp_risk_register_insert compiled',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_insert','P')) IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;

-- Diagnostic -- sample of the restored RC-<org>-<id> / RSK-<org>-<id>
-- shape.
PRINT '--- Diagnostic: candidate_number sample after rollback ---';
SELECT TOP 5 organization_id, candidate_number, risk_candidate_id
  FROM grac_practice.risk_candidate
 ORDER BY risk_candidate_id DESC;

PRINT '--- Diagnostic: risk_number sample after rollback ---';
SELECT TOP 5 organization_id, risk_number, risk_register_id
  FROM grac_practice.risk_register
 ORDER BY risk_register_id DESC;

PRINT '378 rollback complete. candidate_number/risk_number are computed';
PRINT '    columns again (RC-<org>-<id> / RSK-<org>-<id>), and';
PRINT '    sp_risk_candidate_create/sp_risk_register_insert are back to';
PRINT '    their pre-378 bodies (207/354).';
GO
SET NOEXEC OFF;
GO
