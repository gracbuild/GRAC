-- =====================================================================
-- 297_bulk_review_returns_to_acceptance_rollback.sql
--
-- Restores sp_risk_bulk_review to 294's behaviour: next_review_date goes
-- back to COALESCE(@new, existing), so a blank date LEAVES the existing
-- schedule alone instead of clearing it.
--
-- WHAT COMES BACK WITH IT
--   Bulk review stops returning risks for acceptance. Reviewing thirty
--   risks in bulk once again does something different from reviewing the
--   same thirty one at a time -- the single review clears the date and
--   sends them to Acceptance (296), the bulk one keeps their schedule and
--   sends them nowhere.
--
--   The three consequential fixes go with it: a cleared date is again
--   reported as "Unchanged", writes no history row, and the report's
--   ToReviewDate again shows the old date as though it had survived.
--   (None of those can fire once the date is never cleared, so they are
--   restored together rather than left half-applied.)
--
-- NO DATA CHANGE. 297 changed a procedure, not a row. Risks whose
-- schedules were cleared while it was in place STAY cleared -- and stay
-- on the Accept tab, which is where 296 puts them. This file does not
-- and should not try to re-invent the dates it did not record.
--
-- LEAVE 296 ALONE. It is independent and still correct: a ready risk
-- with no review date belongs on the Accept tab however the date came to
-- be NULL. Rolling 296 back as well would strand exactly those risks.
--
-- Re-runnable: yes. ASCII-only (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_risk_bulk_review','P') IS NULL
BEGIN
    PRINT '297 rollback: sp_risk_bulk_review does not exist -- nothing to restore. Run 270 then 294.';
    SET NOEXEC ON;
END
GO

-- 294's procedure, verbatim.
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
               SET next_review_date    = COALESCE(@next_review_date, next_review_date),
                   review_frequency_id = COALESCE(@review_frequency_id, review_frequency_id),
                   last_reviewed_dt    = SYSUTCDATETIME(),
                   review_count        = ISNULL(review_count, 0) + 1,
                   updated_by          = @caller_display_name,
                   updated_dt          = SYSUTCDATETIME()
             WHERE risk_register_id = @id;

            IF @next_review_date IS NOT NULL
               AND (@cur_review IS NULL OR @cur_review <> @next_review_date)
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
            IF @next_review_date IS NOT NULL
               AND (@cur_review IS NULL OR @cur_review <> @next_review_date)
                INSERT INTO grac_practice.risk_register_history
                    (risk_register_id, action_code, from_status_code, to_status_code,
                     field_code, from_value, to_value,
                     remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
                VALUES
                    (@id, N'FieldChange', NULL, NULL,
                     N'next_review_date',
                     CONVERT(NVARCHAR(10), @cur_review, 23),
                     CONVERT(NVARCHAR(10), @next_review_date, 23),
                     N'Next review date changed during bulk review.',
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
                    @cur_review, COALESCE(@next_review_date, @cur_review));
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

SELECT '297 rollback: the date is COALESCEd again' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%COALESCE(@next_review_date, next_review_date)%')
            THEN 'PASS -- 294 behaviour restored'
            ELSE '*** FAIL' END AS Result;

SELECT '297 rollback: 294 fixes are still in place' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%INSERT INTO @accept_sink%'
                            AND definition LIKE '%@review_frequency_id%')
            THEN 'PASS -- the result-set fix and the cadence survived the rollback'
            ELSE '*** FAIL -- 294 was undone as well; re-run it' END AS Result;

SELECT '297 rollback: risks cleared while 297 was live' AS Check_,
       CONCAT((SELECT COUNT(*)
                 FROM grac_practice.risk_register r
                WHERE r.next_review_date IS NULL
                  AND r.last_reviewed_dt IS NOT NULL
                  AND r.status_code NOT IN (N'Closed', N'Retired')),
              ' risk(s) still have no schedule -- they remain on the Accept tab (296)') AS Result;
GO

PRINT '297 rollback: sp_risk_bulk_review restored to 294. No rows were changed.';
PRINT '     296 is deliberately left in place -- roll it back separately only if you mean to.';
GO

SET NOEXEC OFF;
GO
