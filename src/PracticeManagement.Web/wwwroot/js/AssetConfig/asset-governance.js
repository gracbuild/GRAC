// =====================================================================
// Asset Governance (migration 450) -- BRD 19.8, 13.5 (Governance), 19.10
// (Governance KPI Detail). Loaded by asset-governance.cshtml. Services:
// governance (scorecard of a snapshot + trend), governance/items (record
// drill-down), governance/snapshots (history), governance/settings (KPI
// settings, overall thresholds, relationship requirements),
// governance/settings, governance/settings/overall,
// governance/relationship-rules and governance/snapshot (EDIT).
// Every score, rating and record outcome comes from the procedures; this
// screen only lays them out. A tile opens the KPI detail on its failing
// records; an asset row opens the asset on the Asset Register.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config/governance";
  const root = document.getElementById("agvRoot");
  if (!root) return;
  const CAN_EDIT = root.dataset.canEdit === "1";

  const RAG = { GREEN: ["On target", "agv-rag-green"], AMBER: ["Warning", "agv-rag-amber"], RED: ["Below threshold", "agv-rag-red"],
                NA: ["Not applicable", "agv-rag-na"] };
  const OUTCOME = { PASS: ["Passing", "agv-rag-green"], FAIL: ["Failing", "agv-rag-red"], EXCLUDED: ["Excluded", "agv-rag-na"] };
  const KIND = { ASSET: "Asset", SERVICE: "Business service", ATTESTATION: "Attestation", RECONCILIATION: "Reconciliation exception",
                 SOURCE: "Discovery source" };
  const SOURCE = { SCHEDULER: "Scheduler", MANUAL: "Manual" };

  const state = { organizationId: null, mainTab: "SCORECARD", snapshotId: null, card: null, kpiCode: null,
                  settings: null, itemPager: null, historyPager: null };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    const g = window.__pmGrid;
    state.itemPager = g ? g.attach({ hostId: "agvItemPager", onChange: refreshItems }) : null;
    state.historyPager = g ? g.attach({ hostId: "agvHistoryPager", onChange: refreshHistory }) : null;
    bind();
    await populateOrgs();
    const params = new URLSearchParams(window.location.search);
    const sel = document.getElementById("agvOrg");
    const orgParam = params.get("organizationId");
    if (orgParam && [...sel.options].some(o => o.value === orgParam)) sel.value = orgParam;
    else window.gracOrgPref.apply(sel);   // 2026-10-06: last-picked org, else lowest id
    await changeOrg(Number(sel.value) || null);
  }

  async function populateOrgs() {
    const sel = document.getElementById("agvOrg");
    try {
      const r = await fetch(U("/practice/api/organizations/allowed"), { credentials: "same-origin" });
      const b = r.ok ? await r.json() : null;
      ((b && (b.data || b.Data)) || []).forEach(row => {
        const value = String(row.organizationId ?? row.OrganizationId ?? "");
        if (!value) return;
        const o = document.createElement("option");
        o.value = value; o.textContent = String(row.organizationName ?? row.OrganizationName ?? value);
        sel.appendChild(o);
      });
    } catch (_) { /* placeholder stays */ }
    if (sel.options.length === 2) sel.disabled = true;
  }

  function bind() {
    document.getElementById("agvOrg").addEventListener("change", e => changeOrg(Number(e.target.value) || null));
    document.querySelectorAll("[data-agv-main]").forEach(b => b.addEventListener("click", () => selectMainTab(b.dataset.agvMain)));
    document.getElementById("agvRefresh").addEventListener("click", () => selectMainTab(state.mainTab, true));
    document.getElementById("agvTake")?.addEventListener("click", takeSnapshot);
    document.getElementById("agvSnapshotInfo").addEventListener("click", ev => {
      if (ev.target.closest("button[data-agv-current]")) { state.snapshotId = null; selectMainTab(state.mainTab, true); }
    });
    // scorecard
    document.getElementById("agvTiles").addEventListener("click", ev => {
      const t = ev.target.closest("[data-agv-kpi]");
      if (t) openDetail(t.dataset.agvKpi);
    });
    document.getElementById("agvBreaches").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-agv-kpi]");
      if (b) openDetail(b.dataset.agvKpi);
    });
    // detail
    document.getElementById("agvKpi").addEventListener("change", e => { state.kpiCode = e.target.value; renderDefinition(); state.itemPager?.reset(true); refreshItems(); });
    document.getElementById("agvOutcome").addEventListener("change", () => { state.itemPager?.reset(true); refreshItems(); });
    let t = null;
    document.getElementById("agvSearch").addEventListener("input", () => { clearTimeout(t); t = setTimeout(() => { state.itemPager?.reset(true); refreshItems(); }, 300); });
    // history
    document.getElementById("agvHistory").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-agv-snapshot]");
      if (b) { state.snapshotId = Number(b.dataset.agvSnapshot); selectMainTab("SCORECARD", true); }
    });
    // settings
    document.getElementById("agvOSave")?.addEventListener("click", saveOverall);
    document.getElementById("agvSettings").addEventListener("click", ev => {
      const s = ev.target.closest("button[data-agv-save]");
      if (s) { saveKpi(s.dataset.agvSave, false); return; }
      const r = ev.target.closest("button[data-agv-reset]");
      if (r) saveKpi(r.dataset.agvReset, true);
    });
    document.getElementById("agvRRel")?.addEventListener("change", fillSides);
    document.getElementById("agvRAdd")?.addEventListener("click", addRule);
    document.getElementById("agvRules").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-agv-rule]");
      if (b) saveRule(Number(b.dataset.agvRule));
    });
  }

  async function changeOrg(id) {
    state.organizationId = id;
    state.snapshotId = null; state.card = null; state.settings = null;
    hideMessage();
    [state.itemPager, state.historyPager].forEach(p => p?.reset(true));
    await selectMainTab(state.mainTab, true);
  }

  async function selectMainTab(name, reload) {
    state.mainTab = name;
    document.querySelectorAll("[data-agv-main]").forEach(x => { const on = x.dataset.agvMain === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    document.querySelectorAll("[data-agv-mainpanel]").forEach(p => { p.hidden = p.dataset.agvMainpanel !== name; });
    if (name !== "SETTINGS" && name !== "HISTORY" && (reload || !state.card)) await loadCard();
    if (name === "SCORECARD") renderScorecard();
    else if (name === "DETAIL") { renderKpiPicker(); renderDefinition(); await refreshItems(); }
    else if (name === "HISTORY") await refreshHistory();
    else await loadSettings();
  }

  // ------------------------------------------------------------------ scorecard
  async function loadCard() {
    state.card = null;
    if (!state.organizationId) { renderSnapshotInfo(); return; }
    const qs = new URLSearchParams({ organizationId: state.organizationId, trendDays: 90 });
    if (state.snapshotId) qs.set("snapshotId", state.snapshotId);
    const res = await api("GET", `?${qs}`);
    if (!res.ok) { showMessage(res.error, "error"); renderSnapshotInfo(); return; }
    state.card = res.data.data || { snapshot: null, kpis: [], trend: [] };
    if (!state.kpiCode && (state.card.kpis || []).length) state.kpiCode = state.card.kpis[0].kpiCode;
    renderSnapshotInfo();
  }

  function renderSnapshotInfo() {
    const el = document.getElementById("agvSnapshotInfo");
    const s = state.card && state.card.snapshot;
    if (!state.organizationId) { el.textContent = "Select an organization."; return; }
    if (!s) {
      el.textContent = state.card ? `No snapshot yet. ${CAN_EDIT ? "Take snapshot computes every KPI now; " : ""}the asset scheduler takes one each day.` : "";
      return;
    }
    el.innerHTML = `Snapshot of ${esc(date(s.asOfDate))} (version ${esc(s.versionNo)}${Number(s.versionsOfDate) > 1 ? ` of ${esc(s.versionsOfDate)}` : ""}${s.isCurrent ? ", current" : `, superseded ${esc(dateTime(s.supersededDt))}`}),`
      + ` taken ${esc(dateTime(s.takenDt))} by ${esc(s.takenBy)} (${esc(SOURCE[s.sourceCode] || s.sourceCode)}); ${esc(s.itemCount)} records scored.`
      + (s.itemsPurged ? " Record detail of this snapshot has been removed (retention); the scores remain." : "")
      + (state.snapshotId ? ` <button class="pm-link-button" type="button" data-agv-current="1">Show the current snapshot</button>` : "");
  }

  function renderScorecard() {
    const tiles = document.getElementById("agvTiles");
    const c = state.card;
    if (!c || !c.snapshot) {
      tiles.innerHTML = "";
      document.getElementById("agvBreaches").innerHTML = empty(7, state.organizationId ? "No snapshot yet." : "Select an organization.");
      document.getElementById("agvTrendHead").innerHTML = "";
      document.getElementById("agvTrendBody").innerHTML = "";
      return;
    }
    const s = c.snapshot;
    const overall = `<div class="pm-dash-tile${s.overallRag === "RED" ? " is-alert" : ""}">
        <div class="v">${esc(pct(s.overallScore))}</div><div class="k">Overall governance score</div>
        <div class="agv-tile-meta">${chip(RAG, s.overallRag)} target ${esc(num(s.overallTarget))} / warning ${esc(num(s.overallWarning))}${change(s.overallScore, s.previousOverallScore, "HIGHER")}</div></div>`;
    tiles.innerHTML = overall + (c.kpis || []).map(k => {
      const off = !k.isEnabled;
      return `<a class="pm-dash-tile is-clickable${k.rag === "RED" ? " is-alert" : ""}" href="#" data-agv-kpi="${esc(k.kpiCode)}" style="text-decoration:none;display:block">
        <div class="v">${off ? "Off" : esc(pct(k.score))}</div><div class="k">${esc(k.kpiName)}</div>
        <div class="agv-tile-meta">${off ? `<span class="agv-chip agv-rag-na">Not scored</span>`
          : `${chip(RAG, k.rag)} ${esc(k.numerator ?? 0)} / ${esc(k.denominator ?? 0)}${Number(k.failingCount) ? ` - ${esc(k.failingCount)} failing` : ""}${change(k.score, k.previousScore, k.direction)}`}</div></a>`;
    }).join("");
    tiles.querySelectorAll("a[data-agv-kpi]").forEach(a => a.addEventListener("click", ev => ev.preventDefault()));
    const breaches = (c.kpis || []).filter(k => k.isEnabled && (k.rag === "RED" || k.rag === "AMBER"))
      .sort((a, b) => (a.rag === b.rag ? 0 : a.rag === "RED" ? -1 : 1));
    document.getElementById("agvBreaches").innerHTML = breaches.map(k => `
      <tr><td><button class="pm-link-button" type="button" data-agv-kpi="${esc(k.kpiCode)}">${esc(k.kpiName)}</button></td>
          <td>${esc(pct(k.score))}</td><td>${chip(RAG, k.rag)}</td>
          <td>${esc(thresholds(k))}</td><td>${esc(k.numerator)} / ${esc(k.denominator)}</td><td>${esc(k.failingCount)}</td>
          <td>${k.previousScore == null ? "--" : esc(signed(Number(k.score) - Number(k.previousScore)))}</td></tr>`).join("")
      || empty(7, "Every scored KPI is on target.");
    renderTrend();
  }

  function renderTrend() {
    const rows = (state.card && state.card.trend) || [];
    const dates = [...new Set(rows.map(r => date(r.asOfDate)))].sort().slice(-10);
    const head = document.getElementById("agvTrendHead"), body = document.getElementById("agvTrendBody");
    if (!dates.length) { head.innerHTML = ""; body.innerHTML = empty(1, "No trend yet."); return; }
    head.innerHTML = `<tr><th>KPI</th>${dates.map(d => `<th>${esc(d)}</th>`).join("")}</tr>`;
    const cell = (code, d) => {
      const r = rows.find(x => x.kpiCode === code && date(x.asOfDate) === d);
      return r ? `<span class="agv-chip ${(RAG[r.rag] || RAG.NA)[1]}">${esc(pct(r.score))}</span>` : "--";
    };
    const lines = [["OVERALL", "Overall governance score"], ...(state.card.kpis || []).map(k => [k.kpiCode, k.kpiName])];
    body.innerHTML = lines.map(([code, name]) => `<tr><td>${esc(name)}</td>${dates.map(d => `<td>${cell(code, d)}</td>`).join("")}</tr>`).join("");
  }

  async function takeSnapshot() {
    if (!state.organizationId) return;
    if (!await window.gracUi.confirm("Compute every enabled KPI now? A new version of today is saved only when a result changed; the previous version is kept.")) return;
    showMessage("Computing the KPIs...", "info");
    const res = await api("POST", "/snapshot", { organizationId: state.organizationId });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.snapshotId = null;
    await selectMainTab(state.mainTab === "SETTINGS" ? "SCORECARD" : state.mainTab, true);
    showMessage(res.data.result === "UNCHANGED" ? "No change since the current snapshot of today; nothing was saved." : "Snapshot saved.", "success");
  }

  // ------------------------------------------------------------------ KPI detail
  function openDetail(code) { state.kpiCode = code; document.getElementById("agvOutcome").value = "FAIL"; state.itemPager?.reset(true); selectMainTab("DETAIL"); }

  function kpi() { return ((state.card && state.card.kpis) || []).find(k => k.kpiCode === state.kpiCode) || null; }

  function renderKpiPicker() {
    const sel = document.getElementById("agvKpi");
    sel.innerHTML = ((state.card && state.card.kpis) || []).map(k => `<option value="${esc(k.kpiCode)}">${esc(k.kpiName)}</option>`).join("");
    if (state.kpiCode) sel.value = state.kpiCode;
  }

  function renderDefinition() {
    const k = kpi(), el = document.getElementById("agvDefinition");
    if (!k) { el.innerHTML = ""; document.getElementById("agvTotals").textContent = ""; return; }
    const item = (l, v) => `<div><span>${esc(l)}</span>${esc(v)}</div>`;
    el.innerHTML = [
      item("Formula", k.formulaText),
      item("Numerator", k.numeratorText),
      item("Denominator", k.denominatorText),
      item("Population", k.populationText),
      item("As of", k.asOfText),
      item("Exclusions", k.exclusionsText),
      item("Zero denominator", "No score: rated Not applicable and left out of the overall score."),
      item("Rounding", "Numerator / denominator x 100, one decimal (half away from zero)."),
      item("Thresholds", `${thresholds(k)}${k.direction === "LOWER" ? " (lower is better)" : " (higher is better)"}; weight ${k.weight}${k.periodDays ? `; period ${k.periodDays} days` : ""}`),
      item("Authorization", "View: Asset Governance VIEW. Settings and Take snapshot: Asset Governance EDIT. Records are those of the selected organization only."),
      item("One record", `${k.recordLabel}; BRD ${k.brdReference}`),
      item("This snapshot", k.isEnabled ? `${pct(k.score)} - ${(RAG[k.rag] || RAG.NA)[0]}` : "Not scored (disabled in Settings)")
    ].join("");
  }

  async function refreshItems() {
    const body = document.getElementById("agvItems"), totals = document.getElementById("agvTotals");
    const s = state.card && state.card.snapshot;
    if (!state.organizationId || !s || !state.kpiCode) {
      body.innerHTML = empty(5, state.organizationId ? "No snapshot yet." : "Select an organization."); totals.textContent = ""; state.itemPager?.clear(); return;
    }
    body.innerHTML = empty(5, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId, snapshotId: s.snapshotId, kpiCode: state.kpiCode,
      pageNumber: state.itemPager ? state.itemPager.page() : 1, pageSize: state.itemPager ? state.itemPager.size() : 25 });
    if (val("agvOutcome")) qs.set("outcome", val("agvOutcome"));
    if (val("agvSearch")) qs.set("search", val("agvSearch"));
    const res = await api("GET", `/items?${qs}`);
    if (!res.ok) { body.innerHTML = empty(5, res.error); state.itemPager?.clear(); return; }
    const d = res.data.data || {}, rows = d.rows || [];
    state.itemPager?.setTotal(d.totalRows, rows.length);
    const t = code => (d.totals || []).find(x => x.outcome === code) || { itemCount: 0, numerator: 0, denominator: 0 };
    const p = t("PASS"), f = t("FAIL"), x = t("EXCLUDED");
    totals.textContent = s.itemsPurged
      ? "Record detail of this snapshot has been removed (retention); the score above is kept."
      : `Numerator ${Number(p.numerator) + Number(f.numerator)} and denominator ${Number(p.denominator) + Number(f.denominator)} = `
        + `${p.itemCount} passing and ${f.itemCount} failing records; ${x.itemCount} excluded (not counted).`;
    body.innerHTML = rows.map(r => `
      <tr><td>${recordLink(r)}<div class="agv-note">${esc(KIND[r.recordKind] || r.recordKind)} #${esc(r.recordId)}</div></td>
          <td>${chip(OUTCOME, r.outcome)}</td><td>${esc(r.numerator)}</td><td>${esc(r.denominator)}</td>
          <td>${esc(r.reason || "")}</td></tr>`).join("")
      || empty(5, s.itemsPurged ? "Record detail removed (retention)." : "No record in this view.");
  }

  function recordLink(r) {
    if (r.recordKind !== "ASSET") return esc(r.recordName || "");
    const q = new URLSearchParams({ organizationId: state.organizationId, assetId: r.recordId });
    return `<a href="${esc(U(`/Practice/Index/asset-register?${q}`))}">${esc(r.recordName || "")}</a>`;
  }

  // ------------------------------------------------------------------ history
  async function refreshHistory() {
    const body = document.getElementById("agvHistory");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); state.historyPager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.historyPager ? state.historyPager.page() : 1, pageSize: state.historyPager ? state.historyPager.size() : 25 });
    const res = await api("GET", `/snapshots?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.historyPager?.clear(); return; }
    const d = res.data.data || {}, rows = d.rows || [];
    state.historyPager?.setTotal(d.totalRows, rows.length);
    body.innerHTML = rows.map(s => `
      <tr><td>${esc(date(s.asOfDate))}</td>
          <td>v${esc(s.versionNo)} ${s.isCurrent ? `<span class="agv-chip agv-rag-green">Current</span>` : `<span class="agv-chip agv-rag-na">Superseded</span>`}</td>
          <td>${esc(pct(s.overallScore))} ${chip(RAG, s.overallRag)}</td>
          <td>${esc(s.greenCount)} on target, ${esc(s.amberCount)} warning, ${esc(s.redCount)} below, ${esc(s.naCount)} n/a</td>
          <td>${esc(s.itemCount)}${s.itemsPurged ? `<div class="agv-note">detail removed</div>` : ""}</td>
          <td>${esc(dateTime(s.takenDt))}<div class="agv-note">${esc(s.takenBy)}${s.supersededDt ? `; superseded ${esc(dateTime(s.supersededDt))}` : ""}</div></td>
          <td>${esc(SOURCE[s.sourceCode] || s.sourceCode)}</td>
          <td><button class="pm-button" type="button" data-agv-snapshot="${esc(s.snapshotId)}">Open</button></td></tr>`).join("")
      || empty(8, "No snapshot yet.");
  }

  // ------------------------------------------------------------------ settings
  async function loadSettings() {
    const body = document.getElementById("agvSettings");
    if (!state.organizationId) { body.innerHTML = empty(9, "Select an organization."); document.getElementById("agvRules").innerHTML = ""; return; }
    const res = await api("GET", `/settings?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.settings = res.data.data || {};
    renderSettings();
  }

  function renderSettings() {
    const c = state.settings || {}, o = c.overall || {};
    const dis = CAN_EDIT ? "" : " disabled";
    document.getElementById("agvOTarget").value = o.overallTarget ?? 90;
    document.getElementById("agvOWarning").value = o.overallWarning ?? 75;
    document.getElementById("agvORetention").value = o.itemRetentionDays ?? 90;
    ["agvOTarget", "agvOWarning", "agvORetention"].forEach(id => { document.getElementById(id).disabled = !CAN_EDIT; });
    document.getElementById("agvSettings").innerHTML = (c.kpis || []).map(k => `
      <tr><td>${esc(k.kpiName)}<div class="agv-note">${esc(k.formulaText)}</div></td>
          <td>${k.direction === "LOWER" ? "Lower" : "Higher"}</td>
          <td><input type="checkbox" data-agv-en="${esc(k.kpiCode)}"${k.isEnabled ? " checked" : ""}${dis} /></td>
          <td><input type="number" min="0" max="100" step="1" data-agv-w="${esc(k.kpiCode)}" value="${esc(k.weight)}"${dis} /></td>
          <td><input type="number" min="0" max="100" step="0.1" data-agv-t="${esc(k.kpiCode)}" value="${esc(num(k.targetValue))}"${dis} /></td>
          <td><input type="number" min="0" max="100" step="0.1" data-agv-wv="${esc(k.kpiCode)}" value="${esc(num(k.warningValue))}"${dis} /></td>
          <td>${k.defaultPeriodDays == null ? "--" : `<input type="number" min="1" max="3650" step="1" data-agv-p="${esc(k.kpiCode)}" value="${esc(k.periodDays)}"${dis} />`}</td>
          <td><span class="agv-note">${esc(num(k.defaultTarget))} / ${esc(num(k.defaultWarning))}, weight ${esc(k.defaultWeight)}${k.defaultPeriodDays == null ? "" : `, ${esc(k.defaultPeriodDays)} days`}${k.isCustomised ? `; changed ${esc(dateTime(k.updatedDt))}` : ""}</span></td>
          <td>${CAN_EDIT ? `<button class="pm-button" type="button" data-agv-save="${esc(k.kpiCode)}">Save</button>${k.isCustomised ? ` <button class="pm-button" type="button" data-agv-reset="${esc(k.kpiCode)}">Default</button>` : ""}` : ""}</td></tr>`).join("");
    const svc = c.services || {};
    document.getElementById("agvRelNote").textContent = "Relationship Completeness counts the assets of each type below (Active, currently effective relationships of the kind required) and the business services in operation, which need "
      + `${svc.minSupportingRelationships ?? 1} supporting relationship(s) (Business Services settings). With no requirement and no service in operation the KPI is Not applicable.`;
    const typeSel = document.getElementById("agvRType"), relSel = document.getElementById("agvRRel");
    if (typeSel) typeSel.innerHTML = (c.assetTypes || []).map(t => `<option value="${esc(t.assetTypeId)}">${esc(t.assetTypeName)}</option>`).join("");
    if (relSel) { relSel.innerHTML = (c.relationshipTypes || []).map(r => `<option value="${esc(r.typeCode)}">${esc(r.typeName)} / ${esc(r.inverseLabel)}</option>`).join(""); fillSides(); }
    document.getElementById("agvRules").innerHTML = (c.relationshipRules || []).map(r => `
      <tr><td>${esc(r.assetTypeName)}</td>
          <td>${esc(r.assetSide === "SOURCE" ? r.typeName : r.inverseLabel)} <span class="agv-note">(${r.assetSide === "SOURCE" ? "asset is the source" : "asset is the target"})</span></td>
          <td><input type="number" min="1" max="50" step="1" data-agv-rmin="${esc(r.ruleId)}" value="${esc(r.minCount)}"${dis} /></td>
          <td><input type="checkbox" data-agv-ract="${esc(r.ruleId)}"${r.isActive ? " checked" : ""}${dis} /></td>
          <td>${esc(dateTime(r.updatedDt))}<div class="agv-note">${esc(r.updatedBy || "")}</div></td>
          <td>${CAN_EDIT ? `<button class="pm-button" type="button" data-agv-rule="${esc(r.ruleId)}">Save</button>` : ""}</td></tr>`).join("")
      || empty(6, "No relationship requirement.");
  }

  function fillSides() {
    const sideSel = document.getElementById("agvRSide");
    if (!sideSel) return;
    const r = ((state.settings && state.settings.relationshipTypes) || []).find(x => x.typeCode === val("agvRRel"));
    const opts = [];
    if (r && r.assetAsSource) opts.push(["SOURCE", `Asset ${r.typeName.toLowerCase()} ...`]);
    if (r && r.assetAsTarget) opts.push(["TARGET", `Asset ${r.inverseLabel.toLowerCase()} ...`]);
    sideSel.innerHTML = opts.map(([v, l]) => `<option value="${v}">${esc(l)}</option>`).join("");
  }

  async function saveOverall() {
    const res = await api("POST", "/settings/overall", {
      organizationId: state.organizationId, overallTarget: numOrNull("agvOTarget"), overallWarning: numOrNull("agvOWarning"),
      itemRetentionDays: numOrNull("agvORetention")
    });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    await loadSettings();
    showMessage("Overall settings saved; they apply from the next snapshot.", "success");
  }

  async function saveKpi(code, reset) {
    if (reset && !await window.gracUi.confirm("Return this KPI to its default thresholds, weight and period?")) return;
    const q = a => document.querySelector(`[data-agv-${a}="${code}"]`);
    const res = await api("POST", "/settings", reset ? { organizationId: state.organizationId, kpiCode: code, reset: true } : {
      organizationId: state.organizationId, kpiCode: code, reset: false, isEnabled: q("en").checked,
      weight: numOf(q("w")), targetValue: numOf(q("t")), warningValue: numOf(q("wv")), periodDays: q("p") ? numOf(q("p")) : null
    });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    await loadSettings();
    showMessage(reset ? "KPI back to its defaults." : "KPI settings saved; they apply from the next snapshot.", "success");
  }

  async function addRule() {
    const res = await api("POST", "/relationship-rules", {
      organizationId: state.organizationId, ruleId: null, assetTypeId: Number(val("agvRType")) || null,
      relationshipTypeCode: val("agvRRel") || null, assetSide: val("agvRSide") || null, minCount: numOrNull("agvRMin") ?? 1, isActive: true
    });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    await loadSettings();
    showMessage("Relationship requirement added; it applies from the next snapshot.", "success");
  }

  async function saveRule(id) {
    const res = await api("POST", "/relationship-rules", {
      organizationId: state.organizationId, ruleId: id,
      minCount: numOf(document.querySelector(`[data-agv-rmin="${id}"]`)) ?? 1,
      isActive: document.querySelector(`[data-agv-ract="${id}"]`).checked
    });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    await loadSettings();
    showMessage("Relationship requirement saved.", "success");
  }

  // ------------------------------------------------------------------ helpers
  async function api(method, path, body) {
    try {
      const r = await fetch(U(base + path), {
        method, credentials: "same-origin",
        headers: body ? { "Content-Type": "application/json" } : undefined,
        body: body ? JSON.stringify(body) : undefined
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok || data.success === false) {
        const hint = r.status === 404 && !data.error ? " -- the Asset Configuration API was not found; deploy the latest API and Web build" : "";
        return { ok: false, status: r.status, data, errorNumber: data.errorNumber, error: data.error || `Request failed (HTTP ${r.status})${hint}.` };
      }
      return { ok: true, status: r.status, data };
    } catch (err) { return { ok: false, status: 0, data: {}, error: err.message }; }
  }
  function chip(map, code) { const [l, c] = map[code] || [code || "--", "agv-rag-na"]; return `<span class="agv-chip ${c}">${esc(l)}</span>`; }
  function pct(v) { return v == null || v === "" ? "N/A" : `${Number(v).toFixed(1)}%`; }
  function num(v) { return v == null || v === "" ? "" : String(Number(v)); }
  function signed(v) { return isNaN(v) ? "--" : `${v > 0 ? "+" : ""}${v.toFixed(1)}`; }
  function change(now, prev, direction) {
    if (now == null || prev == null) return "";
    const d = Number(now) - Number(prev);
    if (!d) return ` <span title="Same as the previous date">=</span>`;
    const better = direction === "LOWER" ? d < 0 : d > 0;
    return ` <span title="Change from the previous date">${better ? "&#9650;" : "&#9660;"} ${esc(signed(d))}</span>`;
  }
  function thresholds(k) { return k.direction === "LOWER" ? `target <= ${num(k.targetValue)}, warning <= ${num(k.warningValue)}` : `target >= ${num(k.targetValue)}, warning >= ${num(k.warningValue)}`; }
  function numOf(el) { if (!el || el.value === "") return null; const n = Number(el.value); return isNaN(n) ? null : n; }
  function numOrNull(id) { return numOf(document.getElementById(id)); }
  function empty(cols, text) { return `<tr><td colspan="${cols}" class="pm-empty">${esc(text)}</td></tr>`; }
  function showMessage(text, kind) {
    const el = document.getElementById("agvMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.classList.toggle("info", kind === "info"); el.hidden = !text;
  }
  function hideMessage() { const el = document.getElementById("agvMessage"); el.hidden = true; el.textContent = ""; }
  function val(id) { const el = document.getElementById(id); return el ? (el.value || "").trim() : ""; }
  function date(v) { return v ? String(v).substring(0, 10) : ""; }   // SQL DATE values: yyyy-mm-dd
  function dateTime(v) { if (!v) return ""; const x = new Date(v); return isNaN(x) ? String(v) : x.toLocaleString(); }
  function esc(v) { return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
})();
