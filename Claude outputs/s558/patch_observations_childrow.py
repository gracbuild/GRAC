import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
def rep(a, b, n=1):
    global s
    assert s.count(a) == n, (a[:80], s.count(a))
    s = s.replace(a, b)

# ---- markup: one full-width list; the details wait in a holder and open in
# ---- a child row under the observation (the Audit Plans child row).
rep('''    <div style="display:grid; grid-template-columns:minmax(480px, 640px) 1fr; gap:12px; margin-top:12px;">
        @* LEFT: observation list *@
        <div>''', '''    @* 2026-11-14 (sir): one full-width list; an observation's details,
       evidence and history open in a CHILD ROW under it -- the Audit Plans
       child row (.oa-pl-wrap, tr.oa-pl-items-row > td > .oa-pl-items, the
       open row .oa-pl-open) -- instead of a panel beside the list. A row
       click (or View Details) opens it; a second click closes it. *@
    <div style="margin-top:12px;">
        @* the observation list *@
        <div>''')
rep('''            <div class="pm-table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>Observation</th>''', '''            <div class="pm-table-wrap oa-pl-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>Observation</th>''')
rep('''        @* RIGHT: selected observation detail + evidence + history *@
        <div>''', '''        @* the selected observation's detail + evidence + history: waits here,
           shown in the child row under its observation (mountDetail). *@
        <div id="oaObHolder" hidden><div id="oaObDetailPanel">''')
rep('''                        <tbody id="oaObHistoryBody">
                            <tr><td colspan="5" class="pm-empty">No history.</td></tr>
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
    </div>
</section>''', '''                        <tbody id="oaObHistoryBody">
                            <tr><td colspan="5" class="pm-empty">No history.</td></tr>
                        </tbody>
                    </table>
                </div>
            </div>
        </div></div>
    </div>
</section>''')

# ---- list rows: ids read with ??, no inline selection tint (the child-row
# ---- classes mark the open row), the title cell wraps, remount after render.
rep('''            const id     = row.observationId    || row.ObservationId;''',
    '''            // an id is never read with || -- 0 is an id (557)
            const id     = row.observationId    ?? row.ObservationId;''')
rep('''            const isSel  = state.selectedObsId && String(state.selectedObsId) === String(id);
''', '')
rep('''            return '<tr class="pm-row-clickable" data-id="' + id + '"' + (isSel ? ' style="background:var(--primary-50);"' : '') + '>'
                 + '<td><div>' + wf.escape(title) + gapBadge + '</div>\'''', '''            return '<tr class="pm-row-clickable" data-id="' + id + '">'
                 + '<td style="white-space:normal;"><div>' + wf.escape(title) + gapBadge + '</div>\'''')
rep('''                const id = tr.getAttribute('data-id');
                if (id) selectObservation(Number(id));''', '''                const id = tr.getAttribute('data-id');
                if (id === null || id === '') return;
                // a second click on the open observation closes its child row
                if (state.selectedObsId !== null && String(state.selectedObsId) === id) { resetDetail(); return; }
                selectObservation(Number(id));''')
rep('''                    return String(r.observationId || r.ObservationId) === String(id);
                });
                openRowMenu(btn, id, row);''', '''                    return String(r.observationId ?? r.ObservationId) === String(id);
                });
                openRowMenu(btn, id, row);''')
rep('''                if (oid) openGapCenterForObservation(oid);
            });
        });
    }''', '''                if (oid) openGapCenterForObservation(oid);
            });
        });
        mountDetail();   // an open observation stays open under its row
    }

    // The child row under the open observation (Audit Plans' pattern):
    // tr.oa-pl-items-row > td > .oa-pl-items holding #oaObDetailPanel.
    function mountDetail() {
        const body = document.getElementById('oaObListBody');
        const old  = body.querySelector('tr.oa-pl-items-row');
        if (old) old.remove();
        body.querySelectorAll('tr.oa-pl-open').forEach(function (r) { r.classList.remove('oa-pl-open', 'is-selected'); });
        if (state.selectedObsId === null || state.selectedObsId === undefined) return;
        const row = body.querySelector('tr[data-id="' + state.selectedObsId + '"]');
        if (!row) return;
        const tr = document.createElement('tr');
        tr.className = 'oa-pl-items-row is-selected';
        const td = document.createElement('td');
        td.colSpan = 5;
        const host = document.createElement('div');
        host.className = 'oa-pl-items';
        host.appendChild(document.getElementById('oaObDetailPanel'));
        td.appendChild(host);
        tr.appendChild(td);
        row.insertAdjacentElement('afterend', tr);
        row.classList.add('oa-pl-open', 'is-selected');
    }
    function unmountDetail() {
        document.getElementById('oaObHolder').appendChild(document.getElementById('oaObDetailPanel'));
        const body = document.getElementById('oaObListBody');
        const tr = body.querySelector('tr.oa-pl-items-row');
        if (tr) tr.remove();
        body.querySelectorAll('tr.oa-pl-open').forEach(function (r) { r.classList.remove('oa-pl-open', 'is-selected'); });
    }''')

# ---- select / reset: open and close the child row
rep('''    async function selectObservation(id) {
        state.selectedObsId = id;
        document.querySelectorAll('#oaObListBody tr').forEach(function (tr) {
            tr.style.background = (tr.getAttribute('data-id') === String(id)) ? 'var(--primary-50)' : '';
        });''', '''    async function selectObservation(id) {
        state.selectedObsId = id;
        mountDetail();''')
rep('''    function resetDetail() {
        state.selectedObsId = null; state.detail = null;''', '''    function resetDetail() {
        state.selectedObsId = null; state.detail = null;
        unmountDetail();''')

# ---- remaining id reads
rep('''                return String(r.observationId || r.ObservationId) === String(editId);''',
    '''                return String(r.observationId ?? r.ObservationId) === String(editId);''')
rep('''            const newId = j && (j.observationId || j.ObservationId);
            await reloadList();
            if (newId) await selectObservation(Number(newId));''', '''            const newId = j ? (j.observationId ?? j.ObservationId) : null;
            await reloadList();
            if (newId !== null && newId !== undefined) await selectObservation(Number(newId));''')

open(p, 'w', encoding='utf-8', newline='').write(s)
print('patched')
