-- =====================================================================
-- 577  Audit Intelligence -- Audit Universe (CR2 - AA, Part A; Phase 1)
--      docs/audit-intelligence.md
--
-- REQUEST (2026-11-17, sir): "CR2 - AA" -- Audit Assurance -> Audit
--   Intelligence. Phase 1 = the Audit Universe: a governed inventory of
--   auditable subjects that REFERENCES Organization Registry records (569)
--   and never copies them.
--
-- WHAT THIS DOES
--   1. Responsibility HEAD_INTERNAL_AUDIT ("Head of Internal Audit") in the
--      553 master. Universe inclusion, deactivation and retirement are
--      approved by a person whose role carries it -- the Head of Internal
--      Audit or a delegate given the responsibility in Role Master (CR2
--      3.3). Nobody approves their own submission (CR2 14.6).
--   2. NEW tables (all per organization = Legal Entity):
--        org_assurance_universe_master        configurable masters (CR2 3.5):
--            CATEGORY, SUBCATEGORY (under a category), CLASSIFICATION,
--            REG_SIGNIFICANCE, CRITICALITY, STATUS (fixed codes, names
--            editable), RELATIONSHIP (relationship types).
--        org_assurance_universe_subject       the Audit Universe Register (3.4).
--        org_assurance_universe_source        subject -> Organization Registry
--            record(s): many per subject (3.3 item 6); the registry record's
--            own id, never a copy.
--        org_assurance_universe_exclusion     registry records excluded as
--            not independently auditable (3.3 item 3), with a reason.
--        org_assurance_universe_relationship  typed many-to-many links
--            between subjects (3.6); Parent Subject is the hierarchy.
--        org_assurance_universe_history       every change, inclusion,
--            exclusion, ownership change and approval (3.7).
--   3. NEW fn_org_assurance_universe_registry_records(@org): the registry
--      records that can become subjects -- the Legal Entity itself,
--      Organization Units, Locations / Branches, Departments, Business
--      Functions, Business Processes. Assets and Third Parties are NOT
--      sources (3.3 exclusions).
--   4. NEW procedures: universe_master_seed / _list / _save,
--      universe_discover, universe_discover_apply (include / exclude /
--      release), universe_lookups, universe_list, universe_get,
--      universe_save, universe_action, universe_relationship_save,
--      universe_history_list.
--   5. Menu: Audit Assurance -> Audit Intelligence (group, 441; 578) ->
--      Audit Universe (10), Universe Configuration (20); the Audit Plans
--      permissions copied to both; written back into 274.
--
-- LIFECYCLE (CR2 3.7): Discovered -> Under Validation -> Active ->
--   Inactive / Retired.
--     SUBMIT      Discovered -> Under Validation        (anyone; Category and
--                                                        Subject Owner needed)
--     APPROVE     Under Validation -> Active            (Head of Internal Audit,
--                                                        not the submitter)
--     RETURN      Under Validation -> Discovered        (HIA, reason)
--     REVIEW      Active -> Active, Last Reviewed On    (HIA)
--     DEACTIVATE  Active -> Inactive                    (HIA, reason)
--     REACTIVATE  Inactive -> Under Validation          (anyone, reason)
--     RETIRE      Active / Inactive -> Retired          (HIA, reason)
--     DISCARD     Discovered -> Retired                 (anyone, reason)
--   Editable while Discovered, Active or Inactive (every change of an
--   Active subject is in the history, before / after). Nothing is deleted.
--   Saves carry the version read (version_no); a stale save is refused.
--
-- ERRORS: 54090 not found; 54091 not allowed in the subject's state;
--   54092 Head of Internal Audit only; 54093 own submission; 54094 reason
--   required; 54095 a required field is missing; 54096 invalid reference;
--   54097 duplicate; 54098 changed by someone else (reload); 54099 master
--   change not allowed.
-- DEPENDS ON: 553 (responsibilities), 566 (fn_org_responsibility_holder),
--   569 (Organization Registry columns).
-- Rollback: 577_audit_universe_rollback.sql.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.role_responsibility_master','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_org_responsibility_holder','IF') IS NULL
   OR COL_LENGTH('grac_practice.organization','entity_owner_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_location','location_code') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_process','process_code') IS NULL
   OR COL_LENGTH('grac_practice.organization_business_function','owner_employee_id') IS NULL
