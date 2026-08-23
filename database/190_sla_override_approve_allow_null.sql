-- =====================================================================
-- 190 Allow SLA override approve without approved_by_employee_id
--
-- Mirrors migration 188 (which made the REQUESTER employee_id
-- optional). Practice Admin sessions still don't carry an
-- organization_employee row -- so the browser can't send an
-- approvedByEmployeeId either. Audit trail is preserved via
-- @caller_display_name (email) on both the exception_request row
-- and the exception_request_history record.
--
-- Rollback: 190_..._rollback.sql restores the 184 mandatory check.
-- =====================================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_sla_override_approve
    @exception_request_id    BIGINT,
    @approved_by_employee_id BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @exception_request_id IS NULL
        THROW 55330, 'exception_request_id is required.', 1;
    -- 190: approved_by_employee_id is OPTIONAL. Audit via caller_display_name.

    DECLARE @custom_gap_id BIGINT, @type NVARCHAR(30),
            @current NVARCHAR(30), @sla_days_requested INT;
    SELECT @custom_gap_id      = custom_gap_id,
           @type               = request_type_code,
           @current            = status_code,
           @sla_days_requested = sla_days_requested
    FROM grac_practice.exception_request
    WHERE exception_request_id = @exception_request_id;

    IF @custom_gap_id IS NULL    THROW 55332, 'request not found.', 1;
    IF @type <> N'SLA_CANDIDATE' THROW 55333, 'Not an SLA override request. Use sp_exception_request_approve for Gap Candidate approvals.', 1;
    IF @current <> N'Pending'    THROW 55334, 'Only Pending SLA override requests can be approved.', 1;
    IF @sla_days_requested IS NULL THROW 55335, 'Request is missing sla_days_requested; cannot apply.', 1;

    DECLARE @gap_entered_dt DATETIME2;
    SELECT @gap_entered_dt = entered_dt
    FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id;

    BEGIN TRAN;

    UPDATE grac_practice.exception_request
       SET status_code             = N'Approved',
           approved_by_employee_id = @approved_by_employee_id,
           approved_dt             = SYSUTCDATETIME(),
           updated_by              = @caller_display_name,
           updated_dt              = SYSUTCDATETIME()
     WHERE exception_request_id = @exception_request_id;

    INSERT INTO grac_practice.exception_request_history
        (exception_request_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@exception_request_id, N'Approve', N'Pending', N'Approved',
         CONCAT(N'SLA override approved: ', CAST(@sla_days_requested AS NVARCHAR(10)), N' days applied to gap.'),
         @approved_by_employee_id, @caller_display_name,
         @caller_display_name, SYSUTCDATETIME());

    -- Apply the override to the gap.
    UPDATE grac_practice.custom_gap
       SET sla_days_effective = @sla_days_requested,
           sla_source_code    = N'OVERRIDDEN',
           due_date           = DATEADD(DAY, @sla_days_requested, CAST(@gap_entered_dt AS DATE)),
           updated_by         = @caller_display_name,
           updated_dt         = SYSUTCDATETIME()
     WHERE custom_gap_id = @custom_gap_id;

    COMMIT;

    SELECT @exception_request_id AS ExceptionRequestId,
           N'Approved' AS StatusCode,
           @custom_gap_id AS CustomGapId,
           @sla_days_requested AS SlaDaysApplied;
END
GO

PRINT '190 sp_sla_override_approve: approver now optional.';
GO
