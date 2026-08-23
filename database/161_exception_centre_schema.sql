-- =====================================================================
-- 161 Exception Centre -- schema
--
-- WHAT IS AN EXCEPTION IN GRAC?
-- -----------------------------
-- A formal, time-boxed acceptance of a gap that will NOT be remediated
-- inside the exception window. Requires management approval, captures
-- the approval note + optional attachment, and expires on a date. Not
-- a task (no remediation), not a risk (no enterprise-risk transfer) --
-- a distinct governance artefact.
--
-- LIFECYCLE
-- ---------
--   Pending -> Approved | Rejected | Withdrawn
--
-- SOURCING
-- --------
-- Requests are raised from the Gap Centre analysis: when analyst ticks
-- "Recommend an exception" and saves analysis, the Exception request is
-- auto-materialized (idempotent per gap). Requests remain LINKED to
-- their originating gap via custom_gap_id -- ownership stays with the
-- gap (AES sec 7).
--
-- WHAT THIS MIGRATION ADDS
-- ------------------------
--   grac_practice.exception_request              header
--   grac_practice.exception_request_attachment   approval note file storage
--   grac_practice.exception_request_history      per-transition audit log
--
-- ROLLBACK: 161_exception_centre_schema_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
   OR OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_employee','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN
    RAISERROR('161: prerequisites missing. Run 001 / 009 / 054 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. exception_request (header)
-- =====================================================================
IF OBJECT_ID('grac_practice.exception_request','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.exception_request(
        exception_request_id     BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_exception_request PRIMARY KEY,
        organization_id          BIGINT NOT NULL
            CONSTRAINT fk_pm_exception_request_organization
                REFERENCES grac_practice.organization(organization_id),
        custom_gap_id            BIGINT NOT NULL
            CONSTRAINT fk_pm_exception_request_gap
                REFERENCES grac_practice.custom_gap(custom_gap_id),

        request_title            NVARCHAR(300) NOT NULL,
        request_reason           NVARCHAR(MAX) NULL,

        -- Lifecycle
        status_code              NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_exception_request_status DEFAULT N'Pending',

        -- Who raised
        requested_by_employee_id BIGINT NULL
            CONSTRAINT fk_pm_exception_request_requester
                REFERENCES grac_practice.organization_employee(employee_id),
        requested_dt             DATETIME2 NOT NULL
            CONSTRAINT df_pm_exception_request_requested_dt DEFAULT SYSUTCDATETIME(),

        -- Approve fields
        approved_by_employee_id  BIGINT NULL
            CONSTRAINT fk_pm_exception_request_approver
                REFERENCES grac_practice.organization_employee(employee_id),
        approved_dt              DATETIME2 NULL,
        effective_until          DATE NULL,
        approval_note            NVARCHAR(MAX) NULL,

        -- Reject fields
        rejected_by_employee_id  BIGINT NULL
            CONSTRAINT fk_pm_exception_request_rejecter
                REFERENCES grac_practice.organization_employee(employee_id),
        rejected_dt              DATETIME2 NULL,
        rejection_reason         NVARCHAR(MAX) NULL,

        record_status_id         INT NOT NULL
            CONSTRAINT fk_pm_exception_request_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_exception_request_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_exception_request_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL,

        CONSTRAINT ck_pm_exception_request_status
            CHECK (status_code IN (N'Pending', N'Approved', N'Rejected', N'Withdrawn'))
    );
END
GO

IF OBJECT_ID('grac_practice.exception_request','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_exception_request_org_status'
                     AND object_id=OBJECT_ID('grac_practice.exception_request'))
    CREATE INDEX ix_pm_exception_request_org_status
        ON grac_practice.exception_request(organization_id, status_code, requested_dt DESC)
        INCLUDE(custom_gap_id, request_title);
GO

IF OBJECT_ID('grac_practice.exception_request','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_exception_request_gap'
                     AND object_id=OBJECT_ID('grac_practice.exception_request'))
    CREATE INDEX ix_pm_exception_request_gap
        ON grac_practice.exception_request(custom_gap_id, status_code);
GO

-- =====================================================================
-- 2. exception_request_attachment (approval note file storage)
-- Same shape as document_upload_file -- fat column separated from the
-- header so list queries stay narrow.
-- =====================================================================
IF OBJECT_ID('grac_practice.exception_request_attachment','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.exception_request_attachment(
        attachment_id            BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_exception_request_attachment PRIMARY KEY,
        exception_request_id     BIGINT NOT NULL
            CONSTRAINT fk_pm_exception_request_attachment_request
                REFERENCES grac_practice.exception_request(exception_request_id),
        file_name                NVARCHAR(500) NOT NULL,
        content_type             NVARCHAR(200) NULL,
        file_size_bytes          BIGINT NOT NULL
            CONSTRAINT df_pm_exception_request_attachment_size DEFAULT 0,
        file_data                VARBINARY(MAX) NOT NULL,
        uploaded_by_employee_id  BIGINT NULL
            CONSTRAINT fk_pm_exception_request_attachment_uploader
                REFERENCES grac_practice.organization_employee(employee_id),
        uploaded_dt              DATETIME2 NOT NULL
            CONSTRAINT df_pm_exception_request_attachment_dt DEFAULT SYSUTCDATETIME()
    );
END
GO

IF OBJECT_ID('grac_practice.exception_request_attachment','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_exception_request_attachment_req'
                     AND object_id=OBJECT_ID('grac_practice.exception_request_attachment'))
    CREATE INDEX ix_pm_exception_request_attachment_req
        ON grac_practice.exception_request_attachment(exception_request_id, uploaded_dt DESC);
GO

-- =====================================================================
-- 3. exception_request_history (audit log)
-- =====================================================================
IF OBJECT_ID('grac_practice.exception_request_history','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.exception_request_history(
        history_id               BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_exception_request_history PRIMARY KEY,
        exception_request_id     BIGINT NOT NULL
            CONSTRAINT fk_pm_exception_request_history_request
                REFERENCES grac_practice.exception_request(exception_request_id),
        action_code              NVARCHAR(40) NOT NULL,     -- Create / Approve / Reject / Withdraw / AttachmentUpload
        from_status_code         NVARCHAR(30) NULL,
        to_status_code           NVARCHAR(30) NULL,
        remark                   NVARCHAR(MAX) NULL,
        actor_employee_id        BIGINT NULL,
        actor_display_name       NVARCHAR(240) NULL,
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_exception_request_history_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_exception_request_history_entered_dt DEFAULT SYSUTCDATETIME()
    );
END
GO

IF OBJECT_ID('grac_practice.exception_request_history','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_exception_request_history_req'
                     AND object_id=OBJECT_ID('grac_practice.exception_request_history'))
    CREATE INDEX ix_pm_exception_request_history_req
        ON grac_practice.exception_request_history(exception_request_id, entered_dt DESC);
GO

PRINT '161 Exception Centre schema ready.';
GO
