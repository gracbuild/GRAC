-- =====================================================================
-- 207 Risk Centre — source wiring
--     (Risk Candidate Analysis and Risk Register BRD §4A, §6.1, §6.2,
--      §10, §13, §14)
--
-- WHAT THIS FILE DOES, AND WHAT IT DELIBERATELY DOES NOT
-- -----------------------------------------------------
-- 205 gave risk_candidate a general source model. This migration is what
-- makes that model USABLE by any GRAC Centre, by rewriting one procedure:
--
--   sp_risk_candidate_create   -> strict superset of 170
--
-- It does NOT touch a single caller. That is the whole design point.
-- Five migrations call sp_risk_candidate_create today, all with NAMED
-- parameters drawn only from 170's list:
--
--   172  sp_custom_gap_analysis_save     (superseded by 173, then 174)
--   173  sp_custom_gap_analysis_save
--   174  sp_custom_gap_analysis_save     <- live version
--   176  sp_exception_request_reject     (superseded by 184, then 193)
--   184  sp_exception_request_reject
--   193  sp_exception_request_reject     <- live version
--
-- Every one of them passes @custom_gap_id and a subset of the intake
-- fields, so the new proc DERIVES the source from the gap when no source
-- is supplied:
--
--   @custom_gap_id given, @source_type_code omitted
--       -> source_type_code   = 'Gap'
--          source_record_id   = @custom_gap_id
--          source_reference   = 'GAP-<id>'
--          source_centre_code = 'GapCentre'
--
-- Six migrations therefore gain full §10 traceability without a single
-- line changing in any of them. A new Centre — Assurance, Obligation,
-- Asset, Vendor, Event — passes the source explicitly and needs no
-- schema change at all, which is exactly the extensibility §13 asks for.
--
-- BRD §14 — WHY THE SOURCE RECORD IS NOT MOVED OR CHANGED
-- -------------------------------------------------------
-- "Risk Centre shall not replace Gap Centre or Exception Centre ... The
-- source record shall remain independently managed by its originating
-- Centre." So nothing here writes back to custom_gap or
-- exception_request. The candidate points at the source; the source is
-- never told what to do about it.
--
-- IDEMPOTENCY — GENERALISED
-- -------------------------
-- 170 allowed one open candidate per GAP. That rule now keys on
-- (source_type_code, source_record_id), so re-saving a gap analysis, or
-- an assurance observation firing twice, still yields one candidate.
-- Dedupe is skipped when source_record_id is NULL — a candidate with no
-- source record has nothing to be a duplicate OF, and §15's register-side
-- duplicate detection is the right tool there.
--
-- CONTENTS
--   1. sp_risk_candidate_create   REWRITE (superset of 170)
--   2. Backfill legacy candidates raised between 205 and 207
--   3. Sanity
--
-- ERROR CODE RANGE: reuses 170's 55400-55409 for compatibility;
--                   new conditions use 56200-56219.
-- Rollback: database/207_risk_centre_source_wiring_rollback.sql
-- Depends:  205_risk_register_schema.sql
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF COL_LENGTH('grac_practice.risk_candidate','source_type_code') IS NULL
BEGIN PRINT 'ABORT (207): risk_candidate.source_type_code missing — run 205_risk_register_schema.sql first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.risk_source_master','U') IS NULL
BEGIN PRINT 'ABORT (207): risk_source_master missing — run 204_risk_scoring_masters.sql first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('207_risk_centre_source_wiring: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_risk_candidate_create   (REWRITE — strict superset of 170)
--
-- COMPATIBILITY CONTRACT
--   * Every 170 parameter survives, with the same name and the same
--     meaning. @custom_gap_id loses its NOT NULL requirement, which can
--     only relax an existing caller, never break one.
--   * The result set is unchanged: (RiskCandidateId, Created).
--   * 172 and 176 call this proc by name with named parameters and are
--     unaffected.
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
-- 2. Backfill
--
-- Two populations need it:
--   a) rows 205's backfill already handled (no-op here, guarded);
--   b) rows created in the window between 205 and 207, where the 170
--      version of the create proc inserted without touching the source
--      columns and picked up the 'Gap' DEFAULT with no record id.
-- =====================================================================
UPDATE grac_practice.risk_candidate
   SET source_record_id   = custom_gap_id,
       source_reference   = COALESCE(source_reference,
                                     CONCAT(N'GAP-', CAST(custom_gap_id AS NVARCHAR(20)))),
       source_centre_code = COALESCE(source_centre_code, N'GapCentre'),
       updated_by         = N'seed-207',
       updated_dt         = SYSUTCDATETIME()
 WHERE source_type_code = N'Gap'
   AND source_record_id IS NULL
   AND custom_gap_id    IS NOT NULL;
GO

-- Centre code for anything else that arrived without one.
UPDATE c
   SET c.source_centre_code = s.source_centre_code,
       c.updated_by = N'seed-207',
       c.updated_dt = SYSUTCDATETIME()
  FROM grac_practice.risk_candidate c
  JOIN grac_practice.risk_source_master s ON s.source_type_code = c.source_type_code
 WHERE c.source_centre_code IS NULL
   AND s.source_centre_code IS NOT NULL;
GO

UPDATE grac_practice.risk_candidate
   SET identified_dt = requested_dt
 WHERE identified_dt IS NULL;
GO

-- =====================================================================
-- 3. Sanity
-- =====================================================================
SELECT '207 create proc accepts a source' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_candidate_create')
                            AND name = '@source_type_code')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT '170 callers still satisfied (custom_gap_id + caller_display_name present)' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_candidate_create')
                            AND name = '@custom_gap_id')
             AND EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_candidate_create')
                            AND name = '@caller_display_name')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'no gap-sourced candidate is missing its source record id' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.risk_candidate
                              WHERE source_type_code = N'Gap'
                                AND source_record_id IS NULL
                                AND custom_gap_id IS NOT NULL)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '207 Risk Centre source wiring installed.';
PRINT 'UNCHANGED BY DESIGN: 172, 173, 174 (sp_custom_gap_analysis_save) and';
PRINT '            176, 184, 193 (sp_exception_request_reject) keep working through';
PRINT '            source derivation — see this file''s header.';
GO

SET NOEXEC OFF;
GO
