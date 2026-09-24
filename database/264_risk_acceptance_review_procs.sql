-- =====================================================================
-- 264 Risk Centre — Acceptance, Risk Calendar, Review Risk, and the
--     derived workflow stage
--
-- WHAT CLOSES THE LOOP
-- --------------------
-- 261 gave the register somewhere to put an acceptance and a review
-- date. 262 gave it a practice/asset scope. 263 gave it a treatment
-- decision and the work that follows one. This file is the part that
-- makes the flow a CYCLE rather than a line:
--
--   ... -> Acceptance (next review date) -> Risk Calendar
--                                                |
--                                     date arrives
--                                                |
--                                                v
--                                          Review Risk
--                                                |
--                                                v
--                                     Risk Analysis, again
--
-- ---------------------------------------------------------------------
-- DECISION 1 — THE WORKFLOW STAGE IS A VIEW, NOT A COLUMN
-- ---------------------------------------------------------------------
-- 261's header set this out and this is where it is paid off.
--
-- Every screen in this flow needs to know where a risk IS: which button
-- to enable, which tab to list it under, what the chip says. That is one
-- question, and it must have one answer, or the Register grid and the
-- Review list will eventually disagree about the same risk.
--
-- vw_pm_risk_workflow_stage is that one answer. It derives the stage
-- from facts that are already columns -- analysis_pending, the treatment
-- option, the open task count, residual_pending, accepted_dt,
-- next_review_date -- so:
--
--   * it cannot drift, because there is nothing to keep in sync;
--   * it is right for risks created before this migration, because it
--     reads their actual state rather than a flag nobody set;
--   * changing the rules means changing one CASE expression.
--
-- The cost is a view with two correlated EXISTS per row. It is paid on
-- the list page only, it is covered by 261's indexes, and it is a great
-- deal cheaper than a status column that is wrong.
--
-- ---------------------------------------------------------------------
-- DECISION 2 — REVIEW REUSES sp_risk_register_assess. IT DOES NOT COPY IT
-- ---------------------------------------------------------------------
-- Requirement 8: the review page is "similar to the existing Risk
-- Analysis page" and reassesses "using the same analysis process".
--
-- Not similar -- the SAME. sp_risk_register_assess (216) already writes
-- a new versioned risk_analysis row for a registered risk, already runs
-- the §19 approval gate, already applies the result to the register. A
-- review IS that, plus bookkeeping.
--
-- So sp_risk_review_perform is a thin wrapper: it calls 216's procedure
-- unchanged, then stamps analysis_purpose_code = 'Review', advances
-- last_reviewed_dt and review_count, and clears next_review_date so the
-- risk leaves the due list. Zero lines of analysis logic are duplicated,
-- and a future change to how risks are analysed changes reviews too,
-- automatically, which is the only way the two can be guaranteed to stay
-- "the same process".
--
-- ---------------------------------------------------------------------
-- DECISION 3 — DATE COMPARISON, NOT DATETIME COMPARISON
-- ---------------------------------------------------------------------
-- "A risk should appear in Review Risk when Current Date >= Next Review
--  Date." Risks due TODAY must appear TODAY.
--
-- next_review_date is DATE (261). The comparison here is against
-- CAST(SYSUTCDATETIME() AS DATE), computed once into a variable rather
-- than inline, so:
--   * the predicate stays sargable and uses ix_pm_risk_register_next_review;
--   * every row in one call is judged against the same "today", instead
--     of a clock that can tick mid-scan across midnight.
--
-- ---------------------------------------------------------------------
-- DECISION 4 — THE CALENDAR IS A FEED, NOT A SECOND CALENDAR
-- ---------------------------------------------------------------------
-- sp_risk_review_calendar returns one row per risk with a review date in
-- a window, shaped so a month grid can bucket it by date with no further
-- work. It deliberately does NOT reuse assurance_calendar_events (028):
-- that table is a materialised schedule with rules and overrides, and a
-- risk review date is a single mutable column. Writing risk rows into it
-- would mean maintaining schedule rules for something that has none.
--
-- CONTENTS
--   1. vw_pm_risk_workflow_stage       NEW  the one stage definition
--   2. sp_risk_acceptance_save         NEW  requirement 5
--   3. sp_risk_acceptance_get          NEW
--   4. sp_risk_review_due_list         NEW  requirement 7
--   5. sp_risk_review_calendar         NEW  requirement 5, calendar
--   6. sp_risk_review_perform          NEW  requirement 8
--   7. sp_risk_register_list           REWRITE -- superset of 258
--   8. sp_risk_register_get            REWRITE -- superset of 258
--
-- ERROR CODE RANGE: 56600-56639
-- Rollback: database/264_risk_acceptance_review_procs_rollback.sql
-- Depends:  205, 206, 212, 216, 258, 261, 262, 263
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF COL_LENGTH('grac_practice.risk_register','next_review_date') IS NULL
BEGIN PRINT 'ABORT (264): risk_register.next_review_date missing -- run 261 first.'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.risk_register','accepted_dt') IS NULL
BEGIN PRINT 'ABORT (264): risk_register.accepted_dt missing -- run 261 first.'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.risk_register','residual_pending') IS NULL
BEGIN PRINT 'ABORT (264): risk_register.residual_pending missing -- run 258 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_risk_register_assess','P') IS NULL
BEGIN PRINT 'ABORT (264): sp_risk_register_assess missing -- run 216 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NULL
BEGIN PRINT 'ABORT (264): vw_pm_practice_task missing -- run 195 first.'; SET @ok = 0; END

