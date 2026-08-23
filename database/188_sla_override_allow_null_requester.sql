-- =====================================================================
-- 188 Allow SLA override request without requested_by_employee_id
--
-- sp_sla_override_request_create (from 184) throws 55323 when
-- @requested_by_employee_id is NULL. In practice sessions where the
-- logged-in user is not tied to an organization_employee row (e.g.
-- Practice Admin), the browser passes null / 0 -- and the API returned
-- "requestedByEmployeeId is required.".
--
-- The exception_request table already accepts NULL requester
-- (migration 161 column is nullable, FK is nullable). Audit trail
-- stays intact via @caller_display_name which carries the operator's
-- email. So we relax the proc guard: accept null, write null through
-- to the row. exception_request_history's actor_employee_id is also
-- nullable per its 161 shape, so the same relaxation applies there.
--
-- Rollback: 188_..._rollback.sql restores the 184 mandatory check.
-- =====================================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_sla_override_request_create
    @custom_gap_id            BIGINT,
    @sla_days_requested       INT,
    @request_reason           NVARCHAR(MAX),
    @requested_by_employee_id BIGINT        = NULL,
    @caller_display_name      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @custom_gap_id IS NULL
        THROW 55320, 'custom_gap_id is required.', 1;
    IF @sla_days_requested IS NULL OR @sla_days_requested < 0
        THROW 55321, 'sla_days_requested must be >= 0.', 1;
    IF @request_reason IS NULL OR LEN(LTRIM(RTRIM(@request_reason))) = 0
        THROW 55322, 'request_reason is required.', 1;
    -- 188: requested_by_employee_id is OPTIONAL. Audit lands via
    -- caller_display_name (email + display). Kept as a soft
    -- reference on the row when supplied.

    DECLARE @organization_id BIGINT, @gap_title NVARCHAR(250),
            @sla_days_original INT;
    SELECT @organization_id   = organization_id,
           @gap_title          = title,
           @sla_days_original  = sla_days_effective
    FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id;

    IF @organization_id IS NULL
        THROW 55324, 'gap not found.', 1;

    IF EXISTS (
        SELECT 1 FROM grac_practice.exception_request
        WHERE custom_gap_id     = @custom_gap_id
          AND request_type_code = N'SLA_CANDIDATE'
          AND status_code       = N'Pending')
        THROW 55325,
            'A Pending SLA override request already exists for this gap. Approve, reject or withdraw it before raising another.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    DECLARE @title NVARCHAR(300) =
        CONCAT(N'SLA override: ', LEFT(ISNULL(@gap_title, N''), 200),
               N' (', CAST(@sla_days_requested AS NVARCHAR(10)), N' days)');

    BEGIN TRAN;

    INSERT INTO grac_practice.exception_request
        (organization_id, custom_gap_id, request_title, request_reason,
         status_code, request_type_code, sla_days_original, sla_days_requested,
         requested_by_employee_id, requested_dt,
         record_status_id, entered_by, entered_dt)
    VALUES
        (@organization_id, @custom_gap_id, @title, @request_reason,
         N'Pending', N'SLA_CANDIDATE', @sla_days_original, @sla_days_requested,
         @requested_by_employee_id, SYSUTCDATETIME(),
         @active_record_status_id, @caller_display_name, SYSUTCDATETIME());

    DECLARE @request_id BIGINT = SCOPE_IDENTITY();

    INSERT INTO grac_practice.exception_request_history
        (exception_request_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@request_id, N'Create', NULL, N'Pending',
         CONCAT(N'SLA override requested: ', CAST(@sla_days_requested AS NVARCHAR(10)),
                N' days (was ', ISNULL(CAST(@sla_days_original AS NVARCHAR(10)), N'unset'), N'). Reason: ',
                @request_reason),
         @requested_by_employee_id, @caller_display_name,
         @caller_display_name, SYSUTCDATETIME());

    COMMIT;

    SELECT @request_id AS ExceptionRequestId, N'Pending' AS StatusCode,
           N'SLA_CANDIDATE' AS RequestTypeCode;
END
GO

PRINT '188 sp_sla_override_request_create: requester now optional.';
GO
