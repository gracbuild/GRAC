-- =====================================================================
-- 554  An engagement's Branch narrows its scope (branch audit)
--
-- REQUEST (2026-11-14, sir)
--   "If we need to audit a branch, can we do it today?" -- no: the
--   engagement's Branch was free text, used by nothing, and the scope has
--   no branch filter. Decisions (sir): a branch IS a Location (Location
--   master); a practice instance belongs to a branch through its LOCATION
--   dependency resolved in Operationalize.
--
-- MODEL
--   The audit definition's scope stays the full set. An engagement with a
--   Branch (organization_location) audits only what is at that branch:
--     PRACTICE_INSTANCE  kept when an active practice_dependency_resolution
--                        row of type LOCATION points at the branch (the
--                        415 View Data Scope rule)
--     ASSET              kept when organization_dependency_asset.location_id
--                        is the branch
--     anything else      (departments, vendors, legacy dimensions) kept
--   Narrowing only removes; it never adds.
--
-- WHAT THIS DOES
--   1. NEW sp_org_assurance_scope_resolution_narrow_location(@organization_id,
--      @resolution_id, @location_id): narrows a resolved snapshot and
--      recomputes its totals. No transaction of its own, no ROLLBACK --
--      nests in the callers' transactions.
--   2. sp_org_assurance_scope_dimension_values (534 body) + BRANCH: the
--      organization's active Locations (the engagement's Branch picker,
--      GET scope-dimensions/BRANCH/values). BRANCH stays non-pickable, so
--      the Scope Builder is unchanged.
--   3. sp_org_assurance_plan_item_start_execution (552 body): with a
--      Branch, each audit's scope is resolved (EXECUTION), narrowed and
--      handed to materialize as its snapshot (materialize unchanged). An
--      audit with nothing at the branch stops the start: 53942.
--   4. sp_org_assurance_engagement_scope_preview (552 body): View Scope
--      narrowed the same way -- a saved engagement by its own Branch, an
--      unsaved pick by @location_id.
--   Engagements saved before 554 carry only a Branch NAME (free text): no
--   id, so they are not narrowed; the dialog shows them as text only.
--
-- ERRORS: 53939 ids required; 53940 the branch is not a Location of the
--   organization; 53941 scope snapshot not found; 53942 an audit has
--   nothing in scope at the branch.
-- DEPENDS ON: 534, 545, 552.
-- Rollback: 554_engagement_branch_scope_rollback.sql.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_engagement_definition','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_assurance_engagement_scope_preview','P') IS NULL
   OR OBJECT_ID('grac_practice.fn_org_scope_statement_instance','IF') IS NULL
      AND OBJECT_ID('grac_practice.fn_org_scope_statement_instance','TF') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_plan_item','assigned_branch_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','location_id') IS NULL
