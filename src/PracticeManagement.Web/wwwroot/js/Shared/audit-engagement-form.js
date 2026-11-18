// =====================================================================
// js/Shared/audit-engagement-form.js  --  window.gracEngagementForm
//
// 566 (Audit Change spec 4.5): the Audit Engagement form, shared by Audit
// Plans (a planned engagement, in a programme of the plan) and Audit
// Engagements (both kinds; an independent engagement needs no plan but an
// initiation source, the reason and the authority's approval). Extracted
// from org-assurance-plans.cshtml (552 / 553 / 554 / 565): the audits dual
// list, the programme, the auditor list, the branch list and View Scope
// are the same code moved here, not copies.
//
// Markup: Partials/_audit-engagement-form.cshtml (full view, as the plan
// form). Needs _workflow-common (window.__wfCommon, __roleHolderPicker)
// and js/Shared/checkcombo.js (team members, subject matter experts).
//
//   gracEngagementForm.open({
//       orgId,                      required
//       origin,                     'PLANNED' | 'INDEPENDENT' (new ones)
//       engagementId,               edit / team -- null for a new one
//       mode,                       'edit' (default) | 'team' (only the team)
//       planId, planLabel,          a planned one: its plan
//       presetProgrammeId,          Add Engagement from a programme
//       presetDefinitionId,         Add to Plan from an audit
//       itemCount,                  the plan's engagements (the next order)
//       definitions,                the host's audit list, if it has one
//       preset,                     583: a new one's starting values
//                                   { name, subject, from, to, objective }
//                                   (Audit Plan Recommendations -> Accept)
//       onSaved })                  called after a save
//   gracEngagementForm.openScope(orgId, body, subtitle)
//       body { planItemId } or { definitionIds, locationId }
//   gracEngagementForm.startExecution(orgId, planId, engagementId, name)
//       -> true when started (planId null for an independent one)
// =====================================================================
(function () {
    'use strict';

    const API = '/practice/api/org-assurance';
    const U   = p => String(window.appBasePath || window.pmPathBase || '').replace(/\/+$/, '') + p;
    const $   = id => document.getElementById(id);

    const S = {
        opts        : null,
        orgId       : '',
        origin      : 'PLANNED',
        mode        : 'edit',
        detail      : null,     // GET engagements/{id} (edit / team)
        definitions : [],
        defsOrg     : null,
        engDefs     : [],       // the selected audits, in order (ids as strings)
        auditors    : [],       // 553: people whose role carries Auditor
        employees   : [],       // subject matter experts: any active employee
        empOrg      : null,
        sources     : null,     // initiation sources
        plans       : [],       // an independent one may refer to a plan
        plansOrg    : null,
        wired       : false
    };

    function esc(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }
    function v(o, a, b) { return o ? (o[a] !== undefined ? o[a] : o[b]) : undefined; }
    function rowsOf(b) {
        if (Array.isArray(b)) return b;
        return (b && (b.data || b.Data || b.rows || b.Rows)) || [];
    }
    function onlyDate(x) { return x ? String(x).substring(0, 10) : ''; }
    async function safeJson(r) { try { return await r.json(); } catch (_) { return null; } }
    async function getJson(path) {
        const r = await fetch(U(path), { credentials: 'same-origin' });
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
    }
    function message(text, kind) {
        const wf = window.__wfCommon;
        if (wf && wf.setMessage) { wf.setMessage('oaEngMessage', text || '', kind); return; }
        const el = $('oaEngMessage');
        el.textContent = text || '';
        el.style.display = text ? '' : 'none';
    }
    function show(el, on) { if (el) el.style.display = on ? '' : 'none'; }

    // -----------------------------------------------------------------
    // Lookups
    // -----------------------------------------------------------------
    async function loadDefinitions(orgId, given) {
        if (Array.isArray(given) && given.length) { S.definitions = given; S.defsOrg = orgId; return; }
        if (S.defsOrg === orgId && S.definitions.length) return;
        try {
            const b = await getJson(API + '/definitions?organizationId=' + encodeURIComponent(orgId) + '&page=1&pageSize=500');
            S.definitions = rowsOf(b);
        } catch (_) { S.definitions = []; }
        S.defsOrg = orgId;
    }
    async function loadAuditors(orgId) {
        try {
            const b = await getJson('/practice/api/org-roles/responsibility-holders?organizationId='
                                    + encodeURIComponent(orgId) + '&code=AUDITOR');
            S.auditors = rowsOf(b);
        } catch (_) { S.auditors = []; }
    }
    async function loadEmployees(orgId) {
        if (S.empOrg === orgId) return;
        try {
            S.employees = rowsOf(await getJson('/practice/api/document-uploads/lookups/employees?organizationId='
                                               + encodeURIComponent(orgId)));
        } catch (_) { S.employees = []; }
        S.empOrg = orgId;
    }
    async function loadSources() {
        if (S.sources) return;
        try { S.sources = rowsOf(await getJson(API + '/engagement-initiation-sources')); }
        catch (_) { S.sources = []; }
    }
    async function loadPlans(orgId) {
        if (S.plansOrg === orgId) return;
        try {
            S.plans = rowsOf(await getJson(API + '/plans?organizationId=' + encodeURIComponent(orgId) + '&page=1&pageSize=200'));
        } catch (_) { S.plans = []; }
        S.plansOrg = orgId;
    }

    // -----------------------------------------------------------------
    // The audits of the engagement (552): the dual list
    // -----------------------------------------------------------------
    function defById(id) {
        return S.definitions.find(function (d) { return String(d.definitionId || d.DefinitionId) === String(id); }) || null;
    }
    function isPlannable(d) {
        const st = d.currentStatusCode || d.CurrentStatusCode;
        return st === 'Active' || (!!(d.activeVersionId || d.ActiveVersionId) && st !== 'Retired');
    }
    function auditLabel(d, id) {
        if (!d) return 'Audit #' + id;
        const code = d.definitionCode || d.DefinitionCode || '';
        const name = d.definitionName || d.DefinitionName || '';
        const st   = d.currentStatusCode || d.CurrentStatusCode || '';
        return name + (code ? ' (' + code + ')' : '') + (st && st !== 'Active' ? '  --  ' + (d.currentStatusName || d.CurrentStatusName || st) : '');
    }
    function renderAuditLists() {
        const avail = $('oaEngAvail');
        const sel   = $('oaEngSel');
        const taken = new Set(S.engDefs);
        const list  = S.definitions.filter(function (d) { return isPlannable(d) && !taken.has(String(d.definitionId || d.DefinitionId)); })
            .sort(function (x, y) { return String(x.definitionName || x.DefinitionName || '').localeCompare(String(y.definitionName || y.DefinitionName || '')); });
        avail.innerHTML = '';
        list.forEach(function (d) {
            const o = document.createElement('option');
            o.value = String(d.definitionId || d.DefinitionId);
            o.textContent = auditLabel(d, o.value);
            avail.appendChild(o);
        });
        sel.innerHTML = '';
        S.engDefs.forEach(function (id) {
            const o = document.createElement('option');
            o.value = id;
            o.textContent = auditLabel(defById(id), id);
            sel.appendChild(o);
        });
        $('oaEngAvailCount').textContent = String(list.length);
        $('oaEngSelCount').textContent   = String(S.engDefs.length);
    }
    function moveAudits(add) {
        if (S.mode === 'team') return;
        const from = $(add ? 'oaEngAvail' : 'oaEngSel');
        const ids  = Array.prototype.filter.call(from.options, function (o) { return o.selected; })
                          .map(function (o) { return o.value; });
        if (!ids.length) return;
        if (add) ids.forEach(function (id) { if (S.engDefs.indexOf(id) < 0) S.engDefs.push(id); });
        else S.engDefs = S.engDefs.filter(function (id) { return ids.indexOf(id) < 0; });
        renderAuditLists();
    }
    function shiftAudit(delta) {
        if (S.mode === 'team') return;
        const sel = $('oaEngSel');
        const ids = Array.prototype.filter.call(sel.options, function (o) { return o.selected; }).map(function (o) { return o.value; });
        if (ids.length !== 1) return;
        const i = S.engDefs.indexOf(ids[0]), j = i + delta;
        if (i < 0 || j < 0 || j >= S.engDefs.length) return;
        S.engDefs.splice(j, 0, S.engDefs.splice(i, 1)[0]);
        renderAuditLists();
        Array.prototype.forEach.call($('oaEngSel').options, function (o) { o.selected = o.value === ids[0]; });
    }

    // -----------------------------------------------------------------
    // Plan / programme (565)
    // -----------------------------------------------------------------
    function fillPlanSelect(planId, planLabel) {
        const sel = $('oaEngPlan');
        if (S.origin === 'PLANNED') {
            sel.innerHTML = '<option value="' + esc(planId == null ? '' : String(planId)) + '">' + esc(planLabel || ('Plan #' + planId)) + '</option>';
            sel.disabled = true;
            return;
        }
        // Independent: a plan is optional (a reference).
        sel.disabled = S.mode === 'team';
        sel.innerHTML = '<option value="">-- none (not in a plan) --</option>' + S.plans.map(function (p) {
            return '<option value="' + esc(String(p.planId ?? p.PlanId)) + '">'
                 + esc((p.planCode || p.PlanCode || '') + ' - ' + (p.planName || p.PlanName || '')) + '</option>';
        }).join('');
        if (planId != null && planId !== '') {
            if (!Array.prototype.some.call(sel.options, function (o) { return o.value === String(planId); }))
                sel.insertAdjacentHTML('beforeend', '<option value="' + esc(String(planId)) + '">' + esc(planLabel || ('Plan #' + planId)) + '</option>');
            sel.value = String(planId);
        }
    }
    // The plan's programmes; the engagement's (or the one it was added
    // from) chosen; a planned engagement in a plan of one programme has it.
    async function fillProgrammes(planId, selectedId) {
        const sel = $('oaEngProgramme');
        let progs = [];
        if (planId) {
            try {
                progs = rowsOf(await getJson(API + '/plans/' + encodeURIComponent(planId)
                                            + '/programmes?organizationId=' + encodeURIComponent(S.orgId)));
            } catch (_) { progs = []; }
        }
        const planned = S.origin === 'PLANNED';
        sel.innerHTML = (planned
                ? (progs.length ? '<option value="">-- select a programme --</option>'
                                : '<option value="">(no programmes -- add one to the plan first)</option>')
                : '<option value="">-- none --</option>')
            + progs.map(function (g) {
                  return '<option value="' + esc(String(g.programmeId ?? g.ProgrammeId)) + '">'
                       + esc((g.programmeCode || g.ProgrammeCode || '') + ' - ' + (g.programmeName || g.ProgrammeName || '')) + '</option>';
              }).join('');
        if (selectedId != null && selectedId !== '') sel.value = String(selectedId);
        else if (planned && progs.length === 1) sel.value = String(progs[0].programmeId ?? progs[0].ProgrammeId);
        $('oaEngProgReq').style.display = planned ? '' : 'none';
    }

    // -----------------------------------------------------------------
    // People
    // -----------------------------------------------------------------
    // 553: the lead -- auditors only ("Name - Role"); one who is no longer
    // an auditor stays as an extra option so editing does not drop them.
    function auditorOption(id, name, rid, rname, extra) {
        const o = document.createElement('option');
        o.value = String(id);
        o.textContent = name + (rname ? ' - ' + rname : '') + (extra || '');
        o.setAttribute('data-name', name || '');
        o.setAttribute('data-role-id', rid != null ? String(rid) : '');
        o.setAttribute('data-role-name', rname || '');
        return o;
    }
    function fillAuditorSelect(selId, placeholder, empId, empName, roleId, roleName) {
        const sel = $(selId);
        sel.innerHTML = '';
        const ph = document.createElement('option');
        ph.value = '';
        ph.textContent = S.auditors.length ? placeholder : '(no auditors -- give a role the Auditor responsibility in Role Master)';
        sel.appendChild(ph);
        S.auditors.forEach(function (a) {
            sel.appendChild(auditorOption(a.employeeId ?? a.EmployeeId, a.employeeName || a.EmployeeName || '',
                a.roleId ?? a.RoleId, a.roleName || a.RoleName || ''));
        });
        if (empId != null && empId !== '') {
            if (!S.auditors.some(function (a) { return String(a.employeeId ?? a.EmployeeId) === String(empId); }))
                sel.appendChild(auditorOption(empId, empName || ('#' + empId), roleId, roleName, '  (no longer an auditor)'));
            sel.value = String(empId);
        }
    }
    function readAuditor(selId) {
        const sel = $(selId);
        const o = sel.value ? sel.options[sel.selectedIndex] : null;
        return o ? {
            roleId      : o.getAttribute('data-role-id') ? Number(o.getAttribute('data-role-id')) : null,
            roleName    : o.getAttribute('data-role-name') || null,
            employeeId  : Number(sel.value),
            employeeName: o.getAttribute('data-name') || null
        } : { roleId: null, roleName: null, employeeId: null, employeeName: null };
    }
    // Team members (auditors) and subject matter experts (any active
    // employee): the project's multi-select combo. A member kept from
    // before who is no longer in the list stays as an option.
    function renderCombo(hostId, people, idKey, nameKey, picked, keptRows, aria) {
        const opts = people.map(function (p) {
            const name = v(p, nameKey, nameKey.charAt(0).toUpperCase() + nameKey.slice(1)) || '';
            const role = p.roleName || p.RoleName || p.employeeCode || p.EmployeeCode || '';
            return { value: String(v(p, idKey, idKey.charAt(0).toUpperCase() + idKey.slice(1))), label: name + (role ? ' - ' + role : '') };
        });
        (keptRows || []).forEach(function (t) {
            const id = String(t.employeeId ?? t.EmployeeId);
            if (!opts.some(function (o) { return o.value === id; }))
                opts.push({ value: id, label: (t.memberName || t.MemberName || ('#' + id)) + '  (kept)' });
        });
        $(hostId).innerHTML = window.gracCheckCombo.html(opts, picked, { ariaLabel: aria, disabled: false });
    }
    function comboValues(hostId) {
        const c = $(hostId).querySelector('[data-checkcombo]');
        return c ? window.gracCheckCombo.values(c).map(Number) : [];
    }
    function teamOf(role) {
        const t = (S.detail && (S.detail.team || S.detail.Team)) || [];
        return t.filter(function (x) { return (x.teamRole || x.TeamRole) === role; });
    }
    function attachAuditee(roleId, roleName, empId, empName) {
        if (!window.__roleHolderPicker) return Promise.resolve();
        return window.__roleHolderPicker.attach({
            organizationId     : Number(S.orgId),
            roleSelectId       : 'oaEngAuditeeRole',
            employeeSelectId   : 'oaEngAuditee',
            initialRoleId      : roleId,
            initialRoleName    : roleName,
            initialEmployeeId  : empId,
            initialEmployeeName: empName,
            allowEmpty         : true
        }).catch(function () { /* soft-fail, as the plan owner */ });
    }

    // -----------------------------------------------------------------
    // Branch (554): a Location; a pre-554 text-only branch is kept.
    // -----------------------------------------------------------------
    async function fillBranches(branchId, branchName) {
        const sel = $('oaEngBranch');
        sel.innerHTML = '<option value="">Loading branches...</option>';
        let rows = [];
        try {
            rows = rowsOf(await getJson(API + '/scope-dimensions/BRANCH/values?organizationId='
                                        + encodeURIComponent(S.orgId) + '&pageSize=500'));
        } catch (_) { rows = []; }
        sel.innerHTML = '';
        const add = function (value, text, name) {
            const o = document.createElement('option');
            o.value = value;
            o.textContent = text;
            o.setAttribute('data-name', name || '');
            sel.appendChild(o);
        };
        add('', '-- whole scope (no branch) --', '');
        rows.forEach(function (x) {
            const nm = x.name || x.Name || '';
            add(String(x.id ?? x.Id), nm, nm);
        });
        if (branchId) {
            if (!rows.some(function (x) { return String(x.id ?? x.Id) === String(branchId); }))
                add(String(branchId), (branchName || ('#' + branchId)) + '  (not an active Location now)', branchName || '');
            sel.value = String(branchId);
        } else if (branchName) {
            add('text', branchName + '  (text only -- does not narrow the scope)', branchName);
            sel.value = 'text';
        }
    }
    function branchState() {
        const o = $('oaEngBranch').selectedOptions[0];
        const val = o ? o.value : '';
        return { id: /^\d+$/.test(val) ? Number(val) : null, name: (o && o.getAttribute('data-name')) || null };
    }

    // -----------------------------------------------------------------
    // Open
    // -----------------------------------------------------------------
    function setModeFields() {
        const indep = S.origin === 'INDEPENDENT';
        document.querySelectorAll('#oaEngDialog .oa-eng-indep').forEach(function (el) { show(el, indep); });
        // Team mode: only the team can change (any time until cancelled /
        // completed; the change is trailed). Everything else is read-only.
        const team = S.mode === 'team';
        document.querySelectorAll('#oaEngDialog .oa-eng-field').forEach(function (el) {
            el.querySelectorAll('input, select, textarea, button').forEach(function (c) {
                if (c.id === 'oaEngPlan' && S.origin === 'PLANNED') return;   // always fixed
                c.disabled = team;
            });
        });
        $('oaEngOrigin').value = indep ? 'Independent' : 'Planned';
        $('oaEngSubmit').textContent = team ? 'Save Team' : 'Save Engagement';
    }

    async function open(opts) {
        wire();
        S.opts    = opts || {};
        S.orgId   = String(S.opts.orgId || '');
        S.mode    = S.opts.mode === 'team' ? 'team' : 'edit';
        S.detail  = null;
        S.engDefs = [];
        message('');
        if (!S.orgId) { await window.gracUi.alert('Pick an organization first.'); return; }

        const form = $('oaEngForm');
        form.reset();
        const id = S.opts.engagementId;
        try {
            await Promise.all([loadDefinitions(S.orgId, S.opts.definitions), loadAuditors(S.orgId),
                               loadEmployees(S.orgId), loadSources()]);
            if (id != null && id !== '') {
                S.detail = await getJson(API + '/engagements/' + encodeURIComponent(id) + '?organizationId=' + encodeURIComponent(S.orgId));
            }
        } catch (err) { await window.gracUi.alert('Failed: ' + (err.message || err)); return; }

        const e = S.detail ? (S.detail.engagement || S.detail.Engagement || {}) : null;
        S.origin = e ? (v(e, 'engagementOrigin', 'EngagementOrigin') || 'PLANNED')
                     : (String(S.opts.origin || 'PLANNED').toUpperCase() === 'INDEPENDENT' ? 'INDEPENDENT' : 'PLANNED');
        if (S.origin === 'INDEPENDENT') await loadPlans(S.orgId);

        // The source list
        $('oaEngSource').innerHTML = '<option value="">-- select --</option>' + (S.sources || []).map(function (x) {
            return '<option value="' + esc(x.code || x.Code) + '">' + esc(x.name || x.Name || x.code || x.Code) + '</option>';
        }).join('');

        const planId    = e ? v(e, 'planId', 'PlanId') : S.opts.planId;
        const planLabel = e ? ((v(e, 'planCode', 'PlanCode') || '') + ' - ' + (v(e, 'planName', 'PlanName') || '')) : S.opts.planLabel;
        fillPlanSelect(planId, planLabel);
        await fillProgrammes(planId, e ? v(e, 'programmeId', 'ProgrammeId') : S.opts.presetProgrammeId);

        if (e) {
            $('oaEngTitle').textContent = (S.mode === 'team' ? 'Audit Team: ' : 'Edit Engagement: ')
                                        + (v(e, 'engagementCode', 'EngagementCode') || '');
            $('oaEngName').value        = v(e, 'engagementName', 'EngagementName') || '';
            $('oaEngSubject').value     = v(e, 'auditSubject', 'AuditSubject') || '';
            $('oaEngSource').value      = v(e, 'initiationSourceCode', 'InitiationSourceCode') || '';
            $('oaEngReason').value      = v(e, 'initiationReason', 'InitiationReason') || '';
            $('oaEngApprovalRef').value = v(e, 'approvalReference', 'ApprovalReference') || '';
            S.engDefs = ((S.detail.audits || S.detail.Audits) || []).map(function (x) { return String(x.definitionId ?? x.DefinitionId); });
            $('oaEngFrom').value        = onlyDate(v(e, 'plannedStart', 'PlannedStart'));
            $('oaEngTo').value          = onlyDate(v(e, 'plannedEnd', 'PlannedEnd'));
            $('oaEngDept').value        = v(e, 'departmentName', 'DepartmentName') || '';
            $('oaEngObjective').value   = v(e, 'engagementObjective', 'EngagementObjective') || '';
            $('oaEngScope').value       = v(e, 'scopeSummary', 'ScopeSummary') || '';
            $('oaEngInstructions').value= v(e, 'engagementInstructions', 'EngagementInstructions') || '';
            $('oaEngNotes').value       = v(e, 'notes', 'Notes') || '';
            $('oaEngTeamRemarks').value = v(e, 'teamRemarks', 'TeamRemarks') || '';
            $('oaEngOrder').value       = String(v(e, 'itemOrder', 'ItemOrder') ?? 1);
            await fillBranches(v(e, 'branchId', 'BranchId'), v(e, 'branchName', 'BranchName'));
            await attachAuditee(v(e, 'auditeeRoleId', 'AuditeeRoleId'), v(e, 'auditeeRoleName', 'AuditeeRoleName'),
                                v(e, 'auditeeEmployeeId', 'AuditeeEmployeeId'), v(e, 'auditeeName', 'AuditeeName'));
        } else {
            $('oaEngTitle').textContent = S.origin === 'INDEPENDENT' ? 'Add Independent Engagement' : 'Add Engagement';
            $('oaEngOrder').value = String((Number(S.opts.itemCount) || 0) + 1);
            if (S.opts.presetDefinitionId != null && S.opts.presetDefinitionId !== '')
                S.engDefs = [String(S.opts.presetDefinitionId)];   // 546: from Add to Plan
            const pre = S.opts.preset || {};                       // 583: from a recommendation
            if (pre.name)      $('oaEngName').value      = pre.name;
            if (pre.subject)   $('oaEngSubject').value   = pre.subject;
            if (pre.from)      $('oaEngFrom').value      = onlyDate(pre.from);
            if (pre.to)        $('oaEngTo').value        = onlyDate(pre.to);
            if (pre.objective) $('oaEngObjective').value = pre.objective;
            await fillBranches(null, null);
            await attachAuditee(null, null, null, null);
        }
        renderAuditLists();

        // The team: the lead, members, reviewer, experts, externals.
        const lead = e ? v(e, 'leadAuditorEmployeeId', 'LeadAuditorEmployeeId') : null;
        fillAuditorSelect('oaEngLead', '-- select the lead auditor --', lead,
            e ? v(e, 'leadAuditorName', 'LeadAuditorName') : null,
            e ? v(e, 'leadAuditorRoleId', 'LeadAuditorRoleId') : null,
            e ? v(e, 'leadAuditorRoleName', 'LeadAuditorRoleName') : null);
        const members = teamOf('MEMBER'), reviewer = teamOf('REVIEWER')[0] || null, smes = teamOf('SME');
        renderCombo('oaEngMembers', S.auditors, 'employeeId', 'employeeName',
            members.map(function (t) { return String(t.employeeId ?? t.EmployeeId); }), members, 'Audit team members');
        fillAuditorSelect('oaEngReviewer', '-- none --',
            reviewer ? (reviewer.employeeId ?? reviewer.EmployeeId) : null,
            reviewer ? (reviewer.memberName || reviewer.MemberName) : null, null, reviewer ? (reviewer.roleName || reviewer.RoleName) : null);
        renderCombo('oaEngSmes', S.employees, 'employeeId', 'employeeName',
            smes.map(function (t) { return String(t.employeeId ?? t.EmployeeId); }), smes, 'Subject matter experts');
        $('oaEngExternals').value = teamOf('EXTERNAL').map(function (t) {
            const org = t.externalOrganisation || t.ExternalOrganisation || '';
            return (t.memberName || t.MemberName || '') + (org ? ' - ' + org : '');
        }).join('\n');

        setModeFields();
        const dlg = $('oaEngDialog');
        // Full view (as the plan form): show(), Escape closes it by hand.
        if (!dlg.open) dlg.show();
        const first = S.mode === 'team' ? $('oaEngReviewer') : $('oaEngSubject');
        if (first && !first.disabled) first.focus();
    }
    function close() { $('oaEngDialog').close(); }

    // -----------------------------------------------------------------
    // Save
    // -----------------------------------------------------------------
    function readTeam() {
        const lead = $('oaEngLead').value;
        const team = [];
        comboValues('oaEngMembers').forEach(function (id) {
            if (String(id) !== String(lead)) team.push({ teamRole: 'MEMBER', employeeId: id });
        });
        const rev = $('oaEngReviewer').value;
        if (rev) team.push({ teamRole: 'REVIEWER', employeeId: Number(rev) });
        comboValues('oaEngSmes').forEach(function (id) { team.push({ teamRole: 'SME', employeeId: id }); });
        $('oaEngExternals').value.split('\n').forEach(function (line) {
            const t = line.trim();
            if (!t) return;
            const i = t.indexOf(' - ');
            team.push({ teamRole: 'EXTERNAL', name: i > 0 ? t.substring(0, i).trim() : t,
                        organisation: i > 0 ? t.substring(i + 3).trim() || null : null });
        });
        return team;
    }

    async function post(path, body) {
        const r = await fetch(U(API + path), {
            method: 'POST', credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });
        const j = await safeJson(r);
        if (!r.ok) throw new Error((j && (j.error || j.Error)) || ('HTTP ' + r.status));
        return j;
    }

    async function save() {
        message('');
        const e  = S.detail ? (S.detail.engagement || S.detail.Engagement || {}) : null;
        const id = e ? v(e, 'engagementId', 'EngagementId') : null;
        if (S.mode === 'team') {
            try {
                await post('/engagements/' + encodeURIComponent(id) + '/team', {
                    organizationId: Number(S.orgId), team: readTeam(),
                    teamRemarks: $('oaEngTeamRemarks').value.trim() || null, actor: null });
                close();
                if (typeof S.opts.onSaved === 'function') S.opts.onSaved({ engagementId: id });
            } catch (err) { message(err.message || String(err), 'error'); }
            return;
        }

        const indep = S.origin === 'INDEPENDENT';
        // What every engagement needs (sir's table, 566); the server checks the same.
        if (!S.engDefs.length) { message('Add at least one audit to the engagement.', 'error'); return; }
        const programmeId = $('oaEngProgramme').value;
        if (!indep && !programmeId) { message('Pick the programme this engagement belongs to.', 'error'); return; }
        if (!$('oaEngSubject').value.trim()) { message('Give the audit subject of the engagement.', 'error'); return; }
        if (!$('oaEngScope').value.trim())   { message('Describe the scope of the engagement.', 'error'); return; }
        if (!$('oaEngLead').value)           { message('Pick the lead auditor.', 'error'); return; }
        if (indep && (!$('oaEngSource').value || !$('oaEngReason').value.trim())) {
            message('An independent engagement needs its initiation source and the reason for it.', 'error'); return;
        }
        const first   = defById(S.engDefs[0]);
        const lead    = readAuditor('oaEngLead');
        const auditee = window.__roleHolderPicker ? window.__roleHolderPicker.readState('oaEngAuditeeRole', 'oaEngAuditee')
                                                  : { roleId: null, roleName: null, employeeId: null, employeeName: null };
        const planVal = $('oaEngPlan').value;
        const br      = branchState();
        const body = {
            organizationId            : Number(S.orgId),
            planId                    : planVal ? Number(planVal) : null,
            planItemId                : id != null ? Number(id) : null,
            engagementOrigin          : S.origin,
            definitionId              : Number(S.engDefs[0]),
            definitionCode            : first ? (first.definitionCode || first.DefinitionCode || null) : null,
            definitionName            : first ? (first.definitionName || first.DefinitionName || null) : null,
            definitionIds             : S.engDefs.map(Number),
            engagementName            : $('oaEngName').value.trim() || null,
            programmeId               : programmeId ? Number(programmeId) : null,
            itemOrder                 : Number($('oaEngOrder').value || 1),
            scheduledFrom             : $('oaEngFrom').value || null,
            scheduledTo               : $('oaEngTo').value || null,
            assignedAuditorRoleId     : lead.roleId,
            assignedAuditorRoleName   : lead.roleName,
            assignedAuditorEmployeeId : lead.employeeId,
            assignedAuditorName       : lead.employeeName,
            assignedTeamName          : e ? (v(e, 'teamText', 'TeamText') || null) : null,   // the pre-566 text, kept
            assignedDepartmentId      : null,
            assignedDepartmentName    : $('oaEngDept').value.trim() || null,
            assignedBranchId          : br.id,
            assignedBranchName        : br.name,
            notes                     : $('oaEngNotes').value || null,
            auditSubject              : $('oaEngSubject').value.trim(),
            engagementObjective       : $('oaEngObjective').value.trim() || null,
            scopeSummary              : $('oaEngScope').value.trim(),
            auditeeRoleId             : auditee.roleId,
            auditeeRoleName           : auditee.roleName,
            auditeeEmployeeId         : auditee.employeeId,
            auditeeName               : auditee.employeeName,
            engagementInstructions    : $('oaEngInstructions').value.trim() || null,
            teamRemarks               : $('oaEngTeamRemarks').value.trim() || null,
            team                      : readTeam(),
            initiationSourceCode      : indep ? ($('oaEngSource').value || null) : null,
            initiationReason          : indep ? ($('oaEngReason').value.trim() || null) : null,
            approvalReference         : $('oaEngApprovalRef').value.trim() || null,
            actor                     : null
        };
        try {
            const j = await post('/plan-items', body);
            close();
            if (typeof S.opts.onSaved === 'function') S.opts.onSaved({ engagementId: j && (j.planItemId ?? j.PlanItemId) });
        } catch (err) { message(err.message || String(err), 'error'); }
    }

    // -----------------------------------------------------------------
    // View Scope (552): the scope resolved now -- nothing saved.
    // -----------------------------------------------------------------
    async function openScope(orgId, body, subtitle) {
        wire();
        const wf  = window.__wfCommon;
        const dlg = $('oaEngScopeDialog');
        $('oaEngScopeSub').textContent = subtitle || '';
        $('oaEngScopeSummary').innerHTML = '';
        $('oaEngScopeBody').innerHTML = '<tr><td colspan="4" class="pm-empty">Resolving the scope...</td></tr>';
        if (wf) wf.setMessage('oaEngScopeMessage', '');
        if (!dlg.open) dlg.showModal();
        try {
            const j = await post('/engagements/scope-preview', Object.assign({ organizationId: Number(orgId), actor: null }, body));
            const dims = (j && (j.dimensions || j.Dimensions)) || [];
            const ents = (j && (j.entities   || j.Entities))   || [];
            $('oaEngScopeSummary').innerHTML = dims.map(function (d) {
                return '<span class="pm-badge">' + esc(d.dimensionName || d.DimensionName || d.dimensionCode || d.DimensionCode || '')
                     + ' ' + esc(String(d.entityCount ?? d.EntityCount ?? 0)) + '</span>';
            }).join(' ');
            $('oaEngScopeBody').innerHTML = ents.length ? ents.map(function (x) {
                return '<tr><td>' + esc(x.dimensionName || x.DimensionName || x.dimensionCode || x.DimensionCode || '') + '</td>'
                     + '<td>' + esc(x.entityCode || x.EntityCode || '') + '</td>'
                     + '<td>' + esc(x.entityName || x.EntityName || '') + '</td>'
                     + '<td>' + esc(x.definitionCodes || x.DefinitionCodes || '') + '</td></tr>';
            }).join('') : '<tr><td colspan="4" class="pm-empty">The selected audits have no scope yet.</td></tr>';
        } catch (err) {
            $('oaEngScopeBody').innerHTML = '';
            if (wf) wf.setMessage('oaEngScopeMessage', 'The scope could not be resolved: ' + (err.message || err), 'error');
        }
    }

    // -----------------------------------------------------------------
    // Start Execution (546 / 552 / 555): one execution per audit not yet
    // started; the scope stays live until the auditor freezes it.
    // -----------------------------------------------------------------
    async function startExecution(orgId, planId, engagementId, name) {
        if (!await window.gracUi.confirm('Start the executions of ' + (name || 'this engagement') + ' now? One execution is started for each of its audits not started yet. The scope stays live until the auditor freezes it in My Audits.',
              { type: 'confirm', title: 'Start Execution', confirmText: 'Start' })) return false;
        try {
            const j = await post('/engagements/' + encodeURIComponent(engagementId) + '/start-execution',
                { organizationId: Number(orgId), planId: planId != null && planId !== '' ? Number(planId) : 0, actor: null });
            const ex = (j.executions || j.Executions || []);
            const list = ex.length ? ex : [{ executionCode: j.executionCode || j.ExecutionCode }];
            await window.gracUi.alert('Started: ' + list.map(function (x) {
                return (x.executionCode || x.ExecutionCode || '') + ' (' + (x.definitionCode || x.DefinitionCode || '') + ')';
            }).join('; ') + '. The auditor reviews and freezes the scope in My Audits.', { type: 'success' });
            return true;
        } catch (err) {
            await window.gracUi.alert('Failed: ' + (err.message || err), { type: 'error' });
            return false;
        }
    }

    // -----------------------------------------------------------------
    // Wiring (once)
    // -----------------------------------------------------------------
    function wire() {
        if (S.wired) return;
        S.wired = true;
        const dlg = $('oaEngDialog');
        $('oaEngClose').addEventListener('click', close);
        $('oaEngCancel').addEventListener('click', close);
        $('oaEngForm').addEventListener('submit', function (ev) { ev.preventDefault(); save(); });
        dlg.addEventListener('keydown', function (ev) { if (ev.key === 'Escape') { ev.preventDefault(); close(); } });
        $('oaEngAdd').addEventListener('click', function () { moveAudits(true); });
        $('oaEngRemove').addEventListener('click', function () { moveAudits(false); });
        $('oaEngAvail').addEventListener('dblclick', function () { moveAudits(true); });
        $('oaEngSel').addEventListener('dblclick', function () { moveAudits(false); });
        $('oaEngUp').addEventListener('click', function () { shiftAudit(-1); });
        $('oaEngDown').addEventListener('click', function () { shiftAudit(1); });
        $('oaEngScopeLink').addEventListener('click', function (ev) {
            ev.preventDefault();
            if (!S.engDefs.length) { message('Add at least one audit to see the scope.', 'error'); return; }
            const br = branchState();   // 554: narrowed to the branch picked
            openScope(S.orgId, { definitionIds: S.engDefs.map(Number), locationId: br.id },
                      'The ' + S.engDefs.length + ' selected audit(s)' + (br.id ? ' at ' + br.name : ''));
        });
        $('oaEngPlan').addEventListener('change', function () {
            if (S.origin === 'INDEPENDENT') fillProgrammes($('oaEngPlan').value || null, null);
        });
        $('oaEngScopeClose').addEventListener('click', function () { $('oaEngScopeDialog').close(); });
        $('oaEngScopeOk').addEventListener('click', function () { $('oaEngScopeDialog').close(); });
        if (window.gracCheckCombo) window.gracCheckCombo.wire($('oaEngForm'));
    }

    window.gracEngagementForm = { open: open, close: close, openScope: openScope, startExecution: startExecution };
})();
