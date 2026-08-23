-- =====================================================================
-- 096 Organization Assurance Scope Resolution -- Stage 3 procedures
--
-- Depends on 073 (scope schema), 074 (dimension values proc), 095
-- (resolution schema).
--
-- Procedures:
--   sp_org_assurance_scope_resolve
--       Reads the scope tree for a definition version and resolves it
--       into the applicable PM entities per pickable dimension. Writes
--       an immutable snapshot to the resolution tables. Supports two
--       purposes:
--         PREVIEW    ad-hoc "what would run" preview
--         EXECUTION  called by the Stage 4 execution engine
--
--       Semantics for the MVP resolver (Stage 3 first cut):
--         Per dimension D that has ANY condition in the scope:
--           * include_all -> all active entities of D in the org
--           * is_not      -> all active minus the picked values
--           * explicit    -> the picked values
--         Union across all conditions on D (de-duped by entity_id).
--       Full AND/OR/NOT set-ops WITHIN groups + across groups will
--       land in a Stage 3b refinement.
--
--   sp_org_assurance_scope_resolution_list
--   sp_org_assurance_scope_resolution_get
--   sp_org_assurance_scope_resolution_entity_list
--
-- Rollback: 096_org_assurance_scope_resolution_procs_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_scope_resolution','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_scope_resolution_entity','U') IS NULL
BEGIN
    RAISERROR('096: run 095 schema first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_org_assurance_scope_resolve
-- =====================================================================
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
        INSERT INTO grac_practice.org_assurance_scope_resolution_entity
            (org_assurance_scope_resolution_id, organization_id,
             dimension_code, dimension_name,
             entity_id, entity_code, entity_name,
             source_group_order, source_condition_order)
        SELECT @resolution_id_out, @organization_id,
               @dim_code, @dim_name,
               p.entity_id, p.entity_code, p.entity_name,
               p.source_group_order, p.source_condition_order
        FROM @picked p;

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

-- =====================================================================
-- sp_org_assurance_scope_resolution_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_scope_resolution_list
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @version_id      BIGINT = NULL,
    @page            INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    -- Verify org ownership.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_definition
        WHERE org_assurance_definition_id = @definition_id
          AND organization_id = @organization_id)
        THROW 53607, 'Definition belongs to a different organization.', 1;

    DECLARE @offset INT = (@page - 1) * @page_size;

    ;WITH base AS (
        SELECT r.*
        FROM grac_practice.org_assurance_scope_resolution r
        WHERE r.organization_id = @organization_id
          AND r.org_assurance_definition_id = @definition_id
          AND (@version_id IS NULL OR r.org_assurance_definition_version_id = @version_id)
          AND r.is_active = 1
    )
    SELECT CAST(COUNT_BIG(1) AS BIGINT) AS TotalCount,
           CAST(@page      AS INT)      AS PageNumber,
           CAST(@page_size AS INT)      AS PageSize
    FROM base;

    ;WITH base AS (
        SELECT r.org_assurance_scope_resolution_id     AS ResolutionId,
               r.org_assurance_definition_id           AS DefinitionId,
               r.org_assurance_definition_version_id   AS DefinitionVersionId,
               r.resolution_purpose                    AS ResolutionPurpose,
               r.execution_id                          AS ExecutionId,
               r.resolved_at                           AS ResolvedAt,
               r.resolved_by                           AS ResolvedBy,
               r.total_entity_count                    AS TotalEntityCount,
               r.summary_json                          AS SummaryJson,
               r.notes                                 AS Notes
        FROM grac_practice.org_assurance_scope_resolution r
        WHERE r.organization_id = @organization_id
          AND r.org_assurance_definition_id = @definition_id
          AND (@version_id IS NULL OR r.org_assurance_definition_version_id = @version_id)
          AND r.is_active = 1
    )
    SELECT * FROM base
    ORDER BY ResolvedAt DESC, ResolutionId DESC
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- sp_org_assurance_scope_resolution_get
--   Returns 2 result sets: header, per-dimension summary.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_scope_resolution_get
    @organization_id BIGINT,
    @resolution_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @resolution_id IS NULL
        THROW 53602, 'organization_id and resolution_id are required.', 1;

    SELECT r.org_assurance_scope_resolution_id     AS ResolutionId,
           r.org_assurance_definition_id           AS DefinitionId,
           r.org_assurance_definition_version_id   AS DefinitionVersionId,
           r.organization_id                       AS OrganizationId,
           r.resolution_purpose                    AS ResolutionPurpose,
           r.execution_id                          AS ExecutionId,
           r.resolved_at                           AS ResolvedAt,
           r.resolved_by                           AS ResolvedBy,
           r.total_entity_count                    AS TotalEntityCount,
           r.summary_json                          AS SummaryJson,
           r.notes                                 AS Notes
    FROM grac_practice.org_assurance_scope_resolution r
    WHERE r.org_assurance_scope_resolution_id = @resolution_id
      AND r.organization_id = @organization_id
      AND r.is_active = 1;

    -- Summary by dimension
    SELECT dimension_code AS DimensionCode,
           MAX(dimension_name) AS DimensionName,
           COUNT_BIG(*)   AS EntityCount
    FROM grac_practice.org_assurance_scope_resolution_entity
    WHERE org_assurance_scope_resolution_id = @resolution_id
      AND organization_id = @organization_id
    GROUP BY dimension_code
    ORDER BY dimension_code;
