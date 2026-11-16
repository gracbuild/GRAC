import sys
f = sys.argv[1]
t = open(f, encoding='utf-8').read()
def rep(a, b, n=1):
    global t
    c = t.count(a)
    if c != n: raise SystemExit('count %d (want %d): %r' % (c, n, a[:100]))
    t = t.replace(a, b)

# ---- header comment
rep("""    The 516 Question Repository (and its Category / Subcategory) was
    withdrawn by 520: questions belong to their set again.
*@""", """    The 516 Question Repository (and its Category / Subcategory) was
    withdrawn by 520: questions belong to their set again.

    551 (2026-11-14, sir) -- VERSIONS AND APPROVAL
      A question set is a master: it is approved, and changed only by a new
      version. Each version is its own set row (same code, its own
      questions). Version status: Draft -> Under Review (Recommend) ->
      Active (Approve); Return sends it back to Draft; approving makes the
      previous Active version Superseded. Only a Draft is edited.
        List      one row per set -- its latest version: Version, Status.
        Menus     View; Edit / Recommend / Discard Draft (Draft);
                  Approve / Return (Under Review); New Version (Active).
        Set page  Version facts; "Audits using this question set" for a
                  Draft / Under Review version -- what approving it will do
                  to each audit (moved in its draft, or a new audit version
                  for review); the set's Versions (click one to view it).
      Backend (551): GET question-sets/{id}/versions, /impact;
      POST question-sets/{id}/new-version, /submit, /return, /approve;
      DELETE question-sets/{id} discards a Draft v2+.
*@""")

# ---- list table: Version column, colspan 8
rep("""                        <th>Code</th>
                        <th>Name</th>
                        <th style="text-align:right;">Questions</th>""", """                        <th>Code</th>
                        <th>Name</th>
                        <th>Version</th>
                        <th style="text-align:right;">Questions</th>""")
rep("""                    <tr><td colspan="7" class="pm-empty">Select an organization to load sets.</td></tr>
                </tbody>""", """                    <tr><td colspan="8" class="pm-empty">Select an organization to load sets.</td></tr>
                </tbody>""")

# ---- read view: impact + versions sections
rep("""                    <tbody id="qsReadBody"></tbody>
                </table>
            </div>
        </div>""", """                    <tbody id="qsReadBody"></tbody>
                </table>
            </div>

            @* 551: the audits that use another version of this set, and what
               approving this version does to each (Draft / Under Review). *@
            <div id="qsImpact" hidden>
                <h3 class="qs-section">Audits using this question set <span class="pm-badge" id="qsImpactCount">0</span></h3>
                <div class="pm-message qs-impact-note" id="qsImpactNote"></div>
                <div class="pm-table-wrap">
                    <table>
                        <thead>
                            <tr><th>Audit</th><th>Version</th><th>Status</th><th>Uses set version</th><th>When this version is approved</th></tr>
                        </thead>
                        <tbody id="qsImpactBody"></tbody>
                    </table>
                </div>
            </div>

            @* 551: every version of the set; a row opens that version. *@
            <h3 class="qs-section">Versions</h3>
            <div class="pm-table-wrap">
                <table>
                    <thead>
                        <tr><th style="width:80px;">Version</th><th>Status</th><th style="text-align:right;">Questions</th><th>Change Note</th><th>Recommended</th><th>Approved</th></tr>
                    </thead>
                    <tbody id="qsVersionBody"></tbody>
                </table>
            </div>
        </div>""")

# ---- styles
rep("""    #qsSetView .qs-read-sub { font-size: 12px; color: var(--fg-muted); margin-top: 4px; white-space: pre-wrap; }""",
"""    #qsSetView .qs-read-sub { font-size: 12px; color: var(--fg-muted); margin-top: 4px; white-space: pre-wrap; }
    /* 551: the impact note reads as a warning; the open version is marked. */
    #qsSetView .qs-impact-note { display: block; background: var(--warning-100, #fef3c7); color: var(--warning-700, #b45309); margin: 0 0 8px; }
    #qsSetView tr.qs-version-current > td { font-weight: 600; }""")

# ---- list rows: Version + version status
rep("""                     + '<td>' + wf.escape(pick(row, 'setName', 'SetName')) + '</td>'
                     + '<td style="text-align:right;">' + wf.escape(String(pick(row, 'questionCount', 'QuestionCount') || 0)) + '</td>'""",
"""                     + '<td>' + wf.escape(pick(row, 'setName', 'SetName')) + '</td>'
                     + '<td>' + versionCell(row) + '</td>'
                     + '<td style="text-align:right;">' + wf.escape(String(pick(row, 'questionCount', 'QuestionCount') || 0)) + '</td>'""")
