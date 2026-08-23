-- =====================================================================
-- 127 Event Assurance -- obligation-based scoping (supersedes the
--     checklist-based scoping path added in 123/124)
--
-- WHY THIS EXISTS -- correcting 123/124
-- ------------------------------------
-- 123/124 scoped grac_practice.checklist rows to a role or asset
-- category. That was the wrong substrate. The thing the business
-- actually maps to a role is an OBLIGATION:
--
--     "people related onboarding / offboarding nte obligations oke list
--      cheyth organization le role nu against map cheyyan ulla option"
--
-- grac_practice.checklist is 066's own hand-authored entity with no
-- relationship to practice / organization_requirement / obligation. So a
-- practice like REQ-AC-DORMANT-001, configured in GRAC-ADMIN as an
-- event-driven obligation on People Onboarding and made applicable to an
-- organization, was invisible to the 124 mapping screen -- it listed
-- checklist rows, of which the organization had none.
--
-- This migration maps obligations instead. Nothing in 123/124 is dropped:
-- the checklist path still works for organizations that author their own
-- checklists. The obligation path is additive and is what the Scoped
-- Checklist Mapping screen switches to.
--
-- HOW AN OBLIGATION REACHES AN ORGANIZATION
-- -----------------------------------------
--   grac_practice.organization_requirement          (org, applicable)
--     -> repository_requirement_id
--     -> GRAC_New.obligation_requirement_release_map (requirement, obligation, release)
--     -> GRAC_New.requirement_obligation
--     -> GRAC_New.obligation_assurance_spec          (trigger_mode, event_type_id)
--     -> GRAC_New.event_type_master                 (event_code, subject_entity)
--   filtered by grac_practice.repository_subscription on release_id.
--
-- Read live, the same way 122's sp_pm_view_obligations_typed already does.
-- No projection table, so a trigger changed in GRAC-ADMIN takes effect
-- immediately and cannot drift.
--
-- This is read LIVE across schemas in the same database -- GRAC_New is a
-- schema (ControlManagement 001 creates it), not a separate database.
--
-- WHY THE REFERENCES ARE SOFT
-- ---------------------------
-- obligation_id, event_type_id and release_id point at GRAC_New tables in
-- this same database, so a real foreign key WOULD be possible. They are
-- deliberately left soft, matching how this repo already treats every
-- admin-repository identifier on the org side:
--     organization_requirement.repository_requirement_id  -- no FK
--     repository_subscription.release_id                  -- no FK
-- An organization's recorded decisions must survive the admin repository
-- retiring or re-publishing a row; a hard FK would either block that or
-- cascade into org data. The label / code columns beside each id are
-- display snapshots so a screen or an audit export still reads correctly
-- once the admin row is gone.
--
-- Affected objects:
--   * grac_practice.event_obligation_applicability  (NEW)
--   * grac_practice.event_instance_obligation       (NEW -- per-obligation result)
--   * grac_practice.event_instance                  (+ obligation-origin columns)
--
-- Depends on 123 (event_instance scope columns), 126 (baseline events).
-- Procedures follow in 128_event_obligation_scope_procs.sql.
-- Rollback: 127_event_obligation_scope_schema_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.event_instance','U') IS NULL
   OR COL_LENGTH('grac_practice.event_instance','subject_record_id') IS NULL
   OR OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.dependency_asset_category_master','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_requirement','U') IS NULL
BEGIN
    RAISERROR('127: prerequisites missing (run 066 and 123 first).', 16, 1);
    SET NOEXEC ON;
END
GO

-- GRAC_New is a SCHEMA in this same database (ControlManagement 001 does
-- CREATE SCHEMA GRAC_New), not a separate database. So the guard is
-- SCHEMA_ID + two-part OBJECT_ID, exactly as 122 already does it. An
-- earlier cut of this file tested DB_ID('GRAC_New'), which is always NULL
-- for a schema -- that fired this RAISERROR, set NOEXEC ON, and every
-- later statement referencing a column the skipped ALTERs would have
-- created then failed to compile.
IF SCHEMA_ID('GRAC_New') IS NULL
   OR OBJECT_ID('GRAC_New.obligation_assurance_spec','U') IS NULL
   OR OBJECT_ID('GRAC_New.obligation_requirement_release_map','U') IS NULL
   OR OBJECT_ID('GRAC_New.requirement_obligation','U') IS NULL
   OR OBJECT_ID('GRAC_New.event_type_master','U') IS NULL
