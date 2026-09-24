-- =====================================================================
-- 298_suppress_result_on_composed_procs.sql
--
-- FIXES A DEFECT 294 AND 295 INTRODUCED
--
--   Bulk review and bulk accept exist to SKIP AND REPORT: a risk that
--   fails a rule is recorded with its reason and the rest proceed. That
--   is the whole design (270, DECISION 2).
--
--   294 and 295 broke exactly that path.
--
-- ---------------------------------------------------------------------
-- WHAT WENT WRONG
-- ---------------------------------------------------------------------
-- Both composed procedures END WITH A SELECT, so EXEC'd bare inside a
-- loop they stream one result set per risk to the client ahead of the
-- report. 294 tried to silence that with INSERT ... EXEC.
--
-- But SQL Server forbids a procedure called inside INSERT ... EXEC from
-- issuing ROLLBACK -- and both of them do, in their CATCH blocks:
--
--     sp_risk_acceptance_save        IF @@TRANCOUNT > 0 ROLLBACK; THROW;
--     sp_risk_register_status_set    IF @@TRANCOUNT > 0 ROLLBACK; THROW;
--
-- So the moment a risk legitimately failed a rule -- no treatment
-- option (56606), analysis incomplete (56605), accepter in another
-- organisation (56608) -- the procedure entered its CATCH, hit its own
-- ROLLBACK, and SQL Server raised
--
--     "Cannot use the ROLLBACK statement within an INSERT-EXEC statement."
--
-- The real reason was destroyed and replaced by that, leaving a doomed
-- transaction behind it. The happy path worked, which is why this
-- survived review: it only fails when a risk is skipped, which is the
-- one case those procedures were written for.
--
-- ---------------------------------------------------------------------
-- THE FIX WAS ALREADY IN THE CODEBASE
-- ---------------------------------------------------------------------
-- sp_risk_analysis_save (206) and sp_risk_treatment_option_set (263)
-- both carry a @suppress_result parameter for precisely this problem,
-- and 263's header explains why it exists. 294 should have used it.
--
-- 298 adds the same parameter to the two procedures that lacked it and
-- rewrites both bulk procedures to call them plainly with
-- @suppress_result = 1. No INSERT ... EXEC anywhere, no interference
-- with anybody's transaction handling, and one result set per bulk call
-- exactly as before.
--
-- CONTENTS
--   1. sp_risk_acceptance_save      + @suppress_result   (from 293)
--   2. sp_risk_register_status_set  + @suppress_result   (from 206)
--   3. sp_risk_bulk_review          plain EXEC           (from 297)
--   4. sp_risk_bulk_accept          plain EXEC           (from 295)
--
-- Sections 1 and 2 are strict supersets: the parameter defaults to 0, so
-- every existing caller -- the API, the single Accept modal, the review
-- page -- behaves exactly as it does today.
--
-- Re-runnable: yes (CREATE OR ALTER only, no schema change).
-- Rollback: database/298_suppress_result_on_composed_procs_rollback.sql
-- DEPENDS ON: 293 (acceptance_save's @review_frequency_id),
--             295 (sp_risk_bulk_accept), 296, 297 (bulk review's
--             assignment of next_review_date -- section 3 preserves it).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF OBJECT_ID('grac_practice.sp_risk_acceptance_save','P') IS NULL
BEGIN PRINT 'ABORT (298): sp_risk_acceptance_save missing -- run 264 and 293 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.sp_risk_register_status_set','P') IS NULL
BEGIN PRINT 'ABORT (298): sp_risk_register_status_set missing -- run 206 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.sp_risk_bulk_review','P') IS NULL
BEGIN PRINT 'ABORT (298): sp_risk_bulk_review missing -- run 270, 294 and 297 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.sp_risk_bulk_accept','P') IS NULL
BEGIN PRINT 'ABORT (298): sp_risk_bulk_accept missing -- run 295 first.'; SET @ok = 0; END

IF NOT EXISTS (SELECT 1 FROM sys.parameters
                WHERE object_id = OBJECT_ID('grac_practice.sp_risk_acceptance_save')
                  AND name = '@review_frequency_id')
