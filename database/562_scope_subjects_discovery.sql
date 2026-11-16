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

-- ---------------------------------------------------------------------
-- 3. sp_org_assurance_scope_dimension_values (554 body + 562)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_scope_dimension_values
    @organization_id BIGINT,
    @dimension_code  NVARCHAR(60),
    @search          NVARCHAR(200) = NULL,
    @page_size       INT           = 100
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 53701, 'organization_id is required.', 1;
    IF @dimension_code IS NULL
        THROW 53702, 'dimension_code is required.', 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 100;
    IF @page_size > 500                    SET @page_size = 500;

    DECLARE @like NVARCHAR(220) = CASE
        WHEN @search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0 THEN NULL
        ELSE N'%' + @search + N'%'
    END;

    IF @dimension_code = N'DEPARTMENT'
        AND OBJECT_ID('grac_practice.organization_department','U') IS NOT NULL
    BEGIN
        SELECT TOP (@page_size)
               d.department_id   AS Id,
               d.department_code AS Code,
               d.department_name AS Name
        FROM grac_practice.organization_department d
        WHERE d.organization_id = @organization_id
          AND d.status = N'Active'
          AND (@like IS NULL
               OR d.department_name LIKE @like
               OR d.department_code LIKE @like)
        ORDER BY d.department_name;
        RETURN;
    END

    IF @dimension_code = N'VENDOR'
        AND OBJECT_ID('grac_practice.organization_dependency_vendor','U') IS NOT NULL
    BEGIN
        SELECT TOP (@page_size)
               v.vendor_id                     AS Id,
               CAST(NULL AS NVARCHAR(120))     AS Code,
               v.vendor_name                   AS Name
        FROM grac_practice.organization_dependency_vendor v
        WHERE v.organization_id = @organization_id
          AND v.status = N'Active'
          AND (@like IS NULL OR v.vendor_name LIKE @like)
        ORDER BY v.vendor_name;
        RETURN;
    END

    IF @dimension_code = N'ASSET'
        AND OBJECT_ID('grac_practice.organization_dependency_asset','U') IS NOT NULL
    BEGIN
        SELECT TOP (@page_size)
               a.asset_id                    AS Id,
               CAST(NULL AS NVARCHAR(120))   AS Code,
               a.asset_name                  AS Name
        FROM grac_practice.organization_dependency_asset a
        WHERE a.organization_id = @organization_id
          AND a.status = N'Active'
          AND (@like IS NULL OR a.asset_name LIKE @like)
        ORDER BY a.asset_name;
        RETURN;
    END

    -- 554: Branches are the organization's Locations (Location master).
    -- BRANCH stays non-pickable, so the Scope Builder does not offer it;
    -- the Audit Plan engagement's Branch picker reads this list.
    IF @dimension_code = N'BRANCH'
        AND OBJECT_ID('grac_practice.organization_location','U') IS NOT NULL
    BEGIN
        SELECT TOP (@page_size)
               l.location_id                 AS Id,
               CAST(NULL AS NVARCHAR(120))   AS Code,
               l.location_name               AS Name
        FROM grac_practice.organization_location l
        WHERE l.organization_id = @organization_id
          AND l.status = N'Active'
          AND (@like IS NULL OR l.location_name LIKE @like)
        ORDER BY l.location_name;
        RETURN;
    END

    IF @dimension_code = N'PRACTICE_INSTANCE'
        AND OBJECT_ID('grac_practice.practice_instance','U') IS NOT NULL
    BEGIN
        SELECT TOP (@page_size)
               pi.practice_instance_id AS Id,
               pi.instance_code        AS Code,
               pi.instance_name        AS Name
        FROM grac_practice.practice_instance pi
        WHERE pi.organization_id = @organization_id
          AND pi.status = N'Active'
          AND (@like IS NULL
               OR pi.instance_name LIKE @like
               OR pi.instance_code LIKE @like)
        ORDER BY pi.instance_name;
        RETURN;
    END

    -- 534: Source statements (Framework -> Release -> Source Structure ->
    -- Source Statement). Id is org_statement_id. Flat here; the Scope
    -- Builder's tree picker reads sp_org_assurance_scope_statement_tree.
    IF @dimension_code = N'SOURCE_STATEMENT'
        AND OBJECT_ID('grac_practice.fn_org_scope_statement','IF') IS NOT NULL
    BEGIN
        SELECT TOP (@page_size)
               s.StatementId   AS Id,
               s.StatementCode AS Code,
               s.StatementName AS Name
        FROM grac_practice.fn_org_scope_statement(@organization_id) s
        WHERE (@like IS NULL
               OR s.StatementName LIKE @like
               OR s.StatementCode LIKE @like)
        ORDER BY s.FrameworkName, s.ReleaseName, s.StructureOrder, s.StatementOrder, s.StatementCode;
        RETURN;
    END

    -- 562: an audit subject -- a dependency type's objects (Operationalize),
    -- read from the type's source table as dependency_type_source_config
    -- names it; same allow-list as 497 / the Api's dependency-options query.
    IF @dimension_code LIKE N'DEP[_]%'
    BEGIN
        DECLARE @dep_type_id INT = (SELECT TOP 1 dependency_type_id
                                      FROM grac_practice.fn_org_assurance_dep_type(@dimension_code));
        DECLARE @src NVARCHAR(200), @id_col NVARCHAR(80), @name_col NVARCHAR(80),
                @org_col NVARCHAR(80), @status_col NVARCHAR(80), @active_val NVARCHAR(80);
        SELECT TOP 1
               @src        = source_table_name,
               @id_col     = id_column_name,
               @name_col   = display_column_name,
               @org_col    = organization_filter_column,
               @status_col = status_filter_column,
               @active_val = COALESCE(NULLIF(status_active_value, N''), N'Active')
        FROM grac_practice.dependency_type_source_config
        WHERE dependency_type_id = @dep_type_id
          AND status = N'Active'
          AND source_table_name IN (
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
                N'grac_practice.organization_business_function');

        IF @src IS NOT NULL AND @id_col IS NOT NULL AND @name_col IS NOT NULL
           AND OBJECT_ID(@src, 'U') IS NOT NULL
        BEGIN
            DECLARE @sql NVARCHAR(MAX) = N'
                SELECT TOP (@n)
                       CAST(t.' + QUOTENAME(@id_col) + N' AS BIGINT)        AS Id,
                       CAST(NULL AS NVARCHAR(120))                          AS Code,
                       CAST(t.' + QUOTENAME(@name_col) + N' AS NVARCHAR(240)) AS Name
                FROM ' + QUOTENAME(PARSENAME(@src, 2)) + N'.' + QUOTENAME(PARSENAME(@src, 1)) + N' t
                WHERE 1 = 1'
                + CASE WHEN NULLIF(@org_col, N'') IS NOT NULL
                       THEN N' AND t.' + QUOTENAME(@org_col) + N' = @org' ELSE N'' END
                + CASE WHEN NULLIF(@status_col, N'') IS NOT NULL
                       THEN N' AND t.' + QUOTENAME(@status_col) + N' = @active' ELSE N'' END
                + N' AND (@like IS NULL OR t.' + QUOTENAME(@name_col) + N' LIKE @like)
                ORDER BY t.' + QUOTENAME(@name_col) + N';';
            EXEC sp_executesql @sql,
                 N'@n INT, @org BIGINT, @active NVARCHAR(80), @like NVARCHAR(220)',
                 @n = @page_size, @org = @organization_id, @active = @active_val, @like = @like;
            RETURN;
        END
    END

    -- Unsupported dimension -- return empty rowset with the expected shape.
    SELECT CAST(NULL AS BIGINT)      AS Id,
           CAST(NULL AS NVARCHAR(120)) AS Code,
           CAST(NULL AS NVARCHAR(240)) AS Name
    WHERE 1 = 0;