rep("""                     + '<td>' + wf.badge(pick(row, 'status', 'Status') || 'Active') + '</td>'
                     + '<td><button type="button" class="pm-action-trigger" data-id="' + id + '\"""",
"""                     + '<td>' + wf.badge(statusLabel(pick(row, 'versionStatus', 'VersionStatus') || pick(row, 'status', 'Status') || 'Active')) + '</td>'
                     + '<td><button type="button" class="pm-action-trigger" data-id="' + id + '\"""")
rep("""            }).join('') : '<tr><td colspan="7" class="pm-empty">No question sets yet. Click "New Question Set" to create one.</td></tr>';""",
"""            }).join('') : '<tr><td colspan="8" class="pm-empty">No question sets yet. Click "New Question Set" to create one.</td></tr>';""")
rep("""            body.innerHTML = '<tr><td colspan="7" class="pm-empty">Failed to load: ' + wf.escape(err.message || err) + '</td></tr>';""",
"""            body.innerHTML = '<tr><td colspan="8" class="pm-empty">Failed to load: ' + wf.escape(err.message || err) + '</td></tr>';""")
rep("""            body.innerHTML = '<tr><td colspan="7" class="pm-empty">Select an organization to load sets.</td></tr>';
            wf.updatePager('qs-set'""", """            body.innerHTML = '<tr><td colspan="8" class="pm-empty">Select an organization to load sets.</td></tr>';
            wf.updatePager('qs-set'""")
rep("""        body.innerHTML = '<tr><td colspan="7" class="pm-empty">Loading...</td></tr>';
        try {
            const qs = new URLSearchParams();
            qs.set('organizationId', state.orgId);
            if (state.search)""", """        body.innerHTML = '<tr><td colspan="8" class="pm-empty">Loading...</td></tr>';
        try {
            const qs = new URLSearchParams();
            qs.set('organizationId', state.orgId);
            if (state.search)""")

