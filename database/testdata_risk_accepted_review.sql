-- =====================================================================
-- TEST DATA — Accepted risks with a next review date
--
--   Organization : 1
--   Target count : 10-15 risks in status 'Accepted'
--   Next review  : 2026-09-01
--
-- NOT A MIGRATION. Deliberately unnumbered: it seeds test data, it is
-- not part of the schema lineage, and it must never be picked up by a
-- deployment that walks database/NNN_*.sql in order.
--
-- ---------------------------------------------------------------------
-- READ THIS FIRST — THE REVIEW DATE IS IN THE PAST
-- ---------------------------------------------------------------------
-- sp_risk_acceptance_save REFUSES this data:
--
--     IF @next_review_date <= @today
--         THROW 56602, '... the next review date must be in the future.'
--
-- 2026-09-01 is yesterday. So this script CANNOT go through the
-- acceptance procedure, and writes the columns directly instead.
--
-- That is very probably what you want. A review date in the past is
-- exactly what puts a risk into the Review Risk queue
-- (sp_risk_review_due_list: next_review_date <= today) and marks it
-- overdue on the Risk Calendar. A future date would produce accepted
-- risks that show up nowhere until that date arrives.
--
-- If instead you wanted the procedure's own path, set @NextReviewDate
-- to a FUTURE date and call sp_risk_acceptance_save per risk rather than
-- running this script. The script PRINTs which case you are in.
--
-- What the direct write costs you: 56602 is the only rule bypassed, and
-- it guards a human decision ("do not accept a risk without scheduling
-- its return"), not the shape of the row. Every other acceptance rule is
-- honoured below on purpose, so the rows are indistinguishable from ones
-- the procedure would have produced:
--
--     56604  not Closed/Retired      -> excluded by the WHERE
--     56605  analysis_pending = 0    -> set
--     56606  treatment option set    -> set to 'Tolerate'
--     56608  accepter in this org    -> resolved from organization_employee
--     + the risk_register_history row the procedure writes
--
-- ---------------------------------------------------------------------
-- STRATEGY: ADOPT FIRST, CREATE ONLY THE SHORTFALL
-- ---------------------------------------------------------------------
-- Phase 1 takes existing, eligible risks in org 1 and accepts them.
-- Phase 2 runs ONLY if phase 1 found fewer than @MinRisks, and creates
-- the difference.
--
-- Phase 2 builds its rows FROM SCRATCH and needs no existing risk to
-- copy. (An earlier version cloned a template, which meant an empty
-- organisation produced nothing at all -- the script skipped, reported
-- success, and left zero rows.) Everything it needs is resolvable from
-- master data that ships with the schema:
--
--     record_status_id   record_status_master, code 'Active'   (002)
--     source_type_code   risk_source_master,   code 'Custom'   (204)
--
-- The one thing it cannot skip is risk_register.risk_analysis_id, which
-- is NOT NULL -- the §1 invariant, "no risk without an analysis". So a
-- risk_analysis row is created first, satisfying:
--
--     ck_pm_risk_analysis_scope          scope IN (Candidate, Custom)
--     ck_pm_risk_analysis_candidate_link Candidate scope needs a candidate
--     ck_pm_risk_analysis_decision       Register | Reject | Clarify
--     ck_pm_risk_analysis_approval       NotRequired | Pending | ...
--     ck_pm_risk_analysis_version        version >= 1
--     ux_pm_risk_analysis_current        UNIQUE(risk_candidate_id)
--                                        WHERE is_current = 1
--                                          AND risk_candidate_id IS NOT NULL
--
-- Scope 'Custom' with risk_candidate_id NULL satisfies the link rule and
-- sits outside the filtered unique index entirely, so any number of them
-- can coexist.
--
-- ---------------------------------------------------------------------
-- IDEMPOTENT
-- ---------------------------------------------------------------------
-- Re-running does not duplicate anything:
--   * Phase 1's UPDATE is naturally idempotent, and its history row is
--     written only when the status ACTUALLY changed -- so a second run
--     does not pile up 'RiskAccepted' entries.
--   * Phase 2 counts what already exists before creating, and tags its
--     rows with entered_by = 'seed-risk-accepted', so a re-run finds
--     them and creates nothing.
--
-- NOTHING IS DELETED and no pre-existing risk is created twice. Risks
-- that were already Accepted keep their own accepted_by / accepted_dt;
-- only the review date is aligned.
--
-- Rollback: database/testdata_risk_accepted_review_rollback.sql
--
-- AMENDED AFTER 378 -- risk_number became a regular NOT NULL column
-- (was PERSISTED COMPUTED). Phase 2's direct INSERT into risk_register
-- now generates its own R-001-style, per-organisation-sequential
-- risk_number before writing the row -- see the comment at that INSERT.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- ---------------------------------------------------------------------
-- Parameters
-- ---------------------------------------------------------------------
DECLARE @OrgId           BIGINT = 1;
DECLARE @NextReviewDate  DATE   = '2026-09-01';
DECLARE @MinRisks        INT    = 10;   -- create up to this many if short
DECLARE @MaxRisks        INT    = 15;   -- never accept more than this
DECLARE @SeedTag         NVARCHAR(100) = N'seed-risk-accepted';

DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);

