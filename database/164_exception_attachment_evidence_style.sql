-- =====================================================================
-- 164 Exception Centre -- attachment gets evidence-style capture
--
-- Aligns the exception approval attachment with PM's evidence pattern
-- (practice_instance_evidence in schema 001). Two capture modes:
--
--   * Manual    -- upload a file (existing behaviour). file_name +
--                  file_data required; location/locator optional.
--   * Automated -- point at where the approval lives in another
--                  system. evidence_location + evidence_locator
--                  required; file_data optional.
--
-- WHY THIS SHAPE
-- --------------
-- The exception approval MAY be a scanned memo (Manual), OR a link to
-- an existing approval workflow in ServiceNow, DocuSign, SharePoint,
-- etc. (Automated). Mirroring evidence keeps the vocabulary consistent
-- across the platform and lets ops reuse collection_method_master.
--
-- MIGRATION IS ADDITIVE:
--   * columns are added guarded with COL_LENGTH IS NULL
--   * file_data + file_name loosened to NULL (existing rows survive)
--   * existing rows are backfilled to collection_method='Manual'
--
-- Rollback: 164_exception_attachment_evidence_style_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.exception_request_attachment','U') IS NULL
   OR OBJECT_ID('grac_practice.collection_method_master','U') IS NULL
BEGIN
    RAISERROR('164: prerequisites missing. Run 161 and 001 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. ADD new columns (guarded)
-- =====================================================================
IF COL_LENGTH('grac_practice.exception_request_attachment','collection_method_id') IS NULL
    ALTER TABLE grac_practice.exception_request_attachment
        ADD collection_method_id INT NULL
            CONSTRAINT fk_pm_exception_attachment_collection_method
                REFERENCES grac_practice.collection_method_master(collection_method_id);
GO

IF COL_LENGTH('grac_practice.exception_request_attachment','evidence_location') IS NULL
    ALTER TABLE grac_practice.exception_request_attachment
        ADD evidence_location NVARCHAR(500) NULL;
GO

IF COL_LENGTH('grac_practice.exception_request_attachment','evidence_locator') IS NULL
    ALTER TABLE grac_practice.exception_request_attachment
        ADD evidence_locator NVARCHAR(500) NULL;
GO

-- =====================================================================
-- 2. LOOSEN file_data + file_name to NULLable
-- =====================================================================
-- Drop the NOT NULL constraints by re-declaring the columns as NULLable.
IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('grac_practice.exception_request_attachment')
              AND name = N'file_data' AND is_nullable = 0)
    ALTER TABLE grac_practice.exception_request_attachment
        ALTER COLUMN file_data VARBINARY(MAX) NULL;
GO

IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('grac_practice.exception_request_attachment')
              AND name = N'file_name' AND is_nullable = 0)
    ALTER TABLE grac_practice.exception_request_attachment
        ALTER COLUMN file_name NVARCHAR(500) NULL;
GO

-- =====================================================================
-- 3. Backfill existing rows -> Manual (they were file uploads)
-- =====================================================================
DECLARE @manual_id INT =
    (SELECT TOP 1 collection_method_id FROM grac_practice.collection_method_master
      WHERE collection_method_code = N'Manual');
IF @manual_id IS NOT NULL
    UPDATE grac_practice.exception_request_attachment
       SET collection_method_id = @manual_id
     WHERE collection_method_id IS NULL;
GO