BEGIN
    PRINT 'ABORT (554): run 534, 545 and 552 first. Nothing was changed.';
    RAISERROR('554_engagement_branch_scope: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Narrow a resolved scope to one branch (Location)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_scope_resolution_narrow_location
    @organization_id BIGINT,
    @resolution_id   BIGINT,
    @location_id     BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @resolution_id IS NULL OR @location_id IS NULL
        THROW 53939, 'organization_id, resolution_id and location_id are required.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_location
                    WHERE location_id = @location_id AND organization_id = @organization_id)
        THROW 53940, 'The branch is not a Location of this organization.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_scope_resolution
                    WHERE org_assurance_scope_resolution_id = @resolution_id
                      AND organization_id = @organization_id)
        THROW 53941, 'Scope snapshot not found.', 1;

    -- Practice instances: linked to the Location in Operationalize.
    DELETE e
      FROM grac_practice.org_assurance_scope_resolution_entity e
     WHERE e.org_assurance_scope_resolution_id = @resolution_id
       AND e.dimension_code = N'PRACTICE_INSTANCE'
       AND NOT EXISTS (
            SELECT 1
              FROM grac_practice.practice_dependency_resolution r
              JOIN grac_practice.dependency_type_master dt
                ON dt.dependency_type_id = r.dependency_type_id
               AND (dt.dependency_type_code = N'LOCATION' OR dt.dependency_type_name = N'Location')
             WHERE r.practice_instance_id   = e.entity_id
               AND r.organization_id        = @organization_id
               AND r.is_active              = 1
               AND r.resolved_dependency_id = @location_id);

    -- Assets: at the Location.
    DELETE e
      FROM grac_practice.org_assurance_scope_resolution_entity e
     WHERE e.org_assurance_scope_resolution_id = @resolution_id
       AND e.dimension_code = N'ASSET'
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                        WHERE a.asset_id = e.entity_id AND a.location_id = @location_id);

    -- Totals, as the resolver writes them.
    DECLARE @summary NVARCHAR(MAX) = (
        SELECT dimension_code AS dimensionCode, COUNT(*) AS entityCount
          FROM grac_practice.org_assurance_scope_resolution_entity
         WHERE org_assurance_scope_resolution_id = @resolution_id
         GROUP BY dimension_code
         ORDER BY dimension_code
           FOR JSON PATH);
    DECLARE @total BIGINT = (
        SELECT COUNT_BIG(*) FROM grac_practice.org_assurance_scope_resolution_entity
         WHERE org_assurance_scope_resolution_id = @resolution_id);

    UPDATE grac_practice.org_assurance_scope_resolution
       SET total_entity_count = @total,
           summary_json       = @summary
     WHERE org_assurance_scope_resolution_id = @resolution_id;
END
GO

-- 2. Branch list (534 body + 554)
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

    -- Unsupported dimension -- return empty rowset with the expected shape.
    SELECT CAST(NULL AS BIGINT)      AS Id,
           CAST(NULL AS NVARCHAR(120)) AS Code,
           CAST(NULL AS NVARCHAR(240)) AS Name
    WHERE 1 = 0;
END
GO

