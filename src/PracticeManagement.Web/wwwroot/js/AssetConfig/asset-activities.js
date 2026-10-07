// =====================================================================
// Asset Activities (migration 438) -- BRD 7.1, 5.1.7, 5.2.16.
// Loaded by asset-activities.cshtml. Schedules: activities/schedules
// (recalculated on read). Occurrences: activities/occurrences,
// activities/occurrences/{id}/reconcile. Campaigns: activities/campaigns.
// Templates: activities/config, activities/settings. Run now:
// activities/run (the 437 scheduler pass). The procedures hold every rule
// (applicability, frequency / basis, contract-versus-asset decision, one
// open occurrence per asset and activity); this screen shows them.
// 439: activities/occurrences/{id} (detail), .../result, .../result-decision,
// .../disposition, activities/dispositions/{id}/decision, activities/reviews,
// activities/reviews/{id}/decision -- results with reviewer approval,
// reschedule / waive / not applicable / exception with approver (7.1.5) and
// the restrictive-use reviews (9.1.9). Segregation of duties is in SQL.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config/activities";
  const root = document.getElementById("aacRoot");
  if (!root) return;
  const CAN_EDIT = root.dataset.canEdit === "1";
  const CAN_APPROVE = root.dataset.canApprove === "1";   // 439

  const STATUS = { OVERDUE: ["Overdue", "aac-st-bad"], DUE_SOON: ["Due soon", "aac-st-wait"], VALID: ["Valid", "aac-st-active"],
                   COVERED: ["Covered by contract", "aac-st-open"], NOT_SCHEDULED: ["Not scheduled", "aac-st-ended"],
                   NOT_APPLICABLE: ["Not applicable", "aac-st-ended"],
                   FAILED: ["Failed", "aac-st-bad"], WAIVED: ["Waived", "aac-st-ended"] };            // 439
  const OCC_STATUS = { OPEN: ["Open", "aac-st-open"], COMPLETED: ["Completed", "aac-st-active"], CANCELLED: ["Cancelled", "aac-st-ended"],
                       COVERED: ["Covered", "aac-st-open"], WAIVED: ["Waived", "aac-st-ended"] };
  // 439: results, dispositions, restrictive-use reviews.
  const OUTCOME = { PASS: "Pass", FAIL: "Fail", RENEWED: "Renewed", NOT_RENEWED: "Not renewed" };
  const RESULT_STATE = { DRAFT: ["Draft", "aac-st-ended"], SUBMITTED: ["Waiting for review", "aac-st-wait"],
                         RETURNED: ["Returned", "aac-st-bad"], APPROVED: ["Approved", "aac-st-active"] };
  const DISPOSITION = { RESCHEDULE: "Reschedule", WAIVE: "Waive", NOT_APPLICABLE: "Not applicable", EXCEPTION: "Exception" };
  const DISP_STATUS = { PENDING: ["Pending approval", "aac-st-wait"], APPROVED: ["Approved", "aac-st-active"],
                        REJECTED: ["Rejected", "aac-st-bad"], WITHDRAWN: ["Withdrawn", "aac-st-ended"] };
  const REV_STATUS = { OPEN: ["Open", "aac-st-bad"], DECIDED: ["Decided", "aac-st-wait"], RESOLVED: ["Resolved", "aac-st-active"] };
  const REV_ACTION = { CONTROLLED_USE: "Controlled use", RESTRICTED_USE: "Restricted use", REMOVED_FROM_SERVICE: "Removed from service",
                       EXCEPTION_APPROVED: "Exception approved", NO_ACTION_REQUIRED: "No action required", DISABLE: "Disable",
                       UNINSTALL: "Uninstall", REPLACE: "Replace", PURCHASE: "Purchase" };
  // The actions the procedure accepts for each trigger (BRD 9.1.9, 7.1.2, 7.1.3).
  function reviewActions(r) {
    if (r.sourceKind === "EVIDENCE") return ["RESTRICTED_USE", "REMOVED_FROM_SERVICE", "EXCEPTION_APPROVED", "NO_ACTION_REQUIRED"];
    if (r.triggerCode === "EXPIRED") return ["DISABLE", "UNINSTALL", "REPLACE", "PURCHASE", "RESTRICTED_USE", "EXCEPTION_APPROVED"];
    return ["CONTROLLED_USE", "RESTRICTED_USE", "REMOVED_FROM_SERVICE", "EXCEPTION_APPROVED", "NO_ACTION_REQUIRED"];
  }
  const CMP_STATUS = { GENERATED: ["Generated", "aac-st-open"], IN_PROGRESS: ["In progress", "aac-st-wait"],
                       PARTIALLY_COMPLETED: ["Partially completed", "aac-st-bad"], COMPLETED: ["Completed", "aac-st-active"] };
  const DUE_SOURCE = { LAST_DATE_FIELD: "from the last date", COMPLETED_OCCURRENCE: "from the last completed task",
                       NO_HISTORY: "no history -- due now", EXPIRY_FIELD: "licence expiry",
                       FAILED_RESULT: "re-test after a failed result", WAIVED_REVIEW: "review date of a waiver" };   // 439

  const state = { organizationId: null, mainTab: "SCHEDULES", config: null, schPager: null, occPager: null, cmpPager: null,
                  campaignId: null, setting: null, reconcile: null, revPager: null, detail: null, decision: null, revRows: [] };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    state.schPager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "aacSchPager", onChange: refreshSchedules }) : null;
    state.occPager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "aacOccPager", onChange: refreshOccurrences }) : null;
    state.cmpPager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "aacCmpPager", onChange: refreshCampaigns }) : null;
    state.revPager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "aacRevPager", onChange: refreshReviews }) : null;   // 439
    bind();
    await populateOrgs();
    const sel = document.getElementById("aacOrg");
    window.gracOrgPref.apply(sel);   // 2026-10-06: last-picked org, else lowest id
    // 451: opened from the Asset & Contract dashboard -- organization, tab and filter (Shared/dashboard-drill.js).
    const dashDrill = window.__pmDrill ? window.__pmDrill.read() : null;
    window.__pmDrill?.preselectFor(dashDrill, sel, { OCCURRENCES: { status: "aacOccStatus" }, REVIEWS: { status: "aacRevStatus" } });
    await changeOrg(Number(sel.value) || null);
    window.__pmDrill?.showOnPage("aacRoot", "data-aac-main", dashDrill);
  }

  async function populateOrgs() {
    const sel = document.getElementById("aacOrg");
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
    document.getElementById("aacOrg").addEventListener("change", e => changeOrg(Number(e.target.value) || null));
    document.getElementById("aacTemplate").addEventListener("change", () => { resetPagers(); selectMainTab(state.mainTab); });
    document.querySelectorAll("[data-aac-main]").forEach(b => b.addEventListener("click", () => selectMainTab(b.dataset.aacMain)));
    document.querySelectorAll("[data-close-aac]").forEach(b => b.addEventListener("click", () => { document.getElementById(b.dataset.closeAac).hidden = true; }));
    let t1 = null, t2 = null;
    document.getElementById("aacSchSearch").addEventListener("input", () => { clearTimeout(t1); t1 = setTimeout(() => { state.schPager?.reset(true); refreshSchedules(); }, 300); });
    document.getElementById("aacSchStatus").addEventListener("change", () => { state.schPager?.reset(true); refreshSchedules(); });
    document.getElementById("aacSchRefresh").addEventListener("click", () => refreshSchedules());
    document.getElementById("aacOccSearch").addEventListener("input", () => { clearTimeout(t2); t2 = setTimeout(() => { state.occPager?.reset(true); refreshOccurrences(); }, 300); });
    ["aacOccStatus", "aacOccReconcile", "aacOccAwaiting"].forEach(id => document.getElementById(id).addEventListener("change", () => {
      state.campaignId = null; state.occPager?.reset(true); refreshOccurrences();
    }));
    document.getElementById("aacOccBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-aac-reconcile]");
      if (b) openReconcile(Number(b.dataset.aacReconcile));
      const d = ev.target.closest("button[data-aac-open]");                    // 439
      if (d) openOccurrence(Number(d.dataset.aacOpen));
    });
    // 439: reviews, occurrence detail, decisions.
    let t3 = null;
    document.getElementById("aacRevSearch").addEventListener("input", () => { clearTimeout(t3); t3 = setTimeout(() => { state.revPager?.reset(true); refreshReviews(); }, 300); });
    document.getElementById("aacRevStatus").addEventListener("change", () => { state.revPager?.reset(true); refreshReviews(); });
    document.getElementById("aacRevBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-aac-review]");
      if (b) openReviewDecision((state.revRows || []).find(x => x.reviewId === Number(b.dataset.aacReview)));
      const o = ev.target.closest("button[data-aac-open]");
      if (o) openOccurrence(Number(o.dataset.aacOpen));
    });
    document.getElementById("aacResultForm").addEventListener("submit", ev => { ev.preventDefault(); saveResult(true); });
    document.getElementById("aacRsDraft").addEventListener("click", () => saveResult(false));
    document.querySelectorAll("[data-aac-result-decision]").forEach(b => b.addEventListener("click", () => decideResult(b.dataset.aacResultDecision)));
    document.getElementById("aacDpType").addEventListener("change", toggleDispositionDates);
    document.getElementById("aacDispForm").addEventListener("submit", ev => { ev.preventDefault(); requestDisposition(); });
    document.getElementById("aacOdDispBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-aac-disp]");
      if (b) openDispositionDecision((state.detail?.dispositions || []).find(x => x.dispositionId === Number(b.dataset.aacDisp)));
    });
    document.getElementById("aacDecisionForm").addEventListener("submit", ev => { ev.preventDefault(); saveDecision(); });
    document.getElementById("aacCmpBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-aac-campaign]");
      if (!tr) return;
      state.campaignId = Number(tr.dataset.aacCampaign);
      document.getElementById("aacOccStatus").value = "ALL";
      document.getElementById("aacOccReconcile").checked = false;
      selectMainTab("OCCURRENCES", true);
    });
    document.getElementById("aacTplBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-aac-setting]");
      if (b) openSetting(b.dataset.aacSetting);
    });
    document.getElementById("aacSettingForm").addEventListener("submit", ev => { ev.preventDefault(); saveSetting(); });
    document.getElementById("aacReconcileForm").addEventListener("submit", ev => { ev.preventDefault(); saveReconcile(); });
    document.getElementById("aacRunNow")?.addEventListener("click", runNow);
  }

  function resetPagers() { state.schPager?.reset(true); state.occPager?.reset(true); state.cmpPager?.reset(true); state.revPager?.reset(true); }

  async function changeOrg(id) {
    state.organizationId = id;
    state.config = null;
    state.campaignId = null;
    hideMessage();
    resetPagers();
    if (id) await loadConfig();
    await selectMainTab(state.mainTab);
  }

  async function selectMainTab(name, keepCampaign) {
    state.mainTab = name;
    if (!keepCampaign && name !== "OCCURRENCES") state.campaignId = null;
    document.querySelectorAll("[data-aac-main]").forEach(x => { const on = x.dataset.aacMain === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    document.querySelectorAll("[data-aac-mainpanel]").forEach(p => { p.hidden = p.dataset.aacMainpanel !== name; });
    if (name === "OCCURRENCES") await refreshOccurrences();
    else if (name === "CAMPAIGNS") await refreshCampaigns();
    else if (name === "REVIEWS") await refreshReviews();                       // 439
    else if (name === "TEMPLATES") { await loadConfig(); renderTemplates(); }
    else await refreshSchedules();
  }

  async function loadConfig() {
    if (!state.organizationId) return;
    const res = await api("GET", `/config?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.config = res.data.data;
    const sel = document.getElementById("aacTemplate"), keep = sel.value;
    sel.innerHTML = `<option value="">All activities</option>` +
      state.config.templates.map(t => `<option value="${esc(t.templateCode)}">${esc(t.templateName)}</option>`).join("");
    sel.value = keep;
  }

  // ------------------------------------------------------------------ schedules
  async function refreshSchedules() {
    const body = document.getElementById("aacSchBody");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); state.schPager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.schPager ? state.schPager.page() : 1, pageSize: state.schPager ? state.schPager.size() : 25 });
    if (val("aacTemplate")) qs.set("templateCode", val("aacTemplate"));
    if (val("aacSchStatus")) qs.set("status", val("aacSchStatus"));
    if (val("aacSchSearch")) qs.set("search", val("aacSchSearch"));
    const res = await api("GET", `/schedules?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.schPager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.schPager?.setTotal(res.data.data.totalRows, rows.length);
    body.innerHTML = rows.map(s => {
      const [sl, sc] = STATUS[s.statusCode] || [s.statusCode, ""];
      const days = s.daysToDue;
      return `<tr><td>${esc(s.assetName)}<div class="aac-note">${esc(s.assetTypeName || "")}</div></td>
        <td>${esc(s.templateName)}</td>
        <td>${esc(s.frequencyText || "--")}${s.basis ? `<div class="aac-note">${esc(label(s.basis))}</div>` : ""}</td>
        <td>${esc(date(s.lastDoneDate) || "--")}</td>
        <td>${s.revisedDueDate ? `<div class="aac-note">Rescheduled to ${esc(date(s.revisedDueDate))}</div>` : ""}${s.nextDueDate ? esc(date(s.nextDueDate)) + `<div class="aac-note">${days < 0 ? esc(-days) + " days overdue" : days === 0 ? "today" : "in " + esc(days) + " days"}${s.dueSource ? ", " + esc(DUE_SOURCE[s.dueSource] || s.dueSource) : ""}</div>` : "--"}</td>
        <td><span class="aac-chip ${sc}">${esc(sl)}</span>${s.notScheduledReason ? `<div class="aac-note">${esc(s.notScheduledReason)}</div>` : ""}</td>
        <td>${s.contractNumber ? esc(s.contractNumber + " v" + s.contractVersionNo) + (s.coverageEnd ? `<div class="aac-note">to ${esc(date(s.coverageEnd))}</div>` : "") : "--"}</td>
        <td>${s.openOccurrenceKey ? esc(s.openOccurrenceKey) + (s.openTaskId ? `<div><a href="${U("/Practice/Index/task-view?taskId=" + s.openTaskId)}">Task #${esc(s.openTaskId)}</a></div>` : "")
              + (s.needsReconciliation ? `<div><span class="aac-chip aac-st-bad">Reconcile</span></div>` : "") : "--"}</td></tr>`;
    }).join("") || empty(8, "No schedules. Assets need the activity marked as required on the asset register.");
  }

  // ------------------------------------------------------------------ occurrences
  async function refreshOccurrences() {
    const body = document.getElementById("aacOccBody");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); state.occPager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId, status: val("aacOccStatus"),
      pageNumber: state.occPager ? state.occPager.page() : 1, pageSize: state.occPager ? state.occPager.size() : 25 });
    if (val("aacTemplate")) qs.set("templateCode", val("aacTemplate"));
    if (document.getElementById("aacOccReconcile").checked) qs.set("reconcileOnly", "true");
    if (state.campaignId) qs.set("campaignId", state.campaignId);
    if (val("aacOccSearch")) qs.set("search", val("aacOccSearch"));
    if (document.getElementById("aacOccAwaiting").checked) qs.set("awaitingDecision", "true");   // 439
    const res = await api("GET", `/occurrences?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.occPager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.occPager?.setTotal(res.data.data.totalRows, rows.length);
    if (state.campaignId && rows.length) showMessage(`Items of campaign ${rows[0].campaignName || ""}. Change the status filter to leave the campaign.`, "info");
    body.innerHTML = rows.map(o => {
      const [ol, oc] = OCC_STATUS[o.status] || [o.status, ""];
      const [rl, rc] = RESULT_STATE[o.resultState] || ["", ""];
      return `<tr><td><button class="pm-link-button" type="button" data-aac-open="${o.occurrenceId}">${esc(o.occurrenceKey)}</button><div class="aac-note">${esc(o.templateName)}${o.isRetest ? " - re-test" : ""}${o.campaignKey ? " - " + esc(o.campaignKey) : ""}</div></td>
        <td>${esc(o.assetName)}</td>
        <td>${esc(date(o.dueDate))}${o.revisedDueDate ? `<div class="aac-note">Rescheduled to ${esc(date(o.revisedDueDate))}</div>` : ""}${o.status === "OPEN" ? `<div class="aac-note">${o.daysToDue < 0 ? esc(-o.daysToDue) + " days overdue" : "in " + esc(o.daysToDue) + " days"}</div>` : ""}${o.reviewDate ? `<div class="aac-note">Review ${esc(date(o.reviewDate))}</div>` : ""}</td>
        <td>${esc(o.decision === "CONTRACT_COVERED" ? "Covered by contract" : "Asset task")}
            ${o.contractNumber ? `<div class="aac-note">Contract ${esc(o.contractNumber + " v" + o.contractVersionNo)}</div>` : ""}
            <div class="aac-note">${esc(o.decisionReason || "")}</div></td>
        <td>${o.taskId ? `<a href="${U("/Practice/Index/task-view?taskId=" + o.taskId)}">${esc(o.taskNumber || "#" + o.taskId)}</a><div class="aac-note">${esc(o.taskStatusName || "")} - ${esc(o.taskOwnerName || "unassigned")}</div>`
              : o.taskError ? `<span class="aac-chip aac-st-bad">Not created</span><div class="aac-note">${esc(o.taskError)}</div>` : "--"}</td>
        <td><span class="aac-chip ${oc}">${esc(ol)}</span>${o.completedDt ? `<div class="aac-note">${esc(dateTime(o.completedDt))} ${esc(o.completedByName || "")}</div>` : ""}</td>
        <td>${o.resultState ? `<span class="aac-chip ${rc}">${esc(rl)}</span>${o.resultOutcome ? `<div class="aac-note">${esc(OUTCOME[o.resultOutcome] || o.resultOutcome)}</div>` : ""}` : "--"}
            ${o.pendingDispositionType ? `<div><span class="aac-chip aac-st-wait">${esc(DISPOSITION[o.pendingDispositionType] || o.pendingDispositionType)} pending</span></div>` : ""}</td>
        <td>${o.needsReconciliation ? `<span class="aac-chip aac-st-bad">Needed</span><div class="aac-note">${esc(o.reconciliationReason || "")}</div>`
              + (CAN_EDIT ? `<button class="pm-button" type="button" data-aac-reconcile="${o.occurrenceId}">Reconcile</button>` : "")
              : o.reconciledDt ? `<div class="aac-note">${esc(o.reconciledNote || "")} (${esc(o.reconciledBy || "")} ${esc(dateTime(o.reconciledDt))})</div>` : "--"}</td></tr>`;
    }).join("") || empty(8, "No occurrences. The scheduler opens them when a due date comes within the lead days.");
    state.occRows = rows;
  }

  function openReconcile(id) {
    const o = (state.occRows || []).find(x => x.occurrenceId === id);
    if (!o) return;
    state.reconcile = o;
    document.getElementById("aacRecTitle").textContent = `Reconcile - ${o.occurrenceKey}`;
    document.getElementById("aacRecReason").textContent = o.reconciliationReason || "";
    document.getElementById("aacRecNote").value = "";
    hide("aacRecMessage");
    document.getElementById("aacReconcileModal").hidden = false;
  }

  async function saveReconcile() {
    const o = state.reconcile;
    const note = val("aacRecNote");
    if (!note) { show("aacRecMessage", "Enter the reconciliation note."); return; }
    const res = await api("POST", `/occurrences/${o.occurrenceId}/reconcile`, {
      organizationId: state.organizationId, note, expectedRecordVersion: o.recordVersion
    });
    if (!res.ok) { show("aacRecMessage", res.error); return; }
    document.getElementById("aacReconcileModal").hidden = true;
    showMessage("Reconciliation recorded.", "success");
    await refreshOccurrences();
  }

  // ------------------------------------------------------------------ campaigns
  async function refreshCampaigns() {
    const body = document.getElementById("aacCmpBody");
    if (!state.organizationId) { body.innerHTML = empty(9, "Select an organization."); state.cmpPager?.clear(); return; }
    body.innerHTML = empty(9, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.cmpPager ? state.cmpPager.page() : 1, pageSize: state.cmpPager ? state.cmpPager.size() : 25 });
    const res = await api("GET", `/campaigns?${qs}`);
    if (!res.ok) { body.innerHTML = empty(9, res.error); state.cmpPager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.cmpPager?.setTotal(res.data.data.totalRows, rows.length);
    body.innerHTML = rows.map(c => {
      const [cl, cc] = CMP_STATUS[c.campaignStatus] || [c.campaignStatus, ""];
      return `<tr data-aac-campaign="${c.campaignId}"><td>${esc(c.campaignName)}<div class="aac-note">${esc(c.campaignKey)}</div></td>
        <td>${esc(c.templateName)}</td><td>${esc(String(c.periodKey).substring(0, 4) + "-" + String(c.periodKey).substring(4))}</td>
        <td>${esc(c.ownerName || "--")}</td><td>${esc(c.itemCount)}</td><td>${esc(c.openCount)}</td><td>${esc(c.completedCount)}</td>
        <td>${esc(c.cancelledCount)}</td><td><span class="aac-chip ${cc}">${esc(cl)}</span></td></tr>`;
    }).join("") || empty(9, "No campaigns. Set an activity to monthly campaigns on the Templates tab.");
  }

  // ------------------------------------------------------------------ templates
  function renderTemplates() {
    const body = document.getElementById("aacTplBody"), c = state.config;
    if (!c) { body.innerHTML = empty(8, state.organizationId ? "Could not load the templates." : "Select an organization."); return; }
    body.innerHTML = c.templates.map(t => `<tr>
        <td>${esc(t.templateName)}<div class="aac-note">${esc(t.activityKind === "RENEWAL" ? "Renewal" : "Execution")}</div></td>
        <td><div class="aac-note">${esc(t.description)}</div>
            <div class="aac-note">${t.resultRequired ? (t.resultReviewRequired ? "Result approved by a reviewer." : "Result approved on submission.") : ""}
              ${t.dispositionApprovalRequired ? "Reschedule / waive need approval." : "Reschedule / waive apply at once."}
              ${t.restrictOnOverdue && t.restrictOnOverdue !== "NONE" ? "Restrictive review when overdue: " + esc(label(t.restrictOnOverdue.replace(/,/g, ", "))) + "." : ""}
              ${t.restrictOnFail ? "Restrictive review on a failed result." : ""}
              ${t.retestDays != null ? "Re-test " + esc(t.retestDays) + " days after a failure." : ""}</div></td>
        <td><div class="aac-note">${esc([t.requiredFieldKey, t.frequencyFieldKey, t.basisFieldKey, t.lastDateFieldKey, t.expiryFieldKey].filter(Boolean).join(", "))}
            ${t.ownerFieldKey ? "<br/>Task owner: " + esc(t.ownerFieldKey) + ", else the asset owner" : ""}</div></td>
        <td>${esc(t.coverageTypes || "--")}</td>
        <td>${esc(t.leadDays)} / ${esc(t.dueSoonDays)} days</td>
        <td>${esc(t.groupingMode === "CAMPAIGN" ? "Monthly campaign" : "Individual")}${t.campaignOwnerName ? `<div class="aac-note">${esc(t.campaignOwnerName)}</div>` : ""}</td>
        <td>${esc(t.notificationActivityName)}</td>
        <td><span class="aac-chip ${t.isActive ? "aac-st-active" : "aac-st-ended"}">${t.isActive ? "Active" : "Inactive"}</span>
            ${CAN_EDIT ? `<div><button class="pm-button" type="button" data-aac-setting="${esc(t.templateCode)}">Settings</button></div>` : ""}</td></tr>`).join("");
    // 439: evidence date fields.
    document.getElementById("aacEvidenceBody").innerHTML = (c.evidenceFields || []).map(e => `<tr>
        <td>${esc(e.evidenceName)}</td><td>${esc(e.fieldLabel || e.fieldKey)}<div class="aac-note">${esc(e.fieldKey)}</div></td>
        <td>${esc(e.ownerFieldKey ? e.ownerFieldKey + ", else the asset owner" : "Asset owner")}</td>
        <td>${e.restrictOnExpiry ? "Yes" : "No"}</td></tr>`).join("") || empty(4, "No evidence fields.");
  }

  function openSetting(code) {
    const t = state.config.templates.find(x => x.templateCode === code);
    if (!t) return;
    state.setting = t;
    document.getElementById("aacSettingTitle").textContent = `Activity settings - ${t.templateName}`;
    document.getElementById("aacStActive").checked = !!t.isActive;
    document.getElementById("aacStLead").value = t.leadDays;
    document.getElementById("aacStSoon").value = t.dueSoonDays;
    document.getElementById("aacStGrouping").value = t.groupingMode;
    document.getElementById("aacStOwner").innerHTML = `<option value="">--</option>` +
      state.config.employees.map(e => `<option value="${e.employeeId}">${esc(e.employeeName)}</option>`).join("");
    document.getElementById("aacStOwner").value = t.campaignOwnerEmployeeId ? String(t.campaignOwnerEmployeeId) : "";
    // 439
    document.getElementById("aacStReview").checked = !!t.resultReviewRequired;
    document.getElementById("aacStApproval").checked = !!t.dispositionApprovalRequired;
    const ov = document.getElementById("aacStOverdue");
    if (![...ov.options].some(x => x.value === t.restrictOnOverdue)) ov.insertAdjacentHTML("beforeend", `<option value="${esc(t.restrictOnOverdue)}">${esc(t.restrictOnOverdue)}</option>`);
    ov.value = t.restrictOnOverdue || "NONE";
    document.getElementById("aacStFail").checked = !!t.restrictOnFail;
    document.getElementById("aacStFail").disabled = t.activityKind === "RENEWAL";
    hide("aacStMessage");
    document.getElementById("aacSettingModal").hidden = false;
  }

  async function saveSetting() {
    const res = await api("POST", "/settings", {
      organizationId: state.organizationId, templateCode: state.setting.templateCode,
      isActive: document.getElementById("aacStActive").checked,
      leadDays: Number(val("aacStLead")), dueSoonDays: Number(val("aacStSoon")),
      groupingMode: val("aacStGrouping"), campaignOwnerEmployeeId: Number(val("aacStOwner")) || null,
      resultReviewRequired: document.getElementById("aacStReview").checked,                       // 439
      dispositionApprovalRequired: document.getElementById("aacStApproval").checked,
      restrictOnOverdue: val("aacStOverdue"),
      restrictOnFail: state.setting.activityKind === "RENEWAL" ? false : document.getElementById("aacStFail").checked
    });
    if (!res.ok) { show("aacStMessage", res.error); return; }
    document.getElementById("aacSettingModal").hidden = true;
    await loadConfig();
    renderTemplates();
    showMessage("Settings saved. The next scheduler pass applies them.", "success");
  }

  // ------------------------------------------------------------------ occurrence detail (439)
  async function openOccurrence(id) {
    if (!id) return;
    const res = await api("GET", `/occurrences/${id}?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.detail = res.data.data;
    renderOccurrence();
    hide("aacOdMessage");
    document.getElementById("aacOccModal").hidden = false;
  }

  function renderOccurrence() {
    const d = state.detail, o = d.occurrence, r = d.result;
    const [ol] = OCC_STATUS[o.status] || [o.status];
    document.getElementById("aacOdTitle").textContent = `${o.templateName} - ${o.assetName}`;
    document.getElementById("aacOdInfo").innerHTML = [
      ["Occurrence", o.occurrenceKey + (o.isRetest ? " (re-test)" : "")], ["Status", ol],
      ["Due", date(o.dueDate) + (o.revisedDueDate ? ", rescheduled to " + date(o.revisedDueDate) : "")],
      ["Review date", date(o.reviewDate) || "--"],
      ["Task", o.taskId ? (o.taskNumber || "#" + o.taskId) + " - " + (o.taskStatusName || "") + " - " + (o.taskOwnerName || "unassigned") : "--"],
      ["Contract", o.contractNumber ? o.contractNumber + " v" + o.contractVersionNo : "--"],
      ["Decision", o.decisionReason || "--"],
      ["Reconciliation", o.needsReconciliation ? o.reconciliationReason || "Needed" : "--"]
    ].map(([k, v]) => `<div><span>${esc(k)}</span>${esc(v)}</div>`).join("");

    // Result.
    const renewal = o.activityKind === "RENEWAL";
    const outcomes = renewal ? ["RENEWED", "NOT_RENEWED"] : ["PASS", "FAIL"];
    document.getElementById("aacRsOutcome").innerHTML = `<option value="">--</option>` + outcomes.map(x => `<option value="${x}">${esc(OUTCOME[x])}</option>`).join("");
    document.getElementById("aacRsOutcome").value = r?.outcome || "";
    document.getElementById("aacRsPerformed").value = date(r?.performedDate);
    document.getElementById("aacRsCertNo").value = r?.certificateNumber || "";
    document.getElementById("aacRsCertExp").value = date(r?.certificateExpiry);
    document.getElementById("aacRsNewExp").value = date(r?.newExpiry);
    document.getElementById("aacRsEvidence").value = r?.evidenceReference || "";
    document.getElementById("aacRsNote").value = r?.resultNote || "";
    document.querySelectorAll("[data-aac-cert]").forEach(x => { x.hidden = renewal || !o.certificateNumberFieldKey; });
    document.querySelectorAll("[data-aac-renewal]").forEach(x => { x.hidden = !renewal; });
    const [sl] = RESULT_STATE[r?.state] || [""];
    document.getElementById("aacOdResultState").textContent = r
      ? `${sl}${r.submittedByName || r.submittedBy ? " - submitted by " + (r.submittedByName || r.submittedBy) : ""}${r.decidedDt ? ", " + (r.state === "RETURNED" ? "returned" : "decided") + " by " + (r.decidedByName || r.decidedBy || "") : ""}${r.decisionNote ? ": " + r.decisionNote : ""}`
      : (o.resultReviewRequired ? "A reviewer approves the submitted result." : "The submitted result is approved at once.");
    const editable = CAN_EDIT && o.status === "OPEN" && o.decision === "ASSET_TASK" && !(r && (r.state === "SUBMITTED" || r.state === "APPROVED"));
    document.querySelectorAll("#aacResultForm input, #aacResultForm select, #aacResultForm textarea").forEach(x => { x.disabled = !editable; });
    document.getElementById("aacRsButtons").hidden = !editable;
    document.getElementById("aacRsReview").hidden = !(CAN_APPROVE && r && r.state === "SUBMITTED" && o.status === "OPEN");
    document.getElementById("aacRsDecisionNote").value = "";

    // Dispositions.
    const pending = (d.dispositions || []).some(x => x.status === "PENDING");
    document.getElementById("aacOdDispBody").innerHTML = (d.dispositions || []).map(x => {
      const [dl, dc] = DISP_STATUS[x.status] || [x.status, ""];
      return `<tr><td>${esc(DISPOSITION[x.dispositionType] || x.dispositionType)}<div class="aac-note">${esc(x.requestedByName || x.requestedBy)} ${esc(dateTime(x.requestedDt))}</div></td>
        <td>${x.revisedDueDate ? "Due " + esc(date(x.previousDueDate)) + " to " + esc(date(x.revisedDueDate)) : "Until " + esc(date(x.reviewDate))}</td>
        <td>${esc(x.reason)}${x.taskNote ? `<div class="aac-note">${esc(x.taskNote)}</div>` : ""}</td>
        <td><span class="aac-chip ${dc}">${esc(dl)}</span>${x.decidedDt ? `<div class="aac-note">${esc(x.decidedByName || x.decidedBy || "")} ${esc(dateTime(x.decidedDt))}${x.decisionNote ? ": " + esc(x.decisionNote) : ""}</div>` : ""}</td>
        <td>${x.status === "PENDING" && (CAN_APPROVE || CAN_EDIT) ? `<button class="pm-button" type="button" data-aac-disp="${x.dispositionId}">Decide</button>` : ""}</td></tr>`;
    }).join("") || empty(5, "No requests.");
    document.getElementById("aacDispForm").hidden = !(CAN_EDIT && o.status === "OPEN" && !pending);
    document.getElementById("aacDpType").value = "RESCHEDULE";
    document.getElementById("aacDpRevised").value = "";
    document.getElementById("aacDpReview").value = "";
    document.getElementById("aacDpReason").value = "";
    toggleDispositionDates();

    // Reviews.
    document.getElementById("aacOdRevBody").innerHTML = (d.reviews || []).map(x => {
      const [vl, vc] = REV_STATUS[x.status] || [x.status, ""];
      return `<tr><td>${esc(x.title)}</td><td>${esc(date(x.triggerDate))}</td><td><span class="aac-chip ${vc}">${esc(vl)}</span></td>
        <td>${x.decisionCode ? esc(REV_ACTION[x.decisionCode] || x.decisionCode) + `<div class="aac-note">${esc(x.decisionNote || "")}</div>` : "--"}</td></tr>`;
    }).join("") || empty(4, "No restrictive-use reviews.");
  }

  function toggleDispositionDates() {
    const reschedule = val("aacDpType") === "RESCHEDULE";
    document.getElementById("aacDpRevisedWrap").hidden = !reschedule;
    document.getElementById("aacDpReviewWrap").hidden = reschedule;
  }

  async function reloadDetail(text) {
    await openOccurrence(state.detail.occurrence.occurrenceId);
    if (text) show("aacOdMessage", text, "success");
    await refreshOccurrences();
  }

  async function saveResult(submit) {
    const o = state.detail.occurrence, r = state.detail.result;
    if (submit && !await window.gracUi.confirm(o.resultReviewRequired
        ? "Submit the result for review? It cannot be changed while it waits for review."
        : "Submit the result? It is approved at once and updates the asset register.")) return;
    const res = await api("POST", `/occurrences/${o.occurrenceId}/result`, {
      organizationId: state.organizationId, outcome: val("aacRsOutcome") || null, performedDate: val("aacRsPerformed") || null,
      certificateNumber: val("aacRsCertNo") || null, certificateExpiry: val("aacRsCertExp") || null,
      newExpiry: val("aacRsNewExp") || null, evidenceReference: val("aacRsEvidence") || null, resultNote: val("aacRsNote") || null,
      submit, expectedRecordVersion: r ? r.recordVersion : null
    });
    if (!res.ok) { show("aacOdMessage", res.error); return; }
    await reloadDetail(submit ? "Result submitted." : "Draft saved.");
  }

  async function decideResult(decision) {
    const o = state.detail.occurrence, r = state.detail.result;
    const note = val("aacRsDecisionNote");
    if (decision === "RETURN" && !note) { show("aacOdMessage", "Give the reason for returning the result."); return; }
    const res = await api("POST", `/occurrences/${o.occurrenceId}/result-decision`, {
      organizationId: state.organizationId, decision, decisionNote: note || null, expectedRecordVersion: r.recordVersion
    });
    if (!res.ok) { show("aacOdMessage", res.error); return; }
    await reloadDetail(decision === "APPROVE" ? "Result approved; the asset register is updated." : "Result returned.");
  }

  async function requestDisposition() {
    const o = state.detail.occurrence, type = val("aacDpType");
    const res = await api("POST", `/occurrences/${o.occurrenceId}/disposition`, {
      organizationId: state.organizationId, dispositionType: type, reason: val("aacDpReason") || null,
      revisedDueDate: type === "RESCHEDULE" ? val("aacDpRevised") || null : null,
      reviewDate: type === "RESCHEDULE" ? null : val("aacDpReview") || null,
      expectedRecordVersion: o.recordVersion
    });
    if (!res.ok) { show("aacOdMessage", res.error); return; }
    await reloadDetail(res.data.result === "APPROVED" ? "Applied." : "Request recorded; it waits for approval.");
  }

  function openDispositionDecision(x) {
    if (!x) return;
    const opts = [];
    if (CAN_APPROVE) opts.push(["APPROVE", "Approve"], ["REJECT", "Reject"]);
    if (CAN_EDIT) opts.push(["WITHDRAW", "Withdraw (requester only)"]);
    openDecision({ kind: "DISPOSITION", id: x.dispositionId, recordVersion: x.recordVersion },
      `${DISPOSITION[x.dispositionType] || x.dispositionType} - ${x.reason}`, opts, "Note (required to reject)");
  }

  function openReviewDecision(x) {
    if (!x) return;
    openDecision({ kind: "REVIEW", id: x.reviewId, recordVersion: x.recordVersion },
      `${x.title} (since ${date(x.triggerDate)})`, reviewActions(x).map(a => [a, REV_ACTION[a] || label(a)]), "Reason / action taken *");
  }

  function openDecision(target, info, options, noteLabel) {
    state.decision = target;
    document.getElementById("aacDcTitle").textContent = target.kind === "REVIEW" ? "Restrictive-use review" : "Request decision";
    document.getElementById("aacDcInfo").textContent = info;
    document.getElementById("aacDcDecision").innerHTML = options.map(([v, l]) => `<option value="${esc(v)}">${esc(l)}</option>`).join("");
    document.getElementById("aacDcNoteLabel").textContent = noteLabel;
    document.getElementById("aacDcNote").value = "";
    hide("aacDcMessage");
    document.getElementById("aacDecisionModal").hidden = false;
  }

  async function saveDecision() {
    const t = state.decision;
    const path = t.kind === "REVIEW" ? `/reviews/${t.id}/decision` : `/dispositions/${t.id}/decision`;
    const res = await api("POST", path, {
      organizationId: state.organizationId, decision: val("aacDcDecision"), decisionNote: val("aacDcNote") || null,
      expectedRecordVersion: t.recordVersion
    });
    if (!res.ok) { show("aacDcMessage", res.error); return; }
    document.getElementById("aacDecisionModal").hidden = true;
    if (t.kind === "REVIEW") { showMessage("Decision recorded.", "success"); await refreshReviews(); }
    else await reloadDetail("Decision recorded.");
  }

  // ------------------------------------------------------------------ restrictive-use reviews (439)
  async function refreshReviews() {
    const body = document.getElementById("aacRevBody");
    if (!state.organizationId) { body.innerHTML = empty(7, "Select an organization."); state.revPager?.clear(); return; }
    body.innerHTML = empty(7, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.revPager ? state.revPager.page() : 1, pageSize: state.revPager ? state.revPager.size() : 25 });
    if (val("aacRevStatus")) qs.set("status", val("aacRevStatus"));
    if (val("aacRevSearch")) qs.set("search", val("aacRevSearch"));
    const res = await api("GET", `/reviews?${qs}`);
    if (!res.ok) { body.innerHTML = empty(7, res.error); state.revPager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.revPager?.setTotal(res.data.data.totalRows, rows.length);
    state.revRows = rows;
    body.innerHTML = rows.map(r => {
      const [vl, vc] = REV_STATUS[r.status] || [r.status, ""];
      return `<tr><td>${esc(r.title)}<div class="aac-note">${esc(r.sourceName)} - ${esc(label(r.triggerCode))}</div>
            ${r.occurrenceId ? `<button class="pm-link-button" type="button" data-aac-open="${r.occurrenceId}">Open occurrence</button>` : ""}</td>
        <td>${esc(r.assetName)}</td><td>${esc(date(r.triggerDate))}</td><td>${esc(label(r.severityCode))}</td>
        <td><span class="aac-chip ${vc}">${esc(vl)}</span>${r.resolvedDt ? `<div class="aac-note">${esc(dateTime(r.resolvedDt))}</div>` : ""}</td>
        <td>${r.decisionCode ? esc(REV_ACTION[r.decisionCode] || r.decisionCode) + `<div class="aac-note">${esc(r.decisionNote || "")} (${esc(r.decidedByName || r.decidedBy || "")} ${esc(dateTime(r.decidedDt))})</div>` : "--"}</td>
        <td>${CAN_APPROVE && r.status !== "RESOLVED" ? `<button class="pm-button" type="button" data-aac-review="${r.reviewId}">${r.status === "DECIDED" ? "Change" : "Decide"}</button>` : ""}</td></tr>`;
    }).join("") || empty(7, "No restrictive-use reviews.");
  }

  // ------------------------------------------------------------------ run now
  async function runNow() {
    if (!await window.gracUi.confirm("Run the scheduler now for this organization? Completed tasks are recorded, schedules recalculated, and occurrences and tasks created for due dates within the lead days (reminders are recorded too).")) return;
    const btn = document.getElementById("aacRunNow");
    btn.disabled = true;
    const res = await api("POST", "/run", { organizationId: state.organizationId });
    btn.disabled = false;
    if (!res.ok) { showMessage(res.error, "error"); return; }
    const r = res.data.data || {};
    showMessage(r.result === "SKIPPED" ? (r.errorText || "Another scheduler run is in progress.")
      : `Run ${label(r.result)}: ${r.tasksCreated || 0} activity task(s), ${r.notificationsQueued || 0} notice(s), ${r.errorCount || 0} error(s).`
        + (r.errorCount && r.errorText ? " " + r.errorText : ""),
      r.errorCount ? "error" : "success");
    await selectMainTab(state.mainTab, true);
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
    const el = document.getElementById("aacMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.classList.toggle("info", kind === "info"); el.hidden = !text;
  }
  function hideMessage() { const el = document.getElementById("aacMessage"); el.hidden = true; el.textContent = ""; }
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
