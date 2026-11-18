// =====================================================================
// Engagement Management (migrations 486-490; 522 -- CR 2 section 5).
// Loaded by tprm-engagements.cshtml. The list, the engagement page (initial
// form / edit), the Scope & Exposure page, and the workspace of one
// engagement (BRD steps 2-5 + lifecycle).
// Backend: practice/api/tprm (TprmController -> sp_tprm_*); docs/tprm.md
// section 9 lists every endpoint. Rows are the procedures' columns.
//
//   list        GET engagements
//   pages       POST engagements (enEditor: the CR 2 5.1 initial form, edit)
//               POST engagements/{id}/exposure (enExposure: gating questions,
//               the dimensions that apply, the proposed scope as one set)
//   workspace   GET engagements/{id} (header, scope, links, snapshots,
//               history, customValues, dimensions); each step loads its own
//               data when opened:
//     Scope     GET engagements/{id}/discovery (preview), POST ... (record)
//               POST engagements/{id}/scope, engagements/scope/{id}/remove
//               (ACTUAL items only), engagements/{id}/links,
//               engagements/links/{id}/action
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
    // 524 / 525: a link onto one engagement (TP Risk Register, Vendor
    // Registry, Reviews, dashboards) carries it in the encrypted navigation
    // code (?code=), never as ?engagementId=; Vendor Registry -> New
    // engagement carries the vendor the same way (TprmThirdParty).
    const ctx = await T.navigationContext("tprm-engagements");
    state.org = await T.orgs("enOrg", ctx?.organizationId);
    await loadOrg();
    const q = new URLSearchParams(window.location.search);
    // Dashboard drill (490): stage / band / criticality / attention.
    if (q.get("stage")) preselect("enStageFilter", q.get("stage"));
    if (q.get("band")) preselect("enBandFilter", q.get("band"));
    if (q.get("criticality")) preselect("enCriticalityFilter", q.get("criticality"));
    if (q.get("attention")) preselect("enAttentionFilter", q.get("attention"));
    if (q.get("applicability")) preselect("enApplicabilityFilter", q.get("applicability"));   // 525 dashboard drill
    if (state.drill?.active || q.get("stage") || q.get("band") || q.get("criticality") || q.get("attention") || q.get("applicability"))
      window.__pmDrill?.banner(ensureBanner(), { ...(state.drill || {}), active: true, label: q.get("drillLabel") || "a dashboard selection" });
    await refreshList();
    if (ctx?.error) show("enMessage", ctx.error);
    const id = ctx?.filterType === "TprmEngagement" ? ctx.filterId : null;
    if (id > 0 && state.org) openWorkspace(id);
    const tp = ctx?.filterType === "TprmThirdParty" ? ctx.filterId : null;
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
    ["enStageFilter", "enBandFilter", "enCriticalityFilter", "enAttentionFilter", "enApplicabilityFilter"].forEach(id =>
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
    if (!state.org) { body.innerHTML = empty(9, "Select an organization."); state.pager?.clear(); return; }
    body.innerHTML = empty(9, "Loading...");
    const res = await api("GET", `/engagements?${qs({
      organizationId: state.org, search: val("enSearch"), stageCode: val("enStageFilter"), bandCode: val("enBandFilter"),
      criticalityCode: val("enCriticalityFilter"), attention: val("enAttentionFilter"), applicabilityStatus: val("enApplicabilityFilter"),
      pageNumber: state.pager ? state.pager.page() : 1, pageSize: state.pager ? state.pager.size() : 25 })}`);
    if (!res.ok) { body.innerHTML = empty(9, res.error); state.pager?.clear(); return; }
    const rows = res.data.data || [];
    state.pager?.setTotal(res.data.totalRows, rows.length);
    body.innerHTML = rows.map(r => `<tr data-en-row="${esc(F(r, "engagementId"))}">
        <td>${esc(F(r, "engagementCode"))}${yes(F(r, "isSample")) ? ' <span class="pm-badge tprm-sample">Sample</span>' : ""}</td>
        <td>${esc(F(r, "engagementTitle"))}<div class="tprm-muted">${esc(F(r, "serviceCategory") || "")}</div>
            ${yes(F(r, "reassessmentRequired")) ? '<div class="tprm-alert">Reassessment required</div>' : ""}</td>
        <td>${esc(F(r, "thirdPartyCode"))} ${esc(F(r, "thirdPartyName"))}</td>
        <td>${esc(T.stageLabel(F(r, "stageCode")))}</td>
        <td>${esc(applicabilityLabel(F(r, "applicabilityStatus")))}${F(r, "screeningClassification") ? `<div>${classBadge(F(r, "screeningClassification"))}</div>` : ""}</td>
        <td>${T.badge(F(r, "criticality"), F(r, "criticalityColor")) || "--"}</td>
        <td>${F(r, "residualBandCode")
              ? `${T.band(F(r, "residualBand"), F(r, "residualBandColor"), F(r, "residualScore"))}<div class="tprm-muted">residual</div>`
              : `${T.band(F(r, "inherentBand"), F(r, "inherentBandColor"), F(r, "inherentScore"))}${F(r, "inherentBandCode") ? '<div class="tprm-muted">inherent</div>' : ""}`}</td>
        <td>${esc(date(F(r, "nextReviewDt")) || "--")}</td>
        <td>${esc(F(r, "businessOwnerName") || "--")}</td>
      </tr>`).join("") || empty(9, "No engagements match.");
  }

  // ================================================================== create / edit
  // Engagement page (enEditor), POST engagements -- CR 2 5.1: the initial
  // information (all of it mandatory except the proposed end date). The
  // service category and relationship owner default from the vendor and stay
  // editable. Editing adds the administrative fields. A new engagement then
  // goes straight to Scope & Exposure.
  async function editEngagement(eng, forThirdPartyId) {
    const lk = state.lk;
    const h = eng || {};
    let vendors = [];
    if (!eng) {
      // 522: an engagement is opened for an Active vendor only.
      const r = await api("GET", `/third-parties?${qs({ organizationId: state.org, pageNumber: 1, pageSize: 200 })}`);
      vendors = r.ok ? (r.data.data || []).filter(x => F(x, "statusMeaning") === "ACTIVE") : [];
      if (!vendors.length) { show("enMessage", "Register the vendor first (Vendor Registry). Engagements are opened for active vendors."); return; }
    }
    const vendorOf = id => vendors.find(x => String(F(x, "thirdPartyId")) === String(id));
    const first = forThirdPartyId ? vendorOf(forThirdPartyId) : null;
    const emp = lk.employeeOptions();
    const fields = [
      ...(eng ? [] : [{ name: "thirdPartyId", label: "Vendor", type: "select", required: true, value: first ? F(first, "thirdPartyId") : "",
                        options: vendors.map(x => ({ value: F(x, "thirdPartyId"), label: `${F(x, "thirdPartyCode")} - ${F(x, "legalName")}` })) }]),
      { name: "engagementTitle", label: "Engagement name", required: true, maxLength: 250, value: F(h, "engagementTitle"), full: !!eng },
      { name: "serviceCategoryCode", label: "Service category", type: "select", options: lk.options("SERVICE_CATEGORY"), required: true,
        value: eng ? F(h, "serviceCategoryCode") : (first ? F(first, "serviceCategoryCode") : ""), help: "Defaults from the vendor; change it for this engagement if needed." },
      { name: "engagementTypeCode", label: "Engagement type", type: "select", options: lk.options("ENGAGEMENT_TYPE"), value: F(h, "engagementTypeCode"), required: true },
      { name: "serviceModelCode", label: "Service model", type: "select", options: lk.options("SERVICE_MODEL"), value: F(h, "serviceModelCode"), required: true },
      { name: "serviceRecipient", label: "Service recipient", maxLength: 250, value: F(h, "serviceRecipient"), required: true,
        help: "The business unit or entity that receives the service." },
      { name: "deliveryLocations", label: "Delivery location", maxLength: 1000, value: F(h, "deliveryLocations"), required: true,
        help: "Countries / sites from which the service is delivered." },
      { name: "relationshipOwnerEmployeeId", label: "Relationship owner", type: "select", options: emp, required: true,
        value: eng ? F(h, "relationshipOwnerEmployeeId") : (first ? F(first, "relationshipOwnerEmployeeId") : "") },
      { name: "proposedStartDt", label: "Proposed start date", type: "date", value: F(h, "proposedStartDt"), required: true },
      { name: "proposedEndDt", label: "Proposed end date", type: "date", value: F(h, "proposedEndDt") },
      { name: "serviceDescription", label: "Service description", type: "textarea", maxLength: 2000, value: F(h, "serviceDescription"), required: true },
      { name: "businessPurpose", label: "Business purpose", type: "textarea", rows: 2, maxLength: 1000, value: F(h, "businessPurpose"), required: true },
      ...(eng ? [
        { type: "section", label: "Administration", name: "_adm" },
        { name: "businessOwnerEmployeeId", label: "Business owner", type: "select", options: emp, value: F(h, "businessOwnerEmployeeId") },
        { name: "assessorEmployeeId", label: "Due-diligence assessor", type: "select", options: emp, value: F(h, "assessorEmployeeId") },
        { name: "isExisting", label: "Existing relationship (already in place)", type: "checkbox", value: F(h, "isExisting") },
        { name: "actualStartDt", label: "Actual start", type: "date", value: F(h, "actualStartDt") },
        { name: "actualEndDt", label: "Actual end", type: "date", value: F(h, "actualEndDt") },
        { name: "scopeDescription", label: "Scope description", type: "textarea", maxLength: 2000, value: F(h, "scopeDescription") },
        { name: "notes", label: "Notes", type: "textarea", rows: 2, value: F(h, "notes") }
      ] : []),
      ...T.customFields(lk, "ENGAGEMENT", eng ? (state.eng.customValues || []) : [])
    ];
    const res = await T.form({
      page: "enEditor", onOpen: () => {
        swapPage(true);
        // The vendor's primary category and owner fill the empty fields when
        // the vendor is chosen.
        const sel = document.querySelector('#enEditor [data-tf="thirdPartyId"]');
        sel?.addEventListener("change", () => {
          const v = vendorOf(sel.value);
          if (!v) return;
          const cat = document.querySelector('#enEditor [data-tf="serviceCategoryCode"]');
          const owner = document.querySelector('#enEditor [data-tf="relationshipOwnerEmployeeId"]');
          if (cat && !cat.value) cat.value = F(v, "serviceCategoryCode") || "";
          if (owner && !owner.value && F(v, "relationshipOwnerEmployeeId") != null) owner.value = String(F(v, "relationshipOwnerEmployeeId"));
        });
      }, onClose: () => swapPage(false),
      title: eng ? `Edit ${F(h, "engagementCode")} - ${F(h, "engagementTitle")}` : "New engagement", submitText: eng ? "Save" : "Create",
      intro: eng
        ? (["APPROVED", "ONBOARDING", "ACTIVE", "SUSPENDED"].includes(F(h, "stageCode"))
          ? "A change of service model or delivery location on an approved or live engagement is a material change: it is recorded and the engagement is flagged for reassessment." : "")
        : "The initial information of the engagement. Its scope and exposure are asked next, on the Scope & Exposure page -- only the parts that apply to this service.",
      fields,
      validate: v => v.proposedEndDt && v.proposedStartDt && v.proposedEndDt < v.proposedStartDt ? "The proposed end date is before the start date." : null,
      onSubmit: async v => {
        const r = await api("POST", "/engagements", {
          organizationId: state.org, engagementId: eng ? F(h, "engagementId") : null,
          thirdPartyId: eng ? F(h, "thirdPartyId") : Number(v.thirdPartyId),
          engagementTitle: v.engagementTitle, serviceCategoryCode: v.serviceCategoryCode, serviceDescription: v.serviceDescription,
          businessPurpose: v.businessPurpose, serviceRecipient: v.serviceRecipient, engagementTypeCode: v.engagementTypeCode,
          serviceModelCode: v.serviceModelCode, deliveryLocations: v.deliveryLocations, proposedStartDt: v.proposedStartDt,
          proposedEndDt: v.proposedEndDt, relationshipOwnerEmployeeId: num(v.relationshipOwnerEmployeeId),
          ...(eng ? {
            scopeDescription: v.scopeDescription, isExisting: !!v.isExisting, businessOwnerEmployeeId: num(v.businessOwnerEmployeeId),
            assessorEmployeeId: num(v.assessorEmployeeId), actualStartDt: v.actualStartDt, actualEndDt: v.actualEndDt, notes: v.notes,
            expectedRecordVersion: F(h, "recordVersion")
          } : {}),
          customJson: T.customJson(v)
        });
        return r.ok ? { ok: true, id: F(r.data.result, "engagementId"), outcome: F(r.data.result, "result") } : r;
      }
    });
    if (!res) return;
    if (eng) {
      await reloadWorkspace();
      show("enWsMessage", res.result.outcome === "MATERIAL_CHANGE"
        ? "Saved. This is a material change: the engagement is flagged for reassessment." : "Engagement saved.",
        res.result.outcome === "MATERIAL_CHANGE" ? "info" : "success");
      return;
    }
    await refreshList();
    if (await openWorkspace(res.result.id)) await editExposure(true);
  }

  // The list or workspace steps aside while a page (enEditor / enExposure)
  // is open, with the screen heading; it comes back when the page closes.
  function swapPage(open) {
    document.getElementById("enHeading").hidden = open;
    document.getElementById(state.eng && state.id ? "enWs" : "enList").hidden = open;
  }

  // ================================================================== scope & exposure
  // Scope & Exposure page (enExposure), POST engagements/{id}/exposure --
  // CR 2 5.2 / 5.3. Gating questions open only the dimensions that apply;
  // the details of a dimension answered No (or Not sure) are cleared on
  // save. The proposed scope items are saved as one set (scopeJson).
  const ANSWERS = [{ value: "YES", label: "Yes" }, { value: "NO", label: "No" }, { value: "UNKNOWN", label: "Not sure" }];
  const GATES = [
    { name: "appAccessAnswer", key: "appAccessAnswer", label: "Will the vendor access or support our applications or systems?" },
    { name: "premisesAccessAnswer", key: "premisesAccessAnswer", label: "Will the vendor have physical access to our premises?" },
    { name: "dataProcessingAnswer", key: "dataProcessingAnswer", label: "Will the vendor access, process, store or transmit organization or customer data?" },
    { name: "subcontractingAnswer", key: "subcontractingAnswer", label: "Will the vendor use subcontractors or other third parties for this service?" },
    { name: "importantProcessAnswer", key: "importantProcessAnswer", label: "Does the service support an important business process or function?" },
    { name: "disruptionImpactAnswer", key: "disruptionImpactAnswer", label: "Could a disruption of the service affect business operations?" },
    { name: "serviceCommitmentAnswer", key: "serviceCommitmentAnswer", label: "Are service commitments (SLA, recovery objectives) part of the service?" },
    { name: "contractAnswer", key: "contractAnswer", label: "Is there a contract for this engagement?" }
  ];
  const yesTo = (...names) => names.map(field => ({ field, values: ["YES"] }));
  // GRAC records of a kind as multi options ("r:<id>"), plus the proposed
  // items of that kind the lookups do not offer -- named outside GRAC
  // ("n:<name>") or a GRAC record no longer active -- so a save keeps them.
  function recordOptions(list, kind, proposed) {
    const own = list.map(x => ({ value: `r:${F(x, "id")}`, label: F(x, "name") }));
    const known = new Set(own.map(o => o.value));
    const stored = proposed.filter(s => F(s, "itemKind") === kind).map(s => F(s, "refId") != null
      ? { value: `r:${F(s, "refId")}`, label: `${F(s, "itemName")} (no longer active)` }
      : { value: `n:${F(s, "itemName")}`, label: `${F(s, "itemName")} (not in GRAC)` });
    return own.concat(stored.filter(o => !known.has(o.value)));
  }
  // A list's options plus the codes already recorded that are no longer in
  // force (retired / hidden), so a save keeps them.
  function codeOptions(listCode, codes, storedLabel) {
    const own = state.lk.options(listCode);
    const known = new Set(own.map(o => String(o.value)));
    return own.concat(codes.filter(c => c != null && !known.has(String(c)))
      .map(c => ({ value: c, label: `${storedLabel(c) || c} (no longer in use)` })));
  }
  function refValues(kind, proposed) {
    return proposed.filter(s => F(s, "itemKind") === kind).map(s => F(s, "refId") != null ? `r:${F(s, "refId")}` : `n:${F(s, "itemName")}`);
  }
  function refItems(kind, values, otherText) {
    const items = (values || []).map(v => v.startsWith("r:") ? { kind, refId: Number(v.substring(2)) } : { kind, itemName: v.substring(2) });
    String(otherText || "").split("\n").map(x => x.trim()).filter(Boolean).forEach(itemName => items.push({ kind, itemName }));
    return items;
  }

  async function editExposure(afterCreate) {
    const lk = state.lk;
    const h = state.eng.header[0];
    const proposed = (state.eng.scope || []).filter(s => F(s, "exposureMode") === "PROPOSED");
    const codes = kind => proposed.filter(s => F(s, "itemKind") === kind).map(s => F(s, "itemCode"));
    const storedName = kind => code => F(proposed.find(s => F(s, "itemKind") === kind && F(s, "itemCode") === code), "itemName");
    const contracts = lk.contracts.filter(c => F(c, "contractId") != null)
      .map(c => ({ value: F(c, "contractId"), label: `${F(c, "contractNumber")} - ${F(c, "contractName")}` }));
    const fields = [
      { type: "section", label: "Exposure questions", name: "_q" },
      ...GATES.map(g => ({ name: g.name, label: g.label, type: "select", options: ANSWERS, blank: "Not answered", value: F(h, g.key) })),
      { type: "section", label: "Business continuity", name: "_crit" },
      { name: "serviceCriticalityCode", label: "Service criticality", type: "select", options: lk.options("CRITICALITY"), value: F(h, "criticalityCode"), required: true },
      { name: "customerImpactCode", label: "Customer impact", type: "select", options: lk.options("CUSTOMER_IMPACT"), value: F(h, "customerImpactCode"), showWhen: yesTo("disruptionImpactAnswer") },
      { name: "substitutabilityCode", label: "Substitutability", type: "select", options: lk.options("SUBSTITUTABILITY"), value: F(h, "substitutabilityCode"), showWhen: yesTo("disruptionImpactAnswer") },
      { name: "exitDependencies", label: "Exit dependencies", type: "textarea", rows: 2, maxLength: 2000, value: F(h, "exitDependencies"), showWhen: yesTo("disruptionImpactAnswer"),
        help: "What the organization depends on to leave this engagement: data, knowledge, assets, transition support, lock-in." },
      { type: "section", label: "Business processes", name: "_proc", showWhen: yesTo("importantProcessAnswer") },
      { name: "businessFunctions", label: "Business functions", type: "multi", options: recordOptions(lk.businessFunctions, "BUSINESS_FUNCTION", proposed),
        value: refValues("BUSINESS_FUNCTION", proposed), showWhen: yesTo("importantProcessAnswer") },
      { name: "processes", label: "Processes supported or performed", type: "multi", options: recordOptions(lk.processes, "PROCESS", proposed),
        value: refValues("PROCESS", proposed), showWhen: yesTo("importantProcessAnswer") },
      { name: "processesOther", label: "Other processes (not in GRAC) -- one per line", type: "textarea", rows: 2, showWhen: yesTo("importantProcessAnswer") },
      { type: "section", label: "Applications and systems", name: "_app", showWhen: yesTo("appAccessAnswer") },
      { name: "applications", label: "Applications, infrastructure and systems", type: "multi", options: recordOptions(lk.applications, "APPLICATION", proposed),
        value: refValues("APPLICATION", proposed), showWhen: yesTo("appAccessAnswer") },
      { name: "applicationsOther", label: "Other applications / systems (not in GRAC) -- one per line", type: "textarea", rows: 2, showWhen: yesTo("appAccessAnswer") },
      { type: "section", label: "Access privileges", name: "_acc", showWhen: yesTo("appAccessAnswer", "premisesAccessAnswer") },
      { name: "accessCodes", label: "Physical, logical, privileged and administrative access", type: "multi", options: codeOptions("ACCESS_CATEGORY", codes("ACCESS"), storedName("ACCESS")),
        value: codes("ACCESS"), showWhen: yesTo("appAccessAnswer", "premisesAccessAnswer") },
      { type: "section", label: "Data exposure", name: "_data", showWhen: yesTo("dataProcessingAnswer") },
      { name: "dataCodes", label: "Data categories accessed, processed, stored or transmitted", type: "multi", options: codeOptions("DATA_EXPOSURE", codes("DATA_CATEGORY"), storedName("DATA_CATEGORY")),
        value: codes("DATA_CATEGORY"), showWhen: yesTo("dataProcessingAnswer"), help: "The most sensitive category becomes the engagement's data exposure." },
      { name: "dataProcessingDetails", label: "Processing details", type: "textarea", rows: 2, maxLength: 2000, value: F(h, "dataProcessingDetails"), showWhen: yesTo("dataProcessingAnswer"),
        help: "How the data is handled: purpose, volume, where it is stored, retention, transfers." },
      { type: "section", label: "Fourth parties", name: "_fp", showWhen: yesTo("subcontractingAnswer") },
      { name: "fourthParties", label: "Subcontractors and other third-party dependencies", type: "rows", addText: "Add fourth party", showWhen: yesTo("subcontractingAnswer"),
        columns: [{ name: "itemName", label: "Name", maxLength: 300, required: true },
                  { name: "itemCode", label: "Category", type: "select", options: codeOptions("FOURTH_PARTY_CATEGORY", codes("FOURTH_PARTY"), c => lk.label("FOURTH_PARTY_CATEGORY", c)) },
                  { name: "country", label: "Country", maxLength: 120 }],
        value: proposed.filter(s => F(s, "itemKind") === "FOURTH_PARTY").map(s => ({ itemName: F(s, "itemName"), itemCode: F(s, "itemCode"), country: F(s, "country") })) },
      { type: "section", label: "Delivery and processing locations", name: "_loc" },
      { name: "locations", label: "Locations from which services are delivered or data is processed", type: "rows", addText: "Add location",
        columns: [{ name: "itemName", label: "Site / location", maxLength: 300, required: true }, { name: "country", label: "Country", maxLength: 120 }],
        value: proposed.filter(s => F(s, "itemKind") === "LOCATION").map(s => ({ itemName: F(s, "itemName"), country: F(s, "country") })) },
      { type: "section", label: "Service commitments", name: "_sla", showWhen: yesTo("serviceCommitmentAnswer") },
      { name: "slaSummary", label: "SLA", type: "textarea", rows: 2, maxLength: 2000, value: F(h, "slaSummary"), showWhen: yesTo("serviceCommitmentAnswer") },
      { name: "rtoHours", label: "RTO (hours)", type: "number", min: 0, step: "1", value: F(h, "rtoHours"), showWhen: yesTo("serviceCommitmentAnswer") },
      { name: "rpoHours", label: "RPO (hours)", type: "number", min: 0, step: "1", value: F(h, "rpoHours"), showWhen: yesTo("serviceCommitmentAnswer") },
      { type: "section", label: "Contractual information", name: "_con", showWhen: yesTo("contractAnswer") },
      { name: "contractId", label: "Contract (Asset & Contract)", type: "select", options: contracts, value: F(h, "contractId"), showWhen: yesTo("contractAnswer") },
      { name: "contractReference", label: "Contract reference", maxLength: 200, value: F(h, "contractReference"), showWhen: yesTo("contractAnswer") },
      { name: "contractValue", label: "Contract value", type: "number", step: "0.01", value: F(h, "contractValue"), showWhen: yesTo("contractAnswer") },
      { name: "currencyCode", label: "Currency", maxLength: 10, value: F(h, "currencyCode"), showWhen: yesTo("contractAnswer") },
      { name: "contractStartDt", label: "Valid from", type: "date", value: F(h, "contractStartDt"), showWhen: yesTo("contractAnswer") },
      { name: "contractEndDt", label: "Valid until", type: "date", value: F(h, "contractEndDt"), showWhen: yesTo("contractAnswer") },
      { name: "renewalDt", label: "Renewal date", type: "date", value: F(h, "renewalDt"), showWhen: yesTo("contractAnswer") },
      { name: "contractDocuments", label: "Related documents", type: "textarea", rows: 2, maxLength: 1000, value: F(h, "contractDocuments"), showWhen: yesTo("contractAnswer"),
        help: "References to the contract, schedules, DPA and other documents." }
    ];
    const live = ["APPROVED", "ONBOARDING", "ACTIVE", "SUSPENDED"].includes(F(h, "stageCode"));
    const res = await T.form({
      page: "enExposure", onOpen: () => swapPage(true), onClose: () => swapPage(false),
      title: `Scope & Exposure - ${F(h, "engagementCode")} ${F(h, "engagementTitle")}`, submitText: "Save scope & exposure",
      intro: (afterCreate ? "Engagement created. " : "")
        + "Answer the questions; only the parts that apply to this service are asked. Answering No or Not sure clears the details recorded under that question when you save."
        + (live ? " A change of criticality, data exposure, customer impact or substitutability on an approved or live engagement is a material change and flags the engagement for reassessment." : ""),
      fields,
      validate: v => v.contractEndDt && v.contractStartDt && v.contractEndDt < v.contractStartDt ? "The contract end date is before its start date."
        : [v.rtoHours, v.rpoHours].some(x => x != null && (!Number.isInteger(x) || x < 0)) ? "RTO and RPO are whole numbers of hours, 0 or more." : null,
      onSubmit: async v => {
        const scope = [
          ...refItems("BUSINESS_FUNCTION", v.businessFunctions),
          ...refItems("PROCESS", v.processes, v.processesOther),
          ...refItems("APPLICATION", v.applications, v.applicationsOther),
          ...(v.accessCodes || []).map(itemCode => ({ kind: "ACCESS", itemCode })),
          ...(v.dataCodes || []).map(itemCode => ({ kind: "DATA_CATEGORY", itemCode })),
          ...(v.fourthParties || []).map(x => ({ kind: "FOURTH_PARTY", itemName: x.itemName, itemCode: x.itemCode, country: x.country })),
          ...(v.locations || []).map(x => ({ kind: "LOCATION", itemName: x.itemName, country: x.country }))
        ];
        const r = await api("POST", `/engagements/${state.id}/exposure`, {
          organizationId: state.org,
          ...Object.fromEntries(GATES.map(g => [g.name, v[g.name]])),
          serviceCriticalityCode: v.serviceCriticalityCode, customerImpactCode: v.customerImpactCode,
          substitutabilityCode: v.substitutabilityCode, exitDependencies: v.exitDependencies,
          dataProcessingDetails: v.dataProcessingDetails, slaSummary: v.slaSummary, rtoHours: v.rtoHours, rpoHours: v.rpoHours,
          contractId: num(v.contractId), contractReference: v.contractReference, contractValue: v.contractValue,
          currencyCode: v.currencyCode, contractStartDt: v.contractStartDt, contractEndDt: v.contractEndDt,
          renewalDt: v.renewalDt, contractDocuments: v.contractDocuments,
          scopeJson: JSON.stringify(scope), expectedRecordVersion: F(h, "recordVersion")
        });
        return r.ok ? { ok: true, outcome: F(r.data.result, "result") } : r;
      }
    });
    if (!res) return;
    await reloadWorkspace();
    // 523: the save generated a new screening report -- show it.
    selectTab("SCREEN");
    const screened = `Screening report v${H("screeningVersionNo") ?? ""} generated: ${(CLASSIFICATION[H("screeningClassification")] || {}).label || ""}.`;
    show("enWsMessage", res.result.outcome === "MATERIAL_CHANGE"
      ? `Scope & exposure saved. This is a material change: the engagement is flagged for reassessment. ${screened}` : `Scope & exposure saved. ${screened}`,
      res.result.outcome === "MATERIAL_CHANGE" ? "info" : "success");
  }

  // ================================================================== workspace
  async function openWorkspace(id) {
    state.id = id;
    const ok = await reloadWorkspace();
    if (!ok) return false;
    document.getElementById("enList").hidden = true;
    document.getElementById("enWs").hidden = false;
    hide("enWsMessage");
    selectTab(H("applicabilityStatus") !== "ADMITTED" ? (H("exposureSavedDt") ? "SCREEN" : "SCOPE") : (STEP_OF_STAGE[H("stageCode")] || "SCOPE"));
    window.scrollTo({ top: 0, behavior: "smooth" });
    return true;
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
      ["TPRM applicability", `${esc(applicabilityLabel(H("applicabilityStatus")))}${H("screeningClassification") ? `<div>${classBadge(H("screeningClassification"))}</div>` : ""}`, true],
      // 524: the vendor's TP Risk Register record (CR 2 8.1)
      H("registerId") ? ["TP Risk Register", `${btn("open-register", "fa-shield-halved", H("registerCode"))}${H("registerStatus") && H("registerStatus") !== "OPEN"
        ? ` <span class="tprm-muted">${esc(REGISTER_STATUS[H("registerStatus")] || H("registerStatus"))}</span>` : ""}`, true] : null,
      ["Criticality", T.badge(H("criticality"), H("criticalityColor")) || '<span class="tprm-muted">Not set -- Scope &amp; exposure</span>', true],
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
    if (canEdit()) b.push(btn("edit-engagement", "fa-pen", "Edit"), btn("edit-exposure", "fa-list-check", "Scope & exposure", {}, null, H("exposureSavedDt") ? "" : "primary"));
    document.getElementById("enWsActions").innerHTML = b.join("");
    // Step chips: done / current.
    // Closed engagements: every step reached is done (EXITED) or none is current.
    // 523: screening and the applicability decision come before the risk
    // steps; until admission the current step is Scope or Screening.
    const order = ["SCOPE", "SCREEN", "RISK", "DD", "DECISION", "ONBOARD"];
    const current = isClosed() && stage !== "EXITED" ? null
      : !admitted() ? (H("exposureSavedDt") ? "SCREEN" : "SCOPE")
      : stage === "SCOPING" ? "RISK" : (STEP_OF_STAGE[stage] || null);
    const reached = stage === "EXITED" ? order.length : current ? order.indexOf(current)
      : H("applicabilityStatus") === "EXCLUDED" ? order.indexOf("RISK") : 0;
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
    else if (name === "SCREEN") await renderScreening();
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
    // 522: proposed items are changed on the Scope & Exposure page; only the
    // actual (onboarding) items are removed one by one.
    const row = s => `<tr>
        <td>${esc(kindLabel(F(s, "itemKind")))}</td>
        <td>${esc(F(s, "itemName"))}${F(s, "country") ? ` <span class="tprm-muted">${esc(F(s, "country"))}</span>` : ""}${F(s, "notes") ? `<div class="tprm-muted">${esc(F(s, "notes"))}</div>` : ""}</td>
        <td>${state.lk.badge("CRITICALITY", F(s, "criticalityCode"))}${yes(F(s, "isCritical")) ? ' <span class="pm-badge">Critical</span>' : ""}</td>
        <td>${canEdit() && F(s, "exposureMode") === "ACTUAL" ? btn("scope-remove", "fa-trash", "", { id: F(s, "scopeItemId") }, "Remove") : ""}</td></tr>`;
    const answer = k => ({ YES: "Yes", NO: "No", UNKNOWN: "Not sure" })[H(k)] || '<span class="tprm-muted">Not answered</span>';
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
        ["Service recipient", H("serviceRecipient")], ["Delivery location", H("deliveryLocations")],
        ["Proposed term", [date(H("proposedStartDt")), date(H("proposedEndDt"))].filter(Boolean).join(" to ")],
        ["Actual term", [date(H("actualStartDt")), date(H("actualEndDt"))].filter(Boolean).join(" to ")],
        ["Relationship owner", H("relationshipOwnerName")], ["Assessor", H("assessorName")],
        ["Existing relationship", yes(H("isExisting")) ? "Yes" : "No"],
        ["Service description", H("serviceDescription")], ["Business purpose", H("businessPurpose")], ["Scope", H("scopeDescription")],
        ...(e.customValues || []).map(c => [F(c, "label"), F(c, "value")])
      ])}</div>
      <div class="tprm-subhead">Scope &amp; exposure <span>${canEdit() ? btn("edit-exposure", "fa-list-check", H("exposureSavedDt") ? "Edit scope & exposure" : "Capture scope & exposure", {}, null, H("exposureSavedDt") ? "" : "primary") : ""}</span></div>
      <p class="tprm-note">${H("exposureSavedDt")
        ? `Saved ${esc(T.dateTime(H("exposureSavedDt")))}${H("exposureSavedBy") ? ` by ${esc(H("exposureSavedBy"))}` : ""}. What the vendor will access, store, support or depend on, as proposed: it drives the risk-model prefill and which questionnaires and questions apply.`
        : "Not captured yet. The questions ask only for the parts of the exposure that apply to this service."}</p>
      <div class="pm-table-wrap"><table><thead><tr><th>Question</th><th>Answer</th></tr></thead><tbody>${GATES.map(g =>
        `<tr><td>${esc(g.label)}</td><td>${answer(g.key)}</td></tr>`).join("")}</tbody></table></div>
      <div class="tprm-info" style="margin-top:12px">${info([
        ["Criticality", T.badge(H("criticality"), H("criticalityColor")), true], ["Data exposure", H("dataExposure")],
        ["Processing details", H("dataProcessingDetails")],
        ["Customer impact", H("customerImpact")], ["Substitutability", H("substitutability")], ["Exit dependencies", H("exitDependencies")],
        ["SLA", H("slaSummary")], ["RTO / RPO (hours)", H("rtoHours") != null || H("rpoHours") != null ? [H("rtoHours"), H("rpoHours")].map(x => x ?? "--").join(" / ") : ""],
        ["Contract", H("contractReference") || (H("contractId") ? `#${H("contractId")}` : "")],
        ["Contract value", H("contractValue") != null ? [H("contractValue"), H("currencyCode")].filter(x => x != null).join(" ") : ""],
        ["Contract validity", [date(H("contractStartDt")), date(H("contractEndDt"))].filter(Boolean).join(" to ")],
        ["Renewal date", date(H("renewalDt"))], ["Related documents", H("contractDocuments")]
      ])}</div>
      <div class="tprm-subhead">Proposed exposure</div>
      <div class="pm-table-wrap"><table><thead><tr><th>Type</th><th>Item</th><th>Criticality</th><th></th></tr></thead>
        <tbody>${proposed.map(row).join("") || empty(4, "No proposed scope yet.")}</tbody></table></div>
      ${actual.length || ["ONBOARDING", "ACTIVE", "SUSPENDED"].includes(H("stageCode")) ? `
      <div class="tprm-subhead">Actual exposure <span>${canEdit() ? btn("scope-add", "fa-plus", "Add actual item", { mode: "ACTUAL" }) : ""}</span></div>
      <div class="pm-table-wrap"><table><thead><tr><th>Type</th><th>Item</th><th>Criticality</th><th></th></tr></thead>
        <tbody>${actual.map(row).join("") || empty(4, "No actual exposure recorded.")}</tbody></table></div>` : ""}
      <div class="tprm-subhead">Discovered from GRAC
        <span>${btn("discover", "fa-magnifying-glass", "Discover")}${canEdit() ? btn("discover-record", "fa-floppy-disk", "Record discovery") : ""}</span></div>
      <p class="tprm-note">Practice instances, obligations, dependencies, assurance findings, gaps, enterprise risks and the contract that already involve the applications in this engagement's scope (record them under Applications and systems on Scope &amp; exposure first). Discovery only reads; "Record discovery" saves what was found as links to validate.</p>
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

  // ACTUAL exposure (onboarding) only, one item at a time; the PROPOSED
  // exposure is saved on the Scope & Exposure page (522).
  async function addScopeItem(mode) {
    const lk = state.lk;
    const pick = await T.form({
      title: "Add actual exposure", submitText: "Next",
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
      title: `Actual: ${kindLabel(kind)}`, submitText: "Add", fields,
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
    // 521: no legacy GRAC vendor link -- the vendor is the Vendor Registry record.
    const kinds = [{ value: "APPLICATION", label: "Application" }, { value: "CONTRACT", label: "Contract" }];
    const pick = await T.form({ title: "Link a GRAC record", submitText: "Next",
      intro: "Practice instances, dependencies and enterprise risks are linked from the discovery results.",
      fields: [{ name: "kind", label: "Record type", type: "select", options: kinds, required: true, blank: "Choose" }] });
    if (!pick) return;
    const options = pick.kind === "APPLICATION" ? lk.applications.map(x => ({ value: F(x, "id"), label: F(x, "name") }))
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
    // 522: the assessment needs Scope & Exposure saved (criticality, data, access).
    const startBtn = !admitted() ? '<p class="pm-message info">The inherent risk assessment starts after the engagement is admitted to formal TPRM (Screening &amp; decision).</p>'
      : !H("exposureSavedDt") ? (canEdit() ? '<p class="pm-message info">Save Scope &amp; exposure first: the risk model is prefilled from it.</p>' : "")
      : canEdit() && !draft && H("stageCode") !== "PENDING_DECISION" && H("stageCode") !== "EXITING"
      ? btn("risk-start", "fa-play", current ? "Reassess" : "Start inherent risk assessment", {}, null, "primary") : "";
    if (!ra) {
      host.innerHTML = `<p class="tprm-note">The inherent risk is scored on the organization's risk model in force (pinned to the assessment). Factors are prefilled from the scope; every answer is confirmed by the assessor. The band sets the due-diligence tier.</p>
        <div class="tprm-actions">${startBtn}</div>
        ${state.lk.riskModel ? `<p class="tprm-muted">Risk model in force: ${esc(F(state.lk.riskModel, "templateName"))} v${esc(F(state.lk.riskModel, "versionNo"))} (${esc(F(state.lk.riskModel, "origin"))})</p>` : '<p class="pm-message">No risk model is in force. Activate one in Third-Party Settings.</p>'}`;
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
        <td>${esc(F(q, "questionCode"))} ${esc(F(q, "questionText"))}${yes(F(q, "isMandatory")) ? " *" : ""}
          ${F(q, "guidance") ? `<div class="tprm-muted">${esc(F(q, "guidance"))}</div>` : ""}
          ${F(q, "sourceAuthority") ? `<div class="tprm-muted">Source: ${esc(F(q, "sourceAuthority"))}${F(q, "sourceReference") ? ", " + esc(F(q, "sourceReference")) : ""}${yes(F(q, "isRegulatory")) ? "" : " (not a regulatory requirement)"}</div>` : ""}</td>
        <td><div class="en-answer">${answer}${comment}</div>
          ${editable ? `<div class="tprm-actions" style="margin:6px 0 0">
            <select data-ans-respondent title="Answered by"><option value="THIRD_PARTY"${F(q, "respondentType") !== "INTERNAL" ? " selected" : ""}>Vendor</option><option value="INTERNAL"${F(q, "respondentType") === "INTERNAL" ? " selected" : ""}>Internal</option></select>
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
        ${yes(F(rule, "escalateToRiskCentre")) ? " Escalation to the GRAC Risk Centre is recommended for this risk level." : ""}</p>` : '<p class="pm-message">No approval rule applies. Add one in Third-Party Settings.</p>'}
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
        <td><a class="pm-button small" href="${esc(T.U("/Practice/Index/tprm-reviews"))}"${T.navAttrs("tprm-engagements", "tprm-reviews", "TprmEngagement", state.id, state.org, F(v, "reviewNumber"))}>Open</a></td></tr>`).join("");
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

  // ------------------------------------------------------------------ step: screening & decision (523)
  // CR 2 6-7. GET engagements/{id}/applicability (reports, report,
  // observations, decisions, admissions, approvals); POST
  // engagements/{id}/screening (refresh), engagements/{id}/applicability
  // (the client's decision), admissions/{id}/act | /withdraw. GRAC's
  // classification is information only; the decision is the client's.
  const APPLICABILITY = {
    NOT_SCREENED: "Not screened", SCREENED: "Awaiting decision", EXCLUDED: "Excluded from formal TPRM", DEFERRED: "Decision deferred",
    ADMISSION_PENDING: "Admission approval pending", ADMITTED: "Admitted to formal TPRM", ADMISSION_REJECTED: "Admission rejected"
  };
  const CLASSIFICATION = {
    POTENTIAL_TPRM_CASE: { label: "Potential TPRM case", color: "#dc2626" },
    NO_SIGNIFICANT_INDICATORS: { label: "No significant TPRM indicators identified", color: "#16a34a" },
    FURTHER_INFORMATION_REQUIRED: { label: "Further information required", color: "#ca8a04" }
  };
  const SIGNIFICANCE = { HIGH: "#dc2626", MEDIUM: "#ca8a04", LOW: "#16a34a", INFO: "#64748b" };
  const SECTIONS = [
    ["BUSINESS_OPERATIONAL", "Business and operational exposure"], ["DATA_TECHNOLOGY", "Data and technology exposure"],
    ["REGULATORY_OUTSOURCING", "Regulatory and outsourcing"], ["FOURTH_PARTY", "Fourth-party dependencies"],
    ["RELATED_RECORDS", "Related practice instances, risks, gaps and assurance findings (GRAC discovery)"],
    ["INFORMATION_GAP", "Information gaps and inconsistencies"]];
  const DECISIONS = { INCLUDE: "Include in formal TPRM", EXCLUDE: "Exclude from formal TPRM", DEFER: "Defer -- further information required" };
  const VERIFICATION = { DECLARED: "Declared", DISCOVERED_UNVALIDATED: "Not validated", VALIDATED: "Validated" };
  const classBadge = c => c ? T.badge((CLASSIFICATION[c] || { label: c }).label, (CLASSIFICATION[c] || {}).color) : "";
  const applicabilityLabel = s => APPLICABILITY[s] || s || "";
  const admitted = () => H("applicabilityStatus") === "ADMITTED";
  const REGISTER_STATUS = { OPEN: "Open", EXIT_IN_PROGRESS: "Exit in progress", CLOSED: "Closed" };

  async function renderScreening(reportId) {
    const host = document.getElementById("enPanelScreen");
    if (!H("exposureSavedDt")) {
      host.innerHTML = `<p class="tprm-note">The Initial Exposure Screening Report is generated when Scope &amp; exposure is saved.</p>
        <div class="tprm-actions">${canEdit() ? btn("edit-exposure", "fa-list-check", "Capture scope & exposure", {}, null, "primary") : ""}</div>`;
      return;
    }
    const r = await api("GET", `/engagements/${state.id}/applicability?${qs({ organizationId: state.org, reportId })}`);
    if (!r.ok) { host.innerHTML = `<p class="pm-message">${esc(r.error)}</p>`; return; }
    const d = state.screen = r.data;
    const rep = (d.report || [])[0];
    const status = H("applicabilityStatus");
    const pending = (d.admissions || []).find(a => F(a, "status") === "PENDING");
    const current = (d.decisions || []).find(x => F(x, "status") === "CURRENT");
    const canDecide = CAN_APPROVE && !isClosed() && rep && !["ADMISSION_PENDING", "ADMITTED"].includes(status);

    // ---- applicability and admission
    const actions = [
      canDecide ? btn("applicability-decide", "fa-gavel", current ? "Record a revised decision" : "Record decision", {}, null, "primary") : "",
      canEdit() ? btn("screening-refresh", "fa-rotate", "Refresh screening") : ""].join("");
    let admissionHtml = "";
    if (pending) {
      // Withdraw: the decision-maker who included it, or an organization
      // administrator (sp_tprm_admission_withdraw applies the same rule).
      const canWithdraw = canEdit() && (root.dataset.isAdmin === "1"
        || (root.dataset.employeeId && String(F(pending, "submittedByEmployeeId")) === root.dataset.employeeId));
      const levels = (d.approvals || []).filter(p => String(F(p, "admissionId")) === String(F(pending, "admissionId")));
      admissionHtml = `
        <div class="tprm-subhead">Admission ${esc(F(pending, "admissionNo"))} -- approval
          <span>${CAN_APPROVE && !isClosed() ? btn("admission-act", "fa-check", "Approve", { id: F(pending, "admissionId"), action: "APPROVE" }, null, "primary")
                 + btn("admission-act", "fa-xmark", "Reject", { id: F(pending, "admissionId"), action: "REJECT" })
                 + btn("admission-act", "fa-rotate-left", "Return", { id: F(pending, "admissionId"), action: "RETURN" }) : ""}${
                 canWithdraw ? btn("admission-withdraw", "fa-ban", "Withdraw", { id: F(pending, "admissionId") }) : ""}</span></div>
        <p class="tprm-note">Approval rule ${esc(F(pending, "approvalRuleName") || F(pending, "approvalRuleCode"))}: ${esc(F(pending, "requiredLevels"))} level(s)${
          yes(F(pending, "sodRequired")) ? "; the decision-maker cannot approve and each level needs a different person" : ""}. Requested by ${esc(F(pending, "submittedBy") || "")} on ${esc(T.dateTime(F(pending, "submittedDt")))}.</p>
        <div class="pm-table-wrap"><table><thead><tr><th>Level</th><th>Role</th><th>Status</th><th>By</th><th>Comment</th></tr></thead><tbody>${
          levels.map(p => `<tr><td>${esc(F(p, "levelNo"))}</td><td>${esc(F(p, "requiredRoleName") || "Any approver")}</td><td>${esc(F(p, "status"))}</td>
            <td>${esc(F(p, "approverName") || "")}${F(p, "onBehalfOfName") ? `<div class="tprm-muted">for ${esc(F(p, "onBehalfOfName"))}</div>` : ""}</td>
            <td>${esc(F(p, "comment") || "")}</td></tr>`).join("")}</tbody></table></div>`;
    }
    const currentHtml = current ? `<div class="tprm-info">${info([
        ["Decision", DECISIONS[F(current, "decision")] || F(current, "decision")], ["Decision date", date(F(current, "decisionDt"))],
        ["Decision-maker", F(current, "decidedBy")], ["On report", `v${F(current, "reportVersionNo")}`],
        ["Rationale", F(current, "rationale")], ["Evidence / references", F(current, "evidenceReferences")],
        ["Approval reference", F(current, "approvalReference")],
        F(current, "informationRequest") ? ["Information requested", `${F(current, "informationRequest")}${F(current, "informationFromName") ? ` (from ${F(current, "informationFromName")})` : ""}`] : null,
        F(current, "informationTaskId") ? ["Task Board task", `${F(current, "informationTaskNumber") || ""} (${F(current, "informationTaskStatus") || ""})`] : null
      ])}</div>` : "";

    // ---- the report
    let reportHtml = '<p class="tprm-note">No screening report yet. Refresh the screening.</p>';
    if (rep) {
      let s = {};
      try { s = JSON.parse(F(rep, "summaryJson") || "{}") || {}; } catch (_) { s = {}; }
      const obs = d.observations || [];
      const versions = (d.reports || []).length > 1
        ? `<select data-change="screening-version" aria-label="Report version">${(d.reports || []).map(x =>
            `<option value="${esc(F(x, "reportId"))}"${String(F(x, "reportId")) === String(F(rep, "reportId")) ? " selected" : ""}>v${esc(F(x, "versionNo"))} -- ${esc((CLASSIFICATION[F(x, "classification")] || {}).label || F(x, "classification"))}${yes(F(x, "isCurrent")) ? " (current)" : ""}</option>`).join("")}</select>` : "";
      const row = o => `<tr>
          <td>${esc(F(o, "observationText"))}${F(o, "indicatorLabel") ? `<div class="tprm-muted">Indicator: ${esc(F(o, "indicatorLabel"))}</div>` : ""}</td>
          <td>${F(o, "origin") === "DISCOVERED" ? "GRAC discovery" : "Proposed"}</td>
          <td>${T.badge(F(o, "significance"), SIGNIFICANCE[F(o, "significance")])}</td>
          <td>${esc(F(o, "sourceLabel") || "")}</td>
          <td>${esc(VERIFICATION[F(o, "verificationStatus")] || F(o, "verificationStatus"))}${F(o, "evidenceReference") ? `<div class="tprm-muted">${esc(F(o, "evidenceReference"))}</div>` : ""}</td></tr>`;
      reportHtml = `
        <div class="tprm-subhead">Initial Exposure Screening Report v${esc(F(rep, "versionNo"))} <span>${versions}</span></div>
        <div class="tprm-info">${info([
          ["Classification", classBadge(F(rep, "classification")), true],
          ["Generated", `${T.dateTime(F(rep, "generatedDt"))} by ${F(rep, "generatedBy") || ""}`],
          ["High indicators", F(rep, "highCount")], ["Information gaps", F(rep, "gapCount")],
          ["Vendor", [s.vendorCode, s.vendorName].filter(Boolean).join(" ")], ["Service category", s.serviceCategory],
          ["Engagement type", s.engagementType], ["Service model", s.serviceModel], ["Service recipient", s.serviceRecipient],
          ["Delivery location", s.deliveryLocation], ["Criticality", s.criticality], ["Data exposure", s.dataExposure]
        ])}</div>
        <p class="tprm-note">The classification is GRAC's view from the information available; it does not decide TPRM applicability. "Proposed" is what the business declared for this engagement; "GRAC discovery" is what GRAC already holds -- review it before relying on it.</p>
        ${SECTIONS.map(([code, title]) => {
          const rows = obs.filter(o => F(o, "sectionCode") === code);
          return rows.length ? `<h4 class="pm-dash-subhead">${esc(title)}</h4>
            <div class="pm-table-wrap"><table><thead><tr><th style="width:45%">Observation</th><th>Origin</th><th>Significance</th><th>Source</th><th>Verification</th></tr></thead>
            <tbody>${rows.map(row).join("")}</tbody></table></div>` : "";
        }).join("") || '<p class="tprm-note">No observations.</p>'}`;
    }

    const historyHtml = (d.decisions || []).length ? `
      <div class="tprm-subhead">Decision history</div>
      <div class="pm-table-wrap"><table><thead><tr><th>Date</th><th>Decision</th><th>Rationale</th><th>Report</th><th>Decision-maker</th><th>Status</th></tr></thead><tbody>${
        (d.decisions || []).map(x => `<tr><td>${esc(date(F(x, "decisionDt")))}</td><td>${esc(DECISIONS[F(x, "decision")] || F(x, "decision"))}</td>
          <td>${esc(F(x, "rationale") || "")}${F(x, "approvalReference") ? `<div class="tprm-muted">Approval reference: ${esc(F(x, "approvalReference"))}</div>` : ""}</td>
          <td>v${esc(F(x, "reportVersionNo"))}</td><td>${esc(F(x, "decidedBy") || "")}</td>
          <td>${F(x, "status") === "CURRENT" ? "Current" : "Superseded"}</td></tr>`).join("")}</tbody></table></div>
      ${(d.admissions || []).filter(a => F(a, "status") !== "PENDING").length ? `
      <div class="pm-table-wrap" style="margin-top:8px"><table><thead><tr><th>Admission</th><th>Rule</th><th>Outcome</th><th>Rationale</th><th>Decided</th></tr></thead><tbody>${
        (d.admissions || []).filter(a => F(a, "status") !== "PENDING").map(a => `<tr><td>${esc(F(a, "admissionNo"))}</td>
          <td>${esc(F(a, "approvalRuleName") || F(a, "approvalRuleCode"))}</td><td>${esc(F(a, "status"))}</td>
          <td>${esc(F(a, "outcomeRationale") || "")}</td><td>${esc(T.dateTime(F(a, "decidedDt")))} ${esc(F(a, "decidedBy") || "")}</td></tr>`).join("")}</tbody></table></div>` : ""}` : "";

    host.innerHTML = `
      <div class="tprm-subhead">TPRM applicability <span>${actions}</span></div>
      <div class="tprm-info">${info([["Status", `<strong>${esc(applicabilityLabel(status))}</strong>`, true],
        status === "ADMITTED" ? ["Admitted", T.dateTime(H("admittedDt"))] : null])}</div>
      ${currentHtml}${admissionHtml}${reportHtml}${historyHtml}`;
  }

  // The client's decision on the current report (CR 2 7).
  async function decideApplicability() {
    const rep = ((state.screen || {}).report || [])[0];
    const currentId = H("currentScreeningReportId");
    const res = await T.form({
      title: "TPRM applicability decision", submitText: "Record decision", wide: true,
      intro: `On screening report v${H("screeningVersionNo")} (${(CLASSIFICATION[H("screeningClassification")] || {}).label || ""}). GRAC's classification is information only -- the decision is yours. Include starts the admission approval.`
        + (rep && String(F(rep, "reportId")) !== String(currentId) ? " You are viewing an older report; the decision is recorded on the current one." : ""),
      fields: [
        { name: "decision", label: "Decision", type: "select", required: true, blank: "Choose",
          options: Object.entries(DECISIONS).map(([value, label]) => ({ value, label })) },
        { name: "decisionDt", label: "Decision date", type: "date", required: true, value: new Date().toISOString().substring(0, 10) },
        { name: "rationale", label: "Decision rationale", type: "textarea", required: true, maxLength: 2000 },
        { name: "evidenceReferences", label: "Supporting evidence or references", type: "textarea", rows: 2, maxLength: 2000 },
        { name: "approvalReference", label: "Approval reference (where applicable)", maxLength: 200 },
        { name: "informationRequest", label: "Information requested", type: "textarea", rows: 2, maxLength: 2000,
          showWhen: { field: "decision", values: ["DEFER"] } },
        { name: "informationFromEmployeeId", label: "Requested from", type: "select", options: state.lk.employeeOptions(),
          help: "525: a Task Board task is created for this person.",
          showWhen: { field: "decision", values: ["DEFER"] } }
      ],
      onSubmit: v => api("POST", `/engagements/${state.id}/applicability`, {
        organizationId: state.org, decision: v.decision, rationale: v.rationale, decisionDt: v.decisionDt,
        evidenceReferences: v.evidenceReferences, approvalReference: v.approvalReference, informationRequest: v.informationRequest,
        informationFromEmployeeId: num(v.informationFromEmployeeId), expectedReportId: num(currentId) })
    });
    if (!res) return;
    await reloadWorkspace();
    const outcome = F(res.result.data?.result, "result");
    show("enWsMessage", outcome === "ADMISSION_PENDING" ? "Decision recorded. The admission approval has started."
      : outcome === "EXCLUDED" ? "Decision recorded: excluded from formal TPRM." : "Decision recorded: deferred.", "success");
  }

  async function actOnAdmission(id, action) {
    const label = { APPROVE: "Approve admission", REJECT: "Reject admission", RETURN: "Return for a new decision" }[action];
    const res = await T.form({
      title: label, submitText: label,
      intro: action === "APPROVE" ? "At the last approval level the engagement is admitted to formal TPRM." : "",
      fields: [
        { name: "rationale", label: "Rationale", type: "textarea", required: true, maxLength: 2000 },
        { name: "onBehalfOfEmployeeId", label: "Acting for (delegation)", type: "select", options: state.lk.employeeOptions(), blank: "Myself",
          help: "Only with an active approval delegation from that person." }
      ],
      onSubmit: v => api("POST", `/admissions/${id}/act`, { organizationId: state.org, action, rationale: v.rationale,
        onBehalfOfEmployeeId: num(v.onBehalfOfEmployeeId) })
    });
    if (!res) return;
    await reloadWorkspace();
    const outcome = F(res.result.data?.result, "result");
    show("enWsMessage", outcome === "ADMITTED" ? "Admission approved: the engagement is admitted to formal TPRM."
      : outcome === "LEVEL_APPROVED" ? "Approval level recorded." : "Admission decision recorded.", "success");
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
      case "edit-exposure": return editExposure(false);
      // 524: open the vendor's TP Risk Register record (id in the navigation code)
      case "open-register": {
        const err = await T.navigate("tprm-engagements", "tprm-risk-register", "TprmRegister", H("registerId"), state.org);
        if (err) show("enWsMessage", err);
        return;
      }
      // ---- screening & decision (523)
      case "screening-refresh":
        if (await post(`/engagements/${state.id}/screening`, {}, "Screening report regenerated.")) { await reloadWorkspace(); selectTab("SCREEN"); }
        return;
      case "applicability-decide": return decideApplicability();
      case "screening-version": return renderScreening(el.value);
      case "admission-act": return actOnAdmission(id, data.action);
      case "admission-withdraw": {
        const note = await T.note("Why is the admission withdrawn? The engagement goes back to awaiting a decision.", "Withdraw admission", "Withdraw");
        if (note === null) return;
        if (await post(`/admissions/${id}/withdraw`, { note }, "Admission withdrawn.")) await reloadWorkspace();
        return;
      }
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
          intro: risks.length ? "" : "Run Discover on Scope & exposure to list the risks already related to this engagement, or give the risk register id.",
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
