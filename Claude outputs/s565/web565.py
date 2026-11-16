# web565.py -- Audit Plans: annual plan fields, Programmes (Plan ->
# Programme -> Engagement), planned vs actual, plan revision.
# Run from src/PracticeManagement.Web.
import sys
F = 'Views/Practice/Partials/org-assurance-plans.cshtml'
s = open(F, encoding='utf-8').read()

def rep(a, b, n=1):
    global s
    c = s.count(a)
    if c != n:
        sys.exit('count %d != %d: %r' % (c, n, a[:90]))
    s = s.replace(a, b)

# ---------------------------------------------------------------- header comment
rep("""    UX:
      * One plans list; a plan's engagements open under it.""",
"""    565 (2026-11-16, sir -- Audit Change spec 4.3, phase E) -- ANNUAL PLAN,
    PROGRAMMES, PLANNING METHODOLOGY
      Annual Audit Plan -> Audit Programmes -> Audit Engagements. The plan
      dialog gains Financial Year, Objectives, Planned Coverage, Budget
      (amount, currency), Planned Effort (days) and Resources. The plan
      list shows its programmes and planned vs actual (engagements, in
      progress, completed). A plan's child row lists its PROGRAMMES (code,
      programme, planning methodology, owner, planned vs actual); a
      programme row opens its ENGAGEMENTS under it (the engagement grid as
      before). Programmes are added / edited INLINE in the child row (no
      popups, sir): name, methodology (master, required), owner, order,
      objective. Every engagement belongs to a programme (the engagement
      dialog's Programme). An Approved / Active plan is REVISED (3-dot,
      with a reason): back to Draft, version + 1, the old values in the
      revision history shown in the child row; it is then re-submitted and
      re-approved.
      Backend: GET planning-methodologies; GET plans/{id}/programmes;
      POST plan-programmes; DELETE plans/{planId}/programmes/{id};
      POST plans/{id}/revise; GET plans/{id}/revisions.

    UX:
      * One plans list; a plan's programmes open under it, a programme's
        engagements under the programme.""")

# ---------------------------------------------------------------- plan list header
rep("""                    <th>Owner</th>
                    <th style="text-align:right;">Engagements</th>
                    <th>Status</th>""",
"""                    <th>Owner</th>
                    <th style="text-align:right;">Programmes</th>
                    <th>Engagements</th>
                    <th>Status</th>""")
s = s.replace('colspan="8"', 'colspan="9"')   # the plan list has one more column (565)

# ---------------------------------------------------------------- plan dialog fields
rep("""        <label class="pm-field" style="margin-top:10px;">
            <span>Description</span>
            <textarea class="pm-input" id="oaPlPlanDescription" rows="3" maxlength="4000"></textarea>
        </label>""",
"""        @* 565: the annual plan -- financial year, objectives, coverage,
           budget and resources (spec 4.3). *@
        <div style="display:grid; grid-template-columns:minmax(0,1fr) minmax(0,1fr) 110px minmax(0,1fr); gap:10px; align-items:start; margin-top:10px;">
            <label class="pm-field" style="min-width:0;">
                <span>Financial Year</span>
                <input class="pm-input" id="oaPlPlanFy" type="text" maxlength="40" placeholder="e.g. FY 2026-27" />
            </label>
            <label class="pm-field" style="min-width:0;">
                <span>Planned Budget</span>
                <input class="pm-input" id="oaPlPlanBudget" type="number" min="0" step="0.01" />
            </label>
            <label class="pm-field" style="min-width:0;">
                <span>Currency</span>
                <input class="pm-input" id="oaPlPlanCurrency" type="text" maxlength="10" placeholder="INR" />
            </label>
            <label class="pm-field" style="min-width:0;">
                <span>Planned Effort (days)</span>
                <input class="pm-input" id="oaPlPlanEffort" type="number" min="0" step="0.5" />
            </label>
        </div>
        <label class="pm-field" style="margin-top:10px;">
            <span>Objectives</span>
            <textarea class="pm-input" id="oaPlPlanObjectives" rows="3" maxlength="8000"></textarea>
        </label>
        <div style="display:grid; grid-template-columns:minmax(0,1fr) minmax(0,1fr); gap:10px; align-items:start; margin-top:10px;">
            <label class="pm-field" style="min-width:0;">
                <span>Planned Coverage</span>
                <textarea class="pm-input" id="oaPlPlanCoverage" rows="3" maxlength="8000" placeholder="Units, processes, locations the plan covers"></textarea>
            </label>
            <label class="pm-field" style="min-width:0;">
                <span>Resources</span>
                <textarea class="pm-input" id="oaPlPlanResources" rows="3" maxlength="2000" placeholder="Auditors, co-sourced teams, tools"></textarea>
            </label>
        </div>
        <label class="pm-field" style="margin-top:10px;">
            <span>Description</span>
            <textarea class="pm-input" id="oaPlPlanDescription" rows="3" maxlength="4000"></textarea>
        </label>""")

