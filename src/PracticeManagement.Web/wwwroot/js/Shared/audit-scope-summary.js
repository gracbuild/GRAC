// =====================================================================
// window.gracAuditScopeSummary -- an audit scope as read-only sentences
// (2026-11-13).
//
// Moved out of the Audit Definition workspace's view page
// (_audit-definition-workspace.cshtml renderViewScope) when the Scope
// Builder dropped its Advanced mode: a scope saved with groups / OR /
// NOT / "All values" / Practice Instances can no longer be edited in
// the (simple-only) builder, so the builder shows it read-only with this
// same rendering. One implementation, used by both.
//
//   window.gracAuditScopeSummary.html(scopeJson) -> HTML string
//
// scopeJson is the GET .../definitions/{id}/scope body: { groups,
// conditions, values } (either casing). Groups joined by their operator,
// conditions by theirs. Styled by .oa-wv-group / .oa-wv-op / .oa-wv-join
// (practice-management.css).
// =====================================================================
(function () {
    'use strict';
    if (window.gracAuditScopeSummary) return;

    const esc = function (v) {
        return String(v == null ? '' : v).replace(/[&<>"']/g, function (c) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
        });
    };
    const pick = function (o, a, b) { return o ? (o[a] != null ? o[a] : o[b]) : null; };

    function html(json) {
        if (!json) return '<p class="pm-hint">Scope could not be loaded.</p>';
        const groups = (json.groups || json.Groups || []).slice().sort(function (a, b) {
            return (pick(a, 'groupOrder', 'GroupOrder') || 0) - (pick(b, 'groupOrder', 'GroupOrder') || 0);
        });
        const conds  = json.conditions || json.Conditions || [];
        const values = json.values     || json.Values     || [];
        if (!groups.length) return '<p class="pm-hint">No scope defined yet.</p>';

        return groups.map(function (g, gi) {
            const gid = String(pick(g, 'scopeGroupId', 'ScopeGroupId'));
            const label = pick(g, 'groupLabel', 'GroupLabel');
            const cs = conds.filter(function (c) { return String(pick(c, 'scopeGroupId', 'ScopeGroupId')) === gid; })
                .sort(function (a, b) { return (pick(a, 'conditionOrder', 'ConditionOrder') || 0) - (pick(b, 'conditionOrder', 'ConditionOrder') || 0); });
            const lines = cs.map(function (c, ci) {
                const cid = String(pick(c, 'scopeConditionId', 'ScopeConditionId'));
                const vals = pick(c, 'includeAll', 'IncludeAll')
                    ? 'All'
                    : values.filter(function (v) { return String(pick(v, 'scopeConditionId', 'ScopeConditionId')) === cid; })
                            .map(function (v) {
                                return pick(v, 'dimensionEntityName', 'DimensionEntityName')
                                    || pick(v, 'dimensionEntityCode', 'DimensionEntityCode') || '';
                            }).filter(Boolean).join(', ') || '-';
                return '<li>'
                     + (ci > 0 ? '<span class="oa-wv-op">' + esc(pick(c, 'conditionOperator', 'ConditionOperator') || 'AND') + '</span> ' : '')
                     + (pick(c, 'isNot', 'IsNot') ? '<span class="oa-wv-op">NOT</span> ' : '')
                     + '<strong>' + esc(pick(c, 'dimensionName', 'DimensionName') || pick(c, 'dimensionCode', 'DimensionCode')) + '</strong>: '
                     + esc(vals) + '</li>';
            }).join('');
            return (gi > 0 ? '<div class="oa-wv-join">' + esc(pick(g, 'groupOperator', 'GroupOperator') || 'AND') + '</div>' : '')
                 + '<div class="oa-wv-group"><div class="oa-wv-group-title">Group ' + (gi + 1)
                 + (label ? ' - ' + esc(label) : '') + '</div>'
                 + (lines ? '<ul>' + lines + '</ul>' : '<p class="pm-hint">No conditions.</p>') + '</div>';
        }).join('');
    }

    window.gracAuditScopeSummary = { html: html };
})();
