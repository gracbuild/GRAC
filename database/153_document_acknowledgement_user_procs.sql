-- =====================================================================
-- 153 Document Acknowledgement -- user-side procedures (Phase 3)
--
-- SURFACE
-- -------
--   grac_practice.sp_document_ack_user_batches
--       Batches that have at least one row assigned to @employee_id.
--       Returns per-batch progress and per-user progress (how many of
--       MY rows in this batch are still pending).
--
--   grac_practice.sp_document_ack_user_documents
--       Documents in a batch that are assigned to @employee_id, plus
--       my status (Pending / Acknowledged) and acknowledged_dt.
--
--   grac_practice.sp_document_ack_user_ack
--       The Acknowledge action itself. Flips status to 'Acknowledged',
--       stamps the timestamp, records a remark. If the batch has no
--       remaining pending rows after this, the batch is auto-closed
--       (status_code = 'Completed').
--
-- ERROR CODE RANGE: 52800-52820  (151 used 52750-52759).
--
-- DEPENDS ON: 146, 150. Rollback: 153_document_acknowledgement_user_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.document_acknowledgement_user','U') IS NULL
BEGIN
    RAISERROR('153: document_acknowledgement_user is missing. Run 150 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_document_ack_user_batches
--
-- One row per batch that has at least one document assigned to
-- @employee_id. Shows my personal progress (MyDocCount / MyAckCount)
-- alongside the batch's total progress so the user sees "you have
-- N left" without loading the docs.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_ack_user_batches
    @employee_id       BIGINT       = NULL,   -- required when @is_admin = 0
    @include_completed BIT          = 0,       -- 0: only batches with pending rows; 1: everything
    @is_admin          BIT          = 0,       -- 1: ignore employee filter, aggregate across all users
    @organization_id   BIGINT       = NULL    -- required when @is_admin = 1 (org scope)
AS
BEGIN
    SET NOCOUNT ON;

    IF @is_admin = 0 AND @employee_id IS NULL
        THROW 52800, 'sp_document_ack_user_batches: employee_id is required (or set @is_admin=1 with @organization_id).', 1;
    IF @is_admin = 1 AND @organization_id IS NULL
        THROW 52804, 'sp_document_ack_user_batches: organization_id is required when @is_admin=1.', 1;

    ;WITH scoped_rows AS (
        SELECT u.acknowledgement_id, u.document_id, u.status_code
          FROM grac_practice.document_acknowledgement_user u
          JOIN grac_practice.document_acknowledgement       a ON a.acknowledgement_id = u.acknowledgement_id
         WHERE (@is_admin = 0 AND u.employee_id = @employee_id)
            OR (@is_admin = 1 AND a.organization_id = @organization_id)
    ),
    per_batch AS (
        SELECT acknowledgement_id,
               COUNT(DISTINCT document_id)                                    AS MyDocCount,
               SUM(CASE WHEN status_code = N'Acknowledged' THEN 1 ELSE 0 END) AS MyAckCount,
               SUM(CASE WHEN status_code = N'Pending'      THEN 1 ELSE 0 END) AS MyPendingCount
          FROM scoped_rows
         GROUP BY acknowledgement_id
    )
    SELECT
        a.acknowledgement_id   AS AcknowledgementId,
        a.acknowledgement_name AS AcknowledgementName,
        a.due_date             AS DueDate,
        a.status_code          AS BatchStatusCode,
        pb.MyDocCount          AS MyDocCount,     -- in admin mode: total distinct docs across users
        pb.MyAckCount          AS MyAckCount,     -- in admin mode: total Acknowledged assignments
        pb.MyPendingCount      AS MyPendingCount, -- in admin mode: total Pending assignments
        CASE
            WHEN pb.MyDocCount = 0 THEN 0
            ELSE CAST(pb.MyAckCount * 100.0 /
                      NULLIF(pb.MyAckCount + pb.MyPendingCount, 0) AS DECIMAL(6,2))
        END                    AS MyCompletionPct,
        CASE
            WHEN pb.MyPendingCount = 0 THEN N'Completed'
            WHEN pb.MyAckCount > 0     THEN N'In Progress'
            ELSE                             N'Pending'
        END                    AS MyStatusLabel,
        a.entered_dt           AS CreatedOn
      FROM grac_practice.document_acknowledgement a
      JOIN per_batch pb ON pb.acknowledgement_id = a.acknowledgement_id
     WHERE (@include_completed = 1 OR pb.MyPendingCount > 0)
     ORDER BY
        CASE WHEN pb.MyPendingCount > 0 THEN 0 ELSE 1 END,    -- outstanding first
        a.due_date ASC,
        a.entered_dt DESC;
END
GO

-- =====================================================================
-- 2. sp_document_ack_user_documents
--
-- Documents in a batch assigned to @employee_id, with per-doc status
-- for that user. Includes basic doc metadata so the client does not
-- need a second call to render each row.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_ack_user_documents
    @acknowledgement_id BIGINT,
    @employee_id        BIGINT = NULL,   -- required when @is_admin = 0
    @is_admin           BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @acknowledgement_id IS NULL
        THROW 52801, 'sp_document_ack_user_documents: acknowledgement_id is required.', 1;
    IF @is_admin = 0 AND @employee_id IS NULL
        THROW 52805, 'sp_document_ack_user_documents: employee_id is required (or set @is_admin=1).', 1;

    -- Admin mode: one row per (document, employee) so every assignment shows
    -- with the employee name, status, and timestamp -- effectively the
    -- "who has and hasn't acknowledged" table for the batch. The unified
    -- shape uses EmployeeName in the DocumentName column for admin rows
    -- via a computed extra field (rendered in the client).
    SELECT
        u.acknowledgement_user_id AS AcknowledgementUserId,
        u.acknowledgement_id      AS AcknowledgementId,
        a.acknowledgement_name    AS AcknowledgementName,
        a.due_date                AS DueDate,
        u.document_id             AS DocumentId,
        d.document_code           AS DocumentCode,
        d.document_name           AS DocumentName,
        d.version_number          AS VersionNumber,
        d.next_review_date        AS NextReviewDate,
        u.status_code             AS StatusCode,
        u.acknowledged_dt         AS AcknowledgedOn,
        u.remark                  AS Remark,
        u.employee_id             AS EmployeeId,
        e.employee_name           AS EmployeeName,
        e.employee_code           AS EmployeeCode,
        e.email                   AS EmployeeEmail
      FROM grac_practice.document_acknowledgement_user u
      JOIN grac_practice.document_acknowledgement      a  ON a.acknowledgement_id = u.acknowledgement_id
      JOIN grac_practice.document_upload               d  ON d.document_id       = u.document_id
      JOIN grac_practice.organization_employee         e  ON e.employee_id       = u.employee_id
     WHERE u.acknowledgement_id = @acknowledgement_id
       AND ( @is_admin = 1 OR u.employee_id = @employee_id )
     ORDER BY d.document_code,
              CASE WHEN u.status_code = N'Pending' THEN 0 ELSE 1 END,
              e.employee_name;
END
GO

-- =====================================================================
-- 3. sp_document_ack_user_ack
--
-- Mark ONE (batch, document, employee) row as Acknowledged. Idempotent
-- from the DB's perspective: acknowledging a row that is already
-- Acknowledged is a no-op (no double-update, no error). If the batch
-- has zero Pending user rows after this action, the batch's status_code
-- is flipped to 'Completed' so admin dashboards see the transition
-- without a nightly job.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_ack_user_ack
    @acknowledgement_id BIGINT,
    @document_id        BIGINT,
    @employee_id        BIGINT,
    @remark             NVARCHAR(MAX) = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @acknowledgement_id IS NULL OR @document_id IS NULL OR @employee_id IS NULL
        THROW 52802, 'sp_document_ack_user_ack: acknowledgement_id, document_id and employee_id are required.', 1;

    -- Confirm the row exists and belongs to this employee.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.document_acknowledgement_user
         WHERE acknowledgement_id = @acknowledgement_id
           AND document_id        = @document_id
           AND employee_id        = @employee_id)
        THROW 52803, 'sp_document_ack_user_ack: no matching assignment found (caller cannot acknowledge on behalf of another user).', 1;

    BEGIN TRAN;

    -- Idempotent flip. Only touch Pending rows so a re-submit is a no-op.
    UPDATE grac_practice.document_acknowledgement_user
       SET status_code     = N'Acknowledged',
           acknowledged_dt = SYSUTCDATETIME(),
           remark          = COALESCE(NULLIF(LTRIM(RTRIM(@remark)), N''), remark)
     WHERE acknowledgement_id = @acknowledgement_id
       AND document_id        = @document_id
       AND employee_id        = @employee_id
       AND status_code        = N'Pending';

    -- If the batch has zero Pending rows now, mark the batch Completed.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.document_acknowledgement_user
         WHERE acknowledgement_id = @acknowledgement_id
           AND status_code        = N'Pending')
    BEGIN
        UPDATE grac_practice.document_acknowledgement
           SET status_code = N'Completed',
               updated_by  = @caller_display_name,
               updated_dt  = SYSUTCDATETIME()
         WHERE acknowledgement_id = @acknowledgement_id
           AND status_code       <> N'Completed';
    END

    COMMIT;

    SELECT @acknowledgement_id AS AcknowledgementId,
           @document_id        AS DocumentId,
           @employee_id        AS EmployeeId,
           N'Acknowledged'     AS StatusCode,
           SYSUTCDATETIME()    AS AcknowledgedOn;
END
GO

-- End 153 =============================================================
