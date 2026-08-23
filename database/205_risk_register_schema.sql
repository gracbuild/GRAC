-- =====================================================================
-- 205 Risk Centre — Risk Candidate generalisation + Initial Risk
--     Analysis + Risk Register
--     (Risk Candidate Analysis and Risk Register BRD §3, §6-§10, §16,
--      §17, §20, §26)
--
-- THE ONE RULE THIS SCHEMA EXISTS TO ENFORCE
-- ------------------------------------------
-- BRD §1: "Every risk entering the Risk Register must pass through an
-- initial Risk Analysis, irrespective of its source." §24 rule 1 repeats
-- it as a hard business rule.
--
-- That is why risk_register.risk_analysis_id is NOT NULL. It is not a
-- convenience link — it is the constraint. There is no INSERT into
-- risk_register that does not name the analysis that justified it, which
-- makes "Analyse Before Register" (§27) provable from the data alone
-- rather than trusted to application code.
--
-- WHAT WAS ALREADY HERE, AND WHAT WAS WRONG WITH IT
-- -------------------------------------------------
-- 169 built risk_candidate as a placeholder with custom_gap_id BIGINT
-- NOT NULL. That single column made the Gap Centre the only possible
-- source, which BRD §4A (Gap, Exception, Assurance, Obligation,
-- Practice, "other GRAC modules") and §13 (ten source types) both
-- contradict. 169's own header called the register linkage a
-- "placeholder ... when the Risk module ships".
--
-- This is that module. The table is GENERALISED IN PLACE rather than
-- replaced, because 172 (gap analysis), 176 (exception rejection) and
-- 199 (Task Centre treatment candidates) all bind to it and all keep
-- working untouched.
--
-- WHAT THIS MIGRATION ADDS
-- ------------------------
--   1. risk_candidate  — source model, analyst assignment, BRD §16
--                        statuses, register + duplicate links.
--                        custom_gap_id becomes NULLABLE.
--   2. risk_analysis   — BRD §7.1, versioned (§20).
--   3. risk_register   — BRD §9.1, the authoritative repository.
--   4. risk_register_history — BRD §20 audit trail.
--
-- STATUS VOCABULARY — MAPPED, NOT REPLACED
-- ----------------------------------------
-- BRD §16 suggests: New, Under Analysis, Clarification Required,
-- Analysis Completed, Registered, Rejected, Closed as Duplicate.
--
-- 169 shipped: Pending, Accepted, Rejected, Withdrawn — and 172, 176 and
-- 199 write those words today. Renaming Pending to New would break three
-- live migrations for a cosmetic gain, so:
--
--   BRD status              stored code            note
--   ----------------------  --------------------   ------------------------
--   New                     Pending                existing code kept; UI
--                                                  labels it "New"
--   Under Analysis          UnderAnalysis          new
--   Clarification Required  ClarificationRequired  new
--   Analysis Completed      AnalysisCompleted      new
--   Registered              Registered             new
--   Rejected                Rejected               existing
--   Closed as Duplicate     ClosedAsDuplicate      new
--   (not in BRD)            Withdrawn              existing, kept
--   (not in BRD)            Accepted               LEGACY. 169/199's
--                                                  pre-register triage
--                                                  state. Retained so
--                                                  historical rows stay
--                                                  readable; no new code
--                                                  path writes it except
--                                                  sp_risk_candidate_accept,
--                                                  which 206 documents as
--                                                  superseded by
--                                                  sp_risk_candidate_register.
--
-- ADDITIVE ONLY. Idempotent. No existing row is rewritten except the
-- source backfill in §1.4, which is 207's job for the trigger side and
-- is done here only so the NOT NULL can be applied safely.
--
-- ERROR CODE RANGE: 56020-56039 (schema-time only; procs use 56040+)
-- Rollback: database/205_risk_register_schema_rollback.sql
-- Depends:  204_risk_scoring_masters.sql
-- Next:     206_risk_register_procs.sql
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF OBJECT_ID('grac_practice.risk_candidate','U') IS NULL
BEGIN PRINT 'ABORT (205): risk_candidate missing — run 169_risk_centre_schema.sql first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.risk_source_master','U') IS NULL
BEGIN PRINT 'ABORT (205): risk_source_master missing — run 204_risk_scoring_masters.sql first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.organization_employee','U') IS NULL
BEGIN PRINT 'ABORT (205): organization_employee missing — run 009 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN PRINT 'ABORT (205): record_status_master missing — run 008 first.'; SET @ok = 0; END

