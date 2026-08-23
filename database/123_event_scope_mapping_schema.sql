-- =====================================================================
-- 123 Event Assurance -- role / asset-category scoping + subscription filter
--
-- Context
-- -------
-- 066 installed the Event Assurance Engine. Its mapping table resolves
--
--     entity_type + event_definition  ->  checklist
--
-- That is too coarse for the two flows the business actually runs:
--
--   * People. Onboarding and offboarding checklists differ per role. A
--     Software Engineer and a Finance Manager do not answer the same
--     joining questions, and neither answers all of them.
--   * Assets. Commissioning and decommissioning checklists differ per
--     asset category. A laptop and a production server are not wiped,
--     approved or disposed the same way.
--
-- Without a scope dimension every mapped checklist fires for every
-- subject, so users are handed items that do not apply and start
-- marking them NotApplicable in bulk -- which destroys the signal the
-- module exists to produce.
--
-- This migration adds the scope dimension, the subscription filter,
-- the subject lifecycle columns the raise path needs, and a resolution
-- trace.
--
-- WHY A SCOPE DIMENSION COLUMN AND NOT TWO MAPPING TABLES
-- ------------------------------------------------------
-- event_checklist_mapping_role + event_checklist_mapping_asset_category
-- would need a third table the first time Vendor Tier or Application
-- Criticality is scoped, plus a third resolution branch and a third
-- screen. One nullable-pair + a discriminator keeps the resolver a
-- single query. entity_type_master is already org-configurable, so the
-- dimension list has to be open-ended for the same reason.
--
-- WHY release_id AND NOT obligation_id
-- ------------------------------------
-- 066 states the Event engine carries no FK into the Practice /
-- Obligation engine. That boundary is retained deliberately. The
-- business requirement is only "list what the organization subscribes
-- to", which release_id + repository_subscription satisfies without
-- coupling the two engines. A NULL release_id means an org-authored
-- checklist that is always in scope.
--
-- WHY LIFECYCLE COLUMNS ON THE SUBJECT TABLES
-- -------------------------------------------
-- organization_dependency_asset has no notion of commissioned vs
-- decommissioned today -- status is the record status, not the asset
-- lifecycle. Reusing it would conflate "row is active" with "asset is
-- in service", and a decommissioned asset must stay an active row.
-- Same reasoning for the employee onboard / offboard dates: status
-- Active/Inactive cannot tell us WHEN, and SLA due dates are computed
-- from the effective date, not from the row's updated_dt.
--
-- Affected objects:
--   * grac_practice.event_checklist_mapping        (scope + release + owner role)
--   * grac_practice.event_instance                 (subject + scope snapshot + trace link)
--   * grac_practice.organization_dependency_asset  (asset lifecycle)
--   * grac_practice.organization_employee          (onboard / offboard dates)
--   * grac_practice.event_mapping_resolution       (NEW -- why included / excluded)
--
-- All statements are idempotent (COL_LENGTH / OBJECT_ID guards).
-- Procedures follow in 124_event_scope_mapping_procs.sql.
-- Rollback: 123_event_scope_mapping_schema_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.event_checklist_mapping','U') IS NULL
   OR OBJECT_ID('grac_practice.event_instance','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.dependency_asset_category_master','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_dependency_asset','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_employee','U') IS NULL
