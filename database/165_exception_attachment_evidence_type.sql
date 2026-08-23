-- =====================================================================
-- 165 Exception Centre attachment gets evidence_type_id lookup
--
-- Adds evidence_type_id column (FK to grac_practice.evidence_type_master,
-- the existing PM master used by practice_instance_evidence). Extends
-- the save/get/list procs to accept and return the type. Adds a small
-- sp_evidence_type_list so the UI dropdown reads from the master.
--
-- Additive; existing rows leave evidence_type_id NULL.
--
-- Rollback: 165_exception_attachment_evidence_type_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.exception_request_attachment','U') IS NULL
   OR OBJECT_ID('grac_practice.evidence_type_master','U') IS NULL
BEGIN
    RAISERROR('165: prerequisites missing. Run 161 (attachment) and 001 (evidence_type_master).', 16, 1);
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.exception_request_attachment','evidence_type_id') IS NULL
    ALTER TABLE grac_practice.exception_request_attachment
        ADD evidence_type_id INT NULL
            CONSTRAINT fk_pm_exception_attachment_evidence_type
                REFERENCES grac_practice.evidence_type_master(evidence_type_id);
GO

-- =====================================================================
-- sp_evidence_type_list -- small helper for UI combos (active only).
-- Non-invasive; other modules can call it too.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_type_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        evidence_type_id   AS EvidenceTypeId,
        evidence_type_code AS EvidenceTypeCode,
        evidence_type_name AS EvidenceTypeName,
        display_order      AS SortOrder
      FROM grac_practice.evidence_type_master
     WHERE is_active = 1
     ORDER BY display_order, evidence_type_name;
END
GO

-- =====================================================================
-- REWRITE sp_exception_request_attachment_save with evidence_type_code
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_attachment_save
    @exception_request_id    BIGINT,
    @collection_method_code  NVARCHAR(60)   = N'Manual',
    @evidence_type_code      NVARCHAR(60)   = NULL,   -- optional; looked up on the master
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
        THROW 55254, 'sp_exception_request_attachment_save: unknown collection_method_code.', 1;

    DECLARE @evidence_type_id INT = NULL;
    IF @evidence_type_code IS NOT NULL AND LEN(LTRIM(RTRIM(@evidence_type_code))) > 0
    BEGIN
        SELECT @evidence_type_id = evidence_type_id
          FROM grac_practice.evidence_type_master
         WHERE evidence_type_code = @evidence_type_code;
        IF @evidence_type_id IS NULL
            THROW 55257, 'sp_exception_request_attachment_save: unknown evidence_type_code.', 1;
    END

    IF @collection_method_code = N'Manual'
    BEGIN
        IF @file_data IS NULL OR DATALENGTH(@file_data) = 0
            THROW 55251, 'sp_exception_request_attachment_save: Manual attachment requires file_data.', 1;
        IF @file_name IS NULL OR LEN(LTRIM(RTRIM(@file_name))) = 0
            THROW 55252, 'sp_exception_request_attachment_save: Manual attachment requires file_name.', 1;
    END
    ELSE
    BEGIN
        IF @evidence_location IS NULL OR LEN(LTRIM(RTRIM(@evidence_location))) = 0
            THROW 55255, 'sp_exception_request_attachment_save: Automated attachment requires evidence_location.', 1;
        IF @evidence_locator IS NULL OR LEN(LTRIM(RTRIM(@evidence_locator))) = 0
            THROW 55256, 'sp_exception_request_attachment_save: Automated attachment requires evidence_locator.', 1;
    END

    INSERT INTO grac_practice.exception_request_attachment
        (exception_request_id, collection_method_id, evidence_type_id,
         file_name, content_type, file_size_bytes, file_data,
         evidence_location, evidence_locator,
         uploaded_by_employee_id, uploaded_dt)
    VALUES
        (@exception_request_id, @method_id, @evidence_type_id,
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
         CONCAT(N'[', @collection_method_code,
                CASE WHEN @evidence_type_code IS NOT NULL THEN N' / ' + @evidence_type_code ELSE N'' END,
                N'] ',
                COALESCE(@file_name, CONCAT(@evidence_location, N': ', @evidence_locator))),
         @uploaded_by_employee_id, @caller_display_name,
         @caller_display_name, SYSUTCDATETIME());

    SELECT @att_id AS AttachmentId;
END
GO

-- =====================================================================
-- REWRITE sp_exception_request_attachment_get (add type columns)
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
        et.evidence_type_code      AS EvidenceTypeCode,
        et.evidence_type_name      AS EvidenceTypeName,
        a.file_name                AS FileName,
        a.content_type             AS ContentType,
        a.file_size_bytes          AS FileSizeBytes,
        a.file_data                AS FileData,
        a.evidence_location        AS EvidenceLocation,
        a.evidence_locator         AS EvidenceLocator,
        a.uploaded_dt              AS UploadedOn
      FROM grac_practice.exception_request_attachment a
 LEFT JOIN grac_practice.collection_method_master cm ON cm.collection_method_id = a.collection_method_id
 LEFT JOIN grac_practice.evidence_type_master     et ON et.evidence_type_id     = a.evidence_type_id
     WHERE a.attachment_id = @attachment_id;
END
GO

-- =====================================================================
-- REWRITE sp_exception_request_attachment_list (add type columns)
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
      FROM grac_practice.exception_request_attachment a
 LEFT JOIN grac_practice.collection_method_master cm ON cm.collection_method_id = a.collection_method_id
 LEFT JOIN grac_practice.evidence_type_master     et ON et.evidence_type_id     = a.evidence_type_id
 LEFT JOIN grac_practice.organization_employee    e  ON e.employee_id           = a.uploaded_by_employee_id
     WHERE a.exception_request_id = @exception_request_id
     ORDER BY a.uploaded_dt DESC;
END
GO

PRINT '165 Exception attachment + evidence_type_id ready.';
GO