IF @ok = 0
BEGIN
    RAISERROR('205_risk_register_schema: prerequisites missing — see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. risk_candidate — generalisation
-- =====================================================================

-- ---- 1.1 Source model (BRD §6.2, §10, §13) --------------------------
-- source_type_code + source_record_id is the pair every GRAC Centre uses
-- to point at its own record (same shape as task_candidate, 197). It is
-- what makes §13 extensible: a new Centre adds a risk_source_master row
-- and starts calling sp_risk_candidate_create. No schema change.
IF COL_LENGTH('grac_practice.risk_candidate','source_type_code') IS NULL
    ALTER TABLE grac_practice.risk_candidate ADD source_type_code NVARCHAR(40) NULL;
GO
IF COL_LENGTH('grac_practice.risk_candidate','source_record_id') IS NULL
    ALTER TABLE grac_practice.risk_candidate ADD source_record_id BIGINT NULL;
GO
-- Display label the source owns, e.g. 'GAP-101', 'OBS-2026-004'.
IF COL_LENGTH('grac_practice.risk_candidate','source_reference') IS NULL
    ALTER TABLE grac_practice.risk_candidate ADD source_reference NVARCHAR(200) NULL;
GO
-- BRD §6.2 "Source Description" / §10 "Original observation / trigger".
-- Frozen at candidate creation: the source record may later be edited or
-- closed, and §10 requires the register to retain what was observed.
IF COL_LENGTH('grac_practice.risk_candidate','source_description') IS NULL
    ALTER TABLE grac_practice.risk_candidate ADD source_description NVARCHAR(MAX) NULL;
GO
-- Denormalised from risk_source_master for the §10 navigation link, so
-- the "open originating Centre" affordance needs no join at render time.
IF COL_LENGTH('grac_practice.risk_candidate','source_centre_code') IS NULL
    ALTER TABLE grac_practice.risk_candidate ADD source_centre_code NVARCHAR(60) NULL;
GO

-- ---- 1.2 Candidate context (BRD §6.2) -------------------------------
-- "Date Identified" is distinct from requested_dt: a gap found in March
-- and triaged in June was identified in March, and candidate ageing
-- (§23) must not flatter itself by measuring from the triage date.
IF COL_LENGTH('grac_practice.risk_candidate','identified_dt') IS NULL
    ALTER TABLE grac_practice.risk_candidate ADD identified_dt DATETIME2 NULL;
GO
IF COL_LENGTH('grac_practice.risk_candidate','business_unit') IS NULL
    ALTER TABLE grac_practice.risk_candidate ADD business_unit NVARCHAR(200) NULL;
GO
-- BRD §6.2 "Assigned Risk Analyst / Owner", §18 Risk Analyst role.
IF COL_LENGTH('grac_practice.risk_candidate','assigned_analyst_employee_id') IS NULL
    ALTER TABLE grac_practice.risk_candidate ADD assigned_analyst_employee_id BIGINT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
                WHERE name = 'fk_pm_risk_candidate_analyst'
                  AND parent_object_id = OBJECT_ID('grac_practice.risk_candidate'))
    ALTER TABLE grac_practice.risk_candidate
        ADD CONSTRAINT fk_pm_risk_candidate_analyst
            FOREIGN KEY (assigned_analyst_employee_id)
            REFERENCES grac_practice.organization_employee(employee_id);
GO

-- ---- 1.3 Decision outcomes (BRD §8B, §8C, §15) ----------------------
-- §8C: "returned to the relevant owner or analyst for additional
-- information". The note is a column and not only a history row because
-- the Candidates grid has to show WHAT was asked without opening the
-- audit trail.
IF COL_LENGTH('grac_practice.risk_candidate','clarification_note') IS NULL
    ALTER TABLE grac_practice.risk_candidate ADD clarification_note NVARCHAR(MAX) NULL;
GO
IF COL_LENGTH('grac_practice.risk_candidate','clarification_requested_dt') IS NULL
    ALTER TABLE grac_practice.risk_candidate ADD clarification_requested_dt DATETIME2 NULL;
