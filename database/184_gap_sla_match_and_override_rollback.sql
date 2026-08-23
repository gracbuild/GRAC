-- =====================================================================
-- 184 Gap SLA auto-match + override -- ROLLBACK
--
-- Drops the new procs and the schema additions, restores the 176
-- version of sp_exception_request_reject and the 162 version of
-- sp_exception_request_list.
--
-- The filtered UNIQUE index + column DROPs may run into locks if there
-- are open transactions in flight -- run offline.
-- =====================================================================
SET NOCOUNT ON;
GO

-- Drop procs new in 184.
IF OBJECT_ID('grac_practice.sp_org_sla_match_for_severity','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_sla_match_for_severity;
IF OBJECT_ID('grac_practice.sp_custom_gap_apply_sla','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_custom_gap_apply_sla;
IF OBJECT_ID('grac_practice.sp_sla_override_request_create','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_sla_override_request_create;
IF OBJECT_ID('grac_practice.sp_sla_override_approve','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_sla_override_approve;
GO

-- Drop filtered UNIQUE index that references request_type_code.
IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE name = 'ux_pm_exception_request_sla_pending'
              AND object_id = OBJECT_ID('grac_practice.exception_request'))
    DROP INDEX ux_pm_exception_request_sla_pending ON grac_practice.exception_request;
GO

-- Drop CHECKs, then DEFAULT, then columns.
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_exception_request_type')
    ALTER TABLE grac_practice.exception_request DROP CONSTRAINT ck_pm_exception_request_type;
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'df_pm_exception_request_type')
    ALTER TABLE grac_practice.exception_request DROP CONSTRAINT df_pm_exception_request_type;

IF COL_LENGTH('grac_practice.exception_request','request_type_code') IS NOT NULL
    ALTER TABLE grac_practice.exception_request DROP COLUMN request_type_code;
IF COL_LENGTH('grac_practice.exception_request','sla_days_original') IS NOT NULL
    ALTER TABLE grac_practice.exception_request DROP COLUMN sla_days_original;
IF COL_LENGTH('grac_practice.exception_request','sla_days_requested') IS NOT NULL
    ALTER TABLE grac_practice.exception_request DROP COLUMN sla_days_requested;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_custom_gap_sla_source')
    ALTER TABLE grac_practice.custom_gap DROP CONSTRAINT ck_pm_custom_gap_sla_source;

IF COL_LENGTH('grac_practice.custom_gap','sla_master_id') IS NOT NULL
    ALTER TABLE grac_practice.custom_gap DROP COLUMN sla_master_id;
IF COL_LENGTH('grac_practice.custom_gap','sla_days_effective') IS NOT NULL
    ALTER TABLE grac_practice.custom_gap DROP COLUMN sla_days_effective;
IF COL_LENGTH('grac_practice.custom_gap','sla_source_code') IS NOT NULL
    ALTER TABLE grac_practice.custom_gap DROP COLUMN sla_source_code;
GO

-- Restore the 176 version of sp_exception_request_reject (no type awareness).
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

    SELECT @exception_request_id AS ExceptionRequestId, N'Rejected' AS StatusCode;
END
GO

-- Restore the 166 shape of sp_exception_request_list (with
-- ExceptionTypeName + EffectiveFrom + TotalRows -- no type filter,
-- no SLA columns).
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_list
    @organization_id BIGINT,
    @status_code     NVARCHAR(30) = NULL,
    @page_number     INT = 1,
    @page_size       INT = 25
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
     ORDER BY r.requested_dt DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

PRINT '184 rolled back.';
GO