# ---------------------------------------------------------------- engagement dialog: programme
rep("""        <div style="display:grid; grid-template-columns:1fr 100px; gap:10px; align-items:start;">
            <label class="pm-field">
                <span>Engagement Name</span>""",
"""        @* 565: every engagement belongs to a programme of the plan. *@
        <label class="pm-field">
            <span>Programme <span class="required">*</span></span>
            <select class="pm-input" id="oaPlItemProgramme"></select>
        </label>
        <div style="display:grid; grid-template-columns:1fr 100px; gap:10px; align-items:start; margin-top:10px;">
            <label class="pm-field">
                <span>Engagement Name</span>""")

# ---------------------------------------------------------------- state
rep("""        expanded    : new Set(),   // open plans (their slots shown)
        showAll     : new Set(),   // open plans showing every slot
        itemsByPlan : {},          // planId -> slot rows""",
"""        expanded    : new Set(),   // open plans (their programmes shown)
        showAll     : new Set(),   // 'planId:programmeId' showing every engagement
        itemsByPlan : {},          // planId -> engagement rows
        // 565: programmes
        methodologies     : [],          // the Planning Methodology master
        programmesByPlan  : {},          // planId -> programme rows
        openProgrammes    : new Set(),   // 'planId:programmeId' showing its engagements
        progForm          : null,        // { planId, programmeId|null } -- the inline form open
        revisionsOpen     : new Set(),   // plans showing their revision history
        revisionsByPlan   : {},
        presetProgrammeId : null,        // Add Engagement from a programme""")

# ---------------------------------------------------------------- boot: methodologies
rep("""        try { await Promise.all([loadStatuses(), loadPlanTypes()]); } catch (_) {}""",
"""        try { await Promise.all([loadStatuses(), loadPlanTypes(), loadMethodologies()]); } catch (_) {}""")
rep("""    async function loadDefinitions(orgId) {""",
"""    // 565: the Planning Methodology master (a programme picks one).
    async function loadMethodologies() {
        const r = await fetch(U(API + '/planning-methodologies'), { credentials: 'same-origin' });
        if (!r.ok) return;
        const b = await r.json();
        state.methodologies = (b && (b.data || b.Data)) || [];
    }
    async function loadDefinitions(orgId) {""")
rep("""            state.expanded.clear(); state.showAll.clear(); state.itemsByPlan = {};""",
"""            state.expanded.clear(); state.showAll.clear(); state.itemsByPlan = {};
            state.programmesByPlan = {}; state.openProgrammes.clear(); state.progForm = null;   // 565
            state.revisionsOpen.clear(); state.revisionsByPlan = {};""")

# ---------------------------------------------------------------- plan rows
rep("""            const items  = row.itemCount || row.ItemCount || 0;""",
"""            const items  = row.itemCount || row.ItemCount || 0;
            // 565: programmes, and planned vs actual.
            const progs  = row.programmeCount ?? row.ProgrammeCount ?? 0;
            const inProg = row.engagementInProgressCount ?? row.EngagementInProgressCount ?? 0;
            const done   = row.engagementCompletedCount  ?? row.EngagementCompletedCount  ?? 0;""")
rep("""                 + '<td style="text-align:right;">' + wf.escape(String(items)) + '</td>'
                 + '<td>' + wf.badge(stName) + '</td>'
                 + '<td>' + trigger(id, 'plan') + '</td>'""",
"""                 + '<td style="text-align:right;">' + wf.escape(String(progs)) + '</td>'
                 + '<td>' + wf.escape(plannedVsActual(items, inProg, done)) + '</td>'
                 + '<td>' + wf.badge(stName) + '</td>'
                 + '<td>' + trigger(id, 'plan') + '</td>'""")
rep("""                 + ' aria-expanded="' + (open ? 'true' : 'false') + '" title="Show the engagements">'
                 + '<i class="fa-solid fa-chevron-right" aria-hidden="true"></i>'
                 + '<span class="visually-hidden">Show the engagements</span></button>'""",
"""                 + ' aria-expanded="' + (open ? 'true' : 'false') + '" title="Show the programmes">'
                 + '<i class="fa-solid fa-chevron-right" aria-hidden="true"></i>'
                 + '<span class="visually-hidden">Show the programmes</span></button>'""")

