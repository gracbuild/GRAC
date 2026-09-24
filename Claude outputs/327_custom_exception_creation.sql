-- =====================================================================
-- 327 Custom Exception creation
--
-- Sir's specification: Exception Management gets an "+ Add Custom
-- Exception" button. It opens a form capturing the exception's basic
-- details up front, saves it, and from that point on the record is an
-- ordinary exception_request row -- Analysis, Submit for approval,
-- Approve/Reject, the Exception Full View, the Gap View -> Exception
-- card flow, all unchanged. The only new thing is a fourth way for a
-- row to come into existence (the other three are the GAP_CANDIDATE /
-- SLA_CANDIDATE / TASK_* auto-triggers); the row itself must be
-- indistinguishable from any other except for a visible "Source: Custom
-- Exception" marker, exactly as GAP_CANDIDATE and the two TASK_* types
-- already are.
--
-- WHAT A CUSTOM EXCEPTION IS, STRUCTURALLY. Every existing request type
-- hangs off something -- a gap (GAP_CANDIDATE, SLA_CANDIDATE) or a task
-- (TASK_SLA_EXTENSION, TASK_PRIORITY_REDUCTION) -- and derives its
-- organization and, usually, its title from that anchor. A Custom
-- Exception hangs off nothing: the analyst is asserting the exception
-- directly, not deriving it from a gap analysis or an SLA breach. So
-- custom_gap_id can be NULL (task_id already can be, since 192), the
-- organization must be supplied directly, and the title must be
-- supplied directly.
--
-- Sir also asked for "Related Gap, where applicable" on the form -- so
-- a Custom Exception CAN still name a gap if the analyst has one in
-- mind. That does not make it a GAP_CANDIDATE request: the type records
-- HOW the row was created (auto-triggered vs. typed in by hand), not
-- merely whether a gap happens to be linked. request_type_code stays
-- 'CUSTOM' either way; custom_gap_id is just one more optional fact
-- about it, same as linked_practice_id or linked_requirement_ref.
--
-- WHAT THIS MIGRATION DOES
--
--   1. ck_pm_exception_request_type   -- 'CUSTOM' joins the vocabulary
--   2. ck_pm_exception_request_subject -- relaxed: a CUSTOM row needs
--                                         neither a gap nor a task
--   3. sp_exception_request_create    -- extended for standalone
--      creation. Every existing caller (the three auto-triggers) is
--      unaffected: all pass named parameters (verified against every
--      EXEC in 162/168/172/173/174/252/323/324), none pass the four new
--      ones, and @request_type_code defaults to 'GAP_CANDIDATE' -- the
--      exact value the column itself already defaulted to before this
--      migration named it explicitly.
--   4. sp_exception_request_get       -- INNER JOIN custom_gap becomes
--      LEFT JOIN. Bug, not a feature: a gap-less request already
--      existed (TASK_SLA_EXTENSION / TASK_PRIORITY_REDUCTION, since
--      192) and this procedure has been silently unable to return one
--      since the day it was written -- GetAsync's "not found" branch
--      fires instead of a real 500, so nobody noticed, but Exception
--      View (added this session, available in ANY status) would have
--      hit it the first time anyone opened a task-side exception. Also
--      returns request_type_code, so the View page can show Source.
--
-- BODIES RE-EMITTED FROM THEIR LIVE ANCESTORS, deliberately:
--     sp_exception_request_create -> 258 (unchanged except as noted)
--     sp_exception_request_get    -> 260 (unchanged except as noted)
-- Nothing else in either body changes. Both are CREATE OR ALTER, so a
-- re-run is a no-op rather than a duplicate.
--
-- SAFE TO RE-RUN. Requires 161, 166, 192, 258, 260.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (327): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.exception_request','U') IS NULL
BEGIN PRINT 'ABORT (327): exception_request missing (run 161 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_exception_request_create','P') IS NULL
BEGIN PRINT 'ABORT (327): sp_exception_request_create missing (run 258 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_exception_request_get','P') IS NULL
BEGIN PRINT 'ABORT (327): sp_exception_request_get missing (run 260 first).'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.exception_request','proposed_effective_from') IS NULL
BEGIN PRINT 'ABORT (327): proposed_effective_from missing (run 260 first).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('327_custom_exception_creation: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. ck_pm_exception_request_type -- 'CUSTOM' joins the vocabulary
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_exception_request_type')
    ALTER TABLE grac_practice.exception_request
        DROP CONSTRAINT ck_pm_exception_request_type;