BEGIN
    RAISERROR('123: prerequisites missing (run 066 and the organization master migrations first).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. event_checklist_mapping -- scope dimension, release filter, owner role
-- =====================================================================

IF COL_LENGTH('grac_practice.event_checklist_mapping','scope_dimension') IS NULL
    ALTER TABLE grac_practice.event_checklist_mapping
        ADD scope_dimension NVARCHAR(40) NULL;
GO

IF COL_LENGTH('grac_practice.event_checklist_mapping','scope_role_id') IS NULL
    ALTER TABLE grac_practice.event_checklist_mapping
        ADD scope_role_id BIGINT NULL;
GO

IF COL_LENGTH('grac_practice.event_checklist_mapping','scope_asset_category_id') IS NULL
    ALTER TABLE grac_practice.event_checklist_mapping
        ADD scope_asset_category_id INT NULL;
GO

IF COL_LENGTH('grac_practice.event_checklist_mapping','release_id') IS NULL
    ALTER TABLE grac_practice.event_checklist_mapping
        ADD release_id BIGINT NULL;
GO

-- Hybrid ownership, consistent with 115: role is the permanent position,
-- the existing free-text default_owner_role stays as the legacy label.
IF COL_LENGTH('grac_practice.event_checklist_mapping','default_owner_role_id') IS NULL
    ALTER TABLE grac_practice.event_checklist_mapping
        ADD default_owner_role_id BIGINT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_checklist_mapping_scope_role')
    ALTER TABLE grac_practice.event_checklist_mapping
        ADD CONSTRAINT fk_pm_event_checklist_mapping_scope_role
            FOREIGN KEY (scope_role_id) REFERENCES grac_practice.organization_role(role_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_checklist_mapping_scope_asset_cat')
    ALTER TABLE grac_practice.event_checklist_mapping
        ADD CONSTRAINT fk_pm_event_checklist_mapping_scope_asset_cat
            FOREIGN KEY (scope_asset_category_id)
            REFERENCES grac_practice.dependency_asset_category_master(asset_category_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_checklist_mapping_owner_role')
    ALTER TABLE grac_practice.event_checklist_mapping
        ADD CONSTRAINT fk_pm_event_checklist_mapping_owner_role
            FOREIGN KEY (default_owner_role_id) REFERENCES grac_practice.organization_role(role_id);
GO

-- Scope coherence. NULL scope_dimension = mapping applies to every
-- subject of the entity type (the pre-123 behaviour, so existing rows
-- stay valid and keep working untouched).
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_checklist_mapping_scope')
    ALTER TABLE grac_practice.event_checklist_mapping
        ADD CONSTRAINT ck_pm_event_checklist_mapping_scope CHECK (
            (scope_dimension IS NULL
                 AND scope_role_id IS NULL AND scope_asset_category_id IS NULL)
         OR (scope_dimension = N'ORG_ROLE'
                 AND scope_role_id IS NOT NULL AND scope_asset_category_id IS NULL)
         OR (scope_dimension = N'ASSET_CATEGORY'
                 AND scope_asset_category_id IS NOT NULL AND scope_role_id IS NULL)
        );
GO

-- The 066 natural key predates scoping: it would stop the same checklist
-- being mapped to two different roles, which is the whole point of this
-- migration. Replaced by a unique index that includes the scope columns.
-- SQL Server treats NULLs as equal in a unique index, so the unscoped
-- (NULL, NULL) row is still unique per entity+event+checklist.
IF EXISTS (SELECT 1 FROM sys.key_constraints
           WHERE name = 'uq_pm_event_checklist_mapping_natural'
             AND parent_object_id = OBJECT_ID('grac_practice.event_checklist_mapping'))
    ALTER TABLE grac_practice.event_checklist_mapping
        DROP CONSTRAINT uq_pm_event_checklist_mapping_natural;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'uq_pm_event_checklist_mapping_scoped'
                 AND object_id = OBJECT_ID('grac_practice.event_checklist_mapping'))
    CREATE UNIQUE INDEX uq_pm_event_checklist_mapping_scoped
        ON grac_practice.event_checklist_mapping(
            organization_id, entity_type_id, event_definition_id, checklist_id,
            scope_role_id, scope_asset_category_id);
GO

-- Resolver hot path: "which checklists fire for this org + event + scope?"
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_event_checklist_mapping_resolve'
                 AND object_id = OBJECT_ID('grac_practice.event_checklist_mapping'))
    CREATE INDEX ix_pm_event_checklist_mapping_resolve
        ON grac_practice.event_checklist_mapping(
            organization_id, event_definition_id, scope_dimension,
            scope_role_id, scope_asset_category_id)
        INCLUDE (checklist_id, entity_type_id, release_id,
                 default_owner_role_id, default_due_period_days, status);
GO

-- Mapping workspace: "show every checklist mapped to this role".
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_event_checklist_mapping_by_role'
                 AND object_id = OBJECT_ID('grac_practice.event_checklist_mapping'))
    CREATE INDEX ix_pm_event_checklist_mapping_by_role
        ON grac_practice.event_checklist_mapping(organization_id, scope_role_id)
        INCLUDE (event_definition_id, checklist_id, status)
        WHERE scope_role_id IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_event_checklist_mapping_by_asset_cat'
                 AND object_id = OBJECT_ID('grac_practice.event_checklist_mapping'))
    CREATE INDEX ix_pm_event_checklist_mapping_by_asset_cat
        ON grac_practice.event_checklist_mapping(organization_id, scope_asset_category_id)
        INCLUDE (event_definition_id, checklist_id, status)
        WHERE scope_asset_category_id IS NOT NULL;
GO


