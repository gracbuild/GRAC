import re, sys, os
D = sys.argv[1]          # database folder
S = sys.argv[2]          # s551 folder (part files)

def read(f): return open(os.path.join(D, f), encoding='utf-8').read()
def proc(text, name):
    m = re.search(r'CREATE OR ALTER PROCEDURE grac_practice\.' + name + r'\b.*?\nGO\n', text, re.S)
    if not m: raise SystemExit('proc not found: ' + name)
    return m.group(0)
def rep(s, a, b, n=1):
    c = s.count(a)
    if c != n: raise SystemExit('count %d (want %d): %r' % (c, n, a[:90]))
    return s.replace(a, b)

f077 = read('077_org_assurance_question_procs.sql')
f520 = read('520_question_sets_inline_questions.sql')
f535 = read('535_question_set_list_mandatory_weight.sql')
f278 = read('278_org_assurance_setup_procs.sql')
f119 = read('119_definition_procs_role_extension.sql')
f546 = read('546_audit_plan_basic_flow.sql')

orig = {}
out = []

# ---------------- set_save (077) ----------------
p = proc(f077, 'sp_org_assurance_question_set_save'); orig['set_save'] = p
p = rep(p, """        SET @question_set_id_out = SCOPE_IDENTITY();
    END""", """        SET @question_set_id_out = SCOPE_IDENTITY();

        -- 551: a new set is version 1, Draft, of itself.
        UPDATE grac_practice.org_assurance_question_set
           SET root_question_set_id = @question_set_id_out,
               version_number       = 1,
               version_status       = N'Draft'
         WHERE org_assurance_question_set_id = @question_set_id_out;
    END""")
p = rep(p, """        DECLARE @def_org BIGINT;
        SELECT @def_org = organization_id
        FROM grac_practice.org_assurance_question_set""", """        DECLARE @def_org BIGINT, @version_status NVARCHAR(20);
        SELECT @def_org = organization_id, @version_status = version_status
        FROM grac_practice.org_assurance_question_set""")
p = rep(p, """        BEGIN ROLLBACK; THROW 53807, 'Question set belongs to a different organization.', 1; END
""", """        BEGIN ROLLBACK; THROW 53807, 'Question set belongs to a different organization.', 1; END
        -- 551: only a Draft version is changed.
        IF @version_status <> N'Draft'
        BEGIN ROLLBACK; THROW 53840, 'Only a Draft version of a question set can be changed. Use New Version to change an approved set.', 1; END
""")
out.append('-- =====================================================================\n-- 4. Question set procedures (re-issued)\n-- =====================================================================\n\n-- sp_org_assurance_question_set_save (077 body + 551)\n' + p + '\n')

# ---------------- set_get (077) ----------------
p = proc(f077, 'sp_org_assurance_question_set_get'); orig['set_get'] = p
p = rep(p, """           qs.status                        AS Status,
           qs.entered_by                    AS EnteredBy,""", """           qs.status                        AS Status,
           -- 551: the version, and the set's Active / open versions.
           qs.root_question_set_id          AS RootQuestionSetId,
           qs.version_number                AS VersionNumber,
           qs.version_status                AS VersionStatus,
           qs.previous_question_set_id      AS PreviousQuestionSetId,
           qs.change_note                   AS ChangeNote,
           qs.submitted_by                  AS SubmittedBy,
           qs.submitted_dt                  AS SubmittedDt,
           qs.approved_by                   AS ApprovedBy,
           qs.approved_dt                   AS ApprovedDt,
           act.org_assurance_question_set_id AS ActiveQuestionSetId,
           act.version_number               AS ActiveVersionNumber,
           opn.org_assurance_question_set_id AS OpenQuestionSetId,
           opn.version_number               AS OpenVersionNumber,
           opn.version_status               AS OpenVersionStatus,
           qs.entered_by                    AS EnteredBy,""")
p = rep(p, """    FROM grac_practice.org_assurance_question_set qs
    WHERE qs.organization_id               = @organization_id""", """    FROM grac_practice.org_assurance_question_set qs
    OUTER APPLY (SELECT TOP 1 a.org_assurance_question_set_id, a.version_number
                   FROM grac_practice.org_assurance_question_set a
                  WHERE a.root_question_set_id = qs.root_question_set_id AND a.is_active = 1
                    AND a.version_status = N'Active'
                  ORDER BY a.version_number DESC) act
    OUTER APPLY (SELECT TOP 1 o.org_assurance_question_set_id, o.version_number, o.version_status
                   FROM grac_practice.org_assurance_question_set o
                  WHERE o.root_question_set_id = qs.root_question_set_id AND o.is_active = 1
                    AND o.version_status IN (N'Draft', N'UnderReview')
                  ORDER BY o.version_number DESC) opn
    WHERE qs.organization_id               = @organization_id""")
