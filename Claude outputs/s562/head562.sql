-- =====================================================================
-- 562  Scope Builder -- Step 1 Audit Subjects, Step 2 Discover
--      (Audit Change spec 4.2.1, P0 phase C1)
--
-- REQUEST (2026-11-15, sir): phase C of docs/audit-change-p0-plan.md.
--   Decisions:
--     * the audit subjects (Step 1) are the Operationalize DEPENDENCY
--       types -- Person, Tool, Asset, Vendor, Application, Process,
--       Location, ... (dependency_type_master) -- their objects picked
--       from the same lists Operationalize uses
--       (dependency_type_source_config);
--     * Step 1 and Step 2 (Discover related GRAC intelligence) are in
--       Audit Configuration; Step 3 (review, untick records, add manual
--       items, approve the snapshot) is on the engagement / My Audits live
--       scope -- phase C2. Manual subjects come with C2 too (they become
--       scope items there).
--
-- WHAT THIS DOES
--   1. NEW fn_org_assurance_dep_type(@dimension_code) -- the dependency
--      type behind a scope dimension: DEP_<CODE> (this migration), and
--      the older ASSET / DEPARTMENT / VENDOR / APPLICATION / PROCESS /
--      BRANCH dimensions (the 556 map).
--   2. One scope dimension per dependency category Operationalize offers
--      (resolve-workspace DEP_TABLE_CATEGORIES -- Asset, Vendor, Person,
--      Team, Committee, Location, Business Function -- and Department,
--      the picker inside the Person row): DEP_<CODE>, "<type name>",
--      category 'Subject', pickable; active type with an allowed source
--      table only. Any other DEP_ dimension (Tool, Application, Process --
--      not offered in Operationalize) is made inactive (sir, 2026-11-15:
--      "the same as Operationalize").
--   2b. sp_org_assurance_scope_dimension_list (074 body) -- + DependencyTypeId.
--   3. sp_org_assurance_scope_dimension_values (554 body) -- a DEP_<CODE>
--      dimension lists that type's objects from its source table
--      (dependency_type_source_config; same allow-list as 497 / the Api's
--      dependency-options query), active, of the organization.
--   4. sp_org_assurance_scope_resolve (534 body) -- a picked subject
--      resolves to the ACTIVE practice instances that depend on it in
--      Operationalize (practice_dependency_resolution), stored as
--      PRACTICE_INSTANCE rows, exactly as 534 does for control
--      statements -- so freezing, branch narrowing (554), My Audits (555)
--      and Continuous Assurance (556) work unchanged. Subjects add up: the
--      audit covers the instances of every subject picked.
--   5. NEW org_assurance_scope_category -- per definition version, which
--      discovered categories the audit brings in (default: all). Read by
--      phase C2 (Step 3). Versioned: copy_config (560 body) copies it.
--   6. NEW sp_org_assurance_scope_discover -- Step 2: for the version's
--      subjects, the related Practice Instances, Practices, Control
--      Statements, Risks, Gaps, Exceptions, Assets and Vendors, each with
--      WHY it is related; and the per-category counts with their
--      included flag. Read-only; discovery is optional and needs nothing
--      but Operationalize data (standalone use, spec 7).
--   7. NEW sp_org_assurance_scope_category_save -- the category flags
--      (Draft versions only, as the scope).
--
-- Older scopes built on DEPARTMENT / VENDOR / ASSET filters stay valid
-- and apply as saved; the Scope Builder shows them read-only (as it does
-- an Advanced-mode scope) with "Replace with a simple scope".
--
-- ERRORS: 53705 category list not valid JSON; 53706 unknown category;
--   (53602 / 53606 / 53607 / 53608 / 53611 as the scope save).
-- DEPENDS ON: 534, 554, 560 (copy_config body), 245 / 261 / 265 / 328 /
--   382 (gap, risk and exception links).
-- Rollback: 562_scope_subjects_discovery_rollback.sql.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_definition_mandate','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_org_scope_statement_instance','IF') IS NULL
   OR OBJECT_ID('grac_practice.dependency_type_source_config','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NULL
   OR OBJECT_ID('grac_practice.risk_dependency_map','U') IS NULL
   OR OBJECT_ID('grac_practice.risk_practice_map','U') IS NULL
   OR OBJECT_ID('grac_practice.custom_gap_practice_map','U') IS NULL
   OR OBJECT_ID('grac_practice.exception_request_practice','U') IS NULL
BEGIN
    PRINT 'ABORT (562): run 560 (and 534, 245, 261, 265, 328, 382) first. Nothing was changed.';
    RAISERROR('562_scope_subjects_discovery: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. The dependency type behind a scope dimension
-- ---------------------------------------------------------------------
CREATE OR ALTER FUNCTION grac_practice.fn_org_assurance_dep_type(@dimension_code NVARCHAR(60))
RETURNS TABLE
AS
RETURN
    SELECT dt.dependency_type_id, dt.dependency_type_code, dt.dependency_type_name
    FROM grac_practice.dependency_type_master dt
    WHERE dt.is_active = 1
      AND (   N'DEP_' + UPPER(REPLACE(dt.dependency_type_code, N' ', N'_')) = UPPER(@dimension_code)
           -- the older dimensions (556 map)
           OR (UPPER(@dimension_code) = N'ASSET'       AND UPPER(dt.dependency_type_code) = N'ASSET')
           OR (UPPER(@dimension_code) = N'DEPARTMENT'  AND UPPER(dt.dependency_type_code) = N'DEPARTMENT')
           OR (UPPER(@dimension_code) = N'VENDOR'      AND UPPER(dt.dependency_type_code) = N'VENDOR')
           OR (UPPER(@dimension_code) = N'APPLICATION' AND UPPER(dt.dependency_type_code) = N'APPLICATION')
           OR (UPPER(@dimension_code) = N'PROCESS'     AND UPPER(dt.dependency_type_code) = N'PROCESS')
           OR (UPPER(@dimension_code) = N'BRANCH'      AND UPPER(dt.dependency_type_code) = N'LOCATION'));
GO

-- ---------------------------------------------------------------------
-- 2. One subject dimension per dependency type
-- ---------------------------------------------------------------------
;WITH src AS (
    SELECT N'DEP_' + UPPER(REPLACE(dt.dependency_type_code, N' ', N'_')) AS dimension_code,
           dt.dependency_type_name AS dimension_name,
           500 + dt.display_order  AS display_order
    FROM grac_practice.dependency_type_master dt
    WHERE dt.is_active = 1
      AND dt.dependency_type_name IN (N'Asset', N'Vendor', N'Person', N'Department', N'Team',
                                      N'Committee', N'Location', N'Business Function')
      AND EXISTS (SELECT 1 FROM grac_practice.dependency_type_source_config c
                   WHERE c.dependency_type_id = dt.dependency_type_id
                     AND c.status = N'Active'
                     AND c.source_table_name IN (
                        N'grac_practice.organization_dependency_tool',
                        N'grac_practice.organization_dependency_vendor',
                        N'grac_practice.organization_dependency_application',
                        N'grac_practice.organization_dependency_asset',
                        N'grac_practice.organization_dependency_process',
                        N'grac_practice.organization_location',
                        N'grac_practice.organization_employee',
                        N'grac_practice.organization_team',
                        N'grac_practice.organization_committee',
                        N'grac_practice.organization_department',
                        N'grac_practice.organization_business_function'))
)
MERGE grac_practice.org_assurance_scope_dimension_master AS t
USING src AS s ON t.dimension_code = s.dimension_code
WHEN MATCHED THEN
    UPDATE SET dimension_name = s.dimension_name, category = N'Subject', is_pickable = 1,
               display_order = s.display_order, is_active = 1,
               updated_by = N'562_scope_subjects_discovery', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (dimension_code, dimension_name, category, is_pickable, display_order, is_active, entered_by)
    VALUES (s.dimension_code, s.dimension_name, N'Subject', 1, s.display_order, 1, N'562_scope_subjects_discovery');
GO

-- A DEP_ dimension for a category Operationalize does not offer.
UPDATE dm
   SET is_active = 0, updated_by = N'562_scope_subjects_discovery', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.org_assurance_scope_dimension_master dm
 WHERE dm.dimension_code LIKE N'DEP[_]%'
   AND dm.is_active = 1
   AND NOT EXISTS (SELECT 1 FROM grac_practice.dependency_type_master dt
                    WHERE dt.is_active = 1
                      AND dt.dependency_type_name IN (N'Asset', N'Vendor', N'Person', N'Department', N'Team',
                                                      N'Committee', N'Location', N'Business Function')
                      AND N'DEP_' + UPPER(REPLACE(dt.dependency_type_code, N' ', N'_')) = dm.dimension_code);
GO

-- Scope dimensions, with the dependency type behind each (074 body + 562:
-- DependencyTypeId -- the Scope Builder loads a subject's objects with the
-- same dependency-options query Operationalize uses).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_scope_dimension_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT dm.dimension_id    AS DimensionId,
           dm.dimension_code  AS DimensionCode,
           dm.dimension_name  AS DimensionName,
           dm.category        AS Category,
           dm.is_pickable     AS IsPickable,
           dm.display_order   AS DisplayOrder,
           CASE WHEN dm.dimension_code LIKE N'DEP[_]%' THEN dt.dependency_type_id END AS DependencyTypeId
    FROM grac_practice.org_assurance_scope_dimension_master dm
    OUTER APPLY (SELECT TOP 1 x.dependency_type_id
                   FROM grac_practice.fn_org_assurance_dep_type(dm.dimension_code) x) dt
    WHERE dm.is_active = 1
    ORDER BY dm.display_order, dm.dimension_id;
END
GO

-- ---------------------------------------------------------------------
-- 5. Discovered categories the audit brings in (per definition version)
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.org_assurance_scope_category','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_scope_category (
        scope_category_id                   BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_org_assurance_scope_category PRIMARY KEY,
        org_assurance_definition_version_id BIGINT        NOT NULL
            CONSTRAINT FK_org_assurance_scope_category_version
                REFERENCES grac_practice.org_assurance_definition_version (org_assurance_definition_version_id),
        organization_id                     BIGINT        NOT NULL,
        category_code                       NVARCHAR(40)  NOT NULL,
        is_included                         BIT           NOT NULL CONSTRAINT DF_org_assurance_scope_category_inc    DEFAULT (1),
        is_active                           BIT           NOT NULL CONSTRAINT DF_org_assurance_scope_category_active DEFAULT (1),
        entered_by                          NVARCHAR(100) NOT NULL CONSTRAINT DF_org_assurance_scope_category_eby    DEFAULT (N'system'),
        entered_dt                          DATETIME2     NOT NULL CONSTRAINT DF_org_assurance_scope_category_edt    DEFAULT (SYSUTCDATETIME()),
        updated_by                          NVARCHAR(100) NULL,
        updated_dt                          DATETIME2     NULL
    );
    CREATE INDEX IX_org_assurance_scope_category_version
        ON grac_practice.org_assurance_scope_category (org_assurance_definition_version_id, is_active);
    PRINT '562: org_assurance_scope_category created.';
END
GO