BEGIN
    PRINT 'ABORT (577): run 553, 566 and 569 first. Nothing was changed.';
    RAISERROR('577_audit_universe: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Responsibility: Head of Internal Audit
-- =====================================================================
MERGE grac_practice.role_responsibility_master AS t
USING (VALUES
    (N'HEAD_INTERNAL_AUDIT', N'Head of Internal Audit',
     N'Approves the Audit Universe: inclusion, deactivation and retirement of auditable subjects. Give it to a delegate''s role to delegate.', 40)
) AS s(code, name, descr, ord)
ON t.responsibility_code = s.code
WHEN NOT MATCHED THEN
    INSERT (responsibility_code, responsibility_name, description, display_order, is_active, entered_by)
    VALUES (s.code, s.name, s.descr, s.ord, 1, N'seed-577');
PRINT '577.1: HEAD_INTERNAL_AUDIT responsibility rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 2. Tables
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_universe_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_universe_master(
        universe_master_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_uni_master PRIMARY KEY,
        organization_id    BIGINT         NOT NULL,
        master_group       NVARCHAR(30)   NOT NULL,
        code               NVARCHAR(40)   NOT NULL,
        name               NVARCHAR(200)  NOT NULL,
        description        NVARCHAR(1000) NULL,
        parent_master_id   BIGINT         NULL,
        rank_value         INT            NULL,
        display_order      INT            NOT NULL CONSTRAINT df_pm_oa_uni_master_order DEFAULT 0,
        is_system          BIT            NOT NULL CONSTRAINT df_pm_oa_uni_master_system DEFAULT 0,
        is_active          BIT            NOT NULL CONSTRAINT df_pm_oa_uni_master_active DEFAULT 1,
        entered_by         NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_oa_uni_master_by DEFAULT 'system',
        entered_dt         DATETIME2      NOT NULL CONSTRAINT df_pm_oa_uni_master_dt DEFAULT SYSUTCDATETIME(),
        updated_by         NVARCHAR(100)  NULL,
        updated_dt         DATETIME2      NULL,
        CONSTRAINT fk_pm_oa_uni_master_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
        CONSTRAINT fk_pm_oa_uni_master_parent FOREIGN KEY(parent_master_id) REFERENCES grac_practice.org_assurance_universe_master(universe_master_id),
        CONSTRAINT ck_pm_oa_uni_master_group CHECK (master_group IN
            (N'CATEGORY', N'SUBCATEGORY', N'CLASSIFICATION', N'REG_SIGNIFICANCE', N'CRITICALITY', N'STATUS', N'RELATIONSHIP')),
        CONSTRAINT uq_pm_oa_uni_master_code UNIQUE(organization_id, master_group, code)
    );
    PRINT '577.2: org_assurance_universe_master created.';
END
GO

IF OBJECT_ID('grac_practice.org_assurance_universe_subject','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_universe_subject(
        universe_subject_id  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_uni_subject PRIMARY KEY,
        organization_id      BIGINT         NOT NULL,
        ref_no               INT            NOT NULL,
        universe_ref         NVARCHAR(30)   NOT NULL,
        subject_name         NVARCHAR(300)  NOT NULL,
        description          NVARCHAR(MAX)  NULL,
        category_id          BIGINT         NULL,
        subcategory_id       BIGINT         NULL,
        classification_id    BIGINT         NULL,
        reg_significance_id  BIGINT         NULL,
        criticality_id       BIGINT         NULL,
        parent_subject_id    BIGINT         NULL,
        subject_source       NVARCHAR(20)   NOT NULL,
        owner_employee_id    BIGINT         NULL,
        division_id          BIGINT         NULL,
        department_id        BIGINT         NULL,
        status_code          NVARCHAR(30)   NOT NULL CONSTRAINT df_pm_oa_uni_subject_status DEFAULT N'DISCOVERED',
        effective_from       DATE           NULL,
        last_reviewed_on     DATE           NULL,
        remarks              NVARCHAR(2000) NULL,
        submitted_employee_id BIGINT        NULL,
        submitted_by         NVARCHAR(240)  NULL,
        submitted_dt         DATETIME2      NULL,
        approved_employee_id BIGINT         NULL,
        approved_by          NVARCHAR(240)  NULL,
        approved_dt          DATETIME2      NULL,
        version_no           INT            NOT NULL CONSTRAINT df_pm_oa_uni_subject_ver DEFAULT 1,
        entered_by           NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_oa_uni_subject_by DEFAULT 'system',
        entered_dt           DATETIME2      NOT NULL CONSTRAINT df_pm_oa_uni_subject_dt DEFAULT SYSUTCDATETIME(),
        updated_by           NVARCHAR(100)  NULL,
        updated_dt           DATETIME2      NULL,
        CONSTRAINT fk_pm_oa_uni_subject_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
        CONSTRAINT fk_pm_oa_uni_subject_cat FOREIGN KEY(category_id) REFERENCES grac_practice.org_assurance_universe_master(universe_master_id),
        CONSTRAINT fk_pm_oa_uni_subject_subcat FOREIGN KEY(subcategory_id) REFERENCES grac_practice.org_assurance_universe_master(universe_master_id),
        CONSTRAINT fk_pm_oa_uni_subject_class FOREIGN KEY(classification_id) REFERENCES grac_practice.org_assurance_universe_master(universe_master_id),
        CONSTRAINT fk_pm_oa_uni_subject_reg FOREIGN KEY(reg_significance_id) REFERENCES grac_practice.org_assurance_universe_master(universe_master_id),
        CONSTRAINT fk_pm_oa_uni_subject_crit FOREIGN KEY(criticality_id) REFERENCES grac_practice.org_assurance_universe_master(universe_master_id),
        CONSTRAINT fk_pm_oa_uni_subject_parent FOREIGN KEY(parent_subject_id) REFERENCES grac_practice.org_assurance_universe_subject(universe_subject_id),
        CONSTRAINT fk_pm_oa_uni_subject_owner FOREIGN KEY(owner_employee_id) REFERENCES grac_practice.organization_employee(employee_id),
        CONSTRAINT fk_pm_oa_uni_subject_div FOREIGN KEY(division_id) REFERENCES grac_practice.organization_division(division_id),
        CONSTRAINT fk_pm_oa_uni_subject_dept FOREIGN KEY(department_id) REFERENCES grac_practice.organization_department(department_id),
        CONSTRAINT ck_pm_oa_uni_subject_source CHECK (subject_source IN (N'REGISTRY', N'MANUAL', N'OTHER')),
        CONSTRAINT ck_pm_oa_uni_subject_status CHECK (status_code IN
            (N'DISCOVERED', N'UNDER_VALIDATION', N'ACTIVE', N'INACTIVE', N'RETIRED')),
        CONSTRAINT uq_pm_oa_uni_subject_ref UNIQUE(organization_id, ref_no)
    );
    CREATE INDEX ix_pm_oa_uni_subject_org ON grac_practice.org_assurance_universe_subject(organization_id, status_code);
    PRINT '577.2: org_assurance_universe_subject created.';
END
GO

IF OBJECT_ID('grac_practice.org_assurance_universe_source','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_universe_source(
        universe_source_id  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_uni_source PRIMARY KEY,
        universe_subject_id BIGINT        NOT NULL,
        source_kind         NVARCHAR(30)  NOT NULL,
        source_record_id    BIGINT        NOT NULL,
        is_primary          BIT           NOT NULL CONSTRAINT df_pm_oa_uni_source_primary DEFAULT 0,
        is_active           BIT           NOT NULL CONSTRAINT df_pm_oa_uni_source_active DEFAULT 1,
        entered_by          NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_uni_source_by DEFAULT 'system',
        entered_dt          DATETIME2     NOT NULL CONSTRAINT df_pm_oa_uni_source_dt DEFAULT SYSUTCDATETIME(),
        updated_by          NVARCHAR(100) NULL,
        updated_dt          DATETIME2     NULL,
        CONSTRAINT fk_pm_oa_uni_source_subject FOREIGN KEY(universe_subject_id)
            REFERENCES grac_practice.org_assurance_universe_subject(universe_subject_id),
        CONSTRAINT ck_pm_oa_uni_source_kind CHECK (source_kind IN
            (N'LEGAL_ENTITY', N'UNIT', N'LOCATION', N'DEPARTMENT', N'FUNCTION', N'PROCESS')),
        CONSTRAINT uq_pm_oa_uni_source UNIQUE(universe_subject_id, source_kind, source_record_id)
    );
    CREATE INDEX ix_pm_oa_uni_source_record ON grac_practice.org_assurance_universe_source(source_kind, source_record_id);
    PRINT '577.2: org_assurance_universe_source created.';
END
GO

IF OBJECT_ID('grac_practice.org_assurance_universe_exclusion','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_universe_exclusion(
        universe_exclusion_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_uni_excl PRIMARY KEY,
        organization_id       BIGINT         NOT NULL,
        source_kind           NVARCHAR(30)   NOT NULL,
        source_record_id      BIGINT         NOT NULL,
        reason                NVARCHAR(2000) NOT NULL,
        excluded_by           NVARCHAR(240)  NOT NULL,
        excluded_dt           DATETIME2      NOT NULL CONSTRAINT df_pm_oa_uni_excl_dt DEFAULT SYSUTCDATETIME(),
        is_active             BIT            NOT NULL CONSTRAINT df_pm_oa_uni_excl_active DEFAULT 1,
        released_by           NVARCHAR(240)  NULL,
        released_dt           DATETIME2      NULL,
        CONSTRAINT fk_pm_oa_uni_excl_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
        CONSTRAINT ck_pm_oa_uni_excl_kind CHECK (source_kind IN
            (N'LEGAL_ENTITY', N'UNIT', N'LOCATION', N'DEPARTMENT', N'FUNCTION', N'PROCESS'))
    );
    CREATE UNIQUE INDEX ux_pm_oa_uni_excl_active ON grac_practice.org_assurance_universe_exclusion(organization_id, source_kind, source_record_id)
        WHERE is_active = 1;
    PRINT '577.2: org_assurance_universe_exclusion created.';
END
GO

IF OBJECT_ID('grac_practice.org_assurance_universe_relationship','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_universe_relationship(
        universe_relationship_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_uni_rel PRIMARY KEY,
        organization_id          BIGINT         NOT NULL,
        from_subject_id          BIGINT         NOT NULL,
        to_subject_id            BIGINT         NOT NULL,
        relationship_type_id     BIGINT         NOT NULL,
        remarks                  NVARCHAR(1000) NULL,
        is_active                BIT            NOT NULL CONSTRAINT df_pm_oa_uni_rel_active DEFAULT 1,
        entered_by               NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_oa_uni_rel_by DEFAULT 'system',
        entered_dt               DATETIME2      NOT NULL CONSTRAINT df_pm_oa_uni_rel_dt DEFAULT SYSUTCDATETIME(),
        updated_by               NVARCHAR(100)  NULL,
        updated_dt               DATETIME2      NULL,
        CONSTRAINT fk_pm_oa_uni_rel_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
        CONSTRAINT fk_pm_oa_uni_rel_from FOREIGN KEY(from_subject_id) REFERENCES grac_practice.org_assurance_universe_subject(universe_subject_id),
        CONSTRAINT fk_pm_oa_uni_rel_to FOREIGN KEY(to_subject_id) REFERENCES grac_practice.org_assurance_universe_subject(universe_subject_id),
        CONSTRAINT fk_pm_oa_uni_rel_type FOREIGN KEY(relationship_type_id) REFERENCES grac_practice.org_assurance_universe_master(universe_master_id),
        CONSTRAINT ck_pm_oa_uni_rel_self CHECK (from_subject_id <> to_subject_id)
    );
    CREATE UNIQUE INDEX ux_pm_oa_uni_rel_active ON grac_practice.org_assurance_universe_relationship(from_subject_id, to_subject_id, relationship_type_id)
        WHERE is_active = 1;
    PRINT '577.2: org_assurance_universe_relationship created.';
END
GO

IF OBJECT_ID('grac_practice.org_assurance_universe_history','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_universe_history(
        universe_history_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_uni_hist PRIMARY KEY,
        organization_id     BIGINT         NOT NULL,
        universe_subject_id BIGINT         NULL,
        source_kind         NVARCHAR(30)   NULL,
        source_record_id    BIGINT         NULL,
        action_code         NVARCHAR(30)   NOT NULL,
        from_status         NVARCHAR(30)   NULL,
        to_status           NVARCHAR(30)   NULL,
        comment             NVARCHAR(MAX)  NULL,
        changes_json        NVARCHAR(MAX)  NULL,
        employee_id         BIGINT         NULL,
        actor_name          NVARCHAR(240)  NOT NULL,
        action_dt           DATETIME2      NOT NULL CONSTRAINT df_pm_oa_uni_hist_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT fk_pm_oa_uni_hist_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
        CONSTRAINT fk_pm_oa_uni_hist_subject FOREIGN KEY(universe_subject_id)
            REFERENCES grac_practice.org_assurance_universe_subject(universe_subject_id)
    );
    CREATE INDEX ix_pm_oa_uni_hist_subject ON grac_practice.org_assurance_universe_history(organization_id, universe_subject_id, action_dt);
    PRINT '577.2: org_assurance_universe_history created.';
END
GO

-- =====================================================================
-- 3. The Organization Registry records that can become subjects
--    (CR2 3.3). Kind -> registry table:
--      LEGAL_ENTITY organization (the Legal Entity itself)
--      UNIT         organization_division        (Organization Units)
--      LOCATION     organization_location        (Locations / Branches / Regions)
--      DEPARTMENT   organization_department
--      FUNCTION     organization_business_function
--      PROCESS      organization_dependency_process (Business Processes)
--    owner = the record's head / owner; division / department = its
--    organizational ownership, where the registry has one.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_org_assurance_universe_registry_records(@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT CAST(N'LEGAL_ENTITY' AS NVARCHAR(30)) AS source_kind, o.organization_id AS record_id,
           CAST(o.organization_code AS NVARCHAR(100)) AS record_code, CAST(o.organization_name AS NVARCHAR(300)) AS record_name,
           CAST(o.entity_type AS NVARCHAR(200)) AS type_label, CAST(o.status AS NVARCHAR(60)) AS record_status,
           o.entity_owner_employee_id AS owner_employee_id, CAST(NULL AS BIGINT) AS division_id, CAST(NULL AS BIGINT) AS department_id
      FROM grac_practice.organization o
     WHERE o.organization_id = @organization_id
    UNION ALL
    SELECT N'UNIT', d.division_id, d.division_code, d.division_name, d.unit_type, d.status,
           d.head_employee_id, d.division_id, NULL
      FROM grac_practice.organization_division d
     WHERE d.organization_id = @organization_id
    UNION ALL
    SELECT N'LOCATION', l.location_id, l.location_code, l.location_name, t.location_type_name, l.status,
           l.location_head_id, l.division_id, NULL
      FROM grac_practice.organization_location l
      LEFT JOIN grac_practice.location_type_master t ON t.location_type_id = l.location_type_id
     WHERE l.organization_id = @organization_id
    UNION ALL
    SELECT N'DEPARTMENT', p.department_id, p.department_code, p.department_name, p.department_type, p.status,
           p.head_employee_id, p.primary_division_id, p.department_id
      FROM grac_practice.organization_department p
     WHERE p.organization_id = @organization_id
    UNION ALL
    SELECT N'FUNCTION', f.business_function_id, f.function_code, f.function_name, f.function_category, f.status,
           f.owner_employee_id, NULL, f.accountable_department_id
      FROM grac_practice.organization_business_function f
     WHERE f.organization_id = @organization_id
    UNION ALL
    SELECT N'PROCESS', r.process_id, r.process_code, r.process_name, r.process_level, r.status,
           r.process_owner_id, r.primary_division_id, r.owning_department_id
      FROM grac_practice.organization_dependency_process r
     WHERE r.organization_id = @organization_id;
GO

-- The label of a source kind (lists, history).
CREATE OR ALTER FUNCTION grac_practice.fn_org_assurance_universe_kind_label(@kind NVARCHAR(30))
RETURNS NVARCHAR(60)
AS
BEGIN
    RETURN CASE @kind WHEN N'LEGAL_ENTITY' THEN N'Legal Entity' WHEN N'UNIT' THEN N'Organization Unit'
                      WHEN N'LOCATION' THEN N'Location / Branch' WHEN N'DEPARTMENT' THEN N'Department'
                      WHEN N'FUNCTION' THEN N'Business Function' WHEN N'PROCESS' THEN N'Business Process'
                      ELSE @kind END;
END
GO

-- =====================================================================
-- 4. Procedures
-- =====================================================================

-- 4a. Default masters for an organization: a group is seeded only while
-- the organization has none of it (so a deactivated default is never
-- brought back); the five statuses always exist (their codes drive the
-- lifecycle; names and descriptions are editable).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_master_seed
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @d TABLE(grp NVARCHAR(30), code NVARCHAR(40), name NVARCHAR(200), descr NVARCHAR(1000), rnk INT NULL, ord INT, sys BIT);
    INSERT INTO @d (grp, code, name, descr, rnk, ord, sys) VALUES
        (N'CATEGORY', N'LEGAL_ENTITY',      N'Legal Entity',         N'A Legal Entity as a whole',                       NULL, 10, 0),
        (N'CATEGORY', N'BUSINESS_UNIT',     N'Business Unit',        N'An organization unit / division',                 NULL, 20, 0),
        (N'CATEGORY', N'DEPARTMENT',        N'Department',           N'A department',                                    NULL, 30, 0),
        (N'CATEGORY', N'BUSINESS_FUNCTION', N'Business Function',    N'A business function',                             NULL, 40, 0),
        (N'CATEGORY', N'BUSINESS_PROCESS',  N'Business Process',     N'A business process or sub-process',               NULL, 50, 0),
        (N'CATEGORY', N'REGION',            N'Region',               N'A region containing branches / locations',        NULL, 60, 0),
        (N'CATEGORY', N'LOCATION',          N'Branch / Location',    N'A branch, office or other location',              NULL, 70, 0),
        (N'CATEGORY', N'TECHNOLOGY',        N'Technology Function',  N'A technology function supporting the business',   NULL, 80, 0),
        (N'CATEGORY', N'REGULATORY',        N'Regulatory Activity',  N'A regulatory activity spanning units',            NULL, 90, 0),
        (N'CATEGORY', N'MANAGEMENT',        N'Management-defined',   N'A subject defined by management',                 NULL, 100, 0),
        (N'REG_SIGNIFICANCE', N'HIGH',      N'High',                 N'Directly governed; significant regulatory exposure', 3, 10, 0),
        (N'REG_SIGNIFICANCE', N'MEDIUM',    N'Medium',               N'Some regulatory exposure',                        2, 20, 0),
        (N'REG_SIGNIFICANCE', N'LOW',       N'Low',                  N'Little regulatory exposure',                      1, 30, 0),
        (N'REG_SIGNIFICANCE', N'NA',        N'Not Applicable',       N'No regulatory significance',                      0, 40, 0),
        (N'CRITICALITY', N'CRITICAL',       N'Critical',             NULL, 4, 10, 0),
        (N'CRITICALITY', N'HIGH',           N'High',                 NULL, 3, 20, 0),
        (N'CRITICALITY', N'MEDIUM',         N'Medium',               NULL, 2, 30, 0),
        (N'CRITICALITY', N'LOW',            N'Low',                  NULL, 1, 40, 0),
        (N'STATUS', N'DISCOVERED',          N'Discovered',           N'Found or created; not yet submitted for validation', NULL, 10, 1),
        (N'STATUS', N'UNDER_VALIDATION',    N'Under Validation',     N'Waiting for the Head of Internal Audit',          NULL, 20, 1),
        (N'STATUS', N'ACTIVE',              N'Active',               N'In the approved Audit Universe',                  NULL, 30, 1),
        (N'STATUS', N'INACTIVE',            N'Inactive',             N'Taken out of the approved Audit Universe',        NULL, 40, 1),
        (N'STATUS', N'RETIRED',             N'Retired',              N'No longer auditable; kept for history',           NULL, 50, 1),
        (N'RELATIONSHIP', N'CONTAINS',        N'Contains',           N'e.g. a region contains branches',                 NULL, 10, 0),
        (N'RELATIONSHIP', N'OPERATES_ACROSS', N'Operates across',    N'e.g. a process operates across departments',      NULL, 20, 0),
        (N'RELATIONSHIP', N'SUPPORTS',        N'Supports',           N'e.g. a technology function supports processes',   NULL, 30, 0),
        (N'RELATIONSHIP', N'SPANS',           N'Spans',              N'e.g. a regulatory activity spans units',          NULL, 40, 0),
        (N'RELATIONSHIP', N'DEPENDS_ON',      N'Depends on',         NULL,                                               NULL, 50, 0);

    INSERT INTO grac_practice.org_assurance_universe_master
        (organization_id, master_group, code, name, description, rank_value, display_order, is_system, entered_by)
    SELECT @organization_id, d.grp, d.code, d.name, d.descr, d.rnk, d.ord, d.sys, @actor
      FROM @d d
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_master m
                        WHERE m.organization_id = @organization_id AND m.master_group = d.grp AND m.code = d.code)
       AND (d.grp = N'STATUS'
            OR NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_master m
                            WHERE m.organization_id = @organization_id AND m.master_group = d.grp));