-- ---------------------------------------------------------------------
-- Prerequisites. Each is a thing this script cannot invent.
-- ---------------------------------------------------------------------
IF DB_ID() IS NULL OR OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN
    RAISERROR('ABORT: grac_practice.risk_register does not exist. Run 205 first.', 16, 1);
    RETURN;
END

IF COL_LENGTH('grac_practice.risk_register','next_review_date') IS NULL
BEGIN
    RAISERROR('ABORT: next_review_date is missing. Run 261 before this script.', 16, 1);
    RETURN;
END

IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @OrgId)
BEGIN
    RAISERROR('ABORT: organization 1 does not exist.', 16, 1);
    RETURN;
END

PRINT '--- Risk test data: Accepted + next review date ---';
PRINT CONCAT('    Organization      : ', @OrgId);
PRINT CONCAT('    Next review date  : ', CONVERT(NVARCHAR(10), @NextReviewDate, 23));
PRINT CONCAT('    Today             : ', CONVERT(NVARCHAR(10), @Today, 23));

IF @NextReviewDate <= @Today
BEGIN
    PRINT '    NOTE: the review date is in the PAST, so these risks will appear';
    PRINT '          immediately in Review Risk and as overdue on the Risk Calendar.';
    PRINT '          sp_risk_acceptance_save would refuse this (56602); the columns';
    PRINT '          are written directly. See the header.';
END
ELSE
    PRINT '    NOTE: the review date is in the future -- these risks will NOT appear';
    PRINT '          in Review Risk until that date.';

