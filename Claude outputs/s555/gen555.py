import re, sys, os
D = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
def body(fname, name):
    src = open(os.path.join(D, fname), encoding='utf-8').read()
    m = re.search(r'CREATE OR ALTER PROCEDURE grac_practice\.' + name + r'\b.*?\nGO\n', src, re.S)
    if not m: raise SystemExit('missing ' + name + ' in ' + fname)
    return m.group(0)
def rep(s, a, b, n=1):
    if s.count(a) != n: raise SystemExit('count %d: %r' % (s.count(a), a[:90]))
    return s.replace(a, b)

mat0 = body('545_scope_resolved_at_execution.sql', 'sp_org_assurance_execution_materialize')
st0  = body('554_engagement_branch_scope.sql',    'sp_org_assurance_plan_item_start_execution')
xs0  = body('099_org_assurance_execution_procs.sql', 'sp_org_assurance_execution_start')
get0 = body('120_execution_procs_role_extension.sql', 'sp_org_assurance_execution_get')

# ---- materialize: @live ----
mat = rep(mat0, """    @actor               NVARCHAR(100) = 'system',
    @execution_id_out    BIGINT OUTPUT""", """    @actor               NVARCHAR(100) = 'system',
    @live                BIT           = 0,      -- 555: 1 = scope live until the auditor freezes it
    @execution_id_out    BIGINT OUTPUT""")
mat = rep(mat, """    SET @execution_id_out = SCOPE_IDENTITY();
""", """    SET @execution_id_out = SCOPE_IDENTITY();

    -- 555: frozen now (manual / trigger: the scope is fixed at creation),
    -- or left live for the auditor to freeze (plan engagements).
    UPDATE grac_practice.org_assurance_execution
       SET scope_frozen_at = CASE WHEN ISNULL(@live, 0) = 1 THEN NULL ELSE SYSUTCDATETIME() END,
           scope_frozen_by = CASE WHEN ISNULL(@live, 0) = 1 THEN NULL ELSE @actor END
     WHERE org_assurance_execution_id = @execution_id_out;
""")
mat = rep(mat, """    -- Snapshot entities from the scope resolution (auditor left NULL --
    -- assigned per-entity later via sp_org_assurance_execution_entity_auditor_assign).
    INSERT INTO grac_practice.org_assurance_execution_entity(""", """    -- Snapshot entities from the scope resolution (auditor left NULL --
    -- assigned per-entity later via sp_org_assurance_execution_entity_auditor_assign).
    -- 555: not for a live scope -- Freeze Scope copies them.
    IF ISNULL(@live, 0) = 0
    INSERT INTO grac_practice.org_assurance_execution_entity(""")

# ---- snapshot fix (555 follow-up): the workflow / scoring snapshots read
# tables that never existed (org_assurance_workflow_config_stage,
# org_assurance_scoring_config_band) and columns that are not on 083 / 086,
# since 120 -- materialize failed with 208 whenever it ran. Read the real ones.
a = mat.index("    DECLARE @workflow_json NVARCHAR(MAX) = ISNULL(")
b = mat.index("    DECLARE @planned_status_id INT = (")
mat = mat[:a] + """    -- 555: the workflow and scoring snapshots read the real 083 / 086
    -- tables. Since 120 they named org_assurance_workflow_config_stage and
    -- org_assurance_scoring_config_band, which never existed (and columns
    -- that are not on these tables), so every materialize failed with 208.
    DECLARE @workflow_json NVARCHAR(MAX) = ISNULL(
        (SELECT wc.org_assurance_workflow_config_id AS WorkflowConfigId,
                wc.workflow_name                     AS WorkflowName,
                wc.workflow_template_code            AS TemplateCode,
                wc.workflow_template_name            AS TemplateName,
                wc.description                       AS Description,
                wc.total_sla_days                    AS TotalSlaDays,
                ws.stage_order                       AS StageOrder,
                ws.stage_code                        AS StageCode,
                ws.stage_name                        AS StageName,
                ws.stage_type                        AS StageType,
                ws.assigned_role_id                  AS RoleId,
                ws.assigned_role_name                AS RoleName,
                ws.assigned_employee_id              AS EmployeeId,
                ws.assigned_employee_name            AS EmployeeName,
                ws.sla_days                          AS SlaDays,
                ws.escalation_role_id                AS EscalationRoleId,
                ws.escalation_role_name              AS EscalationRoleName,
                ws.escalation_after_days             AS EscalationAfterDays,
                ws.instructions                      AS Instructions
         FROM grac_practice.org_assurance_workflow_config wc
         LEFT JOIN grac_practice.org_assurance_workflow_stage ws
                ON ws.org_assurance_workflow_config_id = wc.org_assurance_workflow_config_id
               AND ws.is_active = 1
         WHERE wc.org_assurance_definition_version_id = @version_id
           AND wc.is_active = 1
         ORDER BY ws.stage_order
         FOR JSON PATH),
        N'[]');

    DECLARE @scoring_json NVARCHAR(MAX) = ISNULL(
        (SELECT sc.org_assurance_scoring_config_id AS ScoringConfigId,
                sc.scoring_model_id                  AS ScoringModelId,
                sc.scoring_model_code                AS ScoringModelCode,
                sc.scoring_model_name                AS ScoringModelName,
                sc.scoring_model_type                AS ScoringModelType,
                sc.max_score                         AS MaxScore,
                sc.pass_threshold                    AS PassThreshold,
                sc.warning_threshold                 AS WarningThreshold,
                sc.fail_threshold                    AS FailThreshold,
                sc.description                       AS Description,
                sb.band_order                        AS BandOrder,
                sb.band_code                         AS BandCode,
                sb.band_name                         AS BandName,
                sb.min_score                         AS BandMinScore,
                sb.max_score                         AS BandMaxScore,
                sb.outcome_code                      AS BandOutcomeCode,
                sb.color_hex                         AS BandColorHex
         FROM grac_practice.org_assurance_scoring_config sc
         LEFT JOIN grac_practice.org_assurance_scoring_band sb
                ON sb.org_assurance_scoring_config_id = sc.org_assurance_scoring_config_id
               AND sb.is_active = 1
         WHERE sc.org_assurance_definition_version_id = @version_id
           AND sc.is_active = 1
         ORDER BY sb.band_order
         FOR JSON PATH),
        N'[]');

""" + mat[b:]

