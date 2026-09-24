-- =====================================================================
-- 299_status_drives_acceptance.sql
--
-- ONE RULE DECIDES WHEN A RISK IS WAITING TO BE ACCEPTED, AND IT IS THE
-- STATUS.
--
--     status_code = 'Monitoring'  ->  AcceptanceDue
--
-- ---------------------------------------------------------------------
-- WHAT THIS REPLACES, AND WHY
-- ---------------------------------------------------------------------
-- 296 inferred it instead, from the ABSENCE of a review date: a risk
-- that was otherwise ready and had no next_review_date was taken to be
-- awaiting acceptance. 297 then made bulk review clear that date so the
-- inference would fire.
--
-- That worked, and it was the wrong shape. Two problems showed up
-- immediately in use:
--
--   1. It fought the UI. The Review Frequency select (294) FILLS the
--      next review date in when you choose a cadence -- so picking
--      "Annual", the obvious thing to do, silently guaranteed the risk
--      would never reach the Accept tab. Twelve reviewed risks sat in
--      stage Accepted with a date of exactly today + 12 months, and
--      nothing on screen explained why.
--
--   2. It destroyed the reviewer's input. To route a risk to acceptance,
--      297 had to throw away the date and cadence the reviewer had just
--      entered -- the very information the person accepting it wants.
--
-- Reading intent out of a NULL is a guess. A status says it.
--
-- ---------------------------------------------------------------------
-- WHAT THE DATE AND THE CADENCE ARE NOW
-- ---------------------------------------------------------------------
-- A PROPOSAL, carried forward rather than consumed.
--
-- The reviewer enters "next review in a year, annually"; both are stored
-- on the risk; the Accept screen opens with them already filled in
-- (sp_risk_acceptance_get has returned NextReviewDate and
-- ReviewFrequencyId/Name since 293, and the modal already prefills from
-- them, so no UI change is needed for this); and whoever accepts may
-- change either before committing.
--
-- Nothing about the date decides routing any more. That is the point.
--
-- ---------------------------------------------------------------------
-- WHY 'Monitoring' AND NOT A NEW STATUS
-- ---------------------------------------------------------------------
-- BRD section 17 already has it, 264 already moved a reviewed risk into
-- it, and 264's own header calls it "section 17's existing word for" a
-- risk somebody is looking at again. A new status would have to be added
-- to the register filter, the dashboard tiles and every report that
-- enumerates statuses.
--
-- sp_risk_treatment_sync (263) also sets Monitoring, when a treated
-- risk's tasks all close. Those risks are NOT affected: the InTreatment
-- and ResidualDue branches sit above the acceptance branch, so such a
-- risk still goes to its residual assessment first and only reaches
-- AcceptanceDue once that is done -- which is correct.
--
-- CONTENTS
--   1. vw_pm_risk_workflow_stage   status rule replaces the null-date rule
--   2. sp_risk_review_perform      always Monitoring; records the cadence
--   3. sp_risk_bulk_review         keeps the date again; defaults to Monitoring
--
-- SUPERSEDES the rules added by 296 and 297. Both stay applied -- 296's
-- Tolerate fix is still needed and is preserved below -- but the
-- null-date routing they introduced is gone.
--
-- Re-runnable: yes.
-- Rollback: database/299_status_drives_acceptance_rollback.sql
-- DEPENDS ON: 296 (the Tolerate branch this preserves), 298 (section 3
--             is 298's body; without it the @suppress_result fix would
--             be undone).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
   OR OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NULL
BEGIN PRINT 'ABORT (299): risk_register or vw_pm_practice_task missing.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage','V') IS NULL
BEGIN PRINT 'ABORT (299): vw_pm_risk_workflow_stage missing -- run 264 and 296 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.sp_risk_review_perform','P') IS NULL
BEGIN PRINT 'ABORT (299): sp_risk_review_perform missing -- run 264 first.'; SET @ok = 0; END

