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
# --- form: Assurance Approach in the third track ---
("""and the Owner pair spans exactly the width of Name. The third
           track is intentionally left empty -- an aligned gap under
           Effective Date reads better than a second row on its own,
           unrelated rhythm.""",
"""and the Owner pair spans exactly the width of Name. 560: the third
           track holds Assurance Approach (how the audit is conducted),
           under Effective Date -- kept apart from Audit Category (what
           kind of audit), as the Audit Change spec 4.1 requires."""),
("""            </div>
        </div>
        <label class="pm-field" style="margin-top:10px;">Objective
            <textarea class="pm-input" id="oaDefObjective" rows="2" maxlength="4000"></textarea>
        </label>""",
"""            </div>
            @* 560: Assurance Approach -- org_assurance_approach_master via
               /practice/api/org-assurance/approaches. *@
            <label class="pm-field" style="min-width:0;">
                <span>Assurance Approach</span>
                <select class="pm-input" id="oaDefApproach">
                    <option value="">Loading approaches...</option>
                </select>
            </label>
        </div>
        <label class="pm-field" style="margin-top:10px;">Objective
            <textarea class="pm-input" id="oaDefObjective" rows="2" maxlength="4000"></textarea>
        </label>
        @* 560: Audit Mandate -- why the audit is required. *@
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
        </div>"""),
# --- script include ---
("""<script src="~/js/Shared/secure-nav.js" asp-append-version="true"></script>
""",
"""<script src="~/js/Shared/secure-nav.js" asp-append-version="true"></script>
@* 560: shared multi-select (.pm-checkcombo) for Applicable Frameworks. *@
<script src="~/js/Shared/checkcombo.js" asp-append-version="true"></script>
"""),
# --- state ---
("""        categories : []    // Admin-published assurance categories
""",
"""        categories : [],   // Admin-published assurance categories
        approaches : [],   // 560: Assurance Approaches
        frameworksByOrg : {} // 560: subscribed frameworks, per organization
"""),
# --- boot ---
("""        await loadCategories();
""",
"""        await loadCategories();
        await loadApproaches();   // 560
        if (window.gracCheckCombo) window.gracCheckCombo.wire(document.getElementById('oaDefForm'));
"""),
# --- loaders / renderers ---
("""    // 119 -- loadEmployees / renderEmployeeOptions retired.""",
"""    // 560: Assurance Approaches (org_assurance_approach_master), once per page.
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
    }

    // 560: the organization's subscribed frameworks (Practice picker list;
    // the "Organization Defined Practices" entry, release -1, is not a framework).
    async function loadFrameworks(orgId) {
        if (!orgId) return [];
        if (state.frameworksByOrg[orgId]) return state.frameworksByOrg[orgId];
        let rows = [];
        try {
            const r = await fetch(U('/practice/api/practice-picker/frameworks?organizationId=' + encodeURIComponent(orgId)),
                                  { credentials: 'same-origin' });
            if (r.ok) {
                const b = await r.json();
                rows = ((b && (b.data || b.Data)) || [])
                    .map(function (f) {
                        return { value: String(f.releaseId != null ? f.releaseId : f.ReleaseId),
                                 label: f.frameworkName || f.FrameworkName || '' };
                    })
                    .filter(function (f) { return f.value !== '-1' && f.value !== 'undefined' && f.label; });
            }
        } catch (_) { /* no list -- typed frameworks still work */ }
        state.frameworksByOrg[orgId] = rows;
        return rows;
    }

    // Saved frameworks: a subscribed one is ticked in the combo; one typed by
    // hand (or no longer subscribed) goes to Other Frameworks, so none is lost.
    async function renderFrameworks(saved) {
        const host  = document.getElementById('oaDefFrameworks');
        const other = document.getElementById('oaDefFrameworksOther');
        const options = await loadFrameworks(state.orgId);
        const known = new Set(options.map(function (o) { return o.value; }));
        const ticked = [], typed = [];
        (saved || []).forEach(function (f) {
            const rel = f.releaseId != null ? f.releaseId : f.ReleaseId;
            const name = f.frameworkName || f.FrameworkName || '';
            if (rel != null && known.has(String(rel))) ticked.push(String(rel));
            else if (name) typed.push(name);
        });
        host.innerHTML = window.gracCheckCombo
            ? window.gracCheckCombo.html(options, ticked, { ariaLabel: 'Applicable Frameworks' })
            : '';
        if (!options.length) {
            host.insertAdjacentHTML('beforeend',
                '<div style="font-size:12px; color:var(--fg-muted); padding-top:4px;">No subscribed frameworks -- type them under Other Frameworks.</div>');
        }
        other.value = typed.join('\\n');
    }

    // The list sent on save: ticked subscribed frameworks, then typed ones.
    function readFrameworks() {
        const combo = document.querySelector('#oaDefFrameworks [data-checkcombo]');
        const options = state.frameworksByOrg[state.orgId] || [];
        const byValue = {};
        options.forEach(function (o) { byValue[o.value] = o.label; });
        const list = (window.gracCheckCombo ? window.gracCheckCombo.values(combo) : []).map(function (v) {
            return { releaseId: Number(v), name: byValue[v] || v };
        });
        document.getElementById('oaDefFrameworksOther').value.split(/\\r?\\n/).forEach(function (line) {
            const name = line.trim();
            if (name) list.push({ releaseId: null, name: name });
        });
        return list;
    }

    // 119 -- loadEmployees / renderEmployeeOptions retired."""),
