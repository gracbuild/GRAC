-- =====================================================================
-- 258 Risk Centre — Residual Risk Analysis
--     (BRD §9.1 "residual risk / treatment effectiveness", §17, §20,
--      §22; docs/risk-centre.md "Still not built")
--
-- WHY THIS EXISTS
-- ---------------
-- Until now the Risk Register carried exactly ONE score: the inherent
-- rating, produced by stage 2 (216) from likelihood x impact against the
-- organisation's own matrix. docs/risk-centre.md listed residual risk
-- under "Still not built" with the note "Not in the BRD's minimum field
-- list; inherent rating only."
--
-- That is now a gap in the register itself, not just in the docs. §22
-- lets an organisation raise treatment work against a registered risk,
-- and §17 gives it an UnderTreatment / Monitoring lifecycle — but once
-- that treatment has been done, nothing in the schema could record what
-- the risk looks like AFTERWARDS. A register that shows only the score a
-- risk had BEFORE anyone treated it cannot answer the one question a
-- board asks: "so where are we now?"
--
-- This migration adds the second score.
--
--   Inherent  = likelihood x impact BEFORE treatment  (216, unchanged)
--   Residual  = likelihood x impact AFTER  treatment  (this migration)
--
-- FOUR DECISIONS, AND WHY
-- -----------------------
--  1. SAME MATRIX, NOT A SECOND ONE.
--     The residual rating is resolved by sp_risk_rating_resolve — the
--     exact procedure the inherent rating already uses — against the
--     same risk_likelihood_master / risk_impact_master /
--     risk_matrix_cell rows. No new masters, no second resolver, no
--     hand-typed score. Two scores that came out of two different
--     methods are not comparable, and a register whose two columns are
--     not comparable is worse than one column.
--
--  2. A TABLE, NOT COLUMNS ON risk_analysis.
--     §20 — "Previous risk ratings and analysis values shall not be
--     overwritten without retaining historical versions." A risk gets
--     treated more than once, and each cycle produces a new residual
--     picture. Versioned rows hold every one; columns hold only the
--     last. This is the same argument 205 made for risk_analysis, and
--     the table has the same shape (version + is_current + a filtered
--     unique index) so the two audit trails read alike.
--
--     It is a SEPARATE table rather than more versions of risk_analysis
--     because the two are re-assessed on different clocks: re-scoring
--     the inherent risk (new information about the threat) and
--     re-scoring the residual risk (new treatment landed) are different
--     events, and folding them into one version chain would mean every
--     residual save also bumped the inherent version — and walked
--     straight into the §19 approval gate, which exists to guard the
--     INHERENT rating.
--
--  3. DENORMALISED ONTO risk_register TOO.
--     Same reason 205 gave for the inherent block: §9 makes the register
--     authoritative, and an authoritative record that renders by joining
--     to a mutable analysis is not authoritative. The grid also filters
--     and sorts on it, and a filtered join to a versioned child table on
--     every list page is the kind of query that is fine at 50 risks and
--     not at 5,000.
--
--  4. GATED ON TREATMENT HAVING STARTED.
--     Residual risk means "what is left after treatment". A residual
--     score on a risk that nobody has treated is not a measurement, it
--     is a guess with a number on it. So sp_risk_residual_analysis_save
--     refuses unless BOTH hold:
--       * the inherent rating exists (analysis_pending = 0) — there is
--         nothing to be residual TO otherwise; and
--       * status_code IN (UnderTreatment, Monitoring, Accepted) —
--         treatment is under way, has been done, or the organisation
--         formally accepted the risk instead of treating it (§17's own
--         vocabulary for "the treatment decision has been taken").
--     Active is refused because it means the treatment decision has not
--     been taken yet; Closed / Retired are refused because they are
--     terminal.
--
-- WHAT THIS MIGRATION DOES **NOT** DO
-- -----------------------------------
--   * It does not touch the §19 approval gate. That gate guards the
--     inherent rating, which is what §19's rating threshold is written
--     against. A residual assessment does not pass through it.
--   * It does not change sp_risk_register_insert, sp_risk_register_assess
--     or sp_risk_register_apply_analysis. The inherent path is untouched.
--   * It does not make residual mandatory anywhere. A risk with no
--     residual assessment reads as "not assessed", the same way 216's
--     analysis_pending reads as work outstanding rather than bad data.
--
-- CONTENTS
--   1. grac_practice.risk_residual_analysis      NEW, versioned
--   2. risk_register + residual_* columns        denormalised
--   3. sp_risk_residual_analysis_save            NEW
--   4. sp_risk_residual_analysis_get             NEW  (current version)
--   5. sp_risk_residual_analysis_history         NEW  (§20)
--   6. sp_risk_register_list                     REWRITE — superset of 216
--   7. sp_risk_register_get                      REWRITE — superset of 216
--
-- ADDITIVE ONLY. Idempotent. No existing row is rewritten.
-- ERROR CODE RANGE: 56450-56479  (56440-56446 was the last range in use,
--                                 taken by 216)
-- Rollback: database/258_risk_residual_analysis_rollback.sql
-- Depends:  204, 205, 206, 212, 216
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN PRINT 'ABORT (258): risk_register missing — run 205 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.risk_analysis','U') IS NULL
BEGIN PRINT 'ABORT (258): risk_analysis missing — run 205 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.risk_register_history','U') IS NULL
BEGIN PRINT 'ABORT (258): risk_register_history missing — run 205 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.sp_risk_rating_resolve','P') IS NULL
BEGIN PRINT 'ABORT (258): sp_risk_rating_resolve missing — run 206 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.risk_matrix_cell','U') IS NULL
BEGIN PRINT 'ABORT (258): risk_matrix_cell missing — run 204 first.'; SET @ok = 0; END

