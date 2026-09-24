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
//
// ACTIONS MENU (change request, 2026-09-22): the "Actions" button wires
// to window.gracExceptionActions (Shared/exception-actions.js) exactly
// the way gap-view.js wires to window.gracGapActions -- see that file's
// own header comment for the general shape. buildMenu() is called with
// the fields this page already has on state.detail (no extra fetch: the
// detail read already includes requestTypeCode, statusCode and
// customGapId), and with onAnalysis/onApprove/onOpenSourceGap but no
// onView, since this page already is the "View" destination.
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
  let actionsMenuEl = null;

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

    if (window.gracExceptionActions) window.gracExceptionActions.init({ onChanged: load });

    const actionsBtn = document.getElementById("evActionsBtn");
    if (actionsBtn) actionsBtn.addEventListener("click", toggleActionsMenu);
    document.addEventListener("click", e => {
      if (!actionsMenuEl) return;
      if (e.target.closest(".pm-action-menu")) return;
      if (e.target.closest("#evActionsBtn")) return;
      closeActionsMenu();
    });
    document.addEventListener("keydown", e => { if (e.key === "Escape") closeActionsMenu(); });
    window.addEventListener("resize", closeActionsMenu);
    window.addEventListener("scroll", closeActionsMenu, true);

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
    if (typeof window.gracFormatDateOnly === "function") { var _g = window.gracFormatDateOnly(v); if (_g && _g !== v) return _g; }
    const d = new Date(v);
    return isNaN(d.getTime()) ? String(v).slice(0, 10) : d.toLocaleDateString();
  }
  function fmtDateTime(v) {
    if (!v) return "";
    if (typeof window.gracFormatDisplayDate === "function") { var _g = window.gracFormatDisplayDate(v); if (_g && _g !== v) return _g; }
    const d = new Date(v);
    return isNaN(d.getTime()) ? String(v) : d.toLocaleString();
  }
  function escapeHtml(v) {
    if (v === null || v === undefined) return "";
    return String(v).replace(/[&<>"']/g, c =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  // ===================================================================
  // Actions menu -- one button, not a per-row trigger, so this popover
  // is a near-copy of Gap View's own version of the same thing
  // (gap-view.js), which is itself a near-copy of Task View's
  // (task-view.js). Same .pm-action-menu / .pm-button CSS every other
  // action menu in the product already uses (wwwroot/css/practice-
  // management.css); only the item LIST and the actions themselves come
  // from the shared window.gracExceptionActions module (see that file's
  // header comment for why).
  // ===================================================================
  function closeActionsMenu() {
    if (actionsMenuEl) { actionsMenuEl.remove(); actionsMenuEl = null; }
    const btn = document.getElementById("evActionsBtn");
    if (btn) btn.setAttribute("aria-expanded", "false");
  }

  function positionActionsMenu(trigger) {
    if (!actionsMenuEl) return;
    const r = trigger.getBoundingClientRect();
    const mr = actionsMenuEl.getBoundingClientRect();
    const gap = 6;
    let top = r.bottom + gap, left = r.left;
    if (top + mr.height > window.innerHeight - 8) top = Math.max(8, r.top - mr.height - gap);
    if (left + mr.width > window.innerWidth - 8) left = window.innerWidth - mr.width - 8;
    if (left < 8) left = 8;
    actionsMenuEl.style.top = top + "px";
    actionsMenuEl.style.left = left + "px";
  }

  function toggleActionsMenu() {
    if (actionsMenuEl) { closeActionsMenu(); return; }
    openActionsMenu();
  }

  function renderActionsMenuItems(items) {
    if (!actionsMenuEl) return;
    actionsMenuEl.innerHTML = "";
    const shown = items.filter(it => it && it.applicable !== false);

    if (!shown.length) {
      const p = document.createElement("div");
      p.style.cssText = "padding:8px 12px; font-size:12px; color:#94a3b8; white-space:nowrap;";
      p.textContent = "No actions available";
      actionsMenuEl.appendChild(p);
    }

    shown.forEach(it => {
      const b = document.createElement("button");
      b.type = "button";
      b.setAttribute("role", "menuitem");
      b.innerHTML = `<i class="fa-solid ${escapeHtml(it.icon)}" aria-hidden="true"></i> ${escapeHtml(it.label)}`;
      if (it.disabled) {
        b.disabled = true;
        b.title = it.disabledReason || "";
      }
      b.addEventListener("click", e => {
        e.preventDefault();
        e.stopPropagation();
        closeActionsMenu();
        try { it.action(); } catch (err) { console.error("[exception-view] action failed", err); }
      });
      actionsMenuEl.appendChild(b);
    });
  }

  function openActionsMenu() {
    const btn = document.getElementById("evActionsBtn");
    const d = state.detail;
    if (!btn || !d) return;
    if (!window.gracExceptionActions) {
      console.error("[exception-view] Shared/exception-actions.js did not load -- Actions menu unavailable.");
      return;
    }

    actionsMenuEl = document.createElement("div");
    actionsMenuEl.className = "pm-action-menu";
    actionsMenuEl.setAttribute("role", "menu");
    document.body.appendChild(actionsMenuEl);
    btn.setAttribute("aria-expanded", "true");

    // Same fields Exception Centre's own row menu reads off its grid row
    // (row.requestTypeCode, row.statusCode, row.customGapId) -- here
    // read straight off the detail this page already fetched, so
    // applicability/permission gating is byte-for-byte the same rule,
    // just a different source for the same values. No onView: this page
    // already IS the read-only view Exception Centre's "View" item would
    // navigate to, so it is left unoffered exactly like Gap View and
    // Task View do for themselves.
    const isTaskType = (d.requestTypeCode === "SLA_CANDIDATE"
      || d.requestTypeCode === "TASK_SLA_EXTENSION"
      || d.requestTypeCode === "TASK_PRIORITY_REDUCTION");

    const items = window.gracExceptionActions.buildMenu(
      { exceptionId: state.id, requestTypeCode: d.requestTypeCode, statusCode: d.statusCode, customGapId: d.customGapId },
      {
        onAnalysis: () => {
          window.location.href = U("/Practice/Index/exception-analysis") + "?exceptionId=" + encodeURIComponent(state.id);
        },
        onApprove: isTaskType
          ? () => window.gracExceptionActions.approveSlaQuick(state.id)
          : () => window.gracExceptionActions.openApprove(state.id),
        onOpenSourceGap: () => {
          window.location.href = U("/Practice/Index/gap-detail")
            + "?gapId=" + encodeURIComponent(d.customGapId)
            + "&orgId=" + encodeURIComponent(d.organizationId || "");
        }
      }
    );

    renderActionsMenuItems(items);
    positionActionsMenu(btn);
  }
})();
