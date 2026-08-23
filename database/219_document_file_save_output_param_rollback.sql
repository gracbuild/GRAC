-- =====================================================================
-- 219 sp_document_file_save OUTPUT parameter -- ROLLBACK
--
-- Restores grac_practice.sp_document_file_save to the exact
-- 147_document_upload_procs.sql body: no @document_file_id OUTPUT, and
-- the trailing "SELECT SCOPE_IDENTITY() AS DocumentFileId" back in place.
--
-- Applying this rollback brings the original defect back on any client
-- that reads only the first result set of sp_document_upload_save: a
-- document created with a file attached returns the DocumentFileId row
-- first, and DocumentUploadService reports "DocumentId" as the error.
--
-- The Api-side change that shipped with 219 (SeekResultSetAsync scanning
-- forward for the result set that carries DocumentId) is unaffected by
-- this rollback -- it tolerates either procedure shape, so the save page
-- keeps working. The defect returns only for a caller that has not taken
-- that change.
--
-- No data to undo -- 219 only replaced a procedure.
--
-- ASCII-only on purpose (sqlcmd codepage).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (219 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_document_file_save
    @document_id      BIGINT,
    @version_number   NVARCHAR(30),
    @file_name        NVARCHAR(500),
    @content_type     NVARCHAR(200) = NULL,
    @file_data        VARBINARY(MAX),
    @uploaded_by      BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;

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

    SELECT SCOPE_IDENTITY() AS DocumentFileId;
END
GO

SELECT 'sp_document_file_save restored to the 147 body' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_document_file_save','P') IS NOT NULL
             AND NOT EXISTS (SELECT 1
                               FROM sys.parameters
                              WHERE object_id = OBJECT_ID('grac_practice.sp_document_file_save')
                                AND name      = '@document_file_id')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO

PRINT '219 sp_document_file_save OUTPUT parameter rollback complete.';
GO

SET NOEXEC OFF;
GO
