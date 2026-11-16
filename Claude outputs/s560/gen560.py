import re, sys, os

DB = sys.argv[1]

def body(fname, proc):
    s = open(os.path.join(DB, fname), encoding='utf-8').read()
    m = re.search(r'CREATE OR ALTER PROCEDURE grac_practice\.' + proc + r'\b.*?\nGO\n', s, re.S)
    assert m, (fname, proc)
    return m.group(0)

def rep(s, old, new, count=1):
    n = s.count(old)
    assert n == count, (old[:80], n, count)
    return s.replace(old, new)

save = body('551_question_set_versioning.sql', 'sp_org_assurance_definition_save')
get  = body('119_definition_procs_role_extension.sql', 'sp_org_assurance_definition_get')
copy = body('551_question_set_versioning.sql', 'sp_org_assurance_definition_version_copy_config')

# rollback keeps the originals
orig = {'save': save, 'get': get, 'copy': copy}

# ---------------- save ----------------
save = rep(save,
"""    @assurance_category_name    NVARCHAR(200) = NULL,
    @actor""",
"""    @assurance_category_name    NVARCHAR(200) = NULL,
    @assurance_approach_id      BIGINT        = NULL,   -- 560
    @audit_mandate_ids_json     NVARCHAR(MAX) = NULL,   -- 560: [id, ...]; NULL = leave as is
    @applicable_frameworks_json NVARCHAR(MAX) = NULL,   -- 560: NULL = leave as is
    @actor""")

save = rep(save,
"""    DECLARE @active_record_status_id INT = (""",
"""    -- 560: Assurance Approach (org_assurance_approach_master) -- id in,
    -- code / name kept on the version as of the save.
    DECLARE @assurance_approach_code NVARCHAR(60), @assurance_approach_name NVARCHAR(120);
    IF @assurance_approach_id IS NOT NULL
    BEGIN
        SELECT @assurance_approach_code = approach_code,
               @assurance_approach_name = approach_name
        FROM grac_practice.org_assurance_approach_master
        WHERE assurance_approach_id = @assurance_approach_id AND is_active = 1;
        IF @assurance_approach_code IS NULL
            THROW 53613, 'The selected Assurance Approach does not exist or is inactive.', 1;
    END

    -- 560: Audit Mandates (org_assurance_mandate_master) -- ids in; code /
    -- name kept on each row as of the save.
    IF @audit_mandate_ids_json IS NOT NULL AND ISJSON(@audit_mandate_ids_json) = 0
        THROW 53615, 'Audit Mandate: invalid list.', 1;
    DECLARE @md TABLE (audit_mandate_id BIGINT NOT NULL PRIMARY KEY, display_order INT NOT NULL);
    IF @audit_mandate_ids_json IS NOT NULL
    BEGIN
        INSERT @md (audit_mandate_id, display_order)
        SELECT x.id, MIN(x.ord)
        FROM (SELECT TRY_CAST(j.[value] AS BIGINT) AS id, CAST(j.[key] AS INT) AS ord
              FROM OPENJSON(@audit_mandate_ids_json) j) x
        WHERE x.id IS NOT NULL
        GROUP BY x.id;
        IF EXISTS (SELECT 1 FROM @md m
                   WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_mandate_master mm
                                     WHERE mm.audit_mandate_id = m.audit_mandate_id AND mm.is_active = 1))
            THROW 53615, 'A selected Audit Mandate does not exist or is inactive.', 1;
    END

    -- 560: Applicable Frameworks -- [{ "releaseId": 12 | null, "name": "..." }].
    IF @applicable_frameworks_json IS NOT NULL AND ISJSON(@applicable_frameworks_json) = 0
        THROW 53614, 'Applicable Frameworks: invalid list.', 1;
    DECLARE @fw TABLE (release_id BIGINT NULL, framework_name NVARCHAR(300) NOT NULL, display_order INT NOT NULL);
    IF @applicable_frameworks_json IS NOT NULL
        INSERT @fw (release_id, framework_name, display_order)
        SELECT MIN(x.release_id), x.framework_name, MIN(x.ord)
        FROM (
            SELECT TRY_CAST(JSON_VALUE(j.[value], '$.releaseId') AS BIGINT) AS release_id,
                   LTRIM(RTRIM(CAST(JSON_VALUE(j.[value], '$.name') AS NVARCHAR(300)))) AS framework_name,
                   CAST(j.[key] AS INT) AS ord
            FROM OPENJSON(@applicable_frameworks_json) j
        ) x
        WHERE x.framework_name IS NOT NULL AND x.framework_name <> N''
        GROUP BY x.framework_name;

    DECLARE @active_record_status_id INT = (""")

