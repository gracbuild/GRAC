import sys, re
f = sys.argv[1]
t = open(f, encoding='utf-8').read()
def rep(a, b, n=1):
    global t
    c = t.count(a)
    if c != n: raise SystemExit('count %d (want %d): %r' % (c, n, a[:100]))
    t = t.replace(a, b)

# ---------------- header comment ----------------
rep("""    UX:
      * One plans list; a plan's slots open under it.""", """    552 (2026-11-14, sir) -- ENGAGEMENTS
      A plan's items are ENGAGEMENTS: who audits (auditor, team,
      department, branch), when (from / to) and WHICH audit definitions --
      one or more, picked in a dual list (Available / Selected, > < and
      up / down -- the Audit Configuration question set picker's layout,
      .oa-adopt-grid). Name defaults to the first audit's. "View Scope"
      (dialog link and the engagement's 3-dot) shows the selected audits'
      scope resolved NOW -- nothing is saved or frozen; the execution
      freezes it. The engagement rows show its code, name, audits and a
      rolled-up status (n / m audits done). Start Execution starts one
      execution per audit not yet started.
      Backend (552): POST plan-items (+ engagementName, definitionIds[]);
      GET plans/{planId}/items/{itemId}/definitions;
      POST engagements/scope-preview.

    UX:
      * One plans list; a plan's engagements open under it.""")

# ---------------- plan list header ----------------
rep("""                    <th style="text-align:right;">Slots</th>""", """                    <th style="text-align:right;">Engagements</th>""")

