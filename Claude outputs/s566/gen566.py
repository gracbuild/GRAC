# gen566.py -- builds database/566_audit_engagements_record.sql (+ rollback)
# from earlier bodies: plan_item_save / plan_item_list (565),
# plan_item_start_execution / my_audits_prepare / my_audit_list (555),
# sp_org_responsibility_holder_list (553), fn_org_assurance_engagement_progress (565).
# Run from the repo root:  python3 "Claude outputs/s566/gen566.py"
import sys, os, re

DB = 'database'
HERE = os.path.dirname(os.path.abspath(__file__))

def body(fname, kind, name):
    s = open(os.path.join(DB, fname), encoding='utf-8').read()
    m = re.search(r'CREATE OR ALTER ' + kind + r' grac_practice\.' + re.escape(name) + r'[\s(]', s)
    if not m:
        sys.exit('not found: ' + name + ' in ' + fname)
    start = m.start()
    end = s.index('\nGO\n', start)
    return s[start:end] + '\nGO\n'

def rep(s, old, new, count=1):
    n = s.count(old)
    if n != count:
        sys.exit('replace count %d != %d for: %r' % (n, count, old[:90]))
    return s.replace(old, new)

isave = body('565_audit_plan_programmes.sql', 'PROCEDURE', 'sp_org_assurance_plan_item_save')
ilist = body('565_audit_plan_programmes.sql', 'PROCEDURE', 'sp_org_assurance_plan_item_list')
start = body('555_my_audits_freeze_scope.sql', 'PROCEDURE', 'sp_org_assurance_plan_item_start_execution')
prep  = body('555_my_audits_freeze_scope.sql', 'PROCEDURE', 'sp_org_assurance_my_audits_prepare')
mylist = body('555_my_audits_freeze_scope.sql', 'PROCEDURE', 'sp_org_assurance_my_audit_list')
holder553 = body('553_role_responsibilities.sql', 'PROCEDURE', 'sp_org_responsibility_holder_list')
prog565 = body('565_audit_plan_programmes.sql', 'FUNCTION', 'fn_org_assurance_engagement_progress')

# =================================================================== item_save
s = isave
s = rep(s,
"""    @programme_id                BIGINT        = NULL,   -- 565: the programme (mandatory)
    @actor                       NVARCHAR(100) = 'system',""",
"""    @programme_id                BIGINT        = NULL,   -- 565: the programme (mandatory)
    -- 566: the engagement record (spec 4.5)
    @engagement_origin           NVARCHAR(20)   = NULL,   -- PLANNED / INDEPENDENT (default: by the plan)
    @audit_subject               NVARCHAR(400)  = NULL,
    @engagement_objective        NVARCHAR(MAX)  = NULL,
    @scope_summary               NVARCHAR(MAX)  = NULL,
    @auditee_role_id             BIGINT         = NULL,
    @auditee_role_name           NVARCHAR(120)  = NULL,
    @auditee_employee_id         BIGINT         = NULL,
    @auditee_name                NVARCHAR(240)  = NULL,
    @engagement_instructions     NVARCHAR(MAX)  = NULL,
    @team_remarks                NVARCHAR(2000) = NULL,
    @team_json                   NVARCHAR(MAX)  = NULL,   -- the team besides the lead (sp_org_assurance_engagement_team_apply)
    @initiation_source_code      NVARCHAR(40)   = NULL,
    @initiation_reason           NVARCHAR(2000) = NULL,
    @approval_reference          NVARCHAR(200)  = NULL,
    @actor                       NVARCHAR(100) = 'system',""")