# new definition insert
save = rep(save,
"""        INSERT INTO grac_practice.org_assurance_definition_version
            (org_assurance_definition_id, organization_id, version_number, version_label,
             description, objective, effective_date,
             assurance_category_id, assurance_category_code, assurance_category_name,
             status_id, is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@definition_id_out, @organization_id, 1, N'1.0',
             @description, @objective, @effective_date,
             @assurance_category_id, @assurance_category_code, @assurance_category_name,
             @draft_status_id, 1, @active_record_status_id, @actor, SYSUTCDATETIME());""",
"""        INSERT INTO grac_practice.org_assurance_definition_version
            (org_assurance_definition_id, organization_id, version_number, version_label,
             description, objective, effective_date,
             assurance_category_id, assurance_category_code, assurance_category_name,
             assurance_approach_id, assurance_approach_code, assurance_approach_name,   -- 560
             status_id, is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@definition_id_out, @organization_id, 1, N'1.0',
             @description, @objective, @effective_date,
             @assurance_category_id, @assurance_category_code, @assurance_category_name,
             @assurance_approach_id, @assurance_approach_code, @assurance_approach_name,
             @draft_status_id, 1, @active_record_status_id, @actor, SYSUTCDATETIME());""")

# draft in-place update
save = rep(save,
"""                assurance_category_name = @assurance_category_name,
                updated_by              = @actor,""",
"""                assurance_category_name = @assurance_category_name,
                assurance_approach_id   = @assurance_approach_id,     -- 560
                assurance_approach_code = @assurance_approach_code,   -- 560
                assurance_approach_name = @assurance_approach_name,   -- 560
                updated_by              = @actor,""")

# new version from Active / Retired
save = rep(save,
"""                 version_label, description, objective, effective_date,
                 assurance_category_id, assurance_category_code, assurance_category_name,
                 status_id, is_active, record_status_id, entered_by, entered_dt)
            VALUES
                (@definition_id, @organization_id, @next_version_number,
                 CAST(@next_version_number AS NVARCHAR(20)) + N'.0',
                 @description, @objective, @effective_date,
                 @assurance_category_id, @assurance_category_code, @assurance_category_name,
                 @draft_status_id,""",
"""                 version_label, description, objective, effective_date,
                 assurance_category_id, assurance_category_code, assurance_category_name,
                 assurance_approach_id, assurance_approach_code, assurance_approach_name,   -- 560
                 status_id, is_active, record_status_id, entered_by, entered_dt)
            VALUES
                (@definition_id, @organization_id, @next_version_number,
                 CAST(@next_version_number AS NVARCHAR(20)) + N'.0',
                 @description, @objective, @effective_date,
                 @assurance_category_id, @assurance_category_code, @assurance_category_name,
                 @assurance_approach_id, @assurance_approach_code, @assurance_approach_name,
                 @draft_status_id,""")

# frameworks written to the version this save produced, before COMMIT
save = rep(save,
"""    COMMIT;
END
GO
""",
"""    -- 560: Applicable Frameworks of the saved version (a new version already
    -- carries the previous list through copy_config; a list sent replaces it).
    IF @applicable_frameworks_json IS NOT NULL
    BEGIN
        UPDATE grac_practice.org_assurance_definition_framework
           SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE org_assurance_definition_version_id = @definition_version_id_out
           AND is_active = 1;

        INSERT INTO grac_practice.org_assurance_definition_framework
            (org_assurance_definition_version_id, organization_id, release_id,
             framework_name, display_order, is_active, entered_by, entered_dt)
        SELECT @definition_version_id_out, @organization_id, f.release_id,
               f.framework_name, f.display_order, 1, @actor, SYSUTCDATETIME()
          FROM @fw f;
    END

    -- 560: Audit Mandates of the saved version (same rule as the frameworks).
    IF @audit_mandate_ids_json IS NOT NULL
    BEGIN
        UPDATE grac_practice.org_assurance_definition_mandate
           SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE org_assurance_definition_version_id = @definition_version_id_out
           AND is_active = 1;

        INSERT INTO grac_practice.org_assurance_definition_mandate
            (org_assurance_definition_version_id, organization_id, audit_mandate_id,
             mandate_code, mandate_name, display_order, is_active, entered_by, entered_dt)
        SELECT @definition_version_id_out, @organization_id, m.audit_mandate_id,
               mm.mandate_code, mm.mandate_name, m.display_order, 1, @actor, SYSUTCDATETIME()
          FROM @md m
          JOIN grac_practice.org_assurance_mandate_master mm ON mm.audit_mandate_id = m.audit_mandate_id;
    END

    COMMIT;
END
GO
""")

