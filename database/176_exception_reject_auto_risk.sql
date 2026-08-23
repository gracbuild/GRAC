-- =====================================================================
-- 176 Exception reject -> auto-create Risk candidate
--
-- SIR'S GOVERNANCE RULE
-- ---------------------
-- If an exception request is REJECTED, the underlying gap still exists
-- and is still not being remediated (rejection means "we won't grant an
-- exception for this"). The only correct GRC outcome is to track it as
-- a business risk. Otherwise the gap silently falls through the cracks.
--
-- BEHAVIOUR
-- ---------
-- After the rejection persists in exception_request + history, we call
-- sp_risk_candidate_create for the same custom_gap_id. That proc is
-- idempotent per gap: if the analyst had already flagged the gap as a
-- business risk during analysis, an existing Pending/Accepted candidate
-- is returned unchanged -- no duplicate created. If none exists (analyst
-- had said business_risk_present='N'), a new candidate is created with
-- the rejection context in the summary.
--
-- Failures in the risk auto-create are best-effort -- the rejection
-- stays durable (wrapped in TRY/CATCH). The rejection is the source of
-- truth; the risk candidate is a downstream signal.
--
-- Rollback: 176_exception_reject_auto_risk_rollback.sql (restores 162
-- body without the risk auto-trigger).
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_risk_candidate_create','P') IS NULL
BEGIN
    RAISERROR('176: sp_risk_candidate_create missing. Run 170 first.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_reject
    @exception_request_id    BIGINT,
    @rejection_reason        NVARCHAR(MAX),
    @rejected_by_employee_id BIGINT,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @exception_request_id IS NULL
        THROW 55240, 'sp_exception_request_reject: exception_request_id is required.', 1;
    IF @rejection_reason IS NULL OR LEN(LTRIM(RTRIM(@rejection_reason))) = 0
        THROW 55241, 'sp_exception_request_reject: rejection_reason is required.', 1;
    IF @rejected_by_employee_id IS NULL
        THROW 55242, 'sp_exception_request_reject: rejected_by_employee_id is required.', 1;

    DECLARE @current NVARCHAR(30);
    SELECT @current = status_code
      FROM grac_practice.exception_request WHERE exception_request_id = @exception_request_id;
    IF @current IS NULL
        THROW 55243, 'sp_exception_request_reject: request not found.', 1;
    IF @current <> N'Pending'
        THROW 55244, 'sp_exception_request_reject: only Pending requests can be rejected.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.exception_request
           SET status_code             = N'Rejected',
               rejected_by_employee_id = @rejected_by_employee_id,
               rejected_dt             = SYSUTCDATETIME(),
               rejection_reason        = @rejection_reason,
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE exception_request_id = @exception_request_id;

        INSERT INTO grac_practice.exception_request_history
            (exception_request_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@exception_request_id, N'Reject', N'Pending', N'Rejected',
             @rejection_reason, @rejected_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    -- ============ Auto-trigger: Risk candidate ========================
    -- Governance: rejected exception means gap remains unresolved AND
    -- unaccepted -- must be tracked as a business risk. Idempotent per
    -- gap via sp_risk_candidate_create.
    BEGIN TRY
        DECLARE @gap_id  BIGINT;
        SELECT @gap_id = custom_gap_id
          FROM grac_practice.exception_request
         WHERE exception_request_id = @exception_request_id;

        -- Precompute the summary (EXEC parameters cannot take expressions).
        DECLARE @risk_summary NVARCHAR(MAX) =
            CONCAT(N'Auto-raised because exception request #',
                   CAST(@exception_request_id AS NVARCHAR(20)),
                   N' was rejected. Rejection reason: ',
                   @rejection_reason);

        EXEC grac_practice.sp_risk_candidate_create
            @custom_gap_id            = @gap_id,
            @candidate_title          = NULL,           -- proc defaults to "Risk: <gap title>"
            @candidate_summary        = @risk_summary,
            @requested_by_employee_id = @rejected_by_employee_id,
            @caller_display_name      = @caller_display_name;
    END TRY
    BEGIN CATCH
        DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
        PRINT CONCAT(N'sp_exception_request_reject: risk auto-create warning: ', @msg);
    END CATCH

    SELECT @exception_request_id AS ExceptionRequestId, N'Rejected' AS StatusCode;
END
GO

PRINT '176 exception reject -> risk auto-create ready.';
GO