END
GO

-- 4b. The masters (Universe Configuration); @group NULL = every group.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_master_list
    @organization_id BIGINT,
    @master_group    NVARCHAR(30)  = NULL,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 54096, 'organization_id is required.', 1;
    EXEC grac_practice.sp_org_assurance_universe_master_seed @organization_id = @organization_id, @actor = @actor;
    SELECT m.universe_master_id AS MasterId, m.master_group AS MasterGroup, m.code AS Code, m.name AS Name,
           m.description AS Description, m.parent_master_id AS ParentMasterId, p.name AS ParentName,
           m.rank_value AS RankValue, m.display_order AS DisplayOrder, m.is_system AS IsSystem, m.is_active AS IsActive,
           (SELECT COUNT(*) FROM grac_practice.org_assurance_universe_subject s
             WHERE s.organization_id = m.organization_id
               AND (s.category_id = m.universe_master_id OR s.subcategory_id = m.universe_master_id
                    OR s.classification_id = m.universe_master_id OR s.reg_significance_id = m.universe_master_id
                    OR s.criticality_id = m.universe_master_id
                    OR (m.master_group = N'STATUS' AND s.status_code = m.code)))
         + (SELECT COUNT(*) FROM grac_practice.org_assurance_universe_relationship r
             WHERE r.relationship_type_id = m.universe_master_id AND r.is_active = 1) AS UsageCount,
           ISNULL(m.updated_dt, m.entered_dt) AS ChangedDt
      FROM grac_practice.org_assurance_universe_master m
      LEFT JOIN grac_practice.org_assurance_universe_master p ON p.universe_master_id = m.parent_master_id
     WHERE m.organization_id = @organization_id
       AND (NULLIF(@master_group, N'') IS NULL OR m.master_group = @master_group)
     ORDER BY m.master_group, m.display_order, m.name;
END
GO

-- 4c. Add / change a master value. Code: required, set when the value is
-- made, not changed afterwards. STATUS: no new values; name, description
-- and order only. SUBCATEGORY needs its Category.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_master_save
    @organization_id    BIGINT,
    @universe_master_id BIGINT         = NULL,
    @master_group       NVARCHAR(30),
    @code               NVARCHAR(40),
    @name               NVARCHAR(200),
    @description        NVARCHAR(1000) = NULL,
    @parent_master_id   BIGINT         = NULL,
    @rank_value         INT            = NULL,
    @display_order      INT            = 0,
    @is_active          BIT            = 1,
    @employee_id        BIGINT         = NULL,
    @actor              NVARCHAR(100)  = 'system',
    @universe_master_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @master_group = UPPER(LTRIM(RTRIM(@master_group)));
    SET @code         = UPPER(REPLACE(LTRIM(RTRIM(@code)), N' ', N'_'));
    SET @name         = NULLIF(LTRIM(RTRIM(@name)), N'');
    SET @description  = NULLIF(LTRIM(RTRIM(@description)), N'');
    IF @organization_id IS NULL THROW 54096, 'organization_id is required.', 1;
    IF @master_group NOT IN (N'CATEGORY', N'SUBCATEGORY', N'CLASSIFICATION', N'REG_SIGNIFICANCE', N'CRITICALITY', N'STATUS', N'RELATIONSHIP')
        THROW 54099, 'Unknown master.', 1;
    IF NULLIF(@code, N'') IS NULL OR @name IS NULL THROW 54095, 'Code and Name are required.', 1;

    DECLARE @old_group NVARCHAR(30), @old_code NVARCHAR(40), @old_name NVARCHAR(200), @old_active BIT, @sys BIT;
    IF @universe_master_id IS NOT NULL
    BEGIN
        SELECT @old_group = master_group, @old_code = code, @old_name = name, @old_active = is_active, @sys = is_system
          FROM grac_practice.org_assurance_universe_master
         WHERE universe_master_id = @universe_master_id AND organization_id = @organization_id;
        IF @old_group IS NULL THROW 54090, 'The master value was not found in this organization.', 1;
        IF @old_group <> @master_group OR @old_code <> @code
            THROW 54099, 'A master value''s group and code cannot be changed.', 1;
        IF @sys = 1 AND @is_active = 0
            THROW 54099, 'A status cannot be deactivated; the lifecycle uses it.', 1;
    END
    ELSE
    BEGIN
        IF @master_group = N'STATUS' THROW 54099, 'Statuses are fixed by the lifecycle; only their names can be changed.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_master
                    WHERE organization_id = @organization_id AND master_group = @master_group AND code = @code)
            THROW 54097, 'That code is already used in this master.', 1;
    END

    IF @master_group = N'SUBCATEGORY'
    BEGIN
        IF @parent_master_id IS NULL THROW 54095, 'A subcategory needs its Category.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_master
                        WHERE universe_master_id = @parent_master_id AND organization_id = @organization_id
                          AND master_group = N'CATEGORY')
            THROW 54096, 'The Category was not found.', 1;
    END
    ELSE SET @parent_master_id = NULL;
    IF @master_group NOT IN (N'REG_SIGNIFICANCE', N'CRITICALITY') SET @rank_value = NULL;

    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    BEGIN TRAN;
    IF @universe_master_id IS NULL
    BEGIN
        INSERT INTO grac_practice.org_assurance_universe_master
            (organization_id, master_group, code, name, description, parent_master_id, rank_value, display_order, is_active, entered_by)
        VALUES (@organization_id, @master_group, @code, @name, @description, @parent_master_id, @rank_value,
                ISNULL(@display_order, 0), ISNULL(@is_active, 1), @actor);
        SET @universe_master_id = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE grac_practice.org_assurance_universe_master
           SET name = @name, description = @description, parent_master_id = @parent_master_id, rank_value = @rank_value,
               display_order = ISNULL(@display_order, 0), is_active = ISNULL(@is_active, 1),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE universe_master_id = @universe_master_id;

    DECLARE @mchanges NVARCHAR(MAX) = (SELECT @master_group AS MasterGroup, @code AS Code,
                                              @old_name AS OldName, @name AS Name,
                                              @old_active AS WasActive, ISNULL(@is_active, 1) AS IsActive
                                          FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES);
    INSERT INTO grac_practice.org_assurance_universe_history
        (organization_id, action_code, comment, changes_json, employee_id, actor_name)
    VALUES (@organization_id, N'MASTER',
            CASE WHEN @old_group IS NULL THEN N'Added ' ELSE N'Changed ' END + @master_group + N' ' + @code,
            @mchanges, @employee_id, @me);
    COMMIT;
    SET @universe_master_id_out = @universe_master_id;
END
GO

