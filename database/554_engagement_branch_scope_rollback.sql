-- =====================================================================
-- 554 ROLLBACK -- restores sp_org_assurance_scope_dimension_values (534),
-- sp_org_assurance_plan_item_start_execution and
-- sp_org_assurance_engagement_scope_preview (552); drops
-- sp_org_assurance_scope_resolution_narrow_location. Deploy the pre-554 Api
-- and Web with it (the Api passes @location_id to the preview). The Branch
-- id saved on engagements is kept. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
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
            @team NVARCHAR(200);
    SELECT @item_plan     = i.org_assurance_plan_id,
           @from          = i.scheduled_from,
           @to            = i.scheduled_to,
           @aud_role_id   = i.assigned_auditor_role_id,
           @aud_role_name = i.assigned_auditor_role_name,
           @aud_emp_id    = i.assigned_auditor_employee_id,
           @aud_name      = i.assigned_auditor_name,
           @team          = i.assigned_team_name
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
            @def BIGINT, @ver BIGINT, @eid BIGINT;

    BEGIN TRAN;
    WHILE @n <= @max
    BEGIN
        SELECT @def = definition_id, @ver = version_id FROM @todo WHERE rn = @n;
        SET @eid = NULL;
        EXEC grac_practice.sp_org_assurance_execution_materialize
             @organization_id     = @organization_id,
             @definition_id       = @def,
             @version_id          = @ver,
             @scope_resolution_id = NULL,
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

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_engagement_scope_preview
    @organization_id  BIGINT,
    @plan_item_id     BIGINT        = NULL,
    @definitions_json NVARCHAR(MAX) = NULL,
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

IF OBJECT_ID('grac_practice.sp_org_assurance_scope_resolution_narrow_location','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_scope_resolution_narrow_location;
GO
PRINT '554 rolled back.';
GO
