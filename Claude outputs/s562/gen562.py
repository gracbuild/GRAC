import re, sys, os
DB = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))

def body(fname, proc, kind='PROCEDURE'):
    s = open(os.path.join(DB, fname), encoding='utf-8').read()
    m = re.search(r'CREATE OR ALTER ' + kind + r' grac_practice\.' + proc + r'\b.*?\nGO\n', s, re.S)
    assert m, (fname, proc)
    return m.group(0)

def rep(s, old, new):
    n = s.count(old)
    assert n == 1, (old[:90], n)
    return s.replace(old, new)

vals = body('554_engagement_branch_scope.sql', 'sp_org_assurance_scope_dimension_values')
res  = body('534_audit_scope_source_statements.sql', 'sp_org_assurance_scope_resolve')
copy = body('560_audit_definition_fields.sql', 'sp_org_assurance_definition_version_copy_config')
dlist = body('074_org_assurance_scope_procs.sql', 'sp_org_assurance_scope_dimension_list')
orig = (vals, res, copy)

# ---- values: DEP_<CODE> from the type's source table -------------------
vals = rep(vals, """    -- Unsupported dimension -- return empty rowset with the expected shape.""",
"""    -- 562: an audit subject -- a dependency type's objects (Operationalize),
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

    -- Unsupported dimension -- return empty rowset with the expected shape.""")

# ---- resolve: a subject -> its practice instances -----------------------
res = rep(res, """                                 AND e.entity_id      = x.PracticeInstanceId);
        END
        ELSE
            INSERT INTO grac_practice.org_assurance_scope_resolution_entity""",
"""                                 AND e.entity_id      = x.PracticeInstanceId);
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
            INSERT INTO grac_practice.org_assurance_scope_resolution_entity""")

# ---- copy_config: the category flags ------------------------------------
copy = rep(copy, """    -- Scoring
""", """    -- 562: the discovered categories the audit brings in
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scope_category', @key_column = N'scope_category_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;

    -- Scoring
""")

head = open(os.path.join(HERE, 'head562.sql'), encoding='utf-8').read()
tail = open(os.path.join(HERE, 'tail562.sql'), encoding='utf-8').read()
sec = lambda n, t: "\n-- ---------------------------------------------------------------------\n-- " + n + "\n-- ---------------------------------------------------------------------\n" + t
out = (head
       + sec("3. sp_org_assurance_scope_dimension_values (554 body + 562)", vals)
       + sec("4. sp_org_assurance_scope_resolve (534 body + 562)", res)
       + sec("5b. sp_org_assurance_definition_version_copy_config (560 body + 562)", copy)
       + "\n" + tail
       + "\nPRINT '562 Scope Builder: audit subjects (dependency types) and discovery installed.';\nGO\nSET NOEXEC OFF;\nGO\n")
open(os.path.join(DB, '562_scope_subjects_discovery.sql'), 'w', encoding='utf-8', newline='\n').write(out)

rb = """-- =====================================================================
-- 562 ROLLBACK  Scope Builder subjects and discovery
--
-- Procedures back to 554 (dimension values), 534 (resolve) and 560
-- (copy_config); drops sp_org_assurance_scope_discover,
-- sp_org_assurance_scope_category_save and fn_org_assurance_dep_type;
-- the DEP_<CODE> dimensions are made inactive (a scope that used them
-- keeps its rows). org_assurance_scope_category is kept.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_scope_discover','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_scope_discover;
IF OBJECT_ID('grac_practice.sp_org_assurance_scope_category_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_scope_category_save;
GO

UPDATE grac_practice.org_assurance_scope_dimension_master
   SET is_active = 0, updated_by = N'562_rollback', updated_dt = SYSUTCDATETIME()
 WHERE dimension_code LIKE N'DEP[_]%';
GO
""" + "\n-- dimension list: 074 body\n" + dlist + "\n-- dimension values: 554 body\n" + orig[0] + "\n-- resolve: 534 body\n" + orig[1] + "\n-- copy_config: 560 body\n" + orig[2] + """
IF OBJECT_ID('grac_practice.fn_org_assurance_dep_type','IF') IS NOT NULL
    DROP FUNCTION grac_practice.fn_org_assurance_dep_type;
GO

PRINT '562 rollback done.';
GO
"""
open(os.path.join(DB, '562_scope_subjects_discovery_rollback.sql'), 'w', encoding='utf-8', newline='\n').write(rb)
print('ok', len(out), len(rb))