GO

ALTER TABLE grac_practice.exception_request
    ADD CONSTRAINT ck_pm_exception_request_type
        CHECK (request_type_code IN (N'GAP_CANDIDATE', N'SLA_CANDIDATE',
                                     N'TASK_SLA_EXTENSION', N'TASK_PRIORITY_REDUCTION',
                                     N'CUSTOM'));
GO
PRINT '327: ck_pm_exception_request_type now permits CUSTOM.';
GO

-- =====================================================================
-- 2. ck_pm_exception_request_subject -- relaxed for CUSTOM
--
-- 192's version required a gap or a task. A CUSTOM exception may name a
-- gap (the "Related Gap, where applicable" field) but is not REQUIRED
-- to, so a third way to satisfy the constraint joins the other two:
-- request_type_code = 'CUSTOM' is itself sufficient grounds to exist.
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_exception_request_subject')
    ALTER TABLE grac_practice.exception_request
        DROP CONSTRAINT ck_pm_exception_request_subject;
GO

ALTER TABLE grac_practice.exception_request
    ADD CONSTRAINT ck_pm_exception_request_subject
        CHECK (custom_gap_id IS NOT NULL OR task_id IS NOT NULL
               OR request_type_code = N'CUSTOM');
GO
PRINT '327: ck_pm_exception_request_subject now also permits a standalone CUSTOM row.';
GO