s = rep(s,
"""    IF @organization_id IS NULL OR @plan_id IS NULL
        THROW 53902, 'organization_id and plan_id are required.', 1;

    -- Verify plan ownership.
    IF NOT EXISTS (""",
"""    IF @organization_id IS NULL
        THROW 53902, 'organization_id is required.', 1;

    -- 566: PLANNED (in a plan's programme, approved with the plan) or
    -- INDEPENDENT (no plan needed, approved by authority). An existing
    -- engagement keeps its origin.
    DECLARE @origin NVARCHAR(20) = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@engagement_origin)), N''),
                                         CASE WHEN @plan_id IS NULL THEN N'INDEPENDENT' ELSE N'PLANNED' END));
    DECLARE @cur_lead BIGINT, @cur_cancelled DATETIME2, @cur_approval NVARCHAR(20);
    IF @plan_item_id IS NOT NULL
        SELECT @origin = engagement_origin, @cur_lead = assigned_auditor_employee_id,
               @cur_cancelled = cancelled_dt, @cur_approval = approval_status
          FROM grac_practice.org_assurance_plan_item
         WHERE org_assurance_plan_item_id = @plan_item_id AND organization_id = @organization_id AND is_active = 1;
    IF @origin NOT IN (N'PLANNED', N'INDEPENDENT')
        THROW 53902, 'engagement_origin must be PLANNED or INDEPENDENT.', 1;
    IF @origin = N'PLANNED' AND @plan_id IS NULL
        THROW 53902, 'A planned engagement needs its plan.', 1;
    IF @cur_cancelled IS NOT NULL
        THROW 53957, 'The engagement is cancelled.', 1;
    IF @origin = N'INDEPENDENT' AND @cur_approval = N'Approved'
        THROW 53956, 'An approved engagement is not edited; change its team with Audit Team.', 1;

    -- Verify plan ownership.
    IF @plan_id IS NOT NULL AND NOT EXISTS (""")
s = rep(s,
"""    IF @plan_status NOT IN (N'Draft', N'Submitted')
        THROW 53909, 'Plan items can be changed only while the plan is Draft or Submitted.', 1;""",
"""    IF @origin = N'PLANNED' AND @plan_status NOT IN (N'Draft', N'Submitted')   -- 566: planned only
        THROW 53909, 'Plan items can be changed only while the plan is Draft or Submitted.', 1;""")
s = rep(s,
"""    IF @programme_id IS NULL
       AND (SELECT COUNT(*) FROM grac_practice.org_assurance_plan_programme""",
"""    IF @programme_id IS NULL AND @origin = N'PLANNED'   -- 566: an independent one picks it, if at all
       AND (SELECT COUNT(*) FROM grac_practice.org_assurance_plan_programme""")
s = rep(s,
"""    IF @programme_id IS NULL
        THROW 53943,""",
"""    IF @programme_id IS NULL AND @origin = N'PLANNED'   -- 566: optional for an independent one
        THROW 53943,""")
s = rep(s,
"""    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan_programme
                    WHERE org_assurance_programme_id = @programme_id""",
"""    IF @programme_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan_programme
                    WHERE org_assurance_programme_id = @programme_id""")
s = rep(s,
"""    BEGIN TRAN;

    IF @plan_item_id IS NULL
    BEGIN
        INSERT INTO grac_practice.org_assurance_plan_item""",
"""    -- 566: what every engagement needs (spec 4.5, sir's table).
    IF NULLIF(LTRIM(RTRIM(@audit_subject)), N'') IS NULL
        THROW 53950, 'Give the audit subject of the engagement.', 1;
    IF NULLIF(LTRIM(RTRIM(@scope_summary)), N'') IS NULL
        THROW 53951, 'Describe the scope of the engagement.', 1;
    IF @assigned_auditor_employee_id IS NULL
        THROW 53952, 'Pick the lead auditor.', 1;
    IF @origin = N'INDEPENDENT'
       AND (NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_engagement_initiation_master
                         WHERE source_code = @initiation_source_code AND is_active = 1)
            OR NULLIF(LTRIM(RTRIM(@initiation_reason)), N'') IS NULL)
        THROW 53953, 'An independent engagement needs its initiation source and the reason for it.', 1;
    -- A new lead must be an auditor (553); the lead does not change once
    -- the engagement has started (the executions are theirs).
    IF (@cur_lead IS NULL OR @cur_lead <> @assigned_auditor_employee_id)
       AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'AUDITOR') h
                        WHERE h.employee_id = @assigned_auditor_employee_id)
        THROW 53954, 'The lead auditor must be an auditor (a role with the Auditor responsibility in Role Master).', 1;
    IF @plan_item_id IS NOT NULL AND @cur_lead IS NOT NULL AND @cur_lead <> @assigned_auditor_employee_id
       AND EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution e
                    WHERE e.org_assurance_plan_item_id = @plan_item_id AND e.is_active = 1)
        THROW 53955, 'The engagement has started; its lead auditor cannot change.', 1;

    BEGIN TRAN;

    IF @plan_item_id IS NULL
    BEGIN
        INSERT INTO grac_practice.org_assurance_plan_item""")