-- 4d. Discovery (CR2 3.3): the registry records of the organization, with
-- whether they are already in the Universe or excluded.
--   @show: NEW (not in the Universe, not excluded; default) / INCLUDED /
--          EXCLUDED / ALL.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_discover
    @organization_id BIGINT,
    @source_kind     NVARCHAR(30)  = NULL,
    @show            NVARCHAR(20)  = N'NEW',
    @search          NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 54096, 'organization_id is required.', 1;
    SET @show = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@show)), N''), N'NEW'));
    WITH r AS (
        SELECT x.source_kind, x.record_id, x.record_code, x.record_name, x.type_label, x.record_status, x.owner_employee_id,
               (SELECT COUNT(*) FROM grac_practice.org_assurance_universe_source s
                  JOIN grac_practice.org_assurance_universe_subject u ON u.universe_subject_id = s.universe_subject_id
                 WHERE s.source_kind = x.source_kind AND s.source_record_id = x.record_id AND s.is_active = 1
                   AND u.organization_id = @organization_id AND u.status_code <> N'RETIRED') AS subject_count,
               ex.universe_exclusion_id, ex.reason AS exclusion_reason, ex.excluded_by, ex.excluded_dt
          FROM grac_practice.fn_org_assurance_universe_registry_records(@organization_id) x
          LEFT JOIN grac_practice.org_assurance_universe_exclusion ex
                 ON ex.organization_id = @organization_id AND ex.source_kind = x.source_kind
                AND ex.source_record_id = x.record_id AND ex.is_active = 1
         WHERE (NULLIF(@source_kind, N'') IS NULL OR x.source_kind = @source_kind)
           AND (NULLIF(@search, N'') IS NULL OR x.record_code LIKE N'%' + @search + N'%' OR x.record_name LIKE N'%' + @search + N'%')
    )
    SELECT r.source_kind AS SourceKind, grac_practice.fn_org_assurance_universe_kind_label(r.source_kind) AS KindLabel,
           r.record_id AS RecordId, r.record_code AS RecordCode, r.record_name AS RecordName, r.type_label AS TypeLabel,
           r.record_status AS RecordStatus, e.employee_name AS OwnerName, r.subject_count AS SubjectCount,
           STUFF((SELECT N', ' + u.universe_ref
                    FROM grac_practice.org_assurance_universe_source s
                    JOIN grac_practice.org_assurance_universe_subject u ON u.universe_subject_id = s.universe_subject_id
                   WHERE s.source_kind = r.source_kind AND s.source_record_id = r.record_id AND s.is_active = 1
                     AND u.organization_id = @organization_id AND u.status_code <> N'RETIRED'
                   ORDER BY u.ref_no FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS SubjectRefs,
           CAST(CASE WHEN r.universe_exclusion_id IS NULL THEN 0 ELSE 1 END AS BIT) AS IsExcluded,
           r.exclusion_reason AS ExclusionReason, r.excluded_by AS ExcludedBy, r.excluded_dt AS ExcludedDt
      FROM r
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = r.owner_employee_id
     WHERE (@show = N'ALL')
        OR (@show = N'NEW'      AND r.subject_count = 0 AND r.universe_exclusion_id IS NULL)
        OR (@show = N'INCLUDED' AND r.subject_count > 0)
        OR (@show = N'EXCLUDED' AND r.universe_exclusion_id IS NOT NULL)
     ORDER BY CASE r.source_kind WHEN N'LEGAL_ENTITY' THEN 1 WHEN N'UNIT' THEN 2 WHEN N'LOCATION' THEN 3
                                 WHEN N'DEPARTMENT' THEN 4 WHEN N'FUNCTION' THEN 5 ELSE 6 END,
              r.record_code, r.record_name;
END
GO

-- 4e. Act on discovered records: [{ kind, id }]
--   INCLUDE  -> one Discovered subject per record (source Organization
--               Registry; name, owner, unit and department from the record;
--               Category = @category_id, else the kind's default category).
--               Records already in the Universe or excluded are skipped.
--   EXCLUDE  -> excluded as not independently auditable (reason required).
--   RELEASE  -> the exclusion is lifted.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_discover_apply
    @organization_id BIGINT,
    @action          NVARCHAR(20),
    @records_json    NVARCHAR(MAX),
    @reason          NVARCHAR(2000) = NULL,
    @category_id     BIGINT         = NULL,
    @employee_id     BIGINT         = NULL,
    @actor           NVARCHAR(100)  = 'system',
    @applied_count   INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @action = UPPER(LTRIM(RTRIM(@action)));
    SET @reason = NULLIF(LTRIM(RTRIM(@reason)), N'');
    SET @applied_count = 0;
    IF @organization_id IS NULL THROW 54096, 'organization_id is required.', 1;
    IF @action NOT IN (N'INCLUDE', N'EXCLUDE', N'RELEASE') THROW 54091, 'Unknown discovery action.', 1;
    IF @action = N'EXCLUDE' AND @reason IS NULL THROW 54094, 'Give the reason the records are not independently auditable.', 1;
    IF ISJSON(ISNULL(@records_json, N'')) = 0 THROW 54096, 'Select at least one record.', 1;

    EXEC grac_practice.sp_org_assurance_universe_master_seed @organization_id = @organization_id, @actor = @actor;
    IF @category_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_master
                        WHERE universe_master_id = @category_id AND organization_id = @organization_id
                          AND master_group = N'CATEGORY' AND is_active = 1)
        THROW 54096, 'The Category was not found or is inactive.', 1;

    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    DECLARE @recs TABLE(seq INT IDENTITY(1,1), kind NVARCHAR(30), record_id BIGINT, record_code NVARCHAR(100), record_name NVARCHAR(300),
                        owner_employee_id BIGINT NULL, division_id BIGINT NULL, department_id BIGINT NULL);
    INSERT INTO @recs (kind, record_id, record_code, record_name, owner_employee_id, division_id, department_id)
    SELECT DISTINCT x.source_kind, x.record_id, x.record_code, x.record_name, x.owner_employee_id, x.division_id, x.department_id
      FROM OPENJSON(@records_json) WITH (kind NVARCHAR(30) '$.kind', id BIGINT '$.id') j
      JOIN grac_practice.fn_org_assurance_universe_registry_records(@organization_id) x
           ON x.source_kind = UPPER(j.kind) AND x.record_id = j.id;
    IF NOT EXISTS (SELECT 1 FROM @recs) THROW 54096, 'None of the selected records was found in this organization''s registry.', 1;

    BEGIN TRAN;
    IF @action = N'EXCLUDE'
    BEGIN
        INSERT INTO grac_practice.org_assurance_universe_exclusion (organization_id, source_kind, source_record_id, reason, excluded_by)
        SELECT @organization_id, r.kind, r.record_id, @reason, @me
          FROM @recs r
         WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_exclusion ex
                            WHERE ex.organization_id = @organization_id AND ex.source_kind = r.kind
                              AND ex.source_record_id = r.record_id AND ex.is_active = 1);
        SET @applied_count = @@ROWCOUNT;
        INSERT INTO grac_practice.org_assurance_universe_history
            (organization_id, source_kind, source_record_id, action_code, comment, employee_id, actor_name)
        SELECT @organization_id, r.kind, r.record_id, N'EXCLUDE',
               grac_practice.fn_org_assurance_universe_kind_label(r.kind) + N' ' + ISNULL(r.record_code + N' - ', N'') + r.record_name
                 + N': ' + @reason, @employee_id, @me
          FROM @recs r;
    END
    ELSE IF @action = N'RELEASE'
    BEGIN
        UPDATE ex SET is_active = 0, released_by = @me, released_dt = SYSUTCDATETIME()
          FROM grac_practice.org_assurance_universe_exclusion ex
          JOIN @recs r ON r.kind = ex.source_kind AND r.record_id = ex.source_record_id
         WHERE ex.organization_id = @organization_id AND ex.is_active = 1;
        SET @applied_count = @@ROWCOUNT;
        INSERT INTO grac_practice.org_assurance_universe_history
            (organization_id, source_kind, source_record_id, action_code, comment, employee_id, actor_name)
        SELECT @organization_id, r.kind, r.record_id, N'RELEASE',
               grac_practice.fn_org_assurance_universe_kind_label(r.kind) + N' ' + ISNULL(r.record_code + N' - ', N'') + r.record_name
                 + ISNULL(N': ' + @reason, N''), @employee_id, @me
          FROM @recs r;
    END
    ELSE
    BEGIN
        DECLARE @seq INT = 1, @max INT = (SELECT MAX(seq) FROM @recs);
        DECLARE @kind NVARCHAR(30), @rid BIGINT, @rcode NVARCHAR(100), @rname NVARCHAR(300), @owner BIGINT, @div BIGINT, @dept BIGINT,
                @cat BIGINT, @ref INT, @sid BIGINT;
        WHILE @seq <= @max
        BEGIN
            SELECT @kind = kind, @rid = record_id, @rcode = record_code, @rname = record_name,
                   @owner = owner_employee_id, @div = division_id, @dept = department_id
              FROM @recs WHERE seq = @seq;
            IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_source s
                             JOIN grac_practice.org_assurance_universe_subject u ON u.universe_subject_id = s.universe_subject_id
                            WHERE s.source_kind = @kind AND s.source_record_id = @rid AND s.is_active = 1
                              AND u.organization_id = @organization_id AND u.status_code <> N'RETIRED')
               AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_exclusion ex
                                WHERE ex.organization_id = @organization_id AND ex.source_kind = @kind
                                  AND ex.source_record_id = @rid AND ex.is_active = 1)
            BEGIN
                SET @cat = ISNULL(@category_id,
                           (SELECT universe_master_id FROM grac_practice.org_assurance_universe_master
                             WHERE organization_id = @organization_id AND master_group = N'CATEGORY' AND is_active = 1
                               AND code = CASE @kind WHEN N'LEGAL_ENTITY' THEN N'LEGAL_ENTITY' WHEN N'UNIT' THEN N'BUSINESS_UNIT'
                                                     WHEN N'LOCATION' THEN N'LOCATION' WHEN N'DEPARTMENT' THEN N'DEPARTMENT'
                                                     WHEN N'FUNCTION' THEN N'BUSINESS_FUNCTION' ELSE N'BUSINESS_PROCESS' END));
                SET @ref = ISNULL((SELECT MAX(ref_no) FROM grac_practice.org_assurance_universe_subject WITH (UPDLOCK, HOLDLOCK)
                                    WHERE organization_id = @organization_id), 0) + 1;
                INSERT INTO grac_practice.org_assurance_universe_subject
                    (organization_id, ref_no, universe_ref, subject_name, category_id, subject_source, owner_employee_id,
                     division_id, department_id, status_code, entered_by)
                VALUES (@organization_id, @ref, N'AU-' + RIGHT(N'00000' + CAST(@ref AS NVARCHAR(10)), 5), @rname, @cat, N'REGISTRY',
                        @owner, @div, @dept, N'DISCOVERED', @actor);
                SET @sid = SCOPE_IDENTITY();
                INSERT INTO grac_practice.org_assurance_universe_source (universe_subject_id, source_kind, source_record_id, is_primary, entered_by)
                VALUES (@sid, @kind, @rid, 1, @actor);
                INSERT INTO grac_practice.org_assurance_universe_history
                    (organization_id, universe_subject_id, source_kind, source_record_id, action_code, to_status, comment, employee_id, actor_name)
                VALUES (@organization_id, @sid, @kind, @rid, N'DISCOVER', N'DISCOVERED',
                        N'Included from the Organization Registry: ' + grac_practice.fn_org_assurance_universe_kind_label(@kind)
                          + N' ' + ISNULL(@rcode + N' - ', N'') + @rname, @employee_id, @me);
                SET @applied_count = @applied_count + 1;
            END
            SET @seq = @seq + 1;
        END
    END
    COMMIT;
END
GO

-- 4f. Lookups for the subject form: people, units, departments, subjects
-- (parent / relationships).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_lookups
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 54096, 'organization_id is required.', 1;
    SELECT employee_id AS Id, employee_code AS Code, employee_name AS Name, designation AS Designation
      FROM grac_practice.organization_employee
     WHERE organization_id = @organization_id AND status = N'Active'
     ORDER BY employee_name;
    SELECT division_id AS Id, division_code AS Code, division_name AS Name, status AS Status
      FROM grac_practice.organization_division
     WHERE organization_id = @organization_id
     ORDER BY division_code, division_name;
    SELECT department_id AS Id, department_code AS Code, department_name AS Name, status AS Status
      FROM grac_practice.organization_department
     WHERE organization_id = @organization_id
     ORDER BY department_code, department_name;
    SELECT universe_subject_id AS Id, universe_ref AS Code, subject_name AS Name, status_code AS StatusCode,
           parent_subject_id AS ParentSubjectId
      FROM grac_practice.org_assurance_universe_subject
     WHERE organization_id = @organization_id
     ORDER BY ref_no;