GO
-- §15: "Close the candidate as duplicate" — pointing at the register
-- entry it duplicates, so the closure is navigable and not just a reason
-- string.
IF COL_LENGTH('grac_practice.risk_candidate','duplicate_of_risk_id') IS NULL
    ALTER TABLE grac_practice.risk_candidate ADD duplicate_of_risk_id BIGINT NULL;
GO
-- §10 traceability, forward direction: Candidate -> Registered Risk.
-- (The reverse lives on risk_register.risk_candidate_id. Both are stored
-- because the Candidates grid and the Register grid each need their own
-- direction on a hot path — same reasoning as 197 §3.)
IF COL_LENGTH('grac_practice.risk_candidate','registered_risk_id') IS NULL
    ALTER TABLE grac_practice.risk_candidate ADD registered_risk_id BIGINT NULL;
GO

-- ---- 1.4 Backfill, then generalise custom_gap_id --------------------
-- Every row that exists today came from a gap (169 §SOURCING), so the
-- backfill is exact, not a guess.
UPDATE grac_practice.risk_candidate
   SET source_type_code   = N'Gap',
       source_record_id   = custom_gap_id,
       source_reference   = CONCAT(N'GAP-', CAST(custom_gap_id AS NVARCHAR(20))),
       source_centre_code = N'GapCentre'
 WHERE source_type_code IS NULL
   AND custom_gap_id IS NOT NULL;
GO

UPDATE grac_practice.risk_candidate
   SET identified_dt = requested_dt
 WHERE identified_dt IS NULL;
GO

-- Now the source columns can carry the invariant the gap FK used to.
IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('grac_practice.risk_candidate')
              AND name = 'source_type_code' AND is_nullable = 1)
   AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_candidate WHERE source_type_code IS NULL)
    ALTER TABLE grac_practice.risk_candidate ALTER COLUMN source_type_code NVARCHAR(40) NOT NULL;
GO

-- A DEFAULT of 'Gap' looks redundant next to 207, which teaches
-- sp_risk_candidate_create to supply the source explicitly. It is there
-- for the window BETWEEN the two migrations: 172 and 176 call the 170
-- version of that proc, which knows nothing about source_type_code, and
-- without a default the NOT NULL above would make every gap analysis
-- save fail until 207 lands. Deployments are not always atomic, and a
-- half-applied migration set must degrade, not break.
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints
                WHERE name = 'df_pm_risk_candidate_source_type'
                  AND parent_object_id = OBJECT_ID('grac_practice.risk_candidate'))
    ALTER TABLE grac_practice.risk_candidate
        ADD CONSTRAINT df_pm_risk_candidate_source_type
            DEFAULT N'Gap' FOR source_type_code;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
                WHERE name = 'fk_pm_risk_candidate_source_type'
                  AND parent_object_id = OBJECT_ID('grac_practice.risk_candidate'))
    ALTER TABLE grac_practice.risk_candidate
        ADD CONSTRAINT fk_pm_risk_candidate_source_type
            FOREIGN KEY (source_type_code)
            REFERENCES grac_practice.risk_source_master(source_type_code);
GO

-- THE KEY CHANGE. A candidate from Assurance, Obligation, Asset, Vendor
-- or Event has no gap, so the column that made Gap mandatory has to go
-- nullable. The FK itself is kept: when a gap IS the source, the link
-- must still be referentially sound, and 172/176 rely on it.
--
-- 169 put custom_gap_id in two indexes — as a key column in
-- ix_pm_risk_candidate_gap and as an INCLUDE in
-- ix_pm_risk_candidate_org_status. SQL Server refuses ALTER COLUMN on an
-- indexed column (error 5074), so both are dropped and rebuilt around
-- the change, byte-identical to 169's definitions.
IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('grac_practice.risk_candidate')
              AND name = 'custom_gap_id' AND is_nullable = 0)
BEGIN
    IF EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_candidate_gap'
                  AND object_id = OBJECT_ID('grac_practice.risk_candidate'))
        DROP INDEX ix_pm_risk_candidate_gap ON grac_practice.risk_candidate;

    IF EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_candidate_org_status'
                  AND object_id = OBJECT_ID('grac_practice.risk_candidate'))
        DROP INDEX ix_pm_risk_candidate_org_status ON grac_practice.risk_candidate;

    ALTER TABLE grac_practice.risk_candidate ALTER COLUMN custom_gap_id BIGINT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_candidate_gap'
                  AND object_id = OBJECT_ID('grac_practice.risk_candidate'))
    CREATE INDEX ix_pm_risk_candidate_gap
        ON grac_practice.risk_candidate(custom_gap_id, status_code);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_candidate_org_status'
                  AND object_id = OBJECT_ID('grac_practice.risk_candidate'))
    CREATE INDEX ix_pm_risk_candidate_org_status
        ON grac_practice.risk_candidate(organization_id, status_code, requested_dt DESC)
        INCLUDE(custom_gap_id, candidate_title, severity_code);
