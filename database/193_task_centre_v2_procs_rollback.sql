-- =====================================================================
-- 193 Task Centre v2 — procedures ROLLBACK
--
-- Drops the procedures 193 introduced and RESTORES the two procedures it
-- rewrote (sp_exception_request_reject, sp_exception_request_list) to
-- their 184 shape, so the Exception Centre keeps working after a
-- rollback instead of silently losing its reject / list behaviour.
--
-- The restored versions below are byte-for-byte the 184 definitions —
-- INNER JOIN on custom_gap, GAP_CANDIDATE risk auto-creation, no task
-- columns. Re-running 184_gap_sla_match_and_override.sql achieves the
-- same thing; this script exists so a rollback is self-contained.
--
-- Order: drop dependents before dependencies. sp_task_apply_sla is
-- called by sp_task_priority_change and sp_task_priority_reduction_
-- approve, and sp_task_activity_add is called by almost everything, so
-- they go last.
--
-- Schema (192) is NOT touched — run 192_task_centre_v2_schema_rollback
-- .sql after this if you want the columns gone too.
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT '193-rollback: schema grac_practice missing — nothing to do.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Drop the 193 procedures (dependents first)
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_task_priority_reduction_approve','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_priority_reduction_approve;
IF OBJECT_ID('grac_practice.sp_task_priority_change','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_priority_change;
IF OBJECT_ID('grac_practice.sp_task_attachment_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_attachment_get;
IF OBJECT_ID('grac_practice.sp_task_attachment_add','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_attachment_add;
IF OBJECT_ID('grac_practice.sp_task_apply_sla','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_apply_sla;
IF OBJECT_ID('grac_practice.sp_org_sla_match_for_priority','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_sla_match_for_priority;
IF OBJECT_ID('grac_practice.sp_task_owner_resolve','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_owner_resolve;
IF OBJECT_ID('grac_practice.sp_task_activity_add','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_activity_add;
IF OBJECT_ID('grac_practice.fn_task_employee_by_name','FN') IS NOT NULL
    DROP FUNCTION grac_practice.fn_task_employee_by_name;
GO

-- ---------------------------------------------------------------------
-- 2. Restore sp_exception_request_reject to the 184 definition
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.exception_request','U') IS NULL
BEGIN
    PRINT '193-rollback: exception_request missing — skipping proc restore.';
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

    DECLARE @current NVARCHAR(30), @type NVARCHAR(30);
    SELECT @current = status_code, @type = request_type_code
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

    IF @type = N'GAP_CANDIDATE'
    BEGIN
        BEGIN TRY
            DECLARE @gap_id BIGINT;
            SELECT @gap_id = custom_gap_id
              FROM grac_practice.exception_request
             WHERE exception_request_id = @exception_request_id;

            DECLARE @risk_summary NVARCHAR(MAX) =
                CONCAT(N'Auto-raised because exception request #',
                       CAST(@exception_request_id AS NVARCHAR(20)),
                       N' was rejected. Rejection reason: ',
                       @rejection_reason);

            EXEC grac_practice.sp_risk_candidate_create
                @custom_gap_id            = @gap_id,
                @candidate_title          = NULL,
                @candidate_summary        = @risk_summary,
                @requested_by_employee_id = @rejected_by_employee_id,
                @caller_display_name      = @caller_display_name;
        END TRY
        BEGIN CATCH
            DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_exception_request_reject: risk auto-create warning: ', @msg);
        END CATCH
    END

    SELECT @exception_request_id AS ExceptionRequestId,
           N'Rejected' AS StatusCode,
           @type AS RequestTypeCode;
END;
GO

-- ---------------------------------------------------------------------
-- 3. Restore sp_exception_request_list to the 184 definition
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_list
    @organization_id   BIGINT,
    @status_code       NVARCHAR(30) = NULL,
    @request_type_code NVARCHAR(30) = NULL,
    @page_number       INT = 1,
    @page_size         INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 55210, 'sp_exception_request_list: organization_id is required.', 1;
    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    SELECT
        r.exception_request_id  AS ExceptionRequestId,
        r.organization_id       AS OrganizationId,
        r.custom_gap_id         AS CustomGapId,
        g.title                 AS GapTitle,
        r.request_title         AS RequestTitle,
        et.exception_type_name  AS ExceptionTypeName,
        r.status_code           AS StatusCode,
        r.request_type_code     AS RequestTypeCode,
        r.sla_days_original     AS SlaDaysOriginal,
        r.sla_days_requested    AS SlaDaysRequested,
        r.requested_dt          AS RequestedOn,
        rq.employee_name        AS RequestedByName,
        r.approved_dt           AS ApprovedOn,
        ap.employee_name        AS ApprovedByName,
        r.effective_from        AS EffectiveFrom,
        r.effective_until       AS EffectiveUntil,
        r.rejected_dt           AS RejectedOn,
        rj.employee_name        AS RejectedByName,
        (SELECT COUNT(*) FROM grac_practice.exception_request_attachment a
          WHERE a.exception_request_id = r.exception_request_id) AS AttachmentCount,
        COUNT(*) OVER () AS TotalRows
      FROM grac_practice.exception_request r
      JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.custom_gap_id
 LEFT JOIN grac_practice.exception_type_master   et ON et.exception_type_id = r.exception_type_id
 LEFT JOIN grac_practice.organization_employee   rq ON rq.employee_id       = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee   ap ON ap.employee_id       = r.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee   rj ON rj.employee_id       = r.rejected_by_employee_id
     WHERE r.organization_id = @organization_id
       AND (@status_code IS NULL OR r.status_code = @status_code)
       AND (@request_type_code IS NULL OR r.request_type_code = @request_type_code)
     ORDER BY r.requested_dt DESC, r.exception_request_id DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

PRINT '193 Task Centre v2 procedures rolled back; 184 Exception Centre procs restored.';
GO

SET NOEXEC OFF;
GO
