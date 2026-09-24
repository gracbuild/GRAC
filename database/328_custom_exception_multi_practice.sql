-- =====================================================================
-- 328 Custom Exception -- multiple Related Practices
--
-- Sir's follow-up: "Related Control / Practice" on the Add Custom
-- Exception dialog should use the SAME reusable cascading Practice
-- Picker Risk Centre already has (Framework -> Source Structure ->
-- Control -> Practice, migration 282's window.__practicePicker), and it
-- should accept MULTIPLE practices, not one.
--
-- WHAT THIS REUSES AS-IS, UNCHANGED: the picker itself
-- (wwwroot/js/practice-picker.js) and its read-only API
-- (sp_practice_picker_* from 282) are generic and already GET-only --
-- "a caller that needs to SAVE a chosen practice keeps using its own
-- screen's endpoint" is the component's own contract (see its header
-- comment). This migration is that save side for Exception Centre.
--
-- WHAT IS DELIBERATELY NOT REUSED: risk_practice_map (261) and its
-- save procedure also propagate an asset-dependency cascade
-- (risk_asset_map / risk_asset_map_source) -- that machinery exists
-- because a Risk's whole point is "what does this touch." An Exception
-- has no such concept; "Related Practice" here is traceability only,
-- the same as linked_practice_id already was on exception_request
-- (161). Copying the asset cascade in would be duplicating a feature
-- that does not apply, not reusing one that does. The new table below
-- mirrors risk_practice_map's SHAPE (org/entity/practice, frozen
-- name+code, audit columns) and nothing else.
--
-- SCOPE, PER SIR'S CONFIRMATION: the Add Custom Exception dialog only.
-- linked_practice_id (singular) is untouched and still read by
-- Analysis / Approve / View / the grid exactly as before -- it is now
-- auto-set to the FIRST practice in the list when the caller does not
-- supply it explicitly, so those existing screens still show something
-- rather than nothing. Nothing about Analysis, Approve, View or the
-- grid is modified by this migration; the full list lives only in the
-- new table, read back by the new list procedure below (not yet wired
-- into any screen -- available if the multi-practice display is asked
-- for later without a further migration).
--
-- WHAT THIS MIGRATION DOES
--   1. exception_request_practice   NEW table -- one row per
--      (exception_request_id, practice_id).
--   2. sp_exception_request_create  re-issued from 327's body, plus one
--      new optional trailing parameter, @practice_ids_json. Every
--      existing caller (327 verified all 8 EXEC sites use named
--      params) is unaffected; the new parameter defaults to NULL.
--   3. sp_exception_request_practice_list  NEW, read-only.
--
-- SAFE TO RE-RUN. Requires 327.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (328): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.exception_request','U') IS NULL
BEGIN PRINT 'ABORT (328): exception_request missing (run 161 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice','U') IS NULL
BEGIN PRINT 'ABORT (328): practice table missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_exception_request_create','P') IS NULL
BEGIN PRINT 'ABORT (328): sp_exception_request_create missing (run 327 first).'; SET @ok = 0; END
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_exception_request_type'
                  AND OBJECT_DEFINITION(object_id) LIKE '%CUSTOM%')