GO

-- ---- 1.5 Status vocabulary (BRD §16) --------------------------------
-- See the header mapping table for why the legacy codes survive.
IF EXISTS (SELECT 1 FROM sys.check_constraints
            WHERE name = 'ck_pm_risk_candidate_status'
              AND parent_object_id = OBJECT_ID('grac_practice.risk_candidate'))
    ALTER TABLE grac_practice.risk_candidate DROP CONSTRAINT ck_pm_risk_candidate_status;
GO

ALTER TABLE grac_practice.risk_candidate WITH NOCHECK
    ADD CONSTRAINT ck_pm_risk_candidate_status
        CHECK (status_code IN (
            N'Pending',                -- BRD "New"
            N'UnderAnalysis',
            N'ClarificationRequired',
            N'AnalysisCompleted',
            N'Registered',
            N'Rejected',
            N'ClosedAsDuplicate',
            N'Withdrawn',              -- pre-BRD, retained
            N'Accepted'                -- legacy triage state, retained
        ));
GO

-- A candidate that says it is Registered must name the risk it became,
-- and nothing else may claim one. This is the candidate-side half of the
-- §1 invariant; risk_analysis_id NOT NULL on the register is the other.
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_risk_candidate_registered_link'
                  AND parent_object_id = OBJECT_ID('grac_practice.risk_candidate'))
    ALTER TABLE grac_practice.risk_candidate WITH NOCHECK
        ADD CONSTRAINT ck_pm_risk_candidate_registered_link
            CHECK ((status_code =  N'Registered' AND registered_risk_id IS NOT NULL)
                OR (status_code <> N'Registered' AND registered_risk_id IS NULL));
GO

-- BRD §15: closing as duplicate is only meaningful against a real
-- register entry.
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_risk_candidate_duplicate_link'
                  AND parent_object_id = OBJECT_ID('grac_practice.risk_candidate'))
    ALTER TABLE grac_practice.risk_candidate WITH NOCHECK
        ADD CONSTRAINT ck_pm_risk_candidate_duplicate_link
            CHECK (status_code <> N'ClosedAsDuplicate' OR duplicate_of_risk_id IS NOT NULL);
GO

-- ---- 1.6 Candidate number -------------------------------------------
-- Mirrors task_candidate.candidate_number (197) so every Centre's
-- records read alike on screen.
IF COL_LENGTH('grac_practice.risk_candidate','candidate_number') IS NULL
    ALTER TABLE grac_practice.risk_candidate ADD candidate_number AS
        (CONCAT('RC-', CAST(organization_id AS NVARCHAR(20)), '-',
                       CAST(risk_candidate_id AS NVARCHAR(20)))) PERSISTED;
GO