BEGIN PRINT 'ABORT (298): sp_risk_acceptance_save has no @review_frequency_id -- run 293 first.'; SET @ok = 0; END

-- 297 changed how bulk review writes next_review_date. Section 3 is
-- extracted from 297, so applying 298 to a database that never had 297
-- would install 297's behaviour as a side effect. Refuse instead of
-- surprising anyone.
IF NOT EXISTS (SELECT 1 FROM sys.sql_modules
                WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                  AND definition LIKE '%SET next_review_date    = @next_review_date,%')
BEGIN
    PRINT 'ABORT (298): sp_risk_bulk_review is not at 297 yet.';
    PRINT '    Section 3 below is 297''s body plus the EXEC change, so applying it';
    PRINT '    now would quietly bring 297''s behaviour with it. Run 297 first.';
    SET @ok = 0;
END

IF @ok = 0
BEGIN
    RAISERROR('298_suppress_result_on_composed_procs: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_risk_acceptance_save -- re-issued from 293
--    Changed in two places, both marked NEW in 298.
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

    IF ISNULL(@suppress_result, 0) = 1
        RETURN;

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
-- 2. sp_risk_register_status_set -- re-issued from 206
--    Changed in two places, both marked NEW in 298.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_register_status_set
    @risk_register_id    BIGINT,
    @status_code         NVARCHAR(30),
    @remark              NVARCHAR(MAX) = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system',
    -- NEW in 298. Same reason as sp_risk_acceptance_save above: this is
    -- called both directly and from inside sp_risk_bulk_review.
    @suppress_result     BIT           = 0
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

    IF ISNULL(@suppress_result, 0) = 1
        RETURN;

    SELECT @risk_register_id AS RiskRegisterId, @status_code AS StatusCode;
END;
GO

-- =====================================================================
-- 3. sp_risk_bulk_review -- re-issued from 297
--    The two sinks are gone; both EXECs pass @suppress_result = 1.
--    Everything 270, 294, 296 and 297 established is preserved.
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
               SET next_review_date    = @next_review_date,
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
-- 4. sp_risk_bulk_accept -- re-issued from 295
--    The sink is gone; the EXEC passes @suppress_result = 1 and the
--    report reads what was written back from risk_register.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_bulk_accept
    @risk_register_ids       NVARCHAR(MAX),
    -- REQUIRED, exactly as it is for one risk. A risk accepted with no
    -- review date never comes back; accepting thirty that way would
    -- retire thirty risks without anybody deciding to.
    @next_review_date        DATE,
    @accepted_by_employee_id BIGINT        = NULL,
    @accepted_date           DATE          = NULL,   -- NULL = today
    @acceptance_note         NVARCHAR(MAX) = NULL,
    @review_frequency_id     INT           = NULL,
    @actor_employee_id       BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_ids IS NULL OR LEN(LTRIM(RTRIM(@risk_register_ids))) = 0
        THROW 56750, 'sp_risk_bulk_accept: at least one risk must be selected.', 1;

    -- Refused here as well as in sp_risk_acceptance_save (56601), because
    -- here it can be said once instead of once per risk.
    IF @next_review_date IS NULL
        THROW 56751, 'sp_risk_bulk_accept: a next review date is required. Without one these risks would never return for review.', 1;

    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    IF @next_review_date <= @today
        THROW 56752, 'sp_risk_bulk_accept: the next review date must be in the future.', 1;

    -- Same rule, and the same reasoning, as 294's 56726: wrong with the
    -- request, not with any of the risks.
    DECLARE @freq_name NVARCHAR(80) = NULL;

    IF @review_frequency_id IS NOT NULL
    BEGIN
        SELECT @freq_name = f.frequency_name
          FROM grac_practice.frequency_master f
         WHERE f.frequency_id = @review_frequency_id
           AND f.is_active    = 1;

        IF @freq_name IS NULL
            THROW 56753, 'sp_risk_bulk_accept: unknown or inactive review frequency.', 1;
    END

    -- ---- the selection ----------------------------------------------
    DECLARE @sel TABLE (risk_register_id BIGINT PRIMARY KEY);

    INSERT INTO @sel (risk_register_id)
    SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT)
      FROM STRING_SPLIT(@risk_register_ids, ',')
     WHERE TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT) IS NOT NULL;

    IF NOT EXISTS (SELECT 1 FROM @sel)
        THROW 56754, 'sp_risk_bulk_accept: no valid risk ids were supplied.', 1;

    -- ---- the report --------------------------------------------------
    DECLARE @out TABLE (
        Seq              INT IDENTITY(1,1),
        RiskRegisterId   BIGINT,
        RiskNumber       NVARCHAR(60),
        RiskTitle        NVARCHAR(300),
        Outcome          NVARCHAR(20),    -- Applied | Skipped
        Reason           NVARCHAR(400),
        FromStatus       NVARCHAR(30),
        ToStatus         NVARCHAR(30),
        AcceptedOn       DATETIME2,
        NextReviewDate   DATE
    );

    -- CHANGED IN 298. The @saved sink is gone. It was an INSERT ... EXEC
    -- around sp_risk_acceptance_save, and that procedure rolls back in
    -- its own CATCH -- which INSERT ... EXEC forbids. Every risk that
    -- failed a rule therefore reported "Cannot use the ROLLBACK
    -- statement within an INSERT-EXEC statement" rather than the refusal
    -- the operator needed to read.
    --
    -- The procedure is now called plainly with @suppress_result = 1, and
    -- the two values the report wants are read back from the row it just
    -- wrote -- which is the same information, from the same source of
    -- truth.
    DECLARE @id BIGINT, @num NVARCHAR(60), @title NVARCHAR(300),
            @cur_status NVARCHAR(30), @org BIGINT, @err NVARCHAR(400),
            @saved_on DATETIME2, @saved_status NVARCHAR(30);

    DECLARE accept_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT s.risk_register_id FROM @sel s ORDER BY s.risk_register_id;

    OPEN accept_cur;
    FETCH NEXT FROM accept_cur INTO @id;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @err = NULL;

        SELECT @org        = r.organization_id,
               @cur_status = r.status_code,
               @num        = r.risk_number,
               @title      = r.risk_title
          FROM grac_practice.risk_register r
         WHERE r.risk_register_id = @id;

        -- Two cheap pre-checks, purely for a better message than the
        -- THROW would give. Everything else is left to
        -- sp_risk_acceptance_save, which owns the rules.
        IF @org IS NULL
            SET @err = N'Risk not found.';
        ELSE IF @cur_status IN (N'Closed', N'Retired')
            SET @err = CONCAT(N'This risk is ', LOWER(@cur_status),
                              N' -- reopen it before accepting it.');

        IF @err IS NOT NULL
        BEGIN
            INSERT INTO @out (RiskRegisterId, RiskNumber, RiskTitle, Outcome, Reason,
                              FromStatus, ToStatus, AcceptedOn, NextReviewDate)
            VALUES (@id, @num, @title, N'Skipped', @err, @cur_status, NULL, NULL, NULL);
            FETCH NEXT FROM accept_cur INTO @id;
            CONTINUE;
        END

        BEGIN TRY
            -- No outer transaction. sp_risk_acceptance_save opens and
            -- commits its own, so one risk's acceptance is already
            -- atomic; wrapping the loop would make thirty acceptances
            -- one transaction, and a single ineligible risk would then
            -- roll back the twenty-nine that succeeded -- the opposite
            -- of skip-and-report.
            EXEC grac_practice.sp_risk_acceptance_save
                 @risk_register_id        = @id,
                 @next_review_date        = @next_review_date,
                 @accepted_by_employee_id = @accepted_by_employee_id,
                 @accepted_date           = @accepted_date,
                 @acceptance_note         = @acceptance_note,
                 @actor_employee_id       = @actor_employee_id,
                 @caller_display_name     = @caller_display_name,
                 @review_frequency_id     = @review_frequency_id,
                 @suppress_result         = 1;

            -- Read back what acceptance actually wrote, rather than
            -- assuming it wrote what was asked for.
            SELECT @saved_on = r.accepted_dt, @saved_status = r.status_code
              FROM grac_practice.risk_register r
             WHERE r.risk_register_id = @id;

            INSERT INTO @out (RiskRegisterId, RiskNumber, RiskTitle, Outcome, Reason,
                              FromStatus, ToStatus, AcceptedOn, NextReviewDate)
            VALUES (@id, @num, @title, N'Applied', NULL,
                    @cur_status, ISNULL(@saved_status, N'Accepted'),
                    @saved_on, @next_review_date);
        END TRY
        BEGIN CATCH
            -- Defensive: sp_risk_acceptance_save rolls its own
            -- transaction back before re-throwing, so this is normally a
            -- no-op. It exists so a future change there cannot strand an
            -- open transaction across the rest of the loop.
            IF @@TRANCOUNT > 0 ROLLBACK;

            -- 56601-56608 arrive here as text. Each already says what to
            -- fix, so it is recorded against the risk verbatim and the
            -- batch continues.
            SET @err = LEFT(ERROR_MESSAGE(), 400);

            INSERT INTO @out (RiskRegisterId, RiskNumber, RiskTitle, Outcome, Reason,
                              FromStatus, ToStatus, AcceptedOn, NextReviewDate)
            VALUES (@id, @num, @title, N'Skipped', @err, @cur_status, NULL, NULL, NULL);
        END CATCH

        FETCH NEXT FROM accept_cur INTO @id;
    END

    CLOSE accept_cur;
    DEALLOCATE accept_cur;

    -- ---- the report --------------------------------------------------
    -- Exactly one result set, by construction: the only EXEC in the loop
    -- is an INSERT ... EXEC.
    SELECT RiskRegisterId, RiskNumber, RiskTitle, Outcome, Reason,
           FromStatus, ToStatus, AcceptedOn, NextReviewDate
      FROM @out ORDER BY Seq;