END
GO

-- 4g. The Audit Universe Register (CR2 3.4). Every matching subject; the
-- page builds the hierarchy from ParentSubjectId. IsApprover = the caller
-- holds HEAD_INTERNAL_AUDIT.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_list
    @organization_id BIGINT,
    @category_id     BIGINT        = NULL,
    @status_code     NVARCHAR(30)  = NULL,
    @subject_source  NVARCHAR(20)  = NULL,
    @criticality_id  BIGINT        = NULL,
    @owner_employee_id BIGINT      = NULL,
    @department_id   BIGINT        = NULL,
    @search          NVARCHAR(200) = NULL,
    @employee_id     BIGINT        = NULL,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 54096, 'organization_id is required.', 1;
    EXEC grac_practice.sp_org_assurance_universe_master_seed @organization_id = @organization_id, @actor = @actor;
    DECLARE @hia BIT = CASE WHEN @employee_id IS NOT NULL AND EXISTS
                            (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'HEAD_INTERNAL_AUDIT') h
                              WHERE h.employee_id = @employee_id) THEN 1 ELSE 0 END;
    SELECT s.universe_subject_id AS UniverseSubjectId, s.universe_ref AS UniverseRef, s.subject_name AS SubjectName,
           s.description AS Description, s.parent_subject_id AS ParentSubjectId, ps.universe_ref AS ParentRef,
           ps.subject_name AS ParentName, s.category_id AS CategoryId, c.name AS CategoryName,
           s.subcategory_id AS SubcategoryId, sc.name AS SubcategoryName, cl.name AS ClassificationName,
           rg.name AS RegSignificanceName, cr.name AS CriticalityName, s.subject_source AS SubjectSource,
           s.owner_employee_id AS OwnerEmployeeId, ow.employee_name AS OwnerName,
           dv.division_code AS DivisionCode, dv.division_name AS DivisionName,
           dp.department_code AS DepartmentCode, dp.department_name AS DepartmentName,
           s.status_code AS StatusCode, st.name AS StatusName, s.effective_from AS EffectiveFrom,
           s.last_reviewed_on AS LastReviewedOn, s.approved_by AS ApprovedBy, s.approved_dt AS ApprovedDt,
           s.submitted_by AS SubmittedBy, s.version_no AS VersionNo,
           (SELECT COUNT(*) FROM grac_practice.org_assurance_universe_source x
             WHERE x.universe_subject_id = s.universe_subject_id AND x.is_active = 1) AS SourceCount,
           (SELECT COUNT(*) FROM grac_practice.org_assurance_universe_relationship x
             WHERE x.is_active = 1 AND (x.from_subject_id = s.universe_subject_id OR x.to_subject_id = s.universe_subject_id)) AS RelationshipCount,
           (SELECT COUNT(*) FROM grac_practice.org_assurance_universe_subject x
             WHERE x.parent_subject_id = s.universe_subject_id AND x.status_code <> N'RETIRED') AS ChildCount,
           @hia AS IsApprover,
           CAST(CASE WHEN @employee_id IS NOT NULL AND s.submitted_employee_id = @employee_id THEN 1 ELSE 0 END AS BIT) AS IsMySubmission
      FROM grac_practice.org_assurance_universe_subject s
      LEFT JOIN grac_practice.org_assurance_universe_subject ps ON ps.universe_subject_id = s.parent_subject_id
      LEFT JOIN grac_practice.org_assurance_universe_master c  ON c.universe_master_id = s.category_id
      LEFT JOIN grac_practice.org_assurance_universe_master sc ON sc.universe_master_id = s.subcategory_id
      LEFT JOIN grac_practice.org_assurance_universe_master cl ON cl.universe_master_id = s.classification_id
      LEFT JOIN grac_practice.org_assurance_universe_master rg ON rg.universe_master_id = s.reg_significance_id
      LEFT JOIN grac_practice.org_assurance_universe_master cr ON cr.universe_master_id = s.criticality_id
      LEFT JOIN grac_practice.org_assurance_universe_master st
             ON st.organization_id = s.organization_id AND st.master_group = N'STATUS' AND st.code = s.status_code
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = s.owner_employee_id
      LEFT JOIN grac_practice.organization_division dv ON dv.division_id = s.division_id
      LEFT JOIN grac_practice.organization_department dp ON dp.department_id = s.department_id
     WHERE s.organization_id = @organization_id
       AND (@category_id IS NULL OR s.category_id = @category_id)
       AND (NULLIF(@status_code, N'') IS NULL OR s.status_code = @status_code)
       AND (NULLIF(@subject_source, N'') IS NULL OR s.subject_source = @subject_source)
       AND (@criticality_id IS NULL OR s.criticality_id = @criticality_id)
       AND (@owner_employee_id IS NULL OR s.owner_employee_id = @owner_employee_id)
       AND (@department_id IS NULL OR s.department_id = @department_id)
       AND (NULLIF(@search, N'') IS NULL OR s.universe_ref LIKE N'%' + @search + N'%' OR s.subject_name LIKE N'%' + @search + N'%')
     ORDER BY s.ref_no;
END
GO

-- 4h. One subject: the subject, its registry records (shown from the
-- registry, not copied), relationships (both directions), sub-subjects and
-- history.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_get
    @organization_id     BIGINT,
    @universe_subject_id BIGINT,
    @employee_id         BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_subject
                    WHERE universe_subject_id = @universe_subject_id AND organization_id = @organization_id)
        THROW 54090, 'The subject was not found in this organization.', 1;
    DECLARE @hia BIT = CASE WHEN @employee_id IS NOT NULL AND EXISTS
                            (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'HEAD_INTERNAL_AUDIT') h
                              WHERE h.employee_id = @employee_id) THEN 1 ELSE 0 END;

    SELECT s.universe_subject_id AS UniverseSubjectId, s.universe_ref AS UniverseRef, s.subject_name AS SubjectName,
           s.description AS Description, s.category_id AS CategoryId, s.subcategory_id AS SubcategoryId,
           s.classification_id AS ClassificationId, s.reg_significance_id AS RegSignificanceId, s.criticality_id AS CriticalityId,
           s.parent_subject_id AS ParentSubjectId, s.subject_source AS SubjectSource, s.owner_employee_id AS OwnerEmployeeId,
           s.division_id AS DivisionId, s.department_id AS DepartmentId, s.status_code AS StatusCode,
           s.effective_from AS EffectiveFrom, s.last_reviewed_on AS LastReviewedOn, s.remarks AS Remarks,
           s.submitted_by AS SubmittedBy, s.submitted_dt AS SubmittedDt, s.approved_by AS ApprovedBy, s.approved_dt AS ApprovedDt,
           s.version_no AS VersionNo, s.entered_by AS EnteredBy, s.entered_dt AS EnteredDt,
           @hia AS IsApprover,
           CAST(CASE WHEN @employee_id IS NOT NULL AND s.submitted_employee_id = @employee_id THEN 1 ELSE 0 END AS BIT) AS IsMySubmission
      FROM grac_practice.org_assurance_universe_subject s
     WHERE s.universe_subject_id = @universe_subject_id;

    SELECT x.universe_source_id AS UniverseSourceId, x.source_kind AS SourceKind,
           grac_practice.fn_org_assurance_universe_kind_label(x.source_kind) AS KindLabel,
           x.source_record_id AS RecordId, r.record_code AS RecordCode, r.record_name AS RecordName, r.type_label AS TypeLabel,
           r.record_status AS RecordStatus, e.employee_name AS RecordOwnerName, x.is_primary AS IsPrimary,
           CAST(CASE WHEN r.record_id IS NULL THEN 1 ELSE 0 END AS BIT) AS IsMissing
      FROM grac_practice.org_assurance_universe_source x
      LEFT JOIN grac_practice.fn_org_assurance_universe_registry_records(@organization_id) r
             ON r.source_kind = x.source_kind AND r.record_id = x.source_record_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = r.owner_employee_id
     WHERE x.universe_subject_id = @universe_subject_id AND x.is_active = 1
     ORDER BY x.is_primary DESC, x.source_kind, r.record_code;

    SELECT r.universe_relationship_id AS UniverseRelationshipId,
           CASE WHEN r.from_subject_id = @universe_subject_id THEN N'OUT' ELSE N'IN' END AS Direction,
           r.relationship_type_id AS RelationshipTypeId, t.name AS RelationshipName,
           o.universe_subject_id AS OtherSubjectId, o.universe_ref AS OtherRef, o.subject_name AS OtherName,
           o.status_code AS OtherStatusCode, r.remarks AS Remarks, r.entered_by AS EnteredBy, r.entered_dt AS EnteredDt
      FROM grac_practice.org_assurance_universe_relationship r
      JOIN grac_practice.org_assurance_universe_master t ON t.universe_master_id = r.relationship_type_id
      JOIN grac_practice.org_assurance_universe_subject o
           ON o.universe_subject_id = CASE WHEN r.from_subject_id = @universe_subject_id THEN r.to_subject_id ELSE r.from_subject_id END
     WHERE r.is_active = 1 AND (r.from_subject_id = @universe_subject_id OR r.to_subject_id = @universe_subject_id)
     ORDER BY t.display_order, o.ref_no;

    SELECT c.universe_subject_id AS UniverseSubjectId, c.universe_ref AS UniverseRef, c.subject_name AS SubjectName,
           c.status_code AS StatusCode
      FROM grac_practice.org_assurance_universe_subject c
     WHERE c.parent_subject_id = @universe_subject_id
     ORDER BY c.ref_no;

    SELECT h.universe_history_id AS UniverseHistoryId, h.action_code AS ActionCode, h.from_status AS FromStatus,
           h.to_status AS ToStatus, h.comment AS Comment, h.changes_json AS ChangesJson, h.actor_name AS ActorName,
           h.action_dt AS ActionDt
      FROM grac_practice.org_assurance_universe_history h
     WHERE h.universe_subject_id = @universe_subject_id
     ORDER BY h.action_dt DESC, h.universe_history_id DESC;
END
GO