# ---------------------------------------------------------------- loadItems: programmes too
rep("""        if (!state.itemsByPlan[pid]) host.innerHTML = '<p class="pm-hint" style="margin:0;">Loading engagements...</p>';
        try {
            const url = U(API + '/plans/' + pid + '/items?organizationId=' + encodeURIComponent(state.orgId));
            const r = await fetch(url, { credentials: 'same-origin' });
            if (!r.ok) throw new Error('HTTP ' + r.status);
            const b = await r.json();
            const rows = (b && (b.data || b.Data)) || [];
            state.itemsByPlan[pid] = rows;
            rows.forEach(function (row) { state.itemsById[String(row.planItemId || row.PlanItemId)] = row; });
            renderItems(pid);
        } catch (err) {
            host.innerHTML = '<p class="pm-hint" style="margin:0;">Engagements could not be loaded: ' + wf.escape(err.message || err) + '</p>';
        }""",
"""        if (!state.itemsByPlan[pid]) host.innerHTML = '<p class="pm-hint" style="margin:0;">Loading programmes...</p>';
        try {
            // 565: the plan's programmes and its engagements.
            const q = '?organizationId=' + encodeURIComponent(state.orgId);
            const both = await Promise.all([
                fetch(U(API + '/plans/' + pid + '/items' + q), { credentials: 'same-origin' }),
                fetch(U(API + '/plans/' + pid + '/programmes' + q), { credentials: 'same-origin' })
            ]);
            if (!both[0].ok) throw new Error('HTTP ' + both[0].status);
            if (!both[1].ok) throw new Error('HTTP ' + both[1].status);
            const b = await both[0].json();
            const rows = (b && (b.data || b.Data)) || [];
            const pb = await both[1].json();
            state.programmesByPlan[pid] = (pb && (pb.data || pb.Data)) || [];
            state.itemsByPlan[pid] = rows;
            rows.forEach(function (row) { state.itemsById[String(row.planItemId || row.PlanItemId)] = row; });
            if (state.revisionsOpen.has(pid)) await loadRevisions(pid);
            renderItems(pid);
        } catch (err) {
            host.innerHTML = '<p class="pm-hint" style="margin:0;">Programmes could not be loaded: ' + wf.escape(err.message || err) + '</p>';
        }""")

