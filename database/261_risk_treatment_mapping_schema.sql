-- =====================================================================
-- 261 Risk Centre — Practice/Asset mapping, Treatment Option,
--     Acceptance and Review  (schema only)
--
-- WHAT THIS ADDS, AND WHY EACH PIECE EXISTS
-- -----------------------------------------
-- The register today can say what a risk IS (205), how bad it is before
-- treatment (216) and how bad it is after (258). It cannot say:
--
--   * WHAT the risk touches   -> risk_practice_map / risk_asset_map
--   * WHAT was decided about it -> risk_register.treatment_option_code
--   * WHO accepted it and until when -> the acceptance block
--   * WHEN it must be looked at again -> next_review_date
--
-- Those four gaps are what this migration closes. Nothing here changes
-- an existing column, an existing constraint or an existing procedure.
--
-- ---------------------------------------------------------------------
-- DECISION 1 — TWO MAP TABLES PLUS A CONTRIBUTION TABLE, NOT ONE TABLE
-- ---------------------------------------------------------------------
-- The obvious model is a single risk_asset_map with a practice_id column
-- and one row per (risk, practice, asset). It was rejected because it
-- makes the stated rule impossible to satisfy:
--
--   "An Asset can be mapped through multiple Practices but should still
--    have only one Risk-level Asset mapping."
--
-- With practice_id on the map row, an asset reachable from two mapped
-- practices produces two rows, and the register shows the same asset
-- twice. Deduplicating at read time hides it in the grid but not in the
-- counts, the exports or anything that joins.
--
-- So the grain is split, exactly as the requirement is worded:
--
--   risk_asset_map          ONE row per (risk, asset). This IS the
--                           "Risk-level Asset mapping" the rule names,
--                           and a UNIQUE constraint makes it true.
--   risk_asset_map_source   WHY that row exists — one row per reason.
--                           A practice dependency contributes one; a
--                           direct mapping contributes one; an asset
--                           reachable from three practices has three.
--
-- That split is what makes removal safe, which is the other stated rule:
--
--   "Removing an additional Practice should not blindly remove an Asset
--    if that Asset is still required by another mapped Practice or was
--    directly mapped."
--
-- Un-mapping a practice deletes ITS contribution rows. The asset row is
-- deleted only when the last contribution goes with it. No procedure
-- has to reason about "is anything else still using this?" — the row
-- count answers it, and the answer cannot drift from the data.
--
-- ---------------------------------------------------------------------
-- DECISION 2 — PRACTICE GRAIN, WITH THE INSTANCE RECORDED
-- ---------------------------------------------------------------------
-- risk_register.linked_practice_id (205) holds a practice.practice_id —
-- the catalogue practice — and the rest of GRAC links to risks that way
-- (Exception Centre derives the same value in 258). But dependencies,
-- and therefore assets, hang off practice_INSTANCE via
-- practice_dependency_resolution (002).
--
-- So the map is keyed on practice_id, and the assets inherited from a
-- practice are the union across that practice's active instances. The
-- instance that actually resolved each dependency is recorded on the
-- contribution row, so "why is this asset here?" answers all the way
-- down to the instance without a second mapping table and without
-- diverging from the practice_id every other Centre already uses.
--
-- ---------------------------------------------------------------------
-- DECISION 3 — TREATMENT OPTION LIVES ON THE REGISTER *AND* ON EACH
--              ANALYSIS VERSION
-- ---------------------------------------------------------------------
-- Same argument 205 made for the inherent block and 258 made for the
-- residual one. The register is authoritative and the grid filters on
-- it; the analysis rows are the retained history (§20). A risk analysed
-- three times, choosing Treat then Transfer then Tolerate, must be able
-- to show all three — and columns hold only the last.
--
-- ---------------------------------------------------------------------
-- DECISION 4 — NO SECOND STATUS VOCABULARY
-- ---------------------------------------------------------------------
-- The workflow this migration supports has stages: analysis, treatment,
-- residual, acceptance, review. It is tempting to add
-- workflow_stage_code NVARCHAR(40) and drive the UI from it.
--
-- It is NOT added, deliberately. risk_register.status_code already owns
-- a lifecycle vocabulary with a CHECK behind it (§17: Active /
-- UnderTreatment / Accepted / Monitoring / Closed / Retired). A second
-- stored status is a second thing every writer must remember to update,
-- and 258 already had to ship a repair pass for exactly one such flag
-- drifting (residual_pending).
--
-- Instead the stage is DERIVED, once, in vw_pm_risk_workflow_stage
-- (migration 264) from facts this migration persists: analysis_pending,
-- treatment_option_code, the open/closed counts of the risk's treatment
-- tasks, residual_pending, accepted_dt and next_review_date. Every one
-- of those is a column; none of them can disagree with the stage,
-- because the stage is not stored.
--
-- CONTENTS
--   1. risk_practice_map            NEW
--   2. risk_asset_map               NEW
--   3. risk_asset_map_source        NEW
--   4. risk_register   + treatment / acceptance / review columns
--   5. risk_analysis   + treatment_option_code, analysis_purpose_code
--   6. risk_residual_analysis + treatment_option_code
--   7. Backfill: linked_practice_id from the candidate's gap source
--
-- ADDITIVE ONLY. Idempotent. Safe to re-run.
-- ERROR CODE RANGE: 56480-56519  (56450-56479 was taken by 258)
-- Rollback: database/261_risk_treatment_mapping_schema_rollback.sql
-- Depends:  001, 002, 204, 205, 212, 215, 216, 258
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN PRINT 'ABORT (261): risk_register missing -- run 205 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.risk_analysis','U') IS NULL
BEGIN PRINT 'ABORT (261): risk_analysis missing -- run 205 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.risk_residual_analysis','U') IS NULL
BEGIN PRINT 'ABORT (261): risk_residual_analysis missing -- run 258 first.'; SET @ok = 0; END

