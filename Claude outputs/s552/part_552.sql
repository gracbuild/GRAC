-- =====================================================================
-- 5. sp_org_assurance_engagement_definition_list -- the audits of one
--    engagement, each with its plannable flag and latest execution.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_engagement_definition_list
    @organization_id BIGINT,
    @plan_item_id    BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @plan_item_id IS NULL
        THROW 53902, 'organization_id and plan_item_id are required.', 1;

    SELECT ed.org_assurance_engagement_definition_id AS EngagementDefinitionId,
           ed.org_assurance_definition_id AS DefinitionId,
           d.definition_code              AS DefinitionCode,
           d.definition_name              AS DefinitionName,
           ed.display_order               AS DisplayOrder,
           s.status_code                  AS DefinitionStatusCode,
           s.status_name                  AS DefinitionStatusName,
           av.version_number              AS ActiveVersionNumber,
           CAST(CASE WHEN d.active_version_id IS NOT NULL AND s.status_code <> N'Retired'
                     THEN 1 ELSE 0 END AS BIT) AS IsPlannable,
           ex.org_assurance_execution_id  AS ExecutionId,
           ex.execution_code              AS ExecutionCode,
           ex.status_code                 AS ExecutionStatusCode,
           ex.status_name                 AS ExecutionStatusName
      FROM grac_practice.org_assurance_engagement_definition ed
      JOIN grac_practice.org_assurance_plan_item i
           ON i.org_assurance_plan_item_id = ed.org_assurance_plan_item_id
      JOIN grac_practice.org_assurance_definition d
           ON d.org_assurance_definition_id = ed.org_assurance_definition_id
      JOIN grac_practice.org_assurance_status_master s
           ON s.org_assurance_status_id = d.current_status_id
      LEFT JOIN grac_practice.org_assurance_definition_version av
           ON av.org_assurance_definition_version_id = d.active_version_id
      OUTER APPLY (
          SELECT TOP 1 e.org_assurance_execution_id, e.execution_code, es.status_code, es.status_name
            FROM grac_practice.org_assurance_execution e
            JOIN grac_practice.org_assurance_execution_status_master es
                 ON es.org_assurance_execution_status_id = e.execution_status_id
           WHERE e.org_assurance_plan_item_id = ed.org_assurance_plan_item_id
             AND e.org_assurance_definition_id = ed.org_assurance_definition_id
             AND e.is_active = 1
           ORDER BY CASE WHEN es.status_code = N'Cancelled' THEN 1 ELSE 0 END,
                    e.org_assurance_execution_id DESC) ex
     WHERE ed.org_assurance_plan_item_id = @plan_item_id
       AND ed.organization_id = @organization_id
       AND ed.is_active = 1
       AND i.is_active = 1
     ORDER BY ed.display_order, ed.org_assurance_engagement_definition_id;
END
GO

-- =====================================================================
-- 6. sp_org_assurance_plan_item_start_execution (rewritten by 552)
--    One execution per audit of the engagement that has none live and can
--    be executed -- its ACTIVE version (551) -- with the engagement's dates,
--    auditor (owner) and team. All in one transaction (materialize and the
--    resolver it calls run no ROLLBACK of their own, so they nest).
--    Returns one row per execution started; @execution_id_out is the first.
-- =====================================================================
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

-- =====================================================================
-- 7. sp_org_assurance_engagement_scope_preview -- View Scope (live).
--    Each audit's scope is resolved by the existing resolver (PREVIEW, its
--    Active version, else its current one) inside a transaction that is
--    ROLLED BACK: nothing is saved, not even the preview history line. The
--    entities are kept in a table variable (unaffected by the rollback).
--    @plan_item_id: a saved engagement. @definitions_json
--    ([{"definitionId": 1}, ...]): an unsaved pick (the engagement dialog).
--    Result 1: per dimension, the entity count. Result 2: the entities with
--    the audits that bring each one in.
-- =====================================================================
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