-- 216 is a hard dependency, not a soft one: this file REWRITES
-- sp_risk_register_list and sp_risk_register_get as supersets of 216's
-- versions. Applying it to a database still on 206 would silently drop
-- the threat / vulnerability / analysis_pending columns those screens
-- already read.
IF COL_LENGTH('grac_practice.risk_register','analysis_pending') IS NULL
BEGIN PRINT 'ABORT (258): risk_register.analysis_pending missing — run 216 first.'; SET @ok = 0; END

IF @ok = 0
BEGIN
    RAISERROR('258_risk_residual_analysis: prerequisites missing — see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. risk_residual_analysis   (BRD §9.1, §20, §22)
--
-- One row per residual assessment. Never UPDATEd except is_current, for
-- the same reason risk_analysis is never UPDATEd — §20 becomes true by
-- construction rather than by discipline.
--
-- inherent_analysis_id is the inherent version this residual was
-- measured AGAINST. Without it, a residual of "Medium" is unreadable a
-- year later: was the inherent High at the time, or Critical? Frozen at
-- save, so a later re-score of the inherent risk does not silently
-- rewrite what this assessment claimed to have reduced.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_residual_analysis','U') IS NULL
CREATE TABLE grac_practice.risk_residual_analysis(
    risk_residual_analysis_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_residual_analysis PRIMARY KEY,
    organization_id       BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_residual_organization
            REFERENCES grac_practice.organization(organization_id),

    -- NOT NULL. A residual assessment with no registered risk behind it
    -- is the same category of nonsense as a register row with no
    -- analysis, and 205 made that impossible for the same reason.
    risk_register_id      BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_residual_register
            REFERENCES grac_practice.risk_register(risk_register_id),

    -- The inherent version this residual is measured against (§10 —
    -- the chain must stay walkable in both directions).
    inherent_analysis_id  BIGINT NULL
        CONSTRAINT fk_pm_risk_residual_inherent
            REFERENCES grac_practice.risk_analysis(risk_analysis_id),

    residual_version      INT NOT NULL
        CONSTRAINT df_pm_risk_residual_version DEFAULT 1,
    is_current            BIT NOT NULL
        CONSTRAINT df_pm_risk_residual_current DEFAULT 1,

    -- ---- The residual scale, same shape as the inherent block --------
    -- code + name + level. The name is frozen so a later rename of
    -- "Possible" to "Occasional" does not rewrite history.
    residual_likelihood_code  NVARCHAR(60)  NULL,
    residual_likelihood_name  NVARCHAR(200) NULL,
    residual_likelihood_value INT NULL,
    residual_impact_code      NVARCHAR(60)  NULL,
    residual_impact_name      NVARCHAR(200) NULL,
    residual_impact_value     INT NULL,

    -- Resolved from risk_matrix_cell via sp_risk_rating_resolve. Never
    -- typed in — see decision 1 in the header.
    residual_rating_code  NVARCHAR(30)  NULL,
    residual_rating_name  NVARCHAR(120) NULL,
    residual_rating_score INT NULL,

    -- The inherent rating AS IT STOOD when this residual was taken.
    -- Denormalised deliberately: it is what makes a version row readable
    -- on its own in the §20 history table, with no join and no risk of
    -- the inherent having moved since.
    inherent_rating_code  NVARCHAR(30)  NULL,
    inherent_rating_name  NVARCHAR(120) NULL,
    inherent_rating_score INT NULL,

    -- ---- The evidence for the reduction (§22) ------------------------
    -- Without these the residual score is an assertion. treatment_summary
    -- says what was DONE; residual_controls says what is now IN PLACE.
    treatment_summary     NVARCHAR(MAX) NULL,
    residual_controls     NVARCHAR(MAX) NULL,
    analyst_remarks       NVARCHAR(MAX) NULL,

    assessed_dt           DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_residual_assessed_dt DEFAULT SYSUTCDATETIME(),
    assessed_by_employee_id BIGINT NULL
        CONSTRAINT fk_pm_risk_residual_assessor
            REFERENCES grac_practice.organization_employee(employee_id),

    record_status_id      INT NOT NULL
        CONSTRAINT fk_pm_risk_residual_record_status
            REFERENCES grac_practice.record_status_master(record_status_id),
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_risk_residual_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_residual_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,

    CONSTRAINT ck_pm_risk_residual_version CHECK (residual_version >= 1)
);
GO

-- One current version per risk. Filtered so superseded rows are free to
-- pile up — which is the entire point of keeping them.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_risk_residual_current'
                  AND object_id = OBJECT_ID('grac_practice.risk_residual_analysis'))
    CREATE UNIQUE INDEX ux_pm_risk_residual_current
        ON grac_practice.risk_residual_analysis(risk_register_id)
        WHERE is_current = 1;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_residual_register_version'
                  AND object_id = OBJECT_ID('grac_practice.risk_residual_analysis'))
    CREATE INDEX ix_pm_risk_residual_register_version
        ON grac_practice.risk_residual_analysis(risk_register_id, residual_version DESC)
        INCLUDE (residual_rating_code, residual_rating_score, assessed_dt);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_residual_org'
                  AND object_id = OBJECT_ID('grac_practice.risk_residual_analysis'))
    CREATE INDEX ix_pm_risk_residual_org
        ON grac_practice.risk_residual_analysis(organization_id, is_current, assessed_dt DESC);