# ---------------- engagement dialog ----------------
a = t.index("@* ---------- Item dialog ---------- *@")
b = t.index("@* ---------- Add to Plan: pick the plan (546) ----------")
t = t[:a] + """@* ---------- Engagement dialog (552; was "Plan Item") ---------- *@
<dialog id="oaPlItemDialog" style="max-width:880px; width:96%;">
    <form id="oaPlItemForm" method="dialog">
        <div class="pm-dialog-heading">
            <h2 id="oaPlItemDialogTitle">Add Engagement</h2>
            <button class="pm-icon-button" type="button" id="oaPlItemClose" aria-label="Close">&times;</button>
        </div>
        <div class="pm-message" id="oaPlItemMessage" style="display:none;"></div>
        <input type="hidden" id="oaPlItemEditId" />

        <div style="display:grid; grid-template-columns:1fr 100px; gap:10px; align-items:start;">
            <label class="pm-field">
                <span>Engagement Name</span>
                <input class="pm-input" id="oaPlItemName" type="text" maxlength="240" placeholder="The first audit's name, if left empty" />
            </label>
            <label class="pm-field">
                <span>Order</span>
                <input class="pm-input" id="oaPlItemOrder" type="number" min="1" step="1" />
            </label>
        </div>

        @* The audits of the engagement: the dual-list picker (> < icon-only,
           up / down for the order), Audit Configuration's question set
           picker layout. *@
        <div class="oa-adopt-grid" style="margin-top:10px;">
            <label class="oa-adopt-label oa-adopt-a-label" for="oaPlItemAvail">
                Audits that can be planned <span class="pm-badge" id="oaPlItemAvailCount">0</span>
            </label>
            <label class="oa-adopt-label oa-adopt-s-label" for="oaPlItemSel">
                Audits in this engagement <span class="required">*</span> <span class="pm-badge" id="oaPlItemSelCount">0</span>
            </label>
            <select id="oaPlItemAvail" class="oa-adopt-box oa-adopt-a-box" multiple size="7"></select>
            <div class="oa-adopt-actions oa-adopt-move">
                <button type="button" class="pm-button" id="oaPlItemAdd" title="Add the selected audits" aria-label="Add the selected audits">
                    <i class="fa-solid fa-angle-right" aria-hidden="true"></i>
                </button>
                <button type="button" class="pm-button" id="oaPlItemRemove" title="Remove the selected audits" aria-label="Remove the selected audits">
                    <i class="fa-solid fa-angle-left" aria-hidden="true"></i>
                </button>
            </div>
            <select id="oaPlItemSel" class="oa-adopt-box oa-adopt-s-box" multiple size="7"></select>
            <div class="oa-adopt-actions oa-adopt-order">
                <button type="button" class="pm-button" id="oaPlItemUp" title="Move up" aria-label="Move up">
                    <i class="fa-solid fa-arrow-up" aria-hidden="true"></i>
                </button>
                <button type="button" class="pm-button" id="oaPlItemDown" title="Move down" aria-label="Move down">
                    <i class="fa-solid fa-arrow-down" aria-hidden="true"></i>
                </button>
            </div>
            <div class="oa-adopt-a-hint">
                <p class="oa-adopt-hint">Audits with an Active version. Select one or more, then &gt;.</p>
            </div>
            <div class="oa-adopt-s-hint">
                <p class="oa-adopt-hint oa-adopt-links">
                    <a href="#" id="oaPlItemScopeLink"><i class="fa-solid fa-eye" aria-hidden="true"></i> View Scope</a>
                    <span>the selected audits' scope as it is now -- nothing is frozen.</span>
                </p>
            </div>
        </div>

        <div style="display:grid; grid-template-columns:1fr 1fr; gap:10px; align-items:start; margin-top:10px;">
            <label class="pm-field">
                <span>Scheduled From</span>
                <input class="pm-input" id="oaPlItemFrom" type="date" />
            </label>
            <label class="pm-field">
                <span>Scheduled To</span>
                <input class="pm-input" id="oaPlItemTo" type="date" />
            </label>
        </div>
        @* 121 hybrid role+employee Auditor picker.
           minmax(0,1fr) + min-width:0 so long role/holder names can't overflow. *@
        <div style="display:grid; grid-template-columns:minmax(0,1fr) minmax(0,1fr); gap:10px; align-items:start; margin-top:10px;">
            <div class="pm-field" style="min-width:0;">
                <span>Assigned Auditor</span>
                <div style="display:grid; grid-template-columns:minmax(0,1fr) minmax(0,1fr); gap:6px; margin-top:2px;">
                    <select class="pm-input" id="oaPlItemAuditorRole" style="min-width:0;" aria-label="Auditor Role">
                        <option value="">Loading roles...</option>
                    </select>
                    <select class="pm-input" id="oaPlItemAuditor" style="min-width:0;" aria-label="Auditor Employee (current holder)">
                        <option value="">-- pick a role first --</option>
                    </select>
                </div>
            </div>
            <label class="pm-field" style="min-width:0;">
                <span>Assigned Team</span>
                <input class="pm-input" id="oaPlItemTeam" type="text" maxlength="200" />
            </label>
        </div>
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:10px; align-items:start; margin-top:10px;">
            <label class="pm-field">
                <span>Assigned Department</span>
                <input class="pm-input" id="oaPlItemDept" type="text" maxlength="200" />
            </label>
            <label class="pm-field">
                <span>Assigned Branch</span>
                <input class="pm-input" id="oaPlItemBranch" type="text" maxlength="200" />
            </label>
        </div>
        <label class="pm-field" style="margin-top:10px;">
            <span>Notes</span>
            <textarea class="pm-input" id="oaPlItemNotes" rows="2" maxlength="4000"></textarea>
        </label>
        <div class="pm-dialog-actions">
            <button type="button" id="oaPlItemCancel" class="pm-button">Cancel</button>
            <button type="submit" id="oaPlItemSubmit" class="pm-button primary">Save Engagement</button>
        </div>
    </form>
</dialog>

@* ---------- View Scope (552): live, nothing saved ---------- *@
<dialog id="oaPlScopeDialog" style="max-width:900px; width:96%;">
    <div class="pm-dialog-heading">
        <div>
            <h2>Engagement Scope</h2>
            <p id="oaPlScopeSub"></p>
        </div>
        <button class="pm-icon-button" type="button" id="oaPlScopeClose" aria-label="Close">&times;</button>
    </div>
    <div class="pm-message" id="oaPlScopeMessage" style="display:none;"></div>
    <div class="oa-pl-scope-summary" id="oaPlScopeSummary"></div>
    <div class="pm-table-wrap">
        <table>
            <thead><tr><th>Type</th><th>Code</th><th>Name</th><th>Audits</th></tr></thead>
            <tbody id="oaPlScopeBody"></tbody>
        </table>
    </div>
    <p class="pm-hint" style="margin:8px 0 0;">Resolved now from each audit's scope. It is not saved or frozen -- the auditor freezes the scope in the execution.</p>
    <div class="pm-dialog-actions">
        <button type="button" id="oaPlScopeOk" class="pm-button">Close</button>
    </div>
</dialog>

""" + t[b:]

