# gen565.py -- builds database/565_audit_plan_programmes.sql (+ rollback)
# from earlier bodies: plan_save / plan_get / plan_list (121),
# plan_item_save / plan_item_list (552).
# Run from the repo root:  python3 "Claude outputs/s565/gen565.py"
import sys, os

DB = 'database'
HERE = os.path.dirname(os.path.abspath(__file__))

def body(fname, name):
    s = open(os.path.join(DB, fname), encoding='utf-8').read()
    start = s.index('CREATE OR ALTER PROCEDURE grac_practice.' + name + '\n')
    end = s.index('\nGO\n', start)
    return s[start:end] + '\nGO\n'

def rep(s, old, new, count=1):
    n = s.count(old)
    if n != count:
        sys.exit('replace count %d != %d for: %r' % (n, count, old[:90]))
    return s.replace(old, new)

save121 = body('121_plan_procs_role_extension.sql', 'sp_org_assurance_plan_save')
get121  = body('121_plan_procs_role_extension.sql', 'sp_org_assurance_plan_get')
list121 = body('121_plan_procs_role_extension.sql', 'sp_org_assurance_plan_list')
isave552 = body('552_audit_engagements.sql', 'sp_org_assurance_plan_item_save')
ilist552 = body('552_audit_engagements.sql', 'sp_org_assurance_plan_item_list')

# ---------------------------------------------------------------- plan_save
ps = rep(save121,
"""    @description         NVARCHAR(MAX) = NULL,
    @actor               NVARCHAR(100) = 'system',""",
"""    @description         NVARCHAR(MAX) = NULL,
    @financial_year      NVARCHAR(40)   = NULL,   -- 565: annual plan fields
    @objectives          NVARCHAR(MAX)  = NULL,
    @planned_coverage    NVARCHAR(MAX)  = NULL,
    @planned_budget      DECIMAL(18,2)  = NULL,
    @budget_currency     NVARCHAR(10)   = NULL,
    @planned_effort_days DECIMAL(10,1)  = NULL,
    @resources_note      NVARCHAR(2000) = NULL,
    @actor               NVARCHAR(100) = 'system',""")
ps = rep(ps,
"""        THROW 53905, 'plan_type must be ANNUAL / QUARTERLY / MONTHLY / ONE_TIME.', 1;
""",
"""        THROW 53905, 'plan_type must be ANNUAL / QUARTERLY / MONTHLY / ONE_TIME.', 1;
    IF @planned_budget < 0 OR @planned_effort_days < 0
        THROW 53945, 'Budget and effort cannot be negative.', 1;   -- 565
""")
ps = rep(ps,
"""             status_id, description, version,
             is_active, record_status_id, entered_by, entered_dt)""",
"""             status_id, description, version,
             financial_year, objectives, planned_coverage,          -- 565
             planned_budget, budget_currency, planned_effort_days, resources_note,
             is_active, record_status_id, entered_by, entered_dt)""")
ps = rep(ps,
"""             @draft_status_id, @description, 1,
             1, @active_record_status_id, @actor, SYSUTCDATETIME());""",
"""             @draft_status_id, @description, 1,
             @financial_year, @objectives, @planned_coverage,       -- 565
             @planned_budget, @budget_currency, @planned_effort_days, @resources_note,
             1, @active_record_status_id, @actor, SYSUTCDATETIME());""")
ps = rep(ps,
"""            description        = @description,
            updated_by         = @actor,""",
"""            description        = @description,
            financial_year      = @financial_year,       -- 565
            objectives          = @objectives,
            planned_coverage    = @planned_coverage,
            planned_budget      = @planned_budget,
            budget_currency     = @budget_currency,
            planned_effort_days = @planned_effort_days,
            resources_note      = @resources_note,
            updated_by         = @actor,""")

