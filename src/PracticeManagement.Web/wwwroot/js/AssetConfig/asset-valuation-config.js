// =====================================================================
// Asset Valuation (migration 422) -- BRD 5.1.18 CIA / valuation / band /
// criticality configuration. Loaded by asset-valuation-config.cshtml.
// Every rule (Draft-only edits, overlap / gap / coverage checks, weights
// total 100, segregation of duties, one Active version) is enforced by
// the procedures; this screen only mirrors them and shows their messages.
// 446: Recalculation view -- valuation/recalculation (impact analysis of
// the Active version on stored Asset Values, earlier runs) and a controlled
// run with a reason against the affected count shown (409 when it moved).
// 447: Consistency rules view -- valuation/consistency/rules (list, get,
// save, preview, action ACTIVATE / RETIRE / NEW_VERSION / DISCARD) and
// valuation/consistency/operands; the rules are enforced by the procedures.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config/valuation";
  const root = document.getElementById("avcRoot");
  if (!root) return;
  const CAN_EDIT = root.dataset.canEdit === "1";
  const CAN_APPROVE = root.dataset.canApprove === "1";

  const STATUS = {
    DRAFT:            { label: "Draft",            cls: "avc-st-draft" },
    PENDING_APPROVAL: { label: "Pending Approval", cls: "avc-st-pending" },
    APPROVED:         { label: "Approved",         cls: "avc-st-approved" },
    ACTIVE:           { label: "Active",           cls: "avc-st-active" },
    RETIRED:          { label: "Retired",          cls: "avc-st-retired" }
  };
  const METHOD = { MAXIMUM: "Maximum", WEIGHTED_AVERAGE: "Weighted Average", SUMMATION: "Summation" };
  const DIM = { C: "Confidentiality", I: "Integrity", A: "Availability" };

  const state = { organizationId: null, rows: [], detail: null, preview: null, ruleOps: null, rules: [], rule: null };   // 447: rules

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    bind();
    await populateOrgs();
    const sel = document.getElementById("avcOrg");
    window.gracOrgPref.apply(sel);   // 2026-10-06: last-picked org, else lowest id
    state.organizationId = Number(sel.value) || null;
    await refreshList();
  }

  async function populateOrgs() {
    const sel = document.getElementById("avcOrg");
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
    document.getElementById("avcOrg").addEventListener("change", e => { state.organizationId = Number(e.target.value) || null; refreshList(); });
    document.getElementById("avcRefresh").addEventListener("click", refreshList);
    document.getElementById("avcNewBtn")?.addEventListener("click", () => createConfig(null));
    document.getElementById("avcListBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-avc-id]");
      if (tr) openDesigner(Number(tr.dataset.avcId));
    });
    document.getElementById("avcBack").addEventListener("click", showList);
    document.querySelectorAll("[data-avc-tab]").forEach(b => b.addEventListener("click", () => selectTab(b.dataset.avcTab)));
    document.querySelectorAll("[data-avc-add]").forEach(b => b.addEventListener("click", () => openItem(b.dataset.avcAdd, null)));
    ["avcCiaBody", "avcBandBody", "avcCritBody"].forEach(id => document.getElementById(id).addEventListener("click", ev => {
      const edit = ev.target.closest("[data-avc-edit]");
      if (edit) { openItem(edit.dataset.kind, Number(edit.dataset.avcEdit)); return; }
      const rm = ev.target.closest("[data-avc-remove]");
      if (rm) removeItem(rm.dataset.kind, Number(rm.dataset.avcRemove));
    }));
    document.getElementById("avcMethodForm").addEventListener("submit", saveHeader);
    ["avcMethodSel", "avcWc", "avcWi", "avcWa"].forEach(id => document.getElementById(id).addEventListener("input", weightNote));
    document.getElementById("avcItemForm").addEventListener("submit", saveItem);
    document.querySelectorAll("[data-close-avc]").forEach(b => b.addEventListener("click", () => { document.getElementById("avcItemModal").hidden = true; }));
    document.addEventListener("keydown", ev => { if (ev.key === "Escape") document.getElementById("avcItemModal").hidden = true; });
    document.getElementById("avcCalcRun").addEventListener("click", calculate);
    document.getElementById("avcReadyRefresh").addEventListener("click", loadReadiness);
    // 446
    document.getElementById("avcRecalcBtn").addEventListener("click", openRecalc);
    document.getElementById("avcRecalcBack").addEventListener("click", showList);
    document.getElementById("avcRecalcRefresh").addEventListener("click", loadRecalc);
    document.getElementById("avcRecalcRun")?.addEventListener("click", runRecalc);
    // 447
    document.getElementById("avcRulesBtn").addEventListener("click", openRules);
    document.getElementById("avcRulesBack").addEventListener("click", showList);
    document.getElementById("avcRuleNew")?.addEventListener("click", newRule);
    document.getElementById("avcRulesBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-avc-rule]");
      if (tr) openRule(Number(tr.dataset.avcRule));
    });
    document.getElementById("avcRuleScopeKind").addEventListener("change", () => fillScopeRefs(val("avcRuleScopeKind"), null));
    document.getElementById("avcCondAdd").addEventListener("click", () => {
      const conds = readConds();
      conds.push({ groupNo: conds.length ? conds[conds.length - 1].groupNo : 1, operandKey: "", operatorCode: "EQ", compareValue: "" });
      renderConds(conds);
    });
    document.getElementById("avcCondBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-avc-cond-remove]");
      if (!b) return;
      const conds = readConds();
      conds.splice(Number(b.dataset.avcCondRemove), 1);
      renderConds(conds);
    });
    document.getElementById("avcCondBody").addEventListener("change", ev => {
      if (ev.target.matches("select[data-avc-cond-op]")) renderConds(readConds());
    });
    document.getElementById("avcRuleActions").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-avc-rule-act]");
      if (b) ruleAction(b.dataset.avcRuleAct);
    });
  }

  // ------------------------------------------------------------------ list
  async function refreshList() {
    const body = document.getElementById("avcListBody");
    if (!state.organizationId) { body.innerHTML = `<tr><td colspan="6" class="pm-empty">Select an organization.</td></tr>`; return; }
    body.innerHTML = `<tr><td colspan="6" class="pm-empty">Loading...</td></tr>`;
    const res = await api("GET", `?organizationId=${state.organizationId}`);
    if (!res.ok) { body.innerHTML = `<tr><td colspan="6" class="pm-empty">${esc(res.error)}</td></tr>`; return; }
    state.rows = res.data.data.rows || [];
    body.innerHTML = state.rows.map(r => `
      <tr class="pm-row-clickable" data-avc-id="${r.configId}">
        <td>${esc(r.configName)}</td>
        <td>v${esc(r.versionNo)}</td>
        <td>${esc(METHOD[r.valuationMethod] || r.valuationMethod)}</td>
        <td>${chip(r.statusCode)}</td>
        <td>${esc(dateRange(r.effectiveFrom, r.effectiveTo))}</td>
        <td>${esc(r.bandCount)}</td>
      </tr>`).join("") || `<tr><td colspan="6" class="pm-empty">No valuation configuration yet${CAN_EDIT ? " -- use New Configuration to start from the BRD defaults." : "."}</td></tr>`;
  }

  async function createConfig(sourceConfigId) {
    if (!state.organizationId) { await notify("Select an organization first.", "warning"); return; }
    let changeReason = null;
    if (state.rows.length) {
      changeReason = await window.gracUi.promptRequired("Why is a new version needed? This is recorded as the change reason.",
        { title: "New version", inputLabel: "Change reason" });
      if (changeReason === null) return;
    }
    const res = await api("POST", "", { organizationId: state.organizationId, sourceConfigId, changeReason });
    if (!res.ok) { await notify(res.error, "error"); return; }
    await refreshList();
    await openDesigner(res.data.id);
    showMessage(state.rows.length > 1 ? "New draft version created from the current configuration."
      : "Draft created with the BRD default 1-5 scale and your current Criticality values. Define the Value Bands next.", "success");
  }

  function showList() {
    document.getElementById("avcDesignView").hidden = true;
    document.getElementById("avcRecalcView").hidden = true;   // 446
    document.getElementById("avcRulesView").hidden = true;    // 447
    document.getElementById("avcListView").hidden = false;
    state.detail = null;
    refreshList();
  }

  // ------------------------------------------------------------------ designer
  async function openDesigner(id) {
    const res = await api("GET", `/${id}?organizationId=${state.organizationId}`);
    if (!res.ok) { await notify(res.error, "error"); return; }
    state.detail = res.data.data;
    document.getElementById("avcListView").hidden = true;
    document.getElementById("avcDesignView").hidden = false;
    hideMessage();
    render();
    selectTab(document.querySelector("[data-avc-tab].active")?.dataset.avcTab || "cia");
  }

  async function reload(message) {
    const id = state.detail.header.configId;
    const res = await api("GET", `/${id}?organizationId=${state.organizationId}`);
    if (res.ok) state.detail = res.data.data;
    render();
    if (message) showMessage(message, "success");
    if (!document.querySelector('[data-avc-panel="readiness"]').hidden) loadReadiness();
  }

  function editable() { return CAN_EDIT && state.detail && state.detail.header.statusCode === "DRAFT"; }

  function selectTab(name) {
    document.querySelectorAll("[data-avc-tab]").forEach(b => {
      const on = b.dataset.avcTab === name;
      b.classList.toggle("active", on); b.setAttribute("aria-selected", on ? "true" : "false");
    });
    document.querySelectorAll("[data-avc-panel]").forEach(p => { p.hidden = p.dataset.avcPanel !== name; });
    if (name === "readiness") loadReadiness();
  }

  function render() {
    const h = state.detail.header;
    document.getElementById("avcTitle").innerHTML = `${esc(h.configName)} &middot; v${esc(h.versionNo)} ${chip(h.statusCode)}`;
    document.getElementById("avcMeta").textContent = `${METHOD[h.valuationMethod] || h.valuationMethod}` +
      (h.effectiveFrom ? ` -- effective ${dateRange(h.effectiveFrom, h.effectiveTo)}` : "") +
      (h.sourceVersionNo ? ` -- from v${h.sourceVersionNo}` : "");
    root.classList.toggle("avc-locked", !editable());
    renderActions();
    const editBtns = (kind, id) => editable()
      ? `<button type="button" class="pm-button icon" data-kind="${kind}" data-avc-edit="${id}" title="Edit"><i class="fa-solid fa-pen"></i></button>
         <button type="button" class="pm-button icon" data-kind="${kind}" data-avc-remove="${id}" title="Remove"><i class="fa-solid fa-xmark"></i></button>` : "";
    document.getElementById("avcCiaBody").innerHTML = state.detail.ciaLevels.map(l => `
      <tr><td>${esc(DIM[l.dimensionCode] || l.dimensionCode)}</td><td>${esc(l.score)}</td><td>${esc(l.levelLabel)}</td>
          <td>${esc(l.impactDescription || "")}</td><td>${editBtns("CIA_LEVEL", l.levelId)}</td></tr>`).join("")
      || `<tr><td colspan="5" class="pm-empty">No levels.</td></tr>`;
    document.getElementById("avcBandBody").innerHTML = state.detail.bands.map(b => `
      <tr><td>${esc(num(b.minScore))}</td><td>${esc(num(b.maxScore))}</td><td>${esc(b.categoryLabel)}</td>
          <td>${esc(b.treatmentGuidance || "")}</td><td>${editBtns("BAND", b.bandId)}</td></tr>`).join("")
      || `<tr><td colspan="5" class="pm-empty">No bands yet. The BRD names the categories but not their score ranges -- define them here.</td></tr>`;
    document.getElementById("avcCritBody").innerHTML = state.detail.criticality.map(l => `
      <tr><td>${esc(l.score)}</td><td>${esc(l.levelLabel)}</td><td>${esc(l.impactDescription || "")}</td>
          <td>${esc(l.reviewFrequencyMonths ?? "")}</td><td>${esc(l.criticalityMasterName || "--")}</td>
          <td>${editBtns("CRITICALITY", l.levelId)}</td></tr>`).join("")
      || `<tr><td colspan="6" class="pm-empty">No criticality levels.</td></tr>`;
    // Method / weights form.
    setVal("avcName", h.configName); setVal("avcMethodSel", h.valuationMethod); setVal("avcRounding", h.roundingMode);
    setVal("avcWc", h.weightC); setVal("avcWi", h.weightI); setVal("avcWa", h.weightA); setVal("avcDp", h.decimalPlaces);
    document.getElementById("avcOverride").checked = !!h.overrideAllowed;
    setVal("avcFrom", isoDate(h.effectiveFrom)); setVal("avcTo", isoDate(h.effectiveTo)); setVal("avcReason", h.changeReason || "");
    document.querySelectorAll("#avcMethodForm input, #avcMethodForm select, #avcMethodForm textarea").forEach(el => { el.disabled = !editable(); });
    weightNote();
    // Calculator pickers from this version's scale.
    ["C", "I", "A"].forEach(d => {
      document.getElementById("avcCalc" + d).innerHTML = state.detail.ciaLevels.filter(l => l.dimensionCode === d)
        .map(l => `<option value="${l.score}">${esc(l.score + " - " + l.levelLabel)}</option>`).join("");
    });
    document.getElementById("avcCalcResult").innerHTML = "";
    document.getElementById("avcHistoryBody").innerHTML = (state.detail.history || []).map(x => `
      <tr><td>${esc(dateTime(x.transitionedAt))}</td><td>${esc(x.fromStatus || "--")}</td><td>${esc(x.toStatus)}</td>
          <td>${esc(x.actorName || (x.actorEmployeeId ? "Employee #" + x.actorEmployeeId : "System"))}</td>
          <td>${esc(x.reasonText || x.reasonCode || "")}</td></tr>`).join("") || `<tr><td colspan="5" class="pm-empty">No history.</td></tr>`;
  }

  function weightNote() {
    const method = val("avcMethodSel");
    const total = (Number(val("avcWc")) || 0) + (Number(val("avcWi")) || 0) + (Number(val("avcWa")) || 0);
    ["avcWc", "avcWi", "avcWa"].forEach(id => { document.getElementById(id).closest("label").hidden = method !== "WEIGHTED_AVERAGE"; });
    document.getElementById("avcWeightNote").textContent = method === "WEIGHTED_AVERAGE"
      ? `Weights total ${Math.round(total * 100) / 100}%. They must total exactly 100% before the version can be submitted.`
      : "";
  }

  function renderActions() {
    const h = state.detail.header, host = document.getElementById("avcActions"), a = [];
    const add = (label, icon, fn, primary) => a.push({ label, icon, fn, primary });
    if (CAN_EDIT) {
      if (h.statusCode === "DRAFT") {
        add("Submit for Approval", "fa-paper-plane", () => transition("PENDING_APPROVAL"), true);
        add("Discard Draft", "fa-trash-can", () => transition("RETIRED", "Why is this draft being discarded?"));
      }
      if (h.statusCode === "APPROVED") {
        add("Activate", "fa-bolt", () => transition("ACTIVE", null,
          "Activate this configuration for asset valuation? The current Active version, if any, will be retired."), true);
        add("Withdraw", "fa-ban", () => transition("RETIRED", "Why is this approved version being withdrawn?"));
      }
      if (h.statusCode === "ACTIVE") add("Retire", "fa-box-archive", () => transition("RETIRED", "Why is this active version being retired?"));
      if (h.statusCode === "ACTIVE" || h.statusCode === "RETIRED") add("New Version", "fa-code-branch", () => createConfig(h.configId), true);
    }
    if (h.statusCode === "PENDING_APPROVAL" && CAN_APPROVE) {
      add("Approve", "fa-circle-check", () => transition("APPROVED", null, "Approve this valuation configuration?"), true);
      add("Return / Reject", "fa-rotate-left", () => transition("DRAFT", "Why is this version being returned?"));
    }
    host.innerHTML = a.map((x, i) => `<button type="button" class="pm-button${x.primary ? " primary" : ""}" data-avc-act="${i}"><i class="fa-solid ${x.icon}"></i> ${esc(x.label)}</button>`).join("");
    host.querySelectorAll("[data-avc-act]").forEach(b => b.addEventListener("click", () => a[Number(b.dataset.avcAct)].fn()));
  }

  async function loadReadiness() {
    const body = document.getElementById("avcReadyBody");
    body.innerHTML = `<tr><td colspan="3" class="pm-empty">Checking...</td></tr>`;
    const res = await api("GET", `/${state.detail.header.configId}/readiness?organizationId=${state.organizationId}`);
    if (!res.ok) { body.innerHTML = `<tr><td colspan="3" class="pm-empty">${esc(res.error)}</td></tr>`; return; }
    const d = res.data.data;
    const range = (d.issues || []).find(i => i.rangeMin != null);
    document.getElementById("avcReadySummary").textContent = d.errorCount
      ? `${d.errorCount} blocking issue(s), ${d.warningCount} warning(s). Blocking issues must be resolved before submission, approval or activation.`
      : `Ready. ${d.warningCount} warning(s).`;
    document.getElementById("avcRangeNote").textContent = range ? `Possible scores for this method: ${num(range.rangeMin)} to ${num(range.rangeMax)}.` : "";
    body.innerHTML = (d.issues || []).map(i => `
      <tr><td><span class="avc-status ${i.severity === "ERROR" ? "avc-sev-error" : "avc-sev-warning"}">${i.severity === "ERROR" ? "Blocking" : "Warning"}</span></td>
          <td>${esc(i.checkCode)}</td><td>${esc(i.message)}</td></tr>`).join("") || `<tr><td colspan="3" class="pm-empty">No issues found.</td></tr>`;
  }

  // ------------------------------------------------------------------ writes
  async function saveHeader(ev) {
    ev.preventDefault();
    if (!editable()) return;
    const h = state.detail.header;
    const res = await api("POST", `/${h.configId}/header`, {
      organizationId: state.organizationId, configName: val("avcName"), valuationMethod: val("avcMethodSel"),
      weightC: Number(val("avcWc")) || 0, weightI: Number(val("avcWi")) || 0, weightA: Number(val("avcWa")) || 0,
      decimalPlaces: Number(val("avcDp")) || 0, roundingMode: val("avcRounding"),
      overrideAllowed: document.getElementById("avcOverride").checked,
      effectiveFrom: val("avcFrom") || null, effectiveTo: val("avcTo") || null,
      changeReason: val("avcReason") || null, expectedRecordVersion: h.recordVersion
    });
    if (!res.ok) { showMessage(res.error, "error"); if (res.status === 409) await reload(); return; }
    await reload("Valuation method saved.");
  }

  function openItem(kind, id) {
    if (!editable()) return;
    const list = kind === "CIA_LEVEL" ? state.detail.ciaLevels : kind === "BAND" ? state.detail.bands : state.detail.criticality;
    const item = id ? list.find(x => (x.levelId ?? x.bandId) === id) : null;
    document.getElementById("avcItemTitle").textContent = (item ? "Edit " : "Add ") +
      (kind === "CIA_LEVEL" ? "CIA level" : kind === "BAND" ? "value band" : "criticality level");
    document.querySelectorAll("#avcItemForm [data-avc-for]").forEach(el => { el.hidden = !el.dataset.avcFor.split(" ").includes(kind); });
    document.getElementById("avcItemLabelCaption").textContent = kind === "BAND" ? "Category *" : "Label *";
    document.getElementById("avcItemDescCaption").textContent = kind === "BAND" ? "Treatment guidance" : "Impact description";
    setVal("avcItemDim", item?.dimensionCode || "C");
    setVal("avcItemScore", item?.score ?? "");
    setVal("avcItemMin", item?.minScore ?? ""); setVal("avcItemMax", item?.maxScore ?? "");
    setVal("avcItemLabel", item?.levelLabel || item?.categoryLabel || "");
    setVal("avcItemDesc", item?.impactDescription || item?.treatmentGuidance || "");
    setVal("avcItemReview", item?.reviewFrequencyMonths ?? "");
    document.getElementById("avcItemMap").innerHTML = `<option value="">-- not mapped --</option>` + (state.detail.criticalityMaster || [])
      .map(m => `<option value="${m.criticalityId}" ${m.criticalityId === item?.criticalityMasterId ? "selected" : ""}>${esc(m.criticalityName)}</option>`).join("");
    const form = document.getElementById("avcItemForm");
    form.dataset.kind = kind; form.dataset.itemId = id ? String(id) : "";
    document.getElementById("avcItemMessage").hidden = true;
    document.getElementById("avcItemModal").hidden = false;
  }

  async function saveItem(ev) {
    ev.preventDefault();
    const form = document.getElementById("avcItemForm");
    const kind = form.dataset.kind;
    const optNum = id => val(id) === "" ? null : Number(val(id));
    const res = await api("POST", `/${state.detail.header.configId}/items`, {
      organizationId: state.organizationId, itemKind: kind, itemId: Number(form.dataset.itemId) || null, remove: false,
      dimensionCode: kind === "CIA_LEVEL" ? val("avcItemDim") : null,
      score: kind === "BAND" ? null : optNum("avcItemScore"),
      minScore: kind === "BAND" ? optNum("avcItemMin") : null,
      maxScore: kind === "BAND" ? optNum("avcItemMax") : null,
      label: val("avcItemLabel"), description: val("avcItemDesc") || null,
      reviewFrequencyMonths: kind === "CRITICALITY" ? optNum("avcItemReview") : null,
      criticalityMasterId: kind === "CRITICALITY" ? optNum("avcItemMap") : null
    });
    if (!res.ok) { const m = document.getElementById("avcItemMessage"); m.textContent = res.error; m.hidden = false; return; }
    document.getElementById("avcItemModal").hidden = true;
    await reload("Saved.");
  }

  async function removeItem(kind, id) {
    if (!await window.gracUi.confirm("Remove this entry from the draft configuration?")) return;
    const res = await api("POST", `/${state.detail.header.configId}/items`, { organizationId: state.organizationId, itemKind: kind, itemId: id, remove: true });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    await reload("Removed.");
  }

  async function transition(toStatusCode, reasonQuestion, confirmQuestion) {
    const h = state.detail.header;
    let reasonText = null;
    if (reasonQuestion) {
      reasonText = await window.gracUi.promptRequired(reasonQuestion, { title: "Reason required", inputLabel: "Reason" });
      if (reasonText === null) return;
    } else if (confirmQuestion && !await window.gracUi.confirm(confirmQuestion)) return;
    const res = await api("POST", `/${h.configId}/transition`, {
      organizationId: state.organizationId, toStatusCode, reasonText, expectedRecordVersion: h.recordVersion
    });
    if (!res.ok) {
      showMessage(res.error, "error");
      if (res.errorNumber === 54263) selectTab("readiness");
      if (res.status === 409) await reload();
      return;
    }
    await reload(`Configuration moved to ${STATUS[toStatusCode]?.label || toStatusCode}.`
      + (toStatusCode === "ACTIVE" ? " Stored Asset Values are not changed; review the impact under Recalculation." : ""));   // 446
  }

  // ------------------------------------------------------------------ recalculation (446)
  const RECALC_WHY = { NOT_CALCULATED: "Not calculated yet", VALUES_CHANGED: "Ratings / method changed",
                       CONFIG_CHANGED: "Newer configuration version", CONFIG_AND_VALUES: "Ratings changed and newer version" };
  const VAL_STATUS = { NOT_RATED: "Not rated", INCOMPLETE: "Incomplete", INVALID: "Invalid", VALID: "Valid" };
  const RUN_STATUS = { RUNNING: "Running", COMPLETED: "Completed", COMPLETED_WITH_ERRORS: "Completed with errors", FAILED: "Failed" };
  const valueText = (cat, score, status) => cat ? `${cat} (${num(score)})` : (VAL_STATUS[status] || "--");

  async function openRecalc() {
    if (!state.organizationId) { await notify("Select an organization first.", "warning"); return; }
    document.getElementById("avcListView").hidden = true;
    document.getElementById("avcDesignView").hidden = true;
    document.getElementById("avcRecalcView").hidden = false;
    recalcMessage("");
    await loadRecalc();
  }

  async function loadRecalc() {
    const res = await api("GET", `/recalculation?organizationId=${state.organizationId}`);
    if (!res.ok) { recalcMessage(res.error, "error"); return; }
    state.preview = res.data.data || {};
    renderRecalc();
  }

  function renderRecalc() {
    const p = state.preview || {}, s = p.summary || {};
    document.getElementById("avcRecalcMeta").textContent = s.activeVersionNo
      ? `Active configuration v${s.activeVersionNo} -- ${METHOD[s.valuationMethod] || s.valuationMethod}${s.overrideAllowed ? ", asset-level override permitted" : ""}`
      : "No Active valuation configuration -- rated assets are shown as invalid until one is activated.";
    document.getElementById("avcRecalcSummary").innerHTML = `
      <dt>Assets to recalculate</dt><dd>${esc(s.affectedAssets ?? 0)}</dd>
      <dt>Newer configuration version</dt><dd>${esc(s.configChanged ?? 0)}</dd>
      <dt>Ratings / method changed</dt><dd>${esc(s.valuesChanged ?? 0)}</dd>
      <dt>Not calculated yet</dt><dd>${esc(s.notCalculated ?? 0)}</dd>
      <dt>Category changes</dt><dd>${esc(s.categoryChanges ?? 0)}</dd>
      <dt>Not valid after recalculation</dt><dd>${esc(s.notValidAfter ?? 0)}</dd>
      <dt>Risks linked to these assets</dt><dd>${esc(s.linkedRisks ?? 0)}</dd>
      <dt>Assets with a valid Asset Value</dt><dd>${esc(s.valuedAssets ?? 0)}</dd>`;
    const run = document.getElementById("avcRecalcRun");
    if (run) run.disabled = !Number(s.affectedAssets) || !!Number(s.runsInProgress);
    document.getElementById("avcRecalcMoves").innerHTML = (p.moves || []).map(m => `
      <tr><td>${esc(m.fromCategory || VAL_STATUS[m.fromStatus] || "Not calculated")}</td>
          <td>${esc(m.toCategory || VAL_STATUS[m.toStatus] || m.toStatus)}</td><td>${esc(m.assetCount)}</td></tr>`).join("")
      || `<tr><td colspan="3" class="pm-empty">Every stored Asset Value is up to date.</td></tr>`;
    document.getElementById("avcRecalcAssets").innerHTML = (p.assets || []).map(a => `
      <tr><td>${esc(a.assetName)} <span class="avc-note">#${esc(a.assetId)}</span></td>
          <td>${esc(RECALC_WHY[a.stateCode] || a.stateCode)}</td>
          <td>${a.storedStatus ? esc(valueText(a.storedCategory, a.storedScore, a.storedStatus)) + (a.storedConfigVersionNo ? ` <span class="avc-note">v${esc(a.storedConfigVersionNo)}</span>` : "") : "--"}</td>
          <td>${esc(valueText(a.newCategory, a.newScore, a.newStatus))}${a.message ? `<div class="avc-note">${esc(a.message)}</div>` : ""}</td>
          <td>${esc(a.riskCount)}</td></tr>`).join("")
      || `<tr><td colspan="5" class="pm-empty">No asset to recalculate.</td></tr>`;
    document.getElementById("avcRecalcRuns").innerHTML = (p.runs || []).map(r => `
      <tr><td>#${esc(r.runId)}</td><td>${esc(dateTime(r.startedDt))}</td><td>${r.configVersionNo ? `v${esc(r.configVersionNo)}` : "--"}</td>
          <td>${esc(RUN_STATUS[r.status] || r.status)}${r.errorText ? `<div class="avc-note">${esc(r.errorText)}</div>` : ""}</td>
          <td>${esc(r.affectedCount)} / ${esc(r.updatedCount)} / ${esc(r.errorCount)}</td><td>${esc(r.enteredBy)}</td><td>${esc(r.reason)}</td></tr>`).join("")
      || `<tr><td colspan="7" class="pm-empty">No recalculation run yet.</td></tr>`;
  }

  async function runRecalc() {
    const s = (state.preview || {}).summary || {};
    const n = Number(s.affectedAssets) || 0;
    if (!n) { await notify("Every stored Asset Value is up to date.", "info"); return; }
    const reason = await window.gracUi.promptRequired(
      `Recalculate ${n} asset(s) with configuration v${s.activeVersionNo || "(none)"}? Previous values stay in each asset's history.`,
      { title: "Run recalculation", inputLabel: "Reason" });
    if (!reason) return;
    recalcMessage("Recalculating...", "info");
    const res = await api("POST", "/recalculation", { organizationId: state.organizationId, reason, expectedAffected: n });
    if (!res.ok) { recalcMessage(res.error, "error"); await loadRecalc(); return; }
    await loadRecalc();
    recalcMessage(`Run #${res.data.id}: ${RUN_STATUS[res.data.result] || res.data.result}.`, res.data.result === "COMPLETED" ? "success" : "error");
  }

  // ------------------------------------------------------------------ consistency rules (447)
  const SCOPE = { TENANT: "Whole organization", CATEGORY: "Category", SUBCATEGORY: "Subcategory", ASSET_TYPE: "Asset type", SERVICE: "Business service" };
  const SEVERITY = { INFO: "Information", WARNING: "Warning", ERROR: "Error", APPROVAL_REQUIRED: "Approval Required" };
  const ACTION = { WARN: "Warn", REQUIRE_RATIONALE: "Require rationale", CREATE_TASK: "Create task", BLOCK_TRANSITION: "Block move to Active" };
  const OPERATOR = { EQ: "equals", NEQ: "does not equal", IN: "is one of", NOT_IN: "is not one of", EMPTY: "is empty", NOT_EMPTY: "is not empty",
                     GT: "greater than", GTE: "at least", LT: "less than", LTE: "at most",
                     DATE_BEFORE_TODAY: "date before today", DATE_AFTER_TODAY: "date after today", DATE_WITHIN_DAYS: "date within (days)" };
  const NO_VALUE = new Set(["EMPTY", "NOT_EMPTY", "DATE_BEFORE_TODAY", "DATE_AFTER_TODAY"]);
  const optionsOf = (map, sel) => Object.entries(map).map(([k, v]) => `<option value="${k}"${k === sel ? " selected" : ""}>${esc(v)}</option>`).join("");

  async function openRules() {
    if (!state.organizationId) { await notify("Select an organization first.", "warning"); return; }
    document.getElementById("avcListView").hidden = true;
    document.getElementById("avcDesignView").hidden = true;
    document.getElementById("avcRecalcView").hidden = true;
    document.getElementById("avcRulesView").hidden = false;
    document.getElementById("avcRuleEditor").hidden = true;
    rulesMessage("");
    state.ruleOps = null;
    const res = await api("GET", `/consistency/operands?organizationId=${state.organizationId}`);
    if (!res.ok) { rulesMessage(res.error, "error"); return; }
    state.ruleOps = res.data.data || { operands: [], scopes: [] };
    await loadRules();
  }

  async function loadRules() {
    const body = document.getElementById("avcRulesBody");
    const res = await api("GET", `/consistency/rules?organizationId=${state.organizationId}`);
    if (!res.ok) { body.innerHTML = `<tr><td colspan="8" class="pm-empty">${esc(res.error)}</td></tr>`; return; }
    state.rules = res.data.data || [];
    body.innerHTML = state.rules.map(r => `
      <tr class="pm-row-clickable" data-avc-rule="${r.ruleId}">
        <td>${esc(r.ruleCode)}<div class="avc-note">${esc(r.ruleName)}</div></td><td>v${esc(r.versionNo)}</td><td>${chip(r.status)}</td>
        <td>${esc(r.scopeLabel)}</td><td>${esc(SEVERITY[r.severity] || r.severity)}</td><td>${esc(ACTION[r.actionCode] || r.actionCode)}</td>
        <td>${esc(dateRange(r.effectiveFrom, r.effectiveTo))}</td>
        <td>${r.status === "ACTIVE" ? `${esc(r.openFindings)} open / ${esc(r.acceptedFindings)} accepted` : "--"}</td>
      </tr>`).join("") || `<tr><td colspan="8" class="pm-empty">No consistency rule yet${CAN_EDIT ? " -- use New rule." : "."}</td></tr>`;
  }

  function newRule() {
    state.rule = {
      rule: { status: "DRAFT", scopeKind: "TENANT", severity: "WARNING", actionCode: "WARN", overrideAllowed: true },
      conditions: [{ groupNo: 1, operandKey: "", operatorCode: "EQ", compareValue: "" }], versions: []
    };
    renderRule();
  }

  async function openRule(id) {
    const res = await api("GET", `/consistency/rules/${id}?organizationId=${state.organizationId}`);
    if (!res.ok) { rulesMessage(res.error, "error"); return; }
    state.rule = res.data.data;
    renderRule();
  }

  function ruleEditable() { const r = state.rule && state.rule.rule; return CAN_EDIT && !!r && r.status === "DRAFT"; }

  function renderRule() {
    const d = state.rule, r = d.rule, edit = ruleEditable();
    document.getElementById("avcRuleEditor").hidden = false;
    document.getElementById("avcRuleTitle").textContent = r.ruleId ? `${r.ruleCode} v${r.versionNo} -- ${r.ruleName}` : "New rule";
    document.getElementById("avcRuleMeta").innerHTML = r.ruleId
      ? `${chip(r.status)} ${esc(r.scopeLabel || "")}${r.activatedBy ? ` -- activated by ${esc(r.activatedBy)} ${esc(dateTime(r.activatedDt))}` : ""}`
        + (r.status === "DRAFT" ? ` -- last saved by ${esc(r.lastChangedBy)}; another person activates it` : "")
      : "Not saved yet.";
    setVal("avcRuleName", r.ruleName); setVal("avcRuleDesc", r.description);
    document.getElementById("avcRuleScopeKind").innerHTML = optionsOf(SCOPE, r.scopeKind || "TENANT");
    fillScopeRefs(r.scopeKind || "TENANT", r.scopeRefId);
    document.getElementById("avcRuleSeverity").innerHTML = optionsOf(SEVERITY, r.severity);
    document.getElementById("avcRuleAction").innerHTML = optionsOf(ACTION, r.actionCode);
    document.getElementById("avcRuleOverride").checked = r.overrideAllowed !== false;
    setVal("avcRuleMaxDays", r.maxOverrideDays); setVal("avcRuleFrom", isoDate(r.effectiveFrom)); setVal("avcRuleTo", isoDate(r.effectiveTo));
    setVal("avcRuleReason", r.changeReason);
    renderConds(d.conditions || []);
    document.querySelectorAll("#avcRuleForm input, #avcRuleForm select, #avcRuleForm textarea").forEach(el => { el.disabled = !edit; });
    if (!edit) document.getElementById("avcRuleScopeRef").disabled = true;
    document.getElementById("avcCondAdd").hidden = !edit;
    const acts = [];
    if (edit) acts.push(["SAVE", "Save draft", "primary", "fa-floppy-disk"]);
    if (r.ruleId) acts.push(["PREVIEW", "Preview", "", "fa-eye"]);
    if (r.ruleId && r.status === "DRAFT" && CAN_APPROVE) acts.push(["ACTIVATE", "Activate", "", "fa-circle-check"]);
    if (r.ruleId && r.status === "DRAFT" && CAN_EDIT) acts.push(["DISCARD", "Discard", "", "fa-trash-can"]);
    if (r.status === "ACTIVE" && CAN_APPROVE) acts.push(["RETIRE", "Retire", "", "fa-box-archive"]);
    if ((r.status === "ACTIVE" || r.status === "RETIRED") && CAN_EDIT) acts.push(["NEW_VERSION", "New version", "", "fa-code-branch"]);
    document.getElementById("avcRuleActions").innerHTML = acts.map(([a, label, cls, icon]) =>
      `<button class="pm-button ${cls}" type="button" data-avc-rule-act="${a}"><i class="fa-solid ${icon}"></i> ${esc(label)}</button>`).join("");
    document.getElementById("avcRulePreviewBody").innerHTML = `<tr><td colspan="4" class="pm-empty">${r.ruleId ? "Use Preview." : "Save the rule first."}</td></tr>`;
    document.getElementById("avcRulePreviewNote").textContent = "Preview lists the assets the saved rule matches now.";
    document.getElementById("avcRuleVersions").innerHTML = (d.versions || []).map(v => `
      <tr><td>v${esc(v.versionNo)}</td><td>${chip(v.status)}</td><td>${esc(dateRange(v.effectiveFrom, v.effectiveTo))}</td>
          <td>${esc(v.changeReason || "")}</td><td>${esc(v.activatedBy || "")}${v.activatedDt ? `<div class="avc-note">${esc(dateTime(v.activatedDt))}</div>` : ""}</td></tr>`).join("")
      || `<tr><td colspan="5" class="pm-empty">--</td></tr>`;
    document.getElementById("avcRuleEditor").scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function fillScopeRefs(kind, selected) {
    const el = document.getElementById("avcRuleScopeRef");
    const opts = ((state.ruleOps || {}).scopes || []).filter(s => s.scopeKind === kind);
    el.innerHTML = kind === "TENANT" ? `<option value="">--</option>`
      : `<option value="">Select</option>` + opts.map(s => `<option value="${esc(s.scopeRefId)}"${String(s.scopeRefId) === String(selected) ? " selected" : ""}>${esc(s.scopeLabel)}</option>`).join("");
    el.disabled = kind === "TENANT" || !ruleEditable();
  }

  function renderConds(conds) {
    const edit = ruleEditable();
    const ops = (state.ruleOps || {}).operands || [];
    const operandOptions = sel => `<option value="">Select</option>`
      + `<optgroup label="Derived">${ops.filter(o => o.operandKind === "DERIVED").map(o => `<option value="${esc(o.operandKey)}"${o.operandKey === sel ? " selected" : ""} title="${esc(o.hint || "")}">${esc(o.operandLabel)}</option>`).join("")}</optgroup>`
      + `<optgroup label="Asset fields">${ops.filter(o => o.operandKind === "FIELD").map(o => `<option value="${esc(o.operandKey)}"${o.operandKey === sel ? " selected" : ""}>${esc(o.operandLabel)} (${esc(o.operandKey)})</option>`).join("")}</optgroup>`;
    document.getElementById("avcCondBody").innerHTML = conds.map((c, i) => `
      <tr><td><input type="number" min="1" step="1" data-avc-cond-group value="${esc(c.groupNo || 1)}"${edit ? "" : " disabled"} /></td>
          <td><select data-avc-cond-operand${edit ? "" : " disabled"}>${operandOptions(c.operandKey)}</select></td>
          <td><select data-avc-cond-op${edit ? "" : " disabled"}>${optionsOf(OPERATOR, c.operatorCode || "EQ")}</select></td>
          <td><input type="text" maxlength="400" data-avc-cond-value value="${esc(NO_VALUE.has(c.operatorCode) ? "" : (c.compareValue || ""))}"${edit && !NO_VALUE.has(c.operatorCode) ? "" : " disabled"} /></td>
          <td>${edit ? `<button class="pm-button icon" type="button" data-avc-cond-remove="${i}" title="Remove" aria-label="Remove"><i class="fa-solid fa-xmark"></i></button>` : ""}</td></tr>`).join("")
      || `<tr><td colspan="5" class="pm-empty">No condition.</td></tr>`;
  }

  function readConds() {
    return [...document.querySelectorAll("#avcCondBody tr")].filter(tr => tr.querySelector("select[data-avc-cond-op]")).map(tr => ({
      groupNo: Number(tr.querySelector("input[data-avc-cond-group]").value) || 1,
      operandKey: tr.querySelector("select[data-avc-cond-operand]").value,
      operatorCode: tr.querySelector("select[data-avc-cond-op]").value,
      compareValue: tr.querySelector("input[data-avc-cond-value]").value.trim() || null
    }));
  }

  async function ruleAction(action) {
    const r = state.rule.rule;
    if (action === "SAVE") { await saveRule(); return; }
    if (action === "PREVIEW") { await previewRule(); return; }
    let reason = null;
    if (action === "RETIRE" || action === "NEW_VERSION") {
      reason = await window.gracUi.promptRequired(action === "RETIRE" ? "Why is this rule retired? Its open findings are resolved." : "Why is a new version needed?",
        { title: action === "RETIRE" ? "Retire rule" : "New version", inputLabel: "Reason" });
      if (!reason) return;
    } else if (!await window.gracUi.confirm(action === "ACTIVATE"
        ? "Activate this rule? It becomes immutable, replaces the Active version of the rule and is evaluated for every asset now."
        : "Discard this Draft?")) return;
    const res = await api("POST", `/consistency/rules/${r.ruleId}/action`, {
      organizationId: state.organizationId, action, reason, expectedRecordVersion: r.recordVersion ?? null
    });
    if (!res.ok) { rulesMessage(res.error, "error"); if (res.status === 409) await openRule(r.ruleId); return; }
    await loadRules();
    if (action === "DISCARD") { document.getElementById("avcRuleEditor").hidden = true; state.rule = null; }
    else await openRule(res.data.id);
    const result = String(res.data.result || "");
    rulesMessage(result.endsWith("_NOT_EVALUATED")
      ? "Done, but the findings could not be refreshed now; the scheduler refreshes them."
      : { ACTIVATED: "Rule activated; findings refreshed.", RETIRED: "Rule retired; its findings were resolved.",
          CREATED: "New Draft version created.", DISCARDED: "Draft discarded." }[result] || "Done.", "success");
  }

  async function saveRule() {
    const r = state.rule.rule;
    const kind = val("avcRuleScopeKind");
    const res = await api("POST", "/consistency/rules", {
      organizationId: state.organizationId, ruleId: r.ruleId || null, ruleName: val("avcRuleName") || null,
      description: val("avcRuleDesc") || null, scopeKind: kind, scopeRefId: kind === "TENANT" ? null : (Number(val("avcRuleScopeRef")) || null),
      severity: val("avcRuleSeverity"), actionCode: val("avcRuleAction"), overrideAllowed: document.getElementById("avcRuleOverride").checked,
      maxOverrideDays: Number(val("avcRuleMaxDays")) || null, effectiveFrom: val("avcRuleFrom") || null, effectiveTo: val("avcRuleTo") || null,
      changeReason: val("avcRuleReason") || null, conditions: readConds(), expectedRecordVersion: r.recordVersion ?? null
    });
    if (!res.ok) { rulesMessage(res.error, "error"); if (res.status === 409 && r.ruleId) await openRule(r.ruleId); return; }
    await loadRules();
    await openRule(res.data.id);
    rulesMessage(res.data.result === "CREATED" ? "Rule saved as Draft version 1. Another person with approval rights activates it." : "Draft saved.", "success");
  }

  async function previewRule() {
    const r = state.rule.rule, body = document.getElementById("avcRulePreviewBody");
    body.innerHTML = `<tr><td colspan="4" class="pm-empty">Evaluating...</td></tr>`;
    const res = await api("GET", `/consistency/rules/${r.ruleId}/preview?organizationId=${state.organizationId}`);
    if (!res.ok) { body.innerHTML = `<tr><td colspan="4" class="pm-empty">${esc(res.error)}</td></tr>`; return; }
    const p = res.data.data || {}, s = p.summary || {};
    document.getElementById("avcRulePreviewNote").textContent = `${s.matched ?? 0} of ${s.inScope ?? 0} assets in scope match the saved conditions now (first 500 listed).`;
    const facts = j => { try { return (JSON.parse(j || "[]") || []).map(x => `${x.operand} = ${x.value}`).join("; "); } catch (_) { return ""; } };
    body.innerHTML = (p.assets || []).map(a => `
      <tr><td>${esc(a.assetName)} <span class="avc-note">#${esc(a.assetId)}</span></td><td>${esc(a.statusName || "")}</td>
          <td>${esc(facts(a.factsJson))}</td><td>${esc(a.findingStatus ? a.findingStatus.replace(/_/g, " ").toLowerCase() : "--")}</td></tr>`).join("")
      || `<tr><td colspan="4" class="pm-empty">No asset matches.</td></tr>`;
  }

  function rulesMessage(text, kind) {
    const el = document.getElementById("avcRulesMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.hidden = !text;
  }

  function recalcMessage(text, kind) {
    const el = document.getElementById("avcRecalcMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.hidden = !text;
  }

  async function calculate() {
    const out = document.getElementById("avcCalcResult");
    const res = await api("POST", `/${state.detail.header.configId}/calculate`, {
      organizationId: state.organizationId,
      confidentiality: Number(val("avcCalcC")), integrity: Number(val("avcCalcI")), availability: Number(val("avcCalcA"))
    });
    if (!res.ok) { out.innerHTML = `<dt>Error</dt><dd>${esc(res.error)}</dd>`; return; }
    const r = res.data.data || {};
    out.innerHTML = `
      <dt>Method</dt><dd>${esc(METHOD[state.detail.header.valuationMethod] || "")}</dd>
      <dt>Raw score</dt><dd>${esc(num(r.rawScore))}</dd>
      <dt>Asset Value score</dt><dd>${esc(num(r.assetValueScore))}</dd>
      <dt>Asset Value category</dt><dd>${esc(r.assetValueCategory || r.validationMessage || "--")}</dd>`;
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
        return { ok: false, status: r.status, errorNumber: data.errorNumber, error: data.error || `Request failed (HTTP ${r.status})${hint}.` };
      }
      return { ok: true, status: r.status, data };
    } catch (err) { return { ok: false, status: 0, error: err.message }; }
  }
  function showMessage(text, kind) {
    const el = document.getElementById("avcMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.hidden = !text;
  }
  function hideMessage() { const el = document.getElementById("avcMessage"); el.hidden = true; el.textContent = ""; }
  async function notify(message, type) {
    if (window.gracUi) await window.gracUi.alert(message, { type: type || "info" }); else window.alert(message);
  }
  function chip(code) { const s = STATUS[code] || { label: code || "", cls: "avc-st-draft" }; return `<span class="avc-status ${s.cls}">${esc(s.label)}</span>`; }
  function val(id) { return (document.getElementById(id).value || "").trim(); }
  function setVal(id, v) { document.getElementById(id).value = v ?? ""; }
  function num(v) { return v == null || v === "" ? "" : String(Number(v)); }
  function isoDate(v) { return v ? String(v).substring(0, 10) : ""; }
  function fmtDate(v) { return !v ? "" : (window.gracFormatDisplayDate ? window.gracFormatDisplayDate(v) : isoDate(v)); }
  function dateRange(from, to) { return !from ? "--" : `${fmtDate(from)}${to ? " to " + fmtDate(to) : " onwards"}`; }
  function dateTime(v) { if (!v) return ""; const d = new Date(v); return isNaN(d) ? String(v) : d.toLocaleString(); }
  function esc(v) { return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
})();