-- 3. Start execution (552 body + 554)
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_item_start_execution
    @organization_id  BIGINT,
    @plan_id          BIGINT,
    @plan_item_id     BIGINT,
    @actor            NVARCHAR(100) = 'system',
    @execution_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @plan_id IS NULL OR @plan_item_id IS NULL
        THROW 53902, 'organization_id, plan_id and plan_item_id are required.', 1;

    DECLARE @item_plan BIGINT,
            @from DATE, @to DATE,
            @aud_role_id BIGINT, @aud_role_name NVARCHAR(120),
            @aud_emp_id BIGINT, @aud_name NVARCHAR(240),
            @team NVARCHAR(200),
            @branch_id BIGINT, @branch_name NVARCHAR(200);   -- 554
    SELECT @item_plan     = i.org_assurance_plan_id,
           @from          = i.scheduled_from,
           @to            = i.scheduled_to,
           @aud_role_id   = i.assigned_auditor_role_id,
           @aud_role_name = i.assigned_auditor_role_name,
           @aud_emp_id    = i.assigned_auditor_employee_id,
           @aud_name      = i.assigned_auditor_name,
           @team          = i.assigned_team_name,
           @branch_id     = i.assigned_branch_id,     -- 554
           @branch_name   = i.assigned_branch_name
      FROM grac_practice.org_assurance_plan_item i
     WHERE i.org_assurance_plan_item_id = @plan_item_id
       AND i.organization_id = @organization_id
       AND i.is_active = 1;

    IF @item_plan IS NULL      THROW 53915, 'Plan item not found.', 1;
    IF @item_plan <> @plan_id  THROW 53916, 'Plan item does not belong to the specified plan.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_plan p
          JOIN grac_practice.org_assurance_plan_status_master s
               ON s.org_assurance_plan_status_id = p.status_id
         WHERE p.org_assurance_plan_id = @plan_id
           AND p.organization_id = @organization_id
           AND p.is_active = 1
           AND s.status_code IN (N'Approved', N'Active'))
        THROW 53935, 'An execution can be started only from an Approved or Active plan.', 1;

    -- The audits to start: active on the engagement, an Active version,
    -- not Retired, and no live execution on this engagement.
    DECLARE @todo TABLE (rn INT IDENTITY(1,1) PRIMARY KEY, definition_id BIGINT NOT NULL, version_id BIGINT NOT NULL);
    INSERT INTO @todo (definition_id, version_id)
    SELECT ed.org_assurance_definition_id, d.active_version_id
      FROM grac_practice.org_assurance_engagement_definition ed
      JOIN grac_practice.org_assurance_definition d
           ON d.org_assurance_definition_id = ed.org_assurance_definition_id
      JOIN grac_practice.org_assurance_status_master s
           ON s.org_assurance_status_id = d.current_status_id
     WHERE ed.org_assurance_plan_item_id = @plan_item_id
       AND ed.is_active = 1
       AND d.active_version_id IS NOT NULL
       AND s.status_code <> N'Retired'
       AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution e
                         JOIN grac_practice.org_assurance_execution_status_master es
                              ON es.org_assurance_execution_status_id = e.execution_status_id
                        WHERE e.org_assurance_plan_item_id = @plan_item_id
                          AND e.org_assurance_definition_id = ed.org_assurance_definition_id
                          AND e.is_active = 1 AND es.status_code <> N'Cancelled')
     ORDER BY ed.display_order, ed.org_assurance_engagement_definition_id;

    IF NOT EXISTS (SELECT 1 FROM @todo)
        THROW 53936, 'Every audit of this engagement has already been started, or none can be executed (no Active version).', 1;

    DECLARE @started TABLE (execution_id BIGINT NOT NULL);
    DECLARE @n INT = 1, @max INT = (SELECT MAX(rn) FROM @todo),
            @def BIGINT, @ver BIGINT, @eid BIGINT,
            @res BIGINT, @def_code NVARCHAR(80), @msg NVARCHAR(400);   -- 554

    BEGIN TRAN;
    WHILE @n <= @max
    BEGIN
        SELECT @def = definition_id, @ver = version_id FROM @todo WHERE rn = @n;
        SET @eid = NULL;
        SET @res = NULL;
        -- 554: the engagement's Branch (a Location) narrows the audit's
        -- scope. The scope is resolved here (EXECUTION), narrowed, and the
        -- snapshot handed to materialize. No branch: materialize resolves
        -- it itself, as before. An audit with nothing left at the branch
        -- stops the start (nothing is created).
        IF @branch_id IS NOT NULL
        BEGIN
            EXEC grac_practice.sp_org_assurance_scope_resolve
                 @organization_id    = @organization_id,
                 @definition_id      = @def,
                 @version_id         = @ver,
                 @resolution_purpose = N'EXECUTION',
                 @execution_id       = NULL,
                 @actor              = @actor,
                 @resolution_id_out  = @res OUTPUT;
            EXEC grac_practice.sp_org_assurance_scope_resolution_narrow_location
                 @organization_id = @organization_id,
                 @resolution_id   = @res,
                 @location_id     = @branch_id;
            IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_scope_resolution_entity
                            WHERE org_assurance_scope_resolution_id = @res)
            BEGIN
                SELECT @def_code = definition_code FROM grac_practice.org_assurance_definition
                 WHERE org_assurance_definition_id = @def;
                SET @msg = CONCAT(N'Audit ', @def_code, N' has nothing in scope at branch ',
                                  ISNULL(@branch_name, N'#' + CAST(@branch_id AS NVARCHAR(20))),
                                  N'. Remove the branch or this audit from the engagement.');
                THROW 53942, @msg, 1;
            END
        END
        EXEC grac_practice.sp_org_assurance_execution_materialize
             @organization_id     = @organization_id,
             @definition_id       = @def,
             @version_id          = @ver,
             @scope_resolution_id = @res,
             @execution_code      = NULL,
             @execution_name      = NULL,
             @origin_type         = N'PLAN',
             @plan_id             = @plan_id,
             @plan_item_id        = @plan_item_id,
             @trigger_config_id   = NULL,
             @planned_start_dt    = @from,
             @planned_end_dt      = @to,
             @owner_role_id       = @aud_role_id,
             @owner_role_name     = @aud_role_name,
             @owner_employee_id   = @aud_emp_id,
             @owner_display_name  = @aud_name,
             @assigned_team_name  = @team,
             @notes               = NULL,
             @actor               = @actor,
             @execution_id_out    = @eid OUTPUT;
        -- 554: a snapshot made here points back at its execution
        -- (materialize does this only for one it resolved itself).
        IF @res IS NOT NULL
            UPDATE grac_practice.org_assurance_scope_resolution
               SET execution_id = @eid
             WHERE org_assurance_scope_resolution_id = @res;
        INSERT INTO @started (execution_id) VALUES (@eid);
        IF @execution_id_out IS NULL SET @execution_id_out = @eid;
        SET @n += 1;
    END
    COMMIT;

    SELECT e.org_assurance_execution_id AS ExecutionId,
           e.execution_code             AS ExecutionCode,
           e.execution_name             AS ExecutionName,
           e.definition_code            AS DefinitionCode,
           e.total_entity_count         AS TotalEntityCount
      FROM grac_practice.org_assurance_execution e
      JOIN @started s ON s.execution_id = e.org_assurance_execution_id
     ORDER BY e.org_assurance_execution_id;
