-- =====================================================================
-- 089 Organization Assurance (Phase 2) -- Stage 3 Assurance Plans
--
-- Business context (BRD Part 2 Sec 8):
--   Support Annual / Quarterly / Monthly / One-Time plans.
--   Assign teams, auditors, branches, departments, schedule.
--   Plans have status, ownership, period, version, approval, org
--   isolation.
--
-- Plans are ORG-LEVEL artifacts (not tied to a single definition
-- version). Each plan contains one or more items -- each item links
-- to an assurance definition and carries a scheduled slot + optional
-- assignments.
--
-- Naming:
--   grac_practice.org_assurance_plan_status_master   Lifecycle vocab
--   grac_practice.org_assurance_plan                 Plan header
--   grac_practice.org_assurance_plan_item            Items in a plan
--
-- Rollback: 089_org_assurance_plan_schema_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
   OR OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_definition','U') IS NULL
BEGIN
    RAISERROR('089: prerequisites missing (run 001 + 069).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Status master (lifecycle vocabulary)
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_plan_status_master','U') IS NULL
CREATE TABLE grac_practice.org_assurance_plan_status_master(
    org_assurance_plan_status_id INT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_plan_status PRIMARY KEY,
    status_code   NVARCHAR(60)  NOT NULL
        CONSTRAINT uq_pm_oa_plan_status_code UNIQUE,
    status_name   NVARCHAR(120) NOT NULL,
    display_order INT           NOT NULL CONSTRAINT df_pm_oa_plan_status_order   DEFAULT 0,
    is_terminal   BIT           NOT NULL CONSTRAINT df_pm_oa_plan_status_terminal DEFAULT 0,
    is_active     BIT           NOT NULL CONSTRAINT df_pm_oa_plan_status_active  DEFAULT 1,
    entered_by    NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_plan_status_ent_by  DEFAULT 'system',
    entered_dt    DATETIME2     NOT NULL CONSTRAINT df_pm_oa_plan_status_ent_dt  DEFAULT SYSUTCDATETIME(),
    updated_by    NVARCHAR(100) NULL,
    updated_dt    DATETIME2     NULL
);
GO

MERGE grac_practice.org_assurance_plan_status_master AS t
USING (VALUES
    (N'Draft',     N'Draft',     1, 0),
    (N'Submitted', N'Submitted', 2, 0),
    (N'Approved',  N'Approved',  3, 0),
    (N'Active',    N'Active',    4, 0),
    (N'Closed',    N'Closed',    5, 1)
) AS src(status_code, status_name, display_order, is_terminal)
ON t.status_code = src.status_code
WHEN MATCHED THEN UPDATE SET
    status_name   = src.status_name,
    display_order = src.display_order,
    is_terminal   = src.is_terminal,
    is_active     = 1,
    updated_by    = 'seed-089',
    updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (status_code, status_name, display_order, is_terminal, is_active, entered_by)
VALUES
    (src.status_code, src.status_name, src.display_order, src.is_terminal, 1, 'seed-089');
GO

-- =====================================================================
-- 2. Plan header
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_plan','U') IS NULL
CREATE TABLE grac_practice.org_assurance_plan(
    org_assurance_plan_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_plan PRIMARY KEY,
    organization_id       BIGINT NOT NULL,

    plan_code             NVARCHAR(80)  NOT NULL,
    plan_name             NVARCHAR(240) NOT NULL,
    -- ANNUAL / QUARTERLY / MONTHLY / ONE_TIME
    plan_type             NVARCHAR(30)  NOT NULL,
    period_from           DATE NULL,
    period_to             DATE NULL,

    owner_employee_id     BIGINT NULL,
    owner_display_name    NVARCHAR(240) NULL,

    status_id             INT NOT NULL,
    description           NVARCHAR(MAX) NULL,
    version               INT NOT NULL CONSTRAINT df_pm_oa_plan_version DEFAULT 1,

    is_active             BIT NOT NULL CONSTRAINT df_pm_oa_plan_active DEFAULT 1,
    record_status_id      INT NOT NULL,
    entered_by            NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_plan_ent_by DEFAULT 'system',
    entered_dt            DATETIME2 NOT NULL CONSTRAINT df_pm_oa_plan_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by            NVARCHAR(100) NULL,
    updated_dt            DATETIME2 NULL,

    CONSTRAINT fk_pm_oa_plan_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_plan_status
        FOREIGN KEY(status_id) REFERENCES grac_practice.org_assurance_plan_status_master(org_assurance_plan_status_id),
    CONSTRAINT fk_pm_oa_plan_record_status
        FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
    CONSTRAINT ck_pm_oa_plan_type CHECK (
        plan_type IN (N'ANNUAL', N'QUARTERLY', N'MONTHLY', N'ONE_TIME')),
    CONSTRAINT ck_pm_oa_plan_period CHECK (
        period_from IS NULL OR period_to IS NULL OR period_to >= period_from),
    CONSTRAINT uq_pm_oa_plan_code UNIQUE(organization_id, plan_code)
);
GO

CREATE INDEX ix_pm_oa_plan_org
    ON grac_practice.org_assurance_plan(organization_id, is_active, status_id)
    WHERE is_active = 1;
GO

-- =====================================================================
-- 3. Plan item -- links to an assurance definition + schedule slot
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_plan_item','U') IS NULL
CREATE TABLE grac_practice.org_assurance_plan_item(
    org_assurance_plan_item_id  BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_plan_item PRIMARY KEY,
    org_assurance_plan_id       BIGINT NOT NULL,
    organization_id             BIGINT NOT NULL,

    org_assurance_definition_id BIGINT NOT NULL,
    definition_code             NVARCHAR(80)  NULL,   -- denormalized snapshot
    definition_name             NVARCHAR(240) NULL,

    -- Version resolved at execution time (Stage 3 item #4). Nullable
    -- during planning.
    org_assurance_definition_version_id BIGINT NULL,

    item_order                  INT NOT NULL CONSTRAINT df_pm_oa_plan_item_order DEFAULT 0,
    scheduled_from              DATE NULL,
    scheduled_to                DATE NULL,

    -- Optional assignments (all soft references, denormalized).
    assigned_auditor_employee_id BIGINT NULL,
    assigned_auditor_name        NVARCHAR(240) NULL,
    assigned_team_name           NVARCHAR(200) NULL,
    assigned_department_id       BIGINT NULL,
    assigned_department_name     NVARCHAR(200) NULL,
    assigned_branch_id           BIGINT NULL,
    assigned_branch_name         NVARCHAR(200) NULL,

    notes                        NVARCHAR(MAX) NULL,

    is_active                    BIT NOT NULL CONSTRAINT df_pm_oa_plan_item_active DEFAULT 1,
    entered_by                   NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_plan_item_ent_by DEFAULT 'system',
    entered_dt                   DATETIME2 NOT NULL CONSTRAINT df_pm_oa_plan_item_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by                   NVARCHAR(100) NULL,
    updated_dt                   DATETIME2 NULL,

    CONSTRAINT fk_pm_oa_plan_item_plan
        FOREIGN KEY(org_assurance_plan_id)
        REFERENCES grac_practice.org_assurance_plan(org_assurance_plan_id),
    CONSTRAINT fk_pm_oa_plan_item_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_plan_item_definition
        FOREIGN KEY(org_assurance_definition_id)
        REFERENCES grac_practice.org_assurance_definition(org_assurance_definition_id),
    CONSTRAINT ck_pm_oa_plan_item_slot CHECK (
        scheduled_from IS NULL OR scheduled_to IS NULL OR scheduled_to >= scheduled_from)
);
GO

CREATE INDEX ix_pm_oa_plan_item_plan
    ON grac_practice.org_assurance_plan_item(org_assurance_plan_id, item_order, org_assurance_plan_item_id)
    WHERE is_active = 1;
GO

COMMIT TRAN;
GO

SELECT '5 plan statuses seeded' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.org_assurance_plan_status_master WHERE is_active = 1) = 5
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_assurance_plan present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_plan','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_assurance_plan_item present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_plan_item','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '089 Organization Assurance Plan schema deployed.';
GO

SET NOEXEC OFF;
GO
