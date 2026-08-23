-- =====================================================================
-- 166 Exception Centre v2 -- capture the full governance dataset
--
-- Adds the 8 missing fields called out by the business (sir's spec):
--   Exception Type (dropdown from new master)
--   Justification (formal user-provided)
--   Risk / Impact
--   Exception Owner (distinct from requester + approver)
--   Effective From
--   Compensating Control (if applicable)
--   Review Frequency (reuses grac_practice.frequency_master)
--   Linked Practice / Requirement (soft link + free-text ref)
--
-- Also promotes EXPIRY to a first-class event:
--   * New status_code 'Expired' (extends CHECK constraint)
--   * sp_exception_request_expire_due -- ops-scheduled daily flip
--
-- ADDITIVE + backward compatible:
--   * new columns are NULLable
--   * old create/approve calls without the new params still work
--     (defaults handle it)
--   * request_reason UNCHANGED (auto-populated from analysis);
--     justification is the NEW formal field
--
-- Rollback: 166_exception_centre_v2_full_capture_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.exception_request','U') IS NULL
   OR OBJECT_ID('grac_practice.frequency_master','U') IS NULL
BEGIN
    RAISERROR('166: prerequisites missing. Run 161 (exception_request) and 001 (frequency_master).', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. exception_type_master  (6 seeded types)
-- =====================================================================
IF OBJECT_ID('grac_practice.exception_type_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.exception_type_master(
        exception_type_id   INT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_exception_type_master PRIMARY KEY,
        exception_type_code NVARCHAR(60) NOT NULL,
        exception_type_name NVARCHAR(200) NOT NULL,
        description         NVARCHAR(500) NULL,
        display_order       INT NOT NULL
            CONSTRAINT df_pm_exception_type_sort DEFAULT 100,
        is_active           BIT NOT NULL
            CONSTRAINT df_pm_exception_type_active DEFAULT 1,
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_exception_type_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_exception_type_entered_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_exception_type_code UNIQUE(exception_type_code)
    );
END
GO

-- Seed the 6 canonical types (idempotent).
;WITH seed(code, name, description, sort) AS (
    SELECT * FROM (VALUES
        (N'TemporaryInability',   N'Temporary inability to comply', N'Compliance blocked by a transient constraint (staffing gap, tool downtime, etc.). Return to compliance is planned.', 10),
        (N'BusinessAcceptance',   N'Business acceptance',           N'Business consciously accepts the deviation for the exception window.',                                            20),
        (N'CompensatingControl',  N'Compensating control',          N'A different control is in place that mitigates the underlying risk while the primary control is not met.',       30),
        (N'TechnicalLimitation',  N'Technical limitation',          N'Current technology cannot satisfy the control (legacy system, unsupported vendor feature, etc.).',               40),
        (N'ThirdPartyDependency', N'Third-party dependency',        N'Non-compliance is caused or blocked by an external vendor or partner.',                                          50),
        (N'Other',                N'Other',                         N'Reason not covered by the above categories -- explain in justification.',                                        60)
    ) v(code, name, description, sort)
)
INSERT INTO grac_practice.exception_type_master
    (exception_type_code, exception_type_name, description, display_order, entered_by)
SELECT s.code, s.name, s.description, s.sort, N'seed-166'
  FROM seed s
 WHERE NOT EXISTS (SELECT 1 FROM grac_practice.exception_type_master m WHERE m.exception_type_code = s.code);
GO

-- =====================================================================
-- 2. ALTER exception_request  (8 new columns; guarded)
-- =====================================================================
IF COL_LENGTH('grac_practice.exception_request','exception_type_id') IS NULL
    ALTER TABLE grac_practice.exception_request
        ADD exception_type_id INT NULL
            CONSTRAINT fk_pm_exception_request_type
                REFERENCES grac_practice.exception_type_master(exception_type_id);
GO
IF COL_LENGTH('grac_practice.exception_request','justification') IS NULL
    ALTER TABLE grac_practice.exception_request ADD justification NVARCHAR(MAX) NULL;
GO
IF COL_LENGTH('grac_practice.exception_request','risk_impact') IS NULL
    ALTER TABLE grac_practice.exception_request ADD risk_impact NVARCHAR(MAX) NULL;
GO
IF COL_LENGTH('grac_practice.exception_request','owner_employee_id') IS NULL
    ALTER TABLE grac_practice.exception_request
        ADD owner_employee_id BIGINT NULL
            CONSTRAINT fk_pm_exception_request_owner
                REFERENCES grac_practice.organization_employee(employee_id);
GO
IF COL_LENGTH('grac_practice.exception_request','effective_from') IS NULL
    ALTER TABLE grac_practice.exception_request ADD effective_from DATE NULL;
GO
IF COL_LENGTH('grac_practice.exception_request','compensating_control') IS NULL
    ALTER TABLE grac_practice.exception_request ADD compensating_control NVARCHAR(MAX) NULL;
GO
IF COL_LENGTH('grac_practice.exception_request','review_frequency_id') IS NULL
    ALTER TABLE grac_practice.exception_request
        ADD review_frequency_id INT NULL
            CONSTRAINT fk_pm_exception_request_freq
                REFERENCES grac_practice.frequency_master(frequency_id);
GO
IF COL_LENGTH('grac_practice.exception_request','linked_practice_id') IS NULL
    ALTER TABLE grac_practice.exception_request ADD linked_practice_id BIGINT NULL;
GO
IF COL_LENGTH('grac_practice.exception_request','linked_requirement_ref') IS NULL
    ALTER TABLE grac_practice.exception_request ADD linked_requirement_ref NVARCHAR(200) NULL;
GO

-- =====================================================================
-- 3. Extend the status CHECK constraint to include 'Expired'
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'ck_pm_exception_request_status')
    ALTER TABLE grac_practice.exception_request DROP CONSTRAINT ck_pm_exception_request_status;
GO
ALTER TABLE grac_practice.exception_request
    ADD CONSTRAINT ck_pm_exception_request_status
        CHECK (status_code IN (N'Pending', N'Approved', N'Rejected', N'Withdrawn', N'Expired'));
GO

-- =====================================================================
-- 4. sp_exception_type_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_type_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT exception_type_id   AS ExceptionTypeId,
           exception_type_code AS ExceptionTypeCode,
           exception_type_name AS ExceptionTypeName,
           description         AS Description,
           display_order       AS SortOrder
      FROM grac_practice.exception_type_master
     WHERE is_active = 1
     ORDER BY display_order, exception_type_name;
END
GO

-- =====================================================================
-- 5. Rewrite sp_exception_request_create -- accept new optional fields.
--    Existing callers (auto-trigger from analysis) still work because
--    every new param has a default.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_create
    @custom_gap_id            BIGINT,
    @request_title            NVARCHAR(300) = NULL,
    @request_reason           NVARCHAR(MAX) = NULL,
    @requested_by_employee_id BIGINT        = NULL,
    @exception_type_code      NVARCHAR(60)  = NULL,
    @justification            NVARCHAR(MAX) = NULL,
    @risk_impact              NVARCHAR(MAX) = NULL,
    @owner_employee_id        BIGINT        = NULL,
    @linked_practice_id       BIGINT        = NULL,
    @linked_requirement_ref   NVARCHAR(200) = NULL,
    @caller_display_name      NVARCHAR(100) = N'system'
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

    DECLARE @type_id INT = NULL;
    IF @exception_type_code IS NOT NULL AND LEN(LTRIM(RTRIM(@exception_type_code))) > 0
    BEGIN
        SELECT @type_id = exception_type_id FROM grac_practice.exception_type_master
         WHERE exception_type_code = @exception_type_code;
        IF @type_id IS NULL
            THROW 55202, 'sp_exception_request_create: unknown exception_type_code.', 1;
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
             exception_type_id, justification, risk_impact,
             owner_employee_id,
             linked_practice_id, linked_requirement_ref,
             status_code,
             requested_by_employee_id, requested_dt,
             record_status_id, entered_by, entered_dt)
        VALUES
            (@org_id, @custom_gap_id,
             @title, @request_reason,
             @type_id, @justification, @risk_impact,
             @owner_employee_id,
             @linked_practice_id, @linked_requirement_ref,
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
    BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK; THROW; END CATCH

    SELECT @new_id AS ExceptionRequestId, CAST(1 AS BIT) AS Created;
END
GO

-- =====================================================================
-- 6. Rewrite sp_exception_request_approve -- accept effective_from,
--    compensating_control, review_frequency_id.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_approve
    @exception_request_id    BIGINT,
    @effective_until         DATE,
    @approval_note           NVARCHAR(MAX),
    @approved_by_employee_id BIGINT,
    @effective_from          DATE           = NULL,
    @compensating_control    NVARCHAR(MAX)  = NULL,
    @review_frequency_id     INT            = NULL,
    -- Request-level fields (settable at approve time if not already captured)
    @exception_type_code     NVARCHAR(60)   = NULL,
    @justification           NVARCHAR(MAX)  = NULL,
    @risk_impact             NVARCHAR(MAX)  = NULL,
    @owner_employee_id       BIGINT         = NULL,
    @linked_practice_id      BIGINT         = NULL,
    @linked_requirement_ref  NVARCHAR(200)  = NULL,
    @caller_display_name     NVARCHAR(100)  = N'system'
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
    IF @effective_from IS NOT NULL AND @effective_from > @effective_until
        THROW 55236, 'sp_exception_request_approve: effective_from must be on or before effective_until.', 1;

    DECLARE @current NVARCHAR(30);
    SELECT @current = status_code
      FROM grac_practice.exception_request WHERE exception_request_id = @exception_request_id;
    IF @current IS NULL
        THROW 55234, 'sp_exception_request_approve: request not found.', 1;
    IF @current <> N'Pending'
        THROW 55235, 'sp_exception_request_approve: only Pending requests can be approved.', 1;

    -- Resolve the exception type code (if the approver supplied one).
    DECLARE @type_id INT = NULL;
    IF @exception_type_code IS NOT NULL AND LEN(LTRIM(RTRIM(@exception_type_code))) > 0
    BEGIN
        SELECT @type_id = exception_type_id FROM grac_practice.exception_type_master
         WHERE exception_type_code = @exception_type_code;
        IF @type_id IS NULL
            THROW 55237, 'sp_exception_request_approve: unknown exception_type_code.', 1;
    END

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.exception_request
           SET status_code             = N'Approved',
               approved_by_employee_id = @approved_by_employee_id,
               approved_dt             = SYSUTCDATETIME(),
               effective_from          = COALESCE(@effective_from, SYSUTCDATETIME()),
               effective_until         = @effective_until,
               approval_note           = @approval_note,
               compensating_control    = COALESCE(@compensating_control, compensating_control),
               review_frequency_id     = COALESCE(@review_frequency_id, review_frequency_id),
               -- Request-level fields: fill if the approver supplied them,
               -- otherwise keep whatever was set at create time.
               exception_type_id       = COALESCE(@type_id,               exception_type_id),
               justification           = COALESCE(@justification,         justification),
               risk_impact             = COALESCE(@risk_impact,           risk_impact),
               owner_employee_id       = COALESCE(@owner_employee_id,     owner_employee_id),
               linked_practice_id      = COALESCE(@linked_practice_id,    linked_practice_id),
               linked_requirement_ref  = COALESCE(@linked_requirement_ref,linked_requirement_ref),
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE exception_request_id = @exception_request_id;

        INSERT INTO grac_practice.exception_request_history
            (exception_request_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@exception_request_id, N'Approve', N'Pending', N'Approved',
             CONCAT(
                 N'Valid ',
                 CONVERT(NVARCHAR(10), COALESCE(@effective_from, CAST(SYSUTCDATETIME() AS DATE)), 23),
                 N' -> ',
                 CONVERT(NVARCHAR(10), @effective_until, 23),
                 N'. Note: ', @approval_note),
             @approved_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK; THROW; END CATCH

    SELECT @exception_request_id AS ExceptionRequestId, N'Approved' AS StatusCode;
END
GO

-- =====================================================================
-- 7. sp_exception_request_expire_due
--    Ops runs this via SQL Agent job daily (or the app-side scheduled
--    task). Idempotent: only flips Approved rows whose effective_until
--    is already in the past. Writes history so audit shows the auto
--    transition.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_expire_due
    @caller_display_name NVARCHAR(100) = N'expiry-runner'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @affected TABLE (exception_request_id BIGINT);

    BEGIN TRY
        BEGIN TRAN;

        UPDATE er
           SET status_code = N'Expired',
               updated_by  = @caller_display_name,
               updated_dt  = SYSUTCDATETIME()
        OUTPUT INSERTED.exception_request_id INTO @affected(exception_request_id)
          FROM grac_practice.exception_request er
         WHERE er.status_code     = N'Approved'
           AND er.effective_until IS NOT NULL
           AND er.effective_until <  @today;

        INSERT INTO grac_practice.exception_request_history
            (exception_request_id, action_code, from_status_code, to_status_code,
             remark, actor_display_name, entered_by, entered_dt)
        SELECT a.exception_request_id, N'Expire', N'Approved', N'Expired',
               CONCAT(N'Auto-expired on ', CONVERT(NVARCHAR(10), @today, 23)),
               @caller_display_name, @caller_display_name, SYSUTCDATETIME()
          FROM @affected a;

        COMMIT;
    END TRY
    BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK; THROW; END CATCH

    SELECT COUNT(*) AS ExpiredCount FROM @affected;
END
GO

-- =====================================================================
-- 8. Rewrite sp_exception_request_get (return all new fields)
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
        r.justification             AS Justification,
        r.risk_impact               AS RiskImpact,
        et.exception_type_code      AS ExceptionTypeCode,
        et.exception_type_name      AS ExceptionTypeName,
        r.owner_employee_id         AS OwnerEmployeeId,
        ow.employee_name            AS OwnerName,
        r.linked_practice_id        AS LinkedPracticeId,
        r.linked_requirement_ref    AS LinkedRequirementRef,
        r.status_code               AS StatusCode,
        r.requested_by_employee_id  AS RequestedByEmployeeId,
        rq.employee_name            AS RequestedByName,
        r.requested_dt              AS RequestedOn,
        r.approved_by_employee_id   AS ApprovedByEmployeeId,
        ap.employee_name            AS ApprovedByName,
        r.approved_dt               AS ApprovedOn,
        r.effective_from            AS EffectiveFrom,
        r.effective_until           AS EffectiveUntil,
        r.approval_note             AS ApprovalNote,
        r.compensating_control      AS CompensatingControl,
        r.review_frequency_id       AS ReviewFrequencyId,
        fm.frequency_name           AS ReviewFrequencyName,
        r.rejected_by_employee_id   AS RejectedByEmployeeId,
        rj.employee_name            AS RejectedByName,
        r.rejected_dt               AS RejectedOn,
        r.rejection_reason          AS RejectionReason
      FROM grac_practice.exception_request r
      JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.custom_gap_id
 LEFT JOIN grac_practice.exception_type_master   et ON et.exception_type_id = r.exception_type_id
 LEFT JOIN grac_practice.organization_employee   ow ON ow.employee_id       = r.owner_employee_id
 LEFT JOIN grac_practice.organization_employee   rq ON rq.employee_id       = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee   ap ON ap.employee_id       = r.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee   rj ON rj.employee_id       = r.rejected_by_employee_id
 LEFT JOIN grac_practice.frequency_master        fm ON fm.frequency_id      = r.review_frequency_id
     WHERE r.exception_request_id = @exception_request_id;
END
GO

-- =====================================================================
-- 9. Rewrite sp_exception_request_list (return effective_from + type)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_list
    @organization_id BIGINT,
    @status_code     NVARCHAR(30) = NULL,
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
        r.exception_request_id  AS ExceptionRequestId,
        r.organization_id       AS OrganizationId,
        r.custom_gap_id         AS CustomGapId,
        g.title                 AS GapTitle,
        r.request_title         AS RequestTitle,
        et.exception_type_name  AS ExceptionTypeName,
        r.status_code           AS StatusCode,
        r.requested_dt          AS RequestedOn,
        rq.employee_name        AS RequestedByName,
        r.approved_dt           AS ApprovedOn,
        ap.employee_name        AS ApprovedByName,
        r.effective_from        AS EffectiveFrom,
        r.effective_until       AS EffectiveUntil,
        r.rejected_dt           AS RejectedOn,
        rj.employee_name        AS RejectedByName,
        (SELECT COUNT(*) FROM grac_practice.exception_request_attachment a
          WHERE a.exception_request_id = r.exception_request_id) AS AttachmentCount,
        COUNT(*) OVER ()        AS TotalRows
      FROM grac_practice.exception_request r
      JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.custom_gap_id
 LEFT JOIN grac_practice.exception_type_master   et ON et.exception_type_id = r.exception_type_id
 LEFT JOIN grac_practice.organization_employee   rq ON rq.employee_id       = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee   ap ON ap.employee_id       = r.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee   rj ON rj.employee_id       = r.rejected_by_employee_id
     WHERE r.organization_id = @organization_id
       AND (@status_code IS NULL OR r.status_code = @status_code)
     ORDER BY r.requested_dt DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

PRINT '166 Exception Centre v2 (full capture + expiry) ready.';
GO
