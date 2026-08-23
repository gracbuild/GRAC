-- =====================================================================
-- 146 Document Upload -- schema
--
-- WHAT THIS MODULE IS
-- -------------------
-- The Document Upload and Acknowledgement module lets an organization
-- register controlled documents (policies, procedures, standards),
-- distribute them to departments or specific employees, run them
-- through a review-and-approve workflow, and track who has
-- acknowledged the currently published version.
--
-- WHY THIS MIGRATION EXISTS
-- -------------------------
-- The module was originally built in the legacy GRAC Plus stack against
-- `dbo.tbl_document_*` tables that use INT keys, VARCHAR columns and
-- external file storage (GRAC_DocumentRepository..tbl_document_register_File).
-- This migration re-implements the same domain inside the
-- `grac_practice` schema so it can live alongside Practice Management
-- and reuse the existing identity/permission model (ControlManagement
-- for authentication, `organization_employee` for people).
--
-- WHAT THIS MIGRATION ADDS
-- ------------------------
--   Foundational lookup (used only by this module today):
--     grac_practice.organization_department
--     grac_practice.document_type_master
--     grac_practice.document_stage_master
--     grac_practice.document_status_master
--     grac_practice.document_source_type_master
--     grac_practice.document_distribution_type_master
--
--   Main + supporting tables:
--     grac_practice.document_upload
--     grac_practice.document_upload_file
--     grac_practice.document_upload_distribution_department
--     grac_practice.document_upload_distribution_employee
--     grac_practice.document_upload_history
--
-- Acknowledgement tables (tbl_acknowledgement_*) are intentionally NOT
-- created here -- they arrive in Phase 2 (migration 150+) so this
-- migration ships an installable upload+workflow slice on its own.
--
-- WHAT THIS MIGRATION DOES NOT DO
-- -------------------------------
--   * No stored procedures (see 147).
--   * No seed data (see 148 for lookup seed, 149 for menu seed).
--   * No file storage in a separate database. The legacy design put file
--     binaries in GRAC_DocumentRepository. We keep them in the same
--     database as the metadata, in a dedicated table so the fat column
--     never widens the main register. Moving to a separate DB or blob
--     store later is a lift-and-shift of one table, not a redesign.
--
-- DESIGN NOTES
-- ------------
--   * Identity keys throughout (BIGINT IDENTITY). The legacy design
--     generated document_id with `select max(id)+1` under a transaction,
--     which races under concurrency. IDENTITY removes the race.
--   * document_code (the user-visible short code, e.g. "DU-15") is
--     still generated in the save proc so the visible sequence per
--     organization stays contiguous. It is UNIQUE per organization.
--   * usr_id in legacy tables mapped to a login user. Here we point at
--     `organization_employee.employee_id` because Practice Management
--     models every person as an employee. Authentication users come from
--     ControlManagement and are mapped to employees at sign-in time.
--   * Distribution splits by type: 1 = by department, 2 = by employee.
--     Only the matching child table is populated for a document.
--   * document_upload_history is a shadow copy written by the save proc
--     on every material change. It replaces the two `_his` tables in
--     the legacy design and captures why the change happened
--     (change_reason + change_remark).
--   * Every mutable table carries the standard PM audit set
--     (record_status_id, entered_by, entered_dt, updated_by, updated_dt)
--     so soft-delete and provenance work the same way as elsewhere.
-- =====================================================================