# ---------------------------------------------------------------- renderItems -> programmes + nested engagements
i0 = s.index("    function renderItems(planId) {")
i1 = s.index("    // Add Item / Show all inside a plan's child row.")
s = s[:i0] + r"""    // 565: the child row under a plan -- a facts line, its PROGRAMMES (each
    // opens its engagements in a row under it), the inline programme form,
    // and the revision history.
    function renderItems(planId) {
        const pid  = String(planId);
        const host = itemsRow(pid);
        if (!host) return;
        const plan  = state.plansById[pid] || {};
        const progs = state.programmesByPlan[pid] || [];
        const all   = state.itemsByPlan[pid] || [];
        const editable = planEditable(pid);
        const facts = [
            'Version ' + (plan.version ?? plan.Version ?? 1),
            plan.financialYear || plan.FinancialYear || '',
            (plan.methodologies || plan.Methodologies) ? 'Methodologies: ' + (plan.methodologies || plan.Methodologies) : '',
            'Planned vs actual: ' + plannedVsActual(plan.itemCount ?? plan.ItemCount ?? all.length,
                plan.engagementInProgressCount ?? plan.EngagementInProgressCount ?? 0,
                plan.engagementCompletedCount  ?? plan.EngagementCompletedCount  ?? 0)
        ].filter(Boolean).join(' · ');
        const version = Number(plan.version ?? plan.Version ?? 1);
        const revLink = version > 1
            ? '<a href="#" class="oa-pl-more" data-revisions="' + pid + '">'
              + (state.revisionsOpen.has(pid) ? 'Hide' : 'Show') + ' revision history</a>' : '';
        const addProg = editable && !(state.progForm && String(state.progForm.planId) === pid && state.progForm.programmeId == null)
            ? '<a href="#" class="oa-pl-add" data-add-programme="' + pid + '"><i class="fa-solid fa-plus" aria-hidden="true"></i> Add Programme</a>' : '';
        const newForm = state.progForm && String(state.progForm.planId) === pid && state.progForm.programmeId == null
            ? programmeFormRow(pid, null) : '';

        let html = '<p class="oa-pl-plan-facts">' + wf.escape(facts) + '</p>';
        if (!progs.length && !newForm) {
            html += '<p class="pm-hint" style="margin:0 0 6px;">No programmes yet. A plan groups its engagements into programmes; add one first.'
                  + (editable ? '' : ' Programmes can be added only while the plan is Draft or Submitted.') + '</p>';
        } else {
            html += '<div class="pm-table-wrap"><table><thead><tr>'
                  + '<th>Code</th><th>Programme</th><th>Planning Methodology</th><th>Owner</th><th>Engagements</th><th style="width:70px;"></th>'
                  + '</tr></thead><tbody>'
                  + progs.map(function (g) {
                        const gid  = String(g.programmeId ?? g.ProgrammeId);
                        const key  = pid + ':' + gid;
                        const open = state.openProgrammes.has(key);
                        if (state.progForm && String(state.progForm.planId) === pid && String(state.progForm.programmeId) === gid)
                            return programmeFormRow(pid, g);
                        const owner = wf.personWithRole(g.ownerDisplayName || g.OwnerDisplayName, g.ownerRoleName || g.OwnerRoleName);
                        return '<tr class="pm-row-clickable' + (open ? ' oa-pl-prog-open' : '') + '" data-programme="' + gid + '" data-plan="' + pid + '">'
                             + '<td><span class="task-tree-cell">'
                             + '<button type="button" class="task-tree-toggle' + (open ? ' is-open' : '') + '" aria-expanded="' + (open ? 'true' : 'false') + '" title="Show the engagements">'
                             + '<i class="fa-solid fa-chevron-right" aria-hidden="true"></i><span class="visually-hidden">Show the engagements</span></button>'
                             + '<span>' + wf.escape(g.programmeCode || g.ProgrammeCode || '') + '</span></span></td>'
                             + '<td>' + wf.escape(g.programmeName || g.ProgrammeName || '') + '</td>'
                             + '<td>' + wf.escape(g.methodologyName || g.MethodologyName || 'Not set') + '</td>'
                             + '<td>' + wf.escape(owner) + '</td>'
                             + '<td>' + wf.escape(plannedVsActual(g.engagementCount ?? g.EngagementCount ?? 0,
                                    g.engagementInProgressCount ?? g.EngagementInProgressCount ?? 0,
                                    g.engagementCompletedCount ?? g.EngagementCompletedCount ?? 0)) + '</td>'
                             + '<td>' + trigger(gid, 'programme') + '</td>'
                             + '</tr>'
                             + (open ? '<tr class="oa-pl-prog-items"><td colspan="6">' + engagementsHtml(pid, gid) + '</td></tr>' : '');
                    }).join('')
                  + newForm
                  + '</tbody></table></div>';
        }
        // Engagements without a programme (only before 565's backfill ran).
        const loose = all.filter(function (r) { return (r.programmeId ?? r.ProgrammeId) == null; });
        if (loose.length && progs.length) html += '<p class="pm-hint" style="margin:8px 0 4px;">Not in a programme yet (edit to pick one):</p>' + engagementsHtml(pid, null);
        else if (loose.length) html += engagementsHtml(pid, null);
        html += '<div class="oa-pl-items-foot">' + addProg + revLink + '</div>';
        if (state.revisionsOpen.has(pid)) html += revisionsHtml(pid);
        host.innerHTML = html;
        if (state.progForm && String(state.progForm.planId) === pid) attachProgrammeOwner();
    }

    // "5 planned, 1 in progress, 2 completed" -- planned vs actual.
    function plannedVsActual(total, inProg, done) {
        const t = Number(total) || 0, p = Number(inProg) || 0, d = Number(done) || 0;
        return t + ' planned' + (p ? ', ' + p + ' in progress' : '') + (d ? ', ' + d + ' completed' : '');
    }

    // A programme's engagements (programmeId null: those without one) --
    // the engagement grid of 552, unchanged.
    function engagementsHtml(planId, programmeId) {
        const pid  = String(planId);
        const key  = pid + ':' + (programmeId == null ? '' : String(programmeId));
        const all  = (state.itemsByPlan[pid] || []).filter(function (r) {
            const g = r.programmeId ?? r.ProgrammeId;
            return programmeId == null ? g == null : String(g) === String(programmeId);
        });
        const shown = state.showAll.has(key) ? all : all.slice(0, SLOT_CAP);
        const addLink = planEditable(pid) && programmeId != null
            ? '<a href="#" class="oa-pl-add" data-add-item="' + pid + '" data-add-programme-item="' + wf.escape(String(programmeId)) + '"><i class="fa-solid fa-plus" aria-hidden="true"></i> Add Engagement</a>'
            : '';
        if (!all.length) {
            return '<p class="pm-hint" style="margin:0 0 6px;">No engagements in this programme yet.'
                + (planEditable(pid) ? '' : ' Engagements can be added only while the plan is Draft or Submitted.') + '</p>' + addLink;
        }
        return '<div class="pm-table-wrap"><table><thead><tr>'
            + '<th style="width:70px;">Order</th><th>Engagement</th><th>Audits</th><th>Scheduled</th><th>Auditor</th>'
            + '<th>Team / Department</th><th>Status</th><th style="width:70px;"></th>'
            + '</tr></thead><tbody>'
            + shown.map(function (row) {
""" + s[s.index("                const id       = row.planItemId  || row.PlanItemId;", i0):s.index("            + '</tbody></table></div>'\n            + '<div class=\"oa-pl-items-foot\">' + addLink", i0)] + r"""            + '</tbody></table></div>'
            + '<div class="oa-pl-items-foot">' + addLink
            + (all.length > shown.length
                ? '<a href="#" class="oa-pl-more" data-show-all="' + wf.escape(key) + '">Show all ' + all.length + ' engagements</a>' : '')
            + '</div>';
    }

    // The inline programme form (565, no popups): a row of the programme
    // table -- for a new programme at the bottom, for an edit in place.
    function programmeFormRow(planId, g) {
        const v = function (a, b) { return g ? (g[a] ?? g[b] ?? '') : ''; };
        const mid = String(v('planningMethodologyId', 'PlanningMethodologyId'));
        const opts = '<option value="">-- select --</option>' + state.methodologies.map(function (m) {
            const id = String(m.id ?? m.Id);
            return '<option value="' + wf.escape(id) + '"' + (id === mid ? ' selected' : '') + '>' + wf.escape(m.name || m.Name || '') + '</option>';
        }).join('');
        return '<tr class="oa-pl-prog-form" data-prog-form="' + wf.escape(String(planId)) + '"><td colspan="6">'
             + '<div class="pm-message" id="oaPlPgMessage" style="display:none; margin-bottom:8px;"></div>'
             + '<div style="display:grid; grid-template-columns:minmax(0,2fr) minmax(0,1fr) 90px; gap:10px; align-items:start;">'
             +   '<label class="pm-field" style="min-width:0;"><span>Programme <span class="required">*</span></span>'
             +     '<input class="pm-input" id="oaPlPgName" type="text" maxlength="240" value="' + wf.escape(v('programmeName', 'ProgrammeName'))
             +     '" placeholder="e.g. Information Systems Audit Programme" /></label>'
             +   '<label class="pm-field" style="min-width:0;"><span>Planning Methodology <span class="required">*</span></span>'
             +     '<select class="pm-input" id="oaPlPgMethod">' + opts + '</select></label>'
             +   '<label class="pm-field" style="min-width:0;"><span>Order</span>'
             +     '<input class="pm-input" id="oaPlPgOrder" type="number" min="1" step="1" value="' + wf.escape(String(v('displayOrder', 'DisplayOrder'))) + '" /></label>'
             + '</div>'
             + '<div class="pm-field" style="min-width:0; margin-top:10px;"><span>Owner</span>'
             +   '<div style="display:grid; grid-template-columns:minmax(0,1fr) minmax(0,1fr); gap:6px; margin-top:2px;">'
             +     '<select class="pm-input" id="oaPlPgOwnerRole" style="min-width:0;" aria-label="Owner Role"><option value="">Loading roles...</option></select>'
             +     '<select class="pm-input" id="oaPlPgOwner" style="min-width:0;" aria-label="Owner Employee"><option value="">-- pick a role first --</option></select>'
             +   '</div></div>'
             + '<label class="pm-field" style="margin-top:10px;"><span>Objective</span>'
             +   '<textarea class="pm-input" id="oaPlPgObjective" rows="2" maxlength="4000">' + wf.escape(v('objective', 'Objective')) + '</textarea></label>'
             + '<div class="pm-dialog-actions">'
             +   '<button type="button" class="pm-button" data-prog-cancel>Cancel</button>'
             +   '<button type="button" class="pm-button primary" data-prog-save>Save Programme</button>'
             + '</div>'
             + '</td></tr>';
    }
    // The form's owner pickers (121 role + current holder).
    function attachProgrammeOwner() {
        if (!state.orgId || !window.__roleHolderPicker || !document.getElementById('oaPlPgOwnerRole')) return;
        const pid = String(state.progForm.planId);
        const g = (state.programmesByPlan[pid] || []).find(function (x) {
            return String(x.programmeId ?? x.ProgrammeId) === String(state.progForm.programmeId);
        }) || {};
        window.__roleHolderPicker.attach({
            organizationId     : Number(state.orgId),
            roleSelectId       : 'oaPlPgOwnerRole',
            employeeSelectId   : 'oaPlPgOwner',
            initialRoleId      : g.ownerRoleId      ?? g.OwnerRoleId,
            initialRoleName    : g.ownerRoleName    || g.OwnerRoleName,
            initialEmployeeId  : g.ownerEmployeeId  ?? g.OwnerEmployeeId,
            initialEmployeeName: g.ownerDisplayName || g.OwnerDisplayName,
            allowEmpty         : true
        }).catch(function () { /* soft-fail, as the plan owner */ });
    }
    function openProgrammeForm(planId, programmeId) {
        state.progForm = { planId: String(planId), programmeId: programmeId == null ? null : String(programmeId) };
        if (!state.expanded.has(String(planId))) { state.expanded.add(String(planId)); setToggle(planId, true); loadItems(planId); return; }
        renderItems(planId);
    }
    async function saveProgramme() {
        const f = state.progForm;
        if (!f) return;
        const msg = function (t) {
            const el = document.getElementById('oaPlPgMessage');
            if (!el) return;
            el.style.display = t ? 'block' : 'none';
            el.style.background = 'var(--danger-100)'; el.style.color = 'var(--danger-700)';
            el.textContent = t || '';
        };
        const name = document.getElementById('oaPlPgName').value.trim();
        const method = document.getElementById('oaPlPgMethod').value;
        if (!name) { msg('The programme needs a name.'); return; }
        if (!method) { msg('Pick the planning methodology.'); return; }
        const owner = (window.__roleHolderPicker && typeof window.__roleHolderPicker.readState === 'function')
            ? window.__roleHolderPicker.readState('oaPlPgOwnerRole', 'oaPlPgOwner')
            : { roleId: null, roleName: null, employeeId: null, employeeName: null };
        const order = document.getElementById('oaPlPgOrder').value;
        try {
            const r = await fetch(U(API + '/plan-programmes'), {
                method: 'POST', credentials: 'same-origin',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    organizationId        : Number(state.orgId),
                    planId                : Number(f.planId),
                    programmeId           : f.programmeId != null ? Number(f.programmeId) : null,
                    programmeName         : name,
                    objective             : document.getElementById('oaPlPgObjective').value.trim() || null,
                    planningMethodologyId : Number(method),
                    ownerRoleId           : owner.roleId       || null,
                    ownerRoleName         : owner.roleName     || null,
                    ownerEmployeeId       : owner.employeeId   || null,
                    ownerDisplayName      : owner.employeeName || null,
                    displayOrder          : order ? Number(order) : null,
                    actor                 : null
                })
            });
            const j = await safeJson(r);
            if (!r.ok) { msg((j && (j.error || j.Error)) || ('HTTP ' + r.status)); return; }
            state.progForm = null;
            reloadPlans();   // counts and methodologies; the open plan re-reads its programmes
        } catch (err) { msg(err.message || String(err)); }
    }
    async function deleteProgramme(planId, programmeId) {
        if (!await window.gracUi.confirm('Remove this programme from the plan? It must have no engagements.',
              { type: 'warning', title: 'Remove programme', confirmText: 'Remove' })) return;
        try {
            const r = await fetch(U(API + '/plans/' + encodeURIComponent(planId) + '/programmes/' + encodeURIComponent(programmeId)
                                    + '?organizationId=' + encodeURIComponent(state.orgId)), { method: 'DELETE', credentials: 'same-origin' });
            const j = await safeJson(r);
            if (!r.ok) { await window.gracUi.alert((j && (j.error || j.Error)) || ('HTTP ' + r.status), { type: 'error' }); return; }
            state.openProgrammes.delete(String(planId) + ':' + String(programmeId));
            reloadPlans();
        } catch (err) { await window.gracUi.alert(err.message || String(err), { type: 'error' }); }
    }

    // 565: plan revision -- reason, back to Draft, version + 1.
    async function revisePlan(planId) {
        // gracUi.promptRequired: a blank reason asks again; Cancel is null.
        const reason = await window.gracUi.promptRequired('Why is the plan being revised? It goes back to Draft (version + 1) and must be submitted and approved again. Running audits continue.',
            { title: 'Revise plan', confirmText: 'Revise', multiline: true });
        if (reason === null) return;
        try {
            const r = await fetch(U(API + '/plans/' + encodeURIComponent(planId) + '/revise'), {
                method: 'POST', credentials: 'same-origin',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ organizationId: Number(state.orgId), planId: Number(planId), reason: String(reason).trim(), actor: null })
            });
            const j = await safeJson(r);
            if (!r.ok) { await window.gracUi.alert((j && (j.error || j.Error)) || ('HTTP ' + r.status), { type: 'error' }); return; }
            state.revisionsByPlan[String(planId)] = null;
            state.expanded.add(String(planId));
            reloadPlans();
        } catch (err) { await window.gracUi.alert(err.message || String(err), { type: 'error' }); }
    }
    async function loadRevisions(planId) {
        const pid = String(planId);
        try {
            const r = await fetch(U(API + '/plans/' + pid + '/revisions?organizationId=' + encodeURIComponent(state.orgId)), { credentials: 'same-origin' });
            const b = r.ok ? await r.json() : null;
            state.revisionsByPlan[pid] = (b && (b.data || b.Data)) || [];
        } catch (_) { state.revisionsByPlan[pid] = []; }
    }
    function revisionsHtml(planId) {
        const rows = state.revisionsByPlan[String(planId)] || [];
        if (!rows.length) return '<p class="pm-hint" style="margin:8px 0 0;">No revisions recorded.</p>';
        return '<div class="pm-table-wrap" style="margin-top:8px;"><table><thead><tr>'
             + '<th>Version</th><th>Was</th><th>Reason</th><th>Revised by</th><th>On</th></tr></thead><tbody>'
             + rows.map(function (x) {
                   return '<tr><td>' + wf.escape(String(x.fromVersion ?? x.FromVersion) + ' → ' + String(x.toVersion ?? x.ToVersion)) + '</td>'
                        + '<td>' + wf.escape(x.fromStatusCode || x.FromStatusCode || '') + '</td>'
                        + '<td>' + wf.escape(x.reason || x.Reason || '') + '</td>'
                        + '<td>' + wf.escape(x.revisedBy || x.RevisedBy || '') + '</td>'
                        + '<td>' + wf.escape(onlyDate(x.revisedDt || x.RevisedDt)) + '</td></tr>';
               }).join('')
             + '</tbody></table></div>';
    }

    // 565: programme rows open / close their engagements; the inline form,
    // Add Programme and the revision history.
    document.getElementById('oaPlPlanBody').addEventListener('click', async function (e) {
        if (e.target.closest('[data-prog-save]'))   { e.preventDefault(); saveProgramme(); return; }
        if (e.target.closest('[data-prog-cancel]')) {
            e.preventDefault();
            const pid = state.progForm && state.progForm.planId;
            state.progForm = null;
            if (pid) renderItems(pid);
            return;
        }
        const addProg = e.target.closest('[data-add-programme]');
        if (addProg) { e.preventDefault(); openProgrammeForm(addProg.getAttribute('data-add-programme'), null); return; }
        const rev = e.target.closest('[data-revisions]');
        if (rev) {
            e.preventDefault();
            const pid = rev.getAttribute('data-revisions');
            if (state.revisionsOpen.has(pid)) state.revisionsOpen.delete(pid);
            else { state.revisionsOpen.add(pid); await loadRevisions(pid); }
            renderItems(pid);
            return;
        }
        if (e.target.closest('.pm-action-trigger, .pm-action-menu, a, input, select, textarea, button:not(.task-tree-toggle)')) return;
        const tr = e.target.closest('tr[data-programme]');
        if (!tr) return;
        const key = tr.getAttribute('data-plan') + ':' + tr.getAttribute('data-programme');
        if (state.openProgrammes.has(key)) state.openProgrammes.delete(key); else state.openProgrammes.add(key);
        renderItems(tr.getAttribute('data-plan'));
    });

""" + s[i1:]