-- =====================================================================
-- 2. event_instance -- subject identity, scope snapshot, trace link
--
--    The scope columns are a SNAPSHOT, not a live lookup. If an employee
--    changes role in November their May onboarding record must still show
--    the role it was raised against, otherwise the checklist that was
--    served can no longer be explained.
-- =====================================================================

IF COL_LENGTH('grac_practice.event_instance','subject_entity') IS NULL
    ALTER TABLE grac_practice.event_instance
        ADD subject_entity NVARCHAR(60) NULL;      -- EMPLOYEE / ASSET
GO

IF COL_LENGTH('grac_practice.event_instance','subject_record_id') IS NULL
    ALTER TABLE grac_practice.event_instance
        ADD subject_record_id BIGINT NULL;         -- employee_id / asset_id
GO

IF COL_LENGTH('grac_practice.event_instance','scope_role_id') IS NULL
    ALTER TABLE grac_practice.event_instance
        ADD scope_role_id BIGINT NULL;
GO

IF COL_LENGTH('grac_practice.event_instance','scope_role_name') IS NULL
    ALTER TABLE grac_practice.event_instance
        ADD scope_role_name NVARCHAR(120) NULL;    -- snapshot label (115 pattern)
GO

IF COL_LENGTH('grac_practice.event_instance','scope_asset_category_id') IS NULL
    ALTER TABLE grac_practice.event_instance
        ADD scope_asset_category_id INT NULL;
GO

IF COL_LENGTH('grac_practice.event_instance','scope_asset_category_name') IS NULL
    ALTER TABLE grac_practice.event_instance
        ADD scope_asset_category_name NVARCHAR(160) NULL;
GO

IF COL_LENGTH('grac_practice.event_instance','release_id') IS NULL
    ALTER TABLE grac_practice.event_instance
        ADD release_id BIGINT NULL;
GO

IF COL_LENGTH('grac_practice.event_instance','source_mapping_id') IS NULL
    ALTER TABLE grac_practice.event_instance
        ADD source_mapping_id BIGINT NULL;         -- which mapping produced this
GO

-- SLA is computed from the effective date, never from entered_dt. An
-- event ingested five days late produces an instance that is already
-- overdue -- which is correct, and is information we must not lose.
IF COL_LENGTH('grac_practice.event_instance','effective_date') IS NULL
    ALTER TABLE grac_practice.event_instance
        ADD effective_date DATE NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_instance_scope_role')
    ALTER TABLE grac_practice.event_instance
        ADD CONSTRAINT fk_pm_event_instance_scope_role
            FOREIGN KEY (scope_role_id) REFERENCES grac_practice.organization_role(role_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_instance_scope_asset_cat')
    ALTER TABLE grac_practice.event_instance
        ADD CONSTRAINT fk_pm_event_instance_scope_asset_cat
            FOREIGN KEY (scope_asset_category_id)
            REFERENCES grac_practice.dependency_asset_category_master(asset_category_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_instance_source_mapping')
    ALTER TABLE grac_practice.event_instance
        ADD CONSTRAINT fk_pm_event_instance_source_mapping
            FOREIGN KEY (source_mapping_id)
            REFERENCES grac_practice.event_checklist_mapping(mapping_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_instance_subject')
    ALTER TABLE grac_practice.event_instance
        ADD CONSTRAINT ck_pm_event_instance_subject CHECK (
            subject_entity IS NULL
         OR (subject_entity IN (N'EMPLOYEE', N'ASSET') AND subject_record_id IS NOT NULL));
GO

-- Idempotency. The same event for the same subject and the same mapping
-- must not raise twice while one is still open; a genuine rehire or a
-- recommissioning is allowed once the first is Completed or Cancelled.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'uq_pm_event_instance_open_subject'
                 AND object_id = OBJECT_ID('grac_practice.event_instance'))
    CREATE UNIQUE INDEX uq_pm_event_instance_open_subject
        ON grac_practice.event_instance(
            organization_id, event_definition_id, subject_entity,
            subject_record_id, source_mapping_id)
        WHERE subject_record_id IS NOT NULL
          AND status <> N'Completed'
          AND status <> N'Cancelled';
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_event_instance_subject'
                 AND object_id = OBJECT_ID('grac_practice.event_instance'))
    CREATE INDEX ix_pm_event_instance_subject
        ON grac_practice.event_instance(organization_id, subject_entity, subject_record_id)
        INCLUDE (event_definition_id, status, due_date, effective_date);
GO


-- =====================================================================
-- 3. organization_dependency_asset -- asset lifecycle
--
--    status  = record status  (Active / Inactive)      -- unchanged
--    lifecycle_status = asset state in service         -- NEW
--
--    A decommissioned asset stays an Active row: it must remain visible
--    for the retention period and its decommissioning checklist must stay
--    attached to it.
-- =====================================================================

IF COL_LENGTH('grac_practice.organization_dependency_asset','lifecycle_status') IS NULL
    ALTER TABLE grac_practice.organization_dependency_asset
        ADD lifecycle_status NVARCHAR(30) NULL;
GO

IF COL_LENGTH('grac_practice.organization_dependency_asset','commissioned_dt') IS NULL
    ALTER TABLE grac_practice.organization_dependency_asset
        ADD commissioned_dt DATE NULL;
GO

IF COL_LENGTH('grac_practice.organization_dependency_asset','decommissioned_dt') IS NULL
    ALTER TABLE grac_practice.organization_dependency_asset
        ADD decommissioned_dt DATE NULL;
GO

-- Backfill: every existing asset row is in service today. purchase_dt is
-- the best available commissioning proxy; left NULL where unknown rather
-- than invented, so SLA maths never runs off a fabricated date.
UPDATE grac_practice.organization_dependency_asset
   SET lifecycle_status = N'Commissioned',
       commissioned_dt  = COALESCE(commissioned_dt, purchase_dt)
 WHERE lifecycle_status IS NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_org_asset_lifecycle_status')
    ALTER TABLE grac_practice.organization_dependency_asset
        ADD CONSTRAINT ck_pm_org_asset_lifecycle_status CHECK (
            lifecycle_status IS NULL
         OR lifecycle_status IN (N'Planned', N'Commissioned', N'Decommissioned'));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_org_asset_lifecycle_dates')
    ALTER TABLE grac_practice.organization_dependency_asset
        ADD CONSTRAINT ck_pm_org_asset_lifecycle_dates CHECK (
            decommissioned_dt IS NULL
         OR commissioned_dt IS NULL
         OR decommissioned_dt >= commissioned_dt);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_org_asset_lifecycle'
                 AND object_id = OBJECT_ID('grac_practice.organization_dependency_asset'))
    CREATE INDEX ix_pm_org_asset_lifecycle
        ON grac_practice.organization_dependency_asset(
            organization_id, lifecycle_status, asset_category_id)
        INCLUDE (asset_name, commissioned_dt, decommissioned_dt);
