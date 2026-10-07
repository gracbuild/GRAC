// =====================================================================
// dashboard-drill.js  (migration 414)
//
// The receiving end of a management-dashboard drill-down. A dashboard
// tile, ageing band or distribution bar opens an EXISTING list page with
// query parameters; this helper reads them once, turns them into the
// list API's drill parameters, and paints the filter banner that says
// what the list is showing, with a way back and a way out.
//
//   URL parameters (all optional; absent = the page as it always was)
//     organizationId  preselects the page's organization
//     drill           drill code the list procedure understands
//                     (open / pending / overdue / completed / noowner /
//                     lapsed / planned / inprogress / upcoming / ...)
//     statusText      a display status (Gap Register)
//     severity        a severity value
//     minAge, maxAge  one ageing band, in days
//     noOwner         1 = only rows with no owner ID
//     status          the page's own status filter value
//     overdue         1 = the page's own overdue filter (Task Board)
//     priority        the page's own priority filter (Task Board)
//     requestType     the page's own request-type filter (Exceptions)
//     tab             451: the tab of an asset screen holding the list
//     kind            451: a kind filter (reconciliation exception kind)
//     pending         451: 1 = only records awaiting approval
//     drillLabel      the words the banner shows
//     from            the dashboard screen key the user came from
//
// Pages keep their own filters; this adds a narrowing on top and is
// cleared by navigating to the page without the parameters (the same
// rule Operationalize's drill-down banner follows), so Back never
// re-applies a filter the user dismissed.
// =====================================================================
(function () {
  "use strict";
  const U = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const esc = v => String(v ?? "").replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#039;" })[ch]);
  // Everything a dashboard link may add; Clear filter removes all of it.
  const DRILL_KEYS = ["drill", "statusText", "severity", "minAge", "maxAge", "noOwner", "drillLabel", "from",
                      "status", "overdue", "priority", "requestType", "tab", "kind", "pending"];   // 451: tab, kind, pending

  function read() {
    const q = new URLSearchParams(window.location.search);
    const num = k => { const v = q.get(k); return v === null || v === "" || isNaN(Number(v)) ? null : Number(v); };
    const d = {
      organizationId: q.get("organizationId") || "",
      drill:      q.get("drill") || "",
      statusText: q.get("statusText") || "",
      severity:   q.get("severity") || "",
      minAge:     num("minAge"),
      maxAge:     num("maxAge"),
      noOwner:    q.get("noOwner") === "1",
      status:     q.get("status") || "",
      label:      q.get("drillLabel") || "",
      from:       q.get("from") || ""
    };
    d.overdue     = q.get("overdue") === "1";
    d.priority    = q.get("priority") || "";
    d.requestType = q.get("requestType");   // null = not given; "" = all types
    d.tab     = q.get("tab") || "";           // 451
    d.kind    = q.get("kind") || "";          // 451
    d.pending = q.get("pending") === "1";     // 451
    d.active = !!(d.drill || d.statusText || d.severity || d.minAge !== null || d.maxAge !== null
                  || d.noOwner || d.label || d.status || d.overdue || d.priority || d.tab || d.kind || d.pending);
    return d;
  }

  // The list API's drill parameters (ListDrillQuery in the Api tier).
  function apiParams(d) {
    const p = {};
    if (!d) return p;
    if (d.drill)            p.drillCode = d.drill;
    if (d.statusText)       p.statusText = d.statusText;
    if (d.severity)         p.severityText = d.severity;
    if (d.minAge !== null)  p.minAgeDays = String(d.minAge);
    if (d.maxAge !== null)  p.maxAgeDays = String(d.maxAge);
    if (d.noOwner)          p.noOwner = "1";
    return p;
  }

  function appendTo(qs, d) {
    Object.entries(apiParams(d)).forEach(([k, v]) => qs.set(k, v));
    return qs;
  }

  // Paints the banner into host (an element or an id). Clear filter
  // reloads the page path without the drill parameters; Dashboard goes
  // back to the dashboard the user came from.
  function banner(host, d) {
    const el = typeof host === "string" ? document.getElementById(host) : host;
    if (!el) return;
    if (!d || !d.active) { el.hidden = true; el.innerHTML = ""; return; }
    el.classList.add("pm-filter-banner");
    const back = /^[a-z0-9-]+-dashboard$/i.test(d.from || "")
      ? `<a class="pm-button" href="${esc(U("/Practice/Index/" + d.from))}">`
        + `<i class="fa-solid fa-arrow-left" aria-hidden="true"></i> Dashboard</a>`
      : "";
    el.innerHTML = `<span>Showing <strong>${esc(d.label || "a dashboard selection")}</strong> from the dashboard.</span>
      <span class="pm-filter-banner-actions">${back}
        <button class="pm-button" type="button" data-drill-clear-page>
          <i class="fa-solid fa-xmark" aria-hidden="true"></i> Clear filter</button></span>`;
    el.hidden = false;
    el.querySelector("[data-drill-clear-page]")?.addEventListener("click", () => {
      const q = new URLSearchParams(window.location.search);
      DRILL_KEYS.forEach(k => q.delete(k));
      const rest = q.toString();
      window.location.assign(window.location.pathname + (rest ? "?" + rest : ""));
    });
  }

  // Sets a select to a value when that value is one of its options.
  function preselect(selectOrId, value) {
    const sel = typeof selectOrId === "string" ? document.getElementById(selectOrId) : selectOrId;
    if (!sel || value === null || value === undefined || value === "") return false;
    if (![...sel.options].some(o => String(o.value) === String(value))) return false;
    sel.value = String(value);
    return true;
  }

  // 451: Asset & Contract screens (their lists filter in the page, not in
  // the API). Before the page loads its organization: the drill's
  // organization, then the page's own filter controls for the drill's tab
  // -- map = { TAB: { status | kind | pending: elementId } } ("" = no tab).
  function preselectFor(d, orgSelect, map) {
    if (!d) return;
    if (d.organizationId) preselect(orgSelect, d.organizationId);
    if (!d.active) return;
    const m = (map && (map[d.tab] || (!d.tab ? map[""] : null))) || {};
    Object.entries(m).forEach(([param, id]) => {
      const el = document.getElementById(id);
      if (!el) return;
      if (el.type === "checkbox") { if (param === "pending" && d.pending) el.checked = true; return; }
      preselect(el, d[param]);
    });
  }

  // 451: after the page loaded -- the banner above the page root and the
  // drill's tab (a button whose tabAttr equals d.tab), which reloads that
  // list with the preselected filter.
  function showOnPage(rootOrId, tabAttr, d) {
    const root = typeof rootOrId === "string" ? document.getElementById(rootOrId) : rootOrId;
    if (!root || !d || !d.active) return;
    let host = document.getElementById("pmDrillBanner");
    if (!host) {
      host = document.createElement("div");
      host.id = "pmDrillBanner";
      root.parentNode.insertBefore(host, root);
    }
    banner(host, d);
    if (tabAttr && d.tab) {
      const btn = [...document.querySelectorAll(`[${tabAttr}]`)].find(b => b.getAttribute(tabAttr) === d.tab);
      if (btn) btn.click();
    }
  }

  window.__pmDrill = { read, apiParams, appendTo, banner, preselect, preselectFor, showOnPage };
})();
