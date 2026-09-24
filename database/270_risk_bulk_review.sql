-- =====================================================================
-- 270 Risk Centre — bulk review
--
-- Reviewing thirty risks after a quarterly cycle meant opening thirty
-- modals. This adds one operation over a selected set.
--
-- ---------------------------------------------------------------------
-- WHAT THIS IS *NOT*: IT IS NOT sp_risk_review_perform IN A LOOP
-- ---------------------------------------------------------------------
-- The single-risk Review is a RE-ASSESSMENT. sp_risk_review_perform
-- takes @risk_category_code, @likelihood_code and @impact_code as
-- REQUIRED parameters and delegates to sp_risk_register_assess -- the
-- same procedure the Analysis screen calls -- producing a new rating and
-- a new analysis version.
--
-- A bulk form carrying three fields cannot do that, and should not
-- pretend to: likelihood and impact are per-risk judgements, and
-- applying one pair of scores to thirty risks would be fabricating an
-- assessment nobody made.
--
-- So this is a REVIEW DISPOSITION, not a re-assessment:
--
--     "these risks were looked at, here is the note, here is where they
--      stand, here is when to look again"
--
-- It stamps last_reviewed_dt, increments review_count, moves
-- next_review_date, optionally sets status, and records the note. A risk
-- needing a genuine re-score still goes through the single-risk Review,
-- which is left completely untouched.
--
-- ---------------------------------------------------------------------
-- DECISION 1 — COMPOSE THE STATUS PROCEDURES, ENFORCE EVERY RULE
-- ---------------------------------------------------------------------
-- Setting status in bulk is where a bulk tool usually goes wrong: it
-- writes status_code directly and quietly produces states the rest of
-- the product believes are impossible -- an Accepted risk with no
-- treatment option, or with no completed analysis.
--
-- This does not. Status goes through the procedure that owns it:
--
--     'Accepted'   -> sp_risk_acceptance_save   (56604/05/06/07/08)
--     anything else-> sp_risk_register_status_set (56172/73/74)
--
-- Accepting therefore still requires a completed analysis, a chosen
-- treatment option, a risk that is not Closed/Retired, and an accepter
-- belonging to the same organisation -- exactly as it does for one risk
-- through the UI. Bulk changes the number of risks, not the rules.
--
-- ---------------------------------------------------------------------
-- DECISION 2 — SKIP AND REPORT, DO NOT FAIL THE BATCH
-- ---------------------------------------------------------------------
-- A risk that fails a precondition is skipped with its own reason and
-- the rest proceed. One ineligible risk in fifty must not block the
-- other forty-nine, and a silent partial success is worse than either --
-- so every risk comes back in the result set with an outcome:
--
--     Applied | Skipped | Unchanged
--
-- The per-risk EXECs run inside their own TRY/CATCH. That is deliberate:
-- a THROW from sp_risk_acceptance_save is INFORMATION here (this risk
-- has no treatment option), not a fault, and must not abort the loop.
--
-- ---------------------------------------------------------------------
-- DECISION 3 — THE DATE RULE IS CHECKED ONCE, UP FRONT
-- ---------------------------------------------------------------------
-- A next review date in the past fails for EVERY risk, identically
-- (sp_risk_acceptance_save 56602, sp_risk_review_perform 56616). Running
-- the loop to produce fifty copies of one message would be theatre, so
-- it THROWS before the loop starts. Per-risk conditions skip per risk;
-- input validation refuses outright.
--
-- ---------------------------------------------------------------------
-- DECISION 4 — WHY risk_register_history GAINS THREE COLUMNS
-- ---------------------------------------------------------------------
-- The requirement is that the audit capture next_review_date as
-- OLD -> NEW. risk_register_history has from_status_code / to_status_code
-- and nothing else: it can express a status change and no other kind.
--
-- The alternative was to write "Next review 2026-06-01 -> 2026-12-01"
-- into `remark` and let anyone auditing it parse English. This adds the
-- three columns task_activity has carried since 192 --
-- field_code / from_value / to_value -- so a field change is a QUERYABLE
-- row rather than a sentence. It is the shape this codebase already uses
-- for exactly this problem, not a new idea.
--
-- All three are NULLable and nothing existing writes them, so every row
-- written before this migration stays valid and unchanged.
--
-- CONTENTS
--   1. risk_register_history + field_code / from_value / to_value
--   2. sp_risk_bulk_review
--
-- ERROR CODE RANGE: 56720-56739
-- Rollback: database/270_risk_bulk_review_rollback.sql
-- Depends:  205/206 (register + status set), 261 (next_review_date),
--           264 (sp_risk_acceptance_save)
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN PRINT 'ABORT (270): risk_register missing -- run 205 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.risk_register_history','U') IS NULL
BEGIN PRINT 'ABORT (270): risk_register_history missing -- run 205 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.sp_risk_register_status_set','P') IS NULL
BEGIN PRINT 'ABORT (270): sp_risk_register_status_set missing -- run 206 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.sp_risk_acceptance_save','P') IS NULL
BEGIN PRINT 'ABORT (270): sp_risk_acceptance_save missing -- run 264 first.'; SET @ok = 0; END

IF COL_LENGTH('grac_practice.risk_register','next_review_date') IS NULL
BEGIN PRINT 'ABORT (270): next_review_date missing -- run 261 first.'; SET @ok = 0; END

