-- =====================================================================
-- 329 Event Assurance -- Profiles: attribute-based applicability scoping
--
-- WHY THIS EXISTS -- extending 127, not replacing it
-- --------------------------------------------------
-- 127 made an obligation applicable to a SINGLE organisation role
-- (People) or a SINGLE asset category (Assets). For People that is too
-- narrow. Whether an onboarding obligation applies is rarely decided by
-- role alone:
--
--     "India / Kerala + IT Operations + System Administrator or IT
--      Manager"  is one population.
--     "Finance, every location, every role"  is another.
--
-- Expressed with scope_role_id the first needs one applicability row per
-- role and cannot express Location or Department at all; the second needs
-- one row per role in the organisation and silently goes wrong the moment
-- a role is added.
--
-- A Profile is the population itself: a named, org-scoped set of
-- attribute criteria. The mapping then reads
--
--     Profile -> Event Type -> Obligation
--
-- instead of
--
--     Role -> Obligation
--
-- WHY A THIRD scope_dimension AND NOT A NEW MAPPING TABLE
-- ------------------------------------------------------
-- 123 chose one nullable-pair + a discriminator over one table per scope
-- kind, precisely so a third kind would not mean a third table, a third
-- resolution branch and a third screen. This migration is that third
-- kind. event_obligation_applicability gains profile_id and its CHECK
-- learns one more shape. Every ORG_ROLE and ASSET_CATEGORY row already in
-- the table stays valid, is not rewritten, and keeps resolving exactly as
-- it does today -- see 331 for the resolver.
--
-- WHY THE CRITERIA ARE METADATA-DRIVEN AND NOT FOUR COLUMNS
-- ---------------------------------------------------------
-- Four columns (location_id, department_id, role_id, designation) would
-- answer today's brief and would have to be redesigned the first time
-- Business Function, Reporting Officer, Employment Type or Grade is
-- scoped: a new column, a new CHECK, a new save parameter, a new matcher
-- branch and a new UI field, on every one of them.
--
-- So the criteria are rows, and the dimension list is a master table --
-- the same shape org_assurance_scope_dimension_master (073) already uses
-- in this schema for exactly this problem. Each dimension row carries the
-- lookup it resolves against AND the employee column it matches on, so
-- the value picker, the matcher and the screen are all data-driven. A new
-- criterion is then a seed row here plus one branch in
-- sp_event_profile_dimension_values -- no schema, save proc, resolver or
-- screen change.
--
-- WHY value_kind
-- --------------
-- location_id, department_id, role_id and business_function_id are real
-- foreign keys on organization_employee. designation is NOT: it is a
-- free-text NVARCHAR(150) with no master anywhere in the product. Rather
-- than pretend otherwise, a dimension declares whether its values are IDs
-- or text, and the value table carries both columns. DESIGNATION is
-- seeded is_active = 0 -- the model supports it, the product has not yet
-- decided whether it gets a master table, and an inactive dimension is
-- invisible to the picker and the matcher alike.
--
-- WHY subject_entity ON THE PROFILE
-- ---------------------------------
-- Profiles are delivered for People. Assets keep the category-scoped
-- screen (asset-category-assurance) untouched. But an asset population
-- is the same idea with different dimensions, so event_profile carries
-- the discriminator from the start and the dimension master is tagged per
-- subject. Turning Assets on later is a seed plus a UI toggle, not a
-- second table.
--
-- Affected objects:
--   * grac_practice.event_profile_dimension_master  (NEW + seed)
--   * grac_practice.event_profile                   (NEW)
--   * grac_practice.event_profile_criteria          (NEW)
--   * grac_practice.event_profile_criteria_value    (NEW)
--   * grac_practice.event_obligation_applicability  (+ profile_id)
--   * grac_practice.event_instance                  (+ scope profile snapshot)
--   * grac_practice.event_mapping_resolution        (+ profile_id)
--
-- Depends on 127 (applicability table), 123 (event_instance scope columns
-- and event_mapping_resolution), 133 (organization_employee.location_id /
-- department_id / business_function_id).
-- Procedures follow in 330_event_profile_procs.sql and
-- 331_event_profile_resolution_procs.sql.
-- Rollback: 329_event_profile_schema_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- =====================================================================
-- Prerequisites
-- =====================================================================
IF OBJECT_ID('grac_practice.event_obligation_applicability','U') IS NULL
   OR OBJECT_ID('grac_practice.event_instance','U') IS NULL
   OR OBJECT_ID('grac_practice.event_mapping_resolution','U') IS NULL
   OR OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role','U') IS NULL