# ---------------- state: the engagement's picked audits ----------------
rep("""        presetDefinitionId   : null,""", """        presetDefinitionId   : null,
        engDefs              : [],      // 552: the dialog's selected audits, in order (ids as strings)""")

# ---------------- wiring ----------------
rep("""        document.getElementById('oaPlItemForm').addEventListener('submit', function (e) { e.preventDefault(); saveItem(); });""",
"""        document.getElementById('oaPlItemForm').addEventListener('submit', function (e) { e.preventDefault(); saveItem(); });
        // 552: the engagement's audits (dual list) and View Scope.
        document.getElementById('oaPlItemAdd').addEventListener('click', function () { moveAudits(true); });
        document.getElementById('oaPlItemRemove').addEventListener('click', function () { moveAudits(false); });
        document.getElementById('oaPlItemAvail').addEventListener('dblclick', function () { moveAudits(true); });
        document.getElementById('oaPlItemSel').addEventListener('dblclick', function () { moveAudits(false); });
        document.getElementById('oaPlItemUp').addEventListener('click', function () { shiftAudit(-1); });
        document.getElementById('oaPlItemDown').addEventListener('click', function () { shiftAudit(1); });
        document.getElementById('oaPlItemScopeLink').addEventListener('click', function (e) {
            e.preventDefault();
            if (!state.engDefs.length) { showItemMessage('error', 'Add at least one audit to see the scope.'); return; }
            openScope({ definitionIds: state.engDefs.map(Number) }, 'The ' + state.engDefs.length + ' selected audit(s)');
        });
        document.getElementById('oaPlScopeClose').addEventListener('click', function () { document.getElementById('oaPlScopeDialog').close(); });
        document.getElementById('oaPlScopeOk').addEventListener('click', function () { document.getElementById('oaPlScopeDialog').close(); });""")