# ---- menus
rep("""    // Row menu items (2026-11-05): View, Edit. The set page's Actions
    // offers the same list minus View. Delete is not offered here.
    function setMenuItems(id) {
        return [
            { key: 'view', icon: 'fa-eye', label: 'View', action: function () { openSet(id, false, 'view'); } },
            { key: 'edit', icon: 'fa-pen', label: 'Edit', action: function () { openSet(id, String(id) === String(state.setId), 'edit'); } }
        ];
    }""", """    // Row menu items (2026-11-05): View, Edit. The set page's Actions
    // offers the same list minus View. Delete is not offered here.
    // 551: by version status -- Edit / Recommend / Discard Draft for a
    // Draft, Approve / Return for one Under Review, New Version for an
    // Active one (when no version is in progress).
    function versionInfo(id) {
        const s = String(id) === String(state.setId) && state.set ? state.set : (state.setsById[String(id)] || {});
        return {
            status : pick(s, 'versionStatus', 'VersionStatus') || 'Active',
            number : Number(pick(s, 'versionNumber', 'VersionNumber') || 1),
            open   : pick(s, 'openQuestionSetId', 'OpenQuestionSetId')
        };
    }
    function setMenuItems(id) {
        const v = versionInfo(id);
        const items = [
            { key: 'view', icon: 'fa-eye', label: 'View', action: function () { openSet(id, false, 'view'); } }
        ];
        if (v.status === 'Draft') {
            items.push({ key: 'edit', icon: 'fa-pen', label: 'Edit', action: function () { openSet(id, String(id) === String(state.setId), 'edit'); } });
            items.push({ key: 'submit', icon: 'fa-paper-plane', label: 'Recommend', action: function () { recommend(id); } });
            if (v.number > 1) items.push({ key: 'discard', icon: 'fa-trash', label: 'Discard Draft', action: function () { discardDraft(id); } });
        }
        if (v.status === 'UnderReview') {
            items.push({ key: 'approve', icon: 'fa-check', label: 'Approve', action: function () { approve(id); } });
            items.push({ key: 'return', icon: 'fa-rotate-left', label: 'Return to Draft', action: function () { returnToDraft(id); } });
        }
        if (v.status === 'Active' && !v.open)
            items.push({ key: 'newversion', icon: 'fa-code-branch', label: 'New Version', action: function () { newVersion(id); } });
        return items;
    }

    function statusLabel(s) { return s === 'UnderReview' ? 'Under Review' : (s || ''); }
    // List: "v2", plus the Active version when the latest is still in progress.
    function versionCell(row) {
        const n = pick(row, 'versionNumber', 'VersionNumber');
        if (!n) return '';
        const vs = pick(row, 'versionStatus', 'VersionStatus');
        const act = pick(row, 'activeVersionNumber', 'ActiveVersionNumber');
        return 'v' + wf.escape(n) + ((vs === 'Draft' || vs === 'UnderReview') && act
            ? ' <span style="color:var(--fg-subtle);">(v' + wf.escape(act) + ' Active)</span>' : '');
    }

    // -----------------------------------------------------------------
    // 551: version actions
    // -----------------------------------------------------------------
    async function loadImpact(id) {
        try {
            const r = await fetch(U(API + '/question-sets/' + encodeURIComponent(id) + '/impact?organizationId='
                + encodeURIComponent(state.orgId)), { credentials: 'same-origin' });
            const b = r.ok ? await r.json() : null;
            return (b && (b.data || b.Data)) || [];
        } catch (_) { return []; }
    }
    function impactLines(rows) {
        return rows.map(function (d) {
            return '- ' + (pick(d, 'definitionCode', 'DefinitionCode') || '') + ' ' + (pick(d, 'definitionName', 'DefinitionName') || '')
                 + ': ' + (pick(d, 'actionText', 'ActionText') || '');
        }).join('\\n');
    }
    async function setAction(id, action, body) {
        return postJson('/question-sets/' + encodeURIComponent(id) + '/' + action,
            Object.assign({ organizationId: Number(state.orgId), note: null, actor: null }, body || {}));
    }
    async function afterAction(id, mode, text) {
        if (!document.getElementById('qsSetView').hidden) {
            await openSet(id, true, mode || 'view');
            wf.setMessage('qsSetMessage', text, 'ok');
        } else {
            reloadSets();
            wf.setMessage('qsListMessage', text, 'ok');
        }
    }
    function actionFailed(err) {
        const msg = err.message || String(err);
        if (!document.getElementById('qsSetView').hidden) wf.setMessage('qsSetMessage', msg, 'error');
        else wf.setMessage('qsListMessage', msg, 'error');
    }

    async function newVersion(id) {
        if (!await window.gracUi.confirm('Create a new Draft version of this question set? It starts as a copy of the Active version; the Active version stays in use until the new one is approved.',
              { type: 'confirm', title: 'New version', confirmText: 'Create' })) return;
        try {
            const j = await setAction(id, 'new-version');
            const nid = j.questionSetId || j.QuestionSetId;
            await openSet(nid, true, 'edit');
            wf.setMessage('qsSetMessage', 'New Draft version created. Change it, Save, then Recommend it for approval.', 'ok');
        } catch (err) { actionFailed(err); }
    }

    async function recommend(id) {
        const rows = await loadImpact(id);
        const note = await window.gracUi.prompt({
            title: 'Recommend for approval',
            message: (rows.length
                ? 'Approving this version will change ' + rows.length + ' audit(s):\\n' + impactLines(rows) + '\\n\\n'
                : '') + 'What changed in this version? (optional)',
            multiline: true, confirmText: 'Recommend' });
        if (note === null) return;
        try {
            await setAction(id, 'submit', { note: note || null });
            await afterAction(id, 'view', 'Recommended for approval.');
        } catch (err) { actionFailed(err); }
    }

    async function approve(id) {
        const rows = await loadImpact(id);
        if (!await window.gracUi.confirm(
              'Approve this question set version? It becomes the Active version.'
              + (rows.length ? '\\n\\nThese audits use an older version and will change:\\n' + impactLines(rows)
                             + '\\n\\nA new audit version needs Submit for Review and Approve again.' : ''),
              { type: rows.length ? 'warning' : 'confirm', title: 'Approve question set', confirmText: 'Approve' })) return;
        try {
            const j = await setAction(id, 'approve');
            const defs = j.definitions || j.Definitions || [];
            const made = defs.filter(function (d) { return pick(d, 'actionCode', 'ActionCode') === 'NEW_VERSION'; });
            const moved = defs.length - made.length;
            let text = 'Approved. This version is now Active.';
            if (made.length) text += ' New audit version for review: ' + made.map(function (d) {
                return (pick(d, 'definitionCode', 'DefinitionCode') || '') + ' v' + (pick(d, 'newVersionNumber', 'NewVersionNumber') || '');
            }).join(', ') + '.';
            if (moved) text += ' ' + moved + ' audit draft(s) moved to this version.';
            await afterAction(id, 'view', text);
        } catch (err) { actionFailed(err); }
    }

    async function returnToDraft(id) {
        const reason = await window.gracUi.prompt({ title: 'Return to Draft', message: 'Reason (optional):', multiline: true, confirmText: 'Return' });
        if (reason === null) return;
        try {
            await setAction(id, 'return', { note: reason || null });
            await afterAction(id, 'view', 'Returned to Draft.');
        } catch (err) { actionFailed(err); }
    }

    async function discardDraft(id) {
        if (!await window.gracUi.confirm('Discard this Draft version and its questions? The Active version is not changed.',
              { type: 'warning', title: 'Discard draft', confirmText: 'Discard' })) return;
        try {
            const r = await fetch(U(API + '/question-sets/' + encodeURIComponent(id) + '?organizationId=' + encodeURIComponent(state.orgId)),
                { method: 'DELETE', credentials: 'same-origin' });
            const j = await safeJson(r);
            if (!r.ok) throw new Error((j && (j.error || j.Error)) || ('HTTP ' + r.status));
            if (!document.getElementById('qsSetView').hidden) showList();
            else reloadSets();
            wf.setMessage('qsListMessage', 'Draft discarded.', 'ok');
        } catch (err) { actionFailed(err); }
    }""")