END
GO

-- =====================================================================
-- sp_org_assurance_scope_resolution_entity_list
--   Filterable by dimension_code; paginated.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_scope_resolution_entity_list
    @organization_id BIGINT,
    @resolution_id   BIGINT,
    @dimension_code  NVARCHAR(60) = NULL,
    @search          NVARCHAR(200) = NULL,
    @page            INT = 1,
    @page_size       INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @resolution_id IS NULL
        THROW 53602, 'organization_id and resolution_id are required.', 1;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 50;
    IF @page_size > 500 SET @page_size = 500;

    DECLARE @offset INT = (@page - 1) * @page_size;

    ;WITH base AS (
        SELECT e.*
        FROM grac_practice.org_assurance_scope_resolution_entity e
        WHERE e.org_assurance_scope_resolution_id = @resolution_id
          AND e.organization_id = @organization_id
          AND (@dimension_code IS NULL OR e.dimension_code = @dimension_code)
          AND (@search IS NULL OR @search = ''
               OR e.entity_name LIKE N'%' + @search + N'%'
               OR e.entity_code LIKE N'%' + @search + N'%')
    )
    SELECT CAST(COUNT_BIG(1) AS BIGINT) AS TotalCount,
           CAST(@page      AS INT)      AS PageNumber,
           CAST(@page_size AS INT)      AS PageSize
    FROM base;

    ;WITH base AS (
        SELECT e.org_assurance_scope_resolution_entity_id AS EntityRowId,
               e.dimension_code           AS DimensionCode,
               e.dimension_name           AS DimensionName,
               e.entity_id                AS EntityId,
               e.entity_code              AS EntityCode,
               e.entity_name              AS EntityName,
               e.source_group_order       AS SourceGroupOrder,
               e.source_condition_order   AS SourceConditionOrder
        FROM grac_practice.org_assurance_scope_resolution_entity e
        WHERE e.org_assurance_scope_resolution_id = @resolution_id
          AND e.organization_id = @organization_id
          AND (@dimension_code IS NULL OR e.dimension_code = @dimension_code)
          AND (@search IS NULL OR @search = ''
               OR e.entity_name LIKE N'%' + @search + N'%'
               OR e.entity_code LIKE N'%' + @search + N'%')
    )
    SELECT * FROM base
    ORDER BY DimensionCode, EntityName, EntityRowId
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

PRINT '096 Organization Assurance Scope Resolution procedures deployed.';
GO