-- =====================================================================
-- 4. REWRITE sp_exception_request_attachment_save
--    Accepts @collection_method_code (Manual | Automated), and
--    conditionally requires either file_data or location+locator.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_attachment_save
    @exception_request_id    BIGINT,
    @collection_method_code  NVARCHAR(60)   = N'Manual',
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

    IF @exception_request_id IS NULL
        THROW 55250, 'sp_exception_request_attachment_save: exception_request_id is required.', 1;
    IF NOT EXISTS(SELECT 1 FROM grac_practice.exception_request WHERE exception_request_id = @exception_request_id)
        THROW 55253, 'sp_exception_request_attachment_save: request not found.', 1;

    IF @collection_method_code IS NULL OR LEN(LTRIM(RTRIM(@collection_method_code))) = 0
        SET @collection_method_code = N'Manual';

    DECLARE @method_id INT =
        (SELECT TOP 1 collection_method_id FROM grac_practice.collection_method_master
          WHERE collection_method_code = @collection_method_code);
    IF @method_id IS NULL
        THROW 55254, 'sp_exception_request_attachment_save: unknown collection_method_code (expected Manual or Automated).', 1;

    IF @collection_method_code = N'Manual'
    BEGIN
        IF @file_data IS NULL OR DATALENGTH(@file_data) = 0
            THROW 55251, 'sp_exception_request_attachment_save: Manual attachment requires file_data.', 1;
        IF @file_name IS NULL OR LEN(LTRIM(RTRIM(@file_name))) = 0
            THROW 55252, 'sp_exception_request_attachment_save: Manual attachment requires file_name.', 1;
    END
    ELSE  -- Automated (or any other non-Manual method that ever gets added)
    BEGIN
        IF @evidence_location IS NULL OR LEN(LTRIM(RTRIM(@evidence_location))) = 0
            THROW 55255, 'sp_exception_request_attachment_save: Automated attachment requires evidence_location.', 1;
        IF @evidence_locator IS NULL OR LEN(LTRIM(RTRIM(@evidence_locator))) = 0
            THROW 55256, 'sp_exception_request_attachment_save: Automated attachment requires evidence_locator.', 1;
    END

    INSERT INTO grac_practice.exception_request_attachment
        (exception_request_id, collection_method_id,
         file_name, content_type, file_size_bytes, file_data,
         evidence_location, evidence_locator,
         uploaded_by_employee_id, uploaded_dt)
    VALUES
        (@exception_request_id, @method_id,
         @file_name, @content_type,
         CASE WHEN @file_data IS NULL THEN 0 ELSE DATALENGTH(@file_data) END,
         @file_data,
         @evidence_location, @evidence_locator,
         @uploaded_by_employee_id, SYSUTCDATETIME());

    DECLARE @att_id BIGINT = SCOPE_IDENTITY();

    INSERT INTO grac_practice.exception_request_history
        (exception_request_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@exception_request_id, N'AttachmentUpload', NULL, NULL,
         CONCAT(N'[', @collection_method_code, N'] ',
                COALESCE(@file_name, CONCAT(@evidence_location, N': ', @evidence_locator))),
         @uploaded_by_employee_id, @caller_display_name,
         @caller_display_name, SYSUTCDATETIME());

    SELECT @att_id AS AttachmentId;
END
GO

-- =====================================================================
-- 5. REWRITE sp_exception_request_attachment_get
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_attachment_get
    @attachment_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @attachment_id IS NULL
        THROW 55260, 'sp_exception_request_attachment_get: attachment_id is required.', 1;

    SELECT
        a.attachment_id            AS AttachmentId,
        a.exception_request_id     AS ExceptionRequestId,
        cm.collection_method_code  AS CollectionMethodCode,
        cm.collection_method_name  AS CollectionMethodName,
        a.file_name                AS FileName,
        a.content_type             AS ContentType,
        a.file_size_bytes          AS FileSizeBytes,
        a.file_data                AS FileData,
        a.evidence_location        AS EvidenceLocation,
        a.evidence_locator         AS EvidenceLocator,
        a.uploaded_dt              AS UploadedOn
      FROM grac_practice.exception_request_attachment a
 LEFT JOIN grac_practice.collection_method_master cm ON cm.collection_method_id = a.collection_method_id
     WHERE a.attachment_id = @attachment_id;
END
GO

-- =====================================================================
-- 6. REWRITE sp_exception_request_attachment_list
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
        cm.collection_method_code AS CollectionMethodCode,
        cm.collection_method_name AS CollectionMethodName,
        a.file_name               AS FileName,
        a.content_type            AS ContentType,
        a.file_size_bytes         AS FileSizeBytes,
        a.evidence_location       AS EvidenceLocation,
        a.evidence_locator        AS EvidenceLocator,
        a.uploaded_by_employee_id AS UploadedByEmployeeId,
        e.employee_name           AS UploadedByName,
        a.uploaded_dt             AS UploadedOn
      FROM grac_practice.exception_request_attachment a
 LEFT JOIN grac_practice.collection_method_master cm ON cm.collection_method_id = a.collection_method_id
 LEFT JOIN grac_practice.organization_employee e ON e.employee_id = a.uploaded_by_employee_id
     WHERE a.exception_request_id = @exception_request_id
     ORDER BY a.uploaded_dt DESC;
END
GO

PRINT '164 Exception attachment evidence-style ready.';
GO