# ---------------- get ----------------
get = rep(get,
"""           v.assurance_category_name     AS AssuranceCategoryName,
""",
"""           v.assurance_category_name     AS AssuranceCategoryName,
           v.assurance_approach_id       AS AssuranceApproachId,     -- 560
           v.assurance_approach_code     AS AssuranceApproachCode,   -- 560
           v.assurance_approach_name     AS AssuranceApproachName,   -- 560
""")
get = rep(get,
"""      AND d.is_active = 1;
END
GO
""",
"""      AND d.is_active = 1;

    -- 560: second result set -- Applicable Frameworks of the current version.
    SELECT f.definition_framework_id AS DefinitionFrameworkId,
           f.release_id              AS ReleaseId,
           f.framework_name          AS FrameworkName,
           f.display_order           AS DisplayOrder
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_definition_framework f
         ON f.org_assurance_definition_version_id = d.current_version_id
        AND f.is_active = 1
    WHERE d.organization_id = @organization_id
      AND d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1
    ORDER BY f.display_order, f.framework_name;

    -- 560: third result set -- Audit Mandates of the current version.
    SELECT m.definition_mandate_id AS DefinitionMandateId,
           m.audit_mandate_id      AS AuditMandateId,
           m.mandate_code          AS MandateCode,
           m.mandate_name          AS MandateName,
           m.display_order         AS DisplayOrder
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_definition_mandate m
         ON m.org_assurance_definition_version_id = d.current_version_id
        AND m.is_active = 1
    WHERE d.organization_id = @organization_id
      AND d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1
    ORDER BY m.display_order, m.mandate_name;
END
GO
""")

# ---------------- copy_config ----------------
copy = rep(copy,
"""    -- Scoring
""",
"""    -- 560: Applicable Frameworks and Audit Mandates (definition details, carried like the configuration)
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

    -- Scoring
""")

head = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'head560.sql'), encoding='utf-8').read()
out = head + "\n-- ---------------------------------------------------------------------\n-- 5. sp_org_assurance_definition_save (551 body + 560)\n-- ---------------------------------------------------------------------\n" + save \
    + "\n-- ---------------------------------------------------------------------\n-- 6. sp_org_assurance_definition_get (119 body + 560)\n-- ---------------------------------------------------------------------\n" + get \
    + "\n-- ---------------------------------------------------------------------\n-- 7. sp_org_assurance_definition_version_copy_config (551 body + 560)\n-- ---------------------------------------------------------------------\n" + copy \
    + "\nPRINT '560 Audit Definition: Assurance Approach, Audit Mandates, Applicable Frameworks installed.';\nGO\nSET NOEXEC OFF;\nGO\n"
open(os.path.join(DB, '560_audit_definition_fields.sql'), 'w', encoding='utf-8', newline='\n').write(out)

rb_head = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'rbhead560.sql'), encoding='utf-8').read()
rb = rb_head + "\n-- save: 551 body\n" + orig['save'] + "\n-- get: 119 body\n" + orig['get'] + "\n-- copy_config: 551 body\n" + orig['copy'] \
    + "\nPRINT '560 rollback: procedures back to 551 / 119; approach and mandate lists dropped (tables and columns kept).';\nGO\nSET NOEXEC OFF;\nGO\n"
open(os.path.join(DB, '560_audit_definition_fields_rollback.sql'), 'w', encoding='utf-8', newline='\n').write(rb)
print('ok', len(out), len(rb))
