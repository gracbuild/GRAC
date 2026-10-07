// =====================================================================
// Asset Discovery (migration 442) -- BRD 5.6, 5.6.1-5.6.5.
// Loaded by asset-discovery.cshtml. Services: discovery/config,
// discovery/sources (save), discovery/sources/{id}/priorities,
// discovery/sources/{id}/batches (ingest), discovery/rules,
// discovery/settings, discovery/batches, discovery/batches/{id},
// discovery/exceptions, discovery/exceptions/{id}/resolve,
// discovery/confidence, discovery/assets/{id}; asset picker:
// relationships/ci-lookup (kind ASSET). The procedures hold every rule
// (matching, scores, precedence, outcomes); this screen shows them.
// 443: Register (new candidate / manual review) opens the Asset Register
// form for the exception (asset-register.js links it after the save);
// Stale assets: discovery/stale, discovery/stale/assets/{id},
// discovery/stale/settings, discovery/stale/reviews, .../{id}/action.
// 444: Merges -- discovery/merges, discovery/merges/{id}, discovery/merges
// (draft save), discovery/merges/{id}/action; a Potential duplicate opens a
// new merge of its two assets. Plan, blockers and every rule are SQL's.
// 445: Splits -- discovery/splits, discovery/splits/{id}, discovery/splits
// (draft with results and allocations), discovery/splits/{id}/action (the
// same action procedure as merges; the action buttons are shared).
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config";
  const root = document.getElementById("adcRoot");
  if (!root) return;
  const CAN_EDIT = root.dataset.canEdit === "1";
  const CAN_APPROVE = root.dataset.canApprove === "1";
  const MAX_RECORDS = 5000;   // sp_asset_discovery_ingest limit (54772)

  const SOURCE_TYPES = { DISCOVERY: "Discovery / CMDB", ENDPOINT: "Endpoint management", IDENTITY: "Identity / directory", CLOUD: "Cloud",
                         NETWORK: "Network", SECURITY: "Security", ERP: "ERP / finance", BIOMEDICAL: "Biomedical", FLEET: "Fleet", CUSTOM: "Custom" };
  const MODES = { POLLING: "Polling", WEBHOOK: "Webhook", BATCH: "Batch", FILE: "File", API: "API" };
  const HEALTH = { SUCCESS: ["Success", "adc-st-active"], WARNING: ["Warning", "adc-st-wait"], FAILED: ["Failed", "adc-st-bad"], NEVER: ["Never run", "adc-st-ended"] };
  const ROLES = { GOLDEN: "Golden", CONTRIBUTING: "Contributing", IGNORED: "Ignored" };
  const STRENGTH = { STRONG: ["Strong", "adc-st-active"], SUPPORTING: ["Supporting", "adc-st-open"], WEAK: ["Weak", "adc-st-ended"] };
  const BATCH = { RUNNING: ["Running", "adc-st-open"], COMPLETED: ["Completed", "adc-st-active"], PARTIAL: ["Partial", "adc-st-wait"], FAILED: ["Failed", "adc-st-bad"] };
  const OUTCOME = { UPDATED: ["Updated", "adc-st-active"], NO_CHANGE: ["No change", "adc-st-ended"], SUGGESTED: ["Suggested match", "adc-st-open"],
                    MANUAL_REVIEW: ["Manual review", "adc-st-wait"], NEW_CANDIDATE: ["New candidate", "adc-st-open"],
                    POTENTIAL_DUPLICATE: ["Potential duplicate", "adc-st-wait"], ERROR: ["Error", "adc-st-bad"] };
  const KIND = { SUGGESTED_MATCH: ["Suggested match", "adc-st-open"], MANUAL_REVIEW: ["Manual review", "adc-st-wait"],
                 NEW_CANDIDATE: ["New candidate", "adc-st-open"], DUPLICATE: ["Potential duplicate", "adc-st-wait"], CONFLICT: ["Conflict", "adc-st-bad"] };
  const CONFIDENCE = { CONFLICTING: ["Conflicting", "adc-st-bad"], STALE: ["Stale", "adc-st-wait"], VERIFIED: ["Verified", "adc-st-active"],
                       PROBABLE: ["Probable", "adc-st-open"], UNVERIFIED: ["Unverified", "adc-st-ended"] };
  // Actions sp_asset_reconciliation_resolve accepts per exception kind (54776).
  const ACTIONS = {
    SUGGESTED_MATCH: ["LINK", "IGNORE"], MANUAL_REVIEW: ["LINK", "IGNORE"], NEW_CANDIDATE: ["LINK", "IGNORE"],
    DUPLICATE: ["LINK", "NOT_DUPLICATE", "IGNORE"], CONFLICT: ["ACCEPT_OBSERVED", "KEEP_CURRENT"]
  };
  const ACTION_LABEL = { LINK: "Link to a register asset", IGNORE: "Ignore", NOT_DUPLICATE: "Not a duplicate", ACCEPT_OBSERVED: "Accept the observed value",
                         KEEP_CURRENT: "Keep the current value" };
  const NOTE_REQUIRED = ["IGNORE", "NOT_DUPLICATE", "KEEP_CURRENT"];   // 54778
  const RESOLUTION = { LINKED: "Linked", REGISTERED: "Registered as new asset", IGNORE: "Ignored", NOT_DUPLICATE: "Not a duplicate", ACCEPT_OBSERVED: "Observed value accepted", KEEP_CURRENT: "Current value kept" };

  const REVIEW = { OPEN: ["In review", "adc-st-open"], DISMISSED: ["Dismissed", "adc-st-ended"],
                   DECOMMISSION_REQUESTED: ["Decommission requested", "adc-st-wait"] };   // 443
  const MERGE = { DRAFT: ["Draft", "adc-st-ended"], PENDING_APPROVAL: ["Pending approval", "adc-st-wait"], APPROVED: ["Approved", "adc-st-open"],
                  EXECUTED: ["Executed", "adc-st-active"], RECOVERED: ["Recovered", "adc-st-wait"], REJECTED: ["Rejected", "adc-st-bad"],
                  CANCELLED: ["Cancelled", "adc-st-ended"] };   // 444
  const PLAN = { MOVE: ["Move", "adc-st-open"], END: ["End", "adc-st-wait"], RESOLVE: ["Resolve", "adc-st-active"], KEEP: ["Keep", "adc-st-ended"],
                 BLOCK: ["Blocked", "adc-st-bad"], MOVED: ["Moved", "adc-st-open"], ENDED: ["Ended", "adc-st-wait"], RESOLVED: ["Resolved", "adc-st-active"],
                 KEPT: ["Kept", "adc-st-ended"], FILLED: ["Filled", "adc-st-open"], REPLACED: ["Replaced", "adc-st-wait"], ALIASED: ["Alias", "adc-st-ended"],
                 ARCHIVED: ["Archived", "adc-st-ended"] };
  const OBJECT = { RELATIONSHIP: "Relationship", DISCOVERY_LINK: "Source record", ATTRIBUTE_SOURCE: "Source value", RECON_EXCEPTION: "Reconciliation",
                   COVERAGE: "Contract coverage", OCCURRENCE: "Activity", RESTRICTIVE_REVIEW: "Restrictive review", RISK_MAP: "Risk mapping",
                   RISK_LINK: "Risk link", PRACTICE_RESOLUTION: "Practice resolution", FIELD: "Field", ALIAS: "Alias", ASSET_RECORD: "Asset record" };
  const DEP_KIND = { RELATIONSHIP: "Relationship", CONTRACT: "Contract coverage", ACTIVITY: "Activity", WORKFLOW: "Workflow",
                     LIFECYCLE: "Lifecycle change", RECONCILIATION: "Reconciliation", RISK: "Risk" };
  const state = { organizationId: null, config: null, mainTab: "SOURCES", batPager: null, qPager: null, cPager: null, stPager: null, stale: null,
                  mgPager: null, merge: null, mergeDups: [], mergeChoices: {},   // 444
                  spPager: null, split: null, splitResults: [], splitAlloc: {},   // 445
                  source: null, priorities: [], rule: null, exception: null, queueAssetId: null, queueAssetName: "", assetId: null, batchRecords: [] };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    const g = window.__pmGrid;
    state.batPager = g ? g.attach({ hostId: "adcBatPager", onChange: refreshBatches }) : null;
    state.qPager = g ? g.attach({ hostId: "adcQPager", onChange: refreshQueue }) : null;
    state.cPager = g ? g.attach({ hostId: "adcCPager", onChange: refreshConfidence }) : null;
    state.stPager = g ? g.attach({ hostId: "adcStPager", onChange: refreshStale }) : null;
    state.mgPager = g ? g.attach({ hostId: "adcMgPager", onChange: refreshMerges }) : null;
    state.spPager = g ? g.attach({ hostId: "adcSpPager", onChange: refreshSplits }) : null;
    const opts = (map, pick) => Object.entries(map).map(([k, l]) => `<option value="${k}">${esc(pick ? pick(l) : l)}</option>`).join("");
    document.getElementById("adcSType").innerHTML = opts(SOURCE_TYPES);
    document.getElementById("adcSMode").innerHTML = opts(MODES);
    document.getElementById("adcQKind").insertAdjacentHTML("beforeend", opts(KIND, l => l[0]));
    document.getElementById("adcCStatus").insertAdjacentHTML("beforeend", opts(CONFIDENCE, l => l[0]));
    bind();
    formatHint();
    await populateOrgs();
    const sel = document.getElementById("adcOrg");
    window.gracOrgPref.apply(sel);   // 2026-10-06: last-picked org, else lowest id
    // 451: opened from the Asset & Contract dashboard -- organization, tab and filter (Shared/dashboard-drill.js).
    const dashDrill = window.__pmDrill ? window.__pmDrill.read() : null;
    window.__pmDrill?.preselectFor(dashDrill, sel, { QUEUE: { kind: "adcQKind" }, CONFIDENCE: { status: "adcCStatus" } });
    await changeOrg(Number(sel.value) || null);
    window.__pmDrill?.showOnPage("adcRoot", "data-adc-main", dashDrill);
  }

  async function populateOrgs() {
    const sel = document.getElementById("adcOrg");
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
    document.getElementById("adcOrg").addEventListener("change", e => changeOrg(Number(e.target.value) || null));
    document.querySelectorAll("[data-adc-main]").forEach(b => b.addEventListener("click", () => selectMainTab(b.dataset.adcMain)));
    document.querySelectorAll("[data-close-adc]").forEach(b => b.addEventListener("click", () => { document.getElementById(b.dataset.closeAdc).hidden = true; }));
    // sources
    document.getElementById("adcSrcAdd")?.addEventListener("click", () => openSource(null));
    document.getElementById("adcSrcBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-adc-src]");
      if (b) openSource(Number(b.dataset.adcSrc));
    });
    document.getElementById("adcSrcForm").addEventListener("submit", ev => { ev.preventDefault(); saveSource(); });
    document.getElementById("adcPrioAdd").addEventListener("click", addPriority);
    document.getElementById("adcPrioSave").addEventListener("click", savePriorities);
    document.getElementById("adcPrioBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-adc-prio-remove]");
      if (b) { state.priorities.splice(Number(b.dataset.adcPrioRemove), 1); renderPriorities(); }
    });
    document.getElementById("adcPrioBody").addEventListener("change", ev => {
      const x = ev.target.closest("[data-adc-prio-edit]");
      if (!x) return;
      const row = state.priorities[Number(x.dataset.adcPrioEdit)];
      if (x.tagName === "SELECT") row.sourceRole = x.value; else row.priority = Number(x.value) || null;
    });
    // rules
    document.getElementById("adcRuleAdd")?.addEventListener("click", () => openRule(null));
    document.getElementById("adcRuleBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-adc-rule]");
      if (b) openRule(Number(b.dataset.adcRule));
    });
    document.getElementById("adcRKeyPick").addEventListener("change", ev => {
      const k = ev.target.value;
      if (!k) return;
      const keys = splitKeys(val("adcRKeys"));
      if (!keys.includes(k)) keys.push(k);
      document.getElementById("adcRKeys").value = keys.join(",");
      ev.target.value = "";
    });
    document.getElementById("adcRuleForm").addEventListener("submit", ev => { ev.preventDefault(); saveRule(); });
    // import and batches
    document.getElementById("adcImpForm")?.addEventListener("submit", ev => { ev.preventDefault(); runImport(); });
    document.getElementById("adcImpFormat")?.addEventListener("change", formatHint);
    document.getElementById("adcImpFile")?.addEventListener("change", readImportFile);
    document.getElementById("adcBatSource").addEventListener("change", () => { state.batPager?.reset(true); refreshBatches(); });
    document.getElementById("adcBatBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-adc-batch]");
      if (b) openBatch(Number(b.dataset.adcBatch));
    });
    document.getElementById("adcBmBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-adc-payload]");
      if (!b) return;
      const rec = state.batchRecords[Number(b.dataset.adcPayload)];
      const pre = document.getElementById("adcBmPayload");
      pre.textContent = pretty(rec && rec.payloadJson) || "The observed values are past the raw payload retention.";
      pre.hidden = false;
    });
    // queue
    let tq = null, tc = null;
    ["adcQStatus", "adcQKind", "adcQSource"].forEach(id => document.getElementById(id).addEventListener("change", () => { state.qPager?.reset(true); refreshQueue(); }));
    document.getElementById("adcQSearch").addEventListener("input", () => { clearTimeout(tq); tq = setTimeout(() => { state.qPager?.reset(true); refreshQueue(); }, 300); });
    document.getElementById("adcQAssetClear").addEventListener("click", () => { setQueueAsset(null, ""); state.qPager?.reset(true); refreshQueue(); });
    document.getElementById("adcQBody").addEventListener("click", ev => {
      const g = ev.target.closest("button[data-adc-register]");   // 443
      if (g) { registerCandidate(Number(g.dataset.adcRegister)); return; }
      const mg = ev.target.closest("button[data-adc-merge-pair]");   // 444
      if (mg) { const [s, d] = mg.dataset.adcMergePair.split(":").map(Number); openMergeNew(s, [d]); return; }
      const r = ev.target.closest("button[data-adc-resolve]");
      if (r) { openResolve(Number(r.dataset.adcResolve)); return; }
      const a = ev.target.closest("button[data-adc-asset]");
      if (a) openAsset(Number(a.dataset.adcAsset));
    });
    document.getElementById("adcRsAction").addEventListener("change", resolveLayout);
    document.getElementById("adcResForm").addEventListener("submit", ev => { ev.preventDefault(); saveResolve(); });
    let ta = null;
    document.getElementById("adcRsSearch").addEventListener("input", () => { clearTimeout(ta); ta = setTimeout(loadAssetOptions, 300); });
    // confidence
    document.getElementById("adcCStatus").addEventListener("change", () => { state.cPager?.reset(true); refreshConfidence(); });
    document.getElementById("adcCSearch").addEventListener("input", () => { clearTimeout(tc); tc = setTimeout(() => { state.cPager?.reset(true); refreshConfidence(); }, 300); });
    document.getElementById("adcCBody").addEventListener("click", ev => {
      const a = ev.target.closest("button[data-adc-asset]");
      if (a) openAsset(Number(a.dataset.adcAsset));
    });
    document.getElementById("adcAmQueue").addEventListener("click", () => {
      document.getElementById("adcAssetModal").hidden = true;
      setQueueAsset(state.assetId, document.getElementById("adcAmTitle").textContent);
      document.getElementById("adcQStatus").value = "ALL";
      state.qPager?.reset(true);
      selectMainTab("QUEUE");
    });
    // merges (444)
    let tm = null;
    document.getElementById("adcMgStatus").addEventListener("change", () => { state.mgPager?.reset(true); refreshMerges(); });
    document.getElementById("adcMgSearch").addEventListener("input", () => { clearTimeout(tm); tm = setTimeout(() => { state.mgPager?.reset(true); refreshMerges(); }, 300); });
    document.getElementById("adcMgNew")?.addEventListener("click", () => openMergeNew(null, []));
    document.getElementById("adcMgBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-adc-merge]");
      if (b) openMerge(Number(b.dataset.adcMerge));
    });
    let tsv = null, tdp = null;
    document.getElementById("adcMgSurvSearch").addEventListener("input", () => { clearTimeout(tsv); tsv = setTimeout(() => fillAssetPicker("adcMgSurvSearch", "adcMgSurv"), 300); });
    document.getElementById("adcMgDupSearch").addEventListener("input", () => { clearTimeout(tdp); tdp = setTimeout(() => fillAssetPicker("adcMgDupSearch", "adcMgDupSel"), 300); });
    document.getElementById("adcMgDupAdd").addEventListener("click", addMergeDuplicate);
    document.getElementById("adcMgDupBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-adc-dup-remove]");
      if (b) { state.mergeDups.splice(Number(b.dataset.adcDupRemove), 1); renderMergeDups(); }
    });
    document.getElementById("adcMgForm").addEventListener("submit", ev => { ev.preventDefault(); saveMerge(); });
    document.getElementById("adcMgActions").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-adc-merge-action]");
      if (b) mergeAction(b.dataset.adcMergeAction);
    });
    document.getElementById("adcMgFieldBody").addEventListener("change", ev => {
      const c = ev.target.closest("input[data-adc-choice]");
      if (!c) return;
      const [key, asset] = [c.dataset.adcChoice, Number(c.value)];
      if (c.checked) {
        state.mergeChoices[key] = asset;
        document.querySelectorAll(`#adcMgFieldBody input[data-adc-choice]`).forEach(o => { if (o !== c && o.dataset.adcChoice === key) o.checked = false; });
      } else delete state.mergeChoices[key];
    });
    // splits (445)
    let tsp = null;
    document.getElementById("adcSpStatus").addEventListener("change", () => { state.spPager?.reset(true); refreshSplits(); });
    document.getElementById("adcSpSearch").addEventListener("input", () => { clearTimeout(tsp); tsp = setTimeout(() => { state.spPager?.reset(true); refreshSplits(); }, 300); });
    document.getElementById("adcSpNew")?.addEventListener("click", () => openSplitNew());
    document.getElementById("adcSpBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-adc-split]");
      if (b) openSplit(Number(b.dataset.adcSplit));
    });
    let tss = null, tsr = null;
    document.getElementById("adcSpSrcSearch").addEventListener("input", () => { clearTimeout(tss); tss = setTimeout(() => fillAssetPicker("adcSpSrcSearch", "adcSpSrc", null, "adcSpMessage"), 300); });
    document.getElementById("adcSpResSearch").addEventListener("input", () => { clearTimeout(tsr); tsr = setTimeout(() => fillAssetPicker("adcSpResSearch", "adcSpResSel", null, "adcSpMessage"), 300); });
    document.getElementById("adcSpResAdd").addEventListener("click", addSplitResult);
    document.getElementById("adcSpRegister").addEventListener("click", () => window.open(U("/Practice/Index/asset-register"), "_blank"));
    document.getElementById("adcSpResBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-adc-res-remove]");
      if (b) { state.splitResults.splice(Number(b.dataset.adcResRemove), 1); renderSplitResults(); }
    });
    document.getElementById("adcSpForm").addEventListener("submit", ev => { ev.preventDefault(); saveSplit(); });
    document.getElementById("adcSpActions").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-adc-split-action]");
      if (b) splitAction(b.dataset.adcSplitAction);
    });
    document.getElementById("adcSpAllocBody").addEventListener("change", ev => {
      const x = ev.target.closest("[data-adc-alloc]");
      if (!x) return;
      const key = x.dataset.adcAlloc, row = state.splitAlloc[key] || (state.splitAlloc[key] = JSON.parse(x.dataset.adcItem));
      const modeSel = x.closest("tr").querySelector("[data-adc-alloc-mode]");
      if (x.dataset.adcAllocMode === undefined) row.targetAssetId = Number(x.value) || null;
      row.fieldMode = modeSel ? modeSel.value : null;
      if (!row.targetAssetId) delete state.splitAlloc[key];
    });
    // stale assets (443)
    let ts = null;
    document.getElementById("adcStView").addEventListener("change", () => { state.stPager?.reset(true); refreshStale(); });
    document.getElementById("adcStSearch").addEventListener("input", () => { clearTimeout(ts); ts = setTimeout(() => { state.stPager?.reset(true); refreshStale(); }, 300); });
    document.getElementById("adcStDaysSave")?.addEventListener("click", saveStaleRule);
    document.getElementById("adcStBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-adc-stale]");
      if (b) openStale(Number(b.dataset.adcStale));
    });
    document.getElementById("adcSrStart").addEventListener("click", startStaleReview);
    document.getElementById("adcSrSourceForm").addEventListener("submit", ev => { ev.preventDefault(); staleAction("CONFIRM_SOURCE", "adcSrSourceNote"); });
    document.getElementById("adcSrDepForm").addEventListener("submit", ev => { ev.preventDefault(); staleAction("REVIEW_DEPENDENCIES", "adcSrDepNote"); });
    document.getElementById("adcSrDecisionForm").addEventListener("submit", ev => ev.preventDefault());
    document.getElementById("adcSrDismiss").addEventListener("click", () => staleAction("DISMISS", "adcSrDecisionNote"));
    document.getElementById("adcSrDecom").addEventListener("click", () => staleAction("REQUEST_DECOMMISSION", "adcSrDecisionNote"));
    // settings
    document.getElementById("adcSetForm").addEventListener("submit", ev => { ev.preventDefault(); saveSettings(); });
  }

  async function changeOrg(id) {
    state.organizationId = id;
    state.config = null;
    hideMessage();
    setQueueAsset(null, "");
    [state.batPager, state.qPager, state.cPager, state.stPager, state.mgPager, state.spPager].forEach(p => p?.reset(true));
    if (id) await loadConfig();
    await selectMainTab(state.mainTab);
  }

  async function loadConfig() {
    const res = await api("GET", `/discovery/config?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.config = res.data.data;
    const c = state.config, opt = (v, l) => `<option value="${esc(v)}">${esc(l)}</option>`;
    document.getElementById("adcSOwner").innerHTML = opt("", "--") + c.employees.map(e => opt(e.employeeId, e.employeeName)).join("");
    const sources = c.sources.map(s => opt(s.sourceId, s.sourceName + (s.isActive ? "" : " (inactive)"))).join("");
    document.getElementById("adcBatSource").innerHTML = opt("", "All sources") + sources;
    document.getElementById("adcQSource").innerHTML = opt("", "All sources") + sources;
    const imp = document.getElementById("adcImpSource");
    if (imp) imp.innerHTML = opt("", "--") + c.sources.filter(s => s.isActive).map(s => opt(s.sourceId, s.sourceName)).join("");
    const fields = c.fields.map(f => opt(f.fieldKey, `${f.fieldLabel} (${f.fieldKey})`)).join("");
    document.getElementById("adcPrioField").innerHTML = fields;
    document.getElementById("adcRKeyPick").innerHTML = opt("", "--") + opt("@source_key", "Source record ID (@source_key)") + fields;
    const st = c.settings || {};
    document.getElementById("adcSetAuto").value = st.autoMatchScore ?? 90;
    document.getElementById("adcSetSug").value = st.suggestedScore ?? 70;
    document.getElementById("adcSetMan").value = st.manualReviewScore ?? 40;
    document.getElementById("adcSetStale").value = st.staleMultiplier ?? 3;
    document.getElementById("adcSetVerify").value = st.verificationDays ?? 365;
    document.getElementById("adcSetTasks").checked = st.createConflictTasks ?? true;
    document.getElementById("adcRuleVersion").textContent = st.ruleSetVersion ?? "--";
    document.querySelectorAll("#adcSetForm input").forEach(x => { x.disabled = !CAN_EDIT; });
  }

  async function selectMainTab(name) {
    state.mainTab = name;
    document.querySelectorAll("[data-adc-main]").forEach(x => { const on = x.dataset.adcMain === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    document.querySelectorAll("[data-adc-mainpanel]").forEach(p => { p.hidden = p.dataset.adcMainpanel !== name; });
    if (name === "SOURCES") renderSources();
    else if (name === "RULES") renderRules();
    else if (name === "IMPORT") await refreshBatches();
    else if (name === "QUEUE") await refreshQueue();
    else if (name === "CONFIDENCE") await refreshConfidence();
    else if (name === "STALE") await refreshStale();
    else if (name === "MERGES") await refreshMerges();
    else if (name === "SPLITS") await refreshSplits();
  }

  // ------------------------------------------------------------------ sources
  function renderSources() {
    const body = document.getElementById("adcSrcBody");
    if (!state.organizationId || !state.config) { body.innerHTML = empty(9, "Select an organization."); return; }
    body.innerHTML = state.config.sources.map(s => {
      const [hl, hc] = HEALTH[s.healthStatus] || [s.healthStatus, ""];
      return `<tr><td><button class="pm-link-button" type="button" data-adc-src="${s.sourceId}">${esc(s.sourceName)}</button>
          <div class="adc-note">${esc(s.sourceCode)}${s.mappingVersion ? " - mapping " + esc(s.mappingVersion) : ""}${s.isActive ? "" : ' - <span class="adc-chip adc-st-ended">Inactive</span>'}</div></td>
        <td>${esc(SOURCE_TYPES[s.sourceType] || s.sourceType)}<div class="adc-note">${esc(MODES[s.collectionMode] || s.collectionMode)}</div></td>
        <td>${esc(s.trustLevel)}</td><td>${esc(s.expectedIntervalHours)}</td>
        <td><span class="adc-chip ${hc}">${esc(hl)}</span></td>
        <td>${esc(dateTime(s.lastRunDt) || "--")}${s.lastRunStatus ? `<div class="adc-note">${esc(label(s.lastRunStatus))}</div>` : ""}</td>
        <td>${esc(dateTime(s.nextRunDueDt) || "--")}</td><td>${esc(s.linkCount)}</td><td>${esc(s.ownerName || "--")}</td></tr>`;
    }).join("") || empty(9, CAN_EDIT ? "No sources. Add the first one with New source." : "No sources.");
  }

  function openSource(id) {
    const s = id ? state.config.sources.find(x => x.sourceId === id) : null;
    state.source = s;
    hide("adcSmMessage");
    document.getElementById("adcSmTitle").textContent = s ? s.sourceName : "New discovery source";
    const set = (fid, v) => { document.getElementById(fid).value = v ?? ""; };
    set("adcSCode", s?.sourceCode); set("adcSName", s?.sourceName); set("adcSType", s?.sourceType ?? "DISCOVERY");
    set("adcSMode", s?.collectionMode ?? "BATCH"); set("adcSScope", s?.scopeText); set("adcSMapping", s?.mappingVersion);
    set("adcSOwner", s?.ownerEmployeeId); set("adcSCred", s?.credentialReference); set("adcSTrust", s?.trustLevel ?? 80);
    set("adcSInterval", s?.expectedIntervalHours ?? 24); set("adcSRaw", s?.rawRetentionDays ?? 90); set("adcSObs", s?.observationRetentionDays ?? 365);
    document.getElementById("adcSActive").checked = s ? !!s.isActive : true;
    document.querySelectorAll("#adcSrcForm input, #adcSrcForm select").forEach(x => { x.disabled = !CAN_EDIT; });
    document.getElementById("adcSrcSaveBar").hidden = !CAN_EDIT;
    state.priorities = s ? state.config.priorities.filter(p => p.sourceId === s.sourceId)
      .map(p => ({ fieldKey: p.fieldKey, fieldLabel: p.fieldLabel, sourceRole: p.sourceRole, priority: p.priority })) : [];
    document.getElementById("adcPrioWrap").hidden = !s;
    document.getElementById("adcPrioAddBar").hidden = !CAN_EDIT;
    renderPriorities();
    document.getElementById("adcSrcModal").hidden = false;
  }

  async function saveSource() {
    const s = state.source;
    const res = await api("POST", "/discovery/sources", {
      organizationId: state.organizationId, sourceId: s ? s.sourceId : null, sourceCode: val("adcSCode"), sourceName: val("adcSName"),
      sourceType: val("adcSType"), collectionMode: val("adcSMode"), scopeText: val("adcSScope"), mappingVersion: val("adcSMapping"),
      ownerEmployeeId: num("adcSOwner"), credentialReference: val("adcSCred"), trustLevel: num("adcSTrust"),
      expectedIntervalHours: num("adcSInterval"), rawRetentionDays: num("adcSRaw"), observationRetentionDays: num("adcSObs"),
      isActive: document.getElementById("adcSActive").checked, expectedRecordVersion: s ? s.recordVersion : null
    });
    if (!res.ok) { show("adcSmMessage", res.error); return; }
    await loadConfig();
    renderSources();
    openSource(res.data.id || (s && s.sourceId));
    show("adcSmMessage", s ? "Source saved." : "Source added. Set its field precedence below.", "success");
  }

  function renderPriorities() {
    const body = document.getElementById("adcPrioBody");
    const fields = state.config ? state.config.fields : [];
    body.innerHTML = state.priorities.map((p, i) => {
      const f = fields.find(x => x.fieldKey === p.fieldKey);
      const roleSel = `<select data-adc-prio-edit="${i}" ${CAN_EDIT ? "" : "disabled"}>${Object.entries(ROLES).map(([k, l]) => `<option value="${k}" ${k === p.sourceRole ? "selected" : ""}>${esc(l)}</option>`).join("")}</select>`;
      return `<tr><td>${esc(p.fieldLabel || (f && f.fieldLabel) || p.fieldKey)}<div class="adc-note">${esc(p.fieldKey)}${f && !f.isWritable ? " - recorded only, never written" : ""}</div></td>
        <td>${roleSel}</td><td><input type="number" min="1" max="999" value="${esc(p.priority ?? "")}" data-adc-prio-edit="${i}" ${CAN_EDIT ? "" : "disabled"} /></td>
        <td>${CAN_EDIT ? `<button class="pm-link-button" type="button" data-adc-prio-remove="${i}">Remove</button>` : ""}</td></tr>`;
    }).join("") || empty(4, "No entries: every field is contributing.");
  }

  function addPriority() {
    const key = val("adcPrioField");
    if (!key) return;
    if (state.priorities.some(p => p.fieldKey === key)) { show("adcSmMessage", "That field is already listed; change its role or priority in the table."); return; }
    const f = state.config.fields.find(x => x.fieldKey === key);
    state.priorities.push({ fieldKey: key, fieldLabel: f ? f.fieldLabel : key, sourceRole: val("adcPrioRole"), priority: num("adcPrioPriority") ?? 100 });
    hide("adcSmMessage");
    renderPriorities();
  }

  async function savePriorities() {
    if (!state.source) return;
    const res = await api("POST", `/discovery/sources/${state.source.sourceId}/priorities`, {
      organizationId: state.organizationId,
      priorities: state.priorities.map(p => ({ fieldKey: p.fieldKey, sourceRole: p.sourceRole, priority: p.priority }))
    });
    if (!res.ok) { show("adcSmMessage", res.error); return; }
    await loadConfig();
    openSource(state.source.sourceId);
    show("adcSmMessage", "Field precedence saved.", "success");
  }

  // ------------------------------------------------------------------ identification rules
  function renderRules() {
    const body = document.getElementById("adcRuleBody");
    if (!state.organizationId || !state.config) { body.innerHTML = empty(6, "Select an organization."); return; }
    const fields = state.config.fields;
    const keyLabel = k => k === "@source_key" ? "Source record ID" : ((fields.find(f => f.fieldKey === k) || {}).fieldLabel || k);
    body.innerHTML = state.config.rules.map(r => {
      const [sl, sc] = STRENGTH[r.strength] || [r.strength, ""];
      const name = CAN_EDIT ? `<button class="pm-link-button" type="button" data-adc-rule="${r.ruleId}">${esc(r.ruleName)}</button>` : esc(r.ruleName);
      return `<tr><td>${esc(r.displayOrder)}</td><td>${name}</td><td>${splitKeys(r.attributeKeys).map(k => esc(keyLabel(k))).join(" + ")}<div class="adc-note">${esc(r.attributeKeys)}</div></td>
        <td><span class="adc-chip ${sc}">${esc(sl)}</span></td><td>${esc(r.weight)}</td><td>${r.isActive ? "Yes" : "No"}</td></tr>`;
    }).join("") || empty(6, "No rules.");
  }

  function openRule(id) {
    const r = id ? state.config.rules.find(x => x.ruleId === id) : null;
    state.rule = r;
    hide("adcRmMessage");
    document.getElementById("adcRmTitle").textContent = r ? r.ruleName : "New identification rule";
    document.getElementById("adcRName").value = r?.ruleName ?? "";
    document.getElementById("adcRKeys").value = r?.attributeKeys ?? "";
    document.getElementById("adcRStrength").value = r?.strength ?? "SUPPORTING";
    document.getElementById("adcRWeight").value = r?.weight ?? 50;
    document.getElementById("adcROrder").value = r?.displayOrder ?? 100;
    document.getElementById("adcRActive").checked = r ? !!r.isActive : true;
    document.getElementById("adcRuleModal").hidden = false;
  }

  async function saveRule() {
    const r = state.rule;
    const res = await api("POST", "/discovery/rules", {
      organizationId: state.organizationId, ruleId: r ? r.ruleId : null, ruleName: val("adcRName"),
      attributeKeys: splitKeys(val("adcRKeys")).join(","), strength: val("adcRStrength"), weight: num("adcRWeight"),
      isActive: document.getElementById("adcRActive").checked, displayOrder: num("adcROrder")
    });
    if (!res.ok) { show("adcRmMessage", res.error); return; }
    document.getElementById("adcRuleModal").hidden = true;
    await loadConfig();
    renderRules();
    showMessage("Identification rule saved; the rule-set version was raised.", "success");
  }

  // ------------------------------------------------------------------ import
  function formatHint() {
    const el = document.getElementById("adcImpHint");
    if (!el) return;
    el.textContent = val("adcImpFormat") === "CSV"
      ? `CSV with a header row: an "externalKey" column (the record ID in the source), an optional "observedAt" column (ISO date-time) and one column per dictionary field key, e.g. externalKey,serial_number,hostname,ip_address. At most ${MAX_RECORDS} records.`
      : `JSON array: [{"externalKey":"dev-1","observedAt":"2026-10-05T10:00:00Z","attributes":{"serial_number":"SN-1","hostname":"srv1"}}]. Attribute names are dictionary field keys. At most ${MAX_RECORDS} records.`;
    const ref = document.getElementById("adcImpRef");
    if (ref && !ref.value) ref.value = "UI-" + new Date().toISOString().replace(/[-:T]/g, "").substring(0, 14);
  }

  function readImportFile(ev) {
    const file = ev.target.files && ev.target.files[0];
    if (!file) return;
    if (/\.csv$/i.test(file.name)) document.getElementById("adcImpFormat").value = "CSV";
    else if (/\.json$/i.test(file.name)) document.getElementById("adcImpFormat").value = "JSON";
    document.getElementById("adcImpChannel").value = "IMPORT";
    const ref = document.getElementById("adcImpRef");
    ref.value = file.name.replace(/\.[^.]+$/, "").substring(0, 100);
    const reader = new FileReader();
    reader.onload = () => { document.getElementById("adcImpText").value = String(reader.result || ""); formatHint(); };
    reader.readAsText(file);
  }

  // Records as the ingest procedure expects them; null + message on a format error.
  function parseRecords() {
    const text = document.getElementById("adcImpText").value.trim();
    if (!text) return { error: "Paste or choose the records." };
    if (val("adcImpFormat") === "JSON") {
      let data;
      try { data = JSON.parse(text); } catch (e) { return { error: "The records are not valid JSON: " + e.message }; }
      if (!Array.isArray(data)) return { error: "The records must be a JSON array." };
      return { records: data };
    }
    const rows = parseCsv(text).filter(r => r.some(c => c.trim() !== ""));
    if (rows.length < 2) return { error: "The CSV needs a header row and at least one record." };
    const head = rows[0].map(h => h.trim());
    const keyCol = head.findIndex(h => /^external_?key$/i.test(h));
    const atCol = head.findIndex(h => /^observed_?at$/i.test(h));
    return { records: rows.slice(1).map(r => {
      const attributes = {};
      head.forEach((h, i) => { if (i !== keyCol && i !== atCol && h && (r[i] ?? "").trim() !== "") attributes[h] = r[i].trim(); });
      const rec = { attributes };
      if (keyCol >= 0 && (r[keyCol] ?? "").trim()) rec.externalKey = r[keyCol].trim();
      if (atCol >= 0 && (r[atCol] ?? "").trim()) rec.observedAt = r[atCol].trim();
      return rec;
    }) };
  }

  // RFC 4180 style: quoted fields, doubled quotes, commas and line breaks inside quotes.
  function parseCsv(text) {
    const rows = []; let row = [], cell = "", q = false;
    for (let i = 0; i < text.length; i++) {
      const ch = text[i];
      if (q) {
        if (ch === '"' && text[i + 1] === '"') { cell += '"'; i++; }
        else if (ch === '"') q = false;
        else cell += ch;
      } else if (ch === '"') q = true;
      else if (ch === ",") { row.push(cell); cell = ""; }
      else if (ch === "\n" || ch === "\r") {
        if (ch === "\r" && text[i + 1] === "\n") i++;
        row.push(cell); rows.push(row); row = []; cell = "";
      } else cell += ch;
    }
    row.push(cell); rows.push(row);
    return rows;
  }

  async function runImport() {
    const sourceId = num("adcImpSource");
    if (!sourceId) { showMessage("Select the source."); return; }
    const parsed = parseRecords();
    if (parsed.error) { showMessage(parsed.error); return; }
    if (parsed.records.length > MAX_RECORDS) { showMessage(`A batch holds at most ${MAX_RECORDS} records; split it.`); return; }
    const btn = document.getElementById("adcImpRun");
    btn.disabled = true;
    showMessage(`Importing ${parsed.records.length} record(s)...`, "info");
    const res = await api("POST", `/discovery/sources/${sourceId}/batches`, {
      organizationId: state.organizationId, batchReference: val("adcImpRef"), channel: val("adcImpChannel"), records: parsed.records
    });
    btn.disabled = false;
    if (!res.ok) { showMessage(res.error); return; }
    const b = res.data.data.batch || {}, recs = res.data.data.records || [];
    renderBatchSummary("adcImpSummary", b);
    document.getElementById("adcImpResultRef").textContent = b.batchReference || "";
    document.getElementById("adcImpResultBody").innerHTML = recs.map(r => {
      const [ol, oc] = OUTCOME[r.outcome] || [r.outcome || "--", ""];
      return `<tr><td>${esc(r.recordNo)}</td><td>${esc(r.externalKey || "--")}</td><td><span class="adc-chip ${oc}">${esc(ol)}</span></td>
        <td>${esc(r.matchScore ?? "--")}</td><td>${esc(r.matchedAssetName || "--")}</td><td>${esc(r.matchedRules || "--")}</td><td>${esc(r.resultText || "")}</td></tr>`;
    }).join("") || empty(7, "No records.");
    document.getElementById("adcImpResultWrap").hidden = false;
    const repeat = !!b.isRepeat;
    showMessage(repeat ? "This batch reference was imported before; its earlier result is shown and nothing was processed again."
                       : `Batch ${b.batchReference}: ${label(b.status)}.`, repeat ? "info" : "success");
    document.getElementById("adcImpRef").value = "";
    formatHint();
    await loadConfig();
    state.batPager?.reset(true);
    await refreshBatches();
  }

  function renderBatchSummary(hostId, b) {
    const [bl, bc] = BATCH[b.status] || [b.status, ""];
    document.getElementById(hostId).innerHTML =
      `<div><span>Status</span><span class="adc-chip ${bc}">${esc(bl)}</span></div>
       <div><span>Records</span>${esc(b.recordCount)}</div>
       <div><span>Updated / no change</span>${esc(b.updatedCount)} / ${esc(b.noChangeCount)}</div>
       <div><span>Exceptions / errors</span>${esc(b.exceptionCount)} / ${esc(b.errorCount)}</div>
       <div><span>Rule-set version</span>${esc(b.ruleSetVersion)}</div>
       <div><span>Received / completed</span>${esc(dateTime(b.receivedDt))}<br />${esc(dateTime(b.completedDt) || "--")}</div>`;
  }

  // ------------------------------------------------------------------ batches
  async function refreshBatches() {
    const body = document.getElementById("adcBatBody");
    if (!state.organizationId) { body.innerHTML = empty(9, "Select an organization."); state.batPager?.clear(); return; }
    body.innerHTML = empty(9, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.batPager ? state.batPager.page() : 1, pageSize: state.batPager ? state.batPager.size() : 25 });
    if (val("adcBatSource")) qs.set("sourceId", val("adcBatSource"));
    const res = await api("GET", `/discovery/batches?${qs}`);
    if (!res.ok) { body.innerHTML = empty(9, res.error); state.batPager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.batPager?.setTotal(res.data.data.totalRows, rows.length);
    body.innerHTML = rows.map(b => {
      const [bl, bc] = BATCH[b.status] || [b.status, ""];
      return `<tr><td><button class="pm-link-button" type="button" data-adc-batch="${b.batchId}">${esc(b.batchReference)}</button></td>
        <td>${esc(b.sourceName)}</td><td>${esc(label(b.channel))}</td><td><span class="adc-chip ${bc}">${esc(bl)}</span></td><td>${esc(b.recordCount)}</td>
        <td>${esc(b.updatedCount)} / ${esc(b.noChangeCount)}</td><td>${esc(b.exceptionCount)} / ${esc(b.errorCount)}</td><td>${esc(b.ruleSetVersion)}</td>
        <td>${esc(dateTime(b.receivedDt))}<div class="adc-note">${esc(b.enteredBy || "")}</div></td></tr>`;
    }).join("") || empty(9, "No batches.");
  }

  async function openBatch(id) {
    const res = await api("GET", `/discovery/batches/${id}?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error); return; }
    const b = res.data.data.batch, recs = res.data.data.records || [];
    state.batchRecords = recs;
    document.getElementById("adcBmTitle").textContent = `Batch ${b.batchReference} - ${b.sourceName}`;
    renderBatchSummary("adcBmInfo", b);
    document.getElementById("adcBmPayload").hidden = true;
    document.getElementById("adcBmBody").innerHTML = recs.map((r, i) => {
      const [ol, oc] = OUTCOME[r.outcome] || [r.outcome || "--", ""];
      const asset = r.matchedAssetName ? esc(r.matchedAssetName) + (r.secondAssetName ? `<div class="adc-note">or ${esc(r.secondAssetName)} (${esc(r.secondScore)})</div>` : "") : "--";
      return `<tr><td>${esc(r.recordNo)}</td><td>${esc(r.externalKey || "--")}</td><td>${esc(dateTime(r.observedDt))}</td><td><span class="adc-chip ${oc}">${esc(ol)}</span></td>
        <td>${esc(r.matchScore ?? "--")}</td><td>${asset}</td><td>${esc(r.matchedRules || "--")}</td><td>${esc(r.resultText || "")}</td>
        <td><button class="pm-link-button" type="button" data-adc-payload="${i}">Values</button></td></tr>`;
    }).join("") || empty(9, "No records (past the observation retention).");
    document.getElementById("adcBatModal").hidden = false;
  }

  // ------------------------------------------------------------------ reconciliation queue
  function setQueueAsset(id, name) {
    state.queueAssetId = id;
    state.queueAssetName = name || "";
    const b = document.getElementById("adcQAssetClear");
    b.hidden = !id;
    document.getElementById("adcQAssetLabel").textContent = id ? `Asset: ${state.queueAssetName}` : "";
  }

  async function refreshQueue() {
    const body = document.getElementById("adcQBody");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); state.qPager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.qPager ? state.qPager.page() : 1, pageSize: state.qPager ? state.qPager.size() : 25 });
    if (val("adcQStatus")) qs.set("status", val("adcQStatus"));
    if (val("adcQKind")) qs.set("kind", val("adcQKind"));
    if (val("adcQSource")) qs.set("sourceId", val("adcQSource"));
    if (val("adcQSearch")) qs.set("search", val("adcQSearch"));
    if (state.queueAssetId) qs.set("assetId", state.queueAssetId);
    const res = await api("GET", `/discovery/exceptions?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.qPager?.clear(); state.queue = []; return; }
    const rows = res.data.data.rows || [];
    state.queue = rows;
    state.qPager?.setTotal(res.data.data.totalRows, rows.length);
    body.innerHTML = rows.map(e => {
      const [kl, kc] = KIND[e.exceptionKind] || [e.exceptionKind, ""];
      const assetBtn = (id, name) => id ? `<button class="pm-link-button" type="button" data-adc-asset="${id}">${esc(name || ("#" + id))}</button>` : "";
      const asset = e.exceptionKind === "DUPLICATE"
        ? `${assetBtn(e.assetId, e.assetName)}<div class="adc-note">and</div>${assetBtn(e.otherAssetId, e.otherAssetName)}`
        : (assetBtn(e.assetId, e.assetName) || (e.exceptionKind === "NEW_CANDIDATE" ? "--" : "--"));
      const field = e.fieldKey ? `${esc(e.fieldLabel || e.fieldKey)}<div class="adc-note">${esc(e.currentValue ?? "(empty)")} / ${esc(e.observedValue ?? "(empty)")}</div>` : "--";
      const canAct = e.status === "OPEN" && (CAN_EDIT || (CAN_APPROVE && e.exceptionKind === "CONFLICT"));
      const canRegister = e.status === "OPEN" && CAN_EDIT && (e.exceptionKind === "NEW_CANDIDATE" || e.exceptionKind === "MANUAL_REVIEW");   // 443
      const status = e.status === "OPEN"
        ? (canAct ? `<button class="pm-button" type="button" data-adc-resolve="${e.exceptionId}"><i class="fa-solid fa-scale-balanced"></i> Resolve</button>` : `<span class="adc-chip adc-st-open">Open</span>`)
          + (canRegister ? ` <button class="pm-button" type="button" data-adc-register="${e.exceptionId}" title="Register a new Draft asset from this record"><i class="fa-solid fa-plus"></i> Register</button>` : "")
          + (e.status === "OPEN" && CAN_EDIT && e.exceptionKind === "DUPLICATE" && e.assetId && e.otherAssetId   // 444
             ? ` <button class="pm-button" type="button" data-adc-merge-pair="${e.assetId}:${e.otherAssetId}" title="Prepare a merge of the two assets"><i class="fa-solid fa-code-merge"></i> Merge</button>` : "")
        : `<span class="adc-chip adc-st-ended">${esc(RESOLUTION[e.resolution] || label(e.resolution))}</span><div class="adc-note">${esc(e.resolvedBy || "")} ${esc(dateTime(e.resolvedDt))}</div>`;
      return `<tr><td><span class="adc-chip ${kc}">${esc(kl)}</span>${e.raisedCount > 1 ? `<div class="adc-note">reported ${esc(e.raisedCount)} times</div>` : ""}</td>
        <td>${esc(e.sourceName)}<div class="adc-note">${esc(e.externalKey || "--")}</div></td><td>${asset}</td><td>${field}</td>
        <td>${esc(e.matchScore ?? "--")}</td><td>${esc(dateTime(e.raisedDt))}</td><td>${esc(e.taskNumber || "--")}</td><td>${status}</td></tr>`;
    }).join("") || empty(8, "No exceptions.");
  }

  function openResolve(id) {
    const e = (state.queue || []).find(x => x.exceptionId === id);
    if (!e) return;
    state.exception = e;
    hide("adcRsMessage");
    const [kl] = KIND[e.exceptionKind] || [e.exceptionKind];
    document.getElementById("adcRsTitle").textContent = `${kl} - ${e.sourceName}`;
    const item = (l, v) => `<div><span>${esc(l)}</span>${v}</div>`;
    document.getElementById("adcRsInfo").innerHTML =
      item("Source record", esc(e.externalKey || "--")) +
      item("Observed", esc(dateTime(e.observedDt))) +
      item("Score", esc(e.matchScore ?? "--")) +
      item("Matched rules", esc(e.matchedRules || "--")) +
      (e.assetId ? item(e.exceptionKind === "DUPLICATE" ? "Assets" : "Asset", esc(e.assetName) + (e.otherAssetId ? " / " + esc(e.otherAssetName) : "")) : "") +
      (e.fieldKey ? item(e.fieldLabel || e.fieldKey, `current: ${esc(e.currentValue ?? "(empty)")}<br />observed: ${esc(e.observedValue ?? "(empty)")}`) : "") +
      (e.taskNumber ? item("Task", esc(e.taskNumber)) : "");
    const allowed = (ACTIONS[e.exceptionKind] || []).filter(a => a === "ACCEPT_OBSERVED" ? CAN_APPROVE : CAN_EDIT);
    document.getElementById("adcRsAction").innerHTML = allowed.map(a => `<option value="${a}">${esc(ACTION_LABEL[a])}</option>`).join("");
    document.getElementById("adcRsPair").innerHTML = e.exceptionKind === "DUPLICATE"
      ? [[e.assetId, e.assetName], [e.otherAssetId, e.otherAssetName]].map(([v, l]) => `<option value="${v}">${esc(l)}</option>`).join("") : "";
    document.getElementById("adcRsNote").value = "";
    document.getElementById("adcRsSearch").value = "";
    const sel = document.getElementById("adcRsAsset");
    sel.innerHTML = `<option value="">--</option>` + (e.assetId && e.exceptionKind !== "DUPLICATE" ? `<option value="${e.assetId}" selected>${esc(e.assetName)} (suggested)</option>` : "");
    document.getElementById("adcRsPayload").textContent = pretty(e.payloadJson) || "The observed values are past the raw payload retention.";
    resolveLayout();
    document.getElementById("adcResModal").hidden = false;
  }

  function resolveLayout() {
    const e = state.exception, action = val("adcRsAction");
    const link = action === "LINK", dup = e && e.exceptionKind === "DUPLICATE";
    document.getElementById("adcRsPairWrap").hidden = !(link && dup);
    document.getElementById("adcRsSearchWrap").hidden = !(link && !dup);
    document.getElementById("adcRsAssetWrap").hidden = !(link && !dup);
    document.getElementById("adcRsNoteLabel").textContent = NOTE_REQUIRED.includes(action) ? "Reason *" : "Note";
    const hints = {
      LINK: "The observation is applied to the asset by the field precedence of the source (empty values filled, golden values overwritten, other differences raised as conflicts) and the source record stays linked to it.",
      IGNORE: "The exception is closed; the source record is raised again if a later observation still does not match.",
      NOT_DUPLICATE: "The two assets are recorded as distinct and are not raised as a duplicate pair again.",
      ACCEPT_OBSERVED: "The observed value replaces the register value (approval permission).",
      KEEP_CURRENT: "The register value stays; the observed value remains recorded against the source."
    };
    document.getElementById("adcRsHint").textContent = hints[action] || "";
    if (link && !dup) loadAssetOptions();
  }

  async function loadAssetOptions() {
    if (!state.organizationId || !state.exception) return;
    const sel = document.getElementById("adcRsAsset"), keep = sel.value;
    const qs = new URLSearchParams({ organizationId: state.organizationId, kind: "ASSET" });
    if (val("adcRsSearch")) qs.set("search", val("adcRsSearch"));
    const res = await api("GET", `/relationships/ci-lookup?${qs}`);
    const rows = res.ok ? (res.data.data || []).filter(c => c.isUsable) : [];
    const e = state.exception;
    const sug = e.assetId && !rows.some(c => c.ciId === e.assetId) ? `<option value="${e.assetId}">${esc(e.assetName)} (suggested)</option>` : "";
    sel.innerHTML = `<option value="">--</option>` + sug + rows.map(c =>
      `<option value="${c.ciId}">${esc(c.ciName)}${c.ciId === e.assetId ? " (suggested)" : ""}${c.ciClass ? " - " + esc(c.ciClass) : ""}</option>`).join("");
    if (keep && [...sel.options].some(o => o.value === keep)) sel.value = keep;
    else if (e.assetId) sel.value = String(e.assetId);
    if (!res.ok) show("adcRsMessage", res.error);
  }

  async function saveResolve() {
    const e = state.exception, action = val("adcRsAction");
    if (!e || !action) return;
    let assetId = null;
    if (action === "LINK") assetId = e.exceptionKind === "DUPLICATE" ? num("adcRsPair") : num("adcRsAsset");
    const res = await api("POST", `/discovery/exceptions/${e.exceptionId}/resolve`, {
      organizationId: state.organizationId, action, assetId, note: val("adcRsNote"), expectedRecordVersion: e.recordVersion
    });
    if (!res.ok) { show("adcRsMessage", res.error); return; }
    document.getElementById("adcResModal").hidden = true;
    showMessage(`${ACTION_LABEL[action]}: done.`, "success");
    await refreshQueue();
  }

  // 443: register a new candidate on the Asset Register form (prefilled from
  // the observation); asset-register.js links the record after the save.
  function registerCandidate(id) {
    const qs = new URLSearchParams({ organizationId: state.organizationId, discoveryException: id });
    window.location.href = U(`/Practice/Index/asset-register?${qs}`);
  }

  // ------------------------------------------------------------------ data confidence
  async function refreshConfidence() {
    const body = document.getElementById("adcCBody");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); state.cPager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.cPager ? state.cPager.page() : 1, pageSize: state.cPager ? state.cPager.size() : 25 });
    if (val("adcCStatus")) qs.set("status", val("adcCStatus"));
    if (val("adcCSearch")) qs.set("search", val("adcCSearch"));
    const res = await api("GET", `/discovery/confidence?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.cPager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.cPager?.setTotal(res.data.data.totalRows, rows.length);
    body.innerHTML = rows.map(c => `<tr><td><button class="pm-link-button" type="button" data-adc-asset="${c.assetId}">${esc(c.assetName)}</button><div class="adc-note">${esc(c.assetTypeName || "")}</div></td>
        <td>${confidenceChip(c.overallStatus)}</td><td>${esc(c.identityScore ?? "--")}</td><td>${esc(c.freshLinkCount)} / ${esc(c.linkCount)}</td>
        <td>${esc(dateTime(c.lastObservedDt) || "--")}${c.ageHours != null ? `<div class="adc-note">${esc(c.ageHours)} h ago</div>` : ""}</td>
        <td>${c.openConflictCount ? `<span class="adc-chip adc-st-bad">${esc(c.openConflictCount)}</span>` : "0"}</td><td>${esc(c.attributeDisagreementCount)}</td>
        <td>${esc(date(c.lastVerifiedDate) || "--")}</td></tr>`).join("") || empty(8, "No assets.");
  }
  function confidenceChip(code) { const [l, c] = CONFIDENCE[code] || [code, ""]; return `<span class="adc-chip ${c}">${esc(l)}</span>`; }

  async function openAsset(id) {
    const res = await api("GET", `/discovery/assets/${id}?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error); return; }
    const d = res.data.data, c = d.confidence || {};
    state.assetId = id;
    document.getElementById("adcAmTitle").textContent = c.assetName || ("Asset " + id);
    const item = (l, v) => `<div><span>${esc(l)}</span>${v}</div>`;
    document.getElementById("adcAmInfo").innerHTML =
      item("Confidence", c.overallStatus ? confidenceChip(c.overallStatus) : "--") + item("Type", esc(c.assetTypeName || "--")) +
      item("Identity score", esc(c.identityScore ?? "--")) + item("Sources (fresh / linked)", `${esc(c.freshLinkCount ?? 0)} / ${esc(c.linkCount ?? 0)}`) +
      item("Last observed", esc(dateTime(c.lastObservedDt) || "--")) + item("Open conflicts", esc(c.openConflictCount ?? 0)) +
      item("Disagreements", esc(c.attributeDisagreementCount ?? 0)) + item("Last verified", esc(date(c.lastVerifiedDate) || "--"));
    const stale = state.config?.settings?.staleMultiplier ?? 3;
    document.getElementById("adcAmLinkBody").innerHTML = (d.links || []).map(l => {
      const fresh = l.ageHours != null && l.ageHours <= l.expectedIntervalHours * stale;
      return `<tr><td>${esc(l.sourceName)}</td><td>${esc(l.externalKey)}</td><td>${esc(l.linkMethod === "AUTO" ? "Auto match" : "Confirmed")}</td><td>${esc(l.identityScore ?? "--")}</td>
        <td>${esc(dateTime(l.firstSeenDt))}</td><td>${esc(dateTime(l.lastSeenDt))}<div class="adc-note">${esc(l.ageHours)} h ago</div></td>
        <td><span class="adc-chip ${fresh ? "adc-st-active" : "adc-st-wait"}">${fresh ? "Fresh" : "Stale"}</span></td></tr>`;
    }).join("") || empty(7, "Not linked to any source record.");
    document.getElementById("adcAmAttrBody").innerHTML = (d.attributes || []).map(a => `<tr><td>${esc(a.fieldLabel || a.fieldKey)}</td><td>${esc(a.sourceName)}</td>
        <td>${esc(ROLES[a.sourceRole] || a.sourceRole)}</td><td>${esc(a.observedValue ?? "")}</td><td>${esc(a.registerValue ?? "")}</td>
        <td>${a.applied ? "Yes" : `<span class="adc-chip adc-st-wait">No</span>`}</td><td>${esc(dateTime(a.observedDt))}</td></tr>`).join("") || empty(7, "No values reported.");
    document.getElementById("adcAmExcBody").innerHTML = (d.exceptions || []).map(x => {
      const [kl, kc] = KIND[x.exceptionKind] || [x.exceptionKind, ""];
      return `<tr><td><span class="adc-chip ${kc}">${esc(kl)}</span></td><td>${esc(x.fieldKey || "--")}</td><td>${esc(x.currentValue ?? "")}</td>
        <td>${esc(x.observedValue ?? "")}</td><td>${esc(x.matchScore ?? "--")}</td><td>${esc(dateTime(x.raisedDt))}</td></tr>`;
    }).join("") || empty(6, "No open exceptions.");
    document.getElementById("adcAssetModal").hidden = false;
  }

  // ------------------------------------------------------------------ merges (444)
  async function refreshMerges() {
    const body = document.getElementById("adcMgBody");
    if (!state.organizationId) { body.innerHTML = empty(6, "Select an organization."); state.mgPager?.clear(); return; }
    body.innerHTML = empty(6, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.mgPager ? state.mgPager.page() : 1, pageSize: state.mgPager ? state.mgPager.size() : 25 });
    if (val("adcMgStatus")) qs.set("status", val("adcMgStatus"));
    if (val("adcMgSearch")) qs.set("search", val("adcMgSearch"));
    const res = await api("GET", `/discovery/merges?${qs}`);
    if (!res.ok) { body.innerHTML = empty(6, res.error); state.mgPager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.mgPager?.setTotal(res.data.data.totalRows, rows.length);
    body.innerHTML = rows.map(m => {
      const [sl, sc] = MERGE[m.status] || [m.status, ""];
      return `<tr><td><button class="pm-link-button" type="button" data-adc-merge="${m.eventId}">Merge #${esc(m.eventId)}</button></td>
        <td>${esc(m.survivorName)}</td><td>${esc(m.duplicateNames || "--")}<div class="adc-note">${esc(m.duplicateCount)} asset(s)</div></td>
        <td><span class="adc-chip ${sc}">${esc(sl)}</span></td>
        <td>${esc(m.approvals)} / ${esc(m.approvalsRequired)}${m.isCritical ? ' <span class="adc-chip adc-st-bad">Critical</span>' : ""}</td>
        <td>${esc(m.requestedBy || "")}<div class="adc-note">${esc(dateTime(m.requestedDt))}</div></td></tr>`;
    }).join("") || empty(6, "No merges.");
  }

  // Asset picker from relationships/ci-lookup (kind ASSET, usable only).
  async function fillAssetPicker(searchId, selectId, keep, msgId) {   // 445: msgId (default the merge window)
    const sel = document.getElementById(selectId);
    const qs = new URLSearchParams({ organizationId: state.organizationId, kind: "ASSET" });
    if (val(searchId)) qs.set("search", val(searchId));
    const res = await api("GET", `/relationships/ci-lookup?${qs}`);
    const rows = res.ok ? (res.data.data || []).filter(c => c.isUsable) : [];
    const extra = keep && !rows.some(c => c.ciId === keep.id) ? `<option value="${keep.id}">${esc(keep.name)}</option>` : "";
    sel.innerHTML = `<option value="">--</option>` + extra + rows.map(c => `<option value="${c.ciId}">${esc(c.ciName)}${c.ciClass ? " - " + esc(c.ciClass) : ""}</option>`).join("");
    if (keep) sel.value = String(keep.id);
    if (!res.ok) show(msgId || "adcMgMessage", res.error);
  }

  function renderMergeDups() {
    const canEdit = CAN_EDIT && (!state.merge || state.merge.merge.status === "DRAFT");
    document.getElementById("adcMgDupBody").innerHTML = state.mergeDups.map((d, i) => `<tr><td>${esc(d.name)} <span class="adc-note">#${esc(d.id)}</span></td>
        <td>${canEdit ? `<button class="pm-link-button" type="button" data-adc-dup-remove="${i}">Remove</button>` : ""}</td></tr>`).join("")
      || empty(2, "Add at least one duplicate.");
  }

  function addMergeDuplicate() {
    const sel = document.getElementById("adcMgDupSel"), id = Number(sel.value);
    if (!id) return;
    if (String(id) === val("adcMgSurv")) { show("adcMgMessage", "The survivor cannot also be a duplicate."); return; }
    if (state.mergeDups.some(d => d.id === id)) return;
    if (state.mergeDups.length >= 10) { show("adcMgMessage", "A merge holds at most 10 duplicates."); return; }
    state.mergeDups.push({ id, name: sel.options[sel.selectedIndex].textContent });
    hide("adcMgMessage");
    renderMergeDups();
  }

  // New (unsaved) merge, optionally prefilled from a duplicate review.
  async function openMergeNew(survivorId, duplicateIds) {
    state.merge = null; state.mergeChoices = {};
    hide("adcMgMessage");
    document.getElementById("adcMgTitle").textContent = "New merge";
    document.getElementById("adcMgInfo").innerHTML = "";
    document.getElementById("adcMgForm").hidden = !CAN_EDIT;
    document.getElementById("adcMgActionWrap").hidden = true;
    document.getElementById("adcMgDetail").hidden = true;
    ["adcMgSurvSearch", "adcMgDupSearch", "adcMgReason"].forEach(id => { document.getElementById(id).value = ""; });
    const names = await assetNames([survivorId, ...duplicateIds].filter(Boolean));
    state.mergeDups = duplicateIds.map(id => ({ id, name: names[id] || "#" + id }));
    await fillAssetPicker("adcMgSurvSearch", "adcMgSurv", survivorId ? { id: survivorId, name: names[survivorId] || "#" + survivorId } : null);
    await fillAssetPicker("adcMgDupSearch", "adcMgDupSel");
    renderMergeDups();
    document.getElementById("adcMergeModal").hidden = false;
  }

  // Names of the assets prefilled from a duplicate review (the queue row holds them).
  async function assetNames(ids) {
    const out = {};
    (state.queue || []).forEach(e => { if (e.assetId) out[e.assetId] = e.assetName; if (e.otherAssetId) out[e.otherAssetId] = e.otherAssetName; });
    return ids.reduce((m, id) => { m[id] = out[id]; return m; }, {});
  }

  async function saveMerge() {
    const survivor = num("adcMgSurv");
    if (!survivor) { show("adcMgMessage", "Choose the survivor."); return; }
    const m = state.merge && state.merge.merge;
    const res = await api("POST", "/discovery/merges", {
      organizationId: state.organizationId, eventId: m ? m.eventId : null, survivorAssetId: survivor,
      duplicateAssetIds: state.mergeDups.map(d => d.id), reason: val("adcMgReason"),
      fieldChoices: Object.keys(state.mergeChoices).length ? state.mergeChoices : null, expectedRecordVersion: m ? m.recordVersion : null
    });
    if (!res.ok) { show("adcMgMessage", res.error); return; }
    await openMerge(res.data.id);
    show("adcMgMessage", "Draft saved. Review the impact, fields, plan and blockers, then submit it for approval.", "success");
    await refreshMerges();
  }

  async function openMerge(id) {
    const res = await api("GET", `/discovery/merges/${id}?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error); return; }
    const d = res.data.data, m = d.merge;
    state.merge = d;
    hide("adcMgMessage");
    const [sl, sc] = MERGE[m.status] || [m.status, ""];
    document.getElementById("adcMgTitle").textContent = `Merge #${m.eventId} - ${m.survivorName}`;
    const item = (l, v) => `<div><span>${esc(l)}</span>${v}</div>`;
    document.getElementById("adcMgInfo").innerHTML =
      item("Status", `<span class="adc-chip ${sc}">${esc(sl)}</span>${m.isCritical ? ' <span class="adc-chip adc-st-bad">Critical</span>' : ""}`) +
      item("Approvals", `${esc(m.approvals)} / ${esc(m.approvalsRequired)}`) + item("Requested", `${esc(m.requestedBy || "")} ${esc(dateTime(m.requestedDt))}`) +
      item("Reason", esc(m.reason || "--")) +
      (m.executedDt ? item("Executed", `${esc(m.executedBy || "")} ${esc(dateTime(m.executedDt))}`) : "") +
      (m.recoveredDt ? item("Recovered", `${esc(m.recoveredBy || "")} ${esc(dateTime(m.recoveredDt))} - ${esc(m.recoveryReason || "")}`) : "") +
      (m.decidedNote ? item("Decision note", esc(m.decidedNote)) : "");
    const draft = m.status === "DRAFT";
    const assets = d.assets || [];
    state.mergeDups = assets.filter(a => a.memberRole !== "SURVIVOR").map(a => ({ id: a.assetId, name: a.assetName }));
    state.mergeChoices = {};
    try { Object.assign(state.mergeChoices, JSON.parse(m.fieldChoicesJson || "{}")); } catch (_) { /* none */ }
    document.getElementById("adcMgForm").hidden = !(draft && CAN_EDIT);
    if (draft && CAN_EDIT) {
      document.getElementById("adcMgReason").value = m.reason || "";
      await fillAssetPicker("adcMgSurvSearch", "adcMgSurv", { id: m.survivorAssetId, name: m.survivorName });
      await fillAssetPicker("adcMgDupSearch", "adcMgDupSel");
    }
    renderMergeDups();
    // actions the status allows; the proxy and SQL check the permission and the people
    const acts = eventActions(m.status, "merge");   // 445: shared with splits
    document.getElementById("adcMgActions").innerHTML = acts.map(([a, l, c]) => `<button class="pm-button ${c}" type="button" data-adc-merge-action="${a}">${esc(l)}</button>`).join("");
    document.getElementById("adcMgActionWrap").hidden = !acts.length;
    document.getElementById("adcMgNote").value = "";
    const nameOf = id => (assets.find(a => a.assetId === id) || {}).assetName || "#" + id;
    // blockers
    document.getElementById("adcMgBlockBody").innerHTML = (d.blockers || []).map(b => `<tr><td>${esc(nameOf(b.assetId))}</td><td>${esc(b.detail)}</td></tr>`).join("")
      || empty(2, ["DRAFT", "PENDING_APPROVAL", "APPROVED"].includes(m.status) ? "None." : "--");
    // impact: one column per asset
    document.getElementById("adcMgImpactHead").innerHTML = `<tr><th>Item</th>${assets.map(a => `<th>${esc(a.assetName)}<div class="adc-note">${a.memberRole === "SURVIVOR" ? "survivor" : "duplicate"} - ${esc(a.statusName)}${a.criticalityName ? ", " + esc(a.criticalityName) : ""}</div></th>`).join("")}</tr>`;
    const items = [...new Map((d.impact || []).map(i => [i.impactItem, i.sortOrder])).entries()].sort((x, y) => x[1] - y[1]).map(x => x[0]);
    document.getElementById("adcMgImpactBody").innerHTML = items.map(it => `<tr><td>${esc(it)}</td>${assets.map(a => {
      const r = (d.impact || []).find(i => i.assetId === a.assetId && i.impactItem === it);
      return `<td>${esc(r ? r.itemCount : 0)}</td>`; }).join("")}</tr>`).join("") || empty(1, "--");
    // fields (open merges)
    const canChoose = draft && CAN_EDIT;
    document.getElementById("adcMgFieldBody").innerHTML = (d.fields || []).map(f => `<tr><td>${esc(f.fieldLabel)}</td>
        <td>${esc(f.survivorDisplay ?? "(empty)")}</td><td>${esc(f.duplicateDisplay ?? "")}<div class="adc-note">${esc(nameOf(f.duplicateAssetId))}</div></td>
        <td>${f.isMergeable && f.isDifferent ? `<input type="checkbox" data-adc-choice="${esc(f.fieldKey)}" value="${f.duplicateAssetId}"${state.mergeChoices[f.fieldKey] === f.duplicateAssetId ? " checked" : ""}${canChoose ? "" : " disabled"} />`
            : (f.survivorDisplay == null && f.isMergeable ? '<span class="adc-note">filled</span>' : "")}</td></tr>`).join("")
      || empty(4, ["DRAFT", "PENDING_APPROVAL", "APPROVED"].includes(m.status) ? "No duplicate values." : "--");
    // plan (open) or outcomes (executed / recovered)
    const open = ["DRAFT", "PENDING_APPROVAL", "APPROVED"].includes(m.status);
    document.getElementById("adcMgPlanTitle").textContent = open ? "Plan" : "Outcomes";
    const rows = open ? (d.plan || []) : (d.outcomes || []);
    document.getElementById("adcMgPlanBody").innerHTML = rows.map(p => {
      const [pl, pc] = PLAN[p.outcome] || [p.outcome, ""];
      const rec = !open && p.outcome !== "KEPT" ? (p.recovered ? ' <span class="adc-chip adc-st-active">Recovered</span>' : (p.recoveryNote ? `<div class="adc-note">${esc(p.recoveryNote)}</div>` : "")) : "";
      return `<tr><td>${esc(nameOf(p.duplicateAssetId))}</td><td>${esc(p.domain || OBJECT[p.objectKind] || p.objectKind)}</td>
        <td>${esc(OBJECT[p.objectKind] || p.objectKind)}: ${esc(p.objectLabel || "")}</td><td><span class="adc-chip ${pc}">${esc(pl)}</span>${rec}</td>
        <td>${esc(p.detail || "")}${!open && (p.beforeValue || p.afterValue) && p.objectKind === "FIELD" ? `<div class="adc-note">${esc(p.beforeValue ?? "(empty)")} -> ${esc(p.afterValue ?? "")}</div>` : ""}</td></tr>`;
    }).join("") || empty(5, "Nothing refers to the duplicates.");
    document.getElementById("adcMgApprBody").innerHTML = (d.approvals || []).map(a => `<tr><td>${esc(label(a.decision))}</td><td>${esc(a.approver)}</td>
        <td>${esc(dateTime(a.decidedDt))}</td><td>${esc(a.note || "")}</td></tr>`).join("") || empty(4, "None yet.");
    document.getElementById("adcMgDetail").hidden = false;
    document.getElementById("adcMergeModal").hidden = false;
  }

  function sameChoices(current, savedJson) {
    let saved = {};
    try { saved = JSON.parse(savedJson || "{}") || {}; } catch (_) { saved = {}; }
    const a = Object.keys(current), b = Object.keys(saved);
    return a.length === b.length && a.every(k => Number(saved[k]) === Number(current[k]));
  }

  async function mergeAction(action) {
    const m = state.merge && state.merge.merge;
    if (!m) return;
    const asks = { EXECUTE: "Execute the merge now? The duplicates are archived and their items move to the survivor.",
                   RECOVER: "Recover this merge? Items are moved back where they were not changed since." };
    if (asks[action] && window.gracUi && window.gracUi.confirm && !(await window.gracUi.confirm(asks[action]))) return;
    if (action === "SUBMIT" && !sameChoices(state.mergeChoices, m.fieldChoicesJson)) {
      show("adcMgMessage", "Save the draft first: the field choices changed.");
      return;
    }
    const res = await api("POST", `/discovery/merges/${m.eventId}/action`, {
      organizationId: state.organizationId, action, note: val("adcMgNote"), expectedRecordVersion: m.recordVersion
    });
    if (!res.ok) { show("adcMgMessage", res.error); return; }
    await openMerge(m.eventId);
    show("adcMgMessage", eventDone(action, res.data.result, "Merge"), "success");
    await refreshMerges();
  }

  // 444 / 445: actions the status allows (the proxy and SQL check permissions and people).
  function eventActions(status, noun) {
    const acts = [];
    if (status === "DRAFT" && CAN_EDIT) acts.push(["SUBMIT", "Submit for approval", "primary"]);
    if (status === "PENDING_APPROVAL" && CAN_APPROVE) acts.push(["APPROVE", "Approve", "primary"], ["REJECT", "Reject", ""]);
    if (status === "APPROVED" && CAN_EDIT) acts.push(["EXECUTE", `Execute ${noun}`, "primary"]);
    if (status === "EXECUTED" && CAN_APPROVE) acts.push(["RECOVER", "Recover", ""]);
    if (["DRAFT", "PENDING_APPROVAL", "APPROVED"].includes(status) && CAN_EDIT) acts.push(["CANCEL", `Cancel ${noun}`, ""]);
    return acts;
  }
  function eventDone(action, result, noun) {
    return { SUBMIT: "Submitted for approval.", APPROVE: result === "FIRST_APPROVAL" ? "First approval recorded; a second approver is needed." : "Approved.",
             REJECT: "Rejected.", CANCEL: "Cancelled.", EXECUTE: `${noun} executed; see the outcomes.`, RECOVER: `${noun} recovered; see the outcome notes.` }[action];
  }

  // ------------------------------------------------------------------ splits (445)
  async function refreshSplits() {
    const body = document.getElementById("adcSpBody");
    if (!state.organizationId) { body.innerHTML = empty(6, "Select an organization."); state.spPager?.clear(); return; }
    body.innerHTML = empty(6, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.spPager ? state.spPager.page() : 1, pageSize: state.spPager ? state.spPager.size() : 25 });
    if (val("adcSpStatus")) qs.set("status", val("adcSpStatus"));
    if (val("adcSpSearch")) qs.set("search", val("adcSpSearch"));
    const res = await api("GET", `/discovery/splits?${qs}`);
    if (!res.ok) { body.innerHTML = empty(6, res.error); state.spPager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.spPager?.setTotal(res.data.data.totalRows, rows.length);
    body.innerHTML = rows.map(m => {
      const [sl, sc] = MERGE[m.status] || [m.status, ""];
      return `<tr><td><button class="pm-link-button" type="button" data-adc-split="${m.eventId}">Split #${esc(m.eventId)}</button></td>
        <td>${esc(m.survivorName)}</td><td>${esc(m.duplicateNames || "--")}<div class="adc-note">${esc(m.duplicateCount)} record(s)</div></td>
        <td><span class="adc-chip ${sc}">${esc(sl)}</span></td>
        <td>${esc(m.approvals)} / ${esc(m.approvalsRequired)}${m.isCritical ? ' <span class="adc-chip adc-st-bad">Critical</span>' : ""}</td>
        <td>${esc(m.requestedBy || "")}<div class="adc-note">${esc(dateTime(m.requestedDt))}</div></td></tr>`;
    }).join("") || empty(6, "No splits.");
  }

  function renderSplitResults() {
    const canEdit = CAN_EDIT && (!state.split || state.split.split.status === "DRAFT");
    document.getElementById("adcSpResBody").innerHTML = state.splitResults.map((d, i) => `<tr><td>${esc(d.name)} <span class="adc-note">#${esc(d.id)}</span></td>
        <td>${canEdit ? `<button class="pm-link-button" type="button" data-adc-res-remove="${i}">Remove</button>` : ""}</td></tr>`).join("")
      || empty(2, "Add at least one resulting record (a new Draft asset).");
  }

  function addSplitResult() {
    const sel = document.getElementById("adcSpResSel"), id = Number(sel.value);
    if (!id) return;
    if (String(id) === val("adcSpSrc")) { show("adcSpMessage", "The source cannot also be a resulting record."); return; }
    if (state.splitResults.some(d => d.id === id)) return;
    if (state.splitResults.length >= 5) { show("adcSpMessage", "A split has at most 5 resulting records."); return; }
    state.splitResults.push({ id, name: sel.options[sel.selectedIndex].textContent });
    hide("adcSpMessage");
    renderSplitResults();
  }

  async function openSplitNew() {
    state.split = null; state.splitResults = []; state.splitAlloc = {};
    hide("adcSpMessage");
    document.getElementById("adcSpTitle").textContent = "New split";
    document.getElementById("adcSpInfo").innerHTML = "";
    document.getElementById("adcSpForm").hidden = !CAN_EDIT;
    document.getElementById("adcSpActionWrap").hidden = true;
    document.getElementById("adcSpDetail").hidden = true;
    ["adcSpSrcSearch", "adcSpResSearch", "adcSpReason"].forEach(id => { document.getElementById(id).value = ""; });
    await fillAssetPicker("adcSpSrcSearch", "adcSpSrc", null, "adcSpMessage");
    await fillAssetPicker("adcSpResSearch", "adcSpResSel", null, "adcSpMessage");
    renderSplitResults();
    document.getElementById("adcSplitModal").hidden = false;
  }

  async function saveSplit() {
    const source = num("adcSpSrc");
    if (!source) { show("adcSpMessage", "Choose the source."); return; }
    const m = state.split && state.split.split;
    const keep = new Set(state.splitResults.map(r => r.id));
    const allocations = Object.values(state.splitAlloc).filter(a => a.targetAssetId && keep.has(a.targetAssetId))
      .map(a => ({ objectKind: a.objectKind, objectId: a.objectId, objectKey: a.objectKey, targetAssetId: a.targetAssetId,
                   fieldMode: a.objectKind === "FIELD" ? (a.fieldMode || "COPY") : null }));
    const res = await api("POST", "/discovery/splits", {
      organizationId: state.organizationId, eventId: m ? m.eventId : null, sourceAssetId: source,
      resultAssetIds: state.splitResults.map(r => r.id), reason: val("adcSpReason"), allocations,
      expectedRecordVersion: m ? m.recordVersion : null
    });
    if (!res.ok) { show("adcSpMessage", res.error); return; }
    await openSplit(res.data.id);
    show("adcSpMessage", "Draft saved. Allocate the items, save again, then submit it for approval.", "success");
    await refreshSplits();
  }

  async function openSplit(id) {
    const res = await api("GET", `/discovery/splits/${id}?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error); return; }
    const d = res.data.data, m = d.split;
    state.split = d;
    hide("adcSpMessage");
    const [sl, sc] = MERGE[m.status] || [m.status, ""];
    document.getElementById("adcSpTitle").textContent = `Split #${m.eventId} - ${m.sourceName}`;
    const item = (l, v) => `<div><span>${esc(l)}</span>${v}</div>`;
    document.getElementById("adcSpInfo").innerHTML =
      item("Status", `<span class="adc-chip ${sc}">${esc(sl)}</span>${m.isCritical ? ' <span class="adc-chip adc-st-bad">Critical</span>' : ""}`) +
      item("Approvals", `${esc(m.approvals)} / ${esc(m.approvalsRequired)}`) + item("Requested", `${esc(m.requestedBy || "")} ${esc(dateTime(m.requestedDt))}`) +
      item("Reason", esc(m.reason || "--")) +
      (m.executedDt ? item("Executed", `${esc(m.executedBy || "")} ${esc(dateTime(m.executedDt))}`) : "") +
      (m.recoveredDt ? item("Recovered", `${esc(m.recoveredBy || "")} ${esc(dateTime(m.recoveredDt))} - ${esc(m.recoveryReason || "")}`) : "") +
      (m.decidedNote ? item("Decision note", esc(m.decidedNote)) : "");
    const draft = m.status === "DRAFT", open = ["DRAFT", "PENDING_APPROVAL", "APPROVED"].includes(m.status);
    const assets = d.assets || [], results = assets.filter(a => a.memberRole !== "SOURCE");
    const nameOf = aid => (assets.find(a => a.assetId === aid) || {}).assetName || "#" + aid;
    state.splitResults = results.map(a => ({ id: a.assetId, name: a.assetName }));
    state.splitAlloc = {};
    (d.plan || []).filter(p => p.targetAssetId).forEach(p => {
      state.splitAlloc[allocKey(p)] = { objectKind: p.objectKind, objectId: p.objectId, objectKey: p.objectKind === "FIELD" ? null : p.objectKey,
                                        targetAssetId: p.targetAssetId, fieldMode: p.fieldMode };
    });
    document.getElementById("adcSpForm").hidden = !(draft && CAN_EDIT);
    if (draft && CAN_EDIT) {
      document.getElementById("adcSpReason").value = m.reason || "";
      await fillAssetPicker("adcSpSrcSearch", "adcSpSrc", { id: m.sourceAssetId, name: m.sourceName }, "adcSpMessage");
      await fillAssetPicker("adcSpResSearch", "adcSpResSel", null, "adcSpMessage");
    }
    renderSplitResults();
    const acts = eventActions(m.status, "split");
    document.getElementById("adcSpActions").innerHTML = acts.map(([a, l, c]) => `<button class="pm-button ${c}" type="button" data-adc-split-action="${a}">${esc(l)}</button>`).join("");
    document.getElementById("adcSpActionWrap").hidden = !acts.length;
    document.getElementById("adcSpNote").value = "";
    document.getElementById("adcSpBlockBody").innerHTML = (d.blockers || []).map(b => `<tr><td>${esc(b.detail)}</td></tr>`).join("")
      || empty(1, open ? "None." : "--");
    document.getElementById("adcSpImpactHead").innerHTML = `<tr><th>Item</th>${assets.map(a => `<th>${esc(a.assetName)}<div class="adc-note">${a.memberRole === "SOURCE" ? "source" : "resulting record"} - ${esc(a.statusName)}${a.criticalityName ? ", " + esc(a.criticalityName) : ""}</div></th>`).join("")}</tr>`;
    const items = [...new Map((d.impact || []).map(i => [i.impactItem, i.sortOrder])).entries()].sort((x, y) => x[1] - y[1]).map(x => x[0]);
    document.getElementById("adcSpImpactBody").innerHTML = items.map(it => `<tr><td>${esc(it)}</td>${assets.map(a => {
      const r = (d.impact || []).find(i => i.assetId === a.assetId && i.impactItem === it);
      return `<td>${esc(r ? r.itemCount : 0)}</td>`; }).join("")}</tr>`).join("") || empty(1, "--");
    // allocation (open) / outcomes (executed, recovered)
    document.getElementById("adcSpAllocWrap").hidden = !open;
    document.getElementById("adcSpOutWrap").hidden = open;
    const canAlloc = draft && CAN_EDIT;
    document.getElementById("adcSpAllocBody").innerHTML = (d.plan || []).map(p => {
      const key = allocKey(p), a = state.splitAlloc[key];
      const itemJson = esc(JSON.stringify({ objectKind: p.objectKind, objectId: p.objectId, objectKey: p.objectKind === "FIELD" ? null : p.objectKey, targetAssetId: null, fieldMode: null }));
      const target = `<select data-adc-alloc="${esc(key)}" data-adc-item="${itemJson}"${canAlloc ? "" : " disabled"}><option value="">Stays with the source</option>${results.map(r => `<option value="${r.assetId}"${a && a.targetAssetId === r.assetId ? " selected" : ""}>${esc(r.assetName)}</option>`).join("")}</select>`;
      const mode = p.objectKind === "FIELD" ? `<select data-adc-alloc="${esc(key)}" data-adc-alloc-mode="1" data-adc-item="${itemJson}"${canAlloc ? "" : " disabled"}><option value="COPY"${a && a.fieldMode === "MOVE" ? "" : " selected"}>Copy</option><option value="MOVE"${a && a.fieldMode === "MOVE" ? " selected" : ""}>Move</option></select>` : "";
      const [pl, pc] = PLAN[p.outcome] || (p.outcome === "STAY" ? ["Stays", "adc-st-ended"] : p.outcome === "COPY" ? ["Copy", "adc-st-open"] : [p.outcome, ""]);
      return `<tr><td>${esc(p.domain || "")}</td><td>${esc(OBJECT[p.objectKind] || p.objectKind)}: ${esc(p.objectLabel || "")}<div class="adc-note">${esc(p.detail || "")}</div></td>
        <td>${target}</td><td>${mode}</td><td><span class="adc-chip ${pc}">${esc(pl)}</span>${p.outcomeNote ? `<div class="adc-note">${esc(p.outcomeNote)}</div>` : ""}</td></tr>`;
    }).join("") || empty(5, "The source has nothing to allocate.");
    document.getElementById("adcSpOutBody").innerHTML = (d.outcomes || []).map(o => {
      const [pl, pc] = PLAN[o.outcome] || [o.outcome, ""];
      const rec = o.outcome !== "KEPT" ? (o.recovered ? ' <span class="adc-chip adc-st-active">Recovered</span>' : (o.recoveryNote ? `<div class="adc-note">${esc(o.recoveryNote)}</div>` : "")) : "";
      return `<tr><td>${esc(nameOf(o.toAssetId))}</td><td>${esc(OBJECT[o.objectKind] || o.objectKind)}: ${esc(o.objectLabel || "")}</td>
        <td><span class="adc-chip ${pc}">${esc(pl)}</span>${rec}</td>
        <td>${esc(o.detail || "")}${o.objectKind === "FIELD" ? `<div class="adc-note">${esc(o.beforeValue ?? "(empty)")} -> ${esc(o.afterValue ?? "(empty)")}</div>` : ""}</td></tr>`;
    }).join("") || empty(4, "--");
    document.getElementById("adcSpApprBody").innerHTML = (d.approvals || []).map(a => `<tr><td>${esc(label(a.decision))}</td><td>${esc(a.approver)}</td>
        <td>${esc(dateTime(a.decidedDt))}</td><td>${esc(a.note || "")}</td></tr>`).join("") || empty(4, "None yet.");
    document.getElementById("adcSpDetail").hidden = false;
    document.getElementById("adcSplitModal").hidden = false;
  }
  function allocKey(p) { return `${p.objectKind}|${p.objectId ?? ""}|${p.objectKind === "FIELD" ? "" : (p.objectKey ?? "")}`; }

  async function splitAction(action) {
    const m = state.split && state.split.split;
    if (!m) return;
    const asks = { EXECUTE: "Execute the split now? The allocated items move to the resulting records.",
                   RECOVER: "Recover this split? Items are moved back where they were not changed since." };
    if (asks[action] && window.gracUi && window.gracUi.confirm && !(await window.gracUi.confirm(asks[action]))) return;
    if (action === "SUBMIT" && !sameAllocation(state.split.plan || [])) { show("adcSpMessage", "Save the draft first: the allocation changed."); return; }
    const res = await api("POST", `/discovery/splits/${m.eventId}/action`, {
      organizationId: state.organizationId, action, note: val("adcSpNote"), expectedRecordVersion: m.recordVersion
    });
    if (!res.ok) { show("adcSpMessage", res.error); return; }
    await openSplit(m.eventId);
    show("adcSpMessage", eventDone(action, res.data.result, "Split"), "success");
    await refreshSplits();
  }
  function sameAllocation(plan) {
    const saved = {};
    plan.filter(p => p.targetAssetId).forEach(p => { saved[allocKey(p)] = `${p.targetAssetId}|${p.fieldMode || ""}`; });
    const now = {};
    Object.entries(state.splitAlloc).forEach(([k, a]) => { if (a.targetAssetId) now[k] = `${a.targetAssetId}|${a.objectKind === "FIELD" ? (a.fieldMode || "COPY") : ""}`; });
    const ks = Object.keys(saved), kn = Object.keys(now);
    return ks.length === kn.length && ks.every(k => saved[k] === now[k]);
  }

  // ------------------------------------------------------------------ stale assets (443)
  async function refreshStale() {
    const body = document.getElementById("adcStBody");
    if (!state.organizationId) { body.innerHTML = empty(6, "Select an organization."); state.stPager?.clear(); return; }
    body.innerHTML = empty(6, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.stPager ? state.stPager.page() : 1, pageSize: state.stPager ? state.stPager.size() : 25 });
    if (val("adcStView")) qs.set("view", val("adcStView"));
    if (val("adcStSearch")) qs.set("search", val("adcStSearch"));
    const res = await api("GET", `/discovery/stale?${qs}`);
    if (!res.ok) { body.innerHTML = empty(6, res.error); state.stPager?.clear(); return; }
    const d = res.data.data, rows = d.rows || [];
    const days = document.getElementById("adcStDays");
    days.value = d.settings ? d.settings.retireAfterDays : 90;
    days.disabled = !CAN_EDIT;
    state.stPager?.setTotal(d.totalRows, rows.length);
    body.innerHTML = rows.map(r => {
      const [rl, rc] = REVIEW[r.reviewStatus] || ["Not reviewed", "adc-st-ended"];
      const progress = r.reviewStatus === "OPEN"
        ? `<div class="adc-note">${r.sourceOutcome ? "source: " + esc(label(r.sourceOutcome)) : "source not confirmed"}, ${r.dependenciesReviewedDt ? "dependencies reviewed" : "dependencies not reviewed"}</div>`
        : (r.closedDt ? `<div class="adc-note">${esc(r.closedBy || "")} ${esc(dateTime(r.closedDt))}${r.changeResult ? " - lifecycle " + esc(label(r.changeResult)) : ""}</div>` : "");
      return `<tr><td><button class="pm-link-button" type="button" data-adc-stale="${r.assetId}">${esc(r.assetName)}</button><div class="adc-note">${esc(r.assetTypeName || "")}</div></td>
        <td>${esc(r.statusName || "--")}</td><td>${esc(dateTime(r.lastObservedDt) || "--")}</td><td>${esc(r.daysUnseen ?? "--")}</td>
        <td>${r.freshLinkCount != null ? esc(r.freshLinkCount) + " / " : ""}${esc(r.linkCount)}</td>
        <td><span class="adc-chip ${rc}">${esc(rl)}</span>${r.reviewStatus === "OPEN" && !r.isStale ? ' <span class="adc-chip adc-st-active">Seen again</span>' : ""}${progress}</td></tr>`;
    }).join("") || empty(6, val("adcStView") === "CLOSED" ? "No closed reviews." : "No stale assets.");
  }

  async function saveStaleRule() {
    const res = await api("POST", "/discovery/stale/settings", { organizationId: state.organizationId, retireAfterDays: num("adcStDays") });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    showMessage("Aging rule saved.", "success");
    state.stPager?.reset(true);
    await refreshStale();
  }

  async function openStale(assetId) {
    const res = await api("GET", `/discovery/stale/assets/${assetId}?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error); return; }
    const d = res.data.data, a = d.asset;
    state.stale = d;
    hide("adcSrMessage");
    document.getElementById("adcSrTitle").textContent = a.assetName;
    const item = (l, v) => `<div><span>${esc(l)}</span>${v}</div>`;
    const [rl, rc] = REVIEW[a.reviewStatus] || ["Not reviewed", "adc-st-ended"];
    document.getElementById("adcSrInfo").innerHTML =
      item("Type / status", `${esc(a.assetTypeName || "--")} / ${esc(a.statusName)}`) +
      item("Last observed", esc(dateTime(a.lastObservedDt) || "--")) + item("Days unseen", esc(a.daysUnseen ?? "--")) +
      item("Sources (fresh / linked)", `${esc(a.freshLinkCount)} / ${esc(a.linkCount)}`) + item("Aging rule", `${esc(a.retireAfterDays)} days`) +
      item("Stale", a.isStale ? '<span class="adc-chip adc-st-wait">Yes</span>' : "No") +
      item("Review", `<span class="adc-chip ${rc}">${esc(rl)}</span>${a.seenAgain ? ' <span class="adc-chip adc-st-active">Seen again</span>' : ""}`) +
      (a.reviewId ? item("Opened", `${esc(a.openedBy || "")} ${esc(dateTime(a.openedDt))}`) : "");
    const open = !!a.reviewId;
    document.getElementById("adcSrStartBar").hidden = open || !a.isStale || !CAN_EDIT;
    document.getElementById("adcSrSteps").hidden = !open;
    if (open) {
      const srcDone = !!a.sourceOutcome, depDone = !!a.dependenciesReviewedDt;
      const sd = document.getElementById("adcSrSourceDone");
      sd.hidden = !srcDone;
      sd.textContent = srcDone ? `Source owner confirmed: ${label(a.sourceOutcome)} - ${a.sourceNote || ""} (${a.sourceConfirmedBy || ""}, ${dateTime(a.sourceConfirmedDt)})` : "";
      document.getElementById("adcSrSourceForm").hidden = srcDone || !CAN_EDIT;
      const dd = document.getElementById("adcSrDepDone");
      dd.hidden = !depDone;
      dd.textContent = depDone ? `Reviewed: ${a.dependencyNote || ""} (${a.dependencyBlockers || 0} blocker(s); ${a.dependenciesReviewedBy || ""}, ${dateTime(a.dependenciesReviewedDt)})` : "";
      document.getElementById("adcSrDepForm").hidden = depDone || !CAN_EDIT;
      document.getElementById("adcSrDecisionForm").hidden = !CAN_EDIT;
      document.getElementById("adcSrDecom").disabled = !(srcDone && a.sourceOutcome === "ABSENT" && depDone && !a.seenAgain);
      ["adcSrOutcome", "adcSrSourceNote", "adcSrDepNote", "adcSrDecisionNote"].forEach(id => { document.getElementById(id).value = ""; });
    }
    document.getElementById("adcSrLinkBody").innerHTML = (d.links || []).map(l => `<tr><td>${esc(l.sourceName)}${l.sourceActive ? "" : ' <span class="adc-chip adc-st-ended">Inactive</span>'}</td>
        <td>${esc(l.externalKey)}</td><td>${esc(l.linkMethod === "AUTO" ? "Auto match" : "Confirmed")}</td><td>${esc(dateTime(l.lastSeenDt))}</td>
        <td>${esc(l.daysUnseen)}</td><td>${esc(dateTime(l.sourceLastRunDt) || "--")}${l.sourceLastRunStatus ? `<div class="adc-note">${esc(label(l.sourceLastRunStatus))}</div>` : ""}</td></tr>`).join("")
      || empty(6, "No source records.");
    document.getElementById("adcSrDepBody").innerHTML = (d.dependencies || []).map(x => `<tr><td>${esc(DEP_KIND[x.itemKind] || x.itemKind)}</td>
        <td>${esc(x.itemName)}</td><td>${esc(x.detail || "")}</td><td>${x.isBlocker ? '<span class="adc-chip adc-st-bad">Blocker</span>' : ""}</td></tr>`).join("")
      || empty(4, "Nothing relies on or refers to this asset.");
    document.getElementById("adcSrHistBody").innerHTML = (d.reviews || []).map(r => {
      const [hl, hc] = REVIEW[r.reviewStatus] || [r.reviewStatus, ""];
      return `<tr><td>${esc(dateTime(r.openedDt))}<div class="adc-note">${esc(r.openedBy || "")}</div></td><td><span class="adc-chip ${hc}">${esc(hl)}</span></td>
        <td>${esc(r.sourceOutcome ? label(r.sourceOutcome) : "--")}<div class="adc-note">${esc(r.sourceNote || "")}</div></td>
        <td>${esc(r.dependencyNote || "--")}${r.dependencyBlockers ? `<div class="adc-note">${esc(r.dependencyBlockers)} blocker(s)</div>` : ""}</td>
        <td>${esc(r.decisionNote || "--")}${r.changeResult ? `<div class="adc-note">lifecycle ${esc(label(r.changeResult))}</div>` : ""}</td>
        <td>${esc(dateTime(r.closedDt) || "--")}<div class="adc-note">${esc(r.closedBy || "")}</div></td></tr>`;
    }).join("") || empty(6, "No reviews yet.");
    document.getElementById("adcStaleModal").hidden = false;
  }

  async function startStaleReview() {
    const a = state.stale && state.stale.asset;
    if (!a) return;
    const res = await api("POST", "/discovery/stale/reviews", { organizationId: state.organizationId, assetId: a.assetId });
    if (!res.ok) { show("adcSrMessage", res.error); return; }
    await openStale(a.assetId);
    show("adcSrMessage", "Review started. Record the source confirmation and the dependency review.", "success");
    await refreshStale();
  }

  async function staleAction(action, noteId) {
    const a = state.stale && state.stale.asset;
    if (!a || !a.reviewId) return;
    if (action === "REQUEST_DECOMMISSION" && window.gracUi && window.gracUi.confirm
        && !(await window.gracUi.confirm("Request decommission of this asset? It moves to Pending Decommission through its lifecycle rules."))) return;
    const res = await api("POST", `/discovery/stale/reviews/${a.reviewId}/action`, {
      organizationId: state.organizationId, action, sourceOutcome: action === "CONFIRM_SOURCE" ? val("adcSrOutcome") : null,
      note: val(noteId), expectedRecordVersion: a.recordVersion
    });
    if (!res.ok) { show("adcSrMessage", res.error); return; }
    const done = { CONFIRM_SOURCE: "Source confirmation recorded.", REVIEW_DEPENDENCIES: "Dependency review recorded.", DISMISS: "Review dismissed.",
                   REQUEST_DECOMMISSION: "Decommission requested; see the asset Lifecycle tab in the Asset Register." };
    await openStale(a.assetId);
    show("adcSrMessage", res.data.result === "DISMISSED" && action === "CONFIRM_SOURCE" ? "The source still holds the asset: review closed (still in use)." : done[action], "success");
    await refreshStale();
  }

  // ------------------------------------------------------------------ settings
  async function saveSettings() {
    const res = await api("POST", "/discovery/settings", {
      organizationId: state.organizationId, autoMatchScore: num("adcSetAuto"), suggestedScore: num("adcSetSug"),
      manualReviewScore: num("adcSetMan"), staleMultiplier: num("adcSetStale"), verificationDays: num("adcSetVerify"),
      createConflictTasks: document.getElementById("adcSetTasks").checked
    });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    await loadConfig();
    showMessage("Settings saved; the rule-set version was raised.", "success");
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
  function splitKeys(v) { return String(v || "").split(",").map(k => k.trim()).filter(Boolean); }
  function pretty(json) { if (!json) return ""; try { return JSON.stringify(JSON.parse(json), null, 2); } catch (_) { return String(json); } }
  function label(code) { return code ? String(code).replace(/_/g, " ").toLowerCase().replace(/^./, c => c.toUpperCase()) : ""; }
  function empty(cols, text) { return `<tr><td colspan="${cols}" class="pm-empty">${esc(text)}</td></tr>`; }
  function showMessage(text, kind) {
    const el = document.getElementById("adcMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.classList.toggle("info", kind === "info"); el.hidden = !text;
  }
  function hideMessage() { const el = document.getElementById("adcMessage"); el.hidden = true; el.textContent = ""; }
  function show(id, text, kind) {
    const el = document.getElementById(id);
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.hidden = !text;
  }
  function hide(id) { const el = document.getElementById(id); el.hidden = true; el.textContent = ""; el.classList.remove("success"); }
  function val(id) { const el = document.getElementById(id); return el ? (el.value || "").trim() : ""; }
  function num(id) { const v = val(id); return v === "" || isNaN(Number(v)) ? null : Number(v); }
  function date(v) { return v ? String(v).substring(0, 10) : ""; }   // SQL DATE values: yyyy-mm-dd
  function dateTime(v) { if (!v) return ""; const x = new Date(v); return isNaN(x) ? String(v) : x.toLocaleString(); }
  function esc(v) { return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
})();