GO


-- =====================================================================
-- 4. organization_employee -- onboarding / offboarding dates
--
--    status Active/Inactive already exists but cannot answer "when", and
--    the whole SLA calculation hangs off the effective date.
-- =====================================================================

IF COL_LENGTH('grac_practice.organization_employee','onboarded_dt') IS NULL
    ALTER TABLE grac_practice.organization_employee
        ADD onboarded_dt DATE NULL;
GO

IF COL_LENGTH('grac_practice.organization_employee','offboarded_dt') IS NULL
    ALTER TABLE grac_practice.organization_employee
        ADD offboarded_dt DATE NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_employee_lifecycle_dates')
    ALTER TABLE grac_practice.organization_employee
        ADD CONSTRAINT ck_pm_employee_lifecycle_dates CHECK (
            offboarded_dt IS NULL
         OR onboarded_dt IS NULL
         OR offboarded_dt >= onboarded_dt);
GO


-- =====================================================================
-- 5. event_mapping_resolution (NEW) -- why a checklist did or did not fire
--
--    Written for INCLUDED and EXCLUDED alike. The first question asked in
--    an audit is "why is this check missing from this person's
--    onboarding?", and that answer has to be a stored fact rather than an
--    inference from today's mappings, which by then have moved on.
--
--    Follows the event_audit precedent: append-only, no record_status_id.
-- =====================================================================

