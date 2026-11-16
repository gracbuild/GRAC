# web567b.py -- 567 Web: Observations gets a "Finding" tab with the spec 4.7
# details (origin, criteria, condition, root cause, risk and impact,
# recommendation, management response, corrective action, supporting
# evidence), saved on their own. Run from the repo root.
import sys, os
P = 'src/PracticeManagement.Web/Views/Practice/Partials/org-assurance-observations.cshtml'
s = open(P, encoding='utf-8').read()
def rep(old, new, count=1):
    global s
    n = s.count(old)
    if n != count: sys.exit('count %d != %d for %r' % (n, count, old[:90]))
    s = s.replace(old, new)

rep("""                <button class="pm-tab active" data-tab="detail"   type="button">Details</button>
""", """                <button class="pm-tab active" data-tab="detail"   type="button">Details</button>
                @* 567: the spec 4.7 details, saved on their own. *@
                <button class="pm-tab"        data-tab="finding"  type="button">Finding</button>
""")

rep("""            <div id="oaObTabEvidence" hidden>""", """            @* 567 (spec 4.7): the finding's details -- the auditor's criteria,
               condition, root cause, risk / impact and recommendation, the
               owner's management response and corrective action. A finding
               raised from a working paper (Workpapers) arrives with the
               auditor's part filled. Not editable once the observation is Closed. *@
            <div id="oaObTabFinding" hidden>
                <div class="pm-message" id="oaObFindingMessage" style="display:none;"></div>
                <div class="oa-pl-plan-grid">
                    <label class="pm-field oa-pl-span-2">
                        <span>Origin</span>
                        <select class="pm-input" id="oaObFndOrigin"></select>
                    </label>
                    <label class="pm-field oa-pl-span-2">
                        <span>Working Paper</span>
                        <span class="pm-view-value" id="oaObFndPaper">--</span>
                    </label>
                    <label class="pm-field oa-pl-span-2">
                        <span>Audit Criteria</span>
                        <textarea class="pm-input" id="oaObFndCriteria" rows="2" placeholder="What should be"></textarea>
                    </label>
                    <label class="pm-field oa-pl-span-2">
                        <span>Condition / Finding</span>
                        <textarea class="pm-input" id="oaObFndCondition" rows="2" placeholder="What is"></textarea>
                    </label>
                    <label class="pm-field oa-pl-span-2">
                        <span>Root Cause</span>
                        <textarea class="pm-input" id="oaObFndRootCause" rows="2"></textarea>
                    </label>
                    <label class="pm-field oa-pl-span-2">
                        <span>Risk and Impact</span>
                        <textarea class="pm-input" id="oaObFndRisk" rows="2"></textarea>
                    </label>
                    <label class="pm-field oa-pl-span-all">
                        <span>Auditor Recommendation</span>
                        <textarea class="pm-input" id="oaObFndRecommendation" rows="2"></textarea>
                    </label>
                    <label class="pm-field oa-pl-span-2">
                        <span>Management Response</span>
                        <textarea class="pm-input" id="oaObFndResponse" rows="2"></textarea>
                    </label>
                    <label class="pm-field oa-pl-span-2">
                        <span>Corrective Action</span>
                        <textarea class="pm-input" id="oaObFndAction" rows="2"></textarea>
                    </label>
                    <label class="pm-field oa-pl-span-all">
                        <span>Supporting Evidence</span>
                        <textarea class="pm-input" id="oaObFndEvidence" rows="2"></textarea>
                    </label>
                </div>
                <div style="display:flex; justify-content:flex-end; margin-top:8px;">
                    <button class="pm-button primary" id="oaObFindingSaveBtn" type="button">
                        <i class="fa-solid fa-floppy-disk" aria-hidden="true"></i> Save Finding
                    </button>
                </div>
            </div>

            <div id="oaObTabEvidence" hidden>""")

# the tab lists
rep("""        ['detail','evidence','history'].forEach(function (t) {""",
    """        ['detail','finding','evidence','history'].forEach(function (t) {""", count=2)

