// =====================================================================
// Asset Register (migration 428) -- BRD 5 / 5.1.14 / 5.1.16 / 5.2.1.
// Loaded by asset-register.cshtml. The form is built from the asset
// type's form template (sections, fields, rules, option lists); live
// visibility / mandatory comes from the same rule engine the save uses
// (register/evaluate -> fn_asset_form_evaluate). Every rule is enforced by
// sp_asset_register_save; this screen only mirrors it and shows its issues.
// 429: Lifecycle tab -- the configured moves from the asset's status with
// their BRD gates (register/{id}/lifecycle), moves through
// register/{id}/transition, approve / reject / cancel through
// register/lifecycle-changes/{id}/decide, and the whole matrix
// (register/lifecycle-matrix). Gates are enforced by the procedures.
// 430: Technology tab -- register/{id}/technology (status, recommended
// target, classification, installation history, exceptions), installations
// through register/{id}/technology/installations, exception requests through
// register/{id}/technology/exceptions and decisions through
// register/technology-exceptions/{id}/decide.
// 431: Custody tab -- register/{id}/custody (verification state, profile,
// owner / custodian / location history, acknowledgements and attestations).
// 432: the Custody tab also lists the asset's verification exceptions.
// 433: Workflows tab -- register/workflows/definitions, register/workflows
// (cases), register/workflows/{id} (case, steps, history), register/{id}/
// workflows (start), register/workflows/{id}/step and /cancel.
// 443: opened with ?discoveryException={id} (Asset Discovery -> Register),
// New asset is prefilled from the observed values of that reconciliation
// exception (discovery/exceptions/{id}/candidate; list values matched by
// value or label) and, once saved as Draft, the source record is linked to
// it (discovery/exceptions/{id}/resolve, action REGISTER).
// 446: Valuation tab -- register/{id}/valuation (stored Asset Value, what the
// Active configuration gives now, history), register/{id}/valuation/
// recalculate and register/{id}/valuation/method (override). The rules
// (automatic recalculation, reason, override permission) are in the
// procedures.
// 447: the Valuation tab lists the asset's consistency findings and linked
// risks (register/{id}/valuation); findings are acted on through
// register/consistency/findings/{id}/action, re-evaluated through
// register/consistency/run; register/consistency/findings is the worklist.
// 448: Privacy tab -- register/{id}/privacy (status, gaps, exceptions,
// reviews), read-only; "Open in Asset Privacy" goes to the asset-privacy
// screen with ?organizationId=&assetId=, where they are acted on.
// 450: opened with ?organizationId=&assetId= (Asset Governance drill-down)
// the asset is opened.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config/register";
  const discoveryBase = "/practice/api/asset-config/discovery";   // 443
  const root = document.getElementById("argRoot");
  if (!root) return;
  const CAN_ADD = root.dataset.canAdd === "1";
  const CAN_EDIT = root.dataset.canEdit === "1";
  const CAN_APPROVE = root.dataset.canApprove === "1";

  // BRD 5 lifecycle statuses (seeded by 428 on entity Asset), for the filter.
  const STATUSES = [
    ["DRAFT", "Draft"], ["REQUESTED", "Requested"], ["APPROVED", "Approved"], ["ORDERED", "Ordered"], ["RECEIVED", "Received"],
    ["UNDER_INSPECTION", "Under Inspection"], ["PENDING_INSTALLATION", "Pending Installation"], ["PENDING_COMMISSIONING", "Pending Commissioning"],
    ["ACTIVE", "Active"], ["MAINTENANCE", "Maintenance"], ["REPAIR", "Repair"], ["OUT_OF_SERVICE", "Out of Service"], ["QUARANTINED", "Quarantined"],
    ["STORAGE", "Storage"], ["TRANSFER_PENDING", "Transfer Pending"], ["TRANSFERRED", "Transferred"], ["OWNER_CHANGE_PENDING", "Owner Change Pending"],
    ["LOST", "Lost"], ["STOLEN", "Stolen"], ["RECALLED", "Recalled"], ["OBSOLETE", "Obsolete"], ["NON_COMPLIANT", "Non-Compliant"],
    ["PENDING_DECOMMISSION", "Pending Decommission"], ["SANITIZATION_PENDING", "Sanitization Pending"], ["DISPOSAL_APPROVAL", "Disposal Approval"],
    ["DISPOSED", "Disposed"], ["ARCHIVED", "Archived"]
  ];
  // Data types the user does not enter (420 seed: is_user_entered = 0).
  const SYSTEM_TYPES = new Set(["AUTO", "CALCULATED", "SYSTEM", "DATETIME", "APPROVAL_REF"]);
  // Lookups the register sets from the asset type / organization, not the user.
  const FIXED_SOURCES = new Set(["MASTER:ASSET_CATEGORY", "MASTER:ASSET_SUBCATEGORY", "MASTER:ASSET_TYPE", "MASTER:ORGANIZATION"]);
  // Masters without a table yet: entered as text (428).
  const TEXT_SOURCES = new Set(["MASTER:COUNTRY", "MASTER:CURRENCY"]);
  const MULTI_TYPES = new Set(["MULTI_SELECT", "MULTI_USER"]);

  const state = {
    organizationId: null, pager: null, lookups: {},
    asset: null, history: [], stored: {}, form: null, typeId: null,
    ruleSources: new Set(), evalState: {}, decisions: {}, evalTimer: null,
    lifecycle: null, move: null, tech: null, installKind: null, custody: null,
    wfDefs: null, wfCase: null,
    discovery: null,  // 443: { exceptionId, recordVersion, sourceName, externalKey, values }
    valuation: null,  // 446: { current, history } (+ 447: risks, findings)
    consFinding: null, consFrom: null, consList: [],  // 447
    privacy: null     // 448: { status, gaps, exceptions, reviews }
  };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    state.pager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "argPager", onChange: refreshList }) : null;
    document.getElementById("argStatusFilter").innerHTML = `<option value="">All statuses</option>`
      + STATUSES.map(([c, n]) => `<option value="${c}">${esc(n)}</option>`).join("");
    bind();
    await populateOrgs();
    const sel = document.getElementById("argOrg");
    window.gracOrgPref.apply(sel);   // 2026-10-06: last-picked org, else lowest id
    // 443: Asset Discovery -> Register passes the organization and the exception.
    const params = new URLSearchParams(window.location.search);
    const orgParam = params.get("organizationId");
    if (orgParam && [...sel.options].some(o => o.value === orgParam)) sel.value = orgParam;
    // 451: opened from the Asset & Contract dashboard -- organization, tab and filter (Shared/dashboard-drill.js).
    const dashDrill = window.__pmDrill ? window.__pmDrill.read() : null;
    window.__pmDrill?.preselectFor(dashDrill, sel, { "": { status: "argStatusFilter", pending: "argPendingOnly" } });
    await changeOrg(Number(sel.value) || null);
    window.__pmDrill?.showOnPage("argRoot", null, dashDrill);
    const excParam = Number(params.get("discoveryException"));
    if (excParam > 0 && state.organizationId) await startFromDiscovery(excParam);
    const assetParam = Number(params.get("assetId"));                     // 450
    if (!(excParam > 0) && assetParam > 0 && state.organizationId) await openAsset(assetParam);
  }

  // 443: New asset prefilled from a discovery candidate (New candidate / Manual review).
  async function startFromDiscovery(exceptionId) {
    const res = await api("GET", `/exceptions/${exceptionId}/candidate?organizationId=${state.organizationId}`, null, discoveryBase);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    const d = res.data.data, x = d.exception;
    if (x.status !== "OPEN" || !["NEW_CANDIDATE", "MANUAL_REVIEW"].includes(x.exceptionKind)) {
      showMessage("This discovery record is no longer an open new candidate; register the asset normally or link it in Asset Discovery.", "info");
      return;
    }
    if (!CAN_ADD) { showMessage("Registering an asset needs the Add permission on the Asset Register.", "error"); return; }
    const values = {};
    (d.attributes || []).forEach(a => { values[a.fieldKey] = a.observedValue; });
    state.discovery = { exceptionId: x.exceptionId, recordVersion: x.recordVersion, sourceName: x.sourceName, externalKey: x.externalKey, values };
    openNew();
    showMessage(`Registering the discovery record ${x.externalKey || "#" + x.exceptionId} from ${x.sourceName}: choose the asset type; `
      + "the form is prefilled from the observed values. The asset is saved as Draft and the source record is linked to it.", "info");
  }

  // 443: the observed value for a field of a new asset, when it fits the field.
  function discoveryValue(f) {
    if (!state.discovery || state.asset || MULTI_TYPES.has(f.dataTypeCode)) return null;
    const v = state.discovery.values[f.fieldKey];
    if (v == null || v === "") return null;
    const opts = optionsFor(f);
    if (opts) {
      const t = String(v).trim().toLowerCase();
      const hit = opts.find(o => String(o.value).toLowerCase() === t) || opts.find(o => String(o.label ?? "").trim().toLowerCase() === t);
      return hit ? String(hit.value) : null;
    }
    return f.dataTypeCode === "DATE" ? String(v).substring(0, 10) : String(v);
  }

  async function populateOrgs() {
    const sel = document.getElementById("argOrg");
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
    document.getElementById("argOrg").addEventListener("change", e => changeOrg(Number(e.target.value) || null));
    document.getElementById("argRefresh").addEventListener("click", () => refreshList());
    let t = null;
    document.getElementById("argSearch").addEventListener("input", () => { clearTimeout(t); t = setTimeout(() => { state.pager?.reset(true); refreshList(); }, 300); });
    ["argTypeFilter", "argStatusFilter", "argPendingOnly"].forEach(id => document.getElementById(id).addEventListener("change", () => { state.pager?.reset(true); refreshList(); }));
    document.getElementById("argMatrixBtn").addEventListener("click", openMatrix);
    document.querySelectorAll("[data-close-arg]").forEach(b => b.addEventListener("click", () => { document.getElementById(b.dataset.closeArg).hidden = true; }));
    document.getElementById("argMoves").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-arg-move]");
      if (b) openMove(b.dataset.argMove);
    });
    document.getElementById("argPending").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-arg-decide]");
      if (b) decide(Number(b.dataset.argChange), b.dataset.argDecide);
    });
    document.getElementById("argMoveForm").addEventListener("submit", ev => { ev.preventDefault(); submitMove(); });
    document.getElementById("argTechPanel").addEventListener("click", ev => {
      const inst = ev.target.closest("button[data-arg-install]");
      if (inst) { openInstall(inst.dataset.argInstall); return; }
      if (ev.target.closest("button[data-arg-exc-new]")) { openException(); return; }
      const d = ev.target.closest("button[data-arg-exc-decide]");
      if (d) decideException(Number(d.dataset.argExc), d.dataset.argExcDecide);
    });
    document.getElementById("argInstallForm").addEventListener("submit", ev => { ev.preventDefault(); submitInstall(); });
    document.getElementById("argExcForm").addEventListener("submit", ev => { ev.preventDefault(); submitException(); });
    document.getElementById("argExcKind").addEventListener("change", () => fillExceptionReleases());
    // 433
    document.getElementById("argWfStartBtn")?.addEventListener("click", openWorkflowStart);
    document.getElementById("argWfForm").addEventListener("submit", ev => { ev.preventDefault(); submitWorkflowStart(); });
    document.getElementById("argWfSite").addEventListener("change", () => fillDestination("site"));
    document.getElementById("argWfBuilding").addEventListener("change", () => fillDestination("building"));
    document.getElementById("argWfFloor").addEventListener("change", () => fillDestination("floor"));
    document.getElementById("argWfPanel").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-arg-wf-act]");
      if (b) workflowAction(b.dataset.argWfAct);
    });
    document.getElementById("argWfListBtn").addEventListener("click", openWorkflowList);
    // 446
    document.getElementById("argValRecalc")?.addEventListener("click", recalcValuation);
    document.getElementById("argValOverride")?.addEventListener("click", openValOverride);
    document.getElementById("argPrivOpen").addEventListener("click", openPrivacyScreen);   // 448
    document.getElementById("argValForm").addEventListener("submit", ev => { ev.preventDefault(); submitValOverride(); });
    // 447
    document.getElementById("argConsBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-arg-cons-act]");
      if (b) consAction(Number(b.dataset.argCons), b.dataset.argConsAct, "asset");
    });
    document.getElementById("argConsRun")?.addEventListener("click", () => runConsistency(true));
    document.getElementById("argConsForm").addEventListener("submit", ev => { ev.preventDefault(); submitConsAccept(); });
    document.getElementById("argConsListBtn").addEventListener("click", openConsList);
    ["argConsStatus", "argConsSeverity"].forEach(id => document.getElementById(id).addEventListener("change", loadConsList));
    let ct = null;
    document.getElementById("argConsSearch").addEventListener("input", () => { clearTimeout(ct); ct = setTimeout(loadConsList, 300); });
    document.getElementById("argConsRunAll")?.addEventListener("click", () => runConsistency(false));
    document.getElementById("argConsListBody").addEventListener("click", ev => {
      const act = ev.target.closest("button[data-arg-cons-act]");
      if (act) { consAction(Number(act.dataset.argCons), act.dataset.argConsAct, "list"); return; }
      const open = ev.target.closest("button[data-arg-cons-asset]");
      if (!open) return;
      document.getElementById("argConsListModal").hidden = true;
      openAsset(Number(open.dataset.argConsAsset)).then(() => selectTab("valuation"));
    });
    document.getElementById("argWfListBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-arg-wf-asset]");
      if (!b) return;
      document.getElementById("argWfListModal").hidden = true;
      openAsset(Number(b.dataset.argWfAsset)).then(() => selectTab("workflows"));
    });
    document.getElementById("argNewBtn")?.addEventListener("click", () => openNew());
    document.getElementById("argListBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-arg-id]");
      if (tr) openAsset(Number(tr.dataset.argId));
    });
    document.getElementById("argBack").addEventListener("click", showList);
    document.getElementById("argCat").addEventListener("change", () => fillTypeStep("cat"));
    document.getElementById("argSub").addEventListener("change", () => fillTypeStep("sub"));
    document.getElementById("argTypeGo").addEventListener("click", () => {
      const typeId = Number(val("argType"));
      if (!typeId) { showMessage("Choose the asset type.", "error"); return; }
      loadForm(typeId, null);
    });
    document.getElementById("argSave").addEventListener("click", save);
    document.getElementById("argForm").addEventListener("change", onFieldChange);
    document.getElementById("argIssues").addEventListener("change", ev => {
      const r = ev.target.closest("input[data-arg-decision]");
      if (r) state.decisions[r.dataset.argDecision] = r.value;
    });
    document.querySelectorAll("[data-arg-tab]").forEach(b => b.addEventListener("click", () => selectTab(b.dataset.argTab)));
  }

  function selectTab(name) {
    document.querySelectorAll("[data-arg-tab]").forEach(x => { const on = x.dataset.argTab === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    document.querySelectorAll("[data-arg-panel]").forEach(p => { p.hidden = p.dataset.argPanel !== name; });
  }

  async function changeOrg(id) {
    state.organizationId = id;
    state.lookups = {};
    state.wfDefs = null;
    showList();
    if (!id) return;
    await ensureLookups(["MASTER:ASSET_CATEGORY", "MASTER:ASSET_SUBCATEGORY", "MASTER:ASSET_TYPE"]);
    const f = document.getElementById("argTypeFilter");
    f.innerHTML = `<option value="">All asset types</option>` + (state.lookups["MASTER:ASSET_TYPE"] || [])
      .map(t => `<option value="${esc(t.value)}">${esc(t.label)}</option>`).join("");
    state.pager?.reset(true);
    await refreshList();
  }

  // ------------------------------------------------------------------ list
  async function refreshList() {
    const body = document.getElementById("argListBody");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); state.pager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId, pageNumber: state.pager ? state.pager.page() : 1, pageSize: state.pager ? state.pager.size() : 25 });
    if (val("argSearch")) qs.set("search", val("argSearch"));
    if (val("argTypeFilter")) qs.set("assetTypeId", val("argTypeFilter"));
    if (val("argStatusFilter")) qs.set("statusCode", val("argStatusFilter"));
    if (document.getElementById("argPendingOnly").checked) qs.set("pendingOnly", "true");
    const res = await api("GET", `?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.pager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.pager?.setTotal(res.data.data.totalRows, rows.length);
    body.innerHTML = rows.map(r => `
      <tr class="pm-row-clickable" data-arg-id="${r.assetId}">
        <td>${esc(r.assetName)}<div class="arg-note">#${esc(r.assetId)}</div></td>
        <td>${esc(r.assetTypeName || "--")}<div class="arg-note">${esc([r.categoryName, r.subcategoryName].filter(Boolean).join(" / "))}</div></td>
        <td>${statusChip(r.statusName, r.phaseName)}${r.pendingChangeId ? `<div class="arg-note">Awaiting approval: ${esc(r.pendingToStatusName)}</div>` : ""}</td>
        <td>${esc(r.ownerName || "--")}</td>
        <td>${esc(r.locationName || "--")}</td>
        <td>${esc(r.criticalityName || "--")}</td>
        <td>${r.templateId ? "v" + esc(r.templateVersion) : `<span class="arg-note">Not on a form</span>`}</td>
        <td>${esc(dateTime(r.lastChanged))}</td>
      </tr>`).join("") || empty(8, "No assets match.");
  }

  function showList() {
    document.getElementById("argAssetView").hidden = true;
    document.getElementById("argListView").hidden = false;
    state.asset = null; state.form = null;
    if (state.organizationId) refreshList();
  }

  // ------------------------------------------------------------------ open
  function resetAssetView(title, meta) {
    document.getElementById("argListView").hidden = true;
    document.getElementById("argAssetView").hidden = false;
    document.getElementById("argTitle").textContent = title;
    document.getElementById("argMeta").innerHTML = meta;
    document.getElementById("argTypeStep").hidden = true;
    document.getElementById("argFormPanel").hidden = true;
    document.getElementById("argSave").hidden = true;
    hideMessage(); renderIssues([]);
    state.decisions = {}; state.evalState = {};
    state.lifecycle = null; state.tech = null;
    document.getElementById("argLifecycleTab").hidden = true;
    document.getElementById("argTechTab").hidden = true;
    document.getElementById("argCustodyTab").hidden = true;
    document.getElementById("argCoverageTab").hidden = true;   // 435
    document.getElementById("argValTab").hidden = true;        // 446
    state.valuation = null;
    document.getElementById("argPrivTab").hidden = true;       // 448
    state.privacy = null;
    state.custody = null;
    document.getElementById("argWorkflowTab").hidden = true;
    state.wfCase = null;
    selectTab("details");
  }

  function openNew() {
    state.asset = null; state.stored = {}; state.history = [];
    resetAssetView("New asset", "");
    fillTypeStep("init");
    document.getElementById("argTypeStep").hidden = false;
  }

  async function openAsset(id) {
    const res = await api("GET", `/${id}?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    const d = res.data.data;
    state.asset = d.asset;
    state.history = d.history || [];
    state.stored = {};
    (d.values || []).forEach(v => { state.stored[v.fieldKey] = v.value; });
    const a = d.asset;
    resetAssetView(a.assetName, `${statusChip(a.statusName, a.phaseName)} <span class="arg-note">#${esc(a.assetId)}</span>`
      + (a.templateId ? ` <span class="arg-note">- form ${esc(a.templateName)} v${esc(a.templateVersion)}`
         + (a.activeTemplateId && a.activeTemplateId !== a.templateId ? ` (v${esc(a.activeTemplateVersion)} is now Active; moving an asset to a newer version needs an approved migration)` : "") + "</span>" : ""));
    renderHistory();
    await loadLifecycle();
    await loadTechnology();
    await loadCustody();
    await loadCoverage();   // 435
    await loadValuation();  // 446
    await loadPrivacy();    // 448
    await loadWorkflows();
    if (!a.assetTypeId) {
      showMessage("This asset was created before asset types existed. Choose its asset type to open the form.", "info");
      fillTypeStep("init");
      document.getElementById("argTypeStep").hidden = false;
      return;
    }
    await loadForm(a.assetTypeId, a.templateId || null);
  }

  // Category -> subcategory -> asset type, from the taxonomy in effect (424).
  function fillTypeStep(changed) {
    const cats = state.lookups["MASTER:ASSET_CATEGORY"] || [], subs = state.lookups["MASTER:ASSET_SUBCATEGORY"] || [],
          types = state.lookups["MASTER:ASSET_TYPE"] || [];
    const opt = (rows, sel) => `<option value="">Select</option>` + rows.map(r => `<option value="${esc(r.value)}"${String(r.value) === String(sel) ? " selected" : ""}>${esc(r.label)}</option>`).join("");
    if (changed === "init") {
      document.getElementById("argCat").innerHTML = opt(cats, "");
      document.getElementById("argSub").innerHTML = opt([], "");
      document.getElementById("argType").innerHTML = opt([], "");
      return;
    }
    if (changed === "cat") {
      document.getElementById("argSub").innerHTML = opt(subs.filter(s => String(s.parentValue) === val("argCat")), "");
      document.getElementById("argType").innerHTML = opt([], "");
    }
    if (changed === "sub")
      document.getElementById("argType").innerHTML = opt(types.filter(t => String(t.parentValue) === val("argSub")), "");
  }

  // ------------------------------------------------------------------ form
  async function loadForm(typeId, templateId) {
    const qs = new URLSearchParams({ organizationId: state.organizationId });
    if (templateId) qs.set("templateId", templateId); else qs.set("assetTypeId", typeId);
    const res = await api("GET", `/form?${qs}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.form = res.data.data;
    state.typeId = typeId;
    const sources = [...new Set(state.form.fields.map(f => f.lookupSource).filter(s => s && s.startsWith("MASTER:") && !TEXT_SOURCES.has(s) && s !== "MASTER:CONTRACT"))];
    await ensureLookups(sources);
    state.ruleSources = new Set((state.form.conditions || []).map(c => c.sourceFieldKey));
    document.getElementById("argTypeStep").hidden = true;
    document.getElementById("argFormPanel").hidden = false;
    const canWrite = state.asset ? CAN_EDIT : CAN_ADD;
    document.getElementById("argSave").hidden = !canWrite;
    if (!state.asset) {
      document.getElementById("argTitle").textContent = `New ${state.form.header.assetTypeName}`;
      document.getElementById("argMeta").innerHTML = `<span class="arg-note">Form ${esc(state.form.header.templateName)} v${esc(state.form.header.versionNo)} - saved assets start as Draft</span>`;
    }
    renderForm(canWrite);
    await evaluate();
  }

  async function ensureLookups(sources) {
    const missing = sources.filter(s => !state.lookups[s]);
    if (!missing.length) return;
    const res = await api("GET", `/lookups?organizationId=${state.organizationId}&sources=${encodeURIComponent(missing.join(","))}`);
    missing.forEach(s => { state.lookups[s] = []; });
    if (res.ok) (res.data.data || []).forEach(r => { (state.lookups[r.source] = state.lookups[r.source] || []).push(r); });
  }

  function isEditable(f) {
    return !SYSTEM_TYPES.has(f.dataTypeCode) && f.storageKind !== "SYSTEM" && !f.isReadOnly && !FIXED_SOURCES.has(f.lookupSource);
  }

  function initialValue(f) {
    if (FIXED_SOURCES.has(f.lookupSource)) {
      if (f.lookupSource === "MASTER:ASSET_TYPE") return String(state.typeId);
      if (f.lookupSource === "MASTER:ORGANIZATION") return String(state.organizationId);
      const type = (state.lookups["MASTER:ASSET_TYPE"] || []).find(t => String(t.value) === String(state.typeId));
      const sub = type && (state.lookups["MASTER:ASSET_SUBCATEGORY"] || []).find(s => String(s.value) === String(type.parentValue));
      if (f.lookupSource === "MASTER:ASSET_SUBCATEGORY") return state.stored[f.fieldKey] ?? (sub ? String(sub.value) : "");
      return state.stored[f.fieldKey] ?? (sub ? String(sub.parentValue) : "");
    }
    if (f.fieldKey in state.stored) return state.stored[f.fieldKey];
    return state.asset ? "" : (discoveryValue(f) ?? f.defaultValue ?? "");   // 443
  }

  function optionsFor(f) {
    if (!f.lookupSource) return null;
    if (f.lookupSource.startsWith("MASTER:")) return (state.lookups[f.lookupSource] || []).map(r => ({ value: String(r.value), label: r.label, parent: r.parentValue }));
    return (state.form.options || []).filter(o => o.fieldDefinitionId === f.fieldDefinitionId)
      .sort((a, b) => (a.displayOrder ?? 0) - (b.displayOrder ?? 0))
      .map(o => ({ value: String(o.optionValue), label: o.optionLabel, parent: o.parentValue }));
  }

  function renderForm(canWrite) {
    const form = document.getElementById("argForm");
    const sections = (state.form.sections || []).filter(s => s.isActive !== false).sort((a, b) => a.displayOrder - b.displayOrder);
    form.innerHTML = sections.map(s => {
      const fields = state.form.fields.filter(f => f.sectionId === s.sectionId).sort((a, b) => a.displayOrder - b.displayOrder);
      if (!fields.length) return "";
      return `<div class="arg-section"><h3>${esc(s.sectionLabel)}</h3><div class="pm-form-grid">${fields.map(f => fieldHtml(f, canWrite)).join("")}</div></div>`;
    }).join("") || `<p class="pm-empty">The form template has no fields.</p>`;
    filterModels();
  }

  function fieldHtml(f, canWrite) {
    const v = initialValue(f);
    const editable = canWrite && isEditable(f);
    const id = `argF_${f.fieldKey}`;
    const dis = editable ? "" : " disabled";
    const full = ["MULTILINE", "MULTI_SELECT", "MULTI_USER"].includes(f.dataTypeCode) ? " full" : "";
    const ph = f.placeholderText ? ` placeholder="${esc(f.placeholderText)}"` : "";
    let control;
    const opts = optionsFor(f);
    if (f.fieldKey === "asset_status") {
      control = `<input type="text" id="${id}" value="${esc(state.asset?.statusName || "Draft")}" disabled />`;
    } else if (f.lookupSource === "MASTER:CONTRACT") {
      control = `<input type="text" id="${id}" value="" disabled placeholder="Linked once contracts are available" />`;
    } else if (!editable && (SYSTEM_TYPES.has(f.dataTypeCode) || f.storageKind === "SYSTEM")) {
      control = `<input type="text" id="${id}" value="${esc(displayOf(f, v))}" disabled />`;
    } else if (opts && !TEXT_SOURCES.has(f.lookupSource) && f.dataTypeCode !== "TEXT") {
      const multi = MULTI_TYPES.has(f.dataTypeCode);
      const chosen = new Set(multi ? parseArray(v) : [String(v ?? "")]);
      control = `<select id="${id}" data-key="${esc(f.fieldKey)}"${multi ? " multiple size=\"5\"" : ""}${dis}>`
        + (multi ? "" : `<option value="">Select</option>`)
        + opts.map(o => `<option value="${esc(o.value)}" data-parent="${esc(o.parent ?? "")}"${chosen.has(o.value) ? " selected" : ""}>${esc(o.label)}</option>`).join("")
        + `</select>`;
    } else if (f.dataTypeCode === "YES_NO") {
      control = `<select id="${id}" data-key="${esc(f.fieldKey)}"${dis}><option value="">Select</option>`
        + ["Yes", "No"].map(x => `<option value="${x}"${v === x ? " selected" : ""}>${x}</option>`).join("") + `</select>`;
    } else if (f.dataTypeCode === "MULTILINE") {
      control = `<textarea id="${id}" data-key="${esc(f.fieldKey)}" rows="3"${ph}${dis}>${esc(v)}</textarea>`;
    } else if (f.dataTypeCode === "DATE") {
      control = `<input type="date" id="${id}" data-key="${esc(f.fieldKey)}" value="${esc(String(v || "").substring(0, 10))}"${dis} />`;
    } else if (["DECIMAL", "CURRENCY", "PERCENT"].includes(f.dataTypeCode)) {
      control = `<input type="number" step="any" id="${id}" data-key="${esc(f.fieldKey)}" value="${esc(v)}"${ph}${f.dataTypeCode === "PERCENT" ? " min=\"0\" max=\"100\"" : ""}${dis} />`;
    } else if (f.dataTypeCode === "QUANTITY_UNIT") {
      const [num, ...unit] = String(v || "").split(" ");
      control = `<span class="arg-qty"><input type="number" step="any" id="${id}" data-key="${esc(f.fieldKey)}" data-qty="n" value="${esc(num)}"${dis} />`
        + `<input type="text" data-key="${esc(f.fieldKey)}" data-qty="u" value="${esc(unit.join(" "))}" placeholder="unit"${dis} /></span>`;
    } else {
      control = `<input type="text" id="${id}" data-key="${esc(f.fieldKey)}" value="${esc(v)}"${ph}${dis} />`;
    }
    return `<label class="arg-field${full}" data-field="${esc(f.fieldKey)}">
      <span>${esc(f.displayLabel)} <b class="arg-req" hidden>*</b></span>${control}
      ${f.helpText ? `<small class="arg-help">${esc(f.helpText)}</small>` : ""}</label>`;
  }

  function displayOf(f, v) {
    if (v == null || v === "") return "";
    const opts = optionsFor(f);
    if (opts) { const o = opts.find(x => x.value === String(v)); if (o) return o.label; }
    return f.dataTypeCode === "DATETIME" ? dateTime(v) : String(v);
  }

  // Make selection filters models (5.1.14).
  function filterModels() {
    const make = document.querySelector('#argForm select[data-key="manufacturer_make"]');
    const model = document.querySelector('#argForm select[data-key="model"]');
    if (!model) return;
    const m = make ? make.value : "";
    Array.from(model.options).forEach(o => { if (o.value) o.hidden = !!m && o.dataset.parent !== m; });
    if (model.selectedOptions[0]?.hidden) model.value = "";
  }

  function readValues() {
    const out = {};
    document.querySelectorAll("#argForm [data-key]").forEach(el => {
      const key = el.dataset.key;
      if (el.dataset.qty) {
        const n = document.querySelector(`#argForm [data-key="${cssEsc(key)}"][data-qty="n"]`).value.trim();
        const u = document.querySelector(`#argForm [data-key="${cssEsc(key)}"][data-qty="u"]`).value.trim();
        out[key] = n === "" ? null : (u ? `${n} ${u}` : n);
        return;
      }
      if (el.multiple) { const a = Array.from(el.selectedOptions).map(o => o.value); out[key] = a.length ? a : null; return; }
      out[key] = el.value.trim() === "" ? null : el.value.trim();
    });
    return out;
  }

  function onFieldChange(ev) {
    const key = ev.target.dataset.key;
    if (key === "manufacturer_make") filterModels();
    if (key && state.ruleSources.has(key)) { clearTimeout(state.evalTimer); state.evalTimer = setTimeout(evaluate, 150); }
  }

  // Live visibility / mandatory from the template rules (same engine as the save).
  async function evaluate() {
    if (!state.form) return;
    const values = { ...state.stored, ...readValues() };
    Object.keys(values).forEach(k => { if (values[k] == null) delete values[k]; });
    const res = await api("POST", "/evaluate", { organizationId: state.organizationId, templateId: state.form.header.templateId, values });
    if (!res.ok) return;
    (res.data.data.fields || []).forEach(f => {
      state.evalState[f.fieldKey] = f;
      const wrap = document.querySelector(`#argForm [data-field="${cssEsc(f.fieldKey)}"]`);
      if (!wrap) return;
      wrap.hidden = !f.isVisible;
      wrap.querySelector(".arg-req").hidden = !f.isMandatory;
    });
  }

  // ------------------------------------------------------------------ save
  async function save() {
    if (!state.form) return;
    const a = state.asset;
    const values = readValues();
    const res = await api("POST", "", {
      organizationId: state.organizationId, assetId: a ? a.assetId : null, assetTypeId: state.typeId,
      values, hiddenDecisions: state.decisions, expectedRecordVersion: a ? a.recordVersion : null
    });
    const body = res.data || {};
    if (res.ok && body.result === "SAVED") {
      const warnings = (body.issues || []).filter(i => i.severity === "WARNING");
      const linked = !a && state.discovery ? await linkDiscovery(body.id) : null;   // 443
      await openAsset(body.id);
      showMessage(linked || (warnings.length ? "Saved with warnings -- see below." : "Asset saved."), linked && linked.startsWith("Saved") ? "info" : "success");
      renderIssues(warnings);
      return;
    }
    if (body.issues && body.issues.length) {
      showMessage(body.result === "NEEDS_DECISION" ? "Decide what happens to the hidden values below, then save again." : "The asset was not saved. Fix the fields below.", "error");
      renderIssues(body.issues);
      return;
    }
    showMessage(res.error, "error");
    if (res.status === 409 && a) await openAsset(a.assetId);
  }

  function renderIssues(issues) {
    const host = document.getElementById("argIssues");
    document.querySelectorAll("#argForm .arg-invalid").forEach(el => el.classList.remove("arg-invalid"));
    if (!issues.length) { host.hidden = true; host.innerHTML = ""; return; }
    issues.forEach(i => { if (i.severity === "ERROR" && i.fieldKey) document.querySelector(`#argForm [data-field="${cssEsc(i.fieldKey)}"]`)?.classList.add("arg-invalid"); });
    const decisions = issues.filter(i => i.severity === "DECISION");
    const others = issues.filter(i => i.severity !== "DECISION");
    host.innerHTML = (others.length ? `<ul>${others.map(i => `<li class="arg-${i.severity === "ERROR" ? "error" : "warning"}">${esc(i.message)}</li>`).join("")}</ul>` : "")
      + decisions.map(i => `<div class="arg-decision"><span>${esc(i.message)}</span>
          <label class="arg-check"><input type="radio" name="argDec_${esc(i.fieldKey)}" data-arg-decision="${esc(i.fieldKey)}" value="RETAIN"${state.decisions[i.fieldKey] === "RETAIN" ? " checked" : ""} /> Keep</label>
          <label class="arg-check"><input type="radio" name="argDec_${esc(i.fieldKey)}" data-arg-decision="${esc(i.fieldKey)}" value="CLEAR"${state.decisions[i.fieldKey] === "CLEAR" ? " checked" : ""} /> Clear</label></div>`).join("");
    host.hidden = false;
  }

  function renderHistory() {
    document.getElementById("argHistory").innerHTML = (state.history || []).map(x => `
      <tr><td>${esc(dateTime(x.transitionedAt))}</td><td>${esc(x.fromStatus || "--")}</td><td>${esc(x.toStatus)}</td>
          <td>${esc(x.actorName || (x.actorEmployeeId ? "Employee #" + x.actorEmployeeId : "System"))}</td>
          <td>${esc(x.reasonText || x.reasonCode || "")}</td></tr>`).join("") || empty(5, "No history yet.");
  }

  // ------------------------------------------------------------------ lifecycle (429)
  async function loadLifecycle() {
    if (!state.asset) return;
    const res = await api("GET", `/${state.asset.assetId}/lifecycle?organizationId=${state.organizationId}`);
    if (!res.ok) return;
    state.lifecycle = res.data.data;
    document.getElementById("argLifecycleTab").hidden = false;
    renderLifecycle();
  }

  function needsText(m) {
    return [m.requiresReason ? "Reason" : null, m.referenceLabel || null, m.requiresEvidence ? "Evidence" : null,
            m.requiresApproval ? "Approval by another person" : null, m.requiresRegisteredForm ? "Saved on its form" : null,
            m.requiresOwner ? "Owner set" : null].filter(Boolean).join(", ") || "--";
  }

  function renderLifecycle() {
    const lc = state.lifecycle || {}, moves = lc.moves || [], changes = lc.changes || [];
    const pending = changes.find(c => c.changeStatus === "PENDING_APPROVAL");
    const host = document.getElementById("argPending");
    host.hidden = !pending;
    host.innerHTML = !pending ? "" : `
      <strong>Awaiting approval: ${esc(pending.fromStatusName)} &rarr; ${esc(pending.toStatusName)}</strong>
      <div class="arg-note">Requested by ${esc(pending.requestedByName || pending.requestedBy)} on ${esc(dateTime(pending.requestedDt))}</div>
      ${changeDetail(pending)}
      <div class="pm-message info">The person who asked for this change cannot approve or reject it.</div>
      <div class="arg-pending-actions">
        ${CAN_APPROVE ? `<button class="pm-button primary" type="button" data-arg-decide="APPROVE" data-arg-change="${pending.changeId}"><i class="fa-solid fa-check"></i> Approve</button>
        <button class="pm-button" type="button" data-arg-decide="REJECT" data-arg-change="${pending.changeId}"><i class="fa-solid fa-xmark"></i> Reject</button>` : ""}
        ${CAN_EDIT ? `<button class="pm-button" type="button" data-arg-decide="CANCEL" data-arg-change="${pending.changeId}">Cancel request</button>` : ""}
      </div>`;
    document.getElementById("argMoves").innerHTML = pending
      ? empty(4, "No other move while a change is awaiting approval.")
      : moves.map(m => `
        <tr><td>${statusChip(m.toStatusName, m.toPhaseName)}</td>
            <td>${esc(m.minimumGate)}<div class="arg-note">BRD ${esc(m.brdSource)}${m.mappingNote ? " - " + esc(m.mappingNote) : ""}</div></td>
            <td>${esc(needsText(m))}${m.blockedReason ? `<div class="arg-note">${esc(m.blockedReason)}</div>` : ""}</td>
            <td>${CAN_EDIT && !m.blockedReason ? `<button class="pm-button" type="button" data-arg-move="${esc(m.toStatusCode)}">${m.requiresApproval ? "Request" : "Move"}</button>` : ""}</td></tr>`).join("")
        || empty(4, "No move is configured from this status.");
    const outcome = { COMPLETED: "Completed", PENDING_APPROVAL: "Awaiting approval", APPROVED: "Approved", REJECTED: "Rejected", CANCELLED: "Cancelled" };
    document.getElementById("argChanges").innerHTML = changes.map(c => `
      <tr><td>${esc(dateTime(c.requestedDt))}</td><td>${esc(c.fromStatusName)}</td><td>${esc(c.toStatusName)}</td>
          <td>${esc(outcome[c.changeStatus] || c.changeStatus)}${c.decisionNote ? `<div class="arg-note">${esc(c.decisionNote)}</div>` : ""}</td>
          <td>${esc(c.requestedByName || c.requestedBy)}</td>
          <td>${esc(c.decidedByName || c.decidedBy || "--")}${c.decidedDt ? `<div class="arg-note">${esc(dateTime(c.decidedDt))}</div>` : ""}</td>
          <td>${changeDetail(c)}</td></tr>`).join("") || empty(7, "No lifecycle change yet.");
  }

  function changeDetail(c) {
    return [c.reasonText ? `<div>${esc(c.reasonText)}</div>` : "",
            c.referenceText ? `<div class="arg-note">${esc(c.referenceLabel || "Reference")}: ${esc(c.referenceText)}</div>` : "",
            c.evidenceText ? `<div class="arg-note">Evidence: ${esc(c.evidenceText)}</div>` : ""].join("");
  }

  function openMove(code) {
    const m = ((state.lifecycle || {}).moves || []).find(x => x.toStatusCode === code);
    if (!m) return;
    state.move = m;
    document.getElementById("argMoveTitle").textContent = `${m.requiresApproval ? "Request" : "Move"}: ${state.lifecycle.current?.statusName || ""} -> ${m.toStatusName}`;
    document.getElementById("argMoveGate").textContent = `Minimum gate (BRD ${m.brdSource}): ${m.minimumGate}.`
      + (m.requiresApproval ? " This change waits for approval by another person with approval rights." : "");
    document.getElementById("argMoveReasonLabel").textContent = m.requiresReason ? "Reason *" : "Reason";
    document.getElementById("argMoveRefWrap").hidden = !m.referenceLabel;
    document.getElementById("argMoveRefLabel").textContent = `${m.referenceLabel || "Reference"} *`;
    document.getElementById("argMoveEvWrap").hidden = !m.requiresEvidence;
    ["argMoveReason", "argMoveRef", "argMoveEv"].forEach(id => { document.getElementById(id).value = ""; });
    const msg = document.getElementById("argMoveMessage"); msg.hidden = true; msg.textContent = "";
    document.getElementById("argMoveModal").hidden = false;
  }

  async function submitMove() {
    const m = state.move;
    if (!m || !state.asset) return;
    const msg = document.getElementById("argMoveMessage");
    const res = await api("POST", `/${state.asset.assetId}/transition`, {
      organizationId: state.organizationId, toStatusCode: m.toStatusCode,
      reasonText: val("argMoveReason") || null, referenceText: m.referenceLabel ? (val("argMoveRef") || null) : null,
      evidenceText: m.requiresEvidence ? (val("argMoveEv") || null) : null,
      expectedRecordVersion: state.lifecycle?.current?.recordVersion ?? null
    });
    if (!res.ok) { msg.textContent = res.error; msg.hidden = false; return; }
    document.getElementById("argMoveModal").hidden = true;
    await openAsset(state.asset.assetId);
    selectTab("lifecycle");
    showMessage(res.data.result === "PENDING_APPROVAL" ? `Change to ${m.toStatusName} is awaiting approval.` : `Asset moved to ${m.toStatusName}.`, "success");
  }

  async function decide(changeId, decision) {
    const change = ((state.lifecycle || {}).changes || []).find(c => c.changeId === changeId);
    let note = null;
    if (decision === "REJECT") {
      note = await window.gracUi.promptRequired("Why is this change rejected?", { title: "Reject change", inputLabel: "Reason" });
      if (!note) return;
    } else if (!await window.gracUi.confirm(decision === "APPROVE"
      ? `Approve the move to ${change?.toStatusName || "the new status"}? The asset changes status at once.`
      : "Cancel this request?")) return;
    const res = await api("POST", `/lifecycle-changes/${changeId}/decide`, {
      organizationId: state.organizationId, decision, decisionNote: note, expectedRecordVersion: change?.recordVersion ?? null
    });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    await openAsset(state.asset.assetId);
    selectTab("lifecycle");
    showMessage({ APPROVED: "Change approved.", REJECTED: "Change rejected.", CANCELLED: "Request cancelled." }[res.data.result] || "Done.", "success");
  }

  async function openMatrix() {
    const body = document.getElementById("argMatrixBody");
    document.getElementById("argMatrixModal").hidden = false;
    if (!state.organizationId) { body.innerHTML = empty(6, "Select an organization."); return; }
    body.innerHTML = empty(6, "Loading...");
    const res = await api("GET", `/lifecycle-matrix?organizationId=${state.organizationId}`);
    if (!res.ok) { body.innerHTML = empty(6, res.error); return; }
    body.innerHTML = (res.data.data || []).map(m => `
      <tr><td>${esc(m.fromStatusName)}</td><td>${esc(m.toStatusName)}</td><td>${esc(m.brdSource)}</td>
          <td>${esc(m.minimumGate)}${m.mappingNote ? `<div class="arg-note">${esc(m.mappingNote)}</div>` : ""}</td>
          <td>${esc(needsText(m))}</td><td>${m.isActive ? "Yes" : "No"}</td></tr>`).join("") || empty(6, "No transition rules.");
  }

  // ------------------------------------------------------------------ technology (430)
  const KIND_NAME = { FIRMWARE: "Firmware", OS: "Operating system" };
  const CLASS_INFO = {
    CURRENT: ["Current", "arg-ph-operation"], DUE_SOON: ["Due soon", "arg-tc-warn"], UNSUPPORTED: ["Unsupported", "arg-ph-exception"],
    EXCEPTION: ["Exception", "arg-tc-warn"], UNKNOWN: ["Unknown", "arg-ph-acquisition"], NOT_APPLICABLE: ["Not applicable", "arg-ph-retirement"]
  };
  const EXC_STATUS = { PENDING_APPROVAL: "Awaiting approval", APPROVED: "Active", EXPIRED: "Expired", REJECTED: "Rejected", WITHDRAWN: "Withdrawn", REVOKED: "Revoked" };

  async function loadTechnology() {
    if (!state.asset) return;
    const res = await api("GET", `/${state.asset.assetId}/technology?organizationId=${state.organizationId}`);
    if (!res.ok) return;
    state.tech = res.data.data;
    document.getElementById("argTechTab").hidden = false;
    renderTechnology();
  }

  function renderTechnology() {
    const t = state.tech || {};
    document.getElementById("argTechStatus").innerHTML = (t.status || []).map(x => {
      const [cls, css] = CLASS_INFO[x.classification] || [x.classification, "arg-ph-acquisition"];
      return `<tr><td>${esc(KIND_NAME[x.kind] || x.kind)}</td>
        <td>${esc(x.currentLabel || "--")}${x.buildPatchLevel ? `<div class="arg-note">Build / patch ${esc(x.buildPatchLevel)}</div>` : ""}
            ${x.minimumCompliantBuild || x.latestApprovedBuild ? `<div class="arg-note">Minimum compliant ${esc(x.minimumCompliantBuild || "--")}, latest approved ${esc(x.latestApprovedBuild || "--")}</div>` : ""}</td>
        <td>${esc(x.releaseStatusName || "--")}</td>
        <td><span class="arg-chip ${css}">${esc(cls)}</span>${x.classificationReason ? `<div class="arg-note">${esc(x.classificationReason)}</div>` : ""}</td>
        <td>${x.recommendedReleaseId ? esc(x.recommendedLabel) + (x.recommendedReleaseId === x.currentReleaseId ? ` <span class="arg-note">(installed)</span>` : "") : `<span class="arg-note">None approved for the model</span>`}</td>
        <td>${esc(date(x.supportEndDate) || "--")}<div class="arg-note">EOL ${esc(date(x.endOfLifeDate) || "--")}</div></td>
        <td>${x.exceptionId ? `#${esc(x.exceptionId)}<div class="arg-note">until ${esc(date(x.exceptionExpiry))}</div>` : "--"}</td></tr>`;
    }).join("") || empty(7, "No technology data.");
    document.getElementById("argFwHistory").innerHTML = (t.firmwareHistory || []).map(h => `
      <tr><td>${esc(date(h.installedDate) || "--")}${h.isCurrent ? ` <span class="arg-note">(current)</span>` : ""}</td><td>${esc(h.releaseLabel)}</td>
          <td>${esc(h.previousLabel || "--")}</td><td>${esc(h.source)}</td><td>${esc(h.result === "FAILED" ? "Failed" : "Successful")}</td>
          <td>${esc(h.rollbackNote || "")}</td><td>${esc(h.evidenceText || "")}</td><td>${esc(dateTime(h.enteredDt))}</td></tr>`).join("") || empty(8, "No firmware installation recorded.");
    document.getElementById("argOsHistory").innerHTML = (t.osHistory || []).map(h => `
      <tr><td>${esc(date(h.installedDate) || "--")}${h.isCurrent ? ` <span class="arg-note">(current)</span>` : ""}</td><td>${esc(h.releaseLabel)}</td>
          <td>${esc(h.buildPatchLevel || "--")}</td><td>${esc([h.previousLabel, h.previousBuildPatchLevel].filter(Boolean).join(" / ") || "--")}</td>
          <td>${esc(h.source)}</td><td>${esc(h.licenceReference || "")}</td><td>${esc(h.evidenceText || "")}</td><td>${esc(dateTime(h.enteredDt))}</td></tr>`).join("") || empty(8, "No operating-system installation recorded.");
    document.getElementById("argTechExceptions").innerHTML = (t.exceptions || []).map(e => {
      const actions = [];
      if (e.status === "PENDING_APPROVAL" && CAN_APPROVE) actions.push(["APPROVE", "Approve"], ["REJECT", "Reject"]);
      if (e.status === "PENDING_APPROVAL" && CAN_EDIT) actions.push(["WITHDRAW", "Withdraw"]);
      if (e.status === "APPROVED" && CAN_APPROVE) actions.push(["REVOKE", "Revoke"]);
      return `<tr><td>${esc(KIND_NAME[e.kind] || e.kind)}<div class="arg-note">${esc(e.releaseLabel)}</div></td>
        <td>${e.scope === "MODEL" ? "Every asset of " + esc(e.modelName || "the model") : "This asset"}</td>
        <td>${esc(e.reason)}<div class="arg-note">Controls: ${esc(e.compensatingControls)}</div></td>
        <td>${esc(e.ownerName || "--")}</td>
        <td>${esc(date(e.expiryDate))}${e.reviewDate ? `<div class="arg-note">Review ${esc(date(e.reviewDate))}</div>` : ""}</td>
        <td>${esc(EXC_STATUS[e.displayStatus] || e.displayStatus)}<div class="arg-note">Requested by ${esc(e.requestedByName || e.requestedBy)}${e.decidedBy ? "; decided by " + esc(e.decidedByName || e.decidedBy) : ""}</div>${e.decisionNote ? `<div class="arg-note">${esc(e.decisionNote)}</div>` : ""}</td>
        <td>${actions.map(([d, label]) => `<button class="pm-button" type="button" data-arg-exc-decide="${d}" data-arg-exc="${e.exceptionId}">${label}</button>`).join(" ")}</td></tr>`;
    }).join("") || empty(7, "No technology exception.");
  }

  function releaseOptions(kind, selected) {
    const rows = state.lookups[kind === "FIRMWARE" ? "MASTER:FIRMWARE" : "MASTER:OS_RELEASE"] || [];
    const current = ((state.tech || {}).status || []).find(x => x.kind === kind);
    const list = rows.map(r => ({ value: String(r.value), label: r.label }));
    if (current?.currentReleaseId && !list.some(o => o.value === String(current.currentReleaseId)))
      list.unshift({ value: String(current.currentReleaseId), label: current.currentLabel });
    return `<option value="">Select</option>` + list.map(o => `<option value="${esc(o.value)}"${o.value === String(selected ?? "") ? " selected" : ""}>${esc(o.label)}</option>`).join("");
  }

  async function openInstall(kind) {
    await ensureLookups(["MASTER:FIRMWARE", "MASTER:OS_RELEASE"]);
    state.installKind = kind;
    const current = ((state.tech || {}).status || []).find(x => x.kind === kind);
    document.getElementById("argInstallTitle").textContent = `Record ${kind === "FIRMWARE" ? "firmware" : "operating-system"} installation`;
    document.getElementById("argInstRelease").innerHTML = releaseOptions(kind, current?.recommendedReleaseId);
    document.getElementById("argInstDate").value = new Date().toISOString().substring(0, 10);
    ["argInstSource", "argInstBuild", "argInstLicence", "argInstRollback", "argInstEvidence"].forEach(id => { document.getElementById(id).value = ""; });
    document.getElementById("argInstResult").value = "SUCCESSFUL";
    ["argInstResultWrap", "argInstRollbackWrap"].forEach(id => { document.getElementById(id).hidden = kind !== "FIRMWARE"; });
    ["argInstBuildWrap", "argInstLicenceWrap"].forEach(id => { document.getElementById(id).hidden = kind !== "OS"; });
    const msg = document.getElementById("argInstMessage"); msg.hidden = true; msg.textContent = "";
    document.getElementById("argInstallModal").hidden = false;
  }

  async function submitInstall() {
    const kind = state.installKind, msg = document.getElementById("argInstMessage");
    const res = await api("POST", `/${state.asset.assetId}/technology/installations`, {
      organizationId: state.organizationId, kind, releaseId: Number(val("argInstRelease")) || 0,
      installedDate: val("argInstDate") || null, source: val("argInstSource") || null,
      result: kind === "FIRMWARE" ? val("argInstResult") : null,
      buildPatchLevel: kind === "OS" ? (val("argInstBuild") || null) : null,
      rollbackNote: kind === "FIRMWARE" ? (val("argInstRollback") || null) : null,
      licenceReference: kind === "OS" ? (val("argInstLicence") || null) : null,
      evidenceText: val("argInstEvidence") || null,
      expectedRecordVersion: state.asset.recordVersion ?? null
    });
    if (!res.ok) { msg.textContent = res.error; msg.hidden = false; return; }
    document.getElementById("argInstallModal").hidden = true;
    await openAsset(state.asset.assetId);
    selectTab("technology");
    showMessage("Installation recorded.", "success");
  }

  async function openException() {
    await ensureLookups(["MASTER:FIRMWARE", "MASTER:OS_RELEASE", "MASTER:EMPLOYEE"]);
    const st = (state.tech || {}).status || [];
    const flagged = st.find(x => x.classification === "UNSUPPORTED") || st.find(x => x.currentReleaseId) || st[0];
    document.getElementById("argExcKind").value = flagged?.kind || "FIRMWARE";
    fillExceptionReleases();
    document.getElementById("argExcScope").value = "ASSET";
    document.getElementById("argExcOwner").innerHTML = `<option value="">Select</option>`
      + (state.lookups["MASTER:EMPLOYEE"] || []).map(e => `<option value="${esc(e.value)}">${esc(e.label)}</option>`).join("");
    ["argExcReason", "argExcControls", "argExcExpiry", "argExcReview"].forEach(id => { document.getElementById(id).value = ""; });
    const msg = document.getElementById("argExcMessage"); msg.hidden = true; msg.textContent = "";
    document.getElementById("argExcModal").hidden = false;
  }

  function fillExceptionReleases() {
    const kind = val("argExcKind");
    const current = ((state.tech || {}).status || []).find(x => x.kind === kind);
    document.getElementById("argExcRelease").innerHTML = releaseOptions(kind, current?.currentReleaseId);
  }

  async function submitException() {
    const msg = document.getElementById("argExcMessage");
    const res = await api("POST", `/${state.asset.assetId}/technology/exceptions`, {
      organizationId: state.organizationId, scope: val("argExcScope"), kind: val("argExcKind"),
      releaseId: Number(val("argExcRelease")) || 0, reason: val("argExcReason") || null,
      compensatingControls: val("argExcControls") || null, ownerEmployeeId: Number(val("argExcOwner")) || null,
      expiryDate: val("argExcExpiry") || null, reviewDate: val("argExcReview") || null
    });
    if (!res.ok) { msg.textContent = res.error; msg.hidden = false; return; }
    document.getElementById("argExcModal").hidden = true;
    await loadTechnology();
    showMessage("Technology exception requested; it needs approval by another person.", "success");
  }

  async function decideException(id, decision) {
    const e = ((state.tech || {}).exceptions || []).find(x => x.exceptionId === id);
    let note = null;
    if (decision === "REJECT" || decision === "REVOKE") {
      note = await window.gracUi.promptRequired(decision === "REJECT" ? "Why is this exception rejected?" : "Why is this exception revoked?",
        { title: decision === "REJECT" ? "Reject exception" : "Revoke exception", inputLabel: "Reason" });
      if (!note) return;
    } else if (!await window.gracUi.confirm(decision === "APPROVE" ? "Approve this technology exception? It is active until its expiry date." : "Withdraw this request?")) return;
    const res = await api("POST", `/technology-exceptions/${id}/decide`, {
      organizationId: state.organizationId, decision, decisionNote: note, expectedRecordVersion: e?.recordVersion ?? null
    });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    await loadTechnology();
    showMessage({ APPROVED: "Exception approved.", REJECTED: "Exception rejected.", WITHDRAWN: "Request withdrawn.", REVOKED: "Exception revoked." }[res.data.result] || "Done.", "success");
  }

  // ------------------------------------------------------------------ custody (431)
  async function loadCustody() {
    if (!state.asset) return;
    const res = await api("GET", `/${state.asset.assetId}/custody?organizationId=${state.organizationId}`);
    if (!res.ok) return;
    state.custody = res.data.data;
    document.getElementById("argCustodyTab").hidden = false;
    renderCustody();
  }

  function renderCustody() {
    const c = state.custody || {}, st = c.state || {};
    const ver = { VERIFIED: "Verified", DISPUTED: "Disputed", NOT_VERIFIED: "Not verified" };
    const freq = { MONTHLY: "monthly", QUARTERLY: "quarterly", HALF_YEARLY: "half-yearly", ANNUAL: "annual", CUSTOM: `every ${st.customIntervalDays} days` };
    const part = { CUSTODIAN: "custodian", OWNER: "asset owner", BOTH: "custodian and asset owner" };
    document.getElementById("argCustodyState").textContent =
      `Verification: ${ver[st.verificationStatus] || st.verificationStatus || "Not verified"}`
      + (st.lastAttestedDate ? `; last attested ${date(st.lastAttestedDate)}` : "")
      + (st.nextAttestationDate ? `; next attestation ${date(st.nextAttestationDate)}` : "") + ". "
      + (st.profileId && st.attestationRequired ? `Attestation profile v${st.profileVersion}: ${part[st.participant] || st.participant}, ${freq[st.frequency] || st.frequency}, due within ${st.dueWindowDays} days.`
                                                : "No attestation profile applies to this asset.");
    const statusName = { GENERATED: "Generated", PENDING: "Pending", IN_PROGRESS: "In progress", OVERDUE: "Overdue", CONFIRMED: "Awaiting approval",
                         DISPUTED: "Disputed", CLOSED: "Closed", CANCELLED: "Cancelled", ESCALATED: "Escalated", EXCEPTION: "Exception", RESOLVED: "Resolved" };
    const typeName = { INITIAL: "Initial acknowledgement", PERIODIC: "Periodic", CAMPAIGN: "Campaign", TRANSFER: "Transfer", RETURN: "Return", EVENT: "Event" };
    document.getElementById("argAssignments").innerHTML = (c.assignments || []).map(h => `
      <tr><td>${esc(date(h.effectiveFrom))}${h.isCurrent ? ` <span class="arg-note">(current)</span>` : ""}</td><td>${esc(date(h.effectiveTo) || "--")}</td>
          <td>${esc(h.ownerName || "--")}</td><td>${esc(h.custodianName || "--")}</td><td>${esc(h.departmentName || "--")}</td>
          <td>${esc([h.locationName, h.building, h.floor, h.room].filter(Boolean).join(" / ") || "--")}</td>
          <td>${esc(h.changeSource)}<div class="arg-note">${esc(h.enteredBy)} ${esc(dateTime(h.enteredDt))}</div></td></tr>`).join("") || empty(7, "No assignment history.");
    document.getElementById("argAttestations").innerHTML = (c.attestations || []).map(t => `
      <tr><td>${esc(typeName[t.attestationType] || t.attestationType)}</td><td>${esc(t.assigneeName || "--")}</td><td>${esc(date(t.dueDate))}</td>
          <td>${esc(statusName[t.displayStatus] || t.displayStatus)}${t.decisionNote ? `<div class="arg-note">${esc(t.decisionNote)}</div>` : ""}</td>
          <td>${t.response ? esc(t.response === "CONFIRM" ? "Confirmed" : "Disagreed") : "--"}${t.disagreementCategory ? `<div class="arg-note">${esc(t.disagreementCategory.replace(/_/g, " ").toLowerCase())}</div>` : ""}${t.comments ? `<div class="arg-note">${esc(t.comments)}</div>` : ""}</td>
          <td>${esc(t.attestedByName || "")}${t.responseDt ? `<div class="arg-note">${esc(dateTime(t.responseDt))}</div>` : ""}</td></tr>`).join("") || empty(6, "No acknowledgement or attestation yet.");
    // 432: verification exceptions of the asset.
    const outcome = { NO_CHANGE: "No change", RECORD_CORRECTION: "Record corrected", LOST_CONFIRMED: "Loss confirmed", DAMAGE_CONFIRMED: "Damage confirmed",
                      RETIREMENT_CONFIRMED: "Retirement confirmed", DUPLICATE_CONFIRMED: "Duplicate confirmed", OTHER: "Other" };
    document.getElementById("argVerExceptions").innerHTML = (c.exceptions || []).map(x => `
      <tr><td>#${esc(x.exceptionId)}<div class="arg-note">${esc(dateTime(x.reportedDt))}</div></td>
          <td>${esc(String(x.category || "").replace(/_/g, " ").toLowerCase())}</td><td>${esc(x.severity === "CRITICAL" ? "Critical" : "Standard")}</td>
          <td>${esc(x.investigatorName || "Unassigned")}</td><td>${esc(x.statusName)}</td><td>${esc(date(x.resolutionDue))}</td>
          <td>${esc(outcome[x.outcome] || "--")}</td></tr>`).join("") || empty(7, "No verification exception.");
  }

  // ------------------------------------------------------------------ coverage (435)
  const COV_STATUS = { COVERED: "Covered", EXPIRING: "Expiring", SUSPENDED: "Suspended", EXCLUDED: "Excluded", EXPIRED: "Expired", UNCOVERED: "Uncovered" };
  async function loadCoverage() {
    if (!state.asset) return;
    const res = await api("GET", `/${state.asset.assetId}/coverage?organizationId=${state.organizationId}`);
    if (!res.ok) return;
    state.coverage = res.data.data;
    document.getElementById("argCoverageTab").hidden = false;
    renderCoverage();
  }

  function renderCoverage() {
    const c = state.coverage || {}, s = c.summary || {};
    const lvl = { NOT_APPLICABLE: "Not applicable", OPTIONAL: "Optional", REQUIRED: "Required" };
    const gaps = (c.requirements || []).filter(r => r.gapKind).length;
    document.getElementById("argCoverageState").textContent = `Coverage status: ${s.coverageStatusLabel || "Uncovered"}.`
      + (gaps ? ` ${gaps} required coverage type(s) have a gap.` : "") + " Coverage is maintained on the contract versions (Contracts).";
    document.getElementById("argCoverageTypes").innerHTML = (c.types || []).map(t => `
      <tr><td>${esc(t.coverageTypeLabel)}</td><td>${esc(COV_STATUS[t.coverageStatus] || t.coverageStatus)}</td>
          <td>${esc(t.contractNumber || "--")}${t.versionNo ? ` <span class="arg-note">v${esc(t.versionNo)}</span>` : ""}</td>
          <td>${esc(date(t.effectiveStart))} to ${esc(date(t.effectiveEnd) || "--")}</td><td>${esc(date(t.expiringFrom) || "--")}</td></tr>`).join("")
      || empty(5, "No coverage line in force or ended.");
    document.getElementById("argCoverageReqs").innerHTML = (c.requirements || []).map(r => `
      <tr><td>${esc(r.coverageTypeLabel)}</td><td>${esc(lvl[r.requirementLevel] || r.requirementLevel)}</td>
          <td>${r.minimumPeriodMonths ? esc(r.minimumPeriodMonths) + " months" : "--"}</td>
          <td>${esc(r.licenceHandling === "ENTERPRISE" ? "Enterprise" : r.licenceHandling === "STANDALONE" ? "Standalone" : "--")}</td>
          <td>${esc(r.missingAction === "BLOCK_ACTIVATION" ? "Blocks activation" : "Warning")}</td>
          <td>${esc(r.gapMessage || "--")}</td></tr>`).join("") || empty(6, "The asset type has no coverage requirement.");
    const st = { COVERED: "Covered", EXCLUDED: "Excluded", SUSPENDED: "Suspended" };
    document.getElementById("argCoverageLines").innerHTML = (c.lines || []).map(l => `
      <tr><td>${esc(l.contractNumber)}<div class="arg-note">${esc(l.contractName)}</div></td><td>v${esc(l.versionNo)} <span class="arg-note">${esc(String(l.versionStatus || "").toLowerCase())}</span></td>
          <td>${esc(l.coverageType)}</td><td>${esc(st[l.coverageState] || l.coverageState)}${l.exclusionReason ? `<div class="arg-note">${esc(l.exclusionReason)}</div>` : ""}</td>
          <td>${esc(COV_STATUS[l.lineStatus] || (l.lineStatus ? l.lineStatus : "Not in force"))}</td>
          <td>${esc(date(l.effectiveStart))} to ${esc(date(l.effectiveEnd) || "--")}</td><td>${esc(l.productSku || "--")}</td>
          <td>${esc(l.serviceLevel || "--")}${l.supportHours ? `<div class="arg-note">${esc(l.supportHours)}</div>` : ""}</td>
          <td>${esc(l.vendorSupportReference || "--")}</td></tr>`).join("") || empty(9, "No contract lists this asset in an approved version.");
  }

  // ------------------------------------------------------------------ valuation (446)
  const VAL_STATUS = { NOT_RATED: "Not rated", INCOMPLETE: "Incomplete", INVALID: "Invalid", VALID: "Valid" };
  const VAL_STATE = {
    CURRENT: "Up to date.", NOT_CALCULATED: "Not calculated yet.",
    VALUES_CHANGED: "The ratings or method changed since the last calculation.",
    CONFIG_CHANGED: "A newer valuation configuration version is Active; the stored value changes with a controlled recalculation.",
    CONFIG_AND_VALUES: "The ratings changed and a newer valuation configuration version is Active."
  };
  const VAL_METHOD = { MAXIMUM: "Maximum", WEIGHTED_AVERAGE: "Weighted Average", SUMMATION: "Summation" };
  const VAL_SOURCE = { FORM: "Asset form", SCHEDULER: "Scheduler", MANUAL: "Recalculated", RECALC_RUN: "Recalculation run", METHOD_OVERRIDE: "Method override" };
  const valNum = v => v == null || v === "" ? "--" : String(Number(v));
  const valMethod = (m, src) => m ? (VAL_METHOD[m] || m) + (src === "OVERRIDE" ? " (asset override)" : "") : "--";

  async function loadValuation() {
    if (!state.asset) return;
    const res = await api("GET", `/${state.asset.assetId}/valuation?organizationId=${state.organizationId}`);
    if (!res.ok) return;
    state.valuation = res.data.data;
    document.getElementById("argValTab").hidden = false;
    renderValuation();
  }

  function renderValuation() {
    const d = state.valuation || {}, v = d.current || {};
    const shown = v.storedStatus || v.validationStatus;
    document.getElementById("argValState").textContent =
      `Asset Value: ${v.storedCategory ? `${v.storedCategory} (score ${valNum(v.storedScore)})` : (VAL_STATUS[shown] || "Not rated")}. `
      + (VAL_STATE[v.stateCode] || "")
      + (v.treatmentGuidance ? ` Treatment guidance: ${v.treatmentGuidance}` : "");
    const recalc = document.getElementById("argValRecalc");
    if (recalc) recalc.hidden = !!Number(v.isCurrent);
    const override = document.getElementById("argValOverride");
    if (override) override.hidden = !v.configId || !(v.overrideAllowed || v.methodOverride);
    const row = (label, now, stored) => `<tr><td>${esc(label)}</td><td>${now}</td><td>${stored}</td></tr>`;
    const st = (code, msg) => esc(VAL_STATUS[code] || code || "--") + (msg ? `<div class="arg-note">${esc(msg)}</div>` : "");
    const hasStored = !!v.storedStatus;
    document.getElementById("argValCompare").innerHTML = [
      row("Configuration version", v.configVersionNo ? `v${esc(v.configVersionNo)}` : "None Active", hasStored && v.storedConfigVersionNo ? `v${esc(v.storedConfigVersionNo)}` : "--"),
      row("Confidentiality", esc(v.confidentiality || "--"), esc(hasStored ? (v.storedConfidentiality || "--") : "--")),
      row("Integrity", esc(v.integrity || "--"), esc(hasStored ? (v.storedIntegrity || "--") : "--")),
      row("Availability", esc(v.availability || "--"), esc(hasStored ? (v.storedAvailability || "--") : "--")),
      row("Method", esc(valMethod(v.methodUsed, v.methodSource)), esc(hasStored ? valMethod(v.storedMethodUsed, v.storedMethodSource) : "--")),
      row("Asset Value score", esc(valNum(v.assetValueScore)), esc(hasStored ? valNum(v.storedScore) : "--")),
      row("Asset Value category", esc(v.assetValueCategory || "--"), esc(hasStored ? (v.storedCategory || "--") : "--")),
      row("Validation status", st(v.validationStatus, v.validationMessage), hasStored ? st(v.storedStatus, v.storedMessage) : "--"),
      row("Calculated", "", hasStored ? `${esc(v.calculatedBy || "")} ${esc(dateTime(v.calculatedDt))}<div class="arg-note">${esc(VAL_SOURCE[v.storedSource] || v.storedSource || "")}</div>` : "--")
    ].join("");
    document.getElementById("argValHistory").innerHTML = (d.history || []).map(h => `
      <tr><td>${esc(dateTime(h.enteredDt))}</td><td>${esc(VAL_SOURCE[h.source] || h.source)}${h.runId ? ` <span class="arg-note">run #${esc(h.runId)}</span>` : ""}</td>
          <td>${h.configVersionNo ? `v${esc(h.configVersionNo)}` : "--"}${h.prevConfigVersionNo && h.prevConfigVersionNo !== h.configVersionNo ? `<div class="arg-note">was v${esc(h.prevConfigVersionNo)}</div>` : ""}</td>
          <td>${esc([h.confidentiality, h.integrity, h.availability].map(x => x || "-").join(" / "))}</td>
          <td>${esc(valMethod(h.methodUsed, h.methodSource))}</td><td>${esc(valNum(h.score))}</td>
          <td>${esc(h.category || "--")}${h.prevStatus ? `<div class="arg-note">was ${esc(h.prevCategory || VAL_STATUS[h.prevStatus] || h.prevStatus)}</div>` : ""}</td>
          <td>${esc(VAL_STATUS[h.status] || h.status)}</td><td>${esc(h.enteredBy || "")}</td>
          <td>${esc(h.reason || "")}${h.message ? `<div class="arg-note">${esc(h.message)}</div>` : ""}</td></tr>`).join("")
      || empty(10, "No calculation yet.");
    renderConsistency();   // 447
    renderValRisks();      // 447
  }

  // ------------------------------------------------------------------ privacy (448)
  const PRIV_STATUS = { NON_COMPLIANT: ["Non-compliant", "arg-ph-exception"], INCOMPLETE: ["Incomplete", "arg-tc-warn"], UNDETERMINED: ["Undetermined", "arg-tc-warn"],
                        CONDITIONAL: ["Conditional", "arg-tc-warn"], COMPLIANT: ["Compliant", "arg-ph-operation"], NOT_APPLICABLE: ["Not applicable", "arg-ph-retirement"] };
  const PRIV_GAP = { FAILED: "Failed", MISSING: "Missing", PARTIAL: "Partial" };
  const PRIV_ENF = { OFF: "Off", WARN: "Warn", BLOCK: "Block" };
  const PRIV_EXC = { PENDING_APPROVAL: "Awaiting approval", APPROVED: "Approved", REJECTED: "Rejected", WITHDRAWN: "Withdrawn", REVOKED: "Revoked", EXPIRED: "Expired" };
  const PRIV_REV = { OPEN: "Open", COMPLETED: "Completed", CANCELLED: "Cancelled" };
  const PRIV_KIND = { PRIVACY: "Privacy / DPIA review", RETENTION: "Retention end" };
  const PRIV_OUTCOME = { REVIEWED: "Reviewed", DELETE: "Data deleted", ARCHIVE: "Data archived", LEGAL_HOLD: "Legal hold verified", EXTEND: "Retention extended" };

  async function loadPrivacy() {
    if (!state.asset) return;
    const res = await api("GET", `/${state.asset.assetId}/privacy?organizationId=${state.organizationId}`);
    if (!res.ok) return;
    state.privacy = res.data.data || {};
    document.getElementById("argPrivTab").hidden = false;
    renderPrivacy();
  }

  function renderPrivacy() {
    const d = state.privacy || {}, s = d.status || {};
    const st = PRIV_STATUS[s.privacyStatus] || [s.privacyStatus || "--", "arg-ph-retirement"];
    document.getElementById("argPrivState").innerHTML = `Privacy status: <span class="arg-chip ${st[1]}">${esc(st[0])}</span>`
      + ` <span class="arg-note">Privacy owner ${esc(s.privacyOwnerName || "--")}; privacy review ${esc(date(s.privacyReviewDate) || "--")}`
      + `; retention end ${esc(date(s.retentionDueDate) || "--")}${String(s.legalHold || "").toUpperCase() === "YES" ? "; legal hold" : ""}</span>`;
    document.getElementById("argPrivGaps").innerHTML = (d.gaps || []).map(g => `
      <tr><td>${esc(g.requirementName)}</td><td>${esc(PRIV_GAP[g.gapKind] || g.gapKind)}: ${esc(g.message)}</td>
          <td>${esc(PRIV_ENF[g.enforcement] || g.enforcement)}${g.enforcement === "BLOCK" ? `<div class="arg-note">blocks ${g.blockTarget === "ACTIVE" ? "a move to Active" : "Disposed / Archived"}</div>` : ""}</td>
          <td>${Number(g.isExcepted) ? `Excepted until ${esc(date(g.exceptionExpiry))}` : "--"}</td></tr>`).join("")
      || empty(4, s.privacyStatus === "NOT_APPLICABLE" ? "Personal data is not processed." : "No gap.");
    document.getElementById("argPrivExceptions").innerHTML = (d.exceptions || []).map(x => `
      <tr><td>${esc(x.requirementName)}</td><td>${esc(PRIV_EXC[x.status] || x.status)}${x.decidedBy ? `<div class="arg-note">${esc(x.decidedBy)} ${esc(dateTime(x.decidedDt))}</div>` : ""}</td>
          <td>${esc(x.reason)}<div class="arg-note">${esc(x.compensatingControls)}</div></td>
          <td>${esc(x.ownerName || "--")}</td><td>${esc(date(x.expiryDate))}</td></tr>`).join("")
      || empty(5, "No exception.");
    document.getElementById("argPrivReviews").innerHTML = (d.reviews || []).map(r => `
      <tr><td>${esc(PRIV_KIND[r.reviewKind] || r.reviewKind)}</td><td>${esc(date(r.dueDate))}</td><td>${esc(PRIV_REV[r.status] || r.status)}</td>
          <td>${esc(PRIV_OUTCOME[r.outcome] || "--")}${r.extendedUntil ? `<div class="arg-note">until ${esc(date(r.extendedUntil))}</div>` : ""}${r.note ? `<div class="arg-note">${esc(r.note)}</div>` : ""}</td></tr>`).join("")
      || empty(4, "No review.");
  }

  function openPrivacyScreen() {
    if (!state.asset) return;
    const qs = new URLSearchParams({ organizationId: state.organizationId, assetId: state.asset.assetId });
    window.location.href = U(`/Practice/Index/asset-privacy?${qs}`);
  }

  // ------------------------------------------------------------------ consistency findings (447)
  const CONS_SEV = { INFO: "Information", WARNING: "Warning", ERROR: "Error", APPROVAL_REQUIRED: "Approval Required" };
  const CONS_STATUS = { OPEN: "Open", PENDING_APPROVAL: "Awaiting approval", ACCEPTED: "Accepted", RESOLVED: "Resolved" };
  const CONS_ACTION = { WARN: "Warn", REQUIRE_RATIONALE: "Rationale required", CREATE_TASK: "Task", BLOCK_TRANSITION: "Blocks move to Active" };
  const consFacts = j => { try { return (JSON.parse(j || "[]") || []).map(x => `${x.operand} = ${x.value}`).join("; "); } catch (_) { return ""; } };
  const consAcceptance = f => f.rationale
    ? `${esc(f.rationale)}<div class="arg-note">Owner ${esc(f.ownerName || "--")}; review ${esc(date(f.reviewDate))}${f.decidedBy ? `; decided by ${esc(f.decidedBy)}` : ""}</div>`
      + (f.decisionNote ? `<div class="arg-note">${esc(f.decisionNote)}</div>` : "")
    : (f.decisionNote ? `<span class="arg-note">${esc(f.decisionNote)}</span>` : "--");
  function consButtons(f) {
    const b = [];
    if (f.status === "OPEN" && f.overrideAllowed && CAN_EDIT) b.push(["ACCEPT", "Accept"]);
    if (f.status === "PENDING_APPROVAL" && CAN_APPROVE) b.push(["APPROVE", "Approve"], ["REJECT", "Reject"]);
    if (f.status === "PENDING_APPROVAL" && CAN_EDIT) b.push(["WITHDRAW", "Withdraw"]);
    if (f.status === "ACCEPTED" && CAN_APPROVE) b.push(["REVOKE", "Revoke"]);
    return b.map(([a, l]) => `<button class="pm-button" type="button" data-arg-cons="${esc(f.findingId)}" data-arg-cons-act="${a}">${esc(l)}</button>`).join(" ");
  }

  function renderConsistency() {
    const rows = (state.valuation || {}).findings || [];
    document.getElementById("argConsBody").innerHTML = rows.map(f => `
      <tr><td>${esc(f.ruleCode)} v${esc(f.ruleVersionNo)}: ${esc(f.message)}<div class="arg-note">${esc(CONS_ACTION[f.actionCode] || f.actionCode)}${consFacts(f.factsJson) ? ` -- ${esc(consFacts(f.factsJson))}` : ""}</div></td>
          <td>${esc(CONS_SEV[f.severity] || f.severity)}</td><td>${esc(CONS_STATUS[f.status] || f.status)}</td>
          <td>${esc(dateTime(f.detectedDt))}${f.resolvedDt ? `<div class="arg-note">resolved ${esc(dateTime(f.resolvedDt))}</div>` : ""}</td>
          <td>${consAcceptance(f)}</td><td>${consButtons(f)}</td></tr>`).join("") || empty(6, "No consistency finding.");
  }

  function renderValRisks() {
    const rows = (state.valuation || {}).risks || [];
    document.getElementById("argValRisks").innerHTML = rows.map(r => `
      <tr><td>${esc(r.riskNumber || "#" + r.riskRegisterId)}<div class="arg-note">${esc(r.riskTitle)}</div></td><td>${esc(r.riskStatus)}</td>
          <td>${esc(r.inherentRating || "--")} / ${esc(r.residualRating || "--")}</td>
          <td>${r.riskAssetValueCategory ? `${esc(r.riskAssetValueCategory)} (${esc(valNum(r.riskAssetValueScore))})` : "--"}<div class="arg-note">highest of the risk's assets</div></td>
          <td>${esc(dateTime(r.riskAssessedDt))}</td>
          <td>${Number(r.reviewSuggested) ? `<span class="arg-chip arg-tc-warn">Review suggested</span><div class="arg-note">Asset Value changed ${esc(dateTime(r.lastValueChangeDt))}</div>` : "--"}</td></tr>`).join("")
      || empty(6, "No risk is linked to this asset.");
  }

  async function consAction(id, action, from) {
    const list = from === "list" ? state.consList : ((state.valuation || {}).findings || []);
    const f = list.find(x => x.findingId === id);
    if (!f) return;
    state.consFrom = from;
    if (action === "ACCEPT") { await openConsAccept(f); return; }
    let note = null;
    if (action === "REJECT" || action === "REVOKE") {
      note = await window.gracUi.promptRequired(action === "REJECT" ? "Why is the acceptance rejected?" : "Why is the acceptance revoked? The finding reopens.",
        { title: action === "REJECT" ? "Reject acceptance" : "Revoke acceptance", inputLabel: "Reason" });
      if (!note) return;
    } else if (!await window.gracUi.confirm(action === "APPROVE" ? "Approve this accepted inconsistency until its review date?" : "Withdraw the acceptance request?")) return;
    const res = await api("POST", `/consistency/findings/${id}/action`, {
      organizationId: state.organizationId, action, note, expectedRecordVersion: f.recordVersion ?? null
    });
    await afterConsChange(res, { ACCEPTED: "Inconsistency accepted.", OPEN: action === "REJECT" ? "Acceptance rejected." : action === "REVOKE" ? "Acceptance revoked." : "Request withdrawn." }[res.data && res.data.result]);
  }

  async function openConsAccept(f) {
    await ensureLookups(["MASTER:EMPLOYEE"]);
    state.consFinding = f;
    const approval = f.severity === "ERROR" || f.severity === "APPROVAL_REQUIRED";
    document.getElementById("argConsNote").textContent = `${f.ruleCode}: ${f.message}. `
      + (approval ? "This severity needs approval by another person with approval rights; evidence is required." : "The acceptance applies at once.")
      + (f.maxOverrideDays ? ` The review date must be within ${f.maxOverrideDays} days.` : "") + " The finding reopens when the review date passes.";
    document.getElementById("argConsEvidenceLabel").textContent = approval ? "Evidence *" : "Evidence";
    document.getElementById("argConsOwner").innerHTML = `<option value="">Select</option>`
      + (state.lookups["MASTER:EMPLOYEE"] || []).map(e => `<option value="${esc(e.value)}">${esc(e.label)}</option>`).join("");
    ["argConsRationale", "argConsEvidence", "argConsReview"].forEach(x => { document.getElementById(x).value = ""; });
    const msg = document.getElementById("argConsMessage"); msg.hidden = true; msg.textContent = "";
    document.getElementById("argConsModal").hidden = false;
  }

  async function submitConsAccept() {
    const f = state.consFinding, msg = document.getElementById("argConsMessage");
    const res = await api("POST", `/consistency/findings/${f.findingId}/action`, {
      organizationId: state.organizationId, action: "ACCEPT", rationale: val("argConsRationale") || null, evidence: val("argConsEvidence") || null,
      ownerEmployeeId: Number(val("argConsOwner")) || null, reviewDate: val("argConsReview") || null, expectedRecordVersion: f.recordVersion ?? null
    });
    if (!res.ok) { msg.textContent = res.error; msg.hidden = false; return; }
    document.getElementById("argConsModal").hidden = true;
    await afterConsChange(res, res.data.result === "PENDING_APPROVAL" ? "Acceptance requested; another person with approval rights decides it." : "Inconsistency accepted.");
  }

  async function afterConsChange(res, okText) {
    if (state.consFrom === "list") {
      await loadConsList();
      if (!res.ok) await window.gracUi.alert(res.error, { type: "error" });
      return;
    }
    if (!res.ok) { showMessage(res.error, "error"); if (res.status !== 409) return; }
    await openAsset(state.asset.assetId);
    selectTab("valuation");
    if (res.ok) showMessage(okText || "Done.", "success");
  }

  async function runConsistency(oneAsset) {
    const res = await api("POST", "/consistency/run", { organizationId: state.organizationId, assetId: oneAsset && state.asset ? state.asset.assetId : null });
    if (oneAsset) {
      if (!res.ok) { showMessage(res.error, "error"); return; }
      await openAsset(state.asset.assetId);
      selectTab("valuation");
      showMessage(`Consistency re-evaluated: ${res.data.result}.`, "success");
      return;
    }
    await loadConsList();
    const el = document.getElementById("argConsCounts");
    el.textContent = (res.ok ? `Re-evaluated: ${res.data.result}. ` : `${res.error} `) + el.textContent;
  }

  async function openConsList() {
    document.getElementById("argConsListModal").hidden = false;
    await loadConsList();
  }

  async function loadConsList() {
    const body = document.getElementById("argConsListBody");
    if (!state.organizationId) { body.innerHTML = empty(7, "Select an organization."); return; }
    body.innerHTML = empty(7, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId, pageNumber: 1, pageSize: 200 });
    if (val("argConsStatus")) qs.set("status", val("argConsStatus"));
    if (val("argConsSeverity")) qs.set("severity", val("argConsSeverity"));
    if (val("argConsSearch")) qs.set("search", val("argConsSearch"));
    const res = await api("GET", `/consistency/findings?${qs}`);
    if (!res.ok) { body.innerHTML = empty(7, res.error); return; }
    const d = res.data.data || {};
    state.consList = d.rows || [];
    const counts = d.counts || [];
    const sum = s => counts.filter(c => c.status === s).reduce((n, c) => n + Number(c.findingCount || 0), 0);
    document.getElementById("argConsCounts").textContent = `Open ${sum("OPEN")}, awaiting approval ${sum("PENDING_APPROVAL")}, accepted ${sum("ACCEPTED")}`
        + (d.totalRows > state.consList.length ? `. Showing the first ${state.consList.length} of ${d.totalRows}.` : ".");
    body.innerHTML = state.consList.map(f => `
      <tr><td>${esc(f.assetName)}<div class="arg-note">#${esc(f.assetId)}</div></td>
          <td>${esc(f.ruleCode)} v${esc(f.ruleVersionNo)}: ${esc(f.message)}${consFacts(f.factsJson) ? `<div class="arg-note">${esc(consFacts(f.factsJson))}</div>` : ""}</td>
          <td>${esc(CONS_SEV[f.severity] || f.severity)}</td><td>${esc(CONS_STATUS[f.status] || f.status)}</td>
          <td>${esc(dateTime(f.detectedDt))}</td><td>${consAcceptance(f)}</td>
          <td>${consButtons(f)} <button class="pm-button" type="button" data-arg-cons-asset="${esc(f.assetId)}">Open</button></td></tr>`).join("")
      || empty(7, "No finding.");
  }

  async function recalcValuation() {
    const v = (state.valuation || {}).current || {};
    let reason = null;
    if (Number(v.configChanged)) {
      reason = await window.gracUi.promptRequired(`Recalculate this asset with valuation configuration version ${v.configVersionNo || "(none)"}? The previous value stays in the history.`,
        { title: "Recalculate Asset Value", inputLabel: "Reason" });
      if (!reason) return;
    }
    const res = await api("POST", `/${state.asset.assetId}/valuation/recalculate`, { organizationId: state.organizationId, reason });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    await openAsset(state.asset.assetId);
    selectTab("valuation");
    showMessage(res.data.result === "RECALCULATED" ? "Asset Value recalculated." : "Asset Value was already up to date.", "success");
  }

  function openValOverride() {
    const v = (state.valuation || {}).current || {};
    const configured = VAL_METHOD[v.configuredMethod] || v.configuredMethod || "--";
    const others = v.overrideAllowed ? Object.keys(VAL_METHOD).filter(m => m !== v.configuredMethod) : [];
    document.getElementById("argValMethod").innerHTML = `<option value="">Configured method (${esc(configured)}) -- no override</option>`
      + others.map(m => `<option value="${m}"${m === v.methodOverride ? " selected" : ""}>${esc(VAL_METHOD[m])}</option>`).join("");
    document.getElementById("argValModalNote").textContent = `Valuation configuration v${v.configVersionNo} uses ${configured}. `
      + (v.overrideAllowed ? "An asset-level method applies to this asset only and is recorded with your reason."
                           : "This version does not permit overrides; you can only remove the recorded override.");
    document.getElementById("argValReason").value = "";
    const msg = document.getElementById("argValMessage"); msg.hidden = true; msg.textContent = "";
    document.getElementById("argValModal").hidden = false;
  }

  async function submitValOverride() {
    const msg = document.getElementById("argValMessage");
    const res = await api("POST", `/${state.asset.assetId}/valuation/method`, {
      organizationId: state.organizationId, method: val("argValMethod") || null, reason: val("argValReason") || null
    });
    if (!res.ok) { msg.textContent = res.error; msg.hidden = false; return; }
    document.getElementById("argValModal").hidden = true;
    await openAsset(state.asset.assetId);
    selectTab("valuation");
    showMessage("Valuation method saved; Asset Value recalculated.", "success");
  }

  // ------------------------------------------------------------------ workflows (433)
  const WF_ACTOR = { START: "Requester", WORKER: "Asset team", APPROVER: "Approver (not the requester)", CURRENT_OWNER: "Current owner", NEW_OWNER: "New owner" };
  const WF_OUTCOME = { DONE: "Done", APPROVED: "Approved", CONFIRMED: "Confirmed", REJECTED: "Rejected / declined" };

  async function ensureWorkflowDefs() {
    if (state.wfDefs) return true;
    const res = await api("GET", `/workflows/definitions?organizationId=${state.organizationId}`);
    if (!res.ok) return false;
    state.wfDefs = res.data.data;
    return true;
  }

  async function loadWorkflows() {
    if (!state.asset) return;
    if (!await ensureWorkflowDefs()) return;
    const res = await api("GET", `/workflows?organizationId=${state.organizationId}&assetId=${state.asset.assetId}&openOnly=false`);
    if (!res.ok) return;
    const cases = res.data.data || [];
    document.getElementById("argWorkflowTab").hidden = false;
    const typeSel = document.getElementById("argWfType");
    if (typeSel) typeSel.innerHTML = (state.wfDefs.workflows || []).map(w => `<option value="${esc(w.workflowCode)}">${esc(w.workflowName)}</option>`).join("");
    document.getElementById("argWfCases").innerHTML = cases.map(c => `
      <tr><td>#${esc(c.caseId)}</td><td>${esc(c.workflowName)}</td><td>${esc(c.caseStatus === "OPEN" ? "Open" : c.caseStatus === "COMPLETED" ? "Completed" : "Cancelled")}</td>
          <td>${c.caseStatus === "OPEN" ? `${esc(c.currentStepNo)} of ${esc(c.stepCount)}: ${esc(c.currentStepName || "")}` : "--"}</td>
          <td>${esc(c.requestedByName || c.requestedBy)}<div class="arg-note">${esc(dateTime(c.requestedDt))}</div></td>
          <td>${esc(dateTime(c.closedDt) || "--")}</td></tr>`).join("") || empty(6, "No workflow case yet.");
    const open = cases.find(c => c.caseStatus === "OPEN");
    document.getElementById("argWfStartBar")?.toggleAttribute("hidden", !!open);
    state.wfCase = null;
    document.getElementById("argWfCase").hidden = true;
    if (open) await loadWorkflowCase(open.caseId);
  }

  async function loadWorkflowCase(caseId) {
    const res = await api("GET", `/workflows/${caseId}?organizationId=${state.organizationId}`);
    if (!res.ok) return;
    const d = res.data.data, c = d.workflowCase;
    state.wfCase = d;
    document.getElementById("argWfCase").hidden = false;
    document.getElementById("argWfCaseTitle").textContent = `${c.workflowName} -- case #${c.caseId}`;
    document.getElementById("argWfCaseInfo").textContent = [
      `Started by ${c.requestedByName || c.requestedBy} on ${dateTime(c.requestedDt)}: ${c.reason}`,
      c.referenceText ? `Reference: ${c.referenceText}` : null,
      c.newOwnerName ? `Owner: ${c.previousOwnerName || "--"} -> ${c.newOwnerName}` : null,
      c.destLocationName ? `Destination: ${[c.destLocationName, c.destBuilding, c.destFloor, c.destRoom].filter(Boolean).join(" / ")} (from ${c.originLocationName || "--"})` : null,
      c.containment ? `Containment: ${c.containment === "QUARANTINE" ? "quarantine" : "controlled use"}` : null
    ].filter(Boolean).join(". ") + ".";
    document.getElementById("argWfSteps").innerHTML = (d.steps || []).map(st => {
      const cls = st.stepNo < c.currentStepNo || (st.stepNo === c.currentStepNo && c.caseStatus !== "OPEN") ? "arg-wf-done"
                : st.stepNo === c.currentStepNo ? "arg-wf-current" : "arg-wf-todo";
      return `<li class="${cls}">${esc(st.stepName)} <span class="arg-note">(${esc(WF_ACTOR[st.actorKind] || st.actorKind)}${st.lifecycleToStatus ? `; asset to ${esc(st.lifecycleToStatus.replace(/_/g, " ").toLowerCase())}` : ""})</span></li>`;
    }).join("");
    const cur = (d.steps || []).find(st => st.stepNo === c.currentStepNo);
    const acts = [];
    if (cur && c.caseStatus === "OPEN") {
      if (cur.actorKind === "WORKER" && CAN_EDIT) acts.push(["COMPLETE", "Complete step", true]);
      if (cur.actorKind === "APPROVER" && CAN_APPROVE && !c.isRequester) acts.push(["APPROVE", cur.stepCode === "VERIFY" ? "Verify" : "Approve", true], ["REJECT", "Reject", false]);
      if ((cur.actorKind === "CURRENT_OWNER" && c.isPreviousOwner) || (cur.actorKind === "NEW_OWNER" && c.isNewOwner))
        acts.push(["CONFIRM", "Confirm", true], ["DECLINE", "Decline", false]);
    }
    if (c.caseStatus === "OPEN" && c.isRequester) acts.push(["CANCEL", "Cancel case", false]);
    document.getElementById("argWfActions").innerHTML = acts.map(([a, l, p]) => `<button class="pm-button${p ? " primary" : ""}" type="button" data-arg-wf-act="${a}">${l}</button>`).join("")
      || `<span class="arg-note">${c.caseStatus === "OPEN" ? `Waiting for: ${esc(WF_ACTOR[cur?.actorKind] || "")}.` : ""}</span>`;
    const working = acts.some(([a]) => a !== "CANCEL");
    document.getElementById("argWfCurrent").hidden = c.caseStatus !== "OPEN";
    document.getElementById("argWfGuidance").textContent = cur ? `Step ${cur.stepNo}: ${cur.stepName}. ${cur.guidance || ""}` : "";
    ["argWfNote", "argWfRef", "argWfEv"].forEach(id => { document.getElementById(id).value = ""; document.getElementById(id).disabled = !working; });
    document.getElementById("argWfChoice").value = "";
    document.getElementById("argWfChoiceWrap").hidden = !(cur && cur.effectCode === "CONTAINMENT_CHOICE");
    document.getElementById("argWfNoteLabel").textContent = cur && cur.requiresNote ? "Note *" : "Note (required to reject, decline or cancel)";
    document.getElementById("argWfRefWrap").hidden = !(cur && cur.requiresReference);
    document.getElementById("argWfEvLabel").textContent = cur && cur.requiresEvidence ? "Evidence *" : "Evidence";
    const msg = document.getElementById("argWfMessage"); msg.hidden = true; msg.textContent = "";
    document.getElementById("argWfHistory").innerHTML = (d.history || []).map(h => `
      <tr><td>${esc(dateTime(h.completedDt))}</td><td>${esc(h.stepName || h.stepNo)}</td>
          <td>${esc(WF_OUTCOME[h.stepOutcome] || h.stepOutcome)}${h.choice ? ` (${esc(h.choice.replace(/_/g, " ").toLowerCase())})` : ""}</td>
          <td>${esc(h.completedByName || h.completedBy)}</td>
          <td>${[h.note, h.evidenceText ? "Evidence: " + h.evidenceText : null, h.referenceText ? "Reference: " + h.referenceText : null].filter(Boolean).map(x => `<div>${esc(x)}</div>`).join("")}</td>
          <td>${h.lifecycleTo ? `${esc(h.lifecycleFrom)} -> ${esc(h.lifecycleTo)}` : "--"}</td></tr>`).join("") || empty(6, "No history.");
  }

  async function workflowAction(action) {
    const d = state.wfCase, msg = document.getElementById("argWfMessage");
    if (!d) return;
    const c = d.workflowCase;
    if (action === "CANCEL") {
      const reason = await window.gracUi.promptRequired("Why is this workflow cancelled? The asset keeps its current status; restore it on the Lifecycle tab if needed.",
        { title: "Cancel workflow", inputLabel: "Reason" });
      if (!reason) return;
      const res = await api("POST", `/workflows/${c.caseId}/cancel`, { organizationId: state.organizationId, reason, expectedRecordVersion: c.recordVersion });
      if (!res.ok) { msg.textContent = res.error; msg.hidden = false; return; }
      await openAsset(state.asset.assetId); selectTab("workflows"); showMessage("Workflow cancelled.", "success");
      return;
    }
    if ((action === "REJECT" || action === "DECLINE") && !val("argWfNote")) { msg.textContent = "Give the reason in the note."; msg.hidden = false; return; }
    if ((action === "APPROVE" || action === "CONFIRM")
        && !await window.gracUi.confirm(action === "APPROVE" ? "Approve this step? Its lifecycle move and effects are applied." : "Confirm this step?")) return;
    const res = await api("POST", `/workflows/${c.caseId}/step`, {
      organizationId: state.organizationId, action, note: val("argWfNote") || null, evidenceText: val("argWfEv") || null,
      referenceText: val("argWfRef") || null, choice: val("argWfChoice") || null, expectedRecordVersion: c.recordVersion
    });
    if (!res.ok) { msg.textContent = res.error; msg.hidden = false; return; }
    await openAsset(state.asset.assetId);
    selectTab("workflows");
    showMessage(res.data.result === "COMPLETED" ? "Workflow completed." : action === "REJECT" || action === "DECLINE" ? "Step rejected; the case went back one step." : "Step recorded.", "success");
  }

  async function openWorkflowStart() {
    if (!await ensureWorkflowDefs()) return;
    await ensureLookups(["MASTER:EMPLOYEE", "MASTER:LOCATION"]);
    const code = val("argWfType");
    const wf = (state.wfDefs.workflows || []).find(w => w.workflowCode === code);
    const steps = (state.wfDefs.steps || []).filter(st => st.workflowCode === code);
    document.getElementById("argWfModalTitle").textContent = `Start: ${wf ? wf.workflowName : code}`;
    document.getElementById("argWfSteplist").textContent = "Steps: " + steps.map(st => st.stepName).join(" -> ") + ".";
    document.getElementById("argWfOwnerWrap").hidden = code !== "OWNER_CHANGE";
    ["argWfSiteWrap", "argWfBuildingWrap", "argWfFloorWrap", "argWfRoomWrap"].forEach(id => { document.getElementById(id).hidden = code !== "LOCATION_TRANSFER"; });
    document.getElementById("argWfOwner").innerHTML = `<option value="">Select</option>` + (state.lookups["MASTER:EMPLOYEE"] || [])
      .map(e => `<option value="${esc(e.value)}">${esc(e.label)}</option>`).join("");
    document.getElementById("argWfSite").innerHTML = `<option value="">Select</option>` + (state.lookups["MASTER:LOCATION"] || [])
      .map(l => `<option value="${esc(l.value)}">${esc(l.label)}</option>`).join("");
    fillDestination("site");
    const first = steps.find(st => st.stepNo === 1);
    document.getElementById("argWfStartRefWrap").hidden = !(first && first.requiresReference);
    document.getElementById("argWfStartRefLabel").textContent = code === "LOCATION_TRANSFER" ? "Destination and handover reference *" : "Reference *";
    ["argWfReason", "argWfStartRef"].forEach(id => { document.getElementById(id).value = ""; });
    const msg = document.getElementById("argWfModalMessage"); msg.hidden = true; msg.textContent = "";
    document.getElementById("argWfModal").hidden = false;
  }

  // Building -> site, floor -> building, room -> floor (organization option lists, 423).
  function fillDestination(changed) {
    const opts = (state.wfDefs && state.wfDefs.options) || [];
    const pick = (group, parent) => `<option value="">Select</option>` + opts.filter(o => o.optionGroup === group && (!o.parentValue || !parent || String(o.parentValue) === String(parent)))
      .map(o => `<option value="${esc(o.optionValue)}">${esc(o.optionLabel)}</option>`).join("");
    if (changed === "site") document.getElementById("argWfBuilding").innerHTML = pick("building", val("argWfSite"));
    if (changed === "site" || changed === "building") document.getElementById("argWfFloor").innerHTML = val("argWfBuilding") ? pick("floor", val("argWfBuilding")) : `<option value="">Select</option>`;
    document.getElementById("argWfRoom").innerHTML = val("argWfFloor") ? pick("room", val("argWfFloor")) : `<option value="">Select</option>`;
  }

  async function submitWorkflowStart() {
    const code = val("argWfType"), msg = document.getElementById("argWfModalMessage");
    const res = await api("POST", `/${state.asset.assetId}/workflows`, {
      organizationId: state.organizationId, workflowCode: code, reason: val("argWfReason") || null, referenceText: val("argWfStartRef") || null,
      newOwnerId: code === "OWNER_CHANGE" ? (Number(val("argWfOwner")) || null) : null,
      destLocationId: code === "LOCATION_TRANSFER" ? (Number(val("argWfSite")) || null) : null,
      destBuilding: code === "LOCATION_TRANSFER" ? (val("argWfBuilding") || null) : null,
      destFloor: code === "LOCATION_TRANSFER" ? (val("argWfFloor") || null) : null,
      destRoom: code === "LOCATION_TRANSFER" ? (val("argWfRoom") || null) : null
    });
    if (!res.ok) { msg.textContent = res.error; msg.hidden = false; return; }
    document.getElementById("argWfModal").hidden = true;
    await openAsset(state.asset.assetId);
    selectTab("workflows");
    showMessage("Workflow started.", "success");
  }

  async function openWorkflowList() {
    const body = document.getElementById("argWfListBody");
    document.getElementById("argWfListModal").hidden = false;
    if (!state.organizationId) { body.innerHTML = empty(6, "Select an organization."); return; }
    body.innerHTML = empty(6, "Loading...");
    const res = await api("GET", `/workflows?organizationId=${state.organizationId}&openOnly=true`);
    if (!res.ok) { body.innerHTML = empty(6, res.error); return; }
    body.innerHTML = (res.data.data || []).map(c => `
      <tr><td>#${esc(c.caseId)}${c.awaitingMe ? ` <span class="arg-chip arg-tc-warn">Waiting for you</span>` : ""}</td>
          <td>${esc(c.assetName)}<div class="arg-note">#${esc(c.assetId)}</div></td><td>${esc(c.workflowName)}</td>
          <td>${esc(c.currentStepNo)} of ${esc(c.stepCount)}: ${esc(c.currentStepName || "")}<div class="arg-note">${esc(WF_ACTOR[c.currentActorKind] || "")}</div></td>
          <td>${esc(c.requestedByName || c.requestedBy)}<div class="arg-note">${esc(dateTime(c.requestedDt))}</div></td>
          <td><button class="pm-button" type="button" data-arg-wf-asset="${esc(c.assetId)}">Open</button></td></tr>`).join("") || empty(6, "No open workflow case.");
  }

  // ------------------------------------------------------------------ helpers
  // 443: link the discovery record to the asset just registered for it.
  async function linkDiscovery(assetId) {
    const x = state.discovery;
    state.discovery = null;
    const res = await api("POST", `/exceptions/${x.exceptionId}/resolve`, {
      organizationId: state.organizationId, action: "REGISTER", assetId, note: null, expectedRecordVersion: x.recordVersion
    }, discoveryBase);
    try { window.history.replaceState(null, "", window.location.pathname); } catch (_) { /* address stays */ }
    return res.ok ? `Asset registered as Draft and linked to the discovery record ${x.externalKey || "#" + x.exceptionId} (${x.sourceName}).`
                  : `Saved as Draft, but the discovery record was not linked: ${res.error} Link it in Asset Discovery.`;
  }

  async function api(method, path, body, root) {
    try {
      const r = await fetch(U((root || base) + path), {   // 443: root = another asset-config area
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
  function statusChip(name, phase) {
    const cls = phase ? "arg-ph-" + String(phase).toLowerCase() : "arg-ph-acquisition";
    return `<span class="arg-chip ${cls}" title="${esc(phase || "")}">${esc(name || "--")}</span>`;
  }
  function parseArray(v) { try { const a = JSON.parse(v || "[]"); return Array.isArray(a) ? a.map(String) : []; } catch (_) { return []; } }
  function cssEsc(v) { return window.CSS && CSS.escape ? CSS.escape(v) : String(v).replace(/"/g, '\\"'); }
  function empty(cols, text) { return `<tr><td colspan="${cols}" class="pm-empty">${esc(text)}</td></tr>`; }
  function showMessage(text, kind) {
    const el = document.getElementById("argMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.classList.toggle("info", kind === "info"); el.hidden = !text;
  }
  function hideMessage() { const el = document.getElementById("argMessage"); el.hidden = true; el.textContent = ""; }
  function val(id) { return (document.getElementById(id).value || "").trim(); }
  function date(v) { return v ? String(v).substring(0, 10) : ""; }   // SQL DATE values: yyyy-mm-dd, no time-zone shift
  function dateTime(v) { if (!v) return ""; const x = new Date(v); return isNaN(x) ? String(v) : x.toLocaleString(); }
  function esc(v) { return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
})();