BEGIN PRINT 'ABORT (328): CUSTOM not yet in ck_pm_exception_request_type (run 327 first).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('328_custom_exception_multi_practice: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. exception_request_practice
--
-- Which practices this exception relates to. Unlike risk_practice_map
-- there is no Primary/Additional distinction -- exception_request
-- already has its own single "primary" concept (linked_practice_id,
-- since 161) and this table is purely the ADDITIONAL fact "which
-- practices, plural, does this exception relate to." A row here does
-- not imply anything about linked_practice_id and vice versa; the
-- service layer (not this table) keeps them in sync at create time.
-- =====================================================================
IF OBJECT_ID('grac_practice.exception_request_practice','U') IS NULL
CREATE TABLE grac_practice.exception_request_practice(
    exception_request_practice_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_exception_request_practice PRIMARY KEY,
    organization_id       BIGINT NOT NULL
        CONSTRAINT fk_pm_exception_request_practice_org
            REFERENCES grac_practice.organization(organization_id),
    exception_request_id  BIGINT NOT NULL
        CONSTRAINT fk_pm_exception_request_practice_request
            REFERENCES grac_practice.exception_request(exception_request_id),
    practice_id            BIGINT NOT NULL
        CONSTRAINT fk_pm_exception_request_practice_practice
            REFERENCES grac_practice.practice(practice_id),

    -- Frozen at link time, same reasoning as risk_practice_map (261):
    -- a later practice rename must not rewrite what this exception was
    -- actually related to when the analyst picked it.
    practice_name          NVARCHAR(300) NULL,
    practice_code          NVARCHAR(100) NULL,

    linked_dt              DATETIME2 NOT NULL
        CONSTRAINT df_pm_exception_request_practice_dt DEFAULT SYSUTCDATETIME(),
    linked_by_employee_id  BIGINT NULL
        CONSTRAINT fk_pm_exception_request_practice_linker
            REFERENCES grac_practice.organization_employee(employee_id),

    record_status_id       INT NOT NULL
        CONSTRAINT fk_pm_exception_request_practice_record_status
            REFERENCES grac_practice.record_status_master(record_status_id),
    entered_by  NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_exception_request_practice_entered_by DEFAULT N'system',
    entered_dt  DATETIME2 NOT NULL
        CONSTRAINT df_pm_exception_request_practice_entered_dt DEFAULT SYSUTCDATETIME(),

    CONSTRAINT uq_pm_exception_request_practice UNIQUE(exception_request_id, practice_id)
);
GO

-- The reverse lookup ("which exceptions touch this practice"), same
-- shape as risk_practice_map's own ix_pm_risk_practice_map_practice.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_exception_request_practice_practice'
                  AND object_id = OBJECT_ID('grac_practice.exception_request_practice'))
    CREATE INDEX ix_pm_exception_request_practice_practice
        ON grac_practice.exception_request_practice(organization_id, practice_id)
        INCLUDE (exception_request_id);
GO
PRINT '328: exception_request_practice created.';
GO