-- =====================================================================
-- Prerequisites
-- =====================================================================
IF OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_employee','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN
    RAISERROR('146: prerequisites missing. Run 001, 002 and 009 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- organization_department
--
-- The legacy design has a `dbo.tbl_department_mst` keyed by department_id
-- with a company_id (== organization_id here) scope. Practice Management
-- currently stores department as a free-text column on
-- organization_employee (see 009). Document distribution needs a first-
-- class department so a document can be "sent to Finance" and stay
-- linked when an employee moves teams.
--
-- We introduce the table in the `grac_practice` schema, scoped by
-- organization, unique on (organization_id, department_name). If a
-- future feature needs departments too it should reuse this table
-- rather than mint its own.
-- =====================================================================
IF OBJECT_ID('grac_practice.organization_department','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.organization_department(
        department_id     BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_organization_department PRIMARY KEY,
        organization_id   BIGINT NOT NULL
            CONSTRAINT fk_pm_org_department_organization
                REFERENCES grac_practice.organization(organization_id),
        department_code   NVARCHAR(80) NULL,
        department_name   NVARCHAR(200) NOT NULL,
        description       NVARCHAR(1000) NULL,
        status            NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_org_department_status DEFAULT N'Active',
        record_status_id  INT NOT NULL
            CONSTRAINT fk_pm_org_department_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_org_department_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_org_department_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL,
        CONSTRAINT uq_pm_org_department_name UNIQUE(organization_id, department_name)
    );
END
GO

IF OBJECT_ID('grac_practice.organization_department','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_org_department_org'
                     AND object_id=OBJECT_ID('grac_practice.organization_department'))
    CREATE INDEX ix_pm_org_department_org
        ON grac_practice.organization_department(organization_id, record_status_id)
        INCLUDE(department_name);
GO

-- =====================================================================
-- document_type_master
-- Analogous to dbo.tbl_document_type. Global (not org-scoped) so
-- catalog values ("Policy", "Procedure", "SOP", "Guideline") stay
-- consistent across every organization.
-- =====================================================================
IF OBJECT_ID('grac_practice.document_type_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.document_type_master(
        document_type_id  INT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_document_type_master PRIMARY KEY,
        type_code         NVARCHAR(60)  NOT NULL,
        document_type     NVARCHAR(200) NOT NULL,
        description       NVARCHAR(500) NULL,
        sort_order        INT NOT NULL
            CONSTRAINT df_pm_doc_type_sort DEFAULT 100,
        status            NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_doc_type_status DEFAULT N'Active',
        record_status_id  INT NOT NULL
            CONSTRAINT fk_pm_doc_type_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_doc_type_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_doc_type_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL,
        CONSTRAINT uq_pm_doc_type_code UNIQUE(type_code)
    );
END
GO

-- =====================================================================
-- document_stage_master
-- Where the document is in its lifecycle (Draft, InReview, Approved,
-- Published, Retired). Global. sort_order drives display order.
-- =====================================================================
IF OBJECT_ID('grac_practice.document_stage_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.document_stage_master(
        document_stage_id INT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_document_stage_master PRIMARY KEY,
        stage_code        NVARCHAR(60)  NOT NULL,
        document_stage    NVARCHAR(200) NOT NULL,
        description       NVARCHAR(500) NULL,
        sort_order        INT NOT NULL
            CONSTRAINT df_pm_doc_stage_sort DEFAULT 100,
        status            NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_doc_stage_status DEFAULT N'Active',
        record_status_id  INT NOT NULL
            CONSTRAINT fk_pm_doc_stage_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_doc_stage_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_doc_stage_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL,
        CONSTRAINT uq_pm_doc_stage_code UNIQUE(stage_code)
    );
END
GO

-- =====================================================================
-- document_status_master
-- Active/Inactive style flag on the document itself. Stage answers
-- "where is this in its lifecycle"; status answers "should we still be
-- looking at it at all".
-- =====================================================================
IF OBJECT_ID('grac_practice.document_status_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.document_status_master(
        document_status_id INT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_document_status_master PRIMARY KEY,
        status_code        NVARCHAR(60)  NOT NULL,
        document_status    NVARCHAR(200) NOT NULL,
        description        NVARCHAR(500) NULL,
        sort_order         INT NOT NULL
            CONSTRAINT df_pm_doc_status_sort DEFAULT 100,
        status             NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_doc_status_status DEFAULT N'Active',
        record_status_id   INT NOT NULL
            CONSTRAINT fk_pm_doc_status_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_doc_status_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_doc_status_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL,
        CONSTRAINT uq_pm_doc_status_code UNIQUE(status_code)
    );
END
GO

-- =====================================================================
-- document_source_type_master
-- Where the document originated (Internal, External, Regulatory,
-- ThirdParty). Retained from legacy for reporting parity.
-- =====================================================================
IF OBJECT_ID('grac_practice.document_source_type_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.document_source_type_master(
        source_type_id    INT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_document_source_type_master PRIMARY KEY,
        source_code       NVARCHAR(60)  NOT NULL,
        source_type       NVARCHAR(200) NOT NULL,
        description       NVARCHAR(500) NULL,
        sort_order        INT NOT NULL
            CONSTRAINT df_pm_doc_source_sort DEFAULT 100,
        status            NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_doc_source_status DEFAULT N'Active',
        record_status_id  INT NOT NULL
            CONSTRAINT fk_pm_doc_source_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_doc_source_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_doc_source_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL,
        CONSTRAINT uq_pm_doc_source_code UNIQUE(source_code)
    );
END
GO

-- =====================================================================
-- document_distribution_type_master
-- ByDepartment / ByEmployee / All. Kept as a lookup rather than an enum
-- so a future distribution mode (e.g. ByRole) can be added by data.
-- =====================================================================
IF OBJECT_ID('grac_practice.document_distribution_type_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.document_distribution_type_master(
        distribution_type_id INT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_document_distribution_type_master PRIMARY KEY,
        distribution_code    NVARCHAR(60)  NOT NULL,
        distribution_type    NVARCHAR(200) NOT NULL,
        description          NVARCHAR(500) NULL,
        sort_order           INT NOT NULL
            CONSTRAINT df_pm_dist_type_sort DEFAULT 100,
        status               NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_dist_type_status DEFAULT N'Active',
        record_status_id     INT NOT NULL
            CONSTRAINT fk_pm_dist_type_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_dist_type_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_dist_type_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL,
        CONSTRAINT uq_pm_dist_type_code UNIQUE(distribution_code)
    );
END
GO

-- =====================================================================
-- document_upload  (main register)
--
-- One row per document, per organization. document_code is the visible
-- short code ("DU-15") generated by the save proc; company_document_code
-- is the customer-entered internal code (matches legacy naming, kept
-- so reports read the same).
--
-- reviewer_id / approver_id / owner_id all point to organization_employee
-- rather than a login user because the person responsible for a policy
-- is defined by the org, not by whether they happen to be signed in.
--
-- current_stage_id / current_status_id hold the LATEST state; the
-- history table records the path taken.
-- =====================================================================
IF OBJECT_ID('grac_practice.document_upload','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.document_upload(
        document_id           BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_document_upload PRIMARY KEY,
        organization_id       BIGINT NOT NULL
            CONSTRAINT fk_pm_document_upload_organization
                REFERENCES grac_practice.organization(organization_id),

        document_code           NVARCHAR(50)  NOT NULL, -- system-generated, e.g. DU-15
        company_document_code   NVARCHAR(100) NULL,     -- user-entered internal code
        document_name           NVARCHAR(500) NOT NULL,

        document_type_id        INT NOT NULL
            CONSTRAINT fk_pm_document_upload_type
                REFERENCES grac_practice.document_type_master(document_type_id),
        source_type_id          INT NULL
            CONSTRAINT fk_pm_document_upload_source
                REFERENCES grac_practice.document_source_type_master(source_type_id),

        version_number          NVARCHAR(30) NOT NULL,
        effective_date          DATE NULL,
        next_review_date        DATE NULL,

        current_stage_id        INT NOT NULL
            CONSTRAINT fk_pm_document_upload_stage
                REFERENCES grac_practice.document_stage_master(document_stage_id),
        current_status_id       INT NOT NULL
            CONSTRAINT fk_pm_document_upload_status
                REFERENCES grac_practice.document_status_master(document_status_id),

        change_summary          NVARCHAR(MAX) NULL,
        keywords_tag            NVARCHAR(MAX) NULL,

        owner_id                BIGINT NULL
            CONSTRAINT fk_pm_document_upload_owner
                REFERENCES grac_practice.organization_employee(employee_id),
        reviewer_id             BIGINT NULL
            CONSTRAINT fk_pm_document_upload_reviewer
                REFERENCES grac_practice.organization_employee(employee_id),
        approver_id             BIGINT NULL
            CONSTRAINT fk_pm_document_upload_approver
                REFERENCES grac_practice.organization_employee(employee_id),

        distribution_type_id    INT NULL
            CONSTRAINT fk_pm_document_upload_dist_type
                REFERENCES grac_practice.document_distribution_type_master(distribution_type_id),
        acknowledgement_required BIT NOT NULL
            CONSTRAINT df_pm_document_upload_ack_flag DEFAULT 0,

        -- Review / approve outcome (final action per current cycle).
        reviewed_by             BIGINT NULL
            CONSTRAINT fk_pm_document_upload_reviewed_by
                REFERENCES grac_practice.organization_employee(employee_id),
        reviewed_on             DATETIME2 NULL,
        review_remark           NVARCHAR(MAX) NULL,
        approved_by             BIGINT NULL
            CONSTRAINT fk_pm_document_upload_approved_by
                REFERENCES grac_practice.organization_employee(employee_id),
        approved_on             DATETIME2 NULL,
        approved_remark         NVARCHAR(MAX) NULL,

        record_status_id        INT NOT NULL
            CONSTRAINT fk_pm_document_upload_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_document_upload_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_document_upload_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL,

        CONSTRAINT uq_pm_document_upload_code UNIQUE(organization_id, document_code),
        CONSTRAINT uq_pm_document_upload_name UNIQUE(organization_id, document_name)
    );
END
GO

IF OBJECT_ID('grac_practice.document_upload','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_document_upload_org_status'
                     AND object_id=OBJECT_ID('grac_practice.document_upload'))
    CREATE INDEX ix_pm_document_upload_org_status
        ON grac_practice.document_upload(organization_id, record_status_id, current_stage_id)
        INCLUDE(document_name, document_code, updated_dt);
GO

IF OBJECT_ID('grac_practice.document_upload','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_document_upload_owner'
                     AND object_id=OBJECT_ID('grac_practice.document_upload'))
    CREATE INDEX ix_pm_document_upload_owner
        ON grac_practice.document_upload(owner_id)
        INCLUDE(organization_id, current_stage_id, current_status_id);
GO

-- =====================================================================
-- document_upload_file  (binary storage)
--
-- Split from the main register so the fat VARBINARY column never
-- widens table scans on document_upload. One row per uploaded version;
-- a re-upload for the same document creates a NEW row, so version
-- history is queryable without going to _history.
-- =====================================================================
IF OBJECT_ID('grac_practice.document_upload_file','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.document_upload_file(
        document_file_id  BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_document_upload_file PRIMARY KEY,
        document_id       BIGINT NOT NULL
            CONSTRAINT fk_pm_document_upload_file_document
                REFERENCES grac_practice.document_upload(document_id),
        version_number    NVARCHAR(30) NOT NULL,
        file_name         NVARCHAR(500) NOT NULL,
        content_type      NVARCHAR(200) NULL,
        file_size_bytes   BIGINT NOT NULL
            CONSTRAINT df_pm_document_upload_file_size DEFAULT 0,
        file_data         VARBINARY(MAX) NOT NULL,
        is_current        BIT NOT NULL
            CONSTRAINT df_pm_document_upload_file_current DEFAULT 1,
        uploaded_by       BIGINT NULL
            CONSTRAINT fk_pm_document_upload_file_uploader
                REFERENCES grac_practice.organization_employee(employee_id),
        uploaded_dt       DATETIME2 NOT NULL
            CONSTRAINT df_pm_document_upload_file_dt DEFAULT SYSUTCDATETIME()
    );
END
GO

IF OBJECT_ID('grac_practice.document_upload_file','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_document_upload_file_current'
                     AND object_id=OBJECT_ID('grac_practice.document_upload_file'))
    CREATE INDEX ix_pm_document_upload_file_current
        ON grac_practice.document_upload_file(document_id, is_current DESC, uploaded_dt DESC);
GO

-- =====================================================================
-- document_upload_distribution_department
-- Which departments (in the owning organization) the document is
-- distributed to. Populated only when distribution_type_id resolves to
-- "ByDepartment".
-- =====================================================================
IF OBJECT_ID('grac_practice.document_upload_distribution_department','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.document_upload_distribution_department(
        distribution_id   BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_document_upload_dist_dept PRIMARY KEY,
        document_id       BIGINT NOT NULL
            CONSTRAINT fk_pm_document_upload_dist_dept_document
                REFERENCES grac_practice.document_upload(document_id),
        department_id     BIGINT NOT NULL
            CONSTRAINT fk_pm_document_upload_dist_dept_department
                REFERENCES grac_practice.organization_department(department_id),
        record_status_id  INT NOT NULL
            CONSTRAINT fk_pm_document_upload_dist_dept_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_document_upload_dist_dept_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_document_upload_dist_dept_entered_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_document_upload_dist_dept UNIQUE(document_id, department_id)
    );
END
GO

IF OBJECT_ID('grac_practice.document_upload_distribution_department','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_document_upload_dist_dept_dept'
                     AND object_id=OBJECT_ID('grac_practice.document_upload_distribution_department'))
    CREATE INDEX ix_pm_document_upload_dist_dept_dept
        ON grac_practice.document_upload_distribution_department(department_id, record_status_id);
GO

-- =====================================================================
-- document_upload_distribution_employee
-- Individual employees the document is distributed to. Populated only
-- when distribution_type_id resolves to "ByEmployee".
-- =====================================================================
IF OBJECT_ID('grac_practice.document_upload_distribution_employee','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.document_upload_distribution_employee(
        distribution_id   BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_document_upload_dist_emp PRIMARY KEY,
        document_id       BIGINT NOT NULL
            CONSTRAINT fk_pm_document_upload_dist_emp_document
                REFERENCES grac_practice.document_upload(document_id),
        employee_id       BIGINT NOT NULL
            CONSTRAINT fk_pm_document_upload_dist_emp_employee
                REFERENCES grac_practice.organization_employee(employee_id),
        record_status_id  INT NOT NULL
            CONSTRAINT fk_pm_document_upload_dist_emp_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_document_upload_dist_emp_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_document_upload_dist_emp_entered_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_document_upload_dist_emp UNIQUE(document_id, employee_id)
    );
END
GO

IF OBJECT_ID('grac_practice.document_upload_distribution_employee','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_document_upload_dist_emp_emp'
                     AND object_id=OBJECT_ID('grac_practice.document_upload_distribution_employee'))
    CREATE INDEX ix_pm_document_upload_dist_emp_emp
        ON grac_practice.document_upload_distribution_employee(employee_id, record_status_id);
GO

-- =====================================================================
-- document_upload_history
--
-- One row per material change to document_upload. Replaces the legacy
-- `_his` shadow tables: instead of duplicating every column on every
-- change, we capture the change_reason (Create / Edit / StatusChange /
-- Submit / Review / Approve / Reject / Retire) and the associated
-- remark, plus a JSON snapshot of the register row at that instant.
--
-- Snapshot-as-JSON keeps the table narrow, survives future column
-- additions without a schema change on the history side, and is easy
-- to render on a workflow timeline.
-- =====================================================================
IF OBJECT_ID('grac_practice.document_upload_history','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.document_upload_history(
        history_id        BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_document_upload_history PRIMARY KEY,
        document_id       BIGINT NOT NULL
            CONSTRAINT fk_pm_document_upload_history_document
                REFERENCES grac_practice.document_upload(document_id),
        change_reason     NVARCHAR(60)  NOT NULL,  -- Create / Edit / StatusChange / Submit / Review / Approve / Reject / Retire
        from_stage_id     INT NULL
            CONSTRAINT fk_pm_document_upload_history_from_stage
                REFERENCES grac_practice.document_stage_master(document_stage_id),
        to_stage_id       INT NULL
            CONSTRAINT fk_pm_document_upload_history_to_stage
                REFERENCES grac_practice.document_stage_master(document_stage_id),
        from_status_id    INT NULL
            CONSTRAINT fk_pm_document_upload_history_from_status
                REFERENCES grac_practice.document_status_master(document_status_id),
        to_status_id      INT NULL
            CONSTRAINT fk_pm_document_upload_history_to_status
                REFERENCES grac_practice.document_status_master(document_status_id),
        actor_employee_id BIGINT NULL
            CONSTRAINT fk_pm_document_upload_history_actor
                REFERENCES grac_practice.organization_employee(employee_id),
        remark            NVARCHAR(MAX) NULL,
        snapshot_json     NVARCHAR(MAX) NULL,
        acted_by          NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_document_upload_history_acted_by DEFAULT N'system',
        acted_dt          DATETIME2 NOT NULL
            CONSTRAINT df_pm_document_upload_history_acted_dt DEFAULT SYSUTCDATETIME()
    );
END
GO

IF OBJECT_ID('grac_practice.document_upload_history','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_document_upload_history_doc'
                     AND object_id=OBJECT_ID('grac_practice.document_upload_history'))
    CREATE INDEX ix_pm_document_upload_history_doc
        ON grac_practice.document_upload_history(document_id, acted_dt DESC)
        INCLUDE(change_reason, actor_employee_id);
GO

-- End 146 =============================================================