GO

-- =====================================================================
-- 2. risk_register — the denormalised residual block
--
-- residual_pending mirrors 216's analysis_pending exactly, including the
-- DEFAULT 1 and the filtered index, so the two "still to do" flags
-- behave identically and the grid can badge them the same way.
--
-- Every existing row gets residual_pending = 1: no risk has ever had a
-- residual assessment, so every one of them is outstanding. That is a
-- statement of fact, not a backfill.
-- =====================================================================
IF COL_LENGTH('grac_practice.risk_register','residual_analysis_id') IS NULL
    ALTER TABLE grac_practice.risk_register ADD residual_analysis_id BIGINT NULL;
GO

IF COL_LENGTH('grac_practice.risk_register','residual_likelihood_code') IS NULL
    ALTER TABLE grac_practice.risk_register ADD residual_likelihood_code NVARCHAR(60) NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_likelihood_name') IS NULL
    ALTER TABLE grac_practice.risk_register ADD residual_likelihood_name NVARCHAR(200) NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_likelihood_value') IS NULL
    ALTER TABLE grac_practice.risk_register ADD residual_likelihood_value INT NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_impact_code') IS NULL
    ALTER TABLE grac_practice.risk_register ADD residual_impact_code NVARCHAR(60) NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_impact_name') IS NULL
    ALTER TABLE grac_practice.risk_register ADD residual_impact_name NVARCHAR(200) NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_impact_value') IS NULL
    ALTER TABLE grac_practice.risk_register ADD residual_impact_value INT NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_rating_code') IS NULL
    ALTER TABLE grac_practice.risk_register ADD residual_rating_code NVARCHAR(30) NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_rating_name') IS NULL
    ALTER TABLE grac_practice.risk_register ADD residual_rating_name NVARCHAR(120) NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_rating_score') IS NULL
    ALTER TABLE grac_practice.risk_register ADD residual_rating_score INT NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_assessed_dt') IS NULL
    ALTER TABLE grac_practice.risk_register ADD residual_assessed_dt DATETIME2 NULL;