# ---------------- picker functions (replace fillDefinitionSelect) ----------------
a = t.index("    function fillDefinitionSelect(selectedId) {")
b = t.index("\n    }\n", a) + 7
t = t[:a] + """    // 552: the engagement's audits -- a dual list. Available: plannable
    // audits (551: an Active version, not Retired) not yet selected;
    // Selected: state.engDefs in order (an audit already on the engagement
    // stays listed even if it is no longer plannable).
    function defById(id) {
        return state.definitions.find(function (d) { return String(d.definitionId || d.DefinitionId) === String(id); }) || null;
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
        const avail = document.getElementById('oaPlItemAvail');
        const sel   = document.getElementById('oaPlItemSel');
        const taken = new Set(state.engDefs);
        const list  = state.definitions.filter(function (d) { return isPlannable(d) && !taken.has(String(d.definitionId || d.DefinitionId)); })
            .sort(function (x, y) { return String(x.definitionName || x.DefinitionName || '').localeCompare(String(y.definitionName || y.DefinitionName || '')); });
        avail.innerHTML = '';
        list.forEach(function (d) {
            const o = document.createElement('option');
            o.value = String(d.definitionId || d.DefinitionId);
            o.textContent = auditLabel(d, o.value);
            avail.appendChild(o);
        });
        sel.innerHTML = '';
        state.engDefs.forEach(function (id) {
            const o = document.createElement('option');
            o.value = id;
            o.textContent = auditLabel(defById(id), id);
            sel.appendChild(o);
        });
        document.getElementById('oaPlItemAvailCount').textContent = String(list.length);
        document.getElementById('oaPlItemSelCount').textContent   = String(state.engDefs.length);
    }
    function moveAudits(add) {
        const from = document.getElementById(add ? 'oaPlItemAvail' : 'oaPlItemSel');
        const ids  = Array.prototype.filter.call(from.options, function (o) { return o.selected; })
                          .map(function (o) { return o.value; });
        if (!ids.length) return;
        if (add) ids.forEach(function (id) { if (state.engDefs.indexOf(id) < 0) state.engDefs.push(id); });
        else state.engDefs = state.engDefs.filter(function (id) { return ids.indexOf(id) < 0; });
        renderAuditLists();
    }
    function shiftAudit(delta) {
        const sel = document.getElementById('oaPlItemSel');
        const ids = Array.prototype.filter.call(sel.options, function (o) { return o.selected; }).map(function (o) { return o.value; });
        if (ids.length !== 1) return;
        const i = state.engDefs.indexOf(ids[0]), j = i + delta;
        if (i < 0 || j < 0 || j >= state.engDefs.length) return;
        state.engDefs.splice(j, 0, state.engDefs.splice(i, 1)[0]);
        renderAuditLists();
        Array.prototype.forEach.call(document.getElementById('oaPlItemSel').options, function (o) { o.selected = o.value === ids[0]; });
    }

    // 552: View Scope -- the scope resolved now (nothing saved).
    // body: { planItemId } for a saved engagement, or { definitionIds }.
    async function openScope(body, subtitle) {
        const dlg = document.getElementById('oaPlScopeDialog');
        document.getElementById('oaPlScopeSub').textContent = subtitle || '';
        document.getElementById('oaPlScopeSummary').innerHTML = '';
        document.getElementById('oaPlScopeBody').innerHTML = '<tr><td colspan="4" class="pm-empty">Resolving the scope...</td></tr>';
        wf.setMessage('oaPlScopeMessage', '');
        if (!dlg.open) dlg.showModal();
        try {
            const r = await fetch(U(API + '/engagements/scope-preview'), {
                method: 'POST', credentials: 'same-origin',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(Object.assign({ organizationId: Number(state.orgId), actor: null }, body))
            });
            const j = await safeJson(r);
            if (!r.ok) throw new Error((j && (j.error || j.Error)) || ('HTTP ' + r.status));
            const dims = (j && (j.dimensions || j.Dimensions)) || [];
            const ents = (j && (j.entities   || j.Entities))   || [];
            document.getElementById('oaPlScopeSummary').innerHTML = dims.map(function (d) {
                return '<span class="pm-badge">' + wf.escape(d.dimensionName || d.DimensionName || d.dimensionCode || d.DimensionCode || '')
                     + ' ' + wf.escape(String(d.entityCount ?? d.EntityCount ?? 0)) + '</span>';
            }).join(' ');
            document.getElementById('oaPlScopeBody').innerHTML = ents.length ? ents.map(function (e) {
                return '<tr><td>' + wf.escape(e.dimensionName || e.DimensionName || e.dimensionCode || e.DimensionCode || '') + '</td>'
                     + '<td>' + wf.escape(e.entityCode || e.EntityCode || '') + '</td>'
                     + '<td>' + wf.escape(e.entityName || e.EntityName || '') + '</td>'
                     + '<td>' + wf.escape(e.definitionCodes || e.DefinitionCodes || '') + '</td></tr>';
            }).join('') : '<tr><td colspan="4" class="pm-empty">The selected audits have no scope yet.</td></tr>';
        } catch (err) {
            document.getElementById('oaPlScopeBody').innerHTML = '';
            wf.setMessage('oaPlScopeMessage', 'The scope could not be resolved: ' + (err.message || err), 'error');
        }
    }
""" + t[b:]

# ---------------- openItemDialog ----------------
rep("""        clearItemMessage();
        fillDefinitionSelect();""", """        clearItemMessage();
        state.engDefs = [];""")
