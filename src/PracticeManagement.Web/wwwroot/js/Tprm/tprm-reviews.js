// =====================================================================
// Third-Party Reviews (migrations 486-490). Loaded by tprm-reviews.cshtml.
// Backend: practice/api/tprm (TprmController)
//   GET  reviews?organizationId&status&reviewType&engagementId&dueWithinDays
//        &ownerEmployeeId&search&pageNumber&pageSize
//   POST reviews/{id}/complete { organizationId, outcomeCode, outcomeNote, cancel }
//   POST monitoring/run        { organizationId }   (APPROVE)
// Drill parameters (490 dashboard): status, type, dueWithin.
// =====================================================================
(() => {
  "use strict";

  const T = window.gracTprm;
  const root = document.getElementById("rvRoot");
  if (!root || !T) return;
  const { F, esc, date, empty, show, hide, api, qs } = T;
  const CAN_EDIT = root.dataset.canEdit === "1";
  const OUTCOMES = [
    { value: "NO_CHANGE", label: "No change -- the risk is as assessed" },
    { value: "REMEDIATE", label: "Remediation needed (record findings on the engagement)" },
    { value: "REASSESS", label: "Reassess the engagement" },
    { value: "SUSPEND", label: "Suspend the engagement" },
    { value: "EXIT", label: "Exit the third party" }];
  const TYPES = { PERIODIC: "Periodic", TRIGGERED: "Triggered", CONTRACT_EXPIRY: "Contract expiry",
                  CERTIFICATION_EXPIRY: "Certification expiry", ACCEPTANCE_EXPIRY: "Risk acceptance expiry" };
  const state = { org: null, lk: null, pager: null, rows: [], engagementId: null };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    state.pager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "rvPager", onChange: refreshList }) : null;
    bind();
    const q = new URLSearchParams(window.location.search);
    state.org = await T.orgs("rvOrg");
    await loadOrg();
    if (q.get("status")) setIf("rvStatusFilter", q.get("status"));
    if (q.get("type")) setIf("rvTypeFilter", q.get("type"));
    if (q.get("dueWithin")) setIf("rvDueFilter", q.get("dueWithin"));
    state.engagementId = Number(q.get("engagementId")) || null;
    if (state.engagementId) { setIf("rvStatusFilter", "ALL"); }
    const drill = window.__pmDrill?.read();
    if (drill && (q.get("status") || q.get("type") || q.get("dueWithin")) && q.get("from")) {
      let host = document.getElementById("pmDrillBanner");
      if (!host) { host = document.createElement("div"); host.id = "pmDrillBanner"; root.parentNode.insertBefore(host, root); }
      window.__pmDrill.banner(host, { ...drill, active: true });
    }
    await refreshList();
    const reviewId = Number(q.get("reviewId"));
    if (reviewId > 0) {
      const row = state.rows.find(r => Number(F(r, "reviewId")) === reviewId);
      if (row && F(row, "status") === "OPEN" && CAN_EDIT) complete(row);
    }
  }
  function setIf(id, v) {
    const sel = document.getElementById(id);
    if ([...sel.options].some(o => o.value === v)) sel.value = v;
  }

  function bind() {
    document.getElementById("rvOrg").addEventListener("change", async e => { state.org = Number(e.target.value) || null; state.engagementId = null; await loadOrg(); await refreshList(); });
    document.getElementById("rvRefresh").addEventListener("click", () => refreshList());
    let t = null;
    document.getElementById("rvSearch").addEventListener("input", () => { clearTimeout(t); t = setTimeout(() => { state.pager?.reset(true); refreshList(); }, 300); });
    ["rvStatusFilter", "rvTypeFilter", "rvDueFilter", "rvOwnerFilter"].forEach(id =>
      document.getElementById(id).addEventListener("change", () => { state.pager?.reset(true); refreshList(); }));
    document.getElementById("rvRun")?.addEventListener("click", runMonitoring);
    document.getElementById("rvListBody").addEventListener("click", ev => {
      const b = ev.target.closest("[data-rv-complete]");
      if (!b) return;
      const row = state.rows.find(r => String(F(r, "reviewId")) === b.dataset.rvComplete);
      if (row) complete(row, b.dataset.mode === "cancel");
    });
  }

  async function loadOrg() {
    hide("rvMessage");
    state.pager?.reset(true);
    state.lk = await T.lookups(state.org);
    if (state.lk.error) show("rvMessage", state.lk.error);
    const sel = document.getElementById("rvOwnerFilter");
    sel.length = 1;
    state.lk.employeeOptions().forEach(o => sel.add(new Option(o.label, o.value)));
  }

  async function refreshList() {
    const body = document.getElementById("rvListBody");
    const note = document.getElementById("rvEngagementNote");
    note.hidden = !state.engagementId;
    note.innerHTML = state.engagementId ? `Showing the reviews of one engagement. <a href="${esc(T.U("/Practice/Index/tprm-reviews") + "?" + qs({ organizationId: state.org }))}">Show all reviews</a>` : "";
    if (!state.org) { body.innerHTML = empty(7, "Select an organization."); state.pager?.clear(); return; }
    body.innerHTML = empty(7, "Loading...");
    const res = await api("GET", `/reviews?${qs({
      organizationId: state.org, status: val("rvStatusFilter") || "OPEN", reviewType: val("rvTypeFilter"), engagementId: state.engagementId,
      dueWithinDays: val("rvDueFilter"), ownerEmployeeId: val("rvOwnerFilter"), search: val("rvSearch"),
      pageNumber: state.pager ? state.pager.page() : 1, pageSize: state.pager ? state.pager.size() : 25 })}`);
    if (!res.ok) { body.innerHTML = empty(7, res.error); state.pager?.clear(); return; }
    state.rows = res.data.data || [];
    state.pager?.setTotal(res.data.totalRows, state.rows.length);
    const engHref = id => T.U("/Practice/Index/tprm-engagements") + "?" + qs({ organizationId: state.org, engagementId: id });
    body.innerHTML = state.rows.map(r => {
      const open = F(r, "status") === "OPEN";
      return `<tr>
        <td>${esc(F(r, "reviewNumber"))}${T.yes(F(r, "requiresReassessment")) ? '<div class="tprm-alert">Reassessment</div>' : ""}</td>
        <td><a href="${esc(engHref(F(r, "engagementId")))}">${esc(F(r, "engagementCode"))}</a> ${esc(F(r, "engagementTitle"))}
          <div class="tprm-muted">${esc(F(r, "thirdPartyName"))} &middot; ${esc(T.stageLabel(F(r, "stageCode")))}</div></td>
        <td>${esc(TYPES[F(r, "reviewType")] || F(r, "reviewType"))}<div class="tprm-muted">${esc(F(r, "triggerLabel") || F(r, "triggerCode"))}</div>
          ${F(r, "triggerDetail") ? `<div class="tprm-muted">${esc(F(r, "triggerDetail"))}</div>` : ""}</td>
        <td>${esc(date(F(r, "dueDt")))}${T.yes(F(r, "isOverdue")) ? ' <span class="tprm-alert">Overdue</span>' : ""}</td>
        <td>${esc(F(r, "ownerName") || "--")}</td>
        <td>${esc(F(r, "status"))}${F(r, "outcomeCode") ? `<div class="tprm-muted">${esc(F(r, "outcomeCode"))}: ${esc(F(r, "outcomeNote") || "")}</div>` : ""}</td>
        <td>${open && CAN_EDIT ? `<button type="button" class="pm-button small" data-rv-complete="${esc(F(r, "reviewId"))}"><i class="fa-solid fa-check"></i> Complete</button>
            <button type="button" class="pm-button small" data-rv-complete="${esc(F(r, "reviewId"))}" data-mode="cancel" title="Cancel review" aria-label="Cancel review"><i class="fa-solid fa-ban"></i></button>` : ""}</td>
      </tr>`;
    }).join("") || empty(7, "No reviews match.");
  }

  async function complete(row, cancel) {
    const res = await T.form({
      title: `${cancel ? "Cancel" : "Complete"} ${F(row, "reviewNumber")}`, submitText: cancel ? "Cancel review" : "Complete review",
      intro: cancel ? "A cancelled review stays in the history with the reason."
        : `${F(row, "engagementCode")} ${F(row, "engagementTitle")} -- ${F(row, "triggerLabel") || F(row, "triggerCode")}. Suspend and Exit also move the engagement.`,
      fields: [
        ...(cancel ? [] : [{ name: "outcomeCode", label: "Outcome", type: "select", options: OUTCOMES, required: true }]),
        { name: "outcomeNote", label: cancel ? "Reason" : "What the review found", type: "textarea", required: true, maxLength: 2000 }
      ],
      onSubmit: v => api("POST", `/reviews/${F(row, "reviewId")}/complete`, {
        organizationId: state.org, outcomeCode: v.outcomeCode, outcomeNote: v.outcomeNote, cancel: !!cancel })
    });
    if (!res) return;
    show("rvMessage", cancel ? "Review cancelled." : "Review completed.", "success");
    await refreshList();
  }

  async function runMonitoring() {
    if (!state.org) { show("rvMessage", "Select an organization."); return; }
    show("rvMessage", "Running the monitoring pass...", "info");
    const res = await api("POST", "/monitoring/run", { organizationId: state.org });
    if (!res.ok) { show("rvMessage", res.error); return; }
    show("rvMessage", `Monitoring pass done: ${F(res.data.result, "reviewsRaised") ?? 0} review(s) raised.`, "success");
    await refreshList();
  }

  function val(id) { return (document.getElementById(id).value || "").trim(); }
})();
