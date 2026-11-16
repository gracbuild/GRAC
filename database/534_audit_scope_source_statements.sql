-- =====================================================================
-- 534  Audit scope: Source Statements replace Practice Instances
--
-- REQUEST (2026-11-13, sir)
-- -------------------------
--   Audit Definition -> Scope Details -> "Filter by Practice Instances"
--   lists every practice instance, which is hard to pick from. Pick
--   SOURCE STATEMENTS instead, in a Framework -> Release -> Source
--   Structure -> Source Statement tree, as two lists (available /
--   selected) with >, >>, <, << buttons. Decisions (asked and answered):
--     * "control" = source statement (Practice Management has no Control).
--     * At run time the audit covers the practice instances of the
--       practices mapped to the selected statements (every team).
--     * The Source Statements filter REPLACES Practice Instances.
--     * Moving a framework / release / structure stores its statements
--       as they are today; statements added later are not included.
--
-- WHAT THIS DOES
--   1. New scope dimension SOURCE_STATEMENT ("Control Statements" --
--      sir, 2026-11-13: the filter reads "Filter by Control Statements";
--      Compliance, pickable, display order 2). PRACTICE_INSTANCE is
--      kept, so audits already scoped by practice instance still resolve
--      and still open (the Scope Builder shows them in Advanced mode,
--      marked legacy); the Simple mode shows Source Statements instead.
--   2. fn_org_scope_statement(@org): one row per selectable statement
--      with its framework, release and source structure. Covers
--      repository statements (fn_org_framework_statement, 392) of active
--      subscriptions and custom release statements (347 overlay).
--      StatementId = organization_framework_statements.org_statement_id.
--   3. fn_org_scope_statement_instance(@org): statement -> active
--      practice instances of the practices mapped to it, through either
--      mapping route: organization_requirement.org_statement_id or
--      organization_statement_practice_mapping (031).
--   4. sp_org_assurance_scope_statement_tree: the tree rows, with each
--      statement's practice instance count (Api: GET
--      org-assurance/scope-statement-tree).
--   5. sp_org_assurance_scope_dimension_values re-issued from its 074
--      body plus a SOURCE_STATEMENT branch (flat list).
--   6. sp_org_assurance_scope_resolve re-issued from its 096 body:
--      SOURCE_STATEMENT picks resolve to PRACTICE_INSTANCE snapshot rows,
--      de-duplicated against any instance already in the snapshot.
--      include_all / NOT for statements read the function (no 500 cap).
--
-- NOT DONE
--   * Existing scopes are not converted. A practice-instance pick and a
--     statement pick mean different things (one team vs every team).
--   * The old Control model (organization_control) and the "Organization
--     Defined Practices" container have no source statement, so they are
--     not in the tree.
--   * The scope_save procedure is unchanged: values are stored as before
--     (dimension_entity_id = org_statement_id).
--
-- ALSO EDITED: 272_master_data_seed.sql (dimension row).
-- DEPENDS ON: 073, 074, 095, 096, 031, 347, 392 (and the 392 reader
--             functions), 387 (practice_instance.practice_id use).
-- Rollback: 534_audit_scope_source_statements_rollback.sql
-- Re-runnable: yes. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @missing NVARCHAR(MAX) = N'';
SELECT @missing += N' ' + x.what + N';'
FROM (VALUES
    (N'table org_assurance_scope_dimension_master (073)', CASE WHEN OBJECT_ID('grac_practice.org_assurance_scope_dimension_master','U') IS NULL THEN 1 ELSE 0 END),
    (N'table org_assurance_scope_resolution_entity (095)', CASE WHEN OBJECT_ID('grac_practice.org_assurance_scope_resolution_entity','U') IS NULL THEN 1 ELSE 0 END),
    (N'proc sp_org_assurance_scope_dimension_values (074)', CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_scope_dimension_values','P') IS NULL THEN 1 ELSE 0 END),
    (N'proc sp_org_assurance_scope_resolve (096)', CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_scope_resolve','P') IS NULL THEN 1 ELSE 0 END),
    (N'function fn_org_framework_statement (392)', CASE WHEN OBJECT_ID('grac_practice.fn_org_framework_statement') IS NULL THEN 1 ELSE 0 END),
    (N'function fn_org_source_structure_node (392)', CASE WHEN OBJECT_ID('grac_practice.fn_org_source_structure_node') IS NULL THEN 1 ELSE 0 END),
    (N'table organization_statement_practice_mapping (031)', CASE WHEN OBJECT_ID('grac_practice.organization_statement_practice_mapping','U') IS NULL THEN 1 ELSE 0 END),
    (N'column organization_framework_statements.custom_statement_id (347)', CASE WHEN COL_LENGTH('grac_practice.organization_framework_statements','custom_statement_id') IS NULL THEN 1 ELSE 0 END),
    (N'column organization_requirement.org_statement_id', CASE WHEN COL_LENGTH('grac_practice.organization_requirement','org_statement_id') IS NULL THEN 1 ELSE 0 END),
    (N'table custom_release_statement (001)', CASE WHEN OBJECT_ID('grac_practice.custom_release_statement','U') IS NULL THEN 1 ELSE 0 END),
    (N'table custom_release_source_structure (001/033)', CASE WHEN OBJECT_ID('grac_practice.custom_release_source_structure','U') IS NULL THEN 1 ELSE 0 END),
    (N'column repository_subscription.custom_release_name (001)', CASE WHEN COL_LENGTH('grac_practice.repository_subscription','custom_release_name') IS NULL THEN 1 ELSE 0 END),
    (N'table practice_instance', CASE WHEN OBJECT_ID('grac_practice.practice_instance','U') IS NULL THEN 1 ELSE 0 END),
    (N'tables grac_new.release / artifact / authority', CASE WHEN OBJECT_ID('grac_new.release','U') IS NULL OR OBJECT_ID('grac_new.artifact','U') IS NULL OR OBJECT_ID('grac_new.authority','U') IS NULL THEN 1 ELSE 0 END)
) x(what, is_missing)
WHERE x.is_missing = 1;
IF @missing <> N''
BEGIN
    PRINT 'ABORT (534): missing --' + @missing + ' Nothing was changed.';
    RAISERROR('534_audit_scope_source_statements: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Dimension
-- =====================================================================
MERGE grac_practice.org_assurance_scope_dimension_master AS t
USING (VALUES (N'SOURCE_STATEMENT', N'Control Statements', N'Compliance', 1, 2))
      AS src(dimension_code, dimension_name, category, is_pickable, display_order)
ON t.dimension_code = src.dimension_code
WHEN MATCHED THEN UPDATE SET
    dimension_name = src.dimension_name, category = src.category,
    is_pickable = src.is_pickable, display_order = src.display_order, is_active = 1
WHEN NOT MATCHED THEN INSERT
    (dimension_code, dimension_name, category, is_pickable, display_order, is_active, entered_by)
VALUES
    (src.dimension_code, src.dimension_name, src.category, src.is_pickable, src.display_order, 1, 'seed-534');
PRINT '534: SOURCE_STATEMENT dimension upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 2. fn_org_scope_statement -- the selectable statements, with their
--    framework / release / source structure. Keys are strings so the
--    two sources (repository, custom) cannot collide in the tree.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_org_scope_statement(@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    -- Repository statements of the organisation's active subscriptions.
    SELECT N'A' + CAST(COALESCE(a.artifact_id, -r.release_id) AS NVARCHAR(30))   AS FrameworkKey,
           COALESCE(NULLIF(auth.authority_name, N'') + N' - ', N'')
             + COALESCE(a.artifact_name, a.artifact_code, N'Framework')          AS FrameworkName,
           N'R' + CAST(r.release_id AS NVARCHAR(30))                             AS ReleaseKey,
           COALESCE(NULLIF(a.artifact_code, N'') + N' ', N'')
             + COALESCE(r.version_no, N'Release')                                AS ReleaseName,
           N'N' + CAST(ISNULL(n.structure_node_id, 0) AS NVARCHAR(30))
             + N'-R' + CAST(r.release_id AS NVARCHAR(30))                        AS StructureKey,
           COALESCE(COALESCE(NULLIF(n.node_reference, N'') + N' - ', N'') + n.node_title,
                    N'(no source structure)')                                    AS StructureName,
           ISNULL(n.display_order, 2147483647)                                   AS StructureOrder,
           fs.org_statement_id                                                   AS StatementId,
           fs.statement_reference                                                AS StatementCode,
           fs.statement_title                                                    AS StatementName,
           ISNULL(fs.display_order, 0)                                           AS StatementOrder
    FROM grac_practice.fn_org_framework_statement(@organization_id) fs
    JOIN grac_new.release r        ON r.release_id = fs.release_id
    LEFT JOIN grac_new.artifact a  ON a.artifact_id = r.artifact_id
    LEFT JOIN grac_new.authority auth ON auth.authority_id = a.authority_id
    LEFT JOIN grac_practice.fn_org_source_structure_node(@organization_id) n
           ON n.structure_node_id = fs.structure_node_id
    WHERE fs.status = N'Active'
      AND fs.org_statement_id IS NOT NULL
      AND EXISTS (SELECT 1 FROM grac_practice.repository_subscription s
                   WHERE s.organization_id = @organization_id
                     AND s.release_id      = fs.release_id
                     AND s.status = N'Active'
                     AND ISNULL(s.subscription_status, N'Active') = N'Active')

    UNION ALL

    -- Custom release statements (the 347 overlay row gives them an
    -- org_statement_id, the same id practices are mapped through).
    SELECT N'C'                                                                  AS FrameworkKey,
           N'Custom Releases'                                                    AS FrameworkName,
           N'S' + CAST(s.subscription_id AS NVARCHAR(30))                        AS ReleaseKey,
           COALESCE(NULLIF(s.custom_release_name, N''),
                    N'Custom release ' + CAST(s.subscription_id AS NVARCHAR(30))) AS ReleaseName,
           N'CN' + CAST(ISNULL(cn.structure_node_id, 0) AS NVARCHAR(30))
             + N'-S' + CAST(s.subscription_id AS NVARCHAR(30))                   AS StructureKey,
           COALESCE(COALESCE(NULLIF(cn.node_reference, N'') + N' - ', N'') + cn.node_title,
                    N'(no source structure)')                                    AS StructureName,
           ISNULL(cn.display_order, 2147483647)                                  AS StructureOrder,
           ofs.org_statement_id                                                  AS StatementId,
           cs.statement_reference                                                AS StatementCode,
           cs.statement_title                                                    AS StatementName,
           ISNULL(cs.display_order, 0)                                           AS StatementOrder
    FROM grac_practice.custom_release_statement cs
    JOIN grac_practice.repository_subscription s
         ON s.subscription_id = cs.subscription_id
        AND s.organization_id = @organization_id
        AND s.status = N'Active'
        AND ISNULL(s.subscription_status, N'Active') = N'Active'
    JOIN grac_practice.organization_framework_statements ofs
         ON ofs.source_type = N'Custom'
        AND ofs.custom_statement_id = cs.custom_statement_id
        AND ofs.organization_id = @organization_id
        AND ofs.status = N'Active'
    LEFT JOIN grac_practice.custom_release_source_structure cn
         ON cn.structure_node_id = cs.structure_node_id
        AND cn.status = N'Active'
    WHERE cs.organization_id = @organization_id
      AND cs.status = N'Active';
GO

-- =====================================================================
-- 3. fn_org_scope_statement_instance -- statement -> practice instances.
--    Both mapping routes; UNION removes the overlap.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_org_scope_statement_instance(@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT m.StatementId,
           pi.practice_instance_id AS PracticeInstanceId,
           pi.instance_code        AS InstanceCode,
           pi.instance_name        AS InstanceName
    FROM (
        -- Route 1: the requirement's own statement.
        SELECT q.org_statement_id AS StatementId, q.organization_requirement_id
        FROM grac_practice.organization_requirement q
        WHERE q.organization_id = @organization_id
          AND q.status = N'Active'
          AND q.org_statement_id IS NOT NULL
        UNION
        -- Route 2: the statement -> practice mapping (a practice can sit
        -- under several statements).
        SELECT sm.org_statement_id, sm.org_practice_id
        FROM grac_practice.organization_statement_practice_mapping sm
        WHERE sm.organization_id = @organization_id
          AND sm.status = N'Active'
    ) m
    JOIN grac_practice.practice p
         ON p.organization_requirement_id = m.organization_requirement_id
        AND p.organization_id = @organization_id
        AND p.status = N'Active'
    JOIN grac_practice.practice_instance pi
         ON pi.practice_id = p.practice_id
        AND pi.organization_id = @organization_id
        AND pi.status = N'Active';
GO

-- =====================================================================
-- 4. sp_org_assurance_scope_statement_tree -- the Scope Builder's tree.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_scope_statement_tree
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 53720, 'organization_id is required.', 1;

    SELECT s.FrameworkKey, s.FrameworkName, s.ReleaseKey, s.ReleaseName,
           s.StructureKey, s.StructureName, s.StatementId, s.StatementCode, s.StatementName,
           ISNULL(c.InstanceCount, 0) AS InstanceCount
    FROM grac_practice.fn_org_scope_statement(@organization_id) s
    LEFT JOIN (SELECT StatementId, COUNT(DISTINCT PracticeInstanceId) AS InstanceCount
                 FROM grac_practice.fn_org_scope_statement_instance(@organization_id)
                GROUP BY StatementId) c
           ON c.StatementId = s.StatementId
    ORDER BY s.FrameworkName, s.ReleaseName, s.StructureOrder, s.StructureName,
             s.StatementOrder, s.StatementCode, s.StatementName;
END
GO

-- =====================================================================
-- 5. sp_org_assurance_scope_dimension_values -- 074 body + 534 branch.
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

-- =====================================================================
-- 6. sp_org_assurance_scope_resolve -- 096 body + 534 statement branch.
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

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '534 SOURCE_STATEMENT dimension active and pickable' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.org_assurance_scope_dimension_master
                          WHERE dimension_code = N'SOURCE_STATEMENT' AND is_active = 1 AND is_pickable = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '534 statement functions + tree proc',
       CASE WHEN OBJECT_ID('grac_practice.fn_org_scope_statement') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_org_scope_statement_instance') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_scope_statement_tree','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '534 values proc has the SOURCE_STATEMENT branch',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_scope_dimension_values')) LIKE '%fn_org_scope_statement%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '534 resolver has the SOURCE_STATEMENT branch',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_scope_resolve')) LIKE '%fn_org_scope_statement_instance%'
            THEN 'PASS' ELSE 'FAIL' END;
PRINT '534 complete. Restart the Api, deploy Web, then open Audit Definition -> Scope Details.';
GO
SET NOEXEC OFF;
GO