# ---------------------------------------------------------------- plan_get
pg = rep(get121,
"""           p.version               AS Version,
           p.entered_by            AS EnteredBy,""",
"""           p.version               AS Version,
           -- 565: annual plan fields, programmes, planned vs actual
           p.financial_year        AS FinancialYear,
           p.objectives            AS Objectives,
           p.planned_coverage      AS PlannedCoverage,
           p.planned_budget        AS PlannedBudget,
           p.budget_currency       AS BudgetCurrency,
           p.planned_effort_days   AS PlannedEffortDays,
           p.resources_note        AS ResourcesNote,
           (SELECT COUNT(*) FROM grac_practice.org_assurance_plan_programme g
             WHERE g.org_assurance_plan_id = p.org_assurance_plan_id AND g.is_active = 1) AS ProgrammeCount,
           (SELECT STRING_AGG(m.methodology_name, N', ')
              FROM (SELECT DISTINCT g.methodology_name FROM grac_practice.org_assurance_plan_programme g
                     WHERE g.org_assurance_plan_id = p.org_assurance_plan_id AND g.is_active = 1
                       AND g.methodology_name IS NOT NULL) m) AS Methodologies,
           (SELECT COUNT(*) FROM grac_practice.fn_org_assurance_engagement_progress(p.org_assurance_plan_id) f) AS EngagementCount,
           (SELECT COUNT(*) FROM grac_practice.fn_org_assurance_engagement_progress(p.org_assurance_plan_id) f
             WHERE f.progress_status = N'InProgress') AS EngagementInProgressCount,
           (SELECT COUNT(*) FROM grac_practice.fn_org_assurance_engagement_progress(p.org_assurance_plan_id) f
             WHERE f.progress_status = N'Completed') AS EngagementCompletedCount,
           p.entered_by            AS EnteredBy,""")

# ---------------------------------------------------------------- plan_list
pl = rep(list121,
"""               p.version,
               p.entered_dt,""",
"""               p.version,
               p.financial_year,            -- 565
               (SELECT COUNT(*) FROM grac_practice.org_assurance_plan_programme g
                 WHERE g.org_assurance_plan_id = p.org_assurance_plan_id AND g.is_active = 1) AS programme_count,
               (SELECT STRING_AGG(m.methodology_name, N', ')
                  FROM (SELECT DISTINCT g.methodology_name FROM grac_practice.org_assurance_plan_programme g
                         WHERE g.org_assurance_plan_id = p.org_assurance_plan_id AND g.is_active = 1
                           AND g.methodology_name IS NOT NULL) m) AS methodologies,
               (SELECT COUNT(*) FROM grac_practice.fn_org_assurance_engagement_progress(p.org_assurance_plan_id) f
                 WHERE f.progress_status = N'InProgress') AS engagement_in_progress_count,
               (SELECT COUNT(*) FROM grac_practice.fn_org_assurance_engagement_progress(p.org_assurance_plan_id) f
                 WHERE f.progress_status = N'Completed') AS engagement_completed_count,
               p.entered_dt,""", 2)
pl = rep(pl,
"""           version               AS Version,
           item_count            AS ItemCount,""",
"""           version               AS Version,
           item_count            AS ItemCount,
           financial_year        AS FinancialYear,                 -- 565
           programme_count       AS ProgrammeCount,
           methodologies         AS Methodologies,
           engagement_in_progress_count AS EngagementInProgressCount,
           engagement_completed_count   AS EngagementCompletedCount,""")

# ---------------------------------------------------------------- item_save
isv = rep(isave552,
"""    @definitions_json            NVARCHAR(MAX) = NULL,   -- 552: [{"definitionId": 1}, ...] in order
    @actor                       NVARCHAR(100) = 'system',""",
"""    @definitions_json            NVARCHAR(MAX) = NULL,   -- 552: [{"definitionId": 1}, ...] in order
    @programme_id                BIGINT        = NULL,   -- 565: the programme (mandatory)
    @actor                       NVARCHAR(100) = 'system',""")
