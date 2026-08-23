-- =====================================================================
-- 073 Organization Assurance (Phase 2) -- Stage 2 Scope Builder schema
--
-- Business context (BRD Part 2 Sec 2 + Sec 3):
--   * Sec 2 -- Scope Builder: user configures the assurance scope
--     using one or more of 17 dimensions with AND/OR/NOT operators.
--   * Sec 3 -- Scope Resolution Engine (Stage 3): at execution time the
--     configured scope is dynamically resolved to organization
--     entities. Only the STORAGE for Sec 2 is delivered here; the
--     resolver is deferred.
--
-- Normalized structure (metadata-driven, extensible):
--
--   org_assurance_scope_dimension_master
--       17 seeded dimensions with a is_pickable flag indicating
--       whether Practice Management already has a value-lookup path
--       for the dimension. Non-pickable dimensions are still
--       selectable in the UI -- callers can save them with
--       "include all" semantics or wait for the picker.
--
--   org_assurance_scope_group
--       One row per group. Groups are combined by group_operator
--       (AND / OR) against the previous group in group_order. First
--       group's operator is ignored (defaults to AND).
--
--   org_assurance_scope_condition
--       One row per condition inside a group. Conditions are combined
--       by condition_operator against the previous condition in
--       condition_order. is_not applies NOT to a single condition.
--       include_all=1 => match every value of the dimension (no
--       explicit value rows required).
--
--   org_assurance_scope_condition_value
--       Explicit value rows for a condition. dimension_entity_id is
--       the ID from the source table (e.g. department_id, vendor_id,
--       practice_instance_id); dimension_entity_code/name are
--       captured at save-time so the scope stays readable even if the
--       source row is later inactivated.
--
-- Scope is tied to a definition VERSION (not the definition itself)
-- so historical executions can safely snapshot the scope of the
-- exact version that ran. Edits are permitted only when the version
-- is Draft -- enforced at the sp_org_assurance_scope_save proc (074).
--
-- Naming: grac_practice.org_assurance_scope_* -- distinct from every
-- existing (unrelated) scope_* / scope_group / scope_condition object.
-- Rollback: 073_org_assurance_scope_schema_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Prerequisites
IF OBJECT_ID('grac_practice.org_assurance_definition','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_definition_version','U') IS NULL
BEGIN
    RAISERROR('073: run 069 first (org_assurance_definition schema missing).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Dimension master + seed
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_scope_dimension_master','U') IS NULL
CREATE TABLE grac_practice.org_assurance_scope_dimension_master(
    dimension_id       INT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_scope_dim PRIMARY KEY,
    dimension_code     NVARCHAR(60)  NOT NULL
        CONSTRAINT uq_pm_oa_scope_dim_code UNIQUE,
    dimension_name     NVARCHAR(160) NOT NULL,
    category           NVARCHAR(60)  NOT NULL,
    -- 1 = PM has a value-lookup path implemented in
    -- sp_org_assurance_scope_dimension_values (074). 0 = dimension
    -- structure is savable but the picker is deferred to Stage 2b.
    is_pickable        BIT           NOT NULL CONSTRAINT df_pm_oa_scope_dim_pickable DEFAULT 0,
    display_order      INT           NOT NULL CONSTRAINT df_pm_oa_scope_dim_order    DEFAULT 0,
    is_active          BIT           NOT NULL CONSTRAINT df_pm_oa_scope_dim_active   DEFAULT 1,
    entered_by         NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_scope_dim_ent_by   DEFAULT 'system',
    entered_dt         DATETIME2     NOT NULL CONSTRAINT df_pm_oa_scope_dim_ent_dt   DEFAULT SYSUTCDATETIME(),
    updated_by         NVARCHAR(100) NULL,
    updated_dt         DATETIME2     NULL
);
GO

-- Seed the 17 BRD dimensions. is_pickable = 1 for the ones sp_..._values
-- (in 074) knows how to fetch from Practice Management tables.
MERGE grac_practice.org_assurance_scope_dimension_master AS t
USING (VALUES
    (N'PRACTICE_CATEGORY',   N'Practice Categories',   N'Practice',    0,  1),
    (N'PRACTICE_INSTANCE',   N'Practice Instances',    N'Practice',    1,  2),
    (N'FRAMEWORK',           N'Frameworks',            N'Compliance',  0,  3),
    (N'REQUIREMENT',         N'Requirements',          N'Compliance',  0,  4),
    (N'OBLIGATION',          N'Obligations',           N'Compliance',  0,  5),
    (N'ASSET_CATEGORY',      N'Asset Categories',      N'Dependency',  0,  6),
    (N'ASSET',               N'Assets',                N'Dependency',  1,  7),
    (N'DEPARTMENT',          N'Departments',           N'Organization',1,  8),
    (N'BRANCH',              N'Branches',              N'Organization',0,  9),
    (N'BUSINESS_UNIT',       N'Business Units',        N'Organization',0, 10),
    (N'VENDOR',              N'Vendors',               N'Dependency',  1, 11),
    (N'VENDOR_SERVICE',      N'Vendor Services',       N'Dependency',  0, 12),
    (N'APPLICATION',         N'Applications',          N'Dependency',  0, 13),
    (N'PRODUCT',             N'Products',              N'Dependency',  0, 14),
    (N'PROCESS',             N'Processes',             N'Dependency',  0, 15),
    (N'RISK',                N'Risks',                 N'Risk',        0, 16),
    (N'PEOPLE_ROLE',         N'People Roles',          N'People',      0, 17)
) AS src(dimension_code, dimension_name, category, is_pickable, display_order)
ON t.dimension_code = src.dimension_code
WHEN MATCHED THEN UPDATE SET
    dimension_name = src.dimension_name,
    category       = src.category,
    is_pickable    = src.is_pickable,
    display_order  = src.display_order,
    is_active      = 1,
    updated_by     = 'seed-073',
    updated_dt     = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (dimension_code, dimension_name, category, is_pickable, display_order, is_active, entered_by)
VALUES
    (src.dimension_code, src.dimension_name, src.category, src.is_pickable, src.display_order, 1, 'seed-073');
GO

-- =====================================================================
-- 2. Scope groups
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_scope_group','U') IS NULL
CREATE TABLE grac_practice.org_assurance_scope_group(
    scope_group_id                       BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_scope_group PRIMARY KEY,
    org_assurance_definition_id          BIGINT NOT NULL,
    org_assurance_definition_version_id  BIGINT NOT NULL,
    organization_id                      BIGINT NOT NULL,
    -- 'AND' / 'OR' -- how this group combines with the previous group.
    group_operator                       NVARCHAR(10) NOT NULL
        CONSTRAINT df_pm_oa_scope_group_op DEFAULT N'AND',
    group_order                          INT           NOT NULL,
    group_label                          NVARCHAR(200) NULL,
    is_active                            BIT           NOT NULL
        CONSTRAINT df_pm_oa_scope_group_active DEFAULT 1,
    entered_by                           NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_scope_group_ent_by DEFAULT 'system',
    entered_dt                           DATETIME2     NOT NULL
        CONSTRAINT df_pm_oa_scope_group_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by                           NVARCHAR(100) NULL,
    updated_dt                           DATETIME2     NULL,
    CONSTRAINT fk_pm_oa_scope_group_def
        FOREIGN KEY(org_assurance_definition_id)
        REFERENCES grac_practice.org_assurance_definition(org_assurance_definition_id),
    CONSTRAINT fk_pm_oa_scope_group_ver
        FOREIGN KEY(org_assurance_definition_version_id)
        REFERENCES grac_practice.org_assurance_definition_version(org_assurance_definition_version_id),
    CONSTRAINT fk_pm_oa_scope_group_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT ck_pm_oa_scope_group_op
        CHECK (group_operator IN (N'AND', N'OR'))
);
GO

CREATE INDEX ix_pm_oa_scope_group_ver
    ON grac_practice.org_assurance_scope_group(org_assurance_definition_version_id, group_order);
GO

-- =====================================================================
-- 3. Scope conditions
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_scope_condition','U') IS NULL
CREATE TABLE grac_practice.org_assurance_scope_condition(
    scope_condition_id      BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_scope_condition PRIMARY KEY,
    scope_group_id          BIGINT NOT NULL,
    organization_id         BIGINT NOT NULL,
    dimension_id            INT    NOT NULL,
    is_not                  BIT    NOT NULL CONSTRAINT df_pm_oa_scope_cond_not DEFAULT 0,
    -- 'AND' / 'OR' -- how this condition combines with the previous
    -- condition in the same group. First condition's value is ignored.
    condition_operator      NVARCHAR(10) NOT NULL
        CONSTRAINT df_pm_oa_scope_cond_op DEFAULT N'AND',
    condition_order         INT NOT NULL,
    -- 1 = "include every value of this dimension" (no value rows needed)
    -- 0 = look at org_assurance_scope_condition_value for the explicit set
    include_all             BIT NOT NULL CONSTRAINT df_pm_oa_scope_cond_all DEFAULT 0,
    is_active               BIT NOT NULL CONSTRAINT df_pm_oa_scope_cond_active DEFAULT 1,
    entered_by              NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_scope_cond_ent_by DEFAULT 'system',
    entered_dt              DATETIME2 NOT NULL CONSTRAINT df_pm_oa_scope_cond_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by              NVARCHAR(100) NULL,
    updated_dt              DATETIME2 NULL,
    CONSTRAINT fk_pm_oa_scope_cond_group
        FOREIGN KEY(scope_group_id) REFERENCES grac_practice.org_assurance_scope_group(scope_group_id),
    CONSTRAINT fk_pm_oa_scope_cond_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_scope_cond_dim
        FOREIGN KEY(dimension_id) REFERENCES grac_practice.org_assurance_scope_dimension_master(dimension_id),
    CONSTRAINT ck_pm_oa_scope_cond_op
        CHECK (condition_operator IN (N'AND', N'OR'))
);
GO

CREATE INDEX ix_pm_oa_scope_cond_group
    ON grac_practice.org_assurance_scope_condition(scope_group_id, condition_order);
GO

-- =====================================================================
-- 4. Scope condition values (explicit picks)
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_scope_condition_value','U') IS NULL
CREATE TABLE grac_practice.org_assurance_scope_condition_value(
    scope_condition_value_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_scope_cond_value PRIMARY KEY,
    scope_condition_id       BIGINT NOT NULL,
    organization_id          BIGINT NOT NULL,
    -- ID from the source table (e.g. department_id, vendor_id,
    -- practice_instance_id, asset_id). NULL is allowed for free-entry
    -- dimensions in Stage 2b -- unused today.
    dimension_entity_id      BIGINT NULL,
    dimension_entity_code    NVARCHAR(120) NULL,
    dimension_entity_name    NVARCHAR(240) NULL,
    is_active                BIT NOT NULL CONSTRAINT df_pm_oa_scope_cv_active DEFAULT 1,
    entered_by               NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_scope_cv_ent_by DEFAULT 'system',
    entered_dt               DATETIME2 NOT NULL CONSTRAINT df_pm_oa_scope_cv_ent_dt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_pm_oa_scope_cv_cond
        FOREIGN KEY(scope_condition_id) REFERENCES grac_practice.org_assurance_scope_condition(scope_condition_id),
    CONSTRAINT fk_pm_oa_scope_cv_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id)
);
GO

CREATE INDEX ix_pm_oa_scope_cv_cond
    ON grac_practice.org_assurance_scope_condition_value(scope_condition_id);
GO

COMMIT TRAN;
GO

-- Sanity report
SELECT '17 scope dimensions seeded' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.org_assurance_scope_dimension_master WHERE is_active = 1) = 17
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'org_assurance_scope_group present'      AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_scope_group','U') IS NOT NULL      THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_assurance_scope_condition present'  AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_scope_condition','U') IS NOT NULL  THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org_assurance_scope_condition_value present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_scope_condition_value','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '073 Organization Assurance Scope schema deployed.';
GO

SET NOEXEC OFF;
GO