out.append('-- sp_org_assurance_question_set_get (077 body + 551)\n' + p + '\n')

# ---------------- set_list (535) ----------------
p = proc(f535, 'sp_org_assurance_question_set_list'); orig['set_list'] = p
latest = """          AND qs.is_active = 1
          -- 551: one row per set -- its latest version.
          AND qs.version_number = (SELECT MAX(x.version_number)
                                     FROM grac_practice.org_assurance_question_set x
                                    WHERE x.root_question_set_id = qs.root_question_set_id
                                      AND x.is_active = 1)
          AND (@search IS NULL OR @search = ''"""
p = rep(p, """          AND qs.is_active = 1
          AND (@search IS NULL OR @search = ''""", latest, 2)
p = rep(p, """               qs.status,
               qs.entered_dt,
               qs.updated_dt,
               (SELECT COUNT_BIG(1)
                  FROM grac_practice.org_assurance_question q
                 WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
                   AND q.is_active = 1) AS question_count,
               -- 535""", """               qs.status,
               qs.entered_dt,
               qs.updated_dt,
               qs.root_question_set_id,
               qs.version_number,
               qs.version_status,
               (SELECT MAX(a.version_number) FROM grac_practice.org_assurance_question_set a
                 WHERE a.root_question_set_id = qs.root_question_set_id AND a.is_active = 1
                   AND a.version_status = N'Active') AS active_version_number,
               (SELECT COUNT_BIG(1)
                  FROM grac_practice.org_assurance_question q
                 WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
                   AND q.is_active = 1) AS question_count,
               -- 535""")
p = rep(p, """           total_weight                  AS TotalWeight,      -- 535
""", """           total_weight                  AS TotalWeight,      -- 535
           root_question_set_id          AS RootQuestionSetId,    -- 551
           version_number                AS VersionNumber,        -- 551
           version_status                AS VersionStatus,        -- 551
           active_version_number         AS ActiveVersionNumber,  -- 551
""")
out.append('-- sp_org_assurance_question_set_list (535 body + 551: latest version per set)\n' + p + '\n')

# ---------------- set_delete (077 -> rewritten) ----------------
orig['set_delete'] = proc(f077, 'sp_org_assurance_question_set_delete')
out.append(open(os.path.join(S, 'part_delete.sql'), encoding='utf-8').read() + '\n')

# ---------------- new procs ----------------
out.append(open(os.path.join(S, 'part_d.sql'), encoding='utf-8').read() + '\n')

# ---------------- questions (520 / 077) ----------------
guard = """    IF @set_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;
    -- 551: only a Draft version of a set is changed.
    IF (SELECT version_status FROM grac_practice.org_assurance_question_set
         WHERE org_assurance_question_set_id = @question_set_id) <> N'Draft'
        THROW 53840, 'Only a Draft version of a question set can be changed. Use New Version to change an approved set.', 1;"""
line = "    IF @set_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;"
sec = '-- =====================================================================\n-- 5. Questions -- only a Draft version of a set changes\n-- =====================================================================\n\n'
p = proc(f520, 'sp_org_assurance_question_set_questions_save'); orig['q_grid'] = p
p = rep(p, line, guard)
sec += '-- sp_org_assurance_question_set_questions_save (520 body + 551)\n' + p + '\n'
p = proc(f520, 'sp_org_assurance_question_save'); orig['q_save'] = p
p = rep(p, line, guard)
sec += '-- sp_org_assurance_question_save (520 body + 551)\n' + p + '\n'
p = proc(f077, 'sp_org_assurance_question_delete'); orig['q_delete'] = p
p = rep(p, """    IF @q_org <> @organization_id THROW 53807, 'Question belongs to a different organization.', 1;
""", """    IF @q_org <> @organization_id THROW 53807, 'Question belongs to a different organization.', 1;
    -- 551: only a Draft version of a set is changed.
    IF (SELECT qs.version_status FROM grac_practice.org_assurance_question q
          JOIN grac_practice.org_assurance_question_set qs
               ON qs.org_assurance_question_set_id = q.org_assurance_question_set_id
         WHERE q.org_assurance_question_id = @question_id) <> N'Draft'
        THROW 53840, 'Only a Draft version of a question set can be changed. Use New Version to change an approved set.', 1;
""")
sec += '-- sp_org_assurance_question_delete (077 body + 551)\n' + p + '\n'
out.append(sec)

# ---------------- definition question sets (278) ----------------
sec = '-- =====================================================================\n-- 6. Definition question sets -- Active versions only\n-- =====================================================================\n\n'
p = proc(f278, 'sp_org_assurance_definition_question_set_get'); orig['dq_get'] = p
p = rep(p, """           qs.set_name                                  AS SetName,
           dqs.display_order                            AS DisplayOrder,""", """           qs.set_name                                  AS SetName,
           qs.version_number                            AS SetVersionNumber,   -- 551
           qs.version_status                            AS SetVersionStatus,   -- 551
           dqs.display_order                            AS DisplayOrder,""")
