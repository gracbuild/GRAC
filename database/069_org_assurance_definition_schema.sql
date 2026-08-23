-- =====================================================================
-- 069 Organization Assurance Management (Phase 2) -- Stage 1 Schema
--
-- Business context:
--   New, INDEPENDENT Assurance Management module (Practice Management /
--   Organization Portal, BRD Part 2). Not a merge, extension, or
--   integration with any existing assurance_activity / assurance_execution
--   / assurance_finding / assurance_schedule / workflow / event / task /
--   custom_gap object. Those are unrelated capabilities kept intact.
--
-- Scope of this migration (Stage 1 -- Foundation only):
--   * org_assurance_status_master   Lifecycle status vocabulary
--       (Draft, Under Review, Approved, Active, Retired)
--   * org_assurance_definition      Organization-level assurance
--       definition (identity, owner, current version pointer)
--   * org_assurance_definition_version  Immutable version row per edit
--       (name/description/category/objective/effective date payload)
--   * org_assurance_definition_history  Lifecycle transition audit log
--
-- Follow-on stages (later scripts, later sessions):
--   Stage 2 : scope builder, question sets, evidence config, workflow /
--             scoring configuration (Admin-published metadata)
--   Stage 3 : plans, triggers, resolution engine, execution snapshots
--   Stage 4 : observations, gaps, task/risk integration, dashboards,
--             reports
--
-- Admin Phase 1 metadata consumption:
--   Assurance categories, scoring models, severities, etc. are published
--   by the ControlManagement (grac_new.*) repository via
--   grac_practice.repository_subscription (same pattern proven by
--   006_sync_organization_controls_from_subscriptions.sql). This schema
--   captures assurance_category_id / assurance_category_code /
--   assurance_category_name as *soft* references so Stage 1 can deploy
--   even before the corresponding Admin master row is subscribed. A hard
--   FK is deliberately NOT added -- Stage 2 introduces the join table
--   that validates the subscribed category id against the caller's
--   active subscription set.
--
-- Naming:
--   * All new objects live under grac_practice.org_assurance_* to keep
--     them clearly separated from the existing (unrelated) assurance_*
--     objects. Object naming, PK style, audit columns, MERGE seed, and
--     rollback pattern mirror migrations 037 / 048 / 054 / 066.
--
-- Idempotent: safe to re-run. ASCII-only. Rollback in
-- database/069_org_assurance_definition_schema_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- ---------------------------------------------------------------------
-- Prerequisites
-- ---------------------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (069): schema grac_practice missing. Run 001_practice_management_schema.sql first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.organization','U') IS NULL
BEGIN
    PRINT 'ABORT (069): grac_practice.organization missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN
    PRINT 'ABORT (069): grac_practice.record_status_master missing (needed for record_status_id FK).';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('069_org_assurance_definition_schema: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. org_assurance_status_master
--    Fixed vocabulary that drives the definition lifecycle. Distinct
--    from the existing (unrelated) assurance_activity_status_master.
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_status_master','U') IS NULL
CREATE TABLE grac_practice.org_assurance_status_master(
    org_assurance_status_id INT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_org_assurance_status PRIMARY KEY,
    status_code   NVARCHAR(60)  NOT NULL
        CONSTRAINT uq_pm_org_assurance_status_code UNIQUE,
    status_name   NVARCHAR(120) NOT NULL,
    display_order INT           NOT NULL CONSTRAINT df_pm_org_assurance_status_order   DEFAULT 0,
    is_terminal   BIT           NOT NULL CONSTRAINT df_pm_org_assurance_status_terminal DEFAULT 0,
    is_active     BIT           NOT NULL CONSTRAINT df_pm_org_assurance_status_active  DEFAULT 1,
    entered_by    NVARCHAR(100) NOT NULL CONSTRAINT df_pm_org_assurance_status_ent_by  DEFAULT 'system',
    entered_dt    DATETIME2     NOT NULL CONSTRAINT df_pm_org_assurance_status_ent_dt  DEFAULT SYSUTCDATETIME(),
    updated_by    NVARCHAR(100) NULL,
    updated_dt    DATETIME2     NULL
);
GO

-- Seed the five BRD-defined lifecycle statuses.
MERGE grac_practice.org_assurance_status_master AS t
USING (VALUES
    (N'Draft',        N'Draft',        1, 0),
    (N'UnderReview',  N'Under Review', 2, 0),
    (N'Approved',     N'Approved',     3, 0),
    (N'Active',       N'Active',       4, 0),
    (N'Retired',      N'Retired',      5, 1)
) AS src(status_code, status_name, display_order, is_terminal)
ON t.status_code = src.status_code
WHEN MATCHED THEN UPDATE SET
    status_name   = src.status_name,
    display_order = src.display_order,
    is_terminal   = src.is_terminal,
    is_active     = 1,
    updated_by    = 'seed-069',
    updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (status_code, status_name, display_order, is_terminal, is_active, entered_by)
VALUES
    (src.status_code, src.status_name, src.display_order, src.is_terminal, 1, 'seed-069');
GO

-- =====================================================================
-- 2. org_assurance_definition
--    Identity + current version pointer + lifecycle status. All
--    editable attributes live on the version row so a version can be
--    treated as an immutable snapshot when execution starts (Stage 3).
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_definition','U') IS NULL
CREATE TABLE grac_practice.org_assurance_definition(
    org_assurance_definition_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_org_assurance_definition PRIMARY KEY,
    organization_id         BIGINT       NOT NULL,
    definition_code         NVARCHAR(80) NOT NULL,        -- unique per org
    definition_name         NVARCHAR(240) NOT NULL,
    owner_employee_id       BIGINT       NULL,            -- soft FK to grac_practice.organization_employee.employee_id
    owner_display_name      NVARCHAR(240) NULL,
    current_version_id      BIGINT       NULL,            -- FK added after version table exists
    current_status_id       INT          NOT NULL,
    active_version_id       BIGINT       NULL,            -- last version that reached Active
    is_active               BIT          NOT NULL CONSTRAINT df_pm_org_assurance_def_active DEFAULT 1,
    record_status_id        INT          NOT NULL,
    entered_by              NVARCHAR(100) NOT NULL CONSTRAINT df_pm_org_assurance_def_ent_by DEFAULT 'system',
    entered_dt              DATETIME2    NOT NULL CONSTRAINT df_pm_org_assurance_def_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by              NVARCHAR(100) NULL,
    updated_dt              DATETIME2    NULL,
    CONSTRAINT fk_pm_org_assurance_def_org
        FOREIGN KEY(organization_id)  REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_org_assurance_def_status
        FOREIGN KEY(current_status_id) REFERENCES grac_practice.org_assurance_status_master(org_assurance_status_id),
    CONSTRAINT fk_pm_org_assurance_def_record_status
        FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
    CONSTRAINT uq_pm_org_assurance_def_code UNIQUE(organization_id, definition_code)
);
GO

CREATE INDEX ix_pm_org_assurance_def_org
    ON grac_practice.org_assurance_definition(organization_id, is_active, current_status_id)
    WHERE is_active = 1;
GO

-- =====================================================================
-- 3. org_assurance_definition_version
--    Immutable per-edit snapshot. Once a version transitions past
--    Draft, updates are blocked at the stored-proc layer (070). This
--    guarantees historical executions (Stage 3) can safely point at a
--    version_id without risk of retroactive change.
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_definition_version','U') IS NULL
CREATE TABLE grac_practice.org_assurance_definition_version(
    org_assurance_definition_version_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_org_assurance_def_version PRIMARY KEY,
    org_assurance_definition_id BIGINT NOT NULL,
    organization_id             BIGINT NOT NULL,          -- denormalized for org isolation on version reads
    version_number              INT    NOT NULL,          -- 1..N per definition
    version_label               NVARCHAR(40) NULL,        -- optional "1.0" style label
    description                 NVARCHAR(MAX) NULL,
    objective                   NVARCHAR(MAX) NULL,
    effective_date              DATE NULL,
    -- Admin Phase 1 metadata (soft reference; grac_new.assurance_category).
    -- Denormalized code/name captured at save-time to keep the definition
    -- readable even if the Admin master row is later retired.
    assurance_category_id       BIGINT NULL,
    assurance_category_code     NVARCHAR(120) NULL,
    assurance_category_name     NVARCHAR(200) NULL,
    status_id                   INT NOT NULL,             -- Draft / UnderReview / Approved / Active / Retired
    submitted_by                NVARCHAR(100) NULL,
    submitted_dt                DATETIME2 NULL,
    approved_by                 NVARCHAR(100) NULL,
    approved_dt                 DATETIME2 NULL,
    activated_by                NVARCHAR(100) NULL,
    activated_dt                DATETIME2 NULL,
    retired_by                  NVARCHAR(100) NULL,
    retired_dt                  DATETIME2 NULL,
    is_active                   BIT NOT NULL CONSTRAINT df_pm_org_assurance_ver_active DEFAULT 1,
    record_status_id            INT NOT NULL,
    entered_by                  NVARCHAR(100) NOT NULL CONSTRAINT df_pm_org_assurance_ver_ent_by DEFAULT 'system',
    entered_dt                  DATETIME2 NOT NULL CONSTRAINT df_pm_org_assurance_ver_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by                  NVARCHAR(100) NULL,
    updated_dt                  DATETIME2 NULL,
    CONSTRAINT fk_pm_org_assurance_ver_def
        FOREIGN KEY(org_assurance_definition_id)
        REFERENCES grac_practice.org_assurance_definition(org_assurance_definition_id),
    CONSTRAINT fk_pm_org_assurance_ver_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_org_assurance_ver_status
        FOREIGN KEY(status_id) REFERENCES grac_practice.org_assurance_status_master(org_assurance_status_id),
    CONSTRAINT fk_pm_org_assurance_ver_record_status
        FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
    CONSTRAINT uq_pm_org_assurance_ver_number
        UNIQUE(org_assurance_definition_id, version_number)
);
GO

CREATE INDEX ix_pm_org_assurance_ver_def
    ON grac_practice.org_assurance_definition_version(org_assurance_definition_id, version_number DESC);
GO

CREATE INDEX ix_pm_org_assurance_ver_org_status
    ON grac_practice.org_assurance_definition_version(organization_id, status_id, is_active)
    WHERE is_active = 1;
GO

-- FK from definition -> version (both current and active pointers).
-- Added after both tables exist to avoid a chicken-and-egg constraint.
IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE name = 'fk_pm_org_assurance_def_current_version'
      AND parent_object_id = OBJECT_ID('grac_practice.org_assurance_definition')
)
ALTER TABLE grac_practice.org_assurance_definition
    ADD CONSTRAINT fk_pm_org_assurance_def_current_version
        FOREIGN KEY(current_version_id)
        REFERENCES grac_practice.org_assurance_definition_version(org_assurance_definition_version_id);
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE name = 'fk_pm_org_assurance_def_active_version'
      AND parent_object_id = OBJECT_ID('grac_practice.org_assurance_definition')
)
ALTER TABLE grac_practice.org_assurance_definition
    ADD CONSTRAINT fk_pm_org_assurance_def_active_version
        FOREIGN KEY(active_version_id)
        REFERENCES grac_practice.org_assurance_definition_version(org_assurance_definition_version_id);
