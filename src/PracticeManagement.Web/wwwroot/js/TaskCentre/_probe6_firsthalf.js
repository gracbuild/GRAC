// =====================================================================
// Task View  (dedicated full page)
// Loaded by Views/Practice/Partials/task-view.cshtml.
//
// URL: /Practice/Index/task-view?taskId=NNN
//
// WHAT THIS FILE DOES, AND WHAT IT DELIBERATELY DOES NOT
// --------------------------------------------------------------------
// This replaces the small "View" dialog (#taskDetailDialog /
// openTaskViewDrawer / renderTaskDetail in tasks.cshtml) as the actual
// destination of every Task "View" action, with a proper full page.
// It reads the exact same single API call tasks.cshtml's dialog always
// used -- GET /practice/api/tasks/{id} -- and lays the same payload out
// as page sections instead of dialog content. No new endpoint, no new
// stored procedure, no duplicate business logic; the one additive
// column (organization_name, migration 326) is projected by the same
// view (vw_pm_practice_task) this call has always read from.
//
// Everything else about the Task (Edit, Complete, Close, Add Evidence,
// Add Update/Comment) is UNCHANGED and still lives entirely in
// tasks.cshtml, reached from the Task Center grid's own row menu --
// this page is read-only, the same way Risk Centre's "View risk" full
// page is read-only and all of a risk's actions stay on the Register
// grid's row menu, not on the view page.
//
// "Related Gap / Risk / Exception" reuses the task's own existing
// source-navigation fields (BRD §15: sourceTypeCode / sourceRecordId /
// sourceReference, already stored at task-open time -- see 196's own
// comment for the exact vocabulary): Gap -> gap-view.cshtml, Exception
// -> exception-view.cshtml (new, see below), Risk -> risk-centre's
// candidate modal, RiskRegister -> risk-centre's registered-risk full
// page -- all three are existing deep-links, not new pages.
// =====================================================================
(() => {
  "use strict";

  const U       = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const taskBase = "/practice/api/tasks";

  // Where "Related <X>" links out to, keyed by the task's own
  // source_type_code (BRD §15, vocabulary fixed by migration 196):
  //   Gap          -> Gap View
  //   Exception    -> Exception View
  //   Risk         -> Risk Centre's candidate detail (not yet registered)
  //   RiskRegister -> Risk Centre's registered-risk full page (215)
  // ContinuousAssurance / EventAssurance / Custom have no dedicated full
  // view to link to today, so they render as plain text.
  const SOURCE_LINK = {
    Gap:          id => U("/Practice/Index/gap-view") + "?gapId=" + encodeURIComponent(id),
    Exception:    id => U("/Practice/Index/exception-view") + "?exceptionId=" + encodeURIComponent(id),
    Risk:         id => U("/Practice/Index/risk-centre") + "#candidateId=" + encodeURIComponent(id),
    RiskRegister: id => U("/Practice/Index/risk-centre") + "#riskId=" + encodeURIComponent(id)
  };
  const SOURCE_LABEL = {
    Gap: "Gap", Exception: "Exception", Risk: "Risk", RiskRegister: "Risk",
    ContinuousAssurance: "Continuous Assurance", EventAssurance: "Event Assurance", Custom: "Source"
  };

  const state = { taskId: null, detail: null };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    const root = document.getElementById("tvRoot");
    if (!root) return;

    const params = new URLSearchParams(location.search);
    state.taskId = Number(params.get("taskId")) || 0;

    if (!state.taskId) {
      unavailable("No task was specified.", "Open this page from Task Center's row menu.");
      return;
    }

    document.getElementById("tvRefreshBtn").addEventListener("click", load);
    await load();
  }

  function unavailable(title, body) {
    document.getElementById("tvRoot").hidden = true;
    document.getElementById("tvUnavailable").hidden = false;
    document.getElementById("tvUnavailableTitle").textContent = title;
    document.getElementById("tvUnavailableBody").textContent = body;
  }

  async function load() {
    const detail = await apiGet(`/${state.taskId}`);
    if (!detail || !detail.header) {
      unavailable("Task not found.", "It may have been removed, or the link is out of date.");
      return;
    }
    state.detail = detail;
    document.getElementById("tvRoot").hidden = false;
    document.getElementById("tvUnavailable").hidden = true;
    render(detail);
  }

  async function apiGet(path) {
    try {
      const r = await fetch(U(taskBase + path), { credentials: "same-origin" });
      if (!r.ok) return null;
      return await r.json();
    } catch (_) {
      return null;
    }
  }

  function render(d) {
    const h = d.header;

    document.getElementById("tvHeading").textContent =
      (h.taskNumber || ("Task #" + h.taskId)) + " — " + (h.subjectTitle || "");
    document.getElementById("tvStatusChip").textContent = h.currentStatusName || h.currentStatusCode || "-";
    document.getElementById("tvOpenTaskCenterLink").href =
      U("/Practice/Index/tasks") + "#taskId=" + encodeURIComponent(h.taskId);

    document.getElementById("tvFacts").innerHTML = renderFacts(h);
    renderRelatedSource(h);
    renderDescription(h);
    renderCompletion(h);
    renderChildren(d.children || [], h);
    renderGovernanceRequests(d.governanceRequests || []);
    renderEvidence(d.attachments || []);
    renderCreatedUpdated(h);
    renderActivity(d.activity || []);
  }

  function factRow(label, value) {
    const empty = value === null || value === undefined || value === "";
    return `<div><dt>${escapeHtml(label)}</dt><dd${empty ? ' class="tv-empty"' : ""}>${empty ? "—" : value}</dd></div>`;
  }

  function ownerValue(h) {
    if (h.assignedToEmployeeName) {
      const src = h.ownerSourceCode && h.ownerSourceCode !== "EXPLICIT_SOURCE" && h.ownerSourceCode !== "REASSIGNED"
        ? ` <span class="tv-hint">(${escapeHtml(ownerSourceLabel(h.ownerSourceCode))})</span>` : "";
      return escapeHtml(h.assignedToEmployeeName) + src;
    }
    if (h.assignedToEmployeeId) return escapeHtml(String(h.assignedToEmployeeId));
    return '<span class="tv-warn">Unassigned</span>';
  }

  function ownerSourceLabel(code) {
    return ({
      PRACTICE_OWNER: "from Practice owner", CONTROL_OWNER: "from Control owner",
      PROCESS_OWNER: "from Process owner", FUNCTION_OWNER: "from Function owner",
      ORG_DEFAULT: "org default owner", MANUAL: "manual assignment"
    })[code] || "";
  }

  function slaStatusValue(h) {
    const code = h.slaStatusCode;
    if (!code) return h.isOverdue ? statusPill("Breached") : "";
    return statusPill(code.replace(/([a-z])([A-Z])/g, "$1 $2"));
  }

  function statusPill(text) {
    return `<span class="pm-badge">${escapeHtml(text)}</span>`;
  }

  function renderFacts(h) {
    const rows = [
      factRow("Task Reference", escapeHtml(h.taskNumber || ("#" + h.taskId))),
      factRow("Type", escapeHtml(h.taskTypeName || h.taskTypeCode)),
      factRow("Status", escapeHtml(h.currentStatusName || h.currentStatusCode)),