IF COL_LENGTH('grac_practice.risk_register','analysis_pending') IS NULL
BEGIN PRINT 'ABORT (261): risk_register.analysis_pending missing -- run 216 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.practice','U') IS NULL
BEGIN PRINT 'ABORT (261): practice missing -- run 001 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.organization_dependency_asset','U') IS NULL
BEGIN PRINT 'ABORT (261): organization_dependency_asset missing -- run 002 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NULL
BEGIN PRINT 'ABORT (261): practice_dependency_resolution missing -- run 002 first.'; SET @ok = 0; END

IF @ok = 0
BEGIN
    RAISERROR('261_risk_treatment_mapping_schema: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. risk_practice_map
--
-- Which practices this risk touches. Exactly one may be 'Primary' -- the
-- practice the risk arrived with, mirrored from
-- risk_register.linked_practice_id so the analysis screen has ONE list
-- to render rather than "the linked one, plus the additional ones".
--
-- Enforcing "one Primary" with a filtered unique index rather than in a
-- procedure means it stays true no matter who writes the row.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_practice_map','U') IS NULL
CREATE TABLE grac_practice.risk_practice_map(
    risk_practice_map_id  BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_practice_map PRIMARY KEY,
    organization_id       BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_practice_map_org
            REFERENCES grac_practice.organization(organization_id),
    risk_register_id      BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_practice_map_register
            REFERENCES grac_practice.risk_register(risk_register_id),
    practice_id           BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_practice_map_practice
            REFERENCES grac_practice.practice(practice_id),

    -- Frozen at map time. A practice rename must not silently rewrite
    -- what an audit trail said the risk touched -- the same reason 205
    -- freezes likelihood_name alongside likelihood_code.
    practice_name         NVARCHAR(300) NULL,
    practice_code         NVARCHAR(100) NULL,

    -- Primary   the practice the risk arrived with (linked_practice_id)
    -- Additional a practice the analyst mapped during Risk Analysis
    map_source_code       NVARCHAR(20) NOT NULL
        CONSTRAINT df_pm_risk_practice_map_source DEFAULT N'Additional',

    mapped_dt             DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_practice_map_dt DEFAULT SYSUTCDATETIME(),
    mapped_by_employee_id BIGINT NULL
        CONSTRAINT fk_pm_risk_practice_map_mapper
            REFERENCES grac_practice.organization_employee(employee_id),
    remarks               NVARCHAR(1000) NULL,

    record_status_id      INT NOT NULL
        CONSTRAINT fk_pm_risk_practice_map_record_status
            REFERENCES grac_practice.record_status_master(record_status_id),
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_risk_practice_map_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_practice_map_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,

    -- Validation case 1: "Same Practice should not be mapped twice."
    -- A constraint, not a procedure check, so it holds for every writer.
    CONSTRAINT uq_pm_risk_practice_map UNIQUE(risk_register_id, practice_id),
    CONSTRAINT ck_pm_risk_practice_map_source
        CHECK (map_source_code IN (N'Primary', N'Additional'))
);
GO

-- At most one Primary per risk. Filtered, so the many Additional rows
-- are unconstrained.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_risk_practice_map_primary'
                  AND object_id = OBJECT_ID('grac_practice.risk_practice_map'))
    CREATE UNIQUE INDEX ux_pm_risk_practice_map_primary
        ON grac_practice.risk_practice_map(risk_register_id)
        WHERE map_source_code = N'Primary';