# Add Engagement / Show all handlers: the programme and the show-all key.
rep("""        const add = e.target.closest('[data-add-item]');
        if (add) {
            e.preventDefault();
            state.selectedPlanId = Number(add.getAttribute('data-add-item'));
            state.selectedPlan   = state.plansById[String(state.selectedPlanId)] || null;
            openItemDialog(null);
            return;
        }
        const more = e.target.closest('[data-show-all]');
        if (more) {
            e.preventDefault();
            const pid = more.getAttribute('data-show-all');
            state.showAll.add(pid);
            renderItems(pid);
        }""",
"""        const add = e.target.closest('[data-add-item]');
        if (add) {
            e.preventDefault();
            state.selectedPlanId = Number(add.getAttribute('data-add-item'));
            state.selectedPlan   = state.plansById[String(state.selectedPlanId)] || null;
            state.presetProgrammeId = add.getAttribute('data-add-programme-item');   // 565
            openItemDialog(null);
            return;
        }
        const more = e.target.closest('[data-show-all]');
        if (more) {
            e.preventDefault();
            const key = more.getAttribute('data-show-all');   // 565: 'planId:programmeId'
            state.showAll.add(key);
            renderItems(key.split(':')[0]);
        }""")

# togglePlan: closing a plan forgets its open programmes' show-all keys
rep("""            state.expanded.delete(pid);
            state.showAll.delete(pid);""",
"""            state.expanded.delete(pid);
            Array.from(state.showAll).forEach(function (k) { if (k.split(':')[0] === pid) state.showAll.delete(k); });   // 565""")
