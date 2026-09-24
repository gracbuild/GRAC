// =====================================================================
// Exception Analysis (migration 257)
//
// The stage between a raised exception request and the approval
// decision. Opened from Exception Centre's 3-dot menu with
// ?exceptionId=, the way gap-detail is opened from Gap Centre.
//
// Three things happen here:
//   1. the request-level case is written (it used to be asked of the
//      approver, inside the Approve modal, which was backwards)
//   2. remediation tasks are attached -- raised new, or mapped from the
//      exception's practice
//   3. Submit for approval, which is the ONLY route to a state where
//      Approve and Reject are offered
//
// Linked practice is displayed, never selected: it belongs to the
// request. Linked requirement ref, approval note and compensating
// control are not here at all -- the note lives on the approver's form.
// =====================================================================
(function () {
  "use strict";

  // Resolved lazily: window.pmPathBase is set by a layout script that
  // runs after this file is parsed.
  const U = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/exception-centre";

  const state = {
    id: null,
    detail: null,
    tasks: [],
    employees: [],
    // sp_exception_request_get returns linked_practice_id but not its
    // name. Rather than re-emit that forty-column procedure just to add a
    // join -- the kind of rebuild that dropped half of migration 174's
    // work in 249 -- the name is resolved from the practices lookup this
    // module already exposes.
    practiceName: null,
    // The linked set as the server last reported it. Save diffs the
    // checkbox grid against this rather than re-sending everything.
    mapOriginal: new Set()
  };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    const root = document.getElementById("exaRoot");
    if (!root) return;

    state.id = readIdFromQuery();
    if (!state.id) {
      // The URL is quoted back deliberately. "No exception request was
      // specified" alone is true and useless: it does not say whether
      // the menu sent nothing, sent NaN because a row had no id, or sent
      // a key this page does not read -- three different bugs with three
      // different fixes, and no way to tell them apart from the screen.
      unavailable("No exception request was specified.",
                  "Open this page from Exception Centre's Actions menu. "
                  + "The page was opened with " + describeLocation()
                  + " -- it expects ?exceptionId=<number>.");
      return;
    }

    bindEvents();

    const ok = await loadDetail();
    if (!ok) return;

    root.hidden = false;
    // Practice name first, then re-render the header with it in place.
    await Promise.all([loadExceptionTypes(), loadEmployees(), loadPracticeName()]);
    renderHeader();
    fillAnalysisForm();
    await loadTasks();
    await loadHistory();
  }

  // EVERY NAME THIS PAGE HAS EVER BEEN OPENED WITH, plus the path.
  //
  // Exception Centre's Actions menu sends ?exceptionId=, and that is the
  // supported way in. The rest are accepted because the page reporting
  // "no exception request was specified" while the id is sitting in the
  // address bar under a different key is the worst possible failure: it
  // is indistinguishable from a broken menu, and it sent two people
  // hunting the menu code.
  //
  // Number(null) is 0 and Number("undefined") is NaN, so a caller that
  // interpolated an undefined id lands here as a falsy/NaN value rather
  // than a plausible one -- which is why the > 0 test is on the number
  // and not on the string.
  function readIdFromQuery() {
    try {
      const q = new URLSearchParams(window.location.search);
      const raw = q.get("exceptionId")
               || q.get("exceptionRequestId")
               || q.get("requestId")
               || q.get("id");
      let v = Number(raw);
      if (Number.isFinite(v) && v > 0) return v;

      // Last resort: /Practice/Index/exception-analysis/123 -- a shape
      // nothing builds today, but a link someone hand-writes or a route
      // added later would, and falling back costs one split.
      const tail = String(window.location.pathname || "").split("/").filter(Boolean).pop();
      v = Number(tail);
      return Number.isFinite(v) && v > 0 ? v : null;
    } catch (_) { return null; }
  }

  // What the page ACTUALLY received, for the message below. Without this
  // the operator can only report "it says no exception request", which
  // is exactly as much as we already knew.
  function describeLocation() {
    try {
      const s = String(window.location.search || "");
      return s && s !== "?" ? s : "(no query string at all)";
    } catch (_) { return "(unreadable)"; }
  }

  function unavailable(title, body) {
    const box = document.getElementById("exaUnavailable");
    if (!box) return;
    box.hidden = false;
    document.getElementById("exaUnavailableTitle").textContent = title;
    document.getElementById("exaUnavailableBody").textContent  = body;
  }

  function bindEvents() {
    document.getElementById("exaSaveBtn").addEventListener("click", onSaveAnalysis);
    document.getElementById("exaSubmitBtn").addEventListener("click", onSubmitForApproval);
    document.getElementById("exaNewTaskBtn").addEventListener("click", openNewTaskModal);
    document.getElementById("exaMapTaskBtn").addEventListener("click", openMapModal);

    document.querySelectorAll("[data-close-exa-map]").forEach(el =>
      el.addEventListener("click", () => hide("exaMapModal")));
    document.querySelectorAll("[data-close-exa-new]").forEach(el =>
      el.addEventListener("click", () => hide("exaNewTaskModal")));

    document.getElementById("exaMapRefresh").addEventListener("click", loadTaskCandidates);
    document.getElementById("exaMapSearch").addEventListener("change", loadTaskCandidates);
    document.getElementById("exaMapSaveBtn").addEventListener("click", onSaveMapping);
    document.getElementById("exaNewTaskForm").addEventListener("submit", onCreateTask);
  }

  // ---- reads ---------------------------------------------------------

  async function loadDetail() {
    const res = await getJson(`${base}/${state.id}`);
    if (!res.ok) {
      unavailable("Could not load this exception request.", res.error);
      return false;
    }
    state.detail = res.data;
    renderHeader();
    return true;
  }

  function renderHeader() {
    const d = state.detail || {};
    document.getElementById("exaHeading").textContent =
      d.requestTitle || `Exception #${state.id}`;
    document.getElementById("exaRequestTitle").textContent = d.requestTitle || "";
    document.getElementById("exaStatusChip").textContent = d.statusCode || "-";

    // Linked practice is shown here, in the read-only strip, precisely
    // because it is not the analyst's to change.
    const facts = [
      ["Request #",       state.id],
      ["Status",          d.statusCode],
      ["Source gap",      d.gapTitle || (d.customGapId ? `Gap #${d.customGapId}` : "")],
      ["Linked practice", state.practiceName
                          || (d.linkedPracticeId ? `Practice #${d.linkedPracticeId}` : "Not linked")],
      ["Requested by",    d.requestedByName],
      ["Requested on",    fmtDate(d.requestedOn)],
      ["Request reason",  d.requestReason]
    ];
    document.getElementById("exaFacts").innerHTML = facts
      .filter(([, v]) => v !== null && v !== undefined && String(v).trim() !== "")
      .map(([k, v]) => `<div><dt>${escapeHtml(k)}</dt><dd>${escapeHtml(v)}</dd></div>`)
      .join("");

    // Submit belongs to Pending only. Once submitted, the request is the
    // approver's; once decided, nobody's.
    const isPending = d.statusCode === "Pending";
    document.getElementById("exaSubmitWrap").hidden = !isPending;

    // After submission the analysis is read-only. The procedure still
    // accepts edits at SubmittedForApproval (an approver may ask for a
    // correction), but the page does not invite them -- an analysis that
    // changes under the approver's feet is worse than a re-submission.
    const editable = isPending;
    ["exaType", "exaOwner", "exaJustification", "exaRiskImpact",
     "exaEffectiveFrom", "exaEffectiveTo"]
      .forEach(id => { const el = document.getElementById(id); if (el) el.disabled = !editable; });
    document.getElementById("exaSaveBtn").hidden    = !editable;
    document.getElementById("exaNewTaskBtn").hidden = !editable;
    document.getElementById("exaMapTaskBtn").hidden = !editable;

    if (!isPending) {
      document.getElementById("exaSubHeading").textContent =
        d.statusCode === "SubmittedForApproval"
          ? "Submitted for approval. The approver sets the effective dates and decides."
          : `This request is ${d.statusCode}. The analysis is shown for reference.`;
    }
  }

  function fillAnalysisForm() {
    const d = state.detail || {};
    setVal("exaType",          d.exceptionTypeCode || "");
    setVal("exaOwner",         d.ownerEmployeeId ? String(d.ownerEmployeeId) : "");
    setVal("exaJustification", d.justification || "");
    setVal("exaRiskImpact",    d.riskImpact || "");
    // <input type="date"> only accepts yyyy-mm-dd; fmtDate already
    // produces exactly that.
    setVal("exaEffectiveFrom", fmtDate(d.proposedEffectiveFrom));
    setVal("exaEffectiveTo",   fmtDate(d.proposedEffectiveUntil));
  }

  async function loadExceptionTypes() {
    const res = await getJson(`${base}/lookups/exception-types`);
    if (!res.ok) return;
    fillSelect("exaType", res.data, "exceptionTypeCode", "exceptionTypeName", "-- select --");
  }

  async function loadEmployees() {
    const orgId = state.detail && state.detail.organizationId;
    if (!orgId) return;
    const res = await getJson(`/practice/api/organizations/${orgId}/employees`);
    if (!res.ok) return;
    state.employees = (res.data && (res.data.data || res.data)) || [];
    fillSelect("exaOwner",       state.employees, "employeeId", "employeeName", "-- unassigned --");
    fillSelect("exaNtAssignee",  state.employees, "employeeId", "employeeName", "-- unassigned --");
  }

  // Resolves linked_practice_id to a name via the module's own practices
  // lookup. Failure is silent: the header falls back to "Practice #n",
  // which is still true, just less readable.
  async function loadPracticeName() {
    const d = state.detail || {};
    if (!d.organizationId || !d.linkedPracticeId) return;
    const res = await getJson(`${base}/lookups/practices?organizationId=${d.organizationId}`);
    if (!res.ok) return;
    const rows = res.data || [];
    const hit = rows.find(r => Number(r.practiceId ?? r.PracticeId) === Number(d.linkedPracticeId));
    if (!hit) return;
    const code = hit.practiceCode ?? hit.PracticeCode;
    const name = hit.practiceName ?? hit.PracticeName;
    state.practiceName = code ? `${code} - ${name}` : name;
  }

  async function loadTasks() {
    const res = await getJson(`${base}/${state.id}/tasks`);
    state.tasks = res.ok ? (res.data || []) : [];
    const body = document.getElementById("exaTaskBody");
    document.getElementById("exaTaskCount").textContent = state.tasks.length;

    if (!res.ok) {
      body.innerHTML = `<tr><td colspan="9" class="pm-empty">Could not load tasks: ${escapeHtml(res.error)}</td></tr>`;
      return;
    }
    if (!state.tasks.length) {
      body.innerHTML = `<tr><td colspan="9" class="pm-empty">No tasks attached yet.</td></tr>`;
      return;
    }
    const editable = (state.detail || {}).statusCode === "Pending";
    body.innerHTML = state.tasks.map(t => `
      <tr>
        <td>${escapeHtml(t.taskNumber || t.taskId)}</td>
        <td>${escapeHtml(t.taskTitle || "")}</td>
        <td>${escapeHtml(t.taskTypeName || t.taskTypeCode || "")}</td>
        <td>${escapeHtml(t.assignedToName || "")}</td>
        <td>${escapeHtml(t.priority || "")}</td>
        <td>${escapeHtml(fmtDate(t.dueAt))}</td>
        <td>${escapeHtml(t.taskStatusName || t.taskStatusCode || "")}</td>
        <td><span class="pm-badge">${escapeHtml(t.linkSourceCode || "")}</span></td>
        <td>${editable
              ? `<button type="button" class="pm-button small" data-unlink="${t.taskId}">
                   <i class="fa-solid fa-link-slash"></i> Unlink</button>`
              : ""}</td>
      </tr>`).join("");

    body.querySelectorAll("[data-unlink]").forEach(btn =>
      btn.addEventListener("click", () => onUnlinkTask(Number(btn.dataset.unlink))));
  }

  // ---- history (260) -------------------------------------------------
  // The whole trail, not just the date change: one reader for every
  // action_code the procedures write, so a new action needs no new UI.

  const HISTORY_LABEL = {
    Create:                "Created",
    SubmitForApproval:     "Submitted for approval",
    EffectiveDatesChanged: "Effective dates changed",
    Approve:               "Approved",
    Reject:                "Rejected",
    Withdraw:              "Withdrawn",
    AttachmentUpload:      "Attachment added"
  };

  async function loadHistory() {
    const body = document.getElementById("exaHistoryBody");
    if (!body) return;
    const res = await getJson(`${base}/${state.id}/history`);
    const rows = res.ok ? (res.data || []) : [];
    if (!res.ok) {
      body.innerHTML = `<tr><td colspan="4" class="pm-empty">Could not load history: ${escapeHtml(res.error)}</td></tr>`;
      return;
    }
    if (!rows.length) {
      body.innerHTML = `<tr><td colspan="4" class="pm-empty">Nothing recorded yet.</td></tr>`;
      return;
    }
    body.innerHTML = rows.map(h => {
      const label = HISTORY_LABEL[h.actionCode] || h.actionCode || "";
      // The date change is the one row an auditor comes here for, so it
      // is the one row that is allowed to shout.
      const cls = h.actionCode === "EffectiveDatesChanged" ? " exc-pending" : "";
      return `
      <tr>
        <td>${escapeHtml(fmtDateTime(h.enteredOn))}</td>
        <td><span class="pm-badge${cls}">${escapeHtml(label)}</span></td>
        <td>${escapeHtml(h.actorName || "system")}</td>
        <td>${escapeHtml(h.remark || "")}</td>
      </tr>`;
    }).join("");
  }

  // ---- writes --------------------------------------------------------

  async function onSaveAnalysis() {
    const msg = document.getElementById("exaSaveMsg");
    msg.textContent = "Saving...";
    const res = await postJson(`${base}/${state.id}/analysis`, {
      exceptionTypeCode: valOrNull("exaType"),
      justification:     valOrNull("exaJustification"),
      riskImpact:        valOrNull("exaRiskImpact"),
      ownerEmployeeId:   numOrNull("exaOwner"),
      // 260. Optional here on purpose -- a draft analysis may not have
      // settled the window yet. Submit is where the procedure insists.
      proposedEffectiveFrom:  valOrNull("exaEffectiveFrom"),
      proposedEffectiveUntil: valOrNull("exaEffectiveTo")
    });
    msg.textContent = res.ok ? "Analysis saved." : (res.error || "Save failed.");
    if (res.ok) await loadDetail();
  }

  async function onSubmitForApproval() {
    // The procedure enforces this too (errors 55268 / 55269 / 55286 /
    // 55287); checking here as well means the operator is told before a
    // round trip.
    if (!valOrNull("exaJustification") || !valOrNull("exaRiskImpact")) {
      alert("Justification and Risk / Impact are both needed before submitting for approval.");
      return;
    }
    const effFrom = valOrNull("exaEffectiveFrom");
    const effTo   = valOrNull("exaEffectiveTo");
    if (!effFrom || !effTo) {
      alert("Effective from and Effective to are both needed before submitting for approval.");
      return;
    }
    if (effFrom > effTo) {
      // Both are yyyy-mm-dd from <input type="date">, so a string
      // comparison is a date comparison — no parsing, no time zone.
      alert("Effective from must be on or before Effective to.");
      return;
    }
    if (!await window.gracUi.confirm(
          "The analysis becomes read-only and the approver decides from here.",
          { title: "Submit for approval", confirmText: "Submit" })) return;

    // Save first, so an unsaved edit is not silently discarded by the
    // submit that follows it.
    await onSaveAnalysis();

    const res = await postJson(`${base}/${state.id}/submit-for-approval`, {});
    if (!res.ok) { alert(res.error || "Could not submit for approval."); return; }
    await loadDetail();
    await loadTasks();
    await loadHistory();
    alert("Submitted for approval.");
  }

  // ---- tasks ---------------------------------------------------------

  function openNewTaskModal() {
    document.getElementById("exaNtMsg").textContent = "";
    document.getElementById("exaNewTaskForm").reset();
    show("exaNewTaskModal");
  }

  async function onCreateTask(ev) {
    ev.preventDefault();
    const d = state.detail || {};
    const title = document.getElementById("exaNtTitle").value.trim();
    const msg = document.getElementById("exaNtMsg");
    if (!title) { msg.textContent = "Task name is required."; return; }

    const target = document.getElementById("exaNtTarget").value;
    // Same endpoint and payload shape Task Centre's New Task uses. The
    // exception's practice and Exception as the source are what make the
    // task findable from both ends afterwards.
    const payload = {
      organizationId:       d.organizationId,
      taskTypeCode:         "Custom",
      subjectEntityType:    "Custom",
      subjectEntityId:      0,
      subjectTitle:         title,
      subjectDescription:   document.getElementById("exaNtDescription").value.trim() || null,
      priority:             document.getElementById("exaNtPriority").value,
      assignedToEmployeeId: numOrNull("exaNtAssignee"),
      linkedPracticeId:     d.linkedPracticeId || null,
      sourceTypeCode:       "Exception",
      sourceRecordId:       state.id,
      targetDate:           target ? new Date(target + "T00:00:00Z").toISOString() : null
    };

    msg.textContent = "Creating...";
    const created = await postJson("/practice/api/tasks", payload);
    if (!created.ok) { msg.textContent = created.error || "Could not create the task."; return; }

    const newId = created.data && (created.data.taskId || created.data.TaskId);
    if (!newId) { msg.textContent = "Task created but no id was returned; attach it with Map existing task."; return; }

    const linked = await postJson(`${base}/${state.id}/tasks`,
                                  { taskId: Number(newId), linkSourceCode: "Created" });
    if (!linked.ok) { msg.textContent = `Task #${newId} created but not attached: ${linked.error}`; return; }

    hide("exaNewTaskModal");
    await loadTasks();
  }

  async function openMapModal() {
    document.getElementById("exaMapMsg").textContent = "";
    // The scope line is written from the payload once it arrives -- the
    // server resolves the practice (it can derive one the request never
    // stored), so the client is not the authority on what is in scope.
    document.getElementById("exaMapScope").textContent = "Loading...";
    show("exaMapModal");
    await loadTaskCandidates();
  }

  // 259: the server decides the scope and says which it used, so the
  // note always describes what is actually on screen.
  function setMapScopeNote(scope) {
    const el = document.getElementById("exaMapScope");
    if (!el) return;
    const tail = " Ticked rows are already attached to this exception; "
               + "untick to detach.";
    if (scope.scopeCode === "Organization" || !scope.practiceId) {
      el.textContent = "This exception has no practice behind it (a custom gap "
                     + "carries none), so every task in the organization is listed."
                     + tail;
      return;
    }
    const label = scope.practiceCode
      ? `${scope.practiceCode} - ${scope.practiceName || ""}`.trim()
      : (scope.practiceName || `practice #${scope.practiceId}`);
    el.textContent = `Showing every task recorded under ${label}.` + tail;
  }

  async function loadTaskCandidates() {
    const body = document.getElementById("exaMapBody");
    body.innerHTML = `<tr><td colspan="7" class="pm-empty">Loading...</td></tr>`;
    const q = document.getElementById("exaMapSearch").value.trim();
    const res = await getJson(`${base}/${state.id}/task-candidates${q ? "?search=" + encodeURIComponent(q) : ""}`);
    if (!res.ok) {
      body.innerHTML = `<tr><td colspan="7" class="pm-empty">Could not load tasks: ${escapeHtml(res.error)}</td></tr>`;
      return;
    }
    // Migration 258: the payload now carries the practice the list was
    // scoped to, so an empty grid can say WHICH of the two happened --
    // no practice resolved, or a practice with no tasks.
    const rows  = (res.data && res.data.rows) || [];
    const scope = res.data || {};
    setMapScopeNote(scope);
    if (!rows.length) {
      // 259: with the org-wide fallback in place, an empty grid means
      // there are genuinely no tasks to offer -- not that we could not
      // work out where to look.
      body.innerHTML = `<tr><td colspan="7" class="pm-empty">${escapeHtml(
        scope.scopeCode === "Organization"
          ? "No tasks exist in this organization yet. Use New task to raise one."
          : "No tasks are recorded under this practice yet. Use New task to raise one."
      )}</td></tr>`;
      state.mapOriginal = new Set();
      updatePendingNote();
      return;
    }

    // The set as the server has it. Save diffs the ticks against this,
    // so re-saving without changing anything sends nothing.
    state.mapOriginal = new Set(rows.filter(r => r.isLinked).map(r => Number(r.taskId)));

    body.innerHTML = rows.map(t => `
      <tr>
        <td><input type="checkbox" class="exa-map-tick" data-task="${t.taskId}"
                   ${t.isLinked ? "checked" : ""} /></td>
        <td>${escapeHtml(t.taskNumber || t.taskId)}</td>
        <td>${escapeHtml(t.taskTitle || "")}</td>
        <td>${escapeHtml(t.taskTypeName || t.taskTypeCode || "")}</td>
        <td>${escapeHtml(t.assignedToName || "")}</td>
        <td>${escapeHtml(t.taskStatusName || t.taskStatusCode || "")}</td>
        <td>${escapeHtml(fmtDate(t.dueAt))}</td>
      </tr>`).join("");

    body.querySelectorAll(".exa-map-tick").forEach(cb =>
      cb.addEventListener("change", updatePendingNote));
    const all = document.getElementById("exaMapAll");
    if (all) {
      all.checked = false;
      all.onclick = () => {
        body.querySelectorAll(".exa-map-tick").forEach(cb => { cb.checked = all.checked; });
        updatePendingNote();
      };
    }
    updatePendingNote();
  }

  // What Save would actually do, computed from the ticks against the
  // set the server returned. Shown in the footer so the operator sees
  // that unticking removes a link before pressing Save, not after.
  function mapDiff() {
    const ticked = new Set(
      [...document.querySelectorAll(".exa-map-tick")]
        .filter(cb => cb.checked).map(cb => Number(cb.dataset.task)));
    const shown = new Set(
      [...document.querySelectorAll(".exa-map-tick")].map(cb => Number(cb.dataset.task)));
    const toLink = [...ticked].filter(id => !state.mapOriginal.has(id));
    // Only rows currently on screen can be unlinked -- a search that
    // hides a linked task must not silently detach it.
    const toUnlink = [...state.mapOriginal].filter(id => shown.has(id) && !ticked.has(id));
    return { toLink, toUnlink };
  }

  function updatePendingNote() {
    const { toLink, toUnlink } = mapDiff();
    const note = document.getElementById("exaMapPending");
    if (!note) return;
    const parts = [];
    if (toLink.length)   parts.push(`${toLink.length} to attach`);
    if (toUnlink.length) parts.push(`${toUnlink.length} to detach`);
    note.textContent = parts.length ? parts.join(" · ") : "No changes";
  }

  async function onSaveMapping() {
    const { toLink, toUnlink } = mapDiff();
    const msg = document.getElementById("exaMapMsg");

    if (!toLink.length && !toUnlink.length) { hide("exaMapModal"); return; }
    if (toUnlink.length && !await window.gracUi.confirm(
          `${toUnlink.length} task(s) will be detached from this exception.`,
          { type: "warning", title: "Detach tasks", confirmText: "Continue" })) return;

    msg.textContent = "Saving...";
    const failures = [];

    // Sequential rather than parallel: these are small, and a partial
    // failure is far easier to report when the order is known.
    for (const id of toLink) {
      const r = await postJson(`${base}/${state.id}/tasks`,
                               { taskId: id, linkSourceCode: "Mapped" });
      if (!r.ok) failures.push(`attach #${id}: ${r.error}`);
    }
    for (const id of toUnlink) {
      const r = await sendJson("DELETE", `${base}/${state.id}/tasks/${id}`, null);
      if (!r.ok) failures.push(`detach #${id}: ${r.error}`);
    }

    if (failures.length) {
      msg.textContent = failures.join("; ");
      await Promise.all([loadTasks(), loadTaskCandidates()]);
      return;
    }
    hide("exaMapModal");
    await loadTasks();
  }

  async function onUnlinkTask(taskId) {
    if (!await window.gracUi.confirm(`Unlink task #${taskId} from this exception?`,
          { type: "warning", title: "Unlink task", confirmText: "Unlink" })) return;
    const res = await sendJson("DELETE", `${base}/${state.id}/tasks/${taskId}`, null);
    if (!res.ok) { alert(res.error || "Could not unlink the task."); return; }
    await loadTasks();
  }

  // ---- plumbing ------------------------------------------------------
  // Every fetch distinguishes a failure from an empty result. Collapsing
  // the two is what made a broken Risk Register read as "no rows match".

  async function getJson(path) {
    try {
      const r = await fetch(U(path), { credentials: "same-origin" });
      if (r.ok) return { ok: true, data: await r.json() };
      const b = await r.json().catch(() => ({}));
      return { ok: false, error: b.error || b.title || `HTTP ${r.status}` };
    } catch (err) { return { ok: false, error: err.message || "Network error" }; }
  }

  function postJson(path, body) { return sendJson("POST", path, body); }

  async function sendJson(method, path, body) {
    try {
      const opts = { method, credentials: "same-origin", headers: {} };
      if (body !== null && body !== undefined) {
        opts.headers["Content-Type"] = "application/json";
        opts.body = JSON.stringify(body);
      }
      const tok = document.querySelector('input[name="__RequestVerificationToken"]');
      if (tok) opts.headers["X-CSRF-TOKEN"] = tok.value;
      const r = await fetch(U(path), opts);
      const data = await r.json().catch(() => ({}));
      return r.ok ? { ok: true, data } : { ok: false, error: data.error || data.title || `HTTP ${r.status}` };
    } catch (err) { return { ok: false, error: err.message || "Network error" }; }
  }

  function fillSelect(id, rows, valueKey, labelKey, placeholder) {
    const sel = document.getElementById(id);
    if (!sel) return;
    const keep = sel.value;
    sel.innerHTML = `<option value="">${escapeHtml(placeholder)}</option>`;
    (rows || []).forEach(row => {
      const v = row[valueKey] ?? row[cap(valueKey)];
      const l = row[labelKey] ?? row[cap(labelKey)];
      if (v === null || v === undefined) return;
      const o = document.createElement("option");
      o.value = String(v); o.textContent = String(l ?? v);
      sel.appendChild(o);
    });
    sel.value = keep;
  }
  const cap = s => s.charAt(0).toUpperCase() + s.slice(1);

  function setVal(id, v) { const el = document.getElementById(id); if (el) el.value = v; }
  function valOrNull(id) {
    const el = document.getElementById(id);
    const v = el ? String(el.value || "").trim() : "";
    return v === "" ? null : v;
  }
  function numOrNull(id) { const v = valOrNull(id); return v === null ? null : Number(v); }
  function show(id) { const el = document.getElementById(id); if (el) el.hidden = false; }
  function hide(id) { const el = document.getElementById(id); if (el) el.hidden = true; }

  function fmtDate(v) {
    if (!v) return "";
    const d = new Date(v);
    return isNaN(d.getTime()) ? String(v).slice(0, 10) : d.toISOString().slice(0, 10);
  }
  // History needs the time as well -- "who changed the window" is a
  // question about an ordering, and two entries on one day are common.
  function fmtDateTime(v) {
    if (!v) return "";
    if (typeof window.gracFormatDisplayDate === "function") { var _g = window.gracFormatDisplayDate(v); if (_g && _g !== v) return _g; }
    const d = new Date(v);
    return isNaN(d.getTime()) ? String(v) : d.toLocaleString();
  }
  function escapeHtml(s) {
    if (s === null || s === undefined) return "";
    return String(s).replace(/[&<>"']/g,
      ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
  }
})();