GO

-- The reverse lookup: "which risks touch this practice?" -- which is the
-- question a practice owner asks, and the one that makes the map worth
-- keeping at all.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_practice_map_practice'
                  AND object_id = OBJECT_ID('grac_practice.risk_practice_map'))
    CREATE INDEX ix_pm_risk_practice_map_practice
        ON grac_practice.risk_practice_map(organization_id, practice_id)
        INCLUDE (risk_register_id, map_source_code);
GO

-- =====================================================================
-- 2. risk_asset_map
--
-- THE risk-level asset mapping. One row per (risk, asset), forever,
-- however many practices reach that asset. See decision 1.
--
-- There is no practice_id column here on purpose: the moment an asset
-- row names one practice, an asset reachable from two of them has to
-- either duplicate or lie. The reasons live in risk_asset_map_source.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_asset_map','U') IS NULL
CREATE TABLE grac_practice.risk_asset_map(
    risk_asset_map_id     BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_asset_map PRIMARY KEY,
    organization_id       BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_asset_map_org
            REFERENCES grac_practice.organization(organization_id),
    risk_register_id      BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_asset_map_register
            REFERENCES grac_practice.risk_register(risk_register_id),
    asset_id              BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_asset_map_asset
            REFERENCES grac_practice.organization_dependency_asset(asset_id),

    asset_name            NVARCHAR(220) NULL,   -- frozen, see above

    first_mapped_dt       DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_asset_map_dt DEFAULT SYSUTCDATETIME(),
    mapped_by_employee_id BIGINT NULL
        CONSTRAINT fk_pm_risk_asset_map_mapper
            REFERENCES grac_practice.organization_employee(employee_id),
    remarks               NVARCHAR(1000) NULL,

    record_status_id      INT NOT NULL
        CONSTRAINT fk_pm_risk_asset_map_record_status
            REFERENCES grac_practice.record_status_master(record_status_id),
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_risk_asset_map_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_asset_map_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,

    -- Validation cases 2 and 3, in one line.
    CONSTRAINT uq_pm_risk_asset_map UNIQUE(risk_register_id, asset_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_asset_map_asset'
                  AND object_id = OBJECT_ID('grac_practice.risk_asset_map'))
    CREATE INDEX ix_pm_risk_asset_map_asset
        ON grac_practice.risk_asset_map(organization_id, asset_id)
        INCLUDE (risk_register_id);
GO

-- =====================================================================
-- 3. risk_asset_map_source
--
-- Why an asset is on a risk. One row per independent reason:
--
--   PracticeDependency  reached through a mapped practice. practice_id
--                       is the mapped practice; practice_instance_id is
--                       the instance whose dependency resolution
--                       actually produced it (decision 2).
--   Direct              a human mapped this asset with no practice
--                       involved. Validation case 4 -- practice_id is
--                       NULL and that is the normal, valid shape.
--
-- THE COMPUTED KEY COLUMNS
-- ------------------------
-- The natural uniqueness is
--   (map, kind, practice_id, practice_instance_id)
-- but two of those are nullable, and in SQL Server a UNIQUE constraint
-- treats NULLs as equal -- which is what we want here -- while an
-- expression like ISNULL(practice_id, 0) is not allowed in a constraint
-- at all. Persisted computed columns give the constraint something
-- concrete to key on and cost nothing at read time. 205 uses the same
-- device for risk_number.
--
-- The result: a practice cannot contribute the same asset twice, a
-- direct mapping cannot be recorded twice, and a direct mapping and a
-- practice contribution for the same asset coexist happily -- which is
-- exactly validation case 5's precondition.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_asset_map_source','U') IS NULL
CREATE TABLE grac_practice.risk_asset_map_source(
    risk_asset_map_source_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_asset_map_source PRIMARY KEY,
    risk_asset_map_id     BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_asset_src_map
            REFERENCES grac_practice.risk_asset_map(risk_asset_map_id),

    source_kind_code      NVARCHAR(30) NOT NULL,

    -- NULL for Direct. No FK cascade anywhere near this: removing a
    -- contribution is a governed act (sp_risk_practice_unmap), not a
    -- side effect of deleting a practice row.
    practice_id           BIGINT NULL
        CONSTRAINT fk_pm_risk_asset_src_practice
            REFERENCES grac_practice.practice(practice_id),
    practice_instance_id  BIGINT NULL
        CONSTRAINT fk_pm_risk_asset_src_instance
            REFERENCES grac_practice.practice_instance(practice_instance_id),

    -- The dependency resolution row this came from, where there was one.
    -- Soft reference: resolutions are re-written by the Resolve
    -- workspace, and a hard FK would make un-resolving a dependency fail
    -- on a risk mapping the operator cannot see.
    resolution_id         BIGINT NULL,

    added_dt              DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_asset_src_dt DEFAULT SYSUTCDATETIME(),
    added_by_employee_id  BIGINT NULL
        CONSTRAINT fk_pm_risk_asset_src_adder
            REFERENCES grac_practice.organization_employee(employee_id),
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_risk_asset_src_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_asset_src_entered_dt DEFAULT SYSUTCDATETIME(),

    practice_key  AS (ISNULL(practice_id, CAST(0 AS BIGINT))) PERSISTED,
    instance_key  AS (ISNULL(practice_instance_id, CAST(0 AS BIGINT))) PERSISTED,

    CONSTRAINT ck_pm_risk_asset_src_kind
        CHECK (source_kind_code IN (N'PracticeDependency', N'Direct')),
    -- A practice-dependency contribution with no practice is not a
    -- contribution, it is a bug that would make un-mapping unable to
    -- find its own rows.
    CONSTRAINT ck_pm_risk_asset_src_practice_present
        CHECK (source_kind_code <> N'PracticeDependency' OR practice_id IS NOT NULL),
    CONSTRAINT ck_pm_risk_asset_src_direct_practice
        CHECK (source_kind_code <> N'Direct' OR practice_id IS NULL),
    CONSTRAINT uq_pm_risk_asset_map_source
        UNIQUE(risk_asset_map_id, source_kind_code, practice_key, instance_key)
);
GO

