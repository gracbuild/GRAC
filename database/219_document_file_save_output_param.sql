-- =====================================================================
-- 219 sp_document_file_save -- return the new id via OUTPUT, not a SELECT
--
-- SYMPTOM
-- -------
-- Document Uploads -> New Document -> fill the form, attach a file, Save.
-- The document IS created (it appears in the register after a refresh),
-- but the browser shows a message box containing the single word
--
--     DocumentId
--
-- and the save page does not close.
--
-- CAUSE
-- -----
-- The chain, end to end:
--
--   grac_practice.sp_document_upload_save (@mode = 'New')
--     -> EXEC grac_practice.sp_document_file_save          (line 777 of 147)
--          ... INSERT INTO document_upload_file ...
--          SELECT SCOPE_IDENTITY() AS DocumentFileId;      <-- result set 1
--     -> COMMIT
--     -> SELECT @new_document_id AS DocumentId;            <-- result set 2
--
-- A result set produced inside a nested procedure is returned to the
-- client ahead of the outer procedure's own SELECT. So the reader in
-- DocumentUploadService.SaveAsync lands on the DocumentFileId row and
-- asks it for a "DocumentId" column:
--
--     docId = Convert.ToInt64(r["DocumentId"]);
--
-- SqlDataReader's string indexer throws IndexOutOfRangeException when the
-- column is absent, and that exception's Message is nothing but the
-- column name -- hence the message box reading "DocumentId". It is not a
-- SqlException, so the service's catch(SqlException) misses it; it
-- surfaces from DocumentUploadController's catch(Exception) as
-- HTTP 400 { success = false, error = "DocumentId" }, and
-- document-uploads.js treats that as a failed save: it alerts the text
-- and keeps the save view open.
--
-- The row order explains the exact shape of the bug report:
--   * New            -> always attaches a file -> always fails this way
--   * Edit + file    -> same
--   * Edit, no file  -> sp_document_file_save is not called, the
--                       DocumentId row is result set 1, save works
--
-- FIX
-- ---
-- A procedure that exists to be called by another procedure must not
-- emit a result set. Re-issue sp_document_file_save with the new file id
-- handed back through @document_file_id OUTPUT and the SELECT removed.
-- sp_document_upload_save then returns exactly one result set -- its own
-- DocumentId row -- in every mode.
--
-- The two EXEC sites inside sp_document_upload_save (New at line 777,
-- Edit at line 900 of 147) need no edit: the new parameter is optional
-- (defaults to NULL) and neither caller ever consumed the discarded
-- DocumentFileId row. 147 is left as shipped; this migration supersedes
-- the procedure body, so keep the two in step if 147 is ever revised.
--
-- sp_document_file_save has no caller outside sp_document_upload_save
-- today (the "replace file" endpoint the 147 header anticipates was
-- never wired). A future direct caller reads @document_file_id OUTPUT.
--
-- The Api-side change that ships with this migration
-- (DocumentUploadService seeking the result set that actually carries
-- DocumentId) is independent of the database and keeps the save page
-- working against an instance where 219 has not been applied yet.
--
-- ASCII-only on purpose (sqlcmd codepage).
-- Idempotent: CREATE OR ALTER only, no data touched.
--
-- DEPENDS ON: 146 (document_upload_file), 147 (the procedure).
-- Rollback:   database/219_document_file_save_output_param_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (219): schema grac_practice missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.sp_document_file_save','P') IS NULL
BEGIN
    PRINT 'ABORT (219): sp_document_file_save missing. Run 147_document_upload_procs.sql first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.document_upload_file','U') IS NULL
   OR OBJECT_ID('grac_practice.document_upload','U') IS NULL
BEGIN
    PRINT 'ABORT (219): document_upload or document_upload_file missing. Run 146_document_upload_schema.sql first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('219_document_file_save_output_param: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_document_file_save -- re-issued from the 147 body with
-- @document_file_id OUTPUT replacing the trailing SELECT. Validation,
-- the is_current flip and the INSERT are byte-for-byte the 147 versions.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_file_save
    @document_id      BIGINT,
    @version_number   NVARCHAR(30),
    @file_name        NVARCHAR(500),
    @content_type     NVARCHAR(200) = NULL,
    @file_data        VARBINARY(MAX),
    @uploaded_by      BIGINT        = NULL,
    @document_file_id BIGINT        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @document_file_id = NULL;

    IF @document_id IS NULL
        THROW 52707, 'sp_document_file_save: document_id is required.', 1;
    IF @file_data IS NULL OR DATALENGTH(@file_data) = 0
        THROW 52708, 'sp_document_file_save: file_data is empty.', 1;
    IF @file_name IS NULL OR LEN(LTRIM(RTRIM(@file_name))) = 0
        THROW 52709, 'sp_document_file_save: file_name is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.document_upload WHERE document_id = @document_id)
        THROW 52710, 'sp_document_file_save: unknown document_id.', 1;

    UPDATE grac_practice.document_upload_file
       SET is_current = 0
     WHERE document_id = @document_id
       AND is_current = 1;

    INSERT INTO grac_practice.document_upload_file
        (document_id, version_number, file_name, content_type,
         file_size_bytes, file_data, is_current, uploaded_by, uploaded_dt)
    VALUES
        (@document_id, @version_number, @file_name, @content_type,
         DATALENGTH(@file_data), @file_data, 1, @uploaded_by, SYSUTCDATETIME());

    -- OUTPUT, not SELECT: this procedure is called from inside
    -- sp_document_upload_save, and a nested result set would reach the
    -- client ahead of that procedure's own DocumentId row. See the
    -- migration header.
    SET @document_file_id = SCOPE_IDENTITY();
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT 'sp_document_file_save has @document_file_id OUTPUT' AS Check_,
       CASE WHEN EXISTS (SELECT 1
                           FROM sys.parameters
                          WHERE object_id  = OBJECT_ID('grac_practice.sp_document_file_save')
                            AND name       = '@document_file_id'
                            AND is_output  = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'sp_document_file_save emits no result set',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_document_file_save'))
                 NOT LIKE '%SELECT SCOPE_IDENTITY()%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'sp_document_upload_save still present',
       CASE WHEN OBJECT_ID('grac_practice.sp_document_upload_save','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;
GO

PRINT '219 sp_document_file_save OUTPUT parameter complete.';
GO

SET NOEXEC OFF;
GO
