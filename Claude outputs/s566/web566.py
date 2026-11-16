# web566.py -- 566 Web: Audit Plans uses the shared engagement form. Run from the repo root.
import sys, os, re
WEB = 'src/PracticeManagement.Web'
p = os.path.join(WEB, 'Views/Practice/Partials/org-assurance-plans.cshtml')
s = open(p, encoding='utf-8').read()

def rep(old, new):
    global s
    n = s.count(old)
    if n != 1: sys.exit('count %d for %r' % (n, old[:90]))
    s = s.replace(old, new)

def cut(start_marker, end_marker, new, include_end=False):
    """Replace s[start:end] (end = start of end_marker, or its end)."""
    global s
    if s.count(start_marker) != 1: sys.exit('start marker %r' % start_marker[:80])
    i = s.index(start_marker)
    j = s.index(end_marker, i)
    if include_end: j += len(end_marker)
    s = s[:i] + new + s[j:]

# ---- header note
rep("""    554 (2026-11-14, sir) -- BRANCH AUDIT""",
"""    566 (2026-11-16) -- AUDIT ENGAGEMENTS AS A RECORD (spec 4.5)
      The engagement form is shared with the Audit Engagements screen:
      Partials/_audit-engagement-form + js/Shared/audit-engagement-form.js
      (window.gracEngagementForm), in full view like the plan form. It adds
      the audit subject, objective, scope, auditee, instructions and the
      audit team (lead, members, reviewer, subject matter experts, external
      auditors, remarks). The dialog, the dual list, the auditor / branch /
      programme lists, View Scope and Start Execution moved there.

    554 (2026-11-14, sir) -- BRANCH AUDIT""")

# ---- markup: the engagement dialog and View Scope -> the shared partial
cut('@* ---------- Engagement dialog (552; was "Plan Item") ---------- *@',
    '@* ---------- Add to Plan: pick the plan (546) ----------',
    """@* ---------- Engagement form + View Scope (566: shared with Audit
   Engagements; was the 552 Engagement dialog) ---------- *@
<partial name="Partials/_audit-engagement-form" />

""")

# ---- wiring: the dialog's own listeners live in the shared module
cut("        document.getElementById('oaPlItemClose').addEventListener('click', closeItemDialog);",
    "        wireRowMenus();",
    """        // 566: the engagement form and View Scope wire themselves
        // (js/Shared/audit-engagement-form.js).

""")

# ---- JS: start execution .. save item -> the shared module
cut("    async function startExecution(itemId) {",
    "    async function deleteItem(id) {",
    """    // 566: Start Execution -- the shared engagement module.
    async function startExecution(itemId) {
        const row = state.itemsById[String(itemId)] || {};
        const name = row.engagementName || row.EngagementName || row.definitionName || row.DefinitionName || 'this engagement';
        if (await window.gracEngagementForm.startExecution(state.orgId, state.selectedPlanId, itemId, name))
            reloadItems(state.selectedPlanId);
    }

    // -----------------------------------------------------------------
    // Engagement form -- 566: the shared full-view form
    // (Partials/_audit-engagement-form, js/Shared/audit-engagement-form.js):
    // the audits, programme, subject, scope, auditee and the audit team.
    // -----------------------------------------------------------------
    function openItemDialog(id) {
        if (!state.selectedPlanId) { window.gracUi.alert('Pick a plan first.'); return; }
        const plan = state.selectedPlan || state.plansById[String(state.selectedPlanId)] || {};
        const presetProgrammeId = state.presetProgrammeId;   // 565: Add Engagement from a programme
        state.presetProgrammeId = null;
        window.gracEngagementForm.open({
            orgId              : state.orgId,
            origin             : 'PLANNED',
            engagementId       : id || null,
            planId             : Number(state.selectedPlanId),
            planLabel          : (plan.planCode || plan.PlanCode || '') + ' - ' + (plan.planName || plan.PlanName || ''),
            presetProgrammeId  : id ? null : presetProgrammeId,
            presetDefinitionId : id ? null : state.presetDefinitionId,   // 546: from Add to Plan
            itemCount          : (state.itemsByPlan[String(state.selectedPlanId)] || []).length,
            definitions        : state.definitions,
            onSaved            : function () {
                // The plan the engagement went into stays open, read again.
                if (state.selectedPlanId) state.expanded.add(String(state.selectedPlanId));
                reloadPlans();
            }
        });
    }

""")

# ---- View Scope from the engagement's 3-dot
rep("""            openScope({ planItemId: Number(id) }, (row.engagementCode""",
    """            window.gracEngagementForm.openScope(state.orgId, { planItemId: Number(id) }, (row.engagementCode""")

# ---- the item message helpers went with the dialog
rep("""    function showItemMessage(kind, text) {
        const el = document.getElementById('oaPlItemMessage');
        el.style.display    = 'block';
        el.style.background = kind === 'error' ? 'var(--danger-100)' : 'var(--success-100)';
        el.style.color      = kind === 'error' ? 'var(--danger-700)' : 'var(--success-700)';
        el.textContent      = text;
    }
    function clearItemMessage() {
        const el = document.getElementById('oaPlItemMessage');
        el.style.display = 'none'; el.textContent = '';
    }
""", "")
rep("""        engDefs              : [],      // 552: the dialog's selected audits, in order (ids as strings)
""", "")

# Nothing of the old dialog may be left.
left = re.findall(r"oaPlItem\w*|oaPlScope\w*|engDefs|fillAuditors|fillBranches|branchState|renderAuditLists|showItemMessage|clearItemMessage|closeItemDialog|saveItem\b|(?<!\.)\bopenScope\(", s)
if left: sys.exit('left over: %s' % sorted(set(left)))
open(p, 'w', encoding='utf-8', newline='').write(s)
print('plans page ok')