-- Section 3 is 298's body. Applying 299 to a database still on 294/297
-- would silently undo 298's @suppress_result fix and reinstate the
-- INSERT ... EXEC defect, so refuse instead.
IF NOT EXISTS (SELECT 1 FROM sys.parameters
                WHERE object_id = OBJECT_ID('grac_practice.sp_risk_acceptance_save')
                  AND name = '@suppress_result')
BEGIN
    PRINT 'ABORT (299): migration 298 is not applied.';
    PRINT '    Section 3 below is 298''s body; applying it now would undo 298.';
    SET @ok = 0;
END

IF COL_LENGTH('grac_practice.risk_register','review_frequency_id') IS NULL
BEGIN PRINT 'ABORT (299): risk_register.review_frequency_id missing -- run 293 first.'; SET @ok = 0; END

IF @ok = 0
BEGIN
    RAISERROR('299_status_drives_acceptance: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. vw_pm_risk_workflow_stage -- re-issued from 296
--
-- Changed in exactly two places, both marked CHANGED IN 299: the two
-- AcceptanceDue tests now read status_code instead of next_review_date.
-- 296's Tolerate nested CASE is preserved -- it fixed a separate defect
-- (an accepted Tolerate risk reading ResidualDue forever) that has
-- nothing to do with this one.
-- =====================================================================
DROP VIEW grac_practice.vw_pm_risk_workflow_stage;
GO

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
         -- CHANGED IN 296. Tolerate is now decided ENTIRELY here, by a
         -- nested CASE, instead of falling through when it does not
         -- match.
         --
         -- 264 wrote this branch as "Tolerate AND accepted_dt IS NULL",
         -- which is right until the risk IS accepted -- after that it
         -- falls past Tolerate, past both InTreatment tests (Tolerate is
         -- in neither list) and lands on ResidualDue. Nothing ever
         -- clears residual_pending for a Tolerate risk, because a
         -- Tolerate risk never HAS a residual assessment -- that is the
         -- very reason this branch sits above that check. So every
         -- accepted Tolerate risk has been reading "ResidualDue",
         -- waiting forever on an assessment it will never receive.
         --
         -- Owning the option outright fixes that and the review case in
         -- one move: a Tolerate risk is AcceptanceDue or Accepted, and
         -- can no longer reach a branch that does not apply to it.
         WHEN r.treatment_option_code = N''Tolerate''
              THEN CASE WHEN r.accepted_dt IS NULL
                          OR r.status_code = N''Monitoring''
                         THEN N''AcceptanceDue''
                        ELSE N''Accepted'' END
         WHEN r.treatment_option_code IN (N''Terminate'', N''Treat'', N''Transfer'')
          AND ISNULL(tt.OpenCount, 0) > 0                      THEN N''InTreatment''
         WHEN r.treatment_option_code IN (N''Terminate'', N''Treat'', N''Transfer'')
          AND ISNULL(tt.TaskCount, 0) = 0                      THEN N''InTreatment''
         WHEN ISNULL(r.residual_pending, 1) = 1                THEN N''ResidualDue''
         -- CHANGED IN 296. Acceptance REQUIRES a next review date
         -- (56601), so every accepted risk has one; a ready risk without
         -- one can only be a risk a review cleared, and it is waiting to
         -- be accepted again.
         WHEN r.accepted_dt IS NULL
           OR r.status_code = N''Monitoring''                   THEN N''AcceptanceDue''
         ELSE N''Accepted''
       END AS workflow_stage_code
  FROM grac_practice.risk_register r
  LEFT JOIN tt ON tt.risk_register_id = r.risk_register_id;';
GO

IF OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage','V') IS NULL
BEGIN
    PRINT '*** ABORT (299): the view was NOT recreated. sp_risk_register_list,';
    PRINT '    sp_risk_register_get and sp_risk_acceptance_get all join it.';
    PRINT '    Re-run 296 to restore it.';
    RAISERROR('299: vw_pm_risk_workflow_stage was dropped and not recreated.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 2. sp_risk_review_perform -- re-issued from 264
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
-- 3. sp_risk_bulk_review -- re-issued from 298
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_bulk_review
    @risk_register_ids       NVARCHAR(MAX),
    @review_remarks          NVARCHAR(MAX) = NULL,
    @status_code             NVARCHAR(30)  = NULL,
    @next_review_date        DATE          = NULL,
    @reviewed_by_employee_id BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N'system',
    -- NEW in 294. NULL = not recorded, which is what every pre-294
    -- caller sends and what a Custom / Event-driven cadence
    -- legitimately has.
    @review_frequency_id     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_ids IS NULL OR LEN(LTRIM(RTRIM(@risk_register_ids))) = 0
        THROW 56720, 'sp_risk_bulk_review: at least one risk must be selected.', 1;

    -- Nothing to do is a mistake worth naming: a form that posts three
    -- empty fields has not reviewed anything.
    --
    -- A frequency is deliberately NOT enough on its own. It describes
    -- how a date was arrived at; with no date and no status and no note
    -- there is nothing for it to describe, and the UI derives a date
    -- whenever a cadence is picked, so this cannot block real use.
    IF @review_remarks IS NULL AND @status_code IS NULL AND @next_review_date IS NULL
        THROW 56721, 'sp_risk_bulk_review: supply at least one of remarks, status or next review date.', 1;

    -- NEW in 299. A bulk review with no explicit status means "these
    -- were looked at" -- and since 299 that has to be said in the
    -- status, because status is what routes a risk to the Accept tab.
    --
    -- Set BEFORE the validation below on purpose, so Monitoring goes
    -- through 56723's allowed-list check and through
    -- sp_risk_register_status_set like any other status. 270's DECISION 1
    -- stands: this procedure still never writes status_code itself.
    IF @status_code IS NULL
        SET @status_code = N'Monitoring';

    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    -- Checked ONCE. This fails identically for every risk, so running the
    -- loop would produce N copies of one message. Same rule as
    -- sp_risk_acceptance_save 56602 and sp_risk_review_perform 56616.
    IF @next_review_date IS NOT NULL AND @next_review_date <= @today
        THROW 56722, 'sp_risk_bulk_review: the next review date must be in the future. Reviewing a risk again in the past is not a schedule.', 1;

    IF @status_code IS NOT NULL
       AND @status_code NOT IN (N'Active', N'UnderTreatment', N'Accepted',
                                N'Monitoring', N'Closed', N'Retired')
        THROW 56723, 'sp_risk_bulk_review: unknown status_code (BRD section 17).', 1;

    -- Closing or retiring needs a reason per risk (56174), and a bulk
    -- form has one shared note. Rather than let fifty risks be closed on
    -- one line of text, bulk simply does not offer it.
    IF @status_code IN (N'Closed', N'Retired')
        THROW 56724, 'sp_risk_bulk_review: closing or retiring is not a bulk action -- each needs its own reason (BRD section 20). Close risks individually.', 1;

    -- NEW in 294. Checked once, for the reason 56722 is: an unknown or
    -- retired cadence is wrong with the REQUEST, not with any of the
    -- risks, and reporting it fifty times as a per-risk skip would
    -- blame the risks for it. The name is resolved here too, so the
    -- audit remark below can read "Quarterly" without a lookup per row.
    DECLARE @freq_name NVARCHAR(80) = NULL;

    IF @review_frequency_id IS NOT NULL
    BEGIN
        SELECT @freq_name = f.frequency_name
          FROM grac_practice.frequency_master f
         WHERE f.frequency_id = @review_frequency_id
           AND f.is_active    = 1;

        IF @freq_name IS NULL
            THROW 56726, 'sp_risk_bulk_review: unknown or inactive review frequency.', 1;
    END

    -- ---- the selection ----------------------------------------------
    DECLARE @sel TABLE (risk_register_id BIGINT PRIMARY KEY);

    INSERT INTO @sel (risk_register_id)
    SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT)
      FROM STRING_SPLIT(@risk_register_ids, ',')
     WHERE TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT) IS NOT NULL;

    IF NOT EXISTS (SELECT 1 FROM @sel)
        THROW 56725, 'sp_risk_bulk_review: no valid risk ids were supplied.', 1;

    -- ---- the report --------------------------------------------------
    DECLARE @out TABLE (
        Seq              INT IDENTITY(1,1),
        RiskRegisterId   BIGINT,
        RiskNumber       NVARCHAR(60),
        RiskTitle        NVARCHAR(300),
        Outcome          NVARCHAR(20),    -- Applied | Skipped | Unchanged
        Reason           NVARCHAR(400),
        FromStatus       NVARCHAR(30),
        ToStatus         NVARCHAR(30),
        FromReviewDate   DATE,
        ToReviewDate     DATE
    );

    -- CHANGED IN 298. The two INSERT ... EXEC sinks 294 introduced are
    -- gone, and with them the defect they carried: SQL Server forbids a
    -- procedure called inside INSERT ... EXEC from issuing ROLLBACK, and
    -- BOTH composed procedures do exactly that in their CATCH. So every
    -- risk that legitimately failed a rule -- the skip-and-report path
    -- this procedure exists for -- reported "Cannot use the ROLLBACK
    -- statement within an INSERT-EXEC statement" instead of its real
    -- reason, and left a doomed transaction behind it.
    --
    -- 298 adds @suppress_result to both procedures instead, which is how
    -- sp_risk_analysis_save and sp_risk_treatment_option_set have always
    -- solved this. A plain EXEC that returns nothing needs no sink.
    -- @cur_freq is NEW in 294; the rest are 270's.
    DECLARE @id BIGINT, @num NVARCHAR(60), @title NVARCHAR(300),
            @cur_status NVARCHAR(30), @cur_review DATE, @org BIGINT,
            @err NVARCHAR(400), @applied BIT, @cur_freq INT;

    DECLARE risk_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT s.risk_register_id FROM @sel s ORDER BY s.risk_register_id;

    OPEN risk_cur;
    FETCH NEXT FROM risk_cur INTO @id;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @err = NULL; SET @applied = 0; SET @cur_freq = NULL;

        SELECT @org        = r.organization_id,
               @cur_status = r.status_code,
               @cur_review = r.next_review_date,
               -- NEW in 294. Read before the write, so the audit row
               -- below can record the cadence as OLD -> NEW.
               @cur_freq   = r.review_frequency_id,
               @num        = r.risk_number,
               @title      = r.risk_title
          FROM grac_practice.risk_register r
         WHERE r.risk_register_id = @id;

        IF @org IS NULL
            SET @err = N'Risk not found.';
        ELSE IF @cur_status IN (N'Closed', N'Retired')
            SET @err = CONCAT(N'This risk is ', LOWER(@cur_status),
                              N' -- reopen it before reviewing it.');

        IF @err IS NOT NULL
        BEGIN
            INSERT INTO @out (RiskRegisterId, RiskNumber, RiskTitle, Outcome, Reason,
                              FromStatus, ToStatus, FromReviewDate, ToReviewDate)
            VALUES (@id, @num, @title, N'Skipped', @err, @cur_status, NULL, @cur_review, NULL);
            FETCH NEXT FROM risk_cur INTO @id;
            CONTINUE;
        END

        BEGIN TRY
            BEGIN TRAN;

            -- ---- status, through the procedure that owns it ----------
            IF @status_code IS NOT NULL AND @status_code <> @cur_status
            BEGIN
                IF @status_code = N'Accepted'
                    -- Carries the acceptance rules AND sets
                    -- next_review_date itself, which is why the date is
                    -- passed here rather than written twice. NEW in 294:
                    -- the cadence travels the same way, for the same
                    -- reason -- acceptance owns both columns.
                    --
                    -- Plain EXEC with @suppress_result = 1 (298), so no
                    -- result set reaches the caller and no INSERT ... EXEC
                    -- blocks this procedure's ROLLBACK.
                    EXEC grac_practice.sp_risk_acceptance_save
                         @risk_register_id        = @id,
                         @next_review_date        = @next_review_date,
                         @accepted_by_employee_id = @reviewed_by_employee_id,
                         @accepted_date           = NULL,   -- NULL = today
                         @acceptance_note         = @review_remarks,
                         @actor_employee_id       = @reviewed_by_employee_id,
                         @caller_display_name     = @caller_display_name,
                         @review_frequency_id     = @review_frequency_id,
                         @suppress_result         = 1;
                ELSE
                    EXEC grac_practice.sp_risk_register_status_set
                         @risk_register_id    = @id,
                         @status_code         = @status_code,
                         @remark              = @review_remarks,
                         @actor_employee_id   = @reviewed_by_employee_id,
                         @caller_display_name = @caller_display_name,
                         @suppress_result     = 1;

                SET @applied = 1;
            END

            -- ---- the review stamp -----------------------------------
            -- next_review_date is set here only when acceptance did not
            -- already set it, so the two paths cannot disagree.
            --
            -- NEW in 294: review_frequency_id takes the identical
            -- COALESCE, so a bulk review that moves dates without
            -- accepting still records what it moved them by. On the
            -- accepted path this re-writes the value acceptance just
            -- wrote -- the same harmless overlap the date already has.
            UPDATE grac_practice.risk_register
               -- CHANGED IN 297. Assignment, not COALESCE: a blank
               -- date CLEARS the schedule, exactly as the single review
               -- has always done. 296 then reads "ready, no review date"
               -- as AcceptanceDue, so a bulk-reviewed risk lands on the
               -- Accept tab without anyone asking it to.
               -- CHANGED IN 299, reverting 297. The date is a PROPOSAL
               -- again, carried to the Accept screen; it no longer
               -- decides whether the risk returns for acceptance, so
               -- clearing it would only destroy the reviewer's input.
               -- NULL means "leave whatever was there".
               SET next_review_date    = COALESCE(@next_review_date, next_review_date),
                   review_frequency_id = COALESCE(@review_frequency_id, review_frequency_id),
                   last_reviewed_dt    = SYSUTCDATETIME(),
                   review_count        = ISNULL(review_count, 0) + 1,
                   updated_by          = @caller_display_name,
                   updated_dt          = SYSUTCDATETIME()
             WHERE risk_register_id = @id;

            -- CHANGED IN 297. NULL-safe on both sides: clearing a date
            -- is a change, and the old test (which required the NEW value
            -- to be non-NULL) would have reported it as "Unchanged --
            -- nothing was different".
            IF (@cur_review IS NULL     AND @next_review_date IS NOT NULL)
            OR (@cur_review IS NOT NULL AND @next_review_date IS NULL)
            OR (@cur_review IS NOT NULL AND @next_review_date IS NOT NULL
                AND @cur_review <> @next_review_date)
                SET @applied = 1;

            -- NEW in 294. Without this a frequency-only change would be
            -- reported as "Unchanged -- nothing was different", which
            -- would be false: something was recorded.
            IF @review_frequency_id IS NOT NULL
               AND (@cur_freq IS NULL OR @cur_freq <> @review_frequency_id)
                SET @applied = 1;

            -- ---- audit ----------------------------------------------
            -- The review itself.
            INSERT INTO grac_practice.risk_register_history
                (risk_register_id, action_code, from_status_code, to_status_code,
                 field_code, from_value, to_value,
                 remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
            VALUES
                (@id, N'BulkReview', @cur_status, ISNULL(@status_code, @cur_status),
                 NULL, NULL, NULL,
                 ISNULL(@review_remarks, N'Reviewed (bulk).'),
                 @reviewed_by_employee_id, NULL, @caller_display_name, SYSUTCDATETIME());

            -- The review date, as OLD -> NEW. A separate row with its own
            -- field_code, so "when did this risk's review date move, and
            -- from what?" is a query rather than a search through prose.
            -- CHANGED IN 297, same NULL-safe test. Clearing a review
            -- date is exactly the kind of change an auditor asks about,
            -- and the old guard wrote no row at all for it.
            IF (@cur_review IS NULL     AND @next_review_date IS NOT NULL)
            OR (@cur_review IS NOT NULL AND @next_review_date IS NULL)
            OR (@cur_review IS NOT NULL AND @next_review_date IS NOT NULL
                AND @cur_review <> @next_review_date)
                INSERT INTO grac_practice.risk_register_history
                    (risk_register_id, action_code, from_status_code, to_status_code,
                     field_code, from_value, to_value,
                     remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
                VALUES
                    (@id, N'FieldChange', NULL, NULL,
                     N'next_review_date',
                     CONVERT(NVARCHAR(10), @cur_review, 23),
                     CONVERT(NVARCHAR(10), @next_review_date, 23),
                     CASE WHEN @next_review_date IS NULL
                          THEN N'Next review date cleared during bulk review -- returned for acceptance.'
                          ELSE N'Next review date changed during bulk review.' END,
                     @reviewed_by_employee_id, NULL, @caller_display_name, SYSUTCDATETIME());

            -- NEW in 294. Same shape, same reason -- the cadence a date
            -- was derived from is exactly the kind of thing an auditor
            -- asks about after the fact.
            --
            -- from_value / to_value hold the IDs, not the names: the
            -- field_code says review_frequency_id, and a name under that
            -- code would break anyone reading to_value as the key it
            -- claims to be. The readable name goes in the remark, so the
            -- row is both queryable and legible.
            IF @review_frequency_id IS NOT NULL
               AND (@cur_freq IS NULL OR @cur_freq <> @review_frequency_id)
                INSERT INTO grac_practice.risk_register_history
                    (risk_register_id, action_code, from_status_code, to_status_code,
                     field_code, from_value, to_value,
                     remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
                VALUES
                    (@id, N'FieldChange', NULL, NULL,
                     N'review_frequency_id',
                     CONVERT(NVARCHAR(20), @cur_freq),
                     CONVERT(NVARCHAR(20), @review_frequency_id),
                     CONCAT(N'Review frequency set to ', @freq_name, N' during bulk review.'),
                     @reviewed_by_employee_id, NULL, @caller_display_name, SYSUTCDATETIME());

            -- The status change, same shape, so both are queryable the
            -- same way even though from/to_status_code also record it.
            IF @status_code IS NOT NULL AND @status_code <> @cur_status
                INSERT INTO grac_practice.risk_register_history
                    (risk_register_id, action_code, from_status_code, to_status_code,
                     field_code, from_value, to_value,
                     remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
                VALUES
                    (@id, N'FieldChange', @cur_status, @status_code,
                     N'status_code', @cur_status, @status_code,
                     N'Status changed during bulk review.',
                     @reviewed_by_employee_id, NULL, @caller_display_name, SYSUTCDATETIME());

            COMMIT;

            INSERT INTO @out (RiskRegisterId, RiskNumber, RiskTitle, Outcome, Reason,
                              FromStatus, ToStatus, FromReviewDate, ToReviewDate)
            VALUES (@id, @num, @title,
                    CASE WHEN @applied = 1 THEN N'Applied' ELSE N'Unchanged' END,
                    CASE WHEN @applied = 1 THEN NULL
                         ELSE N'Reviewed; nothing was different.' END,
                    @cur_status, ISNULL(@status_code, @cur_status),
                    -- CHANGED IN 297: what was WRITTEN, which is NULL
                    -- when the schedule was cleared. COALESCE here would
                    -- report the old date as though it survived.
                    @cur_review, @next_review_date);
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;

            -- A THROW from the composed procedures is INFORMATION -- this
            -- risk has no treatment option, its analysis is incomplete --
            -- not a fault. It is recorded against the risk and the loop
            -- continues.
            SET @err = LEFT(ERROR_MESSAGE(), 400);

            INSERT INTO @out (RiskRegisterId, RiskNumber, RiskTitle, Outcome, Reason,
                              FromStatus, ToStatus, FromReviewDate, ToReviewDate)
            VALUES (@id, @num, @title, N'Skipped', @err, @cur_status, NULL, @cur_review, NULL);
        END CATCH

        FETCH NEXT FROM risk_cur INTO @id;
    END

    CLOSE risk_cur;
    DEALLOCATE risk_cur;

    -- ---- the report --------------------------------------------------
    -- Result shape is UNCHANGED from 270. The client reads the same nine
    -- columns, so an API deployed before this migration keeps working.
    SELECT RiskRegisterId, RiskNumber, RiskTitle, Outcome, Reason,
           FromStatus, ToStatus, FromReviewDate, ToReviewDate
      FROM @out ORDER BY Seq;
END;
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '--- 299 verification ---';

SELECT '299 the stage keys off status, not a null date' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage')
                            AND definition LIKE '%status_code = N''Monitoring''%')
             AND NOT EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage')
                            AND definition LIKE '%OR r.next_review_date IS NULL%')
            THEN 'PASS -- one rule, and it is the status'
            ELSE '*** FAIL -- the null-date rule is still in the view' END AS Result;

SELECT '299 296''s Tolerate fix survived' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage')
                            AND definition LIKE '%THEN CASE WHEN r.accepted_dt IS NULL%')
            THEN 'PASS -- Tolerate is still decided in its own branch'
            ELSE '*** FAIL -- accepted Tolerate risks will read ResidualDue again' END AS Result;

SELECT '299 a review always moves the risk to Monitoring' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_review_perform')
                            AND definition LIKE '%ELSE N''Monitoring'' END%')
            THEN 'PASS' ELSE '*** FAIL -- reviewed risks may strand in their old status' END AS Result;

