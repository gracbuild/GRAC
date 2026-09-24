-- =====================================================================
-- 295_risk_bulk_accept.sql
--
-- PURPOSE
--   The Accept Risk tab: everything waiting to be accepted, in one list,
--   accepted one at a time or many at once.
--
--   Single acceptance already had a home (sp_risk_acceptance_save, 264,
--   extended by 293). This adds the many-at-once form and nothing else.
--
-- ---------------------------------------------------------------------
-- WHY NOT sp_risk_bulk_review WITH @status_code = 'Accepted'
-- ---------------------------------------------------------------------
-- Because that procedure stamps a REVIEW: it sets last_reviewed_dt,
-- increments review_count, and writes a 'BulkReview' history row. Doing
-- that to a risk being accepted for the FIRST time records a review that
-- never happened -- review_count = 1 on a risk nobody has reviewed, and
-- a last_reviewed_dt that the Review Risk queue and every ageing report
-- will believe.
--
-- Accepting is not reviewing. Re-accepting a risk at its review date is
-- reviewing, and that path (bulk review with status Accepted) stays
-- exactly as it is. The two operations differ precisely in the review
-- stamp, so they are two procedures that share the one thing that must
-- not diverge:
--
--     BOTH call sp_risk_acceptance_save.
--
-- Every acceptance rule -- analysis complete (56605), treatment option
-- chosen (56606), not Closed/Retired (56604), accepter in the same
-- organisation (56608), a future review date (56601/56602) -- is
-- enforced there and is not restated here. This procedure decides WHICH
-- risks to call it for and what to report; it decides nothing about
-- whether a risk may be accepted.
--
-- ---------------------------------------------------------------------
-- SKIP AND REPORT (270's DECISION 2, deliberately copied)
-- ---------------------------------------------------------------------
-- A risk failing a precondition is skipped with its reason and the rest
-- proceed. The per-risk EXEC runs in its own TRY/CATCH: a THROW from
-- sp_risk_acceptance_save is INFORMATION here ("this risk has no
-- treatment option"), not a fault, and must not abort the batch.
--
-- Input validation still refuses outright, before the loop: a missing
-- or past review date, or an unknown cadence, fails identically for
-- every risk, and fifty copies of one message would be theatre.
--
-- ---------------------------------------------------------------------
-- INSERT ... EXEC, NOT A BARE EXEC
-- ---------------------------------------------------------------------
-- sp_risk_acceptance_save ends with a SELECT. EXEC'd bare in a loop it
-- would stream one result set per risk to the client ahead of the
-- report -- the exact defect 294 fixes in sp_risk_bulk_review. Captured
-- instead, which both silences it and yields the real AcceptedOn and
-- StatusCode for the report rather than this procedure guessing them.
--
-- Consequence: a procedure containing INSERT ... EXEC cannot itself be
-- called with INSERT ... EXEC. Nothing does.
--
-- ---------------------------------------------------------------------
-- NO AUDIT ROW OF ITS OWN
-- ---------------------------------------------------------------------
-- sp_risk_acceptance_save already writes a 'RiskAccepted' history row
-- per risk, naming the accepter, the date and the next review. A bulk
-- acceptance of thirty risks is thirty acceptances, and thirty identical
-- audit rows is the correct record of that. The shared @acceptance_note
-- lands on each one, which is where "accepted at the Q3 risk committee"
-- belongs.
--
-- ERROR CODE RANGE: 56750-56769 (56720-56749 are 270 and 271).
-- Rollback: database/295_risk_bulk_accept_rollback.sql
-- DEPENDS ON: 264 (sp_risk_acceptance_save, vw_pm_risk_workflow_stage),
--             293 (@review_frequency_id on that procedure).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF OBJECT_ID('grac_practice.sp_risk_acceptance_save','P') IS NULL
BEGIN PRINT 'ABORT (295): sp_risk_acceptance_save missing -- run 264 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN PRINT 'ABORT (295): risk_register missing -- run 205 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.frequency_master','U') IS NULL
BEGIN PRINT 'ABORT (295): frequency_master missing -- run 001 first.'; SET @ok = 0; END

-- Same check 294 makes, and for the same reason: without 293's parameter
-- the EXEC below installs cleanly and fails at run time on every call
-- with "too many arguments specified".
IF NOT EXISTS (SELECT 1 FROM sys.parameters
                WHERE object_id = OBJECT_ID('grac_practice.sp_risk_acceptance_save')
                  AND name = '@review_frequency_id')
BEGIN PRINT 'ABORT (295): sp_risk_acceptance_save has no @review_frequency_id -- run 293 first.'; SET @ok = 0; END

IF @ok = 0
BEGIN
    RAISERROR('295_risk_bulk_accept: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_risk_bulk_accept
--
-- @risk_register_ids is comma separated, matching sp_risk_bulk_review's
-- shape: the caller is a web form posting a selection, a table type
-- would need registering on every connection path, and the list is tens
-- of ids rather than thousands.
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

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '--- 295 verification ---';

SELECT '295 sp_risk_bulk_accept exists' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_bulk_accept','P') IS NOT NULL
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

SELECT '295 it composes acceptance rather than writing status' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_accept')
                            AND definition LIKE '%sp_risk_acceptance_save%')
            THEN 'PASS -- every acceptance rule still applies'
            ELSE '*** FAIL -- status is being written directly' END AS Result;

SELECT '295 it does NOT stamp a review' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_accept')
                            AND definition NOT LIKE '%last_reviewed_dt%'
                            AND definition NOT LIKE '%review_count%')
            THEN 'PASS -- accepting is not reviewing'
            ELSE '*** FAIL -- a review is being recorded that did not happen' END AS Result;

SELECT '295 the inner result set is captured, not streamed' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_accept')
                            AND definition LIKE '%INSERT INTO @saved%')
            THEN 'PASS -- one result set reaches the caller'
            ELSE '*** FAIL -- the loop leaks a result set per risk' END AS Result;

SELECT '295 bulk review is untouched' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_bulk_review')
                            AND definition LIKE '%56724%')
            THEN 'PASS -- the review path still refuses bulk close'
            ELSE '*** CHECK -- sp_risk_bulk_review changed' END AS Result;

PRINT '295 Bulk accept installed.';
PRINT '     Composes sp_risk_acceptance_save, so bulk changes the number of risks, not the rules.';
PRINT '     No review stamp: accepting is not reviewing (that is bulk review with status Accepted).';
PRINT '     Ineligible risks are skipped and reported, never silently missed.';
GO

SET NOEXEC OFF;
GO
