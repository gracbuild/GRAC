// =====================================================================
// window.gracOrgPref -- one Organization choice across every screen
// (2026-10-06).
//
// An administrator who can see several organizations used to land on a
// different organization on each page: every page picked "the first
// option" of a list ordered by NAME (organizations/allowed) or not
// ordered at all (lookups). Now:
//
//   * Organization dropdowns are ordered by organization id.
//   * The default is the organization the user last PICKED on any page;
//     with nothing remembered (or no longer allowed), the lowest id.
//   * Only a user's own change is remembered (e.isTrusted) -- a page that
//     sets the value itself (URL ?organizationId=, dashboard drill-down,
//     a record's own organization) does not overwrite the choice, and an
//     address-bar organization still wins on that page because each page
//     applies it AFTER calling apply().
//
// Storage key is the one practice.js already used for the generic
// screens, so those and every other page share a single choice. Loaded in
// _Layout <head>, before any partial's inline script.
//
//   gracOrgPref.apply(select)        sort options by id, select the preferred
//                                    org (placeholders kept on top), remember
//                                    the user's later changes; returns value
//   gracOrgPref.preferred(values, s) the preferred id among values (s, when
//                                    given, is the select to remember from)
//   gracOrgPref.sort(list, valueOf)  copy of list ordered by numeric id
//   gracOrgPref.watch(select)        remember the user's changes on select
//   gracOrgPref.get() / save(id)
// =====================================================================
(function () {
    "use strict";

    var KEY = "grac.practice.selectedOrganizationId";

    function num(v) {
        var t = String(v == null ? "" : v).trim();
        return t === "" ? NaN : Number(t);
    }

    function get() {
        try { return window.localStorage.getItem(KEY) || ""; } catch (e) { return ""; }
    }

    // "" / "All organizations" is not an organization: keep the last one.
    function save(value) {
        var v = String(value == null ? "" : value).trim();
        if (!v || isNaN(num(v))) return;
        try { window.localStorage.setItem(KEY, v); } catch (e) { /* storage blocked: page still works */ }
    }

    function defaultValueOf(o) {
        if (o == null) return "";
        if (typeof o !== "object") return o;
        if (o.value != null) return o.value;
        if (o.Value != null) return o.Value;
        if (o.organizationId != null) return o.organizationId;
        return o.OrganizationId;
    }

    // Non-numeric entries (placeholders such as "Select organization" or
    // "All organizations") stay first, in their original order.
    function sort(list, valueOf) {
        var fn = valueOf || defaultValueOf;
        return (list || []).map(function (item, i) { return { item: item, i: i, n: num(fn(item)) }; })
            .sort(function (a, b) {
                var an = isNaN(a.n), bn = isNaN(b.n);
                if (an && bn) return a.i - b.i;
                if (an) return -1;
                if (bn) return 1;
                return a.n - b.n || a.i - b.i;
            })
            .map(function (x) { return x.item; });
    }

    function watch(sel) {
        if (sel && sel.dataset) sel.dataset.pmOrgPref = "1";
    }

    function preferred(values, sel) {
        if (sel) watch(sel);
        var ids = (values || []).map(function (v) { return String(v == null ? "" : v); })
            .filter(function (v) { return !isNaN(num(v)); });
        if (!ids.length) return "";
        var saved = get();
        if (saved && ids.indexOf(saved) >= 0) return saved;
        return sort(ids, function (v) { return v; })[0];
    }

    function apply(sel) {
        if (!sel) return "";
        var opts = Array.prototype.slice.call(sel.options);
        var ordered = sort(opts, function (o) { return o.value; });
        if (ordered.some(function (o, i) { return o !== opts[i]; }))
            ordered.forEach(function (o) { sel.appendChild(o); });
        var v = preferred(ordered.map(function (o) { return o.value; }), sel);
        if (v) sel.value = v;
        return v;
    }

    // Capture phase: runs whatever the page's own change handler does.
    document.addEventListener("change", function (e) {
        var t = e.target;
        if (!e.isTrusted || !t || t.tagName !== "SELECT" || !t.dataset || t.dataset.pmOrgPref !== "1") return;
        save(t.value);
    }, true);

    window.gracOrgPref = { KEY: KEY, get: get, save: save, sort: sort, preferred: preferred, apply: apply, watch: watch };
})();
