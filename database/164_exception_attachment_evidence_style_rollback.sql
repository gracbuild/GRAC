-- Restore file-only save; drop the new columns. Existing Automated rows
-- lose their location/locator (captured warning in the PRINT).
SET NOCOUNT ON;
GO
IF EXISTS (SELECT 1 FROM grac_practice.exception_request_attachment
            WHERE evidence_location IS NOT NULL OR evidence_locator IS NOT NULL)
    PRINT '164 rollback: some Automated attachments will lose their evidence_location/locator.';
GO

IF EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_exception_attachment_collection_method')
    ALTER TABLE grac_practice.exception_request_attachment DROP CONSTRAINT fk_pm_exception_attachment_collection_method;
GO
IF COL_LENGTH('grac_practice.exception_request_attachment','collection_method_id') IS NOT NULL
    ALTER TABLE grac_practice.exception_request_attachment DROP COLUMN collection_method_id;
GO
IF COL_LENGTH('grac_practice.exception_request_attachment','evidence_location') IS NOT NULL
    ALTER TABLE grac_practice.exception_request_attachment DROP COLUMN evidence_location;
GO
IF COL_LENGTH('grac_practice.exception_request_attachment','evidence_locator') IS NOT NULL
    ALTER TABLE grac_practice.exception_request_attachment DROP COLUMN evidence_locator;
GO
-- Restore the original 162 save proc (file-only)
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
        (exception_request_id, file_name, content_type, file_size_bytes, file_data,
         uploaded_by_employee_id, uploaded_dt)
    VALUES (@exception_request_id, @file_name, @content_type, DATALENGTH(@file_data), @file_data,
            @uploaded_by_employee_id, SYSUTCDATETIME());
    DECLARE @att_id BIGINT = SCOPE_IDENTITY();
    INSERT INTO grac_practice.exception_request_history
        (exception_request_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES (@exception_request_id, N'AttachmentUpload', NULL, NULL,
            CONCAT(N'Uploaded: ', @file_name),
            @uploaded_by_employee_id, @caller_display_name,
            @caller_display_name, SYSUTCDATETIME());
    SELECT @att_id AS AttachmentId;
END
GO
PRINT '164 rollback complete.';
GO