GO
IF COL_LENGTH('grac_practice.risk_register','residual_pending') IS NULL
    ALTER TABLE grac_practice.risk_register ADD residual_pending BIT NOT NULL
        CONSTRAINT df_pm_risk_register_residual_pending DEFAULT 1;
GO

-- Closes the cycle, the same way 205 closed candidate <-> register. Both
-- sides are nullable, so the cycle is inert.
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
                WHERE name = 'fk_pm_risk_register_residual'
                  AND parent_object_id = OBJECT_ID('grac_practice.risk_register'))
    ALTER TABLE grac_practice.risk_register
        ADD CONSTRAINT fk_pm_risk_register_residual
            FOREIGN KEY (residual_analysis_id)
            REFERENCES grac_practice.risk_residual_analysis(risk_residual_analysis_id);
GO

-- Repair pass, for a database where 258 ran before any residual rows
-- existed and rows were later written by hand: keep the flag honest.
UPDATE grac_practice.risk_register
   SET residual_pending = 0
 WHERE residual_pending = 1
   AND residual_rating_code IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_register_residual_pending'
                  AND object_id = OBJECT_ID('grac_practice.risk_register'))
    CREATE INDEX ix_pm_risk_register_residual_pending
        ON grac_practice.risk_register(organization_id, residual_pending, registered_dt DESC)
        WHERE residual_pending = 1;
GO

-- The grid filters on residual rating the same way it filters on
-- inherent, so it gets the same index shape.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_register_residual_rating'
                  AND object_id = OBJECT_ID('grac_practice.risk_register'))
    CREATE INDEX ix_pm_risk_register_residual_rating
        ON grac_practice.risk_register(organization_id, residual_rating_code, registered_dt DESC)
        INCLUDE (risk_title, inherent_rating_code, status_code);
GO