s = rep(s,
"""             org_assurance_programme_id,                         -- 565
             is_active, entered_by, entered_dt)""",
"""             org_assurance_programme_id,                         -- 565
             engagement_origin, audit_subject, engagement_objective, scope_summary,   -- 566
             auditee_role_id, auditee_role_name, auditee_employee_id, auditee_name,
             engagement_instructions, team_remarks,
             initiation_source_code, initiation_reason, approval_reference, approval_status,
             is_active, entered_by, entered_dt)""")
s = rep(s,
"""             (SELECT LEFT(p.plan_code, 110) + N'-E'
                     + RIGHT(N'0' + CAST((SELECT COUNT(*) + 1 FROM grac_practice.org_assurance_plan_item x
                                           WHERE x.org_assurance_plan_id = @plan_id) AS NVARCHAR(10)), 2)
                FROM grac_practice.org_assurance_plan p WHERE p.org_assurance_plan_id = @plan_id),""",
"""             COALESCE(
             (SELECT LEFT(p.plan_code, 110) + N'-E'
                     + RIGHT(N'0' + CAST((SELECT COUNT(*) + 1 FROM grac_practice.org_assurance_plan_item x
                                           WHERE x.org_assurance_plan_id = @plan_id) AS NVARCHAR(10)), 2)
                FROM grac_practice.org_assurance_plan p WHERE p.org_assurance_plan_id = @plan_id),
             -- 566: an independent engagement without a plan: ENG-<year>-0001 ...
             N'ENG-' + CAST(YEAR(SYSUTCDATETIME()) AS NVARCHAR(4)) + N'-'
                     + RIGHT(N'000' + CAST((SELECT COUNT(*) + 1 FROM grac_practice.org_assurance_plan_item x
                                             WHERE x.organization_id = @organization_id
                                               AND x.org_assurance_plan_id IS NULL) AS NVARCHAR(10)), 4)),""")
s = rep(s,
"""             @programme_id,
             1, @actor, SYSUTCDATETIME());""",
"""             @programme_id,
             @origin, LTRIM(RTRIM(@audit_subject)), @engagement_objective, @scope_summary,   -- 566
             @auditee_role_id, @auditee_role_name, @auditee_employee_id, @auditee_name,
             @engagement_instructions, @team_remarks,
             CASE WHEN @origin = N'INDEPENDENT' THEN @initiation_source_code END,
             CASE WHEN @origin = N'INDEPENDENT' THEN @initiation_reason END,
             @approval_reference,
             CASE WHEN @origin = N'INDEPENDENT' THEN N'Draft' END,
             1, @actor, SYSUTCDATETIME());""")