END
GO

-- ---------------------------------------------------------------------
-- 4. sp_org_assurance_scope_resolve (534 body + 562)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_scope_resolve
    @organization_id     BIGINT,
    @definition_id       BIGINT,
    @version_id          BIGINT        = NULL,          -- default current version
    @resolution_purpose  NVARCHAR(30)  = N'PREVIEW',     -- PREVIEW / EXECUTION
    @execution_id        BIGINT        = NULL,
    @actor               NVARCHAR(100) = 'system',
    @resolution_id_out   BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;
    IF @resolution_purpose NOT IN (N'PREVIEW', N'EXECUTION')
        SET @resolution_purpose = N'PREVIEW';

    -- Resolve current version if caller didn't specify one, and
    -- verify org ownership.
    DECLARE @def_org BIGINT, @current_version_id BIGINT;

    SELECT @def_org            = d.organization_id,
           @current_version_id = d.current_version_id
    FROM grac_practice.org_assurance_definition d
    WHERE d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    IF @def_org IS NULL      THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id
        THROW 53607, 'Definition belongs to a different organization.', 1;

    IF @version_id IS NULL SET @version_id = @current_version_id;
    IF @version_id IS NULL THROW 53611, 'Definition has no current version.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    BEGIN TRAN;

    -- Insert the resolution header first so we have @resolution_id_out
    -- to attach entity rows to.
    INSERT INTO grac_practice.org_assurance_scope_resolution
        (org_assurance_definition_id, org_assurance_definition_version_id, organization_id,
         resolution_purpose, execution_id,
         resolved_at, resolved_by,
         total_entity_count, summary_json,
         is_active, record_status_id)
    VALUES
        (@definition_id, @version_id, @organization_id,
         @resolution_purpose, @execution_id,
         SYSUTCDATETIME(), @actor,
         0, NULL,
         1, @active_record_status_id);

    SET @resolution_id_out = SCOPE_IDENTITY();

    -- Flatten scope conditions + values into a working table so the
    -- per-dimension resolver can loop over them without repeated joins.
    DECLARE @conds TABLE(
        dimension_code         NVARCHAR(60),
        group_order            INT,
        condition_order        INT,
        is_not                 BIT,
        include_all            BIT,
        value_entity_id        BIGINT NULL,
        value_entity_code      NVARCHAR(120) NULL,
        value_entity_name      NVARCHAR(240) NULL);

    INSERT INTO @conds(dimension_code, group_order, condition_order, is_not, include_all,
                       value_entity_id, value_entity_code, value_entity_name)
    SELECT dm.dimension_code,
           g.group_order,
           c.condition_order,
           c.is_not,
           c.include_all,
           v.dimension_entity_id,
           v.dimension_entity_code,
           v.dimension_entity_name
    FROM grac_practice.org_assurance_scope_condition c
    JOIN grac_practice.org_assurance_scope_group g
         ON g.scope_group_id = c.scope_group_id
    JOIN grac_practice.org_assurance_scope_dimension_master dm
         ON dm.dimension_id = c.dimension_id
    LEFT JOIN grac_practice.org_assurance_scope_condition_value v
         ON v.scope_condition_id = c.scope_condition_id AND v.is_active = 1
    WHERE g.org_assurance_definition_version_id = @version_id
      AND g.organization_id = @organization_id
      AND g.is_active = 1
      AND c.is_active = 1;

    -- Resolve each pickable dimension. Non-pickable dimensions have
    -- no PM lookup table wired yet -- we still capture explicit values
    -- (denormalized) at the bottom of this proc so they show up in
    -- the snapshot even though we can't expand include_all / is_not.

    DECLARE @dim_code NVARCHAR(60);
    DECLARE @dim_name NVARCHAR(160);
    DECLARE dim_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT c.dimension_code, dm.dimension_name
        FROM @conds c
        JOIN grac_practice.org_assurance_scope_dimension_master dm
             ON dm.dimension_code = c.dimension_code;

    OPEN dim_cur; FETCH NEXT FROM dim_cur INTO @dim_code, @dim_name;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @picked TABLE(entity_id BIGINT, entity_code NVARCHAR(120), entity_name NVARCHAR(240),
                              source_group_order INT, source_condition_order INT);
        DELETE FROM @picked;

        -- 1) Explicit picks from all conditions on this dimension.
        INSERT INTO @picked(entity_id, entity_code, entity_name,
                            source_group_order, source_condition_order)
        SELECT DISTINCT c.value_entity_id, c.value_entity_code, c.value_entity_name,
               c.group_order, c.condition_order
        FROM @conds c
        WHERE c.dimension_code = @dim_code
          AND c.include_all = 0
          AND c.is_not      = 0
          AND c.value_entity_id IS NOT NULL;

        -- 2) include_all expansion -- delegate to the existing values
        --    proc (074) which knows how to select rows from PM tables
        --    per dimension. If none applies (non-pickable dimension),
        --    the values proc returns an empty rowset.
        IF EXISTS (SELECT 1 FROM @conds
                   WHERE dimension_code = @dim_code AND include_all = 1)
        BEGIN
            -- Grab the include_all trace (group/condition order) so
            -- the snapshot's traceability points somewhere sensible.
            DECLARE @all_go INT, @all_co INT;
            SELECT TOP 1 @all_go = group_order, @all_co = condition_order
            FROM @conds
            WHERE dimension_code = @dim_code AND include_all = 1
            ORDER BY group_order, condition_order;

            DECLARE @all_values TABLE(Id BIGINT, Code NVARCHAR(120), Name NVARCHAR(240));
            DELETE FROM @all_values;

            -- 534: statements come from the function, not the values
            -- proc, which caps at 500 rows.
            IF @dim_code = N'SOURCE_STATEMENT'
                INSERT INTO @all_values(Id, Code, Name)
                SELECT s.StatementId, s.StatementCode, s.StatementName
                FROM grac_practice.fn_org_scope_statement(@organization_id) s;
            ELSE
                INSERT INTO @all_values(Id, Code, Name)
                EXEC grac_practice.sp_org_assurance_scope_dimension_values
                    @organization_id = @organization_id,
                    @dimension_code  = @dim_code,
                    @search          = NULL,
                    @page_size       = 500;

            INSERT INTO @picked(entity_id, entity_code, entity_name,
                                source_group_order, source_condition_order)
            SELECT v.Id, v.Code, v.Name, @all_go, @all_co
            FROM @all_values v
            WHERE v.Id IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM @picked p WHERE p.entity_id = v.Id);
        END

        -- 3) is_not: remove the excluded set from the picked set, and
        --    (if the picked set is empty) treat NOT as "all except".
        IF EXISTS (SELECT 1 FROM @conds
                   WHERE dimension_code = @dim_code AND is_not = 1)
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM @picked)
            BEGIN
                -- "NOT X" with no positive picks -> all - X
                DECLARE @not_go INT, @not_co INT;
                SELECT TOP 1 @not_go = group_order, @not_co = condition_order
                FROM @conds
                WHERE dimension_code = @dim_code AND is_not = 1
                ORDER BY group_order, condition_order;

                DECLARE @all_for_not TABLE(Id BIGINT, Code NVARCHAR(120), Name NVARCHAR(240));
                DELETE FROM @all_for_not;

                IF @dim_code = N'SOURCE_STATEMENT'      -- 534
                    INSERT INTO @all_for_not(Id, Code, Name)
                    SELECT s.StatementId, s.StatementCode, s.StatementName
                    FROM grac_practice.fn_org_scope_statement(@organization_id) s;
                ELSE
                    INSERT INTO @all_for_not(Id, Code, Name)
                    EXEC grac_practice.sp_org_assurance_scope_dimension_values
                        @organization_id = @organization_id,
                        @dimension_code  = @dim_code,
                        @search          = NULL,
                        @page_size       = 500;

                INSERT INTO @picked(entity_id, entity_code, entity_name,
                                    source_group_order, source_condition_order)
                SELECT v.Id, v.Code, v.Name, @not_go, @not_co
                FROM @all_for_not v
                WHERE v.Id IS NOT NULL;
            END

            -- Remove excluded entity_ids.
            DELETE p
              FROM @picked p
              JOIN @conds c
                   ON c.dimension_code = @dim_code
                  AND c.is_not         = 1
                  AND c.value_entity_id IS NOT NULL
                  AND c.value_entity_id = p.entity_id;
        END

        -- 4) Persist to the snapshot.
        -- 534: picked SOURCE STATEMENTS are not audit entities. They
        -- resolve to the active practice instances of the practices mapped
        -- to them, stored as PRACTICE_INSTANCE rows, so the execution
        -- engine (099 / 120) sees exactly what a Practice Instances pick
        -- gave it. An instance already in this snapshot (from another
        -- statement or a legacy Practice Instances pick) is not repeated.
        IF @dim_code = N'SOURCE_STATEMENT'
        BEGIN
            DECLARE @pi_name NVARCHAR(160) = ISNULL((
                SELECT TOP 1 dimension_name FROM grac_practice.org_assurance_scope_dimension_master
                 WHERE dimension_code = N'PRACTICE_INSTANCE'), N'Practice Instances');

            INSERT INTO grac_practice.org_assurance_scope_resolution_entity
                (org_assurance_scope_resolution_id, organization_id,
                 dimension_code, dimension_name,
                 entity_id, entity_code, entity_name,
                 source_group_order, source_condition_order)
            SELECT @resolution_id_out, @organization_id,
                   N'PRACTICE_INSTANCE', @pi_name,
                   x.PracticeInstanceId, x.InstanceCode, x.InstanceName,
                   x.source_group_order, x.source_condition_order
            FROM (
                SELECT si.PracticeInstanceId, si.InstanceCode, si.InstanceName,
                       p.source_group_order, p.source_condition_order,
                       ROW_NUMBER() OVER (PARTITION BY si.PracticeInstanceId
                                          ORDER BY p.source_group_order, p.source_condition_order) AS rn
                FROM @picked p
                JOIN grac_practice.fn_org_scope_statement_instance(@organization_id) si
                     ON si.StatementId = p.entity_id
            ) x
            WHERE x.rn = 1
              AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_scope_resolution_entity e
                               WHERE e.org_assurance_scope_resolution_id = @resolution_id_out
                                 AND e.dimension_code = N'PRACTICE_INSTANCE'
                                 AND e.entity_id      = x.PracticeInstanceId);
        END
        -- 562: a picked audit SUBJECT (a dependency object) resolves to the
        -- active practice instances that depend on it in Operationalize,
        -- stored as PRACTICE_INSTANCE rows (as the statements above), not
        -- repeated when already in this snapshot.
        ELSE IF @dim_code LIKE N'DEP[_]%'
        BEGIN
            DECLARE @pi_name2 NVARCHAR(160) = ISNULL((
                SELECT TOP 1 dimension_name FROM grac_practice.org_assurance_scope_dimension_master
                 WHERE dimension_code = N'PRACTICE_INSTANCE'), N'Practice Instances');

            INSERT INTO grac_practice.org_assurance_scope_resolution_entity
                (org_assurance_scope_resolution_id, organization_id,
                 dimension_code, dimension_name,
                 entity_id, entity_code, entity_name,
                 source_group_order, source_condition_order)
            SELECT @resolution_id_out, @organization_id,
                   N'PRACTICE_INSTANCE', @pi_name2,
                   x.practice_instance_id, x.instance_code, x.instance_name,
                   x.source_group_order, x.source_condition_order
            FROM (
                SELECT pi.practice_instance_id, pi.instance_code, pi.instance_name,
                       p.source_group_order, p.source_condition_order,
                       ROW_NUMBER() OVER (PARTITION BY pi.practice_instance_id
                                          ORDER BY p.source_group_order, p.source_condition_order) AS rn
                FROM @picked p
                CROSS APPLY grac_practice.fn_org_assurance_dep_type(@dim_code) dt
                JOIN grac_practice.practice_dependency_resolution r
                     ON r.dependency_type_id     = dt.dependency_type_id
                    AND r.resolved_dependency_id = p.entity_id
                    AND r.organization_id        = @organization_id
                    AND r.is_active              = 1
                JOIN grac_practice.practice_instance pi
                     ON pi.practice_instance_id = r.practice_instance_id
                    AND pi.organization_id      = @organization_id
                    AND pi.status               = N'Active'
            ) x
            WHERE x.rn = 1
              AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_scope_resolution_entity e
                               WHERE e.org_assurance_scope_resolution_id = @resolution_id_out
                                 AND e.dimension_code = N'PRACTICE_INSTANCE'
                                 AND e.entity_id      = x.practice_instance_id);
        END
        ELSE
            INSERT INTO grac_practice.org_assurance_scope_resolution_entity
                (org_assurance_scope_resolution_id, organization_id,
                 dimension_code, dimension_name,
                 entity_id, entity_code, entity_name,
                 source_group_order, source_condition_order)
            SELECT @resolution_id_out, @organization_id,
                   @dim_code, @dim_name,
                   p.entity_id, p.entity_code, p.entity_name,
                   p.source_group_order, p.source_condition_order
            FROM @picked p
            -- 534: a practice instance a statement already brought in is
            -- not added a second time. Other dimensions as before.
            WHERE NOT (@dim_code = N'PRACTICE_INSTANCE'
                       AND EXISTS (SELECT 1 FROM grac_practice.org_assurance_scope_resolution_entity e
                                    WHERE e.org_assurance_scope_resolution_id = @resolution_id_out
                                      AND e.dimension_code = N'PRACTICE_INSTANCE'
                                      AND e.entity_id      = p.entity_id));

        FETCH NEXT FROM dim_cur INTO @dim_code, @dim_name;
    END
    CLOSE dim_cur; DEALLOCATE dim_cur;

    -- 5) Update header totals + summary JSON (per-dimension count).
    DECLARE @summary NVARCHAR(MAX);
    SET @summary = (
        SELECT dimension_code AS dimensionCode,
               COUNT(*)        AS entityCount
        FROM grac_practice.org_assurance_scope_resolution_entity
        WHERE org_assurance_scope_resolution_id = @resolution_id_out
        GROUP BY dimension_code
        ORDER BY dimension_code
        FOR JSON PATH);

    DECLARE @total BIGINT = (
        SELECT COUNT_BIG(*) FROM grac_practice.org_assurance_scope_resolution_entity
        WHERE org_assurance_scope_resolution_id = @resolution_id_out);

    UPDATE grac_practice.org_assurance_scope_resolution
    SET total_entity_count = @total,
        summary_json       = @summary
    WHERE org_assurance_scope_resolution_id = @resolution_id_out;

    -- Log to the definition history so the audit trail catches it.
    DECLARE @current_status_id INT = (
        SELECT current_status_id FROM grac_practice.org_assurance_definition
        WHERE org_assurance_definition_id = @definition_id);

    INSERT INTO grac_practice.org_assurance_definition_history
        (org_assurance_definition_id, org_assurance_definition_version_id,
         organization_id, action_code, from_status_id, to_status_id,
         reason_text, actor_display_name, entered_by)
    VALUES
        (@definition_id, @version_id, @organization_id,
         CASE WHEN @resolution_purpose = N'PREVIEW' THEN N'SCOPE_RESOLVE_PREVIEW'
              ELSE N'SCOPE_RESOLVE_EXECUTION' END,
         @current_status_id, @current_status_id,
         CONCAT(N'Scope resolved (', @resolution_purpose, N') -- ', CAST(@total AS NVARCHAR(30)), N' entities'),
         @actor, @actor);

    COMMIT;