-- "Which assets did practice P put on risks?" -- the query
-- sp_risk_practice_unmap runs, and the one the UI runs to badge each
-- asset row with the practice it came from.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_asset_src_practice'
                  AND object_id = OBJECT_ID('grac_practice.risk_asset_map_source'))
    CREATE INDEX ix_pm_risk_asset_src_practice
        ON grac_practice.risk_asset_map_source(practice_id, risk_asset_map_id)
        INCLUDE (source_kind_code, practice_instance_id);
GO

-- =====================================================================
-- 4. risk_register -- treatment, acceptance and review
--
-- Each column is added under its own COL_LENGTH guard, the 258 pattern,
-- so a partially-applied run resumes cleanly.
-- =====================================================================

-- ---- 4a. The treatment decision -------------------------------------
-- Four options, fixed by the requirement. The stored code is short and
-- stable; the label the user picked is frozen beside it.
--
--   Terminate  Terminate / Avoid   -> raises a treatment task
--   Treat      Treat / Reduce      -> raises a treatment task
--   Transfer   Transfer / Share    -> raises a treatment task
--   Tolerate   Tolerate / Accept   -> raises NOTHING, goes to acceptance
IF COL_LENGTH('grac_practice.risk_register','treatment_option_code') IS NULL
    ALTER TABLE grac_practice.risk_register ADD treatment_option_code NVARCHAR(30) NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','treatment_option_name') IS NULL
    ALTER TABLE grac_practice.risk_register ADD treatment_option_name NVARCHAR(120) NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','treatment_decided_dt') IS NULL
    ALTER TABLE grac_practice.risk_register ADD treatment_decided_dt DATETIME2 NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','treatment_decided_by_employee_id') IS NULL
    ALTER TABLE grac_practice.risk_register ADD treatment_decided_by_employee_id BIGINT NULL;
GO