rep("""            state.expanded.delete(String(id)); state.showAll.delete(String(id));""",
"""            state.expanded.delete(String(id));
            Array.from(state.showAll).forEach(function (k) { if (k.split(':')[0] === String(id)) state.showAll.delete(k); });   // 565""")

# ---------------------------------------------------------------- plan dialog load / save
rep("""                document.getElementById('oaPlPlanDescription').value = d.description || d.Description || '';""",
"""                document.getElementById('oaPlPlanDescription').value = d.description || d.Description || '';
                // 565: the annual plan fields.
                document.getElementById('oaPlPlanFy').value         = d.financialYear   || d.FinancialYear   || '';
                document.getElementById('oaPlPlanBudget').value     = (d.plannedBudget ?? d.PlannedBudget) != null ? String(d.plannedBudget ?? d.PlannedBudget) : '';
                document.getElementById('oaPlPlanCurrency').value   = d.budgetCurrency  || d.BudgetCurrency  || '';
                document.getElementById('oaPlPlanEffort').value     = (d.plannedEffortDays ?? d.PlannedEffortDays) != null ? String(d.plannedEffortDays ?? d.PlannedEffortDays) : '';
                document.getElementById('oaPlPlanObjectives').value = d.objectives      || d.Objectives      || '';
                document.getElementById('oaPlPlanCoverage').value   = d.plannedCoverage || d.PlannedCoverage || '';
                document.getElementById('oaPlPlanResources').value  = d.resourcesNote   || d.ResourcesNote   || '';""")