END
GO

-- ---------------------------------------------------------------------
-- 5b. sp_org_assurance_definition_version_copy_config (560 body + 562)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_version_copy_config
    @organization_id  BIGINT,
    @from_version_id  BIGINT,
    @to_version_id    BIGINT,
    @swap_root_set_id BIGINT        = NULL,
    @swap_to_set_id   BIGINT        = NULL,
    @actor            NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @from_version_id IS NULL OR @to_version_id IS NULL OR @from_version_id = @to_version_id
        THROW 53849, 'Copy failed: two different versions are required.', 1;

    CREATE TABLE #cfg_group (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);
    CREATE TABLE #cfg_cond  (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);
    CREATE TABLE #cfg_wf    (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);
    CREATE TABLE #cfg_sc    (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);

    -- Scope
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scope_group', @key_column = N'scope_group_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @map_table = N'#cfg_group', @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scope_condition', @key_column = N'scope_condition_id',
         @where = N'src.is_active = 1',
         @source_join = N'JOIN #cfg_group m ON m.old_id = src.scope_group_id', @source_extra = N', m.new_id AS parent_new_id',
         @overrides = N'{"scope_group_id":"src.parent_new_id"}',
         @map_table = N'#cfg_cond', @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scope_condition_value', @key_column = N'scope_condition_value_id',
         @where = N'src.is_active = 1',
         @source_join = N'JOIN #cfg_cond m ON m.old_id = src.scope_condition_id', @source_extra = N', m.new_id AS parent_new_id',
         @overrides = N'{"scope_condition_id":"src.parent_new_id"}',
         @p_actor = @actor;

    -- Question sets (one family optionally moved to a new set version)
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_definition_question_set', @key_column = N'org_assurance_definition_question_set_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @source_join = N'LEFT JOIN grac_practice.org_assurance_question_set f ON f.org_assurance_question_set_id = src.org_assurance_question_set_id',
         @source_extra = N', f.root_question_set_id AS set_root_id',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version","org_assurance_question_set_id":"CASE WHEN @p_root IS NOT NULL AND src.set_root_id = @p_root THEN @p_set ELSE src.org_assurance_question_set_id END"}',
         @p_source = @from_version_id, @p_version = @to_version_id,
         @p_root = @swap_root_set_id, @p_set = @swap_to_set_id, @p_actor = @actor;

    -- Workflow
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_workflow_config', @key_column = N'org_assurance_workflow_config_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @map_table = N'#cfg_wf', @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_workflow_stage', @key_column = N'org_assurance_workflow_stage_id',
         @where = N'src.is_active = 1',
         @source_join = N'JOIN #cfg_wf m ON m.old_id = src.org_assurance_workflow_config_id', @source_extra = N', m.new_id AS parent_new_id',
         @overrides = N'{"org_assurance_workflow_config_id":"src.parent_new_id","org_assurance_definition_version_id":"@p_version"}',
         @p_version = @to_version_id, @p_actor = @actor;

    -- 560: Applicable Frameworks and Audit Mandates (definition details, carried like the configuration)
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_definition_framework', @key_column = N'definition_framework_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_definition_mandate', @key_column = N'definition_mandate_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;

    -- 562: the discovered categories the audit brings in
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scope_category', @key_column = N'scope_category_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;

    -- Scoring
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scoring_config', @key_column = N'org_assurance_scoring_config_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @map_table = N'#cfg_sc', @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scoring_band', @key_column = N'org_assurance_scoring_band_id',
         @where = N'src.is_active = 1',
         @source_join = N'JOIN #cfg_sc m ON m.old_id = src.org_assurance_scoring_config_id', @source_extra = N', m.new_id AS parent_new_id',
         @overrides = N'{"org_assurance_scoring_config_id":"src.parent_new_id","org_assurance_definition_version_id":"@p_version"}',
         @p_version = @to_version_id, @p_actor = @actor;
