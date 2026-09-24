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
      factRow("Priority", escapeHtml(h.priority || "")
        + (h.priorityChangeStatusCode === "Pending"
            ? ` <span class="tv-pending-badge">${escapeHtml(h.requestedPriority || "")} pending</span>` : "")),
      factRow("Related Organization", escapeHtml(h.organizationName || (h.organizationId ? ("#" + h.organizationId) : ""))),
      factRow("Assigned To", ownerValue(h)),
      factRow("Start Date", escapeHtml(fmtDate(h.startDate))),
      factRow("Standard Due", escapeHtml(fmtDate(h.standardDueAt))),
      factRow("Approved Extended Due", escapeHtml(fmtDate(h.approvedExtendedDueAt))),
      factRow("SLA Status", slaStatusValue(h))
    ];
    return rows.join("");
  }

  function renderRelatedSource(h) {
    const wrap = document.getElementById("tvRelatedWrap");
    if (!h.sourceTypeCode) { wrap.hidden = true; return; }
    wrap.hidden = false;
    const label = SOURCE_LABEL[h.sourceTypeCode] || h.sourceTypeCode;
    document.getElementById("tvRelatedLabel").textContent = "Related " + label;
    const text = h.sourceReference || (h.sourceRecordId ? ("#" + h.sourceRecordId) : "");
    const linkFn = SOURCE_LINK[h.sourceTypeCode];
    const el = document.getElementById("tvRelatedValue");
    if (linkFn && h.sourceRecordId) {
      el.innerHTML = `<a href="${escapeHtml(linkFn(h.sourceRecordId))}" target="_blank" rel="noopener">`
        + `${escapeHtml(text)} <i class="fa-solid fa-arrow-up-right-from-square" aria-hidden="true"></i></a>`;
    } else {
      el.textContent = text || "—";
    }
    // Parent task, if any, rides along in the same strip.
    const parentWrap = document.getElementById("tvParentWrap");
    if (h.parentTaskId) {
      parentWrap.hidden = false;
      const a = document.getElementById("tvParentLink");
      a.textContent = h.parentTaskNumber || ("#" + h.parentTaskId);
      a.href = U("/Practice/Index/task-view") + "?taskId=" + encodeURIComponent(h.parentTaskId);
    } else {
      parentWrap.hidden = true;
    }
  }

  function renderDescription(h) {
    const wrap = document.getElementById("tvDescriptionWrap");
    if (!h.subjectDescription) { wrap.hidden = true; return; }
    wrap.hidden = false;
    document.getElementById("tvDescription").textContent = h.subjectDescription;
  }

  function renderCompletion(h) {
    const wrap = document.getElementById("tvCompletionWrap");
    if (!h.completedDt && !h.closedAt) { wrap.hidden = true; return; }
    wrap.hidden = false;
    const parts = [];
    if (h.completedDt) {
      parts.push(factRow("Completed By", escapeHtml(h.completedByEmployeeName || "")));
      parts.push(factRow("Completed On", escapeHtml(fmtDate(h.completedDt))));
    }
    if (h.closedAt) parts.push(factRow("Closed On", escapeHtml(fmtDate(h.closedAt))));
    if (h.reasonText) parts.push(factRow("Reason", escapeHtml(h.reasonText)));
    document.getElementById("tvCompletionFacts").innerHTML = parts.join("");
  }

  function renderChildren(children, h) {
    const wrap = document.getElementById("tvChildrenWrap");
    if (!children.length) { wrap.hidden = true; return; }
    wrap.hidden = false;
    document.getElementById("tvChildrenCount").textContent = String(children.length);
    const body = document.getElementById("tvChildrenBody");
    body.innerHTML = children.map(c => `<tr>
        <td><a href="${U("/Practice/Index/task-view")}?taskId=${encodeURIComponent(c.taskId)}">${escapeHtml(c.taskNumber || ("#" + c.taskId))}</a></td>
        <td>${escapeHtml(c.subjectTitle)}</td>
        <td>${escapeHtml(c.assignedToEmployeeName || (c.assignedToEmployeeId ? String(c.assignedToEmployeeId) : ""))}</td>
        <td>${c.isMandatoryChild === false ? "Optional" : "Mandatory"}</td>
        <td>${escapeHtml(fmtDate(c.childTargetDate))}</td>
        <td>${statusPill(c.currentStatusName || c.currentStatusCode)}</td>
      </tr>`).join("");
    const warn = document.getElementById("tvChildrenWarning");
    if (!h.isEligibleForCompletion && !h.closedAt && h.mandatoryChildOpenCount) {
      warn.hidden = false;
      warn.textContent = h.mandatoryChildOpenCount + " mandatory child task(s) still open — the parent cannot be completed until they are done.";
    } else {
      warn.hidden = true;
    }
  }

  function renderGovernanceRequests(reqs) {
    const wrap = document.getElementById("tvGovernanceWrap");
    if (!reqs.length) { wrap.hidden = true; return; }
    wrap.hidden = false;
    const body = document.getElementById("tvGovernanceBody");
    body.innerHTML = reqs.map(q => {
      const asked = q.requestTypeCode === "TASK_PRIORITY_REDUCTION"
        ? escapeHtml((q.priorityOriginal || "") + " → " + (q.priorityRequested || ""))
        : escapeHtml(fmtDate(q.dueAtOriginal) + " → " + fmtDate(q.dueAtRequested));
      return `<tr>
        <td>${escapeHtml(q.requestTypeCode === "TASK_PRIORITY_REDUCTION" ? "Priority reduction" : "SLA extension")}</td>
        <td>${asked}</td>
        <td>${statusPill(q.statusCode)}</td>
        <td>${escapeHtml(q.requestedByName || "")}</td>
        <td>${escapeHtml(q.approvedByName || q.rejectedByName || "")}</td>
      </tr>`;
    }).join("");
  }

  function renderEvidence(files) {
    const wrap = document.getElementById("tvEvidenceWrap");
    document.getElementById("tvEvidenceCount").textContent = files.length ? String(files.length) : "";
    if (!files.length) {
      wrap.hidden = false;
      document.getElementById("tvEvidenceBody").innerHTML = "";
      document.getElementById("tvEvidenceEmpty").hidden = false;
      document.getElementById("tvEvidenceTable").hidden = true;
      return;
    }
    wrap.hidden = false;
    document.getElementById("tvEvidenceEmpty").hidden = true;
    document.getElementById("tvEvidenceTable").hidden = false;
    document.getElementById("tvEvidenceBody").innerHTML = files.map(f => {
      const href = U("/practice/api/tasks/attachments/") + encodeURIComponent(f.taskAttachmentId);
      const kb = Math.max(1, Math.round((f.fileSizeBytes || 0) / 1024));
      return `<tr>
        <td>${escapeHtml(f.fileName)} <span class="tv-hint">(${kb} KB)</span>
          ${f.evidenceDescription ? `<div class="tv-hint">${escapeHtml(f.evidenceDescription)}</div>` : ""}</td>
        <td>${escapeHtml(f.uploadedByName || "—")}</td>
        <td>${escapeHtml(fmtDate(f.uploadedDt))}</td>
        <td><a href="${href}" target="_blank" rel="noopener" class="pm-button">View / Download</a></td>
      </tr>`;
    }).join("");
  }

  function renderCreatedUpdated(h) {
    document.getElementById("tvCreatedUpdatedFacts").innerHTML = [
      factRow("Created By", escapeHtml(h.enteredBy || "")),
      factRow("Created On", escapeHtml(fmtDate(h.enteredDt))),
      factRow("Last Updated By", escapeHtml(h.updatedBy || "")),
      factRow("Last Updated On", escapeHtml(fmtDate(h.updatedDt)))
    ].join("");
  }

  function renderActivity(acts) {
    const list = document.getElementById("tvActivityList");
    if (!acts.length) {
      list.innerHTML = '<p class="pm-hint">No activity recorded yet.</p>';
      return;
    }
    list.innerHTML = "<ul>" + acts.map(a => {
      const change = (a.fromValue || a.toValue)
        ? ` <span class="tv-hint">${escapeHtml(a.fromValue || "")} → ${escapeHtml(a.toValue || "")}</span>` : "";
      return `<li>
          <div class="tv-activity-head">${escapeHtml(a.activityTypeCode)}${change}</div>
          ${a.remark ? `<div class="tv-activity-remark">${escapeHtml(a.remark)}</div>` : ""}
          <div class="tv-hint">${escapeHtml(a.actorDisplayName || "system")} · ${escapeHtml(fmtDate(a.enteredDt))}</div>
        </li>`;
    }).join("") + "</ul>";
  }

  function fmtDate(v) {
    if (!v) return "";
    const d = new Date(v);
    return isNaN(d.getTime()) ? String(v).slice(0, 10) : d.toLocaleDateString();
  }

  function escapeHtml(v) {
    if (v === null || v === undefined) return "";
    return String(v).replace(/[&<>"']/g, c =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }
})();