# ---- openSet: status field never shown; Actions only for saved sets in view
rep("""        document.getElementById('qsSetStatusField').hidden = !state.setId;   // status: saved sets only""",
"""        // 551: the version status replaces the old Status choice.
        document.getElementById('qsSetStatusField').hidden = true;""")
rep("""        if (editing) renderGrid(); else renderRead();
        syncDirty();
    }""", """        if (editing) renderGrid(); else renderRead();
        syncDirty();
        // 551: only a Draft version is edited.
        if (editing && state.setId && versionInfo(state.setId).status !== 'Draft') {
            openSet(state.setId, true, 'view');
            wf.setMessage('qsSetMessage', 'Only a Draft version can be changed. Use New Version to change an approved question set.', 'error');
        }
    }""")

# ---- renderRead: version facts, impact, versions
rep("""        const facts = [
            ['Code', pick(s, 'setCode', 'SetCode')],
            ['Name', pick(s, 'setName', 'SetName')],
            ['Status', pick(s, 'status', 'Status') || 'Active'],
            ['Questions', String(state.rows.length)],
            ['Description', pick(s, 'description', 'Description'), true],""", """        const vno = pick(s, 'versionNumber', 'VersionNumber');
        const by = function (who, when) { return [who, fmt(when)].filter(Boolean).join(', '); };
        const facts = [
            ['Code', pick(s, 'setCode', 'SetCode')],
            ['Name', pick(s, 'setName', 'SetName')],
            ['Version', vno ? 'v' + vno : ''],                                            // 551
            ['Status', statusLabel(pick(s, 'versionStatus', 'VersionStatus') || pick(s, 'status', 'Status') || 'Active')],
            ['Questions', String(state.rows.length)],
            ['Recommended', by(pick(s, 'submittedBy', 'SubmittedBy'), pick(s, 'submittedDt', 'SubmittedDt'))],
            ['Approved', by(pick(s, 'approvedBy', 'ApprovedBy'), pick(s, 'approvedDt', 'ApprovedDt'))],
            ['Change Note', pick(s, 'changeNote', 'ChangeNote'), true],
            ['Description', pick(s, 'description', 'Description'), true],""")