IF @ok = 0
BEGIN
    RAISERROR('270_risk_bulk_review: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Field-level history
--
-- Same three columns task_activity has carried since 192. Guarded, so
-- re-running changes nothing.
-- =====================================================================
IF COL_LENGTH('grac_practice.risk_register_history','field_code') IS NULL
    ALTER TABLE grac_practice.risk_register_history ADD field_code NVARCHAR(40) NULL;
GO
IF COL_LENGTH('grac_practice.risk_register_history','from_value') IS NULL
    ALTER TABLE grac_practice.risk_register_history ADD from_value NVARCHAR(400) NULL;
GO
IF COL_LENGTH('grac_practice.risk_register_history','to_value') IS NULL
    ALTER TABLE grac_practice.risk_register_history ADD to_value NVARCHAR(400) NULL;
GO

-- =====================================================================
-- 2. sp_risk_bulk_review
--
-- @risk_register_ids is a comma-separated list. STRING_SPLIT rather than
-- a table type: the caller is a web form posting a selection, a TVP
-- would need a type registered on every connection path, and the list is
-- tens of ids, not thousands.
--
-- Every parameter except the ids is optional and NULL means "leave
-- alone", so the same procedure serves "just move the review dates" and
-- "review, note and accept" without a second entry point.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_bulk_review
    @risk_register_ids       NVARCHAR(MAX),
    @review_remarks          NVARCHAR(MAX) = NULL,
    @status_code             NVARCHAR(30)  = NULL,
    @next_review_date        DATE          = NULL,
    @reviewed_by_employee_id BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_ids IS NULL OR LEN(LTRIM(RTRIM(@risk_register_ids))) = 0
        THROW 56720, 'sp_risk_bulk_review: at least one risk must be selected.', 1;

    -- Nothing to do is a mistake worth naming: a form that posts three
    -- empty fields has not reviewed anything.
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
        THROW 56723, 'sp_risk_bulk_review: unknown status_code (BRD §17).', 1;

    -- Closing or retiring needs a reason per risk (56174), and a bulk
    -- form has one shared note. Rather than let fifty risks be closed on
    -- one line of text, bulk simply does not offer it.
    IF @status_code IN (N'Closed', N'Retired')
        THROW 56724, 'sp_risk_bulk_review: closing or retiring is not a bulk action -- each needs its own reason (BRD §20). Close risks individually.', 1;

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

    DECLARE @id BIGINT, @num NVARCHAR(60), @title NVARCHAR(300),
            @cur_status NVARCHAR(30), @cur_review DATE, @org BIGINT,
            @err NVARCHAR(400), @applied BIT;

    DECLARE risk_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT s.risk_register_id FROM @sel s ORDER BY s.risk_register_id;

    OPEN risk_cur;
    FETCH NEXT FROM risk_cur INTO @id;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @err = NULL; SET @applied = 0;

        SELECT @org        = r.organization_id,
               @cur_status = r.status_code,
               @cur_review = r.next_review_date,
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
                    -- Carries the §21 acceptance rules AND sets
                    -- next_review_date itself, which is why the date is
                    -- passed here rather than written twice.
                    EXEC grac_practice.sp_risk_acceptance_save
                         @risk_register_id        = @id,
                         @next_review_date        = @next_review_date,
                         @accepted_by_employee_id = @reviewed_by_employee_id,
                         @accepted_date           = NULL,   -- NULL = today
                         @acceptance_note         = @review_remarks,
                         @actor_employee_id       = @reviewed_by_employee_id,
                         @caller_display_name     = @caller_display_name;
                ELSE
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
            UPDATE grac_practice.risk_register
               SET next_review_date = COALESCE(@next_review_date, next_review_date),
                   last_reviewed_dt = SYSUTCDATETIME(),
                   review_count     = ISNULL(review_count, 0) + 1,
                   updated_by       = @caller_display_name,
                   updated_dt       = SYSUTCDATETIME()
             WHERE risk_register_id = @id;

            IF @next_review_date IS NOT NULL
               AND (@cur_review IS NULL OR @cur_review <> @next_review_date)
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
    SELECT RiskRegisterId, RiskNumber, RiskTitle, Outcome, Reason,
           FromStatus, ToStatus, FromReviewDate, ToReviewDate
      FROM @out ORDER BY Seq;
END;
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '--- 270 verification ---';

SELECT '270 history carries field-level diffs' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.risk_register_history','field_code') IS NOT NULL
             AND COL_LENGTH('grac_practice.risk_register_history','from_value') IS NOT NULL
             AND COL_LENGTH('grac_practice.risk_register_history','to_value')   IS NOT NULL
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

SELECT '270 sp_risk_bulk_review exists' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_bulk_review','P') IS NOT NULL
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

SELECT '270 it composes rather than writing status itself' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%sp_risk_acceptance_save%'
                            AND definition LIKE '%sp_risk_register_status_set%')
            THEN 'PASS -- both status owners are called'
            ELSE '*** FAIL -- status is being written directly, bypassing §21' END AS Result;

SELECT '270 the single-risk review is untouched' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_review_perform')
                            AND definition LIKE '%sp_risk_register_assess%')
            THEN 'PASS -- re-assessment still goes through the analysis procedure'
            ELSE '*** CHECK -- sp_risk_review_perform changed' END AS Result;

SELECT '270 closing is refused in bulk' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%56724%')
            THEN 'PASS -- Closed/Retired need a per-risk reason (§20)'
            ELSE '*** FAIL' END AS Result;

PRINT '270 Risk bulk review installed.';
PRINT '     Three fields: remarks, status, next review date -- applied across a selection.';
PRINT '     Status is routed through sp_risk_acceptance_save / sp_risk_register_status_set,';
PRINT '     so bulk changes the number of risks, not the rules.';
PRINT '     Ineligible risks are skipped and reported, never silently missed.';
GO

SET NOEXEC OFF;
GO