-- =====================================================================
-- 3. sp_risk_residual_analysis_save   (BRD §9.1, §17, §20, §22)
--
-- The ONLY writer of a residual score. Writes a new version, flips
-- is_current, stamps the register, and records the §20 history line — in
-- one transaction, because a residual row the register does not point at
-- is worse than no residual row.
--
-- The rating is NOT a parameter. It is resolved from the same matrix as
-- the inherent rating, by the same procedure. A caller cannot supply one.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_residual_analysis_save
    @risk_register_id        BIGINT,
    @residual_likelihood_code NVARCHAR(60),
    @residual_impact_code    NVARCHAR(60),
    @treatment_summary       NVARCHAR(MAX) = NULL,
    @residual_controls       NVARCHAR(MAX) = NULL,
    @analyst_remarks         NVARCHAR(MAX) = NULL,
    @assessed_by_employee_id BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56450, 'sp_risk_residual_analysis_save: risk_register_id is required.', 1;
    IF @residual_likelihood_code IS NULL OR LEN(LTRIM(RTRIM(@residual_likelihood_code))) = 0
        THROW 56451, 'sp_risk_residual_analysis_save: residual likelihood is required.', 1;
    IF @residual_impact_code IS NULL OR LEN(LTRIM(RTRIM(@residual_impact_code))) = 0
        THROW 56452, 'sp_risk_residual_analysis_save: residual impact is required.', 1;

    DECLARE @org_id BIGINT, @status NVARCHAR(30), @analysis_pending BIT,
            @inherent_analysis_id BIGINT,
            @inh_code NVARCHAR(30), @inh_name NVARCHAR(120), @inh_score INT;

    SELECT @org_id               = organization_id,
           @status               = status_code,
           @analysis_pending     = analysis_pending,
           @inherent_analysis_id = risk_analysis_id,
           @inh_code             = inherent_rating_code,
           @inh_name             = inherent_rating_name,
           @inh_score            = inherent_rating_score
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56453, 'sp_risk_residual_analysis_save: risk not found.', 1;

    -- ---- Gate 1: there must be something to be residual TO -----------
    IF ISNULL(@analysis_pending, 1) = 1 OR @inh_code IS NULL
        THROW 56454, 'sp_risk_residual_analysis_save: this risk has no inherent rating yet. Complete the risk analysis before assessing residual risk.', 1;

    -- ---- Gate 2: treatment must have been decided (§17) --------------
    -- Three separate messages, because the three refusals need three
    -- different actions from the operator and one generic message would
    -- send them all to the wrong place.
    IF @status IN (N'Closed', N'Retired')
        THROW 56455, 'sp_risk_residual_analysis_save: this risk is closed or retired — reopen it before assessing residual risk.', 1;

    IF @status = N'Active'
        THROW 56456, 'sp_risk_residual_analysis_save: residual risk is what remains after treatment. Move this risk to Under treatment, Monitoring or Accepted first.', 1;

    IF @status NOT IN (N'UnderTreatment', N'Monitoring', N'Accepted')
        THROW 56457, 'sp_risk_residual_analysis_save: residual risk can only be assessed on a risk under treatment, monitoring or accepted.', 1;

    -- ---- Resolve the scale — the SAME masters as the inherent path ---
    DECLARE @lk_name NVARCHAR(200), @lk_value INT,
            @im_name NVARCHAR(200), @im_value INT;

    SELECT @lk_name = likelihood_name, @lk_value = level_value
      FROM grac_practice.risk_likelihood_master
     WHERE organization_id = @org_id
       AND likelihood_code = @residual_likelihood_code
       AND status = N'Active';
    IF @lk_value IS NULL
        THROW 56458, 'sp_risk_residual_analysis_save: unknown residual likelihood_code for this organisation.', 1;

    SELECT @im_name = impact_name, @im_value = level_value
      FROM grac_practice.risk_impact_master
     WHERE organization_id = @org_id
       AND impact_code = @residual_impact_code
       AND status = N'Active';
    IF @im_value IS NULL
        THROW 56459, 'sp_risk_residual_analysis_save: unknown residual impact_code for this organisation.', 1;

    -- One resolver for both scores. See decision 1 in the header.
    DECLARE @rt_code NVARCHAR(30), @rt_name NVARCHAR(120), @rt_score INT;
    EXEC grac_practice.sp_risk_rating_resolve
         @organization_id  = @org_id,
         @likelihood_value = @lk_value,
         @impact_value     = @im_value,
         @rating_code      = @rt_code  OUTPUT,
         @rating_name      = @rt_name  OUTPUT,
         @rating_score     = @rt_score OUTPUT;

    IF @rt_code IS NULL
        THROW 56460, 'sp_risk_residual_analysis_save: the residual likelihood/impact pair resolved to no rating. Check the organisation''s risk matrix configuration.', 1;

    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    DECLARE @next_version INT = 1, @residual_id BIGINT;

    BEGIN TRY
        BEGIN TRAN;

        -- No lock hint, matching sp_risk_analysis_save (206). Two
        -- concurrent saves would collide on ux_pm_risk_residual_current
        -- and the loser rolls back — a loud failure, which is the right
        -- outcome for two people scoring the same risk at the same
        -- moment.
        SELECT @next_version = ISNULL(MAX(residual_version), 0) + 1
          FROM grac_practice.risk_residual_analysis
         WHERE risk_register_id = @risk_register_id;

        -- Retire the previous current version BEFORE inserting the new
        -- one: ux_pm_risk_residual_current allows exactly one.
        UPDATE grac_practice.risk_residual_analysis
           SET is_current = 0,
               updated_by = @caller_display_name,
               updated_dt = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id
           AND is_current = 1;

        INSERT INTO grac_practice.risk_residual_analysis
            (organization_id, risk_register_id, inherent_analysis_id,
             residual_version, is_current,
             residual_likelihood_code, residual_likelihood_name, residual_likelihood_value,
             residual_impact_code, residual_impact_name, residual_impact_value,
             residual_rating_code, residual_rating_name, residual_rating_score,
             inherent_rating_code, inherent_rating_name, inherent_rating_score,
             treatment_summary, residual_controls, analyst_remarks,
             assessed_dt, assessed_by_employee_id,
             record_status_id, entered_by, entered_dt)
        VALUES
            (@org_id, @risk_register_id, @inherent_analysis_id,
             @next_version, 1,
             @residual_likelihood_code, @lk_name, @lk_value,
             @residual_impact_code, @im_name, @im_value,
             @rt_code, @rt_name, @rt_score,
             @inh_code, @inh_name, @inh_score,
             @treatment_summary, @residual_controls, @analyst_remarks,
             SYSUTCDATETIME(), @assessed_by_employee_id,
             @active_rs, @caller_display_name, SYSUTCDATETIME());

        SET @residual_id = SCOPE_IDENTITY();

        -- Stamp the authoritative record (decision 3 in the header).
        UPDATE grac_practice.risk_register
           SET residual_analysis_id      = @residual_id,
               residual_likelihood_code  = @residual_likelihood_code,
               residual_likelihood_name  = @lk_name,
               residual_likelihood_value = @lk_value,
               residual_impact_code      = @residual_impact_code,
               residual_impact_name      = @im_name,
               residual_impact_value     = @im_value,
               residual_rating_code      = @rt_code,
               residual_rating_name      = @rt_name,
               residual_rating_score     = @rt_score,
               residual_assessed_dt      = SYSUTCDATETIME(),
               residual_pending          = 0,
               updated_by                = @caller_display_name,
               updated_dt                = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id;

        -- §20 — the register's own trail carries both scores, so the
        -- audit line is readable without opening the assessment.
        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_register_id, N'ResidualAssessed', @status, @status,
             CONCAT(N'Residual assessment v', CAST(@next_version AS NVARCHAR(10)),
                    N'. Inherent ', ISNULL(@inh_code, N'(none)'),
                    N' -> residual ', @rt_code,
                    N' (', @lk_name, N' x ', @im_name, N').'),
             @assessed_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_register_id AS RiskRegisterId,
           @residual_id      AS RiskResidualAnalysisId,
           @next_version     AS ResidualVersion,
           @rt_code          AS ResidualRatingCode,
           @rt_name          AS ResidualRatingName,
           @rt_score         AS ResidualRatingScore,
           @inh_code         AS InherentRatingCode,
           @inh_score        AS InherentRatingScore;