-- The parent treatment task. NULL for Tolerate, and NULL before a
-- decision is taken. This is what makes task creation idempotent
-- (validation case 6) without querying Task Centre: if it is already
-- set and the task is still open, there is nothing to create.
IF COL_LENGTH('grac_practice.risk_register','treatment_task_id') IS NULL
    ALTER TABLE grac_practice.risk_register ADD treatment_task_id BIGINT NULL;
GO

-- ---- 4b. Acceptance --------------------------------------------------
-- accepted_by_employee_id is the FK; accepted_by_name is the frozen
-- label, because an employee record can be deactivated, renamed or
-- merged and "who accepted this risk" must still render years later.
IF COL_LENGTH('grac_practice.risk_register','accepted_by_employee_id') IS NULL
    ALTER TABLE grac_practice.risk_register ADD accepted_by_employee_id BIGINT NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','accepted_by_name') IS NULL
    ALTER TABLE grac_practice.risk_register ADD accepted_by_name NVARCHAR(240) NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','accepted_dt') IS NULL
    ALTER TABLE grac_practice.risk_register ADD accepted_dt DATETIME2 NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','acceptance_note') IS NULL
    ALTER TABLE grac_practice.risk_register ADD acceptance_note NVARCHAR(MAX) NULL;
GO

-- ---- 4c. Review ------------------------------------------------------
-- DATE, not DATETIME2. The rule is "Current Date >= Next Review Date",
-- and a review dated today must appear today -- which a DATETIME2 with a
-- stray time component silently breaks for most of the day. Storing the
-- column as DATE makes the comparison exact rather than nearly right.
IF COL_LENGTH('grac_practice.risk_register','next_review_date') IS NULL
    ALTER TABLE grac_practice.risk_register ADD next_review_date DATE NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','last_reviewed_dt') IS NULL
    ALTER TABLE grac_practice.risk_register ADD last_reviewed_dt DATETIME2 NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','review_count') IS NULL
    ALTER TABLE grac_practice.risk_register ADD review_count INT NOT NULL
        CONSTRAINT df_pm_risk_register_review_count DEFAULT 0;
GO

-- ---- 4d. Constraints and keys ----------------------------------------
-- Added after the columns, each guarded, so re-running is safe.
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_risk_register_treatment_option')
    ALTER TABLE grac_practice.risk_register WITH NOCHECK
        ADD CONSTRAINT ck_pm_risk_register_treatment_option
            CHECK (treatment_option_code IS NULL
                OR treatment_option_code IN (N'Terminate', N'Treat',
                                             N'Transfer', N'Tolerate'));
GO

-- WITH NOCHECK on an all-NULL column is belt and braces, but it keeps
-- the statement identical in shape to 215's widening and costs nothing.
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
                WHERE name = 'fk_pm_risk_register_accepted_by'
                  AND parent_object_id = OBJECT_ID('grac_practice.risk_register'))
    ALTER TABLE grac_practice.risk_register
        ADD CONSTRAINT fk_pm_risk_register_accepted_by
            FOREIGN KEY (accepted_by_employee_id)
            REFERENCES grac_practice.organization_employee(employee_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
                WHERE name = 'fk_pm_risk_register_treatment_decider'
                  AND parent_object_id = OBJECT_ID('grac_practice.risk_register'))
    ALTER TABLE grac_practice.risk_register
        ADD CONSTRAINT fk_pm_risk_register_treatment_decider
            FOREIGN KEY (treatment_decided_by_employee_id)
            REFERENCES grac_practice.organization_employee(employee_id);
GO

-- treatment_task_id gets NO foreign key to practice_task, deliberately.
-- Task Centre owns task lifecycle including deletion paths this schema
-- cannot see, and a hard FK would make a Task Centre operation fail on a
-- Risk Centre row. Every other cross-Centre reference in 205 is soft for
-- the same reason (see "Soft references" on linked_asset_id).

-- The Review Risk list is "next_review_date <= today, not closed", and
-- the Risk Calendar is "next_review_date within a window". Both are
-- served by this one index; the filter keeps it small, because most
-- risks have no review date at all.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_register_next_review'
                  AND object_id = OBJECT_ID('grac_practice.risk_register'))
    CREATE INDEX ix_pm_risk_register_next_review
        ON grac_practice.risk_register(organization_id, next_review_date)
        INCLUDE (risk_title, status_code, inherent_rating_code,
                 residual_rating_code, risk_owner_employee_id)
        WHERE next_review_date IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_register_treatment_option'
                  AND object_id = OBJECT_ID('grac_practice.risk_register'))
    CREATE INDEX ix_pm_risk_register_treatment_option
        ON grac_practice.risk_register(organization_id, treatment_option_code, status_code)
        INCLUDE (risk_title, treatment_task_id, residual_pending);