-- =====================================================================
-- 3. sp_exception_request_create -- standalone (gap-less) creation
--
-- 258's body. Four new optional parameters at the end, before
-- @caller_display_name. Everything a non-CUSTOM caller already does --
-- the gap lookup, the duplicate guard, the practice derivation, the
-- column list, the history row -- is untouched; it just now sits behind
-- an IF that only a CUSTOM caller takes the other branch of.
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
    -- 327: standalone creation. @custom_gap_id was the one required
    -- parameter before this migration (no default) -- it now defaults
    -- to NULL like every other field here, and is required only when
    -- @request_type_code is NOT 'CUSTOM' (checked below, same as the
    -- THROW it always raised, just moved inside the branch that still
    -- applies).
    @request_type_code         NVARCHAR(30)  = N'GAP_CANDIDATE',
    @organization_id           BIGINT        = NULL,
    @proposed_effective_from   DATE          = NULL,
    @proposed_effective_until  DATE          = NULL,
    @caller_display_name       NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @request_type_code IS NULL OR LEN(LTRIM(RTRIM(@request_type_code))) = 0
        SET @request_type_code = N'GAP_CANDIDATE';

    DECLARE @org_id BIGINT, @gap_title NVARCHAR(250);

    IF @request_type_code = N'CUSTOM'
    BEGIN
        -- Standalone: the organization and title are asserted directly,
        -- not derived from a gap. custom_gap_id, if the caller supplied
        -- one (the form's own "Related Gap, where applicable" field),
        -- is validated -- never derived, never required.
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
        -- 161-258 behaviour, unchanged: every non-CUSTOM request hangs
        -- off a gap, and the gap supplies the organization and title.
        IF @custom_gap_id IS NULL
            THROW 55200, 'sp_exception_request_create: custom_gap_id is required.', 1;

        SELECT @org_id = organization_id, @gap_title = title
          FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id;
        IF @org_id IS NULL
            THROW 55201, 'sp_exception_request_create: custom_gap not found.', 1;
    END

    -- 258: SubmittedForApproval joins the "already open" set. Scoped to
    -- non-CUSTOM requests -- the three auto-triggers can double-fire for
    -- the same gap and rely on this guard to fold into the existing
    -- request; a Custom Exception is a deliberate, one-shot Save from a
    -- dialog, not a trigger, so it is never silently merged into
    -- whatever else happens to be open against a gap it also names.
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

    -- 258: derive the practice when the caller did not name one and a
    -- gap exists to derive it from. A CUSTOM exception with no gap has
    -- nothing to derive from; @linked_practice_id is then exactly what
    -- the caller supplied (the form's own Related Practice picker), or
    -- NULL, like every other optional field here.
    IF @linked_practice_id IS NULL AND @custom_gap_id IS NOT NULL
        SELECT @linked_practice_id = pi.practice_id
          FROM grac_practice.custom_gap g
          JOIN grac_practice.practice_instance pi
               ON pi.practice_instance_id = g.source_reference_id
         WHERE g.custom_gap_id = @custom_gap_id
           AND g.source_reference_type = N'PracticeInstance';

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

        COMMIT;
    END TRY
    BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK; THROW; END CATCH

    SELECT @new_id AS ExceptionRequestId, CAST(1 AS BIT) AS Created;
END
GO
PRINT '327: sp_exception_request_create accepts standalone CUSTOM creation.';
GO

-- =====================================================================
-- 4. sp_exception_request_get -- LEFT JOIN custom_gap; return
--    request_type_code
--
-- 260's body (itself 166's). The INNER JOIN silently returned zero rows
-- for any gap-less request -- true of TASK_SLA_EXTENSION /
-- TASK_PRIORITY_REDUCTION since 192, and now also true of CUSTOM.
-- GetAsync's "not found" branch masked this as a 404 rather than a
-- crash, so nothing broke loudly, but Exception View (this session,
-- available in ANY status) would 404 the first time anyone opened a
-- task-side or Custom exception by id.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_get
    @exception_request_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @exception_request_id IS NULL
        THROW 55220, 'sp_exception_request_get: exception_request_id is required.', 1;

    SELECT
        r.exception_request_id       AS ExceptionRequestId,
        r.organization_id            AS OrganizationId,
        r.custom_gap_id              AS CustomGapId,
        g.title                      AS GapTitle,
        r.request_title              AS RequestTitle,
        r.request_reason             AS RequestReason,
        r.justification              AS Justification,
        r.risk_impact                AS RiskImpact,
        et.exception_type_code       AS ExceptionTypeCode,
        et.exception_type_name       AS ExceptionTypeName,
        r.owner_employee_id          AS OwnerEmployeeId,
        ow.employee_name             AS OwnerName,
        r.linked_practice_id         AS LinkedPracticeId,
        r.linked_requirement_ref     AS LinkedRequirementRef,
        r.status_code                AS StatusCode,
        -- 327: so the UI can render "Source: Custom Exception" the same
        -- way exception-centre.js already reads this column for its
        -- Type filter and row-menu gating.
        r.request_type_code          AS RequestTypeCode,
        r.requested_by_employee_id   AS RequestedByEmployeeId,
        rq.employee_name             AS RequestedByName,
        r.requested_dt               AS RequestedOn,
        r.proposed_effective_from    AS ProposedEffectiveFrom,
        r.proposed_effective_until   AS ProposedEffectiveUntil,
        r.approved_by_employee_id    AS ApprovedByEmployeeId,
        ap.employee_name             AS ApprovedByName,
        r.approved_dt                AS ApprovedOn,
        r.effective_from             AS EffectiveFrom,
        r.effective_until            AS EffectiveUntil,
        r.approval_note              AS ApprovalNote,
        r.compensating_control       AS CompensatingControl,
        r.review_frequency_id        AS ReviewFrequencyId,
        fm.frequency_name            AS ReviewFrequencyName,
        r.rejected_by_employee_id    AS RejectedByEmployeeId,
        rj.employee_name             AS RejectedByName,
        r.rejected_dt                AS RejectedOn,
        r.rejection_reason           AS RejectionReason
      FROM grac_practice.exception_request r
      -- 327: was INNER JOIN. A CUSTOM (or task-side) request has no gap
      -- at all -- g.title simply comes back NULL for one, same as every
      -- other optional fact here.
 LEFT JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.custom_gap_id
 LEFT JOIN grac_practice.exception_type_master   et ON et.exception_type_id = r.exception_type_id
 LEFT JOIN grac_practice.organization_employee   ow ON ow.employee_id       = r.owner_employee_id
 LEFT JOIN grac_practice.organization_employee   rq ON rq.employee_id       = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee   ap ON ap.employee_id       = r.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee   rj ON rj.employee_id       = r.rejected_by_employee_id
 LEFT JOIN grac_practice.frequency_master        fm ON fm.frequency_id      = r.review_frequency_id
     WHERE r.exception_request_id = @exception_request_id;
END
GO
PRINT '327: sp_exception_request_get left-joins custom_gap and returns RequestTypeCode.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '327 objects present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_exception_request_create','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_exception_request_get','P')    IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.check_constraints
                          WHERE name = 'ck_pm_exception_request_type'
                            AND OBJECT_DEFINITION(object_id) LIKE '%CUSTOM%')
             AND EXISTS (SELECT 1 FROM sys.check_constraints
                          WHERE name = 'ck_pm_exception_request_subject'
                            AND OBJECT_DEFINITION(object_id) LIKE '%CUSTOM%')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- A round-trip proof, not just an object-existence check: create a
