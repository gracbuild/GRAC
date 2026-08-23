-- =====================================================================
-- 150 Document Acknowledgement -- schema
--
-- WHAT THIS ADDS
-- --------------
-- Four tables that carry the Phase 2 acknowledgement flow:
--
--   grac_practice.document_acknowledgement_pending
--       Queue of documents that have been Approve-published with the
--       acknowledgement flag ON, waiting to be rolled into a batch.
--       One row per (document, cycle_no). cycle_no starts at 1 on the
--       first publish, increments if the doc is re-published and
--       distribution changes (Phase 3 concern; Phase 2 always writes 1).
--
--   grac_practice.document_acknowledgement
--       An acknowledgement BATCH created by an admin -- a named,
--       due-dated bundle of one or more documents plus the users who
--       have to acknowledge each of them.
--
--   grac_practice.document_acknowledgement_document
--       Which documents are in a batch (many-to-many with cycle_no).
--       Legacy `tbl_acknowledgement_details` translated to PM naming.
--
--   grac_practice.document_acknowledgement_user
--       Per (batch, document, employee) row -- the acknowledgement
--       instance itself. status_code is 'Pending' until the employee
--       acknowledges, then flips to 'Acknowledged' with a timestamp.
--       UNIQUE(batch, document, employee) so a user cannot acknowledge
--       the same document twice within the same batch.
--
-- WHY BATCHES
-- -----------
-- The legacy design lets an admin group several published documents
-- into one campaign with a single due date. This matches the compliance
-- rhythm ("all Q3 policy refreshers by 30 Sep") without a per-document
-- notification storm. We keep the batch concept -- it is the natural
-- unit of tracking on the admin dashboard.
--
-- WHAT THIS MIGRATION DOES NOT DO
-- -------------------------------
--   * No stored procedures (see 151).
--   * No menu / permissions (see 152).
--   * The auto-populate of `document_acknowledgement_pending` on
--     Approve happens inside sp_document_upload_workflow_transition,
--     which 151 rewrites.
--
-- DEPENDS ON: 146. Rollback: 150_document_acknowledgement_schema_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Prerequisites -----------------------------------------------------
IF OBJECT_ID('grac_practice.document_upload','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_employee','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN
    RAISERROR('150: prerequisites missing. Run 146 and 009 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- document_acknowledgement_pending
-- =====================================================================
IF OBJECT_ID('grac_practice.document_acknowledgement_pending','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.document_acknowledgement_pending(
        pending_id          BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_doc_ack_pending PRIMARY KEY,
        document_id         BIGINT NOT NULL
            CONSTRAINT fk_pm_doc_ack_pending_document
                REFERENCES grac_practice.document_upload(document_id),
        cycle_no            INT NOT NULL
            CONSTRAINT df_pm_doc_ack_pending_cycle DEFAULT 1,
        -- status_code: 'Open' (waiting to be batched) or 'Processed' (in a batch)
        status_code         NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_doc_ack_pending_status DEFAULT N'Open',
        batch_id            BIGINT NULL,      -- set when moved into a batch (FK added later)
        processed_by        BIGINT NULL
            CONSTRAINT fk_pm_doc_ack_pending_processor
                REFERENCES grac_practice.organization_employee(employee_id),
        processed_dt        DATETIME2 NULL,
        record_status_id    INT NOT NULL
            CONSTRAINT fk_pm_doc_ack_pending_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_doc_ack_pending_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_doc_ack_pending_entered_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_doc_ack_pending UNIQUE(document_id, cycle_no)
    );
END
GO

IF OBJECT_ID('grac_practice.document_acknowledgement_pending','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_doc_ack_pending_status'
                     AND object_id=OBJECT_ID('grac_practice.document_acknowledgement_pending'))
    CREATE INDEX ix_pm_doc_ack_pending_status
        ON grac_practice.document_acknowledgement_pending(status_code, document_id)
        INCLUDE(cycle_no, batch_id);
GO

-- =====================================================================
-- document_acknowledgement  (batch master)
-- =====================================================================
IF OBJECT_ID('grac_practice.document_acknowledgement','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.document_acknowledgement(
        acknowledgement_id      BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_document_acknowledgement PRIMARY KEY,
        organization_id         BIGINT NOT NULL
            CONSTRAINT fk_pm_document_acknowledgement_organization
                REFERENCES grac_practice.organization(organization_id),
        acknowledgement_name    NVARCHAR(200) NOT NULL,
        due_date                DATE NULL,
        -- status_code: 'Open' (users still working through it) or 'Completed'
        status_code             NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_document_acknowledgement_status DEFAULT N'Open',
        record_status_id        INT NOT NULL
            CONSTRAINT fk_pm_document_acknowledgement_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_document_acknowledgement_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_document_acknowledgement_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL
    );
END
GO

-- Deferred FK: pending.batch_id -> document_acknowledgement.acknowledgement_id
-- (added here because master table only exists after its own CREATE above).
IF OBJECT_ID('grac_practice.document_acknowledgement','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.document_acknowledgement_pending','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_doc_ack_pending_batch')
    ALTER TABLE grac_practice.document_acknowledgement_pending
        ADD CONSTRAINT fk_pm_doc_ack_pending_batch
            FOREIGN KEY(batch_id)
            REFERENCES grac_practice.document_acknowledgement(acknowledgement_id);
GO

IF OBJECT_ID('grac_practice.document_acknowledgement','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_document_acknowledgement_org'
                     AND object_id=OBJECT_ID('grac_practice.document_acknowledgement'))
    CREATE INDEX ix_pm_document_acknowledgement_org
        ON grac_practice.document_acknowledgement(organization_id, status_code, due_date DESC)
        INCLUDE(acknowledgement_name);
GO

-- =====================================================================
-- document_acknowledgement_document  (batch -> documents)
-- =====================================================================
IF OBJECT_ID('grac_practice.document_acknowledgement_document','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.document_acknowledgement_document(
        detail_id           BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_doc_ack_doc PRIMARY KEY,
        acknowledgement_id  BIGINT NOT NULL
            CONSTRAINT fk_pm_doc_ack_doc_batch
                REFERENCES grac_practice.document_acknowledgement(acknowledgement_id),
        document_id         BIGINT NOT NULL
            CONSTRAINT fk_pm_doc_ack_doc_document
                REFERENCES grac_practice.document_upload(document_id),
        cycle_no            INT NOT NULL
            CONSTRAINT df_pm_doc_ack_doc_cycle DEFAULT 1,
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_doc_ack_doc_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_doc_ack_doc_entered_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_doc_ack_doc UNIQUE(acknowledgement_id, document_id, cycle_no)
    );
END
GO

IF OBJECT_ID('grac_practice.document_acknowledgement_document','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_doc_ack_doc_document'
                     AND object_id=OBJECT_ID('grac_practice.document_acknowledgement_document'))
    CREATE INDEX ix_pm_doc_ack_doc_document
        ON grac_practice.document_acknowledgement_document(document_id, cycle_no)
        INCLUDE(acknowledgement_id);
GO

-- =====================================================================
-- document_acknowledgement_user  (per-employee acknowledgement instance)
--
-- The atomic unit of tracking:
--   * status_code 'Pending'      -- user has not acknowledged yet
--   * status_code 'Acknowledged' -- user clicked Acknowledge; timestamp
--                                    recorded in acknowledged_dt
--
-- UNIQUE(acknowledgement_id, document_id, employee_id) so an admin
-- cannot double-add the same person to the same document in a batch.
-- =====================================================================
IF OBJECT_ID('grac_practice.document_acknowledgement_user','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.document_acknowledgement_user(
        acknowledgement_user_id BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_doc_ack_user PRIMARY KEY,
        acknowledgement_id      BIGINT NOT NULL
            CONSTRAINT fk_pm_doc_ack_user_batch
                REFERENCES grac_practice.document_acknowledgement(acknowledgement_id),
        document_id             BIGINT NOT NULL
            CONSTRAINT fk_pm_doc_ack_user_document
                REFERENCES grac_practice.document_upload(document_id),
        employee_id             BIGINT NOT NULL
            CONSTRAINT fk_pm_doc_ack_user_employee
                REFERENCES grac_practice.organization_employee(employee_id),
        status_code             NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_doc_ack_user_status DEFAULT N'Pending',
        acknowledged_dt         DATETIME2 NULL,
        remark                  NVARCHAR(MAX) NULL,
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_doc_ack_user_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_doc_ack_user_entered_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_doc_ack_user UNIQUE(acknowledgement_id, document_id, employee_id)
    );
END
GO

IF OBJECT_ID('grac_practice.document_acknowledgement_user','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_doc_ack_user_employee'
                     AND object_id=OBJECT_ID('grac_practice.document_acknowledgement_user'))
    CREATE INDEX ix_pm_doc_ack_user_employee
        ON grac_practice.document_acknowledgement_user(employee_id, status_code)
        INCLUDE(acknowledgement_id, document_id, acknowledged_dt);
GO

IF OBJECT_ID('grac_practice.document_acknowledgement_user','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_doc_ack_user_batch_doc'
                     AND object_id=OBJECT_ID('grac_practice.document_acknowledgement_user'))
    CREATE INDEX ix_pm_doc_ack_user_batch_doc
        ON grac_practice.document_acknowledgement_user(acknowledgement_id, document_id, status_code);
GO

-- End 150 =============================================================