IF OBJECT_ID('grac_practice.event_mapping_resolution','U') IS NULL
CREATE TABLE grac_practice.event_mapping_resolution(
    resolution_id           BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_event_mapping_resolution PRIMARY KEY,
    organization_id         BIGINT        NOT NULL,
    event_definition_id     BIGINT        NOT NULL,
    subject_entity          NVARCHAR(60)  NOT NULL,
    subject_record_id       BIGINT        NOT NULL,
    subject_label           NVARCHAR(300) NULL,
    effective_date          DATE          NULL,

    mapping_id              BIGINT        NULL,   -- NULL when nothing matched at all
    checklist_id            BIGINT        NULL,
    scope_dimension         NVARCHAR(40)  NULL,
    scope_role_id           BIGINT        NULL,
    scope_asset_category_id INT           NULL,
    release_id              BIGINT        NULL,

    decision                NVARCHAR(20)  NOT NULL,   -- Included / Excluded
    reason_code             NVARCHAR(60)  NOT NULL,
    reason_detail           NVARCHAR(1000) NULL,
    event_instance_id       BIGINT        NULL,       -- set when Included

    entered_by              NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_event_mapping_resolution_eb DEFAULT 'system',
    entered_dt              DATETIME2     NOT NULL
        CONSTRAINT df_pm_event_mapping_resolution_ed DEFAULT SYSUTCDATETIME(),

    CONSTRAINT ck_pm_event_mapping_resolution_decision
        CHECK (decision IN (N'Included', N'Excluded')),
    CONSTRAINT ck_pm_event_mapping_resolution_reason
        CHECK (reason_code IN (
            N'ScopeMatched',            -- role / asset category matched
            N'UnscopedMapping',         -- mapping applies to all subjects
            N'ScopeMismatch',           -- mapping is for a different role / category
            N'NoMappingForEvent',       -- nothing mapped for this event at all
            N'SubjectScopeMissing',     -- employee has no role / asset has no category
            N'ReleaseNotSubscribed',    -- mapping release not in an active subscription
            N'MappingInactive',
            N'ChecklistInactive',
            N'NoChecklistItems',
            N'AlreadyOpen')),           -- idempotency guard hit
    CONSTRAINT ck_pm_event_mapping_resolution_included
        CHECK (decision = N'Excluded' OR mapping_id IS NOT NULL),
    CONSTRAINT fk_pm_event_mapping_resolution_org
        FOREIGN KEY (organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_event_mapping_resolution_event
        FOREIGN KEY (event_definition_id)
        REFERENCES grac_practice.event_definition(event_definition_id),
    CONSTRAINT fk_pm_event_mapping_resolution_mapping
        FOREIGN KEY (mapping_id)
        REFERENCES grac_practice.event_checklist_mapping(mapping_id),
    CONSTRAINT fk_pm_event_mapping_resolution_instance
        FOREIGN KEY (event_instance_id)
        REFERENCES grac_practice.event_instance(event_instance_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_event_mapping_resolution_subject'
                 AND object_id = OBJECT_ID('grac_practice.event_mapping_resolution'))
    CREATE INDEX ix_pm_event_mapping_resolution_subject
        ON grac_practice.event_mapping_resolution(
            organization_id, subject_entity, subject_record_id, entered_dt DESC)
        INCLUDE (event_definition_id, decision, reason_code);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_event_mapping_resolution_instance'
                 AND object_id = OBJECT_ID('grac_practice.event_mapping_resolution'))
    CREATE INDEX ix_pm_event_mapping_resolution_instance
        ON grac_practice.event_mapping_resolution(event_instance_id)
        WHERE event_instance_id IS NOT NULL;
GO

-- Coverage gaps surface here rather than in a separate table: an org that
-- has mapped nothing for a role produces NoMappingForEvent rows, and the
-- gap screen is a GROUP BY over this. One writer, one reader, no second
-- store to keep in step.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_event_mapping_resolution_gap'
                 AND object_id = OBJECT_ID('grac_practice.event_mapping_resolution'))
    CREATE INDEX ix_pm_event_mapping_resolution_gap
        ON grac_practice.event_mapping_resolution(
            organization_id, reason_code, scope_role_id, scope_asset_category_id)
        INCLUDE (event_definition_id, entered_dt)
        WHERE decision = N'Excluded';
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'mapping.scope_dimension present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.event_checklist_mapping','scope_dimension') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'mapping.scope_role_id present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.event_checklist_mapping','scope_role_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'mapping.scope_asset_category_id present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.event_checklist_mapping','scope_asset_category_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'mapping.release_id present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.event_checklist_mapping','release_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'old natural key dropped' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.key_constraints
                             WHERE name = 'uq_pm_event_checklist_mapping_natural')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'event_instance.subject_record_id present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.event_instance','subject_record_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'event_instance.effective_date present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.event_instance','effective_date') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'asset.lifecycle_status present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.organization_dependency_asset','lifecycle_status') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'asset lifecycle backfilled' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset
                             WHERE lifecycle_status IS NULL)
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'employee.onboarded_dt present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.organization_employee','onboarded_dt') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'event_mapping_resolution present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.event_mapping_resolution','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '123 Event scope mapping schema deployed.';
GO

SET NOEXEC OFF;
GO