isv = rep(isv,
"""        THROW 53909, 'Plan items can be changed only while the plan is Draft or Submitted.', 1;
""",
"""        THROW 53909, 'Plan items can be changed only while the plan is Draft or Submitted.', 1;

    -- 565: every engagement belongs to a programme of its plan. Not given:
    -- the engagement's own (an edit), else the plan's only programme.
    IF @programme_id IS NULL AND @plan_item_id IS NOT NULL
        SELECT @programme_id = org_assurance_programme_id
          FROM grac_practice.org_assurance_plan_item
         WHERE org_assurance_plan_item_id = @plan_item_id;
    IF @programme_id IS NULL
       AND (SELECT COUNT(*) FROM grac_practice.org_assurance_plan_programme
             WHERE org_assurance_plan_id = @plan_id AND is_active = 1) = 1
        SELECT @programme_id = org_assurance_programme_id
          FROM grac_practice.org_assurance_plan_programme
         WHERE org_assurance_plan_id = @plan_id AND is_active = 1;
    IF @programme_id IS NULL
        THROW 53943, 'Pick the programme this engagement belongs to. A plan needs a programme before engagements are added.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan_programme
                    WHERE org_assurance_programme_id = @programme_id
                      AND org_assurance_plan_id = @plan_id AND is_active = 1)
        THROW 53944, 'The programme is not part of this plan.', 1;
""")
isv = rep(isv,
"""             notes, engagement_code, engagement_name,             -- 552
             is_active, entered_by, entered_dt)""",
"""             notes, engagement_code, engagement_name,             -- 552
             org_assurance_programme_id,                         -- 565
             is_active, entered_by, entered_dt)""")
isv = rep(isv,
"""             @engagement_name,
             1, @actor, SYSUTCDATETIME());""",
"""             @engagement_name,
             @programme_id,
             1, @actor, SYSUTCDATETIME());""")
isv = rep(isv,
"""            engagement_name             = @engagement_name,   -- 552""",
"""            engagement_name             = @engagement_name,   -- 552
            org_assurance_programme_id  = @programme_id,      -- 565""")

# ---------------------------------------------------------------- item_list
il = rep(ilist552,
"""           i.engagement_code             AS EngagementCode,""",
"""           i.engagement_code             AS EngagementCode,
           -- 565: the programme
           i.org_assurance_programme_id  AS ProgrammeId,
           pg.programme_code             AS ProgrammeCode,
           pg.programme_name             AS ProgrammeName,""")
il = rep(il,
"""    LEFT JOIN grac_practice.org_assurance_status_master ds
         ON ds.org_assurance_status_id = d.current_status_id
    OUTER APPLY (""",
"""    LEFT JOIN grac_practice.org_assurance_status_master ds
         ON ds.org_assurance_status_id = d.current_status_id
    LEFT JOIN grac_practice.org_assurance_plan_programme pg
         ON pg.org_assurance_programme_id = i.org_assurance_programme_id
    OUTER APPLY (""")

head = open(os.path.join(HERE, 'head565.sql'), encoding='utf-8').read()
tail = open(os.path.join(HERE, 'tail565.sql'), encoding='utf-8').read()
def sec(title, b):
    return ('-- =====================================================================\n'
            + '-- ' + title + '\n'
            + '-- =====================================================================\n' + b + '\n')
out = (head
       + sec('8a. sp_org_assurance_plan_save (121 body) + the annual plan fields', ps)
       + sec('8b. sp_org_assurance_plan_get (121 body) + fields, programmes, planned vs actual', pg)
       + sec('8c. sp_org_assurance_plan_list (121 body) + programmes, methodologies, planned vs actual', pl)
       + sec('8d. sp_org_assurance_plan_item_save (552 body) + the programme', isv)
       + sec('8e. sp_org_assurance_plan_item_list (552 body) + the programme', il)
       + tail)
for i, ch in enumerate(out):
    if ord(ch) > 127:
        sys.exit('non-ASCII at %d: %r' % (i, out[i-40:i+10]))
open(os.path.join(DB, '565_audit_plan_programmes.sql'), 'w', encoding='ascii', newline='\n').write(out)

rb = open(os.path.join(HERE, 'rbhead565.sql'), encoding='utf-8').read()
rb_out = (rb
          + '-- plan_save / plan_get / plan_list: 121 bodies\n' + save121 + '\n' + get121 + '\n' + list121 + '\n'
          + '-- plan_item_save / plan_item_list: 552 bodies\n' + isave552 + '\n' + ilist552 + '\n'
          + "IF OBJECT_ID('grac_practice.fn_org_assurance_engagement_progress','IF') IS NOT NULL\n"
          + "    DROP FUNCTION grac_practice.fn_org_assurance_engagement_progress;\nGO\n"
          + "PRINT '565 rolled back: plan and engagement procedures back to 121 / 552; programme / revision procedures dropped; tables and columns kept.';\nGO\n")
open(os.path.join(DB, '565_audit_plan_programmes_rollback.sql'), 'w', encoding='ascii', newline='\n').write(rb_out)
print('565 written:', len(out), 'chars; rollback', len(rb_out))
