-- =====================================================================
-- 327 Custom Exception creation -- ROLLBACK
--
-- Restores sp_exception_request_create and sp_exception_request_get to
-- their exact pre-327 bodies (258's and 260's respectively, byte-for-
-- byte), and restores both CHECK constraints to their pre-327 (192)
-- definitions. Does NOT delete any CUSTOM exception_request rows that
-- were created while this migration was live -- that is data, not
-- schema, and this script only undoes the schema/procedure change.
-- A CUSTOM row left behind after rollback will fail
-- ck_pm_exception_request_type's restored CHECK on its next UPDATE
-- (not on SELECT), which is the correct signal that 327 needs to be
-- re-applied before that row can be touched again.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (327 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. ck_pm_exception_request_type -- back to 192's four-value list
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_exception_request_type')
    ALTER TABLE grac_practice.exception_request
        DROP CONSTRAINT ck_pm_exception_request_type;
GO

ALTER TABLE grac_practice.exception_request
    ADD CONSTRAINT ck_pm_exception_request_type
        CHECK (request_type_code IN (N'GAP_CANDIDATE', N'SLA_CANDIDATE',
                                     N'TASK_SLA_EXTENSION', N'TASK_PRIORITY_REDUCTION'));
GO
PRINT '327 rollback: ck_pm_exception_request_type restored to 192 (CUSTOM removed).';
GO

-- =====================================================================
-- 2. ck_pm_exception_request_subject -- back to 192's gap-or-task rule
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_exception_request_subject')
    ALTER TABLE grac_practice.exception_request
        DROP CONSTRAINT ck_pm_exception_request_subject;
GO

ALTER TABLE grac_practice.exception_request
    ADD CONSTRAINT ck_pm_exception_request_subject
        CHECK (custom_gap_id IS NOT NULL OR task_id IS NOT NULL);
GO
PRINT '327 rollback: ck_pm_exception_request_subject restored to 192 (CUSTOM carve-out removed).';
GO

-- =====================================================================
-- 3. sp_exception_request_create -- restored to 258's exact body
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_create
    @custom_gap_id            BIGINT,
    @request_title            NVARCHAR(300) = NULL,
    @request_reason           NVARCHAR(MAX) = NULL,
    @requested_by_employee_id BIGINT        = NULL,
    @exception_type_code      NVARCHAR(60)  = NULL,
    @justification            NVARCHAR(MAX) = NULL,
    @risk_impact              NVARCHAR(MAX) = NULL,
    @owner_employee_id        BIGINT        = NULL,
    @linked_practice_id       BIGINT        = NULL,
    @linked_requirement_ref   NVARCHAR(200) = NULL,
    @caller_display_name      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @custom_gap_id IS NULL
        THROW 55200, 'sp_exception_request_create: custom_gap_id is required.', 1;

    DECLARE @org_id BIGINT, @gap_title NVARCHAR(250);
    SELECT @org_id = organization_id, @gap_title = title
      FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id;
    IF @org_id IS NULL
        THROW 55201, 'sp_exception_request_create: custom_gap not found.', 1;

    -- 258: SubmittedForApproval joins the "already open" set. Without it
    -- a request sitting with the approver would not block a second one
    -- being raised for the same gap -- a hole 257 opened by adding the
    -- status without revisiting this guard.
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

    DECLARE @type_id INT = NULL;
    IF @exception_type_code IS NOT NULL AND LEN(LTRIM(RTRIM(@exception_type_code))) > 0
    BEGIN
        SELECT @type_id = exception_type_id FROM grac_practice.exception_type_master
         WHERE exception_type_code = @exception_type_code;
        IF @type_id IS NULL
            THROW 55202, 'sp_exception_request_create: unknown exception_type_code.', 1;
    END

    -- 258: derive the practice when the caller did not name one. The
    -- analysis screen scopes its task picker to this value, and the only
    -- form that used to populate it was removed by 257.
    IF @linked_practice_id IS NULL
        SELECT @linked_practice_id = pi.practice_id
          FROM grac_practice.custom_gap g
          JOIN grac_practice.practice_instance pi
               ON pi.practice_instance_id = g.source_reference_id
         WHERE g.custom_gap_id = @custom_gap_id
           AND g.source_reference_type = N'PracticeInstance';

    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
    DECLARE @title NVARCHAR(300) = COALESCE(@request_title, N'Exception: ' + @gap_title);
    DECLARE @new_id BIGINT;

    BEGIN TRY
        BEGIN TRAN;

        INSERT INTO grac_practice.exception_request
            (organization_id, custom_gap_id,
             request_title, request_reason,
             exception_type_id, justification, risk_impact,
             owner_employee_id,
             linked_practice_id, linked_requirement_ref,
             status_code,
             requested_by_employee_id, requested_dt,
             record_status_id, entered_by, entered_dt)
        VALUES
            (@org_id, @custom_gap_id,
             @title, @request_reason,
             @type_id, @justification, @risk_impact,
             @owner_employee_id,
             @linked_practice_id, @linked_requirement_ref,
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
PRINT '327 rollback: sp_exception_request_create restored to 258 (custom_gap_id required again).';
GO

-- =====================================================================
-- 4. sp_exception_request_get -- restored to 260's exact body
--    (INNER JOIN custom_gap; no RequestTypeCode column)
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
      JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.custom_gap_id
 LEFT JOIN grac_practice.exception_type_master   et ON et.exception_type_id = r.exception_type_id
 LEFT JOIN grac_practice.organization_employee   ow ON ow.employee_id       = r.owner_employee_id
 LEFT JOIN grac_practice.organization_employee   rq ON rq.employee_id       = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee   ap ON ap.employee_id       = r.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee   rj ON rj.employee_id       = r.rejected_by_employee_id
 LEFT JOIN grac_practice.frequency_master        fm ON fm.frequency_id      = r.review_frequency_id
     WHERE r.exception_request_id = @exception_request_id;
END
GO
PRINT '327 rollback: sp_exception_request_get restored to 260 (INNER JOIN custom_gap).';
GO

SELECT '327 rollback objects restored' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_exception_request_create','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_exception_request_get','P')    IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM sys.check_constraints
                              WHERE name = 'ck_pm_exception_request_type'
                                AND OBJECT_DEFINITION(object_id) LIKE '%CUSTOM%')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '327 rollback complete.';
GO

SET NOEXEC OFF;
GO