-- ---------------------------------------------------------------------
-- The accepting employee. Must belong to org 1 (the procedure's 56608),
-- so it is resolved rather than assumed. NULL is acceptable -- the FK
-- allows it -- and the script says so rather than failing.
-- ---------------------------------------------------------------------
DECLARE @AcceptById BIGINT, @AcceptByName NVARCHAR(240);

SELECT TOP 1 @AcceptById = e.employee_id, @AcceptByName = e.employee_name
FROM grac_practice.organization_employee e
WHERE e.organization_id = @OrgId
ORDER BY e.employee_id;

IF @AcceptById IS NULL
    PRINT '    WARNING: no employee found for organization 1 -- accepted_by will be NULL.';
ELSE
    PRINT CONCAT('    Accepted by       : ', @AcceptByName, ' (id ', @AcceptById, ')');

DECLARE @AcceptedDt DATETIME2 = SYSUTCDATETIME();

-- =====================================================================
-- PHASE 1 — adopt existing risks
--
-- Closed and Retired are excluded, mirroring the procedure's 56604: a
-- closed risk is reopened deliberately, not accepted behind its own back.
-- Oldest first, so repeated runs pick the same rows.
-- =====================================================================
DECLARE @Targets TABLE (risk_register_id BIGINT PRIMARY KEY, from_status NVARCHAR(30));

INSERT INTO @Targets (risk_register_id, from_status)
SELECT TOP (@MaxRisks) r.risk_register_id, r.status_code
FROM grac_practice.risk_register r
WHERE r.organization_id = @OrgId
  AND r.status_code NOT IN (N'Closed', N'Retired')
ORDER BY r.risk_register_id;

DECLARE @Adopted INT = (SELECT COUNT(*) FROM @Targets);

-- Say what was found BEFORE doing anything. An earlier run of this
-- script finished quietly having written nothing, and the only way to
-- find out why was to go and query the tables by hand.
DECLARE @TotalInOrg  INT = (SELECT COUNT(*) FROM grac_practice.risk_register
                             WHERE organization_id = @OrgId);
DECLARE @ClosedInOrg INT = (SELECT COUNT(*) FROM grac_practice.risk_register
                             WHERE organization_id = @OrgId
                               AND status_code IN (N'Closed', N'Retired'));

PRINT CONCAT('    Risks in org ', @OrgId, ' (all statuses): ', @TotalInOrg);
PRINT CONCAT('      of which Closed/Retired         : ', @ClosedInOrg, ' (not eligible)');
PRINT CONCAT('      eligible and selected           : ', @Adopted);

IF @TotalInOrg = 0
    PRINT '    Organization 1 has no risks at all -- phase 2 will create them from scratch.';

BEGIN TRAN;

UPDATE r
   SET status_code           = N'Accepted',
       next_review_date      = @NextReviewDate,
       -- analysis_pending = 0 and a treatment option are what the
       -- acceptance procedure requires (56605 / 56606). Set so the rows
       -- are consistent with the rule, not merely past the check.
       analysis_pending      = 0,
       treatment_option_code = ISNULL(r.treatment_option_code, N'Tolerate'),
       treatment_option_name = ISNULL(r.treatment_option_name, N'Tolerate / Accept'),
       treatment_decided_dt  = ISNULL(r.treatment_decided_dt, @AcceptedDt),
       -- A risk already accepted keeps who accepted it and when. Only
       -- the review date is aligned -- overwriting real acceptance
       -- metadata would destroy the thing under test.
       accepted_by_employee_id = ISNULL(r.accepted_by_employee_id, @AcceptById),
       accepted_by_name        = ISNULL(r.accepted_by_name, @AcceptByName),
       accepted_dt             = ISNULL(r.accepted_dt, @AcceptedDt),
       acceptance_note         = ISNULL(r.acceptance_note,
                                        N'Accepted for testing by ' + @SeedTag + N'.'),
       updated_by            = @SeedTag,
       updated_dt            = SYSUTCDATETIME()
FROM grac_practice.risk_register r
JOIN @Targets t ON t.risk_register_id = r.risk_register_id;

-- History only where the status actually moved. Re-running this script
-- therefore adds no further 'RiskAccepted' entries to a risk that was
-- already accepted -- which is what makes the history idempotent too.
INSERT INTO grac_practice.risk_register_history
    (risk_register_id, action_code, from_status_code, to_status_code,
     remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
SELECT t.risk_register_id, N'RiskAccepted', t.from_status, N'Accepted',
       CONCAT(N'Risk accepted by ', ISNULL(@AcceptByName, N'(unnamed)'),
              N' on ', CONVERT(NVARCHAR(10), @AcceptedDt, 23),
              N'. Next review ', CONVERT(NVARCHAR(10), @NextReviewDate, 23),
              N'. Route: Tolerate / Accept (no treatment work). [test data]'),
       @AcceptById, @AcceptByName, @SeedTag, SYSUTCDATETIME()
FROM @Targets t
WHERE t.from_status <> N'Accepted';

COMMIT;

PRINT CONCAT('    Phase 1: ', @Adopted, ' existing risk(s) set to Accepted.');

-- =====================================================================
-- PHASE 2 — create the shortfall, only if there is one
-- =====================================================================
DECLARE @Shortfall INT = CASE WHEN @Adopted < @MinRisks THEN @MinRisks - @Adopted ELSE 0 END;

IF @Shortfall = 0
    PRINT '    Phase 2: not needed -- enough risks already exist.';
ELSE
BEGIN
    PRINT CONCAT('    Phase 2: creating ', @Shortfall, ' risk(s) to reach ', @MinRisks, '.');

    -- Everything phase 2 needs comes from master data that ships with
    -- the schema. No existing risk is required, so an empty organisation
    -- still gets its test data.
    DECLARE @RecordStatusId INT, @SourceTypeCode NVARCHAR(40);

    SELECT @RecordStatusId = record_status_id
    FROM grac_practice.record_status_master
    WHERE status_code = N'Active';                    -- seeded by 002

    -- 'Custom' is the source for a risk with no candidate behind it
    -- (§24 rule 8, and ck_pm_risk_register_custom_source). Resolved from
    -- the master rather than assumed to be present.
    SELECT @SourceTypeCode = source_type_code
    FROM grac_practice.risk_source_master
    WHERE source_type_code = N'Custom';               -- seeded by 204

    IF @RecordStatusId IS NULL OR @SourceTypeCode IS NULL
    BEGIN
        PRINT '    ABORT phase 2: required master data is missing.';
        IF @RecordStatusId IS NULL
            PRINT '                   record_status_master has no ''Active'' row -- run 002.';
        IF @SourceTypeCode IS NULL
            PRINT '                   risk_source_master has no ''Custom'' row -- run 204.';
    END
    ELSE
    BEGIN
        BEGIN TRAN;

        DECLARE @i INT = 1, @NewAnalysisId BIGINT, @NewRiskId BIGINT, @Label NVARCHAR(300);
        DECLARE @NextRiskNo INT, @RiskNumber NVARCHAR(20);   -- 378: risk_number generation, see below

        WHILE @i <= @Shortfall
        BEGIN
            SET @Label = CONCAT(N'[TEST] Accepted risk ', @i);

            -- ---- the analysis first (§1: no risk without one) --------
            -- Scope 'Custom' with risk_candidate_id NULL: satisfies
            -- ck_pm_risk_analysis_candidate_link, and sits outside
            -- ux_pm_risk_analysis_current (which only indexes rows where
            -- risk_candidate_id IS NOT NULL), so any number can coexist.
            --
            -- Only three NOT NULL columns here lack a default --
            -- organization_id, risk_statement, record_status_id -- but
            -- version / is_current / analysis_dt are stated explicitly
            -- rather than left to their defaults, because this row has to
            -- read as a deliberate record, not as whatever the defaults
            -- happened to be.
            INSERT INTO grac_practice.risk_analysis
                (organization_id, analysis_scope_code, risk_candidate_id,
                 analysis_version, is_current, risk_statement,
                 risk_owner_employee_id, analysed_by_employee_id,
                 analysis_dt, decision_code, decision_dt,
                 approval_status_code,
                 record_status_id, entered_by, entered_dt)
            VALUES
                (@OrgId, N'Custom', NULL,
                 1, 1, LEFT(CONCAT(@Label, N' — statement'), 1000),
                 @AcceptById, @AcceptById,
                 @AcceptedDt, N'Register', @AcceptedDt,
                 N'NotRequired',
                 @RecordStatusId, @SeedTag, SYSUTCDATETIME());

            SET @NewAnalysisId = SCOPE_IDENTITY();

            -- ---- the risk itself ------------------------------------
            -- 378: risk_number is a regular NOT NULL column now (was
            -- PERSISTED COMPUTED before 378), so this direct INSERT
            -- must generate one itself -- same UPDLOCK/HOLDLOCK-read +
            -- FORMAT + collision-guard shape sp_risk_register_insert
            -- uses, scoped to @OrgId.
            SELECT @NextRiskNo = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(risk_number, 3, 20))), 0) + 1
              FROM grac_practice.risk_register WITH (UPDLOCK, HOLDLOCK)
             WHERE organization_id = @OrgId
               AND risk_number LIKE N'R-%'
               AND TRY_CONVERT(INT, SUBSTRING(risk_number, 3, 20)) IS NOT NULL;

            SET @RiskNumber = N'R-' + FORMAT(@NextRiskNo, '000');
            WHILE EXISTS (SELECT 1 FROM grac_practice.risk_register
                           WHERE organization_id = @OrgId AND risk_number = @RiskNumber)
            BEGIN
                SET @NextRiskNo = @NextRiskNo + 1;
                SET @RiskNumber = N'R-' + FORMAT(@NextRiskNo, '000');
            END

            INSERT INTO grac_practice.risk_register
                (organization_id, risk_number, risk_title, risk_statement,
                 source_type_code, source_record_id, risk_candidate_id,
                 risk_analysis_id, risk_owner_employee_id,
                 status_code, analysis_pending,
                 treatment_option_code, treatment_option_name, treatment_decided_dt,
                 accepted_by_employee_id, accepted_by_name, accepted_dt, acceptance_note,
                 next_review_date,
                 registered_dt, registered_by_employee_id,
                 record_status_id, entered_by, entered_dt)
            VALUES
                (@OrgId, @RiskNumber, @Label, CONCAT(N'There is a risk that ', @Label,
                                        N' occurs, leading to a test condition.'),
                 @SourceTypeCode, NULL, NULL,     -- Custom => no candidate
                 @NewAnalysisId, @AcceptById,
                 N'Accepted', 0,
                 N'Tolerate', N'Tolerate / Accept', @AcceptedDt,
                 @AcceptById, @AcceptByName, @AcceptedDt,
                 N'Accepted for testing by ' + @SeedTag + N'.',
                 @NextReviewDate,
                 @AcceptedDt, @AcceptById,
                 @RecordStatusId, @SeedTag, SYSUTCDATETIME());

            SET @NewRiskId = SCOPE_IDENTITY();

            -- The analysis carries a back-link to its register row,
            -- stamped after the register row exists ("NULL while the
            -- analysis is still a proposal"). Leaving it NULL would make
            -- these look like un-registered proposals.
            UPDATE grac_practice.risk_analysis
               SET risk_register_id = @NewRiskId,
                   updated_by       = @SeedTag,
                   updated_dt       = SYSUTCDATETIME()
             WHERE risk_analysis_id = @NewAnalysisId;

            INSERT INTO grac_practice.risk_register_history
                (risk_register_id, action_code, from_status_code, to_status_code,
                 remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
            VALUES
                (@NewRiskId, N'RiskAccepted', N'Active', N'Accepted',
                 CONCAT(N'Risk accepted by ', ISNULL(@AcceptByName, N'(unnamed)'),
                        N'. Next review ', CONVERT(NVARCHAR(10), @NextReviewDate, 23),
                        N'. Route: Tolerate / Accept (no treatment work). [test data]'),
                 @AcceptById, @AcceptByName, @SeedTag, SYSUTCDATETIME());

            SET @i = @i + 1;
        END

        COMMIT;
        PRINT CONCAT('    Phase 2: created ', @Shortfall, ' risk(s).');
    END
END
GO

-- =====================================================================
-- Verification — what the script actually left behind
-- =====================================================================
PRINT '';
PRINT '--- verification ---';

SELECT 'Accepted risks in org 1 with the target review date' AS Check_,
       COUNT(*) AS Result
FROM grac_practice.risk_register
WHERE organization_id = 1
  AND status_code = N'Accepted'
  AND next_review_date = '2026-09-01';

-- This check previously said only "*** FAIL", which is true but useless:
-- it cannot distinguish "the status value was wrong" from "no rows were
-- written at all", and those need completely different fixes. It now
-- says which.
SELECT 'Accepted risks exist in org 1' AS Check_,
       CASE
         WHEN EXISTS (SELECT 1 FROM grac_practice.risk_register
                       WHERE organization_id = 1 AND status_code = N'Accepted')
           THEN 'PASS -- rows written and ck_pm_risk_register_status accepted them'
         WHEN NOT EXISTS (SELECT 1 FROM grac_practice.risk_register
                           WHERE organization_id = 1)
           THEN '*** NO RISKS AT ALL in org 1 -- phase 2 should have created them. '
              + 'Check the PRINT output above for an ABORT phase 2 message.'
         WHEN NOT EXISTS (SELECT 1 FROM grac_practice.risk_register
                           WHERE organization_id = 1
                             AND status_code NOT IN (N'Closed', N'Retired'))
           THEN '*** every risk in org 1 is Closed/Retired -- none was eligible, '
              + 'and phase 2 creates only the shortfall below @MinRisks.'
         ELSE '*** risks exist and were eligible but none is Accepted -- '
              + 'the UPDATE did not match. Check @OrgId.'
       END AS Result;

-- The master data phase 2 depends on, reported so a failure names its
-- own cause rather than leaving it to be discovered by hand.
SELECT 'Master data required by phase 2' AS Check_,
       CONCAT(
         'record_status_master Active: ',
         CASE WHEN EXISTS (SELECT 1 FROM grac_practice.record_status_master
                            WHERE status_code = N'Active') THEN 'present' ELSE 'MISSING (run 002)' END,
         '  |  risk_source_master Custom: ',
         CASE WHEN EXISTS (SELECT 1 FROM grac_practice.risk_source_master
                            WHERE source_type_code = N'Custom') THEN 'present' ELSE 'MISSING (run 204)' END,
         '  |  employees in org 1: ',
         CAST((SELECT COUNT(*) FROM grac_practice.organization_employee
                WHERE organization_id = 1) AS NVARCHAR(10))
       ) AS Result;

SELECT 'Every accepted risk has a review date' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.risk_register
                              WHERE organization_id = 1
                                AND status_code = N'Accepted'
                                AND next_review_date IS NULL)
            THEN 'PASS' ELSE '*** FAIL -- an accepted risk would never return for review' END AS Result;

SELECT 'Every accepted risk has a treatment option (56606)' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.risk_register
                              WHERE organization_id = 1
                                AND status_code = N'Accepted'
                                AND treatment_option_code IS NULL)
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

SELECT 'No orphaned analysis (the §1 invariant)' AS Check_,
       CASE WHEN NOT EXISTS (
              SELECT 1 FROM grac_practice.risk_register r
               WHERE r.organization_id = 1
                 AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_analysis a
                                  WHERE a.risk_analysis_id = r.risk_analysis_id))
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

SELECT 'Seeded rows (re-running creates no more of these)' AS Check_,
       COUNT(*) AS Result
FROM grac_practice.risk_register
WHERE organization_id = 1 AND entered_by = N'seed-risk-accepted';

-- The point of the past review date: these should now be due.
SELECT 'Risks now due for review (Review Risk queue)' AS Check_,
       COUNT(*) AS Result
FROM grac_practice.risk_register
WHERE organization_id = 1
  AND status_code NOT IN (N'Closed', N'Retired')
  AND next_review_date IS NOT NULL
  AND next_review_date <= CAST(SYSUTCDATETIME() AS DATE);

SELECT TOP 20
       risk_number, risk_title, status_code, treatment_option_code,
       accepted_by_name, accepted_dt, next_review_date, entered_by
FROM grac_practice.risk_register
WHERE organization_id = 1 AND status_code = N'Accepted'
ORDER BY risk_register_id;
GO