-- =====================================================================
-- 2. risk_analysis  (BRD §7, §7.1, §8, §12, §20)
--
-- WHY THIS IS A TABLE AND NOT COLUMNS ON THE CANDIDATE
-- ---------------------------------------------------
-- Three reasons, all from the BRD.
--
--  1. §20: "Previous risk ratings and analysis values shall not be
--     overwritten without retaining historical versions." Columns on the
--     candidate can only hold the latest value. Rows can hold every one.
--
--  2. §4B / §11: a Custom Risk has NO candidate. If the analysis lived
--     on the candidate, the custom route would need a second copy of
--     every §7.1 field — and §12 forbids exactly that ("the system shall
--     reuse the same ... mandatory fields ... the only difference shall
--     be the entry route").
--
--  3. §10: the register must be able to navigate
--     "Risk Register -> Risk Analysis -> Risk Candidate -> Original
--     Source". That is a three-hop chain, so the middle hop needs an
--     identity.
--
-- SCOPE
-- -----
-- analysis_scope_code = 'Candidate' -> risk_candidate_id is required
--                     = 'Custom'    -> no candidate exists (§4B); the
--                                      row is created inside
--                                      sp_risk_custom_create and stamped
--                                      with risk_register_id in the same
--                                      transaction.
--
-- VERSIONING
-- ----------
-- Every save writes a NEW row with analysis_version = previous + 1 and
-- flips is_current. Nothing is ever UPDATEd except the is_current flag
-- and the register back-link, which is what makes §20 true by
-- construction rather than by discipline.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_analysis','U') IS NULL
CREATE TABLE grac_practice.risk_analysis(
    risk_analysis_id      BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_analysis PRIMARY KEY,
    organization_id       BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_analysis_organization
            REFERENCES grac_practice.organization(organization_id),

    analysis_scope_code   NVARCHAR(20) NOT NULL
        CONSTRAINT df_pm_risk_analysis_scope DEFAULT N'Candidate',
    risk_candidate_id     BIGINT NULL
        CONSTRAINT fk_pm_risk_analysis_candidate
            REFERENCES grac_practice.risk_candidate(risk_candidate_id),
    -- Back-link, stamped after the register row exists. NULL while the
    -- analysis is still a proposal.
    risk_register_id      BIGINT NULL,

    analysis_version      INT NOT NULL
        CONSTRAINT df_pm_risk_analysis_version DEFAULT 1,
    is_current            BIT NOT NULL
        CONSTRAINT df_pm_risk_analysis_current DEFAULT 1,

    -- ---- BRD §7.1 minimum analysis information ----------------------
    risk_statement        NVARCHAR(1000) NOT NULL,
    risk_category_code    NVARCHAR(60)  NULL,
    risk_category_name    NVARCHAR(200) NULL,
    risk_description      NVARCHAR(MAX) NULL,
    risk_cause            NVARCHAR(MAX) NULL,
    potential_consequence NVARCHAR(MAX) NULL,
    existing_controls     NVARCHAR(MAX) NULL,

    -- Scale values are stored as code + name + level. The level is what
    -- the matrix is keyed on; the name is frozen so a later rename of
    -- "Possible" to "Occasional" does not silently rewrite history.
    likelihood_code       NVARCHAR(60)  NULL,
    likelihood_name       NVARCHAR(200) NULL,
    likelihood_value      INT NULL,
    impact_code           NVARCHAR(60)  NULL,
    impact_name           NVARCHAR(200) NULL,
    impact_value          INT NULL,

    -- Resolved from risk_matrix_cell at save time (206). Never typed in.
    inherent_rating_code  NVARCHAR(30)  NULL,
    inherent_rating_name  NVARCHAR(120) NULL,
    inherent_rating_score INT NULL,

    risk_owner_employee_id BIGINT NULL
        CONSTRAINT fk_pm_risk_analysis_owner
            REFERENCES grac_practice.organization_employee(employee_id),
    business_unit         NVARCHAR(200) NULL,
    process_name          NVARCHAR(200) NULL,
    analyst_remarks       NVARCHAR(MAX) NULL,

    analysis_dt           DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_analysis_dt DEFAULT SYSUTCDATETIME(),
    analysed_by_employee_id BIGINT NULL
        CONSTRAINT fk_pm_risk_analysis_analyst
            REFERENCES grac_practice.organization_employee(employee_id),

    -- ---- BRD §8 decision --------------------------------------------
    -- NULL while the analysis is still being worked. Set when the
    -- analyst takes A / B / C.
    decision_code         NVARCHAR(30) NULL,     -- Register | Reject | Clarify
    decision_note         NVARCHAR(MAX) NULL,
    decision_dt           DATETIME2 NULL,
    decision_by_employee_id BIGINT NULL
        CONSTRAINT fk_pm_risk_analysis_decider
            REFERENCES grac_practice.organization_employee(employee_id),

    -- ---- BRD §19 approval, when the org configures it ---------------
    -- Phase A stores the outcome; the configurable gate that decides
    -- whether approval is REQUIRED is Phase B (see docs/risk-centre.md).
    approval_status_code  NVARCHAR(30) NULL,     -- NotRequired | Pending | Approved | Returned
    approved_by_employee_id BIGINT NULL
        CONSTRAINT fk_pm_risk_analysis_approver
            REFERENCES grac_practice.organization_employee(employee_id),
    approved_dt           DATETIME2 NULL,
    approval_note         NVARCHAR(MAX) NULL,

    record_status_id      INT NOT NULL
        CONSTRAINT fk_pm_risk_analysis_record_status
            REFERENCES grac_practice.record_status_master(record_status_id),
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_risk_analysis_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_analysis_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,

    CONSTRAINT ck_pm_risk_analysis_scope
        CHECK (analysis_scope_code IN (N'Candidate', N'Custom')),
    -- A candidate-scoped analysis without a candidate is meaningless.
    CONSTRAINT ck_pm_risk_analysis_candidate_link
        CHECK (analysis_scope_code <> N'Candidate' OR risk_candidate_id IS NOT NULL),
    CONSTRAINT ck_pm_risk_analysis_decision
        CHECK (decision_code IS NULL
            OR decision_code IN (N'Register', N'Reject', N'Clarify')),
    CONSTRAINT ck_pm_risk_analysis_approval
        CHECK (approval_status_code IS NULL
            OR approval_status_code IN (N'NotRequired', N'Pending', N'Approved', N'Returned')),
    CONSTRAINT ck_pm_risk_analysis_version CHECK (analysis_version >= 1)
);
GO

-- One current version per candidate. Custom analyses have no candidate,
-- so they are excluded — each is a single row created once.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_risk_analysis_current'
                  AND object_id = OBJECT_ID('grac_practice.risk_analysis'))
    CREATE UNIQUE INDEX ux_pm_risk_analysis_current
        ON grac_practice.risk_analysis(risk_candidate_id)
        WHERE is_current = 1 AND risk_candidate_id IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_analysis_candidate_version'
                  AND object_id = OBJECT_ID('grac_practice.risk_analysis'))
    CREATE INDEX ix_pm_risk_analysis_candidate_version
        ON grac_practice.risk_analysis(risk_candidate_id, analysis_version DESC)
        INCLUDE (inherent_rating_code, decision_code, analysis_dt);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_analysis_org'
                  AND object_id = OBJECT_ID('grac_practice.risk_analysis'))
    CREATE INDEX ix_pm_risk_analysis_org
        ON grac_practice.risk_analysis(organization_id, is_current, analysis_dt DESC);