s = rep(s,
"""        DECLARE @item_plan BIGINT;
        SELECT @item_plan = org_assurance_plan_id
        FROM grac_practice.org_assurance_plan_item
        WHERE org_assurance_plan_item_id = @plan_item_id
          AND is_active = 1;

        IF @item_plan IS NULL BEGIN ROLLBACK; THROW 53915, 'Plan item not found.', 1; END
        IF @item_plan <> @plan_id
        BEGIN ROLLBACK; THROW 53916, 'Plan item does not belong to the specified plan.', 1; END""",
"""        DECLARE @item_plan BIGINT, @item_found BIT = 0;   -- 566: an independent one has no plan
        SELECT @item_plan = org_assurance_plan_id, @item_found = 1
        FROM grac_practice.org_assurance_plan_item
        WHERE org_assurance_plan_item_id = @plan_item_id
          AND is_active = 1;

        IF @item_found = 0 BEGIN ROLLBACK; THROW 53915, 'Plan item not found.', 1; END
        IF @origin = N'PLANNED' AND (@item_plan IS NULL OR @item_plan <> @plan_id)
        BEGIN ROLLBACK; THROW 53916, 'Plan item does not belong to the specified plan.', 1; END""")
s = rep(s,
"""            org_assurance_programme_id  = @programme_id,      -- 565""",
"""            org_assurance_programme_id  = @programme_id,      -- 565
            -- 566: the engagement record; an independent one may be linked
            -- to a plan (reference only).
            org_assurance_plan_id       = CASE WHEN @origin = N'INDEPENDENT' THEN @plan_id ELSE org_assurance_plan_id END,
            audit_subject               = LTRIM(RTRIM(@audit_subject)),
            engagement_objective        = @engagement_objective,
            scope_summary               = @scope_summary,
            auditee_role_id             = @auditee_role_id,
            auditee_role_name           = @auditee_role_name,
            auditee_employee_id         = @auditee_employee_id,
            auditee_name                = @auditee_name,
            engagement_instructions     = @engagement_instructions,
            team_remarks                = @team_remarks,
            initiation_source_code      = CASE WHEN @origin = N'INDEPENDENT' THEN @initiation_source_code END,
            initiation_reason           = CASE WHEN @origin = N'INDEPENDENT' THEN @initiation_reason END,
            approval_reference          = @approval_reference,""")
s = rep(s,
"""    COMMIT;
END
GO
""",
"""    -- 566: the team -- the lead from the engagement, the others from @team_json.
    EXEC grac_practice.sp_org_assurance_engagement_team_apply
         @organization_id = @organization_id,
         @plan_item_id    = @plan_item_id_out,
         @team_json       = @team_json,
         @actor           = @actor;

    COMMIT;
END
GO
""")
isave566 = s

# =================================================================== item_list
s = ilist
s = rep(s,
"""           pg.programme_name             AS ProgrammeName,""",
"""           pg.programme_name             AS ProgrammeName,
           -- 566: the engagement record
           i.engagement_origin           AS EngagementOrigin,
           i.audit_subject               AS AuditSubject,
           i.approval_status             AS ApprovalStatus,
           i.cancelled_dt                AS CancelledDt,""")
s = rep(s,
"""           CASE WHEN ISNULL(eg.live_count, 0) > 0 AND eg.done_count >= eg.definition_count THEN N'Completed'""",
"""           CASE WHEN i.cancelled_dt IS NOT NULL THEN N'Cancelled'   -- 566
                WHEN ISNULL(eg.live_count, 0) > 0 AND eg.done_count >= eg.definition_count THEN N'Completed'""")
s = rep(s,
"""           CAST(CASE WHEN ISNULL(eg.startable_count, 0) > 0 THEN 1 ELSE 0 END AS BIT) AS CanStart,""",
"""           CAST(CASE WHEN ISNULL(eg.startable_count, 0) > 0 AND i.cancelled_dt IS NULL THEN 1 ELSE 0 END AS BIT) AS CanStart,   -- 566: not a cancelled one""")
ilist566 = s

# =================================================================== start_execution
s = start
s = rep(s,
"""    IF @organization_id IS NULL OR @plan_id IS NULL OR @plan_item_id IS NULL
        THROW 53902, 'organization_id, plan_id and plan_item_id are required.', 1;""",
"""    IF @organization_id IS NULL OR @plan_item_id IS NULL
        THROW 53902, 'organization_id and plan_item_id are required.', 1;   -- 566: plan_id not for an independent one""")
