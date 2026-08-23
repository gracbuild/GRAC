-- =====================================================================
-- 074 Organization Assurance Scope -- Stage 2 stored procedures
--
-- Depends on:
--   * 069 (org_assurance_definition schema)
--   * 070 (definition procs -- for the "Draft only" edit rule)
--   * 073 (scope schema)
--
-- Procedures:
--   sp_org_assurance_scope_dimension_list      Dimension master feed
--   sp_org_assurance_scope_dimension_values    Value picker for a
--                                              given dimension_code +
--                                              organization
--   sp_org_assurance_scope_get                 Full scope tree for a
--                                              definition version
--                                              (3 result sets)
--   sp_org_assurance_scope_save                Replaces scope from a
--                                              JSON tree. Enforces
--                                              "Draft only" edit rule
--                                              and org isolation.
--
-- Rollback: database/074_org_assurance_scope_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_scope_dimension_master','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_scope_group','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_scope_condition','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_scope_condition_value','U') IS NULL
BEGIN
    RAISERROR('074: run 073 scope schema first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_org_assurance_scope_dimension_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_scope_dimension_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT dimension_id    AS DimensionId,
           dimension_code   AS DimensionCode,
           dimension_name   AS DimensionName,
           category         AS Category,
           is_pickable      AS IsPickable,
           display_order    AS DisplayOrder
    FROM grac_practice.org_assurance_scope_dimension_master
    WHERE is_active = 1
    ORDER BY display_order, dimension_id;
END
GO

-- =====================================================================
-- sp_org_assurance_scope_dimension_values
--   Routes to the correct PM lookup for the requested dimension.
--   Unsupported dimensions return an empty rowset -- the API surfaces
--   this as "picker not yet available" without erroring.
-- =====================================================================
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

    -- Unsupported dimension -- return empty rowset with the expected shape.
    SELECT CAST(NULL AS BIGINT)      AS Id,
           CAST(NULL AS NVARCHAR(120)) AS Code,
           CAST(NULL AS NVARCHAR(240)) AS Name
    WHERE 1 = 0;
END
GO

-- =====================================================================
-- sp_org_assurance_scope_get
--   Returns three result sets: groups, conditions, values -- keyed so
--   the API service can reassemble the tree. @version_id is optional;
--   when NULL, resolves to the definition's current_version_id.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_scope_get
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @version_id      BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;

    -- Validate ownership + resolve current version if needed.
    DECLARE @def_org BIGINT, @current_version_id BIGINT, @current_status_code NVARCHAR(60);

    SELECT @def_org             = d.organization_id,
           @current_version_id  = d.current_version_id,
           @current_status_code = s.status_code
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    WHERE d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    IF @def_org IS NULL
        THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id
        THROW 53607, 'Definition belongs to a different organization.', 1;

    IF @version_id IS NULL SET @version_id = @current_version_id;

    -- Header row (returned first so the caller has scope-context info).
    SELECT @definition_id       AS DefinitionId,
           @version_id          AS VersionId,
           @current_version_id  AS CurrentVersionId,
           @current_status_code AS CurrentStatusCode,
           CAST(CASE WHEN @current_status_code = N'Draft'
                     AND @version_id = @current_version_id
                     THEN 1 ELSE 0 END AS BIT) AS IsEditable;

    -- Groups.
    SELECT g.scope_group_id     AS ScopeGroupId,
           g.group_operator     AS GroupOperator,
           g.group_order        AS GroupOrder,
           g.group_label        AS GroupLabel
    FROM grac_practice.org_assurance_scope_group g
    WHERE g.organization_id = @organization_id
      AND g.org_assurance_definition_version_id = @version_id
      AND g.is_active = 1
    ORDER BY g.group_order, g.scope_group_id;

    -- Conditions.
    SELECT c.scope_condition_id  AS ScopeConditionId,
           c.scope_group_id      AS ScopeGroupId,
           c.dimension_id        AS DimensionId,
           dm.dimension_code     AS DimensionCode,
           dm.dimension_name     AS DimensionName,
           c.is_not              AS IsNot,
           c.condition_operator  AS ConditionOperator,
           c.condition_order     AS ConditionOrder,
           c.include_all         AS IncludeAll
    FROM grac_practice.org_assurance_scope_condition c
    JOIN grac_practice.org_assurance_scope_group g
         ON g.scope_group_id = c.scope_group_id
    JOIN grac_practice.org_assurance_scope_dimension_master dm
         ON dm.dimension_id = c.dimension_id
    WHERE c.organization_id = @organization_id
      AND g.org_assurance_definition_version_id = @version_id
      AND c.is_active = 1
    ORDER BY g.group_order, c.condition_order, c.scope_condition_id;

    -- Values.
    SELECT v.scope_condition_value_id  AS ScopeConditionValueId,
           v.scope_condition_id        AS ScopeConditionId,
           v.dimension_entity_id       AS DimensionEntityId,
           v.dimension_entity_code     AS DimensionEntityCode,
           v.dimension_entity_name     AS DimensionEntityName
    FROM grac_practice.org_assurance_scope_condition_value v
    JOIN grac_practice.org_assurance_scope_condition c
         ON c.scope_condition_id = v.scope_condition_id
    JOIN grac_practice.org_assurance_scope_group g
         ON g.scope_group_id = c.scope_group_id
    WHERE v.organization_id = @organization_id
      AND g.org_assurance_definition_version_id = @version_id
      AND v.is_active = 1
    ORDER BY v.scope_condition_id, v.scope_condition_value_id;
END
GO

-- =====================================================================
-- sp_org_assurance_scope_save
--   Replaces scope for the current Draft version. Rejects the write
--   if the current version is not Draft.
--
--   @scope_json shape:
--   {
--     "groups": [
--       {
--         "groupOperator": "AND",
--         "groupOrder": 1,
--         "groupLabel": null,
--         "conditions": [
--           {
--             "dimensionCode": "DEPARTMENT",
--             "isNot": false,
--             "conditionOperator": "AND",
--             "conditionOrder": 1,
--             "includeAll": false,
--             "values": [
--               { "entityId": 42, "entityCode": "OPS", "entityName": "Operations" }
--             ]
--           }
--         ]
--       }
--     ]
--   }
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_scope_save
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @scope_json      NVARCHAR(MAX),
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;
    IF @scope_json IS NULL SET @scope_json = N'{"groups":[]}';
    IF ISJSON(@scope_json) = 0
        THROW 53703, 'scope_json is not a valid JSON document.', 1;

    -- Ownership + Draft-only enforcement.
    DECLARE @def_org BIGINT, @current_version_id BIGINT, @current_status_code NVARCHAR(60);

    SELECT @def_org             = d.organization_id,
           @current_version_id  = d.current_version_id,
           @current_status_code = s.status_code
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    WHERE d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    IF @def_org IS NULL
        THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id
        THROW 53607, 'Definition belongs to a different organization.', 1;
    IF @current_version_id IS NULL
        THROW 53611, 'Definition has no current version.', 1;
    IF @current_status_code <> N'Draft'
        THROW 53608, 'Scope can only be edited when the current version is Draft.', 1;

    BEGIN TRAN;

    -- Wipe existing scope for this version. Hard delete is safe: history
    -- of past *executions* references execution snapshots (Stage 3), NOT
    -- the live scope rows.
    DELETE v
      FROM grac_practice.org_assurance_scope_condition_value v
      JOIN grac_practice.org_assurance_scope_condition c ON c.scope_condition_id = v.scope_condition_id
      JOIN grac_practice.org_assurance_scope_group g     ON g.scope_group_id     = c.scope_group_id
     WHERE g.org_assurance_definition_version_id = @current_version_id
       AND g.organization_id = @organization_id;

    DELETE c
      FROM grac_practice.org_assurance_scope_condition c
      JOIN grac_practice.org_assurance_scope_group g ON g.scope_group_id = c.scope_group_id
     WHERE g.org_assurance_definition_version_id = @current_version_id
       AND g.organization_id = @organization_id;

    DELETE FROM grac_practice.org_assurance_scope_group
     WHERE org_assurance_definition_version_id = @current_version_id
       AND organization_id = @organization_id;

    -- Rehydrate from JSON. OPENJSON keeps the loop straight-line.
    DECLARE @gt TABLE(
        rowid INT IDENTITY(1,1) PRIMARY KEY,
        group_operator NVARCHAR(10),
        group_order    INT,
        group_label    NVARCHAR(200),
        conditions_json NVARCHAR(MAX));

    INSERT INTO @gt(group_operator, group_order, group_label, conditions_json)
    SELECT COALESCE(NULLIF(g.groupOperator, N''), N'AND'),
           g.groupOrder,
           g.groupLabel,
           g.conditions
    FROM OPENJSON(@scope_json, N'$.groups')
    WITH (
        groupOperator NVARCHAR(10)  '$.groupOperator',
        groupOrder    INT           '$.groupOrder',
        groupLabel    NVARCHAR(200) '$.groupLabel',
        conditions    NVARCHAR(MAX) '$.conditions' AS JSON
    ) g;

    DECLARE @rowid INT = 0, @max_rowid INT = (SELECT ISNULL(MAX(rowid), 0) FROM @gt);
    DECLARE @scope_group_id BIGINT;

    WHILE @rowid < @max_rowid
    BEGIN
        SET @rowid = @rowid + 1;

        DECLARE @grp_op NVARCHAR(10), @grp_order INT, @grp_label NVARCHAR(200), @conds NVARCHAR(MAX);
        SELECT @grp_op    = group_operator,
               @grp_order = group_order,
               @grp_label = group_label,
               @conds     = conditions_json
        FROM @gt WHERE rowid = @rowid;

        IF @grp_op NOT IN (N'AND', N'OR') SET @grp_op = N'AND';
        IF @grp_order IS NULL SET @grp_order = @rowid;

        INSERT INTO grac_practice.org_assurance_scope_group
            (org_assurance_definition_id, org_assurance_definition_version_id,
             organization_id, group_operator, group_order, group_label,
             is_active, entered_by)
        VALUES
            (@definition_id, @current_version_id, @organization_id,
             @grp_op, @grp_order, @grp_label, 1, @actor);
        SET @scope_group_id = SCOPE_IDENTITY();

        -- Conditions in this group.
        IF @conds IS NOT NULL AND ISJSON(@conds) = 1
        BEGIN
            DECLARE @ct TABLE(
                crow INT IDENTITY(1,1) PRIMARY KEY,
                dimension_code NVARCHAR(60),
                is_not BIT,
                condition_operator NVARCHAR(10),
                condition_order INT,
                include_all BIT,
                values_json NVARCHAR(MAX));
            DELETE FROM @ct;

            INSERT INTO @ct(dimension_code, is_not, condition_operator, condition_order, include_all, values_json)
            SELECT c.dimensionCode,
                   ISNULL(c.isNot, 0),
                   COALESCE(NULLIF(c.conditionOperator, N''), N'AND'),
                   c.conditionOrder,
                   ISNULL(c.includeAll, 0),
                   c.valuesJson
            FROM OPENJSON(@conds)
            WITH (
                dimensionCode     NVARCHAR(60)  '$.dimensionCode',
                isNot             BIT           '$.isNot',
                conditionOperator NVARCHAR(10)  '$.conditionOperator',
                conditionOrder    INT           '$.conditionOrder',
                includeAll        BIT           '$.includeAll',
                valuesJson        NVARCHAR(MAX) '$.values' AS JSON
            ) c;

            DECLARE @crow INT = 0, @max_crow INT = (SELECT ISNULL(MAX(crow), 0) FROM @ct);
            DECLARE @scope_condition_id BIGINT;

            WHILE @crow < @max_crow
            BEGIN
                SET @crow = @crow + 1;

                DECLARE @dim_code NVARCHAR(60), @is_not BIT, @cond_op NVARCHAR(10),
                        @cond_order INT, @inc_all BIT, @vals NVARCHAR(MAX),
                        @dimension_id INT;

                SELECT @dim_code   = dimension_code,
                       @is_not     = is_not,
                       @cond_op    = condition_operator,
                       @cond_order = condition_order,
                       @inc_all    = include_all,
                       @vals       = values_json
                FROM @ct WHERE crow = @crow;

                IF @cond_op NOT IN (N'AND', N'OR') SET @cond_op = N'AND';
                IF @cond_order IS NULL SET @cond_order = @crow;

                SELECT @dimension_id = dimension_id
                FROM grac_practice.org_assurance_scope_dimension_master
                WHERE dimension_code = @dim_code AND is_active = 1;

                IF @dimension_id IS NULL
                BEGIN
                    ROLLBACK;
                    THROW 53704, 'Unknown or inactive dimension_code in scope JSON.', 1;
                END

                INSERT INTO grac_practice.org_assurance_scope_condition
                    (scope_group_id, organization_id, dimension_id, is_not,
                     condition_operator, condition_order, include_all,
                     is_active, entered_by)
                VALUES
                    (@scope_group_id, @organization_id, @dimension_id, ISNULL(@is_not, 0),
                     @cond_op, @cond_order, ISNULL(@inc_all, 0),
                     1, @actor);
                SET @scope_condition_id = SCOPE_IDENTITY();

                IF ISNULL(@inc_all, 0) = 0 AND @vals IS NOT NULL AND ISJSON(@vals) = 1
                BEGIN
                    INSERT INTO grac_practice.org_assurance_scope_condition_value
                        (scope_condition_id, organization_id,
                         dimension_entity_id, dimension_entity_code, dimension_entity_name,
                         is_active, entered_by)
                    SELECT @scope_condition_id, @organization_id,
                           x.entityId, x.entityCode, x.entityName,
                           1, @actor
                    FROM OPENJSON(@vals)
                    WITH (
                        entityId   BIGINT        '$.entityId',
                        entityCode NVARCHAR(120) '$.entityCode',
                        entityName NVARCHAR(240) '$.entityName'
                    ) x;
                END
            END
        END
    END

    -- Track the scope edit in the definition history log.
    DECLARE @current_status_id INT = (
        SELECT current_status_id FROM grac_practice.org_assurance_definition
        WHERE org_assurance_definition_id = @definition_id);

    INSERT INTO grac_practice.org_assurance_definition_history
        (org_assurance_definition_id, org_assurance_definition_version_id,
         organization_id, action_code, from_status_id, to_status_id,
         reason_text, actor_display_name, entered_by)
    VALUES
        (@definition_id, @current_version_id, @organization_id,
         N'SCOPE_EDIT', @current_status_id, @current_status_id,
         N'Scope saved', @actor, @actor);

    -- Bump the definition updated_by/dt so list screens can sort by
    -- recency without joining scope tables.
    UPDATE grac_practice.org_assurance_definition
    SET updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_definition_id = @definition_id;

    COMMIT;
END
GO

PRINT '074 Organization Assurance Scope procedures deployed.';
GO