rep("""        }).join('') : '<tr><td colspan="6" class="pm-empty">No questions in this set yet. Use Actions &rsaquo; Edit to add some.</td></tr>';
    }""", """        }).join('') : '<tr><td colspan="6" class="pm-empty">No questions in this version yet.'
                       + (versionInfo(state.setId).status === 'Draft' ? ' Use Actions &rsaquo; Edit to add some.' : '') + '</td></tr>';
        renderImpact();
        renderVersions();
    }

    // 551: for a Draft / Under Review version -- the audits using another
    // version of the set and what approving this one does to each.
    async function renderImpact() {
        const box = document.getElementById('qsImpact');
        const vs = versionInfo(state.setId).status;
        box.hidden = true;
        if (vs !== 'Draft' && vs !== 'UnderReview') return;
        const sid = state.setId;
        const rows = await loadImpact(sid);
        if (String(sid) !== String(state.setId) || !rows.length) return;
        document.getElementById('qsImpactCount').textContent = String(rows.length);
        document.getElementById('qsImpactNote').textContent =
            rows.length + ' audit(s) use an older version of this question set. Approving this version moves them to it'
            + ' -- an audit that is Active gets a new version that needs Submit for Review and Approve again.';
        document.getElementById('qsImpactBody').innerHTML = rows.map(function (d) {
            return '<tr><td>' + wf.escape((pick(d, 'definitionCode', 'DefinitionCode') || '') + ' ' + (pick(d, 'definitionName', 'DefinitionName') || '')) + '</td>'
                 + '<td>v' + wf.escape(pick(d, 'currentVersionNumber', 'CurrentVersionNumber') || '') + '</td>'
                 + '<td>' + wf.badge(pick(d, 'currentStatusName', 'CurrentStatusName') || '') + '</td>'
                 + '<td>v' + wf.escape(pick(d, 'linkedSetVersion', 'LinkedSetVersion') || '') + '</td>'
                 + '<td>' + wf.escape(pick(d, 'actionText', 'ActionText') || '') + '</td></tr>';
        }).join('');
        box.hidden = false;
    }

    // 551: the set's versions, newest first; a row opens that version.
    async function renderVersions() {
        const body = document.getElementById('qsVersionBody');
        const sid = state.setId;
        body.innerHTML = '<tr><td colspan="6" class="pm-empty">Loading...</td></tr>';
        let rows = [];
        try {
            const r = await fetch(U(API + '/question-sets/' + encodeURIComponent(sid) + '/versions?organizationId='
                + encodeURIComponent(state.orgId)), { credentials: 'same-origin' });
            const b = r.ok ? await r.json() : null;
            rows = (b && (b.data || b.Data)) || [];
        } catch (_) { rows = []; }
        if (String(sid) !== String(state.setId)) return;
        const fmt = function (who, when) {
            if (!when) return '';
            const d = typeof window.gracFormatDisplayDate === 'function' ? window.gracFormatDisplayDate(when) : String(when).slice(0, 10);
            return wf.escape([who, d].filter(Boolean).join(', '));
        };
        body.innerHTML = rows.length ? rows.map(function (v) {
            const id = pick(v, 'questionSetId', 'QuestionSetId');
            const cur = String(id) === String(state.setId);
            return '<tr class="pm-row-clickable' + (cur ? ' qs-version-current is-selected' : '') + '" data-version-id="' + wf.escape(id) + '">'
                 + '<td>v' + wf.escape(pick(v, 'versionNumber', 'VersionNumber')) + '</td>'
                 + '<td>' + wf.badge(statusLabel(pick(v, 'versionStatus', 'VersionStatus'))) + '</td>'
                 + '<td style="text-align:right;">' + wf.escape(String(pick(v, 'questionCount', 'QuestionCount') || 0)) + '</td>'
                 + '<td>' + wf.escape(pick(v, 'changeNote', 'ChangeNote') || '') + '</td>'
                 + '<td>' + fmt(pick(v, 'submittedBy', 'SubmittedBy'), pick(v, 'submittedDt', 'SubmittedDt')) + '</td>'
                 + '<td>' + fmt(pick(v, 'approvedBy', 'ApprovedBy'), pick(v, 'approvedDt', 'ApprovedDt')) + '</td></tr>';
        }).join('') : '<tr><td colspan="6" class="pm-empty">No versions.</td></tr>';
    }""")

# versions row click (wire once)
rep("""        const grid = document.getElementById('qsGridBody');""", """        // 551: a version row opens that version.
        document.getElementById('qsVersionBody').addEventListener('click', function (e) {
            const tr = e.target.closest('tr[data-version-id]');
            if (tr && String(tr.getAttribute('data-version-id')) !== String(state.setId))
                openSet(tr.getAttribute('data-version-id'), false, 'view');
        });

        const grid = document.getElementById('qsGridBody');""")

# save: keep the set's status (field removed)
rep("""                status           : state.setId ? document.getElementById('qsSetStatus').value : 'Active',""",
"""                status           : pick(state.set, 'status', 'Status') || 'Active',   // 551: version status rules instead""")

open(f, 'w', encoding='utf-8').write(t)
print('ok')