p = rep(p, """           qs.set_name                      AS SetName,
           (SELECT COUNT(*)""", """           qs.set_name                      AS SetName,
           qs.version_number                AS SetVersionNumber,   -- 551
           (SELECT COUNT(*)""")
p = rep(p, """    WHERE qs.organization_id = @organization_id
      AND qs.is_active = 1
    ORDER BY qs.set_name;""", """    WHERE qs.organization_id = @organization_id
      AND qs.is_active = 1
      AND qs.version_status = N'Active'      -- 551: approved versions only
    ORDER BY qs.set_name;""")
sec += '-- sp_org_assurance_definition_question_set_get (278 body + 551)\n' + p + '\n'
p = proc(f278, 'sp_org_assurance_definition_question_set_save'); orig['dq_save'] = p
p = rep(p, """        THROW 53713, 'One or more question sets do not exist in this organization.', 1;
""", """        THROW 53713, 'One or more question sets do not exist in this organization.', 1;

    -- 551: only an approved (Active) question set version is adopted.
    IF EXISTS (
        SELECT 1
        FROM @incoming i
        JOIN grac_practice.org_assurance_question_set qs
             ON qs.org_assurance_question_set_id = i.question_set_id
        WHERE qs.version_status <> N'Active')
        THROW 53714, 'Only an approved (Active) question set version can be added to an audit.', 1;
""")
sec += '-- sp_org_assurance_definition_question_set_save (278 body + 551)\n' + p + '\n'
out.append(sec)

# ---------------- definition save (119) ----------------
p = proc(f119, 'sp_org_assurance_definition_save'); orig['def_save'] = p
p = rep(p, """                 @draft_status_id, 1, @active_record_status_id, @actor, SYSUTCDATETIME());

            SET @definition_version_id_out = SCOPE_IDENTITY();

            UPDATE grac_practice.org_assurance_definition
            SET definition_name    = @definition_name,""", """                 @draft_status_id, 1, @active_record_status_id, @actor, SYSUTCDATETIME());

            SET @definition_version_id_out = SCOPE_IDENTITY();

            -- 551: the new Draft version carries the configuration of the
            -- version it revises (scope, question sets, workflow, scoring);
            -- it started empty before.
            EXEC grac_practice.sp_org_assurance_definition_version_copy_config
                 @organization_id = @organization_id,
                 @from_version_id = @current_version_id,
                 @to_version_id   = @definition_version_id_out,
                 @actor           = @actor;

            UPDATE grac_practice.org_assurance_definition
            SET definition_name    = @definition_name,""")
out.append('-- =====================================================================\n-- 7. sp_org_assurance_definition_save (119 body + 551: copy the configuration)\n-- =====================================================================\n' + p + '\n')

# ---------------- plan items (546) ----------------
sec = '-- =====================================================================\n-- 8. Plannable audit = an Active version, not Retired (546 bodies + 551)\n-- =====================================================================\n\n'
p = proc(f546, 'sp_org_assurance_plan_item_save'); orig['pi_save'] = p
p = rep(p, """    DECLARE @def_status NVARCHAR(60);
    SELECT @def_status      = s.status_code,
           @definition_code = d.definition_code,
           @definition_name = d.definition_name
      FROM grac_practice.org_assurance_definition d
      JOIN grac_practice.org_assurance_status_master s
           ON s.org_assurance_status_id = d.current_status_id
     WHERE d.org_assurance_definition_id = @org_assurance_definition_id;
    IF @def_status <> N'Active'
        THROW 53933, 'Only an Active audit can be added to a plan.', 1;""", """    -- 551: an audit with an Active version that is not Retired can be
    -- planned, also while a revised Draft version is in progress.
    DECLARE @def_status NVARCHAR(60), @def_active_version BIGINT;
    SELECT @def_status         = s.status_code,
           @def_active_version = d.active_version_id,
           @definition_code    = d.definition_code,
           @definition_name    = d.definition_name
      FROM grac_practice.org_assurance_definition d
      JOIN grac_practice.org_assurance_status_master s
           ON s.org_assurance_status_id = d.current_status_id
     WHERE d.org_assurance_definition_id = @org_assurance_definition_id;
    IF @def_active_version IS NULL OR @def_status = N'Retired'
        THROW 53933, 'Only an audit with an Active version can be added to a plan.', 1;""")
