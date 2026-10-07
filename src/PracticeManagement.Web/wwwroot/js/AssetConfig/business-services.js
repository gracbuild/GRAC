// =====================================================================
// Business Services (migration 441) -- BRD 5.5, 5.5.1, 5.5.2.
// Loaded by business-services.cshtml. Services: business-services,
// business-services/{id}, business-services (save), .../transition,
// .../retirement-decision, business-services/settings, /conflicts, /tree.
// Supporting items are Supports Service relationships: relationships
// (propose) and relationships/ci-lookup; service impact:
// relationships/impact (services result). The procedures hold every rule;
// this screen shows them.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config";
  const root = document.getElementById("bsvRoot");
  if (!root) return;
  const CAN_ADD = root.dataset.canAdd === "1";
  const CAN_EDIT = root.dataset.canEdit === "1";
  const CAN_APPROVE = root.dataset.canApprove === "1";

  const TYPES = { BUSINESS: "Business", CUSTOMER_FACING: "Customer-facing", TECHNICAL: "Technical", SHARED: "Shared", SUPPORTING: "Supporting" };
  const STATUS = { DRAFT: ["Draft", "bsv-st-ended"], DESIGN: ["Design", "bsv-st-open"], ACTIVE: ["Active", "bsv-st-active"],
                   DEGRADED: ["Degraded", "bsv-st-wait"], SUSPENDED: ["Suspended", "bsv-st-bad"], RETIRING: ["Retiring", "bsv-st-wait"],
                   RETIRED: ["Retired", "bsv-st-ended"] };
  // Status moves the procedure allows (5.5).
  const MOVES = { DRAFT: ["DESIGN", "RETIRED"], DESIGN: ["DRAFT", "ACTIVE", "RETIRED"], ACTIVE: ["DEGRADED", "SUSPENDED", "RETIRING"],
                  DEGRADED: ["ACTIVE", "SUSPENDED", "RETIRING"], SUSPENDED: ["ACTIVE", "RETIRING"], RETIRING: ["ACTIVE", "RETIRED"], RETIRED: [] };
  const KINDS = { ASSET: "Asset", APPLICATION: "Application", PROCESS: "Process", VENDOR: "Vendor", CONTRACT: "Contract", SERVICE: "Business service",
                  LOCATION: "Location" };
  const CONSUMER = { DEPARTMENT: "Department", BUSINESS_FUNCTION: "Business function", LOCATION: "Location", EXTERNAL: "External" };
  const CONFLICT = { SUPPORT_CRITICALITY: "Lower criticality", SUPPORT_RPO: "RPO longer", CHILD_OBJECTIVE: "Child service objectives",
                     SUPPORT_NOT_IN_USE: "Item not in use", SUPPORT_DISPUTED: "Disputed mapping", NO_OWNER: "No owner",
                     NO_SUPPORT: "No support", REVIEW_OVERDUE: "Review overdue" };
  const REL = { PROPOSED: ["Proposed", "bsv-st-wait"], ACTIVE: ["Active", "bsv-st-active"], DISPUTED: ["Disputed", "bsv-st-bad"] };

  const state = { organizationId: null, config: null, mainTab: "SERVICES", pager: null, confPager: null, current: null, consumers: [], move: null };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    state.pager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "bsvPager", onChange: refreshServices }) : null;
    state.confPager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "bsvConfPager", onChange: refreshConflicts }) : null;
    document.getElementById("bsvFltType").insertAdjacentHTML("beforeend", Object.entries(TYPES).map(([k, l]) => `<option value="${k}">${esc(l)}</option>`).join(""));
    document.getElementById("bsvFType").innerHTML = Object.entries(TYPES).map(([k, l]) => `<option value="${k}">${esc(l)}</option>`).join("");
    document.querySelectorAll("[data-bsv-rating]").forEach(s => { s.innerHTML = `<option value="">--</option>` + [1, 2, 3, 4, 5].map(n => `<option value="${n}">${n}</option>`).join(""); });
    ["bsvImpKind", "bsvSupKind"].forEach(id => {
      document.getElementById(id).innerHTML = Object.entries(KINDS).filter(([k]) => id === "bsvImpKind" || k !== "LOCATION")
        .map(([k, l]) => `<option value="${k}">${esc(l)}</option>`).join("");
    });
    bind();
    await populateOrgs();
    const sel = document.getElementById("bsvOrg");
    window.gracOrgPref.apply(sel);   // 2026-10-06: last-picked org, else lowest id
    // 451: opened from the Asset & Contract dashboard -- organization, tab and filter (Shared/dashboard-drill.js).
    const dashDrill = window.__pmDrill ? window.__pmDrill.read() : null;
    window.__pmDrill?.preselectFor(dashDrill, sel, { "": { status: "bsvFltStatus" }, SERVICES: { status: "bsvFltStatus" } });
    await changeOrg(Number(sel.value) || null);
    window.__pmDrill?.showOnPage("bsvRoot", "data-bsv-main", dashDrill);
  }

  async function populateOrgs() {
    const sel = document.getElementById("bsvOrg");
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
    document.getElementById("bsvOrg").addEventListener("change", e => changeOrg(Number(e.target.value) || null));
    document.querySelectorAll("[data-bsv-main]").forEach(b => b.addEventListener("click", () => selectMainTab(b.dataset.bsvMain)));
    document.querySelectorAll("[data-close-bsv]").forEach(b => b.addEventListener("click", () => { document.getElementById(b.dataset.closeBsv).hidden = true; }));
    let t1 = null, t2 = null;
    document.getElementById("bsvFltSearch").addEventListener("input", () => { clearTimeout(t1); t1 = setTimeout(() => { state.pager?.reset(true); refreshServices(); }, 300); });
    ["bsvFltStatus", "bsvFltType"].forEach(id => document.getElementById(id).addEventListener("change", () => { state.pager?.reset(true); refreshServices(); }));
    document.getElementById("bsvConfSearch").addEventListener("input", () => { clearTimeout(t2); t2 = setTimeout(() => { state.confPager?.reset(true); refreshConflicts(); }, 300); });
    document.getElementById("bsvBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-bsv-open]");
      if (b) openService(Number(b.dataset.bsvOpen));
    });
    ["bsvConfBody", "bsvTree", "bsvImpBody", "bsvSupportsBody"].forEach(id => document.getElementById(id).addEventListener("click", ev => {
      const b = ev.target.closest("button[data-bsv-open]");
      if (b) openService(Number(b.dataset.bsvOpen));
    }));
    document.getElementById("bsvAdd")?.addEventListener("click", () => openService(null));
    document.getElementById("bsvForm").addEventListener("submit", ev => { ev.preventDefault(); saveService(); });
    document.getElementById("bsvConsKind").addEventListener("change", fillConsumerRefs);
    document.getElementById("bsvConsAdd").addEventListener("click", addConsumer);
    document.getElementById("bsvConsBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-bsv-cons-remove]");
      if (b) { state.consumers.splice(Number(b.dataset.bsvConsRemove), 1); renderConsumers(); }
    });
    document.getElementById("bsvMdStatusBar").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-bsv-move]");
      if (b) openMove(b.dataset.bsvMove);
    });
    document.getElementById("bsvStatusForm").addEventListener("submit", ev => { ev.preventDefault(); saveMove(); });
    picker("bsvSupKind", "bsvSupSearch", "bsvSupCi");
    picker("bsvImpKind", "bsvImpSearch", "bsvImpCi");
    document.getElementById("bsvSupForm").addEventListener("submit", ev => { ev.preventDefault(); proposeSupport(); });
    document.getElementById("bsvImpRun").addEventListener("click", runImpact);
    document.getElementById("bsvSettingForm").addEventListener("submit", ev => { ev.preventDefault(); saveSettings(); });
  }

  // Kind select + search box + result select, filled from relationships/ci-lookup.
  function picker(kindId, searchId, selectId) {
    const kind = document.getElementById(kindId), search = document.getElementById(searchId), sel = document.getElementById(selectId);
    let t = null;
    const load = async () => {
      if (!state.organizationId) return;
      const qs = new URLSearchParams({ organizationId: state.organizationId, kind: kind.value });
      if (search.value.trim()) qs.set("search", search.value.trim());
      const res = await api("GET", `/relationships/ci-lookup?${qs}`);
      const rows = res.ok ? (res.data.data || []) : [];
      sel.innerHTML = `<option value="">--</option>` + rows.filter(c => c.isUsable).map(c =>
        `<option value="${esc(c.ciKind + ":" + c.ciId)}">${esc(c.ciName)}${c.ciClass && c.ciClass !== KINDS[c.ciKind] ? " (" + esc(c.ciClass) + ")" : ""}</option>`).join("");
    };
    kind.addEventListener("change", () => { search.value = ""; load(); });
    search.addEventListener("input", () => { clearTimeout(t); t = setTimeout(load, 300); });
    sel._bsvLoad = load;
  }
  function picked(selectId) {
    const v = val(selectId);
    if (!v) return null;
    const i = v.indexOf(":");
    return { kind: v.substring(0, i), id: Number(v.substring(i + 1)) };
  }

  async function changeOrg(id) {
    state.organizationId = id;
    state.config = null;
    hideMessage();
    state.pager?.reset(true);
    state.confPager?.reset(true);
    if (id) {
      await loadConfig();
      ["bsvSupCi", "bsvImpCi"].forEach(s => document.getElementById(s)._bsvLoad?.());
    }
    await selectMainTab(state.mainTab);
  }

  async function loadConfig() {
    const res = await api("GET", `/business-services/config?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.config = res.data.data;
    const c = state.config, opt = (v, l) => `<option value="${esc(v)}">${esc(l)}</option>`;
    const people = opt("", "--") + c.employees.map(e => opt(e.employeeId, e.employeeName)).join("");
    document.getElementById("bsvFOwner").innerHTML = people;
    document.getElementById("bsvFManager").innerHTML = people;
    document.getElementById("bsvFDept").innerHTML = opt("", "--") + c.departments.map(d => opt(d.departmentId, d.departmentName)).join("");
    document.getElementById("bsvFCrit").innerHTML = opt("", "--") + c.criticalities.map(x => opt(x.criticalityId, x.criticalityCode)).join("");
    document.getElementById("bsvStMin").value = c.settings?.minSupportingRelationships ?? 1;
    document.getElementById("bsvStApproval").checked = c.settings ? !!c.settings.retirementApprovalRequired : true;
    document.querySelectorAll("#bsvSettingForm input").forEach(x => { x.disabled = !CAN_EDIT; });
    fillConsumerRefs();
  }

  async function selectMainTab(name) {
    state.mainTab = name;
    document.querySelectorAll("[data-bsv-main]").forEach(x => { const on = x.dataset.bsvMain === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    document.querySelectorAll("[data-bsv-mainpanel]").forEach(p => { p.hidden = p.dataset.bsvMainpanel !== name; });
    if (name === "SERVICES") await refreshServices();
    else if (name === "TREE") await refreshTree();
    else if (name === "CONFLICTS") await refreshConflicts();
  }

  // ------------------------------------------------------------------ services
  async function refreshServices() {
    const body = document.getElementById("bsvBody");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); state.pager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.pager ? state.pager.page() : 1, pageSize: state.pager ? state.pager.size() : 25 });
    if (val("bsvFltStatus")) qs.set("status", val("bsvFltStatus"));
    if (val("bsvFltType")) qs.set("serviceType", val("bsvFltType"));
    if (val("bsvFltSearch")) qs.set("search", val("bsvFltSearch"));
    const res = await api("GET", `/business-services?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.pager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.pager?.setTotal(res.data.data.totalRows, rows.length);
    body.innerHTML = rows.map(s => {
      const [sl, sc] = STATUS[s.status] || [s.status, ""];
      return `<tr><td><button class="pm-link-button" type="button" data-bsv-open="${s.serviceId}">${esc(s.serviceName)}</button><div class="bsv-note">${esc(s.serviceCode)}${s.accountableDepartmentName ? " - " + esc(s.accountableDepartmentName) : ""}</div></td>
        <td>${esc(TYPES[s.serviceType] || s.serviceType)}</td>
        <td><span class="bsv-chip ${sc}">${esc(sl)}</span>${s.pendingRetirement ? `<div><span class="bsv-chip bsv-st-wait">Retirement pending</span></div>` : ""}</td>
        <td>${esc(s.criticalityCode || "--")}</td><td>${objectives(s)}</td>
        <td>${esc(s.businessOwnerName || "--")}<div class="bsv-note">${esc(s.serviceManagerName || "")}</div></td>
        <td>${esc(s.supportCount)} item(s)<div class="bsv-note">supports ${esc(s.supportsCount)} service(s), ${esc(s.consumerCount)} consumer(s)</div></td>
        <td>${s.conflictCount ? `<span class="bsv-chip bsv-st-bad">${esc(s.conflictCount)}</span>` : "--"}</td></tr>`;
    }).join("") || empty(8, "No services. Add the first one with New service.");
  }
  function objectives(s) { return `${esc(s.rtoHours ?? "-")} / ${esc(s.rpoHours ?? "-")} / ${esc(s.mtpdHours ?? "-")}`; }

  // ------------------------------------------------------------------ service window
  async function openService(id) {
    if (!state.config) return;
    hide("bsvMdMessage");
    if (!id) {
      state.current = null;
      state.consumers = [];
      document.getElementById("bsvMdTitle").textContent = "New business service";
      document.getElementById("bsvMdInfo").innerHTML = "";
      document.getElementById("bsvMdStatusBar").innerHTML = "";
      ["bsvFCode", "bsvFName", "bsvFDesc", "bsvFOutcome", "bsvFReview", "bsvFRto", "bsvFRpo", "bsvFMtpd", "bsvFHours", "bsvFData", "bsvFPrivacy", "bsvFSla",
       "bsvFOwner", "bsvFManager", "bsvFDept", "bsvFCrit", "bsvFC", "bsvFI", "bsvFA"].forEach(x => { document.getElementById(x).value = ""; });
      document.getElementById("bsvFType").value = "BUSINESS";
      renderConsumers();
      setEditable(CAN_ADD);
      document.getElementById("bsvDetail").hidden = true;
      document.getElementById("bsvModal").hidden = false;
      return;
    }
    const res = await api("GET", `/business-services/${id}?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    const d = res.data.data, s = d.service;
    state.current = d;
    const [sl] = STATUS[s.status] || [s.status];
    document.getElementById("bsvMdTitle").textContent = `${s.serviceName} (${s.serviceCode})`;
    document.getElementById("bsvMdInfo").innerHTML = [
      ["Status", sl + (s.pendingRetirement ? " - retirement waiting for approval" : "")], ["Version", s.versionNo],
      ["Note", s.statusNote || "--"],
      ["Consumer review", s.consumerReviewNote || "--"], ["Contract assessment", s.contractAssessmentNote || "--"],
      ["Retirement requested", s.pendingRetirement ? `${s.pendingBy} ${dateTime(s.pendingDt)}` : "--"]
    ].map(([k, v]) => `<div><span>${esc(k)}</span>${esc(v)}</div>`).join("");
    const set = (x, v) => { document.getElementById(x).value = v ?? ""; };
    set("bsvFCode", s.serviceCode); set("bsvFName", s.serviceName); set("bsvFType", s.serviceType); set("bsvFDesc", s.description);
    set("bsvFOutcome", s.customerOutcome); set("bsvFOwner", s.businessOwnerEmployeeId); set("bsvFManager", s.serviceManagerEmployeeId);
    set("bsvFDept", s.accountableDepartmentId); set("bsvFCrit", s.criticalityId); set("bsvFReview", date(s.reviewDate));
    set("bsvFC", s.confidentialityRating); set("bsvFI", s.integrityRating); set("bsvFA", s.availabilityRating);
    set("bsvFRto", s.rtoHours); set("bsvFRpo", s.rpoHours); set("bsvFMtpd", s.mtpdHours); set("bsvFHours", s.serviceHours);
    set("bsvFData", s.dataClassification); set("bsvFPrivacy", s.privacyClassification); set("bsvFSla", s.slaText);
    state.consumers = (d.consumers || []).map(c => ({ consumerKind: c.consumerKind, consumerRefId: c.consumerRefId, consumerName: c.consumerName, note: c.note }));
    renderConsumers();
    const retired = s.status === "RETIRED";
    setEditable(CAN_EDIT && !retired);
    renderStatusBar(s);

    document.getElementById("bsvDetail").hidden = false;
    document.getElementById("bsvSupBody").innerHTML = (d.supporting || []).map(x => {
      const [rl, rc] = REL[x.status] || [x.status, ""];
      return `<tr><td>${esc(x.ciName || "--")}<div class="bsv-note">${esc(KINDS[x.ciKind] || x.ciKind)}${x.ciClass && x.ciClass !== KINDS[x.ciKind] ? " - " + esc(x.ciClass) : ""}${x.ciStatus ? " - " + esc(x.ciStatus) : ""}</div></td>
        <td>${esc(x.serviceRole || "--")}</td><td>${x.isCritical ? `<span class="bsv-chip bsv-st-bad">Critical</span><div class="bsv-note">${esc(label(x.dependencyCriticality))}</div>` : "--"}</td>
        <td>${esc(date(x.effectiveFrom))}${x.effectiveTo ? " to " + esc(date(x.effectiveTo)) : ""}</td>
        <td><span class="bsv-chip ${rc}">${esc(rl)}</span>${x.pendingAction ? `<div class="bsv-note">${x.pendingAction === "RETIRE" ? "Retirement" : "Change"} pending</div>` : ""}<div class="bsv-note">#${esc(x.relationshipId)}</div></td></tr>`;
    }).join("") || empty(5, "No supporting items yet.");
    document.getElementById("bsvSupForm").hidden = retired || !CAN_ADD;
    document.getElementById("bsvSupFrom").value = new Date().toISOString().substring(0, 10);
    ["bsvSupRole", "bsvSupSearch"].forEach(x => { document.getElementById(x).value = ""; });
    document.getElementById("bsvSupCritical").checked = false;
    document.getElementById("bsvSupCriticality").value = "";
    document.getElementById("bsvSupportsBody").innerHTML = (d.supports || []).map(x => `<tr>
        <td><button class="pm-link-button" type="button" data-bsv-open="${x.serviceId}">${esc(x.serviceName)}</button><div class="bsv-note">${esc(label(x.serviceStatus))}</div></td>
        <td>${esc(x.serviceRole || "--")}</td><td>${x.isCritical ? "Yes" : "--"}</td><td>${esc(label(x.status))}</td></tr>`).join("")
      || empty(4, "It supports no other service.");
    document.getElementById("bsvMdConfBody").innerHTML = (d.conflicts || []).map(x => `<tr><td>${esc(CONFLICT[x.conflictCode] || x.conflictCode)}</td>
        <td>${esc(x.ciName || "--")}</td><td>${esc(x.message)}</td></tr>`).join("") || empty(3, "No conflicts.");
    document.getElementById("bsvHistBody").innerHTML = (d.history || []).map(h => `<tr><td>${esc(h.versionNo)}</td><td>${esc(label(h.actionCode))}</td>
        <td>${esc(label(h.status))}</td><td>${esc(h.note || "")}</td><td>${esc(h.actorName || h.actor)}</td><td>${esc(dateTime(h.enteredDt))}</td></tr>`).join("")
      || empty(6, "No history.");
    document.getElementById("bsvModal").hidden = false;
  }

  function renderStatusBar(s) {
    const bar = document.getElementById("bsvMdStatusBar");
    if (s.pendingRetirement) {
      bar.innerHTML = (CAN_APPROVE ? `<button type="button" class="pm-button primary" data-bsv-move="APPROVE">Approve retirement</button>
          <button type="button" class="pm-button" data-bsv-move="REJECT">Reject retirement</button>` : "")
        + (CAN_EDIT ? `<button type="button" class="pm-button" data-bsv-move="WITHDRAW">Withdraw retirement (requester)</button>` : "");
      return;
    }
    bar.innerHTML = CAN_EDIT ? (MOVES[s.status] || []).map(m => `<button type="button" class="pm-button${m === "ACTIVE" ? " primary" : ""}" data-bsv-move="${m}">${esc(m === "RETIRED" && s.status === "RETIRING" ? "Retire" : "Move to " + (STATUS[m] || [m])[0])}</button>`).join("") : "";
  }

  function setEditable(editable) {
    document.querySelectorAll("#bsvForm input, #bsvForm select, #bsvForm textarea").forEach(x => { x.disabled = !editable; });
    document.getElementById("bsvSaveBar").hidden = !editable;
    document.getElementById("bsvConsAddBar").hidden = !editable;
    state.formEditable = editable;
  }

  function fillConsumerRefs() {
    if (!state.config) return;
    const kind = val("bsvConsKind"), sel = document.getElementById("bsvConsRef");
    const list = kind === "DEPARTMENT" ? state.config.departments.map(d => [d.departmentId, d.departmentName])
      : kind === "BUSINESS_FUNCTION" ? state.config.businessFunctions.map(f => [f.businessFunctionId, f.functionName])
      : kind === "LOCATION" ? state.config.locations.map(l => [l.locationId, l.locationName]) : [];
    sel.innerHTML = list.map(([v, l]) => `<option value="${esc(v)}">${esc(l)}</option>`).join("");
    sel.hidden = kind === "EXTERNAL";
    document.getElementById("bsvConsName").hidden = kind !== "EXTERNAL";
  }

  function consumerName(c) {
    if (c.consumerKind === "EXTERNAL") return c.consumerName;
    const list = c.consumerKind === "DEPARTMENT" ? state.config.departments.map(d => [d.departmentId, d.departmentName])
      : c.consumerKind === "BUSINESS_FUNCTION" ? state.config.businessFunctions.map(f => [f.businessFunctionId, f.functionName])
      : state.config.locations.map(l => [l.locationId, l.locationName]);
    return (list.find(([v]) => Number(v) === Number(c.consumerRefId)) || [null, c.consumerName || "#" + c.consumerRefId])[1];
  }

  function renderConsumers() {
    document.getElementById("bsvConsBody").innerHTML = state.consumers.map((c, i) => `<tr><td>${esc(CONSUMER[c.consumerKind] || c.consumerKind)}</td>
        <td>${esc(consumerName(c))}</td><td>${esc(c.note || "")}</td>
        <td>${state.formEditable !== false ? `<button class="pm-button" type="button" data-bsv-cons-remove="${i}" title="Remove">&times;</button>` : ""}</td></tr>`).join("")
      || empty(4, "No consumers.");
  }

  function addConsumer() {
    const kind = val("bsvConsKind");
    const c = kind === "EXTERNAL" ? { consumerKind: kind, consumerRefId: null, consumerName: val("bsvConsName"), note: val("bsvConsNote") || null }
                                  : { consumerKind: kind, consumerRefId: Number(val("bsvConsRef")) || null, consumerName: null, note: val("bsvConsNote") || null };
    if ((kind === "EXTERNAL" && !c.consumerName) || (kind !== "EXTERNAL" && !c.consumerRefId)) { show("bsvMdMessage", "Select or name the consumer."); return; }
    if (state.consumers.some(x => x.consumerKind === c.consumerKind && (x.consumerRefId ?? x.consumerName) === (c.consumerRefId ?? c.consumerName))) return;
    state.consumers.push(c);
    document.getElementById("bsvConsName").value = "";
    document.getElementById("bsvConsNote").value = "";
    renderConsumers();
  }

  async function saveService() {
    const s = state.current?.service, num = id => val(id) === "" ? null : Number(val(id));
    const res = await api("POST", "/business-services", {
      organizationId: state.organizationId, serviceId: s ? s.serviceId : null,
      serviceCode: val("bsvFCode"), serviceName: val("bsvFName"), serviceType: val("bsvFType"),
      description: val("bsvFDesc") || null, customerOutcome: val("bsvFOutcome") || null,
      businessOwnerEmployeeId: num("bsvFOwner"), serviceManagerEmployeeId: num("bsvFManager"), accountableDepartmentId: num("bsvFDept"),
      criticalityId: num("bsvFCrit"), confidentialityRating: num("bsvFC"), integrityRating: num("bsvFI"), availabilityRating: num("bsvFA"),
      rtoHours: num("bsvFRto"), rpoHours: num("bsvFRpo"), mtpdHours: num("bsvFMtpd"),
      serviceHours: val("bsvFHours") || null, slaText: val("bsvFSla") || null,
      dataClassification: val("bsvFData") || null, privacyClassification: val("bsvFPrivacy") || null,
      reviewDate: val("bsvFReview") || null, consumers: state.consumers,
      expectedRecordVersion: s ? s.recordVersion : null
    });
    if (!res.ok) { show("bsvMdMessage", res.error); return; }
    showMessage(res.data.result === "CREATED" ? "Service created as Draft." : "Service saved.", "success");
    await refreshServices();
    await openService(res.data.id);
  }

  function openMove(move) {
    const s = state.current.service;
    state.move = move;
    const decision = ["APPROVE", "REJECT", "WITHDRAW"].includes(move);
    const retire = move === "RETIRED" && s.status === "RETIRING";
    document.getElementById("bsvSmTitle").textContent = decision ? `${label(move)} retirement` : `${s.serviceName}: ${(STATUS[move] || [move])[0]}`;
    document.getElementById("bsvSmInfo").textContent = move === "ACTIVE" ? "Needs a business owner and the minimum active supporting relationships."
      : retire ? "Needs no active critical dependants, the consumer review and the contract assessment; approved by another person where configured."
      : decision ? "Approval checks the dependants again; the service and its relationships are then retired." : "";
    const noteOptional = (["DRAFT", "DESIGN"].includes(s.status) && ["DESIGN", "ACTIVE"].includes(move)) || move === "APPROVE" || move === "WITHDRAW";
    document.getElementById("bsvSmNoteLabel").textContent = noteOptional ? "Note" : "Note *";
    document.getElementById("bsvSmConsumerWrap").hidden = !retire;
    document.getElementById("bsvSmContractWrap").hidden = !retire;
    ["bsvSmNote", "bsvSmConsumer", "bsvSmContract"].forEach(x => { document.getElementById(x).value = ""; });
    hide("bsvSmMessage");
    document.getElementById("bsvStatusModal").hidden = false;
  }

  async function saveMove() {
    const s = state.current.service, move = state.move;
    const decision = ["APPROVE", "REJECT", "WITHDRAW"].includes(move);
    const res = decision
      ? await api("POST", `/business-services/${s.serviceId}/retirement-decision`, {
          organizationId: state.organizationId, decision: move, decisionNote: val("bsvSmNote") || null, expectedRecordVersion: s.recordVersion })
      : await api("POST", `/business-services/${s.serviceId}/transition`, {
          organizationId: state.organizationId, toStatus: move, note: val("bsvSmNote") || null,
          consumerReviewNote: val("bsvSmConsumer") || null, contractAssessmentNote: val("bsvSmContract") || null,
          expectedRecordVersion: s.recordVersion });
    if (!res.ok) { show("bsvSmMessage", res.error); return; }
    document.getElementById("bsvStatusModal").hidden = true;
    showMessage(res.data.result === "PENDING_APPROVAL" ? "The retirement waits for approval." : `Done: ${label(res.data.result)}.`, "success");
    await refreshServices();
    await openService(s.serviceId);
  }

  async function proposeSupport() {
    const s = state.current.service, ci = picked("bsvSupCi");
    if (!ci) { show("bsvMdMessage", "Select the supporting item."); return; }
    const res = await api("POST", "/relationships", {
      organizationId: state.organizationId, relationshipId: null, relationshipTypeCode: "SUPPORTS_SERVICE",
      sourceKind: ci.kind, sourceId: ci.id, targetKind: "SERVICE", targetId: s.serviceId,
      isCritical: document.getElementById("bsvSupCritical").checked, dependencyCriticality: val("bsvSupCriticality") || null,
      effectiveFrom: val("bsvSupFrom") || null, serviceRole: val("bsvSupRole") || null
    });
    if (!res.ok) { show("bsvMdMessage", res.error); return; }
    await openService(s.serviceId);
    show("bsvMdMessage", "Supporting item proposed; approve it in Asset Relationships.", "success");
  }

  // ------------------------------------------------------------------ hierarchy
  async function refreshTree() {
    const host = document.getElementById("bsvTree");
    if (!state.organizationId) { host.textContent = "Select an organization."; return; }
    const res = await api("GET", `/business-services/tree?organizationId=${state.organizationId}`);
    if (!res.ok) { host.textContent = res.error; return; }
    const services = res.data.data.services || [], links = res.data.data.links || [];
    const byId = new Map(services.map(s => [s.serviceId, s]));
    const children = new Map();
    links.forEach(l => { if (!children.has(l.parentServiceId)) children.set(l.parentServiceId, []); children.get(l.parentServiceId).push(l); });
    const hasParent = new Set(links.filter(l => byId.has(l.parentServiceId)).map(l => l.childServiceId));
    const node = (s, link, path) => {
      const [sl, sc] = STATUS[s.status] || [s.status, ""];
      const kids = path.includes(s.serviceId) ? [] : (children.get(s.serviceId) || []).filter(l => byId.has(l.childServiceId));
      return `<li><button class="pm-link-button" type="button" data-bsv-open="${s.serviceId}">${esc(s.serviceName)}</button>
          <span class="bsv-note">${esc(s.serviceCode)} - ${esc(TYPES[s.serviceType] || s.serviceType)} - ${esc(s.criticalityCode || "no criticality")} - RTO ${esc(s.rtoHours ?? "-")} h - ${esc(s.businessOwnerName || "no owner")}</span>
          <span class="bsv-chip ${sc}">${esc(sl)}</span>${link && link.status !== "ACTIVE" ? ` <span class="bsv-chip bsv-st-wait">${esc(label(link.status))} link</span>` : ""}${link && link.isCritical ? ' <span class="bsv-chip bsv-st-bad">Critical</span>' : ""}
          ${kids.length ? `<ul>${kids.map(l => node(byId.get(l.childServiceId), l, path.concat(s.serviceId))).join("")}</ul>` : ""}</li>`;
    };
    const roots = services.filter(s => !hasParent.has(s.serviceId));
    host.innerHTML = services.length ? `<ul>${roots.map(s => node(s, null, [])).join("")}</ul>` : "No services.";
  }

  // ------------------------------------------------------------------ conflicts
  async function refreshConflicts() {
    const body = document.getElementById("bsvConfBody");
    if (!state.organizationId) { body.innerHTML = empty(4, "Select an organization."); state.confPager?.clear(); return; }
    body.innerHTML = empty(4, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.confPager ? state.confPager.page() : 1, pageSize: state.confPager ? state.confPager.size() : 25 });
    if (val("bsvConfSearch")) qs.set("search", val("bsvConfSearch"));
    const res = await api("GET", `/business-services/conflicts?${qs}`);
    if (!res.ok) { body.innerHTML = empty(4, res.error); state.confPager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.confPager?.setTotal(res.data.data.totalRows, rows.length);
    body.innerHTML = rows.map(x => `<tr><td><button class="pm-link-button" type="button" data-bsv-open="${x.serviceId}">${esc(x.serviceName)}</button></td>
        <td><span class="bsv-chip bsv-st-wait">${esc(CONFLICT[x.conflictCode] || x.conflictCode)}</span></td>
        <td>${esc(x.ciName || "--")}${x.ciKind ? `<div class="bsv-note">${esc(KINDS[x.ciKind] || x.ciKind)}</div>` : ""}</td><td>${esc(x.message)}</td></tr>`).join("")
      || empty(4, "No conflicts.");
  }

  // ------------------------------------------------------------------ service impact
  async function runImpact() {
    const body = document.getElementById("bsvImpBody"), ci = picked("bsvImpCi");
    if (!state.organizationId || !ci) { body.innerHTML = empty(7, "Select an item."); return; }
    body.innerHTML = empty(7, "Analysing...");
    const qs = new URLSearchParams({ organizationId: state.organizationId, ciKind: ci.kind, ciId: ci.id, direction: "DOWNSTREAM", maxDepth: 10 });
    const res = await api("GET", `/relationships/impact?${qs}`);
    if (!res.ok) { body.innerHTML = empty(7, res.error); return; }
    body.innerHTML = (res.data.data.services || []).map(v => {
      const [sl, sc] = STATUS[v.serviceStatus] || [v.serviceStatus, ""];
      return `<tr><td>${esc(v.impactLevel)}</td><td><button class="pm-link-button" type="button" data-bsv-open="${v.serviceId}">${esc(v.serviceName)}</button><div class="bsv-note">${esc(v.serviceCode)}</div></td>
        <td><span class="bsv-chip ${sc}">${esc(sl)}</span></td><td>${esc(v.criticalityCode || "--")}</td><td>${objectives(v)}</td>
        <td>${esc(v.businessOwnerName || "--")}<div class="bsv-note">${esc(v.serviceManagerName || "")}</div></td><td>${esc(v.consumers || "--")}</td></tr>`;
    }).join("") || empty(7, "No business service depends on it through active relationships.");
  }

  // ------------------------------------------------------------------ settings
  async function saveSettings() {
    const res = await api("POST", "/business-services/settings", {
      organizationId: state.organizationId, minSupportingRelationships: Number(val("bsvStMin")),
      retirementApprovalRequired: document.getElementById("bsvStApproval").checked
    });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    await loadConfig();
    showMessage("Settings saved.", "success");
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
  function label(code) { return code ? String(code).replace(/_/g, " ").toLowerCase().replace(/^./, c => c.toUpperCase()) : ""; }
  function empty(cols, text) { return `<tr><td colspan="${cols}" class="pm-empty">${esc(text)}</td></tr>`; }
  function showMessage(text, kind) {
    const el = document.getElementById("bsvMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.classList.toggle("info", kind === "info"); el.hidden = !text;
  }
  function hideMessage() { const el = document.getElementById("bsvMessage"); el.hidden = true; el.textContent = ""; }
  function show(id, text, kind) {
    const el = document.getElementById(id);
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.hidden = !text;
  }
  function hide(id) { const el = document.getElementById(id); el.hidden = true; el.textContent = ""; el.classList.remove("success"); }
  function val(id) { return (document.getElementById(id).value || "").trim(); }
  function date(v) { return v ? String(v).substring(0, 10) : ""; }   // SQL DATE values: yyyy-mm-dd
  function dateTime(v) { if (!v) return ""; const x = new Date(v); return isNaN(x) ? String(v) : x.toLocaleString(); }
  function esc(v) { return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
})();