-- 258 and 263 are hard dependencies, not soft ones: sections 7 and 8
-- REWRITE sp_risk_register_list and sp_risk_register_get as supersets of
-- 258's versions. Applying this file to a database still on 216 would
-- silently drop the residual columns those screens already read.
IF COL_LENGTH('grac_practice.risk_register','residual_rating_code') IS NULL
BEGIN PRINT 'ABORT (264): risk_register.residual_rating_code missing -- run 258 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_risk_treatment_state','P') IS NULL
BEGIN PRINT 'ABORT (264): sp_risk_treatment_state missing -- run 263 first.'; SET @ok = 0; END

IF @ok = 0
BEGIN
    RAISERROR('264_risk_acceptance_review_procs: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. vw_pm_risk_workflow_stage
--
-- The one definition of "where is this risk in the flow".
--
-- Built through sp_executesql for the reason 195 gives: CREATE VIEW has
-- no deferred name resolution, so a static statement would be PARSED
-- (and fail) even under SET NOEXEC ON when a prerequisite is missing.
--
-- THE STAGE LADDER, IN PRIORITY ORDER
-- -----------------------------------
-- The CASE is ordered by urgency, not by chronology, because a risk can
-- satisfy several conditions at once and the screen must show the one
-- that needs action:
--
--   Closed          terminal, nothing to do
--   ReviewDue       the review date has arrived -- outranks everything,
--                   because a risk due for review needs looking at
--                   whatever else is true of it
--   AnalysisDue     no inherent rating yet
--   TreatmentDue    rated, but no treatment option chosen
--   InTreatment     option chosen, work still open
--   ResidualDue     all treatment closed, no residual assessment
--   AcceptanceDue   ready to be accepted -- Tolerate chosen, or the
--                   residual assessment is done
--   Accepted        accepted, with a review date in the future
--
-- OpenTreatmentTaskCount is exposed as a column rather than left inside
-- the CASE because every screen that shows the stage also wants to show
-- WHY -- "In treatment (2 open)" is useful, "In treatment" is not.
-- =====================================================================
IF OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage','V') IS NOT NULL
    DROP VIEW grac_practice.vw_pm_risk_workflow_stage;
GO

IF OBJECT_ID('grac_practice.risk_register','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NOT NULL
BEGIN
    EXEC sp_executesql N'
CREATE VIEW grac_practice.vw_pm_risk_workflow_stage AS
WITH tt AS (
    SELECT r.risk_register_id,
           -- Parents only. BRD 11: the parent owns the commitment, so a
           -- parent with two open children is ONE open treatment task.
           SUM(CASE WHEN v.parent_task_id IS NULL THEN 1 ELSE 0 END) AS TaskCount,
           SUM(CASE WHEN v.parent_task_id IS NULL
                     AND v.closed_at IS NULL
                     AND v.current_status_is_terminal = 0
                    THEN 1 ELSE 0 END)                               AS OpenCount
      FROM grac_practice.risk_register r
      JOIN grac_practice.vw_pm_practice_task v
        ON v.organization_id = r.organization_id
       AND ((v.source_type_code = N''RiskRegister''
             AND v.source_record_id = r.risk_register_id)
         OR (r.risk_candidate_id IS NOT NULL
             AND v.source_type_code = N''Risk''
             AND v.source_record_id = r.risk_candidate_id))
     GROUP BY r.risk_register_id
)
SELECT r.risk_register_id,
       r.organization_id,
       ISNULL(tt.TaskCount, 0) AS treatment_task_count,
       ISNULL(tt.OpenCount, 0) AS open_treatment_task_count,
       CAST(CASE WHEN r.next_review_date IS NOT NULL
                  AND r.next_review_date <= CAST(SYSUTCDATETIME() AS DATE)
                  AND r.status_code NOT IN (N''Closed'', N''Retired'')
                 THEN 1 ELSE 0 END AS BIT) AS is_review_due,
       CASE
         WHEN r.status_code IN (N''Closed'', N''Retired'')      THEN N''Closed''
         WHEN r.next_review_date IS NOT NULL
          AND r.next_review_date <= CAST(SYSUTCDATETIME() AS DATE)
                                                               THEN N''ReviewDue''
         WHEN ISNULL(r.analysis_pending, 1) = 1                THEN N''AnalysisDue''
         WHEN r.treatment_option_code IS NULL                  THEN N''TreatmentDue''
         WHEN r.treatment_option_code = N''Tolerate''
          AND r.accepted_dt IS NULL                            THEN N''AcceptanceDue''
         WHEN r.treatment_option_code IN (N''Terminate'', N''Treat'', N''Transfer'')
          AND ISNULL(tt.OpenCount, 0) > 0                      THEN N''InTreatment''
         WHEN r.treatment_option_code IN (N''Terminate'', N''Treat'', N''Transfer'')
          AND ISNULL(tt.TaskCount, 0) = 0                      THEN N''InTreatment''
         WHEN ISNULL(r.residual_pending, 1) = 1                THEN N''ResidualDue''
         WHEN r.accepted_dt IS NULL                            THEN N''AcceptanceDue''
         ELSE N''Accepted''
       END AS workflow_stage_code
  FROM grac_practice.risk_register r
  LEFT JOIN tt ON tt.risk_register_id = r.risk_register_id;';
    PRINT '264: vw_pm_risk_workflow_stage created.';
END
ELSE
    PRINT '264: prerequisites for vw_pm_risk_workflow_stage missing -- view NOT created.';
GO

-- ---------------------------------------------------------------------
-- HARD STOP if the view did not get created.
--
-- WHY THIS GUARD EXISTS
-- ---------------------
-- Sections 7 and 8 rewrite sp_risk_register_list and sp_risk_register_get,
-- and both JOIN the view above. SQL Server uses DEFERRED NAME RESOLUTION
-- for procedures: a procedure that references a missing view is created
-- happily and fails at RUN time instead.
--
-- So without this guard, a failure in the dynamic CREATE VIEW above --
-- a syntax error inside the string, a permission problem, anything --
-- lets the file carry on and finish with a cheerful "installed" message,
-- while leaving the two most-used read procedures compiled against an
-- object that does not exist. The symptom is every Risk Register list
-- and detail read failing with "Invalid object name", in a screen whose
-- error message says nothing about this migration.
--
-- That is exactly the failure this file's own ROLLBACK guards against in
-- the other direction, and it should have been guarded here too. It is
-- now: if the view is missing, nothing further is executed and the two
-- read procedures keep whatever definition they already had (258's),
-- which still works.
--
-- The ELSE branch above (a genuinely missing prerequisite) reaches this
-- same stop, which is correct -- a missing risk_register or
-- vw_pm_practice_task is not a state in which to install this file.
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage','V') IS NULL
BEGIN
    PRINT 'ABORT (264): vw_pm_risk_workflow_stage was NOT created -- see the error above.';
    PRINT '             Stopping BEFORE sp_risk_register_list / sp_risk_register_get are';
    PRINT '             rewritten: they JOIN that view, and SQL Server''s deferred name';
    PRINT '             resolution would create them anyway and fail at run time on every';
    PRINT '             Risk Register read.';
    PRINT '             Nothing has been changed. Fix the view, then re-run this file.';
    RAISERROR('264_risk_acceptance_review_procs: workflow stage view missing -- aborting before the read-procedure rewrites.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 2. sp_risk_acceptance_save   (requirement 5, validation case 10)
--
-- The ONLY writer of an acceptance. Captures Accepted By, Accepted Date
-- and Next Review Date, sets status = 'Accepted', and records §20.
--
-- NEXT REVIEW DATE IS MANDATORY. Not "recommended", not "defaulted" --
-- required, and refused without.
--
-- The reason is that this column is the ONLY thing that ever brings an
-- accepted risk back. A risk accepted with a NULL review date is
-- invisible to sp_risk_review_due_list and to the calendar, forever: it
-- has been quietly retired without anybody deciding to retire it. That
-- is the single worst failure mode in this whole flow, so it is a THROW
-- rather than a warning.
--
-- IT MUST ALSO BE IN THE FUTURE. A review date of yesterday would put
-- the risk straight back on the due list the moment it was accepted,
-- which is not acceptance, it is a loop.
--
-- WHO CAN BE ACCEPTED BY
-- ----------------------
-- @accepted_by_employee_id defaults to the risk owner when not supplied,
-- because the owner accepting their own risk is the common case and
-- making the screen ask twice adds nothing. The name is frozen beside
-- the id -- see 261.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_acceptance_save
    @risk_register_id        BIGINT,
    @next_review_date        DATE,
    @accepted_by_employee_id BIGINT        = NULL,
    @accepted_date           DATE          = NULL,   -- NULL = today
    @acceptance_note         NVARCHAR(MAX) = NULL,
    @actor_employee_id       BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
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
    -- quantity. §19's whole apparatus exists to make the rating
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

    SELECT @risk_register_id AS RiskRegisterId,
           @risk_number      AS RiskNumber,
           @accept_by        AS AcceptedByEmployeeId,
           @accept_name      AS AcceptedByName,
           @accepted_on      AS AcceptedOn,
           @next_review_date AS NextReviewDate,
           N'Accepted'       AS StatusCode;
END;
GO

-- =====================================================================
-- 3. sp_risk_acceptance_get
--
-- What the acceptance screen needs to open: the current acceptance if
-- there is one, the risk's own context, and -- importantly -- whether
-- acceptance is allowed yet and why not. The screen must be able to
-- explain a disabled button; a bare boolean cannot.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_acceptance_get
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56609, 'sp_risk_acceptance_get: risk_register_id is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.risk_register
                    WHERE risk_register_id = @risk_register_id)
        THROW 56610, 'sp_risk_acceptance_get: risk not found.', 1;

    SELECT r.risk_register_id        AS RiskRegisterId,
           r.risk_number             AS RiskNumber,
           r.risk_title              AS RiskTitle,
           r.status_code             AS StatusCode,
           r.risk_owner_employee_id  AS RiskOwnerEmployeeId,
           ow.employee_name          AS RiskOwnerName,
           r.treatment_option_code   AS TreatmentOptionCode,
           r.treatment_option_name   AS TreatmentOptionName,
           r.inherent_rating_code    AS InherentRatingCode,
           r.residual_rating_code    AS ResidualRatingCode,
           r.residual_pending        AS ResidualPending,
           r.analysis_pending        AS AnalysisPending,

           r.accepted_by_employee_id AS AcceptedByEmployeeId,
           COALESCE(ab.employee_name, r.accepted_by_name) AS AcceptedByName,
           r.accepted_dt             AS AcceptedOn,
           r.acceptance_note         AS AcceptanceNote,
           r.next_review_date        AS NextReviewDate,
           r.last_reviewed_dt        AS LastReviewedOn,
           r.review_count            AS ReviewCount,
           st.workflow_stage_code    AS WorkflowStageCode,
           st.open_treatment_task_count AS OpenTreatmentTaskCount,

           CAST(CASE WHEN r.status_code IN (N'Closed', N'Retired') THEN 0
                     WHEN ISNULL(r.analysis_pending, 1) = 1        THEN 0
                     WHEN r.treatment_option_code IS NULL          THEN 0
                     ELSE 1 END AS BIT)              AS CanAccept,

           CASE WHEN r.status_code IN (N'Closed', N'Retired')
                     THEN N'This risk is closed or retired.'
                WHEN ISNULL(r.analysis_pending, 1) = 1
                     THEN N'Complete the risk analysis first.'
                WHEN r.treatment_option_code IS NULL
                     THEN N'Choose a treatment option first.'
                WHEN r.treatment_option_code = N'Tolerate'
                     THEN N'Tolerate / Accept -- this risk goes straight to acceptance.'
                WHEN ISNULL(r.residual_pending, 1) = 1
                     THEN N'Residual risk has not been assessed. You may still accept, but assessing it first is the intended order.'
                ELSE N'Ready to accept.'
           END                                        AS AcceptGuidance
      FROM grac_practice.risk_register r
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.risk_owner_employee_id
      LEFT JOIN grac_practice.organization_employee ab ON ab.employee_id = r.accepted_by_employee_id
      LEFT JOIN grac_practice.vw_pm_risk_workflow_stage st ON st.risk_register_id = r.risk_register_id
     WHERE r.risk_register_id = @risk_register_id;
END;
GO

-- =====================================================================
-- 4. sp_risk_review_due_list   (requirement 7, validation cases 11 & 12)
--
-- "A risk should appear in Review Risk when Current Date >= Next Review
--  Date."
--
-- Which is exactly the predicate below, and nothing else:
--
--   next_review_date <= @today   ->  due today, and everything overdue
--   next_review_date >  @today   ->  not yet (validation case 12)
--   next_review_date IS NULL     ->  never scheduled, so never due
--
-- Closed and Retired risks are excluded. A review is an instruction to
-- go and look at a live risk, and a terminal one has nothing to look at.
--
-- DaysOverdue is signed and computed from the same @today, so a risk due
-- today reads 0 rather than 1 or -1 depending on the hour.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_review_due_list
    @organization_id   BIGINT,
    @owner_employee_id BIGINT        = NULL,
    @rating_code       NVARCHAR(30)  = NULL,
    @search            NVARCHAR(200) = NULL,
    @include_future_days INT         = NULL,   -- NULL = due only
    @page_number       INT = 1,
    @page_size         INT = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 56611, 'sp_risk_review_due_list: organization_id is required.', 1;
    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    -- One "today" for the whole call. See decision 3.
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    -- The horizon. NULL means "due and overdue only", which is the
    -- literal requirement; a number lets the same procedure feed a
    -- "coming up in the next N days" panel without a second query whose
    -- rules could drift from these.
    DECLARE @horizon DATE =
        CASE WHEN @include_future_days IS NULL OR @include_future_days <= 0
             THEN @today ELSE DATEADD(DAY, @include_future_days, @today) END;

    SELECT r.risk_register_id       AS RiskRegisterId,
           r.risk_number            AS RiskNumber,
           r.risk_title             AS RiskTitle,
           r.risk_statement         AS RiskStatement,
           r.risk_category_name     AS RiskCategoryName,
           r.status_code            AS StatusCode,
           r.risk_owner_employee_id AS RiskOwnerEmployeeId,
           ow.employee_name         AS RiskOwnerName,
           r.business_unit          AS BusinessUnit,
           r.inherent_rating_code   AS InherentRatingCode,
           r.inherent_rating_name   AS InherentRatingName,
           r.residual_rating_code   AS ResidualRatingCode,
           r.residual_rating_name   AS ResidualRatingName,
           r.treatment_option_code  AS TreatmentOptionCode,
           r.treatment_option_name  AS TreatmentOptionName,
           r.accepted_dt            AS AcceptedOn,
           COALESCE(ab.employee_name, r.accepted_by_name) AS AcceptedByName,
           r.next_review_date       AS NextReviewDate,
           r.last_reviewed_dt       AS LastReviewedOn,
           r.review_count           AS ReviewCount,
           DATEDIFF(DAY, r.next_review_date, @today) AS DaysOverdue,
           CAST(CASE WHEN r.next_review_date <= @today THEN 1 ELSE 0 END AS BIT) AS IsDue,
           st.workflow_stage_code   AS WorkflowStageCode,
           COUNT(*) OVER ()         AS TotalRows
      FROM grac_practice.risk_register r
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.risk_owner_employee_id
      LEFT JOIN grac_practice.organization_employee ab ON ab.employee_id = r.accepted_by_employee_id
      LEFT JOIN grac_practice.vw_pm_risk_workflow_stage st ON st.risk_register_id = r.risk_register_id
     WHERE r.organization_id = @organization_id
       AND r.next_review_date IS NOT NULL
       AND r.next_review_date <= @horizon
       AND r.status_code NOT IN (N'Closed', N'Retired')
       AND (@owner_employee_id IS NULL OR r.risk_owner_employee_id = @owner_employee_id)
       AND (@rating_code IS NULL
            OR r.inherent_rating_code = @rating_code
            OR r.residual_rating_code = @rating_code)
       AND (@search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0
            OR r.risk_title     LIKE N'%' + @search + N'%'
            OR r.risk_statement LIKE N'%' + @search + N'%'
            OR r.risk_number    LIKE N'%' + @search + N'%')
     -- Most overdue first: the list is a work queue, and the oldest
     -- breach is the one that has been ignored longest.
     ORDER BY r.next_review_date ASC, r.inherent_rating_score DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- =====================================================================
-- 5. sp_risk_review_calendar   (requirement 5, the Risk Calendar)
--
-- One row per risk with a review date inside [@from, @to]. Shaped for a
-- month grid: EventDate is a bare DATE so the client buckets on it
-- directly, and every field the day-cell and the side panel need is
-- already on the row -- no follow-up call per risk.
--
-- Unlike section 4 this does NOT exclude future dates -- a calendar
-- whose whole purpose is to show what is coming would be useless if it
-- only showed what was already late. It DOES exclude Closed and Retired
-- for the same reason section 4 does.
--
-- The default window is the current month, computed with DATEFROMPARTS
-- rather than string arithmetic so it is culture-independent.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_review_calendar
    @organization_id   BIGINT,
    @from_date         DATE = NULL,
    @to_date           DATE = NULL,
    @owner_employee_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 56612, 'sp_risk_review_calendar: organization_id is required.', 1;

    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    IF @from_date IS NULL
        SET @from_date = DATEFROMPARTS(YEAR(@today), MONTH(@today), 1);
    IF @to_date IS NULL
        SET @to_date = EOMONTH(@from_date);

    IF @to_date < @from_date
        THROW 56613, 'sp_risk_review_calendar: to_date must not be before from_date.', 1;

    -- A year of day cells is already more than any grid renders; the cap
    -- stops a malformed range asking for a decade of rows.
    IF DATEDIFF(DAY, @from_date, @to_date) > 400
        THROW 56614, 'sp_risk_review_calendar: the date range must not exceed 400 days.', 1;

    SELECT r.risk_register_id       AS RiskRegisterId,
           r.risk_number            AS RiskNumber,
           r.risk_title             AS RiskTitle,
           r.next_review_date       AS EventDate,
           r.status_code            AS StatusCode,
           r.risk_category_name     AS RiskCategoryName,
           r.risk_owner_employee_id AS RiskOwnerEmployeeId,
           ow.employee_name         AS RiskOwnerName,
           r.business_unit          AS BusinessUnit,
           r.inherent_rating_code   AS InherentRatingCode,
           r.residual_rating_code   AS ResidualRatingCode,
           -- The chip colour: the residual score where one exists,
           -- because that is the risk as it stands now; the inherent one
           -- otherwise. Same precedence the register grid uses.
           COALESCE(r.residual_rating_code, r.inherent_rating_code) AS EffectiveRatingCode,
           r.treatment_option_code  AS TreatmentOptionCode,
           r.treatment_option_name  AS TreatmentOptionName,
           r.accepted_dt            AS AcceptedOn,
           COALESCE(ab.employee_name, r.accepted_by_name) AS AcceptedByName,
           r.review_count           AS ReviewCount,
           CAST(CASE WHEN r.next_review_date <  @today THEN 1 ELSE 0 END AS BIT) AS IsOverdue,
           CAST(CASE WHEN r.next_review_date =  @today THEN 1 ELSE 0 END AS BIT) AS IsToday,
           st.workflow_stage_code   AS WorkflowStageCode
      FROM grac_practice.risk_register r
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.risk_owner_employee_id
      LEFT JOIN grac_practice.organization_employee ab ON ab.employee_id = r.accepted_by_employee_id
      LEFT JOIN grac_practice.vw_pm_risk_workflow_stage st ON st.risk_register_id = r.risk_register_id
     WHERE r.organization_id = @organization_id
       AND r.next_review_date IS NOT NULL
       AND r.next_review_date BETWEEN @from_date AND @to_date
       AND r.status_code NOT IN (N'Closed', N'Retired')
       AND (@owner_employee_id IS NULL OR r.risk_owner_employee_id = @owner_employee_id)
     ORDER BY r.next_review_date, r.inherent_rating_score DESC, r.risk_title;
END;
GO

-- =====================================================================
-- 6. sp_risk_review_perform   (requirement 8)
--
-- A review IS a re-analysis. See decision 2: this delegates the whole
-- analysis to 216's sp_risk_register_assess and adds only bookkeeping.
--
-- WHAT HAPPENS TO next_review_date
-- --------------------------------
-- It is CLEARED unless the caller supplies a new one. That is
-- deliberate: after a review, the risk is back in the flow -- it may
-- need new treatment, a new residual assessment, or a fresh acceptance.
-- The next review date is set again when the risk is next ACCEPTED,
-- by sp_risk_acceptance_save, which is the one procedure that requires
-- it. Leaving the old date in place would keep the risk on the due list
-- forever; inventing a new one here would be guessing at a decision
-- acceptance exists to make.
--
-- A caller that genuinely wants "reviewed, no change, see me again in a
-- year" passes @next_review_date and gets exactly that in one call.
--
-- STATUS: an Accepted risk under review returns to Monitoring. It is no
-- longer settled -- somebody is looking at it again -- and Monitoring is
-- §17's existing word for that. Risks in any other status are left
-- alone; the analysis itself may move them.
-- =====================================================================
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
    @caller_display_name    NVARCHAR(100) = N'system'
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
    -- 216 owns this. It writes the new version, runs the §19 gate and
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
    DECLARE @new_status NVARCHAR(30) =
        CASE WHEN @status = N'Accepted' THEN N'Monitoring' ELSE @status END;

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
               next_review_date  = @next_review_date,   -- NULL clears it
               status_code       = @new_status,
               updated_by        = @caller_display_name,
               updated_dt        = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id;

        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
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
             @caller_display_name, SYSUTCDATETIME());

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
-- 7. sp_risk_register_list   (REWRITE -- strict superset of 258)
--
-- 258's body, unchanged, plus the treatment / acceptance / review block
-- and the derived stage. Every 216 column and every 258 column survives
-- in place; the new ones are appended. Every existing caller keeps
-- working without being edited, which is what makes this a superset.
--
-- TotalRows stays LAST in the projection, because the client reads it
-- positionally in one code path (see docs/risk-centre.md, "Positional
-- result sets"). Appending after it would break that.
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
    @analysis_pending BIT = NULL,
    @residual_rating_code NVARCHAR(30) = NULL,
    @residual_pending     BIT          = NULL,
    -- NEW in 264. All default to NULL = "no opinion".
    @treatment_option_code NVARCHAR(30)  = NULL,
    @workflow_stage_code   NVARCHAR(30)  = NULL,
    @review_due            BIT           = NULL
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
        -- ---- 258 ----------------------------------------------------
        r.residual_likelihood_name AS ResidualLikelihoodName,
        r.residual_impact_name     AS ResidualImpactName,
        r.residual_rating_code     AS ResidualRatingCode,
        r.residual_rating_name     AS ResidualRatingName,
        r.residual_rating_score    AS ResidualRatingScore,
        r.residual_assessed_dt     AS ResidualAssessedOn,
        r.residual_pending         AS ResidualPending,
        -- ---- 261 / 263 / 264 ----------------------------------------
        r.treatment_option_code    AS TreatmentOptionCode,
        r.treatment_option_name    AS TreatmentOptionName,
        r.treatment_task_id        AS TreatmentTaskId,
        r.accepted_dt              AS AcceptedOn,
        COALESCE(ab.employee_name, r.accepted_by_name) AS AcceptedByName,
        r.next_review_date         AS NextReviewDate,
        r.last_reviewed_dt         AS LastReviewedOn,
        r.review_count             AS ReviewCount,
        st.workflow_stage_code     AS WorkflowStageCode,
        st.open_treatment_task_count AS OpenTreatmentTaskCount,
        st.treatment_task_count      AS TreatmentTaskCount,
        st.is_review_due             AS IsReviewDue,
        -- Counts for the mapping badges. Correlated subqueries in the
        -- SELECT list, not aggregates over a join -- a join would
        -- multiply the register rows and every score in the row would
        -- have to be wrapped in an aggregate to survive it.
        (SELECT COUNT(*) FROM grac_practice.risk_practice_map pm
          WHERE pm.risk_register_id = r.risk_register_id) AS MappedPracticeCount,
        (SELECT COUNT(*) FROM grac_practice.risk_asset_map am
          WHERE am.risk_register_id = r.risk_register_id) AS MappedAssetCount,
        COUNT(*) OVER ()        AS TotalRows
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.risk_owner_employee_id
 LEFT JOIN grac_practice.organization_employee rb ON rb.employee_id = r.registered_by_employee_id
 LEFT JOIN grac_practice.organization_employee ab ON ab.employee_id = r.accepted_by_employee_id
 LEFT JOIN grac_practice.vw_pm_risk_workflow_stage st ON st.risk_register_id = r.risk_register_id
     WHERE r.organization_id = @organization_id
       AND (@status_code      IS NULL OR r.status_code         = @status_code)
       AND (@source_type_code IS NULL OR r.source_type_code    = @source_type_code)
       AND (@category_code    IS NULL OR r.risk_category_code  = @category_code)
       AND (@rating_code      IS NULL OR r.inherent_rating_code= @rating_code)
       AND (@owner_employee_id IS NULL OR r.risk_owner_employee_id = @owner_employee_id)
       AND (@analysis_pending IS NULL OR r.analysis_pending    = @analysis_pending)
       AND (@residual_rating_code IS NULL OR r.residual_rating_code = @residual_rating_code)
       AND (@residual_pending     IS NULL OR r.residual_pending     = @residual_pending)
       AND (@treatment_option_code IS NULL OR r.treatment_option_code = @treatment_option_code)
       AND (@workflow_stage_code   IS NULL OR st.workflow_stage_code  = @workflow_stage_code)
       AND (@review_due            IS NULL OR st.is_review_due        = @review_due)
       AND (@search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0
            OR r.risk_title     LIKE N'%' + @search + N'%'
            OR r.risk_statement LIKE N'%' + @search + N'%'
            OR r.risk_number    LIKE N'%' + @search + N'%')
     ORDER BY r.registered_dt DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- =====================================================================
-- 8. sp_risk_register_get   (REWRITE -- strict superset of 258)
--
-- Same rule again: every 216 and 258 column survives untouched; the
-- treatment, acceptance, review and stage block is appended.
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
        (SELECT COUNT(*) FROM grac_practice.risk_asset_map am
          WHERE am.risk_register_id = r.risk_register_id) AS MappedAssetCount
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
-- Sanity
-- =====================================================================
SELECT '264 objects present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage','V') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_acceptance_save','P')   IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_acceptance_get','P')    IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_review_due_list','P')   IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_review_calendar','P')   IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_review_perform','P')    IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- The superset promise, asserted rather than trusted: 216's columns,
-- 258's columns and 264's columns must all be in the list proc.
SELECT '264 list proc is a superset of 216 and 258' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_register_list')
                            AND definition LIKE '%AnalysisPending%'
                            AND definition LIKE '%ThreatName%'
                            AND definition LIKE '%ResidualRatingCode%'
                            AND definition LIKE '%WorkflowStageCode%'
                            AND definition LIKE '%NextReviewDate%')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT '264 get proc is a superset of 216 and 258' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_register_get')
                            AND definition LIKE '%ThreatDescription%'
                            AND definition LIKE '%ResidualTreatmentSummary%'
                            AND definition LIKE '%TreatmentOptionCode%'
                            AND definition LIKE '%AcceptanceNote%')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- Review reuses 216's analysis rather than reimplementing it. If this
-- ever fails, somebody has copied the analysis body and the two paths
-- will start to drift.
SELECT '264 review delegates to sp_risk_register_assess' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_review_perform')
                            AND definition LIKE '%sp_risk_register_assess%')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- No accepted risk may exist without a review date. This is the
-- invariant sp_risk_acceptance_save's THROW protects, checked against
-- the data on every run.
SELECT '264 every accepted risk has a review date' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.risk_register
                              WHERE accepted_dt IS NOT NULL
                                AND next_review_date IS NULL
                                AND status_code = N'Accepted')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '264 Risk acceptance, calendar, review and workflow stage installed.';
PRINT '     The stage is DERIVED in vw_pm_risk_workflow_stage -- no stage column exists.';
PRINT '     Review Risk uses next_review_date <= today; future dates do not appear.';
PRINT '     Acceptance refuses without a future next review date.';
GO

SET NOEXEC OFF;
GO