-- 4i. Create / change a subject. New subjects are Discovered, source
-- Manually Created (or Other). @sources_json [{ kind, id, isPrimary }]
-- replaces the registry links when given (NULL = unchanged). Editable
-- while Discovered, Active or Inactive; @version_no must be the version
-- read. A change is recorded with its before / after values.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_save
    @organization_id     BIGINT,
    @universe_subject_id BIGINT         = NULL,
    @version_no          INT            = NULL,
    @subject_name        NVARCHAR(300),
    @description         NVARCHAR(MAX)  = NULL,
    @category_id         BIGINT         = NULL,
    @subcategory_id      BIGINT         = NULL,
    @classification_id   BIGINT         = NULL,
    @reg_significance_id BIGINT         = NULL,
    @criticality_id      BIGINT         = NULL,
    @parent_subject_id   BIGINT         = NULL,
    @subject_source      NVARCHAR(20)   = NULL,
    @owner_employee_id   BIGINT         = NULL,
    @division_id         BIGINT         = NULL,
    @department_id       BIGINT         = NULL,
    @effective_from      DATE           = NULL,
    @remarks             NVARCHAR(2000) = NULL,
    @sources_json        NVARCHAR(MAX)  = NULL,
    @employee_id         BIGINT         = NULL,
    @actor               NVARCHAR(100)  = 'system',
    @universe_subject_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @subject_name = NULLIF(LTRIM(RTRIM(@subject_name)), N'');
    SET @description  = NULLIF(LTRIM(RTRIM(@description)), N'');
    SET @remarks      = NULLIF(LTRIM(RTRIM(@remarks)), N'');
    IF @organization_id IS NULL THROW 54096, 'organization_id is required.', 1;
    IF @subject_name IS NULL THROW 54095, 'Subject Name is required.', 1;
    IF @category_id IS NULL THROW 54095, 'Subject Category is required.', 1;

    DECLARE @status NVARCHAR(30), @ver INT, @src NVARCHAR(20);
    IF @universe_subject_id IS NOT NULL
    BEGIN
        SELECT @status = status_code, @ver = version_no, @src = subject_source
          FROM grac_practice.org_assurance_universe_subject
         WHERE universe_subject_id = @universe_subject_id AND organization_id = @organization_id;
        IF @status IS NULL THROW 54090, 'The subject was not found in this organization.', 1;
        IF @status NOT IN (N'DISCOVERED', N'ACTIVE', N'INACTIVE')
            THROW 54091, 'The subject cannot be changed while it is Under Validation or Retired.', 1;
        IF @version_no IS NULL OR @version_no <> @ver
            THROW 54098, 'The subject was changed by someone else. Reload it and make the change again.', 1;
    END
    ELSE SET @src = CASE WHEN UPPER(ISNULL(@subject_source, N'')) = N'OTHER' THEN N'OTHER' ELSE N'MANUAL' END;

    -- References belong to this organization (masters: right group, active
    -- unless the subject already holds the value).
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_master m
                    WHERE m.universe_master_id = @category_id AND m.organization_id = @organization_id AND m.master_group = N'CATEGORY'
                      AND (m.is_active = 1 OR EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_subject s
                                                       WHERE s.universe_subject_id = @universe_subject_id AND s.category_id = m.universe_master_id)))
        THROW 54096, 'The Subject Category was not found or is inactive.', 1;
    IF @subcategory_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_master m
                        WHERE m.universe_master_id = @subcategory_id AND m.organization_id = @organization_id
                          AND m.master_group = N'SUBCATEGORY' AND m.parent_master_id = @category_id
                          AND (m.is_active = 1 OR EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_subject s
                                                           WHERE s.universe_subject_id = @universe_subject_id AND s.subcategory_id = m.universe_master_id)))
        THROW 54096, 'The Subcategory does not belong to the Category or is inactive.', 1;
    IF EXISTS (SELECT 1 FROM (VALUES (@classification_id, N'CLASSIFICATION'), (@reg_significance_id, N'REG_SIGNIFICANCE'),
                                     (@criticality_id, N'CRITICALITY')) v(id, grp)
                WHERE v.id IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_master m
                                   WHERE m.universe_master_id = v.id AND m.organization_id = @organization_id AND m.master_group = v.grp
                                     AND (m.is_active = 1 OR EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_subject s
                                                                      WHERE s.universe_subject_id = @universe_subject_id
                                                                        AND v.id IN (s.classification_id, s.reg_significance_id, s.criticality_id)))))
        THROW 54096, 'An Audit Classification, Regulatory Significance or Business Criticality value was not found or is inactive.', 1;
    IF @owner_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                        WHERE employee_id = @owner_employee_id AND organization_id = @organization_id)
        THROW 54096, 'The Subject Owner is not a person of this organization.', 1;
    IF @division_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_division WHERE division_id = @division_id AND organization_id = @organization_id)
        THROW 54096, 'The Business Unit is not in this organization.', 1;
    IF @department_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_department WHERE department_id = @department_id AND organization_id = @organization_id)
        THROW 54096, 'The Department is not in this organization.', 1;
    IF @parent_subject_id IS NOT NULL
    BEGIN
        IF @parent_subject_id = @universe_subject_id THROW 54096, 'A subject cannot be its own parent.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_subject
                        WHERE universe_subject_id = @parent_subject_id AND organization_id = @organization_id AND status_code <> N'RETIRED')
            THROW 54096, 'The Parent Subject was not found or is retired.', 1;
        IF @universe_subject_id IS NOT NULL
        BEGIN
            -- no loop: the subject must not be an ancestor of its new parent
            DECLARE @walk BIGINT = @parent_subject_id, @hops INT = 0;
            WHILE @walk IS NOT NULL AND @hops < 100
            BEGIN
                IF @walk = @universe_subject_id THROW 54096, 'That parent would make a loop (it is under this subject).', 1;
                SET @walk = (SELECT parent_subject_id FROM grac_practice.org_assurance_universe_subject WHERE universe_subject_id = @walk);
                SET @hops = @hops + 1;
            END
        END
    END

    DECLARE @srcs TABLE(kind NVARCHAR(30), record_id BIGINT, is_primary BIT);
    IF @sources_json IS NOT NULL
    BEGIN
        IF ISJSON(@sources_json) = 0 THROW 54096, 'The registry records are not valid.', 1;
        INSERT INTO @srcs (kind, record_id, is_primary)
        SELECT UPPER(j.kind), j.id, MAX(CAST(ISNULL(j.isPrimary, 0) AS INT))
          FROM OPENJSON(@sources_json) WITH (kind NVARCHAR(30) '$.kind', id BIGINT '$.id', isPrimary BIT '$.isPrimary') j
         WHERE j.kind IS NOT NULL AND j.id IS NOT NULL
         GROUP BY UPPER(j.kind), j.id;
        IF EXISTS (SELECT 1 FROM @srcs s
                    WHERE NOT EXISTS (SELECT 1 FROM grac_practice.fn_org_assurance_universe_registry_records(@organization_id) r
                                       WHERE r.source_kind = s.kind AND r.record_id = s.record_id))
            THROW 54096, 'A linked record is not in this organization''s registry.', 1;
        -- one primary: the first flagged, else the first
        IF (SELECT COUNT(*) FROM @srcs WHERE is_primary = 1) <> 1 AND EXISTS (SELECT 1 FROM @srcs)
        BEGIN
            DECLARE @pk NVARCHAR(30), @pid BIGINT;
            SELECT TOP 1 @pk = kind, @pid = record_id FROM @srcs ORDER BY is_primary DESC, kind, record_id;
            UPDATE @srcs SET is_primary = CASE WHEN kind = @pk AND record_id = @pid THEN 1 ELSE 0 END;
        END
        IF @src = N'REGISTRY' AND NOT EXISTS (SELECT 1 FROM @srcs)
            THROW 54095, 'A subject from the Organization Registry keeps at least one registry record.', 1;
    END

    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);

    -- before (names, for the history)
    DECLARE @before TABLE(field NVARCHAR(60), val NVARCHAR(MAX));
    IF @universe_subject_id IS NOT NULL
        INSERT INTO @before (field, val)
        SELECT v.field, v.val
          FROM grac_practice.org_assurance_universe_subject s
         CROSS APPLY (VALUES
            (N'Subject Name', s.subject_name), (N'Description', s.description),
            (N'Category', (SELECT name FROM grac_practice.org_assurance_universe_master WHERE universe_master_id = s.category_id)),
            (N'Subcategory', (SELECT name FROM grac_practice.org_assurance_universe_master WHERE universe_master_id = s.subcategory_id)),
            (N'Audit Classification', (SELECT name FROM grac_practice.org_assurance_universe_master WHERE universe_master_id = s.classification_id)),
            (N'Regulatory Significance', (SELECT name FROM grac_practice.org_assurance_universe_master WHERE universe_master_id = s.reg_significance_id)),
            (N'Business Criticality', (SELECT name FROM grac_practice.org_assurance_universe_master WHERE universe_master_id = s.criticality_id)),
            (N'Parent Subject', (SELECT universe_ref + N' - ' + subject_name FROM grac_practice.org_assurance_universe_subject WHERE universe_subject_id = s.parent_subject_id)),
            (N'Subject Owner', (SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id = s.owner_employee_id)),
            (N'Business Unit', (SELECT division_code + N' - ' + division_name FROM grac_practice.organization_division WHERE division_id = s.division_id)),
            (N'Department', (SELECT department_code + N' - ' + department_name FROM grac_practice.organization_department WHERE department_id = s.department_id)),
            (N'Effective From', CONVERT(NVARCHAR(10), s.effective_from, 23)),
            (N'Remarks', s.remarks)) v(field, val)
         WHERE s.universe_subject_id = @universe_subject_id;

    BEGIN TRAN;
    IF @universe_subject_id IS NULL
    BEGIN
        DECLARE @ref INT = ISNULL((SELECT MAX(ref_no) FROM grac_practice.org_assurance_universe_subject WITH (UPDLOCK, HOLDLOCK)
                                    WHERE organization_id = @organization_id), 0) + 1;
        INSERT INTO grac_practice.org_assurance_universe_subject
            (organization_id, ref_no, universe_ref, subject_name, description, category_id, subcategory_id, classification_id,
             reg_significance_id, criticality_id, parent_subject_id, subject_source, owner_employee_id, division_id, department_id,
             status_code, effective_from, remarks, entered_by)
        VALUES (@organization_id, @ref, N'AU-' + RIGHT(N'00000' + CAST(@ref AS NVARCHAR(10)), 5), @subject_name, @description,
                @category_id, @subcategory_id, @classification_id, @reg_significance_id, @criticality_id, @parent_subject_id, @src,
                @owner_employee_id, @division_id, @department_id, N'DISCOVERED', @effective_from, @remarks, @actor);
        SET @universe_subject_id = SCOPE_IDENTITY();
        INSERT INTO grac_practice.org_assurance_universe_history
            (organization_id, universe_subject_id, action_code, to_status, comment, employee_id, actor_name)
        VALUES (@organization_id, @universe_subject_id, N'CREATE', N'DISCOVERED',
                CASE @src WHEN N'OTHER' THEN N'Created (source: Other)' ELSE N'Created manually' END, @employee_id, @me);
    END
    ELSE
    BEGIN
        UPDATE grac_practice.org_assurance_universe_subject
           SET subject_name = @subject_name, description = @description, category_id = @category_id, subcategory_id = @subcategory_id,
               classification_id = @classification_id, reg_significance_id = @reg_significance_id, criticality_id = @criticality_id,
               parent_subject_id = @parent_subject_id, owner_employee_id = @owner_employee_id, division_id = @division_id,
               department_id = @department_id, effective_from = @effective_from, remarks = @remarks,
               version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE universe_subject_id = @universe_subject_id AND version_no = @ver;
        IF @@ROWCOUNT = 0 THROW 54098, 'The subject was changed by someone else. Reload it and make the change again.', 1;
    END

    -- registry links
    IF @sources_json IS NOT NULL
    BEGIN
        INSERT INTO grac_practice.org_assurance_universe_history
            (organization_id, universe_subject_id, source_kind, source_record_id, action_code, comment, employee_id, actor_name)
        SELECT @organization_id, @universe_subject_id, x.source_kind, x.source_record_id, N'UNLINK',
               N'Registry record removed: ' + grac_practice.fn_org_assurance_universe_kind_label(x.source_kind)
                 + ISNULL(N' ' + r.record_code, N'') + ISNULL(N' - ' + r.record_name, N''), @employee_id, @me
          FROM grac_practice.org_assurance_universe_source x
          LEFT JOIN grac_practice.fn_org_assurance_universe_registry_records(@organization_id) r
                 ON r.source_kind = x.source_kind AND r.record_id = x.source_record_id
         WHERE x.universe_subject_id = @universe_subject_id AND x.is_active = 1
           AND NOT EXISTS (SELECT 1 FROM @srcs s WHERE s.kind = x.source_kind AND s.record_id = x.source_record_id);
        UPDATE x SET is_active = 0, is_primary = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
          FROM grac_practice.org_assurance_universe_source x
         WHERE x.universe_subject_id = @universe_subject_id AND x.is_active = 1
           AND NOT EXISTS (SELECT 1 FROM @srcs s WHERE s.kind = x.source_kind AND s.record_id = x.source_record_id);

        INSERT INTO grac_practice.org_assurance_universe_history
            (organization_id, universe_subject_id, source_kind, source_record_id, action_code, comment, employee_id, actor_name)
        SELECT @organization_id, @universe_subject_id, s.kind, s.record_id, N'LINK',
               N'Registry record linked: ' + grac_practice.fn_org_assurance_universe_kind_label(s.kind)
                 + ISNULL(N' ' + r.record_code, N'') + N' - ' + r.record_name, @employee_id, @me
          FROM @srcs s
          JOIN grac_practice.fn_org_assurance_universe_registry_records(@organization_id) r
               ON r.source_kind = s.kind AND r.record_id = s.record_id
         WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_source x
                            WHERE x.universe_subject_id = @universe_subject_id AND x.source_kind = s.kind
                              AND x.source_record_id = s.record_id AND x.is_active = 1);
        UPDATE x SET is_active = 1, is_primary = s.is_primary, updated_by = @actor, updated_dt = SYSUTCDATETIME()
          FROM grac_practice.org_assurance_universe_source x
          JOIN @srcs s ON s.kind = x.source_kind AND s.record_id = x.source_record_id
         WHERE x.universe_subject_id = @universe_subject_id;
        INSERT INTO grac_practice.org_assurance_universe_source (universe_subject_id, source_kind, source_record_id, is_primary, entered_by)
        SELECT @universe_subject_id, s.kind, s.record_id, s.is_primary, @actor
          FROM @srcs s
         WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_source x
                            WHERE x.universe_subject_id = @universe_subject_id AND x.source_kind = s.kind AND x.source_record_id = s.record_id);
    END

    -- what changed (an existing subject)
    IF EXISTS (SELECT 1 FROM @before)
    BEGIN
        DECLARE @after TABLE(field NVARCHAR(60), val NVARCHAR(MAX));
        INSERT INTO @after (field, val)
        SELECT v.field, v.val
          FROM grac_practice.org_assurance_universe_subject s
         CROSS APPLY (VALUES
            (N'Subject Name', s.subject_name), (N'Description', s.description),
            (N'Category', (SELECT name FROM grac_practice.org_assurance_universe_master WHERE universe_master_id = s.category_id)),
            (N'Subcategory', (SELECT name FROM grac_practice.org_assurance_universe_master WHERE universe_master_id = s.subcategory_id)),
            (N'Audit Classification', (SELECT name FROM grac_practice.org_assurance_universe_master WHERE universe_master_id = s.classification_id)),
            (N'Regulatory Significance', (SELECT name FROM grac_practice.org_assurance_universe_master WHERE universe_master_id = s.reg_significance_id)),
            (N'Business Criticality', (SELECT name FROM grac_practice.org_assurance_universe_master WHERE universe_master_id = s.criticality_id)),
            (N'Parent Subject', (SELECT universe_ref + N' - ' + subject_name FROM grac_practice.org_assurance_universe_subject WHERE universe_subject_id = s.parent_subject_id)),
            (N'Subject Owner', (SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id = s.owner_employee_id)),
            (N'Business Unit', (SELECT division_code + N' - ' + division_name FROM grac_practice.organization_division WHERE division_id = s.division_id)),
            (N'Department', (SELECT department_code + N' - ' + department_name FROM grac_practice.organization_department WHERE department_id = s.department_id)),
            (N'Effective From', CONVERT(NVARCHAR(10), s.effective_from, 23)),
            (N'Remarks', s.remarks)) v(field, val)
         WHERE s.universe_subject_id = @universe_subject_id;
        DECLARE @changes NVARCHAR(MAX) = (SELECT b.field AS Field, b.val AS Before, a.val AS After
                                            FROM @before b JOIN @after a ON a.field = b.field
                                           WHERE ISNULL(b.val, N'') <> ISNULL(a.val, N'')
                                             FOR JSON PATH, INCLUDE_NULL_VALUES);
        IF @changes IS NOT NULL
            INSERT INTO grac_practice.org_assurance_universe_history
                (organization_id, universe_subject_id, action_code, from_status, to_status, changes_json, employee_id, actor_name)
            VALUES (@organization_id, @universe_subject_id, N'UPDATE', @status, @status, @changes, @employee_id, @me);
    END
    COMMIT;
    SET @universe_subject_id_out = @universe_subject_id;
