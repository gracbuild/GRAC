-- =====================================================================
-- 151 Document Acknowledgement -- procedures
--
-- Adds the Phase 2 acknowledgement surface. Also REWRITES
-- sp_document_upload_workflow_transition so the Approve-Approve
-- transition auto-populates document_acknowledgement_pending when the
-- underlying document has acknowledgement_required = 1. That is what
-- kicks off the whole flow -- publishing a policy that needs
-- acknowledgement puts it on the admin's pending list.
--
-- SURFACE
-- -------
--   grac_practice.sp_document_ack_pending_list        pending queue (org-scoped)
--   grac_practice.sp_document_ack_create              admin creates a batch
--   grac_practice.sp_document_ack_list                admin list of batches with progress
--   grac_practice.sp_document_ack_documents_list      docs in a batch with per-doc progress
--   grac_practice.sp_document_ack_document_users_list who has to acknowledge a doc in a batch
--
--   Rewrite: grac_practice.sp_document_upload_workflow_transition
--     (unchanged public shape; adds ack-pending insert on Approve-Approve)
--
-- ERROR CODE RANGE: 52750-52799  (147 used 52700-52745).
--
-- USER-SIDE (WHO ACKNOWLEDGES) IS PHASE 3
-- ---------------------------------------
-- sp_document_ack_user_list and sp_document_ack_user_ack (the actual
-- Acknowledge action) arrive with migration 153+.
--
-- DEPENDS ON: 146, 147, 150. Rollback: 151_document_acknowledgement_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Prerequisites -----------------------------------------------------
IF OBJECT_ID('grac_practice.document_acknowledgement','U') IS NULL
   OR OBJECT_ID('grac_practice.document_acknowledgement_pending','U') IS NULL
   OR OBJECT_ID('grac_practice.document_acknowledgement_document','U') IS NULL
   OR OBJECT_ID('grac_practice.document_acknowledgement_user','U') IS NULL
