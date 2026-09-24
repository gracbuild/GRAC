-- =====================================================================
-- 298_suppress_result_on_composed_procs_rollback.sql
--
-- Restores all four procedures to their pre-298 definitions:
--   sp_risk_acceptance_save      -> 293 (no @suppress_result)
--   sp_risk_register_status_set  -> 206 (no @suppress_result)
--   sp_risk_bulk_review          -> 297 (INSERT ... EXEC sinks)
--   sp_risk_bulk_accept          -> 295 (INSERT ... EXEC sink)
--
-- ---------------------------------------------------------------------
-- THIS REINSTATES A KNOWN DEFECT. READ BEFORE RUNNING.
-- ---------------------------------------------------------------------
-- The pre-298 bulk procedures wrap their composed calls in
-- INSERT ... EXEC, and SQL Server forbids a procedure called that way
-- from issuing ROLLBACK -- which both composed procedures do in their
-- CATCH blocks.
--
-- So after this rollback, any risk that legitimately fails a rule during
-- a bulk review or bulk accept will once again report
--
--     "Cannot use the ROLLBACK statement within an INSERT-EXEC statement."
--
-- instead of its real reason (56604-56608), and leave a doomed
-- transaction behind it. The happy path -- every selected risk eligible
-- -- still works, which is exactly what made the defect easy to miss.
--
-- Roll back only if 298 caused a worse problem than that.
--
-- NO DATA CHANGE, in either direction. 298 changed four procedures and
-- wrote no row. Anything accepted or reviewed while it was in place
-- stays exactly as it is.
--
-- CALLERS: nothing outside these four procedures passes
-- @suppress_result, and the API does not, so removing the parameter
-- breaks no caller. If you have added one, update it first.
--
-- Re-runnable: yes. ASCII-only (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_risk_bulk_review','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_risk_bulk_accept','P') IS NULL
BEGIN
    PRINT 'ABORT (298 rollback): a bulk procedure is missing -- run 294/295/297 first.';
    RAISERROR('298 rollback: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- 293's sp_risk_acceptance_save, verbatim.
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
    @review_frequency_id     INT           = NULL
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

    SELECT @risk_register_id AS RiskRegisterId,
           @risk_number      AS RiskNumber,
           @accept_by        AS AcceptedByEmployeeId,
           @accept_name      AS AcceptedByName,
           @accepted_on      AS AcceptedOn,
           @next_review_date AS NextReviewDate,
           N'Accepted'       AS StatusCode;
END;
GO

-- 206's sp_risk_register_status_set, verbatim.
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_register_status_set
    @risk_register_id    BIGINT,
    @status_code         NVARCHAR(30),
    @remark              NVARCHAR(MAX) = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
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

    SELECT @risk_register_id AS RiskRegisterId, @status_code AS StatusCode;
END;
GO

-- 297's sp_risk_bulk_review, verbatim (INSERT ... EXEC sinks and all).
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

    -- NEW in 294 -- A BUG FIX, not a feature.
    --
    -- Both composed procedures END WITH A SELECT: sp_risk_acceptance_save
    -- returns seven columns, sp_risk_register_status_set two. EXEC'd bare
    -- inside this loop, each one STREAMS ITS RESULT SET TO THE CLIENT --
    -- so a batch of thirty risks sent thirty result sets ahead of the
    -- report below, and a caller that reads the first reader it gets was
    -- handed an acceptance row where it expected an Outcome column.
    --
    -- That is why bulk review worked with only a note or a date (no EXEC,
    -- so the report WAS the first result set) and failed the moment a
    -- status was chosen -- which is to say, on every bulk ACCEPT.
    --
    -- INSERT ... EXEC captures each inner result set into a sink instead.
    -- Nothing reads these tables; their only job is to stop the rows
    -- reaching the client, so this procedure returns exactly one result
    -- set, as its callers always assumed.
    --
    -- One consequence, stated because it is invisible otherwise: a
    -- procedure containing INSERT ... EXEC cannot itself be called with
    -- INSERT ... EXEC (SQL Server forbids nesting). Nothing does that
    -- today; anything that wants these rows should call the underlying
    -- procedures directly.
    DECLARE @accept_sink TABLE (
        RiskRegisterId       BIGINT,
        RiskNumber           NVARCHAR(60),
        AcceptedByEmployeeId BIGINT,
        AcceptedByName       NVARCHAR(240),
        AcceptedOn           DATETIME2,
        NextReviewDate       DATE,
        StatusCode           NVARCHAR(30)
    );
    DECLARE @status_sink TABLE (
        RiskRegisterId BIGINT,
        StatusCode     NVARCHAR(30)
    );

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
                    -- INSERT ... EXEC, not a bare EXEC: see @accept_sink.
                    INSERT INTO @accept_sink
                        (RiskRegisterId, RiskNumber, AcceptedByEmployeeId,
                         AcceptedByName, AcceptedOn, NextReviewDate, StatusCode)
                    EXEC grac_practice.sp_risk_acceptance_save
                         @risk_register_id        = @id,
                         @next_review_date        = @next_review_date,
                         @accepted_by_employee_id = @reviewed_by_employee_id,
                         @accepted_date           = NULL,   -- NULL = today
                         @acceptance_note         = @review_remarks,
                         @actor_employee_id       = @reviewed_by_employee_id,
                         @caller_display_name     = @caller_display_name,
                         @review_frequency_id     = @review_frequency_id;
                ELSE
                    INSERT INTO @status_sink (RiskRegisterId, StatusCode)
                    EXEC grac_practice.sp_risk_register_status_set
                         @risk_register_id    = @id,
                         @status_code         = @status_code,
                         @remark              = @review_remarks,
                         @actor_employee_id   = @reviewed_by_employee_id,
                         @caller_display_name = @caller_display_name;

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

-- 295's sp_risk_bulk_accept, verbatim (INSERT ... EXEC sink and all).
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

    -- Captures sp_risk_acceptance_save's result set. Read, unlike 294's
    -- sinks: the accepter's resolved name and the stamped AcceptedOn come
    -- back from the procedure that decided them, so the report states
    -- what was written rather than what was requested.
    DECLARE @saved TABLE (
        RiskRegisterId       BIGINT,
        RiskNumber           NVARCHAR(60),
        AcceptedByEmployeeId BIGINT,
        AcceptedByName       NVARCHAR(240),
        AcceptedOn           DATETIME2,
        NextReviewDate       DATE,
        StatusCode           NVARCHAR(30)
    );

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
        DELETE FROM @saved;

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
            INSERT INTO @saved
                (RiskRegisterId, RiskNumber, AcceptedByEmployeeId,
                 AcceptedByName, AcceptedOn, NextReviewDate, StatusCode)
            EXEC grac_practice.sp_risk_acceptance_save
                 @risk_register_id        = @id,
                 @next_review_date        = @next_review_date,
                 @accepted_by_employee_id = @accepted_by_employee_id,
                 @accepted_date           = @accepted_date,
                 @acceptance_note         = @acceptance_note,
                 @actor_employee_id       = @actor_employee_id,
                 @caller_display_name     = @caller_display_name,
                 @review_frequency_id     = @review_frequency_id;

            SELECT TOP (1) @saved_on = s.AcceptedOn, @saved_status = s.StatusCode
              FROM @saved s;

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

SELECT '298 rollback: @suppress_result is gone' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.parameters
                              WHERE object_id = OBJECT_ID('grac_practice.sp_risk_acceptance_save')
                                AND name = '@suppress_result')
            THEN 'PASS -- restored to 293'
            ELSE '*** FAIL' END AS Result;

SELECT '298 rollback: the INSERT-EXEC defect is back' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%INSERT INTO @accept_sink%')
            THEN 'EXPECTED -- a skipped risk will mis-report its reason again'
            ELSE '*** CHECK -- bulk review is not at 297' END AS Result;

SELECT '298 rollback: 297''s date behaviour survived' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%SET next_review_date    = @next_review_date,%')
            THEN 'PASS -- a blank date still clears the schedule'
            ELSE '*** FAIL -- re-run 297' END AS Result;
GO

PRINT '298 rollback: four procedures restored. No rows were changed.';
PRINT '     The INSERT-EXEC / ROLLBACK defect is reinstated -- see this file''s header.';
GO

SET NOEXEC OFF;
GO
