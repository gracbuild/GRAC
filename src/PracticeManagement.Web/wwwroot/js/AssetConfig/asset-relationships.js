// =====================================================================
// Asset Relationships (migration 440) -- BRD 5.4, 5.4.1, 5.4.2.
// Loaded by asset-relationships.cshtml. Relationships: relationships,
// relationships/{id}, relationships (save), relationships/{id}/action.
// Item picker: relationships/ci-lookup. Impact: relationships/impact.
// Types: relationships/config. The procedures hold every rule (permitted
// kinds, cardinality, loops, segregation of duties, pending changes of
// critical relationships); this screen shows them.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config/relationships";
  const root = document.getElementById("arlRoot");
  if (!root) return;
  const CAN_ADD = root.dataset.canAdd === "1";
  const CAN_EDIT = root.dataset.canEdit === "1";
  const CAN_APPROVE = root.dataset.canApprove === "1";

  const KINDS = { ASSET: "Asset", APPLICATION: "Application", PROCESS: "Process", VENDOR: "Vendor", LOCATION: "Location", SERVICE: "Business service",
                  CONTRACT: "Contract" };   // 441: services and contracts
  const STATUS = { PROPOSED: ["Proposed", "arl-st-wait"], ACTIVE: ["Active", "arl-st-active"], DISPUTED: ["Disputed", "arl-st-bad"],
                   INACTIVE: ["Inactive", "arl-st-ended"], RETIRED: ["Retired", "arl-st-ended"] };
  const CARD = { MANY: "Many to many", ONE_TARGET: "One target per source", ONE_SOURCE: "One source per target", ONE_TO_ONE: "One to one" };
  const LOOP = { BLOCK: "Block", FLAG: "Allow and flag", ALLOW: "Allow" };
  const SIDE = { SOURCE: "Source depends on target", TARGET: "Target depends on source", NONE: "No impact" };
  const ACTION = {
    APPROVE: ["Approve", "APPROVE", false], REJECT: ["Reject", "APPROVE", true], WITHDRAW: ["Withdraw", "EDIT", false],
    DISPUTE: ["Dispute", "EDIT", true], CONFIRM: ["Confirm", "APPROVE", true], RETIRE: ["Retire", "EDIT", true],
    ACCEPT_RETIREMENT: ["Accept for retirement", "APPROVE", true]
  };

  const state = { organizationId: null, config: null, mainTab: "RELATIONSHIPS", relPager: null, rows: [], current: null, action: null };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    state.relPager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "arlRelPager", onChange: refreshRelationships }) : null;
    ["arlFltKind", "arlImpKind", "arlRmSrcKind", "arlRmTgtKind"].forEach(id => {
      const sel = document.getElementById(id);
      Object.entries(KINDS).forEach(([k, l]) => sel.insertAdjacentHTML("beforeend", `<option value="${k}">${esc(l)}</option>`));
    });
    bind();
    await populateOrgs();
    const sel = document.getElementById("arlOrg");
    window.gracOrgPref.apply(sel);   // 2026-10-06: last-picked org, else lowest id
    // 451: opened from the Asset & Contract dashboard -- organization, tab and filter (Shared/dashboard-drill.js).
    const dashDrill = window.__pmDrill ? window.__pmDrill.read() : null;
    window.__pmDrill?.preselectFor(dashDrill, sel, { "": { status: "arlFltStatus" }, RELATIONSHIPS: { status: "arlFltStatus" } });
    await changeOrg(Number(sel.value) || null);
    window.__pmDrill?.showOnPage("arlRoot", "data-arl-main", dashDrill);
  }

  async function populateOrgs() {
    const sel = document.getElementById("arlOrg");
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
    document.getElementById("arlOrg").addEventListener("change", e => changeOrg(Number(e.target.value) || null));
    document.querySelectorAll("[data-arl-main]").forEach(b => b.addEventListener("click", () => selectMainTab(b.dataset.arlMain)));
    document.querySelectorAll("[data-close-arl]").forEach(b => b.addEventListener("click", () => { document.getElementById(b.dataset.closeArl).hidden = true; }));
    picker("arlFltKind", "arlFltCiSearch", "arlFltCi", () => { state.relPager?.reset(true); refreshRelationships(); });
    picker("arlImpKind", "arlImpCiSearch", "arlImpCi");
    picker("arlRmSrcKind", "arlRmSrcSearch", "arlRmSrc");
    picker("arlRmTgtKind", "arlRmTgtSearch", "arlRmTgt");
    let t1 = null;
    document.getElementById("arlFltSearch").addEventListener("input", () => { clearTimeout(t1); t1 = setTimeout(() => { state.relPager?.reset(true); refreshRelationships(); }, 300); });
    ["arlFltType", "arlFltStatus", "arlFltCritical", "arlFltPending"].forEach(id =>
      document.getElementById(id).addEventListener("change", () => { state.relPager?.reset(true); refreshRelationships(); }));
    document.getElementById("arlRelBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-arl-open]");
      if (b) openRelationship(Number(b.dataset.arlOpen));
    });
    document.getElementById("arlAdd")?.addEventListener("click", () => openRelationship(null));
    document.getElementById("arlRmType").addEventListener("change", applyTypeKinds);
    document.getElementById("arlRelForm").addEventListener("submit", ev => { ev.preventDefault(); saveRelationship(); });
    document.getElementById("arlRmActions").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-arl-action]");
      if (b) openAction(b.dataset.arlAction);
    });
    document.getElementById("arlActionForm").addEventListener("submit", ev => { ev.preventDefault(); saveAction(); });
    document.getElementById("arlImpRun").addEventListener("click", runImpact);
  }

  // Kind select + search box + result select, filled from ci-lookup.
  function picker(kindId, searchId, selectId, onPick) {
    const kind = document.getElementById(kindId), search = document.getElementById(searchId), sel = document.getElementById(selectId);
    let t = null;
    const load = async () => {
      if (!state.organizationId) return;
      const qs = new URLSearchParams({ organizationId: state.organizationId });
      if (kind.value) qs.set("kind", kind.value);
      if (search.value.trim()) qs.set("search", search.value.trim());
      const res = await api("GET", `/ci-lookup?${qs}`);
      const rows = res.ok ? (res.data.data || []) : [];
      sel.innerHTML = `<option value="">--</option>` + rows.map(c =>
        `<option value="${esc(c.ciKind + ":" + c.ciId)}">${esc(c.ciName)} (${esc(KINDS[c.ciKind] || c.ciKind)}${c.ciClass && c.ciClass !== KINDS[c.ciKind] ? ", " + esc(c.ciClass) : ""}${c.isUsable ? "" : ", " + esc(c.ciStatus)})</option>`).join("");
    };
    kind.addEventListener("change", () => { search.value = ""; load(); onPick?.(); });
    search.addEventListener("input", () => { clearTimeout(t); t = setTimeout(load, 300); });
    sel.addEventListener("change", () => onPick?.());
    sel._arlLoad = load;
  }
  function picked(selectId) {
    const v = val(selectId);
    if (!v) return null;
    const i = v.indexOf(":");
    return { kind: v.substring(0, i), id: Number(v.substring(i + 1)) };
  }
  // Puts one known item in a picker (editing an existing relationship).
  function setPicked(kindId, selectId, kind, id, name) {
    const ks = document.getElementById(kindId);
    if (![...ks.options].some(o => o.value === kind)) ks.insertAdjacentHTML("beforeend", `<option value="${esc(kind)}">${esc(KINDS[kind] || kind)}</option>`);
    ks.value = kind;
    document.getElementById(selectId).innerHTML = `<option value="${esc(kind + ":" + id)}">${esc(name || "#" + id)}</option>`;
  }

  async function changeOrg(id) {
    state.organizationId = id;
    state.config = null;
    hideMessage();
    state.relPager?.reset(true);
    if (id) {
      await loadConfig();
      ["arlFltCi", "arlImpCi"].forEach(s => document.getElementById(s)._arlLoad?.());
    }
    await selectMainTab(state.mainTab);
  }

  async function loadConfig() {
    const res = await api("GET", `/config?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.config = res.data.data;
    const keep = val("arlFltType");
    document.getElementById("arlFltType").innerHTML = `<option value="">All types</option>` +
      state.config.types.map(t => `<option value="${esc(t.typeCode)}">${esc(t.typeName)}</option>`).join("");
    document.getElementById("arlFltType").value = keep;
    const people = `<option value="">--</option>` + state.config.employees.map(e => `<option value="${e.employeeId}">${esc(e.employeeName)}</option>`).join("");
    document.getElementById("arlRmOwner").innerHTML = people;
    document.getElementById("arlRmVerifier").innerHTML = people;
  }

  async function selectMainTab(name) {
    state.mainTab = name;
    document.querySelectorAll("[data-arl-main]").forEach(x => { const on = x.dataset.arlMain === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    document.querySelectorAll("[data-arl-mainpanel]").forEach(p => { p.hidden = p.dataset.arlMainpanel !== name; });
    if (name === "TYPES") renderTypes();
    else if (name === "RELATIONSHIPS") await refreshRelationships();
  }

  // ------------------------------------------------------------------ relationships
  async function refreshRelationships() {
    const body = document.getElementById("arlRelBody");
    if (!state.organizationId) { body.innerHTML = empty(7, "Select an organization."); state.relPager?.clear(); return; }
    body.innerHTML = empty(7, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.relPager ? state.relPager.page() : 1, pageSize: state.relPager ? state.relPager.size() : 25 });
    const ci = picked("arlFltCi");
    if (ci) { qs.set("ciKind", ci.kind); qs.set("ciId", ci.id); }
    if (val("arlFltType")) qs.set("typeCode", val("arlFltType"));
    if (val("arlFltStatus")) qs.set("status", val("arlFltStatus"));
    if (document.getElementById("arlFltCritical").checked) qs.set("criticalOnly", "true");
    if (document.getElementById("arlFltPending").checked) qs.set("pendingOnly", "true");
    if (val("arlFltSearch")) qs.set("search", val("arlFltSearch"));
    const res = await api("GET", `?${qs}`);
    if (!res.ok) { body.innerHTML = empty(7, res.error); state.relPager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.relPager?.setTotal(res.data.data.totalRows, rows.length);
    state.rows = rows;
    body.innerHTML = rows.map(r => {
      const [sl, sc] = STATUS[r.status] || [r.status, ""];
      return `<tr><td>${ciCell(r.sourceKind, r.sourceName, r.sourceClass, r.sourceStatus)}</td>
        <td><button class="pm-link-button" type="button" data-arl-open="${r.relationshipId}">${esc(r.typeName)}</button>
            <div class="arl-note">#${esc(r.relationshipId)} v${esc(r.versionNo)}${r.inLoop ? " - loop (flagged)" : ""}${r.serviceRole ? " - " + esc(r.serviceRole) : ""}</div></td>
        <td>${ciCell(r.targetKind, r.targetName, r.targetClass, r.targetStatus)}</td>
        <td>${r.isCritical ? `<span class="arl-chip arl-st-bad">Critical</span><div class="arl-note">${esc(label(r.dependencyCriticality))}</div>` : "--"}
            ${r.impactWeight != null ? `<div class="arl-note">Weight ${esc(r.impactWeight)}</div>` : ""}
            ${r.retirementAccepted ? `<div class="arl-note">Accepted for retirement</div>` : ""}</td>
        <td>${esc(date(r.effectiveFrom))}${r.effectiveTo ? " to " + esc(date(r.effectiveTo)) : ""}<div class="arl-note">${esc(label(r.sourceCode))}${r.confidencePct != null ? ", " + esc(r.confidencePct) + "%" : ""}</div></td>
        <td><span class="arl-chip ${sc}">${esc(sl)}</span>
            ${r.pendingAction ? `<div><span class="arl-chip arl-st-wait">${r.pendingAction === "RETIRE" ? "Retirement" : "Change"} pending</span></div>` : ""}
            <div class="arl-note">${esc(label(r.verificationStatus))}</div></td>
        <td>${esc(r.ownerName || "--")}<div class="arl-note">${esc(r.verifierName || "")}</div></td></tr>`;
    }).join("") || empty(7, "No relationships match.");
  }

  function ciCell(kind, name, cls, status) {
    return `${esc(name || "--")}<div class="arl-note">${esc(KINDS[kind] || kind)}${cls && cls !== KINDS[kind] ? " - " + esc(cls) : ""}${status ? " - " + esc(status) : ""}</div>`;
  }

  // ------------------------------------------------------------------ relationship window
  async function openRelationship(id) {
    if (!state.config) return;
    hide("arlRmMessage");
    document.getElementById("arlRmType").innerHTML = state.config.types.filter(t => t.isActive || id)
      .map(t => `<option value="${esc(t.typeCode)}">${esc(t.typeName)} (${esc(t.brdPair)})</option>`).join("");
    if (!id) {
      state.current = null;
      document.getElementById("arlRmTitle").textContent = "Propose relationship";
      document.getElementById("arlRmInfo").innerHTML = "";
      ["arlRmSrcSearch", "arlRmTgtSearch", "arlRmWeight", "arlRmConfidence", "arlRmTo", "arlRmEvidence", "arlRmChange", "arlRmRole", "arlRmReason"].forEach(x => { document.getElementById(x).value = ""; });
      document.getElementById("arlRmFrom").value = new Date().toISOString().substring(0, 10);
      document.getElementById("arlRmCritical").checked = false;
      document.getElementById("arlRmCriticality").value = "";
      document.getElementById("arlRmOwner").value = "";
      document.getElementById("arlRmVerifier").value = "";
      applyTypeKinds();
      setEditable(CAN_ADD, true);
      document.getElementById("arlRmSaveLabel").textContent = "Propose";
      document.getElementById("arlRmActions").innerHTML = "";
      document.getElementById("arlRmHistBody").innerHTML = empty(6, "Not proposed yet.");
      document.getElementById("arlRmImpactBody").innerHTML = empty(4, "Shown once the relationship is proposed.");
      document.getElementById("arlRmImpactNote").textContent = "";
      document.getElementById("arlRelModal").hidden = false;
      return;
    }
    const res = await api("GET", `/${id}?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    const r = res.data.data.relationship, history = res.data.data.history || [];
    state.current = r;
    const [sl] = STATUS[r.status] || [r.status];
    document.getElementById("arlRmTitle").textContent = `${r.sourceName} ${r.typeName} ${r.targetName}`;
    document.getElementById("arlRmInfo").innerHTML = [
      ["Relationship", "#" + r.relationshipId + ", version " + r.versionNo], ["Status", sl + (r.inLoop ? " (loop flagged)" : "")],
      ["Inverse", `${r.targetName} ${r.inverseLabel} ${r.sourceName}`],
      ["Proposed", `${r.proposedBy || ""} ${dateTime(r.proposedDt)}`], ["Approved", r.approvedBy ? `${r.approvedBy} ${dateTime(r.approvedDt)}` : "--"],
      ["Pending", r.pendingAction ? `${r.pendingAction === "RETIRE" ? "Retirement" : "Change"} by ${r.pendingBy}: ${r.pendingReason || ""}` : "--"],
      ["Retirement", r.retirementAccepted ? `Accepted by ${r.retirementAcceptedBy}: ${r.retirementNote || ""}` : "--"],
      ["Note", r.statusNote || "--"]
    ].map(([k, v]) => `<div><span>${esc(k)}</span>${esc(v)}</div>`).join("");
    document.getElementById("arlRmType").value = r.typeCode;
    setPicked("arlRmSrcKind", "arlRmSrc", r.sourceKind, r.sourceId, r.sourceName);
    setPicked("arlRmTgtKind", "arlRmTgt", r.targetKind, r.targetId, r.targetName);
    document.getElementById("arlRmCritical").checked = !!r.isCritical;
    document.getElementById("arlRmCriticality").value = r.dependencyCriticality || "";
    document.getElementById("arlRmWeight").value = r.impactWeight ?? "";
    document.getElementById("arlRmConfidence").value = r.confidencePct ?? "";
    document.getElementById("arlRmFrom").value = date(r.effectiveFrom);
    document.getElementById("arlRmTo").value = date(r.effectiveTo);
    document.getElementById("arlRmOwner").value = r.ownerEmployeeId ? String(r.ownerEmployeeId) : "";
    document.getElementById("arlRmVerifier").value = r.verifierEmployeeId ? String(r.verifierEmployeeId) : "";
    document.getElementById("arlRmEvidence").value = r.evidenceReference || "";
    document.getElementById("arlRmChange").value = r.changeReference || "";
    document.getElementById("arlRmRole").value = r.serviceRole || "";   // 441
    document.getElementById("arlRmReason").value = "";
    const changeable = CAN_EDIT && ["PROPOSED", "ACTIVE", "DISPUTED"].includes(r.status) && !r.pendingAction;
    setEditable(changeable, false);
    document.getElementById("arlRmSaveLabel").textContent = r.status === "ACTIVE" && r.isCritical ? "Request change" : "Save change";
    renderActions(r);
    document.getElementById("arlRmHistBody").innerHTML = history.map(h => `<tr><td>${esc(h.versionNo)}</td><td>${esc(label(h.actionCode))}</td>
        <td>${esc(label(h.status))}</td><td>${esc(h.note || "")}</td><td>${esc(h.actorName || h.actor)}</td><td>${esc(dateTime(h.enteredDt))}</td></tr>`).join("")
      || empty(6, "No history.");
    document.getElementById("arlRelModal").hidden = false;
    await loadPreview(r);
  }

  // Impact preview: what depends on the provider end -- including this relationship while it is proposed.
  async function loadPreview(r) {
    const body = document.getElementById("arlRmImpactBody");
    const type = state.config.types.find(t => t.typeCode === r.typeCode);
    if (!type || type.dependentSide === "NONE") {
      body.innerHTML = empty(4, "This relationship type carries no impact.");
      document.getElementById("arlRmImpactNote").textContent = "";
      return;
    }
    const provider = type.dependentSide === "SOURCE" ? { kind: r.targetKind, id: r.targetId, name: r.targetName } : { kind: r.sourceKind, id: r.sourceId, name: r.sourceName };
    const qs = new URLSearchParams({ organizationId: state.organizationId, ciKind: provider.kind, ciId: provider.id, direction: "DOWNSTREAM", maxDepth: 5 });
    if (r.status === "PROPOSED") qs.set("previewRelationshipId", r.relationshipId);
    const res = await api("GET", `/impact?${qs}`);
    if (!res.ok) { body.innerHTML = empty(4, res.error); return; }
    const rows = res.data.data.rows || [];
    document.getElementById("arlRmImpactNote").textContent = `-- what is affected when ${provider.name} fails (${rows.length} item(s)${r.status === "PROPOSED" ? ", including this proposal" : ""}).`;
    body.innerHTML = rows.map(x => `<tr><td>${esc(x.impactLevel)}</td><td>${esc(x.ciName)}${x.viaPreview ? ' <span class="arl-chip arl-st-wait">This proposal</span>' : ""}</td>
        <td>${esc(KINDS[x.ciKind] || x.ciKind)}${x.ciClass && x.ciClass !== KINDS[x.ciKind] ? " - " + esc(x.ciClass) : ""}</td>
        <td>${esc(x.viaLabel)} ${esc(x.fromName || "")}${x.viaCritical ? ' <span class="arl-chip arl-st-bad">Critical</span>' : ""}</td></tr>`).join("")
      || empty(4, "Nothing depends on it.");
  }

  function renderActions(r) {
    const can = p => (p === "APPROVE" ? CAN_APPROVE : CAN_EDIT);
    const list = [];
    if (r.status === "PROPOSED") list.push("APPROVE", "REJECT", "WITHDRAW");
    else if (r.pendingAction) list.push("APPROVE", "REJECT", "WITHDRAW");
    else if (r.status === "ACTIVE") { list.push("DISPUTE", "RETIRE"); if (r.isCritical && !r.retirementAccepted) list.push("ACCEPT_RETIREMENT"); }
    else if (r.status === "DISPUTED") list.push("CONFIRM", "RETIRE");
    else if (r.status === "INACTIVE") list.push("RETIRE");
    document.getElementById("arlRmActions").innerHTML = list.filter(a => can(ACTION[a][1]))
      .map(a => `<button type="button" class="pm-button${a === "APPROVE" || a === "CONFIRM" ? " primary" : ""}" data-arl-action="${a}">${esc(r.pendingAction && a !== "WITHDRAW" ? ACTION[a][0] + " " + (r.pendingAction === "RETIRE" ? "retirement" : "change") : ACTION[a][0])}</button>`).join("");
  }

  function setEditable(editable, isNew) {
    document.querySelectorAll("#arlRelForm input, #arlRelForm select, #arlRelForm textarea").forEach(x => { x.disabled = !editable; });
    ["arlRmType", "arlRmSrcKind", "arlRmSrcSearch", "arlRmSrc", "arlRmTgtKind", "arlRmTgtSearch", "arlRmTgt"].forEach(x => {
      document.getElementById(x).disabled = !(editable && isNew);
    });
    document.getElementById("arlRmSaveBar").hidden = !editable;
  }

  // Limits the kind selects to the kinds the chosen type permits.
  function applyTypeKinds() {
    const t = state.config.types.find(x => x.typeCode === val("arlRmType"));
    if (!t) return;
    [["arlRmSrcKind", t.sourceKinds, "arlRmSrc"], ["arlRmTgtKind", t.targetKinds, "arlRmTgt"]].forEach(([id, kinds, selId]) => {
      const allowed = String(kinds).split(",");
      const sel = document.getElementById(id), keep = sel.value;
      sel.innerHTML = allowed.map(k => `<option value="${esc(k)}">${esc(KINDS[k] || k)}</option>`).join("");
      sel.value = allowed.includes(keep) ? keep : allowed[0];
      document.getElementById(selId)._arlLoad?.();
    });
  }

  async function saveRelationship() {
    const r = state.current, src = picked("arlRmSrc"), tgt = picked("arlRmTgt");
    if (!r && (!src || !tgt)) { show("arlRmMessage", "Select the source and the target."); return; }
    const res = await api("POST", "", {
      organizationId: state.organizationId, relationshipId: r ? r.relationshipId : null,
      relationshipTypeCode: r ? r.typeCode : val("arlRmType"),
      sourceKind: r ? r.sourceKind : src.kind, sourceId: r ? r.sourceId : src.id,
      targetKind: r ? r.targetKind : tgt.kind, targetId: r ? r.targetId : tgt.id,
      isCritical: document.getElementById("arlRmCritical").checked, dependencyCriticality: val("arlRmCriticality") || null,
      impactWeight: val("arlRmWeight") === "" ? null : Number(val("arlRmWeight")),
      confidencePct: val("arlRmConfidence") === "" ? null : Number(val("arlRmConfidence")),
      effectiveFrom: val("arlRmFrom") || null, effectiveTo: val("arlRmTo") || null,
      ownerEmployeeId: Number(val("arlRmOwner")) || null, verifierEmployeeId: Number(val("arlRmVerifier")) || null,
      evidenceReference: val("arlRmEvidence") || null, changeReference: val("arlRmChange") || null, reason: val("arlRmReason") || null,
      serviceRole: val("arlRmRole") || null,   // 441
      expectedRecordVersion: r ? r.recordVersion : null
    });
    if (!res.ok) { show("arlRmMessage", res.error); return; }
    const id = res.data.id;
    showMessage(res.data.result === "PENDING_APPROVAL" ? "The change waits for approval; the relationship stays as it is until then."
      : res.data.result === "PROPOSED" ? "Relationship proposed; it becomes Active when approved." : "Relationship saved.", "success");
    await refreshRelationships();
    if (id) await openRelationship(id);
  }

  function openAction(action) {
    const r = state.current, [name, , needsNote] = ACTION[action];
    state.action = action;
    document.getElementById("arlAcTitle").textContent = name;
    document.getElementById("arlAcInfo").textContent = action === "RETIRE" && r.isCritical && r.status === "ACTIVE"
      ? "A critical relationship is retired once another person approves it."
      : action === "ACCEPT_RETIREMENT" ? "The dependency stays active but no longer blocks the retirement of the item it relies on."
      : `${r.sourceName} ${r.typeName} ${r.targetName}`;
    document.getElementById("arlAcNoteLabel").textContent = needsNote ? "Note *" : "Note";
    document.getElementById("arlAcNote").value = "";
    hide("arlAcMessage");
    document.getElementById("arlActionModal").hidden = false;
  }

  async function saveAction() {
    const r = state.current;
    const res = await api("POST", `/${r.relationshipId}/action`, {
      organizationId: state.organizationId, action: state.action, note: val("arlAcNote") || null, expectedRecordVersion: r.recordVersion
    });
    if (!res.ok) { show("arlAcMessage", res.error); return; }
    document.getElementById("arlActionModal").hidden = true;
    showMessage(res.data.result === "PENDING_APPROVAL" ? "The retirement waits for approval." : `Done: ${label(res.data.result)}.`, "success");
    await refreshRelationships();
    await openRelationship(r.relationshipId);
  }

  // ------------------------------------------------------------------ impact analysis
  async function runImpact() {
    const body = document.getElementById("arlImpBody"), ci = picked("arlImpCi");
    document.getElementById("arlImpSvcBody").innerHTML = "";   // 441
    if (!state.organizationId || !ci) { body.innerHTML = empty(6, "Select an item."); return; }
    body.innerHTML = empty(6, "Analysing...");
    const qs = new URLSearchParams({ organizationId: state.organizationId, ciKind: ci.kind, ciId: ci.id,
      direction: val("arlImpDirection"), maxDepth: val("arlImpDepth") });
    if (document.getElementById("arlImpCritical").checked) qs.set("criticalOnly", "true");
    const res = await api("GET", `/impact?${qs}`);
    if (!res.ok) { body.innerHTML = empty(6, res.error); return; }
    const rows = res.data.data.rows || [], s = res.data.data.summary || {};
    document.getElementById("arlImpSummary").textContent = `${s.ciName || ""}: ${s.reachedCount || 0} item(s) ${s.direction === "UPSTREAM" ? "it relies on" : "affected"}, ${s.criticalCount || 0} through a critical dependency, deepest level ${s.deepestLevel || 0} of ${s.maxDepth || 0}.`;
    body.innerHTML = rows.map(x => `<tr><td>${esc(x.impactLevel)}</td><td>${esc(x.ciName)}</td>
        <td>${esc(KINDS[x.ciKind] || x.ciKind)}${x.ciClass && x.ciClass !== KINDS[x.ciKind] ? " - " + esc(x.ciClass) : ""}</td><td>${esc(x.ciStatus || "")}</td>
        <td>${esc(x.viaLabel)} ${esc(x.fromName || "")} <button class="pm-link-button" type="button" data-arl-open="${x.viaRelationshipId}">#${esc(x.viaRelationshipId)}</button></td>
        <td>${x.viaCritical ? '<span class="arl-chip arl-st-bad">Critical</span>' : "--"}</td></tr>`).join("")
      || empty(6, s.direction === "UPSTREAM" ? "It relies on nothing through active relationships." : "Nothing depends on it through active relationships.");
    body.querySelectorAll("button[data-arl-open]").forEach(b => b.addEventListener("click", () => openRelationship(Number(b.dataset.arlOpen))));
    // 441: business services reached.
    document.getElementById("arlImpSvcBody").innerHTML = (res.data.data.services || []).map(v => `<tr><td>${esc(v.impactLevel)}</td>
        <td>${esc(v.serviceName)}<div class="arl-note">${esc(v.serviceCode)} - ${esc(label(v.serviceType))}</div></td><td>${esc(label(v.serviceStatus))}</td>
        <td>${esc(v.criticalityCode || "--")}</td><td>${esc(v.rtoHours ?? "-")} / ${esc(v.rpoHours ?? "-")} / ${esc(v.mtpdHours ?? "-")}</td>
        <td>${esc(v.businessOwnerName || "--")}<div class="arl-note">${esc(v.serviceManagerName || "")}</div></td><td>${esc(v.consumers || "--")}</td></tr>`).join("")
      || empty(7, "No business service reached.");
  }

  // ------------------------------------------------------------------ types
  function renderTypes() {
    const body = document.getElementById("arlTypeBody");
    if (!state.config) { body.innerHTML = empty(8, state.organizationId ? "Could not load the types." : "Select an organization."); return; }
    body.innerHTML = state.config.types.map(t => `<tr><td>${esc(t.typeName)}<div class="arl-note">${esc(t.brdPair)} - ${esc(t.description)}</div></td>
        <td>${esc(t.inverseLabel)}</td><td>${esc(kinds(t.sourceKinds))}</td><td>${esc(kinds(t.targetKinds))}</td>
        <td>${esc(CARD[t.cardinality] || t.cardinality)}</td><td>${esc(LOOP[t.loopRule] || t.loopRule)}</td><td>${esc(SIDE[t.dependentSide] || t.dependentSide)}</td>
        <td><span class="arl-chip ${t.isActive ? "arl-st-active" : "arl-st-ended"}">${t.isActive ? "Active" : "Inactive"}</span>${t.inactiveReason ? `<div class="arl-note">${esc(t.inactiveReason)}</div>` : ""}</td></tr>`).join("");
  }
  function kinds(list) { return String(list || "").split(",").map(k => KINDS[k] || k).join(", "); }

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
    const el = document.getElementById("arlMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.classList.toggle("info", kind === "info"); el.hidden = !text;
  }
  function hideMessage() { const el = document.getElementById("arlMessage"); el.hidden = true; el.textContent = ""; }
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
