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

B = 'src/PracticeManagement.Web/Views/Practice/Partials/org-assurance-scope-builder.cshtml'
patch(B, [
("""    543 (2026-11-13, sir) -- the scope moved from Audit Definition to Audit
    Configuration, where it is the first step and opens in its own popup.""",
"""    562 (2026-11-15, sir -- Audit Change spec 4.2.1, Step 1 SELECT AUDIT
    SUBJECTS): the cards are the audit subject types -- one per
    Operationalize dependency type (DEP_<CODE> dimensions: Person, Tool,
    Asset, Vendor, Application, Process, Location, ...; values from the
    type's source table) plus Control Statements. A subject resolves to the
    practice instances that depend on it, at execution (562 resolver).
    Subjects add up -- the audit covers the instances of every subject
    picked. A scope saved on the older Departments / Vendors / Assets
    filters opens read-only (legacy) and applies as saved.
    After a load or a save the page fires `audit-scope-loaded`
    { organizationId, definitionId, editable } -- Step 2 (Discover,
    Partials/_audit-scope-step) listens for it.

    543 (2026-11-13, sir) -- the scope moved from Audit Definition to Audit
    Configuration, where it is the first step and opens in its own popup."""),
("""            <strong>How to use this page:</strong>
            Pick values under any of the filters below. The audit will apply to items that match
            <em>every filter you fill in</em>. Leave a filter empty to skip it.""",
"""            <strong>Step 1 &mdash; Select Audit Subjects.</strong>
            Pick what this audit covers: the dependencies set up in Operationalize (people, tools, assets,
            vendors, applications, processes, locations, ...) and control statements. The audit covers the
            practice instances that depend on <em>any</em> subject you pick. Leave a type empty to skip it."""),
("""    const LEGACY_DIMS   = ['PRACTICE_INSTANCE'];
    const isLegacyDim   = function (code) { return LEGACY_DIMS.indexOf(code) >= 0; };
    // The dimensions Simple mode offers: pickable, not legacy.
    const simpleDims    = function () {
        return state.dimensions.filter(function (d) { return d.isPickable && !isLegacyDim(d.dimensionCode); });
    };""",
"""    // 562: the subject types -- Control Statements and one DEP_<CODE>
    // dimension per Operationalize dependency type. Every other dimension
    // (Practice Instances, and the older Departments / Vendors / Assets)
    // is legacy: a scope that uses it opens read-only and applies as saved.
    const isSubjectDim  = function (code) { return code === STATEMENT_DIM || String(code || '').indexOf('DEP_') === 0; };
    const isLegacyDim   = function (code) { return !isSubjectDim(code); };
    // The dimensions Simple mode offers: pickable subject types.
    const simpleDims    = function () {
        return state.dimensions.filter(function (d) { return d.isPickable && isSubjectDim(d.dimensionCode); });
    };"""),
("""        root.querySelector('[data-role="dim-name"]').textContent = 'Filter by ' + dim.dimensionName;""",
"""        root.querySelector('[data-role="dim-name"]').textContent = dim.dimensionName;   // 562: a subject type"""),
("""            setMessage('ok', 'Scope saved.');
            // Let a host page repaint its status chips.
            document.dispatchEvent(new CustomEvent('audit-setup-changed'));
            return true;""",
"""            setMessage('ok', 'Scope saved.');
            // Let a host page repaint its status chips.
            document.dispatchEvent(new CustomEvent('audit-setup-changed'));
            announceLoaded();   // 562: Step 2 re-discovers from the saved subjects
            return true;"""),
("""    window.__oaScopeBuilder = { save: saveScope, reload: function () { return reloadScope(true); } };""",
"""    window.__oaScopeBuilder = { save: saveScope, reload: function () { return reloadScope(true); } };

    // 562: tell Step 2 (Discover) which audit is loaded and whether it can
    // be edited.
    function announceLoaded() {
        try {
            document.dispatchEvent(new CustomEvent('audit-scope-loaded', { detail: {
                organizationId : state.orgId != null ? Number(state.orgId) : null,
                definitionId   : state.definitionId != null ? Number(state.definitionId) : null,
                editable       : !!(state.header && state.header.isEditable)
            }}));
        } catch (_) { /* the scope itself loaded; never fail on the notification */ }
    }"""),
])
