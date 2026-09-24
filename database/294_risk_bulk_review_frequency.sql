-- =====================================================================
-- 294_risk_bulk_review_frequency.sql
--
-- PURPOSE
--   Bulk review already accepts risks -- 270 routes status 'Accepted'
--   through sp_risk_acceptance_save, so every rule applies. What it
--   could not do, until now, is say WHY the new review date is that
--   date. 293 gave a single acceptance a cadence; this gives the bulk
--   one the same, so accepting thirty risks does not produce thirty
--   dates with nothing behind them.
--
-- ---------------------------------------------------------------------
-- THIS IS NOT A SECOND BULK-ACCEPT PATH
-- ---------------------------------------------------------------------
-- No new procedure, no new entry point. sp_risk_bulk_review is
-- re-issued from 270 with ONE parameter added and four marked edits in
-- its body. A separate "bulk accept" would have been a second caller of
-- sp_risk_acceptance_save free to drift from this one -- two places for
-- the same rules to live, which is the failure 270's DECISION 1 exists
-- to prevent.
--
-- ---------------------------------------------------------------------
-- WHERE THE CADENCE IS WRITTEN, AND BY WHOM
-- ---------------------------------------------------------------------
-- Exactly the shape 270 already uses for next_review_date, because the
-- two answer the same question and must not disagree:
--
--   status = 'Accepted' -> passed to sp_risk_acceptance_save, which
--                          writes it. Not written again here.
--   otherwise           -> COALESCE(@review_frequency_id, existing) in
--                          the review stamp, so NULL means "leave
--                          alone" and a bulk review that only moves
--                          dates still records what it moved them by.
--
-- review_frequency_id carries no rules of its own -- it is a record of
-- a derivation, not a gate -- so writing it on the non-accept path
-- bypasses nothing. next_review_date remains the authority for when a
-- risk comes back; 56601 / 56602 / 56722 are untouched.
--
-- ---------------------------------------------------------------------
-- VALIDATED ONCE, NOT PER RISK (270's DECISION 3)
-- ---------------------------------------------------------------------
-- An unknown or inactive frequency id fails identically for every risk
-- in the selection. Left to the FK, it would surface as fifty copies of
-- a constraint-violation message, each reported as a per-risk "Skipped"
-- reason -- which would be a lie: nothing is wrong with those risks.
-- So it THROWS before the loop, as 56722 does for the date.
--
-- 56726, in 270's own range (56720-56739). The code belongs to the
-- procedure that raises it, not to the migration that added the line.
--
-- ---------------------------------------------------------------------
-- ONE DELIBERATE TEXT CHANGE
-- ---------------------------------------------------------------------
-- 270's 56723 and 56724 messages contain a section sign, and 270 is the
-- only non-ASCII file in this sequence. Under sqlcmd's default codepage
-- that character does not survive intact, so the messages are re-issued
-- here with the word "section" spelled out. The error NUMBERS, the
-- conditions and the meaning are identical; only the two message
-- strings differ, and they differ from mojibake toward English.
--
-- ---------------------------------------------------------------------
-- ALSO FIXES: THE INNER RESULT SETS 270 LEAKED
-- ---------------------------------------------------------------------
-- Found while building the Accept tab. Both composed procedures end with
-- a SELECT, and 270 EXEC'd them bare inside the loop -- so every risk
-- that changed status pushed a result set to the client BEFORE the
-- report, and a caller reading the first reader it was handed got an
-- acceptance row where it expected an Outcome column.
--
-- Bulk review therefore worked with only a note or a date, and failed
-- as soon as a status was chosen -- which is every bulk ACCEPT. Both
-- EXECs are now INSERT ... EXEC into a discard table, so the procedure
-- returns exactly one result set, as its callers always assumed.
--
-- IF 294 HAS ALREADY BEEN APPLIED, RUN IT AGAIN -- the file is
-- CREATE OR ALTER and re-running is safe. The earlier version of 294
-- carried the leak.
--
-- Re-runnable: yes (CREATE OR ALTER, no schema change).
-- Rollback: database/294_risk_bulk_review_frequency_rollback.sql
-- DEPENDS ON: 270 (sp_risk_bulk_review, the history field columns),
--             293 (sp_risk_acceptance_save's @review_frequency_id,
--                  risk_register.review_frequency_id, frequency_master).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF OBJECT_ID('grac_practice.sp_risk_bulk_review','P') IS NULL
BEGIN PRINT 'ABORT (294): sp_risk_bulk_review missing -- run 270 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.frequency_master','U') IS NULL
BEGIN PRINT 'ABORT (294): frequency_master missing -- run 001 first.'; SET @ok = 0; END