END
GO

-- 4j. The lifecycle (CR2 3.7) -- see the header for who does what.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_action
    @organization_id     BIGINT,
    @universe_subject_id BIGINT,
    @action              NVARCHAR(20),
    @comment             NVARCHAR(MAX) = NULL,
    @version_no          INT           = NULL,
    @employee_id         BIGINT        = NULL,
    @actor               NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @action  = UPPER(LTRIM(RTRIM(@action)));
    SET @comment = NULLIF(LTRIM(RTRIM(@comment)), N'');
    IF @action NOT IN (N'SUBMIT', N'APPROVE', N'RETURN', N'REVIEW', N'DEACTIVATE', N'REACTIVATE', N'RETIRE', N'DISCARD')
        THROW 54091, 'Unknown action.', 1;
    DECLARE @status NVARCHAR(30), @ver INT, @cat BIGINT, @owner BIGINT, @submitter BIGINT;
    SELECT @status = status_code, @ver = version_no, @cat = category_id, @owner = owner_employee_id, @submitter = submitted_employee_id
      FROM grac_practice.org_assurance_universe_subject
     WHERE universe_subject_id = @universe_subject_id AND organization_id = @organization_id;
    IF @status IS NULL THROW 54090, 'The subject was not found in this organization.', 1;
    IF @version_no IS NOT NULL AND @version_no <> @ver
        THROW 54098, 'The subject was changed by someone else. Reload it and try again.', 1;

    DECLARE @hia BIT = CASE WHEN @employee_id IS NOT NULL AND EXISTS
                            (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'HEAD_INTERNAL_AUDIT') h
                              WHERE h.employee_id = @employee_id) THEN 1 ELSE 0 END;
    DECLARE @to NVARCHAR(30) = CASE @action WHEN N'SUBMIT' THEN N'UNDER_VALIDATION' WHEN N'APPROVE' THEN N'ACTIVE'
                                            WHEN N'RETURN' THEN N'DISCOVERED' WHEN N'REVIEW' THEN N'ACTIVE'
                                            WHEN N'DEACTIVATE' THEN N'INACTIVE' WHEN N'REACTIVATE' THEN N'UNDER_VALIDATION'
                                            ELSE N'RETIRED' END;

    IF (@action = N'SUBMIT' AND @status <> N'DISCOVERED')
       OR (@action IN (N'APPROVE', N'RETURN') AND @status <> N'UNDER_VALIDATION')
       OR (@action IN (N'REVIEW', N'DEACTIVATE') AND @status <> N'ACTIVE')
       OR (@action = N'REACTIVATE' AND @status <> N'INACTIVE')
       OR (@action = N'RETIRE' AND @status NOT IN (N'ACTIVE', N'INACTIVE'))
       OR (@action = N'DISCARD' AND @status <> N'DISCOVERED')
        THROW 54091, 'The subject is not in a state that allows this.', 1;
    IF @action IN (N'APPROVE', N'RETURN', N'REVIEW', N'DEACTIVATE', N'RETIRE') AND @hia = 0
        THROW 54092, 'Only the Head of Internal Audit (or a delegate holding that responsibility) does this.', 1;
    IF @action = N'APPROVE' AND @submitter IS NOT NULL AND @submitter = @employee_id
        THROW 54093, 'You submitted this subject; another Head of Internal Audit delegate approves it.', 1;
    IF @action IN (N'RETURN', N'DEACTIVATE', N'REACTIVATE', N'RETIRE', N'DISCARD') AND @comment IS NULL
        THROW 54094, 'Give the reason.', 1;
    IF @action IN (N'SUBMIT', N'REACTIVATE') AND (@cat IS NULL OR @owner IS NULL)
        THROW 54095, 'Set the Subject Category and the Subject Owner before submitting.', 1;
    IF @action IN (N'RETIRE', N'DISCARD')
       AND EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_subject
                    WHERE parent_subject_id = @universe_subject_id AND status_code <> N'RETIRED')
        THROW 54091, 'Move or retire its sub-subjects first.', 1;

    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    BEGIN TRAN;
    UPDATE grac_practice.org_assurance_universe_subject
       SET status_code           = @to,
           submitted_employee_id = CASE WHEN @action IN (N'SUBMIT', N'REACTIVATE') THEN @employee_id ELSE submitted_employee_id END,
           submitted_by          = CASE WHEN @action IN (N'SUBMIT', N'REACTIVATE') THEN @me ELSE submitted_by END,
           submitted_dt          = CASE WHEN @action IN (N'SUBMIT', N'REACTIVATE') THEN SYSUTCDATETIME() ELSE submitted_dt END,
           approved_employee_id  = CASE WHEN @action = N'APPROVE' THEN @employee_id ELSE approved_employee_id END,
           approved_by           = CASE WHEN @action = N'APPROVE' THEN @me ELSE approved_by END,
           approved_dt           = CASE WHEN @action = N'APPROVE' THEN SYSUTCDATETIME() ELSE approved_dt END,
           effective_from        = CASE WHEN @action = N'APPROVE' AND effective_from IS NULL
                                        THEN CAST(SYSUTCDATETIME() AS DATE) ELSE effective_from END,
           last_reviewed_on      = CASE WHEN @action IN (N'APPROVE', N'REVIEW') THEN CAST(SYSUTCDATETIME() AS DATE) ELSE last_reviewed_on END,
           version_no            = version_no + 1,
           updated_by            = @actor, updated_dt = SYSUTCDATETIME()
     WHERE universe_subject_id = @universe_subject_id AND version_no = @ver;
    IF @@ROWCOUNT = 0 THROW 54098, 'The subject was changed by someone else. Reload it and try again.', 1;
    INSERT INTO grac_practice.org_assurance_universe_history
        (organization_id, universe_subject_id, action_code, from_status, to_status, comment, employee_id, actor_name)
    VALUES (@organization_id, @universe_subject_id, @action, @status, @to, @comment, @employee_id, @me);
    COMMIT;
