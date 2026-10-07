// =====================================================================
// Contracts (migration 434) -- BRD 7, 7.2, 7.4.
// Loaded by asset-contracts.cshtml. List: contracts?...; lookups:
// contracts/lookups; contract dialog: contracts/{id} (summary, versions,
// contacts, documents, approvals, warnings, contact history); version:
// contracts/versions/{id} (+ /action, /documents); compare:
// contracts/versions/compare; contacts: contracts/{id}/contacts and
// contracts/contacts/{id}/action. Only a Draft is editable, the submitter
// cannot review / approve, another person validates a contact mapping --
// the procedures enforce it; this screen mirrors it.
// 435: coverage gaps (contracts/coverage-gaps), coverage requirements and
// expiring window (contracts/coverage-config, contracts/coverage-requirements,
// contracts/coverage-settings), entitlements and asset coverage of a Draft
// version (contracts/versions/{id}/entitlements | coverage | coverage/bulk,
// contracts/entitlements/{id}/remove, contracts/coverage/{id}/remove, asset
// picker contracts/assets), coverage posture / history and comparison.
// 436: renewals -- contracts/renewals/due, contracts/renewals (list, also per
// contract = Renewal history), contracts/{id}/renewals (start),
// contracts/renewals/{id} (detail, save), contracts/renewals/{id}/action,
// contracts/renewal-items/{id}/resolve.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config/contracts";
  const root = document.getElementById("acoRoot");
  if (!root) return;
  const CAN_ADD = root.dataset.canAdd === "1";
  const CAN_EDIT = root.dataset.canEdit === "1";
  const CAN_APPROVE = root.dataset.canApprove === "1";

  const CONTRACT_STATUS = {
    DRAFT: ["Draft", "aco-st-open"], APPROVED: ["Approved", "aco-st-wait"], ACTIVE: ["Active", "aco-st-active"],
    EXPIRED: ["Expired", "aco-st-ended"], TERMINATED: ["Terminated", "aco-st-bad"]
  };
  const VERSION_STATUS = {
    DRAFT: "aco-st-open", IN_REVIEW: "aco-st-wait", PENDING_APPROVAL: "aco-st-wait", APPROVED: "aco-st-wait",
    ACTIVE: "aco-st-active", SUPERSEDED: "aco-st-ended", EXPIRED: "aco-st-ended", TERMINATED: "aco-st-bad", REJECTED: "aco-st-ended"
  };
  const VERSION_TYPE = { INITIAL: "Initial", RENEWAL: "Renewal", AMENDMENT: "Amendment", EXTENSION: "Extension",
                         VARIATION: "Variation", CORRECTION: "Correction", TERMINATION: "Termination" };
  const DOC_TYPE = { SIGNED_AGREEMENT: "Signed agreement", SCHEDULE: "Schedule", AMENDMENT: "Amendment", QUOTATION: "Quotation",
                     PURCHASE_ORDER: "Purchase order", INVOICE: "Invoice", SUPPORTING_EVIDENCE: "Supporting evidence", OTHER: "Other" };
  const CHANNEL = { EMAIL: "Email", PHONE: "Phone", PORTAL: "Portal", OTHER: "Other" };
  const MAPPING_STATE = { PENDING: ["Pending validation", "aco-st-wait"], CURRENT: ["Active", "aco-st-active"],
                          FUTURE: ["Future", "aco-st-open"], ENDED: ["Ended", "aco-st-ended"] };
  const LINE_STATUS = { COVERED: ["Covered", "aco-st-active"], EXPIRING: ["Expiring", "aco-st-wait"], SUSPENDED: ["Suspended", "aco-st-wait"],
                        EXCLUDED: ["Excluded", "aco-st-ended"], EXPIRED: ["Expired", "aco-st-bad"], UNCOVERED: ["Uncovered", "aco-st-bad"],
                        NOT_STARTED: ["Not started", "aco-st-open"] };
  const REN_TYPE = { RENEWAL: "Renewal", EXTENSION: "Extension", REBID: "Rebid", REPLACEMENT: "Replacement", NON_RENEWAL: "Non-renewal" };
  const REN_STATUS = { OPEN: "aco-st-open", PENDING_APPROVAL: "aco-st-wait", APPROVED: "aco-st-wait", COMPLETED: "aco-st-active", CANCELLED: "aco-st-ended" };
  const REN_OUTCOME = { RENEWED: "Renewed", PARTIALLY_RENEWED: "Partially renewed", REPLACED: "Replaced", NOT_RENEWED: "Not renewed", CANCELLED: "Cancelled" };
  const RECON = { COVERED: ["Covered", "aco-st-active"], ADDED: ["Added", "aco-st-open"], REMOVED: ["Removed", "aco-st-ended"],
                  EXCLUDED: ["Excluded", "aco-st-wait"], UNRESOLVED: ["Unresolved", "aco-st-bad"] };
  const RESOLUTION = { MAPPED: "Mapped", SEPARATELY_RENEWED: "Separately renewed", REPLACED: "Replaced", UNINSTALLED: "Uninstalled",
                       EXEMPTED: "Exempted", RETIRED: "Retired" };
  const COV_STATE = { COVERED: "Covered", EXCLUDED: "Excluded", SUSPENDED: "Suspended" };
  const REQ_LEVEL = { NOT_APPLICABLE: "Not applicable", OPTIONAL: "Optional", REQUIRED: "Required" };
  const CHANGE = { ADDED: ["Added", "aco-st-active"], REMOVED: ["Removed", "aco-st-bad"], CHANGED: ["Changed", "aco-st-wait"], SAME: ["Same", "aco-st-ended"] };
  const VERSION_FIELDS = [
    ["acoVfLabel", "versionLabel"], ["acoVfStart", "effectiveStart", "date"], ["acoVfEnd", "effectiveEnd", "date"],
    ["acoVfNotice", "noticeDate", "date"], ["acoVfDecision", "decisionDate", "date"], ["acoVfTermination", "terminationDate", "date"],
    ["acoVfValue", "contractValue", "number"], ["acoVfCurrency", "currencyCode"], ["acoVfTax", "taxDetails"],
    ["acoVfPayment", "paymentTerms"], ["acoVfPo", "poReference"], ["acoVfInvoice", "invoiceReference"], ["acoVfCost", "costAllocation"],
    ["acoVfRenewal", "renewalTerms"], ["acoVfScope", "serviceScope"], ["acoVfSla", "slaTerms"], ["acoVfHours", "supportHours"],
    ["acoVfResponse", "responseTime"], ["acoVfResolution", "resolutionTime"], ["acoVfVisits", "serviceVisits"],
    ["acoVfOwner", "contractOwnerId", "id"], ["acoVfProcurement", "procurementOwnerId", "id"], ["acoVfSummary", "changeSummary"]
  ];

  const state = { organizationId: null, pager: null, rows: [], lookups: null, detail: null, tab: "SUMMARY", version: null,
                  compare: null, contactEdit: null, endMapping: null, editing: null,
                  mainTab: "CONTRACTS", gapPager: null, config: null, entEdit: null, lineEdit: null, picks: [],   // 435
                  renPager: null, renewal: null, renewalContract: null, resolveItem: null };                     // 436

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    state.pager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "acoPager", onChange: refreshList }) : null;
    state.gapPager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "acoGapPager", onChange: refreshGaps }) : null;
    state.renPager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "acoRenPager", onChange: refreshRenewals }) : null;
    bind();
    await populateOrgs();
    const sel = document.getElementById("acoOrg");
    window.gracOrgPref.apply(sel);   // 2026-10-06: last-picked org, else lowest id
    // 451: opened from the Asset & Contract dashboard -- organization, tab and filter (Shared/dashboard-drill.js).
    const dashDrill = window.__pmDrill ? window.__pmDrill.read() : null;
    window.__pmDrill?.preselectFor(dashDrill, sel, { "": { status: "acoStatus" }, CONTRACTS: { status: "acoStatus" } });
    await changeOrg(Number(sel.value) || null);
    window.__pmDrill?.showOnPage("acoRoot", "data-aco-main", dashDrill);
  }

  async function populateOrgs() {
    const sel = document.getElementById("acoOrg");
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
    document.getElementById("acoOrg").addEventListener("change", e => changeOrg(Number(e.target.value) || null));
    document.getElementById("acoRefresh").addEventListener("click", () => refreshList());
    let t = null;
    document.getElementById("acoSearch").addEventListener("input", () => { clearTimeout(t); t = setTimeout(() => { state.pager?.reset(true); refreshList(); }, 300); });
    ["acoStatus", "acoVendorFilter", "acoTypeFilter"].forEach(id =>
      document.getElementById(id).addEventListener("change", () => { state.pager?.reset(true); refreshList(); }));
    document.getElementById("acoNew")?.addEventListener("click", () => openEdit(null));
    document.getElementById("acoListBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-aco-contract]");
      if (tr) openContract(Number(tr.dataset.acoContract), "SUMMARY");
    });
    document.querySelectorAll("[data-close-aco]").forEach(b => b.addEventListener("click", () => { document.getElementById(b.dataset.closeAco).hidden = true; }));
    document.querySelectorAll("[data-aco-tab]").forEach(b => b.addEventListener("click", () => selectDetailTab(b.dataset.acoTab)));
    document.getElementById("acoEditBtn")?.addEventListener("click", () => openEdit(state.detail?.contract || null));
    document.getElementById("acoNewVersionBtn")?.addEventListener("click", openNewVersion);
    document.getElementById("acoOpenVersionBtn").addEventListener("click", () => {
      const id = state.detail?.contract?.openVersionId;
      if (id) openVersion(id);
    });
    document.getElementById("acoEditForm").addEventListener("submit", ev => { ev.preventDefault(); submitEdit(); });
    document.getElementById("acoNewVersionForm").addEventListener("submit", ev => { ev.preventDefault(); submitNewVersion(); });
    document.getElementById("acoVersionsBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-aco-version]");
      if (tr) openVersion(Number(tr.dataset.acoVersion));
    });
    document.getElementById("acoCompareBtn").addEventListener("click", runCompare);
    document.getElementById("acoCmpChangedOnly").addEventListener("change", renderCompare);
    document.getElementById("acoCmpExport").addEventListener("click", exportCompare);
    ["acoDocVersion", "acoDocType"].forEach(id => document.getElementById(id).addEventListener("change", renderDocuments));
    document.getElementById("acoVersionForm").addEventListener("submit", ev => ev.preventDefault());
    document.getElementById("acoVersionActions").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-aco-vact]");
      if (b) versionAction(b.dataset.acoVact);
    });
    document.getElementById("acoDfAdd").addEventListener("click", addDocument);
    document.getElementById("acoVersionDocs").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-aco-doc-remove]");
      if (b) removeDocument(Number(b.dataset.acoDocRemove));
    });
    document.getElementById("acoContactNew")?.addEventListener("click", () => openContact(null));
    document.getElementById("acoContactsBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-aco-cact]");
      if (b) contactAction(Number(b.dataset.acoMapping), b.dataset.acoCact);
    });
    document.getElementById("acoCfRole").addEventListener("change", syncRoleUse);
    document.getElementById("acoContactForm").addEventListener("submit", ev => { ev.preventDefault(); submitContact(); });
    document.getElementById("acoEndForm").addEventListener("submit", ev => { ev.preventDefault(); submitEnd(); });
    // 435: main tabs, gaps, requirements
    document.querySelectorAll("[data-aco-main]").forEach(b => b.addEventListener("click", () => selectMainTab(b.dataset.acoMain)));
    let tg = null;
    document.getElementById("acoGapSearch").addEventListener("input", () => { clearTimeout(tg); tg = setTimeout(() => { state.gapPager?.reset(true); refreshGaps(); }, 300); });
    document.getElementById("acoGapType").addEventListener("change", () => { state.gapPager?.reset(true); refreshGaps(); });
    document.getElementById("acoReqType").addEventListener("change", renderRequirements);
    document.getElementById("acoReqBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-aco-req]");
      if (b) saveRequirement(b.dataset.acoReq);
    });
    document.getElementById("acoSetSave")?.addEventListener("click", saveWindow);
    // 435: entitlements and coverage of a Draft version
    document.getElementById("acoEfSave").addEventListener("click", saveEntitlement);
    document.getElementById("acoEfCancel").addEventListener("click", () => fillEntForm(null));
    document.getElementById("acoVersionEnts").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-aco-ent]");
      if (b) entitlementAction(Number(b.dataset.acoEntId), b.dataset.acoEnt);
    });
    document.getElementById("acoCfFind").addEventListener("click", findAssets);
    document.getElementById("acoCfAssetSearch").addEventListener("keydown", ev => { if (ev.key === "Enter") { ev.preventDefault(); findAssets(); } });
    document.getElementById("acoCfEnt").addEventListener("change", () => {
      const e = (state.version?.entitlements || []).find(x => String(x.entitlementId) === val("acoCfEnt"));
      if (e) document.getElementById("acoCfCovType").value = e.coverageType;
    });
    document.getElementById("acoCfPickAll").addEventListener("change", ev => {
      document.querySelectorAll("#acoCfPickBody input[data-aco-pick]:not(:disabled)").forEach(c => { c.checked = ev.target.checked; });
    });
    document.getElementById("acoCfAddSel").addEventListener("click", () => coverAssets(null));
    document.getElementById("acoCfPickBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-aco-pick-one]");
      if (b) coverAssets([Number(b.dataset.acoPickOne)]);
    });
    document.getElementById("acoVersionCov").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-aco-cov]");
      if (b) coverageAction(Number(b.dataset.acoCovId), b.dataset.acoCov);
    });
    document.getElementById("acoLfState").addEventListener("change", () => {
      document.getElementById("acoLfReasonWrap").hidden = val("acoLfState") !== "EXCLUDED";
    });
    document.getElementById("acoLineForm").addEventListener("submit", ev => { ev.preventDefault(); saveLine(); });
    // 436: renewals
    document.getElementById("acoDueWithin").addEventListener("change", refreshDue);
    document.getElementById("acoRenStatus").addEventListener("change", () => { state.renPager?.reset(true); refreshRenewals(); });
    let tr = null;
    document.getElementById("acoRenSearch").addEventListener("input", () => { clearTimeout(tr); tr = setTimeout(() => { state.renPager?.reset(true); refreshRenewals(); }, 300); });
    document.getElementById("acoDueBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-aco-due-start]");
      if (b) openStartRenewal(Number(b.dataset.acoDueStart), b.dataset.acoDueNumber);
    });
    ["acoRenBody", "acoRenewalHistoryBody"].forEach(id => document.getElementById(id).addEventListener("click", ev => {
      const t = ev.target.closest("tr[data-aco-renewal]");
      if (t) openRenewal(Number(t.dataset.acoRenewal));
    }));
    document.getElementById("acoStartRenewalBtn")?.addEventListener("click", () => {
      const c = state.detail?.contract;
      if (c) openStartRenewal(c.contractId, c.contractNumber);
    });
    document.getElementById("acoStartRenewalForm").addEventListener("submit", ev => { ev.preventDefault(); submitStartRenewal(); });
    document.getElementById("acoRenForm").addEventListener("submit", ev => ev.preventDefault());
    document.getElementById("acoRenewalModal").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-aco-ract]");
      if (b) renewalAction(b.dataset.acoRact);
      const r = ev.target.closest("button[data-aco-resolve]");
      if (r) openResolve(Number(r.dataset.acoResolve));
    });
    document.getElementById("acoRfType").addEventListener("change", syncRenewalForm);
    document.getElementById("acoResolveForm").addEventListener("submit", ev => { ev.preventDefault(); submitResolve(); });
  }

  async function changeOrg(id) {
    state.organizationId = id;
    state.lookups = null;
    hideMessage();
    state.pager?.reset(true);
    state.config = null;
    await loadLookups();
    await selectMainTab(state.mainTab);
  }

  // 435: main tabs -- contracts, coverage gaps, coverage requirements
  async function selectMainTab(name) {
    state.mainTab = name;
    document.querySelectorAll("[data-aco-main]").forEach(x => { const on = x.dataset.acoMain === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    document.querySelectorAll("[data-aco-mainpanel]").forEach(p => { p.hidden = p.dataset.acoMainpanel !== name; });
    if (name === "GAPS") { state.gapPager?.reset(true); await refreshGaps(); }
    else if (name === "RENEWALS") { state.renPager?.reset(true); await refreshDue(); await refreshRenewals(); }
    else if (name === "REQUIREMENTS") { await ensureConfig(true); renderRequirements(); }
    else await refreshList();
  }

  async function loadLookups() {
    const vf = document.getElementById("acoVendorFilter"), tf = document.getElementById("acoTypeFilter");
    vf.innerHTML = `<option value="">All vendors</option>`;
    tf.innerHTML = `<option value="">All types</option>`;
    if (!state.organizationId) return;
    const res = await api("GET", `/lookups?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.lookups = res.data.data;
    vf.innerHTML += state.lookups.vendors.map(v => `<option value="${v.vendorId}">${esc(v.vendorName)}</option>`).join("");
    tf.innerHTML += state.lookups.contractTypes.map(o => `<option value="${esc(o.optionValue)}">${esc(o.optionLabel)}</option>`).join("");
    document.getElementById("acoGapType").innerHTML = `<option value="">All coverage types</option>` +
      state.lookups.contractTypes.map(o => `<option value="${esc(o.optionValue)}">${esc(o.optionLabel)}</option>`).join("");
  }

  // ------------------------------------------------------------------ coverage gaps and requirements (435)
  async function refreshGaps() {
    const body = document.getElementById("acoGapBody");
    if (!state.organizationId) { body.innerHTML = empty(7, "Select an organization."); state.gapPager?.clear(); return; }
    body.innerHTML = empty(7, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.gapPager ? state.gapPager.page() : 1, pageSize: state.gapPager ? state.gapPager.size() : 25 });
    if (val("acoGapSearch")) qs.set("search", val("acoGapSearch"));
    if (val("acoGapType")) qs.set("coverageType", val("acoGapType"));
    const res = await api("GET", `/coverage-gaps?${qs}`);
    if (!res.ok) { body.innerHTML = empty(7, res.error); state.gapPager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.gapPager?.setTotal(res.data.data.totalRows, rows.length);
    body.innerHTML = rows.map(g => {
      const [l, css] = LINE_STATUS[g.coverageStatus] || [g.coverageStatus, ""];
      return `<tr><td>${esc(g.assetName)}<div class="aco-note">#${esc(g.assetId)}</div></td><td>${esc(g.assetTypeName)}</td>
        <td>${esc(g.coverageTypeLabel)}</td><td><span class="aco-chip ${css}">${esc(l)}</span></td>
        <td>${esc(g.gapKind === "SHORT" ? "Shorter than " + g.minimumPeriodMonths + " months" : "Missing")}</td>
        <td>${esc(g.missingAction === "BLOCK_ACTIVATION" ? "Blocks activation" : "Warning")}</td>
        <td>${g.contractNumber ? esc(g.contractNumber) + `<div class="aco-note">to ${esc(date(g.effectiveEnd) || "--")}</div>` : "--"}</td></tr>`;
    }).join("") || empty(7, "No coverage gaps.");
  }

  async function ensureConfig(force) {
    if (state.config && !force) return true;
    if (!state.organizationId) return false;
    const res = await api("GET", `/coverage-config?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return false; }
    state.config = res.data.data;
    const sel = document.getElementById("acoReqType"), keep = sel.value;
    sel.innerHTML = state.config.assetTypes.map(t => `<option value="${t.assetTypeId}">${esc(t.assetTypeName)}</option>`).join("");
    if (keep && state.config.assetTypes.some(t => String(t.assetTypeId) === keep)) sel.value = keep;
    document.getElementById("acoCfAssetType").innerHTML = `<option value="">All asset types</option>` +
      state.config.assetTypes.map(t => `<option value="${t.assetTypeId}">${esc(t.assetTypeName)}</option>`).join("");
    document.getElementById("acoSetWindow").value = state.config.settings ? state.config.settings.expiringWindowDays : 30;
    return true;
  }

  function renderRequirements() {
    const body = document.getElementById("acoReqBody"), c = state.config;
    if (!c) { body.innerHTML = empty(7, "Select an organization."); return; }
    const typeId = Number(val("acoReqType"));
    if (!typeId) { body.innerHTML = empty(7, "No asset type available."); return; }
    const dis = CAN_EDIT ? "" : " disabled";
    body.innerHTML = c.coverageTypes.map(o => {
      const r = c.requirements.find(x => x.assetTypeId === typeId && x.coverageType === o.optionValue) || {};
      const k = esc(o.optionValue);
      const opt = (map, cur) => Object.entries(map).map(([v, l]) => `<option value="${v}"${v === cur ? " selected" : ""}>${esc(l)}</option>`).join("");
      return `<tr data-aco-req-row="${k}">
        <td>${esc(o.optionLabel)}${r.updatedBy ? `<div class="aco-note">${esc(r.updatedBy)} ${esc(dateTime(r.updatedDt))}</div>` : ""}</td>
        <td><select data-f="level"${dis}>${opt(REQ_LEVEL, r.requirementLevel || "NOT_APPLICABLE")}</select></td>
        <td><input type="number" data-f="months" min="1" max="600" value="${esc(r.minimumPeriodMonths ?? "")}"${dis} /></td>
        <td><select data-f="licence"${dis}>${opt({ "": "--", ENTERPRISE: "Enterprise", STANDALONE: "Standalone" }, r.licenceHandling || "")}</select></td>
        <td><select data-f="action"${dis}>${opt({ WARN: "Warning", BLOCK_ACTIVATION: "Block activation" }, r.missingAction || "WARN")}</select></td>
        <td><input type="text" data-f="notes" maxlength="1000" value="${esc(r.notes || "")}"${dis} /></td>
        <td>${CAN_EDIT ? `<button class="pm-button" type="button" data-aco-req="${k}">Save</button>` : ""}</td></tr>`;
    }).join("") || empty(7, "The coverage type list is empty (Option Lists).");
  }

  async function saveRequirement(coverageType) {
    const tr = Array.from(document.querySelectorAll("#acoReqBody tr[data-aco-req-row]")).find(x => x.dataset.acoReqRow === coverageType);
    if (!tr) return;
    const f = n => (tr.querySelector(`[data-f="${n}"]`).value || "").trim();
    const res = await api("POST", "/coverage-requirements", {
      organizationId: state.organizationId, assetTypeId: Number(val("acoReqType")), coverageType,
      requirementLevel: f("level"), minimumPeriodMonths: f("months") ? Number(f("months")) : null,
      licenceHandling: f("licence") || null, missingAction: f("action"), notes: f("notes") || null
    });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    await ensureConfig(true);
    renderRequirements();
    showMessage("Requirement saved.", "success");
  }

  async function saveWindow() {
    const res = await api("POST", "/coverage-settings", { organizationId: state.organizationId, expiringWindowDays: Number(val("acoSetWindow")) || 0 });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    await ensureConfig(true);
    showMessage("Expiring window saved.", "success");
  }

  // ------------------------------------------------------------------ list
  async function refreshList() {
    const body = document.getElementById("acoListBody");
    if (!state.organizationId) { body.innerHTML = empty(9, "Select an organization."); state.pager?.clear(); return; }
    body.innerHTML = empty(9, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.pager ? state.pager.page() : 1, pageSize: state.pager ? state.pager.size() : 25 });
    if (val("acoSearch")) qs.set("search", val("acoSearch"));
    if (val("acoStatus")) qs.set("status", val("acoStatus"));
    if (val("acoVendorFilter")) qs.set("vendorId", val("acoVendorFilter"));
    if (val("acoTypeFilter")) qs.set("contractType", val("acoTypeFilter"));
    const res = await api("GET", `?${qs}`);
    if (!res.ok) { body.innerHTML = empty(9, res.error); state.pager?.clear(); return; }
    state.rows = res.data.data.rows || [];
    state.pager?.setTotal(res.data.data.totalRows, state.rows.length);
    body.innerHTML = state.rows.map(r => {
      const [label, css] = CONTRACT_STATUS[r.contractStatus] || [r.contractStatus, "aco-st-open"];
      return `<tr data-aco-contract="${r.contractId}">
        <td>${esc(r.contractNumber)}<div class="aco-note">${esc(r.contractName)}${r.parentContractNumber ? " - under " + esc(r.parentContractNumber) : ""}</div></td>
        <td>${esc(r.contractTypeLabel)}</td>
        <td>${esc(r.vendorName)}${r.vendorStatus && r.vendorStatus !== "Active" ? `<div class="aco-note">${esc(r.vendorStatus)}</div>` : ""}</td>
        <td><span class="aco-chip ${css}">${esc(label)}</span></td>
        <td>${r.currentVersionNo ? "v" + esc(r.currentVersionNo) : "--"}</td>
        <td>${r.effectiveStart ? esc(date(r.effectiveStart)) + " to " + esc(date(r.effectiveEnd) || "--") : "--"}</td>
        <td>${money(r.contractValue, r.currencyCode)}</td>
        <td>${esc(r.contractOwnerName || "--")}</td>
        <td>${r.openVersionNo ? `v${esc(r.openVersionNo)} <span class="aco-chip ${VERSION_STATUS[r.openVersionStatus] || ""}">${esc(statusLabel(r.openVersionStatus))}</span>` : "--"}</td>
      </tr>`;
    }).join("") || empty(9, "No contracts.");
  }

  // ------------------------------------------------------------------ contract dialog
  async function openContract(id, tab) {
    const res = await api("GET", `/${id}?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.detail = res.data.data;
    renderContract();
    await loadRenewalHistory();   // 436
    document.getElementById("acoModal").hidden = false;
    selectDetailTab(tab || state.tab || "SUMMARY");
  }

  async function reloadContract() {
    if (!state.detail) return;
    const res = await api("GET", `/${state.detail.contract.contractId}?organizationId=${state.organizationId}`);
    if (res.ok) { state.detail = res.data.data; renderContract(); await loadRenewalHistory(); }
  }

  function selectDetailTab(name) {
    state.tab = name;
    document.querySelectorAll("[data-aco-tab]").forEach(x => { const on = x.dataset.acoTab === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    document.querySelectorAll("[data-aco-panel]").forEach(p => { p.hidden = p.dataset.acoPanel !== name; });
  }

  function renderContract() {
    const d = state.detail, c = d.contract;
    hideDetailMessage();
    document.getElementById("acoTitle").textContent = `${c.contractNumber} - ${c.contractName}`;
    const [label, css] = CONTRACT_STATUS[c.contractStatus] || [c.contractStatus, "aco-st-open"];
    document.getElementById("acoSummary").innerHTML = info([
      ["Status", `<span class="aco-chip ${css}">${esc(label)}</span>`, true],
      ["Type", c.contractTypeLabel], ["Vendor", c.vendorName + (c.vendorStatus && c.vendorStatus !== "Active" ? ` (${c.vendorStatus})` : "")],
      ["Parent agreement", c.parentContractNumber ? `${c.parentContractNumber} - ${c.parentContractName}` : "--"],
      ["Current version", c.currentVersionNo ? `v${c.currentVersionNo} ${VERSION_TYPE[c.currentVersionType] || ""} (${statusLabel(c.currentVersionStatus)})` : "None in force yet"],
      ["Effective", c.effectiveStart ? `${date(c.effectiveStart)} to ${date(c.effectiveEnd) || "--"}` : "--"],
      ["Notice date", date(c.noticeDate) || "--"], ["Decision date", date(c.decisionDate) || "--"],
      ["Termination date", date(c.terminationDate) || "--"],
      ["Value", money(c.contractValue, c.currencyCode), true], ["Payment terms", c.paymentTerms || "--"],
      ["Support hours", c.supportHours || "--"], ["SLA", c.slaTerms || "--"], ["Renewal terms", c.renewalTerms || "--"],
      ["Contract owner", c.contractOwnerName || "--"], ["Procurement owner", c.procurementOwnerName || "--"],
      ["Version in progress", c.openVersionNo ? `v${c.openVersionNo} (${statusLabel(c.openVersionStatus)})` : "--"],
      ["Description", c.description || "--"]
    ]);
    const warn = d.warnings || [];
    document.getElementById("acoWarnings").hidden = warn.length === 0;
    document.getElementById("acoWarningList").innerHTML = warn.map(w => `<li>${esc(w.warning)}</li>`).join("");
    document.getElementById("acoOpenVersionBtn").hidden = !c.openVersionId;
    const terminated = c.contractStatus === "TERMINATED";
    const nv = document.getElementById("acoNewVersionBtn");
    if (nv) nv.hidden = terminated || !!c.openVersionId;
    const cn = document.getElementById("acoContactNew");
    if (cn) cn.hidden = terminated;
    const sr = document.getElementById("acoStartRenewalBtn");   // 436
    if (sr) sr.hidden = terminated || !c.currentVersionId;

    // Version history
    document.getElementById("acoVersionsBody").innerHTML = d.versions.map(v => `<tr data-aco-version="${v.versionId}">
        <td>v${esc(v.versionNo)}${v.versionLabel ? `<div class="aco-note">${esc(v.versionLabel)}</div>` : ""}</td>
        <td>${esc(VERSION_TYPE[v.versionType] || v.versionType)}</td>
        <td><span class="aco-chip ${VERSION_STATUS[v.statusCode] || ""}">${esc(v.statusName)}</span></td>
        <td>${v.effectiveStart ? esc(date(v.effectiveStart)) + " to " + esc(date(v.effectiveEnd) || "--") : "--"}</td>
        <td>${money(v.contractValue, v.currencyCode)}</td>
        <td>${esc(v.createdByName || v.createdBy || "")}<div class="aco-note">${esc(dateTime(v.createdDt))}</div></td>
        <td>${v.approvalDt ? esc(v.approvedByName || v.approvedBy || "") + `<div class="aco-note">${esc(dateTime(v.approvalDt))}</div>` : "--"}</td>
        <td>${v.supersedesVersionNo ? "replaces v" + esc(v.supersedesVersionNo) : ""}${v.supersededByVersionNo ? `<div class="aco-note">replaced by v${esc(v.supersededByVersionNo)}</div>` : ""}</td>
      </tr>`).join("") || empty(8, "No versions.");
    const opts = d.versions.map(v => `<option value="${v.versionId}">v${esc(v.versionNo)} - ${esc(VERSION_TYPE[v.versionType] || v.versionType)} (${esc(v.statusName)})</option>`).join("");
    document.getElementById("acoCmpA").innerHTML = opts;
    document.getElementById("acoCmpB").innerHTML = opts;
    if (d.versions.length > 1) { document.getElementById("acoCmpA").selectedIndex = 1; document.getElementById("acoCmpB").selectedIndex = 0; }
    document.getElementById("acoCompareBtn").disabled = d.versions.length < 2;

    // Vendor contacts
    document.getElementById("acoContactsBody").innerHTML = d.contacts.map(m => {
      const [st, scss] = MAPPING_STATE[m.effectiveState] || [m.status, "aco-st-open"];
      const acts = [];
      if (!terminated && m.effectiveState !== "ENDED") {
        if (m.status === "PENDING_VALIDATION" && CAN_APPROVE && !m.actorIsCreator) acts.push(["VALIDATE", "Validate", true]);
        if (CAN_EDIT) acts.push(["EDIT", "Edit", false], ["END", "End", false]);
      }
      return `<tr>
        <td>${esc(m.roleName)}${m.roleMandatory ? ` <span class="aco-note">(mandatory)</span>` : ""}</td>
        <td>${esc(m.contactName)}<div class="aco-note">${esc(m.contactEmail || "")}${m.contactStatus !== "Active" ? " - " + esc(m.contactStatus) : ""}</div></td>
        <td>${m.isPrimary ? "Yes" : "No"}</td>
        <td>${esc(date(m.effectiveStart))} to ${esc(date(m.effectiveEnd) || "--")}</td>
        <td><span class="aco-chip ${scss}">${esc(st)}</span>${m.validatedByName ? `<div class="aco-note">validated by ${esc(m.validatedByName)}</div>` : ""}${m.endReason ? `<div class="aco-note">${esc(m.endReason)}</div>` : ""}</td>
        <td>${esc(CHANNEL[m.preferredChannel] || m.preferredChannel)}</td>
        <td>${m.notificationParticipation ? "Yes" : "No"}</td>
        <td>${m.versionNo ? "v" + esc(m.versionNo) + " only" : "All versions"}</td>
        <td><div class="aco-actions">${acts.map(([a, l, p]) => `<button class="pm-button${p ? " primary" : ""}" type="button" data-aco-cact="${a}" data-aco-mapping="${m.mappingId}">${l}</button>`).join("")}</div></td>
      </tr>`;
    }).join("") || empty(9, "No vendor contacts mapped.");

    // Documents (filters)
    const dv = document.getElementById("acoDocVersion"), keep = dv.value;
    dv.innerHTML = `<option value="">All versions</option>` + d.versions.map(v => `<option value="${v.versionId}">v${esc(v.versionNo)}</option>`).join("");
    dv.value = d.versions.some(v => String(v.versionId) === keep) ? keep : "";
    renderDocuments();

    document.getElementById("acoApprovalsBody").innerHTML = d.approvals.map(h => `<tr>
        <td>${esc(dateTime(h.transitionedAt))}</td><td>v${esc(h.versionNo)}</td><td>${esc(h.fromStatus || "--")}</td><td>${esc(h.toStatus)}</td>
        <td>${esc(h.actorName || "system")}</td><td>${esc(reasonLabel(h.reasonCode))}${h.reasonText ? `<div class="aco-note">${esc(h.reasonText)}</div>` : ""}</td>
      </tr>`).join("") || empty(6, "No history.");

    // 435: current coverage posture and coverage history
    document.getElementById("acoPosture").innerHTML = (d.coveragePosture || []).map(p => {
      const [l, css] = LINE_STATUS[p.lineStatus] || [p.lineStatus, ""];
      return `<span class="aco-chip ${css}">${esc(l)}: ${esc(p.lines)}</span>`;
    }).join("") || `<span class="aco-note">No asset coverage in the version in force.</span>`;
    document.getElementById("acoCoverageHistoryBody").innerHTML = (d.coverageHistory || []).map(h => `<tr>
        <td>v${esc(h.versionNo)}</td><td>${esc(h.statusName)}</td>
        <td>${h.effectiveStart ? esc(date(h.effectiveStart)) + " to " + esc(date(h.effectiveEnd) || "--") : "--"}</td>
        <td>${esc(h.coveredAssets)}</td><td>${esc(h.excludedAssets)}</td><td>${esc(h.suspendedAssets)}</td>
        <td>${esc(h.entitlements)}</td><td>${h.entitlementQuantity === null || h.entitlementQuantity === undefined ? "--" : esc(h.entitlementQuantity)}</td>
      </tr>`).join("") || empty(8, "No versions.");

    document.getElementById("acoContactHistoryBody").innerHTML = d.contactHistory.map(s => `<tr>
        <td>v${esc(s.versionNo)}</td><td>${esc(s.roleName)}</td><td>${esc(s.contactName)}<div class="aco-note">${esc(s.contactEmail || "")}</div></td>
        <td>${esc(s.vendorName)}</td><td>${s.isPrimary ? "Yes" : "No"}</td>
        <td>${esc(date(s.effectiveStart))} to ${esc(date(s.effectiveEnd) || "--")}</td><td>${esc(CHANNEL[s.preferredChannel] || s.preferredChannel)}</td>
      </tr>`).join("") || empty(7, "No approved version has vendor contacts yet.");
  }

  function renderDocuments() {
    if (!state.detail) return;
    const v = val("acoDocVersion"), t = val("acoDocType");
    const rows = state.detail.documents.filter(x => (!v || String(x.versionId) === v) && (!t || x.documentType === t));
    document.getElementById("acoDocsBody").innerHTML = rows.map(x => `<tr>
        <td>v${esc(x.versionNo)}</td><td>${esc(DOC_TYPE[x.documentType] || x.documentType)}</td><td>${esc(x.title)}</td>
        <td>${linkOrText(x.referenceText)}</td>
        <td>${x.status === "REMOVED" ? `<span class="aco-chip aco-st-ended">Removed</span><div class="aco-note">${esc(x.removedBy || "")} ${esc(dateTime(x.removedDt))}</div>` : `<span class="aco-chip aco-st-active">Active</span>`}</td>
        <td>${esc(x.addedBy || "")}<div class="aco-note">${esc(dateTime(x.addedDt))}</div></td>
      </tr>`).join("") || empty(6, "No documents.");
  }

  // ------------------------------------------------------------------ contract header
  function openEdit(c) {
    const lk = state.lookups;
    if (!lk) return;
    state.editing = c;
    document.getElementById("acoEditTitle").textContent = c ? "Edit contract" : "New contract";
    document.getElementById("acoEdNumber").value = c ? c.contractNumber : "";
    document.getElementById("acoEdName").value = c ? c.contractName : "";
    document.getElementById("acoEdDescription").value = c ? (c.description || "") : "";
    document.getElementById("acoEdType").innerHTML = `<option value="">Select</option>` +
      lk.contractTypes.map(o => `<option value="${esc(o.optionValue)}">${esc(o.optionLabel)}</option>`).join("");
    document.getElementById("acoEdType").value = c ? c.contractType : "";
    // New contracts: active vendors only (7.4.1); an existing contract keeps its vendor even when inactive.
    document.getElementById("acoEdVendor").innerHTML = `<option value="">Select</option>` + lk.vendors
      .filter(v => v.status === "Active" || (c && v.vendorId === c.vendorId))
      .map(v => `<option value="${v.vendorId}">${esc(v.vendorName)}${v.status !== "Active" ? " (" + esc(v.status) + ")" : ""}</option>`).join("");
    document.getElementById("acoEdVendor").value = c ? String(c.vendorId) : "";
    document.getElementById("acoEdParent").innerHTML = `<option value="">None</option>` + lk.contracts
      .filter(x => !c || x.contractId !== c.contractId)
      .map(x => `<option value="${x.contractId}">${esc(x.contractNumber)} - ${esc(x.contractName)}</option>`).join("");
    document.getElementById("acoEdParent").value = c && c.parentContractId ? String(c.parentContractId) : "";
    const locked = !!(c && c.identityLocked);
    document.getElementById("acoEdType").disabled = locked;
    document.getElementById("acoEdVendor").disabled = locked;
    document.getElementById("acoEdLockNote").hidden = !locked;
    document.getElementById("acoEdNewNote").hidden = !!c;
    hide("acoEditMessage");
    document.getElementById("acoEditModal").hidden = false;
  }

  async function submitEdit() {
    const c = state.editing;
    const res = await api("POST", "", {
      organizationId: state.organizationId, contractId: c ? c.contractId : null,
      contractNumber: val("acoEdNumber"), contractName: val("acoEdName"), contractType: val("acoEdType") || null,
      vendorId: Number(val("acoEdVendor")) || null, parentContractId: Number(val("acoEdParent")) || null,
      description: val("acoEdDescription") || null, expectedRecordVersion: c ? c.recordVersion : null
    });
    if (!res.ok) { show("acoEditMessage", res.error); return; }
    document.getElementById("acoEditModal").hidden = true;
    await loadLookups();
    await refreshList();
    if (c) { await reloadContract(); showDetailMessage("Contract saved.", "success"); }
    else {
      await openContract(res.data.id, "SUMMARY");
      if (state.detail?.contract?.openVersionId) await openVersion(state.detail.contract.openVersionId);
    }
  }

  // ------------------------------------------------------------------ versions
  function openNewVersion() {
    const c = state.detail?.contract;
    if (!c) return;
    const hasApproved = state.detail.versions.some(v => v.approvalDt);
    document.getElementById("acoNvType").value = hasApproved ? "RENEWAL" : "INITIAL";
    document.getElementById("acoNvSummary").value = "";
    hide("acoNewVersionMessage");
    document.getElementById("acoNewVersionModal").hidden = false;
  }

  async function submitNewVersion() {
    const c = state.detail?.contract;
    const res = await api("POST", `/${c.contractId}/versions`, {
      organizationId: state.organizationId, versionType: val("acoNvType"), changeSummary: val("acoNvSummary") || null
    });
    if (!res.ok) { show("acoNewVersionMessage", res.error); return; }
    document.getElementById("acoNewVersionModal").hidden = true;
    await reloadContract();
    await refreshList();
    await openVersion(res.data.id);
  }

  async function openVersion(id) {
    const res = await api("GET", `/versions/${id}?organizationId=${state.organizationId}`);
    if (!res.ok) { showDetailMessage(res.error, "error"); return; }
    state.version = res.data.data;
    renderVersion();
    document.getElementById("acoVersionModal").hidden = false;
  }

  function renderVersion() {
    const p = state.version, v = p.version, lk = state.lookups;
    const draft = v.statusCode === "DRAFT", editable = draft && CAN_EDIT, termination = v.versionType === "TERMINATION";
    document.getElementById("acoVersionTitle").textContent = `${v.contractNumber} - v${v.versionNo} ${VERSION_TYPE[v.versionType] || v.versionType} (${v.statusName})`;
    document.getElementById("acoVersionInfo").innerHTML = info([
      ["Status", `<span class="aco-chip ${VERSION_STATUS[v.statusCode] || ""}">${esc(v.statusName)}</span>`, true],
      ["Vendor", v.vendorName],
      ["Created", `${v.createdByName || v.createdBy || ""} ${dateTime(v.createdDt)}`],
      ["Submitted", v.submittedDt ? `${v.submittedByName || ""} ${dateTime(v.submittedDt)}` : "--"],
      ["Reviewed", v.reviewedDt ? `${v.reviewedByName || ""} ${dateTime(v.reviewedDt)}` : "--"],
      ["Approved", v.approvalDt ? `${v.approvedByName || v.approvedBy || ""} ${dateTime(v.approvalDt)}` : "--"],
      ["Replaces", v.supersedesVersionNo ? `v${v.supersedesVersionNo}` : "--"],
      ["Replaced by", v.supersededByVersionNo ? `v${v.supersededByVersionNo}` : "--"],
      ["Last decision note", v.decisionNote || "--"]
    ]);
    const people = `<option value="">Select</option>` + (lk ? lk.employees.map(e => `<option value="${e.employeeId}">${esc(e.employeeName)}</option>`).join("") : "");
    document.getElementById("acoVfOwner").innerHTML = people;
    document.getElementById("acoVfProcurement").innerHTML = people;
    VERSION_FIELDS.forEach(([id, key, kind]) => {
      const el = document.getElementById(id), x = v[key];
      if (kind === "id" && x && !Array.from(el.options).some(o => o.value === String(x))) {
        const o = document.createElement("option"); o.value = String(x);
        o.textContent = (key === "contractOwnerId" ? v.contractOwnerName : v.procurementOwnerName) || String(x);
        el.appendChild(o);
      }
      el.value = x === null || x === undefined ? "" : kind === "date" ? date(x) : String(x);
      el.disabled = !editable;
    });
    // A termination version takes effect on its termination date and has no end date.
    document.getElementById("acoVfStart").disabled = !editable || termination;
    document.getElementById("acoVfEnd").disabled = !editable || termination;
    document.getElementById("acoVfTerminationLabel").textContent = termination ? "Termination date *" : "Termination date";
    document.getElementById("acoVfSummaryLabel").textContent = v.versionType === "INITIAL" ? "Change summary / reason" : "Change summary / reason *";

    const warn = p.warnings || [];
    document.getElementById("acoVfWarnings").hidden = warn.length === 0;
    document.getElementById("acoVfWarningList").innerHTML = warn.map(w => `<li>${esc(w.warning)}</li>`).join("");

    const acts = [];
    const notSubmitter = !v.actorIsSubmitter;
    if (draft && CAN_EDIT) acts.push(["SAVE", "Save draft", false], ["SUBMIT", "Submit for review", true], ["WITHDRAW", "Withdraw", false]);
    if (v.statusCode === "IN_REVIEW") {
      if (CAN_EDIT && notSubmitter) acts.push(["REVIEW", "Review complete", true]);
      if (CAN_EDIT) acts.push(["RETURN", "Return to draft", false]);
      if (CAN_APPROVE && notSubmitter) acts.push(["REJECT", "Reject", false]);
    }
    if (v.statusCode === "PENDING_APPROVAL") {
      if (CAN_APPROVE && notSubmitter) acts.push(["APPROVE", "Approve", true]);
      if (CAN_EDIT) acts.push(["RETURN", "Return to draft", false]);
      if (CAN_APPROVE && notSubmitter) acts.push(["REJECT", "Reject", false]);
    }
    document.getElementById("acoVersionActions").innerHTML = acts.map(([a, l, pr]) =>
      `<button class="pm-button${pr ? " primary" : ""}" type="button" data-aco-vact="${a}">${l}</button>`).join("")
      || `<span class="aco-note">${draft ? "Read-only." : "This version is " + esc(v.statusName.toLowerCase()) + " and cannot be changed."}</span>`;
    hide("acoVersionMessage");

    const docsOpen = ["DRAFT", "IN_REVIEW", "PENDING_APPROVAL"].includes(v.statusCode) && CAN_EDIT;
    document.getElementById("acoDocForm").hidden = !docsOpen;
    document.getElementById("acoVersionDocs").innerHTML = p.documents.map(x => `<tr>
        <td>${esc(DOC_TYPE[x.documentType] || x.documentType)}</td><td>${esc(x.title)}</td><td>${linkOrText(x.referenceText)}</td>
        <td>${x.status === "REMOVED" ? `<span class="aco-chip aco-st-ended">Removed</span>` : `<span class="aco-chip aco-st-active">Active</span>`}</td>
        <td>${esc(x.addedBy || "")}<div class="aco-note">${esc(dateTime(x.addedDt))}</div></td>
        <td>${draft && CAN_EDIT && x.status === "ACTIVE" ? `<button class="pm-button" type="button" data-aco-doc-remove="${x.documentId}">Remove</button>` : ""}</td>
      </tr>`).join("") || empty(6, "No documents.");

    renderVersionCoverage(draft && CAN_EDIT);

    document.getElementById("acoVersionContactSource").textContent = v.approvalDt ? "(frozen at approval)" : "(current mappings for the version dates)";
    document.getElementById("acoVersionContacts").innerHTML = p.contacts.map(k => `<tr>
        <td>${esc(k.roleName)}</td><td>${esc(k.contactName)}<div class="aco-note">${esc(k.contactEmail || "")}</div></td>
        <td>${k.isPrimary ? "Yes" : "No"}</td><td>${esc(date(k.effectiveStart))} to ${esc(date(k.effectiveEnd) || "--")}</td>
        <td>${esc(CHANNEL[k.preferredChannel] || k.preferredChannel)}</td>
        <td>${k.mappingStatus === "PENDING_VALIDATION" ? `<span class="aco-chip aco-st-wait">Pending validation</span>` : `<span class="aco-chip aco-st-active">Active</span>`}</td>
      </tr>`).join("") || empty(6, "No vendor contacts for this version.");

    document.getElementById("acoVersionHistory").innerHTML = p.history.map(h => `<tr>
        <td>${esc(dateTime(h.transitionedAt))}</td><td>${esc(h.fromStatus || "--")}</td><td>${esc(h.toStatus)}</td>
        <td>${esc(h.actorName || "system")}</td><td>${esc(reasonLabel(h.reasonCode))}${h.reasonText ? `<div class="aco-note">${esc(h.reasonText)}</div>` : ""}</td>
      </tr>`).join("") || empty(5, "No history.");
  }

  // ------------------------------------------------------------------ renewals (436, BRD 7.3)
  async function refreshDue() {
    const body = document.getElementById("acoDueBody");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); return; }
    body.innerHTML = empty(8, "Loading...");
    const res = await api("GET", `/renewals/due?organizationId=${state.organizationId}&withinDays=${val("acoDueWithin") || 90}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); return; }
    body.innerHTML = (res.data.data || []).map(d => {
      const [l, css] = CONTRACT_STATUS[d.contractStatus] || [d.contractStatus, ""];
      return `<tr><td>${esc(d.contractNumber)}<div class="aco-note">${esc(d.contractName)}</div></td><td>${esc(d.vendorName)}</td>
        <td><span class="aco-chip ${css}">${esc(l)}</span></td><td>v${esc(d.versionNo)}</td><td>${esc(date(d.effectiveEnd) || "--")}</td>
        <td>${esc(date(d.dueDate))}<div class="aco-note">${d.daysToDue < 0 ? esc(-d.daysToDue) + " days overdue" : "in " + esc(d.daysToDue) + " days"}</div></td>
        <td>${esc(d.contractOwnerName || "--")}</td>
        <td>${CAN_EDIT ? `<button class="pm-button" type="button" data-aco-due-start="${d.contractId}" data-aco-due-number="${esc(d.contractNumber)}">Start renewal</button>` : ""}</td></tr>`;
    }).join("") || empty(8, "No contract reaches its renewal date in this period without a renewal.");
  }

  async function refreshRenewals() {
    const body = document.getElementById("acoRenBody");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); state.renPager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.renPager ? state.renPager.page() : 1, pageSize: state.renPager ? state.renPager.size() : 25 });
    if (val("acoRenStatus")) qs.set("status", val("acoRenStatus"));
    if (val("acoRenSearch")) qs.set("search", val("acoRenSearch"));
    const res = await api("GET", `/renewals?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.renPager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.renPager?.setTotal(res.data.data.totalRows, rows.length);
    body.innerHTML = rows.map(r => `<tr data-aco-renewal="${r.renewalId}">
        <td>${esc(r.occurrenceKey)}</td><td>${esc(r.contractNumber)}<div class="aco-note">${esc(r.vendorName)}</div></td>
        <td>${esc(REN_TYPE[r.renewalType] || r.renewalType)}</td>
        <td><span class="aco-chip ${REN_STATUS[r.statusCode] || ""}">${esc(r.statusName)}</span></td>
        <td>${esc(date(r.dueDate) || "--")}</td><td>${esc(date(r.oldExpiry) || "--")} / ${esc(date(r.newExpiry) || "--")}</td>
        <td>${money(r.renewalValue, r.currencyCode)}</td>
        <td>${esc(REN_OUTCOME[r.outcome] || "--")}${r.openUnresolved ? `<div class="aco-note">${esc(r.openUnresolved)} unresolved</div>` : ""}</td></tr>`).join("")
      || empty(8, "No renewal occurrences.");
  }

  async function loadRenewalHistory() {
    const body = document.getElementById("acoRenewalHistoryBody"), c = state.detail?.contract;
    if (!c) return;
    const res = await api("GET", `/renewals?organizationId=${state.organizationId}&contractId=${c.contractId}&pageSize=200`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); return; }
    body.innerHTML = (res.data.data.rows || []).map(r => `<tr data-aco-renewal="${r.renewalId}">
        <td>${esc(r.occurrenceKey)}<div class="aco-note">from v${esc(r.priorVersionNo)}</div></td><td>${esc(REN_TYPE[r.renewalType] || r.renewalType)}</td>
        <td><span class="aco-chip ${REN_STATUS[r.statusCode] || ""}">${esc(r.statusName)}</span></td>
        <td>${esc(date(r.oldExpiry) || "--")} / ${esc(date(r.newExpiry) || "--")}</td><td>${money(r.renewalValue, r.currencyCode)}</td>
        <td>${esc([r.quotationReference, r.poReference, r.invoiceReference].filter(Boolean).join(" / ") || "--")}</td>
        <td>${r.resultingVersionNo ? esc((r.resultingContractNumber && r.resultingContractNumber !== c.contractNumber ? r.resultingContractNumber + " " : "") + "v" + r.resultingVersionNo) : "--"}</td>
        <td>${esc(REN_OUTCOME[r.outcome] || "--")}</td></tr>`).join("") || empty(8, "No renewals yet.");
  }

  function openStartRenewal(contractId, number) {
    state.renewalContract = contractId;
    document.getElementById("acoSrTitle").textContent = `Start renewal - ${number || ""}`;
    document.getElementById("acoSrType").value = "RENEWAL";
    document.getElementById("acoSrNotes").value = "";
    hide("acoSrMessage");
    document.getElementById("acoStartRenewalModal").hidden = false;
  }

  async function submitStartRenewal() {
    const res = await api("POST", `/${state.renewalContract}/renewals`, {
      organizationId: state.organizationId, renewalType: val("acoSrType"), notes: val("acoSrNotes") || null
    });
    if (!res.ok) { show("acoSrMessage", res.error); return; }
    document.getElementById("acoStartRenewalModal").hidden = true;
    if (state.mainTab === "RENEWALS") { await refreshDue(); await refreshRenewals(); }
    if (state.detail) await loadRenewalHistory();
    await openRenewal(res.data.id);
  }

  async function openRenewal(id) {
    const res = await api("GET", `/renewals/${id}?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.renewal = res.data.data;
    renderRenewal();
    document.getElementById("acoRenewalModal").hidden = false;
  }

  function syncRenewalForm() {
    const t = val("acoRfType"), open = state.renewal?.renewal?.statusCode === "OPEN" && CAN_EDIT;
    ["acoRfExpiry", "acoRfValue", "acoRfCurrency"].forEach(id => { document.getElementById(id).disabled = !open || t === "NON_RENEWAL"; });
  }

  function renderRenewal() {
    const d = state.renewal, r = d.renewal, open = r.statusCode === "OPEN" && CAN_EDIT;
    document.getElementById("acoRenTitle").textContent = `${r.occurrenceKey} - ${r.contractNumber}`;
    document.getElementById("acoRenInfo").innerHTML = info([
      ["Status", `<span class="aco-chip ${REN_STATUS[r.statusCode] || ""}">${esc(r.statusName)}</span>`, true],
      ["Contract", `${r.contractNumber} - ${r.contractName}`], ["Vendor", r.vendorName],
      ["Prior version", `v${r.priorVersionNo} (${r.priorVersionStatus}) ${date(r.priorEffectiveStart)} to ${date(r.priorEffectiveEnd) || "--"}`],
      ["Renewal due", date(r.dueDate) || "--"], ["Old expiry", date(r.oldExpiry) || "--"], ["New expiry", date(r.newExpiry) || "--"],
      ["Started", `${r.startedBy || ""} ${dateTime(r.startedDt)}`],
      ["Submitted", r.submittedDt ? `${r.submittedByName || ""} ${dateTime(r.submittedDt)}` : "--"],
      ["Approved", r.approvalDt ? `${r.approvedByName || r.approvedBy || ""} ${dateTime(r.approvalDt)}` : "--"],
      ["Approval comments", r.approvalComments || "--"],
      ["Outcome", REN_OUTCOME[r.outcome] || "--"],
      ["Completed", r.completedDt ? `${r.completedByName || r.completedBy || ""} ${dateTime(r.completedDt)}` : "--"],
      ["Cancel reason", r.cancelReason || "--"]
    ]);
    const set = (id, v) => { const el = document.getElementById(id); el.value = v ?? ""; el.disabled = !open; };
    set("acoRfType", r.renewalType); set("acoRfExpiry", date(r.newExpiry)); set("acoRfValue", r.renewalValue); set("acoRfCurrency", r.currencyCode);
    set("acoRfQuote", r.quotationReference); set("acoRfPo", r.poReference); set("acoRfInvoice", r.invoiceReference);
    set("acoRfDecision", r.decisionComments); set("acoRfNotes", r.notes);
    syncRenewalForm();

    const nonRenewal = r.renewalType === "NON_RENEWAL";
    document.getElementById("acoRenResultWrap").hidden = nonRenewal;
    document.getElementById("acoRenResult").innerHTML = r.resultingVersionId
      ? `${esc(r.resultingContractNumber)} v${esc(r.resultingVersionNo)} - ${esc(r.resultingVersionStatus)} (${esc(date(r.resultingEffectiveStart) || "--")} to ${esc(date(r.resultingEffectiveEnd) || "--")})`
        + (r.resultingApprovalDt ? "" : ". Approve the version (version details) before completing the renewal.")
      : (r.statusCode === "APPROVED" ? (["RENEWAL", "EXTENSION"].includes(r.renewalType)
          ? "Create the renewal version below, or link an existing later version." : "Link the version of the new / replacement contract.")
          : "Created or linked after the decision is approved.");
    const canLink = r.statusCode === "APPROVED" && !r.resultingVersionId && !nonRenewal && CAN_EDIT;
    document.getElementById("acoRenLinkWrap").hidden = !canLink || !(d.linkable || []).length;
    document.getElementById("acoRfLink").innerHTML = (d.linkable || []).map(v =>
      `<option value="${v.versionId}">${esc(v.contractNumber)} v${esc(v.versionNo)} ${esc(VERSION_TYPE[v.versionType] || v.versionType)} (${esc(v.statusName)})</option>`).join("");

    const acts = [];
    if (open) acts.push(["SAVE", "Save", false], ["SUBMIT", "Submit decision", true]);
    if (r.statusCode === "PENDING_APPROVAL" && CAN_APPROVE) {
      if (!r.actorIsSubmitter) acts.push(["APPROVE", "Approve decision", true]);
      acts.push(["RETURN", "Return", false]);
    }
    if (r.statusCode === "APPROVED" && CAN_EDIT) {
      if (!r.resultingVersionId && ["RENEWAL", "EXTENSION"].includes(r.renewalType)) acts.push(["CREATE_VERSION", "Create renewal version", true]);
      if (r.resultingVersionId) acts.push(["OPEN_VERSION", "Open resulting version", false]);
      if (nonRenewal || r.resultingApprovalDt) acts.push(["COMPLETE", "Complete renewal", true]);
      if (!r.resultingVersionId) acts.push(["REOPEN", "Reopen decision", false]);
    }
    if (["OPEN", "PENDING_APPROVAL", "APPROVED"].includes(r.statusCode) && CAN_EDIT) acts.push(["CANCEL", "Cancel renewal", false]);
    document.getElementById("acoRenActions").innerHTML = acts.map(([a, l, pr]) =>
      `<button class="pm-button${pr ? " primary" : ""}" type="button" data-aco-ract="${a}">${l}</button>`).join("")
      || `<span class="aco-note">No step available.</span>`;
    hide("acoRenMessage");

    const frozen = (d.reconciliation || []).some(x => x.isFrozen);
    document.getElementById("acoRenReconNote").textContent = frozen ? "(frozen at completion)"
      : (nonRenewal ? "(preview: every prior line is removed)" : r.resultingVersionId ? "(preview against the resulting version)" : "");
    document.getElementById("acoRenRecon").innerHTML = (d.reconciliation || []).map(x => {
      const [l, css] = RECON[x.reconciliationResult] || [x.reconciliationResult, ""];
      const item = x.itemKind === "ASSET" ? `${esc(x.assetName || "#" + x.assetId)}<div class="aco-note">asset</div>`
                                          : `${esc(x.productSku || "")}<div class="aco-note">entitlement</div>`;
      const prior = x.itemKind === "ASSET" ? (COV_STATE[x.priorState] || "--") : (x.priorQuantity ?? (x.reconciliationResult === "ADDED" ? "--" : "listed"));
      const result = x.itemKind === "ASSET" ? (COV_STATE[x.resultState] || "--") : (x.resultQuantity ?? (x.reconciliationResult === "REMOVED" ? "--" : "listed"));
      return `<tr><td>${item}</td><td>${esc(covTypeLabel(x.coverageType))}</td><td>${esc(prior)}</td><td>${esc(result)}</td>
        <td><span class="aco-chip ${css}">${esc(l)}</span></td>
        <td>${x.resolutionCode ? esc(RESOLUTION[x.resolutionCode] || x.resolutionCode) + `<div class="aco-note">${esc(x.resolutionNote || "")} ${esc(x.resolvedBy || "")}</div>` : "--"}</td>
        <td>${x.itemId && x.reconciliationResult === "UNRESOLVED" && !x.resolutionCode && CAN_EDIT ? `<button class="pm-button" type="button" data-aco-resolve="${x.itemId}">Resolve</button>` : ""}</td></tr>`;
    }).join("") || empty(7, nonRenewal || r.resultingVersionId ? "Nothing to reconcile." : "The reconciliation appears once a resulting version is linked.");

    document.getElementById("acoRenHistory").innerHTML = (d.history || []).map(h => `<tr>
        <td>${esc(dateTime(h.transitionedAt))}</td><td>${esc(h.fromStatus || "--")}</td><td>${esc(h.toStatus)}</td>
        <td>${esc(h.actorName || "system")}</td><td>${esc(reasonLabel(h.reasonCode))}${h.reasonText ? `<div class="aco-note">${esc(h.reasonText)}</div>` : ""}</td>
      </tr>`).join("") || empty(5, "No history.");
  }

  async function saveRenewal() {
    const r = state.renewal.renewal;
    const res = await api("POST", `/renewals/${r.renewalId}`, {
      organizationId: state.organizationId, renewalType: val("acoRfType"), newExpiry: val("acoRfExpiry") || null,
      renewalValue: val("acoRfValue") ? Number(val("acoRfValue")) : null, currencyCode: val("acoRfCurrency") || null,
      quotationReference: val("acoRfQuote") || null, poReference: val("acoRfPo") || null, invoiceReference: val("acoRfInvoice") || null,
      decisionComments: val("acoRfDecision") || null, notes: val("acoRfNotes") || null, expectedRecordVersion: r.recordVersion
    });
    if (!res.ok) { show("acoRenMessage", res.error); return false; }
    return true;
  }

  async function renewalAction(action) {
    const r = state.renewal.renewal;
    if (action === "OPEN_VERSION") { await openVersion(r.resultingVersionId); return; }
    if (action === "SAVE" || action === "SUBMIT") {
      if (!await saveRenewal()) return;
      if (action === "SAVE") { await openRenewal(r.renewalId); show("acoRenMessage", "Renewal saved.", "success"); await refreshAfterRenewal(); return; }
      const fresh = await api("GET", `/renewals/${r.renewalId}?organizationId=${state.organizationId}`);
      if (fresh.ok) state.renewal = fresh.data.data;
    }
    let note = null, versionId = null;
    if (["RETURN", "REOPEN", "CANCEL"].includes(action)) {
      const q = { RETURN: ["Return decision", "Why is the decision returned?"], REOPEN: ["Reopen decision", "Why is the approved decision reopened?"],
                  CANCEL: ["Cancel renewal", "Why is the renewal cancelled? It stays in the renewal history."] }[action];
      note = await window.gracUi.promptRequired(q[1], { title: q[0], inputLabel: "Reason" });
      if (!note) return;
    } else if (action === "APPROVE") {
      note = await window.gracUi.prompt("Approval comments (optional)", { title: "Approve renewal decision", inputLabel: "Comments" });
      if (note === null || note === undefined) return;
      note = String(note).trim() || null;
    } else if (action === "LINK_VERSION") {
      versionId = Number(val("acoRfLink")) || null;
      if (!versionId) return;
    } else if (action === "COMPLETE") {
      if (!await window.gracUi.confirm("Complete the renewal? The coverage reconciliation is frozen and the outcome recorded.")) return;
    } else if (action === "CREATE_VERSION") {
      if (!await window.gracUi.confirm("Create the renewal version? It starts as a Draft copy of the prior version with the new expiry, value and references, and is approved through the version workflow.")) return;
    }
    const res = await api("POST", `/renewals/${state.renewal.renewal.renewalId}/action`, {
      organizationId: state.organizationId, action, note, versionId, expectedRecordVersion: state.renewal.renewal.recordVersion
    });
    if (!res.ok) { show("acoRenMessage", res.error); return; }
    await openRenewal(r.renewalId);
    show("acoRenMessage", { PENDING_APPROVAL: "Decision submitted for approval.", APPROVED: "Decision approved.", OPEN: "Back to Open.",
      VERSION_CREATED: "Renewal version created as a Draft; complete and approve it through the version details.", VERSION_LINKED: "Version linked.",
      CANCELLED: "Renewal cancelled.", RENEWED: "Renewal completed: Renewed.", PARTIALLY_RENEWED: "Renewal completed: Partially renewed.",
      REPLACED: "Renewal completed: Replaced.", NOT_RENEWED: "Renewal completed: Not renewed." }[res.data.result] || "Done.", "success");
    await refreshAfterRenewal();
  }

  async function refreshAfterRenewal() {
    if (state.mainTab === "RENEWALS") { await refreshDue(); await refreshRenewals(); }
    if (state.detail && !document.getElementById("acoModal").hidden) await reloadContract();
  }

  function openResolve(itemId) {
    state.resolveItem = itemId;
    document.getElementById("acoRsCode").value = "MAPPED";
    document.getElementById("acoRsNote").value = "";
    hide("acoRsMessage");
    document.getElementById("acoResolveModal").hidden = false;
  }

  async function submitResolve() {
    const res = await api("POST", `/renewal-items/${state.resolveItem}/resolve`, {
      organizationId: state.organizationId, resolutionCode: val("acoRsCode"), note: val("acoRsNote") || null
    });
    if (!res.ok) { show("acoRsMessage", res.error); return; }
    document.getElementById("acoResolveModal").hidden = true;
    await openRenewal(state.renewal.renewal.renewalId);
    show("acoRenMessage", "Item resolved.", "success");
  }

  // ------------------------------------------------------------------ entitlements and coverage (435)
  function covTypeLabel(v) { return ((state.lookups?.contractTypes || []).find(o => o.optionValue === v) || {}).optionLabel || v || ""; }
  function covTypeOptions() { return (state.lookups?.contractTypes || []).map(o => `<option value="${esc(o.optionValue)}">${esc(o.optionLabel)}</option>`).join(""); }

  function renderVersionCoverage(editable) {
    const p = state.version, ents = p.entitlements || [], cov = p.coverage || [];
    document.getElementById("acoEntForm").hidden = !editable;
    document.getElementById("acoCovForm").hidden = !editable;
    if (editable) {
      document.getElementById("acoEfType").innerHTML = covTypeOptions();
      document.getElementById("acoCfCovType").innerHTML = covTypeOptions();
      document.getElementById("acoCfEnt").innerHTML = `<option value="">No entitlement</option>` +
        ents.map(e => `<option value="${e.entitlementId}">${esc(e.productSku)} (${esc(covTypeLabel(e.coverageType))})</option>`).join("");
      fillEntForm(null);
      document.getElementById("acoCfPickBody").innerHTML = empty(5, "Search assets to cover.");
      ensureConfig(false);
    }
    document.getElementById("acoVersionEnts").innerHTML = ents.map(e => `<tr>
        <td>${esc(e.productSku)}${e.description ? `<div class="aco-note">${esc(e.description)}</div>` : ""}</td>
        <td>${esc(covTypeLabel(e.coverageType))}</td>
        <td>${e.quantity === null || e.quantity === undefined ? "--" : esc(e.quantity) + (e.unit ? " " + esc(e.unit) : "")}</td>
        <td>${esc(e.allocatedAssets)}${e.quantity !== null && e.quantity !== undefined && e.allocatedAssets > e.quantity ? ` <span class="aco-chip aco-st-bad">Over</span>` : ""}</td>
        <td>${esc(e.serviceLevel || "--")}${e.supportHours ? `<div class="aco-note">${esc(e.supportHours)}</div>` : ""}</td>
        <td>${e.startDate || e.endDate ? esc(date(e.startDate) || "version") + " to " + esc(date(e.endDate) || "version") : "Version dates"}</td>
        <td>${esc(e.exclusions || "--")}</td>
        <td>${editable ? `<div class="aco-actions"><button class="pm-button" type="button" data-aco-ent="EDIT" data-aco-ent-id="${e.entitlementId}">Edit</button><button class="pm-button" type="button" data-aco-ent="REMOVE" data-aco-ent-id="${e.entitlementId}">Remove</button></div>` : ""}</td>
      </tr>`).join("") || empty(8, "No entitlements.");
    document.getElementById("acoVersionCov").innerHTML = cov.map(c => {
      const [l, css] = LINE_STATUS[c.lineStatus] || ["--", ""];
      return `<tr>
        <td>${esc(c.assetName)}<div class="aco-note">#${esc(c.assetId)} ${esc(c.assetTypeName || "")}</div></td>
        <td>${esc(covTypeLabel(c.coverageType))}</td>
        <td>${esc(COV_STATE[c.coverageState] || c.coverageState)}${c.exclusionReason ? `<div class="aco-note">${esc(c.exclusionReason)}</div>` : ""}</td>
        <td>${esc(c.productSku || "--")}</td>
        <td>${c.coverageStart || c.coverageEnd ? esc(date(c.coverageStart) || "default") + " to " + esc(date(c.coverageEnd) || "default") : "Default dates"}</td>
        <td>${esc(c.serviceLevel || "--")}${c.supportHours ? `<div class="aco-note">${esc(c.supportHours)}</div>` : ""}</td>
        <td>${esc(c.vendorSupportReference || "--")}</td>
        <td>${c.lineStatus ? `<span class="aco-chip ${css}">${esc(l)}</span>` : "--"}</td>
        <td>${editable ? `<div class="aco-actions"><button class="pm-button" type="button" data-aco-cov="EDIT" data-aco-cov-id="${c.coverageId}">Edit</button><button class="pm-button" type="button" data-aco-cov="REMOVE" data-aco-cov-id="${c.coverageId}">Remove</button></div>` : ""}</td>
      </tr>`;
    }).join("") || empty(9, "No assets covered by this version.");
  }

  function fillEntForm(e) {
    state.entEdit = e;
    const set = (id, v) => { document.getElementById(id).value = v ?? ""; };
    set("acoEfSku", e?.productSku); set("acoEfType", e?.coverageType || (state.lookups?.contractTypes?.[0]?.optionValue ?? ""));
    set("acoEfQty", e?.quantity); set("acoEfUnit", e?.unit); set("acoEfLevel", e?.serviceLevel); set("acoEfHours", e?.supportHours);
    set("acoEfStart", e ? date(e.startDate) : ""); set("acoEfEnd", e ? date(e.endDate) : ""); set("acoEfDesc", e?.description); set("acoEfExcl", e?.exclusions);
    document.getElementById("acoEfSaveLabel").textContent = e ? "Save entitlement" : "Add entitlement";
    document.getElementById("acoEfCancel").hidden = !e;
  }

  async function saveEntitlement() {
    const v = state.version.version, e = state.entEdit;
    const res = await api("POST", `/versions/${v.versionId}/entitlements`, {
      organizationId: state.organizationId, entitlementId: e ? e.entitlementId : null, productSku: val("acoEfSku"),
      coverageType: val("acoEfType") || null, quantity: val("acoEfQty") ? Number(val("acoEfQty")) : null, unit: val("acoEfUnit") || null,
      serviceLevel: val("acoEfLevel") || null, supportHours: val("acoEfHours") || null, startDate: val("acoEfStart") || null,
      endDate: val("acoEfEnd") || null, description: val("acoEfDesc") || null, exclusions: val("acoEfExcl") || null
    });
    if (!res.ok) { show("acoVersionMessage", res.error); return; }
    await openVersion(v.versionId);
    show("acoVersionMessage", e ? "Entitlement saved." : "Entitlement added.", "success");
  }

  async function entitlementAction(id, action) {
    const e = (state.version.entitlements || []).find(x => x.entitlementId === id);
    if (!e) return;
    if (action === "EDIT") { fillEntForm(e); return; }
    if (!await window.gracUi.confirm(`Remove entitlement ${e.productSku}? Coverage lines linked to it stay, without the entitlement.`)) return;
    const res = await api("POST", `/entitlements/${id}/remove`, { organizationId: state.organizationId });
    if (!res.ok) { show("acoVersionMessage", res.error); return; }
    await openVersion(state.version.version.versionId);
  }

  async function findAssets() {
    const v = state.version.version, body = document.getElementById("acoCfPickBody");
    const qs = new URLSearchParams({ organizationId: state.organizationId, versionId: v.versionId });
    if (val("acoCfAssetSearch")) qs.set("search", val("acoCfAssetSearch"));
    if (val("acoCfAssetType")) qs.set("assetTypeId", val("acoCfAssetType"));
    body.innerHTML = empty(5, "Loading...");
    const res = await api("GET", `/assets?${qs}`);
    if (!res.ok) { body.innerHTML = empty(5, res.error); return; }
    state.picks = res.data.data || [];
    document.getElementById("acoCfPickAll").checked = false;
    body.innerHTML = state.picks.map(a => `<tr>
        <td><input type="checkbox" data-aco-pick="${a.assetId}" /></td>
        <td>${esc(a.assetName)}<div class="aco-note">#${esc(a.assetId)}${a.inVersion ? " - already in this version" : ""}</div></td>
        <td>${esc(a.assetTypeName || "--")}</td><td>${esc(a.statusName || "--")}</td>
        <td><button class="pm-button" type="button" data-aco-pick-one="${a.assetId}">Cover</button></td></tr>`).join("") || empty(5, "No matching assets (the first 200 are shown).");
  }

  async function coverAssets(ids) {
    const v = state.version.version;
    const list = ids || Array.from(document.querySelectorAll("#acoCfPickBody input[data-aco-pick]:checked")).map(c => Number(c.dataset.acoPick));
    if (!list.length) { show("acoVersionMessage", "Select at least one asset."); return; }
    const res = await api("POST", `/versions/${v.versionId}/coverage/bulk`, {
      organizationId: state.organizationId, assetIds: list, coverageType: val("acoCfCovType") || null, entitlementId: Number(val("acoCfEnt")) || null
    });
    if (!res.ok) { show("acoVersionMessage", res.error); return; }
    const n = Number(String(res.data.result || "").replace("ADDED:", "")) || 0;
    await openVersion(v.versionId);
    show("acoVersionMessage", `${n} asset(s) covered${n < list.length ? `; ${list.length - n} already had this coverage type or are not available` : ""}.`, "success");
  }

  function coverageAction(id, action) {
    const c = (state.version.coverage || []).find(x => x.coverageId === id);
    if (!c) return;
    if (action === "REMOVE") { removeLine(c); return; }
    state.lineEdit = c;
    document.getElementById("acoLineTitle").textContent = `Coverage - ${c.assetName}`;
    document.getElementById("acoLfType").innerHTML = covTypeOptions();
    document.getElementById("acoLfEnt").innerHTML = `<option value="">No entitlement</option>` +
      (state.version.entitlements || []).map(e => `<option value="${e.entitlementId}">${esc(e.productSku)}</option>`).join("");
    const set = (id2, v) => { document.getElementById(id2).value = v ?? ""; };
    set("acoLfType", c.coverageType); set("acoLfState", c.coverageState); set("acoLfEnt", c.entitlementId ? String(c.entitlementId) : "");
    set("acoLfLevel", c.serviceLevel); set("acoLfStart", date(c.coverageStart)); set("acoLfEnd", date(c.coverageEnd));
    set("acoLfHours", c.supportHours); set("acoLfRef", c.vendorSupportReference); set("acoLfReason", c.exclusionReason);
    document.getElementById("acoLfReasonWrap").hidden = c.coverageState !== "EXCLUDED";
    hide("acoLineMessage");
    document.getElementById("acoLineModal").hidden = false;
  }

  async function saveLine() {
    const c = state.lineEdit, v = state.version.version;
    const res = await api("POST", `/versions/${v.versionId}/coverage`, {
      organizationId: state.organizationId, coverageId: c.coverageId, assetId: c.assetId, coverageType: val("acoLfType") || null,
      coverageState: val("acoLfState"), entitlementId: Number(val("acoLfEnt")) || null, coverageStart: val("acoLfStart") || null,
      coverageEnd: val("acoLfEnd") || null, serviceLevel: val("acoLfLevel") || null, supportHours: val("acoLfHours") || null,
      vendorSupportReference: val("acoLfRef") || null, exclusionReason: val("acoLfReason") || null
    });
    if (!res.ok) { show("acoLineMessage", res.error); return; }
    document.getElementById("acoLineModal").hidden = true;
    await openVersion(v.versionId);
    show("acoVersionMessage", "Coverage saved.", "success");
  }

  async function removeLine(c) {
    if (!await window.gracUi.confirm(`Remove ${c.assetName} (${covTypeLabel(c.coverageType)}) from this version?`)) return;
    const res = await api("POST", `/coverage/${c.coverageId}/remove`, { organizationId: state.organizationId });
    if (!res.ok) { show("acoVersionMessage", res.error); return; }
    await openVersion(state.version.version.versionId);
  }

  function versionBody() {
    const b = { organizationId: state.organizationId, expectedRecordVersion: state.version.version.recordVersion };
    VERSION_FIELDS.forEach(([id, key, kind]) => {
      const x = val(id);
      b[key] = !x ? null : kind === "number" ? Number(x) : kind === "id" ? Number(x) : x;
    });
    return b;
  }

  async function saveVersion() {
    const v = state.version.version;
    const res = await api("POST", `/versions/${v.versionId}`, versionBody());
    if (!res.ok) { show("acoVersionMessage", res.error); return false; }
    return true;
  }

  async function versionAction(action) {
    const v = state.version.version;
    if (action === "SAVE") {
      if (!await saveVersion()) return;
      await openVersion(v.versionId);
      show("acoVersionMessage", "Draft saved.", "success");
      await reloadContract();
      return;
    }
    let note = null;
    if (["RETURN", "REJECT", "WITHDRAW"].includes(action)) {
      const q = { RETURN: ["Return to draft", "Why is the version returned to draft?"],
                  REJECT: ["Reject version", "Why is the version rejected? It stays in the history and never takes effect."],
                  WITHDRAW: ["Withdraw draft", "Why is the draft withdrawn? It stays in the history and never takes effect."] }[action];
      note = await window.gracUi.promptRequired(q[1], { title: q[0], inputLabel: "Reason" });
      if (!note) return;
    } else if (action === "APPROVE") {
      const w = (state.version.warnings || []).length;
      if (!await window.gracUi.confirm(`${w ? w + " warning(s) are open. " : ""}Approve this version? It becomes immutable and takes effect on its effective start date.`)) return;
    } else if (action === "SUBMIT") {
      // Keep the edits on screen: save the draft first, then submit.
      if (!await saveVersion()) return;
      const fresh = await api("GET", `/versions/${v.versionId}?organizationId=${state.organizationId}`);
      if (fresh.ok) state.version = fresh.data.data;
    }
    const res = await api("POST", `/versions/${v.versionId}/action`, {
      organizationId: state.organizationId, action, note, expectedRecordVersion: state.version.version.recordVersion
    });
    if (!res.ok) { show("acoVersionMessage", res.error); return; }
    await openVersion(v.versionId);
    show("acoVersionMessage", { IN_REVIEW: "Submitted for review.", PENDING_APPROVAL: "Review complete; awaiting approval.",
      DRAFT: "Returned to draft.", REJECTED: action === "WITHDRAW" ? "Draft withdrawn." : "Version rejected.",
      APPROVED: "Approved; it takes effect on its effective start date.", ACTIVE: "Approved and now in force." }[res.data.result] || "Done.", "success");
    await reloadContract();
    await refreshList();
  }

  async function addDocument() {
    const v = state.version.version;
    const res = await api("POST", `/versions/${v.versionId}/documents`, {
      organizationId: state.organizationId, documentType: val("acoDfType"), title: val("acoDfTitle"), referenceText: val("acoDfReference")
    });
    if (!res.ok) { show("acoVersionMessage", res.error); return; }
    document.getElementById("acoDfTitle").value = "";
    document.getElementById("acoDfReference").value = "";
    await openVersion(v.versionId);
    show("acoVersionMessage", "Document added.", "success");
    await reloadContract();
  }

  async function removeDocument(id) {
    if (!await window.gracUi.confirm("Remove this document reference? It stays in the history as Removed.")) return;
    const res = await api("POST", `/documents/${id}/remove`, { organizationId: state.organizationId });
    if (!res.ok) { show("acoVersionMessage", res.error); return; }
    await openVersion(state.version.version.versionId);
    await reloadContract();
  }

  // ------------------------------------------------------------------ compare (7.2.4)
  async function runCompare() {
    const a = val("acoCmpA"), b = val("acoCmpB");
    if (!a || !b || a === b) { showDetailMessage("Select two different versions.", "error"); return; }
    const res = await api("GET", `/versions/compare?organizationId=${state.organizationId}&versionA=${a}&versionB=${b}`);
    if (!res.ok) { showDetailMessage(res.error, "error"); return; }
    state.compare = res.data.data;
    renderCompare();
    document.getElementById("acoCompareModal").hidden = false;
  }

  function renderCompare() {
    const c = state.compare;
    if (!c) return;
    const h = c.heading, only = document.getElementById("acoCmpChangedOnly").checked;
    document.getElementById("acoCompareTitle").textContent = `Compare v${h.versionANo} and v${h.versionBNo}`;
    document.getElementById("acoCompareHeading").textContent =
      `${h.contractNumber} - ${h.contractName}. Generated by ${h.generatedBy || ""} at ${dateTime(h.generatedAt)}. Read-only; neither version changes.`;
    document.getElementById("acoCmpHeadA").textContent = `v${h.versionANo}`;
    document.getElementById("acoCmpHeadB").textContent = `v${h.versionBNo}`;
    document.getElementById("acoCompareFields").innerHTML = c.fields.filter(f => !only || f.changed).map(f => `<tr class="${f.changed ? "aco-changed" : ""}">
        <td>${esc(f.label)}</td><td>${esc(f.valueA ?? "--")}</td><td>${esc(f.valueB ?? "--")}</td></tr>`).join("") || empty(3, "No differences.");
    document.getElementById("acoCompareContacts").innerHTML = c.contacts.filter(x => !only || x.changeType !== "SAME").map(x => {
      const [l, css] = CHANGE[x.changeType] || [x.changeType, ""];
      return `<tr><td>${esc(x.roleName)}</td><td>${esc(x.contactName)}</td><td><span class="aco-chip ${css}">${esc(l)}</span></td>
        <td>${yn(x.primaryInA)} / ${yn(x.primaryInB)}</td></tr>`;
    }).join("") || empty(4, "No vendor contact differences.");
    // 435: asset coverage and entitlement differences
    ["acoCmpCovA", "acoCmpEntA"].forEach(id => { document.getElementById(id).textContent = `v${h.versionANo}`; });
    ["acoCmpCovB", "acoCmpEntB"].forEach(id => { document.getElementById(id).textContent = `v${h.versionBNo}`; });
    document.getElementById("acoCompareCoverage").innerHTML = (c.coverage || []).filter(x => !only || x.changeType !== "SAME").map(x => {
      const [l, css] = CHANGE[x.changeType] || [x.changeType, ""];
      return `<tr><td>${esc(x.assetName)}</td><td>${esc(covTypeLabel(x.coverageType))}</td><td><span class="aco-chip ${css}">${esc(l)}</span></td>
        <td>${esc(x.detailA || "--")}</td><td>${esc(x.detailB || "--")}</td></tr>`;
    }).join("") || empty(5, "No asset coverage differences.");
    document.getElementById("acoCompareEntitlements").innerHTML = (c.entitlements || []).filter(x => !only || x.changeType !== "SAME").map(x => {
      const [l, css] = CHANGE[x.changeType] || [x.changeType, ""];
      return `<tr><td>${esc(x.productSku)}</td><td><span class="aco-chip ${css}">${esc(l)}</span></td>
        <td>${esc(x.skuA ? x.skuA + " | " + (x.detailA || "") : "--")}</td><td>${esc(x.skuB ? x.skuB + " | " + (x.detailB || "") : "--")}</td></tr>`;
    }).join("") || empty(4, "No entitlement differences.");
  }

  function exportCompare() {
    const c = state.compare;
    if (!c) return;
    const h = c.heading, q = v => `"${String(v ?? "").replace(/"/g, '""')}"`;
    const lines = [
      ["Contract ID", h.contractNumber].map(q).join(","), ["Contract", h.contractName].map(q).join(","),
      ["Compared versions", `v${h.versionANo} / v${h.versionBNo}`].map(q).join(","),
      ["Generated by", h.generatedBy].map(q).join(","), ["Generated at (UTC)", h.generatedAt].map(q).join(","), "",
      ["Field", `v${h.versionANo}`, `v${h.versionBNo}`, "Changed"].map(q).join(",")
    ];
    c.fields.forEach(f => lines.push([f.label, f.valueA, f.valueB, f.changed ? "Yes" : "No"].map(q).join(",")));
    lines.push("", ["Role", "Contact", "Change", `Primary v${h.versionANo}`, `Primary v${h.versionBNo}`].map(q).join(","));
    c.contacts.forEach(x => lines.push([x.roleName, x.contactName, (CHANGE[x.changeType] || [x.changeType])[0], yn(x.primaryInA), yn(x.primaryInB)].map(q).join(",")));
    lines.push("", ["Asset", "Coverage type", "Change", `v${h.versionANo}`, `v${h.versionBNo}`].map(q).join(","));
    (c.coverage || []).forEach(x => lines.push([x.assetName, covTypeLabel(x.coverageType), (CHANGE[x.changeType] || [x.changeType])[0], x.detailA, x.detailB].map(q).join(",")));
    lines.push("", ["Product / SKU", "Change", `v${h.versionANo}`, `v${h.versionBNo}`].map(q).join(","));
    (c.entitlements || []).forEach(x => lines.push([x.productSku, (CHANGE[x.changeType] || [x.changeType])[0], x.detailA, x.detailB].map(q).join(",")));
    const blob = new Blob([lines.join("\r\n")], { type: "text/csv;charset=utf-8" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `contract-${h.contractNumber}-v${h.versionANo}-v${h.versionBNo}.csv`;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  // ------------------------------------------------------------------ vendor contacts (7.4)
  function openContact(m) {
    const d = state.detail, lk = state.lookups;
    if (!d || !lk) return;
    state.contactEdit = m;
    const c = d.contract;
    const users = lk.vendorUsers.filter(u => u.vendorId === c.vendorId && (u.status === "Active" || (m && u.employeeId === m.employeeId)));
    document.getElementById("acoCfUser").innerHTML = `<option value="">Select</option>` +
      users.map(u => `<option value="${u.employeeId}">${esc(u.employeeName)}${u.email ? " - " + esc(u.email) : ""}</option>`).join("");
    document.getElementById("acoCfRole").innerHTML = `<option value="">Select</option>` +
      lk.roles.map(r => `<option value="${esc(r.roleCode)}">${esc(r.roleName)}${r.isMandatory ? " (mandatory)" : ""}</option>`).join("");
    const openV = c.openVersionId ? d.versions.find(v => v.versionId === c.openVersionId) : null;
    document.getElementById("acoCfScope").innerHTML = `<option value="">All versions of the contract</option>` +
      (openV ? `<option value="${openV.versionId}">Only v${esc(openV.versionNo)} (in progress)</option>` : "") +
      (m && m.versionId && (!openV || openV.versionId !== m.versionId) ? `<option value="${m.versionId}">Only v${esc(m.versionNo)}</option>` : "");
    document.getElementById("acoCfUser").value = m ? String(m.employeeId) : "";
    document.getElementById("acoCfRole").value = m ? m.roleCode : "";
    document.getElementById("acoCfScope").value = m && m.versionId ? String(m.versionId) : "";
    document.getElementById("acoCfChannel").value = m ? m.preferredChannel : "EMAIL";
    document.getElementById("acoCfStart").value = m ? date(m.effectiveStart) : (date(c.effectiveStart) || today());
    document.getElementById("acoCfEnd").value = m ? date(m.effectiveEnd) : "";
    document.getElementById("acoCfPrimary").checked = m ? !!m.isPrimary : false;
    document.getElementById("acoCfNotify").checked = m ? !!m.notificationParticipation : true;
    document.getElementById("acoCfNotes").value = m ? (m.notes || "") : "";
    // An existing mapping keeps its person, role and scope; a validated one also its primary flag and dates.
    const active = !!(m && m.status === "ACTIVE");
    ["acoCfUser", "acoCfRole", "acoCfScope"].forEach(id => { document.getElementById(id).disabled = !!m; });
    ["acoCfStart", "acoCfEnd", "acoCfPrimary"].forEach(id => { document.getElementById(id).disabled = active; });
    document.getElementById("acoContactTitle").textContent = m ? "Edit vendor contact" : "Add vendor contact";
    syncRoleUse();
    hide("acoContactMessage");
    document.getElementById("acoContactModal").hidden = false;
  }

  function syncRoleUse() {
    const r = (state.lookups?.roles || []).find(x => x.roleCode === val("acoCfRole"));
    document.getElementById("acoCfRoleUse").textContent = r && r.typicalUse ? `Typical use: ${r.typicalUse}.` : "";
  }

  async function submitContact() {
    const m = state.contactEdit, c = state.detail.contract;
    const res = await api("POST", `/${c.contractId}/contacts`, {
      organizationId: state.organizationId, mappingId: m ? m.mappingId : null, versionId: Number(val("acoCfScope")) || null,
      employeeId: Number(val("acoCfUser")) || null, roleCode: val("acoCfRole") || null,
      isPrimary: document.getElementById("acoCfPrimary").checked, effectiveStart: val("acoCfStart") || null,
      effectiveEnd: val("acoCfEnd") || null, preferredChannel: val("acoCfChannel"),
      notificationParticipation: document.getElementById("acoCfNotify").checked, notes: val("acoCfNotes") || null,
      expectedRecordVersion: m ? m.recordVersion : null
    });
    if (!res.ok) { show("acoContactMessage", res.error); return; }
    document.getElementById("acoContactModal").hidden = true;
    await reloadContract();
    showDetailMessage(m ? "Vendor contact saved." : "Vendor contact added; another person validates it.", "success");
  }

  async function contactAction(id, action) {
    const m = state.detail.contacts.find(x => x.mappingId === id);
    if (!m) return;
    if (action === "EDIT") { openContact(m); return; }
    if (action === "END") {
      state.endMapping = m;
      document.getElementById("acoEndDate").value = today();
      document.getElementById("acoEndReason").value = "";
      hide("acoEndMessage");
      document.getElementById("acoEndModal").hidden = false;
      return;
    }
    if (!await window.gracUi.confirm(`Validate ${m.contactName} as ${m.roleName}?`)) return;
    const res = await api("POST", `/contacts/${id}/action`, { organizationId: state.organizationId, action: "VALIDATE", expectedRecordVersion: m.recordVersion });
    if (!res.ok) { showDetailMessage(res.error, "error"); return; }
    await reloadContract();
    showDetailMessage("Vendor contact validated.", "success");
  }

  async function submitEnd() {
    const m = state.endMapping;
    if (!m) return;
    const res = await api("POST", `/contacts/${m.mappingId}/action`, {
      organizationId: state.organizationId, action: "END", endDate: val("acoEndDate") || null, note: val("acoEndReason") || null,
      expectedRecordVersion: m.recordVersion
    });
    if (!res.ok) { show("acoEndMessage", res.error); return; }
    document.getElementById("acoEndModal").hidden = true;
    await reloadContract();
    showDetailMessage("Assignment ended; it stays in the history.", "success");
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
  function info(items) {
    return items.map(([k, v, html]) => `<div><span>${esc(k)}</span>${html ? v : esc(v ?? "--")}</div>`).join("");
  }
  function statusLabel(code) { return code ? code.replace(/_/g, " ").toLowerCase().replace(/^./, c => c.toUpperCase()) : ""; }
  function reasonLabel(code) { return code ? statusLabel(code) : ""; }
  function money(v, cur) {
    if (v === null || v === undefined || v === "") return "--";
    const n = Number(v);
    return esc((isNaN(n) ? String(v) : n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })) + (cur ? " " + cur : ""));
  }
  function linkOrText(v) {
    const s = String(v ?? "");
    return /^https?:\/\//i.test(s) ? `<a href="${esc(s)}" target="_blank" rel="noopener noreferrer">${esc(s)}</a>` : esc(s);
  }
  function yn(v) { return v === null || v === undefined ? "--" : v ? "Yes" : "No"; }
  function empty(cols, text) { return `<tr><td colspan="${cols}" class="pm-empty">${esc(text)}</td></tr>`; }
  function showMessage(text, kind) {
    const el = document.getElementById("acoMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.classList.toggle("info", kind === "info"); el.hidden = !text;
  }
  function hideMessage() { const el = document.getElementById("acoMessage"); el.hidden = true; el.textContent = ""; }
  function showDetailMessage(text, kind) { show("acoDetailMessage", text, kind); }
  function hideDetailMessage() { hide("acoDetailMessage"); }
  function show(id, text, kind) {
    const el = document.getElementById(id);
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.hidden = !text;
  }
  function hide(id) { const el = document.getElementById(id); el.hidden = true; el.textContent = ""; el.classList.remove("success"); }
  function val(id) { return (document.getElementById(id).value || "").trim(); }
  function today() { return new Date().toISOString().substring(0, 10); }
  function date(v) { return v ? String(v).substring(0, 10) : ""; }   // SQL DATE values: yyyy-mm-dd
  function dateTime(v) { if (!v) return ""; const x = new Date(v); return isNaN(x) ? String(v) : x.toLocaleString(); }
  function esc(v) { return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
})();