rep("""                if (!row) { alert('Item not found.'); return; }
                document.getElementById('oaPlItemDialogTitle').textContent = 'Edit Plan Item';
                document.getElementById('oaPlItemEditId').value = String(row.planItemId || row.PlanItemId || '');
                fillDefinitionSelect(row.definitionId || row.DefinitionId);""", """                if (!row) { alert('Engagement not found.'); return; }
                document.getElementById('oaPlItemDialogTitle').textContent = 'Edit Engagement';
                document.getElementById('oaPlItemEditId').value = String(row.planItemId || row.PlanItemId || '');
                document.getElementById('oaPlItemName').value = row.engagementName || row.EngagementName || '';
                // 552: the engagement's audits, in order.
                try {
                    const dr = await fetch(U(API + '/plans/' + state.selectedPlanId + '/items/' + encodeURIComponent(id)
                        + '/definitions?organizationId=' + encodeURIComponent(state.orgId)), { credentials: 'same-origin' });
                    const db = dr.ok ? await dr.json() : null;
                    state.engDefs = ((db && (db.data || db.Data)) || []).map(function (x) { return String(x.definitionId || x.DefinitionId); });
                } catch (_) { state.engDefs = []; }
                if (!state.engDefs.length) state.engDefs = [String(row.definitionId || row.DefinitionId)];
                renderAuditLists();""")
rep("""            document.getElementById('oaPlItemDialogTitle').textContent = 'Add Plan Item';
            document.getElementById('oaPlItemForm').reset();
            document.getElementById('oaPlItemEditId').value = '';
            document.getElementById('oaPlItemOrder').value  = '1';
            // 546: from Add to Plan -- the audit is already chosen.
            if (state.presetDefinitionId) fillDefinitionSelect(state.presetDefinitionId);""", """            document.getElementById('oaPlItemDialogTitle').textContent = 'Add Engagement';
            document.getElementById('oaPlItemForm').reset();
            document.getElementById('oaPlItemEditId').value = '';
            const n = (state.itemsByPlan[String(state.selectedPlanId)] || []).length;
            document.getElementById('oaPlItemOrder').value  = String(n + 1);
            // 546: from Add to Plan -- the audit is already chosen.
            if (state.presetDefinitionId) state.engDefs = [String(state.presetDefinitionId)];
            renderAuditLists();""")

# ---------------- saveItem ----------------
rep("""        const defSel = document.getElementById('oaPlItemDefinition');
        const defOpt = defSel.options[defSel.selectedIndex] || null;
        if (!defSel.value) { showItemMessage('error', 'Pick an audit.'); return; }""", """        // 552: the engagement's audits, in order (the first is its main audit).
        if (!state.engDefs.length) { showItemMessage('error', 'Add at least one audit to the engagement.'); return; }
        const first = defById(state.engDefs[0]);""")
rep("""            definitionId                : Number(defSel.value),
            definitionCode              : defOpt ? (defOpt.getAttribute('data-code') || null) : null,
            definitionName              : defOpt ? (defOpt.getAttribute('data-name') || null) : null,""", """            definitionId                : Number(state.engDefs[0]),
            definitionCode              : first ? (first.definitionCode || first.DefinitionCode || null) : null,
            definitionName              : first ? (first.definitionName || first.DefinitionName || null) : null,
            definitionIds               : state.engDefs.map(Number),                                       // 552
            engagementName              : document.getElementById('oaPlItemName').value.trim() || null,   // 552""")

# ---------------- delete text ----------------
rep("""        if (!await window.gracUi.confirm('Remove this item from the plan?',
              { type: 'warning', title: 'Remove plan item', confirmText: 'Remove' })) return;""", """        if (!await window.gracUi.confirm('Remove this engagement from the plan?',
              { type: 'warning', title: 'Remove engagement', confirmText: 'Remove' })) return;""")

# ---------------- plan menu ----------------
rep("""                items.push({ icon: 'fa-plus', label: 'Add Item', action: function () {""", """                items.push({ icon: 'fa-plus', label: 'Add Engagement', action: function () {""")
rep("""Approving makes it Active, and its slots can then be started as executions.""", """Approving makes it Active, and its engagements can then be started as executions.""")