END
GO

-- 4k. Add / end a relationship between two subjects (CR2 3.6). Neither may
-- be retired; one active link per pair and type.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_relationship_save
    @organization_id          BIGINT,
    @universe_relationship_id BIGINT         = NULL,
    @from_subject_id          BIGINT         = NULL,
    @to_subject_id            BIGINT         = NULL,
    @relationship_type_id     BIGINT         = NULL,
    @remarks                  NVARCHAR(1000) = NULL,
    @is_active                BIT            = 1,
    @employee_id              BIGINT         = NULL,
    @actor                    NVARCHAR(100)  = 'system',
    @universe_relationship_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @remarks = NULLIF(LTRIM(RTRIM(@remarks)), N'');
    IF @organization_id IS NULL THROW 54096, 'organization_id is required.', 1;
    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    DECLARE @type_name NVARCHAR(200), @from_ref NVARCHAR(400), @to_ref NVARCHAR(400);

    IF @universe_relationship_id IS NOT NULL
    BEGIN
        -- end (or change the remarks of) an existing link
        SELECT @from_subject_id = r.from_subject_id, @to_subject_id = r.to_subject_id, @type_name = t.name
          FROM grac_practice.org_assurance_universe_relationship r
          JOIN grac_practice.org_assurance_universe_master t ON t.universe_master_id = r.relationship_type_id
         WHERE r.universe_relationship_id = @universe_relationship_id AND r.organization_id = @organization_id AND r.is_active = 1;
        IF @from_subject_id IS NULL THROW 54090, 'The relationship was not found.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_subject
                    WHERE universe_subject_id IN (@from_subject_id, @to_subject_id) AND status_code = N'RETIRED')
            THROW 54091, 'A retired subject''s relationships are kept as they are.', 1;
        SELECT @from_ref = universe_ref + N' - ' + subject_name FROM grac_practice.org_assurance_universe_subject WHERE universe_subject_id = @from_subject_id;
        SELECT @to_ref   = universe_ref + N' - ' + subject_name FROM grac_practice.org_assurance_universe_subject WHERE universe_subject_id = @to_subject_id;
        BEGIN TRAN;
        UPDATE grac_practice.org_assurance_universe_relationship
           SET is_active = ISNULL(@is_active, 1), remarks = @remarks, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE universe_relationship_id = @universe_relationship_id;
        IF ISNULL(@is_active, 1) = 0
            INSERT INTO grac_practice.org_assurance_universe_history
                (organization_id, universe_subject_id, action_code, comment, employee_id, actor_name)
            VALUES (@organization_id, @from_subject_id, N'UNRELATE', @from_ref + N' ' + @type_name + N' ' + @to_ref + N' -- ended', @employee_id, @me),
                   (@organization_id, @to_subject_id,   N'UNRELATE', @from_ref + N' ' + @type_name + N' ' + @to_ref + N' -- ended', @employee_id, @me);
        COMMIT;
        SET @universe_relationship_id_out = @universe_relationship_id;
        RETURN;
    END

    IF @from_subject_id IS NULL OR @to_subject_id IS NULL OR @relationship_type_id IS NULL
        THROW 54095, 'Choose both subjects and the relationship.', 1;
    IF @from_subject_id = @to_subject_id THROW 54096, 'A subject cannot be related to itself.', 1;
    IF (SELECT COUNT(*) FROM grac_practice.org_assurance_universe_subject
         WHERE universe_subject_id IN (@from_subject_id, @to_subject_id) AND organization_id = @organization_id
           AND status_code <> N'RETIRED') <> 2
        THROW 54096, 'Both subjects must be in this organization''s Universe and not retired.', 1;
    SELECT @type_name = name FROM grac_practice.org_assurance_universe_master
     WHERE universe_master_id = @relationship_type_id AND organization_id = @organization_id
       AND master_group = N'RELATIONSHIP' AND is_active = 1;
    IF @type_name IS NULL THROW 54096, 'The relationship type was not found or is inactive.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_relationship
                WHERE from_subject_id = @from_subject_id AND to_subject_id = @to_subject_id
                  AND relationship_type_id = @relationship_type_id AND is_active = 1)
        THROW 54097, 'That relationship already exists.', 1;
    SELECT @from_ref = universe_ref + N' - ' + subject_name FROM grac_practice.org_assurance_universe_subject WHERE universe_subject_id = @from_subject_id;
    SELECT @to_ref   = universe_ref + N' - ' + subject_name FROM grac_practice.org_assurance_universe_subject WHERE universe_subject_id = @to_subject_id;

    BEGIN TRAN;
    INSERT INTO grac_practice.org_assurance_universe_relationship
        (organization_id, from_subject_id, to_subject_id, relationship_type_id, remarks, entered_by)
    VALUES (@organization_id, @from_subject_id, @to_subject_id, @relationship_type_id, @remarks, @actor);
    SET @universe_relationship_id_out = SCOPE_IDENTITY();
    INSERT INTO grac_practice.org_assurance_universe_history
        (organization_id, universe_subject_id, action_code, comment, employee_id, actor_name)
    VALUES (@organization_id, @from_subject_id, N'RELATE', @from_ref + N' ' + @type_name + N' ' + @to_ref + ISNULL(N' (' + @remarks + N')', N''), @employee_id, @me),
           (@organization_id, @to_subject_id,   N'RELATE', @from_ref + N' ' + @type_name + N' ' + @to_ref + ISNULL(N' (' + @remarks + N')', N''), @employee_id, @me);
    COMMIT;
END
GO

-- 4l. Universe History (CR2 3.2 / 3.7): every change across the Universe.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_history_list
    @organization_id     BIGINT,
    @universe_subject_id BIGINT        = NULL,
    @action_code         NVARCHAR(30)  = NULL,
    @from_dt             DATE          = NULL,
    @to_dt               DATE          = NULL,
    @search              NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 54096, 'organization_id is required.', 1;
    SELECT TOP (2000)
           h.universe_history_id AS UniverseHistoryId, h.universe_subject_id AS UniverseSubjectId,
           s.universe_ref AS UniverseRef, s.subject_name AS SubjectName,
           h.source_kind AS SourceKind, grac_practice.fn_org_assurance_universe_kind_label(h.source_kind) AS KindLabel,
           h.action_code AS ActionCode, h.from_status AS FromStatus, h.to_status AS ToStatus,
           h.comment AS Comment, h.changes_json AS ChangesJson, h.actor_name AS ActorName, h.action_dt AS ActionDt
      FROM grac_practice.org_assurance_universe_history h
      LEFT JOIN grac_practice.org_assurance_universe_subject s ON s.universe_subject_id = h.universe_subject_id
     WHERE h.organization_id = @organization_id
       AND (@universe_subject_id IS NULL OR h.universe_subject_id = @universe_subject_id)
       AND (NULLIF(@action_code, N'') IS NULL OR h.action_code = @action_code)
       AND (@from_dt IS NULL OR h.action_dt >= @from_dt)
       AND (@to_dt IS NULL OR h.action_dt < DATEADD(DAY, 1, @to_dt))
       AND (NULLIF(@search, N'') IS NULL OR s.universe_ref LIKE N'%' + @search + N'%' OR s.subject_name LIKE N'%' + @search + N'%'
            OR h.comment LIKE N'%' + @search + N'%' OR h.actor_name LIKE N'%' + @search + N'%')
     ORDER BY h.action_dt DESC, h.universe_history_id DESC;
END
GO

-- =====================================================================
-- 5. Menu: Audit Assurance -> Audit Intelligence (group, 441, first group
--    after the Dashboard -- 578) -> Audit Universe (10), Universe Configuration (20);
--    also in 274's snapshot.
-- =====================================================================
DECLARE @assurance_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'nav-audit-intelligence', N'Audit Intelligence', CAST(NULL AS NVARCHAR(300)), 441, N'brain')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @assurance_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Audit Assurance',
    status = N'Active', updated_by = 'seed-577', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @assurance_id, src.display_order,
     src.icon_class, N'Audit Assurance', N'Active', 'seed-577');
PRINT '577.5: nav-audit-intelligence menu row upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

DECLARE @intel_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-audit-intelligence');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'org-audit-universe',        N'Audit Universe',         N'Practice/org-audit-universe',        10, N'globe'),
    (N'org-audit-universe-config', N'Universe Configuration', N'Practice/org-audit-universe-config', 20, N'sliders')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @intel_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Audit Assurance',
    status = N'Active', updated_by = 'seed-577', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @intel_id, src.display_order,
     src.icon_class, N'Audit Assurance', N'Active', 'seed-577');
PRINT '577.5: Audit Universe menu rows upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- The roles that hold Audit Plans get both screens with the same rights.
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT p.role_id, m.menu_id, p.can_view, p.can_add, p.can_edit, p.can_delete, p.can_approve,
       p.status, p.record_status_id, N'seed-577', SYSUTCDATETIME()
FROM   grac_practice.organization_role_menu_permission p
JOIN   grac_practice.menu_master pm ON pm.menu_id = p.menu_id AND pm.menu_key = N'org-assurance-plans'
JOIN   grac_practice.menu_master m  ON m.menu_key IN (N'org-audit-universe', N'org-audit-universe-config')
WHERE  NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission x
        WHERE x.role_id = p.role_id AND x.menu_id = m.menu_id);
PRINT '577.5: Audit Universe permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 6. Verification
-- =====================================================================
DECLARE @missing NVARCHAR(MAX) = N'';
SELECT @missing = @missing + n.name + N' '
  FROM (VALUES (N'fn_org_assurance_universe_registry_records'), (N'fn_org_assurance_universe_kind_label'),
               (N'sp_org_assurance_universe_master_seed'), (N'sp_org_assurance_universe_master_list'),
               (N'sp_org_assurance_universe_master_save'), (N'sp_org_assurance_universe_discover'),
               (N'sp_org_assurance_universe_discover_apply'), (N'sp_org_assurance_universe_lookups'),
               (N'sp_org_assurance_universe_list'), (N'sp_org_assurance_universe_get'),
               (N'sp_org_assurance_universe_save'), (N'sp_org_assurance_universe_action'),
               (N'sp_org_assurance_universe_relationship_save'), (N'sp_org_assurance_universe_history_list')) n(name)
 WHERE OBJECT_ID(N'grac_practice.' + n.name) IS NULL;
IF @missing <> N'' RAISERROR('577 verification: missing objects: %s', 16, 1, @missing);
SELECT (SELECT COUNT(*) FROM grac_practice.role_responsibility_master WHERE responsibility_code = N'HEAD_INTERNAL_AUDIT') AS hia_responsibility,
       (SELECT COUNT(*) FROM grac_practice.menu_master
         WHERE menu_key IN (N'nav-audit-intelligence', N'org-audit-universe', N'org-audit-universe-config') AND status = N'Active') AS menu_rows;
PRINT '577 done: Audit Intelligence -- Audit Universe (register, discovery, classification, relationships, approval, history).';
GO