BEGIN
    RAISERROR('151: prerequisites missing. Run 150 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_document_ack_pending_list
--    Docs still waiting to be rolled into a batch. Paginated.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_ack_pending_list
    @organization_id BIGINT,
    @page_number     INT = 1,
    @page_size       INT = 50
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 52750, 'sp_document_ack_pending_list: organization_id is required.', 1;

    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 50;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    ;WITH pending AS (
        SELECT p.pending_id, p.document_id, p.cycle_no, p.entered_dt
          FROM grac_practice.document_acknowledgement_pending p
          JOIN grac_practice.document_upload d ON d.document_id = p.document_id
         WHERE p.status_code    = N'Open'
           AND d.organization_id = @organization_id
    )
    SELECT
        p.pending_id      AS PendingId,
        p.document_id     AS DocumentId,
        d.document_code   AS DocumentCode,
        d.document_name   AS DocumentName,
        d.version_number  AS VersionNumber,
        d.next_review_date AS NextReviewDate,
        p.cycle_no        AS CycleNo,
        p.entered_dt      AS QueuedOn,
        COUNT(*) OVER ()  AS TotalRows
      FROM pending p
      JOIN grac_practice.document_upload d ON d.document_id = p.document_id
     ORDER BY p.entered_dt DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- 2. sp_document_ack_create
--
-- Rolls one or more pending rows into a batch:
--   * inserts a document_acknowledgement (batch master)
--   * inserts one document_acknowledgement_document per pending row
--   * for each document, inserts document_acknowledgement_user rows for
--     every employee in the doc's distribution (department or user based)
--   * marks the pending rows as Processed and points them at the batch
--
-- @pending_ids is a comma-separated list of pending_id values. All
-- must belong to the same organization or the call errors out.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_ack_create
    @organization_id     BIGINT,
    @acknowledgement_name NVARCHAR(200),
    @due_date            DATE           = NULL,
    @pending_ids         NVARCHAR(MAX),      -- CSV of pending_id
    @caller_employee_id  BIGINT         = NULL,
    @caller_display_name NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 52751, 'sp_document_ack_create: organization_id is required.', 1;
    IF @acknowledgement_name IS NULL OR LEN(LTRIM(RTRIM(@acknowledgement_name))) = 0
        THROW 52752, 'sp_document_ack_create: acknowledgement_name is required.', 1;
    IF @pending_ids IS NULL OR LEN(LTRIM(RTRIM(@pending_ids))) = 0
        THROW 52753, 'sp_document_ack_create: pick at least one pending document.', 1;

    DECLARE @active_rs_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
    IF @active_rs_id IS NULL
        THROW 52754, 'sp_document_ack_create: record_status_master.Active missing.', 1;

    -- Parse and validate the pending id list.
    DECLARE @ids TABLE (pending_id BIGINT PRIMARY KEY);
    INSERT INTO @ids(pending_id)
    SELECT DISTINCT TRY_CAST(value AS BIGINT)
      FROM STRING_SPLIT(@pending_ids, N',')
     WHERE TRY_CAST(value AS BIGINT) IS NOT NULL;

    IF NOT EXISTS(SELECT 1 FROM @ids)
        THROW 52755, 'sp_document_ack_create: pending_ids parsed to zero valid ids.', 1;

    -- Every id must be Open and belong to a document in this organization.
    IF EXISTS (
        SELECT 1
          FROM @ids i
     LEFT JOIN grac_practice.document_acknowledgement_pending p ON p.pending_id = i.pending_id
     LEFT JOIN grac_practice.document_upload d ON d.document_id = p.document_id
         WHERE p.pending_id IS NULL
            OR p.status_code    <> N'Open'
            OR d.organization_id <> @organization_id )
        THROW 52756, 'sp_document_ack_create: one or more pending ids are invalid, already processed, or belong to a different organization.', 1;

    BEGIN TRAN;

    -- Master row -----------------------------------------------------
    INSERT INTO grac_practice.document_acknowledgement
        (organization_id, acknowledgement_name, due_date,
         status_code, record_status_id, entered_by, entered_dt)
    VALUES
        (@organization_id, @acknowledgement_name, @due_date,
         N'Open', @active_rs_id, @caller_display_name, SYSUTCDATETIME());

    DECLARE @batch_id BIGINT = SCOPE_IDENTITY();

    -- Document rows -------------------------------------------------
    INSERT INTO grac_practice.document_acknowledgement_document
        (acknowledgement_id, document_id, cycle_no, entered_by, entered_dt)
    SELECT @batch_id, p.document_id, p.cycle_no, @caller_display_name, SYSUTCDATETIME()
      FROM grac_practice.document_acknowledgement_pending p
      JOIN @ids i ON i.pending_id = p.pending_id;

    -- User rows -----------------------------------------------------
    -- For each document in the batch, fan out to the recipient employees
    -- based on distribution_type: 'Organization' -> every active employee,
    -- 'Departments' -> employees whose department matches, 'Users' -> the
    -- named employees. Duplicates within a batch are impossible thanks to
    -- the UNIQUE constraint; INSERT ... SELECT DISTINCT guards the input.
    ;WITH batch_docs AS (
        SELECT p.document_id
          FROM grac_practice.document_acknowledgement_pending p
          JOIN @ids i ON i.pending_id = p.pending_id
    ),
    doc_recipients AS (
        -- Organization -> every active employee
        SELECT bd.document_id, e.employee_id
          FROM batch_docs bd
          JOIN grac_practice.document_upload d ON d.document_id = bd.document_id
          JOIN grac_practice.document_distribution_type_master dt
                ON dt.distribution_type_id = d.distribution_type_id
               AND dt.distribution_code    = N'Organization'
          JOIN grac_practice.organization_employee e
                ON e.organization_id = d.organization_id
          JOIN grac_practice.record_status_master r ON r.record_status_id = e.record_status_id
         WHERE r.status_code = N'Active'
        UNION
        -- Departments -> employees whose department name matches
        SELECT bd.document_id, e.employee_id
          FROM batch_docs bd
          JOIN grac_practice.document_upload d ON d.document_id = bd.document_id
          JOIN grac_practice.document_distribution_type_master dt
                ON dt.distribution_type_id = d.distribution_type_id
               AND dt.distribution_code    = N'Departments'
          JOIN grac_practice.document_upload_distribution_department dud
                ON dud.document_id = d.document_id
          JOIN grac_practice.record_status_master rd ON rd.record_status_id = dud.record_status_id
                AND rd.status_code = N'Active'
          JOIN grac_practice.organization_department od
                ON od.department_id = dud.department_id
          JOIN grac_practice.organization_employee e
                ON e.organization_id = d.organization_id
               AND e.department      = od.department_name
          JOIN grac_practice.record_status_master re ON re.record_status_id = e.record_status_id
                AND re.status_code = N'Active'
        UNION
        -- Users -> the named employees
        SELECT bd.document_id, due.employee_id
          FROM batch_docs bd
          JOIN grac_practice.document_upload d ON d.document_id = bd.document_id
          JOIN grac_practice.document_distribution_type_master dt
                ON dt.distribution_type_id = d.distribution_type_id
               AND dt.distribution_code    = N'Users'
          JOIN grac_practice.document_upload_distribution_employee due
                ON due.document_id = d.document_id
          JOIN grac_practice.record_status_master rd ON rd.record_status_id = due.record_status_id
                AND rd.status_code = N'Active'
    )
    INSERT INTO grac_practice.document_acknowledgement_user
        (acknowledgement_id, document_id, employee_id, status_code, entered_by, entered_dt)
    SELECT DISTINCT @batch_id, r.document_id, r.employee_id, N'Pending',
           @caller_display_name, SYSUTCDATETIME()
      FROM doc_recipients r;

    -- Mark pending rows as processed and link them to the batch.
    UPDATE p
       SET status_code   = N'Processed',
           batch_id      = @batch_id,
           processed_by  = @caller_employee_id,
           processed_dt  = SYSUTCDATETIME()
      FROM grac_practice.document_acknowledgement_pending p
      JOIN @ids i ON i.pending_id = p.pending_id;

    COMMIT;

    SELECT @batch_id AS AcknowledgementId;
END
GO

-- =====================================================================
-- 3. sp_document_ack_list
--
-- Admin dashboard: every batch in the organisation, with progress
-- counts (users completed / total, %). status_code auto-transitions to
-- Completed here for display only when every user row is 'Acknowledged';
-- the underlying status_code is not mutated by this list proc.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_ack_list
    @organization_id BIGINT,
    @page_number     INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 52757, 'sp_document_ack_list: organization_id is required.', 1;

    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    ;WITH counts AS (
        SELECT
            a.acknowledgement_id,
            COUNT(DISTINCT ad.document_id)                                              AS DocumentCount,
            COUNT(u.acknowledgement_user_id)                                            AS UserCount,
            SUM(CASE WHEN u.status_code = N'Acknowledged' THEN 1 ELSE 0 END)            AS AckCount
          FROM grac_practice.document_acknowledgement a
     LEFT JOIN grac_practice.document_acknowledgement_document ad
                ON ad.acknowledgement_id = a.acknowledgement_id
     LEFT JOIN grac_practice.document_acknowledgement_user u
                ON u.acknowledgement_id = a.acknowledgement_id
         WHERE a.organization_id = @organization_id
         GROUP BY a.acknowledgement_id
    )
    SELECT
        a.acknowledgement_id   AS AcknowledgementId,
        a.acknowledgement_name AS AcknowledgementName,
        a.due_date             AS DueDate,
        a.status_code          AS StatusCode,
        c.DocumentCount        AS DocumentCount,
        c.UserCount            AS UserCount,
        c.AckCount             AS AckCount,
        CASE
            WHEN c.UserCount IS NULL OR c.UserCount = 0 THEN 0
            ELSE CAST(c.AckCount * 100.0 / c.UserCount AS DECIMAL(6,2))
        END                    AS CompletionPct,
        CASE
            WHEN c.UserCount > 0 AND c.AckCount = c.UserCount THEN N'Completed'
            WHEN c.UserCount > 0 AND c.AckCount > 0            THEN N'In Progress'
            ELSE                                                    N'Pending'
        END                    AS ProgressLabel,
        a.entered_dt           AS CreatedOn,
        a.entered_by           AS CreatedBy,
        COUNT(*) OVER ()       AS TotalRows
      FROM grac_practice.document_acknowledgement a
      JOIN counts c ON c.acknowledgement_id = a.acknowledgement_id
     WHERE a.organization_id = @organization_id
     ORDER BY a.entered_dt DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- 4. sp_document_ack_documents_list
--    Docs inside a batch, one row per doc, with progress.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_ack_documents_list
    @acknowledgement_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @acknowledgement_id IS NULL
        THROW 52758, 'sp_document_ack_documents_list: acknowledgement_id is required.', 1;

    SELECT
        ad.document_id       AS DocumentId,
        d.document_code      AS DocumentCode,
        d.document_name      AS DocumentName,
        d.version_number     AS VersionNumber,
        ad.cycle_no          AS CycleNo,
        COUNT(u.acknowledgement_user_id) AS UserCount,
        SUM(CASE WHEN u.status_code = N'Acknowledged' THEN 1 ELSE 0 END) AS AckCount,
        CASE
            WHEN COUNT(u.acknowledgement_user_id) = 0 THEN 0
            ELSE CAST(SUM(CASE WHEN u.status_code = N'Acknowledged' THEN 1 ELSE 0 END) * 100.0
                      / COUNT(u.acknowledgement_user_id) AS DECIMAL(6,2))
        END AS CompletionPct,
        CASE
            WHEN COUNT(u.acknowledgement_user_id) = 0 THEN N'Pending'
            WHEN SUM(CASE WHEN u.status_code = N'Acknowledged' THEN 1 ELSE 0 END)
               = COUNT(u.acknowledgement_user_id) THEN N'Completed'
            WHEN SUM(CASE WHEN u.status_code = N'Acknowledged' THEN 1 ELSE 0 END) > 0
                THEN N'In Progress'
            ELSE N'Pending'
        END AS ProgressLabel
      FROM grac_practice.document_acknowledgement_document ad
      JOIN grac_practice.document_upload d ON d.document_id = ad.document_id
 LEFT JOIN grac_practice.document_acknowledgement_user u
        ON u.acknowledgement_id = ad.acknowledgement_id
       AND u.document_id        = ad.document_id
     WHERE ad.acknowledgement_id = @acknowledgement_id
     GROUP BY ad.document_id, d.document_code, d.document_name, d.version_number, ad.cycle_no
     ORDER BY d.document_code;
END
GO

-- =====================================================================
-- 5. sp_document_ack_document_users_list
--    Users tied to one document in one batch, with their status.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_ack_document_users_list
    @acknowledgement_id BIGINT,
    @document_id        BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @acknowledgement_id IS NULL OR @document_id IS NULL
        THROW 52759, 'sp_document_ack_document_users_list: acknowledgement_id and document_id are required.', 1;

    SELECT
        u.employee_id      AS EmployeeId,
        e.employee_code    AS EmployeeCode,
        e.employee_name    AS EmployeeName,
        e.email            AS Email,
        u.status_code      AS StatusCode,
        u.acknowledged_dt  AS AcknowledgedOn,
        u.remark           AS Remark
      FROM grac_practice.document_acknowledgement_user u
      JOIN grac_practice.organization_employee e ON e.employee_id = u.employee_id
     WHERE u.acknowledgement_id = @acknowledgement_id
       AND u.document_id        = @document_id
     ORDER BY u.status_code, e.employee_name;
END
GO

-- =====================================================================
-- 6. sp_document_upload_workflow_transition  (REWRITE)
--
-- Same public shape as the 147 version. The only behavioural change:
-- when Approve-Approve moves a document to Published AND the document
-- has acknowledgement_required = 1, insert a corresponding row into
-- document_acknowledgement_pending so the admin sees it in the "waiting
-- for a batch" queue. Idempotent -- the UNIQUE(document, cycle) key
-- prevents a duplicate row on repeated approvals of the same cycle.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_upload_workflow_transition
    @document_id          BIGINT,
    @transition           NVARCHAR(20),
    @decision             NVARCHAR(20) = N'Approve',
    @remark               NVARCHAR(MAX) = NULL,
    @caller_employee_id   BIGINT        = NULL,
    @caller_display_name  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @document_id IS NULL
        THROW 52740, 'sp_document_upload_workflow_transition: document_id is required.', 1;
    IF @transition IS NULL OR @transition NOT IN (N'Review', N'Approve')
        THROW 52741, 'sp_document_upload_workflow_transition: transition must be Review or Approve.', 1;
    IF @decision IS NULL OR @decision NOT IN (N'Approve', N'Reject')
        THROW 52742, 'sp_document_upload_workflow_transition: decision must be Approve or Reject.', 1;

    DECLARE @cur_stage_id INT, @ack_required BIT, @active_rs_id INT;
    SELECT @cur_stage_id  = current_stage_id,
           @ack_required  = acknowledgement_required
      FROM grac_practice.document_upload
     WHERE document_id = @document_id;
    IF @cur_stage_id IS NULL
        THROW 52743, 'sp_document_upload_workflow_transition: document not found.', 1;

    DECLARE @cur_stage_code NVARCHAR(60) =
        (SELECT stage_code FROM grac_practice.document_stage_master WHERE document_stage_id = @cur_stage_id);

    DECLARE @next_stage_code NVARCHAR(60) = NULL;
    IF @transition = N'Review' AND @cur_stage_code = N'Draft'
        SET @next_stage_code = CASE WHEN @decision = N'Approve' THEN N'Reviewed' ELSE N'Draft' END;
    ELSE IF @transition = N'Approve' AND @cur_stage_code = N'Reviewed'
        SET @next_stage_code = CASE WHEN @decision = N'Approve' THEN N'Published' ELSE N'Draft' END;

    IF @next_stage_code IS NULL
        THROW 52744, 'sp_document_upload_workflow_transition: transition not allowed from the current stage.', 1;

    DECLARE @next_stage_id INT =
        (SELECT document_stage_id FROM grac_practice.document_stage_master WHERE stage_code = @next_stage_code);
    IF @next_stage_id IS NULL
        THROW 52745, 'sp_document_upload_workflow_transition: target stage missing from seed (run 148).', 1;

    SELECT @active_rs_id = record_status_id
      FROM grac_practice.record_status_master WHERE status_code = N'Active';

    DECLARE @change_reason NVARCHAR(60) = CONCAT(@transition, N'-', @decision);

    BEGIN TRAN;

    UPDATE grac_practice.document_upload
       SET current_stage_id = @next_stage_id,
           reviewed_by      = CASE WHEN @transition = N'Review'  THEN @caller_employee_id ELSE reviewed_by END,
           reviewed_on      = CASE WHEN @transition = N'Review'  THEN SYSUTCDATETIME()    ELSE reviewed_on END,
           review_remark    = CASE WHEN @transition = N'Review'  THEN @remark              ELSE review_remark END,
           approved_by      = CASE WHEN @transition = N'Approve' AND @decision = N'Approve' THEN @caller_employee_id ELSE approved_by END,
           approved_on      = CASE WHEN @transition = N'Approve' AND @decision = N'Approve' THEN SYSUTCDATETIME()    ELSE approved_on END,
           approved_remark  = CASE WHEN @transition = N'Approve' THEN @remark              ELSE approved_remark END,
           updated_by       = @caller_display_name,
           updated_dt       = SYSUTCDATETIME()
     WHERE document_id = @document_id;

    INSERT INTO grac_practice.document_upload_history
        (document_id, change_reason,
         from_stage_id, to_stage_id,
         actor_employee_id, remark, acted_by, acted_dt)
    VALUES
        (@document_id, @change_reason,
         @cur_stage_id, @next_stage_id,
         @caller_employee_id, @remark, @caller_display_name, SYSUTCDATETIME());

    -- Auto-enqueue for acknowledgement -------------------------------
    -- Only on Approve-Approve (Published) AND if the doc requires it.
    -- cycle_no = 1 for the first publish; a re-publish flow (Phase 3)
    -- will bump the cycle. UNIQUE(document_id, cycle_no) makes this
    -- safe against a double-fire from the same action.
    IF @transition = N'Approve' AND @decision = N'Approve' AND @ack_required = 1
    BEGIN
        DECLARE @cycle INT =
            ISNULL((SELECT MAX(cycle_no) + 1
                      FROM grac_practice.document_acknowledgement_pending
                     WHERE document_id = @document_id), 1);

        IF NOT EXISTS (
            SELECT 1 FROM grac_practice.document_acknowledgement_pending
             WHERE document_id = @document_id AND cycle_no = @cycle)
        BEGIN
            INSERT INTO grac_practice.document_acknowledgement_pending
                (document_id, cycle_no, status_code,
                 record_status_id, entered_by, entered_dt)
            VALUES
                (@document_id, @cycle, N'Open',
                 @active_rs_id, @caller_display_name, SYSUTCDATETIME());
        END
    END

    COMMIT;

    SELECT @document_id      AS DocumentId,
           @next_stage_id    AS StageId,
           @next_stage_code  AS StageCode;
END
GO

-- End 151 =============================================================