END
GO

-- 4. View Scope (552 body + 554)
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_engagement_scope_preview
    @organization_id  BIGINT,
    @plan_item_id     BIGINT        = NULL,
    @definitions_json NVARCHAR(MAX) = NULL,
    @location_id      BIGINT        = NULL,   -- 554: the branch (unsaved pick)
    @actor            NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL
        THROW 53901, 'organization_id is required.', 1;

    DECLARE @defs TABLE (rn INT IDENTITY(1,1) PRIMARY KEY, definition_id BIGINT NOT NULL,
                         definition_code NVARCHAR(80) NULL, version_id BIGINT NULL);
    IF @definitions_json IS NOT NULL AND ISJSON(@definitions_json) = 1
        INSERT INTO @defs (definition_id, definition_code, version_id)
        SELECT d.org_assurance_definition_id, d.definition_code,
               ISNULL(d.active_version_id, d.current_version_id)
          FROM (SELECT DISTINCT TRY_CAST(JSON_VALUE(j.[value], '$.definitionId') AS BIGINT) AS id
                  FROM OPENJSON(@definitions_json) j) x
          JOIN grac_practice.org_assurance_definition d
               ON d.org_assurance_definition_id = x.id
         WHERE d.organization_id = @organization_id AND d.is_active = 1;
    ELSE IF @plan_item_id IS NOT NULL
        INSERT INTO @defs (definition_id, definition_code, version_id)
        SELECT d.org_assurance_definition_id, d.definition_code,
               ISNULL(d.active_version_id, d.current_version_id)
          FROM grac_practice.org_assurance_engagement_definition ed
          JOIN grac_practice.org_assurance_definition d
               ON d.org_assurance_definition_id = ed.org_assurance_definition_id
         WHERE ed.org_assurance_plan_item_id = @plan_item_id
           AND ed.organization_id = @organization_id
           AND ed.is_active = 1
         ORDER BY ed.display_order;

    -- 554: a saved engagement previews with its own branch; an unsaved
    -- pick (the dialog) with the branch it passes.
    IF NOT (@definitions_json IS NOT NULL AND ISJSON(@definitions_json) = 1)
       AND @plan_item_id IS NOT NULL AND @location_id IS NULL
        SELECT @location_id = i.assigned_branch_id
          FROM grac_practice.org_assurance_plan_item i
         WHERE i.org_assurance_plan_item_id = @plan_item_id
           AND i.organization_id = @organization_id
           AND i.is_active = 1;

    DECLARE @ents TABLE (definition_code NVARCHAR(80) NULL, dimension_code NVARCHAR(60) NULL,
                         dimension_name NVARCHAR(160) NULL, entity_id BIGINT NULL,
                         entity_code NVARCHAR(120) NULL, entity_name NVARCHAR(240) NULL);

    DECLARE @n INT = 1, @max INT = ISNULL((SELECT MAX(rn) FROM @defs), 0),
            @def BIGINT, @code NVARCHAR(80), @ver BIGINT, @res BIGINT;

    BEGIN TRAN;
    WHILE @n <= @max
    BEGIN
        SELECT @def = definition_id, @code = definition_code, @ver = version_id FROM @defs WHERE rn = @n;
        IF @ver IS NOT NULL
        BEGIN
            SET @res = NULL;
            EXEC grac_practice.sp_org_assurance_scope_resolve
                 @organization_id    = @organization_id,
                 @definition_id      = @def,
                 @version_id         = @ver,
                 @resolution_purpose = N'PREVIEW',
                 @execution_id       = NULL,
                 @actor              = @actor,
                 @resolution_id_out  = @res OUTPUT;
            IF @location_id IS NOT NULL                       -- 554
                EXEC grac_practice.sp_org_assurance_scope_resolution_narrow_location
                     @organization_id = @organization_id,
                     @resolution_id   = @res,
                     @location_id     = @location_id;
            INSERT INTO @ents (definition_code, dimension_code, dimension_name, entity_id, entity_code, entity_name)
            SELECT @code, e.dimension_code, e.dimension_name, e.entity_id, e.entity_code, e.entity_name
              FROM grac_practice.org_assurance_scope_resolution_entity e
             WHERE e.org_assurance_scope_resolution_id = @res;
        END
        SET @n += 1;
    END
    ROLLBACK;   -- a preview: nothing the resolver wrote is kept

    ;WITH u AS (
        SELECT dimension_code, MAX(dimension_name) AS dimension_name, entity_id,
               MAX(entity_code) AS entity_code, MAX(entity_name) AS entity_name,
               STRING_AGG(CONVERT(NVARCHAR(MAX), definition_code), N', ') AS definition_codes
          FROM (SELECT DISTINCT definition_code, dimension_code, dimension_name, entity_id, entity_code, entity_name
                  FROM @ents) x
         GROUP BY dimension_code, entity_id
    )
    SELECT dimension_code AS DimensionCode, MAX(dimension_name) AS DimensionName, COUNT(*) AS EntityCount
      FROM u GROUP BY dimension_code ORDER BY dimension_code;

    ;WITH u AS (
        SELECT dimension_code, MAX(dimension_name) AS dimension_name, entity_id,
               MAX(entity_code) AS entity_code, MAX(entity_name) AS entity_name,
               STRING_AGG(CONVERT(NVARCHAR(MAX), definition_code), N', ') AS definition_codes
          FROM (SELECT DISTINCT definition_code, dimension_code, dimension_name, entity_id, entity_code, entity_name
                  FROM @ents) x
         GROUP BY dimension_code, entity_id
    )
    SELECT dimension_code AS DimensionCode, dimension_name AS DimensionName,
           entity_id AS EntityId, entity_code AS EntityCode, entity_name AS EntityName,
           definition_codes AS DefinitionCodes
      FROM u
     ORDER BY dimension_code, entity_name, entity_code;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '554 narrow procedure' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_scope_resolution_narrow_location','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '554 branch list',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_scope_dimension_values')) LIKE '%organization_location%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '554 start execution narrows',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_plan_item_start_execution')) LIKE '%narrow_location%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '554 view scope narrows',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_engagement_scope_preview')) LIKE '%narrow_location%'
            THEN 'PASS' ELSE 'FAIL' END;
PRINT '554 complete. Restart the Api and publish Web; pick a Branch on an engagement to audit that branch.';
GO
SET NOEXEC OFF;
GO