# ---- plan item start execution: live, no narrowing at start, @suppress_result ----
st = rep(st0, """    @actor            NVARCHAR(100) = 'system',
    @execution_id_out BIGINT OUTPUT""", """    @actor            NVARCHAR(100) = 'system',
    @suppress_result  BIT           = 0,      -- 555: My Audits prepare calls it
    @execution_id_out BIGINT OUTPUT""")
a = st.index("        -- 554: the engagement's Branch (a Location) narrows the audit's")
b = st.index("        EXEC grac_practice.sp_org_assurance_execution_materialize")
st = st[:a] + """        -- 555: the scope stays LIVE -- the auditor reviews it (narrowed to
        -- the engagement's Branch, 554) and freezes it in My Audits.
""" + st[b:]
st = rep(st, """             @scope_resolution_id = @res,
""", """             @scope_resolution_id = NULL,
""")
st = rep(st, """             @actor               = @actor,
             @execution_id_out    = @eid OUTPUT;""", """             @actor               = @actor,
             @live                = 1,                -- 555
             @execution_id_out    = @eid OUTPUT;""")
a = st.index("        -- 554: a snapshot made here points back at its execution")
b = st.index("        INSERT INTO @started (execution_id) VALUES (@eid);")
st = st[:a] + st[b:]
st = rep(st, """    COMMIT;

    SELECT e.org_assurance_execution_id AS ExecutionId,""", """    COMMIT;

    IF ISNULL(@suppress_result, 0) = 1 RETURN;   -- 555

    SELECT e.org_assurance_execution_id AS ExecutionId,""")

# ---- execution start: needs a frozen scope ----
xs = rep(xs0, """    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_execution_transition""", """    SET NOCOUNT ON;
    -- 555: an execution with a live scope starts by Freeze Scope (My Audits).
    IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution
                WHERE org_assurance_execution_id = @execution_id
                  AND organization_id = @organization_id
                  AND scope_frozen_at IS NULL)
        THROW 54030, 'The scope of this execution is live. The auditor starts it by freezing the scope in My Audits.', 1;
    EXEC grac_practice.sp_org_assurance_execution_transition""")

# ---- execution get: scope state ----
get = rep(get0, """           e.notes                                 AS Notes,
""", """           e.notes                                 AS Notes,
           e.scope_frozen_at                       AS ScopeFrozenAt,      -- 555
           e.scope_frozen_by                       AS ScopeFrozenBy,      -- 555
           (SELECT COUNT(*) FROM grac_practice.org_assurance_execution_scope_exclusion x
             WHERE x.org_assurance_execution_id = e.org_assurance_execution_id) AS ScopeExclusionCount,
""")

head = open(os.path.join(HERE, 'head555.sql'), encoding='utf-8').read()
mid  = open(os.path.join(HERE, 'mid555.sql'), encoding='utf-8').read()
tail = open(os.path.join(HERE, 'tail555.sql'), encoding='utf-8').read()
out = (head
       + "\n-- =====================================================================\n-- 3. Materialize (545 body + 555 @live)\n-- =====================================================================\n" + mat
       + "\n-- =====================================================================\n-- 4. Engagement Start Execution (554 body + 555: live, @suppress_result)\n-- =====================================================================\n" + st
       + "\n-- =====================================================================\n-- 5. Execution Start needs a frozen scope (099 body + 555)\n-- =====================================================================\n" + xs
       + "\n-- =====================================================================\n-- 6. Execution get + scope state (120 body + 555)\n-- =====================================================================\n" + get
       + mid + tail)
open(os.path.join(D, '555_my_audits_freeze_scope.sql'), 'w', encoding='utf-8', newline='\n').write(out)

rb = """-- =====================================================================
-- 555 ROLLBACK -- restores materialize (545), engagement start execution
-- (554), execution start (099) and execution get (120); drops the 555
-- procedures; sets the My Audits menu row Inactive. KEPT: the scope_frozen
-- columns and org_assurance_execution_scope_exclusion (unread). Executions
-- created live (no entities) stay as they are -- cancel them. Deploy the
-- pre-555 Api and Web with it. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
""" + mat0 + '\n' + st0 + '\n' + xs0 + '\n' + get0 + """
IF OBJECT_ID('grac_practice.sp_org_assurance_my_audit_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_my_audit_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_my_audits_prepare','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_my_audits_prepare;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_execution_live_scope','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_execution_live_scope;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_execution_freeze_scope','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_execution_freeze_scope;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_execution_scope_exclusion_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_execution_scope_exclusion_list;
GO
UPDATE grac_practice.menu_master
   SET status = N'Inactive', updated_by = 'rollback-555', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-my-audits';
GO
PRINT '555 rolled back.';
GO
"""
open(os.path.join(D, '555_my_audits_freeze_scope_rollback.sql'), 'w', encoding='utf-8', newline='\n').write(rb)
for f in ['555_my_audits_freeze_scope.sql', '555_my_audits_freeze_scope_rollback.sql']:
    b = open(os.path.join(D, f), 'rb').read(); print(f, len(b), all(c < 128 for c in b))