SELECT '299 the review records the proposed cadence' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_review_perform')
                            AND name = '@review_frequency_id')
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

SELECT '299 bulk review keeps the reviewer''s date' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%COALESCE(@next_review_date, next_review_date)%')
            THEN 'PASS -- 297''s clearing is reverted; the date is a proposal'
            ELSE '*** FAIL' END AS Result;

SELECT '299 298''s @suppress_result fix survived' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%@suppress_result%')
             AND NOT EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%INSERT INTO @accept_sink%')
            THEN 'PASS -- a skipped risk can still report its own reason'
            ELSE '*** FAIL -- the INSERT-EXEC defect is back' END AS Result;

-- The point of the migration, asked of the real data.
SELECT '299 reviewed risks are now on the Accept tab' AS Check_,
       CONCAT(COUNT(*), ' risk(s) read AcceptanceDue because their status is Monitoring') AS Result
  FROM grac_practice.risk_register r
  JOIN grac_practice.vw_pm_risk_workflow_stage st
    ON st.risk_register_id = r.risk_register_id
 WHERE r.status_code = N'Monitoring'
   AND st.workflow_stage_code = N'AcceptanceDue';

PRINT '299 Status drives acceptance.';
PRINT '     Reviewed -> Monitoring -> the Accept tab, whatever the date says.';
PRINT '     The date and cadence entered at review travel to the Accept screen';
PRINT '     as the proposal, and whoever accepts may change them.';
GO

SET NOEXEC OFF;
GO