BEGIN
    RAISERROR('127: GRAC_New obligation/event objects missing. Run ControlManagement migrations 001 and 033 against this database first.', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. event_obligation_applicability
--
--    One row per (organization, obligation, event type, scope value).
--    Absence of a row means "not decided yet" -- which the resolver
--    reports as a coverage gap rather than silently skipping.
-- =====================================================================
IF OBJECT_ID('grac_practice.event_obligation_applicability','U') IS NULL
CREATE TABLE grac_practice.event_obligation_applicability(
    applicability_id        BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_event_obl_applicability PRIMARY KEY,
    organization_id         BIGINT        NOT NULL,

    -- Soft references into GRAC_New (no cross-database FK possible).
    obligation_id           BIGINT        NOT NULL,
    obligation_label        NVARCHAR(400) NULL,   -- display snapshot
    event_type_id           BIGINT        NOT NULL,
    event_type_code         NVARCHAR(60)  NULL,   -- display snapshot
    release_id              BIGINT        NULL,   -- which release carried it

    scope_dimension         NVARCHAR(40)  NOT NULL,   -- ORG_ROLE / ASSET_CATEGORY
    scope_role_id           BIGINT        NULL,
    scope_asset_category_id INT           NULL,

    is_applicable           BIT           NOT NULL
        CONSTRAINT df_pm_event_obl_app_applicable DEFAULT 1,
    rationale               NVARCHAR(1000) NULL,     -- mandatory when NOT applicable

    owner_role_id           BIGINT        NULL,
    due_days                INT           NULL,

    status                  NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_event_obl_app_status DEFAULT N'Active',
    entered_by              NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_event_obl_app_eb DEFAULT 'system',
    entered_dt              DATETIME2     NOT NULL
        CONSTRAINT df_pm_event_obl_app_ed DEFAULT SYSUTCDATETIME(),
    updated_by              NVARCHAR(100) NULL,
    updated_dt              DATETIME2     NULL,

    CONSTRAINT fk_pm_event_obl_app_org
        FOREIGN KEY (organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_event_obl_app_scope_role
        FOREIGN KEY (scope_role_id) REFERENCES grac_practice.organization_role(role_id),
    CONSTRAINT fk_pm_event_obl_app_scope_asset_cat
        FOREIGN KEY (scope_asset_category_id)
        REFERENCES grac_practice.dependency_asset_category_master(asset_category_id),
    CONSTRAINT fk_pm_event_obl_app_owner_role
        FOREIGN KEY (owner_role_id) REFERENCES grac_practice.organization_role(role_id),

    CONSTRAINT ck_pm_event_obl_app_status
        CHECK (status IN (N'Active', N'Inactive')),
    CONSTRAINT ck_pm_event_obl_app_scope CHECK (
        (scope_dimension = N'ORG_ROLE'
             AND scope_role_id IS NOT NULL AND scope_asset_category_id IS NULL)
     OR (scope_dimension = N'ASSET_CATEGORY'
             AND scope_asset_category_id IS NOT NULL AND scope_role_id IS NULL)),
    -- "Not applicable" without a reason will not survive an audit.
    CONSTRAINT ck_pm_event_obl_app_rationale
        CHECK (is_applicable = 1 OR rationale IS NOT NULL),
    CONSTRAINT ck_pm_event_obl_app_due
        CHECK (due_days IS NULL OR due_days BETWEEN 0 AND 3650)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'uq_pm_event_obl_app_natural'
                 AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
    CREATE UNIQUE INDEX uq_pm_event_obl_app_natural
        ON grac_practice.event_obligation_applicability(
            organization_id, obligation_id, event_type_id,
            scope_role_id, scope_asset_category_id);
GO

-- Resolver hot path: "which obligations apply to this role for this event?"
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_event_obl_app_resolve'
                 AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
    CREATE INDEX ix_pm_event_obl_app_resolve
        ON grac_practice.event_obligation_applicability(
            organization_id, event_type_id, scope_dimension,
            scope_role_id, scope_asset_category_id)
        INCLUDE (obligation_id, is_applicable, owner_role_id, due_days, status, release_id);
GO

-- Mapping workspace: "everything decided for this role".
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_event_obl_app_by_role'
                 AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
    CREATE INDEX ix_pm_event_obl_app_by_role
        ON grac_practice.event_obligation_applicability(organization_id, scope_role_id)
        INCLUDE (obligation_id, event_type_id, is_applicable, status)
        WHERE scope_role_id IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_event_obl_app_by_asset_cat'
                 AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
    CREATE INDEX ix_pm_event_obl_app_by_asset_cat
        ON grac_practice.event_obligation_applicability(organization_id, scope_asset_category_id)
        INCLUDE (obligation_id, event_type_id, is_applicable, status)
        WHERE scope_asset_category_id IS NOT NULL;
GO


-- =====================================================================
-- 2. event_instance -- obligation-origin columns
--
--    checklist_id stays NULL for obligation-derived instances; 066's
--    checklist path is untouched. origin_kind is the discriminator so a
--    reader never has to infer intent from which column is populated.
-- =====================================================================
IF COL_LENGTH('grac_practice.event_instance','origin_kind') IS NULL
    ALTER TABLE grac_practice.event_instance
        ADD origin_kind NVARCHAR(20) NULL;     -- CHECKLIST / OBLIGATION
GO

IF COL_LENGTH('grac_practice.event_instance','event_type_id') IS NULL
    ALTER TABLE grac_practice.event_instance
        ADD event_type_id BIGINT NULL;         -- soft ref GRAC_New.event_type_master
GO

IF COL_LENGTH('grac_practice.event_instance','event_type_code') IS NULL
    ALTER TABLE grac_practice.event_instance
        ADD event_type_code NVARCHAR(60) NULL;
GO

-- Existing rows all came from the checklist path.
--
-- Statements that READ a column added earlier in this same script go through
-- EXEC(): SQL Server compiles a whole batch before running any of it, so a
-- direct reference to a column that does not exist yet -- or whose ALTER was
-- skipped because a guard set NOEXEC ON -- fails at compile time with
-- "Invalid column name" instead of being cleanly skipped. Dynamic SQL defers
-- that resolution to execution, which is what makes this script safe to
-- re-run after a partial failure.
IF COL_LENGTH('grac_practice.event_instance','origin_kind') IS NOT NULL
    EXEC('UPDATE grac_practice.event_instance
             SET origin_kind = N''CHECKLIST''
           WHERE origin_kind IS NULL;');
GO

IF COL_LENGTH('grac_practice.event_instance','origin_kind') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_instance_origin_kind')
    EXEC('ALTER TABLE grac_practice.event_instance
              ADD CONSTRAINT ck_pm_event_instance_origin_kind CHECK (
                  origin_kind IS NULL OR origin_kind IN (N''CHECKLIST'', N''OBLIGATION''));');
GO


-- =====================================================================
-- 3. event_instance_obligation -- one row per obligation on the instance
--
--    Parallel to event_instance_item rather than an extension of it:
--    event_instance_item.checklist_item_id is NOT NULL with a real FK, and
--    an obligation is not a checklist item. Forcing one table would mean
--    making that FK nullable and losing the guarantee that every checklist
--    row points at a real checklist item.
-- =====================================================================
IF OBJECT_ID('grac_practice.event_instance_obligation','U') IS NULL
CREATE TABLE grac_practice.event_instance_obligation(
    event_instance_obligation_id BIGINT       IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_event_instance_obligation PRIMARY KEY,
    event_instance_id       BIGINT        NOT NULL,
    organization_id         BIGINT        NOT NULL,

    obligation_id           BIGINT        NOT NULL,   -- soft ref GRAC_New
    obligation_label        NVARCHAR(400) NULL,       -- snapshot at raise time
    obligation_text         NVARCHAR(MAX) NULL,       -- snapshot: what was asked
    applicability_id        BIGINT        NULL,       -- which mapping produced it

    item_sequence           INT           NOT NULL
        CONSTRAINT df_pm_event_instance_obl_seq DEFAULT 1,
    is_mandatory            BIT           NOT NULL
        CONSTRAINT df_pm_event_instance_obl_mandatory DEFAULT 1,
    evidence_required       BIT           NOT NULL
        CONSTRAINT df_pm_event_instance_obl_evidence DEFAULT 0,

    item_status             NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_event_instance_obl_status DEFAULT N'Pending',
    evidence_url            NVARCHAR(1000) NULL,
    remarks                 NVARCHAR(MAX) NULL,
    na_justification        NVARCHAR(2000) NULL,
    completed_by            NVARCHAR(100) NULL,
    completed_dt            DATETIME2     NULL,

    entered_dt              DATETIME2     NOT NULL
        CONSTRAINT df_pm_event_instance_obl_ed DEFAULT SYSUTCDATETIME(),
    updated_by              NVARCHAR(100) NULL,
    updated_dt              DATETIME2     NULL,

    CONSTRAINT fk_pm_event_instance_obl_instance
        FOREIGN KEY (event_instance_id)
        REFERENCES grac_practice.event_instance(event_instance_id),
    CONSTRAINT fk_pm_event_instance_obl_org
        FOREIGN KEY (organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_event_instance_obl_applicability
        FOREIGN KEY (applicability_id)
        REFERENCES grac_practice.event_obligation_applicability(applicability_id),
    CONSTRAINT ck_pm_event_instance_obl_status
        CHECK (item_status IN (N'Pending', N'Passed', N'Failed',
                               N'NotApplicable', N'InProgress')),
    -- NotApplicable must carry a reason, same rule as the mapping table.
    CONSTRAINT ck_pm_event_instance_obl_na
        CHECK (item_status <> N'NotApplicable' OR na_justification IS NOT NULL),
    CONSTRAINT uq_pm_event_instance_obl
        UNIQUE (event_instance_id, obligation_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_event_instance_obl_instance'
                 AND object_id = OBJECT_ID('grac_practice.event_instance_obligation'))
    CREATE INDEX ix_pm_event_instance_obl_instance
        ON grac_practice.event_instance_obligation(event_instance_id, item_status)
        INCLUDE (obligation_id, item_sequence, is_mandatory);
GO


-- =====================================================================
-- 4. event_mapping_resolution -- obligation columns
--
--    123 created this table keyed on mapping_id / checklist_id. The
--    obligation path needs the same trace, so the columns are widened
--    rather than a second trace table introduced -- one store, one
--    reader, no reconciliation.
-- =====================================================================
IF COL_LENGTH('grac_practice.event_mapping_resolution','obligation_id') IS NULL
    ALTER TABLE grac_practice.event_mapping_resolution
        ADD obligation_id BIGINT NULL;
GO

IF COL_LENGTH('grac_practice.event_mapping_resolution','obligation_label') IS NULL
    ALTER TABLE grac_practice.event_mapping_resolution
        ADD obligation_label NVARCHAR(400) NULL;
GO

IF COL_LENGTH('grac_practice.event_mapping_resolution','applicability_id') IS NULL
    ALTER TABLE grac_practice.event_mapping_resolution
        ADD applicability_id BIGINT NULL;
GO

IF COL_LENGTH('grac_practice.event_mapping_resolution','event_type_id') IS NULL
    ALTER TABLE grac_practice.event_mapping_resolution
        ADD event_type_id BIGINT NULL;
GO

-- 123 constrained reason_code to the checklist-path vocabulary. The
-- obligation path adds its own reasons, so the constraint is replaced.
IF EXISTS (SELECT 1 FROM sys.check_constraints
           WHERE name = 'ck_pm_event_mapping_resolution_reason')
    ALTER TABLE grac_practice.event_mapping_resolution
        DROP CONSTRAINT ck_pm_event_mapping_resolution_reason;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = 'ck_pm_event_mapping_resolution_reason2')
    ALTER TABLE grac_practice.event_mapping_resolution
        ADD CONSTRAINT ck_pm_event_mapping_resolution_reason2 CHECK (reason_code IN (
            -- checklist path (123/124)
            N'ScopeMatched', N'UnscopedMapping', N'ScopeMismatch', N'NoMappingForEvent',
            N'SubjectScopeMissing', N'ReleaseNotSubscribed', N'MappingInactive',
            N'ChecklistInactive', N'NoChecklistItems', N'AlreadyOpen',
            -- obligation path (127/128)
            N'ObligationApplicable',      -- mapped applicable to this scope
            N'ObligationNotApplicable',   -- explicitly excluded, with rationale
            N'ObligationUnmapped',        -- no decision recorded yet -> coverage gap
            N'RequirementNotApplicable',  -- practice/requirement not applicable to org
            N'ObligationNotEventDriven',  -- trigger_mode is not EventDriven
            N'EventTypeMismatch'));       -- event-driven, but for a different event
GO

-- 123's included-must-have-mapping check assumed the checklist path.
IF EXISTS (SELECT 1 FROM sys.check_constraints
           WHERE name = 'ck_pm_event_mapping_resolution_included')
    ALTER TABLE grac_practice.event_mapping_resolution
        DROP CONSTRAINT ck_pm_event_mapping_resolution_included;
GO

-- EXEC() for the same reason as above: both statements read obligation_id,
-- which this script added a few batches earlier.
IF COL_LENGTH('grac_practice.event_mapping_resolution','obligation_id') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints
                    WHERE name = 'ck_pm_event_mapping_resolution_included2')
    EXEC('ALTER TABLE grac_practice.event_mapping_resolution
              ADD CONSTRAINT ck_pm_event_mapping_resolution_included2 CHECK (
                  decision = N''Excluded'' OR mapping_id IS NOT NULL OR obligation_id IS NOT NULL);');
GO

IF COL_LENGTH('grac_practice.event_mapping_resolution','obligation_id') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'ix_pm_event_mapping_resolution_obligation'
                      AND object_id = OBJECT_ID('grac_practice.event_mapping_resolution'))
    EXEC('CREATE INDEX ix_pm_event_mapping_resolution_obligation
              ON grac_practice.event_mapping_resolution(organization_id, obligation_id, entered_dt DESC)
              WHERE obligation_id IS NOT NULL;');
GO

COMMIT TRAN;
GO


-- =====================================================================
-- 5. Diagnostic view -- every event-driven obligation reaching an org
--
--    This is the join the mapping screen is built on. Exposed as a view
--    so it can be inspected directly when a practice "does not show up",
--    which is exactly the symptom that produced this migration.
-- =====================================================================
CREATE OR ALTER VIEW grac_practice.vw_pm_event_driven_obligation
AS
    SELECT DISTINCT
        req.organization_id,
        req.organization_requirement_id,
        req.requirement_code,
        req.requirement_name,
        req.applicability_status                                   AS RequirementApplicability,
        p.practice_id,
        p.practice_code,
        p.practice_name,
        p.applicability_status                                     AS PracticeApplicability,
        orm.release_id,
        o.obligation_id,
        COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''),
                 LEFT(o.obligation_text, 300))                     AS obligation_label,
        o.obligation_text,
        spec.trigger_mode,
        spec.event_type_id,
        et.event_code                                              AS event_type_code,
        et.event_name                                              AS event_type_name,
        et.subject_entity,
        CAST(CASE WHEN EXISTS (
                 SELECT 1 FROM grac_practice.repository_subscription s
                  WHERE s.organization_id     = req.organization_id
                    AND s.release_id          = orm.release_id
                    AND s.subscription_status = N'Active'
                    AND s.status              = N'Active')
             THEN 1 ELSE 0 END AS BIT)                             AS is_subscribed
    FROM       grac_practice.organization_requirement req
    LEFT JOIN  grac_practice.practice p
           ON  p.organization_requirement_id = req.organization_requirement_id
          AND  p.organization_id             = req.organization_id
          AND  p.status                      = N'Active'
    LEFT JOIN  GRAC_New.requirement repo_req
           ON  repo_req.requirement_code = req.requirement_code
          AND  repo_req.status           = N'Active'
    JOIN       GRAC_New.obligation_requirement_release_map orm
           ON  orm.requirement_id = COALESCE(req.repository_requirement_id, repo_req.requirement_id)
          AND  orm.status         = N'Active'
    JOIN       GRAC_New.requirement_obligation o
           ON  o.obligation_id = orm.obligation_id
    JOIN       GRAC_New.obligation_assurance_spec spec
           ON  spec.obligation_id = o.obligation_id
          AND  spec.status        = N'Active'
    JOIN       GRAC_New.event_type_master et
           ON  et.event_type_id = spec.event_type_id
          AND  et.status        = N'Active'
    -- trigger_mode is stored as the CODE by ControlManagement 033.
    WHERE      spec.trigger_mode = N'EventDriven'
      AND      req.status        = N'Active';
GO


-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'event_obligation_applicability table' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.event_obligation_applicability','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'event_instance_obligation table',
       CASE WHEN OBJECT_ID('grac_practice.event_instance_obligation','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'event_instance.origin_kind',
       CASE WHEN COL_LENGTH('grac_practice.event_instance','origin_kind') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'resolution.obligation_id',
       CASE WHEN COL_LENGTH('grac_practice.event_mapping_resolution','obligation_id') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'vw_pm_event_driven_obligation view',
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_event_driven_obligation','V') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;

-- THE ANSWER TO "why does my practice not show up".
-- Run this and read the flags: is_subscribed = 0 means the release is not
-- subscribed; PracticeApplicability not 'Applicable' means the practice is
-- not switched on for the org; no rows at all means the obligation's
-- trigger_mode / event_type_id is not set in GRAC-ADMIN.
PRINT '--- Event-driven obligations reaching each organization ---';
SELECT organization_id, practice_code, obligation_label,
       event_type_code, subject_entity,
       RequirementApplicability, PracticeApplicability, is_subscribed
FROM   grac_practice.vw_pm_event_driven_obligation
ORDER BY organization_id, practice_code, obligation_id;

PRINT '127 Obligation-based event scoping schema deployed.';
PRINT 'NEXT: run 128_event_obligation_scope_procs.sql.';
GO

SET NOEXEC OFF;
GO