rep("""        await Promise.all([loadEvidence(id), loadHistory(id)]);
    }""", """        await Promise.all([loadEvidence(id), loadHistory(id), loadFinding(id)]);   // 567: + the finding
    }

    // -----------------------------------------------------------------
    // 567 (spec 4.7): the Finding tab -- GET / POST observations/{id}/finding.
    // -----------------------------------------------------------------
    const FINDING_FIELDS = {
        oaObFndCriteria: 'auditCriteria', oaObFndCondition: 'conditionText', oaObFndRootCause: 'rootCause',
        oaObFndRisk: 'riskImpact', oaObFndRecommendation: 'recommendation', oaObFndResponse: 'managementResponse',
        oaObFndAction: 'correctiveAction', oaObFndEvidence: 'supportingEvidence'
    };
    function pickF(o, k) { return o ? (o[k] ?? o[k.charAt(0).toUpperCase() + k.slice(1)]) : undefined; }
    function findingMessage(kind, text) {
        const el = document.getElementById('oaObFindingMessage');
        el.style.display = text ? 'block' : 'none';
        el.style.background = kind === 'error' ? 'var(--danger-100)' : 'var(--success-100)';
        el.style.color      = kind === 'error' ? 'var(--danger-700)' : 'var(--success-700)';
        el.textContent = text || '';
    }
    async function loadFinding(id) {
        findingMessage('', '');
        try {
            if (!state.origins) {
                const r0 = await fetch(U(API + '/observation-origins'), { credentials: 'same-origin' });
                const b0 = r0.ok ? await r0.json() : null;
                state.origins = (b0 && (b0.data || b0.Data)) || [];
            }
            const r = await fetch(U(API + '/observations/' + id + '/finding?organizationId=' + encodeURIComponent(state.orgId)),
                                  { credentials: 'same-origin' });
            if (!r.ok) throw new Error('HTTP ' + r.status);
            const f = await r.json();
            const origin = document.getElementById('oaObFndOrigin');
            origin.innerHTML = '<option value="">-- not set --</option>' + state.origins.map(function (o) {
                const c = pickF(o, 'code');
                return '<option value="' + wf.escape(c) + '">' + wf.escape(pickF(o, 'name') || c) + '</option>';
            }).join('');
            origin.value = pickF(f, 'originCode') || '';
            document.getElementById('oaObFndPaper').textContent = pickF(f, 'workingPaperCode') || '--';
            Object.keys(FINDING_FIELDS).forEach(function (elId) {
                document.getElementById(elId).value = pickF(f, FINDING_FIELDS[elId]) || '';
            });
            const closed = pickF(f, 'statusCode') === 'Closed';
            document.querySelectorAll('#oaObTabFinding select, #oaObTabFinding textarea').forEach(function (el) { el.disabled = closed; });
            document.getElementById('oaObFindingSaveBtn').hidden = closed;
        } catch (err) {
            findingMessage('error', 'Failed to load the finding: ' + (err.message || err));
        }
    }
    async function saveFinding() {
        if (state.selectedObsId === null || state.selectedObsId === undefined) return;
        const body = { organizationId: Number(state.orgId), originCode: document.getElementById('oaObFndOrigin').value || null, actor: null };
        Object.keys(FINDING_FIELDS).forEach(function (elId) {
            body[FINDING_FIELDS[elId]] = document.getElementById(elId).value.trim() || null;
        });
        try {
            const r = await fetch(U(API + '/observations/' + state.selectedObsId + '/finding'), {
                method: 'POST', credentials: 'same-origin',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body)
            });
            let j = null; try { j = await r.json(); } catch (_) { }
            if (!r.ok) throw new Error((j && (j.error || j.Error)) || ('HTTP ' + r.status));
            findingMessage('ok', 'Finding saved.');
        } catch (err) { findingMessage('error', err.message || String(err)); }
    }""")

rep("""        document.getElementById('oaObNewBtn').addEventListener('click', function () { openSave(null); });""",
    """        document.getElementById('oaObNewBtn').addEventListener('click', function () { openSave(null); });
        document.getElementById('oaObFindingSaveBtn').addEventListener('click', saveFinding);   // 567""")

open(P, 'w', encoding='utf-8', newline='').write(s)
print('observations ok')
