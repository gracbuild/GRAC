-- =====================================================================
-- 297_bulk_review_returns_to_acceptance.sql
--
-- PURPOSE
--   A bulk review now sends its risks back for acceptance on its own.
--
--   Before this, bulk review and single review disagreed about the same
--   word. Both stamp "reviewed", but:
--
--       single review   next_review_date = @next_review_date  (NULL clears)
--       bulk review     next_review_date = COALESCE(@new, existing)
--
--   so a single review with the date left blank returned the risk for a
--   fresh acceptance (296), and a bulk review of the same risks quietly
--   kept their old schedule and returned nothing. Reviewing thirty risks
--   therefore did something different from reviewing them one at a time,
--   which is not a thing "review" can be allowed to mean.
--
--   297 makes bulk review assign the date rather than COALESCE it. A
--   blank date clears the schedule, 296 reads "ready, no review date" as
--   AcceptanceDue, and the risks appear on the Accept tab.
--
-- ---------------------------------------------------------------------
-- WHERE THE DATE IS SET INSTEAD
-- ---------------------------------------------------------------------
-- At acceptance, which is 264's original design and the reason
-- sp_risk_acceptance_save is the one procedure that REQUIRES a date:
--
--     "The next review date is set again when the risk is next ACCEPTED
--      ... Leaving the old date in place would keep the risk on the due
--      list forever; inventing a new one here would be guessing at a
--      decision acceptance exists to make."
--
-- A reviewer who genuinely means "reviewed, no change, see me in a year"
-- still types that date into the bulk form and gets exactly that. Only a
-- BLANK date now means "back to acceptance" -- and blank is what the form
-- offers by default.
--
-- ---------------------------------------------------------------------
-- THE ACCEPTED PATH IS UNAFFECTED
-- ---------------------------------------------------------------------
-- Bulk review with @status_code = 'Accepted' routes through
-- sp_risk_acceptance_save, which refuses a NULL date with 56601. Such a
-- call always carries a date, so assignment and COALESCE are identical
-- there. Nothing about bulk acceptance changes.
--
-- ---------------------------------------------------------------------
-- THE CADENCE IS DELIBERATELY *NOT* CLEARED
-- ---------------------------------------------------------------------
-- review_frequency_id keeps its COALESCE. The cadence is a property of
-- the last acceptance, not of the schedule, and keeping it means the
-- Accept modal opens preselected with the frequency this risk was last
-- reviewed on -- which is almost always the one it will be given again.
-- Clearing it would make every returning risk look like it had never had
-- a cadence.
--
-- ---------------------------------------------------------------------
-- THREE CONSEQUENCES THAT HAD TO BE FIXED WITH IT
-- ---------------------------------------------------------------------
-- Each is marked "CHANGED IN 297" in the body below.
--
--   1. @applied treated a cleared date as no change, so a bulk review
--      that only cleared schedules reported "Unchanged -- nothing was
--      different" for every risk. The test is now NULL-safe on both
--      sides.
--   2. The next_review_date audit row was guarded by "new value IS NOT
--      NULL", so clearing a schedule wrote NO history at all. Same
--      NULL-safe test, and the remark says "cleared ... returned for
--      acceptance" when that is what happened.
--   3. The report's ToReviewDate was COALESCE(@new, @old), which would
--      have reported the old date as though it had survived. It now
--      states what was written, NULL included.
--
-- Re-runnable: yes (CREATE OR ALTER, no schema change).
-- Rollback: database/297_bulk_review_returns_to_acceptance_rollback.sql
-- DEPENDS ON: 294 (the procedure this re-issues), 296 (the stage rule
--             that turns a cleared date into AcceptanceDue -- without it
--             this migration strands risks instead of routing them).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF OBJECT_ID('grac_practice.sp_risk_bulk_review','P') IS NULL
BEGIN PRINT 'ABORT (297): sp_risk_bulk_review missing -- run 270 and 294 first.'; SET @ok = 0; END

IF NOT EXISTS (SELECT 1 FROM sys.parameters
                WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                  AND name = '@review_frequency_id')
BEGIN PRINT 'ABORT (297): sp_risk_bulk_review has no @review_frequency_id -- run 294 first.'; SET @ok = 0; END

-- Without 296 this migration makes things WORSE, not better: clearing
-- the date would move risks off the review list without putting them on
-- the acceptance list, which is the stranding 296 exists to prevent.
IF NOT EXISTS (SELECT 1 FROM sys.sql_modules
                WHERE object_id = OBJECT_ID('grac_practice.vw_pm_risk_workflow_stage')
                  AND definition LIKE '%next_review_date IS NULL%')
BEGIN
    PRINT 'ABORT (297): migration 296 is not applied. Without it a cleared review date';
    PRINT '    strands the risk on no work list at all instead of sending it to acceptance.';
    SET @ok = 0;
END

IF @ok = 0
BEGIN
    RAISERROR('297_bulk_review_returns_to_acceptance: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_risk_bulk_review -- re-issued from 294
--
-- Extracted from 294 and changed only where marked "CHANGED IN 297".
-- Every guard, THROW, cursor mechanic, INSERT ... EXEC sink, history
-- insert and result column is reproduced unchanged.
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
-- Verification
-- =====================================================================
PRINT '--- 297 verification ---';

SELECT '297 a blank date now clears the schedule' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%SET next_review_date    = @next_review_date,%')
            THEN 'PASS -- assignment, not COALESCE'
            ELSE '*** FAIL -- bulk review still keeps the old date' END AS Result;

SELECT '297 the cadence is still carried forward' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%review_frequency_id = COALESCE(@review_frequency_id%')
            THEN 'PASS -- the Accept modal can still preselect it'
            ELSE '*** FAIL -- the cadence is being cleared with the date' END AS Result;

SELECT '297 acceptance is still composed, not written directly' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%sp_risk_acceptance_save%'
                            AND definition LIKE '%sp_risk_register_status_set%')
            THEN 'PASS -- 270 DECISION 1 intact'
            ELSE '*** FAIL' END AS Result;

SELECT '297 inner result sets are still captured' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%INSERT INTO @accept_sink%'
                            AND definition LIKE '%INSERT INTO @status_sink%')
            THEN 'PASS -- 294 fix intact'
            ELSE '*** FAIL -- the result-set leak is back' END AS Result;

PRINT '297 Bulk review returns risks to acceptance.';
PRINT '     Blank next review date -> cleared -> AcceptanceDue (via 296).';
PRINT '     A date typed into the form still means "see me again then".';
PRINT '     Status = Accepted is unchanged: acceptance requires a date anyway.';
GO

SET NOEXEC OFF;
GO