END;
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '--- 298 verification ---';

SELECT '298 both composed procedures take @suppress_result' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_acceptance_save')
                            AND name = '@suppress_result')
             AND EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_register_status_set')
                            AND name = '@suppress_result')
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

-- The point of the migration. Any INSERT ... EXEC left in either bulk
-- procedure means a skipped risk still cannot report its real reason.
SELECT '298 no INSERT ... EXEC remains in the bulk procedures' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.sql_modules
                              WHERE object_id IN (OBJECT_ID('grac_practice.sp_risk_bulk_review'),
                                                  OBJECT_ID('grac_practice.sp_risk_bulk_accept'))
                                AND (definition LIKE '%INSERT INTO @accept_sink%'
                                  OR definition LIKE '%INSERT INTO @status_sink%'
                                  OR definition LIKE '%INSERT INTO @saved%'))
            THEN 'PASS -- a skipped risk can report its own reason again'
            ELSE '*** FAIL -- ROLLBACK inside INSERT-EXEC will still mask refusals' END AS Result;

SELECT '298 both bulk procedures silence the inner result set' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%@suppress_result         = 1%'
                            AND definition LIKE '%@suppress_result     = 1%')
             AND EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_accept')
                            AND definition LIKE '%@suppress_result         = 1%')
            THEN 'PASS -- one result set per bulk call'
            ELSE '*** FAIL -- an inner SELECT still reaches the caller' END AS Result;

SELECT '298 297''s date behaviour survived' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%SET next_review_date    = @next_review_date,%')
            THEN 'PASS -- a blank date still clears the schedule'
            ELSE '*** FAIL -- 297 was undone; re-run it' END AS Result;

SELECT '298 status is still composed, never written directly' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%sp_risk_acceptance_save%'
                            AND definition LIKE '%sp_risk_register_status_set%')
            THEN 'PASS -- 270 DECISION 1 intact'
            ELSE '*** FAIL' END AS Result;

SELECT '298 bulk accept still stamps no review' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_accept')
                            AND definition NOT LIKE '%last_reviewed_dt%'
                            AND definition NOT LIKE '%review_count%')
            THEN 'PASS -- accepting is still not reviewing'
            ELSE '*** FAIL' END AS Result;

PRINT '298 @suppress_result replaces INSERT ... EXEC in both bulk procedures.';
PRINT '     A risk that fails a rule now reports ITS OWN reason again.';
PRINT '     Existing callers are unaffected: the parameter defaults to 0.';
GO

SET NOEXEC OFF;
GO
