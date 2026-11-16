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
