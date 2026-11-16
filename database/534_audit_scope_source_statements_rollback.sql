-- =====================================================================
-- 534 ROLLBACK  Audit scope: Source Statements
--
-- Restores sp_org_assurance_scope_dimension_values (074 body) and
-- sp_org_assurance_scope_resolve (096 body), drops the tree procedure and
-- the two functions, and sets the SOURCE_STATEMENT dimension inactive.
-- The dimension row is kept (scope conditions reference it by id); its
-- saved picks stay in the scope tables but no longer resolve. Revert the
-- Web / Api files and 272_master_data_seed.sql with it. ASCII-only.
-- Re-runnable.
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

    -- Unsupported dimension -- return empty rowset with the expected shape.
    SELECT CAST(NULL AS BIGINT)      AS Id,
           CAST(NULL AS NVARCHAR(120)) AS Code,
           CAST(NULL AS NVARCHAR(240)) AS Name
    WHERE 1 = 0;
END
GO
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
IF OBJECT_ID('grac_practice.sp_org_assurance_scope_statement_tree','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_scope_statement_tree;
IF OBJECT_ID('grac_practice.fn_org_scope_statement_instance') IS NOT NULL
    DROP FUNCTION grac_practice.fn_org_scope_statement_instance;
IF OBJECT_ID('grac_practice.fn_org_scope_statement') IS NOT NULL
    DROP FUNCTION grac_practice.fn_org_scope_statement;
GO
UPDATE grac_practice.org_assurance_scope_dimension_master
   SET is_active = 0
 WHERE dimension_code = N'SOURCE_STATEMENT';
PRINT 'ROLLBACK 534: SOURCE_STATEMENT dimension set inactive = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO
PRINT 'ROLLBACK 534 complete.';
GO