# --- edit: fill ---
("""                renderCategoryOptions(selectedCatId);
""",
"""                renderCategoryOptions(selectedCatId);

                // 560: Assurance Approach, Audit Mandate, Applicable Frameworks.
                const apId = d.assuranceApproachId != null ? d.assuranceApproachId : d.AssuranceApproachId;
                renderApproachOptions(apId != null ? String(apId) : '');
                document.getElementById('oaDefMandate').value = d.auditMandate || d.AuditMandate || '';
                await renderFrameworks(d.applicableFrameworks || d.ApplicableFrameworks || []);
"""),
# --- new: reset ---
("""            renderCategoryOptions('');
""",
"""            renderCategoryOptions('');
            renderApproachOptions('');   // 560
            await renderFrameworks([]);  // 560
"""),
# --- save body ---
("""            assuranceCategoryName   : catName,
            actor                   : null
        };""",
"""            assuranceCategoryName   : catName,
            actor                   : null,
            // 560: Assurance Approach, Audit Mandate, Applicable Frameworks
            assuranceApproachId     : document.getElementById('oaDefApproach').value
                                          ? Number(document.getElementById('oaDefApproach').value) : null,
            auditMandate            : document.getElementById('oaDefMandate').value || null,
            applicableFrameworks    : readFrameworks()
        };"""),
])

V = 'src/PracticeManagement.Web/wwwroot/js/Shared/audit-view.js'
patch(V, [
("""            ['Assurance Category', p('assuranceCategoryName', 'AssuranceCategoryName')],
""",
"""            ['Assurance Category', p('assuranceCategoryName', 'AssuranceCategoryName')],
            ['Assurance Approach', p('assuranceApproachName', 'AssuranceApproachName')],   // 560
            ['Applicable Frameworks', (p('applicableFrameworks', 'ApplicableFrameworks') || [])   // 560
                .map(function (f) { return pick(f, 'frameworkName', 'FrameworkName'); })
                .filter(Boolean).join(', ')],
"""),
("""        const narrative = [['Objective', p('objective', 'Objective')], ['Description', p('description', 'Description')]]""",
"""        const narrative = [['Objective', p('objective', 'Objective')], ['Audit Mandate', p('auditMandate', 'AuditMandate')],   // 560
                           ['Description', p('description', 'Description')]]"""),
])