rep("""            description       : document.getElementById('oaPlPlanDescription').value || null,
            actor             : null
        };""",
"""            description       : document.getElementById('oaPlPlanDescription').value || null,
            // 565: the annual plan fields.
            financialYear     : document.getElementById('oaPlPlanFy').value.trim() || null,
            plannedBudget     : document.getElementById('oaPlPlanBudget').value !== '' ? Number(document.getElementById('oaPlPlanBudget').value) : null,
            budgetCurrency    : document.getElementById('oaPlPlanCurrency').value.trim() || null,
            plannedEffortDays : document.getElementById('oaPlPlanEffort').value !== '' ? Number(document.getElementById('oaPlPlanEffort').value) : null,
            objectives        : document.getElementById('oaPlPlanObjectives').value.trim() || null,
            plannedCoverage   : document.getElementById('oaPlPlanCoverage').value.trim() || null,
            resourcesNote     : document.getElementById('oaPlPlanResources').value.trim() || null,
            actor             : null
        };""")

# ---------------------------------------------------------------- engagement dialog: the programme select
rep("""    async function openItemDialog(id) {
        if (!state.selectedPlanId) { alert('Pick a plan first.'); return; }
        clearItemMessage();
        state.engDefs = [];""",
"""    // 565: the plan's programmes; the engagement's (or the one it was added
    // from) chosen; a plan with one programme has it chosen.
    async function fillProgrammes(selectedId) {
        const pid = String(state.selectedPlanId);
        if (!state.programmesByPlan[pid]) {
            try {
                const r = await fetch(U(API + '/plans/' + pid + '/programmes?organizationId=' + encodeURIComponent(state.orgId)), { credentials: 'same-origin' });
                const b = r.ok ? await r.json() : null;
                state.programmesByPlan[pid] = (b && (b.data || b.Data)) || [];
            } catch (_) { state.programmesByPlan[pid] = []; }
        }
        const progs = state.programmesByPlan[pid];
        const sel = document.getElementById('oaPlItemProgramme');
        sel.innerHTML = (progs.length ? '<option value="">-- select a programme --</option>'
                                      : '<option value="">(no programmes -- add one to the plan first)</option>')
            + progs.map(function (g) {
                  return '<option value="' + wf.escape(String(g.programmeId ?? g.ProgrammeId)) + '">'
                       + wf.escape((g.programmeCode || g.ProgrammeCode || '') + ' - ' + (g.programmeName || g.ProgrammeName || '')) + '</option>';
              }).join('');
        if (selectedId != null && selectedId !== '') sel.value = String(selectedId);
        else if (progs.length === 1) sel.value = String(progs[0].programmeId ?? progs[0].ProgrammeId);
    }

    async function openItemDialog(id) {
        if (!state.selectedPlanId) { alert('Pick a plan first.'); return; }
        clearItemMessage();
        state.engDefs = [];""")