# ---------------- engagement menu ----------------
rep("""        if ((planSt === 'Approved' || planSt === 'Active') && slot === 'Planned' && plannable)
            itemMenu.push({ icon: 'fa-play', label: 'Start Execution', action: function () { startExecution(id); } });
        return itemMenu;""", """        // 552: View Scope always; Start Execution while an audit of the
        // engagement is left to start (CanStart), once the plan is Approved / Active.
        itemMenu.push({ icon: 'fa-eye', label: 'View Scope', action: function () {
            openScope({ planItemId: Number(id) }, (row.engagementCode || row.EngagementCode || '') + '  ' + (row.engagementName || row.EngagementName || ''));
        } });
        const canStart = (row.canStart != null || row.CanStart != null)
            ? !!(row.canStart != null ? row.canStart : row.CanStart)
            : (slot === 'Planned' && plannable);
        if ((planSt === 'Approved' || planSt === 'Active') && canStart)
            itemMenu.push({ icon: 'fa-play', label: 'Start Execution', action: function () { startExecution(id); } });
        return itemMenu;""")

# ---------------- status cell ----------------
rep("""    function slotStatusHtml(row) {
        const st   = row.slotStatus || row.SlotStatus || 'Planned';
        const code = row.executionCode || row.ExecutionCode || '';
        const retired = (row.definitionStatusCode || row.DefinitionStatusCode) === 'Retired';
        return wf.badge(SLOT_LABEL[st] || st)
             + (code ? ' <span style="color:var(--fg-subtle);">' + wf.escape(code) + '</span>' : '')
             + (retired ? ' <span style="color:var(--fg-subtle);">(audit retired)</span>' : '');""", """    function slotStatusHtml(row) {
        const st   = row.slotStatus || row.SlotStatus || 'Planned';
        const code = row.executionCode || row.ExecutionCode || '';
        const retired = (row.definitionStatusCode || row.DefinitionStatusCode) === 'Retired';
        // 552: an engagement of several audits shows "done / audits".
        const n    = Number(row.definitionCount ?? row.DefinitionCount ?? 1) || 1;
        const done = Number(row.executionDoneCount ?? row.ExecutionDoneCount ?? 0);
        const live = Number(row.executionCount ?? row.ExecutionCount ?? 0);
        return wf.badge(SLOT_LABEL[st] || st)
             + (n > 1 ? ' <span style="color:var(--fg-subtle);">' + done + ' / ' + n + ' done' + (live > done ? ', ' + (live - done) + ' running' : '') + '</span>'
                      : (code ? ' <span style="color:var(--fg-subtle);">' + wf.escape(code) + '</span>' : ''))
             + (retired && n === 1 ? ' <span style="color:var(--fg-subtle);">(audit retired)</span>' : '');""")

# ---------------- start execution ----------------
rep("""        const name = row.definitionName || row.DefinitionName || 'this audit';
        if (!await window.gracUi.confirm('Start the execution of ' + name + ' for this slot? Its scope is resolved now.',
              { type: 'confirm', title: 'Start Execution', confirmText: 'Start' })) return;""", """        const name = row.engagementName || row.EngagementName || row.definitionName || row.DefinitionName || 'this engagement';
        if (!await window.gracUi.confirm('Start the executions of ' + name + '? One execution is started for each of its audits not started yet; each audit\\'s scope is resolved now.',
              { type: 'confirm', title: 'Start Execution', confirmText: 'Start' })) return;""")