BEGIN
    RAISERROR('329: prerequisites missing. Run 123 and 127 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- organization_employee must carry the attribute foreign keys the
-- matcher reads. They arrive in 133; without them a profile could be
-- saved and would then match nobody, silently.
IF OBJECT_ID('grac_practice.organization_employee','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','location_id')   IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','department_id') IS NULL
BEGIN
    RAISERROR('329: organization_employee.location_id / department_id missing. Run 133 first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.organization_location','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_department','U') IS NULL
BEGIN
    RAISERROR('329: organization_location / organization_department missing.', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. event_profile_dimension_master
--
--    The extensibility hinge. Every consumer -- picker, matcher, screen
--    -- reads this table rather than hard-coding a dimension list.
--
--    source_* describe where the VALUES come from (the lookup the admin
--    picks from). employee_match_column names the column on
--    organization_employee that a picked value is compared against. The
--    two are separate because they genuinely are: DEPARTMENT's values
--    come from organization_department.department_id, and are matched
--    against organization_employee.department_id.
--
--    ORG_ROLE is the one dimension whose match is not a plain column
--    comparison -- an employee can hold several roles, through two
--    different tables. It is flagged is_multi_valued and the matcher
--    routes it through fn_pm_employee_role_ids (131), the existing single
--    source of truth, instead of reading a column. Marking it in data
--    rather than special-casing it in the matcher keeps the next
--    multi-valued dimension (Team, Committee) a seed row.
-- =====================================================================
IF OBJECT_ID('grac_practice.event_profile_dimension_master','U') IS NULL
CREATE TABLE grac_practice.event_profile_dimension_master(
    dimension_id            INT           IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_event_profile_dim PRIMARY KEY,
    dimension_code          NVARCHAR(40)  NOT NULL
        CONSTRAINT uq_pm_event_profile_dim_code UNIQUE,
    dimension_name          NVARCHAR(160) NOT NULL,

    -- EMPLOYEE / ASSET. Which kind of profile may use this dimension.
    subject_entity          NVARCHAR(60)  NOT NULL,

    -- ID   = values are bigints from source_table (the normal case)
    -- TEXT = values are strings compared case-insensitively (no master)
    value_kind              NVARCHAR(10)  NOT NULL
        CONSTRAINT df_pm_event_profile_dim_kind DEFAULT N'ID',

    -- Where the picker reads its options from. NULL for TEXT dimensions
    -- that have no master -- the picker then offers DISTINCT values in use.
    source_table            NVARCHAR(200) NULL,
    source_id_column        NVARCHAR(128) NULL,
    source_name_column      NVARCHAR(128) NULL,
    -- Set when the source table is organisation-scoped, so the picker
    -- never leaks one tenant's options into another's.
    source_org_column       NVARCHAR(128) NULL,

    -- The organization_employee column a picked value is matched against.
    -- NULL when is_multi_valued = 1 (the matcher uses a function instead).
    employee_match_column   NVARCHAR(128) NULL,
    is_multi_valued         BIT           NOT NULL
        CONSTRAINT df_pm_event_profile_dim_multi DEFAULT 0,

    display_order           INT           NOT NULL
        CONSTRAINT df_pm_event_profile_dim_order DEFAULT 0,
    is_active               BIT           NOT NULL
        CONSTRAINT df_pm_event_profile_dim_active DEFAULT 1,
    entered_by              NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_event_profile_dim_eb DEFAULT 'system',
    entered_dt              DATETIME2     NOT NULL
        CONSTRAINT df_pm_event_profile_dim_ed DEFAULT SYSUTCDATETIME(),
    updated_by              NVARCHAR(100) NULL,
    updated_dt              DATETIME2     NULL,

    CONSTRAINT ck_pm_event_profile_dim_subject
        CHECK (subject_entity IN (N'EMPLOYEE', N'ASSET')),
    CONSTRAINT ck_pm_event_profile_dim_kind
        CHECK (value_kind IN (N'ID', N'TEXT')),
    -- A single-valued dimension must say which column it matches on;
    -- a multi-valued one must not, because it does not match on one.
    CONSTRAINT ck_pm_event_profile_dim_match
        CHECK ((is_multi_valued = 0 AND employee_match_column IS NOT NULL)
            OR (is_multi_valued = 1 AND employee_match_column IS NULL))
);
GO

-- Seed. MERGE with UPDATE so a re-run corrects a drifted row, matching
-- how 073 seeds its own dimension master.
--
-- DESIGNATION is seeded is_active = 0 on purpose: organization_employee.
-- designation is free text with no master table, so the product has an
-- open decision to make (text matching now, or a real master later).
-- The row exists so that turning it on is an UPDATE, not a migration.
MERGE grac_practice.event_profile_dimension_master AS t
USING (VALUES
    (N'LOCATION',   N'Location',   N'EMPLOYEE', N'ID',
     N'grac_practice.organization_location',   N'location_id',   N'location_name',   N'organization_id',
     N'location_id',          0, 10, 1),
    (N'DEPARTMENT', N'Department', N'EMPLOYEE', N'ID',
     N'grac_practice.organization_department', N'department_id', N'department_name', N'organization_id',
     N'department_id',        0, 20, 1),
    (N'ORG_ROLE',   N'Role',       N'EMPLOYEE', N'ID',
     N'grac_practice.organization_role',       N'role_id',       N'role_name',       N'organization_id',
     NULL,                    1, 30, 1),
    -- Free text today. See the note above.
    (N'DESIGNATION', N'Designation', N'EMPLOYEE', N'TEXT',
     NULL, NULL, NULL, NULL,
     N'designation',          0, 40, 0),
    -- Present and inactive, to show the shape a further dimension takes.
    -- Turn on with a single UPDATE; nothing else changes.
    (N'BUSINESS_FUNCTION', N'Business Function', N'EMPLOYEE', N'ID',
     N'grac_practice.organization_business_function', N'business_function_id', N'function_name', N'organization_id',
     N'business_function_id', 0, 50, 0)
) AS src(dimension_code, dimension_name, subject_entity, value_kind,
         source_table, source_id_column, source_name_column, source_org_column,
         employee_match_column, is_multi_valued, display_order, is_active)
ON t.dimension_code = src.dimension_code
WHEN MATCHED THEN UPDATE SET
    dimension_name        = src.dimension_name,
    subject_entity        = src.subject_entity,
    value_kind            = src.value_kind,
    source_table          = src.source_table,
    source_id_column      = src.source_id_column,
    source_name_column    = src.source_name_column,
    source_org_column     = src.source_org_column,
    employee_match_column = src.employee_match_column,
    is_multi_valued       = src.is_multi_valued,
    display_order         = src.display_order,
    is_active             = src.is_active,
    updated_by            = 'seed-329',
    updated_dt            = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (dimension_code, dimension_name, subject_entity, value_kind,
     source_table, source_id_column, source_name_column, source_org_column,
     employee_match_column, is_multi_valued, display_order, is_active, entered_by)
VALUES
    (src.dimension_code, src.dimension_name, src.subject_entity, src.value_kind,
     src.source_table, src.source_id_column, src.source_name_column, src.source_org_column,
     src.employee_match_column, src.is_multi_valued, src.display_order, src.is_active, 'seed-329');
GO


-- =====================================================================
-- 2. event_profile
--
--    One row per named population, per organisation.
--
--    status Active / Inactive rather than a delete: a profile that has
--    produced event instances is the recorded reason those checklists
--    were served, and deleting it would orphan that explanation. 330's
--    delete proc therefore refuses once the profile has been used.
-- =====================================================================
IF OBJECT_ID('grac_practice.event_profile','U') IS NULL
CREATE TABLE grac_practice.event_profile(
    profile_id          BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_event_profile PRIMARY KEY,
    organization_id     BIGINT        NOT NULL,
    profile_code        NVARCHAR(60)  NOT NULL,
    profile_name        NVARCHAR(200) NOT NULL,
    description         NVARCHAR(1000) NULL,

    -- EMPLOYEE today. ASSET reserved -- see the header.
    subject_entity      NVARCHAR(60)  NOT NULL
        CONSTRAINT df_pm_event_profile_subject DEFAULT N'EMPLOYEE',

    status              NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_event_profile_status DEFAULT N'Active',
    entered_by          NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_event_profile_eb DEFAULT 'system',
    entered_dt          DATETIME2     NOT NULL
        CONSTRAINT df_pm_event_profile_ed DEFAULT SYSUTCDATETIME(),
    updated_by          NVARCHAR(100) NULL,
    updated_dt          DATETIME2     NULL,

    CONSTRAINT fk_pm_event_profile_org
        FOREIGN KEY (organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT ck_pm_event_profile_status
        CHECK (status IN (N'Active', N'Inactive')),
    CONSTRAINT ck_pm_event_profile_subject
        CHECK (subject_entity IN (N'EMPLOYEE', N'ASSET')),
    CONSTRAINT uq_pm_event_profile_code
        UNIQUE (organization_id, profile_code)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_event_profile_org_status'
                 AND object_id = OBJECT_ID('grac_practice.event_profile'))
    CREATE INDEX ix_pm_event_profile_org_status
        ON grac_practice.event_profile(organization_id, subject_entity, status)
        INCLUDE (profile_code, profile_name);
GO


-- =====================================================================
-- 3. event_profile_criteria
--
--    One row per dimension constrained by the profile.
--
--    ABSENCE IS THE DEFAULT, AND IT IS "ALL". A profile with no
--    DEPARTMENT row places no department constraint. match_all = 1
--    records the same effect as a deliberate choice, so a screen can show
--    "All" as something the admin picked rather than as something nobody
--    filled in. The matcher treats them identically -- it has to, or the
--    meaning of a profile would depend on which screen created it.
--
--    One row per (profile, dimension): a second DEPARTMENT row would be
--    a second constraint on the same attribute with no defined combining
--    rule. Multiple departments go in the value table, OR-ed.
-- =====================================================================
IF OBJECT_ID('grac_practice.event_profile_criteria','U') IS NULL
CREATE TABLE grac_practice.event_profile_criteria(
    criteria_id         BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_event_profile_criteria PRIMARY KEY,
    profile_id          BIGINT        NOT NULL,
    organization_id     BIGINT        NOT NULL,   -- denormalised for org-isolated reads
    dimension_id        INT           NOT NULL,
    dimension_code      NVARCHAR(40)  NOT NULL,   -- snapshot, so a read needs no join

    match_all           BIT           NOT NULL
        CONSTRAINT df_pm_event_profile_crit_all DEFAULT 0,

    entered_by          NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_event_profile_crit_eb DEFAULT 'system',
    entered_dt          DATETIME2     NOT NULL
        CONSTRAINT df_pm_event_profile_crit_ed DEFAULT SYSUTCDATETIME(),

    CONSTRAINT fk_pm_event_profile_crit_profile
        FOREIGN KEY (profile_id) REFERENCES grac_practice.event_profile(profile_id),
    CONSTRAINT fk_pm_event_profile_crit_dim
        FOREIGN KEY (dimension_id) REFERENCES grac_practice.event_profile_dimension_master(dimension_id),
    CONSTRAINT uq_pm_event_profile_crit_dim
        UNIQUE (profile_id, dimension_code)
);
GO


-- =====================================================================
-- 4. event_profile_criteria_value
--
--    The OR-ed values of one criterion.
--
--    value_label is a save-time snapshot, following
--    org_assurance_scope_condition_value (073) for the same reason: the
--    profile must still read correctly -- on screen and in an audit
--    export -- after the department it names has been renamed or
--    inactivated. The matcher uses the id, never the label.
-- =====================================================================
IF OBJECT_ID('grac_practice.event_profile_criteria_value','U') IS NULL
CREATE TABLE grac_practice.event_profile_criteria_value(
    criteria_value_id   BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_event_profile_crit_value PRIMARY KEY,
    criteria_id         BIGINT        NOT NULL,
    profile_id          BIGINT        NOT NULL,   -- denormalised: the matcher reads by profile

    value_id            BIGINT        NULL,       -- value_kind = ID
    value_text          NVARCHAR(200) NULL,       -- value_kind = TEXT
    value_label         NVARCHAR(300) NULL,       -- display snapshot

    entered_by          NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_event_profile_cv_eb DEFAULT 'system',
    entered_dt          DATETIME2     NOT NULL
        CONSTRAINT df_pm_event_profile_cv_ed DEFAULT SYSUTCDATETIME(),

    CONSTRAINT fk_pm_event_profile_cv_criteria
        FOREIGN KEY (criteria_id) REFERENCES grac_practice.event_profile_criteria(criteria_id),
    CONSTRAINT fk_pm_event_profile_cv_profile
        FOREIGN KEY (profile_id) REFERENCES grac_practice.event_profile(profile_id),
    -- Exactly one of the two value columns. A row carrying neither would
    -- narrow a criterion to nothing and make the profile match no one,
    -- which is never what anybody meant to save.
    CONSTRAINT ck_pm_event_profile_cv_one_value
        CHECK ((value_id IS NOT NULL AND value_text IS NULL)
            OR (value_id IS NULL AND value_text IS NOT NULL))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_event_profile_cv_criteria'
                 AND object_id = OBJECT_ID('grac_practice.event_profile_criteria_value'))
    CREATE INDEX ix_pm_event_profile_cv_criteria
        ON grac_practice.event_profile_criteria_value(criteria_id)
        INCLUDE (value_id, value_text, value_label);
GO

-- Matcher hot path: every value of every criterion of one profile.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_event_profile_cv_profile'
                 AND object_id = OBJECT_ID('grac_practice.event_profile_criteria_value'))
    CREATE INDEX ix_pm_event_profile_cv_profile
        ON grac_practice.event_profile_criteria_value(profile_id)
        INCLUDE (criteria_id, value_id, value_text);
GO


-- =====================================================================
-- 5. event_obligation_applicability -- the third scope shape
--
--    profile_id joins scope_role_id and scope_asset_category_id as a
--    third mutually exclusive scope target. Existing rows are not
--    touched, not rewritten and not migrated: scope_dimension on them
--    still reads ORG_ROLE or ASSET_CATEGORY and 331's resolver still
--    honours both.
-- =====================================================================
IF COL_LENGTH('grac_practice.event_obligation_applicability','profile_id') IS NULL
    ALTER TABLE grac_practice.event_obligation_applicability
        ADD profile_id BIGINT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_obl_app_profile')
   AND COL_LENGTH('grac_practice.event_obligation_applicability','profile_id') IS NOT NULL
    ALTER TABLE grac_practice.event_obligation_applicability
        ADD CONSTRAINT fk_pm_event_obl_app_profile
            FOREIGN KEY (profile_id) REFERENCES grac_practice.event_profile(profile_id);
GO

-- The 127 CHECK allows exactly two shapes. Replacing it is the only way
-- to add a third: SQL Server has no "extend a constraint". Dropped and
-- recreated in one migration so the table is never left unconstrained
-- outside this transaction.
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_obl_app_scope')
    ALTER TABLE grac_practice.event_obligation_applicability
        DROP CONSTRAINT ck_pm_event_obl_app_scope;
GO

-- Statements that READ profile_id go through EXEC() -- the batch is
-- compiled before any of it runs, so a direct reference to a column added
-- earlier in this same script fails at compile time with "Invalid column
-- name" rather than being skipped. Same reasoning as 127's own note.
IF COL_LENGTH('grac_practice.event_obligation_applicability','profile_id') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_obl_app_scope')
    EXEC('ALTER TABLE grac_practice.event_obligation_applicability
              ADD CONSTRAINT ck_pm_event_obl_app_scope CHECK (
                  (scope_dimension = N''ORG_ROLE''
                       AND scope_role_id IS NOT NULL
                       AND scope_asset_category_id IS NULL
                       AND profile_id IS NULL)
               OR (scope_dimension = N''ASSET_CATEGORY''
                       AND scope_asset_category_id IS NOT NULL
                       AND scope_role_id IS NULL
                       AND profile_id IS NULL)
               OR (scope_dimension = N''PROFILE''
                       AND profile_id IS NOT NULL
                       AND scope_role_id IS NULL
                       AND scope_asset_category_id IS NULL));');
GO

-- The 127 natural key is (org, obligation, event_type, role, asset_cat).
-- Two profiles deciding the same obligation would collide on it, because
-- both carry NULL in the two scope columns and SQL Server treats NULLs as
-- equal in a unique index. Replaced by one that includes profile_id.
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'uq_pm_event_obl_app_natural'
             AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
    DROP INDEX uq_pm_event_obl_app_natural
        ON grac_practice.event_obligation_applicability;
GO

IF COL_LENGTH('grac_practice.event_obligation_applicability','profile_id') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = 'uq_pm_event_obl_app_natural'
                     AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
    EXEC('CREATE UNIQUE INDEX uq_pm_event_obl_app_natural
              ON grac_practice.event_obligation_applicability(
                  organization_id, obligation_id, event_type_id,
                  scope_role_id, scope_asset_category_id, profile_id);');
GO

-- Resolver hot path for the profile branch: "which obligations did these
-- profiles decide for this event?"
IF COL_LENGTH('grac_practice.event_obligation_applicability','profile_id') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = 'ix_pm_event_obl_app_by_profile'
                     AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
    EXEC('CREATE INDEX ix_pm_event_obl_app_by_profile
              ON grac_practice.event_obligation_applicability(organization_id, profile_id, event_type_id)
              INCLUDE (obligation_id, is_applicable, owner_role_id, due_days, status, release_id)
              WHERE profile_id IS NOT NULL;');
GO


-- =====================================================================
-- 6. event_instance -- profile snapshot
--
--    Same reasoning as 123's scope_role_name. A profile edited in
--    November must not change what May's onboarding record says it was
--    served against, so the id AND the name are frozen onto the instance.
-- =====================================================================
IF COL_LENGTH('grac_practice.event_instance','scope_profile_id') IS NULL
    ALTER TABLE grac_practice.event_instance
        ADD scope_profile_id BIGINT NULL;
GO

IF COL_LENGTH('grac_practice.event_instance','scope_profile_name') IS NULL
    ALTER TABLE grac_practice.event_instance
        ADD scope_profile_name NVARCHAR(200) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_instance_scope_profile')
   AND COL_LENGTH('grac_practice.event_instance','scope_profile_id') IS NOT NULL
    ALTER TABLE grac_practice.event_instance
        ADD CONSTRAINT fk_pm_event_instance_scope_profile
            FOREIGN KEY (scope_profile_id) REFERENCES grac_practice.event_profile(profile_id);
GO


-- =====================================================================
-- 7. event_mapping_resolution -- profile trace
--
--    "Why is this check missing from this person's onboarding?" is the
--    first question asked in an audit, and with profiles the answer is
--    often "no profile matched them" or "the profile that matched
--    excluded it". Neither is expressible without this column.
-- =====================================================================
IF COL_LENGTH('grac_practice.event_mapping_resolution','profile_id') IS NULL
    ALTER TABLE grac_practice.event_mapping_resolution
        ADD profile_id BIGINT NULL;
GO

IF COL_LENGTH('grac_practice.event_mapping_resolution','profile_name') IS NULL
    ALTER TABLE grac_practice.event_mapping_resolution
        ADD profile_name NVARCHAR(200) NULL;
GO

COMMIT TRAN;
GO


-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'event_profile_dimension_master' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.event_profile_dimension_master','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'event_profile',
       CASE WHEN OBJECT_ID('grac_practice.event_profile','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'event_profile_criteria',
       CASE WHEN OBJECT_ID('grac_practice.event_profile_criteria','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'event_profile_criteria_value',
       CASE WHEN OBJECT_ID('grac_practice.event_profile_criteria_value','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'applicability.profile_id',
       CASE WHEN COL_LENGTH('grac_practice.event_obligation_applicability','profile_id') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'applicability CHECK allows PROFILE',
       CASE WHEN EXISTS (SELECT 1 FROM sys.check_constraints
                          WHERE name = 'ck_pm_event_obl_app_scope'
                            AND OBJECT_DEFINITION(object_id) LIKE '%PROFILE%')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'natural key includes profile_id',
       CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns ic
                          JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                          JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                         WHERE i.name = 'uq_pm_event_obl_app_natural'
                           AND c.name = 'profile_id')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'event_instance.scope_profile_id',
       CASE WHEN COL_LENGTH('grac_practice.event_instance','scope_profile_id') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'resolution.profile_id',
       CASE WHEN COL_LENGTH('grac_practice.event_mapping_resolution','profile_id') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;

PRINT '--- Profile criteria dimensions available ---';
SELECT dimension_code, dimension_name, subject_entity, value_kind,
       employee_match_column, is_multi_valued, is_active, display_order
FROM   grac_practice.event_profile_dimension_master
ORDER BY display_order, dimension_id;

PRINT '329 Event Profile schema deployed.';
PRINT 'NEXT: run 330_event_profile_procs.sql, then 331_event_profile_resolution_procs.sql.';
GO

SET NOEXEC OFF;
GO