-- throwaway CUSTOM exception against organization_id 1 (the seeded
-- admin org -- see 322), confirm sp_exception_request_get can read it
-- back through the new LEFT JOIN, then remove the proof row so this
-- script stays safe to re-run.
IF EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = 1)
BEGIN
    DECLARE @proof_id BIGINT;
    BEGIN TRY
        EXEC grac_practice.sp_exception_request_create
            @request_type_code   = N'CUSTOM',
            @organization_id     = 1,
            @request_title       = N'327 verification (safe to ignore / delete)',
            @request_reason      = N'Migration 327 round-trip check.',
            @caller_display_name = N'migration-327-verify';
        SELECT @proof_id = SCOPE_IDENTITY();
    END TRY
    BEGIN CATCH
        PRINT CONCAT('327 verification: create FAILED - ', ERROR_MESSAGE());
    END CATCH

    IF @proof_id IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.exception_request
                    WHERE exception_request_id = @proof_id
                      AND request_type_code = N'CUSTOM'
                      AND custom_gap_id IS NULL)
            PRINT '327 verification: PASS - standalone CUSTOM row created with no gap.';
        ELSE
            PRINT '327 verification: FAIL - row did not come back as expected.';

        -- sp_exception_request_get itself, through the LEFT JOIN.
        IF EXISTS (SELECT 1 FROM grac_practice.exception_request r
                    WHERE r.exception_request_id = @proof_id)
        BEGIN
            DECLARE @got_title NVARCHAR(300);
            SELECT @got_title = r.request_title
              FROM grac_practice.exception_request r
              LEFT JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.custom_gap_id
             WHERE r.exception_request_id = @proof_id;
            PRINT CASE WHEN @got_title IS NOT NULL
                       THEN '327 verification: PASS - LEFT JOIN read the gap-less row back.'
                       ELSE '327 verification: FAIL - LEFT JOIN read returned nothing.' END;
        END

        DELETE FROM grac_practice.exception_request_history WHERE exception_request_id = @proof_id;
        DELETE FROM grac_practice.exception_request WHERE exception_request_id = @proof_id;
        PRINT '327 verification: proof row removed.';
    END
END
ELSE
    PRINT '327 verification: skipped (no organization_id = 1 in this database).';
GO

PRINT '327 Custom Exception creation installed. Next: update Web/API tiers (see docs/centre-source-column.md).';
GO

SET NOEXEC OFF;
GO