END
GO

-- ---------------------------------------------------------------------
-- 6. Step 2 -- Discover related GRAC intelligence
--    Result 1: one row per category -- CategoryCode, CategoryName,
--              DisplayOrder, ItemCount, IsIncluded.
--    Result 2: the records -- CategoryCode, RecordId, RecordCode,
--              RecordName, Status, Reason (why it is related).
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_scope_discover
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @version_id      BIGINT = NULL      -- default: the current version
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;

    DECLARE @def_org BIGINT, @current_version_id BIGINT;
    SELECT @def_org = d.organization_id, @current_version_id = d.current_version_id
    FROM grac_practice.org_assurance_definition d
    WHERE d.org_assurance_definition_id = @definition_id AND d.is_active = 1;
    IF @def_org IS NULL THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id THROW 53607, 'Definition belongs to a different organization.', 1;
    IF @version_id IS NULL SET @version_id = @current_version_id;
    IF @version_id IS NULL THROW 53611, 'Definition has no current version.', 1;

    DECLARE @active_rs INT = (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
                               WHERE status_code = N'ACTIVE' OR status_name = N'Active'
                               ORDER BY record_status_id);

    -- Categories, in display order.
    CREATE TABLE #cat (category_code NVARCHAR(40) PRIMARY KEY, category_name NVARCHAR(80), display_order INT);
    INSERT #cat VALUES
        (N'PRACTICE_INSTANCE', N'Practice Instances', 1),
        (N'PRACTICE',          N'Practices',          2),
        (N'CONTROL_STATEMENT', N'Control Statements', 3),
        (N'RISK',              N'Risks',              4),
        (N'GAP',               N'Gaps',               5),
        (N'EXCEPTION',         N'Exceptions',         6),
        (N'ASSET',             N'Assets',             7),
        (N'VENDOR',            N'Vendors',            8);

    -- The version's subjects (explicit picks; a NOT / include-all rule from
    -- the removed Advanced mode is not discovered).
    CREATE TABLE #subj (dimension_code NVARCHAR(60), entity_id BIGINT, entity_name NVARCHAR(240),
                        dependency_type_id INT NULL, dependency_type_name NVARCHAR(120) NULL);
    INSERT #subj (dimension_code, entity_id, entity_name, dependency_type_id, dependency_type_name)
    SELECT DISTINCT dm.dimension_code, v.dimension_entity_id,
           ISNULL(v.dimension_entity_name, N'#' + CAST(v.dimension_entity_id AS NVARCHAR(30))),
           dt.dependency_type_id, dt.dependency_type_name
    FROM grac_practice.org_assurance_scope_group g
    JOIN grac_practice.org_assurance_scope_condition c
         ON c.scope_group_id = g.scope_group_id AND c.is_active = 1 AND c.is_not = 0
    JOIN grac_practice.org_assurance_scope_dimension_master dm ON dm.dimension_id = c.dimension_id
    JOIN grac_practice.org_assurance_scope_condition_value v
         ON v.scope_condition_id = c.scope_condition_id AND v.is_active = 1 AND v.dimension_entity_id IS NOT NULL
    OUTER APPLY grac_practice.fn_org_assurance_dep_type(dm.dimension_code) dt
    WHERE g.org_assurance_definition_version_id = @version_id
      AND g.organization_id = @organization_id
      AND g.is_active = 1;

    -- Practice instances in scope, with why.
    CREATE TABLE #pi (practice_instance_id BIGINT, reason NVARCHAR(400));
    INSERT #pi (practice_instance_id, reason)
    SELECT DISTINCT r.practice_instance_id,
           N'Depends on ' + s.dependency_type_name + N' "' + s.entity_name + N'"'
    FROM #subj s
    JOIN grac_practice.practice_dependency_resolution r
         ON r.dependency_type_id = s.dependency_type_id
        AND r.resolved_dependency_id = s.entity_id
        AND r.organization_id = @organization_id
        AND r.is_active = 1
    JOIN grac_practice.practice_instance pi
         ON pi.practice_instance_id = r.practice_instance_id AND pi.status = N'Active'
    WHERE s.dependency_type_id IS NOT NULL;

    INSERT #pi (practice_instance_id, reason)
    SELECT DISTINCT si.PracticeInstanceId, N'Under control statement "' + s.entity_name + N'"'
    FROM #subj s
    JOIN grac_practice.fn_org_scope_statement_instance(@organization_id) si ON si.StatementId = s.entity_id
    WHERE s.dimension_code = N'SOURCE_STATEMENT';

    INSERT #pi (practice_instance_id, reason)
    SELECT DISTINCT s.entity_id, N'Picked directly'
    FROM #subj s
    WHERE s.dimension_code = N'PRACTICE_INSTANCE';

    CREATE TABLE #inst (practice_instance_id BIGINT PRIMARY KEY, practice_id BIGINT, instance_code NVARCHAR(100),
                        instance_name NVARCHAR(300), status NVARCHAR(30), reason NVARCHAR(MAX));
    INSERT #inst
    SELECT pi.practice_instance_id, pi.practice_id, pi.instance_code, pi.instance_name, pi.status,
           STRING_AGG(CONVERT(NVARCHAR(MAX), x.reason), N'; ')
    FROM (SELECT DISTINCT practice_instance_id, reason FROM #pi) x
    JOIN grac_practice.practice_instance pi
         ON pi.practice_instance_id = x.practice_instance_id AND pi.organization_id = @organization_id
    GROUP BY pi.practice_instance_id, pi.practice_id, pi.instance_code, pi.instance_name, pi.status;

    -- Practices of those instances.
    CREATE TABLE #prac (practice_id BIGINT PRIMARY KEY, practice_code NVARCHAR(100), practice_name NVARCHAR(300),
                        status NVARCHAR(30), instance_codes NVARCHAR(MAX));
    INSERT #prac
    SELECT p.practice_id, p.practice_code, p.practice_name, p.status,
           STRING_AGG(CONVERT(NVARCHAR(MAX), i.instance_code), N', ')
    FROM #inst i
    JOIN grac_practice.practice p ON p.practice_id = i.practice_id
    GROUP BY p.practice_id, p.practice_code, p.practice_name, p.status;

    CREATE TABLE #out (category_code NVARCHAR(40), record_id BIGINT, record_code NVARCHAR(120),
                       record_name NVARCHAR(400), status NVARCHAR(60), reason NVARCHAR(MAX));

    -- Practice instances
    INSERT #out SELECT N'PRACTICE_INSTANCE', practice_instance_id, instance_code, instance_name, status, reason FROM #inst;

    -- Practices
    INSERT #out SELECT N'PRACTICE', practice_id, practice_code, practice_name, status,
                       N'Practice of instance(s) ' + instance_codes FROM #prac;

    -- Control statements: mapped to the instances, or picked as a subject.
    ;WITH st AS (
        SELECT si.StatementId, N'Mapped to instance ' + i.instance_code AS reason
        FROM #inst i
        JOIN grac_practice.fn_org_scope_statement_instance(@organization_id) si ON si.PracticeInstanceId = i.practice_instance_id
        UNION
        SELECT s.entity_id, N'Picked as a subject'
        FROM #subj s WHERE s.dimension_code = N'SOURCE_STATEMENT'
    )
    INSERT #out
    SELECT N'CONTROL_STATEMENT', fs.StatementId, fs.StatementCode, fs.StatementName, NULL,
           STRING_AGG(CONVERT(NVARCHAR(MAX), st.reason), N'; ')
    FROM st
    JOIN grac_practice.fn_org_scope_statement(@organization_id) fs ON fs.StatementId = st.StatementId
    GROUP BY fs.StatementId, fs.StatementCode, fs.StatementName;

    -- Risks: impact a subject (Risk -> Impact Details), or linked to a
    -- practice in scope (treatment mapping, or the risk's own practice).
    ;WITH rk AS (
        SELECT m.risk_register_id,
               N'Impacts ' + s.dependency_type_name + N' "' + s.entity_name + N'"' AS reason
        FROM #subj s
        JOIN grac_practice.risk_dependency_map m
             ON m.dependency_type_id = s.dependency_type_id
            AND m.dependency_object_id = s.entity_id
            AND m.organization_id = @organization_id
            AND m.record_status_id = @active_rs
        WHERE s.dependency_type_id IS NOT NULL
        UNION
        SELECT rpm.risk_register_id, N'Linked to practice ' + p.practice_code
        FROM #prac p
        JOIN grac_practice.risk_practice_map rpm
             ON rpm.practice_id = p.practice_id AND rpm.organization_id = @organization_id
            AND rpm.record_status_id = @active_rs
        UNION
        SELECT rr.risk_register_id, N'Linked to practice ' + p.practice_code
        FROM #prac p
        JOIN grac_practice.risk_register rr
             ON rr.linked_practice_id = p.practice_id AND rr.organization_id = @organization_id
    )
    INSERT #out
    SELECT N'RISK', rr.risk_register_id, NULL, rr.risk_title, rr.status_code,
           STRING_AGG(CONVERT(NVARCHAR(MAX), rk.reason), N'; ')
    FROM rk
    JOIN grac_practice.risk_register rr
         ON rr.risk_register_id = rk.risk_register_id AND rr.organization_id = @organization_id
        AND rr.record_status_id = @active_rs
    GROUP BY rr.risk_register_id, rr.risk_title, rr.status_code;

    -- Gaps (Gap Center) raised against a practice in scope.
    INSERT #out
    SELECT N'GAP', cg.custom_gap_id, NULL, cg.title, cg.status,
           STRING_AGG(CONVERT(NVARCHAR(MAX), N'Raised against practice ' + p.practice_code), N'; ')
    FROM #prac p
    JOIN grac_practice.custom_gap_practice_map gm
         ON gm.practice_id = p.practice_id AND gm.organization_id = @organization_id
        AND gm.record_status_id = @active_rs
    JOIN grac_practice.custom_gap cg
         ON cg.custom_gap_id = gm.custom_gap_id AND cg.organization_id = @organization_id
    GROUP BY cg.custom_gap_id, cg.title, cg.status;

    -- Exceptions raised against a practice in scope.
    INSERT #out
    SELECT N'EXCEPTION', er.exception_request_id, NULL, er.request_title, er.status_code,
           STRING_AGG(CONVERT(NVARCHAR(MAX), N'Raised against practice ' + p.practice_code), N'; ')
    FROM #prac p
    JOIN grac_practice.exception_request_practice ep
         ON ep.practice_id = p.practice_id AND ep.organization_id = @organization_id
        AND ep.record_status_id = @active_rs
    JOIN grac_practice.exception_request er
         ON er.exception_request_id = ep.exception_request_id AND er.organization_id = @organization_id
    GROUP BY er.exception_request_id, er.request_title, er.status_code;

    -- Assets and vendors: picked as a subject, or a dependency of an
    -- instance in scope (Operationalize).
    ;WITH dep AS (
        SELECT UPPER(s.dependency_type_name) AS type_key, s.entity_id AS object_id,
               s.entity_name AS object_name, N'Picked as a subject' AS reason
        FROM #subj s
        WHERE UPPER(s.dependency_type_name) IN (N'ASSET', N'VENDOR')
        UNION
        SELECT UPPER(dt.dependency_type_name), r.resolved_dependency_id, r.resolved_dependency_name,
               N'Instance ' + i.instance_code + N' depends on it'
        FROM #inst i
        JOIN grac_practice.practice_dependency_resolution r
             ON r.practice_instance_id = i.practice_instance_id
            AND r.organization_id = @organization_id AND r.is_active = 1
        JOIN grac_practice.dependency_type_master dt
             ON dt.dependency_type_id = r.dependency_type_id
        WHERE UPPER(dt.dependency_type_name) IN (N'ASSET', N'VENDOR')
    )
    INSERT #out
    SELECT dep.type_key, dep.object_id, NULL, MAX(dep.object_name), NULL,
           STRING_AGG(CONVERT(NVARCHAR(MAX), dep.reason), N'; ')
    FROM dep
    GROUP BY dep.type_key, dep.object_id;

    -- Result 1: categories
    SELECT c.category_code AS CategoryCode,
           c.category_name AS CategoryName,
           c.display_order AS DisplayOrder,
           (SELECT COUNT_BIG(*) FROM #out o WHERE o.category_code = c.category_code) AS ItemCount,
           CAST(ISNULL(sc.is_included, 1) AS BIT) AS IsIncluded
    FROM #cat c
    LEFT JOIN grac_practice.org_assurance_scope_category sc
           ON sc.org_assurance_definition_version_id = @version_id
          AND sc.category_code = c.category_code
          AND sc.is_active = 1
    ORDER BY c.display_order;

    -- Result 2: records
    SELECT o.category_code AS CategoryCode,
           o.record_id     AS RecordId,
           o.record_code   AS RecordCode,
           o.record_name   AS RecordName,
           o.status        AS Status,
           o.reason        AS Reason
    FROM #out o
    JOIN #cat c ON c.category_code = o.category_code
    ORDER BY c.display_order, o.record_code, o.record_name;
END
GO

-- ---------------------------------------------------------------------
-- 7. Save the category flags -- [{ "code": "RISK", "isIncluded": false }]
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_scope_category_save
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @categories_json NVARCHAR(MAX),
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;
    IF @categories_json IS NULL OR ISJSON(@categories_json) = 0
        THROW 53705, 'Categories: invalid list.', 1;

    DECLARE @def_org BIGINT, @version_id BIGINT, @status_code NVARCHAR(60);
    SELECT @def_org = d.organization_id, @version_id = d.current_version_id, @status_code = s.status_code
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s ON s.org_assurance_status_id = d.current_status_id
    WHERE d.org_assurance_definition_id = @definition_id AND d.is_active = 1;
    IF @def_org IS NULL THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id THROW 53607, 'Definition belongs to a different organization.', 1;
    IF @version_id IS NULL THROW 53611, 'Definition has no current version.', 1;
    IF @status_code <> N'Draft'
        THROW 53608, 'Scope can only be edited when the current version is Draft.', 1;

    DECLARE @in TABLE (category_code NVARCHAR(40) PRIMARY KEY, is_included BIT NOT NULL);
    INSERT @in (category_code, is_included)
    SELECT UPPER(LTRIM(RTRIM(x.code))), MAX(CAST(ISNULL(x.isIncluded, 1) AS INT))
    FROM OPENJSON(@categories_json) WITH (code NVARCHAR(40) '$.code', isIncluded BIT '$.isIncluded') x
    WHERE x.code IS NOT NULL
    GROUP BY UPPER(LTRIM(RTRIM(x.code)));

    IF EXISTS (SELECT 1 FROM @in WHERE category_code NOT IN
               (N'PRACTICE_INSTANCE', N'PRACTICE', N'CONTROL_STATEMENT', N'RISK',
                N'GAP', N'EXCEPTION', N'ASSET', N'VENDOR'))
        THROW 53706, 'Unknown scope category.', 1;

    BEGIN TRAN;
    UPDATE sc
       SET sc.is_included = i.is_included, sc.updated_by = @actor, sc.updated_dt = SYSUTCDATETIME()
      FROM grac_practice.org_assurance_scope_category sc
      JOIN @in i ON i.category_code = sc.category_code
     WHERE sc.org_assurance_definition_version_id = @version_id AND sc.is_active = 1;

    INSERT grac_practice.org_assurance_scope_category
        (org_assurance_definition_version_id, organization_id, category_code, is_included, is_active, entered_by, entered_dt)
    SELECT @version_id, @organization_id, i.category_code, i.is_included, 1, @actor, SYSUTCDATETIME()
      FROM @in i
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_scope_category sc
                        WHERE sc.org_assurance_definition_version_id = @version_id
                          AND sc.category_code = i.category_code AND sc.is_active = 1);
    COMMIT;
END
GO

PRINT '562 Scope Builder: audit subjects (dependency types) and discovery installed.';
GO
SET NOEXEC OFF;
GO