END;
GO

-- =====================================================================
-- 4. sp_risk_residual_analysis_get   (the current version, for the form)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_residual_analysis_get
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_register_id IS NULL
        THROW 56461, 'sp_risk_residual_analysis_get: risk_register_id is required.', 1;

    SELECT TOP 1
        d.risk_residual_analysis_id AS RiskResidualAnalysisId,
        d.organization_id           AS OrganizationId,
        d.risk_register_id          AS RiskRegisterId,
        d.inherent_analysis_id      AS InherentAnalysisId,
        d.residual_version          AS ResidualVersion,
        d.is_current                AS IsCurrent,
        d.residual_likelihood_code  AS ResidualLikelihoodCode,
        d.residual_likelihood_name  AS ResidualLikelihoodName,
        d.residual_likelihood_value AS ResidualLikelihoodValue,
        d.residual_impact_code      AS ResidualImpactCode,
        d.residual_impact_name      AS ResidualImpactName,
        d.residual_impact_value     AS ResidualImpactValue,
        d.residual_rating_code      AS ResidualRatingCode,
        d.residual_rating_name      AS ResidualRatingName,
        d.residual_rating_score     AS ResidualRatingScore,
        d.inherent_rating_code      AS InherentRatingCode,
        d.inherent_rating_name      AS InherentRatingName,
        d.inherent_rating_score     AS InherentRatingScore,
        d.treatment_summary         AS TreatmentSummary,
        d.residual_controls         AS ResidualControls,
        d.analyst_remarks           AS AnalystRemarks,
        d.assessed_dt               AS AssessedOn,
        d.assessed_by_employee_id   AS AssessedByEmployeeId,
        ab.employee_name            AS AssessedByName
      FROM grac_practice.risk_residual_analysis d
 LEFT JOIN grac_practice.organization_employee ab ON ab.employee_id = d.assessed_by_employee_id
     WHERE d.risk_register_id = @risk_register_id
       AND d.is_current = 1
     ORDER BY d.residual_version DESC;