-- =====================================================================
-- 2. sp_exception_request_create -- accepts @practice_ids_json
--
-- 327's body verbatim, plus:
--   a) one new trailing optional parameter, @practice_ids_json
--      NVARCHAR(MAX) -- a JSON array of practice ids, e.g. "[12,45,9]".
--   b) when @linked_practice_id was not supplied AND not derived from
--      a gap (327's existing derivation, untouched), it is set to the
--      FIRST id in @practice_ids_json -- so linked_practice_id keeps
--      meaning "a practice this exception relates to" for every screen
--      that already reads only that one column.
--   c) after the request row exists, one row per id in
--      @practice_ids_json is inserted into exception_request_practice,
--      inside the SAME transaction as the create -- so a Custom
--      Exception and its related-practice list are created atomically,
--      never one without the other.
--
-- A practice id that does not belong to @org_id is silently dropped
-- (the JOIN below simply does not match it), not thrown -- the same
-- choice sp_risk_practice_map makes loudly (THROW 56527) because a
-- risk's practice list is one explicit action at a time; here the list
-- arrives as a whole batch from a picker that was already org-scoped
-- when it built the list, so a mismatch can only come from a tampered
-- request, and dropping it quietly is enough.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_create
    @custom_gap_id             BIGINT        = NULL,
    @request_title             NVARCHAR(300) = NULL,
    @request_reason            NVARCHAR(MAX) = NULL,
    @requested_by_employee_id  BIGINT        = NULL,
    @exception_type_code       NVARCHAR(60)  = NULL,
    @justification             NVARCHAR(MAX) = NULL,
    @risk_impact               NVARCHAR(MAX) = NULL,
    @owner_employee_id         BIGINT        = NULL,
    @linked_practice_id        BIGINT        = NULL,
    @linked_requirement_ref    NVARCHAR(200) = NULL,
    @request_type_code         NVARCHAR(30)  = N'GAP_CANDIDATE',
    @organization_id           BIGINT        = NULL,
    @proposed_effective_from   DATE          = NULL,
    @proposed_effective_until  DATE          = NULL,
    -- 328. NULL or empty means "no related practices" -- exactly what
    -- every caller before this migration effectively sent.
    @practice_ids_json         NVARCHAR(MAX) = NULL,
    @caller_display_name       NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @request_type_code IS NULL OR LEN(LTRIM(RTRIM(@request_type_code))) = 0
        SET @request_type_code = N'GAP_CANDIDATE';

    DECLARE @org_id BIGINT, @gap_title NVARCHAR(250);

    IF @request_type_code = N'CUSTOM'
    BEGIN
        IF @organization_id IS NULL
            THROW 55205, 'sp_exception_request_create: organization_id is required for a CUSTOM exception.', 1;
        IF @request_title IS NULL OR LEN(LTRIM(RTRIM(@request_title))) = 0
            THROW 55206, 'sp_exception_request_create: request_title is required for a CUSTOM exception.', 1;
        SET @org_id = @organization_id;

        IF @custom_gap_id IS NOT NULL
        BEGIN
            SELECT @gap_title = title FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id;
            IF @gap_title IS NULL
                THROW 55207, 'sp_exception_request_create: custom_gap_id does not exist.', 1;
        END
    END
    ELSE
    BEGIN
        IF @custom_gap_id IS NULL
            THROW 55200, 'sp_exception_request_create: custom_gap_id is required.', 1;

        SELECT @org_id = organization_id, @gap_title = title
          FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id;
        IF @org_id IS NULL
            THROW 55201, 'sp_exception_request_create: custom_gap not found.', 1;
    END

    IF @custom_gap_id IS NOT NULL AND @request_type_code <> N'CUSTOM'
    BEGIN
        DECLARE @existing_id BIGINT =
            (SELECT TOP 1 exception_request_id
               FROM grac_practice.exception_request
              WHERE custom_gap_id = @custom_gap_id
                AND status_code IN (N'Pending', N'SubmittedForApproval', N'Approved')
              ORDER BY exception_request_id DESC);
        IF @existing_id IS NOT NULL
        BEGIN
            SELECT @existing_id AS ExceptionRequestId, CAST(0 AS BIT) AS Created;
            RETURN;
        END
    END

    DECLARE @type_id INT = NULL;
    IF @exception_type_code IS NOT NULL AND LEN(LTRIM(RTRIM(@exception_type_code))) > 0
    BEGIN
        SELECT @type_id = exception_type_id FROM grac_practice.exception_type_master
         WHERE exception_type_code = @exception_type_code;
        IF @type_id IS NULL
            THROW 55202, 'sp_exception_request_create: unknown exception_type_code.', 1;
    END

    IF @linked_practice_id IS NULL AND @custom_gap_id IS NOT NULL
        SELECT @linked_practice_id = pi.practice_id
          FROM grac_practice.custom_gap g
          JOIN grac_practice.practice_instance pi
               ON pi.practice_instance_id = g.source_reference_id
         WHERE g.custom_gap_id = @custom_gap_id
           AND g.source_reference_type = N'PracticeInstance';

    -- 328. Neither an explicit @linked_practice_id nor a gap to derive
    -- one from -- if the caller supplied a related-practice list, its
    -- first entry becomes the "primary" one every other screen already
    -- knows how to show. JSON array order is preserved via [key] (the
    -- zero-based index OPENJSON assigns), cast to INT so "10" does not
    -- sort before "2" as text would.
    IF @linked_practice_id IS NULL AND @practice_ids_json IS NOT NULL
       AND LEN(LTRIM(RTRIM(@practice_ids_json))) > 0
        SELECT TOP 1 @linked_practice_id = TRY_CAST(j.value AS BIGINT)
          FROM OPENJSON(@practice_ids_json) j
         WHERE TRY_CAST(j.value AS BIGINT) IS NOT NULL
         ORDER BY TRY_CAST(j.[key] AS INT);

    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
    DECLARE @title NVARCHAR(300) =
        COALESCE(@request_title,
                 CASE WHEN @gap_title IS NOT NULL THEN N'Exception: ' + @gap_title
                      ELSE N'Custom Exception Request' END);
    DECLARE @new_id BIGINT;

    BEGIN TRY
        BEGIN TRAN;

        INSERT INTO grac_practice.exception_request
            (organization_id, custom_gap_id,
             request_title, request_reason,
             exception_type_id, justification, risk_impact,
             owner_employee_id,
             linked_practice_id, linked_requirement_ref,
             request_type_code,
             proposed_effective_from, proposed_effective_until,
             status_code,
             requested_by_employee_id, requested_dt,
             record_status_id, entered_by, entered_dt)
        VALUES
            (@org_id, @custom_gap_id,
             @title, @request_reason,
             @type_id, @justification, @risk_impact,
             @owner_employee_id,
             @linked_practice_id, @linked_requirement_ref,
             @request_type_code,
             @proposed_effective_from, @proposed_effective_until,
             N'Pending',
             @requested_by_employee_id, SYSUTCDATETIME(),
             @active_rs, @caller_display_name, SYSUTCDATETIME());

        SET @new_id = SCOPE_IDENTITY();

        INSERT INTO grac_practice.exception_request_history
            (exception_request_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@new_id, N'Create', NULL, N'Pending',
             @request_reason, @requested_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        -- 328. One row per related practice. SELECT DISTINCT: the JSON
        -- can name the same id twice (a double-click on Add, say)
        -- without risking a duplicate-key error that would roll back
        -- the whole create -- practice_name/code are functionally
        -- dependent on practice_id, so DISTINCT across all five columns
        -- already dedupes on the id alone.
        IF @practice_ids_json IS NOT NULL AND LEN(LTRIM(RTRIM(@practice_ids_json))) > 0
            INSERT INTO grac_practice.exception_request_practice
                (organization_id, exception_request_id, practice_id,
                 practice_name, practice_code,
                 linked_dt, linked_by_employee_id,
                 record_status_id, entered_by, entered_dt)
            SELECT DISTINCT
                   @org_id, @new_id, p.practice_id,
                   p.practice_name, p.practice_code,
                   SYSUTCDATETIME(), @requested_by_employee_id,
                   @active_rs, @caller_display_name, SYSUTCDATETIME()
              FROM OPENJSON(@practice_ids_json) j
              JOIN grac_practice.practice p
                   ON p.practice_id = TRY_CAST(j.value AS BIGINT)
                  AND p.organization_id = @org_id;

        COMMIT;
    END TRY
    BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK; THROW; END CATCH

    SELECT @new_id AS ExceptionRequestId, CAST(1 AS BIT) AS Created;
END
GO
PRINT '328: sp_exception_request_create accepts @practice_ids_json.';
GO

-- =====================================================================
-- 3. sp_exception_request_practice_list -- read-only
--
-- Not wired into any screen by this migration (see header) -- exists so
-- the data this migration writes has a matching, correct way to read
-- it back, and so a future "show every related practice" ask does not
-- need another migration, just a UI + Web/API change.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_practice_list
    @exception_request_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @exception_request_id IS NULL
        THROW 55230, 'sp_exception_request_practice_list: exception_request_id is required.', 1;

    SELECT
        x.exception_request_practice_id AS ExceptionRequestPracticeId,
        x.practice_id                   AS PracticeId,
        x.practice_name                 AS PracticeName,
        x.practice_code                 AS PracticeCode,
        x.linked_dt                     AS LinkedOn
      FROM grac_practice.exception_request_practice x
     WHERE x.exception_request_id = @exception_request_id
     ORDER BY x.exception_request_practice_id;
END
GO
PRINT '328: sp_exception_request_practice_list installed.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '328 objects present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.exception_request_practice','U')       IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_exception_request_practice_list','P') IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_exception_request_create')
                            AND name = '@practice_ids_json')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- Round-trip proof: create a throwaway CUSTOM exception against