s = rep(s,
"""            @branch_id BIGINT, @branch_name NVARCHAR(200);   -- 554""",
"""            @branch_id BIGINT, @branch_name NVARCHAR(200),   -- 554
            @found BIT = 0, @origin NVARCHAR(20), @approval NVARCHAR(20), @cancelled DATETIME2;   -- 566""")
s = rep(s,
"""           @branch_name   = i.assigned_branch_name""",
"""           @branch_name   = i.assigned_branch_name,
           @found         = 1,                         -- 566
           @origin        = i.engagement_origin,
           @approval      = i.approval_status,
           @cancelled     = i.cancelled_dt""")
s = rep(s,
"""    IF @item_plan IS NULL      THROW 53915, 'Plan item not found.', 1;
    IF @item_plan <> @plan_id  THROW 53916, 'Plan item does not belong to the specified plan.', 1;

    IF NOT EXISTS (""",
"""    IF @found = 0 THROW 53915, 'Plan item not found.', 1;
    IF @cancelled IS NOT NULL THROW 53957, 'The engagement is cancelled.', 1;   -- 566
    -- 566: an independent engagement starts once approved by its
    -- authority; its executions are MANUAL with the engagement, no plan.
    DECLARE @exec_origin NVARCHAR(20) = CASE WHEN @origin = N'INDEPENDENT' THEN N'MANUAL' ELSE N'PLAN' END;
    DECLARE @exec_plan BIGINT = CASE WHEN @origin = N'INDEPENDENT' THEN NULL ELSE @plan_id END;
    IF @origin = N'INDEPENDENT' AND ISNULL(@approval, N'Draft') <> N'Approved'
        THROW 53956, 'An independent engagement starts once it is approved.', 1;
    IF @origin = N'PLANNED' AND (@plan_id IS NULL OR @item_plan IS NULL OR @item_plan <> @plan_id)
        THROW 53916, 'Plan item does not belong to the specified plan.', 1;

    IF @origin = N'PLANNED' AND NOT EXISTS (""")
s = rep(s,
"""             @origin_type         = N'PLAN',
             @plan_id             = @plan_id,""",
"""             @origin_type         = @exec_origin,      -- 566
             @plan_id             = @exec_plan,""")
start566 = s

# =================================================================== my_audits_prepare
s = prep
s = rep(s,
"""                        plan_id BIGINT NOT NULL, plan_item_id BIGINT NOT NULL,""",
"""                        plan_id BIGINT NULL, plan_item_id BIGINT NOT NULL,   -- 566: none for an independent one""")
s = rep(s,
"""      FROM grac_practice.org_assurance_plan_item i
      JOIN grac_practice.org_assurance_plan p
           ON p.org_assurance_plan_id = i.org_assurance_plan_id
      JOIN grac_practice.org_assurance_plan_status_master ps
           ON ps.org_assurance_plan_status_id = p.status_id
     WHERE i.assigned_auditor_employee_id = @employee_id
       AND i.is_active = 1
       AND p.is_active = 1
       AND ps.status_code IN (N'Approved', N'Active')""",
"""      FROM grac_practice.org_assurance_plan_item i
      LEFT JOIN grac_practice.org_assurance_plan p
           ON p.org_assurance_plan_id = i.org_assurance_plan_id
      LEFT JOIN grac_practice.org_assurance_plan_status_master ps
           ON ps.org_assurance_plan_status_id = p.status_id
     WHERE i.assigned_auditor_employee_id = @employee_id
       AND i.is_active = 1
       AND i.cancelled_dt IS NULL                       -- 566
       -- 566: planned -- the plan Approved / Active; independent -- approved
       AND (   (i.engagement_origin = N'PLANNED' AND p.is_active = 1 AND ps.status_code IN (N'Approved', N'Active'))
            OR (i.engagement_origin = N'INDEPENDENT' AND i.approval_status = N'Approved'))""")
