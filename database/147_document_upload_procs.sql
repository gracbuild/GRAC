-- =====================================================================
-- 147 Document Upload -- procedures
--
-- SURFACE
-- -------
--   Lookups (read-only):
--     grac_practice.sp_document_type_list
--     grac_practice.sp_document_stage_list
--     grac_practice.sp_document_status_list
--     grac_practice.sp_document_source_type_list
--     grac_practice.sp_document_distribution_type_list
--     grac_practice.sp_organization_department_list
--     grac_practice.sp_organization_employee_by_department
--
--   Register (read):
--     grac_practice.sp_document_register_list
--     grac_practice.sp_document_details_get
--     grac_practice.sp_document_distribution_department_list
--     grac_practice.sp_document_distribution_employee_list
--     grac_practice.sp_document_file_get
--
--   Register (write):
--     grac_practice.sp_document_upload_save            (mode 1 New, 2 Edit, 3 StatusToggle)
--     grac_practice.sp_document_file_save              (re-upload / new version)
--     grac_practice.sp_document_upload_workflow_transition  (Submit, Review, Approve, Reject)
--
-- WHY THESE SHAPES
-- ----------------
--   * All procs run under `CREATE OR ALTER` -- safe to reapply on top
--     of an earlier deployment of 147 without a drop step.
--   * Errors are raised with THROW <errcode>, ..., 1 in the range
--     52700-52799 (147's allotment). Callers see structured errors, not
--     an ERROR_MESSAGE from a swallowed catch. This is the PM
--     convention (see 141's 52600 block).
--   * Callers pass @caller_employee_id from the session; procs stamp
--     audit columns from it. `entered_by` and `updated_by` accept a
--     display name because the app already resolves it once at session
--     start -- avoids a second employee lookup per write.
--   * Lookup ids are resolved by CODE, not by hard-coded integers.
--     Seed (148) is authoritative for what a stage_code / status_code
--     means; the procs stay decoupled from whichever id the identity
--     column happens to hand out.
--
-- DEPENDS ON: 146. Rollback: 147_document_upload_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Prerequisites -----------------------------------------------------
IF OBJECT_ID('grac_practice.document_upload','U') IS NULL
   OR OBJECT_ID('grac_practice.document_upload_file','U') IS NULL
   OR OBJECT_ID('grac_practice.document_upload_history','U') IS NULL
BEGIN
    RAISERROR('147: prerequisites missing. Run 146 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_document_type_list
-- Optional @include_all=1 prepends a synthetic (-1,'All') row so the
-- Web layer can bind directly to the same result set for filter widgets.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_type_list
    @include_all BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @include_all = 1
    BEGIN
        SELECT -1 AS DocumentTypeId, N'All' AS DocumentType, N'ALL' AS TypeCode, 0 AS SortOrder
        UNION ALL
        SELECT t.document_type_id AS DocumentTypeId,
               t.document_type    AS DocumentType,
               t.type_code        AS TypeCode,
               t.sort_order       AS SortOrder
          FROM grac_practice.document_type_master t
          JOIN grac_practice.record_status_master r
            ON t.record_status_id = r.record_status_id
         WHERE r.status_code = N'Active'
         ORDER BY SortOrder, DocumentType;
    END
    ELSE
    BEGIN
        SELECT t.document_type_id AS DocumentTypeId,
               t.document_type    AS DocumentType,
               t.type_code        AS TypeCode,
               t.sort_order       AS SortOrder
          FROM grac_practice.document_type_master t
          JOIN grac_practice.record_status_master r
            ON t.record_status_id = r.record_status_id
         WHERE r.status_code = N'Active'
         ORDER BY t.sort_order, t.document_type;
    END
END
GO

-- =====================================================================
-- 2. sp_document_stage_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_stage_list
    @include_all BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @include_all = 1
    BEGIN
        SELECT -1 AS DocumentStageId, N'All' AS DocumentStage, N'ALL' AS StageCode, 0 AS SortOrder
        UNION ALL
        SELECT s.document_stage_id, s.document_stage, s.stage_code, s.sort_order
          FROM grac_practice.document_stage_master s
          JOIN grac_practice.record_status_master r
            ON s.record_status_id = r.record_status_id
         WHERE r.status_code = N'Active'
         ORDER BY SortOrder, DocumentStage;
    END
    ELSE
    BEGIN
        SELECT s.document_stage_id AS DocumentStageId,
               s.document_stage    AS DocumentStage,
               s.stage_code        AS StageCode,
               s.sort_order        AS SortOrder
          FROM grac_practice.document_stage_master s
          JOIN grac_practice.record_status_master r
            ON s.record_status_id = r.record_status_id
         WHERE r.status_code = N'Active'
         ORDER BY s.sort_order, s.document_stage;
    END
END
GO

-- =====================================================================
-- 3. sp_document_status_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_status_list
    @include_all BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @include_all = 1
    BEGIN
        SELECT -1 AS DocumentStatusId, N'All' AS DocumentStatus, N'ALL' AS StatusCode, 0 AS SortOrder
        UNION ALL
        SELECT s.document_status_id, s.document_status, s.status_code, s.sort_order
          FROM grac_practice.document_status_master s
          JOIN grac_practice.record_status_master r
            ON s.record_status_id = r.record_status_id
         WHERE r.status_code = N'Active'
         ORDER BY SortOrder, DocumentStatus;
    END
    ELSE
    BEGIN
        SELECT s.document_status_id AS DocumentStatusId,
               s.document_status    AS DocumentStatus,
               s.status_code        AS StatusCode,
               s.sort_order         AS SortOrder
          FROM grac_practice.document_status_master s
          JOIN grac_practice.record_status_master r
            ON s.record_status_id = r.record_status_id
         WHERE r.status_code = N'Active'
         ORDER BY s.sort_order, s.document_status;
    END
END
GO

-- =====================================================================
-- 4. sp_document_source_type_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_source_type_list
    @include_all BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @include_all = 1
    BEGIN
        SELECT -1 AS SourceTypeId, N'All' AS SourceType, N'ALL' AS SourceCode, 0 AS SortOrder
        UNION ALL
        SELECT s.source_type_id, s.source_type, s.source_code, s.sort_order
          FROM grac_practice.document_source_type_master s
          JOIN grac_practice.record_status_master r
            ON s.record_status_id = r.record_status_id
         WHERE r.status_code = N'Active'
         ORDER BY SortOrder, SourceType;
    END
    ELSE
    BEGIN
        SELECT s.source_type_id AS SourceTypeId,
               s.source_type    AS SourceType,
               s.source_code    AS SourceCode,
               s.sort_order     AS SortOrder
          FROM grac_practice.document_source_type_master s
          JOIN grac_practice.record_status_master r
            ON s.record_status_id = r.record_status_id
         WHERE r.status_code = N'Active'
         ORDER BY s.sort_order, s.source_type;
    END
END
GO

-- =====================================================================
-- 5. sp_document_distribution_type_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_distribution_type_list
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.distribution_type_id AS DistributionTypeId,
           d.distribution_type    AS DistributionType,
           d.distribution_code    AS DistributionCode,
           d.sort_order           AS SortOrder
      FROM grac_practice.document_distribution_type_master d
      JOIN grac_practice.record_status_master r
        ON d.record_status_id = r.record_status_id
     WHERE r.status_code = N'Active'
     ORDER BY d.sort_order, d.distribution_type;
END
GO

-- =====================================================================
-- 6. sp_organization_department_list
-- Departments belonging to one organization. Optional @include_all=1
-- prepends the (-1,'All') row for filter widgets.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_organization_department_list
    @organization_id BIGINT,
    @include_all     BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 52700, 'sp_organization_department_list: organization_id is required.', 1;

    IF @include_all = 1
    BEGIN
        SELECT -1 AS DepartmentId, N'All' AS DepartmentName
        UNION ALL
        SELECT d.department_id, d.department_name
          FROM grac_practice.organization_department d
          JOIN grac_practice.record_status_master r
            ON d.record_status_id = r.record_status_id
         WHERE d.organization_id = @organization_id
           AND r.status_code = N'Active'
         ORDER BY DepartmentName;
    END
    ELSE
    BEGIN
        SELECT d.department_id   AS DepartmentId,
               d.department_name AS DepartmentName
          FROM grac_practice.organization_department d
          JOIN grac_practice.record_status_master r
            ON d.record_status_id = r.record_status_id
         WHERE d.organization_id = @organization_id
           AND r.status_code = N'Active'
         ORDER BY d.department_name;
    END
END
GO

-- =====================================================================
-- 7. sp_organization_employee_by_department
--
-- If @department_ids is NULL or empty, returns every active employee
-- in the organization. Otherwise filters to the given comma-separated
-- department id list. This matches the legacy QRY006 shape one endpoint
-- serves both "pick from all" and "pick from Finance+HR" cases.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_organization_employee_by_department
    @organization_id BIGINT,
    @department_ids  NVARCHAR(MAX) = NULL,   -- comma-separated department_id list
    @include_all     BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 52701, 'sp_organization_employee_by_department: organization_id is required.', 1;

    DECLARE @use_filter BIT = CASE
        WHEN @department_ids IS NULL OR LEN(LTRIM(RTRIM(@department_ids))) = 0 THEN 0
        WHEN LTRIM(RTRIM(@department_ids)) = N'-1' THEN 0
        ELSE 1
    END;

    IF @include_all = 1
    BEGIN
        SELECT -1 AS EmployeeId, N'All' AS EmployeeName, NULL AS EmployeeCode, NULL AS Email
        UNION ALL
        SELECT e.employee_id, e.employee_name, e.employee_code, e.email
          FROM grac_practice.organization_employee e
          JOIN grac_practice.record_status_master r
            ON e.record_status_id = r.record_status_id
         WHERE e.organization_id = @organization_id
           AND r.status_code = N'Active'
           AND ( @use_filter = 0
              OR EXISTS ( SELECT 1
                            FROM STRING_SPLIT(@department_ids, ',') s
                            JOIN grac_practice.organization_department d
                              ON d.department_id = TRY_CAST(s.value AS BIGINT)
                           WHERE d.organization_id = @organization_id
                             AND d.department_name = e.department ) )
         ORDER BY EmployeeName;
    END
    ELSE
    BEGIN
        SELECT e.employee_id   AS EmployeeId,
               e.employee_name AS EmployeeName,
               e.employee_code AS EmployeeCode,
               e.email         AS Email
          FROM grac_practice.organization_employee e
          JOIN grac_practice.record_status_master r
            ON e.record_status_id = r.record_status_id
         WHERE e.organization_id = @organization_id
           AND r.status_code = N'Active'
           AND ( @use_filter = 0
              OR EXISTS ( SELECT 1
                            FROM STRING_SPLIT(@department_ids, ',') s
                            JOIN grac_practice.organization_department d
                              ON d.department_id = TRY_CAST(s.value AS BIGINT)
                           WHERE d.organization_id = @organization_id
                             AND d.department_name = e.department ) )
         ORDER BY e.employee_name;
    END
END
GO

-- =====================================================================
-- 8. sp_document_register_list
--
-- The Policy / Document List screen. Filters on org, type, stage,
-- status; supports search across code + name + tags; paginated.
-- Callers pass -1 for "any" on the id filters (matches legacy QRY004).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_register_list
    @organization_id     BIGINT,
    @document_type_id    INT           = -1,
    @stage_id            INT           = -1,
    @status_id           INT           = -1,
    @search              NVARCHAR(300) = N'',
    @page_number         INT           = 1,
    @page_size           INT           = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 52702, 'sp_document_register_list: organization_id is required.', 1;

    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    IF @search IS NULL SET @search = N'';

    DECLARE @offset INT = (@page_number - 1) * @page_size;
    DECLARE @like NVARCHAR(310) = N'%' + LTRIM(RTRIM(@search)) + N'%';

    ;WITH filtered AS (
        SELECT d.document_id, d.document_code, d.company_document_code,
               d.document_name, d.document_type_id, d.version_number,
               d.next_review_date, d.effective_date,
               d.current_stage_id, d.current_status_id,
               d.owner_id, d.updated_dt, d.entered_dt
          FROM grac_practice.document_upload d
          JOIN grac_practice.record_status_master r
            ON d.record_status_id = r.record_status_id
         WHERE r.status_code = N'Active'
           AND d.organization_id = @organization_id
           AND ( @document_type_id = -1 OR d.document_type_id = @document_type_id )
           AND ( @stage_id          = -1 OR d.current_stage_id  = @stage_id )
           AND ( @status_id         = -1 OR d.current_status_id = @status_id )
           AND ( LEN(LTRIM(RTRIM(@search))) = 0
                 OR d.document_name         LIKE @like
                 OR d.document_code         LIKE @like
                 OR d.company_document_code LIKE @like
                 OR d.keywords_tag          LIKE @like )
    )
    SELECT
        f.document_id                                   AS DocumentId,
        f.document_code                                 AS DocumentCode,
        f.company_document_code                         AS CompanyDocumentCode,
        f.document_name                                 AS DocumentName,
        f.document_type_id                              AS DocumentTypeId,
        t.document_type                                 AS DocumentType,
        f.version_number                                AS VersionNumber,
        f.next_review_date                              AS NextReviewDate,
        f.current_stage_id                              AS StageId,
        s.document_stage                                AS DocumentStage,
        f.current_status_id                             AS StatusId,
        st.document_status                              AS DocumentStatus,
        COALESCE(f.updated_dt, f.entered_dt)            AS LastActivityDt,
        COUNT(*) OVER ()                                AS TotalRows
      FROM filtered f
      JOIN grac_practice.document_type_master   t  ON f.document_type_id  = t.document_type_id
      JOIN grac_practice.document_stage_master  s  ON f.current_stage_id  = s.document_stage_id
      JOIN grac_practice.document_status_master st ON f.current_status_id = st.document_status_id
     ORDER BY LastActivityDt DESC, f.document_id DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- 9. sp_document_details_get
-- Full detail card for one document.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_details_get
    @document_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @document_id IS NULL
        THROW 52703, 'sp_document_details_get: document_id is required.', 1;

    SELECT
        d.document_id                AS DocumentId,
        d.organization_id            AS OrganizationId,
        o.organization_name          AS OrganizationName,
        d.document_code              AS DocumentCode,
        d.company_document_code      AS CompanyDocumentCode,
        d.document_name              AS DocumentName,
        d.document_type_id           AS DocumentTypeId,
        t.document_type              AS DocumentType,
        d.source_type_id             AS SourceTypeId,
        src.source_type              AS SourceType,
        d.version_number             AS VersionNumber,
        d.effective_date             AS EffectiveDate,
        d.next_review_date           AS NextReviewDate,
        d.acknowledgement_required   AS AcknowledgementRequired,
        d.current_stage_id           AS StageId,
        st.document_stage            AS DocumentStage,
        d.current_status_id          AS StatusId,
        stu.document_status          AS DocumentStatus,
        d.change_summary             AS ChangeSummary,
        d.keywords_tag               AS KeywordsTag,
        d.owner_id                   AS OwnerId,
        own.employee_name            AS OwnerName,
        d.reviewer_id                AS ReviewerId,
        rev.employee_name            AS ReviewerName,
        d.approver_id                AS ApproverId,
        app.employee_name            AS ApproverName,
        d.distribution_type_id       AS DistributionTypeId,
        dt.distribution_type         AS DistributionType,
        d.reviewed_by                AS ReviewedById,
        rby.employee_name            AS ReviewedByName,
        d.reviewed_on                AS ReviewedOn,
        d.review_remark              AS ReviewRemark,
        d.approved_by                AS ApprovedById,
        aby.employee_name            AS ApprovedByName,
        d.approved_on                AS ApprovedOn,
        d.approved_remark            AS ApprovedRemark,
        d.entered_by                 AS CreatedBy,
        d.entered_dt                 AS CreatedOn,
        d.updated_by                 AS UpdatedBy,
        d.updated_dt                 AS UpdatedOn
      FROM grac_practice.document_upload d
      JOIN grac_practice.organization                    o   ON d.organization_id      = o.organization_id
      JOIN grac_practice.document_type_master            t   ON d.document_type_id     = t.document_type_id
 LEFT JOIN grac_practice.document_source_type_master     src ON d.source_type_id       = src.source_type_id
      JOIN grac_practice.document_stage_master           st  ON d.current_stage_id     = st.document_stage_id
      JOIN grac_practice.document_status_master          stu ON d.current_status_id    = stu.document_status_id
 LEFT JOIN grac_practice.document_distribution_type_master dt ON d.distribution_type_id = dt.distribution_type_id
 LEFT JOIN grac_practice.organization_employee           own ON d.owner_id             = own.employee_id
 LEFT JOIN grac_practice.organization_employee           rev ON d.reviewer_id          = rev.employee_id
 LEFT JOIN grac_practice.organization_employee           app ON d.approver_id          = app.employee_id
 LEFT JOIN grac_practice.organization_employee           rby ON d.reviewed_by          = rby.employee_id
 LEFT JOIN grac_practice.organization_employee           aby ON d.approved_by          = aby.employee_id
     WHERE d.document_id = @document_id;
END
GO

-- =====================================================================
-- 10. sp_document_distribution_department_list
-- Which departments a document is distributed to. Only returns active
-- rows so a soft-removed department disappears from the card.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_distribution_department_list
    @document_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @document_id IS NULL
        THROW 52704, 'sp_document_distribution_department_list: document_id is required.', 1;

    SELECT dd.department_id     AS DepartmentId,
           d.department_name    AS DepartmentName
      FROM grac_practice.document_upload_distribution_department dd
      JOIN grac_practice.organization_department d
        ON dd.department_id = d.department_id
      JOIN grac_practice.record_status_master r
        ON dd.record_status_id = r.record_status_id
     WHERE dd.document_id = @document_id
       AND r.status_code = N'Active'
     ORDER BY d.department_name;
END
GO

-- =====================================================================
-- 11. sp_document_distribution_employee_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_distribution_employee_list
    @document_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @document_id IS NULL
        THROW 52705, 'sp_document_distribution_employee_list: document_id is required.', 1;

    SELECT de.employee_id      AS EmployeeId,
           e.employee_name     AS EmployeeName,
           e.employee_code     AS EmployeeCode,
           e.email             AS Email
      FROM grac_practice.document_upload_distribution_employee de
      JOIN grac_practice.organization_employee e
        ON de.employee_id = e.employee_id
      JOIN grac_practice.record_status_master r
        ON de.record_status_id = r.record_status_id
     WHERE de.document_id = @document_id
       AND r.status_code = N'Active'
     ORDER BY e.employee_name;
END
GO

-- =====================================================================
-- 12. sp_document_file_get
-- Returns the CURRENT file for a document (is_current = 1). Callers
-- who need a specific version pass @document_file_id instead.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_file_get
    @document_id      BIGINT       = NULL,
    @document_file_id BIGINT       = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @document_id IS NULL AND @document_file_id IS NULL
        THROW 52706, 'sp_document_file_get: pass document_id or document_file_id.', 1;

    IF @document_file_id IS NOT NULL
    BEGIN
        SELECT document_file_id AS DocumentFileId,
               document_id      AS DocumentId,
               version_number   AS VersionNumber,
               file_name        AS FileName,
               content_type     AS ContentType,
               file_size_bytes  AS FileSizeBytes,
               file_data        AS FileData,
               uploaded_dt      AS UploadedOn
          FROM grac_practice.document_upload_file
         WHERE document_file_id = @document_file_id;
        RETURN;
    END

    -- current file for document
    SELECT TOP 1
           document_file_id AS DocumentFileId,
           document_id      AS DocumentId,
           version_number   AS VersionNumber,
           file_name        AS FileName,
           content_type     AS ContentType,
           file_size_bytes  AS FileSizeBytes,
           file_data        AS FileData,
           uploaded_dt      AS UploadedOn
      FROM grac_practice.document_upload_file
     WHERE document_id = @document_id
       AND is_current  = 1
     ORDER BY uploaded_dt DESC;
END
GO

-- =====================================================================
-- 13. sp_document_file_save
--
-- Adds a new file row and flips previous rows for the same document to
-- is_current = 0. Called by sp_document_upload_save on New/Edit and by
-- the "replace file" endpoint on its own.
-- =====================================================================
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

-- =====================================================================
-- 14. sp_document_upload_save
--
-- Three modes (kept in one proc so the Web layer has one write endpoint
-- for the upload form -- matches the legacy sp_document_upload shape):
--
--     @mode = 'New'          -> insert document + file, generate document_code
--     @mode = 'Edit'         -> update metadata; if @file_data provided,
--                               add a new file version via sp_document_file_save
--     @mode = 'StatusToggle' -> flip current_status_id between Active/Inactive
--
-- distribution_type_code drives which child table is populated:
--     'Departments' -> distribution_ids treated as department ids
--     'Users'       -> distribution_ids treated as employee ids
--     'Organization'-> neither table populated (whole org)
--
-- The distribution list is passed as a comma-separated string to keep
-- the wire format one primitive. STRING_SPLIT parses it. On edit, the
-- proc reconciles: adds new ids, soft-deletes ids no longer present.
--
-- Returns one row: DocumentId (of the created / edited document).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_upload_save
    @mode                     NVARCHAR(20),        -- New | Edit | StatusToggle
    @document_id              BIGINT        = NULL,
    @organization_id          BIGINT,
    @document_name            NVARCHAR(500) = NULL,
    @company_document_code    NVARCHAR(100) = NULL,
    @document_type_id         INT           = NULL,
    @source_type_id           INT           = NULL,
    @version_number           NVARCHAR(30)  = NULL,
    @effective_date           DATE          = NULL,
    @next_review_date         DATE          = NULL,
    @distribution_type_code   NVARCHAR(60)  = NULL, -- Organization | Departments | Users
    @distribution_ids         NVARCHAR(MAX) = NULL, -- CSV of dept ids or employee ids
    @acknowledgement_required BIT           = 0,
    @change_summary           NVARCHAR(MAX) = NULL,
    @keywords_tag             NVARCHAR(MAX) = NULL,
    @owner_id                 BIGINT        = NULL,
    @reviewer_id              BIGINT        = NULL,
    @approver_id              BIGINT        = NULL,
    @file_name                NVARCHAR(500) = NULL,
    @content_type             NVARCHAR(200) = NULL,
    @file_data                VARBINARY(MAX) = NULL,
    @caller_employee_id       BIGINT        = NULL,
    @caller_display_name      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @mode IS NULL OR @mode NOT IN (N'New', N'Edit', N'StatusToggle')
        THROW 52720, 'sp_document_upload_save: mode must be New, Edit or StatusToggle.', 1;
    IF @organization_id IS NULL
        THROW 52721, 'sp_document_upload_save: organization_id is required.', 1;

    DECLARE @draft_stage_id    INT = (SELECT document_stage_id FROM grac_practice.document_stage_master WHERE stage_code = N'Draft');
    DECLARE @active_status_id  INT = (SELECT document_status_id FROM grac_practice.document_status_master WHERE status_code = N'Active');
    DECLARE @retired_status_id INT = (SELECT document_status_id FROM grac_practice.document_status_master WHERE status_code = N'Retired');
    DECLARE @active_rs_id      INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
    DECLARE @inactive_rs_id    INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Inactive');

    IF @draft_stage_id IS NULL OR @active_status_id IS NULL OR @retired_status_id IS NULL OR @active_rs_id IS NULL OR @inactive_rs_id IS NULL
        THROW 52722, 'sp_document_upload_save: seed data missing (Draft stage / Active-Retired status / record_status). Run 148.', 1;

    DECLARE @distribution_type_id INT = NULL;
    IF @distribution_type_code IS NOT NULL AND LEN(LTRIM(RTRIM(@distribution_type_code))) > 0
    BEGIN
        SELECT @distribution_type_id = distribution_type_id
          FROM grac_practice.document_distribution_type_master
         WHERE distribution_code = @distribution_type_code;

        IF @distribution_type_id IS NULL
            THROW 52723, 'sp_document_upload_save: unknown distribution_type_code.', 1;
    END

    -- Default source to UPLOADED when the caller does not specify one.
    -- Documents added through the register UI are always "Uploaded";
    -- "Policy Driven" originates from a separate flow (not shipped in
    -- Phase 1) and would set source_type_id explicitly.
    IF @source_type_id IS NULL
        SELECT @source_type_id = source_type_id
          FROM grac_practice.document_source_type_master
         WHERE source_code = N'UPLOADED';

    BEGIN TRAN;

    -----------------------------------------------------------------
    -- New
    -----------------------------------------------------------------
    IF @mode = N'New'
    BEGIN
        IF @document_name IS NULL OR LEN(LTRIM(RTRIM(@document_name))) = 0
        BEGIN ROLLBACK; THROW 52724, 'sp_document_upload_save (New): document_name is required.', 1; END
        IF @document_type_id IS NULL
        BEGIN ROLLBACK; THROW 52725, 'sp_document_upload_save (New): document_type_id is required.', 1; END
        IF @version_number IS NULL OR LEN(LTRIM(RTRIM(@version_number))) = 0
        BEGIN ROLLBACK; THROW 52726, 'sp_document_upload_save (New): version_number is required.', 1; END
        IF @file_data IS NULL OR DATALENGTH(@file_data) = 0
        BEGIN ROLLBACK; THROW 52727, 'sp_document_upload_save (New): file_data is required.', 1; END

        IF EXISTS ( SELECT 1
                      FROM grac_practice.document_upload
                     WHERE organization_id = @organization_id
                       AND UPPER(document_name) = UPPER(@document_name) )
        BEGIN ROLLBACK; THROW 52728, 'sp_document_upload_save (New): document with this name already exists.', 1; END

        -- Generate document_code: DU-{next org-scoped sequence}
        DECLARE @next_code INT;
        SELECT @next_code = ISNULL(MAX(TRY_CAST(REPLACE(document_code, N'DU-', N'') AS INT)), 0) + 1
          FROM grac_practice.document_upload
         WHERE organization_id = @organization_id
           AND document_code LIKE N'DU-%';

        DECLARE @document_code NVARCHAR(50) = CONCAT(N'DU-', @next_code);

        INSERT INTO grac_practice.document_upload
            (organization_id, document_code, company_document_code, document_name,
             document_type_id, source_type_id, version_number,
             effective_date, next_review_date,
             current_stage_id, current_status_id,
             change_summary, keywords_tag,
             owner_id, reviewer_id, approver_id,
             distribution_type_id, acknowledgement_required,
             record_status_id, entered_by, entered_dt)
        VALUES
            (@organization_id, @document_code, @company_document_code, @document_name,
             @document_type_id, @source_type_id, @version_number,
             @effective_date, @next_review_date,
             @draft_stage_id, @active_status_id,
             @change_summary, @keywords_tag,
             @owner_id, @reviewer_id, @approver_id,
             @distribution_type_id, ISNULL(@acknowledgement_required, 0),
             @active_rs_id, @caller_display_name, SYSUTCDATETIME());

        DECLARE @new_document_id BIGINT = SCOPE_IDENTITY();

        -- Distribution rows
        IF @distribution_type_code = N'Departments' AND @distribution_ids IS NOT NULL
        BEGIN
            INSERT INTO grac_practice.document_upload_distribution_department
                (document_id, department_id, record_status_id, entered_by, entered_dt)
            SELECT @new_document_id, TRY_CAST(s.value AS BIGINT), @active_rs_id, @caller_display_name, SYSUTCDATETIME()
              FROM STRING_SPLIT(@distribution_ids, N',') s
             WHERE TRY_CAST(s.value AS BIGINT) IS NOT NULL;
        END
        ELSE IF @distribution_type_code = N'Users' AND @distribution_ids IS NOT NULL
        BEGIN
            INSERT INTO grac_practice.document_upload_distribution_employee
                (document_id, employee_id, record_status_id, entered_by, entered_dt)
            SELECT @new_document_id, TRY_CAST(s.value AS BIGINT), @active_rs_id, @caller_display_name, SYSUTCDATETIME()
              FROM STRING_SPLIT(@distribution_ids, N',') s
             WHERE TRY_CAST(s.value AS BIGINT) IS NOT NULL;
        END

        -- File
        EXEC grac_practice.sp_document_file_save
            @document_id    = @new_document_id,
            @version_number = @version_number,
            @file_name      = @file_name,
            @content_type   = @content_type,
            @file_data      = @file_data,
            @uploaded_by    = @caller_employee_id;

        -- History
        INSERT INTO grac_practice.document_upload_history
            (document_id, change_reason, to_stage_id, to_status_id,
             actor_employee_id, remark, acted_by, acted_dt)
        VALUES
            (@new_document_id, N'Create', @draft_stage_id, @active_status_id,
             @caller_employee_id, @change_summary, @caller_display_name, SYSUTCDATETIME());

        COMMIT;
        SELECT @new_document_id AS DocumentId;
        RETURN;
    END

    -----------------------------------------------------------------
    -- Edit
    -----------------------------------------------------------------
    IF @mode = N'Edit'
    BEGIN
        IF @document_id IS NULL
        BEGIN ROLLBACK; THROW 52730, 'sp_document_upload_save (Edit): document_id is required.', 1; END

        IF NOT EXISTS (SELECT 1 FROM grac_practice.document_upload WHERE document_id = @document_id AND organization_id = @organization_id)
        BEGIN ROLLBACK; THROW 52731, 'sp_document_upload_save (Edit): document not found in organization.', 1; END

        IF @document_name IS NOT NULL
           AND EXISTS ( SELECT 1
                          FROM grac_practice.document_upload
                         WHERE organization_id = @organization_id
                           AND UPPER(document_name) = UPPER(@document_name)
                           AND document_id <> @document_id )
        BEGIN ROLLBACK; THROW 52732, 'sp_document_upload_save (Edit): another document with this name already exists.', 1; END

        DECLARE @old_stage_id INT, @old_status_id INT;
        SELECT @old_stage_id = current_stage_id, @old_status_id = current_status_id
          FROM grac_practice.document_upload
         WHERE document_id = @document_id;

        UPDATE grac_practice.document_upload
           SET document_name           = COALESCE(@document_name,           document_name),
               company_document_code   = COALESCE(@company_document_code,   company_document_code),
               document_type_id        = COALESCE(@document_type_id,        document_type_id),
               source_type_id          = COALESCE(@source_type_id,          source_type_id),
               version_number          = COALESCE(@version_number,          version_number),
               effective_date          = COALESCE(@effective_date,          effective_date),
               next_review_date        = COALESCE(@next_review_date,        next_review_date),
               change_summary          = COALESCE(@change_summary,          change_summary),
               keywords_tag            = COALESCE(@keywords_tag,            keywords_tag),
               owner_id                = COALESCE(@owner_id,                owner_id),
               reviewer_id             = COALESCE(@reviewer_id,             reviewer_id),
               approver_id             = COALESCE(@approver_id,             approver_id),
               distribution_type_id    = COALESCE(@distribution_type_id,    distribution_type_id),
               acknowledgement_required = COALESCE(@acknowledgement_required, acknowledgement_required),
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE document_id = @document_id;

        -- Reconcile distribution
        IF @distribution_type_code = N'Departments'
        BEGIN
            -- soft-delete rows no longer in the list
            UPDATE dd
               SET record_status_id = @inactive_rs_id
              FROM grac_practice.document_upload_distribution_department dd
             WHERE dd.document_id = @document_id
               AND dd.record_status_id = @active_rs_id
               AND ( @distribution_ids IS NULL
                     OR NOT EXISTS ( SELECT 1
                                       FROM STRING_SPLIT(@distribution_ids, N',') s
                                      WHERE TRY_CAST(s.value AS BIGINT) = dd.department_id ) );

            -- add rows newly in the list (or revive soft-deleted ones)
            IF @distribution_ids IS NOT NULL
            BEGIN
                MERGE grac_practice.document_upload_distribution_department AS tgt
                USING ( SELECT DISTINCT TRY_CAST(s.value AS BIGINT) AS department_id
                          FROM STRING_SPLIT(@distribution_ids, N',') s
                         WHERE TRY_CAST(s.value AS BIGINT) IS NOT NULL ) AS src
                   ON tgt.document_id = @document_id AND tgt.department_id = src.department_id
                 WHEN MATCHED AND tgt.record_status_id <> @active_rs_id
                     THEN UPDATE SET record_status_id = @active_rs_id
                 WHEN NOT MATCHED BY TARGET
                     THEN INSERT (document_id, department_id, record_status_id, entered_by, entered_dt)
                          VALUES (@document_id, src.department_id, @active_rs_id, @caller_display_name, SYSUTCDATETIME());
            END
        END
        ELSE IF @distribution_type_code = N'Users'
        BEGIN
            UPDATE de
               SET record_status_id = @inactive_rs_id
              FROM grac_practice.document_upload_distribution_employee de
             WHERE de.document_id = @document_id
               AND de.record_status_id = @active_rs_id
               AND ( @distribution_ids IS NULL
                     OR NOT EXISTS ( SELECT 1
                                       FROM STRING_SPLIT(@distribution_ids, N',') s
                                      WHERE TRY_CAST(s.value AS BIGINT) = de.employee_id ) );

            IF @distribution_ids IS NOT NULL
            BEGIN
                MERGE grac_practice.document_upload_distribution_employee AS tgt
                USING ( SELECT DISTINCT TRY_CAST(s.value AS BIGINT) AS employee_id
                          FROM STRING_SPLIT(@distribution_ids, N',') s
                         WHERE TRY_CAST(s.value AS BIGINT) IS NOT NULL ) AS src
                   ON tgt.document_id = @document_id AND tgt.employee_id = src.employee_id
                 WHEN MATCHED AND tgt.record_status_id <> @active_rs_id
                     THEN UPDATE SET record_status_id = @active_rs_id
                 WHEN NOT MATCHED BY TARGET
                     THEN INSERT (document_id, employee_id, record_status_id, entered_by, entered_dt)
                          VALUES (@document_id, src.employee_id, @active_rs_id, @caller_display_name, SYSUTCDATETIME());
            END
        END

        -- File (optional on edit)
        IF @file_data IS NOT NULL AND DATALENGTH(@file_data) > 0
        BEGIN
            EXEC grac_practice.sp_document_file_save
                @document_id    = @document_id,
                @version_number = @version_number,
                @file_name      = @file_name,
                @content_type   = @content_type,
                @file_data      = @file_data,
                @uploaded_by    = @caller_employee_id;
        END

        -- History
        INSERT INTO grac_practice.document_upload_history
            (document_id, change_reason,
             from_stage_id, to_stage_id,
             from_status_id, to_status_id,
             actor_employee_id, remark, acted_by, acted_dt)
        VALUES
            (@document_id, N'Edit',
             @old_stage_id, @old_stage_id,
             @old_status_id, @old_status_id,
             @caller_employee_id, @change_summary, @caller_display_name, SYSUTCDATETIME());

        COMMIT;
        SELECT @document_id AS DocumentId;
        RETURN;
    END

    -----------------------------------------------------------------
    -- StatusToggle
    -----------------------------------------------------------------
    IF @mode = N'StatusToggle'
    BEGIN
        IF @document_id IS NULL
        BEGIN ROLLBACK; THROW 52735, 'sp_document_upload_save (StatusToggle): document_id is required.', 1; END

        IF NOT EXISTS (SELECT 1 FROM grac_practice.document_upload WHERE document_id = @document_id AND organization_id = @organization_id)
        BEGIN ROLLBACK; THROW 52736, 'sp_document_upload_save (StatusToggle): document not found in organization.', 1; END

        DECLARE @cur_status_id INT;
        SELECT @cur_status_id = current_status_id FROM grac_practice.document_upload WHERE document_id = @document_id;

        DECLARE @new_status_id INT = CASE WHEN @cur_status_id = @active_status_id THEN @retired_status_id ELSE @active_status_id END;

        UPDATE grac_practice.document_upload
           SET current_status_id = @new_status_id,
               updated_by        = @caller_display_name,
               updated_dt        = SYSUTCDATETIME()
         WHERE document_id = @document_id;

        INSERT INTO grac_practice.document_upload_history
            (document_id, change_reason,
             from_status_id, to_status_id,
             actor_employee_id, remark, acted_by, acted_dt)
        VALUES
            (@document_id, N'StatusChange',
             @cur_status_id, @new_status_id,
             @caller_employee_id, @change_summary, @caller_display_name, SYSUTCDATETIME());

        COMMIT;
        SELECT @document_id AS DocumentId;
        RETURN;
    END

    -- unreachable (mode check above), but keep rollback safe
    IF @@TRANCOUNT > 0 ROLLBACK;
END
GO

-- =====================================================================
-- 15. sp_document_upload_workflow_transition
--
-- Three stages exist today (per 148 seed): Draft, Reviewed, Published.
-- The valid moves between them are:
--
--   @transition='Review'   Draft     -> Reviewed   (@decision='Approve')
--                          Draft     -> Draft      (@decision='Reject', logs remark)
--   @transition='Approve'  Reviewed  -> Published  (@decision='Approve')
--                          Reviewed  -> Draft      (@decision='Reject', back for edit)
--
-- Retiring a published document is a STATUS change (Active -> Retired),
-- not a stage change -- call sp_document_upload_save @mode='StatusToggle'.
-- Kept as a distinct concept because a retired policy still lived in
-- the Published stage while it was in force; the archival act is
-- separate from the lifecycle position.
--
-- Uses stage_code (not id) as the transition currency so the proc
-- stays intact if identity values differ between environments.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_document_upload_workflow_transition
    @document_id          BIGINT,
    @transition           NVARCHAR(20),                -- Review | Approve
    @decision             NVARCHAR(20) = N'Approve',   -- Approve | Reject
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

    DECLARE @cur_stage_id INT;
    SELECT @cur_stage_id = current_stage_id FROM grac_practice.document_upload WHERE document_id = @document_id;
    IF @cur_stage_id IS NULL
        THROW 52743, 'sp_document_upload_workflow_transition: document not found.', 1;

    DECLARE @cur_stage_code NVARCHAR(60) =
        (SELECT stage_code FROM grac_practice.document_stage_master WHERE document_stage_id = @cur_stage_id);

    -- (transition, current stage, decision) -> next stage code
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

    -- Composite change_reason so the history timeline reads clearly
    -- ("Review-Approve", "Review-Reject", "Approve-Approve", "Approve-Reject").
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

    COMMIT;

    SELECT @document_id      AS DocumentId,
           @next_stage_id    AS StageId,
           @next_stage_code  AS StageCode;
END
GO

-- End 147 =============================================================