GO

-- =====================================================================
-- 3. risk_register  (BRD §9, §9.1, §10, §17)
--
-- "The authoritative repository of formally recognised organisational
-- risks" (§9).
--
-- Every §9.1 field is a column here even where the same value also sits
-- on the analysis. That duplication is deliberate: §9 makes the register
-- authoritative, and an authoritative record that renders by joining to
-- a mutable analysis is not authoritative. The analysis stays as the
-- justification and the audit chain (§10); the register holds the risk
-- as it was recognised.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
CREATE TABLE grac_practice.risk_register(
    risk_register_id      BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_register PRIMARY KEY,
    organization_id       BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_register_organization
            REFERENCES grac_practice.organization(organization_id),

    -- ---- BRD §9.1 identity ------------------------------------------
    risk_title            NVARCHAR(300)  NOT NULL,
    risk_statement        NVARCHAR(1000) NOT NULL,
    risk_description      NVARCHAR(MAX)  NULL,
    risk_category_code    NVARCHAR(60)   NULL,
    risk_category_name    NVARCHAR(200)  NULL,

    -- ---- BRD §10 traceability ---------------------------------------
    -- source_type_code is NOT NULL because §24 rule 7 is absolute:
    -- "Every registered risk shall have a defined source." Custom risks
    -- carry 'Custom' (§24 rule 8), enforced in 206.
    source_type_code      NVARCHAR(40) NOT NULL
        CONSTRAINT fk_pm_risk_register_source_type
            REFERENCES grac_practice.risk_source_master(source_type_code),
    source_record_id      BIGINT NULL,           -- NULL for Custom
    source_reference      NVARCHAR(200) NULL,
    source_description    NVARCHAR(MAX) NULL,    -- frozen original trigger
    source_centre_code    NVARCHAR(60)  NULL,

    risk_candidate_id     BIGINT NULL            -- NULL for the custom route
        CONSTRAINT fk_pm_risk_register_candidate
            REFERENCES grac_practice.risk_candidate(risk_candidate_id),

    -- THE §1 INVARIANT. Not nullable, ever.
    risk_analysis_id      BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_register_analysis
            REFERENCES grac_practice.risk_analysis(risk_analysis_id),

    -- ---- BRD §9.1 assessment (copied from the analysis at registration)
    risk_owner_employee_id BIGINT NULL
        CONSTRAINT fk_pm_risk_register_owner
            REFERENCES grac_practice.organization_employee(employee_id),
    business_unit         NVARCHAR(200) NULL,
    process_name          NVARCHAR(200) NULL,
    risk_cause            NVARCHAR(MAX) NULL,
    potential_consequence NVARCHAR(MAX) NULL,
    existing_controls     NVARCHAR(MAX) NULL,

    likelihood_code       NVARCHAR(60)  NULL,
    likelihood_name       NVARCHAR(200) NULL,
    likelihood_value      INT NULL,
    impact_code           NVARCHAR(60)  NULL,
    impact_name           NVARCHAR(200) NULL,
    impact_value          INT NULL,
    inherent_rating_code  NVARCHAR(30)  NULL,
    inherent_rating_name  NVARCHAR(120) NULL,
    inherent_rating_score INT NULL,

    -- ---- BRD §9.1 related records, where applicable -----------------
    -- Soft references. A hard FK per Centre would make the Risk Centre
    -- depend on every module that can name a risk, which is the coupling
    -- §13 asks us to avoid.
    linked_asset_id       BIGINT NULL,
    linked_vendor_id      BIGINT NULL,
    linked_practice_id    BIGINT NULL,
    linked_obligation_id  BIGINT NULL,
    linked_control_id     BIGINT NULL,

    -- ---- BRD §17 lifecycle ------------------------------------------
    status_code           NVARCHAR(30) NOT NULL
        CONSTRAINT df_pm_risk_register_status DEFAULT N'Active',

    registered_dt         DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_register_registered_dt DEFAULT SYSUTCDATETIME(),
    registered_by_employee_id BIGINT NULL
        CONSTRAINT fk_pm_risk_register_registrar
            REFERENCES grac_practice.organization_employee(employee_id),

    closed_dt             DATETIME2 NULL,
    closed_by_employee_id BIGINT NULL
        CONSTRAINT fk_pm_risk_register_closer
            REFERENCES grac_practice.organization_employee(employee_id),
    closure_reason        NVARCHAR(MAX) NULL,

    record_status_id      INT NOT NULL
        CONSTRAINT fk_pm_risk_register_record_status
            REFERENCES grac_practice.record_status_master(record_status_id),
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_risk_register_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_register_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,

    -- BRD §9.1 "Risk ID". Human-facing, stable, org-qualified — the
    -- string that goes in board packs and audit requests.
    risk_number AS
        (CONCAT('RSK-', CAST(organization_id AS NVARCHAR(20)), '-',
                        CAST(risk_register_id AS NVARCHAR(20)))) PERSISTED,

    CONSTRAINT ck_pm_risk_register_status
        CHECK (status_code IN (N'Active', N'UnderTreatment', N'Accepted',
                               N'Monitoring', N'Closed', N'Retired')),
    -- A closed or retired risk must say why; §20 requires the trail and
    -- a NULL reason breaks it at exactly the moment it matters.
    CONSTRAINT ck_pm_risk_register_closure
        CHECK (status_code NOT IN (N'Closed', N'Retired') OR closure_reason IS NOT NULL),
    -- §24 rule 8, both directions.
    CONSTRAINT ck_pm_risk_register_custom_source
        CHECK ((source_type_code =  N'Custom' AND risk_candidate_id IS NULL)
            OR (source_type_code <> N'Custom'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_register_org_status'
                  AND object_id = OBJECT_ID('grac_practice.risk_register'))
    CREATE INDEX ix_pm_risk_register_org_status
        ON grac_practice.risk_register(organization_id, status_code, registered_dt DESC)
        INCLUDE (risk_title, risk_category_code, source_type_code,
                 inherent_rating_code, risk_owner_employee_id);
GO

-- BRD §23: "Risks by source", and the §10 reverse lookup
-- "which risk did this gap produce?".
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_register_source'
                  AND object_id = OBJECT_ID('grac_practice.risk_register'))
    CREATE INDEX ix_pm_risk_register_source
        ON grac_practice.risk_register(source_type_code, source_record_id)
        INCLUDE (organization_id, status_code, risk_title);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_register_candidate'
                  AND object_id = OBJECT_ID('grac_practice.risk_register'))
    CREATE INDEX ix_pm_risk_register_candidate
        ON grac_practice.risk_register(risk_candidate_id)
        WHERE risk_candidate_id IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_register_number'
                  AND object_id = OBJECT_ID('grac_practice.risk_register'))
    CREATE INDEX ix_pm_risk_register_number
        ON grac_practice.risk_register(risk_number);
