-- =====================================================================
-- 066 Workflow & Event-Driven Assurance Engine -- schema
--
-- BRD: GRAC -- Workflow & Event-Driven Assurance Engine (v1.0)
--
-- Introduces the Event Assurance Engine (BRD Sec 4B). This is entirely
-- independent from the Practice Assurance Engine (Practice Instances /
-- Obligations); no FK/dependency crosses the boundary.
--
-- Tables introduced (all under grac_practice, org-scoped, metadata-driven):
--   workflow                       Sec 6
--   workflow_stage                 Sec 7
--   entity_type_master             Sec 9  (org-defined entity types)
--   event_definition               Sec 8
--   checklist                      Sec 11
--   checklist_item                 Sec 11
--   event_checklist_mapping        Sec 10 (Entity + Event -> Checklist)
--   event_instance                 Sec 13/14 (event -> assurance)
--   event_instance_item            per-item execution row
--   event_gap                      Sec 15 (event-driven gaps)
--   event_audit                    Sec 18 (config + execution audit trail)
--
-- Design principles honoured (BRD Sec 21):
--   * Organization-scoped (organization_id NOT NULL on every entity).
--   * Metadata-driven: entity types, events, checklists all configurable.
--   * Version-controlled: workflow/checklist carry a version column.
--   * Extensible: JSON payload columns kept as NVARCHAR(MAX) for
--     source-system parity without schema change.
--
-- ASCII-only, plain MERGE / INSERT constructs (matches migration 054).
-- Rollback: database/066_workflow_engine_schema_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    RAISERROR('066: schema grac_practice missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- workflow (BRD Sec 6)
-- =====================================================================
IF OBJECT_ID('grac_practice.workflow','U') IS NULL
CREATE TABLE grac_practice.workflow(
    workflow_id             BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_workflow PRIMARY KEY,
    organization_id         BIGINT        NOT NULL,
    workflow_code           NVARCHAR(60)  NOT NULL,
    workflow_name           NVARCHAR(200) NOT NULL,
    description             NVARCHAR(MAX) NULL,
    applicable_entity_type  NVARCHAR(100) NULL,  -- Sec 6: applicable entity
    version                 NVARCHAR(20)  NOT NULL
        CONSTRAINT df_pm_workflow_version DEFAULT N'1.0',
    owner_employee_id       BIGINT        NULL,
    status                  NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_workflow_status DEFAULT N'Active',
    is_default_template     BIT           NOT NULL
        CONSTRAINT df_pm_workflow_is_default DEFAULT 0,
    entered_by              NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_workflow_entered_by DEFAULT 'system',
    entered_dt              DATETIME2     NOT NULL
        CONSTRAINT df_pm_workflow_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by              NVARCHAR(100) NULL,
    updated_dt              DATETIME2     NULL,
    CONSTRAINT ck_pm_workflow_status
        CHECK (status IN (N'Active', N'Inactive', N'Draft', N'Archived')),
    CONSTRAINT uq_pm_workflow_org_code
        UNIQUE (organization_id, workflow_code)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_workflow_org_status' AND object_id = OBJECT_ID('grac_practice.workflow'))
    CREATE INDEX ix_pm_workflow_org_status
        ON grac_practice.workflow(organization_id, status)
        INCLUDE (workflow_name, applicable_entity_type);
GO

-- =====================================================================
-- workflow_stage (BRD Sec 7)
-- =====================================================================
IF OBJECT_ID('grac_practice.workflow_stage','U') IS NULL
CREATE TABLE grac_practice.workflow_stage(
    workflow_stage_id       BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_workflow_stage PRIMARY KEY,
    workflow_id             BIGINT        NOT NULL,
    stage_code              NVARCHAR(60)  NOT NULL,
    stage_name              NVARCHAR(200) NOT NULL,
    description             NVARCHAR(MAX) NULL,
    stage_sequence          INT           NOT NULL
        CONSTRAINT df_pm_workflow_stage_seq DEFAULT 1,
    previous_stage_id       BIGINT        NULL,
    next_stage_id           BIGINT        NULL,
    allowed_transitions     NVARCHAR(1000) NULL,  -- CSV of stage_codes
    status                  NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_workflow_stage_status DEFAULT N'Active',
    entered_by              NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_workflow_stage_entered_by DEFAULT 'system',
    entered_dt              DATETIME2     NOT NULL
        CONSTRAINT df_pm_workflow_stage_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by              NVARCHAR(100) NULL,
    updated_dt              DATETIME2     NULL,
    CONSTRAINT ck_pm_workflow_stage_status
        CHECK (status IN (N'Active', N'Inactive')),
    CONSTRAINT fk_pm_workflow_stage_workflow
        FOREIGN KEY (workflow_id) REFERENCES grac_practice.workflow(workflow_id),
    CONSTRAINT uq_pm_workflow_stage_workflow_code
        UNIQUE (workflow_id, stage_code)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_workflow_stage_workflow_seq' AND object_id = OBJECT_ID('grac_practice.workflow_stage'))
    CREATE INDEX ix_pm_workflow_stage_workflow_seq
        ON grac_practice.workflow_stage(workflow_id, stage_sequence);
GO

-- =====================================================================
-- entity_type_master (BRD Sec 9)
--   Configurable, org-defined. GRAC does not hard-code the list.
-- =====================================================================
IF OBJECT_ID('grac_practice.entity_type_master','U') IS NULL
CREATE TABLE grac_practice.entity_type_master(
    entity_type_id          BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_entity_type PRIMARY KEY,
    organization_id         BIGINT        NOT NULL,
    entity_type_code        NVARCHAR(60)  NOT NULL,
    entity_type_name        NVARCHAR(200) NOT NULL,
    description             NVARCHAR(MAX) NULL,
    entity_category         NVARCHAR(60)  NULL,  -- Asset / Tool / Application / People / Vendor / Branch / Department / Custom
    status                  NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_entity_type_status DEFAULT N'Active',
    entered_by              NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_entity_type_entered_by DEFAULT 'system',
    entered_dt              DATETIME2     NOT NULL
        CONSTRAINT df_pm_entity_type_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by              NVARCHAR(100) NULL,
    updated_dt              DATETIME2     NULL,
    CONSTRAINT ck_pm_entity_type_status
        CHECK (status IN (N'Active', N'Inactive')),
    CONSTRAINT uq_pm_entity_type_org_code
        UNIQUE (organization_id, entity_type_code)
);
GO

-- =====================================================================
-- event_definition (BRD Sec 8)
-- =====================================================================
IF OBJECT_ID('grac_practice.event_definition','U') IS NULL
CREATE TABLE grac_practice.event_definition(
    event_definition_id     BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_event_definition PRIMARY KEY,
    organization_id         BIGINT        NOT NULL,
    event_code              NVARCHAR(60)  NOT NULL,
    event_name              NVARCHAR(200) NOT NULL,
    description             NVARCHAR(MAX) NULL,
    entity_category         NVARCHAR(60)  NULL,   -- People / Assets / Vendor / Applications / Custom
    workflow_id             BIGINT        NULL,   -- optional link to a workflow
    workflow_stage_id       BIGINT        NULL,   -- optional link to a stage
    trigger_source          NVARCHAR(60)  NULL,   -- Manual / API / HRMS / ERP / ITSM / CMDB / Webhook / MQ
    status                  NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_event_definition_status DEFAULT N'Active',
    entered_by              NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_event_definition_entered_by DEFAULT 'system',
    entered_dt              DATETIME2     NOT NULL
        CONSTRAINT df_pm_event_definition_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by              NVARCHAR(100) NULL,
    updated_dt              DATETIME2     NULL,
    CONSTRAINT ck_pm_event_definition_status
        CHECK (status IN (N'Active', N'Inactive', N'Draft')),
    CONSTRAINT uq_pm_event_definition_org_code
        UNIQUE (organization_id, event_code),
    CONSTRAINT fk_pm_event_definition_workflow
        FOREIGN KEY (workflow_id) REFERENCES grac_practice.workflow(workflow_id),
    CONSTRAINT fk_pm_event_definition_stage
        FOREIGN KEY (workflow_stage_id) REFERENCES grac_practice.workflow_stage(workflow_stage_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_event_definition_org_status' AND object_id = OBJECT_ID('grac_practice.event_definition'))
    CREATE INDEX ix_pm_event_definition_org_status
        ON grac_practice.event_definition(organization_id, status)
        INCLUDE (event_name, entity_category);
GO

-- =====================================================================
-- checklist (BRD Sec 11) + checklist_item
-- =====================================================================
IF OBJECT_ID('grac_practice.checklist','U') IS NULL
CREATE TABLE grac_practice.checklist(
    checklist_id            BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_checklist PRIMARY KEY,
    organization_id         BIGINT        NOT NULL,
    checklist_code          NVARCHAR(60)  NOT NULL,
    checklist_name          NVARCHAR(200) NOT NULL,
    description             NVARCHAR(MAX) NULL,
    version                 NVARCHAR(20)  NOT NULL
        CONSTRAINT df_pm_checklist_version DEFAULT N'1.0',
    status                  NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_checklist_status DEFAULT N'Active',
    entered_by              NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_checklist_entered_by DEFAULT 'system',
    entered_dt              DATETIME2     NOT NULL
        CONSTRAINT df_pm_checklist_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by              NVARCHAR(100) NULL,
    updated_dt              DATETIME2     NULL,
    CONSTRAINT ck_pm_checklist_status
        CHECK (status IN (N'Active', N'Inactive', N'Draft', N'Archived')),
    CONSTRAINT uq_pm_checklist_org_code
        UNIQUE (organization_id, checklist_code)
);
GO

IF OBJECT_ID('grac_practice.checklist_item','U') IS NULL
CREATE TABLE grac_practice.checklist_item(
    checklist_item_id       BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_checklist_item PRIMARY KEY,
    checklist_id            BIGINT        NOT NULL,
    item_sequence           INT           NOT NULL
        CONSTRAINT df_pm_checklist_item_seq DEFAULT 1,
    item_text               NVARCHAR(500) NOT NULL,
    item_type               NVARCHAR(60)  NOT NULL
        CONSTRAINT df_pm_checklist_item_type DEFAULT N'Manual',
    is_mandatory            BIT           NOT NULL
        CONSTRAINT df_pm_checklist_item_mandatory DEFAULT 1,
    evidence_required       BIT           NOT NULL
        CONSTRAINT df_pm_checklist_item_evidence DEFAULT 0,
    attachment_required     BIT           NOT NULL
        CONSTRAINT df_pm_checklist_item_attachment DEFAULT 0,
    approval_required       BIT           NOT NULL
        CONSTRAINT df_pm_checklist_item_approval DEFAULT 0,
    responsible_role        NVARCHAR(100) NULL,
    due_period_days         INT           NULL,
    escalation_rules        NVARCHAR(MAX) NULL,
    status                  NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_checklist_item_status DEFAULT N'Active',
    entered_by              NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_checklist_item_entered_by DEFAULT 'system',
    entered_dt              DATETIME2     NOT NULL
        CONSTRAINT df_pm_checklist_item_entered_dt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT ck_pm_checklist_item_type
        CHECK (item_type IN (N'Manual', N'Automated', N'API Validation',
                             N'Document Upload', N'Observation',
                             N'Approval', N'Integration Call')),
    CONSTRAINT ck_pm_checklist_item_status
        CHECK (status IN (N'Active', N'Inactive')),
    CONSTRAINT fk_pm_checklist_item_checklist
        FOREIGN KEY (checklist_id) REFERENCES grac_practice.checklist(checklist_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_checklist_item_checklist_seq' AND object_id = OBJECT_ID('grac_practice.checklist_item'))
    CREATE INDEX ix_pm_checklist_item_checklist_seq
        ON grac_practice.checklist_item(checklist_id, item_sequence);
GO

-- =====================================================================
-- event_checklist_mapping (BRD Sec 10)
--   Entity + Event -> Checklist. Same checklist may be reused across
--   multiple mappings.
-- =====================================================================
IF OBJECT_ID('grac_practice.event_checklist_mapping','U') IS NULL
CREATE TABLE grac_practice.event_checklist_mapping(
    mapping_id              BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_event_checklist_mapping PRIMARY KEY,
    organization_id         BIGINT        NOT NULL,
    entity_type_id          BIGINT        NOT NULL,
    event_definition_id     BIGINT        NOT NULL,
    checklist_id            BIGINT        NOT NULL,
    default_owner_role      NVARCHAR(100) NULL,
    default_due_period_days INT           NULL,
    status                  NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_event_checklist_mapping_status DEFAULT N'Active',
    entered_by              NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_event_checklist_mapping_entered_by DEFAULT 'system',
    entered_dt              DATETIME2     NOT NULL
        CONSTRAINT df_pm_event_checklist_mapping_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by              NVARCHAR(100) NULL,
    updated_dt              DATETIME2     NULL,
    CONSTRAINT ck_pm_event_checklist_mapping_status
        CHECK (status IN (N'Active', N'Inactive')),
    CONSTRAINT fk_pm_event_checklist_mapping_entity
        FOREIGN KEY (entity_type_id) REFERENCES grac_practice.entity_type_master(entity_type_id),
    CONSTRAINT fk_pm_event_checklist_mapping_event
        FOREIGN KEY (event_definition_id) REFERENCES grac_practice.event_definition(event_definition_id),
    CONSTRAINT fk_pm_event_checklist_mapping_checklist
        FOREIGN KEY (checklist_id) REFERENCES grac_practice.checklist(checklist_id),
    CONSTRAINT uq_pm_event_checklist_mapping_natural
        UNIQUE (organization_id, entity_type_id, event_definition_id, checklist_id)
);
GO

-- =====================================================================
-- event_instance (BRD Sec 13/14)
--   One row per event received. Drives the assurance execution below.
-- =====================================================================
IF OBJECT_ID('grac_practice.event_instance','U') IS NULL
CREATE TABLE grac_practice.event_instance(
    event_instance_id       BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_event_instance PRIMARY KEY,
    organization_id         BIGINT        NOT NULL,
    event_definition_id     BIGINT        NOT NULL,
    entity_type_id          BIGINT        NULL,
    entity_reference        NVARCHAR(200) NULL,   -- external system id/name
    entity_display_name     NVARCHAR(300) NULL,
    checklist_id            BIGINT        NULL,   -- resolved by trigger engine
    trigger_source          NVARCHAR(60)  NULL,
    payload_json            NVARCHAR(MAX) NULL,   -- original event payload
    owner_employee_id       BIGINT        NULL,
    due_date                DATE          NULL,
    status                  NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_event_instance_status DEFAULT N'Received',
    completed_dt            DATETIME2     NULL,
    comments                NVARCHAR(MAX) NULL,
    entered_by              NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_event_instance_entered_by DEFAULT 'system',
    entered_dt              DATETIME2     NOT NULL
        CONSTRAINT df_pm_event_instance_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by              NVARCHAR(100) NULL,
    updated_dt              DATETIME2     NULL,
    CONSTRAINT ck_pm_event_instance_status
        CHECK (status IN (N'Received', N'Assured', N'Pending',
                          N'InProgress', N'Completed', N'Failed',
                          N'Overdue', N'Cancelled')),
    CONSTRAINT fk_pm_event_instance_event
        FOREIGN KEY (event_definition_id) REFERENCES grac_practice.event_definition(event_definition_id),
    CONSTRAINT fk_pm_event_instance_entity
        FOREIGN KEY (entity_type_id) REFERENCES grac_practice.entity_type_master(entity_type_id),
    CONSTRAINT fk_pm_event_instance_checklist
        FOREIGN KEY (checklist_id) REFERENCES grac_practice.checklist(checklist_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_event_instance_org_status' AND object_id = OBJECT_ID('grac_practice.event_instance'))
    CREATE INDEX ix_pm_event_instance_org_status
        ON grac_practice.event_instance(organization_id, status)
        INCLUDE (due_date, event_definition_id);
GO

-- =====================================================================
-- event_instance_item -- per-item execution row
-- =====================================================================
IF OBJECT_ID('grac_practice.event_instance_item','U') IS NULL
CREATE TABLE grac_practice.event_instance_item(
    event_instance_item_id  BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_event_instance_item PRIMARY KEY,
    event_instance_id       BIGINT        NOT NULL,
    checklist_item_id       BIGINT        NOT NULL,
    item_status             NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_event_instance_item_status DEFAULT N'Pending',
    evidence_url            NVARCHAR(1000) NULL,
    remarks                 NVARCHAR(MAX) NULL,
    completed_by            NVARCHAR(100) NULL,
    completed_dt            DATETIME2     NULL,
    entered_dt              DATETIME2     NOT NULL
        CONSTRAINT df_pm_event_instance_item_entered_dt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT ck_pm_event_instance_item_status
        CHECK (item_status IN (N'Pending', N'Passed', N'Failed',
                               N'NotApplicable', N'InProgress')),
    CONSTRAINT fk_pm_event_instance_item_instance
        FOREIGN KEY (event_instance_id) REFERENCES grac_practice.event_instance(event_instance_id),
    CONSTRAINT fk_pm_event_instance_item_checklist_item
        FOREIGN KEY (checklist_item_id) REFERENCES grac_practice.checklist_item(checklist_item_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_event_instance_item_instance' AND object_id = OBJECT_ID('grac_practice.event_instance_item'))
    CREATE INDEX ix_pm_event_instance_item_instance
        ON grac_practice.event_instance_item(event_instance_id, item_status);
GO

-- =====================================================================
-- event_gap (BRD Sec 15)
--   Kept independent of grac_practice.custom_gap because event-driven
--   gaps carry back-references to event_instance/entity for reporting.
--   A follow-up may unify these under a common gap facade -- for now
--   they live side by side so this migration is small and additive.
-- =====================================================================
IF OBJECT_ID('grac_practice.event_gap','U') IS NULL
CREATE TABLE grac_practice.event_gap(
    event_gap_id            BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_event_gap PRIMARY KEY,
    organization_id         BIGINT        NOT NULL,
    event_instance_id       BIGINT        NOT NULL,
    checklist_item_id       BIGINT        NULL,
    entity_reference        NVARCHAR(200) NULL,
    title                   NVARCHAR(250) NOT NULL,
    description             NVARCHAR(MAX) NULL,
    severity                NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_event_gap_severity DEFAULT N'Medium',
    owner_employee_id       BIGINT        NULL,
    due_date                DATE          NULL,
    status                  NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_event_gap_status DEFAULT N'Open',
    linked_task_id          BIGINT        NULL,
    entered_by              NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_event_gap_entered_by DEFAULT 'system',
    entered_dt              DATETIME2     NOT NULL
        CONSTRAINT df_pm_event_gap_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by              NVARCHAR(100) NULL,
    updated_dt              DATETIME2     NULL,
    CONSTRAINT ck_pm_event_gap_severity
        CHECK (severity IN (N'Low', N'Medium', N'High', N'Critical')),
    CONSTRAINT ck_pm_event_gap_status
        CHECK (status IN (N'Open', N'InProgress', N'Closed', N'Cancelled')),
    CONSTRAINT fk_pm_event_gap_event_instance
        FOREIGN KEY (event_instance_id) REFERENCES grac_practice.event_instance(event_instance_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_event_gap_org_status' AND object_id = OBJECT_ID('grac_practice.event_gap'))
    CREATE INDEX ix_pm_event_gap_org_status
        ON grac_practice.event_gap(organization_id, status)
        INCLUDE (severity, due_date);
GO

-- =====================================================================
-- event_audit (BRD Sec 18) -- lightweight config-and-execution trail.
--   For deeper diff (previous_value / new_value) records we lean on the
--   existing audit_trace infrastructure; this table captures the event
--   assurance timeline (received / assured / gap / task) for dashboard
--   drill-in.
-- =====================================================================
IF OBJECT_ID('grac_practice.event_audit','U') IS NULL
CREATE TABLE grac_practice.event_audit(
    event_audit_id          BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_event_audit PRIMARY KEY,
    organization_id         BIGINT        NOT NULL,
    event_instance_id       BIGINT        NULL,
    entity_type              NVARCHAR(60)  NOT NULL, -- Workflow / Event / Checklist / Mapping / EventInstance / Gap
    entity_id                BIGINT        NULL,
    action                  NVARCHAR(60)  NOT NULL,  -- Create / Update / Delete / Trigger / Complete / GapRaised / TaskCreated
    actor                   NVARCHAR(100) NULL,
    previous_value          NVARCHAR(MAX) NULL,
    new_value               NVARCHAR(MAX) NULL,
    reason                  NVARCHAR(1000) NULL,
    entered_dt              DATETIME2     NOT NULL
        CONSTRAINT df_pm_event_audit_entered_dt DEFAULT SYSUTCDATETIME()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_event_audit_org_entity' AND object_id = OBJECT_ID('grac_practice.event_audit'))
    CREATE INDEX ix_pm_event_audit_org_entity
        ON grac_practice.event_audit(organization_id, entity_type, entity_id)
        INCLUDE (action, entered_dt);
GO

PRINT '066 workflow engine schema installed.';
GO

SET NOEXEC OFF;
GO
