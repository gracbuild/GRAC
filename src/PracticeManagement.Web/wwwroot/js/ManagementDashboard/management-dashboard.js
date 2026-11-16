// =====================================================================
// management-dashboard.js  (migration 414)
//
// Renders the module landing dashboards (Partials/management-dashboard.cshtml):
// Governance, Issues & Actions, Audit Assurance, Third-Party Risk,
// Policies & Documents and Asset & Contract. The numbers come from SQL --
// one GET per dashboard, four result sets (KPIs, ageing, distributions,
// lists). Every dashboard uses the v2 layout (509): KPI cards, Needs
// attention beside the lead charts, a chart grid, then watchlists, drawn
// with ManagementDashboard/dashboard-components.js.
// This file only lays them out and turns every
// clickable element into a link to the EXISTING list page, with that
// page's own filter values (the receiving side is Shared/dashboard-drill.js).
//
// 451: also the Asset & Contract dashboard (asset-contract). Its tiles
// and bars open the asset screens with tab / status / kind / pending, which
// those screens read through Shared/dashboard-drill.js; an ageing band is a
// link only where the page filters by age (AGEING_DRILL).
//
// 490: also the Third-Party Risk dashboard (tprm). Its section keys carry a
// "tprm" prefix (one drill map serves every dashboard and "findings" is
// already Audit Assurance's). Tiles and bars open Engagements (stage /
// band / criticality / attention) or Reviews (status / type / dueWithin),
// which read those values on load; a list row opens the engagement.
//
// 509: Asset & Contract moved to the v2 layout (loadAssetContract) -- every
//      dashboard is now v2, so the 414 tile / bar / list renderers and the
//      414 load path are removed (sp_dashboard_asset_contract unchanged).
// 508: Policies & Documents dashboard (documents, new) on the v2 layout
//      (loadDocuments). Section "docevidence" -- "evidence" is Governance's.
// 507: Third-Party Risk moved to the v2 layout (loadTprm).
// 506: Audit Assurance moved to the v2 layout (loadAuditAssurance);
//      watchTable is the shared watchlist (Issues & Actions uses it too).
// 504: Issues & Actions moved to the v2 layout too (loadIssuesActions).
// 503: Governance moved to the v2 dashboard layout (UI specification v2,
// section 6): executive KPIs, Needs attention, framework coverage,
// signature distributions and a watchlist, drawn with the shared
// components in ManagementDashboard/dashboard-components.js
// (window.gracDash). The other dashboards keep the 414 layout here.
//
// Nothing here decides what "open", "overdue" or "pending" means: the
// drill passes the same bucket code (drill=) the dashboard counted with,
// and the list procedure filters by the same definition (414 section 3).
// =====================================================================
(function () {
  "use strict";

  const root = document.getElementById("mdRoot");
  if (!root) return;

  const U = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const esc = v => String(v ?? "").replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#039;" })[ch]);
  const F = (row, k) => row?.[k] ?? row?.[k.charAt(0).toUpperCase() + k.slice(1)] ?? null;
  const csrf = document.querySelector("input[name='__RequestVerificationToken']")?.value
            || document.querySelector("meta[name='csrf-token']")?.content || "";

  const MODULE  = root.dataset.module;          // governance | issues-actions | audit-assurance
  const SCREEN  = root.dataset.screen;          // <module>-dashboard (the "from" of every drill)
  const ALLOWED = new Set(String(root.dataset.sections || "").split(",").filter(Boolean));
  let orgId = "";

  // ---- drill targets --------------------------------------------------
  // One function per list page: (extra query values) -> URL. The
  // organization and the way back travel with every drill.
  function link(path, params, label) {
    const q = new URLSearchParams();
    if (orgId) q.set("organizationId", orgId);
    Object.entries(params || {}).forEach(([k, v]) => {
      if (v !== null && v !== undefined && v !== "") q.set(k, String(v));
    });
    if (label) q.set("drillLabel", label);
    q.set("from", SCREEN);
    return U(path) + "?" + q.toString();
  }
  const TARGET = {
    gaps:       (p, l) => link("/Practice/Index/gaps", p, l),
    tasks:      (p, l) => link("/Practice/Index/tasks", p, l),
    exceptions: (p, l) => link("/Practice/Index/exception-centre", p, l),
    audits:     (p, l) => link("/Practice/org-assurance-executions", p, l),
    findings:   (p, l) => link("/Practice/org-assurance-observations", p, l),
    plans:      (p, l) => link("/Practice/org-assurance-plans", p, l),
    // 451: Asset & Contract dashboard sections
    governance:    (p, l) => link("/Practice/Index/asset-governance", p, l),
    assets:        (p, l) => link("/Practice/Index/asset-register", p, l),
    technology:    (p, l) => link("/Practice/Index/asset-register", p, l),
    contracts:     (p, l) => link("/Practice/Index/asset-contracts", p, l),
    attestation:   (p, l) => link("/Practice/Index/asset-attestation", p, l),
    activities:    (p, l) => link("/Practice/Index/asset-activities", p, l),
    privacy:       (p, l) => link("/Practice/Index/asset-privacy", p, l),
    discovery:     (p, l) => link("/Practice/Index/asset-discovery", p, l),
    services:      (p, l) => link("/Practice/Index/business-services", p, l),
    relationships: (p, l) => link("/Practice/Index/asset-relationships", p, l),
    notifications: (p, l) => link("/Practice/Index/asset-notifications", p, l),
    // 490: Third-Party Risk dashboard sections
    tprmthirdparties: (p, l) => link("/Practice/Index/tprm-third-parties", p, l),
    tprmengagements:  (p, l) => link("/Practice/Index/tprm-engagements", p, l),
    tprmreviews:      (p, l) => link("/Practice/Index/tprm-reviews", p, l),
    tprmregister:     (p, l) => link("/Practice/Index/tprm-risk-register", p, l),   // 525
    // 508: Policies & Documents dashboard sections (Document Library reads
    // ?type= / ?stage= / ?status= codes; Evidence Center ?validity= / ?usage=).
    // Document Acknowledgements has no list filter, so it is never a drill.
    documents:   (p, l) => link("/Practice/Index/document-uploads", p, l),
    docevidence: (p, l) => link("/Practice/Index/evidence-center", p, l)
  };

  // KPI (section.key) -> list filter. Absent = the tile is not a link.
  const KPI_DRILL = {
    "gaps.total":         {},
    "gaps.open":          { drill: "open" },
    "gaps.pending":       { drill: "pending" },
    "gaps.overdue":       { drill: "overdue" },
    "gaps.completed":     { drill: "completed" },
    "gaps.noowner":       { drill: "noowner" },
    "tasks.total":        {},
    "tasks.open":         { status: "OpenSet" },
    "tasks.pending":      { status: "PendingReview" },
    "tasks.overdue":      { overdue: "1" },
    "tasks.completed":    { status: "Closed" },
    "tasks.noowner":      { status: "OpenSet", noOwner: "1" },
    "exceptions.total":   {},
    "exceptions.open":    { drill: "open" },
    "exceptions.pending": { status: "SubmittedForApproval" },
    "exceptions.lapsed":  { drill: "lapsed" },
    "exceptions.approved":{ status: "Approved" },
    "exceptions.noowner": { drill: "noowner" },
    "audits.total":       {},
    "audits.planned":     { drill: "planned" },
    "audits.inprogress":  { drill: "inprogress" },
    "audits.completed":   { drill: "completed" },
    "audits.overdue":     { drill: "overdue" },
    "audits.upcoming":    { drill: "upcoming" },
    "findings.total":     {},
    "findings.pending":   { drill: "pending" },
    "findings.awaiting":  { drill: "awaiting" },
    "findings.overdue":   { drill: "overdue" },
    "findings.closed":    { drill: "closed" },
    "findings.noowner":   { drill: "noowner" },
    "plans.total":        {},
    "plans.active":       { status: "Active" },
    // 451: Asset & Contract. A tile without an entry counts something its
    // page cannot filter to (in use, no owner, overdue activities ...), so
    // it is not a link.
    "governance.overall":     {},
    "governance.red":         {},
    "governance.amber":       {},
    "governance.green":       {},
    "governance.failing":     {},
    "assets.total":           {},
    "assets.draft":           { status: "DRAFT" },
    "assets.pending":         { pending: "1" },
    "contracts.active":       { tab: "CONTRACTS", status: "ACTIVE" },
    "contracts.expired":      { tab: "CONTRACTS", status: "EXPIRED" },
    "contracts.renewals":     { tab: "RENEWALS" },
    "contracts.gaps":         { tab: "GAPS" },
    "attestation.pending":    { tab: "ALL", status: "PENDING" },
    "attestation.inprogress": { tab: "ALL", status: "IN_PROGRESS" },
    "attestation.overdue":    { tab: "ALL", status: "OVERDUE" },
    "attestation.confirmed":  { tab: "ALL", status: "CONFIRMED" },
    "attestation.disputed":   { tab: "ALL", status: "DISPUTED" },
    "attestation.exceptions": { tab: "EXCEPTIONS", status: "OPEN_ALL" },
    "activities.open":        { tab: "OCCURRENCES", status: "OPEN" },
    "activities.reviews":     { tab: "REVIEWS", status: "OPEN" },
    "privacy.noncompliant":   { tab: "ASSETS", status: "NON_COMPLIANT" },
    "privacy.incomplete":     { tab: "ASSETS", status: "INCOMPLETE" },
    "privacy.undetermined":   { tab: "ASSETS", status: "UNDETERMINED" },
    "discovery.open":         { tab: "QUEUE" },
    "discovery.conflicts":    { tab: "QUEUE", kind: "CONFLICT" },
    "discovery.duplicates":   { tab: "QUEUE", kind: "DUPLICATE" },
    "discovery.stale":        { tab: "STALE" },
    "services.degraded":      { tab: "SERVICES", status: "DEGRADED" },
    "services.conflicts":     { tab: "CONFLICTS" },
    "relationships.active":   { tab: "RELATIONSHIPS", status: "ACTIVE" },
    "relationships.proposed": { tab: "RELATIONSHIPS", status: "PROPOSED" },
    "relationships.disputed": { tab: "RELATIONSHIPS", status: "DISPUTED" },
    "notifications.open":     { tab: "OCCURRENCES", status: "OPEN" },
    "notifications.failed":   { tab: "LOG", status: "Failed" },
    // 490: Third-Party Risk. Due-diligence, findings and acceptance tiles
    // count records inside engagements that no list filters to -- no link.
    "tprmthirdparties.total":          {},
    "tprmengagements.open":            { stage: "OPEN" },
    "tprmengagements.inassessment":    { stage: "IN_ASSESSMENT" },
    "tprmengagements.pendingdecision": { stage: "PENDING_DECISION" },
    "tprmengagements.active":          { stage: "ACTIVE" },
    "tprmengagements.reassess":        { attention: "REASSESS" },
    "tprmreviews.open":                { status: "OPEN" },
    "tprmreviews.overdue":             { status: "OVERDUE" },
    "tprmreviews.due30":               { status: "OPEN", dueWithin: "30" },
    "tprmreviews.triggered":           { status: "OPEN", type: "TRIGGERED" },
    // 525 (CR 2 6-8): applicability, admission and the TP Risk Register
    "tprmengagements.undecided":        { stage: "OPEN", applicability: "UNDECIDED" },
    "tprmengagements.deferred":         { stage: "OPEN", applicability: "DEFERRED" },
    "tprmengagements.admissionpending": { stage: "OPEN", applicability: "ADMISSION_PENDING" },
    "tprmengagements.excluded":         { stage: "OPEN", applicability: "EXCLUDED" },
    "tprmregister.total":               { status: "ACTIVE" },
    "tprmregister.impactopen":          { attention: "IMPACT_REVIEW" },
    "tprmregister.reviewoverdue":       { attention: "PROFILE_REVIEW_OVERDUE" },
    "tprmregister.reviewdue30":         { attention: "PROFILE_REVIEW_DUE" },
    "tprmregister.notrated":            { attention: "NOT_RATED" },
    "tprmregister.exiting":             { attention: "EXIT" },
    // 508: Policies & Documents. Review dates, owners and acknowledgements
    // are not Document Library filters, so those tiles are not links.
    "documents.current":         { status: "Active" },
    "documents.draft":           { stage: "Draft", status: "Active" },
    "documents.pendingapproval": { stage: "Reviewed", status: "Active" },
    "documents.published":       { stage: "Published", status: "Active" },
    "documents.retired":         { status: "Retired" },
    "docevidence.active":        {},
    "docevidence.expiring":      { validity: "Expiring" },
    "docevidence.expired":       { validity: "Expired" },
    "docevidence.unused":        { usage: "Unused" }
  };

  // Ageing group -> the open bucket the band narrows.
  const AGEING_DRILL = {
    gaps:       { drill: "open" },
    tasks:      { status: "OpenSet" },
    exceptions: { drill: "open" },
    findings:   { drill: "pending" }
  };

  // Distribution group -> (section, filter for one item key).
  const DIST_DRILL = {
    gaps_status:       ["gaps",       k => ({ statusText: k })],
    gaps_severity:     ["gaps",       k => ({ drill: "open", severity: k })],
    gaps_source:       ["gaps",       k => ({ drill: "open", source: k })],   // 504: Gap Register ?source=
    tasks_status:      ["tasks",      k => ({ status: k })],
    tasks_priority:    ["tasks",      k => ({ status: "OpenSet", priority: k })],
    exceptions_status: ["exceptions", k => ({ status: k })],
    exceptions_type:   ["exceptions", k => ({ requestType: k })],
    audits_status:     ["audits",     k => ({ status: k })],
    findings_severity: ["findings",   k => ({ drill: "pending", severity: k })],
    findings_status:   ["findings",   k => ({ status: k })],
    plans_status:      ["plans",      k => ({ status: k })],
    // 451: Asset & Contract (groups without an entry are not links)
    assets_status:        ["assets",        k => ({ status: k })],
    contracts_status:     ["contracts",     k => ({ tab: "CONTRACTS", status: k })],
    attestation_status:   ["attestation",   k => ({ tab: "ALL", status: k })],
    privacy_status:       ["privacy",       k => ({ tab: "ASSETS", status: k })],
    discovery_kind:       ["discovery",     k => ({ tab: "QUEUE", kind: k })],
    discovery_confidence: ["discovery",     k => ({ tab: "CONFIDENCE", status: k })],
    services_status:      ["services",      k => ({ tab: "SERVICES", status: k })],
    relationships_status: ["relationships", k => ({ tab: "RELATIONSHIPS", status: k })],
    // 490: Third-Party Risk
    tprmengagements_stage:       ["tprmengagements", k => ({ stage: k })],
    tprmengagements_band:        ["tprmengagements", k => ({ stage: "OPEN", band: k })],
    tprmengagements_criticality: ["tprmengagements", k => ({ stage: "OPEN", criticality: k })],
    tprmreviews_type:            ["tprmreviews",     k => ({ status: "OPEN", type: k })],
    // 525 (CR 2 6-8)
    tprmengagements_applicability: ["tprmengagements", k => ({ stage: "OPEN", applicability: k })],
    tprmregister_overall:          ["tprmregister",    k => ({ status: "ACTIVE", band: k })],
    // 508: Policies & Documents (item keys are master codes)
    documents_stage:      ["documents",   k => ({ stage: k, status: "Active" })],
    documents_status:     ["documents",   k => ({ status: k })],
    documents_type:       ["documents",   k => ({ type: k, status: "Active" })],
    docevidence_validity: ["docevidence", k => ({ validity: k })]
  };

  const sectionOf = key => String(key || "").split("_")[0];

  // Lists: the row opens the record's own existing page where there is
  // one (Task View, Gap View); audit rows open the Executions list on
  // the same bucket.
  function listRowHref(listKey, row) {
    const id = F(row, "recordId");
    if (listKey === "tasks_overdue" && id) return U("/Practice/Index/task-view") + "?taskId=" + encodeURIComponent(id);
    if (listKey === "gaps_overdue" && id)  return U("/Practice/Index/gap-view") + "?gapId=" + encodeURIComponent(id) + "&orgId=" + encodeURIComponent(orgId);
    if (listKey === "audits_upcoming") return TARGET.audits({ drill: "upcoming" }, "Audits starting in the next 30 days");
    if (listKey === "audits_overdue")  return TARGET.audits({ drill: "overdue" }, "Overdue audits");
    // 506: Observations has no single-record URL; a row opens the overdue list.
    if (listKey === "findings_overdue") return TARGET.findings({ drill: "overdue" }, "Overdue findings");
    // 451: an asset opens on the Asset Register (?assetId=, 450).
    if (listKey === "technology_unsupported" && id)
      return U("/Practice/Index/asset-register") + "?" + new URLSearchParams({ organizationId: orgId, assetId: id }).toString();
    if (listKey === "attestation_overdue") return TARGET.attestation({ tab: "ALL", status: "OVERDUE" }, "Overdue attestations");
    // 490 / 525: a Third-Party Management row opens its engagement or
    // register record through the encrypted navigation code (listRowNav);
    // the href is the list, used only if the code cannot be minted.
    if (listKey.startsWith("tprmregister") && id) return U("/Practice/Index/tprm-risk-register");
    if (listKey.startsWith("tprm") && id) return U("/Practice/Index/tprm-engagements");
    return null;
  }
  // 525: the record of a row, in the navigation code (Shared/secure-nav.js)
  // -- never as ?engagementId= / ?registerId= in the URL.
  function listRowNav(listKey, row) {
    const id = F(row, "recordId");
    if (!id || !listKey.startsWith("tprm") || !window.gracSecureNav) return "";
    return listKey.startsWith("tprmregister")
      ? window.gracSecureNav.attrs(SCREEN, "tprm-risk-register", "TprmRegister", id, orgId)
      : window.gracSecureNav.attrs(SCREEN, "tprm-engagements", "TprmEngagement", id, orgId);
  }

  // ---- Governance (503 -- Dashboard UI specification v2, section 6) -----
  // Layout: executive KPIs -> framework/release coverage (full row) ->
  // Needs attention | first analytics -> signature analytics -> watchlist.
  // Three sources, each the existing authoritative one, loaded together and failing independently:
  //   * management-dashboard/governance (sp_dashboard_governance, 503):
  //     instances, evidence, dependencies -- Operationalize's ownership
  //     rule (admin: all instances; anyone else: the instances they own);
  //   * subscribed-frameworks: per-release control statement counts
  //     (Standards & Frameworks' own query);
  //   * dashboard-summary: practice applicability counts (Home overview).
  //     Organisation-level, and labelled so (spec 6.5).
  // A card is drawn only for a section the caller may VIEW (ALLOWED) and
  // only from values the server returned; a value missing from an older
  // database body is left out, never shown as 0 (spec 3.4).
  // Links open an existing screen with a filter it really applies
  // (Operationalize ?status=, Control Statements ?releaseId=&status=);
  // everything else is plain text (spec 3.3).
  const D = window.gracDash;

  // Implementation status -> tone (Operationalize's status names).
  const IMPL_TONE = {
    "Implemented": "success", "Partially Implemented": "info",
    "Not Implemented": "danger", "Not Updated": "muted"
  };
  const IMPL_ORDER = ["Implemented", "Partially Implemented", "Not Implemented", "Not Updated"];
  const CRIT_TONE = { "Critical": "critical", "High": "warning", "Medium": "info", "Low": "neutral", "Not set": "faint" };
  const ALIGN_TONES = ["info", "info2", "info3", "neutral", "muted"];

  async function gatewayQuery(entityType, data) {
    const r = await fetch(U(`/practice-management-gateway/${entityType}/query`), {
      method: "POST", credentials: "same-origin",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrf },
      body: JSON.stringify({ data })
    });
    if (!r.ok) throw new Error(`${entityType}: HTTP ${r.status}`);
    const b = await r.json();
    if (!(b.success ?? b.Success)) throw new Error(b.message || b.Message || `${entityType} failed.`);
    return b.data || b.Data || [];
  }

  async function fetchDashboard() {
    const r = await fetch(U(`/practice/api/management-dashboard/${encodeURIComponent(MODULE)}?organizationId=${encodeURIComponent(orgId)}`),
                          { credentials: "same-origin" });
    const b = await r.json().catch(() => ({}));
    if (!r.ok) {
      const e = new Error(b.error || `HTTP ${r.status}`);
      e.notConfigured = !!(b.notConfigured ?? b.NotConfigured);   // 503: procedure not in this database
      throw e;
    }
    return b;
  }

  const settle = p => p.then(value => ({ ok: true, value }), error => ({ ok: false, error }));

  async function loadGovernance(body) {
    body.innerHTML = D.skeleton();
    const want = s => ALLOWED.has(s);
    const [dash, fw, sum] = await Promise.all([
      want("instances") || want("evidence") || want("dependencies") ? settle(fetchDashboard()) : Promise.resolve(null),
      want("frameworks") ? settle(gatewayQuery("subscribed-frameworks", { organizationId: Number(orgId), pageNumber: 1, pageSize: 500 })) : Promise.resolve(null),
      want("practices") ? settle(gatewayQuery("dashboard-summary", { organizationId: Number(orgId), pageNumber: 1, pageSize: 1 })) : Promise.resolve(null)
    ]);
    body.innerHTML = renderGovernance(dash, fw, sum);
    body.querySelectorAll(".pm-dx-row-2").forEach(D.balance);   // even out attention | lead visuals
    body.querySelectorAll("[data-md-retry]").forEach(b => b.addEventListener("click", load));
    setContext(dash && dash.ok ? (instancesOwnOnly(dash.value) ? "Instances you own" : "All instances") : "",
               "Instance, evidence and dependency figures follow Operationalize's ownership rule.");
  }

  function instancesOwnOnly(d) {
    const k = (F(d, "kpis") || []).find(x => F(x, "sectionKey") === "instances" && F(x, "kpiKey") === "total");
    return !!k && /^your\b/i.test(String(F(k, "sectionTitle") || ""));
  }

  function renderGovernance(dash, fw, sum) {
    const d = dash && dash.ok ? dash.value : null;
    const { has, v } = kpiValues(d);
    const dist = g => (d ? F(d, "distributions") || [] : []).filter(x => F(x, "groupKey") === g);
    const instScope = d ? (instancesOwnOnly(d) ? "Your instances" : "All instances") : "";

    const releases = fw && fw.ok ? (fw.value[0] || []) : null;
    const summary = sum && sum.ok ? ((sum.value[0] || [])[0] || {}) : null;
    const rs = k => (releases || []).reduce((s, r) => s + (Number(F(r, k)) || 0), 0);

    // Drill targets (existing screens, real filters only).
    const std = () => link("/Practice/Index/organization-controls", {}, "");
    const prac = () => link("/Practice/Index/organization-requirements", {}, "");
    const ops = status => link("/Practice/Index/resolve", status ? { status } : {}, status ? `Practice instances: ${status}` : "");
    const cs = (release, status) => {
      const q = new URLSearchParams({ organizationId: String(F(release, "OrganizationId") || orgId), releaseId: String(F(release, "ReleaseId")) });
      if (status) q.set("status", status);
      return U("/Practice/Index/source-statements") + "?" + q.toString();
    };

    const errors = [];
    const fail = (what, res) => errors.push(D.errorCard({
      title: `Could not load ${what}`, message: res.error && res.error.message, retryId: "" }));
    if (dash && !dash.ok) fail("practice instances, evidence and dependencies", dash);
    if (fw && !fw.ok) fail("framework coverage", fw);
    if (sum && !sum.ok) fail("practice applicability", sum);

    // ---- C. Executive KPIs ---------------------------------------------
    const kpis = [];
    if (releases) {
      const pending = rs("PendingUpdatesCount");
      kpis.push(D.kpiCard({
        label: "Subscribed frameworks", value: releases.length, href: std(),
        qualifier: pending ? `${D.fmt(pending)} repository update${pending === 1 ? "" : "s"} pending` : "No repository updates pending",
        title: "Framework releases this organisation subscribes to (Standards & Frameworks)."
      }));
      // 2026-11-10: implemented / applicable on one card. Implemented is
      // the Control Statements rule (every instance of every mapped
      // practice Implemented, no mapped practice without an instance);
      // Partially Implemented is not counted.
      const total = rs("TotalStatementsCount"), app = rs("ApplicableStatementsCount"), impl = rs("ImplementedStatementsCount");
      kpis.push(D.kpiCard({
        label: "Control statements", value: impl, suffix: `/ ${D.fmt(app)}`, href: std(),
        segments: [{ count: impl, tone: "success", label: "Implemented" },
                   { count: Math.max(0, app - impl), tone: "info", label: "Applicable, not implemented" }],
        segTotal: total,
        qualifier: `${D.dot("success")} ${D.fmt(impl)} implemented &middot; ${D.dot("info")} ${D.fmt(app)} applicable &middot; of ${D.fmt(total)}`,
        title: "Implemented / applicable statements across subscribed releases. Bar, out of all statements in subscribed releases: green = implemented, blue = applicable not yet implemented."
      }));
    }
    if (summary) {
      const total = Number(F(summary, "TotalPractices")) || 0, nu = Number(F(summary, "NotUpdatedPractices")) || 0;
      const app = Number(F(summary, "ApplicablePractices")) || 0;
      // 2026-11-10 / 528: implemented / applicable on one card (the
      // Practices grid's rule; Partially Implemented not counted). Without
      // the dashboard KPI (528 not run, or the instance sections not
      // allowed) the card falls back to applicability only.
      if (has("practices.implemented")) {
        const impl = v("practices.implemented");
        kpis.push(D.kpiCard({
          label: "Practices", scope: "Organisation", value: impl, suffix: `/ ${D.fmt(app)}`, href: prac(),
          segments: [{ count: impl, tone: "success", label: "Implemented" },
                     { count: Math.max(0, app - impl), tone: "info", label: "Applicable, not implemented" }],
          segTotal: total,
          qualifier: `${D.dot("success")} ${D.fmt(impl)} implemented &middot; ${D.dot("info")} ${D.fmt(app)} applicable &middot; of ${D.fmt(total)}`,
          title: `Implemented / applicable organisation practices (${D.fmt(nu)} not updated). Bar, out of all active practices: green = implemented, blue = applicable not yet implemented.`
        }));
      } else {
        const decided = D.pct(total - nu, total);
        kpis.push(D.kpiCard({
          label: "Applicable practices", scope: "Organisation", value: app, href: prac(),
          qualifier: `of ${D.fmt(total)} practices &middot; ${D.fmt(nu)} not updated`,
          meter: decided, meterTone: "info",
          title: "Organisation practices marked Applicable. Bar: practices with an applicability decision / all active practices."
        }));
      }
    }
    if (has("instances.total")) {
      // 2026-11-10: one card, implemented / all active instances (was two
      // cards). Implemented = status Implemented; Partially Implemented is
      // not counted.
      const total = v("instances.total"), impl = v("instances.implemented");
      const p = D.pct(impl, total);
      kpis.push(D.kpiCard({
        label: "Practice instances", scope: instScope, value: impl, suffix: `/ ${D.fmt(total)}`, href: ops(""),
        segments: [{ count: impl, tone: "success", label: "Implemented" },
                   { count: Math.max(0, total - impl), tone: "info", label: "Not implemented" }],
        segTotal: total,
        qualifier: total
          ? `${D.dot("success")} ${D.fmt(impl)} implemented (${p}%) &middot; ${D.dot("info")} ${D.fmt(total - impl)} not yet`
          : "No instances yet",
        title: "Implemented / all active practice instances in scope (Operationalize). Bar: green = implemented, blue = not yet implemented (Not Implemented, Not Updated, Partially Implemented)."
      }));
    }
    if (has("evidence.onetime")) {
      const all = v("evidence.onetime"), ok = v("evidence.onetimeresolved");
      const p = D.pct(ok, all);
      kpis.push(D.kpiCard({
        label: "One-time evidence provided", scope: instScope, value: ok,
        qualifier: all ? `of ${D.fmt(all)} rows &middot; ${D.fmt(v("evidence.onetimemissing"))} missing` : "No one-time evidence rows",
        meter: p, meterTone: "success",
        title: "One-time evidence rows resolved by their chosen option (upload / Evidence Center link, or location and locator) / all one-time evidence rows."
      }));
    }

    // ---- D. Needs attention ----------------------------------------------
    const att = [];
    if (releases) {
      const one = releases.length === 1 ? releases[0] : null;
      att.push({ title: "Control statements not updated", severity: "High", count: rs("NotUpdatedStatementsCount"),
        detail: one ? "No applicability decision yet." : "No applicability decision yet; open per release in Framework coverage.",
        href: one ? cs(one, "Not Updated") : null });
      att.push({ title: "Repository updates pending", severity: "Medium", count: rs("PendingUpdatesCount"),
        detail: "Framework changes awaiting review or adoption.",
        href: link("/Practice/Index/repository-updates", {}, "") });
    }
    if (summary) att.push({ title: "Practices not updated", severity: "High", count: Number(F(summary, "NotUpdatedPractices")) || 0,
      detail: "Organisation practices with no applicability decision." });
    if (has("practices.noinstance")) att.push({ title: "Applicable practices without an instance", severity: "High",
      count: v("practices.noinstance"), detail: "Applicable practices need at least one practice instance." });
    if (has("instances.criticalopen")) att.push({ title: "Critical instances not implemented", severity: "High",
      count: v("instances.criticalopen"), detail: "Criticality Critical, status other than Implemented.", href: "#mdWatch" });
    if (has("evidence.recurringoverdue")) att.push({ title: "Recurring evidence tasks overdue", severity: "High",
      count: v("evidence.recurringoverdue"), detail: "Scheduled tasks past due whose obligation needs recurring evidence." });
    if (has("evidence.onetimemissing")) att.push({ title: "One-time evidence missing", severity: "Medium",
      count: v("evidence.onetimemissing"), detail: "One-time evidence rows not yet provided on Operationalize." });
    if (has("instances.noowner")) att.push({ title: "Instances without an owner", severity: "Medium",
      count: v("instances.noowner"), detail: "Active practice instances with no primary owner." });
    if (has("instances.notimplemented")) att.push({ title: "Instances not implemented", severity: "Medium",
      count: v("instances.notimplemented"), detail: "Implementation status Not Implemented.", href: ops("Not Implemented") });
    if (has("instances.notupdated")) att.push({ title: "Instances not updated", severity: "Medium",
      count: v("instances.notupdated"), detail: "No applicable obligation updated yet.", href: ops("Not Updated") });
    if (has("dependencies.expired")) att.push({ title: "Instances with an expired dependency", severity: "Medium",
      count: v("dependencies.expired"), detail: "Linked tool licence/support, application support/end of life or vendor contract date has passed." });

    // ---- E1. Framework / release coverage ---------------------------------
    let coverage = "";
    if (releases) {
      const cell = (r, key, status) => {
        const n = Number(F(r, key)) || 0;
        return n > 0 && status ? `<a href="${esc(cs(r, status))}">${D.fmt(n)}</a>` : D.fmt(n);
      };
      const rows = releases.map(r => {
        const t = Number(F(r, "TotalStatementsCount")) || 0;
        const a = Number(F(r, "ApplicableStatementsCount")) || 0;
        const na = Number(F(r, "NotApplicableStatementsCount")) || 0;
        const nu = Number(F(r, "NotUpdatedStatementsCount")) || 0;
        const other = Math.max(0, t - a - na - nu);
        const impl = Number(F(r, "ImplementedStatementsCount")) || 0;
        const ip = D.pct(impl, a);
        const seg = (n, tn, lbl) => n > 0 ? `<span style="flex:${n} 1 0;background:var(--${tn})" title="${lbl}: ${n}"></span>` : "";
        return [
          `<a href="${esc(cs(r, ""))}">${esc(F(r, "FrameworkRelease") || F(r, "ReleaseVersion") || "")}</a>`,
          D.fmt(t),
          `<span class="pm-dx-stack sm" role="img" aria-label="Applicable ${a}, not applicable ${na}, not updated ${nu}">${seg(a, "primary-500", "Applicable")}${seg(na, "neutral-400", "Not applicable")}${seg(other, "primary-200", "Other decision")}${seg(nu, "warning-500", "Not updated")}</span>`,
          cell(r, "ApplicableStatementsCount", "Applicable"),
          D.fmt(na),
          cell(r, "NotUpdatedStatementsCount", "Not Updated"),
          `${D.fmt(impl)}${ip === null ? "" : ` <span class="pm-dx-muted">${ip}%</span>`}`,
          D.fmt(Number(F(r, "PendingUpdatesCount")) || 0)
        ];
      });
      coverage = D.table({
        title: "Framework coverage", meta: `${releases.length} release${releases.length === 1 ? "" : "s"}`,
        columns: [{ label: "Framework / Release" }, { label: "Statements", cls: "num" }, { label: "Applicability", cls: "bar" },
                  { label: "Applicable", cls: "num" }, { label: "Not applicable", cls: "num" }, { label: "Not updated", cls: "num" },
                  { label: "Implemented", cls: "num" }, { label: "Updates pending", cls: "num" }],
        rows, emptyText: "No framework subscribed. Subscribe in Standards & Frameworks.",
        footer: `<p class="pm-dx-note"><span class="pm-dx-dot" style="background:var(--primary-500)"></span>Applicable <span class="pm-dx-dot" style="background:var(--neutral-400)"></span>Not applicable <span class="pm-dx-dot" style="background:var(--primary-200)"></span>Other decision <span class="pm-dx-dot" style="background:var(--warning-500)"></span>Not updated &middot; Implemented % = implemented / applicable statements.</p>`
      });
    }

    // ---- E2. Signature analytics -----------------------------------------
    const charts = [];
    if (has("instances.total")) {
      const st = dist("instances_status");
      const known = IMPL_ORDER.map(name => {
        const row = st.find(x => F(x, "itemKey") === name);
        return { label: name, count: row ? Number(F(row, "itemCount")) || 0 : 0, tone: IMPL_TONE[name], href: ops(name) };
      });
      const others = st.filter(x => !IMPL_ORDER.includes(F(x, "itemKey")))
        .map(x => ({ label: F(x, "itemLabel"), count: Number(F(x, "itemCount")) || 0, tone: "neutral",
                     href: F(x, "itemKey") ? ops(F(x, "itemKey")) : null }));
      charts.push(D.distCard({ title: "Implementation status", scope: instScope, total: v("instances.total"), totalLabel: "instances",
        items: known.concat(others), emptyText: "No practice instances in this scope." }));
    }
    if (summary) {
      const t = Number(F(summary, "TotalPractices")) || 0, a = Number(F(summary, "ApplicablePractices")) || 0;
      const na = Number(F(summary, "NotApplicablePractices")) || 0, nu = Number(F(summary, "NotUpdatedPractices")) || 0;
      const items = [{ label: "Applicable", count: a, tone: "info" }, { label: "Not applicable", count: na, tone: "neutral" }];
      if (t - a - na - nu > 0) items.push({ label: "Other decision", count: t - a - na - nu, tone: "info2" });
      items.push({ label: "Not updated", count: nu, tone: "warning" });
      charts.push(D.distCard({ title: "Practice applicability", scope: "Organisation", total: t, totalLabel: "practices", items,
        footer: has("practices.noinstance") ? `<p class="pm-dx-foot"><span>Applicable without an instance</span><strong>${D.fmt(v("practices.noinstance"))}</strong></p>` : "",
        emptyText: "No practices yet." }));
    }
    if (has("instances.critical")) {
      const cr = dist("instances_criticality").map(x => ({ label: F(x, "itemLabel"), count: Number(F(x, "itemCount")) || 0,
        tone: CRIT_TONE[F(x, "itemLabel")] || "neutral" }));
      charts.push(D.distCard({ title: "Instance criticality", scope: instScope, total: v("instances.total"), totalLabel: "instances", items: cr,
        footer: `<p class="pm-dx-foot"><span>Critical not implemented</span><strong>${D.fmt(v("instances.criticalopen"))}</strong></p>`,
        emptyText: "No practice instances in this scope." }));
    }
    if (has("evidence.onetime")) {
      const foot = `<p class="pm-dx-foot"><span>Recurring evidence rows</span><strong>${D.fmt(v("evidence.recurring"))}</strong></p>`
        + `<p class="pm-dx-foot"><span>Recurring evidence tasks overdue</span><strong>${D.fmt(v("evidence.recurringoverdue"))}</strong></p>`;
      charts.push(D.distCard({ title: "One-time evidence", scope: instScope, total: v("evidence.onetime"), totalLabel: "rows",
        items: [{ label: "Provided", count: v("evidence.onetimeresolved"), tone: "success" },
                { label: "Missing", count: v("evidence.onetimemissing"), tone: "warning" }],
        footer: foot, emptyText: "No one-time evidence rows in this scope." }));
      const al = dist("evidence_alignment").map((x, ix) => ({ label: F(x, "itemLabel"), count: Number(F(x, "itemCount")) || 0,
        tone: F(x, "itemLabel") === "Not set" ? "faint" : ALIGN_TONES[ix % ALIGN_TONES.length] }));
      charts.push(D.distCard({ title: "Evidence alignment status", scope: instScope, totalLabel: "rows", items: al,
        emptyText: "No evidence rows in this scope.",
        footer: `<p class="pm-dx-note">As recorded on each evidence row (inherited from the repository or organisation-defined); one-time and recurring rows together.</p>` }));
    }
    if (has("dependencies.linked")) {
      const dc = dist("dependencies_category").map(x => ({ label: F(x, "itemLabel"), count: Number(F(x, "itemCount")) || 0, tone: "info" }));
      const withP = D.pct(v("dependencies.instances"), v("instances.total"));
      charts.push(D.distCard({ title: "Dependencies by category", scope: instScope, total: v("dependencies.linked"), totalLabel: "linked objects",
        mode: "bars", items: dc, emptyText: "No dependency objects linked in this scope.",
        footer: `<p class="pm-dx-foot"><span>Instances with dependencies</span><strong>${D.fmt(v("dependencies.instances"))}${withP === null ? "" : ` <span class="pm-dx-muted">${withP}%</span>`}</strong></p>`
              + `<p class="pm-dx-foot"><span>Instances with an expired dependency</span><strong>${D.fmt(v("dependencies.expired"))}</strong></p>` }));
    }

    // ---- F. Watchlist -----------------------------------------------------
    let watch = "";
    if (has("instances.criticalopen")) {
      const rows = (d ? F(d, "lists") || [] : []).filter(l => F(l, "listKey") === "instances_critical").map(r => {
        const id = F(r, "recordId");
        const href = id ? U("/Practice/Index/resolve-workspace") + "?" + new URLSearchParams({ instanceId: id, organizationId: orgId, mode: "view" }).toString() : "";
        const dt = F(r, "dateValue");
        const status = F(r, "statusText") || "";
        return [
          href ? `<a href="${esc(href)}">${esc(F(r, "refText") || id)}</a>` : esc(F(r, "refText") || ""),
          esc(F(r, "title") || ""),
          esc(F(r, "ownerName") || "Unassigned"),
          `<span class="pm-dx-pill tone-${esc(IMPL_TONE[status] || "muted")}">${esc(status)}</span>`,
          dt ? esc(window.gracFormatDateOnly ? window.gracFormatDateOnly(dt) : String(dt).slice(0, 10)) : "&mdash;"
        ];
      });
      const total = v("instances.criticalopen");
      watch = D.table({ id: "mdWatch", title: "Critical instances not implemented", scope: instScope,
        meta: total > rows.length ? `Showing ${rows.length} of ${D.fmt(total)}` : `${D.fmt(total)}`,
        columns: [{ label: "Instance" }, { label: "Title" }, { label: "Owner" }, { label: "Status" }, { label: "Last updated" }],
        rows, emptyText: "No critical practice instance is waiting for implementation." });
    }

    const lead = att.length ? charts.slice(0, 2) : [];
    const rest = charts.slice(lead.length);
    const errorHtml = errorBlock(errors);
    if (!kpis.length && !att.length && !coverage && !charts.length && !watch)
      return errorHtml || `<div class="pm-dx-empty">Nothing to show for this organization.</div>`;
    return `<div class="pm-dx">${errorHtml}`
      + (kpis.length ? `<div class="pm-dx-kpis">${kpis.join("")}</div>` : "")
      // 2026-11-10: framework coverage on its own full-width row (the
      // per-release table was cramped beside Needs attention).
      + coverage
      // Then Needs attention | the first two distributions, so the tall
      // attention list has no empty space beside it. The rest of the
      // distributions follow in a grid.
      + (att.length ? `<div class="pm-dx-row-2${lead.length ? "" : " single"}"><div class="pm-dx-col">${D.attention(att)}</div>`
          + (lead.length ? `<div class="pm-dx-col"><div class="pm-dx-grid pm-dx-grid-2">${lead.join("")}</div></div>` : "") + `</div>` : "")
      + (rest.length ? `<div class="pm-dx-grid">${rest.join("")}</div>` : "")
      + watch + `</div>`;
  }

  // ---- Shared v2 helpers (503 / 504) -------------------------------------
  // KPI values the caller may see (ALLOWED sections) from one dashboard
  // response: has(key) = the server returned it, v(key) = its value.
  function kpiValues(d) {
    const kv = {};
    (d ? F(d, "kpis") || [] : []).forEach(k => {
      if (ALLOWED.has(F(k, "sectionKey"))) kv[`${F(k, "sectionKey")}.${F(k, "kpiKey")}`] = Number(F(k, "value")) || 0;
    });
    return { has: k => Object.prototype.hasOwnProperty.call(kv, k), v: k => kv[k] || 0 };
  }

  // One distribution group, as chart items, each a link where the 414 drill
  // map (DIST_DRILL) has a list filter for it.
  function distItems(d, group, toneOf) {
    const [section, filterOf] = DIST_DRILL[group] || [];
    if (!ALLOWED.has(sectionOf(group))) return null;
    return (d ? F(d, "distributions") || [] : []).filter(x => F(x, "groupKey") === group).map(x => {
      const key = F(x, "itemKey"), label = F(x, "itemLabel");
      return {
        label, count: Number(F(x, "itemCount")) || 0, tone: toneOf ? toneOf(label, key) : "info",
        colour: F(x, "colourHex"),   // 506: a master's own colour (e.g. observation severity) wins
        href: key !== null && section && TARGET[section] ? TARGET[section](filterOf(key), `${F(x, "groupTitle")}: ${label}`) : null
      };
    });
  }

  // A KPI tile's 414 drill (KPI_DRILL), or null when its list cannot filter to it.
  function kpiHref(section, key, label) {
    const f = KPI_DRILL[`${section}.${key}`];
    return f && TARGET[section] ? TARGET[section](f, label) : null;
  }

  function setContext(scope, scopeTitle) {
    const ctx = document.getElementById("mdContext");
    if (!ctx) return;
    const org = document.getElementById("mdOrganization");
    const orgName = org && org.selectedIndex >= 0 ? org.options[org.selectedIndex].text : "";
    ctx.innerHTML = [orgName && `<span><i class="fa-regular fa-building" aria-hidden="true"></i> ${esc(orgName)}</span>`,
      scope && `<span${scopeTitle ? ` title="${esc(scopeTitle)}"` : ""}><i class="fa-regular fa-user" aria-hidden="true"></i> ${esc(scope)}</span>`,
      `<span><i class="fa-regular fa-clock" aria-hidden="true"></i> Refreshed ${esc(new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }))}</span>`]
      .filter(Boolean).join("");
  }

  function errorBlock(errors) {
    return errors.length
      ? `<div class="pm-dx-errors">${errors.join("")}<button type="button" class="pm-button" data-md-retry>Retry</button></div>` : "";
  }

  const SEV_TONE = { "Critical": "critical", "High": "warning", "Medium": "info", "Low": "neutral" };
  const sevTone = label => SEV_TONE[label] || "faint";
  const EXC_TONE = { "Approved": "success", "Submitted for approval": "warning", "Pending": "info", "Rejected": "danger" };
  // Whole days from a due date to today (UTC dates); null when unparseable.
  const daysPast = date => {
    const m = /^(\d{4})-(\d{1,2})-(\d{1,2})/.exec(String(date || ""));
    if (!m) return null;
    const due = Date.UTC(+m[1], +m[2] - 1, +m[3]);
    const now = new Date();
    const today = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
    return Math.max(0, Math.round((today - due) / 86400000));
  };

  // ---- Issues & Actions (504 -- Dashboard UI specification v2, section 7) --
  // One source: sp_dashboard_issues_actions (414 + 504). Gap Register, Task
  // Board and Exceptions & Waivers stay authoritative; every count here is
  // the definition their list filters by (414), and every link opens that
  // list with the same filter. An approved waiver is not a closed issue:
  // issues keep their own status (spec 7.5).
  async function loadIssuesActions(body) {
    body.innerHTML = D.skeleton();
    const dash = await settle(fetchDashboard());
    body.innerHTML = renderIssuesActions(dash);
    body.querySelectorAll(".pm-dx-row-2").forEach(D.balance);
    body.querySelectorAll("[data-md-retry]").forEach(b => b.addEventListener("click", load));
    setContext("");
  }

  function renderIssuesActions(dash) {
    const d = dash.ok ? dash.value : null;
    if (!d) return errorBlock([D.errorCard({ title: "Could not load Issues & Actions", message: dash.error && dash.error.message })]);
    const { has, v } = kpiValues(d);

    // ---- C. Executive KPIs ---------------------------------------------
    const kpis = [];
    if (has("gaps.open")) kpis.push(D.kpiCard({
      label: "Open issues", value: v("gaps.open"), href: kpiHref("gaps", "open", "Open issues"),
      qualifier: `${D.fmt(v("gaps.pending"))} pending analysis &middot; ${D.fmt(v("gaps.completed"))} closed`,
      title: "Gap Register issues not Closed, Cancelled or in a terminal lifecycle state." }));
    if (has("gaps.overdue")) {
      const p = D.pct(v("gaps.overdue"), v("gaps.open"));
      kpis.push(D.kpiCard({
        label: "Overdue issues", value: v("gaps.overdue"), href: kpiHref("gaps", "overdue", "Overdue issues"),
        qualifier: p === null ? "No open issues" : `${p}% of open issues`, meter: p, meterTone: "danger",
        title: "Open issues whose due date (or target resolution date) has passed. Bar: overdue / open issues." }));
    }
    if (has("tasks.open")) kpis.push(D.kpiCard({
      label: "Open tasks", value: v("tasks.open"), href: kpiHref("tasks", "open", "Open tasks"),
      qualifier: (has("tasks.duesoon") ? `${D.fmt(v("tasks.duesoon"))} due soon &middot; ` : "") + `${D.fmt(v("tasks.pending"))} pending review`,
      title: "Top-level Task Board tasks in a non-terminal status." }));
    if (has("tasks.overdue")) {
      const p = D.pct(v("tasks.overdue"), v("tasks.open"));
      kpis.push(D.kpiCard({
        label: "Overdue tasks", value: v("tasks.overdue"), href: kpiHref("tasks", "overdue", "Overdue tasks"),
        qualifier: p === null ? "No open tasks" : `${p}% of open tasks`, meter: p, meterTone: "danger",
        title: "Open tasks past their SLA due date. Bar: overdue / open tasks." }));
    }
    if (has("exceptions.pending")) kpis.push(D.kpiCard({
      label: "Exceptions awaiting approval", value: v("exceptions.pending"), href: kpiHref("exceptions", "pending", "Exceptions awaiting approval"),
      qualifier: `${D.fmt(v("exceptions.open"))} open requests`,
      title: "Exception requests in status Submitted for approval." }));
    if (has("exceptions.approved")) kpis.push(D.kpiCard({
      label: "Approved waivers", value: v("exceptions.approved"), href: kpiHref("exceptions", "approved", "Approved waivers"),
      qualifier: (has("exceptions.expiring") ? `${D.fmt(v("exceptions.expiring"))} ending in 30 days &middot; ` : "") + `${D.fmt(v("exceptions.lapsed"))} lapsed`,
      title: "Exception requests in status Approved, including those past their effective-until date (lapsed)." }));

    // ---- D. Needs attention -----------------------------------------------
    const att = [];
    const add = (key, title, severity, detail, link) => {
      if (has(key)) att.push({ title, severity, count: v(key), detail, href: link === false ? null : kpiHref(key.split(".")[0], key.split(".")[1], title) });
    };
    add("gaps.overdue", "Overdue issues", "High", "Open issues past their due date.");
    add("tasks.overdue", "Overdue tasks", "High", "Open tasks past their SLA due date.");
    add("gaps.highsev", "Critical or high severity issues", "High", "Open issues with severity Critical or High; see Open issues by severity.", false);
    add("exceptions.lapsed", "Lapsed waivers", "High", "Approved waivers past their effective-until date.");
    add("gaps.noowner", "Issues without an owner", "Medium", "Open issues with no owner.");
    add("tasks.noowner", "Tasks without an owner", "Medium", "Open tasks not assigned to anyone.");
    add("tasks.pending", "Tasks pending review", "Medium", "Tasks waiting for review or validation.");
    add("exceptions.pending", "Exceptions awaiting approval", "Medium", "Requests submitted and waiting for a decision.");
    add("exceptions.expiring", "Waivers ending in 30 days", "Medium", "Approved waivers whose effective-until date is within 30 days.", false);
    add("tasks.duesoon", "Tasks due soon", "Medium", "Open tasks the SLA monitor marks Due today or Due soon.", false);
    add("exceptions.noowner", "Exception requests without an owner", "Medium", "Open requests with no owner.");

    // ---- E1. Ageing (separate series) -------------------------------------
    const SERIES = [{ key: "gaps", label: "Issues", tone: "info3" }, { key: "tasks", label: "Tasks", tone: "info" },
                    { key: "exceptions", label: "Exception requests", tone: "info2" }].filter(s => ALLOWED.has(s.key));
    const bandMap = new Map();
    (F(d, "ageing") || []).forEach(b => {
      const g = F(b, "groupKey");
      if (!SERIES.some(s => s.key === g)) return;
      const code = F(b, "bandCode");
      if (!bandMap.has(code)) bandMap.set(code, { label: F(b, "bandName"), sort: Number(F(b, "sortOrder")) || 0, values: {} });
      const max = F(b, "maxDays");
      bandMap.get(code).values[g] = {
        count: Number(F(b, "itemCount")) || 0,
        href: TARGET[g] && AGEING_DRILL[g]
          ? TARGET[g]({ ...AGEING_DRILL[g], minAge: F(b, "minDays"), maxAge: max >= 100000 ? null : max }, `${F(b, "groupTitle")} aged ${F(b, "bandName")}`) : null
      };
    });
    const ageHtml = SERIES.length && bandMap.size
      ? D.ageing({ title: "Ageing of open items", meta: "days since raised", series: SERIES,
                   bands: [...bandMap.values()].sort((a, b) => a.sort - b.sort) })
      : "";

    // ---- E2. Distributions --------------------------------------------------
    const chart = (group, title, mode, toneOf, totalLabel, empty) => {
      const items = distItems(d, group, toneOf);
      return items ? D.distCard({ title, mode, items, totalLabel, emptyText: empty }) : "";
    };
    const lead = [
      chart("gaps_severity", "Open issues by severity", "stack", sevTone, "open issues", "No open issues."),
      chart("tasks_priority", "Open tasks by priority", "stack", sevTone, "open tasks", "No open tasks.")
    ].filter(Boolean);
    const rest = [
      chart("gaps_status", "Issues by status", "bars", null, "issues", "No issues yet."),
      chart("gaps_source", "Open issues by source", "bars", null, "open issues", "No open issues."),
      chart("tasks_status", "Tasks by status", "bars", null, "tasks", "No tasks yet."),
      chart("exceptions_status", "Exception requests by status", "stack", l => EXC_TONE[l] || "neutral", "requests", "No exception requests yet."),
      chart("exceptions_type", "Exception requests by type", "bars", null, "requests", "No exception requests yet.")
    ].filter(Boolean);

    // ---- F. Watchlists ------------------------------------------------------
    const watches = [
      watchTable(d, has, v, { listKey: "gaps_overdue", title: "Overdue issues", kpiKey: "gaps.overdue", empty: "No issue is past its due date." }),
      watchTable(d, has, v, { listKey: "tasks_overdue", title: "Overdue tasks", kpiKey: "tasks.overdue", empty: "No task is past its SLA due date." })
    ].filter(Boolean);

    if (!kpis.length && !att.length && !ageHtml && !lead.length && !rest.length && !watches.length)
      return `<div class="pm-dx-empty">Nothing to show for this organization.</div>`;
    const right = ageHtml || lead.length
      ? `<div class="pm-dx-col">${ageHtml}${lead.length ? `<div class="pm-dx-grid pm-dx-grid-2">${lead.join("")}</div>` : ""}</div>` : "";
    return `<div class="pm-dx">`
      + (kpis.length ? `<div class="pm-dx-kpis">${kpis.join("")}</div>` : "")
      + (att.length || right ? `<div class="pm-dx-row-2${att.length && right ? "" : " single"}">${att.length ? `<div class="pm-dx-col">${D.attention(att)}</div>` : ""}${right}</div>` : "")
      + (rest.length ? `<div class="pm-dx-grid">${rest.join("")}</div>` : "")
      + (watches.length ? `<div class="pm-dx-grid pm-dx-grid-watch">${watches.join("")}</div>` : "")
      + `</div>`;
  }

  // One overdue / upcoming list as a watchlist table (504; shared by 506).
  // o = { listKey, title, kpiKey (its total), empty, statusLabel?, dateLabel?,
  //       late (true: add an "Overdue by" column), statusFormat? (text -> text) }. Rows link through
  // listRowHref; "View all" opens the list on the KPI's 414 drill.
  function watchTable(d, has, v, o) {
    if (!ALLOWED.has(sectionOf(o.listKey)) || !has(o.kpiKey)) return "";
    const late = o.late !== false;
    const rows = (F(d, "lists") || []).filter(l => F(l, "listKey") === o.listKey).map(r => {
      const href = listRowHref(o.listKey, r);
      const ref = esc(F(r, "refText") || "");
      const due = F(r, "dateValue");
      const n = daysPast(due);
      const cells = [
        ...(o.hideRef ? [] : [href ? `<a href="${esc(href)}"${listRowNav(o.listKey, r)}>${ref}</a>` : ref]),
        esc(F(r, "title") || ""),
        ...(o.hideOwner ? [] : [esc(F(r, "ownerName") || "Unassigned")]),
        ...(o.hideStatus ? [] : [esc(o.statusFormat ? o.statusFormat(F(r, "statusText") || "") : (F(r, "statusText") || ""))]),
        due ? esc(window.gracFormatDateOnly ? window.gracFormatDateOnly(due) : String(due).slice(0, 10)) : "&mdash;"
      ];
      if (late) cells.push(n === null ? "&mdash;" : `<span class="pm-dx-pill tone-danger">${n} day${n === 1 ? "" : "s"}</span>`);
      return cells;
    });
    // 509: total -- a list that spans more than its KPI (unsupported + unknown).
    const total = o.total !== undefined ? o.total : v(o.kpiKey);
    const [section, key] = o.kpiKey.split(".");
    const all = total > 0 ? kpiHref(section, key, o.title) : null;
    // 508: hideRef / hideOwner -- a list whose rows have no reference or
    // owner (acknowledgement batches) drops the column instead of blanks.
    // 509: hideStatus -- a list whose status is the list itself ("Overdue").
    const columns = [...(o.hideRef ? [] : [{ label: "Reference" }]), { label: o.titleLabel || "Title" },
      ...(o.hideOwner ? [] : [{ label: "Owner" }]), ...(o.hideStatus ? [] : [{ label: o.statusLabel || "Status" }]), { label: o.dateLabel || "Due" }];
    if (late) columns.push({ label: "Overdue by", cls: "num" });
    return D.table({ title: o.title, meta: total > rows.length ? `${late ? "Oldest" : "First"} ${rows.length} of ${D.fmt(total)}` : D.fmt(total),
      columns, rows, emptyText: o.empty,
      footer: (all ? `<p class="pm-dx-note"><a href="${esc(all)}">View all ${esc(o.title.toLowerCase())}</a></p>` : "") + (o.footer || "") });
  }

  // ---- Audit Assurance (506 -- Dashboard UI specification v2, section 9) --
  // One source: sp_dashboard_audit_assurance (414 + 506). Executions,
  // Observations and Audit Plans stay authoritative; counts use the
  // execution / observation state views (414) the lists filter by, and
  // every link opens that list on the same drill. A resolved finding is
  // not closed: it shows as awaiting closure until validated (spec 9.7).
  async function loadAuditAssurance(body) {
    body.innerHTML = D.skeleton();
    const dash = await settle(fetchDashboard());
    body.innerHTML = renderAuditAssurance(dash);
    body.querySelectorAll(".pm-dx-row-2").forEach(D.balance);
    body.querySelectorAll("[data-md-retry]").forEach(b => b.addEventListener("click", load));
    setContext("");
  }

  function renderAuditAssurance(dash) {
    const d = dash.ok ? dash.value : null;
    if (!d) return errorBlock([D.errorCard({ title: "Could not load Audit Assurance", message: dash.error && dash.error.message })]);
    const { has, v } = kpiValues(d);

    // ---- C. Executive KPIs ---------------------------------------------
    const kpis = [];
    if (has("audits.inprogress")) kpis.push(D.kpiCard({
      label: "Audits in progress", value: v("audits.inprogress"), href: kpiHref("audits", "inprogress", "Audits in progress"),
      qualifier: `${D.fmt(v("audits.planned"))} planned &middot; ${D.fmt(v("audits.upcoming"))} starting in 30 days`,
      title: "Audit executions started and not yet closed or cancelled." }));
    if (has("audits.entitiestotal")) {
      const total = v("audits.entitiestotal"), done = v("audits.entitiesdone");
      const p = D.pct(done, total);
      kpis.push(D.kpiCard({
        label: "Fieldwork progress", value: p === null ? 0 : p, suffix: p === null ? "" : "%",
        qualifier: p === null ? "No entities in scope of in-progress audits" : `${D.fmt(done)} of ${D.fmt(total)} entities completed`,
        meter: p, meterTone: "success",
        title: "In-progress audits: entities completed / entities in scope (the executions' own counters)." }));
    }
    if (has("audits.overdue")) kpis.push(D.kpiCard({
      label: "Overdue audits", value: v("audits.overdue"), href: kpiHref("audits", "overdue", "Overdue audits"),
      qualifier: `${D.fmt(v("audits.completed"))} completed`,
      title: "Audits past their planned end date and not closed or cancelled." }));
    if (has("findings.pending")) kpis.push(D.kpiCard({
      label: "Open findings", value: v("findings.pending"), href: kpiHref("findings", "pending", "Open findings"),
      qualifier: (has("findings.highsev") ? `${D.fmt(v("findings.highsev"))} critical or high &middot; ` : "")
        + (has("findings.linkedgap") ? `${D.fmt(v("findings.linkedgap"))} linked to an issue` : `${D.fmt(v("findings.total"))} in total`),
      title: "Observations not yet resolved, rejected or closed." }));
    if (has("findings.overdue")) {
      const p = D.pct(v("findings.overdue"), v("findings.pending"));
      kpis.push(D.kpiCard({
        label: "Overdue findings", value: v("findings.overdue"), href: kpiHref("findings", "overdue", "Overdue findings"),
        qualifier: p === null ? "No open findings" : `${p}% of open findings`, meter: p, meterTone: "danger",
        title: "Open findings past their remediation due date. Bar: overdue / open findings." }));
    }
    if (has("findings.awaiting")) kpis.push(D.kpiCard({
      label: "Resolved, awaiting closure", value: v("findings.awaiting"), href: kpiHref("findings", "awaiting", "Findings resolved, awaiting closure"),
      qualifier: `${D.fmt(v("findings.closed"))} closed`,
      title: "Findings marked Resolved; validation and closure are not complete, so they are not counted as closed." }));

    // ---- D. Needs attention -----------------------------------------------
    const att = [];
    const add = (key, title, severity, detail, link) => {
      if (has(key)) att.push({ title, severity, count: v(key), detail,
        href: link === false ? null : kpiHref(key.split(".")[0], key.split(".")[1], title) });
    };
    add("audits.overdue", "Overdue audits", "High", "Past the planned end date, not closed.");
    add("findings.overdue", "Overdue findings", "High", "Open findings past their remediation due date.");
    add("findings.highsev", "Critical or high findings open", "High", "Severity Critical or High, not yet resolved; see Open findings by severity.", false);
    add("findings.noowner", "Findings without an owner", "High", "Open findings with no assigned owner.");
    add("findings.awaiting", "Resolved, awaiting closure", "Medium", "Remediation done; validation and closure pending.");
    add("findings.noduedate", "Findings without a due date", "Medium", "Open findings with no remediation due date.", false);
    add("audits.triggeredopen", "Event-driven audits open", "Medium", "Audits raised by a trigger, not yet closed.", false);
    add("audits.upcoming", "Audits starting in 30 days", "Info", "Planned audits due to start soon.");

    // ---- E. Charts ------------------------------------------------------------
    const chart = (group, title, mode, toneOf, totalLabel, empty) => {
      const items = distItems(d, group, toneOf);
      return items ? D.distCard({ title, mode, items, totalLabel, emptyText: empty }) : "";
    };
    let ageHtml = "";
    if (ALLOWED.has("findings")) {
      const bands = (F(d, "ageing") || []).filter(b => F(b, "groupKey") === "findings");
      if (bands.length) ageHtml = D.distCard({ title: "Open findings ageing", totalLabel: "open findings", mode: "bars",
        items: bands.map(b => {
          const max = F(b, "maxDays");
          return { label: F(b, "bandName"), count: Number(F(b, "itemCount")) || 0, tone: "info",
            href: TARGET.findings({ ...AGEING_DRILL.findings, minAge: F(b, "minDays"), maxAge: max >= 100000 ? null : max },
                                  `Open findings aged ${F(b, "bandName")}`) };
        }),
        footer: `<p class="pm-dx-note">Days since the finding was observed.</p>`, emptyText: "No open findings." });
    }
    const lead = [
      chart("findings_severity", "Open findings by severity", "stack", l => SEV_TONE[l] || "neutral", "open findings", "No open findings."),
      chart("audits_status", "Audits by status", "bars", null, "audits", "No audits yet.")
    ].filter(Boolean);
    const rest = [
      chart("findings_status", "Findings by status", "bars", null, "findings", "No findings yet."),
      chart("findings_type", "Open findings by type", "stack", l => ({ "Finding": "info3", "Risk": "warning", "Improvement": "info", "Best practice": "info2" })[l] || "neutral", "open findings", "No open findings."),
      chart("audits_origin", "Audits by origin", "stack", l => ({ "Audit plan": "info", "Manual": "info2", "Event-driven (trigger)": "info3" })[l] || "neutral", "audits", "No audits yet."),
      chart("plans_status", "Audit plans by status", "bars", null, "plans", "No audit plans yet.")
    ].filter(Boolean);

    // ---- F. Watchlists ----------------------------------------------------------
    const watches = [
      watchTable(d, has, v, { listKey: "audits_overdue", title: "Overdue audits", kpiKey: "audits.overdue", empty: "No audit is past its planned end date.", dateLabel: "Planned end" }),
      watchTable(d, has, v, { listKey: "findings_overdue", title: "Overdue findings", kpiKey: "findings.overdue", empty: "No finding is past its due date.", statusLabel: "Severity" })
    ].filter(Boolean);
    const upcoming = watchTable(d, has, v, { listKey: "audits_upcoming", title: "Audits starting in the next 30 days", kpiKey: "audits.upcoming",
      empty: "No audit starts in the next 30 days.", dateLabel: "Planned start", late: false });

    if (!kpis.length && !att.length && !ageHtml && !lead.length && !rest.length && !watches.length && !upcoming)
      return `<div class="pm-dx-empty">Nothing to show for this organization.</div>`;
    const right = ageHtml || lead.length
      ? `<div class="pm-dx-col">${ageHtml}${lead.length ? `<div class="pm-dx-grid pm-dx-grid-2">${lead.join("")}</div>` : ""}</div>` : "";
    return `<div class="pm-dx">`
      + (kpis.length ? `<div class="pm-dx-kpis">${kpis.join("")}</div>` : "")
      + (att.length || right ? `<div class="pm-dx-row-2${att.length && right ? "" : " single"}">${att.length ? `<div class="pm-dx-col">${D.attention(att)}</div>` : ""}${right}</div>` : "")
      + (rest.length ? `<div class="pm-dx-grid">${rest.join("")}</div>` : "")
      // Watchlists: overdue audits + upcoming audits | overdue findings, two
      // even columns balanced like row 2 (a short list beside a long one
      // left a blank card).
      + (watches.length || upcoming
          ? `<div class="pm-dx-row-2 pm-dx-row-even"><div class="pm-dx-col">${watches[0] || ""}${upcoming}</div>`
            + `<div class="pm-dx-col">${watches.slice(1).join("")}</div></div>` : "")
      + `</div>`;
  }

  // ---- Third-Party Risk (507 -- Dashboard UI specification v2, section 10) --
  // One source: sp_dashboard_tprm (490 + 507; 525: the CR 2 views --
  // applicability funnel, admissions, TP Risk Register). Third Parties, Engagements
  // and Reviews stay authoritative; every figure is 490's definition (the
  // one the Engagements / Reviews filters use) and every link opens that
  // list with its own filter (stage / band / criticality / attention /
  // review status). Sections without a list filter are not links.
  const TPRM_STAGE_GROUP = {   // spec 10.2 lifecycle stages
    SCOPING: "Scope & risk", RISK_ASSESSED: "Scope & risk", DUE_DILIGENCE: "Due diligence",
    PENDING_DECISION: "Decision", APPROVED: "Onboarding", ONBOARDING: "Onboarding",
    ACTIVE: "Operation", SUSPENDED: "Operation", EXITING: "Operation"
  };

  async function loadTprm(body) {
    body.innerHTML = D.skeleton();
    const dash = await settle(fetchDashboard());
    body.innerHTML = renderTprm(dash);
    body.querySelectorAll(".pm-dx-row-2").forEach(D.balance);
    body.querySelectorAll("[data-md-retry]").forEach(b => b.addEventListener("click", load));
    setContext("");
  }

  function renderTprm(dash) {
    const d = dash.ok ? dash.value : null;
    if (!d) return dash.error && dash.error.notConfigured
      ? `<div class="pm-dx-empty">${esc(dash.error.message)}</div>`
      : errorBlock([D.errorCard({ title: "Could not load Third-Party Management", message: dash.error && dash.error.message })]);
    const { has, v } = kpiValues(d);

    // ---- C. Executive KPIs ---------------------------------------------
    const kpis = [];
    if (has("tprmthirdparties.total")) kpis.push(D.kpiCard({
      // 521: the register is the Vendor Registry (label only; the section
      // keys stay tprmthirdparties until the Phase 6 dashboard rework).
      label: "Vendors", value: v("tprmthirdparties.total"), href: kpiHref("tprmthirdparties", "total", "Vendors"),
      qualifier: `${D.fmt(v("tprmthirdparties.withactive"))} with an active engagement`,
      title: "Vendor Registry records (not archived) in this organisation." }));
    if (has("tprmengagements.open")) kpis.push(D.kpiCard({
      label: "Open engagements", value: v("tprmengagements.open"), href: kpiHref("tprmengagements", "open", "Open engagements"),
      qualifier: `${D.fmt(v("tprmengagements.inassessment"))} in assessment &middot; ${D.fmt(v("tprmengagements.active"))} active`,
      title: "Engagements from scoping to exiting (not exited, rejected or cancelled)." }));
    // 525 (CR 2 6-7): the screening -> applicability -> admission funnel
    if (has("tprmengagements.undecided")) kpis.push(D.kpiCard({
      label: "Awaiting TPRM decision", value: v("tprmengagements.undecided"),
      href: kpiHref("tprmengagements", "undecided", "Engagements awaiting the TPRM applicability decision"),
      qualifier: `${D.fmt(v("tprmengagements.potentialcase"))} potential TPRM cases &middot; ${D.fmt(v("tprmengagements.admissionpending"))} admissions pending`,
      title: "Open engagements not yet admitted or excluded: not screened, screened, deferred or admission rejected." }));
    // 525 (CR 2 8): the TP Risk Register
    if (has("tprmregister.total")) kpis.push(D.kpiCard({
      label: "TP Risk Register", value: v("tprmregister.total"), href: kpiHref("tprmregister", "total", "TP Risk Register"),
      qualifier: `${D.fmt(v("tprmregister.high"))} high or critical overall &middot; ${D.fmt(v("tprmregister.impactopen"))} impact reviews open`,
      title: "Vendors admitted to formal TPRM (open or exiting records). Overall vendor risk: the highest of the vendor profile ratings and the engagements' risk." }));
    if (has("tprmengagements.highrisk")) kpis.push(D.kpiCard({
      label: "High or critical active", value: v("tprmengagements.highrisk"),
      qualifier: "Residual band, else inherent",
      title: "Active or suspended engagements whose residual (else inherent) risk band ranks high or critical in the risk model." }));
    if (has("tprmdiligence.overdue")) kpis.push(D.kpiCard({
      label: "Due diligence overdue", value: v("tprmdiligence.overdue"),
      qualifier: `${D.fmt(v("tprmdiligence.inprogress"))} rounds in progress`,
      title: "Due-diligence rounds in progress past their due date." }));
    if (has("tprmengagements.pendingdecision")) kpis.push(D.kpiCard({
      label: "Decisions pending", value: v("tprmengagements.pendingdecision"), href: kpiHref("tprmengagements", "pendingdecision", "Engagements pending decision"),
      qualifier: "Awaiting the risk decision / approval",
      title: "Engagements in stage Pending decision." }));
    if (has("tprmreviews.overdue")) kpis.push(D.kpiCard({
      label: "Reviews overdue", value: v("tprmreviews.overdue"), href: kpiHref("tprmreviews", "overdue", "Overdue reviews"),
      qualifier: `${D.fmt(v("tprmreviews.due30"))} due in 30 days`,
      title: "Open periodic or triggered reviews past their due date." }));

    // ---- D. Needs attention -----------------------------------------------
    const att = [];
    const add = (key, title, severity, detail) => {
      if (has(key)) att.push({ title, severity, count: v(key), detail, href: kpiHref(key.split(".")[0], key.split(".")[1], title) });
    };
    add("tprmdiligence.overdue", "Due diligence overdue", "High", "Rounds in progress past their due date.");
    add("tprmreviews.overdue", "Reviews overdue", "High", "Open reviews past their due date.");
    add("tprmfindings.overdue", "Overdue remediation", "High", "Open findings past their remediation due date.");
    add("tprmfindings.high", "High or critical findings open", "High", "Open findings ranked high or critical; see Open findings by severity.");
    add("tprmengagements.reassess", "Reassessment required", "High", "Open engagements flagged for reassessment.");
    // 525 (CR 2 6-8)
    add("tprmengagements.potentialcase", "Potential TPRM cases awaiting a decision", "High", "Screened as a potential TPRM case; the applicability decision is not recorded yet.");
    add("tprmregister.reviewoverdue", "Vendor profile reviews overdue", "High", "TP Risk Register records whose periodic vendor profile review is past due.");
    add("tprmengagements.admissionpending", "Admission approvals pending", "Medium", "Included engagements waiting for the TPRM admission approval.");
    add("tprmengagements.inforequired", "Further information required", "Medium", "Screening found information gaps; the engagement is screened or deferred.");
    add("tprmregister.impactopen", "Impact reviews open", "Medium", "A further engagement of an admitted vendor: review its effect on the vendor profile.");
    add("tprmregister.notrated", "Vendor profile not fully rated", "Medium", "Register records with a profile area not rated yet.");
    add("tprmregister.exiting", "Register records in exit", "Medium", "No admitted engagement remains: complete the exit and close the record.");
    add("tprmengagements.pendingdecision", "Decisions pending", "Medium", "Engagements waiting for the risk decision.");
    add("tprmdiligence.evidencepending", "Evidence awaiting review", "Medium", "Linked evidence not yet reviewed.");
    add("tprmacceptance.acceptexpiring", "Risk acceptance ending in 60 days", "Medium", "Live engagements whose accepted risk ends soon.");
    add("tprmacceptance.contractexpiring", "Engagements ending in 90 days", "Medium", "Active engagements whose end date is near.");
    add("tprmacceptance.certexpiring", "Accepted evidence expiring in 60 days", "Medium", "Certifications / evidence of active engagements expiring.");
    add("tprmfindings.conditions", "Open approval conditions", "Medium", "Conditions attached to approvals, not yet met.");

    // ---- E. Charts ------------------------------------------------------------
    const chart = (group, title, mode, toneOf, totalLabel, empty) => {
      const items = distItems(d, group, toneOf);
      return items ? D.distCard({ title, mode, items, totalLabel, emptyText: empty }) : "";
    };
    // Lifecycle (spec 10.2): open engagements per stage, in stage order, the
    // stage group shown with each bar. Each bar opens Engagements on that stage.
    const stageItems = distItems(d, "tprmengagements_stage", () => "info");
    // The five lifecycle groups, summed from the stage rows, as one line.
    const groupN = {};
    (F(d, "distributions") || []).filter(x => F(x, "groupKey") === "tprmengagements_stage").forEach(x => {
      const g = TPRM_STAGE_GROUP[F(x, "itemKey")];
      if (g) groupN[g] = (groupN[g] || 0) + (Number(F(x, "itemCount")) || 0);
    });
    const groups = ["Scope & risk", "Due diligence", "Decision", "Onboarding", "Operation"]
      .map(g => `${esc(g)} <strong>${D.fmt(groupN[g] || 0)}</strong>`).join(" &rarr; ");
    const lifecycle = stageItems ? D.distCard({ title: "Engagement lifecycle", mode: "bars", totalLabel: "open engagements",
      items: stageItems,
      footer: `<p class="pm-dx-note">${groups}</p>`,
      emptyText: "No open engagements." }) : "";
    const lead = [
      // 525 (CR 2 6-8)
      chart("tprmengagements_applicability", "Open engagements by TPRM applicability", "stack", null, "open engagements", "No open engagements."),
      chart("tprmregister_overall", "TP Risk Register by overall vendor risk", "stack", null, "register records", "No vendor on the register."),
      chart("tprmengagements_band", "Open engagements by risk band", "stack", null, "open engagements", "No open engagements."),
      chart("tprmengagements_criticality", "Open engagements by criticality", "stack", null, "open engagements", "No open engagements.")
    ].filter(Boolean);
    const SERIES = [{ key: "tprmfindings", label: "Open findings", tone: "info3" }, { key: "tprmengagements", label: "Pending decisions", tone: "info2" },
                    { key: "tprmadmissions", section: "tprmengagements", label: "Pending admissions", tone: "info" }]   // 525
      .filter(s => ALLOWED.has(s.section || s.key));
    const bandMap = new Map();
    (F(d, "ageing") || []).forEach(b => {
      const g = F(b, "groupKey");
      if (!SERIES.some(s => s.key === g)) return;
      const code = F(b, "bandCode");
      if (!bandMap.has(code)) bandMap.set(code, { label: F(b, "bandName"), sort: Number(F(b, "sortOrder")) || 0, values: {} });
      bandMap.get(code).values[g] = { count: Number(F(b, "itemCount")) || 0 };
    });
    const rest = [
      chart("tprmfindings_severity", "Open findings by severity", "stack", null, "open findings", "No open findings."),
      chart("tprmreviews_type", "Open reviews by type", "bars", null, "open reviews", "No open reviews."),
      SERIES.length && bandMap.size ? D.ageing({ title: "Ageing", meta: "findings since recorded, decisions and admissions since submitted", series: SERIES,
        bands: [...bandMap.values()].sort((a, b) => a.sort - b.sort) }) : ""
    ].filter(Boolean);

    // ---- F. Watchlists (balanced two columns) ---------------------------------
    const left = [
      watchTable(d, has, v, { listKey: "tprmengagements_highrisk", title: "High-risk engagements", kpiKey: "tprmengagements.highrisk",
        empty: "No active engagement is in a high or critical band.", statusLabel: "Risk band", dateLabel: "Next review", late: false }),
      watchTable(d, has, v, { listKey: "tprmengagements_decisions", title: "Pending decisions", kpiKey: "tprmengagements.pendingdecision",
        empty: "No decision is pending.", statusLabel: "Risk band", dateLabel: "Submitted", late: false }),
      // 525 (CR 2 7.1)
      watchTable(d, has, v, { listKey: "tprmengagements_admissions", title: "Admission approvals pending", kpiKey: "tprmengagements.admissionpending",
        empty: "No admission is waiting for approval.", statusLabel: "Screening", dateLabel: "Requested", late: false })
    ].filter(Boolean);
    const right = [
      watchTable(d, has, v, { listKey: "tprmreviews_overdue", title: "Overdue reviews", kpiKey: "tprmreviews.overdue",
        empty: "No review is past its due date.", statusLabel: "Trigger",
        // trigger_code is a code (PERIODIC, CERT_EXPIRY ...): shown as words.
        statusFormat: c => { const w = String(c).replace(/_/g, " ").toLowerCase(); return w.charAt(0).toUpperCase() + w.slice(1); } }),
      watchTable(d, has, v, { listKey: "tprmfindings_overdue", title: "Overdue remediation", kpiKey: "tprmfindings.overdue",
        empty: "No finding is past its remediation date.", statusLabel: "Severity" }),
      watchTable(d, has, v, { listKey: "tprmacceptance_expiring", title: "Risk acceptance ending in 60 days", kpiKey: "tprmacceptance.acceptexpiring",
        empty: "No accepted risk ends in the next 60 days.", statusLabel: "Risk band", dateLabel: "Accepted until", late: false }),
      // 525 (CR 2 8.4, open point 7)
      watchTable(d, has, v, { listKey: "tprmregister_attention", title: "TP Risk Register: needs attention", kpiKey: "tprmregister.attention",
        empty: "No impact review is open and no vendor profile review is due in 30 days.", statusLabel: "Needs",
        dateLabel: "Profile review due", late: false })
    ].filter(Boolean);

    if (!kpis.length && !att.length && !lifecycle && !lead.length && !rest.length && !left.length && !right.length)
      return `<div class="pm-dx-empty">Nothing to show for this organization.</div>`;
    const col2 = lifecycle || lead.length
      ? `<div class="pm-dx-col">${lifecycle}${lead.length ? `<div class="pm-dx-grid pm-dx-grid-2">${lead.join("")}</div>` : ""}</div>` : "";
    return `<div class="pm-dx">`
      + (kpis.length ? `<div class="pm-dx-kpis">${kpis.join("")}</div>` : "")
      + (att.length || col2 ? `<div class="pm-dx-row-2${att.length && col2 ? "" : " single"}">${att.length ? `<div class="pm-dx-col">${D.attention(att)}</div>` : ""}${col2}</div>` : "")
      + (rest.length ? `<div class="pm-dx-grid pm-dx-grid-3">${rest.join("")}</div>` : "")
      + (left.length || right.length
          ? `<div class="pm-dx-row-2 pm-dx-row-even"><div class="pm-dx-col">${left.join("")}</div><div class="pm-dx-col">${right.join("")}</div></div>` : "")
      + `</div>`;
  }

  // ---- Policies & Documents (508 -- Dashboard UI specification v2, section 11) --
  // One source: sp_dashboard_documents. Document Library, Document
  // Acknowledgements and Evidence Center stay authoritative; each figure is
  // the definition that page uses (record Active, stage / status codes,
  // batch Open, the Evidence Center visibility and validity rules) and a
  // link opens the page on its own filter (type / stage / status, validity /
  // used-in). Review dates, owners and acknowledgements are not list
  // filters, so those figures are not links. A document is in force only
  // when Published and Active; a Reviewed document is not approved.
  async function loadDocuments(body) {
    body.innerHTML = D.skeleton();
    const dash = await settle(fetchDashboard());
    body.innerHTML = renderDocuments(dash);
    body.querySelectorAll(".pm-dx-row-2").forEach(D.balance);
    body.querySelectorAll("[data-md-retry]").forEach(b => b.addEventListener("click", load));
    setContext("", "");
  }

  const DOC_STAGE_TONE = { "Draft": "neutral", "Reviewed": "warning", "Published": "success" };   // by stage_code
  const REVIEW_TONE = { "Overdue": "danger", "Due in 30 days": "warning", "Due in 31-60 days": "info",
                        "Due in 61-90 days": "info2", "Later": "success", "No review date": "faint" };
  const VALIDITY_TONE = { "Valid": "success", "Expiring in 30 days": "warning", "Expired": "danger", "No expiry": "neutral" };

  function renderDocuments(dash) {
    const d = dash.ok ? dash.value : null;
    if (!d) return dash.error && dash.error.notConfigured
      ? `<div class="pm-dx-empty">${esc(dash.error.message)}</div>`
      : errorBlock([D.errorCard({ title: "Could not load Policies & Documents", message: dash.error && dash.error.message })]);
    const { has, v } = kpiValues(d);

    // ---- C. Executive KPIs ---------------------------------------------
    const kpis = [];
    if (has("documents.current")) kpis.push(D.kpiCard({
      label: "Current documents", value: v("documents.current"), href: kpiHref("documents", "current", "Current documents"),
      qualifier: `${D.fmt(v("documents.published"))} published &middot; ${D.fmt(v("documents.retired"))} retired`,
      title: "Documents with status Active, any stage (Draft, Reviewed or Published)." }));
    if (has("documents.draft")) kpis.push(D.kpiCard({
      label: "Awaiting review", value: v("documents.draft"), href: kpiHref("documents", "draft", "Draft documents awaiting review"),
      qualifier: "Stage Draft",
      title: "Active documents in stage Draft -- with the reviewer." }));
    if (has("documents.pendingapproval")) kpis.push(D.kpiCard({
      label: "Awaiting approval", value: v("documents.pendingapproval"),
      href: kpiHref("documents", "pendingapproval", "Reviewed documents awaiting approval"),
      qualifier: "Reviewed, not yet approved",
      title: "Active documents in stage Reviewed. Reviewed is not approved: they are not in force until Published." }));
    if (has("documents.reviewoverdue")) {
      const p = D.pct(v("documents.reviewoverdue"), v("documents.published"));
      kpis.push(D.kpiCard({
        label: "Review overdue", value: v("documents.reviewoverdue"),
        qualifier: `${D.fmt(v("documents.review30"))} due in 30 days` + (p === null ? "" : ` &middot; ${p}% of published`),
        meter: p, meterTone: "danger",
        title: "Published documents whose next review date has passed. Bar: overdue / published." }));
    }
    if (has("acknowledgements.pending")) {
      const done = v("acknowledgements.acknowledged"), all = done + v("acknowledgements.pending");
      const p = D.pct(done, all);
      kpis.push(D.kpiCard({
        label: "Acknowledgement completion", value: p === null ? 0 : p, suffix: p === null ? "" : "%",
        qualifier: p === null ? "No open acknowledgement batch"
          : `${D.fmt(done)} of ${D.fmt(all)} &middot; ${D.fmt(v("acknowledgements.overdue"))} overdue`,
        meter: p, meterTone: "success",
        title: "Open batches: users who acknowledged / users asked to acknowledge." }));
    }
    if (has("docevidence.active")) kpis.push(D.kpiCard({
      label: "Evidence expiring", value: v("docevidence.expiring"), href: kpiHref("docevidence", "expiring", "Evidence expiring in 30 days"),
      qualifier: `${D.fmt(v("docevidence.expired"))} expired &middot; ${D.fmt(v("docevidence.active"))} active items`,
      title: "Active Evidence Center items you can see whose validity ends in the next 30 days." }));

    // ---- D. Needs attention -----------------------------------------------
    const att = [];
    const add = (key, title, severity, detail, link) => {
      if (has(key)) att.push({ title, severity, count: v(key), detail,
        href: link === false ? null : kpiHref(key.split(".")[0], key.split(".")[1], title) });
    };
    add("documents.reviewoverdue", "Document reviews overdue", "High", "Published documents past their next review date.", false);
    add("acknowledgements.overdue", "Acknowledgements overdue", "High", "Users who have not acknowledged and whose batch is past its due date.", false);
    add("docevidence.expired", "Evidence expired", "High", "Active evidence items past their valid-to date.");
    add("documents.noowner", "Published documents without an owner", "High", "No document owner recorded.", false);
    add("documents.pendingapproval", "Documents awaiting approval", "Medium", "Reviewed, waiting for the approver.");
    add("documents.noreview", "Published documents without a review date", "Medium", "No next review date set.", false);
    add("docevidence.expiring", "Evidence expiring in 30 days", "Medium", "Active evidence items whose validity ends soon.");
    add("acknowledgements.awaitingbatch", "Documents awaiting an acknowledgement batch", "Medium", "Published documents queued on the Pending tab.", false);
    add("documents.draft", "Drafts awaiting review", "Info", "Documents with the reviewer.");
    add("docevidence.unused", "Evidence not used anywhere", "Info", "Active items with no current link.");

    // ---- E. Charts ------------------------------------------------------------
    const chart = (group, title, mode, toneOf, totalLabel, empty, footer) => {
      const items = distItems(d, group, toneOf);
      return items ? D.distCard({ title, mode, items, totalLabel, emptyText: empty, footer }) : "";
    };
    const calendar = chart("documents_review", "Review calendar", "bars", l => REVIEW_TONE[l] || "info", "published documents",
      "No published documents.", `<p class="pm-dx-note">Published documents by next review date.</p>`);
    const lead = [
      chart("documents_stage", "Current documents by stage", "stack",
        (l, k) => DOC_STAGE_TONE[k] || "info",   // tone by stage CODE (item key): a renamed stage keeps its colour
        "current documents", "No current documents."),
      chart("documents_status", "Documents by status", "stack", (l, k) => (k === "Active" ? "success" : "muted"), "documents", "No documents yet.")
    ].filter(Boolean);
    let ackCard = "";
    if (has("acknowledgements.pending")) {
      const overdue = v("acknowledgements.overdue");
      const ackPage = U("/Practice/Index/document-acknowledgements") + (orgId ? "?organizationId=" + encodeURIComponent(orgId) : "");
      ackCard = D.distCard({ title: "Acknowledgement progress", mode: "stack", totalLabel: "users in open batches",
        items: [{ label: "Acknowledged", count: v("acknowledgements.acknowledged"), tone: "success" },
                { label: "Pending, not yet due", count: Math.max(0, v("acknowledgements.pending") - overdue), tone: "info" },
                { label: "Pending, overdue", count: overdue, tone: "danger" }],
        footer: `<p class="pm-dx-foot"><span>Open batches</span><strong>${D.fmt(v("acknowledgements.openbatches"))}</strong></p>`
          + `<p class="pm-dx-foot"><span>Documents awaiting a batch</span><strong>${D.fmt(v("acknowledgements.awaitingbatch"))}</strong></p>`
          + `<p class="pm-dx-note"><a href="${esc(ackPage)}">Open Document Acknowledgements</a></p>`,
        emptyText: "No open acknowledgement batch." });
    }
    const rest = [
      chart("documents_type", "Current documents by type", "bars", null, "current documents", "No current documents."),
      ackCard,
      chart("docevidence_validity", "Evidence items by validity", "stack", l => VALIDITY_TONE[l] || "neutral", "active items", "No active evidence items.")
    ].filter(Boolean);

    // ---- F. Watchlists (balanced two columns) ---------------------------------
    const left = [
      watchTable(d, has, v, { listKey: "documents_reviewoverdue", title: "Document reviews overdue", kpiKey: "documents.reviewoverdue",
        empty: "No published document is past its review date.", statusLabel: "Type", dateLabel: "Review due" }),
      watchTable(d, has, v, { listKey: "documents_pendingapproval", title: "Documents awaiting approval", kpiKey: "documents.pendingapproval",
        empty: "No document is waiting for approval.", statusLabel: "Version", dateLabel: "Reviewed on", late: false })
    ].filter(Boolean);
    const right = [
      watchTable(d, has, v, { listKey: "acknowledgements_open", title: "Open acknowledgement batches", kpiKey: "acknowledgements.openbatches",
        empty: "No acknowledgement batch is open.", titleLabel: "Batch", statusLabel: "Progress", dateLabel: "Due",
        hideRef: true, hideOwner: true, late: false })
    ].filter(Boolean);

    if (!kpis.length && !att.length && !calendar && !lead.length && !rest.length && !left.length && !right.length)
      return `<div class="pm-dx-empty">Nothing to show for this organization.</div>`;
    const col2 = calendar || lead.length
      ? `<div class="pm-dx-col">${calendar}${lead.length ? `<div class="pm-dx-grid pm-dx-grid-2">${lead.join("")}</div>` : ""}</div>` : "";
    return `<div class="pm-dx">`
      + (kpis.length ? `<div class="pm-dx-kpis">${kpis.join("")}</div>` : "")
      + (att.length || col2 ? `<div class="pm-dx-row-2${att.length && col2 ? "" : " single"}">${att.length ? `<div class="pm-dx-col">${D.attention(att)}</div>` : ""}${col2}</div>` : "")
      + (rest.length ? `<div class="pm-dx-grid pm-dx-grid-3">${rest.join("")}</div>` : "")
      + (left.length || right.length
          ? `<div class="pm-dx-row-2 pm-dx-row-even${left.length && right.length ? "" : " single"}"><div class="pm-dx-col">${left.join("")}</div>`
            + (right.length ? `<div class="pm-dx-col">${right.join("")}</div>` : "") + `</div>` : "")
      + `</div>`;
  }

  // ---- Asset & Contract (509 -- Dashboard UI specification v2 layout) -----
  // One source: sp_dashboard_asset_contract (451, unchanged). Spec v2 has no
  // Asset & Contract section, so this applies its common rules (3.x, 13.1A)
  // to the eleven 451 sections: every figure is 451's definition (the one
  // the section page lists with) and every link opens that page on its own
  // tab / status / kind filter (KPI_DRILL / DIST_DRILL, 451). Figures whose
  // page has no such filter (in use, no owner, overdue activities, support
  // ending ...) are not links. A section the caller may not VIEW is absent.
  async function loadAssetContract(body) {
    body.innerHTML = D.skeleton();
    const dash = await settle(fetchDashboard());
    body.innerHTML = renderAssetContract(dash);
    body.querySelectorAll(".pm-dx-row-2").forEach(D.balance);
    body.querySelectorAll("[data-md-retry]").forEach(b => b.addEventListener("click", load));
    setContext("");
  }

  // Tones follow the codes 451 classifies with (not counts).
  const TECH_TONE = { "Current": "success", "Support ending": "warning", "Unsupported": "danger", "Unknown": "neutral", "Exception": "info2" };
  const CONTRACT_TONE = { DRAFT: "neutral", APPROVED: "info2", ACTIVE: "success", EXPIRED: "warning", TERMINATED: "muted" };
  const PRIVACY_TONE = { NON_COMPLIANT: "danger", INCOMPLETE: "warning", UNDETERMINED: "neutral", CONDITIONAL: "info2", COMPLIANT: "success" };
  const CONFIDENCE_TONE = { CONFLICTING: "danger", STALE: "warning", UNVERIFIED: "neutral", PROBABLE: "info2", VERIFIED: "success" };
  const RELATION_TONE = { PROPOSED: "info2", ACTIVE: "success", DISPUTED: "danger", INACTIVE: "neutral", RETIRED: "muted" };

  function renderAssetContract(dash) {
    const d = dash.ok ? dash.value : null;
    if (!d) return dash.error && dash.error.notConfigured
      ? `<div class="pm-dx-empty">${esc(dash.error.message)}</div>`
      : errorBlock([D.errorCard({ title: "Could not load Asset & Contract", message: dash.error && dash.error.message })]);
    const { has, v } = kpiValues(d);

    // ---- C. Executive KPIs ---------------------------------------------
    const kpis = [];
    if (has("assets.total")) kpis.push(D.kpiCard({
      label: "Assets in use", value: v("assets.inuse"),
      qualifier: `of ${D.fmt(v("assets.total"))} registered &middot; ${D.fmt(v("assets.draft"))} draft`,
      title: "Registered assets not excluded from governance (decommissioned, disposed ...). Registered = every Asset Register record." }));
    // Governance runs on snapshots (Asset Governance): with none yet the
    // score is "not available", never 0% (spec 3.4).
    if (ALLOWED.has("governance")) {
      const snap = has("governance.overall");
      kpis.push(D.kpiCard({
        label: "Governance score", value: snap ? v("governance.overall") : null, suffix: snap ? "%" : "",
        href: kpiHref("governance", "overall", "Asset governance"),
        qualifier: snap ? `${D.fmt(v("governance.red"))} KPIs below threshold &middot; ${D.fmt(v("governance.amber"))} at warning`
                        : "No governance snapshot yet",
        meter: snap ? v("governance.overall") : null, meterTone: "success",
        title: "Overall score of the latest current Asset Governance snapshot." }));
    }
    if (has("technology.unsupported")) kpis.push(D.kpiCard({
      label: "Unsupported technology", value: v("technology.unsupported"),
      qualifier: `${D.fmt(v("technology.duesoon"))} support ending &middot; ${D.fmt(v("technology.unknown"))} unknown version`,
      title: "Assets in use whose firmware or operating system is past its support end (no approved exception)." }));
    if (has("contracts.active")) kpis.push(D.kpiCard({
      label: "Active contracts", value: v("contracts.active"), href: kpiHref("contracts", "active", "Active contracts"),
      qualifier: `${D.fmt(v("contracts.expiring30"))} ending in 30 days &middot; ${D.fmt(v("contracts.expiring90"))} in 90`,
      title: "Contracts in status Active; ending = the version in force ends in the window." }));
    if (has("attestation.overdue")) kpis.push(D.kpiCard({
      label: "Attestations overdue", value: v("attestation.overdue"), href: kpiHref("attestation", "overdue", "Overdue attestations"),
      qualifier: `${D.fmt(v("attestation.pending"))} pending &middot; ${D.fmt(v("attestation.disputed"))} disputed`,
      title: "Open attestations (generated, pending, in progress) past their due date." }));
    if (has("activities.overdue")) kpis.push(D.kpiCard({
      label: "Activities overdue", value: v("activities.overdue"),
      qualifier: `${D.fmt(v("activities.due30"))} due in 30 days &middot; ${D.fmt(v("activities.open"))} open`,
      title: "Open maintenance, calibration and inspection occurrences past their due date." }));

    // ---- D. Needs attention -----------------------------------------------
    // The 16 most material checks; 451's other figures sit in the chart
    // footers (a 27-row list left the lead column half empty).
    const att = [];
    const add = (key, title, severity, detail) => {
      if (has(key)) att.push({ title, severity, count: v(key), detail, href: kpiHref(key.split(".")[0], key.split(".")[1], title) });
    };
    add("attestation.overdue", "Attestations overdue", "High", "Open attestations past their due date.");
    add("activities.overdue", "Maintenance / calibration overdue", "High", "Open activity occurrences past their due date.");
    add("technology.unsupported", "Unsupported technology in use", "High", "Firmware or OS past support end, no approved exception.");
    add("contracts.gaps", "Contract coverage gaps", "High", "Assets that need a contract and have none in force.");
    add("contracts.expiring30", "Contracts ending in 30 days", "High", "Active contracts whose version in force ends soon.");
    add("privacy.noncompliant", "Privacy non-compliant assets", "High", "Assets whose privacy status is non-compliant.");
    add("privacy.reviews", "Privacy reviews overdue", "High", "Open privacy reviews past their due date.");
    add("assets.noowner", "Assets in use without an owner", "High", "No asset owner recorded.");
    add("discovery.conflicts", "CMDB conflicts open", "High", "Discovery values that disagree with the register.");
    add("services.degraded", "Business services degraded", "High", "Services in status Degraded.");
    add("notifications.failed", "Failed notification deliveries", "High", "Outbox messages that could not be sent.");
    add("attestation.disputed", "Attestations disputed", "Medium", "The assignee disputes the recorded facts.");
    add("assets.pending", "Lifecycle changes awaiting approval", "Medium", "Asset status changes waiting for the approver.");
    add("technology.unknown", "Technology version unknown", "Medium", "Assets in use whose firmware / OS version is not recorded.");
    add("privacy.incomplete", "Privacy profile incomplete", "Medium", "Personal-data assets with missing privacy facts.");
    add("discovery.stale", "Stale assets", "Medium", "Assets not seen by discovery within the expected interval.");

    // ---- E. Charts ------------------------------------------------------------
    const chart = (group, title, mode, toneOf, totalLabel, empty, footer) => {
      const items = distItems(d, group, toneOf);
      return items ? D.distCard({ title, mode, items, totalLabel, emptyText: empty, footer }) : "";
    };
    // Governance KPI RAG of the latest snapshot (counts of KPIs, not assets).
    const gov = has("governance.overall") ? D.distCard({ title: "Governance KPIs (latest snapshot)", mode: "stack", totalLabel: "KPIs",
      items: [{ label: "On target", count: v("governance.green"), tone: "success", href: kpiHref("governance", "green", "Governance KPIs on target") },
              { label: "At warning", count: v("governance.amber"), tone: "warning", href: kpiHref("governance", "amber", "Governance KPIs at warning") },
              { label: "Below threshold", count: v("governance.red"), tone: "danger", href: kpiHref("governance", "red", "Governance KPIs below threshold") }],
      footer: `<p class="pm-dx-foot"><span>Failing records</span><strong>${D.fmt(v("governance.failing"))}</strong></p>`,
      emptyText: "No KPI in the latest snapshot." }) : "";
    const tech = l => TECH_TONE[l] || "neutral";
    const lead = [
      chart("assets_status", "Assets by lifecycle status", "bars", null, "assets", "No assets registered."),
      chart("contracts_status", "Contracts by status", "stack", (l, k) => CONTRACT_TONE[k] || "neutral", "contracts", "No contracts yet.",
        has("contracts.renewals") ? `<p class="pm-dx-foot"><span>Open renewals</span><strong>${D.fmt(v("contracts.renewals"))}</strong></p>` : ""),
      chart("technology_firmware", "Firmware (assets in use)", "stack", tech, "assets", "No firmware recorded.",
        has("technology.exception") ? `<p class="pm-dx-foot"><span>Assets on a technology exception</span><strong>${D.fmt(v("technology.exception"))}</strong></p>`
          + `<p class="pm-dx-foot"><span>Exceptions ending in 30 days</span><strong>${D.fmt(v("technology.expiring"))}</strong></p>` : ""),
      chart("technology_os", "Operating systems (assets in use)", "stack", tech, "assets", "No operating system recorded.")
    ].filter(Boolean);
    // Ageing: open attestations since generated, open reconciliation
    // exceptions since raised (the pages do not filter by age: not links).
    const SERIES = [{ key: "attestation", label: "Open attestations", tone: "info3" }, { key: "discovery", label: "Reconciliation exceptions", tone: "info2" }]
      .filter(s => ALLOWED.has(s.key));
    const bandMap = new Map();
    (F(d, "ageing") || []).forEach(b => {
      const g = F(b, "groupKey");
      if (!SERIES.some(s => s.key === g)) return;
      const code = F(b, "bandCode");
      if (!bandMap.has(code)) bandMap.set(code, { label: F(b, "bandName"), sort: Number(F(b, "sortOrder")) || 0, values: {} });
      bandMap.get(code).values[g] = { count: Number(F(b, "itemCount")) || 0 };
    });
    const ageing = SERIES.length && bandMap.size ? D.ageing({ title: "Ageing", meta: "attestations since generated, exceptions since raised",
      series: SERIES, bands: [...bandMap.values()].sort((a, b) => a.sort - b.sort) }) : "";
    const rest = [
      chart("assets_value", "Assets in use by Asset Value", "bars", l => (l === "Not rated" ? "faint" : "info"), "assets in use", "No assets in use."),
      chart("attestation_status", "Attestations by status", "bars", null, "attestations", "No attestations yet.",
        has("attestation.exceptions") ? `<p class="pm-dx-foot"><span>Verification exceptions not closed</span><strong>${D.fmt(v("attestation.exceptions"))}</strong></p>` : ""),
      ageing,
      chart("activities_template", "Open activities by type", "bars", null, "open activities", "No open activities.",
        has("activities.reviews") ? `<p class="pm-dx-foot"><span>Restrictive-use reviews open</span><strong>${D.fmt(v("activities.reviews"))}</strong></p>` : ""),
      chart("privacy_status", "Assets by privacy status", "stack", (l, k) => PRIVACY_TONE[k] || "muted", "assets", "No privacy profile yet.",
        has("privacy.personal") ? `<p class="pm-dx-foot"><span>Personal data (yes or unknown)</span><strong>${D.fmt(v("privacy.personal"))}</strong></p>`
          + `<p class="pm-dx-foot"><span>Exceptions awaiting approval</span><strong>${D.fmt(v("privacy.exceptions"))}</strong></p>` : ""),
      chart("discovery_confidence", "Data confidence (assets)", "stack", (l, k) => CONFIDENCE_TONE[k] || "neutral", "assets", "No discovery data yet."),
      chart("discovery_kind", "Open reconciliation by kind", "bars", null, "open exceptions", "No open reconciliation exceptions.",
        has("discovery.sources") ? `<p class="pm-dx-foot"><span>Discovery sources needing attention</span><strong>${D.fmt(v("discovery.sources"))}</strong></p>` : ""),
      chart("relationships_status", "CMDB relationships by status", "stack", (l, k) => RELATION_TONE[k] || "neutral", "relationships", "No relationships yet.",
        has("relationships.critical") ? `<p class="pm-dx-foot"><span>Active critical dependencies</span><strong>${D.fmt(v("relationships.critical"))}</strong></p>` : ""),
      chart("services_status", "Business services by status", "bars", null, "services", "No business services yet.",
        has("services.conflicts") ? `<p class="pm-dx-foot"><span>Validation conflicts</span><strong>${D.fmt(v("services.conflicts"))}</strong></p>`
          + `<p class="pm-dx-foot"><span>No business owner</span><strong>${D.fmt(v("services.noowner"))}</strong></p>`
          + `<p class="pm-dx-foot"><span>Review date passed</span><strong>${D.fmt(v("services.review"))}</strong></p>` : ""),
      chart("notifications_activity", "Open notifications by activity", "bars", null, "open occurrences", "No open notification occurrences.",
        has("notifications.escalated") ? `<p class="pm-dx-foot"><span>Escalated</span><strong>${D.fmt(v("notifications.escalated"))}</strong></p>` : "")
    ].filter(Boolean);

    // ---- F. Watchlists (balanced two columns) ---------------------------------
    const left = [
      watchTable(d, has, v, { listKey: "attestation_overdue", title: "Overdue attestations", kpiKey: "attestation.overdue",
        empty: "No attestation is past its due date.", hideStatus: true }),
      watchTable(d, has, v, { listKey: "activities_overdue", title: "Overdue activities", kpiKey: "activities.overdue",
        empty: "No activity is past its due date.", hideStatus: true })
    ].filter(Boolean);
    const right = [
      watchTable(d, has, v, { listKey: "contracts_expiring", title: "Active contracts ending in 90 days", kpiKey: "contracts.expiring90",
        empty: "No active contract ends in the next 90 days.", dateLabel: "Ends", late: false, hideStatus: true }),
      // The list holds unsupported AND unknown (unsupported first).
      watchTable(d, has, v, { listKey: "technology_unsupported", title: "Unsupported or unknown technology", kpiKey: "technology.unsupported",
        total: v("technology.unsupported") + v("technology.unknown"),
        empty: "No asset in use runs unsupported or unknown technology.", titleLabel: "Asset", statusLabel: "Technology",
        dateLabel: "Support end", late: false })
    ].filter(Boolean);

    if (!kpis.length && !att.length && !gov && !lead.length && !rest.length && !left.length && !right.length)
      return `<div class="pm-dx-empty">Nothing to show for this organization.</div>`;
    // Lead charts in pairs: one auto-fit grid of four made three columns
    // and an orphan beside Needs attention.
    const pairs = [];
    for (let i = 0; i < lead.length; i += 2) pairs.push(`<div class="pm-dx-grid pm-dx-grid-2">${lead.slice(i, i + 2).join("")}</div>`);
    const col2 = gov || lead.length ? `<div class="pm-dx-col">${gov}${pairs.join("")}</div>` : "";
    return `<div class="pm-dx">`
      + (kpis.length ? `<div class="pm-dx-kpis">${kpis.join("")}</div>` : "")
      + (att.length || col2 ? `<div class="pm-dx-row-2${att.length && col2 ? "" : " single"}">${att.length ? `<div class="pm-dx-col">${D.attention(att)}</div>` : ""}${col2}</div>` : "")
      + (rest.length ? `<div class="pm-dx-grid pm-dx-grid-3">${rest.join("")}</div>` : "")
      + (left.length || right.length
          ? `<div class="pm-dx-row-2 pm-dx-row-even${left.length && right.length ? "" : " single"}"><div class="pm-dx-col">${left.join("")}</div>`
            + (right.length ? `<div class="pm-dx-col">${right.join("")}</div>` : "") + `</div>` : "")
      + `</div>`;
  }

  // ---- load --------------------------------------------------------------
  function message(text) {
    const m = document.getElementById("mdMessage");
    m.textContent = text || "";
    m.hidden = !text;
  }

  async function load() {
    const body = document.getElementById("mdBody");
    if (!orgId) { body.innerHTML = ""; message("Select an organization."); return; }
    // v2 layout (UI specification v2): Governance (503), Issues & Actions
    // (504), Audit Assurance (506), Third-Party Risk (507), Policies &
    // Documents (508), Asset & Contract (509).
    const v2 = { "governance": loadGovernance, "issues-actions": loadIssuesActions,
                 "audit-assurance": loadAuditAssurance,   // 506
                 "tprm": loadTprm,                        // 507
                 "documents": loadDocuments,              // 508
                 "asset-contract": loadAssetContract }[MODULE];   // 509
    if (v2) {
      message("");
      try { await v2(body); }
      catch (err) { body.innerHTML = ""; message(`Could not load the dashboard: ${err.message}`); }
      return;
    }
    // 509: every module dashboard renders on the v2 layout.
    message(`Unknown dashboard '${MODULE}'.`);
  }

  async function init() {
    const sel = document.getElementById("mdOrganization");
    try {
      const r = await fetch(U("/practice/api/organizations/allowed"), { credentials: "same-origin" });
      const b = r.ok ? await r.json() : {};
      ((b && (b.data || b.Data)) || []).forEach(row => {
        const value = String(F(row, "organizationId") ?? "");
        if (!value) return;
        const opt = document.createElement("option");
        opt.value = value;
        opt.textContent = String(F(row, "organizationName") ?? value);
        sel.appendChild(opt);
      });
    } catch (_) { /* the message below says what is missing */ }
    const wanted = new URLSearchParams(window.location.search).get("organizationId");
    if (wanted && [...sel.options].some(o => o.value === wanted)) sel.value = wanted;
    else window.gracOrgPref.apply(sel);   // 2026-10-06: last-picked org, else lowest id
    orgId = sel.value;
    sel.addEventListener("change", () => { orgId = sel.value; load(); });
    document.getElementById("mdRefreshBtn").addEventListener("click", load);
    await load();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
