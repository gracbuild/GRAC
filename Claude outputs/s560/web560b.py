import sys, os
ROOT = sys.argv[1]

def patch(rel, pairs):
    p = os.path.join(ROOT, rel)
    raw = open(p, 'rb').read()
    crlf = b'\r\n' in raw
    bom = raw.startswith(b'\xef\xbb\xbf')
    s = raw.decode('utf-8-sig').replace('\r\n', '\n')
    for old, new in pairs:
        n = s.count(old)
        assert n == 1, (rel, old[:90], n)
        s = s.replace(old, new)
    if crlf: s = s.replace('\n', '\r\n')
    open(p, 'wb').write((b'\xef\xbb\xbf' if bom else b'') + s.encode('utf-8'))
    print('patched', rel)

F = 'src/PracticeManagement.Web/Views/Practice/Partials/org-assurance-definitions.cshtml'
patch(F, [
# --- markup: take Mandate textarea + frameworks grid out from under Objective ---
("""        @* 560: Audit Mandate -- why the audit is required. *@
        <label class="pm-field" style="margin-top:10px;">Audit Mandate
            <textarea class="pm-input" id="oaDefMandate" rows="2" maxlength="4000"></textarea>
        </label>
        @* 560: Applicable Frameworks -- the organization's subscribed
           frameworks (the Practice picker's list, a .pm-checkcombo), and
           frameworks typed by hand for an organization without
           subscriptions, one per line. *@
        <div style="display:grid; grid-template-columns:minmax(0,1fr) minmax(0,1fr); gap:10px; margin-top:10px; align-items:start;">
            <div class="pm-field" style="min-width:0;">
                <span>Applicable Frameworks</span>
                <div id="oaDefFrameworks"></div>
            </div>
            <label class="pm-field" style="min-width:0;">
                <span>Other Frameworks / Standards</span>
                <textarea class="pm-input" id="oaDefFrameworksOther" rows="2" maxlength="4000" placeholder="One per line"></textarea>
            </label>
        </div>""",
""""""),
# --- markup: third row on the same 1fr / 2fr / 1fr tracks, before Objective ---
("""        </div>
        <label class="pm-field" style="margin-top:10px;">Objective""",
"""        </div>
        @* 560: third row, same 1fr / 2fr / 1fr tracks as the two above:
           Audit Mandate (a dropdown -- the basis of the audit,
           /practice/api/org-assurance/mandates) under Audit Category;
           Applicable Frameworks under Owner -- the organization's subscribed
           frameworks (the Practice picker's list, a .pm-checkcombo); Other
           Frameworks / Standards under Assurance Approach -- typed by hand
           for an organization without subscriptions, one per line. *@
        <div style="display:grid; grid-template-columns:1fr 2fr 1fr; gap:10px; margin-top:10px; align-items:start;">
            <label class="pm-field" style="min-width:0;">
                <span>Audit Mandate</span>
                <select class="pm-input" id="oaDefMandate">
                    <option value="">Loading mandates...</option>
                </select>
            </label>
            <div class="pm-field" style="min-width:0;">
                <span>Applicable Frameworks</span>
                <div id="oaDefFrameworks"></div>
            </div>
            <label class="pm-field" style="min-width:0;">
                <span>Other Frameworks / Standards</span>
                <textarea class="pm-input" id="oaDefFrameworksOther" rows="2" maxlength="4000" placeholder="One per line"></textarea>
            </label>
        </div>
        <label class="pm-field" style="margin-top:10px;">Objective"""),
# --- state ---
("""        approaches : [],   // 560: Assurance Approaches
""",
"""        approaches : [],   // 560: Assurance Approaches
        mandates   : [],   // 560: Audit Mandates
"""),
# --- boot ---
("""        await loadApproaches();   // 560
""",
"""        // 560: Assurance Approach and Audit Mandate dropdowns
        await loadMaster('approaches', '/approaches', 'oaDefApproach', 'approaches');
        await loadMaster('mandates',   '/mandates',   'oaDefMandate',  'mandates');
"""),
# --- generic loader replaces the approach-only pair ---
("""    // 560: Assurance Approaches (org_assurance_approach_master), once per page.
    async function loadApproaches() {
        const sel = document.getElementById('oaDefApproach');
        try {
            const r = await fetch(U(API + '/approaches'), { credentials: 'same-origin' });
            if (!r.ok) {
                sel.innerHTML = '<option value="">(no approaches available)</option>';
                return;
            }
            const b = await r.json();
            state.approaches = (b && (b.data || b.Data)) || [];
            renderApproachOptions();
        } catch (_) {
            sel.innerHTML = '<option value="">(failed to load approaches)</option>';
        }
    }

    function renderApproachOptions(selectedId) {
        const sel = document.getElementById('oaDefApproach');
        sel.innerHTML = '';
        const placeholder = document.createElement('option');
        placeholder.value = '';
        placeholder.textContent = state.approaches.length ? '-- select an approach --' : '(no approaches available)';
        sel.appendChild(placeholder);
        for (const a of state.approaches) {
            const id  = a.id != null ? a.id : a.Id;
            const opt = document.createElement('option');
            opt.value = String(id != null ? id : '');
            opt.textContent = a.name || a.Name || '';
            sel.appendChild(opt);
        }
        if (selectedId != null && selectedId !== '') sel.value = String(selectedId);
    }""",
"""    // 560: the Definition masters -- Assurance Approach
    // (org_assurance_approach_master) and Audit Mandate
    // (org_assurance_mandate_master) -- loaded once per page into
    // state[key] and drawn into their select. One loader for both.
    async function loadMaster(key, path, selectId, noun) {
        const sel = document.getElementById(selectId);
        try {
            const r = await fetch(U(API + path), { credentials: 'same-origin' });
            if (!r.ok) {
                sel.innerHTML = '<option value="">(no ' + noun + ' available)</option>';
                return;
            }
            const b = await r.json();
            state[key] = (b && (b.data || b.Data)) || [];
            renderMasterOptions(key, selectId, noun);
        } catch (_) {
            sel.innerHTML = '<option value="">(failed to load ' + noun + ')</option>';
        }
    }

    function renderMasterOptions(key, selectId, noun, selectedId) {
        const sel = document.getElementById(selectId);
        const rows = state[key] || [];
        sel.innerHTML = '';
        const placeholder = document.createElement('option');
        placeholder.value = '';
        placeholder.textContent = rows.length ? '-- select --' : '(no ' + noun + ' available)';
        sel.appendChild(placeholder);
        for (const a of rows) {
            const id  = a.id != null ? a.id : a.Id;
            const opt = document.createElement('option');
            opt.value = String(id != null ? id : '');
            opt.textContent = a.name || a.Name || '';
            sel.appendChild(opt);
        }
        if (selectedId != null && selectedId !== '') sel.value = String(selectedId);
    }"""),
# --- edit: fill ---
("""                const apId = d.assuranceApproachId != null ? d.assuranceApproachId : d.AssuranceApproachId;
                renderApproachOptions(apId != null ? String(apId) : '');
                document.getElementById('oaDefMandate').value = d.auditMandate || d.AuditMandate || '';""",
"""                const apId = d.assuranceApproachId != null ? d.assuranceApproachId : d.AssuranceApproachId;
                renderMasterOptions('approaches', 'oaDefApproach', 'approaches', apId != null ? String(apId) : '');
                const mdId = d.auditMandateId != null ? d.auditMandateId : d.AuditMandateId;
                renderMasterOptions('mandates', 'oaDefMandate', 'mandates', mdId != null ? String(mdId) : '');"""),
# --- new: reset ---
("""            renderApproachOptions('');   // 560
""",
"""            renderMasterOptions('approaches', 'oaDefApproach', 'approaches', '');   // 560
            renderMasterOptions('mandates',   'oaDefMandate',  'mandates',   '');   // 560
"""),
# --- save ---
("""            auditMandate            : document.getElementById('oaDefMandate').value || null,""",
"""            auditMandateId          : document.getElementById('oaDefMandate').value
                                          ? Number(document.getElementById('oaDefMandate').value) : null,"""),
# --- comment on the second row ---
("""           and the Owner pair spans exactly the width of Name. 560: the third
           track holds Assurance Approach (how the audit is conducted),
           under Effective Date -- kept apart from Audit Category (what
           kind of audit), as the Audit Change spec 4.1 requires.""",
"""           and the Owner pair spans exactly the width of Name. 560: the third
           track holds Assurance Approach (how the audit is conducted),
           under Effective Date -- kept apart from Audit Category (what
           kind of audit), as the Audit Change spec 4.1 requires. A third
           row on the same tracks follows: Audit Mandate, Applicable
           Frameworks, Other Frameworks."""),
])

V = 'src/PracticeManagement.Web/wwwroot/js/Shared/audit-view.js'
patch(V, [
("""            ['Assurance Approach', p('assuranceApproachName', 'AssuranceApproachName')],   // 560
""",
"""            ['Assurance Approach', p('assuranceApproachName', 'AssuranceApproachName')],   // 560
            ['Audit Mandate',      p('auditMandateName', 'AuditMandateName')],             // 560
"""),
("""        const narrative = [['Objective', p('objective', 'Objective')], ['Audit Mandate', p('auditMandate', 'AuditMandate')],   // 560
                           ['Description', p('description', 'Description')]]""",
"""        const narrative = [['Objective', p('objective', 'Objective')], ['Description', p('description', 'Description')]]"""),
])
