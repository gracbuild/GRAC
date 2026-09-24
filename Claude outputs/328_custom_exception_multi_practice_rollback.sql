-- =====================================================================
-- 328 Custom Exception -- multiple Related Practices -- ROLLBACK
--
-- Restores sp_exception_request_create to 327's exact body (verified
-- byte-identical against 327's own source via Python difflib before
-- this file was written) and removes everything 328 added: the new
-- table and its index, and sp_exception_request_practice_list.
--
-- SAFE TO RE-RUN.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- =====================================================================
-- 1. sp_exception_request_create -- back to 327's body exactly
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
PRINT '328 rollback: sp_exception_request_create restored to 327 body.';
GO

-- =====================================================================
-- 2. Remove what 328 added
-- =====================================================================
IF OBJECT_ID('grac_practice.sp_exception_request_practice_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_exception_request_practice_list;
GO
PRINT '328 rollback: sp_exception_request_practice_list dropped.';
GO

IF OBJECT_ID('grac_practice.exception_request_practice','U') IS NOT NULL
    DROP TABLE grac_practice.exception_request_practice;
GO
PRINT '328 rollback: exception_request_practice dropped.';
GO

SET NOEXEC OFF;
GO
