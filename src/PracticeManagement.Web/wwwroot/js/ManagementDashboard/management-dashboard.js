// =====================================================================
// management-dashboard.js  (migration 414)
//
// Renders the Governance, Issues & Actions and Audit & Assurance landing
// dashboards (Partials/management-dashboard.cshtml). The numbers come
// from SQL -- one GET per dashboard, four result sets (KPIs, ageing,
// distributions, lists). Layout (2026-10-01/02): KPI cards | ageing +
// lists as one 50/50 row (lists scroll within it), then distributions in
// one row. Without ageing: KPIs, distributions, then full-width lists.
// This file only lays them out and turns every
// clickable element into a link to the EXISTING list page, with that
// page's own filter values (the receiving side is Shared/dashboard-drill.js).
//
// 451: also the Asset & Contract dashboard (asset-contract). Its tiles
// and bars open the asset screens with tab / status / kind / pending, which
// those screens read through Shared/dashboard-drill.js; an ageing band is a
// link only where the page filters by age (AGEING_DRILL).
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
    instances:  (p, l) => link("/Practice/Index/resolve", p, l),
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
    notifications: (p, l) => link("/Practice/Index/asset-notifications", p, l)
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
    "instances.total":          {},
    "instances.implemented":    { status: "Implemented" },
    "instances.partial":        { status: "Partially Implemented" },
    "instances.notimplemented": { status: "Not Implemented" },
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
    "notifications.failed":   { tab: "LOG", status: "Failed" }
    // instances.noowner has no drill: Operationalize has no "no owner"
    // filter, and an unfiltered list under a "No owner" tile would lie.
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
    tasks_status:      ["tasks",      k => ({ status: k })],
    tasks_priority:    ["tasks",      k => ({ status: "OpenSet", priority: k })],
    exceptions_status: ["exceptions", k => ({ status: k })],
    exceptions_type:   ["exceptions", k => ({ requestType: k })],
    audits_status:     ["audits",     k => ({ status: k })],
    findings_severity: ["findings",   k => ({ drill: "pending", severity: k })],
    findings_status:   ["findings",   k => ({ status: k })],
    plans_status:      ["plans",      k => ({ status: k })],
    instances_status:  ["instances",  k => ({ status: k })],
    // 451: Asset & Contract (groups without an entry are not links)
    assets_status:        ["assets",        k => ({ status: k })],
    contracts_status:     ["contracts",     k => ({ tab: "CONTRACTS", status: k })],
    attestation_status:   ["attestation",   k => ({ tab: "ALL", status: k })],
    privacy_status:       ["privacy",       k => ({ tab: "ASSETS", status: k })],
    discovery_kind:       ["discovery",     k => ({ tab: "QUEUE", kind: k })],
    discovery_confidence: ["discovery",     k => ({ tab: "CONFIDENCE", status: k })],
    services_status:      ["services",      k => ({ tab: "SERVICES", status: k })],
    relationships_status: ["relationships", k => ({ tab: "RELATIONSHIPS", status: k })]
  };

  const sectionOf = key => String(key || "").split("_")[0];

  // ---- rendering -------------------------------------------------------
  function tile(value, label, href, alert) {
    const cls = `pm-dash-tile${alert && Number(value) > 0 ? " is-alert" : ""}${href ? " is-clickable" : ""}`;
    const body = `<div class="v">${esc(value ?? 0)}</div><div class="k">${esc(label)}</div>`;
    return href
      ? `<a class="${cls}" href="${esc(href)}" style="text-decoration:none;display:block">${body}</a>`
      : `<div class="${cls}">${body}</div>`;
  }

  function bars(rows) {
    const list = rows.filter(r => !r.heading);
    if (!list.length) return `<p class="pm-hint">No data.</p>`;
    const max = Math.max(1, ...list.map(r => r.count || 0));
    return `<div class="pm-dash-bars">${rows.map(r => {
      const width = Math.round((r.count || 0) / max * 100);
      const fill = `<span class="trk"><span class="fil" style="width:${width}%${r.colour ? `;background:${esc(r.colour)}` : ""}"></span></span>`;
      const inner = `<span class="lbl" title="${esc(r.label)}">${esc(r.label)}</span>${fill}<span class="num">${r.count || 0}</span>`;
      return r.href && (r.count || 0) > 0
        ? `<a class="pm-dash-bar-row is-clickable" href="${esc(r.href)}" style="text-decoration:none">${inner}</a>`
        : `<div class="pm-dash-bar-row">${inner}</div>`;
    }).join("")}</div>`;
  }

  function block(title, inner) {
    return `<div><h4 class="pm-dash-subhead">${esc(title)}</h4>${inner}</div>`;
  }

  function renderKpis(kpis) {
    const bySection = new Map();
    kpis.forEach(k => {
      const s = F(k, "sectionKey");
      if (!ALLOWED.has(s)) return;
      if (!bySection.has(s)) bySection.set(s, { title: F(k, "sectionTitle"), items: [] });
      bySection.get(s).items.push(k);
    });
    let html = "";
    bySection.forEach((sec, key) => {
      html += `<h3 class="pm-dash-subhead">${esc(sec.title)}</h3><div class="pm-dash-tiles">`
        + sec.items.map(k => {
            const kk = `${key}.${F(k, "kpiKey")}`;
            const filter = KPI_DRILL[kk];
            const label = `${sec.title}: ${F(k, "label")}`;
            const href = filter && TARGET[key] ? TARGET[key](filter, label) : null;
            return tile(F(k, "value"), F(k, "label"), href, F(k, "isAlert"));
          }).join("")
        + `</div>`;
    });
    return html;
  }

  function renderAgeing(ageing) {
    const groups = new Map();
    ageing.forEach(b => {
      const g = F(b, "groupKey");
      if (!ALLOWED.has(g)) return;
      if (!groups.has(g)) groups.set(g, { title: F(b, "groupTitle"), bands: [] });
      groups.get(g).bands.push(b);
    });
    if (!groups.size) return "";
    // --pm-dash-cols: one column per ageing group, so beside the KPIs
    // (.pm-dash-split) the groups sit side by side in one row.
    let html = `<h3 class="pm-dash-subhead">Ageing <span class="pm-hint">(open items, days since raised)</span></h3>`
      + `<div class="pm-dash-grid pm-dash-grid-ageing" style="--pm-dash-cols:${groups.size}">`;
    groups.forEach((g, key) => {
      html += block(g.title, bars(g.bands.map(b => {
        const max = F(b, "maxDays");
        const filter = { ...(AGEING_DRILL[key] || {}), minAge: F(b, "minDays"), maxAge: max >= 100000 ? null : max };
        return {
          label: F(b, "bandName"), count: F(b, "itemCount"),
          // 451: a band links only where the page filters by age (AGEING_DRILL).
          href: TARGET[key] && AGEING_DRILL[key] ? TARGET[key](filter, `${g.title} aged ${F(b, "bandName")}`) : null
        };
      })));
    });
    return html + `</div>`;
  }

  function renderDistributions(items) {
    const groups = new Map();
    items.forEach(d => {
      const g = F(d, "groupKey");
      if (!ALLOWED.has(sectionOf(g))) return;
      if (!groups.has(g)) groups.set(g, { title: F(d, "groupTitle"), items: [] });
      groups.get(g).items.push(d);
    });
    if (!groups.size) return "";
    let html = `<h3 class="pm-dash-subhead">Distribution</h3><div class="pm-dash-grid pm-dash-grid-dist">`;
    groups.forEach((g, key) => {
      const [section, filterOf] = DIST_DRILL[key] || [];
      html += block(g.title, bars(g.items.map(d => {
        const itemKey = F(d, "itemKey");
        const label = F(d, "itemLabel");
        return {
          label, count: F(d, "itemCount"), colour: F(d, "colourHex"),
          href: itemKey !== null && section && TARGET[section]
            ? TARGET[section](filterOf(itemKey), `${g.title}: ${label}`) : null
        };
      })));
    });
    return html + `</div>`;
  }

  // Lists: the row opens the record's own existing page where there is
  // one (Task View, Gap View); audit rows open the Executions list on
  // the same bucket.
  function listRowHref(listKey, row) {
    const id = F(row, "recordId");
    if (listKey === "tasks_overdue" && id) return U("/Practice/Index/task-view") + "?taskId=" + encodeURIComponent(id);
    if (listKey === "gaps_overdue" && id)  return U("/Practice/Index/gap-view") + "?gapId=" + encodeURIComponent(id) + "&orgId=" + encodeURIComponent(orgId);
    if (listKey === "audits_upcoming") return TARGET.audits({ drill: "upcoming" }, "Audits starting in the next 30 days");
    if (listKey === "audits_overdue")  return TARGET.audits({ drill: "overdue" }, "Overdue audits");
    // 451: an asset opens on the Asset Register (?assetId=, 450).
    if (listKey === "technology_unsupported" && id)
      return U("/Practice/Index/asset-register") + "?" + new URLSearchParams({ organizationId: orgId, assetId: id }).toString();
    if (listKey === "attestation_overdue") return TARGET.attestation({ tab: "ALL", status: "OVERDUE" }, "Overdue attestations");
    return null;
  }

  function renderLists(lists) {
    const groups = new Map();
    lists.forEach(l => {
      const k = F(l, "listKey");
      if (!ALLOWED.has(sectionOf(k))) return;
      if (!groups.has(k)) groups.set(k, { title: F(l, "listTitle"), rows: [] });
      groups.get(k).rows.push(l);
    });
    if (!groups.size) return "";
    // Each list takes a full row (2026-10-01): side by side in the grid
    // the tables were too narrow and scrolled sideways.
    let html = `<div class="pm-dash-lists">`;
    groups.forEach((g, key) => {
      html += block(g.title, `<div class="pm-table-wrap"><table>
        <thead><tr><th>Reference</th><th>Title</th><th>Owner</th><th>Status</th><th>Date</th></tr></thead>
        <tbody>${g.rows.map(r => {
          const href = listRowHref(key, r);
          const ref = esc(F(r, "refText") || "");
          const d = F(r, "dateValue");
          return `<tr>
            <td>${href ? `<a href="${esc(href)}">${ref}</a>` : ref}</td>
            <td>${esc(F(r, "title") || "")}</td>
            <td>${esc(F(r, "ownerName") || "—")}</td>
            <td>${esc(F(r, "statusText") || "")}</td>
            <td>${d ? esc(window.gracFormatDateOnly ? window.gracFormatDateOnly(d) : String(d).slice(0, 10)) : "—"}</td>
          </tr>`;
        }).join("")}</tbody></table></div>`);
    });
    return html + `</div>`;
  }

  // ---- Governance: the two existing aggregate queries -----------------
  // Standards & Frameworks' per-release counts (subscribed-frameworks)
  // and the Home overview's practices and attention items
  // (dashboard-summary). Both are the existing gateway queries, with
  // their existing security; nothing is recounted here.
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

  function renderFrameworks(releases) {
    const n = k => releases.reduce((s, r) => s + (Number(F(r, k)) || 0), 0);
    const std = (params, label) => link("/Practice/Index/organization-controls", params, label);
    let html = `<h3 class="pm-dash-subhead">Standards &amp; Frameworks</h3><div class="pm-dash-tiles">`
      + tile(releases.length, "Subscribed frameworks", std({}, ""))
      + tile(n("TotalStatementsCount"), "Control statements", std({}, ""))
      + tile(n("NotUpdatedStatementsCount"), "Not updated", std({}, ""), true)
      + tile(n("ApplicableStatementsCount"), "Applicable", std({}, ""))
      + tile(n("ImplementedStatementsCount"), "Implemented", std({}, ""))
      + tile(n("PendingUpdatesCount"), "Pending repository updates", std({}, ""), true)
      + `</div>`;
    if (!releases.length) return html;
    const cs = (release, status) => {
      const q = new URLSearchParams({ organizationId: String(F(release, "OrganizationId") || orgId), releaseId: String(F(release, "ReleaseId")) });
      if (status) q.set("status", status);
      return U("/Practice/Index/source-statements") + "?" + q.toString();
    };
    const cell = (release, key, status) => {
      const v = Number(F(release, key)) || 0;
      return v > 0 && status ? `<a href="${esc(cs(release, status))}">${v}</a>` : String(v);
    };
    html += `<div class="pm-table-wrap"><table>
      <thead><tr><th>Framework / Release</th><th>Total</th><th>Not updated</th><th>Applicable</th><th>Not applicable</th><th>Implemented</th><th>Pending updates</th></tr></thead>
      <tbody>${releases.map(r => `<tr>
        <td><a href="${esc(cs(r, ""))}">${esc(F(r, "FrameworkRelease") || F(r, "ReleaseVersion") || "")}</a></td>
        <td>${Number(F(r, "TotalStatementsCount")) || 0}</td>
        <td>${cell(r, "NotUpdatedStatementsCount", "Not Updated")}</td>
        <td>${cell(r, "ApplicableStatementsCount", "Applicable")}</td>
        <td>${Number(F(r, "NotApplicableStatementsCount")) || 0}</td>
        <td>${Number(F(r, "ImplementedStatementsCount")) || 0}</td>
        <td>${Number(F(r, "PendingUpdatesCount")) || 0}</td>
      </tr>`).join("")}</tbody></table></div>`;
    return html;
  }

  function renderPractices(summary, attention) {
    // No status filter: the counts are the Home overview's (practice rows),
    // so the tiles open the Organization Practices list itself.
    const pr = () => link("/Practice/Index/organization-requirements", {}, "");
    let html = `<h3 class="pm-dash-subhead">Practices</h3><div class="pm-dash-tiles">`
      + tile(F(summary, "TotalPractices") ?? 0, "Total", pr())
      + tile(F(summary, "ApplicablePractices") ?? 0, "Applicable", pr())
      + tile(F(summary, "NotUpdatedPractices") ?? 0, "Not updated", pr(), true)
      + tile(F(summary, "NotApplicablePractices") ?? 0, "Not applicable", pr())
      + `</div>`;
    const items = (attention || []).filter(a => Number(F(a, "ItemCount")) > 0);
    if (items.length) {
      html += `<h3 class="pm-dash-subhead">Needs attention</h3><div class="pm-attention-list">`
        + items.map(a => {
            const route = F(a, "Route");
            return `<div><strong>${esc(F(a, "Title"))}</strong> <b>${esc(F(a, "ItemCount"))}</b>
              <span class="pm-hint">${esc(F(a, "Detail") || "")}</span>
              ${route ? ` <a href="${esc(U("/" + String(route).replace(/^\/+/, "")))}">Open</a>` : ""}</div>`;
          }).join("")
        + `</div>`;
    }
    return html;
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
    message("Loading...");
    try {
      const calls = [fetch(U(`/practice/api/management-dashboard/${encodeURIComponent(MODULE)}?organizationId=${encodeURIComponent(orgId)}`),
                           { credentials: "same-origin" })
        .then(async r => {
          const b = await r.json().catch(() => ({}));
          if (!r.ok) throw new Error(b.error || `HTTP ${r.status}`);
          return b;
        })];
      if (MODULE === "governance") {
        calls.push(ALLOWED.has("frameworks")
          ? gatewayQuery("subscribed-frameworks", { organizationId: Number(orgId), pageNumber: 1, pageSize: 500 }) : Promise.resolve(null));
        calls.push(ALLOWED.has("practices")
          ? gatewayQuery("dashboard-summary", { organizationId: Number(orgId), pageNumber: 1, pageSize: 1 }) : Promise.resolve(null));
      }
      const [d, frameworks, summary] = await Promise.all(calls);

      let html = "";
      if (frameworks) html += renderFrameworks(frameworks[0] || []);
      if (summary)    html += renderPractices((summary[0] || [])[0] || {}, summary[1] || []);
      // KPIs and ageing share one row when both exist (2026-10-01):
      // the summary cards take the left half, the ageing groups the
      // right half, instead of the cards leaving the right side empty.
      // The lists (Overdue tasks / issues / audits) fill the rest of the
      // right half under the ageing (2026-10-02): that column is held to
      // the KPI column's height (.pm-dash-side) and the list tables
      // scroll inside it, so the row still ends where Distribution
      // starts. A dashboard without ageing keeps its KPIs full width and
      // its lists in full rows at the bottom.
      const kpiHtml = renderKpis(F(d, "kpis") || []);
      const ageHtml = renderAgeing(F(d, "ageing") || []);
      const listHtml = renderLists(F(d, "lists") || []);
      html += (kpiHtml && ageHtml
                ? `<div class="pm-dash-split"><div>${kpiHtml}</div><div class="pm-dash-side">${ageHtml}${listHtml}</div></div>`
                  + renderDistributions(F(d, "distributions") || [])
                : kpiHtml + ageHtml
                  + renderDistributions(F(d, "distributions") || [])
                  + listHtml);
      body.innerHTML = html || `<div class="pm-empty compact">Nothing to show for this organization.</div>`;
      message("");
    } catch (err) {
      body.innerHTML = "";
      message(`Could not load the dashboard: ${err.message}`);
    }
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
