// =====================================================================
// practice-dashboard.js -- Home page organisation picker and module
// overview (503 -- Dashboard UI specification v2, section 5)
//
//   * Loads the organisations the caller may pick and publishes the choice
//     as "pm:home-organization" (home-my-work.js follows it -- unchanged).
//   * Module overview: one snapshot card per module dashboard the caller
//     may open (#homeModules data-modules, built by
//     PracticeController.Dashboard with the dashboard page's own
//     CanViewScreen rule, plus the sections the caller may see). Each card
//     reads THAT dashboard's own endpoint, so a Home figure is the same
//     number the module dashboard shows (spec 12.1):
//       governance, issues-actions, audit-assurance, tprm, asset-contract
//         GET /practice/api/management-dashboard/{module}?organizationId=
//       risk
//         GET /practice/api/risk-centre/dashboard?organizationId=
//     A figure is used only when its section is in the caller's sections
//     and the server returned it; nothing is recounted here.
//   * Upcoming: dated items ahead, from the dashboards' own lists --
//     audits starting in 30 days, risk acceptances ending in 60 days,
//     contracts ending in 90 days.
//   Cards fail independently: a module that cannot load shows an error
//   card with Retry; the others still render (spec 3.4).
//
// Replaces the 2026-09-29 organisation "Overview" (dashboard-summary),
// whose counts were organisation-wide whatever the caller's access.
// =====================================================================
(() => {
  "use strict";

  const pathBase = (window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "");
  const buildAppUrl = path => {
    path = String(path || "");
    if (!path || path === "#") return path || "#";
    if (/^(?:[a-z][a-z0-9+.-]*:)?\/\//i.test(path)) return path;
    return `${pathBase}/${path.replace(/^\/+/, "")}`;
  };
  const api = window.pmApi || buildAppUrl("practice-management-gateway");
  const apiData = result => result.data?.[0] || result.Data?.[0] || [];
  const escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, ch => ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", "\"":"&quot;", "'":"&#039;" })[ch]);
  const csrfToken = document.querySelector("input[name='__RequestVerificationToken']")?.value || document.querySelector("meta[name='csrf-token']")?.content || "";
  const organizationSelect = document.querySelector("#dashboardOrganization");
  const F = (row, k) => row?.[k] ?? row?.[k.charAt(0).toUpperCase() + k.slice(1)] ?? null;
  const D = window.gracDash;

  const modulesHost = document.getElementById("homeModules");
  const moduleBody = document.getElementById("homeModuleBody");
  let MODULES = [];
  try { MODULES = JSON.parse(modulesHost?.dataset.modules || "[]") || []; } catch (_) { MODULES = []; }

  function loginRedirect() {
    window.location.assign(`${window.location.origin}${buildAppUrl("Login")}?returnUrl=${encodeURIComponent(window.location.pathname + window.location.search)}`);
  }

  async function fetchJson(url, options = {}) {
    const response = await fetch(url, Object.assign({ credentials: "same-origin" }, options));
    if (response.status === 401) {
      loginRedirect();
      return null;
    }
    if (!response.ok) {
      const body = await response.json().catch(() => ({}));
      const error = new Error(body.error || body.message || `Request failed (${response.status}).`);
      error.notConfigured = !!(body.notConfigured ?? body.NotConfigured);   // 503: module not set up here
      throw error;
    }
    return response.json();
  }

  async function postQuery(entityType, data) {
    return fetchJson(`${api}/${entityType}/query`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ data })
    });
  }

  async function loadOrganizations() {
    if (!organizationSelect) return "";
    const result = await postQuery("lookups", { pageNumber: 1, pageSize: 1 });
    if (!result || !(result.success ?? result.Success)) throw new Error(result?.message || result?.Message || "Unable to load organizations.");
    // 2026-10-06: ordered by id; the default is the org last picked on any
    // page (Shared/org-preference.js), else the lowest id.
    const organizations = window.gracOrgPref.sort(apiData(result)
      .filter(item => (item.LookupKey || item.lookupKey) === "organizations")
      .map(item => ({ value: item.Value || item.value, label: item.Label || item.label }))
      .filter(item => item.value));
    organizationSelect.innerHTML = organizations.length
      ? organizations.map(item => `<option value="${escapeHtml(item.value)}">${escapeHtml(item.label)}</option>`).join("")
      : `<option value="">No organizations available</option>`;
    organizationSelect.disabled = organizations.length <= 1;
    return window.gracOrgPref.preferred(organizations.map(o => o.value), organizationSelect) || "";
  }

  // ---- Module snapshot definitions --------------------------------------
  // Each returns the card's figures from its dashboard's response. k(key)
  // is a KPI "section.kpi" value, has(key) whether the server returned it
  // for a section the caller may see. Labels follow the module dashboards.
  const of = (part, whole, unit) => {
    const p = D.pct(part, whole);
    return p === null ? "" : `${p}% of ${D.fmt(whole)} ${unit}`;
  };
  const SNAP = {
    governance: (k, has) => {
      const s = [];
      if (has("instances.total")) s.push({ label: "Implemented instances", value: k("instances.implemented"),
        qualifier: of(k("instances.implemented"), k("instances.total"), "instances") || "No instances yet",
        meter: D.pct(k("instances.implemented"), k("instances.total")), meterTone: "success" });
      if (has("instances.criticalopen")) s.push({ label: "Critical instances not implemented", value: k("instances.criticalopen"),
        qualifier: `${D.fmt(k("instances.critical"))} critical in total` });
      if (has("evidence.onetimemissing")) s.push({ label: "One-time evidence missing", value: k("evidence.onetimemissing"),
        qualifier: `of ${D.fmt(k("evidence.onetime"))} one-time rows` });
      return s;
    },
    "issues-actions": (k, has) => {
      const s = [];
      if (has("gaps.open")) s.push({ label: "Open issues", value: k("gaps.open"), qualifier: `${D.fmt(k("gaps.overdue"))} overdue &middot; ${D.fmt(k("gaps.noowner"))} no owner` });
      if (has("tasks.open")) s.push({ label: "Open tasks", value: k("tasks.open"), qualifier: `${D.fmt(k("tasks.overdue"))} overdue &middot; ${D.fmt(k("tasks.pending"))} pending review` });
      if (has("exceptions.pending")) s.push({ label: "Exceptions awaiting approval", value: k("exceptions.pending"), qualifier: `${D.fmt(k("exceptions.lapsed"))} lapsed waivers` });
      return s;
    },
    "audit-assurance": (k, has) => {
      const s = [];
      if (has("audits.inprogress")) s.push({ label: "Audits in progress", value: k("audits.inprogress"), qualifier: `${D.fmt(k("audits.planned"))} planned &middot; ${D.fmt(k("audits.overdue"))} overdue` });
      if (has("findings.pending")) s.push({ label: "Open findings", value: k("findings.pending"), qualifier: `${D.fmt(k("findings.overdue"))} overdue` });
      if (has("findings.awaiting")) s.push({ label: "Resolved, awaiting closure", value: k("findings.awaiting"), qualifier: "Validation or closure not complete" });
      return s;
    },
    tprm: (k, has) => {
      const s = [];
      if (has("tprmengagements.active")) s.push({ label: "Active engagements", value: k("tprmengagements.active"), qualifier: `${D.fmt(k("tprmengagements.highrisk"))} high or critical band` });
      // 525 (CR 2 8): the TP Risk Register
      if (has("tprmregister.total")) s.push({ label: "Vendors on the TP Risk Register", value: k("tprmregister.total"),
        qualifier: `${D.fmt(k("tprmregister.high"))} high or critical overall &middot; ${D.fmt(k("tprmregister.reviewoverdue"))} profile reviews overdue` });
      if (has("tprmdiligence.overdue")) s.push({ label: "Overdue due-diligence rounds", value: k("tprmdiligence.overdue"), qualifier: `${D.fmt(k("tprmdiligence.inprogress"))} rounds in progress` });
      if (has("tprmreviews.overdue")) s.push({ label: "Overdue reviews", value: k("tprmreviews.overdue"), qualifier: `${D.fmt(k("tprmreviews.due30"))} due in 30 days` });
      return s;
    },
    // 508: Policies & Documents
    documents: (k, has) => {
      const s = [];
      if (has("documents.current")) s.push({ label: "Current documents", value: k("documents.current"),
        qualifier: `${D.fmt(k("documents.pendingapproval"))} awaiting approval &middot; ${D.fmt(k("documents.draft"))} in draft` });
      if (has("documents.reviewoverdue")) s.push({ label: "Document reviews overdue", value: k("documents.reviewoverdue"),
        qualifier: `${D.fmt(k("documents.review30"))} due in 30 days` });
      if (has("acknowledgements.overdue")) s.push({ label: "Acknowledgements overdue", value: k("acknowledgements.overdue"),
        qualifier: `${D.fmt(k("acknowledgements.pending"))} pending in ${D.fmt(k("acknowledgements.openbatches"))} open batches` });
      else if (has("docevidence.expired")) s.push({ label: "Evidence expired", value: k("docevidence.expired"),
        qualifier: `${D.fmt(k("docevidence.expiring"))} expiring in 30 days` });
      return s;
    },
    "asset-contract": (k, has) => {
      const s = [];
      if (has("assets.inuse")) s.push({ label: "Assets in use", value: k("assets.inuse"), qualifier: `${D.fmt(k("assets.noowner"))} without an owner` });
      if (has("contracts.expiring30")) s.push({ label: "Contracts ending in 30 days", value: k("contracts.expiring30"), qualifier: `${D.fmt(k("contracts.expired"))} expired &middot; ${D.fmt(k("contracts.renewals"))} open renewals` });
      if (has("attestation.overdue")) s.push({ label: "Overdue attestations", value: k("attestation.overdue"), qualifier: `${D.fmt(k("attestation.disputed"))} disputed` });
      return s;
    }
  };

  // Risk Management reads the Risk Centre dashboard (413) -- the same
  // figures its dashboard tiles and heatmap notes show.
  function riskStats(d) {
    const r = F(d, "register") || {}, cov = F(d, "heatmapCoverage") || {};
    const open = Number(F(cov, "openRisks")) || 0;
    const overdueReviews = (F(d, "reviewAgeing") || [])
      .filter(b => F(b, "bandGroup") === "Overdue").reduce((s, b) => s + (Number(F(b, "riskCount")) || 0), 0);
    return [
      { label: "Open risks", value: open, qualifier: `${D.fmt(F(r, "underTreatmentCount"))} under treatment &middot; ${D.fmt(F(r, "unownedCount"))} no owner` },
      { label: "Residual assessment pending", value: F(cov, "residualPending") || 0, qualifier: `of ${D.fmt(open)} open risks` },
      { label: "Reviews overdue", value: overdueReviews, qualifier: `${D.fmt(F(r, "acceptedCount"))} accepted risks` }
    ];
  }

  // Upcoming sources: list key -> how a row reads (dashboard's own lists).
  const UPCOMING = {
    audits_upcoming:         { type: "Audit starts", module: "audit-assurance",
                               href: (row, org) => buildAppUrl(`Practice/org-assurance-executions?${new URLSearchParams({ organizationId: org, drill: "upcoming", drillLabel: "Audits starting in the next 30 days" })}`) },
    tprmacceptance_expiring: { type: "Risk acceptance ends", module: "tprm",
                               // 525: the engagement travels in the encrypted navigation code (Shared/secure-nav.js)
                               href: (row) => F(row, "recordId") ? buildAppUrl("Practice/Index/tprm-engagements") : null,
                               nav: (row, org) => F(row, "recordId") && window.gracSecureNav
                                 ? window.gracSecureNav.attrs("tprm-dashboard", "tprm-engagements", "TprmEngagement", F(row, "recordId"), org) : "" },
    contracts_expiring:      { type: "Contract ends", module: "asset-contract", href: () => null }
  };

  async function fetchModule(m, organizationId) {
    const url = m.module === "risk"
      ? buildAppUrl(`practice/api/risk-centre/dashboard?organizationId=${encodeURIComponent(organizationId)}`)
      : buildAppUrl(`practice/api/management-dashboard/${encodeURIComponent(m.module)}?organizationId=${encodeURIComponent(organizationId)}`);
    return fetchJson(url);
  }

  function moduleCard(m, d, organizationId) {
    const href = buildAppUrl(`Practice/Index/${m.screen}?organizationId=${encodeURIComponent(organizationId)}`);
    if (m.module === "risk") return D.snapshot({ title: m.title, href, stats: riskStats(d) });
    const allowed = new Set(m.sections || []);
    const kv = {};
    (F(d, "kpis") || []).forEach(x => {
      if (allowed.has(F(x, "sectionKey"))) kv[`${F(x, "sectionKey")}.${F(x, "kpiKey")}`] = Number(F(x, "value")) || 0;
    });
    const has = key => Object.prototype.hasOwnProperty.call(kv, key);
    const stats = (SNAP[m.module] || (() => []))(key => kv[key] || 0, has);
    let scope = "";
    if (m.module === "governance") {
      const t = (F(d, "kpis") || []).find(x => F(x, "sectionKey") === "instances" && F(x, "kpiKey") === "total");
      if (t) scope = /^your\b/i.test(String(F(t, "sectionTitle") || "")) ? "Your instances" : "All instances";
    }
    return D.snapshot({ title: m.title, href, scope, stats,
      note: stats.length ? "" : "Open the dashboard for this module's figures." });
  }

  function upcomingRows(results, organizationId) {
    const rows = [];
    results.forEach(({ m, res }) => {
      if (!res.ok || m.module === "risk") return;
      const allowed = new Set(m.sections || []);
      (F(res.value, "lists") || []).forEach(l => {
        const key = F(l, "listKey");
        const def = UPCOMING[key];
        if (!def || def.module !== m.module || !allowed.has(String(key).split("_")[0])) return;
        const date = F(l, "dateValue");
        if (!date) return;
        rows.push({ date: String(date).slice(0, 10), type: def.type, ref: F(l, "refText") || "", title: F(l, "title") || "",
                    owner: F(l, "ownerName") || "", href: def.href(l, organizationId), nav: def.nav ? def.nav(l, organizationId) : "" });
      });
    });
    return rows.sort((a, b) => a.date.localeCompare(b.date)).slice(0, 12);
  }

  // Upcoming is shown when the caller may see at least one of its lists.
  function hasUpcomingSource() {
    return MODULES.some(m => Object.entries(UPCOMING).some(([key, u]) =>
      u.module === m.module && (m.sections || []).includes(key.split("_")[0])));
  }

  async function loadModules(organizationId) {
    if (!moduleBody) return;
    if (!organizationId) { moduleBody.innerHTML = `<div class="pm-dx-empty">Select an organization.</div>`; return; }
    moduleBody.innerHTML = `<div class="pm-dx-grid pm-home-snaps">${MODULES.map(() => `<div class="pm-dx-skel chart"></div>`).join("")}</div>`;
    const results = await Promise.all(MODULES.map(m => fetchModule(m, organizationId)
      .then(value => ({ m, res: { ok: true, value } }), error => ({ m, res: { ok: false, error } }))));
    const cards = results.map(({ m, res }) => res.ok && res.value
      ? moduleCard(m, res.value, organizationId)
      // Not set up in this database (spec 3.4): a neutral note, not an
      // error and not zeros; no Retry -- retrying cannot change it.
      : res.error?.notConfigured
      ? `<div class="pm-dx-card pm-dx-snap"><div class="pm-dx-card-head"><span class="pm-dx-snap-title">${escapeHtml(m.title)}</span></div>`
        + `<div class="pm-dx-card-body"><div class="pm-dx-empty">Not set up in this environment yet.</div></div></div>`
      : `<div class="pm-dx-card pm-dx-snap"><div class="pm-dx-card-head"><span class="pm-dx-snap-title">${escapeHtml(m.title)}</span></div>`
        + `<div class="pm-dx-card-body">${D.errorCard({ title: "Could not load", message: res.error?.message || "" })}`
        + `<button type="button" class="pm-button" data-home-retry>Retry</button></div></div>`);
    let html = `<div class="pm-dx-grid pm-home-snaps">${cards.join("")}</div>`;
    if (hasUpcomingSource()) {
      const up = upcomingRows(results, organizationId);
      html += D.table({
        title: "Upcoming", meta: "Audits in 30 days, risk acceptances in 60 days, contracts in 90 days",
        columns: [{ label: "Date" }, { label: "What" }, { label: "Reference" }, { label: "Title" }, { label: "Owner" }],
        rows: up.map(r => [
          escapeHtml(window.gracFormatDateOnly ? window.gracFormatDateOnly(r.date) : r.date),
          escapeHtml(r.type),
          r.href ? `<a href="${escapeHtml(r.href)}"${r.nav || ""}>${escapeHtml(r.ref)}</a>` : escapeHtml(r.ref),
          escapeHtml(r.title),
          escapeHtml(r.owner || "Unassigned")
        ]),
        emptyText: "Nothing scheduled in these windows.", cls: "pm-home-upcoming"
      });
    }
    moduleBody.innerHTML = html;
    moduleBody.querySelectorAll("[data-home-retry]").forEach(b => b.addEventListener("click", () => loadModules(organizationId)));
  }

  function setContext(organizationId) {
    const ctx = document.getElementById("homeContext");
    if (!ctx) return;
    const name = organizationSelect && organizationSelect.selectedIndex >= 0 ? organizationSelect.options[organizationSelect.selectedIndex].text : "";
    ctx.innerHTML = organizationId
      ? [name && `<span><i class="fa-regular fa-building" aria-hidden="true"></i> ${escapeHtml(name)}</span>`,
         `<span><i class="fa-regular fa-clock" aria-hidden="true"></i> Refreshed ${escapeHtml(new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }))}</span>`]
          .filter(Boolean).join("")
      : "";
  }

  async function loadDashboard(organizationId) {
    // Home "My work" (home-my-work.js) follows this same Organization
    // picker rather than owning a second one (change request 2026-09-27).
    document.dispatchEvent(new CustomEvent("pm:home-organization", { detail: { organizationId: organizationId || "" } }));
    setContext(organizationId);
    await loadModules(organizationId);
  }

  function showError(error) {
    if (moduleBody) moduleBody.innerHTML = D.errorCard({ title: "Could not load the Home page", message: error.message });
    console.error("[home] failed to load:", error);
  }

  async function init() {
    try {
      const organizationId = await loadOrganizations();
      if (organizationSelect && organizationId) organizationSelect.value = organizationId;
      await loadDashboard(organizationSelect?.value || organizationId);
      organizationSelect?.addEventListener("change", () => loadDashboard(organizationSelect.value).catch(showError));
    } catch (error) {
      showError(error);
    }
  }

  init();
})();
