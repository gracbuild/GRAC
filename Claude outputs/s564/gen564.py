# gen564.py -- builds database/564_audit_control_practice_mapping.sql (+ rollback)
# from earlier bodies: fn_org_assurance_setup_steps (548),
# sp_org_assurance_definition_submit (537), copy_config (562).
# Run from the repo root:  python3 "Claude outputs/s564/gen564.py"
import sys, os

DB = 'database'
HERE = os.path.dirname(os.path.abspath(__file__))

def body(fname, kind, name):
    s = open(os.path.join(DB, fname), encoding='utf-8').read()
    start = s.index('CREATE OR ALTER ' + kind + ' grac_practice.' + name + '\n')
    end = s.index('\nGO\n', start)
    return s[start:end] + '\nGO\n'

def rep(s, old, new, count=1):
    n = s.count(old)
    if n != count:
        sys.exit('replace count %d != %d for: %r' % (n, count, old[:80]))
    return s.replace(old, new)

fn548  = body('548_audit_trigger_step_removed.sql', 'FUNCTION', 'fn_org_assurance_setup_steps')
sub537 = body('537_audit_configuration_list.sql', 'PROCEDURE', 'sp_org_assurance_definition_submit')
cc562  = body('562_scope_subjects_discovery.sql', 'PROCEDURE', 'sp_org_assurance_definition_version_copy_config')

# ---------------------------------------------------------------- setup steps
fn = rep(fn548,
"""                AND b.is_active = 1))))         AS scoring_ready""",
"""                AND b.is_active = 1))))         AS scoring_ready,
            -- 564: Control and Practice Mapping (optional step)
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_definition_mapping m
              WHERE m.org_assurance_definition_version_id = @version_id
                AND m.organization_id = @organization_id
                AND m.is_active = 1)                                  AS mappings""")
fn = rep(fn,
"""        (3, N'questions',        N'Question Sets',    CAST(1 AS BIT), c.question_sets,
            CASE WHEN c.question_sets > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (4, N'workflow',         N'Workflow',         CAST(1 AS BIT), c.workflow_stage,""",
"""        -- 564: optional (spec 4.2.2 "allow"): not a configuration step for
        -- the review gate or the list's count; Optional until something is
        -- mapped.
        (3, N'mapping',          N'Control and Practice Mapping', CAST(0 AS BIT), c.mappings,
            CASE WHEN c.mappings > 0 THEN N'Completed' ELSE N'Optional' END),
        (4, N'questions',        N'Question Sets',    CAST(1 AS BIT), c.question_sets,
            CASE WHEN c.question_sets > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (5, N'workflow',         N'Workflow',         CAST(1 AS BIT), c.workflow_stage,""")
fn = rep(fn,
"""        (5, N'scoring',          N'Scoring',          CAST(1 AS BIT),""",
"""        (6, N'scoring',          N'Scoring',          CAST(1 AS BIT),""")

# ---------------------------------------------------------------- review gate
sub = rep(sub537,
"""         WHERE f.StepKey <> N'details'
           AND f.Status  <> N'Completed';""",
"""         WHERE f.IsConfiguration = 1      -- 564: an optional step (mapping) never blocks
           AND f.Status <> N'Completed';""")

# ---------------------------------------------------------------- copy_config
cc = rep(cc562,
"""    -- Scoring
    EXEC grac_practice.sp_org_assurance_clone_rows""",
"""    -- 564: Control and Practice Mapping
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_definition_mapping', @key_column = N'definition_mapping_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;

    -- Scoring
    EXEC grac_practice.sp_org_assurance_clone_rows""")

head = open(os.path.join(HERE, 'head564.sql'), encoding='utf-8').read()
tail = open(os.path.join(HERE, 'tail564.sql'), encoding='utf-8').read()
out = (head
       + '-- =====================================================================\n'
       + '-- 2. fn_org_assurance_setup_steps (548 body) + the optional mapping step\n'
       + '-- =====================================================================\n'
       + fn + '\n'
       + '-- =====================================================================\n'
       + '-- 3. sp_org_assurance_definition_submit (537 body): the gate reads\n'
       + '--    IsConfiguration, so an optional step never blocks the review\n'
       + '-- =====================================================================\n'
       + sub + '\n'
       + '-- =====================================================================\n'
       + '-- 4. sp_org_assurance_definition_version_copy_config (562 body) + mapping\n'
       + '-- =====================================================================\n'
       + cc + '\n'
       + tail)
for i, ch in enumerate(out):
    if ord(ch) > 127:
        sys.exit('non-ASCII at %d: %r' % (i, out[i-40:i+10]))
open(os.path.join(DB, '564_audit_control_practice_mapping.sql'), 'w', encoding='ascii', newline='\n').write(out)

rb = open(os.path.join(HERE, 'rbhead564.sql'), encoding='utf-8').read()
rb_out = (rb
          + '-- setup steps: 548 body\n' + fn548 + '\n'
          + '-- submit: 537 body\n' + sub537 + '\n'
          + '-- copy_config: 562 body\n' + cc562 + '\n'
          + "PRINT '564 rolled back: setup steps 548, submit 537, copy_config 562; mapping procedures dropped; org_assurance_definition_mapping kept.';\nGO\n")
open(os.path.join(DB, '564_audit_control_practice_mapping_rollback.sql'), 'w', encoding='ascii', newline='\n').write(rb_out)
print('564 written:', len(out), 'chars; rollback', len(rb_out))