GO

-- =====================================================================
-- 4. org_assurance_definition_history
--    Immutable transition audit log. Every submit / approve / activate
--    / retire (plus edits to a Draft version) produces one row. Used by
--    the Version History screen and, later, by dashboards.
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_definition_history','U') IS NULL
CREATE TABLE grac_practice.org_assurance_definition_history(
    org_assurance_definition_history_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_org_assurance_def_hist PRIMARY KEY,
    org_assurance_definition_id BIGINT NOT NULL,
    org_assurance_definition_version_id BIGINT NULL,
    organization_id BIGINT NOT NULL,
    action_code     NVARCHAR(40)  NOT NULL,            -- CREATE, EDIT, SUBMIT, APPROVE, ACTIVATE, RETIRE
    from_status_id  INT NULL,
    to_status_id    INT NULL,
    reason_text     NVARCHAR(1000) NULL,
    actor_employee_id BIGINT NULL,
    actor_display_name NVARCHAR(240) NULL,
    entered_by      NVARCHAR(100) NOT NULL CONSTRAINT df_pm_org_assurance_hist_ent_by DEFAULT 'system',
    entered_dt      DATETIME2 NOT NULL CONSTRAINT df_pm_org_assurance_hist_ent_dt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_pm_org_assurance_hist_def
        FOREIGN KEY(org_assurance_definition_id)
        REFERENCES grac_practice.org_assurance_definition(org_assurance_definition_id),
    CONSTRAINT fk_pm_org_assurance_hist_ver
        FOREIGN KEY(org_assurance_definition_version_id)
        REFERENCES grac_practice.org_assurance_definition_version(org_assurance_definition_version_id),
    CONSTRAINT fk_pm_org_assurance_hist_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_org_assurance_hist_from_status
        FOREIGN KEY(from_status_id) REFERENCES grac_practice.org_assurance_status_master(org_assurance_status_id),
    CONSTRAINT fk_pm_org_assurance_hist_to_status
        FOREIGN KEY(to_status_id)   REFERENCES grac_practice.org_assurance_status_master(org_assurance_status_id)
);
GO

CREATE INDEX ix_pm_org_assurance_hist_def
    ON grac_practice.org_assurance_definition_history(org_assurance_definition_id, entered_dt DESC);
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Post-migration sanity report
-- =====================================================================
SELECT 'org_assurance_status_master seeded' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.org_assurance_status_master) >= 5
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'org_assurance_definition table present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_definition','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'org_assurance_definition_version table present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_definition_version','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'org_assurance_definition_history table present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_definition_history','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '069 Organization Assurance -- Stage 1 schema deployed.';
GO

SET NOEXEC OFF;
GO
