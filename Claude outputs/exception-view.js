// =====================================================================
// Exception View  (dedicated full page)
// Loaded by Views/Practice/Partials/exception-view.cshtml.
//
// URL: /Practice/Index/exception-view?exceptionId=NNN
//
// WHAT THIS FILE DOES, AND WHAT IT DELIBERATELY DOES NOT
// --------------------------------------------------------------------
// exception-analysis.cshtml is the Pending-request ANALYSIS WORKFLOW
// (justification, proposed dates, Submit for approval) -- it is not,
// and was never meant to be, a read-only viewer: it has no view mode,
// its own row-menu link is disabled once a request leaves Pending/
// SubmittedForApproval, and it never renders approval info, Control/
// Obligation, or attachments at all. This page is the missing
// counterpart: a genuine read-only full view of an exception request in
// ANY status, reusing exception-analysis's own already-working reads
// rather than re-deriving them:
//   * GET /practice/api/exception-centre/{id}             (the exact
//     read exception-analysis.js's loadDetail() uses)
//   * GET /practice/api/exception-centre/{id}/history      (the exact
//     read exception-analysis.js's loadHistory() uses)
//   * GET /practice/api/exception-centre/{id}/attachments  (already
//     existed on the API; no UI ever called it before this page --
//     everything the write path already captures, listed for the
//     first time)
//   * GET /practice/api/exception-centre/{id}/tasks        (the exact
//     read exception-analysis.js's loadTasks() uses, for Related Tasks)
//   * GET /practice/api/exception-centre/lookups/practices (the exact
//     lookup exception-analysis.js's loadPracticeName() uses to resolve
//     linkedPracticeId to a name)
//
// No new endpoint, no new stored procedure, no duplicate business
// logic -- every read above already existed before this page.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/exception-centre";

  const HISTORY_LABEL = {
    Create: "Created", SubmitForApproval: "Submitted for approval",
    EffectiveDatesChanged: "Effective dates changed", Approve: "Approved",
    Reject: "Rejected", Withdraw: "Withdrawn", AttachmentUpload: "Attachment added"
  };

  const state = { id: null, detail: null, practiceName: null };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    const root = document.getElementById("evRoot");
    if (!root) return;

    state.id = Number(new URLSearchParams(location.search).get("exceptionId")) || 0;
    if (!state.id) {
      unavailable("No exception request was specified.", "Open this page from Exception Centre's row menu.");
      return;
    }

    document.getElementById("evRefreshBtn").addEventListener("click", load);
    await load();
  }

  function unavailable(title, body) {
    document.getElementById("evRoot").hidden = true;
    document.getElementById("evUnavailable").hidden = false;
    document.getElementById("evUnavailableTitle").textContent = title;
    document.getElementById("evUnavailableBody").textContent = body;
  }

  async function load() {
    const res = await getJson(`${base}/${state.id}`);
    if (!res.ok) {
      unavailable("Could not load this exception request.", res.error || "It may have been removed.");
      return;
    }
    state.detail = res.data;
    document.getElementById("evRoot").hidden = false;
    document.getElementById("evUnavailable").hidden = true;

    await loadPracticeName();
    render(state.detail);
    await Promise.all([loadHistory(), loadAttachments(), loadTasks()]);
  }

  async function getJson(path) {
    try {
      const r = await fetch(U(path), { credentials: "same-origin" });
      if (r.ok) return { ok: true, data: await r.json() };
      const b = await r.json().catch(() => ({}));
      return { ok: false, error: b.error || b.title || `HTTP ${r.status}` };
    } catch (err) { return { ok: false, error: err.message || "Network error" }; }
  }

  // Same lookup exception-analysis.js's loadPracticeName() uses: the
  // detail read returns linked_practice_id but not its name, so the
  // name is resolved from the practices list this org already has.
  async function loadPracticeName() {
    const d = state.detail || {};
    state.practiceName = null;
    if (!d.organizationId || !d.linkedPracticeId) return;
    const res = await getJson(`${base}/lookups/practices?organizationId=${d.organizationId}`);
    if (!res.ok) return;
    const hit = (res.data || []).find(r => Number(r.practiceId ?? r.PracticeId) === Number(d.linkedPracticeId));
    if (!hit) return;
    const code = hit.practiceCode ?? hit.PracticeCode;
    const name = hit.practiceName ?? hit.PracticeName;
    state.practiceName = code ? `${code} - ${name}` : name;
  }

  function factRow(label, value) {
    const empty = value === null || value === undefined || value === "";
    return `<div><dt>${escapeHtml(label)}</dt><dd${empty ? ' class="ev-empty"' : ""}>${empty ? "—" : value}</dd></div>`;
  }

  function statusPill(text) {
    return text ? `<span class="pm-badge">${escapeHtml(text)}</span>` : "";
  }

  function render(d) {
    document.getElementById("evHeading").textContent = d.requestTitle || `Exception request #${d.exceptionRequestId}`;
    document.getElementById("evStatusChip").textContent = d.statusCode || "-";
    document.getElementById("evOpenAnalysisLink").href =
      U("/Practice/Index/exception-analysis") + "?exceptionId=" + encodeURIComponent(d.exceptionRequestId);

    document.getElementById("evFacts").innerHTML = [
      factRow("Request Reference", escapeHtml("#" + d.exceptionRequestId)),
      factRow("Exception Type", escapeHtml(d.exceptionTypeName || d.exceptionTypeCode)),
      factRow("Status", statusPill(d.statusCode)),
      // Migration 327. Every other request type is self-evident from the
      // rest of the page (a Related Gap section for GAP_CANDIDATE/
      // SLA_CANDIDATE, a Related Tasks row for the TASK_* types) -- a
      // Custom Exception has neither, so it gets the one explicit marker
      // sir asked for. Does not appear, and nothing else changes, for any
      // other request type.
      ...(d.requestTypeCode === "CUSTOM" ? [factRow("Source", "Custom Exception")] : []),
      factRow("Requested By", escapeHtml(d.requestedByName || "")),
      factRow("Requested On", escapeHtml(fmtDate(d.requestedOn))),
      factRow("Owner", escapeHtml(d.ownerName || ""))
    ].join("");

    renderRelated(d);
    renderReason(d);
    renderValidity(d);
    renderApproval(d);
  }

  function renderRelated(d) {
    const parts = [];
    if (d.customGapId) {
      parts.push(`<div><dt>Related Gap</dt><dd><a href="${escapeHtml(U("/Practice/Index/gap-view") + "?gapId=" + encodeURIComponent(d.customGapId))}" target="_blank" rel="noopener">`
        + `${escapeHtml(d.gapTitle || ("Gap #" + d.customGapId))} <i class="fa-solid fa-arrow-up-right-from-square" aria-hidden="true"></i></a></dd></div>`);
    }
    if (d.linkedPracticeId) {
      parts.push(factRow("Related Practice", escapeHtml(state.practiceName || ("#" + d.linkedPracticeId))));
    }
    if (d.linkedRequirementRef) {
      parts.push(factRow("Related Obligation / Requirement", escapeHtml(d.linkedRequirementRef)));
    }
    if (d.compensatingControl) {
      parts.push(factRow("Compensating Control", escapeHtml(d.compensatingControl)));
    }
    const wrap = document.getElementById("evRelatedWrap");
    if (!parts.length) { wrap.hidden = true; return; }
    wrap.hidden = false;
    document.getElementById("evRelatedFacts").innerHTML = parts.join("");
  }

  function renderReason(d) {
    const wrap = document.getElementById("evReasonWrap");
    if (!d.requestReason && !d.justification && !d.riskImpact) { wrap.hidden = true; return; }
    wrap.hidden = false;
    const parts = [];
    if (d.requestReason) parts.push(`<div><dt>Reason / Justification (requester)</dt><dd class="ev-block">${escapeHtml(d.requestReason)}</dd></div>`);
    if (d.justification) parts.push(`<div><dt>Justification (analyst)</dt><dd class="ev-block">${escapeHtml(d.justification)}</dd></div>`);
    if (d.riskImpact)    parts.push(`<div><dt>Risk / Impact</dt><dd class="ev-block">${escapeHtml(d.riskImpact)}</dd></div>`);
    document.getElementById("evReasonFacts").innerHTML = parts.join("");
  }

  function renderValidity(d) {
    const wrap = document.getElementById("evValidityWrap");
    const hasApproved = d.effectiveFrom || d.effectiveUntil;
    const hasProposed = d.proposedEffectiveFrom || d.proposedEffectiveUntil;
    if (!hasApproved && !hasProposed) { wrap.hidden = true; return; }
    wrap.hidden = false;
    const parts = [];
    if (hasApproved) {
      parts.push(factRow("Valid From", escapeHtml(fmtDate(d.effectiveFrom))));
      parts.push(factRow("Valid Until", escapeHtml(fmtDate(d.effectiveUntil))));
    } else {
      parts.push(factRow("Proposed Valid From", escapeHtml(fmtDate(d.proposedEffectiveFrom))));
      parts.push(factRow("Proposed Valid Until", escapeHtml(fmtDate(d.proposedEffectiveUntil))));
    }
    if (d.reviewFrequencyName) parts.push(factRow("Review Frequency", escapeHtml(d.reviewFrequencyName)));
    document.getElementById("evValidityFacts").innerHTML = parts.join("");
  }

  function renderApproval(d) {
    const wrap = document.getElementById("evApprovalWrap");
    const isDecided = d.statusCode === "Approved" || d.statusCode === "Rejected";
    if (!isDecided) { wrap.hidden = true; return; }
    wrap.hidden = false;
    const parts = [];
    if (d.statusCode === "Approved") {
      parts.push(factRow("Approved By", escapeHtml(d.approvedByName || "")));
      parts.push(factRow("Approved On", escapeHtml(fmtDate(d.approvedOn))));
      if (d.approvalNote) parts.push(`<div><dt>Approval Note</dt><dd class="ev-block">${escapeHtml(d.approvalNote)}</dd></div>`);
    } else {
      parts.push(factRow("Rejected By", escapeHtml(d.rejectedByName || "")));
      parts.push(factRow("Rejected On", escapeHtml(fmtDate(d.rejectedOn))));
      if (d.rejectionReason) parts.push(`<div><dt>Rejection Reason</dt><dd class="ev-block">${escapeHtml(d.rejectionReason)}</dd></div>`);
    }
    document.getElementById("evApprovalFacts").innerHTML = parts.join("");
  }

  async function loadHistory() {
    const res = await getJson(`${base}/${state.id}/history`);
    const body = document.getElementById("evHistoryBody");
    const rows = res.ok ? (res.data || []) : [];
    if (!rows.length) { body.innerHTML = '<tr><td colspan="4" class="pm-empty">No history recorded.</td></tr>'; return; }
    body.innerHTML = rows.map(h => {
      const label = HISTORY_LABEL[h.actionCode] || h.actionCode || "";
      return `<tr>
        <td>${escapeHtml(fmtDateTime(h.enteredOn))}</td>
        <td>${statusPill(label)}</td>
        <td>${escapeHtml(h.actorName || "system")}</td>
        <td>${escapeHtml(h.remark || "")}</td>
      </tr>`;
    }).join("");
  }

  async function loadAttachments() {
    const res = await getJson(`${base}/${state.id}/attachments`);
    const wrap = document.getElementById("evEvidenceWrap");
    const rows = res.ok ? (res.data || []) : [];
    document.getElementById("evEvidenceCount").textContent = rows.length ? String(rows.length) : "";
    if (!rows.length) {
      document.getElementById("evEvidenceEmpty").hidden = false;
      document.getElementById("evEvidenceTable").hidden = true;
      return;
    }
    document.getElementById("evEvidenceEmpty").hidden = true;
    document.getElementById("evEvidenceTable").hidden = false;
    document.getElementById("evEvidenceBody").innerHTML = rows.map(f => {
      const href = U(`${base}/attachments/`) + encodeURIComponent(f.attachmentId);
      const kb = Math.max(1, Math.round((f.fileSizeBytes || 0) / 1024));
      const method = f.collectionMethodName || f.collectionMethodCode || "";
      return `<tr>
        <td>${f.fileName ? escapeHtml(f.fileName) + ` <span class="ev-hint">(${kb} KB)</span>` : `<span class="ev-hint">${escapeHtml(method)} evidence</span>`}
          ${f.evidenceLocation ? `<div class="ev-hint">${escapeHtml(f.evidenceLocation)}${f.evidenceLocator ? " / " + escapeHtml(f.evidenceLocator) : ""}</div>` : ""}</td>
        <td>${escapeHtml(f.evidenceTypeName || "")}</td>
        <td>${escapeHtml(f.uploadedByName || "—")}</td>
        <td>${escapeHtml(fmtDate(f.uploadedOn))}</td>
        <td>${f.fileName ? `<a href="${href}" target="_blank" rel="noopener" class="pm-button">View / Download</a>` : ""}</td>
      </tr>`;
    }).join("");
  }

  async function loadTasks() {
    const res = await getJson(`${base}/${state.id}/tasks`);
    const wrap = document.getElementById("evTasksWrap");
    const rows = res.ok ? (res.data || []) : [];
    if (!rows.length) { wrap.hidden = true; return; }
    wrap.hidden = false;
    document.getElementById("evTasksBody").innerHTML = rows.map(t => `<tr>
        <td><a href="${U("/Practice/Index/task-view")}?taskId=${encodeURIComponent(t.taskId)}" target="_blank" rel="noopener">${escapeHtml(t.taskNumber || ("#" + t.taskId))}</a></td>
        <td>${escapeHtml(t.taskTitle || "")}</td>
        <td>${statusPill(t.taskStatusName || t.taskStatusCode)}</td>
        <td>${escapeHtml(t.assignedToName || "")}</td>
        <td>${escapeHtml(fmtDate(t.dueAt))}</td>
      </tr>`).join("");
  }

  function fmtDate(v) {
    if (!v) return "";
    const d = new Date(v);
    return isNaN(d.getTime()) ? String(v).slice(0, 10) : d.toLocaleDateString();
  }
  function fmtDateTime(v) {
    if (!v) return "";
    const d = new Date(v);
    return isNaN(d.getTime()) ? String(v) : d.toLocaleString();
  }
  function escapeHtml(v) {
    if (v === null || v === undefined) return "";
    return String(v).replace(/[&<>"']/g, c =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }
})();