sec += '-- sp_org_assurance_plan_item_save (546 body + 551)\n' + p + '\n'
p = proc(f546, 'sp_org_assurance_plan_item_list'); orig['pi_list'] = p
p = rep(p, """           ds.status_name                AS DefinitionStatusName,
""", """           ds.status_name                AS DefinitionStatusName,
           -- 551: the audit can be planned / executed -- it has an Active
           -- version and is not Retired (a revision may be in Draft).
           CAST(CASE WHEN d.active_version_id IS NOT NULL AND ds.status_code <> N'Retired'
                     THEN 1 ELSE 0 END AS BIT) AS DefinitionIsPlannable,
""")
sec += '-- sp_org_assurance_plan_item_list (546 body + 551)\n' + p + '\n'
p = proc(f546, 'sp_org_assurance_plan_item_start_execution'); orig['pi_start'] = p
p = rep(p, """    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_definition d
          JOIN grac_practice.org_assurance_status_master s
               ON s.org_assurance_status_id = d.current_status_id
         WHERE d.org_assurance_definition_id = @definition_id
           AND s.status_code = N'Active')
        THROW 53933, 'The audit is not Active (it may have been retired), so this slot cannot be executed.', 1;""", """    -- 551: run the audit's ACTIVE version (its current version may be a
    -- Draft revision); no Active version, or Retired, cannot be executed.
    DECLARE @active_version_id BIGINT;
    SELECT @active_version_id = d.active_version_id
      FROM grac_practice.org_assurance_definition d
      JOIN grac_practice.org_assurance_status_master s
           ON s.org_assurance_status_id = d.current_status_id
     WHERE d.org_assurance_definition_id = @definition_id
       AND s.status_code <> N'Retired';
    IF @active_version_id IS NULL
        THROW 53933, 'The audit has no Active version (it may have been retired), so this slot cannot be executed.', 1;""")
p = rep(p, "         @version_id          = NULL,", "         @version_id          = @active_version_id,   -- 551")
sec += '-- sp_org_assurance_plan_item_start_execution (546 body + 551)\n' + p + '\n'
out.append(sec)

tail = """-- =====================================================================
-- Verification
-- =====================================================================
SELECT '551 version columns' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.org_assurance_question_set','version_status') IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_question_set WHERE root_question_set_id IS NULL)
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '551 clone engine',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_clone_rows','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_definition_version_copy_config','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '551 set lifecycle procedures',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_question_set_new_version','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_question_set_submit','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_question_set_return','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_question_set_approve','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_question_set_impact','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_question_set_version_list','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '551 Draft-only question changes',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_question_set_questions_save')) LIKE '%THROW 53840%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '551 definition edit copies configuration',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_definition_save')) LIKE '%version_copy_config%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '551 execution runs the Active version',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_plan_item_start_execution')) LIKE '%@active_version_id%' THEN 'PASS' ELSE 'FAIL' END;
PRINT '551 complete. Restart the Api and publish Web.';
GO
SET NOEXEC OFF;
GO
"""
head = open(os.path.join(S, 'part_a.sql'), encoding='utf-8').read()
sql = head + '\n' + '\n'.join(out) + tail
open(os.path.join(D, '551_question_set_versioning.sql'), 'w', encoding='utf-8', newline='\n').write(sql)

rb = """-- =====================================================================
-- 551 ROLLBACK -- restores the procedures 551 re-issued (077, 520, 535,
-- 278, 119, 546 bodies) and drops the procedures it added. The version
-- columns, their values and the (organization_id, set_code,
-- version_number) unique key are KEPT: sets may now have several versions
-- sharing a code, which the old (organization_id, set_code) key would
-- reject. Deploy the pre-551 Api and Web with it. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
"""
for k in ['set_save', 'set_get', 'set_list', 'set_delete', 'q_grid', 'q_save', 'q_delete', 'dq_get', 'dq_save', 'def_save', 'pi_save', 'pi_list', 'pi_start']:
    rb += orig[k] + '\n'
for n in ['sp_org_assurance_question_set_version_list', 'sp_org_assurance_question_set_new_version',
          'sp_org_assurance_question_set_submit', 'sp_org_assurance_question_set_return',
          'sp_org_assurance_question_set_impact', 'sp_org_assurance_question_set_approve',
          'sp_org_assurance_definition_version_copy_config', 'sp_org_assurance_clone_rows']:
    rb += "IF OBJECT_ID('grac_practice.%s','P') IS NOT NULL DROP PROCEDURE grac_practice.%s;\nGO\n" % (n, n)
rb += "PRINT '551 rolled back (procedures). Version columns kept.';\nGO\n"
open(os.path.join(D, '551_question_set_versioning_rollback.sql'), 'w', encoding='utf-8', newline='\n').write(rb)
for f in ['551_question_set_versioning.sql', '551_question_set_versioning_rollback.sql']:
    b = open(os.path.join(D, f), 'rb').read()
    print(f, len(b), 'ASCII' if all(c < 128 for c in b) else 'NONASCII')
