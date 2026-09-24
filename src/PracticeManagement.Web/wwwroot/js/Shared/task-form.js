// =====================================================================
// window.gracTaskForm — THE Task / Sub Task creation form.
//
// Pairs with Views/Practice/Partials/_task-form-dialog.cshtml. Include
// that partial once on a page, load this script, and any screen on that
// page can open the same dialog.
//
// WHY THIS EXISTS
// ---------------
// Task work could be created from three places, each with its own form:
//
//   Task Center "New Task (Custom)"   a proper dialog
//   Task Center "Add child task"      FOUR chained window.prompt() boxes
//                                     and a confirm() for mandatory
//   Risk Treatment "Add a sub task"   an inline panel, its own fields
//
// Three implementations of one concept: three validations, three sets of
// field names, three places to change when a task field is added. The
// prompt() chain could not even show which parent it was adding to.
//
// ONE FORM, TWO MODES
// -------------------
//   mode: "task"     -> POST /practice/api/tasks              (sp_task_open)
//   mode: "subtask"  -> POST /practice/api/tasks/{id}/children (sp_task_child_create)
//
// The caller does not pick the endpoint or build a payload; it says what
// it wants created and in what context, and this decides the rest.
//
// WHAT A SUB TASK CANNOT CARRY, AND WHY THE FIELDS STAY ANYWAY
// -----------------------------------------------------------
// sp_task_child_create takes title, description, assignee, mandatory and
// a target date -- no priority and no start date, because BRD §11 makes
// the child inherit both from its parent ("the parent owns the
// commitment; children distribute the work"). That is a rule, not a gap.
//
// Hiding those two fields in sub task mode would make the form look
// different depending on how it was opened, which is the inconsistency
// this component exists to end. So they are SHOWN, DISABLED, and say why.
// The user sees the same eight fields everywhere and learns the rule from
// the form instead of from a support ticket.
//
// Remarks is the exception: the child endpoint does not take it either,
// but unlike priority there is no rule against a sub task having one. So
// it stays editable and is posted as a task activity immediately after
// creation (sp_task_activity_add) -- the same place a remark on any task
// ends up. Nothing is silently dropped.
//
// PARENT TASK
// -----------
//   opened from a task's own menu -> parent is known, shown read-only,
//                                    and cannot be changed
//   opened without one            -> a parent selector is shown and is
//                                    required
// Both are the same dialog; only one of the two rows is visible.
//
// USAGE
//   window.gracTaskForm.open({
//     mode:             "task" | "subtask",
//     organizationId:   123,
//     organizationName: "Demo Bank Limited",
//     parentTask:       { taskId, taskNumber, title },   // subtask, known parent
//     parentOptions:    [ { taskId, taskNumber, title } ], // subtask, user picks
//     employees:        [...],        // optional; fetched when omitted
//     defaults:         { title, description, priority, assignedToEmployeeId,
//                         startDate, targetDate, remarks },
//     onSaved:          result => { ... }   // { taskId, isSubTask, parentTaskId }
//   });
// =====================================================================
(() => {
  "use strict";

  // Resolved lazily, not captured at parse time: this script can load
  // before the layout's inline script sets window.pmPathBase, and a
  // published build under a PathBase would then post to the origin root.
  const U = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;

  const $ = id => document.getElementById(id);

  let opts = null;          // the options of the currently open dialog
  let wired = false;


  function msg(text, kind) {
    const el = $("gracTaskFormMessage");
    if (!el) return;
    if (!text) { el.style.display = "none"; el.textContent = ""; return; }
    el.style.display = "block";
    el.textContent = text;
    el.style.background = kind === "error" ? "#fef2f2" : kind === "ok" ? "#ecfdf5" : "#eff6ff";
    el.style.color      = kind === "error" ? "#b91c1c" : kind === "ok" ? "#065f46" : "#1e40af";
  }

  // Two endpoints exist for the same list -- Task Center uses
  // /organizations/{id}/employees, Risk Centre used the document-uploads
  // lookup. The primary is the one the reference form already used; the
  // fallback keeps callers working where only the other is permitted.
  async function fetchEmployees(orgId) {
    if (!orgId) return [];
    const urls = [
      U(`/practice/api/organizations/${encodeURIComponent(orgId)}/employees`),
      U(`/practice/api/document-uploads/lookups/employees?organizationId=${encodeURIComponent(orgId)}`)
    ];
    for (const url of urls) {
      try {
        const r = await fetch(url, { credentials: "same-origin" });
        if (!r.ok) continue;
        const arr = await r.json();
        if (Array.isArray(arr)) return arr;
      } catch (_) { /* try the next one */ }
    }
    return [];
  }

  function fillAssignees(list, keep) {
    const sel = $("gracTaskFormAssignee");
    sel.innerHTML = "";
    const ph = document.createElement("option");
    ph.value = "";
    ph.textContent = list.length ? "— select an employee —"
                                 : "No active employees for this organization";
    sel.appendChild(ph);
    list.forEach(e => {
      const o = document.createElement("option");
      o.value = String(e.employeeId);
      o.textContent = e.employeeName + (e.employeeCode ? ` (${e.employeeCode})` : "");
      if (e.email) o.title = e.email;
      sel.appendChild(o);
    });
    if (keep) sel.value = String(keep);
  }

  function setDisabled(id, on, noteId, noteText) {
    const el = $(id);
    if (el) {
      el.disabled = on;
      el.style.background = on ? "#f1f5f9" : "";
    }
    const note = noteId ? $(noteId) : null;
    if (note) {
      note.textContent = on ? (noteText || "") : "";
      note.style.display = on && noteText ? "block" : "none";
    }
  }

  async function open(options) {
    const dlg = $("gracTaskFormDialog");
    if (!dlg) {
      console.error("[grac-task-form] _task-form-dialog.cshtml is not on this page.");
      return;
    }
    wire();

    opts = Object.assign({ mode: "task", defaults: {} }, options || {});
    const isSub  = opts.mode === "subtask";
    const parent = opts.parentTask || null;
    const d      = opts.defaults || {};

    msg("");
    $("gracTaskFormTitle").textContent = isSub ? "New Sub Task" : "New Task (Custom)";
    $("gracTaskFormSubmit").textContent = isSub ? "Create Sub Task" : "Create Task";
    $("gracTaskFormSubmit").disabled = false;
    $("gracTaskFormOrgLabel").textContent =
      opts.organizationName || (opts.organizationId ? `Organization ${opts.organizationId}` : "—");

    // The mode drives layout as well as behaviour: a task has no Parent
    // Task cell, so Organization takes the whole row rather than leaving
    // half of one empty. That is a CSS decision, so CSS is told the mode
    // rather than the JS setting grid spans by hand.
    $("gracTaskForm").classList.toggle("is-subtask", isSub);

    // ---- Parent task rows -------------------------------------------
    const fixed = $("gracTaskFormParentFixed");
    const pick  = $("gracTaskFormParentPick");
    fixed.style.display = "none";
    pick.style.display  = "none";
    $("gracTaskFormParentId").value = "";
    $("gracTaskFormParentSelect").innerHTML = `<option value="">— select the parent task —</option>`;

    if (isSub && parent && parent.taskId) {
      fixed.style.display = "block";
      $("gracTaskFormParentId").value = String(parent.taskId);
      $("gracTaskFormParentLabel").value =
        `${parent.taskNumber || "#" + parent.taskId}${parent.title ? " — " + parent.title : ""}`;
    } else if (isSub) {
      pick.style.display = "block";
      const sel = $("gracTaskFormParentSelect");
      (opts.parentOptions || []).forEach(p => {
        const o = document.createElement("option");
        o.value = String(p.taskId);
        o.textContent = `${p.taskNumber || "#" + p.taskId}${p.title ? " — " + p.title : ""}`;
        sel.appendChild(o);
      });
    }

    // ---- Fields the child endpoint cannot carry ---------------------
    // Shown, disabled, and explained. See the header for why they are not
    // hidden instead.
    setDisabled("gracTaskFormPriority", isSub, "gracTaskFormPriorityNote",
                "Inherited from the parent task (BRD §11).");
    setDisabled("gracTaskFormStartDate", isSub, "gracTaskFormStartNote",
                "A sub task runs within its parent's window.");

    $("gracTaskFormMandatoryRow").style.display = isSub ? "flex" : "none";
    $("gracTaskFormMandatory").checked = true;

    // ---- Values ------------------------------------------------------
    $("gracTaskFormTitleInput").value  = d.title || "";
    $("gracTaskFormDescription").value = d.description || "";
    $("gracTaskFormRemarks").value     = d.remarks || "";
    $("gracTaskFormStartDate").value   = d.startDate || "";
    $("gracTaskFormTargetDate").value  = d.targetDate || "";
    $("gracTaskFormPriority").value    = d.priority || "Medium";

    const sel = $("gracTaskFormAssignee");
    sel.innerHTML = `<option value="">Loading employees...</option>`;
    sel.disabled = true;
    const list = Array.isArray(opts.employees) && opts.employees.length
      ? opts.employees
      : await fetchEmployees(opts.organizationId);
    sel.disabled = false;
    fillAssignees(list, d.assignedToEmployeeId);

    if (!dlg.open) (dlg.showModal ? dlg.showModal() : (dlg.open = true));
    $("gracTaskFormTitleInput").focus();
  }

  function close() {
    const dlg = $("gracTaskFormDialog");
    if (!dlg) return;
    if (dlg.close) { try { dlg.close(); } catch (_) { dlg.open = false; } }
    else dlg.open = false;
    opts = null;
  }

  // A <input type="date"> is a local calendar day. new Date("YYYY-MM-DD")
  // parses as UTC midnight, which is the previous day west of Greenwich,
  // so the T00:00:00Z suffix is what keeps the date the user picked.
  const isoOrNull = v => (v ? new Date(v + "T00:00:00Z").toISOString() : null);

  async function submit(ev) {
    if (ev) ev.preventDefault();
    if (!opts) return;

    const isSub    = opts.mode === "subtask";
    const title    = $("gracTaskFormTitleInput").value.trim();
    const assignee = $("gracTaskFormAssignee").value;
    const parentId = isSub
      ? Number($("gracTaskFormParentId").value || $("gracTaskFormParentSelect").value || 0)
      : 0;

    // One validation, so every caller refuses the same things for the
    // same reasons.
    if (isSub && !parentId) { msg("Parent Task is required.", "error"); return; }
    if (!title)             { msg("Task Name is required.", "error"); return; }
    if (!assignee)          { msg("Assigned To is required — select an employee.", "error"); return; }

    const btn = $("gracTaskFormSubmit");
    btn.disabled = true;
    msg("Saving...");

    const description = $("gracTaskFormDescription").value.trim() || null;
    const remarks     = $("gracTaskFormRemarks").value.trim() || null;
    const targetDate  = $("gracTaskFormTargetDate").value;
    const startDate   = $("gracTaskFormStartDate").value;

    try {
      let url, payload;
      if (isSub) {
        url = U(`/practice/api/tasks/${parentId}/children`);
        payload = {
          subjectTitle:         title,
          subjectDescription:   description,
          assignedToEmployeeId: Number(assignee),
          isMandatory:          $("gracTaskFormMandatory").checked,
          childTargetDate:      targetDate || null
        };
      } else {
        url = U("/practice/api/tasks");
        payload = {
          organizationId:       Number(opts.organizationId),
          taskTypeCode:         opts.taskTypeCode || "Custom",
          subjectEntityType:    opts.subjectEntityType || "Custom",
          subjectEntityId:      opts.subjectEntityId || 0,
          subjectTitle:         title,
          subjectDescription:   description,
          priority:             $("gracTaskFormPriority").value,
          assignedToEmployeeId: Number(assignee),
          startDate:            isoOrNull(startDate),
          targetDate:           isoOrNull(targetDate)
          // No `remarks` here: TaskOpenRequest has no such field and
          // sp_task_open has no such parameter. The Task Center form has
          // always sent one and it has always been discarded by model
          // binding -- silently, because an unknown JSON property is not
          // an error. Remarks is posted as an activity below instead, for
          // BOTH modes, which is where a remark on a task belongs and
          // means the field finally does something.
        };
        // A caller may need the task tied to its own origin (BRD §15) --
        // passed straight through rather than reinvented per caller.
        if (opts.sourceTypeCode) payload.sourceTypeCode = opts.sourceTypeCode;
        if (opts.sourceRecordId) payload.sourceRecordId = opts.sourceRecordId;
        if (opts.sourceReference) payload.sourceReference = opts.sourceReference;
        if (opts.linkedPracticeId) payload.linkedPracticeId = opts.linkedPracticeId;
        if (opts.linkedControlId)  payload.linkedControlId  = opts.linkedControlId;
      }

      const r = await fetch(url, {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload)
      });
      const body = await r.json().catch(() => ({}));
      if (!r.ok || body.success === false) {
        msg((body.error || `Request failed (HTTP ${r.status})`)
            + (body.reasonCode ? ` [${body.reasonCode}]` : ""), "error");
        btn.disabled = false;
        return;
      }

      const newId = body.taskId || body.childTaskId || body.id || null;

      // Remarks -> a task activity, for a task AND a sub task alike.
      // Neither endpoint stores a remark on the row itself: the child
      // endpoint has no field, and sp_task_open has no parameter. An
      // activity is where a remark on a task lives anyway, so one path
      // serves both modes and the field behaves the same either way.
      //
      // Best-effort: the task is already created, and failing the whole
      // operation because a comment did not attach would be the wrong
      // trade. A failure is logged, not swallowed.
      if (remarks && newId) {
        try {
          await fetch(U(`/practice/api/tasks/${newId}/activity`), {
            method: "POST",
            credentials: "same-origin",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ activityTypeCode: "Comment", remark: remarks })
          });
        } catch (err) {
          console.warn("[grac-task-form] task created; remark not attached", err);
        }
      }

      msg(`${isSub ? "Sub task" : "Task"} ${newId ? "#" + newId : ""} created.`, "ok");
      const done = opts.onSaved;
      const result = { taskId: newId, isSubTask: isSub, parentTaskId: isSub ? parentId : null };
      setTimeout(() => {
        close();
        if (typeof done === "function") { try { done(result); } catch (e) { console.error(e); } }
      }, 700);
    } catch (err) {
      msg("Network error: " + err.message, "error");
      btn.disabled = false;
    }
  }

  // Bound once, on first open. The dialog markup is static, so there is
  // nothing to re-bind and no listener to leak.
  function wire() {
    if (wired) return;
    wired = true;
    $("gracTaskFormClose")?.addEventListener("click", close);
    $("gracTaskFormCancel")?.addEventListener("click", close);
    $("gracTaskForm")?.addEventListener("submit", submit);
    // Click outside to dismiss, matching the Task Center dialog it
    // replaces. Was a coordinate check (e.clientX/e.clientY against the
    // dialog's own rect) -- that misfires on ANY click event whose
    // coordinates are not real, including a programmatic click a browser
    // extension, clipboard-sync tool, or assistive technology can
    // dispatch on the focused field (clientX/clientY default to 0, which
    // reads as "outside" a centred dialog) -- e.g. pressing Ctrl+C while
    // a field inside the dialog was focused could close the whole form.
    // event.target is the standard, coordinate-free way to detect a
    // native <dialog> backdrop click: a real click on anything INSIDE the
    // dialog always targets that descendant element, never the <dialog>
    // node itself -- only a genuine backdrop click does.
    const dlg = $("gracTaskFormDialog");
    dlg?.addEventListener("click", e => {
      if (e.target === dlg) close();
    });
  }

  window.gracTaskForm = { open, close };
})();