rep("""                document.getElementById('oaPlItemName').value = row.engagementName || row.EngagementName || '';""",
"""                document.getElementById('oaPlItemName').value = row.engagementName || row.EngagementName || '';
                await fillProgrammes(row.programmeId ?? row.ProgrammeId);   // 565""")
rep("""            document.getElementById('oaPlItemDialogTitle').textContent = 'Add Engagement';
            document.getElementById('oaPlItemForm').reset();
            document.getElementById('oaPlItemEditId').value = '';""",
"""            document.getElementById('oaPlItemDialogTitle').textContent = 'Add Engagement';
            document.getElementById('oaPlItemForm').reset();
            document.getElementById('oaPlItemEditId').value = '';
            await fillProgrammes(state.presetProgrammeId);   // 565
            state.presetProgrammeId = null;""")
rep("""        if (!state.engDefs.length) { showItemMessage('error', 'Add at least one audit to the engagement.'); return; }""",
"""        if (!state.engDefs.length) { showItemMessage('error', 'Add at least one audit to the engagement.'); return; }
        // 565: every engagement belongs to a programme.
        const programmeId = document.getElementById('oaPlItemProgramme').value;
        if (!programmeId) { showItemMessage('error', 'Pick the programme this engagement belongs to.'); return; }""")
rep("""            engagementName              : document.getElementById('oaPlItemName').value.trim() || null,   // 552""",
"""            engagementName              : document.getElementById('oaPlItemName').value.trim() || null,   // 552
            programmeId                 : Number(programmeId),                                            // 565""")

# ---------------------------------------------------------------- menus
rep("""            if (statusCode === 'Active')    items.push({ icon: 'fa-flag-checkered', label: 'Close', action: function () { transition(id, 'close');    } });""",
"""            if (statusCode === 'Active')    items.push({ icon: 'fa-flag-checkered', label: 'Close', action: function () { transition(id, 'close');    } });
            // 565: an Approved / Active plan is revised (back to Draft, version + 1).
            if (statusCode === 'Approved' || statusCode === 'Active')
                items.push({ icon: 'fa-code-branch', label: 'Revise', action: function () { revisePlan(id); } });""")
rep("""            if (statusCode === 'Draft' || statusCode === 'Submitted')
                items.push({ icon: 'fa-plus', label: 'Add Engagement', action: function () {""",
"""            // 565: a plan gets programmes first; engagements go into a programme.
            if (statusCode === 'Draft' || statusCode === 'Submitted')
                items.push({ icon: 'fa-layer-group', label: 'Add Programme', action: function () { openProgrammeForm(id, null); } });
            if (statusCode === 'Draft' || statusCode === 'Submitted')
                items.push({ icon: 'fa-plus', label: 'Add Engagement', action: function () {""")
rep("""        // 546: Edit / Remove while the plan is Draft or Submitted and the
        // slot has no execution;""",
"""        // 565: a programme -- Edit / Add Engagement / Remove while the plan
        // is Draft or Submitted.
        if (kind === 'programme') {
            const pid = String(state.selectedPlanId);
            const progMenu = [];
            if (planEditable(pid)) {
                progMenu.push({ icon: 'fa-pen', label: 'Edit', action: function () { openProgrammeForm(pid, id); } });
                progMenu.push({ icon: 'fa-plus', label: 'Add Engagement', action: function () {
                    state.presetProgrammeId = String(id);
                    openItemDialog(null);
                } });
                progMenu.push({ icon: 'fa-trash', label: 'Remove', action: function () { deleteProgramme(pid, id); } });
            }
            return progMenu;
        }
        // 546: Edit / Remove while the plan is Draft or Submitted and the
        // slot has no execution;""")
rep("""                if (kind === 'item' && tr && tr.getAttribute('data-plan')) {""",
"""                if ((kind === 'item' || kind === 'programme') && tr && tr.getAttribute('data-plan')) {   // 565: programmes too""")

open(F, 'w', encoding='utf-8').write(s)
print('web565 ok')
