// =====================================================================
// Engagements (migrations 486-490). Loaded by tprm-engagements.cshtml.
// The list, and the workspace of one engagement (BRD steps 2-5 + lifecycle).
// Backend: practice/api/tprm (TprmController -> sp_tprm_*); docs/tprm.md
// section 9 lists every endpoint. Rows are the procedures' columns.
//
//   list        GET engagements
//   workspace   GET engagements/{id} (header, scope, links, snapshots,
//               history, customValues, dimensions); each step loads its own
//               data when opened:
//     Scope     GET engagements/{id}/discovery (preview), POST ... (record)
//               POST engagements, engagements/{id}/scope, engagements/scope/{id}/remove,
//               engagements/{id}/links, engagements/links/{id}/action
//     Risk      POST engagements/{id}/risk-assessments; GET risk-assessments/{id};
//               POST risk-assessments/{id}/answers | /complete
//     DD        POST/GET engagements/{id}/due-diligence; POST due-diligence/responses/{id}
//               | /rate, due-diligence/safeguards/{id}, due-diligence/{ddId}/complete,
//               engagements/{id}/evidence, evidence/{id}/review, engagements/{id}/findings,
//               findings/{id}/action, engagements/{id}/residual; GET evidence/candidates
//     Decision  GET engagements/{id}/decision; POST .../decision/submit,
//               decisions/{id}/act | /withdraw, engagements/{id}/risk-centre
//     Onboard   GET engagements/{id}/onboarding; POST .../onboarding/start,
//               onboarding/items/{id}/action, .../exposure/compare, deviations/{id}/action,
//               .../activate, .../lifecycle, .../reviews
// =====================================================================
(() => {
  "use strict";

  const T = window.gracTprm;
  const root = document.getElementById("enRoot");
  if (!root || !T) return;
  const { F, esc, date, empty, info, show, hide, api, qs, yes } = T;
  const CAN_ADD = root.dataset.canAdd === "1";
  const CAN_EDIT = root.dataset.canEdit === "1";
  const CAN_APPROVE = root.dataset.canApprove === "1";
  const HAS_EMPLOYEE = root.dataset.hasEmployee === "1";
  const CLOSED = ["EXITED", "REJECTED", "CANCELLED"];
  const STEP_OF_STAGE = { SCOPING: "SCOPE", RISK_ASSESSED: "DD", DUE_DILIGENCE: "DD", PENDING_DECISION: "DECISION",
                          APPROVED: "ONBOARD", ONBOARDING: "ONBOARD", ACTIVE: "ONBOARD", SUSPENDED: "ONBOARD", EXITING: "ONBOARD" };
  const SCOPE_KINDS = [
    { value: "BUSINESS_FUNCTION", label: "Business function" }, { value: "PROCESS", label: "Process" },
    { value: "APPLICATION", label: "Application" }, { value: "DATA_CATEGORY", label: "Data category" },
    { value: "ACCESS", label: "Access" }, { value: "LOCATION", label: "Location" }, { value: "FOURTH_PARTY", label: "Fourth party" }];
  const kindLabel = k => (SCOPE_KINDS.find(x => x.value === k) || { label: k }).label;

  const state = { org: null, lk: null, pager: null, drill: null, id: null, eng: null, tab: "SCOPE",
                  discovery: null, risk: null, dd: null, decision: null, onboarding: null, evidenceTarget: null };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  // ================================================================== list
  async function init() {
    state.pager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "enPager", onChange: refreshList }) : null;
    state.drill = window.__pmDrill ? window.__pmDrill.read() : null;
    bind();
    state.org = await T.orgs("enOrg");
    await loadOrg();
    const q = new URLSearchParams(window.location.search);
    // Dashboard drill (490): stage / band / criticality / attention.
    if (q.get("stage")) preselect("enStageFilter", q.get("stage"));
    if (q.get("band")) preselect("enBandFilter", q.get("band"));
    if (q.get("criticality")) preselect("enCriticalityFilter", q.get("criticality"));
    if (q.get("attention")) preselect("enAttentionFilter", q.get("attention"));
    if (state.drill?.active || q.get("stage") || q.get("band") || q.get("criticality") || q.get("attention"))
      window.__pmDrill?.banner(ensureBanner(), { ...(state.drill || {}), active: true, label: q.get("drillLabel") || "a dashboard selection" });
    await refreshList();
    const id = Number(q.get("engagementId"));
    if (id > 0 && state.org) openWorkspace(id);
    const tp = Number(q.get("newForThirdParty"));
    if (tp > 0 && state.org && CAN_ADD) editEngagement(null, tp);
  }
  function ensureBanner() {
    let host = document.getElementById("pmDrillBanner");
    if (!host) { host = document.createElement("div"); host.id = "pmDrillBanner"; root.parentNode.insertBefore(host, root); }
    return host;
  }
  function preselect(id, v) {
    const sel = document.getElementById(id);
    if (![...sel.options].some(o => o.value === v)) sel.add(new Option(T.stageLabel(v) || v, v));
    sel.value = v;
  }

  function bind() {
    document.getElementById("enOrg").addEventListener("change", async e => { state.org = Number(e.target.value) || null; await loadOrg(); closeWorkspace(); await refreshList(); });
    document.getElementById("enRefresh").addEventListener("click", () => refreshList());
    let t = null;
    document.getElementById("enSearch").addEventListener("input", () => { clearTimeout(t); t = setTimeout(() => { state.pager?.reset(true); refreshList(); }, 300); });
    ["enStageFilter", "enBandFilter", "enCriticalityFilter", "enAttentionFilter"].forEach(id =>
      document.getElementById(id).addEventListener("change", () => { state.pager?.reset(true); refreshList(); }));
    document.getElementById("enNew")?.addEventListener("click", () => editEngagement(null));
    document.getElementById("enListBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-en-row]");
      if (tr) openWorkspace(Number(tr.dataset.enRow));
    });
    document.getElementById("enBack").addEventListener("click", () => { closeWorkspace(); refreshList(); });
    document.querySelectorAll("[data-en-tab]").forEach(b => b.addEventListener("click", () => selectTab(b.dataset.enTab)));
    document.querySelectorAll("[data-close-en]").forEach(b => b.addEventListener("click", () => { document.getElementById(b.dataset.closeEn).hidden = true; }));
    // One delegated handler for every button the workspace renders.
    document.getElementById("enWs").addEventListener("click", ev => {
      const b = ev.target.closest("[data-act]");
      if (b && !b.disabled) act(b.dataset.act, b.dataset);
    });
    document.getElementById("enWs").addEventListener("change", ev => {
      const el = ev.target.closest("[data-change]");
      if (el) act(el.dataset.change, el.dataset, el);
    });
    document.getElementById("enEvidenceModal").addEventListener("click", ev => {
      const b = ev.target.closest("[data-act]");
      if (b && !b.disabled) act(b.dataset.act, b.dataset);
    });
  }

  async function loadOrg() {
    hide("enMessage");
    state.pager?.reset(true);
    state.lk = await T.lookups(state.org);
    if (state.lk.error) show("enMessage", state.lk.error);
    fill("enBandFilter", state.lk.bands.map(b => ({ value: F(b, "bandCode"), label: F(b, "bandName") })), "Any risk band");
    fill("enCriticalityFilter", state.lk.options("CRITICALITY"), "Any criticality");
  }
  function fill(id, options, blank) {
    const sel = document.getElementById(id);
    const keep = sel.value;
    sel.length = 0;
    sel.add(new Option(blank, ""));
    options.forEach(o => sel.add(new Option(o.label, o.value)));
    if ([...sel.options].some(o => o.value === keep)) sel.value = keep;
  }

  async function refreshList() {
    const body = document.getElementById("enListBody");
    if (!state.org) { body.innerHTML = empty(8, "Select an organization."); state.pager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const res = await api("GET", `/engagements?${qs({
      organizationId: state.org, search: val("enSearch"), stageCode: val("enStageFilter"), bandCode: val("enBandFilter"),
      criticalityCode: val("enCriticalityFilter"), attention: val("enAttentionFilter"),
      pageNumber: state.pager ? state.pager.page() : 1, pageSize: state.pager ? state.pager.size() : 25 })}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.pager?.clear(); return; }
    const rows = res.data.data || [];
    state.pager?.setTotal(res.data.totalRows, rows.length);
    body.innerHTML = rows.map(r => `<tr data-en-row="${esc(F(r, "engagementId"))}">
        <td>${esc(F(r, "engagementCode"))}${yes(F(r, "isSample")) ? ' <span class="pm-badge tprm-sample">Sample</span>' : ""}</td>
        <td>${esc(F(r, "engagementTitle"))}<div class="tprm-muted">${esc(F(r, "serviceCategory") || "")}</div>
            ${yes(F(r, "reassessmentRequired")) ? '<div class="tprm-alert">Reassessment required</div>' : ""}</td>
        <td>${esc(F(r, "thirdPartyCode"))} ${esc(F(r, "thirdPartyName"))}</td>
        <td>${esc(T.stageLabel(F(r, "stageCode")))}</td>
        <td>${T.badge(F(r, "criticality"), F(r, "criticalityColor")) || "--"}</td>
        <td>${F(r, "residualBandCode")
              ? `${T.band(F(r, "residualBand"), F(r, "residualBandColor"), F(r, "residualScore"))}<div class="tprm-muted">residual</div>`
              : `${T.band(F(r, "inherentBand"), F(r, "inherentBandColor"), F(r, "inherentScore"))}${F(r, "inherentBandCode") ? '<div class="tprm-muted">inherent</div>' : ""}`}</td>
        <td>${esc(date(F(r, "nextReviewDt")) || "--")}</td>
        <td>${esc(F(r, "businessOwnerName") || "--")}</td>
      </tr>`).join("") || empty(8, "No engagements match.");
  }

  // ================================================================== create / edit
  async function editEngagement(eng, forThirdPartyId) {
    const lk = state.lk;
    const h = eng || {};
    let thirdParties = [];
    if (!eng) {
      const r = await api("GET", `/third-parties?${qs({ organizationId: state.org, pageNumber: 1, pageSize: 200 })}`);
      thirdParties = r.ok ? (r.data.data || []).map(x => ({ value: F(x, "thirdPartyId"), label: `${F(x, "thirdPartyCode")} - ${F(x, "legalName")}` })) : [];
      if (!thirdParties.length) { show("enMessage", "Register the third party first (Third Parties screen)."); return; }
    }
    const contracts = lk.contracts.filter(c => F(c, "contractId") != null)
      .map(c => ({ value: F(c, "contractId"), label: `${F(c, "contractNumber")} - ${F(c, "contractName")}` }));
    const emp = lk.employeeOptions();
    const fields = [
      ...(eng ? [] : [{ name: "thirdPartyId", label: "Third party", type: "select", options: thirdParties, value: forThirdPartyId || "", required: true }]),
      { name: "engagementTitle", label: "Engagement title", required: true, maxLength: 250, value: F(h, "engagementTitle"), full: true },
      { type: "section", label: "Service and scope", name: "_s" },
      { name: "serviceCategoryCode", label: "Service category", type: "select", options: lk.options("SERVICE_CATEGORY"), value: F(h, "serviceCategoryCode") },
      { name: "engagementTypeCode", label: "Engagement type", type: "select", options: lk.options("ENGAGEMENT_TYPE"), value: F(h, "engagementTypeCode") },
      { name: "serviceModelCode", label: "Service / delivery model", type: "select", options: lk.options("SERVICE_MODEL"), value: F(h, "serviceModelCode") },
      { name: "serviceCriticalityCode", label: "Service criticality", type: "select", options: lk.options("CRITICALITY"), value: F(h, "criticalityCode"), required: true },
      { name: "dataExposureCode", label: "Most sensitive data exposure", type: "select", options: lk.options("DATA_EXPOSURE"), value: F(h, "dataExposureCode"),
        help: "Recorded as a proposed data-category scope item too. Needed before the inherent risk assessment." },
      { name: "isExisting", label: "Existing relationship (already in place)", type: "checkbox", value: F(h, "isExisting") },
      { name: "serviceDescription", label: "Service description", type: "textarea", maxLength: 2000, value: F(h, "serviceDescription") },
      { name: "scopeDescription", label: "Scope description", type: "textarea", maxLength: 2000, value: F(h, "scopeDescription") },
      { name: "businessPurpose", label: "Business purpose", type: "textarea", rows: 2, maxLength: 1000, value: F(h, "businessPurpose") },
      { name: "deliveryLocations", label: "Delivery locations (countries / sites)", maxLength: 1000, value: F(h, "deliveryLocations"), full: true },
      { type: "section", label: "People", name: "_p" },
      { name: "businessOwnerEmployeeId", label: "Business owner", type: "select", options: emp, value: F(h, "businessOwnerEmployeeId") },
      { name: "relationshipOwnerEmployeeId", label: "Relationship owner", type: "select", options: emp, value: F(h, "relationshipOwnerEmployeeId") },
      { name: "assessorEmployeeId", label: "Due-diligence assessor", type: "select", options: emp, value: F(h, "assessorEmployeeId") },
      { type: "section", label: "Contract and dates", name: "_c" },
      { name: "contractId", label: "Contract (Asset & Contract)", type: "select", options: contracts, value: F(h, "contractId") },
      { name: "contractReference", label: "Contract reference", maxLength: 200, value: F(h, "contractReference") },
      { name: "contractValue", label: "Contract value", type: "number", step: "0.01", value: F(h, "contractValue") },
      { name: "currencyCode", label: "Currency", maxLength: 10, value: F(h, "currencyCode") },
      { name: "proposedStartDt", label: "Proposed start", type: "date", value: F(h, "proposedStartDt") },
      { name: "proposedEndDt", label: "Proposed end", type: "date", value: F(h, "proposedEndDt") },
      { name: "renewalDt", label: "Renewal date", type: "date", value: F(h, "renewalDt") },
      { name: "rtoHours", label: "RTO (hours)", type: "number", min: 0, value: F(h, "rtoHours") },
      { name: "rpoHours", label: "RPO (hours)", type: "number", min: 0, value: F(h, "rpoHours") },
      { name: "slaSummary", label: "SLA summary", type: "textarea", rows: 2, maxLength: 2000, value: F(h, "slaSummary") },
      { name: "notes", label: "Notes", type: "textarea", rows: 2, value: F(h, "notes") },
      ...T.customFields(lk, "ENGAGEMENT", eng ? (state.eng.customValues || []) : [])
    ];
    const res = await T.form({
      title: eng ? `Edit ${F(h, "engagementCode")}` : "New engagement", wide: true, submitText: eng ? "Save" : "Create",
      intro: eng && ["APPROVED", "ONBOARDING", "ACTIVE", "SUSPENDED"].includes(F(h, "stageCode"))
        ? "A change of criticality, data exposure, service model or delivery locations on an approved or live engagement is a material change: it is recorded and the engagement is flagged for reassessment." : "",
      fields,
      onSubmit: async v => {
        const r = await api("POST", "/engagements", {
          organizationId: state.org, engagementId: eng ? F(h, "engagementId") : null,
          thirdPartyId: eng ? F(h, "thirdPartyId") : Number(v.thirdPartyId),
          engagementTitle: v.engagementTitle, serviceDescription: v.serviceDescription, scopeDescription: v.scopeDescription,
          businessPurpose: v.businessPurpose, serviceCategoryCode: v.serviceCategoryCode, engagementTypeCode: v.engagementTypeCode,
          serviceModelCode: v.serviceModelCode, deliveryLocations: v.deliveryLocations, isExisting: !!v.isExisting,
          contractId: v.contractId ? Number(v.contractId) : null, contractReference: v.contractReference,
          contractValue: v.contractValue, currencyCode: v.currencyCode, proposedStartDt: v.proposedStartDt, proposedEndDt: v.proposedEndDt,
          renewalDt: v.renewalDt, businessOwnerEmployeeId: num(v.businessOwnerEmployeeId), relationshipOwnerEmployeeId: num(v.relationshipOwnerEmployeeId),
          assessorEmployeeId: num(v.assessorEmployeeId), serviceCriticalityCode: v.serviceCriticalityCode, dataExposureCode: v.dataExposureCode,
          rtoHours: v.rtoHours, rpoHours: v.rpoHours, slaSummary: v.slaSummary, notes: v.notes, customJson: T.customJson(v),
          expectedRecordVersion: eng ? F(h, "recordVersion") : null
        });
        return r.ok ? { ok: true, id: F(r.data.result, "engagementId"), outcome: F(r.data.result, "result") } : r;
      }
    });
    if (!res) return;
    if (res.result.outcome === "MATERIAL_CHANGE") show("enWsMessage", "Saved. This is a material change: the engagement is flagged for reassessment.", "info");
    if (eng) await reloadWorkspace(); else { await refreshList(); openWorkspace(res.result.id); }
  }

  // ================================================================== workspace
  async function openWorkspace(id) {
    state.id = id;
    const ok = await reloadWorkspace();
    if (!ok) return;
    document.getElementById("enList").hidden = true;
    document.getElementById("enWs").hidden = false;
    hide("enWsMessage");
    selectTab(STEP_OF_STAGE[H("stageCode")] || "SCOPE");
    window.scrollTo({ top: 0, behavior: "smooth" });
  }
  function closeWorkspace() {
    state.id = null; state.eng = null;
    document.getElementById("enWs").hidden = true;
    document.getElementById("enList").hidden = false;
  }
  async function reloadWorkspace() {
    const res = await api("GET", `/engagements/${state.id}?${qs({ organizationId: state.org })}`);
    if (!res.ok) { show(state.eng ? "enWsMessage" : "enMessage", res.error); return false; }
    state.eng = res.data;
    renderHeader();
    await renderTab(state.tab);
    return true;
  }
  const H = k => F((state.eng?.header || [])[0], k);
  const isClosed = () => CLOSED.includes(H("stageCode"));
  const canEdit = () => CAN_EDIT && !isClosed();

  function renderHeader() {
    const stage = H("stageCode");
    document.getElementById("enWsTitle").textContent = `${H("engagementCode")} - ${H("engagementTitle")}`;
    document.getElementById("enWsSub").innerHTML = `${esc(H("thirdPartyCode"))} ${esc(H("thirdPartyName"))} &middot; ${esc(T.stageLabel(stage))}`
      + (yes(H("isSample")) ? ' <span class="pm-badge tprm-sample">Sample record</span>' : "");
    document.getElementById("enWsSummary").innerHTML = info([
      ["Stage", `<strong>${esc(T.stageLabel(stage))}</strong> <span class="tprm-muted">since ${esc(date(H("stageDt")))}</span>`, true],
      ["Criticality", T.badge(H("criticality"), H("criticalityColor")), true],
      ["Data exposure", H("dataExposure")],
      ["Inherent risk", T.band(H("inherentBand"), H("inherentBandColor"), H("inherentScore")), true],
      ["Due-diligence tier", H("ddTier")],
      ["Residual risk", T.band(H("residualBand"), H("residualBandColor"), H("residualScore")), true],
      ["Risk accepted until", date(H("acceptanceUntil"))],
      ["Next review", date(H("nextReviewDt"))],
      ["Business owner", H("businessOwnerName")]
    ]);
    const banner = document.getElementById("enWsBanner");
    banner.innerHTML = yes(H("reassessmentRequired"))
      ? `<p class="pm-message">Reassessment required: ${esc(H("reassessmentReason") || "")}. Start a new inherent risk assessment.</p>` : "";
    const b = [];
    if (canEdit()) b.push(btn("edit-engagement", "fa-pen", "Edit"));
    document.getElementById("enWsActions").innerHTML = b.join("");
    // Step chips: done / current.
    // Closed engagements: every step reached is done (EXITED) or none is current.
    const order = ["SCOPE", "RISK", "DD", "DECISION", "ONBOARD"];
    const current = STEP_OF_STAGE[stage] || null;
    const reached = stage === "EXITED" ? order.length : current ? order.indexOf(current) : 0;
    order.forEach((s, i) => {
      const chip = document.querySelector(`[data-en-chip="${s}"]`);
      chip.classList.toggle("done", i < reached);
      chip.classList.toggle("current", s === current);
    });
  }

  function selectTab(name) {
    state.tab = name;
    document.querySelectorAll("[data-en-tab]").forEach(x => { const on = x.dataset.enTab === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    document.querySelectorAll("[data-en-panel]").forEach(p => { p.hidden = p.dataset.enPanel !== name; });
    renderTab(name);
  }
  async function renderTab(name) {
    if (!state.eng) return;
    if (name === "SCOPE") renderScope();
    else if (name === "RISK") await renderRisk();
    else if (name === "DD") await renderDd();
    else if (name === "DECISION") await renderDecision();
    else if (name === "ONBOARD") await renderOnboarding();
    else renderHistory();
  }

  // ------------------------------------------------------------------ step: scope & exposure
  function renderScope() {
    const e = state.eng;
    const scope = e.scope || [];
    const links = e.links || [];
    const row = s => `<tr>
        <td>${esc(kindLabel(F(s, "itemKind")))}</td>
        <td>${esc(F(s, "itemName"))}${F(s, "country") ? ` <span class="tprm-muted">${esc(F(s, "country"))}</span>` : ""}${F(s, "notes") ? `<div class="tprm-muted">${esc(F(s, "notes"))}</div>` : ""}</td>
        <td>${state.lk.badge("CRITICALITY", F(s, "criticalityCode"))}${yes(F(s, "isCritical")) ? ' <span class="pm-badge">Critical</span>' : ""}</td>
        <td>${canEdit() ? btn("scope-remove", "fa-trash", "", { id: F(s, "scopeItemId") }, "Remove") : ""}</td></tr>`;
    const proposed = scope.filter(s => F(s, "exposureMode") === "PROPOSED");
    const actual = scope.filter(s => F(s, "exposureMode") === "ACTUAL");
    const linkRow = l => `<tr>
        <td>${esc(F(l, "linkKind"))}</td><td>${esc(F(l, "targetLabel"))}</td>
        <td>${esc(F(l, "linkSource"))}</td>
        <td>${yes(F(l, "isValidated")) ? `Validated <span class="tprm-muted">${esc(F(l, "validatedBy") || "")}</span>` : '<span class="tprm-muted">Not validated</span>'}</td>
        <td>${canEdit() ? (yes(F(l, "isValidated")) ? "" : btn("link-validate", "fa-check", "Validate", { id: F(l, "linkId") })) + btn("link-remove", "fa-link-slash", "", { id: F(l, "linkId") }, "Remove link") : ""}</td></tr>`;
    document.getElementById("enPanelScope").innerHTML = `
      <div class="tprm-subhead">Engagement</div>
      <div class="tprm-info">${info([
        ["Service category", H("serviceCategory")], ["Engagement type", H("engagementType")], ["Service model", H("serviceModel")],
        ["Existing relationship", yes(H("isExisting")) ? "Yes" : "No"], ["Delivery locations", H("deliveryLocations")],
        ["Contract", H("contractReference") || (H("contractId") ? `#${H("contractId")}` : "")],
        ["Proposed term", [date(H("proposedStartDt")), date(H("proposedEndDt"))].filter(Boolean).join(" to ")],
        ["Actual term", [date(H("actualStartDt")), date(H("actualEndDt"))].filter(Boolean).join(" to ")],
        ["RTO / RPO (hours)", [H("rtoHours"), H("rpoHours")].map(x => x ?? "--").join(" / ")],
        ["Relationship owner", H("relationshipOwnerName")], ["Assessor", H("assessorName")],
        ["Service description", H("serviceDescription")], ["Scope", H("scopeDescription")], ["Business purpose", H("businessPurpose")],
        ["SLA", H("slaSummary")],
        ...(e.customValues || []).map(c => [F(c, "label"), F(c, "value")])
      ])}</div>
      <div class="tprm-subhead">Proposed exposure <span>${canEdit() ? btn("scope-add", "fa-plus", "Add scope item", { mode: "PROPOSED" }) : ""}</span></div>
      <p class="tprm-note">What the third party will access, store, support or depend on, as proposed. It drives the risk-model prefill and which questionnaires and questions apply.</p>
      <div class="pm-table-wrap"><table><thead><tr><th>Type</th><th>Item</th><th>Criticality</th><th></th></tr></thead>
        <tbody>${proposed.map(row).join("") || empty(4, "No proposed scope yet.")}</tbody></table></div>
      ${actual.length || ["ONBOARDING", "ACTIVE", "SUSPENDED"].includes(H("stageCode")) ? `
      <div class="tprm-subhead">Actual exposure <span>${canEdit() ? btn("scope-add", "fa-plus", "Add actual item", { mode: "ACTUAL" }) : ""}</span></div>
      <div class="pm-table-wrap"><table><thead><tr><th>Type</th><th>Item</th><th>Criticality</th><th></th></tr></thead>
        <tbody>${actual.map(row).join("") || empty(4, "No actual exposure recorded.")}</tbody></table></div>` : ""}
      <div class="tprm-subhead">Discovered from GRAC
        <span>${btn("discover", "fa-magnifying-glass", "Discover")}${canEdit() ? btn("discover-record", "fa-floppy-disk", "Record discovery") : ""}</span></div>
      <p class="tprm-note">Practice instances, obligations, dependencies, assurance findings, gaps, enterprise risks and contracts that already involve this third party's GRAC vendor or the applications in scope. Discovery only reads; "Record discovery" saves what was found as links to validate.</p>
      <div id="enDiscovery">${state.discovery ? discoveryHtml(state.discovery) : ""}</div>
      <div class="tprm-subhead">Linked GRAC records <span>${canEdit() ? btn("link-add", "fa-link", "Link a record") : ""}</span></div>
      <div class="pm-table-wrap"><table><thead><tr><th>Type</th><th>Record</th><th>Source</th><th>Validation</th><th></th></tr></thead>
        <tbody>${links.map(linkRow).join("") || empty(5, "Nothing linked yet.")}</tbody></table></div>`;
  }

  function discoveryHtml(d) {
    const counts = (d.summary || []).map(c => `<div><span>${esc(F(c, "countKey"))}</span>${esc(F(c, "countValue"))}</div>`).join("");
    const table = (title, cols, rows, cells, linkKind, idKey) => rows.length ? `
      <h4 class="pm-dash-subhead">${esc(title)}</h4>
      <div class="pm-table-wrap"><table><thead><tr>${cols.map(c => `<th>${esc(c)}</th>`).join("")}${linkKind ? "<th></th>" : ""}</tr></thead><tbody>${
        rows.map(r => `<tr>${cells(r).map(c => `<td>${c}</td>`).join("")}${linkKind ? `<td>${canEdit() && !yes(F(r, "isLinked")) ? btn("link-from-discovery", "fa-link", "Link", { kind: linkKind, id: F(r, idKey) }) : (yes(F(r, "isLinked")) ? '<span class="tprm-muted">Linked</span>' : "")}</td>` : ""}</tr>`).join("")
      }</tbody></table></div>` : "";
    return `<div class="tprm-info">${counts}</div>`
      + table("Practice instances", ["Instance", "Practice", "Criticality", "Implementation", "Via"], d.instances || [],
          r => [esc(`${F(r, "instanceCode")} ${F(r, "instanceName")}`), esc(`${F(r, "practiceCode")} ${F(r, "practiceName")}`), esc(F(r, "criticality") || ""), esc(F(r, "implementationStatus") || ""), esc(F(r, "via") || "")],
          "PRACTICE_INSTANCE", "practiceInstanceId")
      + table("Obligations", ["Obligation", "Level", "Type", "Frequency", "Responsibility"], d.obligations || [],
          r => [esc(F(r, "obligationName")), esc(F(r, "level")), esc(F(r, "obligationTypeCode") || ""), esc(F(r, "executionFrequency") || ""), esc(F(r, "responsibility") || "")])
      + table("Dependencies", ["Kind", "Dependency", "Instance", "Status"], d.dependencies || [],
          r => [esc(F(r, "dependencyKind")), esc(F(r, "dependencyName")), esc(F(r, "instanceCode") || ""), esc(F(r, "resolutionStatus") || "")])
      + table("Assurance findings", ["Finding", "Severity", "Status", "Observed", "On"], d.findings || [],
          r => [esc(`${F(r, "observationCode")} ${F(r, "observationTitle")}`), esc(F(r, "severityName") || ""), esc(F(r, "statusName") || ""), esc(date(F(r, "observedDt"))), esc(F(r, "entityName") || "")])
      + table("Practice gaps", ["Gap", "Instance", "Status", "Opened"], d.gaps || [],
          r => [esc(`#${F(r, "practiceGapId")}`), esc(F(r, "practiceInstanceId")), esc(F(r, "gapStatus")), esc(date(F(r, "openedDt")))])
      + table("Enterprise risks", ["Risk", "Status", "Inherent rating"], d.risks || [],
          r => [esc(`${F(r, "riskNumber")} ${F(r, "riskTitle")}`), esc(F(r, "statusCode")), esc(F(r, "inherentRating") || "")],
          "ENTERPRISE_RISK", "riskRegisterId")
      + table("Contracts", ["Contract", "Name", "Status"], d.contracts || [],
          r => [esc(F(r, "contractNumber")), esc(F(r, "contractName") || ""), esc(F(r, "contractStatus") || "")], "CONTRACT", "contractId");
  }

  async function addScopeItem(mode) {
    const lk = state.lk;
    const pick = await T.form({
      title: mode === "ACTUAL" ? "Add actual exposure" : "Add proposed scope item", submitText: "Next",
      fields: [{ name: "kind", label: "Type", type: "select", options: SCOPE_KINDS, required: true, blank: "Choose" }]
    });
    if (!pick) return;
    const kind = pick.kind;
    const refOptions = kind === "BUSINESS_FUNCTION" ? lk.businessFunctions : kind === "PROCESS" ? lk.processes : kind === "APPLICATION" ? lk.applications : null;
    const listCode = kind === "DATA_CATEGORY" ? "DATA_EXPOSURE" : kind === "ACCESS" ? "ACCESS_CATEGORY" : kind === "FOURTH_PARTY" ? "FOURTH_PARTY_CATEGORY" : null;
    const fields = [];
    if (refOptions) fields.push({ name: "refId", label: `GRAC ${kindLabel(kind).toLowerCase()}`, type: "select", options: refOptions.map(x => ({ value: F(x, "id"), label: F(x, "name") })),
      help: "Or name an item that is not in GRAC below." }, { name: "itemName", label: "Name (when not in GRAC)", maxLength: 300 });
    else if (kind === "DATA_CATEGORY" || kind === "ACCESS") fields.push({ name: "itemCode", label: kindLabel(kind), type: "select", options: lk.options(listCode), required: true });
    else if (kind === "FOURTH_PARTY") fields.push({ name: "itemName", label: "Fourth party (subcontractor)", required: true, maxLength: 300 },
      { name: "itemCode", label: "Category", type: "select", options: lk.options(listCode) }, { name: "country", label: "Country", maxLength: 120 });
    else fields.push({ name: "itemName", label: "Location / site", required: true, maxLength: 300 }, { name: "country", label: "Country", maxLength: 120 });
    fields.push({ name: "criticalityCode", label: "Criticality", type: "select", options: lk.options("CRITICALITY") },
      { name: "isCritical", label: "Critical to the service", type: "checkbox" },
      { name: "notes", label: "Notes", type: "textarea", rows: 2, maxLength: 1000 });
    await T.form({
      title: `${mode === "ACTUAL" ? "Actual" : "Proposed"}: ${kindLabel(kind)}`, submitText: "Add", fields,
      onSubmit: async v => {
        const label = (listCode && v.itemCode) ? lk.label(listCode, v.itemCode) : null;
        const refName = refOptions && v.refId ? F(refOptions.find(x => String(F(x, "id")) === String(v.refId)), "name") : null;
        const r = await api("POST", `/engagements/${state.id}/scope`, {
          organizationId: state.org, itemKind: kind, exposureMode: mode, refId: num(v.refId), itemCode: v.itemCode,
          itemName: v.itemName || refName || label, criticalityCode: v.criticalityCode, country: v.country,
          isCritical: !!v.isCritical, notes: v.notes });
        return r;
      }
    }).then(async r => { if (r) await reloadWorkspace(); });
  }

  async function addLink() {
    const lk = state.lk;
    const kinds = [{ value: "VENDOR", label: "GRAC vendor" }, { value: "APPLICATION", label: "Application" }, { value: "CONTRACT", label: "Contract" }];
    const pick = await T.form({ title: "Link a GRAC record", submitText: "Next",
      intro: "Practice instances, dependencies and enterprise risks are linked from the discovery results.",
      fields: [{ name: "kind", label: "Record type", type: "select", options: kinds, required: true, blank: "Choose" }] });
    if (!pick) return;
    const options = pick.kind === "VENDOR" ? lk.vendors.map(x => ({ value: F(x, "vendorId"), label: F(x, "vendorName") }))
      : pick.kind === "APPLICATION" ? lk.applications.map(x => ({ value: F(x, "id"), label: F(x, "name") }))
      : lk.contracts.filter(c => F(c, "contractId") != null).map(x => ({ value: F(x, "contractId"), label: `${F(x, "contractNumber")} - ${F(x, "contractName")}` }));
    await T.form({ title: "Link a GRAC record", submitText: "Link",
      fields: [{ name: "targetId", label: kinds.find(k => k.value === pick.kind).label, type: "select", options, required: true },
               { name: "note", label: "Note", type: "textarea", rows: 2, maxLength: 1000 }],
      onSubmit: v => api("POST", `/engagements/${state.id}/links`, { organizationId: state.org, linkKind: pick.kind, targetId: Number(v.targetId), note: v.note })
    }).then(async r => { if (r) await reloadWorkspace(); });
  }

  // ------------------------------------------------------------------ step: inherent risk
  async function renderRisk() {
    const host = document.getElementById("enPanelRisk");
    const draft = H("draftRiskAssessmentId"), current = H("currentRiskAssessmentId");
    const id = draft || current;
    let ra = null;
    if (id) {
      const r = await api("GET", `/risk-assessments/${id}?${qs({ organizationId: state.org })}`);
      if (!r.ok) { host.innerHTML = `<p class="pm-message">${esc(r.error)}</p>`; return; }
      ra = r.data;
    }
    state.risk = ra;
    const startBtn = canEdit() && !draft && H("stageCode") !== "PENDING_DECISION" && H("stageCode") !== "EXITING"
      ? btn("risk-start", "fa-play", current ? "Reassess" : "Start inherent risk assessment", {}, null, "primary") : "";
    if (!ra) {
      host.innerHTML = `<p class="tprm-note">The inherent risk is scored on the organization's risk model in force (pinned to the assessment). Factors are prefilled from the scope; every answer is confirmed by the assessor. The band sets the due-diligence tier.</p>
        <div class="tprm-actions">${startBtn}</div>
        ${state.lk.riskModel ? `<p class="tprm-muted">Risk model in force: ${esc(F(state.lk.riskModel, "templateName"))} v${esc(F(state.lk.riskModel, "versionNo"))} (${esc(F(state.lk.riskModel, "origin"))})</p>` : '<p class="pm-message">No risk model is in force. Activate one in TPRM Configuration.</p>'}`;
      return;
    }
    const a = ra.header[0];
    const isDraft = F(a, "status") === "DRAFT";
    const answers = new Map((ra.answers || []).map(x => [String(F(x, "factorId")), x]));
    const dims = ra.dimensions || [];
    const factors = ra.factors || [];
    const options = ra.options || [];
    const editable = isDraft && canEdit();
    const factorRows = d => factors.filter(f => String(F(f, "dimensionId")) === String(F(d, "dimensionId"))).map(f => {
      const ans = answers.get(String(F(f, "factorId")));
      const opts = options.filter(o => String(F(o, "factorId")) === String(F(f, "factorId")));
      const chosen = ans ? String(F(ans, "optionId") ?? "") : "";
      return `<tr class="en-q-row" data-factor="${esc(F(f, "factorId"))}">
        <td>${esc(F(f, "questionText"))}${yes(F(f, "isMandatory")) ? " *" : ""}${F(f, "guidance") ? `<div class="tprm-muted">${esc(F(f, "guidance"))}</div>` : ""}</td>
        <td>${editable ? `<select data-factor-option>${'<option value="">--</option>' + opts.map(o => `<option value="${esc(F(o, "optionId"))}"${String(F(o, "optionId")) === chosen ? " selected" : ""}>${esc(F(o, "optionLabel"))} (${esc(F(o, "score"))})</option>`).join("")}</select>`
              : esc(F(opts.find(o => String(F(o, "optionId")) === chosen), "optionLabel") || "--")}
            ${ans && yes(F(ans, "isPrefilled")) ? '<div class="tprm-muted">Prefilled from the scope -- confirm or change</div>' : ""}</td>
        <td>${editable ? `<input type="text" data-factor-comment maxlength="1000" value="${esc(ans ? F(ans, "comment") || "" : "")}" />` : esc(ans ? F(ans, "comment") || "" : "")}</td></tr>`;
    }).join("");
    host.innerHTML = `
      <div class="tprm-info">${info([
        ["Assessment", `#${F(a, "assessmentNo")} ${F(a, "status")}`], ["Risk model", `${F(a, "riskModelName")} v${F(a, "riskModelVersionNo")}`],
        ["Trigger", state.lk.label("REVIEW_TRIGGER", F(a, "triggerCode")) || F(a, "triggerCode")],
        ["Inherent score", T.band(F(a, "inherentBand"), F(a, "inherentBandColor"), F(a, "inherentScore")), true],
        ["Due-diligence tier", state.lk.label("DD_TIER", F(a, "ddTierCode"))], ["Why this tier", F(a, "ddTierReason")],
        ["Assessed by", F(a, "assessedByName")], ["Completed", F(a, "completedDt") ? T.dateTime(F(a, "completedDt")) : ""]
      ])}</div>
      <div class="tprm-actions">${startBtn}
        ${editable ? btn("risk-save", "fa-floppy-disk", "Save answers") + btn("risk-complete", "fa-check", "Complete assessment", {}, null, "primary") + btn("risk-discard", "fa-xmark", "Discard") : ""}</div>
      ${isDraft && current ? '<p class="tprm-note">The completed assessment stays in force until this one is completed.</p>' : ""}
      <div class="pm-table-wrap"><table><thead><tr><th>Dimension</th><th>Weight</th><th>Inherent</th><th>Residual</th><th>Safeguards</th></tr></thead><tbody>${
        dims.map(d => `<tr><td>${esc(F(d, "dimensionName"))}</td><td>${esc(F(d, "weight"))}</td><td>${score(F(d, "inherentScore"))}</td>
          <td>${score(F(d, "residualScore"))}</td><td class="tprm-muted">${esc(F(d, "safeguardSummary") || "")}</td></tr>`).join("")}</tbody></table></div>
      ${dims.map(d => `<div class="tprm-subhead">${esc(F(d, "dimensionName"))}</div>
        <div class="pm-table-wrap"><table><thead><tr><th style="width:45%">Factor</th><th>Answer</th><th>Comment</th></tr></thead><tbody>${factorRows(d) || empty(3, "No factors.")}</tbody></table></div>`).join("")}`;
  }
  function riskAnswers() {
    return [...document.querySelectorAll("#enPanelRisk tr[data-factor]")].map(tr => ({
      factorId: Number(tr.dataset.factor),
      optionId: num(tr.querySelector("[data-factor-option]")?.value),
      comment: (tr.querySelector("[data-factor-comment]")?.value || "").trim() || null
    }));
  }

  // ------------------------------------------------------------------ step: due diligence
  async function renderDd() {
    const host = document.getElementById("enPanelDd");
    const r = await api("GET", `/engagements/${state.id}/due-diligence?${qs({ organizationId: state.org })}`);
    if (!r.ok) { host.innerHTML = `<p class="pm-message">${esc(r.error)}</p>`; return; }
    state.dd = r.data;
    const d = (r.data.header || [])[0];
    const canStart = canEdit() && H("currentRiskAssessmentId") && !(d && F(d, "status") === "IN_PROGRESS")
      && ["RISK_ASSESSED", "DUE_DILIGENCE", "ACTIVE", "SUSPENDED", "APPROVED", "ONBOARDING"].includes(H("stageCode"));
    const start = canStart ? btn("dd-start", "fa-play", d ? "Start a new round" : "Start due diligence", {}, null, "primary") : "";
    if (!d) {
      host.innerHTML = `<p class="tprm-note">Questionnaires are generated from the service category, the due-diligence tier and the scope (data and access); follow-up questions appear when an answer calls for them. Safeguards are assessed for effectiveness: only a verified effective or partially effective safeguard reduces the residual risk.</p>
        <div class="tprm-actions">${start}</div>${H("currentRiskAssessmentId") ? "" : '<p class="pm-message info">Complete the inherent risk assessment first.</p>'}`;
      renderFindingsAndResidual(host, true);
      return;
    }
    const open = F(d, "status") === "IN_PROGRESS";
    const editable = open && canEdit();
    const evidence = r.data.evidence || [];
    const evCount = (kind, id) => evidence.filter(e => F(e, "targetKind") === kind && String(F(e, "targetId")) === String(id)).length;
    const opts = r.data.options || [];
    const ratings = state.lk.options("RESPONSE_RATING");
    const questionRow = q => {
      if (!yes(F(q, "isApplicable"))) return "";
      const rid = F(q, "responseId"), type = F(q, "responseType");
      const qopts = opts.filter(o => String(F(o, "questionId")) === String(F(q, "questionId")));
      const chosen = String(F(q, "answerOptionCodes") || "").split(",").filter(Boolean);
      let answer;
      if (!editable) answer = esc(type === "YES_NO" || type === "SINGLE" || type === "MULTI"
        ? qopts.filter(o => chosen.includes(F(o, "optionCode"))).map(o => F(o, "optionLabel")).join(", ")
        : (F(q, "answerText") ?? F(q, "answerNumber") ?? date(F(q, "answerDate")) ?? "")) || '<span class="tprm-muted">No answer</span>';
      else if (type === "MULTI") answer = qopts.map(o => `<label class="tprm-inline-check"><input type="checkbox" data-ans-multi value="${esc(F(o, "optionCode"))}"${chosen.includes(F(o, "optionCode")) ? " checked" : ""} /> ${esc(F(o, "optionLabel"))}</label>`).join(" ");
      else if (type === "YES_NO" || type === "SINGLE") answer = `<select data-ans-option><option value="">--</option>${qopts.map(o => `<option value="${esc(F(o, "optionCode"))}"${chosen.includes(F(o, "optionCode")) ? " selected" : ""}>${esc(F(o, "optionLabel"))}</option>`).join("")}</select>`;
      else if (type === "DATE") answer = `<input type="date" data-ans-date value="${esc(date(F(q, "answerDate")))}" />`;
      else if (type === "NUMBER") answer = `<input type="number" step="any" data-ans-number value="${esc(F(q, "answerNumber") ?? "")}" />`;
      else answer = `<textarea data-ans-text rows="2">${esc(F(q, "answerText") || "")}</textarea>`;
      const comment = editable && type !== "TEXT" ? `<input type="text" data-ans-text placeholder="Comment" value="${esc(type === "TEXT" ? "" : F(q, "answerText") || "")}" />` : "";
      const rating = F(q, "ratingCode") ? state.lk.badge("RESPONSE_RATING", F(q, "ratingCode")) : (F(q, "status") === "ANSWERED" ? '<span class="tprm-muted">Not rated</span>' : "");
      return `<tr class="en-q-row${F(q, "parentQuestionCode") ? " is-followup" : ""}" data-response="${esc(rid)}" data-type="${esc(type)}">
        <td><strong>${esc(F(q, "questionCode"))}</strong> ${esc(F(q, "questionText"))}${yes(F(q, "isMandatory")) ? " *" : ""}
          ${F(q, "guidance") ? `<div class="tprm-muted">${esc(F(q, "guidance"))}</div>` : ""}
          ${F(q, "sourceAuthority") ? `<div class="tprm-muted">Source: ${esc(F(q, "sourceAuthority"))}${F(q, "sourceReference") ? ", " + esc(F(q, "sourceReference")) : ""}${yes(F(q, "isRegulatory")) ? "" : " (not a regulatory requirement)"}</div>` : ""}</td>
        <td><div class="en-answer">${answer}${comment}</div>
          ${editable ? `<div class="tprm-actions" style="margin:6px 0 0">
            <select data-ans-respondent title="Answered by"><option value="THIRD_PARTY"${F(q, "respondentType") !== "INTERNAL" ? " selected" : ""}>Third party</option><option value="INTERNAL"${F(q, "respondentType") === "INTERNAL" ? " selected" : ""}>Internal</option></select>
            ${btn("answer-save", "fa-floppy-disk", "Save", { id: rid })}</div>` : ""}
          ${F(q, "answeredBy") ? `<div class="tprm-muted">${esc(F(q, "answeredBy"))}, ${esc(T.dateTime(F(q, "answeredDt")))}</div>` : ""}</td>
        <td>${rating}${F(q, "assessorComment") ? `<div class="tprm-muted">${esc(F(q, "assessorComment"))}</div>` : ""}${F(q, "reviewerComment") ? `<div class="tprm-muted">Reviewer: ${esc(F(q, "reviewerComment"))}</div>` : ""}
          ${editable && F(q, "status") !== "PENDING" ? btn("answer-rate", "fa-star", "Rate", { id: rid }) : ""}</td>
        <td>${btn("evidence-open", "fa-paperclip", `${evCount("RESPONSE", rid)}`, { kind: "RESPONSE", id: rid, title: F(q, "questionCode") }, yes(F(q, "evidenceExpected")) ? "Evidence expected" : "Evidence")}
          ${yes(F(q, "evidenceExpected")) ? '<div class="tprm-muted">expected</div>' : ""}${Number(F(q, "findingCount")) > 0 ? '<div class="tprm-alert">Finding</div>' : ""}</td></tr>`;
    };
    const sections = r.data.sections || [];
    const questions = r.data.questions || [];
    const qHtml = (r.data.questionnaires || []).map(qn => `
      <div class="tprm-subhead">${esc(F(qn, "templateName"))} <span class="tprm-muted">v${esc(F(qn, "versionNo"))}</span></div>
      ${sections.filter(s => String(F(s, "ddqId")) === String(F(qn, "ddqId"))).map(s => {
        const rows = questions.filter(q => String(F(q, "sectionId")) === String(F(s, "sectionId")) && String(F(q, "ddqId")) === String(F(qn, "ddqId"))).map(questionRow).join("");
        return rows ? `<h4 class="pm-dash-subhead">${esc(F(s, "title"))}</h4><div class="pm-table-wrap"><table>
          <thead><tr><th style="width:38%">Question</th><th>Answer</th><th>Rating</th><th>Evidence</th></tr></thead><tbody>${rows}</tbody></table></div>` : "";
      }).join("")}`).join("");
    const sgRows = (r.data.safeguards || []).filter(s => yes(F(s, "isApplicable")) || !open).map(s => `<tr>
        <td>${esc(F(s, "safeguardName"))}<div class="tprm-muted">${esc(state.lk.label("SAFEGUARD_CATEGORY", F(s, "categoryCode")) || "")}${yes(F(s, "isContractClause")) ? " - contractual" : ""}</div>
          ${F(s, "effectivenessCriteria") ? `<div class="tprm-muted">Effective when: ${esc(F(s, "effectivenessCriteria"))}</div>` : ""}</td>
        <td>${yes(F(s, "isApplicable")) ? esc(F(s, "existenceCode") || "--") : '<span class="tprm-muted">Not applicable</span>'}${F(s, "contractClauseRef") ? `<div class="tprm-muted">Clause ${esc(F(s, "contractClauseRef"))}</div>` : ""}</td>
        <td>${state.lk.badge("EFFECTIVENESS", F(s, "effectivenessCode")) || '<span class="tprm-muted">Not assessed</span>'}</td>
        <td>${yes(F(s, "isVerified")) ? `Verified <div class="tprm-muted">${esc(F(s, "verificationMethod") || "")}, ${esc(F(s, "verifiedByName") || "")}</div>` : '<span class="tprm-muted">Not verified</span>'}</td>
        <td>${btn("evidence-open", "fa-paperclip", `${evCount("SAFEGUARD", F(s, "sgAssessmentId"))}`, { kind: "SAFEGUARD", id: F(s, "sgAssessmentId"), title: F(s, "safeguardName") }, "Evidence")}
          ${editable ? btn("safeguard-edit", "fa-pen", "Assess", { id: F(s, "sgAssessmentId") }) : ""}</td></tr>`).join("");
    host.innerHTML = `
      <div class="tprm-info">${info([
        ["Round", `#${F(d, "ddNo")} ${F(d, "status")}`], ["Tier", state.lk.label("DD_TIER", F(d, "ddTierCode"))], ["Due", date(F(d, "dueDt"))],
        ["Assessor", F(d, "assessorName")], ["Evidence reviewer", F(d, "reviewerName")],
        ["Questions", `${F(d, "answeredQuestions")} of ${F(d, "applicableQuestions")} answered, ${F(d, "ratedQuestions")} rated`],
        ["Safeguards", `${F(d, "assessedSafeguards")} of ${F(d, "applicableSafeguards")} assessed, ${F(d, "verifiedSafeguards")} verified`],
        ["Summary", F(d, "summary")]
      ])}</div>
      <div class="tprm-actions">${start}${editable ? btn("dd-complete", "fa-check", "Complete due diligence", { id: F(d, "ddId") }, null, "primary") : ""}</div>
      ${qHtml || '<p class="tprm-note">No questionnaire applies.</p>'}
      <div class="tprm-subhead">Safeguards</div>
      <p class="tprm-note">A policy, certificate or clause alone does not reduce the risk: a safeguard counts once its effectiveness is verified by reviewed evidence, an assurance result, a test or the contract.</p>
      <div class="pm-table-wrap"><table><thead><tr><th style="width:38%">Safeguard</th><th>Exists</th><th>Effectiveness</th><th>Verification</th><th></th></tr></thead>
        <tbody>${sgRows || empty(5, "No safeguards.")}</tbody></table></div>`;
    renderFindingsAndResidual(host, false);
  }

  function renderFindingsAndResidual(host, append) {
    const d = state.dd || {};
    const findings = d.findings || [];
    const dims = d.dimensions || [];
    const fRow = f => {
      const st = F(f, "status");
      const openF = st === "OPEN" || st === "IN_PROGRESS";
      const actions = !canEdit() ? "" : (openF
        ? btn("finding-edit", "fa-pen", "", { id: F(f, "findingId") }, "Edit")
          + (st === "OPEN" ? btn("finding-action", "fa-play", "Start", { id: F(f, "findingId"), action: "START" }) : "")
          + btn("finding-action", "fa-check", "Close", { id: F(f, "findingId"), action: "CLOSE" })
          + (CAN_APPROVE ? btn("finding-action", "fa-stamp", "Waive", { id: F(f, "findingId"), action: "WAIVE" }) : "")
          + (F(f, "customGapId") ? "" : btn("finding-action", "fa-arrow-up-right-from-square", "To Gap Register", { id: F(f, "findingId"), action: "RAISE_GAP" }))
          + btn("finding-action", "fa-ban", "", { id: F(f, "findingId"), action: "CANCEL" }, "Cancel")
        : btn("finding-action", "fa-rotate-left", "Reopen", { id: F(f, "findingId"), action: "REOPEN" }));
      return `<tr>
        <td>${esc(F(f, "findingNumber"))}<div class="tprm-muted">${esc(F(f, "findingKind"))}${yes(F(f, "isAutomatic")) ? " (from a response)" : ""}</div></td>
        <td>${esc(F(f, "title"))}${F(f, "description") ? `<div class="tprm-muted">${esc(F(f, "description"))}</div>` : ""}
          ${F(f, "customGapId") ? `<div class="tprm-muted">Gap Register #${esc(F(f, "customGapId"))}</div>` : ""}</td>
        <td>${state.lk.badge("FINDING_SEVERITY", F(f, "severityCode"))}</td>
        <td>${esc(F(f, "ownerName") || "--")}</td>
        <td>${esc(date(F(f, "dueDt")) || "--")}${yes(F(f, "isOverdue")) ? ' <span class="tprm-alert">Overdue</span>' : ""}${F(f, "exceptionUntil") ? `<div class="tprm-muted">Exception until ${esc(date(F(f, "exceptionUntil")))}</div>` : ""}</td>
        <td>${esc(st)}${yes(F(f, "isMandatoryForActivation")) ? '<div class="tprm-muted">blocks activation</div>' : ""}</td>
        <td>${btn("evidence-open", "fa-paperclip", "", { kind: "FINDING", id: F(f, "findingId"), title: F(f, "findingNumber") }, "Evidence")}${actions}</td></tr>`;
    };
    const html = `
      <div class="tprm-subhead">Findings and remediation <span>${canEdit() ? btn("finding-new", "fa-plus", "Record finding") : ""}</span></div>
      <div class="pm-table-wrap"><table><thead><tr><th>Finding</th><th>Title</th><th>Severity</th><th>Owner</th><th>Due</th><th>Status</th><th></th></tr></thead>
        <tbody>${findings.map(fRow).join("") || empty(7, "No findings.")}</tbody></table></div>
      <div class="tprm-subhead">Residual risk <span>${canEdit() ? btn("residual-recalc", "fa-calculator", "Recalculate") : ""}</span></div>
      <p class="tprm-note">Residual = inherent reduced by the verified safeguards of each dimension, raised by open high and critical deficiencies, never below the model's floor.</p>
      <div class="pm-table-wrap"><table><thead><tr><th>Dimension</th><th>Inherent</th><th>Reduction %</th><th>Uplift %</th><th>Residual</th><th>Safeguards</th></tr></thead>
        <tbody>${dims.map(x => `<tr><td>${esc(F(x, "dimensionName"))}</td><td>${score(F(x, "inherentScore"))}</td><td>${score(F(x, "reductionPct"))}</td>
          <td>${score(F(x, "upliftPct"))}</td><td>${score(F(x, "residualScore"))}</td><td class="tprm-muted">${esc(F(x, "safeguardSummary") || "")}</td></tr>`).join("") || empty(6, "No inherent assessment yet.")}</tbody></table></div>`;
    host.insertAdjacentHTML("beforeend", html);
  }

  async function saveAnswer(responseId) {
    const tr = document.querySelector(`#enPanelDd tr[data-response="${responseId}"]`);
    const type = tr.dataset.type;
    const body = { organizationId: state.org, respondentType: tr.querySelector("[data-ans-respondent]")?.value || "THIRD_PARTY" };
    if (type === "MULTI") body.answerOptionCodes = [...tr.querySelectorAll("[data-ans-multi]:checked")].map(x => x.value).join(",") || null;
    else if (type === "YES_NO" || type === "SINGLE") body.answerOptionCodes = tr.querySelector("[data-ans-option]")?.value || null;
    else if (type === "DATE") body.answerDate = tr.querySelector("[data-ans-date]")?.value || null;
    else if (type === "NUMBER") body.answerNumber = num(tr.querySelector("[data-ans-number]")?.value);
    const text = tr.querySelector("[data-ans-text]")?.value.trim();
    if (text) body.answerText = text;
    const r = await api("POST", `/due-diligence/responses/${responseId}`, body);
    if (!r.ok) { show("enWsMessage", r.error); return; }
    show("enWsMessage", F(r.data.result, "result") === "SAVED_DEFICIENCY" ? "Saved. The answer indicates a deficiency: a finding was recorded." : "Answer saved.", "success");
    await reloadWorkspace();
  }

  // ------------------------------------------------------------------ evidence of one item
  async function openEvidence(kind, id, title) {
    state.evidenceTarget = { kind, id: Number(id), title };
    document.getElementById("enEvidenceTitle").textContent = `Evidence - ${title || ""}`;
    document.getElementById("enEvidenceNote").textContent =
      "Evidence comes from the Evidence Center (pinned to the version linked) or is an external reference. Another person than the one who added it accepts or rejects it.";
    hide("enEvidenceMessage");
    renderEvidence();
    document.getElementById("enEvidenceModal").hidden = false;
  }
  function renderEvidence() {
    const t = state.evidenceTarget;
    const rows = ((state.dd && state.dd.evidence) || []).filter(e => F(e, "targetKind") === t.kind && String(F(e, "targetId")) === String(t.id));
    const me = root.dataset.employeeId;
    const ddOpen = state.dd && (state.dd.header || [])[0] && F(state.dd.header[0], "status") === "IN_PROGRESS";
    const editable = canEdit() && (ddOpen || t.kind === "FINDING");
    document.getElementById("enEvidenceActions").innerHTML = editable
      ? btn("evidence-pick", "fa-box-archive", "Select from Evidence Center") + btn("evidence-external", "fa-link", "External reference") : "";
    document.getElementById("enEvidenceBody").innerHTML = rows.map(e => {
      const fileHref = F(e, "evidenceFileId")
        ? T.U(`/practice/api/evidence-center/files/${F(e, "evidenceFileId")}?organizationId=${state.org}`) : null;
      const review = F(e, "reviewStatus");
      const mine = me && String(F(e, "addedByEmployeeId")) === me;
      return `<tr>
        <td>${fileHref ? `<a href="${esc(fileHref)}" target="_blank" rel="noopener">${esc(F(e, "title"))}</a>` : esc(F(e, "title"))}
          ${F(e, "versionNo") ? ` <span class="tprm-muted">v${esc(F(e, "versionNo"))}</span>` : ""}${F(e, "note") ? `<div class="tprm-muted">${esc(F(e, "note"))}</div>` : ""}</td>
        <td>${F(e, "sourceKind") === "EXTERNAL" ? `External: ${esc(F(e, "externalReference"))}${F(e, "externalLocation") ? `<div class="tprm-muted">${esc(F(e, "externalLocation"))}</div>` : ""}` : "Evidence Center"}</td>
        <td>${esc([date(F(e, "validFrom")), date(F(e, "validTo"))].filter(Boolean).join(" to ") || "--")}</td>
        <td>${esc(review)}${F(e, "reviewedByName") ? `<div class="tprm-muted">${esc(F(e, "reviewedByName"))}${F(e, "reviewNote") ? ": " + esc(F(e, "reviewNote")) : ""}</div>` : ""}</td>
        <td>${esc(F(e, "addedByName") || "--")}</td>
        <td>${editable && review === "PENDING" && !mine && HAS_EMPLOYEE ? btn("evidence-review", "fa-check", "Accept", { id: F(e, "tprmEvidenceId"), action: "ACCEPT" }) + btn("evidence-review", "fa-xmark", "Reject", { id: F(e, "tprmEvidenceId"), action: "REJECT" }) : ""}
            ${editable ? btn("evidence-review", "fa-link-slash", "", { id: F(e, "tprmEvidenceId"), action: "REMOVE" }, "Remove") : ""}</td></tr>`;
    }).join("") || empty(6, "No evidence linked.");
  }
  async function afterEvidenceChange(message) {
    await reloadWorkspace();
    renderEvidence();
    if (message) show("enEvidenceMessage", message, "success");
  }

  // ------------------------------------------------------------------ step: decision
  async function renderDecision() {
    const host = document.getElementById("enPanelDecision");
    const r = await api("GET", `/engagements/${state.id}/decision?${qs({ organizationId: state.org })}`);
    if (!r.ok) { host.innerHTML = `<p class="pm-message">${esc(r.error)}</p>`; return; }
    state.decision = r.data;
    const p = (r.data.pack || [])[0] || {};
    const rule = (r.data.rule || [])[0];
    const decisions = r.data.decisions || [];
    const approvals = r.data.approvals || [];
    const pending = decisions.find(x => F(x, "status") === "PENDING");
    const chain = d => approvals.filter(a => String(F(a, "decisionId")) === String(F(d, "decisionId"))).map(a => `
      <div class="${yes(F(a, "isCurrent")) ? "is-current" : ""}"><strong>Level ${esc(F(a, "levelNo"))}</strong> ${esc(F(a, "requiredRoleName") || "Any approver")}
        <div>${esc(F(a, "status"))}${F(a, "approverName") ? ` - ${esc(F(a, "approverName"))}` : ""}${F(a, "onBehalfOfName") ? ` (for ${esc(F(a, "onBehalfOfName"))})` : ""}</div>
        ${F(a, "comment") ? `<div class="tprm-muted">${esc(F(a, "comment"))}</div>` : ""}</div>`).join("");
    const links = (r.data.riskLinks || []).map(l => `<li>${esc(F(l, "linkKind") === "RISK_CANDIDATE" ? "Risk candidate" : "Enterprise risk")} ${esc(F(l, "targetLabel"))} <span class="tprm-muted">${esc(F(l, "targetStatus") || "")}</span></li>`).join("");
    const canSubmit = yes(F(p, "canSubmit")) && canEdit();
    host.innerHTML = `
      <div class="tprm-subhead">Decision pack</div>
      <div class="tprm-info">${info([
        ["Inherent", T.band(F(p, "inherentBand"), F(p, "inherentBandColor"), F(p, "inherentScore")), true],
        ["Residual", T.band(F(p, "residualBand"), F(p, "residualBandColor"), F(p, "residualScore")), true],
        ["Criticality", state.lk.label("CRITICALITY", F(p, "criticalityCode"))], ["Due-diligence tier", state.lk.label("DD_TIER", F(p, "ddTierCode"))],
        ["Due diligence", F(p, "ddStatus")],
        ["Safeguards verified", `${F(p, "verifiedSafeguards") ?? 0} of ${F(p, "applicableSafeguards") ?? 0}`],
        ["Open findings", `${F(p, "openFindings") ?? 0} (${F(p, "openHighFindings") ?? 0} high or critical)`],
        ["Evidence awaiting review", F(p, "pendingEvidence")]
      ])}</div>
      ${rule ? `<div class="tprm-subhead">Approval path (${esc(F(rule, "ruleName"))})</div>
      <p class="tprm-note">${esc(F(rule, "approvalLevels"))} level(s): ${esc([F(rule, "level1RoleName"), F(rule, "level2RoleName"), F(rule, "level3RoleName")].filter(Boolean).slice(0, F(rule, "approvalLevels")).join(" -> ") || "any approver")}.
        ${yes(F(rule, "sodRequired")) ? "Segregation of duties applies: the requester and the assessors cannot approve, and each level needs a different person." : ""}
        ${F(rule, "maxAcceptanceMonths") ? ` Risk can be accepted for at most ${esc(F(rule, "maxAcceptanceMonths"))} months.` : ""}
        ${yes(F(rule, "escalateToRiskCentre")) ? " Escalation to the GRAC Risk Centre is recommended for this risk level." : ""}</p>` : '<p class="pm-message">No approval rule applies. Add one in TPRM Configuration.</p>'}
      <div class="tprm-actions">
        ${canSubmit ? btn("decision-submit", "fa-paper-plane", "Request decision", {}, null, "primary") : ""}
        ${pending && CAN_APPROVE && HAS_EMPLOYEE ? btn("decision-act", "fa-stamp", "Decide", { id: F(pending, "decisionId") }, null, "primary") : ""}
        ${pending && canEdit() ? btn("decision-withdraw", "fa-rotate-left", "Withdraw request", { id: F(pending, "decisionId") }) : ""}
      </div>
      ${pending && CAN_APPROVE && !HAS_EMPLOYEE ? '<p class="tprm-note">Deciding needs a sign-in linked to an employee.</p>' : ""}
      ${!canSubmit && !pending && F(p, "ddStatus") !== "COMPLETED" ? '<p class="tprm-note">A decision can be requested once due diligence is completed.</p>' : ""}
      ${decisions.map(d => `<div class="tprm-subhead">Decision ${esc(F(d, "decisionNo"))} - ${esc(F(d, "status"))}${F(d, "outcomeLabel") ? `: ${esc(F(d, "outcomeLabel"))}` : ""}</div>
        <div class="tprm-info">${info([
          ["Requested", `${T.dateTime(F(d, "submittedDt"))} by ${F(d, "submittedByName") || ""}`], ["Rule", F(d, "approvalRuleCode")],
          ["Residual at request", `${F(d, "residualScore") ?? "--"} ${F(d, "residualBandCode") || ""}`],
          ["Open findings at request", F(d, "openFindingsCount")], ["Rationale", F(d, "rationale")],
          ["Risk accepted", yes(F(d, "riskAccepted")) ? `Until ${date(F(d, "acceptanceUntil"))}` : "No"],
          ["Mandatory review", date(F(d, "mandatoryReviewDt"))], ["Decided", F(d, "decidedDt") ? `${T.dateTime(F(d, "decidedDt"))} by ${F(d, "decidedByName") || ""}` : ""]
        ])}</div><div class="en-chain">${chain(d)}</div>`).join("")}
      <div class="tprm-subhead">GRAC Risk Centre <span>${canEdit() ? btn("risk-escalate", "fa-arrow-up-right-from-square", "Escalate as a risk candidate") + btn("risk-link", "fa-link", "Link an enterprise risk") : ""}</span></div>
      <p class="tprm-note">Escalation is a deliberate choice: one candidate per engagement (a repeat returns the open one), never an automatic copy of every engagement risk.</p>
      ${links ? `<ul>${links}</ul>` : '<p class="tprm-muted">Not escalated or linked.</p>'}`;
  }

  async function decide(decisionId) {
    const d = state.decision;
    const outcomes = (d.outcomes || []).map(o => ({ value: F(o, "valueCode"), label: F(o, "label"), meaning: F(o, "meaningCode") }));
    const rule = (d.rule || [])[0];
    const delegations = (d.delegations || []).map(x => ({ value: F(x, "fromEmployeeId"), label: `${F(x, "fromEmployeeName")} (until ${date(F(x, "validTo"))})` }));
    const res = await T.form({
      title: "Decide", submitText: "Record decision", submitIcon: "fa-stamp", wide: true,
      intro: "Approve passes the request to the next approval level, or decides it at the last level. Reject and Return decide it now.",
      fields: [
        { name: "action", label: "Action", type: "select", required: true, blank: "Choose",
          options: [{ value: "APPROVE", label: "Approve" }, { value: "REJECT", label: "Reject" }, { value: "RETURN", label: "Return for more information" }] },
        { name: "outcomeCode", label: "Outcome (at the last level)", type: "select", options: outcomes.map(o => ({ value: o.value, label: o.label })) },
        { name: "rationale", label: "Rationale", type: "textarea", required: true, maxLength: 2000 },
        { name: "riskAccepted", label: "Accept the residual risk (time-bound)", type: "checkbox" },
        { name: "acceptanceUntil", label: "Risk accepted until", type: "date",
          help: rule && F(rule, "maxAcceptanceMonths") ? `At most ${F(rule, "maxAcceptanceMonths")} months.` : "" },
        { name: "mandatoryReviewDt", label: "Mandatory review date", type: "date" },
        { name: "conditions", label: "Conditions -- one per line: title | severity code | due date (yyyy-mm-dd)", type: "textarea", rows: 3,
          help: "Approval with conditions: each condition must be met before activation." },
        ...(delegations.length ? [{ name: "onBehalfOf", label: "Acting on behalf of (delegation)", type: "select", options: delegations }] : [])
      ],
      onSubmit: v => api("POST", `/decisions/${decisionId}/act`, {
        organizationId: state.org, action: v.action, outcomeCode: v.outcomeCode, rationale: v.rationale,
        riskAccepted: !!v.riskAccepted, acceptanceUntil: v.acceptanceUntil, mandatoryReviewDt: v.mandatoryReviewDt,
        conditionsJson: conditionsJson(v.conditions), onBehalfOfEmployeeId: num(v.onBehalfOf) })
    });
    if (!res) return;
    show("enWsMessage", F(res.result.data.result, "result") === "LEVEL_APPROVED" ? "Approved at this level; the next level decides." : "Decision recorded.", "success");
    await reloadWorkspace();
  }
  function conditionsJson(text) {
    const lines = String(text || "").split("\n").map(x => x.trim()).filter(Boolean);
    if (!lines.length) return null;
    return JSON.stringify(lines.map(l => { const [title, severity, due] = l.split("|").map(x => (x || "").trim()); return { title, severity: severity || null, dueDt: due || null }; }));
  }

  // ------------------------------------------------------------------ step: onboarding & monitoring
  async function renderOnboarding() {
    const host = document.getElementById("enPanelOnboard");
    const r = await api("GET", `/engagements/${state.id}/onboarding?${qs({ organizationId: state.org })}`);
    if (!r.ok) { host.innerHTML = `<p class="pm-message">${esc(r.error)}</p>`; return; }
    state.onboarding = r.data;
    const rd = (r.data.readiness || [])[0] || {};
    const rule = (r.data.reviewRule || [])[0];
    const stage = H("stageCode");
    const checkRows = items => items.map(i => {
      const st = F(i, "status");
      const live = (F(i, "phase") === "ONBOARDING" && stage === "ONBOARDING") || (F(i, "phase") === "EXIT" && stage === "EXITING");
      const acts = !live || !CAN_EDIT ? "" : (st === "PENDING"
        ? btn("check-action", "fa-check", "Done", { id: F(i, "itemId"), action: "DONE" })
          + (CAN_APPROVE ? btn("check-action", "fa-stamp", "Waive", { id: F(i, "itemId"), action: "WAIVE" }) : "")
          + (yes(F(i, "isMandatory")) ? "" : btn("check-action", "fa-minus", "N/A", { id: F(i, "itemId"), action: "NA" }))
        : btn("check-action", "fa-rotate-left", "Reopen", { id: F(i, "itemId"), action: "REOPEN" }));
      return `<tr><td>${esc(F(i, "checkLabel"))}${yes(F(i, "isMandatory")) ? " *" : ""}</td><td>${esc(st)}</td>
        <td>${esc(F(i, "note") || "")}${F(i, "evidenceReference") ? `<div class="tprm-muted">${esc(F(i, "evidenceReference"))}</div>` : ""}</td>
        <td>${esc(F(i, "completedByName") || "")}${F(i, "completedDt") ? `<div class="tprm-muted">${esc(T.dateTime(F(i, "completedDt")))}</div>` : ""}</td><td>${acts}</td></tr>`;
    }).join("");
    const devRows = (r.data.deviations || []).map(d => `<tr><td>${esc(F(d, "deviationKind"))}</td><td>${esc(kindLabel(F(d, "itemKind")))}: ${esc(F(d, "itemName"))}</td>
        <td>${yes(F(d, "isMaterial")) ? '<span class="tprm-alert">Material</span>' : ""}</td><td>${esc(F(d, "status"))}${F(d, "decisionNote") ? `<div class="tprm-muted">${esc(F(d, "decisionNote"))}</div>` : ""}</td>
        <td>${F(d, "status") === "OPEN" && CAN_EDIT ? (CAN_APPROVE ? btn("deviation-action", "fa-check", "Accept", { id: F(d, "deviationId"), action: "ACCEPT" }) : "")
            + btn("deviation-action", "fa-rotate", "Reassess", { id: F(d, "deviationId"), action: "REASSESS" }) : ""}</td></tr>`).join("");
    const revRows = (r.data.reviews || []).map(v => `<tr><td>${esc(F(v, "reviewNumber"))}</td><td>${esc(F(v, "reviewType"))}<div class="tprm-muted">${esc(state.lk.label("REVIEW_TRIGGER", F(v, "triggerCode")))}</div></td>
        <td>${esc(date(F(v, "dueDt")))}</td><td>${esc(F(v, "status"))}${F(v, "outcomeCode") ? ` - ${esc(F(v, "outcomeCode"))}` : ""}</td><td>${esc(F(v, "ownerName") || "--")}</td>
        <td><a class="pm-button small" href="${esc(T.U("/Practice/Index/tprm-reviews") + "?" + qs({ organizationId: state.org, engagementId: state.id, reviewId: F(v, "reviewId") }))}">Open</a></td></tr>`).join("");
    const lifecycle = [];
    if (CAN_EDIT) {
      if (["ACTIVE", "SUSPENDED"].includes(stage)) lifecycle.push(btn("lifecycle", "fa-arrows-rotate", "Renew", { action: "RENEW" }));
      if (["ACTIVE", "SUSPENDED", "ONBOARDING", "APPROVED"].includes(stage)) lifecycle.push(btn("lifecycle", "fa-pen-ruler", "Scope change", { action: "SCOPE_CHANGE" }));
    }
    if (CAN_APPROVE) {
      if (stage === "ACTIVE") lifecycle.push(btn("lifecycle", "fa-pause", "Suspend", { action: "SUSPEND" }));
      if (stage === "SUSPENDED") lifecycle.push(btn("lifecycle", "fa-play", "Resume", { action: "RESUME" }));
      if (["ACTIVE", "SUSPENDED", "APPROVED", "ONBOARDING"].includes(stage)) lifecycle.push(btn("lifecycle", "fa-door-open", "Start exit", { action: "START_EXIT" }));
      if (stage === "EXITING") lifecycle.push(btn("lifecycle", "fa-flag-checkered", "Complete exit", { action: "COMPLETE_EXIT" }, null, "primary"));
      if (["SCOPING", "RISK_ASSESSED", "DUE_DILIGENCE", "APPROVED", "ONBOARDING"].includes(stage)) lifecycle.push(btn("lifecycle", "fa-ban", "Cancel engagement", { action: "CANCEL" }));
    }
    host.innerHTML = `
      <div class="tprm-info">${info([
        ["Stage", T.stageLabel(stage)], ["Mandatory checks pending", F(rd, "pendingMandatoryChecks")], ["Open mandatory conditions", F(rd, "openMandatoryConditions")],
        ["Open material deviations", F(rd, "openMaterialDeviations")], ["Actual exposure compared", yes(F(rd, "exposureCompared")) ? "Yes" : "No"],
        ["Dependency links validated", `${F(rd, "validatedDependencyLinks") ?? 0} (${F(rd, "unvalidatedDependencyLinks") ?? 0} to validate)`],
        ["Actual start", date(F(rd, "actualStartDt"))], ["End", date(F(rd, "actualEndDt") || F(rd, "proposedEndDt"))],
        ["Last / next review", `${date(F(rd, "lastReviewDt")) || "--"} / ${date(F(rd, "nextReviewDt")) || "--"}`],
        ["Review rule", rule ? `${F(rule, "ruleName")}: every ${F(rule, "reviewFrequencyMonths")} months` : ""]
      ])}</div>
      <div class="tprm-actions">
        ${stage === "APPROVED" && CAN_EDIT ? btn("onboarding-start", "fa-play", "Start onboarding", {}, null, "primary") : ""}
        ${["ONBOARDING", "ACTIVE", "SUSPENDED"].includes(stage) && CAN_EDIT ? btn("exposure-confirm", "fa-equals", "Confirm proposed scope as actual") + btn("exposure-compare", "fa-code-compare", "Compare actual exposure") : ""}
        ${stage === "ONBOARDING" && CAN_APPROVE ? btn("activate", "fa-circle-check", "Activate", {}, null, "primary") : ""}
        ${!isClosed() && CAN_EDIT ? btn("review-raise", "fa-bell", "Raise review") : ""}
        ${lifecycle.join("")}
      </div>
      ${(r.data.onboardingChecks || []).length ? `<div class="tprm-subhead">Onboarding prerequisites</div>
      <div class="pm-table-wrap"><table><thead><tr><th>Check</th><th>Status</th><th>Note</th><th>By</th><th></th></tr></thead><tbody>${checkRows(r.data.onboardingChecks)}</tbody></table></div>` : ""}
      ${(r.data.conditions || []).length ? `<div class="tprm-subhead">Approval conditions</div>
      <div class="pm-table-wrap"><table><thead><tr><th>Condition</th><th>Severity</th><th>Owner</th><th>Due</th><th>Status</th></tr></thead><tbody>${
        r.data.conditions.map(c => `<tr><td>${esc(F(c, "findingNumber"))} ${esc(F(c, "title"))}</td><td>${state.lk.badge("FINDING_SEVERITY", F(c, "severityCode"))}</td><td>${esc(F(c, "ownerName") || "--")}</td><td>${esc(date(F(c, "dueDt")) || "--")}</td><td>${esc(F(c, "status"))}</td></tr>`).join("")}</tbody></table></div>
      <p class="tprm-note">Close a condition from Due diligence -> Findings once it is met.</p>` : ""}
      ${devRows ? `<div class="tprm-subhead">Deviations from the proposed exposure</div>
      <div class="pm-table-wrap"><table><thead><tr><th>Change</th><th>Item</th><th></th><th>Status</th><th></th></tr></thead><tbody>${devRows}</tbody></table></div>` : ""}
      ${(r.data.exitChecks || []).length ? `<div class="tprm-subhead">Exit checks</div>
      <div class="pm-table-wrap"><table><thead><tr><th>Check</th><th>Status</th><th>Note</th><th>By</th><th></th></tr></thead><tbody>${checkRows(r.data.exitChecks)}</tbody></table></div>` : ""}
      <div class="tprm-subhead">Reviews</div>
      <div class="pm-table-wrap"><table><thead><tr><th>Review</th><th>Type</th><th>Due</th><th>Status</th><th>Owner</th><th></th></tr></thead><tbody>${revRows || empty(6, "No reviews yet.")}</tbody></table></div>`;
  }

  // ------------------------------------------------------------------ history
  function renderHistory() {
    const e = state.eng;
    document.getElementById("enPanelHistory").innerHTML = `
      <div class="pm-table-wrap"><table><thead><tr><th>When</th><th>Event</th><th>Stage</th><th>Detail</th><th>By</th></tr></thead><tbody>${
        (e.history || []).map(h => `<tr><td>${esc(T.dateTime(F(h, "eventDt")))}</td><td>${esc(F(h, "eventCode"))}</td>
          <td>${F(h, "fromStageCode") || F(h, "toStageCode") ? `${esc(T.stageLabel(F(h, "fromStageCode")) || "")} -> ${esc(T.stageLabel(F(h, "toStageCode")) || "")}` : ""}</td>
          <td>${esc(F(h, "detail") || "")}</td><td>${esc(F(h, "actorName") || F(h, "actor") || "")}</td></tr>`).join("") || empty(5, "No history.")}</tbody></table></div>
      <div class="tprm-subhead">Exposure snapshots</div>
      <div class="pm-table-wrap"><table><thead><tr><th>When</th><th>Kind</th><th>Summary</th><th>By</th></tr></thead><tbody>${
        (e.snapshots || []).map(s => `<tr><td>${esc(T.dateTime(F(s, "takenDt")))}</td><td>${esc(F(s, "snapshotKind"))}</td>
          <td>${esc(snapshotSummary(F(s, "summaryJson")))}</td><td>${esc(F(s, "takenBy") || "")}</td></tr>`).join("") || empty(4, "No snapshots.")}</tbody></table></div>`;
  }
  function snapshotSummary(json) {
    try { return (JSON.parse(json || "[]") || []).map(x => `${x.key}: ${x.count}`).join(", "); } catch (_) { return ""; }
  }

  // ================================================================== actions
  async function act(name, data, el) {
    const id = Number(data.id);
    const post = async (path, body, okMessage) => {
      const r = await api("POST", path, { organizationId: state.org, ...(body || {}) });
      if (!r.ok) { show("enWsMessage", r.error); return null; }
      if (okMessage) show("enWsMessage", okMessage, "success");
      return r;
    };
    switch (name) {
      case "edit-engagement": return editEngagement(H("engagementId") ? state.eng.header[0] : null);
      // ---- scope
      case "scope-add": return addScopeItem(data.mode);
      case "scope-remove":
        if (!await T.confirm("Remove this scope item?", "Remove scope item", "Remove")) return;
        if (await post(`/engagements/scope/${id}/remove`)) await reloadWorkspace();
        return;
      case "discover": {
        const r = await api("GET", `/engagements/${state.id}/discovery?${qs({ organizationId: state.org })}`);
        if (!r.ok) { show("enWsMessage", r.error); return; }
        state.discovery = r.data;
        document.getElementById("enDiscovery").innerHTML = discoveryHtml(r.data);
        return;
      }
      case "discover-record": {
        const r = await post(`/engagements/${state.id}/discovery`, {}, "Discovery recorded. The records found are linked as discovered; validate the ones that apply.");
        if (r) { state.discovery = r.data; await reloadWorkspace(); }
        return;
      }
      case "link-add": return addLink();
      case "link-from-discovery":
        if (await post(`/engagements/${state.id}/links`, { linkKind: data.kind, targetId: id }, "Linked.")) { state.discovery = null; await reloadWorkspace(); }
        return;
      case "link-validate":
        if (await post(`/engagements/links/${id}/action`, { action: "VALIDATE" }, "Link validated.")) await reloadWorkspace();
        return;
      case "link-remove": {
        const note = await T.note("Why is this link removed?", "Remove link", "Remove");
        if (note === null) return;
        if (await post(`/engagements/links/${id}/action`, { action: "REMOVE", note }, "Link removed.")) await reloadWorkspace();
        return;
      }
      // ---- inherent risk
      case "risk-start": {
        const v = await T.form({ title: H("currentRiskAssessmentId") ? "Reassess inherent risk" : "Start inherent risk assessment", submitText: "Start",
          fields: [{ name: "triggerCode", label: "Trigger", type: "select", options: state.lk.options("REVIEW_TRIGGER"), blank: "Initial assessment" },
                   { name: "triggerNote", label: "Note", type: "textarea", rows: 2, maxLength: 1000 }] });
        if (!v) return;
        if (await post(`/engagements/${state.id}/risk-assessments`, v, "Assessment started. Factors are prefilled from the scope -- confirm each one.")) await reloadWorkspace();
        return;
      }
      case "risk-save":
        if (await post(`/risk-assessments/${F(state.risk.header[0], "assessmentId")}/answers`, { answersJson: JSON.stringify(riskAnswers()) }, "Answers saved.")) await reloadWorkspace();
        return;
      case "risk-complete": {
        const aid = F(state.risk.header[0], "assessmentId");
        if (!await post(`/risk-assessments/${aid}/answers`, { answersJson: JSON.stringify(riskAnswers()) })) return;
        if (await post(`/risk-assessments/${aid}/complete`, { discard: false }, "Inherent risk assessed.")) await reloadWorkspace();
        return;
      }
      case "risk-discard":
        if (!await T.confirm("Discard this assessment in progress? The completed one (if any) stays in force.", "Discard assessment", "Discard")) return;
        if (await post(`/risk-assessments/${F(state.risk.header[0], "assessmentId")}/complete`, { discard: true }, "Assessment discarded.")) await reloadWorkspace();
        return;
      // ---- due diligence
      case "dd-start": {
        const emp = state.lk.employeeOptions();
        const v = await T.form({ title: "Start due diligence", submitText: "Start",
          intro: "A new round supersedes the previous one; its answers, ratings and safeguard results are copied when asked, so only what changed needs work.",
          fields: [{ name: "dueDt", label: "Due date", type: "date" },
                   { name: "assessorEmployeeId", label: "Assessor", type: "select", options: emp, value: H("assessorEmployeeId") },
                   { name: "reviewerEmployeeId", label: "Evidence reviewer (a different person)", type: "select", options: emp },
                   { name: "copyPrevious", label: "Copy the previous round's answers", type: "checkbox", value: true }] });
        if (!v) return;
        if (await post(`/engagements/${state.id}/due-diligence`, { dueDt: v.dueDt, assessorEmployeeId: num(v.assessorEmployeeId), reviewerEmployeeId: num(v.reviewerEmployeeId), copyPrevious: !!v.copyPrevious }, "Due diligence started."))
          await reloadWorkspace();
        return;
      }
      case "dd-complete": {
        const summary = await T.note("Summarise the due-diligence result.", "Complete due diligence", "Complete");
        if (summary === null) return;
        if (await post(`/due-diligence/${id}/complete`, { summary }, "Due diligence completed; residual risk recalculated.")) await reloadWorkspace();
        return;
      }
      case "answer-save": return saveAnswer(id);
      case "answer-rate": {
        const q = (state.dd.questions || []).find(x => String(F(x, "responseId")) === String(id));
        const v = await T.form({ title: `Rate ${F(q, "questionCode")}`, submitText: "Rate",
          fields: [{ name: "ratingCode", label: "Rating", type: "select", options: state.lk.options("RESPONSE_RATING"), value: F(q, "ratingCode"), required: true },
                   { name: "assessorComment", label: "Assessor comment", type: "textarea", rows: 2, maxLength: 2000, value: F(q, "assessorComment") },
                   { name: "reviewerComment", label: "Reviewer comment", type: "textarea", rows: 2, maxLength: 2000, value: F(q, "reviewerComment") }] });
        if (!v) return;
        if (await post(`/due-diligence/responses/${id}/rate`, v, "Rated.")) await reloadWorkspace();
        return;
      }
      case "safeguard-edit": {
        const s = (state.dd.safeguards || []).find(x => String(F(x, "sgAssessmentId")) === String(id));
        const v = await T.form({ title: F(s, "safeguardName"), submitText: "Save", wide: true,
          intro: F(s, "effectivenessCriteria") ? `Effective when: ${F(s, "effectivenessCriteria")}` : "",
          fields: [
            { name: "isApplicable", label: "Applies to this engagement", type: "checkbox", value: F(s, "isApplicable") },
            { name: "existenceCode", label: "Does it exist?", type: "select", value: F(s, "existenceCode"),
              options: [{ value: "EXISTS", label: "Exists" }, { value: "PARTIAL", label: "Partially" }, { value: "MISSING", label: "Missing" }, { value: "UNKNOWN", label: "Unknown" }] },
            ...(yes(F(s, "isContractClause")) ? [{ name: "contractClauseRef", label: "Contract clause reference", maxLength: 300, value: F(s, "contractClauseRef") }] : []),
            { name: "effectivenessCode", label: "Effectiveness", type: "select", options: state.lk.options("EFFECTIVENESS"), value: F(s, "effectivenessCode") },
            { name: "verificationMethod", label: "Verified by", type: "select", value: F(s, "verificationMethod"),
              options: [{ value: "EVIDENCE_REVIEW", label: "Reviewing accepted evidence" }, { value: "ASSURANCE_RESULT", label: "An assurance result" },
                        { value: "TESTING", label: "Testing" }, { value: "CONTRACT_REVIEW", label: "Contract review" }, { value: "ATTESTATION_ONLY", label: "Attestation only (does not verify)" }] },
            { name: "verify", label: "Mark as verified (effective / partially effective only)", type: "checkbox", value: F(s, "isVerified") },
            { name: "verificationNote", label: "What was checked", type: "textarea", rows: 2, maxLength: 2000, value: F(s, "verificationNote") },
            { name: "comment", label: "Comment", type: "textarea", rows: 2, maxLength: 2000, value: F(s, "comment") }] });
        if (!v) return;
        const r = await post(`/due-diligence/safeguards/${id}`, { ...v, isApplicable: !!v.isApplicable, verify: !!v.verify });
        if (r) { show("enWsMessage", F(r.data.result, "result") === "VERIFIED" ? "Safeguard verified." : "Safeguard saved.", "success"); await reloadWorkspace(); }
        return;
      }
      case "evidence-open": return openEvidence(data.kind, id, data.title);
      case "evidence-pick": {
        const t = state.evidenceTarget;
        if (!window.gracEvidencePicker) return;
        const out = await window.gracEvidencePicker.open({
          context: `Evidence for ${t.title || t.kind}`,
          load: async ({ search, pageNumber, pageSize }) => {
            const r = await api("GET", `/evidence/candidates?${qs({ organizationId: state.org, search, pageNumber, pageSize })}`);
            return r.ok ? { ok: true, rows: r.data.data || [], totalRows: r.data.totalRows } : { ok: false, error: r.error };
          },
          link: async row => {
            const r = await api("POST", `/engagements/${state.id}/evidence`, { organizationId: state.org, targetKind: t.kind, targetId: t.id,
              sourceKind: "EVIDENCE_CENTER", evidenceItemId: F(row, "evidenceItemId") });
            return r.ok ? { ok: true, message: "Evidence linked." } : { ok: false, error: r.error };
          }
        });
        if (out && out.linked) await afterEvidenceChange(out.message);
        return;
      }
      case "evidence-external": {
        const t = state.evidenceTarget;
        const v = await T.form({ title: "External evidence reference", submitText: "Add",
          fields: [{ name: "externalReference", label: "Reference (report, document number, link)", required: true, maxLength: 400 },
                   { name: "externalLocation", label: "Where it is held", maxLength: 1000 },
                   { name: "title", label: "Title", maxLength: 300 },
                   { name: "evidenceRequirementCode", label: "Evidence requirement", type: "select",
                     options: state.lk.libraryItems("EVIDENCE_REQUIREMENT").map(x => ({ value: F(x, "itemCode"), label: F(x, "itemName") })) },
                   { name: "validFrom", label: "Valid from", type: "date" }, { name: "validTo", label: "Valid to", type: "date" },
                   { name: "note", label: "Note", type: "textarea", rows: 2, maxLength: 1000 }],
          onSubmit: v => api("POST", `/engagements/${state.id}/evidence`, { organizationId: state.org, targetKind: t.kind, targetId: t.id, sourceKind: "EXTERNAL", ...v }) });
        if (v) await afterEvidenceChange("Evidence reference added.");
        return;
      }
      case "evidence-review": {
        let note = null;
        if (data.action !== "ACCEPT") {
          note = await T.note(data.action === "REJECT" ? "Why is the evidence rejected?" : "Why is the evidence removed?", "Evidence", data.action === "REJECT" ? "Reject" : "Remove");
          if (note === null) return;
        }
        const r = await api("POST", `/evidence/${id}/review`, { organizationId: state.org, action: data.action, note });
        if (!r.ok) { show("enEvidenceMessage", r.error); return; }
        await afterEvidenceChange(data.action === "ACCEPT" ? "Accepted." : data.action === "REJECT" ? "Rejected." : "Removed.");
        return;
      }
      case "finding-new": return editFinding(null);
      case "finding-edit": return editFinding((state.dd.findings || []).find(f => String(F(f, "findingId")) === String(id)));
      case "finding-action": {
        let note = null;
        if (["CLOSE", "WAIVE", "CANCEL", "REOPEN"].includes(data.action)) {
          note = await T.note({ CLOSE: "How was it remediated?", WAIVE: "Why is it accepted without remediation?", CANCEL: "Why is it cancelled?", REOPEN: "Why is it reopened?" }[data.action],
            "Finding", { CLOSE: "Close", WAIVE: "Waive", CANCEL: "Cancel finding", REOPEN: "Reopen" }[data.action]);
          if (note === null) return;
        } else if (data.action === "RAISE_GAP" && !await T.confirm("Raise this finding in the GRAC Gap Register? It is tracked there from now on.", "Gap Register", "Raise gap")) return;
        if (await post(`/findings/${id}/action`, { action: data.action, note }, "Done.")) await reloadWorkspace();
        return;
      }
      case "residual-recalc":
        if (await post(`/engagements/${state.id}/residual`, {}, "Residual risk recalculated.")) await reloadWorkspace();
        return;
      // ---- decision
      case "decision-submit": {
        const note = await T.note("Note for the approvers (what they should know).", "Request decision", "Request");
        if (note === null) return;
        if (await post(`/engagements/${state.id}/decision/submit`, { submissionNote: note }, "Decision requested.")) await reloadWorkspace();
        return;
      }
      case "decision-act": return decide(id);
      case "decision-withdraw": {
        const note = await T.note("Why is the request withdrawn?", "Withdraw request", "Withdraw");
        if (note === null) return;
        if (await post(`/decisions/${id}/withdraw`, { note }, "Request withdrawn.")) await reloadWorkspace();
        return;
      }
      case "risk-escalate": {
        const v = await T.form({ title: "Escalate to the GRAC Risk Centre", submitText: "Escalate",
          fields: [{ name: "candidateTitle", label: "Risk candidate title", maxLength: 300, value: `Third-party risk: ${H("thirdPartyName")} - ${H("engagementTitle")}` },
                   { name: "summary", label: "Summary", type: "textarea", rows: 4 }] });
        if (!v) return;
        if (await post(`/engagements/${state.id}/risk-centre`, { mode: "ESCALATE", ...v }, "Escalated. The Risk Centre analyses the candidate.")) await reloadWorkspace();
        return;
      }
      case "risk-link": {
        let risks = (state.discovery?.risks || []).map(x => ({ value: F(x, "riskRegisterId"), label: `${F(x, "riskNumber")} ${F(x, "riskTitle")}` }));
        const v = await T.form({ title: "Link an enterprise risk", submitText: "Link",
          intro: risks.length ? "" : "Run Discover on Scope & exposure to list the risks already related to this third party, or give the risk register id.",
          fields: [risks.length ? { name: "riskRegisterId", label: "Enterprise risk", type: "select", options: risks, required: true }
                                : { name: "riskRegisterId", label: "Risk register id", type: "number", min: 1, required: true },
                   { name: "summary", label: "Note", type: "textarea", rows: 2 }] });
        if (!v) return;
        if (await post(`/engagements/${state.id}/risk-centre`, { mode: "LINK", riskRegisterId: num(v.riskRegisterId), summary: v.summary }, "Linked.")) await reloadWorkspace();
        return;
      }
      // ---- onboarding & monitoring
      case "onboarding-start":
        if (await post(`/engagements/${state.id}/onboarding/start`, {}, "Onboarding started.")) await reloadWorkspace();
        return;
      case "check-action": {
        let body = { action: data.action };
        if (data.action === "DONE") {
          const v = await T.form({ title: "Check done", submitText: "Done", fields: [
            { name: "note", label: "Note", type: "textarea", rows: 2, maxLength: 1000 }, { name: "evidenceReference", label: "Evidence reference", maxLength: 400 }] });
          if (!v) return;
          body = { ...body, ...v };
        } else if (data.action === "WAIVE") {
          const note = await T.note("Why is this check formally waived?", "Waive check", "Waive");
          if (note === null) return;
          body.note = note;
        }
        if (await post(`/onboarding/items/${id}/action`, body, "Saved.")) await reloadWorkspace();
        return;
      }
      case "exposure-confirm":
      case "exposure-compare": {
        const r = await post(`/engagements/${state.id}/exposure/compare`, { confirmProposed: name === "exposure-confirm" });
        if (r) { const x = r.data.result || {}; show("enWsMessage", `Compared: ${F(x, "deviationCount") ?? 0} deviation(s), ${F(x, "materialCount") ?? 0} material.`, "success"); await reloadWorkspace(); }
        return;
      }
      case "deviation-action": {
        const note = await T.note(data.action === "ACCEPT" ? "Why does this deviation not change the risk?" : "What needs reassessing?", "Deviation", data.action === "ACCEPT" ? "Accept" : "Reassess");
        if (note === null) return;
        if (await post(`/deviations/${id}/action`, { action: data.action, note }, "Saved.")) await reloadWorkspace();
        return;
      }
      case "activate": {
        const v = await T.form({ title: "Activate engagement", submitText: "Activate", submitIcon: "fa-circle-check",
          intro: "Every mandatory prerequisite and condition must be met or formally waived, and the actual exposure compared.",
          fields: [{ name: "actualStartDt", label: "Actual start", type: "date" }, { name: "note", label: "Note", type: "textarea", rows: 2, maxLength: 1000 }] });
        if (!v) return;
        if (await post(`/engagements/${state.id}/activate`, v, "Engagement activated.")) await reloadWorkspace();
        return;
      }
      case "lifecycle": {
        const labels = { SUSPEND: "Suspend", RESUME: "Resume", RENEW: "Renew", SCOPE_CHANGE: "Record a material scope change", START_EXIT: "Start exit", COMPLETE_EXIT: "Complete exit", CANCEL: "Cancel engagement" };
        const v = await T.form({ title: labels[data.action], submitText: labels[data.action],
          intro: data.action === "SCOPE_CHANGE" ? "The engagement is flagged for reassessment and a triggered review is raised."
            : data.action === "START_EXIT" ? "Exit checks (data return, deletion evidence, access revocation, dependency deactivation) are created; the exit closes when the mandatory ones are done or waived." : "",
          fields: [...(data.action === "RENEW" ? [{ name: "newEndDt", label: "New end date", type: "date", required: true }] : []),
                   { name: "reason", label: "Reason", type: "textarea", required: true, maxLength: 1000 }] });
        if (!v) return;
        if (await post(`/engagements/${state.id}/lifecycle`, { action: data.action, ...v }, "Done.")) await reloadWorkspace();
        return;
      }
      case "review-raise": {
        const v = await T.form({ title: "Raise a review", submitText: "Raise",
          fields: [{ name: "triggerCode", label: "Trigger", type: "select", options: state.lk.options("REVIEW_TRIGGER"), required: true },
                   { name: "triggerDetail", label: "What happened", type: "textarea", maxLength: 2000 },
                   { name: "dueDt", label: "Due", type: "date" },
                   { name: "ownerEmployeeId", label: "Owner", type: "select", options: state.lk.employeeOptions() },
                   ...T.customFields(state.lk, "REVIEW", [])] });
        if (!v) return;
        if (await post(`/engagements/${state.id}/reviews`, { triggerCode: v.triggerCode, triggerDetail: v.triggerDetail, dueDt: v.dueDt,
          ownerEmployeeId: num(v.ownerEmployeeId), customJson: T.customJson(v) }, "Review raised.")) await reloadWorkspace();
        return;
      }
      default: return;
    }
  }

  async function editFinding(f) {
    const lk = state.lk;
    const res = await T.form({
      title: f ? `Edit ${F(f, "findingNumber")}` : "Record finding", submitText: "Save", wide: true,
      fields: [
        { name: "findingKind", label: "Type", type: "select", required: true, value: f ? F(f, "findingKind") : "DEFICIENCY", blank: false,
          options: [{ value: "DEFICIENCY", label: "Deficiency" }, { value: "CONDITION", label: "Condition (before activation)" }, { value: "EXCEPTION", label: "Exception (time-bound)" }] },
        { name: "severityCode", label: "Severity", type: "select", options: lk.options("FINDING_SEVERITY"), value: f ? F(f, "severityCode") : "", required: true },
        { name: "title", label: "Title", required: true, maxLength: 300, value: f ? F(f, "title") : "", full: true },
        { name: "description", label: "Description", type: "textarea", maxLength: 2000, value: f ? F(f, "description") : "" },
        { name: "dimensionCode", label: "Risk dimension", type: "select", options: lk.dimensions.map(d => ({ value: F(d, "dimensionCode"), label: F(d, "dimensionName") })), value: f ? F(f, "dimensionCode") : "" },
        { name: "treatmentActionCode", label: "Treatment", type: "select", options: lk.libraryItems("TREATMENT_ACTION").map(x => ({ value: F(x, "itemCode"), label: F(x, "itemName") })), value: f ? F(f, "treatmentActionCode") : "" },
        { name: "ownerEmployeeId", label: "Owner", type: "select", options: lk.employeeOptions(), value: f ? F(f, "ownerEmployeeId") : "" },
        { name: "dueDt", label: "Due", type: "date", value: f ? F(f, "dueDt") : "" },
        { name: "exceptionUntil", label: "Exception until", type: "date", value: f ? F(f, "exceptionUntil") : "" },
        { name: "isMandatoryForActivation", label: "Must be closed before activation", type: "checkbox", value: f ? F(f, "isMandatoryForActivation") : false },
        ...T.customFields(lk, "FINDING", [])
      ],
      onSubmit: v => api("POST", `/engagements/${state.id}/findings`, {
        organizationId: state.org, findingId: f ? F(f, "findingId") : null, findingKind: v.findingKind, title: v.title, description: v.description,
        severityCode: v.severityCode, dimensionCode: v.dimensionCode, treatmentActionCode: v.treatmentActionCode, ownerEmployeeId: num(v.ownerEmployeeId),
        dueDt: v.dueDt, isMandatoryForActivation: !!v.isMandatoryForActivation, exceptionUntil: v.exceptionUntil, customJson: T.customJson(v),
        expectedRecordVersion: f ? F(f, "recordVersion") : null })
    });
    if (res) { show("enWsMessage", "Finding saved.", "success"); await reloadWorkspace(); }
  }

  // ================================================================== helpers
  function btn(action, icon, text, data, title, kind) {
    const attrs = Object.entries(data || {}).map(([k, v]) => ` data-${k}="${esc(v)}"`).join("");
    return `<button type="button" class="pm-button small${kind ? " " + kind : ""}" data-act="${esc(action)}"${attrs}${title ? ` title="${esc(title)}" aria-label="${esc(title)}"` : ""}>`
      + `<i class="fa-solid ${esc(icon)}" aria-hidden="true"></i>${text ? " " + esc(text) : ""}</button>`;
  }
  function score(v) { return v === null || v === undefined ? "--" : esc(Number(v).toFixed(1)); }
  function num(v) { return v === null || v === undefined || v === "" || isNaN(Number(v)) ? null : Number(v); }
  function val(id) { return (document.getElementById(id).value || "").trim(); }
})();
