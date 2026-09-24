// =====================================================================
// window.gracExceptionActions -- THE Exception Centre row-menu actions
// (Approve / Reject / SLA quick-approve) plus the menu-item list they
// come from.
//
// Extracted from Views/Practice/Partials/exception-centre.cshtml (change
// request: Exception View's own "Actions" menu must reuse these
// verbatim -- same forms, same API calls, same validation, same
// permission / applicability rules, same success/error handling --
// rather than a second copy for Exception View. Exception Centre itself
// was rewired to call this module too, so there is exactly one
// implementation of each action, used from both screens. Mirrors the
// Task Centre / Task View precedent (Shared/task-actions.js, change
// request 2026-09-22) for exactly the same reason.
//
// Pairs with Views/Practice/Partials/_exception-action-dialogs.cshtml,
// which carries the Approve / Reject dialog markup this module drives
// (moved out of exception-centre.cshtml, unchanged, by this same
// change). Include that partial once on a page, load this script, call
// window.gracExceptionActions.init({...}) once, and the page can then:
//
//   * build the same 3-dot / Actions menu item list Exception Centre
//     uses, via buildMenu(fields, handlers) -- pass only the handlers
//     the host page wants wired (a handler that is omitted is not
//     offered at all, so e.g. Exception View simply never passes onView);
//   * open the shared dialogs directly: openApprove, openReject,
//     approveSlaQuick.
//
// PERMISSION / APPLICABILITY
// ---------------------------
// buildMenu() reproduces exactly the applicable/disabled rules
// exception-centre.js's own row-menu click handler used to hardcode, so
// a host page that calls it gets identical status-based gating for free
// -- there is no separate "can this user decide this request" role
// check in Exception Centre beyond these; the item list itself IS the
// permission surface, same as Task Centre's and Gap Centre's.
//
// WHAT IS DELIBERATELY *NOT* HERE
// --------------------------------
// The small, PURELY PRESENTATIONAL helpers this module needs
// (escapeHtml, show/hide, apiGet/apiPost, isoDate) are duplicated from
// exception-centre.js's own copies rather than exported from there,
// exactly for the reason Shared/task-actions.js's own header comment
// gives: exception-centre.js's OTHER screens (the grid, Add Custom
// Exception) are unrelated to this change and were left untouched, and a
// plain <script src> has no way to reach into another script's closure
// regardless. None of these carry any business rule; they only format a
// value or toggle a hidden attribute that already came from, or is
// about to go to, the API.
//
// "Open source gap" and the "Analysis" navigation ARE reproduced here
// (unlike Task's Add Child Task, which stayed local because it already
// had its own shared component) -- they are plain client-side
// navigations with a status/id gate, not forms, so there was nothing
// gained by leaving two copies of that gate in two files.
// =====================================================================
(function () {
  "use strict";

  var U    = function (p) { return String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p; };
  var base = "/practice/api/exception-centre";
  var $    = function (id) { return document.getElementById(id); };

  function show(id) { var e = $(id); if (e) e.hidden = false; }
  function hide(id) { var e = $(id); if (e) e.hidden = true; }
  function escapeHtml(s) {
    if (s === null || s === undefined) return "";
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function isoDate(v) {
    if (!v) return "";
    var d = new Date(v);
    return isNaN(d.getTime()) ? String(v).slice(0, 10) : d.toISOString().slice(0, 10);
  }

  async function apiGet(path) {
    var url = U(base + (path.charAt(0) === "/" ? path : "/" + path));
    try {
      var r = await fetch(url, { credentials: "same-origin" });
      if (r.status === 404) return null;
      if (!r.ok) { console.warn("[grac-exception-actions] GET", url, r.status); return null; }
      return await r.json();
    } catch (err) { console.error("[grac-exception-actions] GET failed", url, err); return null; }
  }
  async function apiPost(path, body) {
    var url = U(base + (path.charAt(0) === "/" ? path : "/" + path));
    try {
      var r = await fetch(url, {
        method: "POST", credentials: "same-origin",
        headers: { "Content-Type": "application/json" }, body: JSON.stringify(body)
      });
      var data = await r.json().catch(function () { return {}; });
      if (!r.ok) return { success: false, error: data.error || ("HTTP " + r.status) };
      return Object.assign({ success: data.success !== false }, data);
    } catch (err) { return { success: false, error: err.message }; }
  }

  // ---- menu item list -------------------------------------------------
  // Mirrors exception-centre.js's own wireRowMenu() click handler
  // exactly (migration 257's lifecycle rules):
  //   Pending               -> Analysis        (no decision yet)
  //   SubmittedForApproval  -> Approve          (the decision)
  // Approve is offered only while the request is actually decidable; a
  // greyed-out row on every other status was noise. Reject is not a menu
  // item at all -- it lives on the Approve form (excApproveRejectBtn),
  // a decision the approver makes with the request in front of them.
  // The task-side types (SLA / priority requests raised from Task
  // Centre) have no analysis stage at all -- they are decided straight
  // from Pending, which is what the procedures enforce too.
  //
  // fields: { exceptionId, requestTypeCode, statusCode, customGapId }
  // handlers: { onView, onAnalysis, onApprove, onOpenSourceGap }
  // A handler that is omitted means that item is not offered at all --
  // e.g. Exception View has no use for "View" (the page already IS the
  // view), so it simply does not pass onView.
  function buildMenu(fields, handlers) {
    fields = fields || {};
    handlers = handlers || {};
    var items = [];
    var id = fields.exceptionId;
    var validId = Number.isFinite(id) && id > 0;
    var isTaskType = (fields.requestTypeCode === "SLA_CANDIDATE"
                    || fields.requestTypeCode === "TASK_SLA_EXTENSION"
                    || fields.requestTypeCode === "TASK_PRIORITY_REDUCTION");

    if (handlers.onView) {
      items.push({
        icon: "fa-eye", label: "View",
        disabled: !validId,
        disabledReason: "This row arrived without an exception request id, so there is nothing to view. "
          + "Reload the list; if it persists the request id is missing from the list response.",
        action: handlers.onView
      });
    }

    if (!isTaskType && handlers.onAnalysis) {
      var okStatus = (fields.statusCode === "Pending" || fields.statusCode === "SubmittedForApproval");
      items.push({
        icon: "fa-magnifying-glass", label: "Analysis",
        disabled: !validId || !okStatus,
        disabledReason: !validId
          ? "This row arrived without an exception request id, so there is nothing to analyse. "
            + "Reload the list; if it persists the request id is missing from the list response."
          : "Analysis applies to a Pending request (current: " + fields.statusCode + ").",
        action: handlers.onAnalysis
      });
    }

    var canDecide = isTaskType ? (fields.statusCode === "Pending") : (fields.statusCode === "SubmittedForApproval");
    if (canDecide && handlers.onApprove) {
      items.push({ icon: "fa-check", label: "Approve", action: handlers.onApprove });
    }

    if (handlers.onOpenSourceGap) {
      items.push({
        icon: "fa-route", label: "Open source gap",
        disabled: !fields.customGapId,
        disabledReason: "This request has no linked gap.",
        action: handlers.onOpenSourceGap
      });
    }

    return items;
  }

  // ---- module state (the dialogs this drives) --------------------------
  var cfg = { onChanged: function () {} };
  var wired = false;
  var evidenceTypesCache  = [];
  var frequenciesCache    = [];

  function changed() {
    try { cfg.onChanged && cfg.onChanged(); } catch (err) { console.error("[grac-exception-actions] onChanged handler failed", err); }
  }

  // ---- shared helpers (approver's read of the case) --------------------
  function metaOf(r) {
    var row = function (k, v) { return v ? ("<dt>" + escapeHtml(k) + "</dt><dd>" + escapeHtml(v) + "</dd>") : ""; };
    return row("Request", r.requestTitle)
         + row("Gap", r.gapTitle || (r.customGapId ? ("#" + r.customGapId) : ""))
         + row("Reason", r.requestReason)
         + row("Exception type", r.exceptionTypeName || r.exceptionTypeCode)
         + row("Exception owner", r.ownerName)
         + row("Justification", r.justification)
         + row("Risk / Impact", r.riskImpact)
         + "<dt>Requested</dt><dd>" + window.gracFormatDisplayDate(r.requestedOn) + " by " + escapeHtml(r.requestedByName || "system") + "</dd>";
  }

  function renderApproveMethodFields() {
    var m = $("excApproveMethod").value;
    $("excApproveFileWrap").hidden     = (m !== "Manual");
    $("excApproveLocationWrap").hidden = (m !== "Automated");
    $("excApproveLocatorWrap").hidden  = (m !== "Automated");
    $("excApproveEvidenceTypeWrap").hidden = (m === "");
  }

  async function loadFrequencies() {
    // grac_practice.frequency_master, via the same
    // sp_risk_review_frequency_list (293) Risk Centre's Acceptance screen
    // already reads -- a shared master table, not a Risk-owned list, so
    // this fetches it the same way Approve already fetches evidence types
    // rather than embedding a second, hard-coded set of options.
    if (!frequenciesCache.length) {
      try {
        var r = await fetch(U(base + "/lookups/review-frequencies"), { credentials: "same-origin" });
        frequenciesCache = r.ok ? ((await r.json()) || []) : [];
      } catch (_e) { frequenciesCache = []; }
    }
    var sel = $("excApproveReviewFrequency");
    if (!sel) return;
    sel.innerHTML = '<option value="">-- select --</option>';
    frequenciesCache.forEach(function (f) {
      var o = document.createElement("option");
      o.value = f.frequencyId; o.textContent = f.frequencyName;
      sel.appendChild(o);
    });
  }

  async function loadEvidenceTypes() {
    if (!evidenceTypesCache.length) {
      try {
        var r = await fetch(U(base + "/lookups/evidence-types"), { credentials: "same-origin" });
        evidenceTypesCache = r.ok ? ((await r.json()) || []) : [];
      } catch (_e) { evidenceTypesCache = []; }
    }
    var sel = $("excApproveEvidenceType");
    if (!sel) return;
    sel.innerHTML = '<option value="">-- select --</option>';
    evidenceTypesCache.forEach(function (t) {
      var o = document.createElement("option");
      o.value = t.evidenceTypeCode; o.textContent = t.evidenceTypeName;
      sel.appendChild(o);
    });
  }

  var HISTORY_LABEL = {
    Create:                "Created",
    SubmitForApproval:     "Submitted for approval",
    EffectiveDatesChanged: "Effective dates changed",
    Approve:               "Approved",
    Reject:                "Rejected",
    Withdraw:               "Withdrawn",
    AttachmentUpload:      "Attachment added"
  };

  async function loadApproveHistory(id) {
    var body = $("excApproveHistoryBody");
    if (!body) return;
    var rows = (await apiGet("/" + id + "/history")) || [];
    if (!rows.length) {
      body.innerHTML = '<tr><td colspan="4" class="pm-empty-row">Nothing recorded yet.</td></tr>';
      return;
    }
    body.innerHTML = rows.map(function (h) {
      var label = HISTORY_LABEL[h.actionCode] || h.actionCode || "";
      var cls = h.actionCode === "EffectiveDatesChanged" ? " exc-pending" : "";
      return "<tr>"
           + "<td>" + escapeHtml(window.gracFormatDisplayDate(h.enteredOn)) + "</td>"
           + '<td><span class="exc-status-chip' + cls + '">' + escapeHtml(label) + "</span></td>"
           + "<td>" + escapeHtml(h.actorName || "system") + "</td>"
           + "<td>" + escapeHtml(h.remark || "") + "</td>"
           + "</tr>";
    }).join("");
  }

  // ==== Approve ==========================================================
  async function openApprove(id) {
    var req = await apiGet("/" + id);
    if (!req) { alert("Request not found."); return; }
    $("excApproveId").value = id;
    var propFrom  = isoDate(req.proposedEffectiveFrom);
    var propUntil = isoDate(req.proposedEffectiveUntil);
    $("excApproveEffectiveFrom").value  = propFrom;
    $("excApproveEffectiveUntil").value = propUntil;

    var proposedHint = $("excApproveProposed");
    if (proposedHint) {
      if (propFrom || propUntil) {
        proposedHint.textContent =
          "Analyst proposed " + (propFrom || "(not set)") + " to " + (propUntil || "(not set)") + "."
          + " Change these only if the window needs to differ — the change is recorded.";
        proposedHint.hidden = false;
      } else {
        proposedHint.hidden = true;
      }
    }
    $("excApproveNote").value = "";
    $("excApproveFile").value = "";
    $("excApproveMethod").value = "";
    $("excApproveLocation").value = "";
    $("excApproveLocator").value = "";
    $("excApproveMessage").textContent = "";
    $("excApproveMeta").innerHTML = metaOf(req);

    await Promise.all([loadEvidenceTypes(), loadFrequencies()]);
    $("excApproveEvidenceType").value = "";
    $("excApproveReviewFrequency").value = "";

    renderApproveMethodFields();
    show("excApproveModal");
    loadApproveHistory(id);
  }

  async function onApproveSubmit(ev) {
    ev.preventDefault();
    var msg = $("excApproveMessage");
    msg.textContent = "";
    var id = Number($("excApproveId").value);
    var effectiveUntil = $("excApproveEffectiveUntil").value;
    var note           = $("excApproveNote").value.trim();
    if (!effectiveUntil || !note) { msg.textContent = "Effective until date and approval note are required."; return; }

    var efFrom     = $("excApproveEffectiveFrom").value || null;
    var freqIdVal  = Number($("excApproveReviewFrequency").value) || null;
    var reviewFreq = (freqIdVal && freqIdVal > 0) ? freqIdVal : null;

    var result = await apiPost("/" + id + "/approve", {
      effectiveFrom:     efFrom,
      effectiveUntil:    effectiveUntil,
      approvalNote:      note,
      reviewFrequencyId: reviewFreq
    });
    if (!result || result.success === false) {
      var err = (result && result.error) || "Approve failed.";
      msg.textContent = err; alert(err);
      return;
    }

    var method = $("excApproveMethod").value;
    if (method) {
      var fd = new FormData();
      fd.append("CollectionMethodCode", method);
      var evType = $("excApproveEvidenceType").value;
      if (evType) fd.append("EvidenceTypeCode", evType);

      if (method === "Manual") {
        var file = $("excApproveFile").files && $("excApproveFile").files[0];
        if (!file) { alert("Approved, but Manual attachment needs a file. Skipping upload."); }
        else       { fd.append("File", file, file.name); }
      } else if (method === "Automated") {
        var loc = $("excApproveLocation").value.trim();
        var lct = $("excApproveLocator").value.trim();
        if (!loc || !lct) {
          alert("Approved, but Automated attachment needs Location and Locator. Skipping upload.");
        } else {
          fd.append("EvidenceLocation", loc);
          fd.append("EvidenceLocator",  lct);
        }
      }
      if ((method === "Manual" && fd.has("File")) ||
          (method === "Automated" && fd.has("EvidenceLocation"))) {
        try {
          var r = await fetch(U(base + "/" + id + "/attachments"), {
            method: "POST", body: fd, credentials: "same-origin"
          });
          var b = await r.json().catch(function () { return {}; });
          if (!r.ok || b.success === false) {
            alert("Approved, but attachment upload failed: " + (b.error || ("HTTP " + r.status)));
          }
        } catch (err) {
          alert("Approved, but attachment upload failed: " + err.message);
        }
      }
    }
    hide("excApproveModal");
    alert("Exception approved.");
    changed();
  }

  // ==== Reject (reached from the Approve form's own Reject button) =====
  async function openReject(id) {
    var req = await apiGet("/" + id);
    if (!req) { alert("Request not found."); return; }
    $("excRejectId").value = id;
    $("excRejectReason").value = "";
    $("excRejectMessage").textContent = "";
    $("excRejectMeta").innerHTML = metaOf(req);
    show("excRejectModal");
  }

  async function onRejectSubmit(ev) {
    ev.preventDefault();
    var msg = $("excRejectMessage");
    msg.textContent = "";
    var id = Number($("excRejectId").value);
    var reason = $("excRejectReason").value.trim();
    if (!reason) { msg.textContent = "Rejection reason is required."; return; }
    var result = await apiPost("/" + id + "/reject", { rejectionReason: reason });
    if (!result || result.success === false) {
      var err = (result && result.error) || "Reject failed.";
      msg.textContent = err; alert(err);
      return;
    }
    hide("excRejectModal");
    alert("Exception rejected.");
    changed();
  }

  // ==== SLA quick-approve (task-side types, no dialog) ==================
  async function approveSlaQuick(id) {
    var confirmFn = window.gracConfirm || function (msg) { return Promise.resolve(confirm(msg)); };
    var ok = await confirmFn({
      type:        "confirm",
      title:       "Approve SLA override",
      message:     "Approve this SLA override and apply the requested days to the gap?",
      confirmText: "Approve",
      cancelText:  "Cancel"
    });
    if (!ok) return;
    var result = await apiPost("/" + id + "/approve-sla", {
      approvedByEmployeeId: Number(window.pmEmployeeId || 0) || null,
      callerDisplayName:    window.pmEmail || "system"
    });
    if (!result.success) {
      (window.gracAlert || alert)({ type: "error", title: "Approve failed", message: result.error || "Unknown error." });
      return;
    }
    changed();
  }

  // ==== wiring / init ==================================================
  function wire() {
    if (wired) return;
    wired = true;

    var aForm = $("excApproveForm");
    var rForm = $("excRejectForm");
    if (aForm) aForm.addEventListener("submit", onApproveSubmit);
    if (rForm) rForm.addEventListener("submit", onRejectSubmit);
    document.querySelectorAll("[data-close-exc-approve]").forEach(function (el) {
      el.addEventListener("click", function () { hide("excApproveModal"); });
    });
    document.querySelectorAll("[data-close-exc-reject]").forEach(function (el) {
      el.addEventListener("click", function () { hide("excRejectModal"); });
    });

    // Reject starts from the Approve form, not the row menu -- it hands
    // off to the Reject modal so the mandatory reason is still captured
    // in one place.
    var rejectBtn = $("excApproveRejectBtn");
    if (rejectBtn) rejectBtn.addEventListener("click", function () {
      var id = Number($("excApproveId").value);
      if (!id) return;
      hide("excApproveModal");
      openReject(id);
    });

    var methodSel = $("excApproveMethod");
    if (methodSel) methodSel.addEventListener("change", renderApproveMethodFields);
  }

  function init(options) {
    cfg = Object.assign({ onChanged: function () {} }, options || {});
    wire();
  }

  window.gracExceptionActions = {
    init: init,
    buildMenu: buildMenu,
    openApprove: openApprove,
    openReject: openReject,
    approveSlaQuick: approveSlaQuick
  };
})();