GO

-- =====================================================================
-- 5. risk_analysis -- the option chosen at each version
--
-- analysis_purpose_code says WHY this version exists. Without it, a
-- review and a re-assessment are the same row and the audit trail
-- cannot tell "we looked again because it was due" from "we looked again
-- because something changed".
--
--   Initial   the first analysis (candidate stage, or custom creation)
--   Analysis  a re-assessment on a registered risk
--   Review    a scheduled review driven by next_review_date
--
-- Existing rows are left NULL rather than backfilled to a guess. NULL
-- reads as "recorded before purposes were tracked", which is true;
-- stamping them all 'Initial' would assert something we do not know.
-- =====================================================================
IF COL_LENGTH('grac_practice.risk_analysis','treatment_option_code') IS NULL
    ALTER TABLE grac_practice.risk_analysis ADD treatment_option_code NVARCHAR(30) NULL;
GO
IF COL_LENGTH('grac_practice.risk_analysis','treatment_option_name') IS NULL
    ALTER TABLE grac_practice.risk_analysis ADD treatment_option_name NVARCHAR(120) NULL;
GO
IF COL_LENGTH('grac_practice.risk_analysis','analysis_purpose_code') IS NULL
    ALTER TABLE grac_practice.risk_analysis ADD analysis_purpose_code NVARCHAR(20) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_risk_analysis_treatment_option')
    ALTER TABLE grac_practice.risk_analysis WITH NOCHECK
        ADD CONSTRAINT ck_pm_risk_analysis_treatment_option
            CHECK (treatment_option_code IS NULL
                OR treatment_option_code IN (N'Terminate', N'Treat',
                                             N'Transfer', N'Tolerate'));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_risk_analysis_purpose')
    ALTER TABLE grac_practice.risk_analysis WITH NOCHECK
        ADD CONSTRAINT ck_pm_risk_analysis_purpose
            CHECK (analysis_purpose_code IS NULL
                OR analysis_purpose_code IN (N'Initial', N'Analysis', N'Review'));
GO

-- =====================================================================
-- 6. risk_residual_analysis -- the option chosen after treatment
--
-- The residual analysis is a full analysis (the requirement says so
-- explicitly), which means it can conclude with a different treatment
-- decision from the original: a risk treated once and still too high may
-- now be Transferred, or finally Tolerated. So the option lives here as
-- well as on the inherent analysis.
-- =====================================================================
IF COL_LENGTH('grac_practice.risk_residual_analysis','treatment_option_code') IS NULL
    ALTER TABLE grac_practice.risk_residual_analysis ADD treatment_option_code NVARCHAR(30) NULL;
GO
IF COL_LENGTH('grac_practice.risk_residual_analysis','treatment_option_name') IS NULL
    ALTER TABLE grac_practice.risk_residual_analysis ADD treatment_option_name NVARCHAR(120) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_risk_residual_treatment_option')
    ALTER TABLE grac_practice.risk_residual_analysis WITH NOCHECK
        ADD CONSTRAINT ck_pm_risk_residual_treatment_option
            CHECK (treatment_option_code IS NULL
                OR treatment_option_code IN (N'Terminate', N'Treat',
                                             N'Transfer', N'Tolerate'));
GO