END;
GO

-- =====================================================================
-- 5. sp_risk_residual_analysis_history   (BRD §20)
--
-- Every retained version, newest first. Same shape as
-- sp_risk_analysis_history so the UI renders both with one component.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_residual_analysis_history
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_register_id IS NULL
        THROW 56462, 'sp_risk_residual_analysis_history: risk_register_id is required.', 1;

    SELECT
        d.risk_residual_analysis_id AS RiskResidualAnalysisId,
        d.residual_version          AS ResidualVersion,
        d.is_current                AS IsCurrent,
        d.residual_likelihood_name  AS ResidualLikelihoodName,
        d.residual_impact_name      AS ResidualImpactName,
        d.residual_rating_code      AS ResidualRatingCode,
        d.residual_rating_score     AS ResidualRatingScore,
        d.inherent_rating_code      AS InherentRatingCode,
        d.inherent_rating_score     AS InherentRatingScore,
        d.treatment_summary         AS TreatmentSummary,
        d.analyst_remarks           AS AnalystRemarks,
        d.assessed_dt               AS AssessedOn,
        ab.employee_name            AS AssessedByName
      FROM grac_practice.risk_residual_analysis d
 LEFT JOIN grac_practice.organization_employee ab ON ab.employee_id = d.assessed_by_employee_id
     WHERE d.risk_register_id = @risk_register_id
     ORDER BY d.residual_version DESC;
END;
GO

-- =====================================================================
-- 6. sp_risk_register_list   (REWRITE — strict superset of 216)
--
-- Every column and parameter 216 emitted is still here, in the same
-- order, with the same name. Added at the end:
--
--   columns     ResidualRatingCode / Name / Score, ResidualLikelihoodName,
--               ResidualImpactName, ResidualAssessedOn, ResidualPending
--   parameters  @residual_rating_code, @residual_pending
--
-- TotalRows stays LAST, because the service reads it by name but the
-- window function must see the finished WHERE clause — moving it would
-- not break anything, but every other list proc in this schema puts it
-- last and consistency is cheaper than a surprise.
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
    @analysis_pending BIT = NULL,          -- 216: "what still needs scoring?"
    -- NEW in 258. Both default to NULL = "no opinion", so every existing
    -- caller keeps its current behaviour without being edited.
    @residual_rating_code NVARCHAR(30) = NULL,
    @residual_pending     BIT          = NULL
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
        -- ---- 258 — the second score ---------------------------------
        r.residual_likelihood_name AS ResidualLikelihoodName,
        r.residual_impact_name     AS ResidualImpactName,
        r.residual_rating_code     AS ResidualRatingCode,
        r.residual_rating_name     AS ResidualRatingName,
        r.residual_rating_score    AS ResidualRatingScore,
        r.residual_assessed_dt     AS ResidualAssessedOn,
        r.residual_pending         AS ResidualPending,
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
       AND (@analysis_pending IS NULL OR r.analysis_pending    = @analysis_pending)
       AND (@residual_rating_code IS NULL OR r.residual_rating_code = @residual_rating_code)
       AND (@residual_pending     IS NULL OR r.residual_pending     = @residual_pending)
       AND (@search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0
            OR r.risk_title     LIKE N'%' + @search + N'%'
            OR r.risk_statement LIKE N'%' + @search + N'%'
            OR r.risk_number    LIKE N'%' + @search + N'%')
     ORDER BY r.registered_dt DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- =====================================================================