rep("""            await window.gracUi.alert('Execution ' + (j.executionCode || j.ExecutionCode || '') + ' started ('
                + (j.totalEntityCount || j.TotalEntityCount || 0) + ' entities in scope). It is in Executions.', { type: 'success' });""", """            // 552: one execution per audit started.
            const ex = (j.executions || j.Executions || []);
            const list = ex.length ? ex : [{ executionCode: j.executionCode || j.ExecutionCode, totalEntityCount: j.totalEntityCount || j.TotalEntityCount }];
            await window.gracUi.alert('Started: ' + list.map(function (x) {
                return (x.executionCode || x.ExecutionCode || '') + ' (' + (x.definitionCode || x.DefinitionCode || '') + ', '
                     + (x.totalEntityCount ?? x.TotalEntityCount ?? 0) + ' entities)';
            }).join('; ') + '. They are in Executions.', { type: 'success' });""")

# ---------------- engagement rows ----------------
rep("""            ? '<a href="#" class="oa-pl-add" data-add-item="' + pid + '"><i class="fa-solid fa-plus" aria-hidden="true"></i> Add Item</a>'""",
"""            ? '<a href="#" class="oa-pl-add" data-add-item="' + pid + '"><i class="fa-solid fa-plus" aria-hidden="true"></i> Add Engagement</a>'""")
rep("""            host.innerHTML = '<p class="pm-hint" style="margin:0 0 6px;">No slots yet.'
                + (planEditable(pid) ? '' : ' Slots can be added only while the plan is Draft or Submitted.') + '</p>' + addLink;""", """            host.innerHTML = '<p class="pm-hint" style="margin:0 0 6px;">No engagements yet.'
                + (planEditable(pid) ? '' : ' Engagements can be added only while the plan is Draft or Submitted.') + '</p>' + addLink;""")
rep("""            + '<th style="width:70px;">Order</th><th>Audit</th><th>Scheduled</th><th>Auditor</th>'""",
"""            + '<th style="width:70px;">Order</th><th>Engagement</th><th>Audits</th><th>Scheduled</th><th>Auditor</th>'""")
rep("""                const defName  = row.definitionName || row.DefinitionName || '';
                const defCode  = row.definitionCode || row.DefinitionCode || '';""", """                // 552: the engagement and its audits.
                const engName  = row.engagementName || row.EngagementName || row.definitionName || row.DefinitionName || '';
                const engCode  = row.engagementCode || row.EngagementCode || '';
                const audits   = row.definitionCodes || row.DefinitionCodes || row.definitionCode || row.DefinitionCode || '';""")
rep("""                     + '<td>' + wf.escape(defName) + (defCode ? ' <span style="color:var(--fg-subtle);">(' + wf.escape(defCode) + ')</span>' : '') + '</td>'""",
"""                     + '<td>' + wf.escape(engName) + (engCode ? ' <span style="color:var(--fg-subtle);">(' + wf.escape(engCode) + ')</span>' : '') + '</td>'
                     + '<td>' + wf.escape(audits) + '</td>'""")
rep("""                ? '<a href="#" class="oa-pl-more" data-show-all="' + pid + '">Show all ' + all.length + ' slots</a>' : '')""",
"""                ? '<a href="#" class="oa-pl-more" data-show-all="' + pid + '">Show all ' + all.length + ' engagements</a>' : '')""")
rep("""        if (!state.itemsByPlan[pid]) host.innerHTML = '<p class="pm-hint" style="margin:0;">Loading slots...</p>';""",
"""        if (!state.itemsByPlan[pid]) host.innerHTML = '<p class="pm-hint" style="margin:0;">Loading engagements...</p>';""")
rep("""            host.innerHTML = '<p class="pm-hint" style="margin:0;">Slots could not be loaded: ' + wf.escape(err.message || err) + '</p>';""",
"""            host.innerHTML = '<p class="pm-hint" style="margin:0;">Engagements could not be loaded: ' + wf.escape(err.message || err) + '</p>';""")
rep("""title="Show the slots">'""", """title="Show the engagements">'""")
rep("""'<span class="visually-hidden">Show the slots</span></button>'""", """'<span class="visually-hidden">Show the engagements</span></button>'""")
rep("""        if (!await window.gracUi.confirm('Delete this plan (and its items)?',""", """        if (!await window.gracUi.confirm('Delete this plan (and its engagements)?',""")

open(f, 'w', encoding='utf-8').write(t)
print('ok')