GO

-- ---- Close the traceability cycle -----------------------------------
-- risk_candidate.registered_risk_id and risk_candidate.duplicate_of_risk_id
-- could not be FK'd until risk_register existed. Both are nullable, so
-- the cycle is inert — the same pattern already used elsewhere in this
-- schema for definition/version pairs.
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
                WHERE name = 'fk_pm_risk_candidate_registered_risk'
                  AND parent_object_id = OBJECT_ID('grac_practice.risk_candidate'))
    ALTER TABLE grac_practice.risk_candidate
        ADD CONSTRAINT fk_pm_risk_candidate_registered_risk
            FOREIGN KEY (registered_risk_id)
            REFERENCES grac_practice.risk_register(risk_register_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
                WHERE name = 'fk_pm_risk_candidate_duplicate_risk'
                  AND parent_object_id = OBJECT_ID('grac_practice.risk_candidate'))
    ALTER TABLE grac_practice.risk_candidate
        ADD CONSTRAINT fk_pm_risk_candidate_duplicate_risk
            FOREIGN KEY (duplicate_of_risk_id)
            REFERENCES grac_practice.risk_register(risk_register_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
                WHERE name = 'fk_pm_risk_analysis_register'
                  AND parent_object_id = OBJECT_ID('grac_practice.risk_analysis'))
    ALTER TABLE grac_practice.risk_analysis
        ADD CONSTRAINT fk_pm_risk_analysis_register
            FOREIGN KEY (risk_register_id)
            REFERENCES grac_practice.risk_register(risk_register_id);