-- 7. sp_risk_register_get   (REWRITE — strict superset of 216)
--
-- Same rule: every 216 column survives untouched; the residual block and
-- the residual assessor's name are appended.
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
        -- ---- 258 — the residual block -------------------------------
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
        rab.employee_name           AS ResidualAssessedByName
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.risk_source_master  sm ON sm.source_type_code = r.source_type_code
 LEFT JOIN grac_practice.risk_candidate      c  ON c.risk_candidate_id = r.risk_candidate_id
 LEFT JOIN grac_practice.risk_analysis       a  ON a.risk_analysis_id  = r.risk_analysis_id
 OUTER APPLY (SELECT TOP 1 x.approval_status_code
                FROM grac_practice.risk_analysis x
               WHERE x.risk_register_id = r.risk_register_id
                 AND x.is_current = 1
               ORDER BY x.analysis_version DESC) AS cur
 -- Joined on the register's own pointer rather than on is_current, so
 -- the detail screen shows the version the register is actually carrying
 -- even if a later one were ever written outside this migration's proc.
 LEFT JOIN grac_practice.risk_residual_analysis res
        ON res.risk_residual_analysis_id = r.residual_analysis_id
 LEFT JOIN grac_practice.organization_employee rab ON rab.employee_id = res.assessed_by_employee_id
 LEFT JOIN grac_practice.organization_employee an ON an.employee_id = a.analysed_by_employee_id
 LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.risk_owner_employee_id
 LEFT JOIN grac_practice.organization_employee rb ON rb.employee_id = r.registered_by_employee_id
 LEFT JOIN grac_practice.organization_employee cb ON cb.employee_id = r.closed_by_employee_id
     WHERE r.risk_register_id = @risk_register_id;
END;
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '258 objects present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.risk_residual_analysis','U')            IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_residual_analysis_save','P')     IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_residual_analysis_get','P')      IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_residual_analysis_history','P')  IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'residual columns on risk_register' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.risk_register','residual_rating_code')  IS NOT NULL
             AND COL_LENGTH('grac_practice.risk_register','residual_rating_score') IS NOT NULL
             AND COL_LENGTH('grac_practice.risk_register','residual_pending')      IS NOT NULL
             AND COL_LENGTH('grac_practice.risk_register','residual_analysis_id')  IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'list proc kept its 216 columns and gained the residual ones' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_register_list')
                            AND definition LIKE '%AnalysisPending%'
                            AND definition LIKE '%ThreatName%'
                            AND definition LIKE '%ResidualRatingCode%')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'residual uses the shared resolver, not a second one' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_residual_analysis_save')
                            AND definition LIKE '%sp_risk_rating_resolve%')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'no residual score without an inherent one' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.risk_register
                              WHERE residual_rating_code IS NOT NULL
                                AND inherent_rating_code IS NULL)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '258 Residual Risk Analysis installed.';
PRINT 'Inherent = before treatment (216). Residual = after treatment (this file).';
PRINT 'Both scores resolve through sp_risk_rating_resolve against the same matrix.';
PRINT 'Gate: inherent rating must exist AND status must be UnderTreatment / Monitoring / Accepted.';
PRINT 'NOT WIRED (by design): the 19 approval gate. It guards the inherent rating only.';
GO
