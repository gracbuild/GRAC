-- =====================================================================
-- 576  Risk acceptance & review history
--
-- REQUEST (2026-11-16)
--   "risk nte review lu already accept cheythapo kodutha message avide
--    kanikunnundu. pakshe review lu athu matti review cheythu kazhinjal
--    pinne aa pazhaya message kanunnilla ... oro acceptance and review
--    nteyum details means date reviewed by and description history ayi
--    kanikkan patto"
--
-- WHY THE OLD TEXT DISAPPEARED
--   The Review page pre-fills the CURRENT assessment's remark and the
--   register keeps only the LATEST acceptance note
--   (risk_register.acceptance_note). Every acceptance and review was
--   already written to risk_register_history (RiskAccepted /
--   RiskReviewed), but with the note folded into a generated sentence.
--
-- WHAT THIS DOES
--   1. risk_register_history + event_note, event_by_name, event_dt: the
--      note as typed ('' = none), who accepted / reviewed, and when (the
--      acceptance date, which may be back-dated).
--   2. sp_risk_acceptance_save (310 body) and sp_risk_review_perform (299
--      body) fill them. Bulk accept goes through sp_risk_acceptance_save;
--      bulk review's own RiskReviewed rows already carry the remark as
--      their whole text, so neither bulk procedure changes.
--   3. Backfill of earlier rows, best effort, never overwriting:
--        RiskReviewed -> the Review analysis written with it (same risk,
--                        within 60 seconds): its remark and analyst;
--        RiskAccepted -> "Risk accepted by <name> on <date>" from the
--                        generated text; the note = the text after
--                        "Risk version N." (310 format), and for each
--                        risk's latest acceptance the register's note.
--      A row the backfill cannot split keeps showing its full text.
--   4. sp_risk_decision_history_list @risk_register_id: every acceptance
--      and review, newest first.
--
-- SAFE TO RE-RUN. Requires 299 and 310. ASCII-only.
-- Rollback: 576_risk_decision_history_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.risk_register_history','U') IS NULL
   OR ISNULL(OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_acceptance_save')), N'') NOT LIKE N'%risk_version%'
   OR ISNULL(OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_review_perform')), N'') NOT LIKE N'%review_frequency_id%'
   OR COL_LENGTH('grac_practice.risk_register','acceptance_note') IS NULL
   OR COL_LENGTH('grac_practice.risk_register','review_frequency_id') IS NULL
   OR COL_LENGTH('grac_practice.risk_register','risk_version') IS NULL
   OR COL_LENGTH('grac_practice.risk_analysis','analysis_purpose_code') IS NULL
   OR OBJECT_ID('grac_practice.sp_risk_treatment_option_set','P') IS NULL
BEGIN
    PRINT 'ABORT (576): run 299 and 310 first. Nothing was changed.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Columns
-- =====================================================================
IF COL_LENGTH('grac_practice.risk_register_history','event_note') IS NULL
    ALTER TABLE grac_practice.risk_register_history ADD event_note NVARCHAR(MAX) NULL;
IF COL_LENGTH('grac_practice.risk_register_history','event_by_name') IS NULL
    ALTER TABLE grac_practice.risk_register_history ADD event_by_name NVARCHAR(240) NULL;
IF COL_LENGTH('grac_practice.risk_register_history','event_dt') IS NULL
    ALTER TABLE grac_practice.risk_register_history ADD event_dt DATETIME2 NULL;
GO

-- =====================================================================
-- 2. Writers (310 / 299 bodies + the 576 parts, marked "576")
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
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt,
             event_note, event_by_name, event_dt)   -- 576
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
             @caller_display_name, SYSUTCDATETIME(),
             -- 576: the acceptance as the history shows it -- the note
             -- ('' = none), who accepted and the acceptance date.
             ISNULL(@acceptance_note, N''), @accept_name, @accepted_on);

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

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_review_perform
    @risk_register_id       BIGINT,
    @risk_category_code     NVARCHAR(60),
    @likelihood_code        NVARCHAR(60),
    @impact_code            NVARCHAR(60),
    @risk_cause             NVARCHAR(MAX) = NULL,
    @potential_consequence  NVARCHAR(MAX) = NULL,
    @existing_controls      NVARCHAR(MAX) = NULL,
    @risk_description       NVARCHAR(MAX) = NULL,
    @process_name           NVARCHAR(200) = NULL,
    @review_remarks         NVARCHAR(MAX) = NULL,
    @treatment_option_code  NVARCHAR(30)  = NULL,
    @next_review_date       DATE          = NULL,
    @reviewed_by_employee_id BIGINT       = NULL,
    @caller_display_name    NVARCHAR(100) = N'system',
    -- NEW in 299. The cadence the reviewer PROPOSES, carried onto the
    -- risk so the Accept screen can open with it already chosen. It is a
    -- proposal, not a decision -- whoever accepts may change it.
    @review_frequency_id    INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56615, 'sp_risk_review_perform: risk_register_id is required.', 1;

    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    IF @next_review_date IS NOT NULL AND @next_review_date <= @today
        THROW 56616, 'sp_risk_review_perform: a supplied next review date must be in the future.', 1;

    DECLARE @org_id BIGINT, @status NVARCHAR(30), @prev_review DATE, @risk_number NVARCHAR(60);
    SELECT @org_id      = organization_id,
           @status      = status_code,
           @prev_review = next_review_date,
           @risk_number = risk_number
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56617, 'sp_risk_review_perform: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56618, 'sp_risk_review_perform: this risk is closed or retired -- reopen it before reviewing.', 1;

    -- ---- The analysis itself, unchanged and unduplicated -------------
    -- 216 owns this. It writes the new version, runs the section 19 gate and
    -- applies the result. Its result set is consumed by the caller of
    -- THIS procedure, so it is executed first and its own SELECT is
    -- allowed to flow through as result set 1.
    EXEC grac_practice.sp_risk_register_assess
         @risk_register_id        = @risk_register_id,
         @risk_category_code      = @risk_category_code,
         @likelihood_code         = @likelihood_code,
         @impact_code             = @impact_code,
         @risk_cause              = @risk_cause,
         @potential_consequence   = @potential_consequence,
         @existing_controls       = @existing_controls,
         @risk_description        = @risk_description,
         @process_name            = @process_name,
         @analyst_remarks         = @review_remarks,
         @analysed_by_employee_id = @reviewed_by_employee_id,
         @caller_display_name     = @caller_display_name;

    -- ---- Bookkeeping --------------------------------------------------
    -- CHANGED IN 299. Monitoring for ANY reviewable risk, not only one
    -- that was Accepted.
    --
    -- Monitoring is what now routes a risk to the Accept tab (the stage
    -- view keys off it), so leaving an Active or UnderTreatment risk in
    -- its old status after a review would silently strand it -- reviewed,
    -- but on no list. 264 only had to consider the Accepted case because
    -- nothing depended on the status back then.
    --
    -- Closed and Retired are left alone: those are terminal, and a review
    -- does not reopen them.
    DECLARE @new_status NVARCHAR(30) =
        CASE WHEN @status IN (N'Closed', N'Retired') THEN @status
             ELSE N'Monitoring' END;

    -- 576: the reviewer's name for the history.
    DECLARE @reviewer_name NVARCHAR(240) =
        COALESCE((SELECT employee_name FROM grac_practice.organization_employee
                   WHERE employee_id = @reviewed_by_employee_id), @caller_display_name);

    BEGIN TRY
        BEGIN TRAN;

        -- Stamp the version 216 just wrote as a Review. Identified by
        -- is_current rather than by a captured id, because 216 does not
        -- hand one back through an OUTPUT parameter.
        UPDATE grac_practice.risk_analysis
           SET analysis_purpose_code = N'Review',
               updated_by = @caller_display_name,
               updated_dt = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id
           AND is_current = 1;

        UPDATE grac_practice.risk_register
           SET last_reviewed_dt  = SYSUTCDATETIME(),
               review_count      = ISNULL(review_count, 0) + 1,
               -- The reviewer's PROPOSED date and cadence. Since 299
               -- these no longer decide anything -- status does -- so a
               -- date here simply travels to the Accept screen as the
               -- suggestion, and NULL means "no suggestion".
               next_review_date  = @next_review_date,
               review_frequency_id = COALESCE(@review_frequency_id, review_frequency_id),
               status_code       = @new_status,
               updated_by        = @caller_display_name,
               updated_dt        = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id;

        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt,
             event_note, event_by_name, event_dt)   -- 576
        VALUES
            (@risk_register_id, N'RiskReviewed', @status, @new_status,
             CONCAT(N'Risk reviewed',
                    CASE WHEN @prev_review IS NULL THEN N''
                         ELSE CONCAT(N' (was due ', CONVERT(NVARCHAR(10), @prev_review, 23), N')') END,
                    N'. ',
                    CASE WHEN @next_review_date IS NULL
                         THEN N'Next review date cleared -- it is set again when the risk is accepted.'
                         ELSE CONCAT(N'Next review ', CONVERT(NVARCHAR(10), @next_review_date, 23), N'.') END,
                    CASE WHEN @review_remarks IS NULL THEN N''
                         ELSE CONCAT(N' ', @review_remarks) END),
             @reviewed_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME(),
             -- 576: the review remark ('' = none), the reviewer, now.
             ISNULL(@review_remarks, N''), @reviewer_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    -- A review can conclude with a new treatment decision -- which is the
    -- whole point of reviewing. Delegated to 263's single writer, which
    -- raises the task if the option calls for one.
    --
    -- @suppress_result = 1: this procedure already passes through
    -- sp_risk_register_assess's result set, and a third one from the
    -- dispatch would make "which result set is the review's answer?" a
    -- question of call order rather than of contract.
    IF @treatment_option_code IS NOT NULL
        EXEC grac_practice.sp_risk_treatment_option_set
             @risk_register_id      = @risk_register_id,
             @treatment_option_code = @treatment_option_code,
             @remark                = N'Set from risk review.',
             @actor_employee_id     = @reviewed_by_employee_id,
             @caller_display_name   = @caller_display_name,
             @suppress_result       = 1;

    SELECT @risk_register_id      AS RiskRegisterId,
           @risk_number           AS RiskNumber,
           @new_status            AS StatusCode,
           @next_review_date      AS NextReviewDate,
           @treatment_option_code AS TreatmentOptionCode;
END;
GO

-- =====================================================================
-- 3. Backfill (only rows without the 576 values)
-- =====================================================================
-- Reviews: the Review analysis sp_risk_review_perform wrote in the same call.
UPDATE h
   SET event_note    = ISNULL(ra.analyst_remarks, N''),
       event_by_name = COALESCE(e.employee_name, h.actor_display_name),
       event_dt      = h.entered_dt
  FROM grac_practice.risk_register_history h
 CROSS APPLY (SELECT TOP (1) a.analyst_remarks, a.analysed_by_employee_id
                FROM grac_practice.risk_analysis a
               WHERE a.risk_register_id = h.risk_register_id
                 AND a.analysis_purpose_code = N'Review'
                 AND ABS(DATEDIFF(SECOND, a.analysis_dt, h.entered_dt)) <= 60
               ORDER BY ABS(DATEDIFF(SECOND, a.analysis_dt, h.entered_dt))) ra
  LEFT JOIN grac_practice.organization_employee e ON e.employee_id = ra.analysed_by_employee_id
 WHERE h.action_code = N'RiskReviewed' AND h.event_by_name IS NULL;

-- Acceptances: who and when, from "Risk accepted by <name> on <yyyy-mm-dd>".
UPDATE h
   SET event_by_name = SUBSTRING(h.remark, 18, CHARINDEX(N' on ', h.remark, 18) - 18),
       event_dt      = COALESCE(TRY_CONVERT(DATETIME2, SUBSTRING(h.remark, CHARINDEX(N' on ', h.remark, 18) + 4, 10), 23),
                                h.entered_dt)
  FROM grac_practice.risk_register_history h
 WHERE h.action_code = N'RiskAccepted' AND h.event_by_name IS NULL
   AND h.remark LIKE N'Risk accepted by % on %'
   AND CHARINDEX(N' on ', h.remark, 18) > 18;

-- ... the note after "Risk version N." (310 format)
;WITH v AS (
    SELECT h.history_id, h.remark,
           PATINDEX(N'%Risk version [0-9]%', h.remark) AS p
      FROM grac_practice.risk_register_history h
     WHERE h.action_code = N'RiskAccepted' AND h.event_note IS NULL)
UPDATE h
   SET event_note = LTRIM(SUBSTRING(v.remark, CHARINDEX(N'.', v.remark, v.p + 13) + 1, 4000))
  FROM grac_practice.risk_register_history h
  JOIN v ON v.history_id = h.history_id
 WHERE v.p > 0 AND CHARINDEX(N'.', v.remark, v.p + 13) > 0;

-- ... and the register's own note for each risk's latest acceptance.
;WITH lastacc AS (
    SELECT h.history_id, h.risk_register_id,
           ROW_NUMBER() OVER (PARTITION BY h.risk_register_id ORDER BY h.entered_dt DESC, h.history_id DESC) AS rn
      FROM grac_practice.risk_register_history h
     WHERE h.action_code = N'RiskAccepted')
UPDATE h
   SET event_note = r.acceptance_note
  FROM grac_practice.risk_register_history h
  JOIN lastacc l ON l.history_id = h.history_id AND l.rn = 1
  JOIN grac_practice.risk_register r ON r.risk_register_id = h.risk_register_id
 WHERE (h.event_note IS NULL OR h.event_note = N'')
   AND NULLIF(LTRIM(RTRIM(r.acceptance_note)), N'') IS NOT NULL;
GO

-- =====================================================================
-- 4. sp_risk_decision_history_list -- every acceptance and review of one
--    risk, newest first. Description = the note; a row written before
--    576 that the backfill could not split shows its full text.
--    EventDate = when it was RECORDED (2026-11-16, sir: today's acceptance
--    showed under the earlier acceptance date the form had carried over);
--    AcceptedOn = the acceptance date entered on the form.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_decision_history_list
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_register_id IS NULL
        THROW 56700, 'sp_risk_decision_history_list: risk_register_id is required.', 1;

    SELECT h.history_id AS HistoryId,
           CASE h.action_code WHEN N'RiskAccepted' THEN N'Accepted' ELSE N'Reviewed' END AS EventType,
           h.entered_dt AS EventDate,
           CASE WHEN h.action_code = N'RiskAccepted' THEN h.event_dt END AS AcceptedOn,
           COALESCE(NULLIF(h.event_by_name, N''), h.actor_display_name) AS ByName,
           COALESCE(h.event_note, h.remark) AS Description,
           h.from_status_code AS FromStatusCode,
           h.to_status_code AS ToStatusCode,
           h.entered_dt AS RecordedOn
      FROM grac_practice.risk_register_history h
     WHERE h.risk_register_id = @risk_register_id
       AND h.action_code IN (N'RiskAccepted', N'RiskReviewed')
     ORDER BY h.entered_dt DESC, h.history_id DESC;
END;
GO

-- =====================================================================
-- 5. Verification
-- =====================================================================
SELECT '576 columns' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.risk_register_history','event_note') IS NOT NULL
             AND COL_LENGTH('grac_practice.risk_register_history','event_by_name') IS NOT NULL
             AND COL_LENGTH('grac_practice.risk_register_history','event_dt') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '576 procedures',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_acceptance_save')) LIKE '%event_note%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_review_perform')) LIKE '%event_note%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_decision_history_list')) LIKE '%AcceptedOn%'
            THEN 'PASS' ELSE 'FAIL' END;
PRINT '576 complete. Restart the Api, deploy Web, then hard-refresh.';
GO
SET NOEXEC OFF;
GO