GO

-- =====================================================================
-- 4. risk_register_history  (BRD §20)
--
-- Same shape as risk_candidate_history (169), task_candidate_history
-- (197) and exception_request_history (161) — every Centre's audit log
-- reads the same way, and the UI renders them with one component.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_register_history','U') IS NULL
CREATE TABLE grac_practice.risk_register_history(
    history_id            BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_register_history PRIMARY KEY,
    risk_register_id      BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_register_history_risk
            REFERENCES grac_practice.risk_register(risk_register_id),
    action_code           NVARCHAR(40) NOT NULL,   -- Register / StatusChange / OwnerChange / Reassess / Close
    from_status_code      NVARCHAR(30) NULL,
    to_status_code        NVARCHAR(30) NULL,
    remark                NVARCHAR(MAX) NULL,
    actor_employee_id     BIGINT NULL,
    actor_display_name    NVARCHAR(240) NULL,
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_risk_register_history_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_register_history_entered_dt DEFAULT SYSUTCDATETIME()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_register_history_risk'
                  AND object_id = OBJECT_ID('grac_practice.risk_register_history'))
    CREATE INDEX ix_pm_risk_register_history_risk
        ON grac_practice.risk_register_history(risk_register_id, entered_dt DESC)
        INCLUDE (action_code, actor_display_name);
GO

-- =====================================================================
-- 5. Candidate source index (BRD §10 reverse lookup, §23 "by source")
-- =====================================================================
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_candidate_source'
                  AND object_id = OBJECT_ID('grac_practice.risk_candidate'))
    CREATE INDEX ix_pm_risk_candidate_source
        ON grac_practice.risk_candidate(source_type_code, source_record_id)
        INCLUDE (organization_id, status_code, candidate_title, registered_risk_id);
GO

-- =====================================================================
-- 6. Sanity
-- =====================================================================
SELECT '205 tables present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.risk_analysis','U')         IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_register','U')         IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_register_history','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'custom_gap_id is now nullable' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.risk_candidate')
                            AND name = 'custom_gap_id' AND is_nullable = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'every candidate has a source' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.risk_candidate
                              WHERE source_type_code IS NULL)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'register cannot exist without an analysis' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.risk_register')
                            AND name = 'risk_analysis_id' AND is_nullable = 0)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '205 Risk Register schema installed. Next: 206_risk_register_procs.sql';
GO

SET NOEXEC OFF;
GO
