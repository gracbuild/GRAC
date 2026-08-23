-- =====================================================================
-- 169 Risk Centre -- schema (placeholder module, mirrors Exception Centre)
--
-- WHAT IS A RISK CANDIDATE IN GRAC?
-- --------------------------------
-- A candidate risk raised from Gap Centre analysis when the analyst
-- flags "Is there a business Risk? = Yes". A risk manager triages the
-- candidate later (Accept / Reject / Withdraw) and, once the formal
-- Risk Management module is built, promotes accepted candidates into
-- the enterprise risk register.
--
-- LIFECYCLE
-- ---------
--   Pending -> Accepted | Rejected | Withdrawn
--   (Accepted = "will be tracked as a formal risk"; the risk-register
--    linkage arrives with the full Risk module. For now Accepted is a
--    terminal parking state.)
--
-- SOURCING
-- --------
-- Auto-created from sp_custom_gap_analysis_save (migration 172) when
-- business_risk_present='Y'. Idempotent per gap (one candidate per gap).
--
-- WHAT THIS MIGRATION ADDS
-- ------------------------
--   grac_practice.risk_candidate              header
--   grac_practice.risk_candidate_attachment   evidence file storage
--   grac_practice.risk_candidate_history      per-transition audit log
--
-- Error range: 55400-55499  (procs will use 55400-55450, attachments
--              55451-55480, history 55481-55499)
-- ROLLBACK: 169_risk_centre_schema_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
   OR OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_employee','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN
    RAISERROR('169: prerequisites missing. Run 001 / 009 / 054 / 156 / 161 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. risk_candidate (header)
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_candidate','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.risk_candidate(
        risk_candidate_id        BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_risk_candidate PRIMARY KEY,
        organization_id          BIGINT NOT NULL
            CONSTRAINT fk_pm_risk_candidate_organization
                REFERENCES grac_practice.organization(organization_id),
        custom_gap_id            BIGINT NOT NULL
            CONSTRAINT fk_pm_risk_candidate_gap
                REFERENCES grac_practice.custom_gap(custom_gap_id),

        candidate_title          NVARCHAR(300) NOT NULL,
        candidate_summary        NVARCHAR(MAX) NULL,

        -- Simple 4-level severity (Critical/High/Medium/Low). Advisory
        -- until the full Risk module lands; captured at intake so the
        -- risk manager can triage by severity from day one.
        severity_code            NVARCHAR(30) NULL,
        severity_name            NVARCHAR(120) NULL,

        -- Optional impact + likelihood free-text (analyst's read at
        -- intake time; full 5x5 heatmap arrives with the Risk module).
        impact_summary           NVARCHAR(MAX) NULL,
        likelihood_summary       NVARCHAR(MAX) NULL,

        -- Lifecycle
        status_code              NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_risk_candidate_status DEFAULT N'Pending',

        -- Who raised
        requested_by_employee_id BIGINT NULL
            CONSTRAINT fk_pm_risk_candidate_requester
                REFERENCES grac_practice.organization_employee(employee_id),
        requested_dt             DATETIME2 NOT NULL
            CONSTRAINT df_pm_risk_candidate_requested_dt DEFAULT SYSUTCDATETIME(),

        -- Accept fields ("will track as formal risk")
        accepted_by_employee_id  BIGINT NULL
            CONSTRAINT fk_pm_risk_candidate_acceptor
                REFERENCES grac_practice.organization_employee(employee_id),
        accepted_dt              DATETIME2 NULL,
        acceptance_note          NVARCHAR(MAX) NULL,
        -- Placeholder for the future formal risk-register linkage; when
        -- the Risk module ships, we'll populate this with the risk_id
        -- from the enterprise risk register.
        formal_risk_ref          NVARCHAR(200) NULL,

        -- Reject fields
        rejected_by_employee_id  BIGINT NULL
            CONSTRAINT fk_pm_risk_candidate_rejecter
                REFERENCES grac_practice.organization_employee(employee_id),
        rejected_dt              DATETIME2 NULL,
        rejection_reason         NVARCHAR(MAX) NULL,

        record_status_id         INT NOT NULL
            CONSTRAINT fk_pm_risk_candidate_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_risk_candidate_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_risk_candidate_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL,

        CONSTRAINT ck_pm_risk_candidate_status
            CHECK (status_code IN (N'Pending', N'Accepted', N'Rejected', N'Withdrawn'))
    );
END
GO

IF OBJECT_ID('grac_practice.risk_candidate','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_risk_candidate_org_status'
                     AND object_id=OBJECT_ID('grac_practice.risk_candidate'))
    CREATE INDEX ix_pm_risk_candidate_org_status
        ON grac_practice.risk_candidate(organization_id, status_code, requested_dt DESC)
        INCLUDE(custom_gap_id, candidate_title, severity_code);
GO

IF OBJECT_ID('grac_practice.risk_candidate','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_risk_candidate_gap'
                     AND object_id=OBJECT_ID('grac_practice.risk_candidate'))
    CREATE INDEX ix_pm_risk_candidate_gap
        ON grac_practice.risk_candidate(custom_gap_id, status_code);
GO

-- =====================================================================
-- 2. risk_candidate_attachment (evidence-style, mirrors exception)
--    Manual (file) OR Automated (external location + locator). Same
--    vocabulary as practice_instance_evidence + exception_request_attachment.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_candidate_attachment','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.risk_candidate_attachment(
        attachment_id            BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_risk_candidate_attachment PRIMARY KEY,
        risk_candidate_id        BIGINT NOT NULL
            CONSTRAINT fk_pm_risk_candidate_attachment_candidate
                REFERENCES grac_practice.risk_candidate(risk_candidate_id),

        collection_method_id     INT NULL
            CONSTRAINT fk_pm_risk_candidate_attachment_method
                REFERENCES grac_practice.collection_method_master(collection_method_id),
        collection_method_code   NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_risk_candidate_attachment_method_code DEFAULT N'Manual',
        evidence_type_id         INT NULL
            CONSTRAINT fk_pm_risk_candidate_attachment_evidence_type
                REFERENCES grac_practice.evidence_type_master(evidence_type_id),
        evidence_type_code       NVARCHAR(60) NULL,

        -- Manual columns
        file_name                NVARCHAR(500) NULL,
        content_type             NVARCHAR(200) NULL,
        file_size_bytes          BIGINT NOT NULL
            CONSTRAINT df_pm_risk_candidate_attachment_size DEFAULT 0,
        file_data                VARBINARY(MAX) NULL,

        -- Automated columns
        evidence_location        NVARCHAR(500) NULL,   -- e.g. SharePoint / ServiceNow
        evidence_locator         NVARCHAR(500) NULL,   -- URL / record id

        uploaded_by_employee_id  BIGINT NULL
            CONSTRAINT fk_pm_risk_candidate_attachment_uploader
                REFERENCES grac_practice.organization_employee(employee_id),
        uploaded_dt              DATETIME2 NOT NULL
            CONSTRAINT df_pm_risk_candidate_attachment_dt DEFAULT SYSUTCDATETIME(),

        CONSTRAINT ck_pm_risk_candidate_attachment_method
            CHECK (collection_method_code IN (N'Manual', N'Automated')),
        CONSTRAINT ck_pm_risk_candidate_attachment_shape
            CHECK (
                (collection_method_code = N'Manual'    AND file_data IS NOT NULL AND file_name IS NOT NULL)
             OR (collection_method_code = N'Automated' AND evidence_location IS NOT NULL AND evidence_locator IS NOT NULL)
            )
    );
END
GO

IF OBJECT_ID('grac_practice.risk_candidate_attachment','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_risk_candidate_attachment_cand'
                     AND object_id=OBJECT_ID('grac_practice.risk_candidate_attachment'))
    CREATE INDEX ix_pm_risk_candidate_attachment_cand
        ON grac_practice.risk_candidate_attachment(risk_candidate_id, uploaded_dt DESC);
GO

-- =====================================================================
-- 3. risk_candidate_history (audit log)
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_candidate_history','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.risk_candidate_history(
        history_id               BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_risk_candidate_history PRIMARY KEY,
        risk_candidate_id        BIGINT NOT NULL
            CONSTRAINT fk_pm_risk_candidate_history_candidate
                REFERENCES grac_practice.risk_candidate(risk_candidate_id),
        action_code              NVARCHAR(40) NOT NULL,     -- Create / Accept / Reject / Withdraw / AttachmentUpload
        from_status_code         NVARCHAR(30) NULL,
        to_status_code           NVARCHAR(30) NULL,
        remark                   NVARCHAR(MAX) NULL,
        actor_employee_id        BIGINT NULL,
        actor_display_name       NVARCHAR(240) NULL,
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_risk_candidate_history_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_risk_candidate_history_entered_dt DEFAULT SYSUTCDATETIME()
    );
END
GO

IF OBJECT_ID('grac_practice.risk_candidate_history','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_risk_candidate_history_cand'
                     AND object_id=OBJECT_ID('grac_practice.risk_candidate_history'))
    CREATE INDEX ix_pm_risk_candidate_history_cand
        ON grac_practice.risk_candidate_history(risk_candidate_id, entered_dt DESC);
GO

PRINT '169 Risk Centre schema ready.';
GO