-- =====================================================================
-- 7. Backfill linked_practice_id where the chain already knows it
--
-- THE PROBLEM THIS SOLVES
-- -----------------------
-- risk_register.linked_practice_id has existed since 205 and has never
-- been written: the Risk Centre UI does not send it, and no procedure
-- derives it. So "a risk will already be associated with a Practice when
-- it reaches Risk Analysis" is not true of a single existing row.
--
-- For gap-sourced risks the association is not missing, only unrecorded:
-- the candidate carries the gap id (207: source_type_code = 'Gap',
-- source_record_id = custom_gap_id), the gap points at the practice
-- instance through source_reference_type / source_reference_id, and the
-- instance carries the practice. Exception Centre had exactly this gap
-- and closed it with exactly this join in 258.
--
-- Only rows where linked_practice_id IS NULL are touched, so a value set
-- by hand or by a later analysis is never overwritten. Risks from other
-- sources keep NULL and get their practice from the analyst's picker --
-- which is why the picker exists rather than the backfill being the
-- whole answer.
--
-- Two passes, because a risk can reach the register by either route and
-- both know the practice: through a candidate (route A) or as a custom
-- risk that named the gap directly on the register (route B, where 206
-- stamps source_record_id on risk_register itself).
-- =====================================================================
IF OBJECT_ID('grac_practice.custom_gap','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.practice_instance','U') IS NOT NULL
BEGIN
    -- Route A: register -> candidate -> gap -> instance -> practice
    UPDATE r
       SET linked_practice_id = pi.practice_id,
           updated_by = N'seed-261',
           updated_dt = SYSUTCDATETIME()
      FROM grac_practice.risk_register r
      JOIN grac_practice.risk_candidate c
        ON c.risk_candidate_id = r.risk_candidate_id
      JOIN grac_practice.custom_gap g
        ON g.custom_gap_id = c.source_record_id
      JOIN grac_practice.practice_instance pi
        ON pi.practice_instance_id = g.source_reference_id
     WHERE r.linked_practice_id IS NULL
       AND c.source_type_code       = N'Gap'
       AND g.source_reference_type  = N'PracticeInstance'
       AND g.source_reference_id    IS NOT NULL
       AND pi.practice_id           IS NOT NULL
       AND pi.organization_id       = r.organization_id;

    PRINT CONCAT('261: backfilled linked_practice_id on ', @@ROWCOUNT,
                 ' registered risk(s) via the candidate -> gap chain.');

    -- Route B: the register's own source columns (205), for risks that
    -- never had a candidate.
    UPDATE r
       SET linked_practice_id = pi.practice_id,
           updated_by = N'seed-261',
           updated_dt = SYSUTCDATETIME()
      FROM grac_practice.risk_register r
      JOIN grac_practice.custom_gap g
        ON g.custom_gap_id = r.source_record_id
      JOIN grac_practice.practice_instance pi
        ON pi.practice_instance_id = g.source_reference_id
     WHERE r.linked_practice_id IS NULL
       AND r.source_type_code      = N'Gap'
       AND g.source_reference_type = N'PracticeInstance'
       AND g.source_reference_id   IS NOT NULL
       AND pi.practice_id          IS NOT NULL
       AND pi.organization_id      = r.organization_id;

    PRINT CONCAT('261: backfilled linked_practice_id on ', @@ROWCOUNT,
                 ' registered risk(s) via the register source columns.');
END
ELSE
    PRINT '261: custom_gap/practice_instance not present -- linked_practice_id backfill skipped.';
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '261 mapping tables present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.risk_practice_map','U')     IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_asset_map','U')        IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_asset_map_source','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT '261 register columns present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.risk_register','treatment_option_code') IS NOT NULL
             AND COL_LENGTH('grac_practice.risk_register','treatment_task_id')     IS NOT NULL
             AND COL_LENGTH('grac_practice.risk_register','accepted_dt')           IS NOT NULL
             AND COL_LENGTH('grac_practice.risk_register','next_review_date')      IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT '261 analysis columns present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.risk_analysis','treatment_option_code')          IS NOT NULL
             AND COL_LENGTH('grac_practice.risk_analysis','analysis_purpose_code')          IS NOT NULL
             AND COL_LENGTH('grac_practice.risk_residual_analysis','treatment_option_code') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- One risk-level row per asset, whatever the contribution count. This is
-- the invariant the whole mapping design exists to hold, so it is worth
-- asserting on every run rather than trusting the constraint silently.
SELECT '261 one asset mapping per risk/asset' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.risk_asset_map
                 GROUP BY risk_register_id, asset_id
                HAVING COUNT(*) > 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT '261 no orphan asset mappings' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1
                  FROM grac_practice.risk_asset_map m
                 WHERE NOT EXISTS (SELECT 1 FROM grac_practice.risk_asset_map_source s
                                    WHERE s.risk_asset_map_id = m.risk_asset_map_id))
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '261 Risk mapping / treatment / acceptance / review schema installed.';
PRINT '     No stage column was added -- the workflow stage is derived in 264.';
PRINT '     Next: 262 (mapping procs), 263 (treatment), 264 (acceptance/review).';
GO

SET NOEXEC OFF;
GO