-- organization_id 1 with a real 2-practice list (if that org actually
-- has 2+ practices to test with), confirm both landed in the new
-- table, confirm linked_practice_id auto-took the first one, confirm
-- sp_exception_request_practice_list reads them back, then remove
-- everything so this script stays safe to re-run.
IF EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = 1)
BEGIN
    DECLARE @p1 BIGINT, @p2 BIGINT;
    SELECT TOP 1 @p1 = practice_id FROM grac_practice.practice
     WHERE organization_id = 1 ORDER BY practice_id;
    SELECT TOP 1 @p2 = practice_id FROM grac_practice.practice
     WHERE organization_id = 1 AND practice_id <> ISNULL(@p1, 0) ORDER BY practice_id;

    IF @p1 IS NOT NULL AND @p2 IS NOT NULL
    BEGIN
        DECLARE @proof_id BIGINT, @json NVARCHAR(200) =
            N'[' + CAST(@p1 AS NVARCHAR(20)) + N',' + CAST(@p2 AS NVARCHAR(20)) + N']';
        BEGIN TRY
            EXEC grac_practice.sp_exception_request_create
                @request_type_code   = N'CUSTOM',
                @organization_id     = 1,
                @request_title       = N'328 verification (safe to ignore / delete)',
                @request_reason      = N'Migration 328 round-trip check.',
                @practice_ids_json   = @json,
                @caller_display_name = N'migration-328-verify';
            SELECT @proof_id = SCOPE_IDENTITY();
        END TRY
        BEGIN CATCH
            PRINT CONCAT('328 verification: create FAILED - ', ERROR_MESSAGE());
        END CATCH

        IF @proof_id IS NOT NULL
        BEGIN
            DECLARE @linked_count INT =
                (SELECT COUNT(*) FROM grac_practice.exception_request_practice
                  WHERE exception_request_id = @proof_id);
            PRINT CASE WHEN @linked_count = 2
                       THEN '328 verification: PASS - both practices linked.'
                       ELSE CONCAT('328 verification: FAIL - expected 2 linked rows, found ', @linked_count, '.') END;

            DECLARE @got_primary BIGINT =
                (SELECT linked_practice_id FROM grac_practice.exception_request
                  WHERE exception_request_id = @proof_id);
            PRINT CASE WHEN @got_primary = @p1
                       THEN '328 verification: PASS - linked_practice_id auto-set to the first list entry.'
                       ELSE '328 verification: FAIL - linked_practice_id did not take the first entry.' END;

            -- sp_exception_request_practice_list itself, not just the
            -- table directly -- proves the proc runs and returns the
            -- same rows, the way the rest of this file's verification
            -- blocks exercise the actual read path rather than only the
            -- data.
            CREATE TABLE #proof_list (
                ExceptionRequestPracticeId BIGINT, PracticeId BIGINT,
                PracticeName NVARCHAR(300), PracticeCode NVARCHAR(100), LinkedOn DATETIME2);
            INSERT INTO #proof_list
            EXEC grac_practice.sp_exception_request_practice_list @exception_request_id = @proof_id;
            DECLARE @list_rows INT = (SELECT COUNT(*) FROM #proof_list);
            PRINT CASE WHEN @list_rows = 2
                       THEN '328 verification: PASS - sp_exception_request_practice_list read both rows back.'
                       ELSE CONCAT('328 verification: FAIL - list proc returned ', @list_rows, ' row(s).') END;
            DROP TABLE #proof_list;
        END
        ELSE
            PRINT '328 verification: skipped read-back (create did not return an id).';

        IF @proof_id IS NOT NULL
        BEGIN
            DELETE FROM grac_practice.exception_request_practice WHERE exception_request_id = @proof_id;
            DELETE FROM grac_practice.exception_request_history  WHERE exception_request_id = @proof_id;
            DELETE FROM grac_practice.exception_request           WHERE exception_request_id = @proof_id;
            PRINT '328 verification: proof rows removed.';
        END
    END
    ELSE
        PRINT '328 verification: skipped (organization_id 1 does not have 2 practices to test with).';
END
ELSE
    PRINT '328 verification: skipped (no organization_id = 1 in this database).';
GO

PRINT '328 Custom Exception multi-practice installed. Next: update Web/API tiers and the Add Custom Exception dialog.';
GO

SET NOEXEC OFF;
GO