IF COL_LENGTH('grac_practice.risk_register','review_frequency_id') IS NULL
BEGIN PRINT 'ABORT (294): risk_register.review_frequency_id missing -- run 293 first.'; SET @ok = 0; END

-- 293 is what makes the EXEC below legal. Without its parameter the
-- procedure would install cleanly and then fail at run time on every
-- bulk acceptance with "too many arguments specified" -- so it is
-- checked here rather than discovered by a user.
IF NOT EXISTS (SELECT 1 FROM sys.parameters
                WHERE object_id = OBJECT_ID('grac_practice.sp_risk_acceptance_save')
                  AND name = '@review_frequency_id')
BEGIN PRINT 'ABORT (294): sp_risk_acceptance_save has no @review_frequency_id -- run 293 first.'; SET @ok = 0; END

IF COL_LENGTH('grac_practice.risk_register_history','field_code') IS NULL
BEGIN PRINT 'ABORT (294): risk_register_history.field_code missing -- run 270 first.'; SET @ok = 0; END

IF @ok = 0
BEGIN
    RAISERROR('294_risk_bulk_review_frequency: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_risk_bulk_review -- re-issued from 270
--
-- Extracted from 270 and changed in the places marked "NEW in 294".
-- Every other guard, THROW, cursor mechanic, history insert and result
-- column is reproduced unchanged, including the skip-and-report
-- behaviour and the per-risk TRY/CATCH that makes it work.
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

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '--- 294 verification ---';

SELECT '294 sp_risk_bulk_review takes a review frequency' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND name = '@review_frequency_id')
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

-- Ordered LIKE, not an exact-spacing match: the cadence must appear
-- AFTER the EXEC of sp_risk_acceptance_save in the body. Matching the
-- argument line character for character would turn any future
-- re-indent of that EXEC into a failing check for no reason.
SELECT '294 the cadence reaches acceptance, not a direct write' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%sp_risk_acceptance_save%@review_frequency_id%')
            THEN 'PASS -- sp_risk_acceptance_save receives it'
            ELSE '*** FAIL -- acceptance is not being given the cadence' END AS Result;

SELECT '294 it still composes rather than writing status itself' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%sp_risk_acceptance_save%'
                            AND definition LIKE '%sp_risk_register_status_set%')
            THEN 'PASS -- both status owners are still called'
            ELSE '*** FAIL -- 270 DECISION 1 has been lost' END AS Result;

SELECT '294 closing is still refused in bulk' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%56724%')
            THEN 'PASS -- Closed/Retired still need a per-risk reason'
            ELSE '*** FAIL' END AS Result;

SELECT '294 an unknown cadence is refused once, up front' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%56726%')
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

-- The leak fix. A bare EXEC of either composed procedure would stream
-- its result set to the client; both must be INSERT ... EXEC.
SELECT '294 inner result sets are captured, not streamed' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%INSERT INTO @accept_sink%'
                            AND definition LIKE '%INSERT INTO @status_sink%')
            THEN 'PASS -- one result set reaches the caller'
            ELSE '*** FAIL -- the loop leaks a result set per risk; bulk accept will break' END AS Result;

SELECT '294 the single-risk review is untouched' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_review_perform')
                            AND definition LIKE '%sp_risk_register_assess%')
            THEN 'PASS -- re-assessment still goes through the analysis procedure'
            ELSE '*** CHECK -- sp_risk_review_perform changed' END AS Result;

PRINT '294 Bulk review carries a review frequency.';
PRINT '     Accepted -> passed to sp_risk_acceptance_save, which owns the column.';
PRINT '     Otherwise -> COALESCEd into the review stamp, NULL meaning leave alone.';
PRINT '     An unknown or inactive cadence is refused once (56726), not per risk.';
PRINT '     Result shape is unchanged from 270.';
GO

SET NOEXEC OFF;
GO
