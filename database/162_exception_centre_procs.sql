-- =====================================================================
-- 162 Exception Centre -- procedures + auto-trigger from gap analysis
--
-- SURFACE
--   sp_exception_request_create              (idempotent per gap; called by trigger + manually)
--   sp_exception_request_list                admin dashboard, org-scoped
--   sp_exception_request_get                 single request detail
--   sp_exception_request_approve             sets state, effective_until, note; audit
--   sp_exception_request_reject              sets state, reason; audit
--   sp_exception_request_withdraw            requester withdraws
--   sp_exception_request_attachment_save     upload approval note attachment
--   sp_exception_request_attachment_get      download
--   sp_exception_request_attachment_list     per-request attachment list
--
--   REWRITE: sp_custom_gap_analysis_save
--     Preserves existing behaviour; ADDS auto-create of an
--     exception_request when recommend_exception=1 AND no active
--     Pending/Approved exception exists for the gap already.
--
-- ERROR CODE RANGE: 55200-55299.
-- Rollback: 162_exception_centre_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.exception_request','U') IS NULL
BEGIN
    RAISERROR('162: run 161 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_exception_request_create
--    Idempotent per (custom_gap_id, active_status). If a Pending or
--    Approved request already exists for the gap, returns that id -- no
--    duplicate raised. Called by the analysis-save trigger AND by a
--    user "Request Exception" button (future).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_create
    @custom_gap_id           BIGINT,
    @request_title           NVARCHAR(300) = NULL,
    @request_reason          NVARCHAR(MAX) = NULL,
    @requested_by_employee_id BIGINT       = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
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

    -- Idempotent: return existing active request if one exists.
    DECLARE @existing_id BIGINT =
        (SELECT TOP 1 exception_request_id
           FROM grac_practice.exception_request
          WHERE custom_gap_id = @custom_gap_id
            AND status_code IN (N'Pending', N'Approved')
          ORDER BY exception_request_id DESC);
    IF @existing_id IS NOT NULL
    BEGIN
        SELECT @existing_id AS ExceptionRequestId, CAST(0 AS BIT) AS Created;
        RETURN;
    END

    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    DECLARE @title NVARCHAR(300) = COALESCE(@request_title, N'Exception: ' + @gap_title);
    DECLARE @new_id BIGINT;

    BEGIN TRY
        BEGIN TRAN;

        INSERT INTO grac_practice.exception_request
            (organization_id, custom_gap_id,
             request_title, request_reason,
             status_code,
             requested_by_employee_id, requested_dt,
             record_status_id, entered_by, entered_dt)
        VALUES
            (@org_id, @custom_gap_id,
             @title, @request_reason,
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
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @new_id AS ExceptionRequestId, CAST(1 AS BIT) AS Created;
END
GO

-- =====================================================================
-- 2. sp_exception_request_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_list
    @organization_id BIGINT,
    @status_code     NVARCHAR(30) = NULL,      -- Pending / Approved / Rejected / Withdrawn / NULL=all
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
        r.exception_request_id      AS ExceptionRequestId,
        r.organization_id           AS OrganizationId,
        r.custom_gap_id             AS CustomGapId,
        g.title                     AS GapTitle,
        r.request_title             AS RequestTitle,
        r.status_code               AS StatusCode,
        r.requested_dt              AS RequestedOn,
        rq.employee_name            AS RequestedByName,
        r.approved_dt               AS ApprovedOn,
        ap.employee_name            AS ApprovedByName,
        r.effective_until           AS EffectiveUntil,
        r.rejected_dt               AS RejectedOn,
        rj.employee_name            AS RejectedByName,
        (SELECT COUNT(*) FROM grac_practice.exception_request_attachment a
          WHERE a.exception_request_id = r.exception_request_id) AS AttachmentCount,
        COUNT(*) OVER ()            AS TotalRows
      FROM grac_practice.exception_request r
      JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.custom_gap_id
 LEFT JOIN grac_practice.organization_employee rq ON rq.employee_id = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee ap ON ap.employee_id = r.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee rj ON rj.employee_id = r.rejected_by_employee_id
     WHERE r.organization_id = @organization_id
       AND (@status_code IS NULL OR r.status_code = @status_code)
     ORDER BY r.requested_dt DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- 3. sp_exception_request_get
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_get
    @exception_request_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @exception_request_id IS NULL
        THROW 55220, 'sp_exception_request_get: exception_request_id is required.', 1;

    SELECT
        r.exception_request_id      AS ExceptionRequestId,
        r.organization_id           AS OrganizationId,
        r.custom_gap_id             AS CustomGapId,
        g.title                     AS GapTitle,
        r.request_title             AS RequestTitle,
        r.request_reason            AS RequestReason,
        r.status_code               AS StatusCode,
        r.requested_by_employee_id  AS RequestedByEmployeeId,
        rq.employee_name            AS RequestedByName,
        r.requested_dt              AS RequestedOn,
        r.approved_by_employee_id   AS ApprovedByEmployeeId,
        ap.employee_name            AS ApprovedByName,
        r.approved_dt               AS ApprovedOn,
        r.effective_until           AS EffectiveUntil,
        r.approval_note             AS ApprovalNote,
        r.rejected_by_employee_id   AS RejectedByEmployeeId,
        rj.employee_name            AS RejectedByName,
        r.rejected_dt               AS RejectedOn,
        r.rejection_reason          AS RejectionReason
      FROM grac_practice.exception_request r
      JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.custom_gap_id
 LEFT JOIN grac_practice.organization_employee rq ON rq.employee_id = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee ap ON ap.employee_id = r.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee rj ON rj.employee_id = r.rejected_by_employee_id
     WHERE r.exception_request_id = @exception_request_id;
END
GO

-- =====================================================================
-- 4. sp_exception_request_approve
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_approve
    @exception_request_id    BIGINT,
    @effective_until         DATE,
    @approval_note           NVARCHAR(MAX),
    @approved_by_employee_id BIGINT,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @exception_request_id IS NULL
        THROW 55230, 'sp_exception_request_approve: exception_request_id is required.', 1;
    IF @effective_until IS NULL
        THROW 55231, 'sp_exception_request_approve: effective_until date is required.', 1;
    IF @approval_note IS NULL OR LEN(LTRIM(RTRIM(@approval_note))) = 0
        THROW 55232, 'sp_exception_request_approve: approval_note is required.', 1;
    IF @approved_by_employee_id IS NULL
        THROW 55233, 'sp_exception_request_approve: approved_by_employee_id is required.', 1;

    DECLARE @current NVARCHAR(30);
    SELECT @current = status_code
      FROM grac_practice.exception_request WHERE exception_request_id = @exception_request_id;
    IF @current IS NULL
        THROW 55234, 'sp_exception_request_approve: request not found.', 1;
    IF @current <> N'Pending'
        THROW 55235, 'sp_exception_request_approve: only Pending requests can be approved.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.exception_request
           SET status_code             = N'Approved',
               approved_by_employee_id = @approved_by_employee_id,
               approved_dt             = SYSUTCDATETIME(),
               effective_until         = @effective_until,
               approval_note           = @approval_note,
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE exception_request_id = @exception_request_id;

        INSERT INTO grac_practice.exception_request_history
            (exception_request_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@exception_request_id, N'Approve', N'Pending', N'Approved',
             CONCAT(N'Effective until ', CONVERT(NVARCHAR(10), @effective_until, 23),
                    N'. Note: ', @approval_note),
             @approved_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @exception_request_id AS ExceptionRequestId, N'Approved' AS StatusCode;
END
GO

-- =====================================================================
-- 5. sp_exception_request_reject
-- =====================================================================
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

    SELECT @exception_request_id AS ExceptionRequestId, N'Rejected' AS StatusCode;
END
GO

-- =====================================================================
-- 6. sp_exception_request_attachment_save  (approval note file)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_attachment_save
    @exception_request_id    BIGINT,
    @file_name               NVARCHAR(500),
    @content_type            NVARCHAR(200) = NULL,
    @file_data               VARBINARY(MAX),
    @uploaded_by_employee_id BIGINT = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @exception_request_id IS NULL
        THROW 55250, 'sp_exception_request_attachment_save: exception_request_id is required.', 1;
    IF @file_data IS NULL OR DATALENGTH(@file_data) = 0
        THROW 55251, 'sp_exception_request_attachment_save: file_data is empty.', 1;
    IF @file_name IS NULL OR LEN(LTRIM(RTRIM(@file_name))) = 0
        THROW 55252, 'sp_exception_request_attachment_save: file_name is required.', 1;
    IF NOT EXISTS(SELECT 1 FROM grac_practice.exception_request WHERE exception_request_id = @exception_request_id)
        THROW 55253, 'sp_exception_request_attachment_save: request not found.', 1;

    INSERT INTO grac_practice.exception_request_attachment
        (exception_request_id, file_name, content_type,
         file_size_bytes, file_data, uploaded_by_employee_id, uploaded_dt)
    VALUES
        (@exception_request_id, @file_name, @content_type,
         DATALENGTH(@file_data), @file_data, @uploaded_by_employee_id, SYSUTCDATETIME());

    DECLARE @att_id BIGINT = SCOPE_IDENTITY();

    INSERT INTO grac_practice.exception_request_history
        (exception_request_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@exception_request_id, N'AttachmentUpload', NULL, NULL,
         CONCAT(N'Uploaded: ', @file_name),
         @uploaded_by_employee_id, @caller_display_name,
         @caller_display_name, SYSUTCDATETIME());

    SELECT @att_id AS AttachmentId;
END
GO

-- =====================================================================
-- 7. sp_exception_request_attachment_get
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_attachment_get
    @attachment_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @attachment_id IS NULL
        THROW 55260, 'sp_exception_request_attachment_get: attachment_id is required.', 1;

    SELECT
        attachment_id            AS AttachmentId,
        exception_request_id     AS ExceptionRequestId,
        file_name                AS FileName,
        content_type             AS ContentType,
        file_size_bytes          AS FileSizeBytes,
        file_data                AS FileData,
        uploaded_dt              AS UploadedOn
      FROM grac_practice.exception_request_attachment
     WHERE attachment_id = @attachment_id;
END
GO

-- =====================================================================
-- 8. sp_exception_request_attachment_list  (per request; no file_data)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_attachment_list
    @exception_request_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @exception_request_id IS NULL
        THROW 55270, 'sp_exception_request_attachment_list: exception_request_id is required.', 1;

    SELECT
        a.attachment_id           AS AttachmentId,
        a.file_name               AS FileName,
        a.content_type            AS ContentType,
        a.file_size_bytes         AS FileSizeBytes,
        a.uploaded_by_employee_id AS UploadedByEmployeeId,
        e.employee_name           AS UploadedByName,
        a.uploaded_dt             AS UploadedOn
      FROM grac_practice.exception_request_attachment a
 LEFT JOIN grac_practice.organization_employee e ON e.employee_id = a.uploaded_by_employee_id
     WHERE a.exception_request_id = @exception_request_id
     ORDER BY a.uploaded_dt DESC;
END
GO

-- =====================================================================
-- 9. REWRITE sp_custom_gap_analysis_save
--    Adds auto-create of exception_request when recommend_exception=1
--    (idempotent via sp_exception_request_create which returns existing
--    id if one already exists for the gap). Everything else is unchanged
--    from 157's version.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_analysis_save
    @custom_gap_id            BIGINT,
    @detection_method_code    NVARCHAR(60)  = NULL,
    @detection_method_name    NVARCHAR(200) = NULL,
    @severity_code            NVARCHAR(30)  = NULL,
    @severity_name            NVARCHAR(120) = NULL,
    @business_impact_code     NVARCHAR(30)  = NULL,
    @business_impact_summary  NVARCHAR(MAX) = NULL,
    @regulatory_impact_code   NVARCHAR(30)  = NULL,
    @regulatory_impact_summary NVARCHAR(MAX) = NULL,
    @rca_required             BIT           = 0,
    @rca_method_code          NVARCHAR(60)  = NULL,
    @rca_summary              NVARCHAR(MAX) = NULL,
    @recommended_action_summary NVARCHAR(MAX) = NULL,
    @recommend_task           BIT           = 0,
    @recommend_exception      BIT           = 0,
    @recommend_risk           BIT           = 0,
    @analysed_by_employee_id  BIGINT        = NULL,
    @caller_display_name      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @custom_gap_id IS NULL
        THROW 55121, 'sp_custom_gap_analysis_save: custom_gap_id is required.', 1;
    IF NOT EXISTS(SELECT 1 FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id)
        THROW 55122, 'sp_custom_gap_analysis_save: custom_gap not found.', 1;

    MERGE grac_practice.custom_gap_analysis AS tgt
    USING (SELECT @custom_gap_id AS custom_gap_id) AS src
    ON tgt.custom_gap_id = src.custom_gap_id
    WHEN MATCHED THEN UPDATE SET
        detection_method_code    = @detection_method_code,
        detection_method_name    = @detection_method_name,
        severity_code            = @severity_code,
        severity_name            = @severity_name,
        business_impact_code     = @business_impact_code,
        business_impact_summary  = @business_impact_summary,
        regulatory_impact_code   = @regulatory_impact_code,
        regulatory_impact_summary= @regulatory_impact_summary,
        rca_required             = @rca_required,
        rca_method_code          = @rca_method_code,
        rca_summary              = @rca_summary,
        recommended_action_summary = @recommended_action_summary,
        recommend_task           = @recommend_task,
        recommend_exception      = @recommend_exception,
        recommend_risk           = @recommend_risk,
        analysed_by_employee_id  = COALESCE(@analysed_by_employee_id, tgt.analysed_by_employee_id),
        analysed_on              = COALESCE(tgt.analysed_on, SYSUTCDATETIME()),
        updated_by               = @caller_display_name,
        updated_dt               = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (custom_gap_id, detection_method_code, detection_method_name,
         severity_code, severity_name,
         business_impact_code, business_impact_summary,
         regulatory_impact_code, regulatory_impact_summary,
         rca_required, rca_method_code, rca_summary,
         recommended_action_summary,
         recommend_task, recommend_exception, recommend_risk,
         analysed_by_employee_id, analysed_on,
         entered_by, entered_dt)
    VALUES
        (@custom_gap_id, @detection_method_code, @detection_method_name,
         @severity_code, @severity_name,
         @business_impact_code, @business_impact_summary,
         @regulatory_impact_code, @regulatory_impact_summary,
         @rca_required, @rca_method_code, @rca_summary,
         @recommended_action_summary,
         @recommend_task, @recommend_exception, @recommend_risk,
         @analysed_by_employee_id, SYSUTCDATETIME(),
         @caller_display_name, SYSUTCDATETIME());

    IF @severity_code IS NOT NULL AND LEN(LTRIM(RTRIM(@severity_code))) > 0
        UPDATE grac_practice.custom_gap
           SET severity_code = @severity_code,
               severity_name = COALESCE(@severity_name, severity_name),
               updated_by    = @caller_display_name,
               updated_dt    = SYSUTCDATETIME()
         WHERE custom_gap_id = @custom_gap_id;

    -- ============ Auto-trigger: Exception request =====================
    -- If analyst recommended an exception, materialize a request in
    -- Exception Centre (idempotent -- returns existing if already there).
    -- Failures inside the create proc are surfaced but should not roll
    -- back the analysis save; wrap in TRY/CATCH so analysis is durable.
    IF @recommend_exception = 1
    BEGIN
        BEGIN TRY
            DECLARE @gap_title NVARCHAR(250) =
                (SELECT title FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id);
            EXEC grac_practice.sp_exception_request_create
                @custom_gap_id            = @custom_gap_id,
                @request_title            = NULL,           -- proc defaults to "Exception: <gap title>"
                @request_reason           = @recommended_action_summary,
                @requested_by_employee_id = @analysed_by_employee_id,
                @caller_display_name      = @caller_display_name;
        END TRY
        BEGIN CATCH
            -- Best-effort; keep the analysis save successful even if the
            -- exception create failed (it can be retried by re-saving).
            DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_custom_gap_analysis_save: exception auto-create warning: ', @msg);
        END CATCH
    END

    SELECT @custom_gap_id AS CustomGapId;
END
GO

PRINT '162 Exception Centre procs ready.';
GO