prep566 = s

# =================================================================== my_audit_list
s = mylist
s = rep(s,
"""      JOIN grac_practice.org_assurance_plan p
           ON p.org_assurance_plan_id = i.org_assurance_plan_id
      JOIN grac_practice.org_assurance_plan_status_master ps
           ON ps.org_assurance_plan_status_id = p.status_id
      JOIN grac_practice.org_assurance_definition d""",
"""      LEFT JOIN grac_practice.org_assurance_plan p                  -- 566: an independent one has none
           ON p.org_assurance_plan_id = i.org_assurance_plan_id
      LEFT JOIN grac_practice.org_assurance_plan_status_master ps
           ON ps.org_assurance_plan_status_id = p.status_id
      JOIN grac_practice.org_assurance_definition d""")
s = rep(s,
"""       AND p.is_active  = 1
       AND ps.status_code IN (N'Approved', N'Active', N'Closed')""",
"""       -- 566: planned -- the plan Approved / Active / Closed; independent -- approved
       AND (   (i.engagement_origin = N'PLANNED' AND p.is_active = 1
                AND ps.status_code IN (N'Approved', N'Active', N'Closed'))
            OR (i.engagement_origin = N'INDEPENDENT' AND i.approval_status = N'Approved'))""")
mylist566 = s

head = open(os.path.join(HERE, 'head566.sql'), encoding='utf-8').read()
tail = open(os.path.join(HERE, 'tail566.sql'), encoding='utf-8').read()
def sec(title, b):
    return ('-- =====================================================================\n-- ' + title
            + '\n-- =====================================================================\n' + b + '\n')
out = (head
       + sec('8a. sp_org_assurance_plan_item_save (565 body) + independent engagements, the record, the team', isave566)
       + sec('8b. sp_org_assurance_plan_item_list (565 body) + origin, subject, Cancelled', ilist566)
       + sec('8c. sp_org_assurance_plan_item_start_execution (555 body) + independent engagements', start566)
       + sec('8d. sp_org_assurance_my_audits_prepare (555 body) + independent engagements', prep566)
       + sec('8e. sp_org_assurance_my_audit_list (555 body) + independent engagements', mylist566)
       + tail)
for i, ch in enumerate(out):
    if ord(ch) > 127:
        sys.exit('non-ASCII at %d: %r' % (i, out[i-40:i+10]))
open(os.path.join(DB, '566_audit_engagements_record.sql'), 'w', encoding='ascii', newline='\n').write(out)

rb = open(os.path.join(HERE, 'rbhead566.sql'), encoding='utf-8').read()
rb_out = (rb
          + '-- plan_item_save / plan_item_list: 565 bodies\n' + isave + '\n' + ilist + '\n'
          + '-- start / prepare / my list: 555 bodies\n' + start + '\n' + prep + '\n' + mylist + '\n'
          + '-- holder list: 553 body\n' + holder553 + '\n'
          + '-- engagement progress: 565 body\n' + prog565 + '\n'
          + "IF OBJECT_ID('grac_practice.fn_org_assurance_engagement_rows') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_engagement_rows;\n"
          + "IF OBJECT_ID('grac_practice.fn_org_assurance_engagement_status') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_engagement_status;\n"
          + "IF OBJECT_ID('grac_practice.fn_org_responsibility_holder') IS NOT NULL DROP FUNCTION grac_practice.fn_org_responsibility_holder;\nGO\n"
          + "PRINT '566 rolled back: procedures back to 553 / 555 / 565; engagement procedures and functions dropped; Audit Engagements menu Inactive; tables / columns kept (an independent engagement keeps a NULL plan).';\nGO\n")
open(os.path.join(DB, '566_audit_engagements_record_rollback.sql'), 'w', encoding='ascii', newline='\n').write(rb_out)
print('566 written:', len(out), 'chars; rollback', len(rb_out))
