-- =====================================================================
-- 170 Risk Centre -- procedures (mirror of Exception Centre 162/164/165)
--
-- PROCS:
--   sp_risk_candidate_create              idempotent per gap
--   sp_risk_candidate_list                admin dashboard, org-scoped
--   sp_risk_candidate_get                 single detail
--   sp_risk_candidate_accept              triage 'this becomes a formal risk'
--   sp_risk_candidate_reject              not a real risk / duplicate / etc.
--   sp_risk_candidate_withdraw            requester withdraws
--   sp_risk_candidate_attachment_save     evidence-style (Manual OR Automated)
--   sp_risk_candidate_attachment_get      download / read
--   sp_risk_candidate_attachment_list     per-candidate list (no BLOB)
--
-- Error range: 55400-55499
-- Rollback: 170_risk_centre_procs_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.risk_candidate','U') IS NULL
BEGIN
    RAISERROR('170: risk_candidate table missing. Run 169 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_risk_candidate_create  (idempotent per gap)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_create
    @custom_gap_id            BIGINT,
    @candidate_title          NVARCHAR(300) = NULL,
    @candidate_summary        NVARCHAR(MAX) = NULL,
    @severity_code            NVARCHAR(30)  = NULL,
    @severity_name            NVARCHAR(120) = NULL,
    @impact_summary           NVARCHAR(MAX) = NULL,
    @likelihood_summary       NVARCHAR(MAX) = NULL,
    @requested_by_employee_id BIGINT        = NULL,
    @caller_display_name      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @custom_gap_id IS NULL
        THROW 55400, 'sp_risk_candidate_create: custom_gap_id is required.', 1;

    DECLARE @org_id BIGINT, @gap_title NVARCHAR(250), @gap_severity NVARCHAR(30);
    SELECT @org_id = organization_id, @gap_title = title, @gap_severity = severity_code
      FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id;
    IF @org_id IS NULL
        THROW 55401, 'sp_risk_candidate_create: custom_gap not found.', 1;

    -- Idempotent: one active candidate per gap.
    DECLARE @existing_id BIGINT =
        (SELECT TOP 1 risk_candidate_id
           FROM grac_practice.risk_candidate
          WHERE custom_gap_id = @custom_gap_id
            AND status_code IN (N'Pending', N'Accepted')
          ORDER BY risk_candidate_id DESC);
    IF @existing_id IS NOT NULL
    BEGIN
        SELECT @existing_id AS RiskCandidateId, CAST(0 AS BIT) AS Created;
        RETURN;
    END

    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    DECLARE @title    NVARCHAR(300) = COALESCE(@candidate_title, N'Risk: ' + @gap_title);
    DECLARE @severity NVARCHAR(30)  = COALESCE(@severity_code, @gap_severity);
    DECLARE @new_id   BIGINT;

    BEGIN TRY
        BEGIN TRAN;

        INSERT INTO grac_practice.risk_candidate
            (organization_id, custom_gap_id,
             candidate_title, candidate_summary,
             severity_code, severity_name,
             impact_summary, likelihood_summary,
             status_code,
             requested_by_employee_id, requested_dt,
             record_status_id, entered_by, entered_dt)
        VALUES
            (@org_id, @custom_gap_id,
             @title, @candidate_summary,
             @severity, @severity_name,
             @impact_summary, @likelihood_summary,
             N'Pending',
             @requested_by_employee_id, SYSUTCDATETIME(),
             @active_rs, @caller_display_name, SYSUTCDATETIME());

        SET @new_id = SCOPE_IDENTITY();

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@new_id, N'Create', NULL, N'Pending',
             @candidate_summary, @requested_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @new_id AS RiskCandidateId, CAST(1 AS BIT) AS Created;
END
GO

-- =====================================================================
-- 2. sp_risk_candidate_list  (paged, org-scoped)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_list
    @organization_id BIGINT,
    @status_code     NVARCHAR(30) = NULL,      -- Pending / Accepted / Rejected / Withdrawn / NULL=all
    @page_number     INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 55410, 'sp_risk_candidate_list: organization_id is required.', 1;
    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    SELECT
        r.risk_candidate_id         AS RiskCandidateId,
        r.organization_id           AS OrganizationId,
        r.custom_gap_id             AS CustomGapId,
        g.title                     AS GapTitle,
        r.candidate_title           AS CandidateTitle,
        r.severity_code             AS SeverityCode,
        r.status_code               AS StatusCode,
        r.requested_dt              AS RequestedOn,
        rq.employee_name            AS RequestedByName,
        r.accepted_dt               AS AcceptedOn,
        ac.employee_name            AS AcceptedByName,
        r.rejected_dt               AS RejectedOn,
        rj.employee_name            AS RejectedByName,
        r.formal_risk_ref           AS FormalRiskRef,
        (SELECT COUNT(*) FROM grac_practice.risk_candidate_attachment a
          WHERE a.risk_candidate_id = r.risk_candidate_id) AS AttachmentCount,
        COUNT(*) OVER ()            AS TotalRows
      FROM grac_practice.risk_candidate r
      JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.custom_gap_id
 LEFT JOIN grac_practice.organization_employee rq ON rq.employee_id = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee ac ON ac.employee_id = r.accepted_by_employee_id
 LEFT JOIN grac_practice.organization_employee rj ON rj.employee_id = r.rejected_by_employee_id
     WHERE r.organization_id = @organization_id
       AND (@status_code IS NULL OR r.status_code = @status_code)
     ORDER BY r.requested_dt DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- 3. sp_risk_candidate_get
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_get
    @risk_candidate_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 55420, 'sp_risk_candidate_get: risk_candidate_id is required.', 1;

    SELECT
        r.risk_candidate_id         AS RiskCandidateId,
        r.organization_id           AS OrganizationId,
        r.custom_gap_id             AS CustomGapId,
        g.title                     AS GapTitle,
        r.candidate_title           AS CandidateTitle,
        r.candidate_summary         AS CandidateSummary,
        r.severity_code             AS SeverityCode,
        r.severity_name             AS SeverityName,
        r.impact_summary            AS ImpactSummary,
        r.likelihood_summary        AS LikelihoodSummary,
        r.status_code               AS StatusCode,
        r.requested_by_employee_id  AS RequestedByEmployeeId,
        rq.employee_name            AS RequestedByName,
        r.requested_dt              AS RequestedOn,
        r.accepted_by_employee_id   AS AcceptedByEmployeeId,
        ac.employee_name            AS AcceptedByName,
        r.accepted_dt               AS AcceptedOn,
        r.acceptance_note           AS AcceptanceNote,
        r.formal_risk_ref           AS FormalRiskRef,
        r.rejected_by_employee_id   AS RejectedByEmployeeId,
        rj.employee_name            AS RejectedByName,
        r.rejected_dt               AS RejectedOn,
        r.rejection_reason          AS RejectionReason
      FROM grac_practice.risk_candidate r
      JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.custom_gap_id
 LEFT JOIN grac_practice.organization_employee rq ON rq.employee_id = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee ac ON ac.employee_id = r.accepted_by_employee_id
 LEFT JOIN grac_practice.organization_employee rj ON rj.employee_id = r.rejected_by_employee_id
     WHERE r.risk_candidate_id = @risk_candidate_id;
END
GO

-- =====================================================================
-- 4. sp_risk_candidate_accept
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_accept
    @risk_candidate_id       BIGINT,
    @acceptance_note         NVARCHAR(MAX),
    @accepted_by_employee_id BIGINT,
    @formal_risk_ref         NVARCHAR(200) = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 55430, 'sp_risk_candidate_accept: risk_candidate_id is required.', 1;
    IF @acceptance_note IS NULL OR LEN(LTRIM(RTRIM(@acceptance_note))) = 0
        THROW 55431, 'sp_risk_candidate_accept: acceptance_note is required.', 1;
    IF @accepted_by_employee_id IS NULL
        THROW 55432, 'sp_risk_candidate_accept: accepted_by_employee_id is required.', 1;

    DECLARE @current NVARCHAR(30);
    SELECT @current = status_code
      FROM grac_practice.risk_candidate WHERE risk_candidate_id = @risk_candidate_id;
    IF @current IS NULL
        THROW 55433, 'sp_risk_candidate_accept: candidate not found.', 1;
    IF @current <> N'Pending'
        THROW 55434, 'sp_risk_candidate_accept: only Pending candidates can be accepted.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_candidate
           SET status_code             = N'Accepted',
               accepted_by_employee_id = @accepted_by_employee_id,
               accepted_dt             = SYSUTCDATETIME(),
               acceptance_note         = @acceptance_note,
               formal_risk_ref         = @formal_risk_ref,
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id, N'Accept', N'Pending', N'Accepted',
             CONCAT(N'Note: ', @acceptance_note,
                    CASE WHEN @formal_risk_ref IS NOT NULL
                         THEN CONCAT(N'  Formal risk ref: ', @formal_risk_ref)
                         ELSE N'' END),
             @accepted_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_candidate_id AS RiskCandidateId, N'Accepted' AS StatusCode;
END
GO

-- =====================================================================
-- 5. sp_risk_candidate_reject
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_reject
    @risk_candidate_id       BIGINT,
    @rejection_reason        NVARCHAR(MAX),
    @rejected_by_employee_id BIGINT,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 55440, 'sp_risk_candidate_reject: risk_candidate_id is required.', 1;
    IF @rejection_reason IS NULL OR LEN(LTRIM(RTRIM(@rejection_reason))) = 0
        THROW 55441, 'sp_risk_candidate_reject: rejection_reason is required.', 1;
    IF @rejected_by_employee_id IS NULL
        THROW 55442, 'sp_risk_candidate_reject: rejected_by_employee_id is required.', 1;

    DECLARE @current NVARCHAR(30);
    SELECT @current = status_code
      FROM grac_practice.risk_candidate WHERE risk_candidate_id = @risk_candidate_id;
    IF @current IS NULL
        THROW 55443, 'sp_risk_candidate_reject: candidate not found.', 1;
    IF @current <> N'Pending'
        THROW 55444, 'sp_risk_candidate_reject: only Pending candidates can be rejected.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_candidate
           SET status_code             = N'Rejected',
               rejected_by_employee_id = @rejected_by_employee_id,
               rejected_dt             = SYSUTCDATETIME(),
               rejection_reason        = @rejection_reason,
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id, N'Reject', N'Pending', N'Rejected',
             @rejection_reason, @rejected_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_candidate_id AS RiskCandidateId, N'Rejected' AS StatusCode;
END
GO

-- =====================================================================
-- 6. sp_risk_candidate_withdraw  (requester or admin cancels a Pending)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_withdraw
    @risk_candidate_id       BIGINT,
    @withdraw_reason         NVARCHAR(MAX) = NULL,
    @actor_employee_id       BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 55450, 'sp_risk_candidate_withdraw: risk_candidate_id is required.', 1;

    DECLARE @current NVARCHAR(30);
    SELECT @current = status_code
      FROM grac_practice.risk_candidate WHERE risk_candidate_id = @risk_candidate_id;
    IF @current IS NULL
        THROW 55451, 'sp_risk_candidate_withdraw: candidate not found.', 1;
    IF @current <> N'Pending'
        THROW 55452, 'sp_risk_candidate_withdraw: only Pending candidates can be withdrawn.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_candidate
           SET status_code = N'Withdrawn',
               updated_by  = @caller_display_name,
               updated_dt  = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id, N'Withdraw', N'Pending', N'Withdrawn',
             @withdraw_reason, @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_candidate_id AS RiskCandidateId, N'Withdrawn' AS StatusCode;
END
GO

-- =====================================================================
-- 7. sp_risk_candidate_attachment_save  (evidence-style)
--    Manual  -> file_name + file_data required
--    Automated -> evidence_location + evidence_locator required
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_attachment_save
    @risk_candidate_id       BIGINT,
    @collection_method_code  NVARCHAR(60)   = N'Manual',
    @evidence_type_code      NVARCHAR(60)   = NULL,
    @file_name               NVARCHAR(500)  = NULL,
    @content_type            NVARCHAR(200)  = NULL,
    @file_data               VARBINARY(MAX) = NULL,
    @evidence_location       NVARCHAR(500)  = NULL,
    @evidence_locator        NVARCHAR(500)  = NULL,
    @uploaded_by_employee_id BIGINT         = NULL,
    @caller_display_name     NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_candidate_id IS NULL
        THROW 55460, 'sp_risk_candidate_attachment_save: risk_candidate_id is required.', 1;
    IF NOT EXISTS(SELECT 1 FROM grac_practice.risk_candidate WHERE risk_candidate_id = @risk_candidate_id)
        THROW 55461, 'sp_risk_candidate_attachment_save: candidate not found.', 1;

    IF @collection_method_code IS NULL OR LEN(LTRIM(RTRIM(@collection_method_code))) = 0
        SET @collection_method_code = N'Manual';

    DECLARE @method_id INT =
        (SELECT TOP 1 collection_method_id FROM grac_practice.collection_method_master
          WHERE collection_method_code = @collection_method_code);
    IF @method_id IS NULL
        THROW 55462, 'sp_risk_candidate_attachment_save: unknown collection_method_code (expected Manual or Automated).', 1;

    DECLARE @evidence_type_id INT = NULL;
    IF @evidence_type_code IS NOT NULL AND LEN(LTRIM(RTRIM(@evidence_type_code))) > 0
    BEGIN
        SELECT @evidence_type_id = evidence_type_id
          FROM grac_practice.evidence_type_master
         WHERE evidence_type_code = @evidence_type_code;
        IF @evidence_type_id IS NULL
            THROW 55463, 'sp_risk_candidate_attachment_save: unknown evidence_type_code.', 1;
    END

    IF @collection_method_code = N'Manual'
    BEGIN
        IF @file_data IS NULL OR DATALENGTH(@file_data) = 0
            THROW 55464, 'sp_risk_candidate_attachment_save: Manual attachment requires file_data.', 1;
        IF @file_name IS NULL OR LEN(LTRIM(RTRIM(@file_name))) = 0
            THROW 55465, 'sp_risk_candidate_attachment_save: Manual attachment requires file_name.', 1;
    END
    ELSE
    BEGIN
        IF @evidence_location IS NULL OR LEN(LTRIM(RTRIM(@evidence_location))) = 0
            THROW 55466, 'sp_risk_candidate_attachment_save: Automated attachment requires evidence_location.', 1;
        IF @evidence_locator IS NULL OR LEN(LTRIM(RTRIM(@evidence_locator))) = 0
            THROW 55467, 'sp_risk_candidate_attachment_save: Automated attachment requires evidence_locator.', 1;
    END

    INSERT INTO grac_practice.risk_candidate_attachment
        (risk_candidate_id,
         collection_method_id, collection_method_code,
         evidence_type_id, evidence_type_code,
         file_name, content_type, file_size_bytes, file_data,
         evidence_location, evidence_locator,
         uploaded_by_employee_id, uploaded_dt)
    VALUES
        (@risk_candidate_id,
         @method_id, @collection_method_code,
         @evidence_type_id, @evidence_type_code,
         @file_name, @content_type,
         CASE WHEN @file_data IS NULL THEN 0 ELSE DATALENGTH(@file_data) END,
         @file_data,
         @evidence_location, @evidence_locator,
         @uploaded_by_employee_id, SYSUTCDATETIME());

    DECLARE @att_id BIGINT = SCOPE_IDENTITY();

    INSERT INTO grac_practice.risk_candidate_history
        (risk_candidate_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@risk_candidate_id, N'AttachmentUpload', NULL, NULL,
         CONCAT(N'[', @collection_method_code, N'] ',
                COALESCE(@file_name, CONCAT(@evidence_location, N': ', @evidence_locator))),
         @uploaded_by_employee_id, @caller_display_name,
         @caller_display_name, SYSUTCDATETIME());

    SELECT @att_id AS AttachmentId;
END
GO

-- =====================================================================
-- 8. sp_risk_candidate_attachment_get  (single row incl. BLOB)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_attachment_get
    @attachment_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @attachment_id IS NULL
        THROW 55470, 'sp_risk_candidate_attachment_get: attachment_id is required.', 1;

    SELECT
        a.attachment_id            AS AttachmentId,
        a.risk_candidate_id        AS RiskCandidateId,
        cm.collection_method_code  AS CollectionMethodCode,
        cm.collection_method_name  AS CollectionMethodName,
        et.evidence_type_code      AS EvidenceTypeCode,
        et.evidence_type_name      AS EvidenceTypeName,
        a.file_name                AS FileName,
        a.content_type             AS ContentType,
        a.file_size_bytes          AS FileSizeBytes,
        a.file_data                AS FileData,
        a.evidence_location        AS EvidenceLocation,
        a.evidence_locator         AS EvidenceLocator,
        a.uploaded_dt              AS UploadedOn
      FROM grac_practice.risk_candidate_attachment a
 LEFT JOIN grac_practice.collection_method_master cm ON cm.collection_method_id = a.collection_method_id
 LEFT JOIN grac_practice.evidence_type_master     et ON et.evidence_type_id = a.evidence_type_id
     WHERE a.attachment_id = @attachment_id;
END
GO

-- =====================================================================
-- 9. sp_risk_candidate_attachment_list  (per candidate; no BLOB)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_attachment_list
    @risk_candidate_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 55480, 'sp_risk_candidate_attachment_list: risk_candidate_id is required.', 1;

    SELECT
        a.attachment_id           AS AttachmentId,
        cm.collection_method_code AS CollectionMethodCode,
        cm.collection_method_name AS CollectionMethodName,
        et.evidence_type_code     AS EvidenceTypeCode,
        et.evidence_type_name     AS EvidenceTypeName,
        a.file_name               AS FileName,
        a.content_type            AS ContentType,
        a.file_size_bytes         AS FileSizeBytes,
        a.evidence_location       AS EvidenceLocation,
        a.evidence_locator        AS EvidenceLocator,
        a.uploaded_by_employee_id AS UploadedByEmployeeId,
        e.employee_name           AS UploadedByName,
        a.uploaded_dt             AS UploadedOn
      FROM grac_practice.risk_candidate_attachment a
 LEFT JOIN grac_practice.collection_method_master cm ON cm.collection_method_id = a.collection_method_id
 LEFT JOIN grac_practice.evidence_type_master     et ON et.evidence_type_id = a.evidence_type_id
 LEFT JOIN grac_practice.organization_employee    e  ON e.employee_id = a.uploaded_by_employee_id
     WHERE a.risk_candidate_id = @risk_candidate_id
     ORDER BY a.uploaded_dt DESC;
END
GO

PRINT '170 Risk Centre procs ready.';
GO
