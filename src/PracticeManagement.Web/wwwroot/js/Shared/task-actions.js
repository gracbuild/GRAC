// =====================================================================
// window.gracTaskActions -- THE Task Centre row-menu actions (Edit,
// Complete, Close, Add Evidence, Add Update/Comment) plus the menu-item
// list they come from.
//
// Extracted from Views/Practice/Partials/tasks.cshtml (change request:
// Task View's own "Actions" menu must reuse these verbatim -- same
// forms, same API calls, same validation, same permission /
// applicability rules, same success/error handling -- rather than a
// second copy for Task View. Task Center itself was rewired to call
// this module too, so there is exactly one implementation of each
// action, used from both screens.
//
// Pairs with Views/Practice/Partials/_task-action-dialogs.cshtml, which
// carries the Edit / Complete / Close / Add Evidence dialog markup this
// module drives. Include that partial once on a page, load this script,
// call window.gracTaskActions.init({...}) once, and the page can then:
//
//   * build the same 3-dot / Actions menu item list Task Center uses,
//     via buildMenu(fields, handlers) -- pass only the handlers the
//     host page wants wired (a handler that is omitted is not offered
//     at all, so e.g. Task View simply never passes onView);
//   * open any of the shared dialogs directly: openEdit, openComplete,
//     openClose, openEvidenceUpload, openAddUpdate, openView.
//
// PERMISSION / APPLICABILITY
// ---------------------------
// buildMenu() reproduces exactly the applicable/disabled rules
// tasks.cshtml's own buildRowMenu() used to hardcode, so a host page
// that calls it gets identical status-based gating for free -- there is
// no separate "can this user edit this task" role check in Task Center
// beyond these; the item list itself IS the permission surface.
//
// WHAT IS DELIBERATELY *NOT* HERE
// --------------------------------
// "Add Child Task" / "New Task" is not duplicated here -- it already had
// its own shared component before this change (window.gracTaskForm,
// Shared/task-form.js + _task-form-dialog.cshtml), so both Task Center
// and Task View call that directly instead of through this module.
//
// A handful of small, PURELY PRESENTATIONAL helpers (escape, fmtDate,
// ownerCell, ownerSourceLabel, slaStatusBadge, formatBadge) are
// duplicated from tasks.cshtml's own copies rather than exported from
// there, because tasks.cshtml's grid-row rendering is unrelated to this
// change and was left untouched -- and because a plain <script src> has
// no way to reach into another script's closure regardless. None of
// these carry any business rule; they only format a value that already
// came from the API.
// =====================================================================
(function () {
  "use strict";

  var U = function (p) { return String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p; };
  var $ = function (id) { return document.getElementById(id); };

  function escape(v) {
    if (v === null || v === undefined) return "";
    return String(v).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function fmtDate(v) {
    if (!v) return "";
    if (typeof window.gracFormatDisplayDate === "function") {
      var out = window.gracFormatDisplayDate(v);
      if (out !== v) return out;
    }
    var d = new Date(v);
    return isNaN(d.getTime()) ? String(v).slice(0, 10) : d.toISOString().slice(0, 10);
  }
  function formatBadge(v) { return v ? '<span class="pm-badge">' + escape(v) + '</span>' : ''; }
  function ownerSourceLabel(code) {
    return ({
      PRACTICE_OWNER: 'from Practice owner',
      CONTROL_OWNER: 'from Control owner',
      PROCESS_OWNER: 'from Process owner',
      FUNCTION_OWNER: 'from Function owner',
      ORG_DEFAULT: 'org default owner',
      MANUAL: 'manual assignment'
    })[code] || '';
  }
  function ownerCell(r) {
    if (r.assignedToEmployeeName) {
      var src = r.ownerSourceCode && r.ownerSourceCode !== 'EXPLICIT_SOURCE' && r.ownerSourceCode !== 'REASSIGNED'
        ? '<div style="font-size:11px; color:var(--fg-muted);">' + escape(ownerSourceLabel(r.ownerSourceCode)) + '</div>'
        : '';
      return escape(r.assignedToEmployeeName) + src;
    }
    if (r.assignedToEmployeeId) return escape(r.assignedToEmployeeId);
    return '<span style="color:var(--warning-700);">Unassigned</span>';
  }
  var SLA_BADGE_STYLE = {
    OnTrack:   { bg: 'var(--success-100)', fg: 'var(--success-700)', label: 'On Track'  },
    DueSoon:   { bg: 'var(--warning-50)', fg: 'var(--warning-700)', label: 'Due Soon'  },
    DueToday:  { bg: 'var(--warning-100)', fg: 'var(--danger-700)', label: 'Due Today' },
    Breached:  { bg: 'var(--danger-100)', fg: 'var(--danger-700)', label: 'Breached'  },
    Extended:  { bg: 'var(--primary-100)', fg: 'var(--primary-800)', label: 'Extended'  },
    Completed: { bg: 'var(--bg-subtle)', fg: 'var(--fg-secondary)', label: 'Completed' },
    NotSet:    { bg: 'var(--bg-subtle)', fg: 'var(--fg-muted)', label: 'No SLA'    }
  };
  function slaStatusBadge(r) {
    var code = r.slaStatusCode;
    if (!code) return r.isOverdue ? '<span class="pm-badge">Breached</span>' : '';
    var s = SLA_BADGE_STYLE[code] || { bg: 'var(--bg-subtle)', fg: 'var(--fg-secondary)', label: code };
    return '<span class="pm-badge" style="background:' + s.bg + '; color:' + s.fg + ';">'
         + escape(s.label) + '</span>';
  }

  // ---- menu item list -------------------------------------------------
  // THREE STATES, NOT TWO -- mirrors tasks.cshtml's own note on this:
  // applicable:false HIDES an item that can never apply (a closed task,
  // "Add Child Task" on a sub task); disabled SHOWS a greyed item with a
  // reason when it is blocked by something that can change (mandatory
  // sub tasks still open). This is presentation only -- the API and SQL
  // enforce every rule again.
  var FLAGS = {
    edit:                  false,
    viewAssuranceActivity: false, // opens once the Assurance drill-down lands
    viewWorkflowHistory:   false  // opens once the workflow-history viewer lands
  };

  // fields: { taskId, taskNumber, taskTitle, taskType, isTerminal, isChild, isEligible }
  // handlers: { onView, onEdit, onComplete, onAddChild, onAddEvidence, onAddUpdate,
  //             onViewAssuranceActivity, onViewWorkflowHistory, onClose }
  // A handler that is omitted means that item is not offered at all --
  // e.g. Task View has no use for "View" (the page already IS the view),
  // so it simply does not pass onView.
  function buildMenu(fields, handlers) {
    fields = fields || {};
    handlers = handlers || {};
    var items = [];

    if (handlers.onView) {
      items.push({ icon: 'fa-eye', label: 'View', action: handlers.onView });
    }
    if (handlers.onEdit) {
      items.push({ icon: 'fa-pen', label: 'Edit',
        applicable: !fields.isTerminal, action: handlers.onEdit });
    }
    if (handlers.onComplete) {
      items.push({ icon: 'fa-circle-check', label: 'Complete Task',
        applicable: !fields.isTerminal,
        disabled: !fields.isEligible,
        disabledReason: 'Mandatory sub tasks are still open. BRD §12: the parent '
                      + 'cannot be completed until they are done.',
        action: handlers.onComplete });
    }
    if (handlers.onAddChild) {
      items.push({ icon: 'fa-diagram-project', label: 'Add Child Task',
        applicable: !fields.isTerminal && !fields.isChild, action: handlers.onAddChild });
    }
    if (handlers.onAddEvidence) {
      items.push({ icon: 'fa-paperclip', label: 'Add Evidence',
        applicable: !fields.isTerminal, action: handlers.onAddEvidence });
    }
    if (handlers.onAddUpdate) {
      items.push({ icon: 'fa-comment-dots', label: 'Add Update / Comment',
        applicable: !fields.isTerminal, action: handlers.onAddUpdate });
    }
    if (handlers.onViewAssuranceActivity && fields.taskType === 'Assurance' && FLAGS.viewAssuranceActivity) {
      items.push({ icon: 'fa-shield-halved', label: 'View Assurance Activity',
        action: handlers.onViewAssuranceActivity });
    }
    if (handlers.onViewWorkflowHistory && FLAGS.viewWorkflowHistory) {
      items.push({ icon: 'fa-clock-rotate-left', label: 'View Workflow History',
        action: handlers.onViewWorkflowHistory });
    }
    if (handlers.onClose) {
      items.push({ icon: 'fa-lock',
        label: fields.taskType === 'Custom' ? 'Close / Inactivate' : 'Cancel Task',
        applicable: !fields.isTerminal && fields.taskType !== 'Assurance',
        action: handlers.onClose });
    }
    // Reopen -- only for tasks whose current status is actually 'Closed'
    // (terminal). The API (sp_task_reopen) enforces admin-OR-owner; the
    // button is offered broadly and the server is the real gate.
    if (handlers.onReopen) {
      items.push({ icon: 'fa-rotate-left', label: 'Reopen',
        applicable: !!fields.isTerminal && fields.rawStatusCode === 'Closed',
        action: handlers.onReopen });
    }
    return items;
  }

  // ---- module state (the dialogs this drives) --------------------------
  var cfg = { getOrganizationId: function () { return null; }, onChanged: function () {} };
  // Full-page host (task-edit.cshtml): the view/edit dialog rendered
  // inline on its own page instead of as a modal. hideDialog then
  // navigates back to the Task Board. Only the taskDetailDialog (the
  // view/edit surface) is hosted this way; the other dialogs are not
  // reachable from the edit page.
  var pageMode = false;
  var pageBackUrl = null;
  // 2026-10-23: which dialog the full page hosts -- taskDetailDialog
  // (task-edit.cshtml) or taskCompleteDialog (task-complete.cshtml).
  var pageDialogId = 'taskDetailDialog';
  var wired = false;
  var currentTaskDetail  = null;
  var currentEditOptions = null;

  function changed() {
    try { cfg.onChanged && cfg.onChanged(); } catch (err) { console.error('[grac-task-actions] onChanged handler failed', err); }
  }

  function showDialog(dlg) {
    if (!dlg) return;
    if (pageMode && dlg === $(pageDialogId)) {
      dlg.classList.add(pageDialogId === 'taskCompleteDialog' ? 'tcd--page' : 'tdd--page');
      dlg.setAttribute('open', 'open');
      dlg.style.display = 'block';
      return;
    }
    if (dlg.open) return;
    if (typeof dlg.showModal === 'function') dlg.showModal();
    else { dlg.setAttribute('open', 'open'); dlg.style.display = 'block'; }
  }
  function hideDialog(dlg) {
    if (!dlg) return;
    if (pageMode && dlg === $(pageDialogId)) {
      window.location.assign(pageBackUrl);
      return;
    }
    if (typeof dlg.close === 'function') dlg.close();
    else { dlg.removeAttribute('open'); dlg.style.display = 'none'; }
  }

  async function fetchOrgEmployees(orgId) {
    if (!orgId) return [];
    var url = U('/practice/api/organizations/') + encodeURIComponent(orgId) + '/employees';
    var r = await fetch(url, { credentials: 'same-origin' });
    if (!r.ok) throw new Error('HTTP ' + r.status + ' from ' + url);
    var arr = await r.json();
    return Array.isArray(arr) ? arr : [];
  }

  // ==== View / Edit -- one dialog, two modes (see tasks.cshtml's own
  // note on why: the reader who decides to edit is already looking at
  // the fields they want to change). ==================================
  function setDetailMode(mode, taskId) {
    var dlg = $('taskDetailDialog');
    if (dlg) dlg.classList.toggle('is-editing', mode === 'edit');
    var btn = $('taskDetailEditBtn');
    if (!btn) return;
    btn.hidden = (mode !== 'view');
    btn.setAttribute('data-task-id', taskId || '');
  }

  async function openView(taskId) {
    var dlg  = $('taskDetailDialog');
    var bodyEl = $('taskDetailBody');
    if (!dlg || !bodyEl) return;
    bodyEl.innerHTML = '<p class="pm-empty">Loading task #' + escape(taskId) + '...</p>';
    setDetailMode('view', taskId);
    showDialog(dlg);
    try {
      var r = await fetch(U('/practice/api/tasks/') + encodeURIComponent(taskId), { credentials: 'same-origin' });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      var detail = await r.json();
      currentTaskDetail = detail;
      renderTaskDetail(detail);
    } catch (err) {
      bodyEl.innerHTML = '<p class="pm-empty">Failed to load: ' + escape(err.message) + '</p>';
    }
  }

  async function openEdit(taskId, pageOpts) {
    // pageOpts.host === "page" -> render inline on the task-edit page
    // and navigate back to the board on close/save. Omitted elsewhere,
    // so the row-menu / view-dialog Edit keep their modal behaviour.
    if (pageOpts && pageOpts.host === 'page') {
      pageMode = true;                       // sticky for this page load
      pageBackUrl = pageOpts.backUrl || U('/Practice/Index/tasks');
    }
    var dlg    = $('taskDetailDialog');
    var bodyEl = $('taskDetailBody');
    if (!dlg || !bodyEl) return;

    bodyEl.innerHTML = '<p class="pm-empty">Loading task #' + escape(taskId) + '...</p>';
    setDetailMode('edit', taskId);
    showDialog(dlg);

    try {
      var results = await Promise.all([
        fetch(U('/practice/api/tasks/') + encodeURIComponent(taskId), { credentials: 'same-origin' }),
        fetch(U('/practice/api/tasks/') + encodeURIComponent(taskId) + '/edit-options', { credentials: 'same-origin' })
      ]);
      var dRes = results[0], oRes = results[1];
      if (!dRes.ok) throw new Error('HTTP ' + dRes.status);
      currentTaskDetail  = await dRes.json();
      currentEditOptions = oRes.ok ? await oRes.json() : null;
    } catch (err) {
      bodyEl.innerHTML = '<p class="pm-empty">Failed to load: ' + escape(err.message) + '</p>';
      return;
    }

    var h = currentTaskDetail && currentTaskDetail.header;
    if (!h) { bodyEl.innerHTML = '<p class="pm-empty">Task not found.</p>'; return; }

    if (currentEditOptions && currentEditOptions.canEdit === false) {
      bodyEl.innerHTML = '<p class="pm-empty">This task is closed and cannot be edited. '
                       + 'Reopening a closed task is a separate, deliberate act.</p>';
      setDetailMode('view', taskId);
      return;
    }

    renderTaskEditForm(h, currentEditOptions);
  }

  async function renderTaskEditForm(h, opts) {
    var bodyEl = $('taskDetailBody');
    $('taskDetailTitle').textContent = 'Edit ' + (h.taskNumber || ('Task #' + h.taskId));

    var employees = await fetchOrgEmployees(cfg.getOrganizationId() || (h && h.organizationId));
    var statuses  = (opts && opts.allowedStatuses) || [];

    var canPriority = !opts || opts.canEditPriority !== false;
    var canDue      = !opts || opts.canEditDueDate  !== false;
    var prioPending = opts && opts.priorityChangePending;
    var slaPending  = opts && opts.slaExtensionPending;
    var isChild     = opts && opts.isChild;

    function opt(v, label, sel) {
      return '<option value="' + escape(v) + '"' + (sel ? ' selected' : '') + '>' + escape(label) + '</option>';
    }
    function dateVal(v) { return v ? String(v).substring(0, 10) : ''; }

    var cur = opts || {};

    var p = [];
    p.push('<form id="taskEditForm">');
    p.push('<div class="tef-grid">');

    p.push('<label class="tef-span2"><span class="tef-l">Task name<i class="tef-r">*</i></span>'
         + '<input type="text" id="tefTitle" maxlength="250" required value="' + escape(h.subjectTitle || '') + '" /></label>');

    p.push('<label><span class="tef-l">Status</span><select id="tefStatus">'
         + (statuses.length
             ? statuses.map(function (s) {
                 return opt(s.statusCode, s.statusName, s.statusCode === (opts && opts.currentStatusCode));
               }).join('')
             : opt(h.currentStatusCode || '', h.currentStatusName || '—', true))
         + '</select>'
         + '<span class="tef-h">Only legal transitions are listed. Closing is done with '
         + 'Complete&nbsp;Task or Close&nbsp;Task.</span></label>');

    p.push('<label><span class="tef-l">Owner</span><select id="tefOwner">'
         + opt('', '— unassigned —', !h.assignedToEmployeeId)
         + employees.map(function (e) {
             return opt(e.employeeId, e.employeeName + (e.employeeCode ? ' (' + e.employeeCode + ')' : ''),
                        String(e.employeeId) === String(h.assignedToEmployeeId));
           }).join('')
         + '</select></label>');

    p.push('<label><span class="tef-l">Priority</span><select id="tefPriority"'
         + (canPriority && !prioPending ? '' : ' disabled') + '>'
         + ['Low', 'Medium', 'High', 'Critical'].map(function (v) {
             return opt(v, v, v === (h.priority || 'Medium'));
           }).join('')
         + '</select><span class="tef-h">'
         + (isChild
              ? 'Inherited from the parent (BRD §11).'
              : prioPending
                ? 'A reduction is already awaiting approval.'
                : 'Raising applies at once. <strong>Lowering needs approval and changes nothing until then.</strong>')
         + '</span></label>');

    p.push('<label><span class="tef-l">Due date</span>'
         + '<input type="date" id="tefDueAt" value="' + escape(dateVal(h.slaDueAt)) + '"'
         // 2026-10-26: the date the form opened with -- saveTaskEdit sends
         // the field only when it differs (see there).
         + ' data-initial="' + escape(dateVal(h.slaDueAt)) + '"'
         + (canDue && !slaPending ? '' : ' disabled') + ' />'
         + '<span class="tef-h">'
         + (isChild
              ? 'Runs within the parent’s SLA (BRD §11).'
              : slaPending
                ? 'An SLA extension is already awaiting approval.'
                : 'Moving it raises an <strong>SLA extension request</strong>; unchanged until approved.')
         + '</span></label>');

    p.push('<label><span class="tef-l">Start date</span>'
         + '<input type="date" id="tefStartDate" value="'
         + escape(dateVal(cur.startDate != null ? cur.startDate : h.startDate)) + '"'
         + ' data-initial="' + escape(dateVal(cur.startDate != null ? cur.startDate : h.startDate)) + '" /></label>');

    if (opts && opts.canEditMandatory) {
      p.push('<label class="tef-span2 tef-check">'
           + '<input type="checkbox" id="tefMandatory"' + (cur.isMandatoryChild ? ' checked' : '') + ' />'
           + '<span class="tef-h">Mandatory &mdash; the parent cannot be completed while this sub task is open (BRD &sect;12).</span>'
           + '</label>');
    }

    p.push('<label class="tef-span2"><span class="tef-l">Description</span>'
         + '<textarea id="tefDescription" maxlength="4000">' + escape(h.subjectDescription || '') + '</textarea></label>');

    p.push('<label><span class="tef-l">Reason for these changes</span>'
         + '<textarea id="tefReason" maxlength="1000" '
         + 'placeholder="Required when lowering priority or moving the due date — it is what the approver reads."></textarea></label>');

    p.push('</div>');
    p.push('<p id="tefMsg" style="margin:8px 0 0; font-size:12px;"></p>');
    p.push('<footer class="tef-actions">'
         + '<button type="button" class="pm-button" id="tefCancel">Cancel</button>'
         + '<button type="submit" class="pm-button primary"><i class="fa-solid fa-floppy-disk"></i> Save changes</button>'
         + '</footer>');
    p.push('</form>');

    bodyEl.innerHTML = p.join('');

    $('tefCancel').addEventListener('click', function () { openView(h.taskId); });
    $('taskEditForm').addEventListener('submit', function (ev) {
      ev.preventDefault();
      saveTaskEdit(h);
    });
  }

  async function saveTaskEdit(h) {
    var msg = $('tefMsg');
    var val = function (id) { var e = $(id); return e ? e.value : null; };
    var num = function (id) { var v = val(id); return v ? Number(v) : null; };
    var mand = $('tefMandatory');
    // 2026-10-26: the two date boxes show the DATE of a stored date-time
    // (a due date is usually end of day, 23:59:59). Sending the box back
    // unchanged made sp_task_update see a different value and treat an
    // untouched due date as an SLA extension that needs a reason. A date
    // is sent only when the user changed it; null = "no opinion".
    var changedDate = function (id) {
      var e = $(id); if (!e || !e.value) return null;
      return e.value !== (e.getAttribute('data-initial') || '') ? e.value : null;
    };

    var title = (val('tefTitle') || '').trim();
    if (!title) { msg.style.color = 'var(--danger-700)'; msg.textContent = 'Task name is required.'; return; }

    var body = {
      subjectTitle:         title,
      subjectDescription:   val('tefDescription'),
      assignedToEmployeeId: num('tefOwner'),
      priority:             val('tefPriority'),
      statusCode:           val('tefStatus'),
      startDate:            changedDate('tefStartDate'),
      dueAt:                changedDate('tefDueAt'),
      isMandatoryChild:     mand ? mand.checked : null,
      changeReason:         (val('tefReason') || '').trim() || null,
      expectedUpdatedDt:    (currentEditOptions && currentEditOptions.updatedDt) || null
    };

    msg.style.color = 'var(--fg-muted)';
    msg.textContent = 'Saving...';

    try {
      var r = await fetch(U('/practice/api/tasks/') + encodeURIComponent(h.taskId), {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin', body: JSON.stringify(body)
      });
      var b = await r.json().catch(function () { return {}; });

      if (!r.ok) {
        msg.style.color = 'var(--danger-700)';
        msg.textContent = (b.error || ('Save failed (HTTP ' + r.status + ')'))
                        + (b.reasonCode ? ' [' + b.reasonCode + ']' : '');
        return;
      }

      var changes = b.changes || [];
      if (!changes.length) {
        msg.style.color = 'var(--fg-muted)';
        msg.textContent = 'Nothing was different — no changes were recorded.';
        return;
      }

      await openView(h.taskId);
      renderSaveOutcome(changes);
      changed();
    } catch (err) {
      msg.style.color = 'var(--danger-700)';
      msg.textContent = 'Network error: ' + err.message;
    }
  }

  function renderSaveOutcome(changes) {
    var bodyEl = $('taskDetailBody');
    if (!bodyEl) return;
    var pending = changes.filter(function (c) { return c.outcome === 'PendingApproval'; });

    var rows = changes.map(function (c) {
      var isPend = c.outcome === 'PendingApproval';
      return '<li style="margin-bottom:3px;">'
           + '<strong>' + escape(c.fieldLabel) + ':</strong> '
           + escape(c.fromValue || '—') + ' → ' + escape(c.toValue || '—')
           + (isPend
               ? ' <span class="pm-badge" style="background:var(--warning-50); color:var(--warning-700);">awaiting approval</span>'
               : '')
           + (c.detail ? '<div style="font-size:11px; color:var(--fg-muted);">' + escape(c.detail) + '</div>' : '')
           + '</li>';
    }).join('');

    var box = document.createElement('div');
    box.style.cssText = 'border-radius:6px; padding:10px 12px; margin-bottom:12px; font-size:12px; '
                      + (pending.length
                          ? 'background:var(--warning-50); border:1px solid var(--warning-200); color:var(--warning-700);'
                          : 'background:var(--success-50); border:1px solid var(--success-200); color:var(--success-700);');
    box.innerHTML = '<div style="font-weight:700; margin-bottom:5px;">'
                  + (pending.length
                      ? 'Saved — but ' + pending.length + ' change'
                        + (pending.length === 1 ? '' : 's') + ' still need'
                        + (pending.length === 1 ? 's' : '') + ' approval'
                      : 'Saved')
                  + '</div><ul style="margin:0; padding-left:16px; list-style:disc;">' + rows + '</ul>';
    bodyEl.insertBefore(box, bodyEl.firstChild);
  }

  function detailField(label, value) {
    return '<div><div style="font-size:11px; color:var(--fg-muted); text-transform:uppercase; letter-spacing:.04em;">'
         + escape(label) + '</div><div style="font-weight:600; color:var(--fg-strong);">'
         + (value || '<span style="font-weight:400; color:var(--fg-subtle);">&mdash;</span>') + '</div></div>';
  }

  function renderTaskDetail(d) {
    var bodyEl = $('taskDetailBody');
    var h = d && d.header;
    if (!h) { bodyEl.innerHTML = '<p class="pm-empty">Task not found.</p>'; return; }

    $('taskDetailTitle').textContent = (h.taskNumber || ('Task #' + h.taskId)) + ' — ' + (h.subjectTitle || '');

    var editBtn = $('taskDetailEditBtn');
    if (editBtn) {
      var closed = !!h.closedAt || h.currentStatusCode === 'Closed' || h.currentStatusCode === 'Cancelled';
      editBtn.hidden = closed;
      editBtn.setAttribute('data-task-id', h.taskId);
      editBtn.title = closed ? 'A closed task cannot be edited.' : 'Edit this task';
    }

    var parts = [];

    parts.push('<div style="display:grid; grid-template-columns:repeat(3,1fr); gap:12px; margin-bottom:14px;">');
    parts.push(detailField('Type',     escape(h.taskTypeName || h.taskTypeCode)));
    parts.push(detailField('Status',   escape(h.currentStatusName || '')));
    parts.push(detailField('Priority', escape(h.priority || '')
               + (h.priorityChangeStatusCode === 'Pending'
                  ? ' <span class="pm-badge" style="background:var(--warning-50); color:var(--warning-700);">'
                    + escape(h.requestedPriority || '') + ' pending</span>' : '')));
    parts.push(detailField('Owner',    ownerCell(h)));
    parts.push(detailField('Origin',   h.sourceTypeCode
               ? escape(h.sourceTypeCode + ' #' + (h.sourceRecordId || '')) : ''));
    parts.push(detailField('Parent',   h.parentTaskId
               ? '<a href="#" data-open-task="' + escape(h.parentTaskId) + '">'
                 + escape(h.parentTaskNumber || ('#' + h.parentTaskId)) + '</a>' : ''));
    parts.push('</div>');

    parts.push('<div style="background:var(--neutral-50); border:1px solid var(--border); border-radius:6px; padding:10px 12px; margin-bottom:14px;">');
    parts.push('<div style="display:grid; grid-template-columns:repeat(4,1fr); gap:12px;">');
    parts.push(detailField('Standard SLA', h.standardSlaDays != null ? escape(h.standardSlaDays + ' days') : ''));
    parts.push(detailField('Standard Due', escape(fmtDate(h.standardDueAt))));
    parts.push(detailField('Approved Extended Due', escape(fmtDate(h.approvedExtendedDueAt))));
    parts.push(detailField('SLA Status', slaStatusBadge(h)));
    parts.push('</div>');
    if (h.extensionStatusCode === 'Pending') {
      parts.push('<div style="margin-top:8px; font-size:12px; color:var(--warning-700);">'
               + 'Extension to ' + escape(fmtDate(h.requestedDueAt))
               + ' is awaiting Exceptions &amp; Waivers approval. The due date is unchanged until then.'
               + '</div>');
    }
    if (h.slaSourceCode === 'TYPE_DEFAULT') {
      parts.push('<div style="margin-top:8px; font-size:12px; color:var(--fg-muted);">'
               + 'No organisation SLA policy matched this priority — the task-type default was used. '
               + 'Configure an SLA for this classification in Org SLA Configuration.'
               + '</div>');
    }
    parts.push('</div>');

    if (h.subjectDescription) {
      parts.push('<div style="margin-bottom:14px;"><div style="font-size:11px; color:var(--fg-muted); text-transform:uppercase; letter-spacing:.04em;">Action required</div>'
               + '<div style="white-space:pre-wrap; color:var(--fg-strong);">' + escape(h.subjectDescription) + '</div></div>');
    }

    var children = d.children || [];
    if (children.length) {
      parts.push('<h3 style="font-size:13px; margin:14px 0 6px;">Child tasks ('
               + children.length + ')</h3><div class="pm-table-wrap"><table><thead><tr>'
               + '<th>Task #</th><th>Activity</th><th>Owner</th><th>Mandatory</th><th>Target</th><th>Status</th>'
               + '</tr></thead><tbody>');
      for (var ci = 0; ci < children.length; ci++) {
        var c = children[ci];
        parts.push('<tr><td><a href="#" data-open-task="' + escape(c.taskId) + '">'
                 + escape(c.taskNumber || ('#' + c.taskId)) + '</a></td>'
                 + '<td>' + escape(c.subjectTitle) + '</td>'
                 + '<td>' + escape(c.assignedToEmployeeName || c.assignedToEmployeeId || '') + '</td>'
                 + '<td>' + (c.isMandatoryChild === false ? 'Optional' : 'Mandatory') + '</td>'
                 + '<td>' + escape(fmtDate(c.childTargetDate)) + '</td>'
                 + '<td>' + formatBadge(c.currentStatusName) + '</td></tr>');
      }
      parts.push('</tbody></table></div>');
      if (!h.isEligibleForCompletion && !h.closedAt) {
        parts.push('<p style="font-size:12px; color:var(--warning-700); margin:6px 0 0;">'
                 + escape(h.mandatoryChildOpenCount) + ' mandatory child task(s) still open — '
                 + 'the parent cannot be completed until they are done.</p>');
      }
    }

    var reqs = d.governanceRequests || [];
    if (reqs.length) {
      parts.push('<h3 style="font-size:13px; margin:14px 0 6px;">Exceptions &amp; Waivers requests</h3>'
               + '<div class="pm-table-wrap"><table><thead><tr>'
               + '<th>Type</th><th>Asked for</th><th>Status</th><th>Requested by</th><th>Decision</th>'
               + '</tr></thead><tbody>');
      for (var qi = 0; qi < reqs.length; qi++) {
        var q = reqs[qi];
        var asked = q.requestTypeCode === 'TASK_PRIORITY_REDUCTION'
            ? escape((q.priorityOriginal || '') + ' → ' + (q.priorityRequested || ''))
            : escape(fmtDate(q.dueAtOriginal) + ' → ' + fmtDate(q.dueAtRequested));
        parts.push('<tr><td>' + escape(q.requestTypeCode === 'TASK_PRIORITY_REDUCTION' ? 'Priority reduction' : 'SLA extension') + '</td>'
                 + '<td>' + asked + '</td>'
                 + '<td>' + formatBadge(q.statusCode) + '</td>'
                 + '<td>' + escape(q.requestedByName || '') + '</td>'
                 + '<td>' + escape(q.approvedByName || q.rejectedByName || '') + '</td></tr>');
      }
      parts.push('</tbody></table></div>');
    }

    parts.push(renderEvidenceList(d.attachments || [], { readOnly: true }));

    var acts = d.activity || [];
    parts.push('<h3 style="font-size:13px; margin:14px 0 6px;">Activity</h3>');
    if (!acts.length) {
      parts.push('<p style="color:var(--fg-subtle); font-size:12px;">No activity recorded yet.</p>');
    } else {
      parts.push('<ul style="list-style:none; margin:0; padding:0;">');
      for (var ai = 0; ai < acts.length; ai++) {
        var a = acts[ai];
        var change = (a.fromValue || a.toValue)
            ? ' <span style="color:var(--fg-muted);">' + escape(a.fromValue || '') + ' → ' + escape(a.toValue || '') + '</span>'
            : '';
        parts.push('<li style="border-left:2px solid var(--border); padding:4px 0 8px 10px; margin-bottom:2px;">'
                 + '<div style="font-size:12px; font-weight:600; color:var(--fg-strong);">'
                 + escape(a.activityTypeCode) + change + '</div>'
                 + (a.remark ? '<div style="font-size:12px; color:var(--neutral-700); white-space:pre-wrap;">' + escape(a.remark) + '</div>' : '')
                 + '<div style="font-size:11px; color:var(--fg-subtle);">'
                 + escape(a.actorDisplayName || 'system') + ' · ' + escape(fmtDate(a.enteredDt))
                 + '</div></li>');
      }
      parts.push('</ul>');
    }

    bodyEl.innerHTML = parts.join('');
    wireTaskDetailBody();
  }

  function wireTaskDetailBody() {
    var bodyEl = $('taskDetailBody');
    if (!bodyEl) return;
    bodyEl.querySelectorAll('[data-open-task]').forEach(function (a) {
      a.addEventListener('click', function (e) {
        e.preventDefault();
        openView(a.getAttribute('data-open-task'));
      });
    });
  }

  // ==== Evidence (BRD Sec16) ============================================
  function renderEvidenceList(files, opts) {
    opts = opts || {};
    var n = files.length;
    var p = [];

    if (!opts.compact) {
      p.push('<h3 style="font-size:13px; margin:14px 0 6px;">Evidence'
           + (n ? ' <span class="pm-badge" style="background:var(--neutral-200); color:var(--neutral-700);">' + n + '</span>' : '')
           + '</h3>');
    }

    if (!n) {
      p.push('<p style="color:var(--fg-subtle); font-size:12px; margin:0 0 8px;">No evidence uploaded.</p>');
      return p.join('');
    }

    p.push('<div style="border:1px solid var(--border); border-radius:6px; overflow:hidden; margin-bottom:10px;">');
    p.push('<table style="width:100%; border-collapse:collapse; font-size:12px;">');
    p.push('<thead><tr style="background:var(--neutral-50); color:var(--fg-muted);">'
         + '<th style="text-align:left; padding:5px 8px; font-weight:600;">File</th>'
         + '<th style="text-align:left; padding:5px 8px; font-weight:600;">Uploaded by</th>'
         + '<th style="text-align:left; padding:5px 8px; font-weight:600;">Uploaded</th>'
         + '<th style="text-align:right; padding:5px 8px; font-weight:600;">&nbsp;</th></tr></thead><tbody>');

    for (var fi = 0; fi < files.length; fi++) {
      var f = files[fi];
      var href = U('/practice/api/tasks/attachments/') + escape(f.taskAttachmentId);
      var kb   = Math.max(1, Math.round((f.fileSizeBytes || 0) / 1024));
      p.push('<tr style="border-top:1px solid var(--neutral-100);">'
           + '<td style="padding:5px 8px;">' + escape(f.fileName)
           + ' <span style="color:var(--fg-subtle);">(' + evidenceMeta(f, kb) + ')</span>'
           + (f.evidenceTitle && f.evidenceTitle !== f.fileName
               ? '<div style="color:var(--fg-muted); font-size:11px;">' + escape(f.evidenceTitle) + '</div>' : '')
           + (f.evidenceDescription
               ? '<div style="color:var(--fg-muted); font-size:11px;">' + escape(f.evidenceDescription) + '</div>' : '')
           + '</td>'
           + '<td style="padding:5px 8px;">' + escape(f.uploadedByName || '—') + '</td>'
           + '<td style="padding:5px 8px;">' + escape(fmtDate(f.uploadedDt)) + '</td>'
           + '<td style="padding:5px 8px; text-align:right;">'
           + '<a href="' + href + '" target="_blank" rel="noopener" class="pm-button" '
           + 'style="padding:2px 8px; font-size:11px;">View / Download</a></td>'
           + '</tr>');
    }
    p.push('</tbody></table></div>');
    return p.join('');
  }

  // 477: "(v2, 12 KB, for 2026-10-01)" -- the Evidence Center version the
  // task is pinned to and the period it was attached for, when present.
  function evidenceMeta(f, kb) {
    return [f.versionNo ? 'v' + f.versionNo : '', kb + ' KB',
            f.periodDate ? 'for ' + String(f.periodDate).substring(0, 10) : '']
      .filter(Boolean).map(escape).join(', ');
  }

  // 482: instanceEvidenceId = the recurring evidence row the file answers
  // (Complete Task); omitted = general task evidence, as before.
  // 499: metadata = the Evidence Center fields the shared upload dialog
  // collected. The endpoint is unchanged; 499 taught it and
  // sp_task_attachment_add to carry them to sp_evidence_item_store, so a
  // file attached while completing a task is described instead of blank.
  async function postEvidence(taskId, file, description, instanceEvidenceId, metadata) {
    var fd = new FormData();
    fd.append('file', file);
    if (description) fd.append('evidenceDescription', description);
    if (instanceEvidenceId) fd.append('instanceEvidenceId', String(instanceEvidenceId));
    if (metadata) {
      // evidenceItemDescription, not evidenceDescription: the latter is
      // this attachment's note on the task, the former is the Evidence
      // Center item's own description. The Api keeps them apart.
      if (metadata.evidenceTitle)       fd.append('evidenceTitle', metadata.evidenceTitle);
      if (metadata.evidenceTypeId)      fd.append('evidenceTypeId', String(metadata.evidenceTypeId));
      if (metadata.evidenceDescription) fd.append('evidenceItemDescription', metadata.evidenceDescription);
      if (metadata.ownerEmployeeId)     fd.append('ownerEmployeeId', String(metadata.ownerEmployeeId));
      if (metadata.validFrom)           fd.append('validFrom', metadata.validFrom);
      if (metadata.validTo)             fd.append('validTo', metadata.validTo);
      if (metadata.classification)      fd.append('classification', metadata.classification);
      if (metadata.tags)                fd.append('tags', metadata.tags);
    }
    try {
      var r = await fetch(U('/practice/api/tasks/') + encodeURIComponent(taskId) + '/attachments', {
        method: 'POST', credentials: 'same-origin', body: fd
      });
      if (r.ok) {
        // 477: says whether the file was stored or the identical one in
        // the Evidence Center linked instead.
        var ok = await r.json().catch(function () { return {}; });
        return { ok: true, message: ok.message || null };
      }
      var b = await r.json().catch(function () { return {}; });
      // b.title: an ASP.NET ProblemDetails (model-binding) 400 has no
      // "error" field -- show its title rather than only the status code.
      return { ok: false, error: b.error || b.title || ('Upload failed (HTTP ' + r.status + ')') };
    } catch (err) {
      return { ok: false, error: 'Network error: ' + err.message };
    }
  }

  // 499: Complete Task's Direct Upload. Opens the Evidence Center's own
  // Upload evidence form (Shared/evidence-upload.js) and stores the file
  // immediately, with everything the dialog captured -- instead of the
  // bare file picker that used to sit on the row and be swept up when the
  // task was completed. instanceEvidenceId null = general task evidence.
  //
  // Named apart from openEvidenceUpload below, which is this file's own
  // "Add evidence" dialog on a task and is not part of the completion flow.
  async function openEcUploadDialog(taskId, instanceEvidenceId, context, typeId) {
    if (!window.gracEvidenceUpload) return { ok: false, error: 'The upload dialog did not load. Refresh the page.' };

    var employees = [];
    try { employees = await fetchOrgEmployees(await taskOrganizationId(taskId)); }
    catch (err) { console.warn('[task-actions] employee list unavailable for the upload dialog', err); }

    var outcome = await window.gracEvidenceUpload.open({
      context: context || '',
      typeId:  typeId || '',
      // Evidence types are not loaded on this screen; the dropdown is
      // offered empty rather than wrong, and every other field still
      // reaches the Evidence Center.
      lookups: { types: [], employees: employees },
      submit:  function (payload) {
        return postEvidence(taskId, payload.file, null, instanceEvidenceId, payload.metadata)
          .then(function (r) { return { ok: r.ok, error: r.error, message: r.message }; });
      }
    });
    return outcome.saved ? { ok: true, message: outcome.message } : { ok: false, cancelled: true };
  }

  async function openEvidenceUpload(taskId, taskNumber) {
    var dlg = $('taskEvidenceDialog');
    if (!dlg) return;
    $('taskEvidenceSubject').textContent = taskNumber || ('#' + taskId);
    $('taskEvidenceFile').value = '';
    $('taskEvidenceDesc').value = '';
    $('taskEvidenceMsg').textContent = '';
    dlg.setAttribute('data-task-id', taskId);

    var listEl = $('taskEvidenceExisting');
    listEl.innerHTML = '<p style="color:var(--fg-subtle); font-size:12px; margin:0;">Loading…</p>';
    showDialog(dlg);
    try {
      var r = await fetch(U('/practice/api/tasks/') + encodeURIComponent(taskId), { credentials: 'same-origin' });
      var d = r.ok ? await r.json() : null;
      rememberTaskOrganization(taskId, d);
      listEl.innerHTML = renderEvidenceList((d && d.attachments) || [], { compact: true });
    } catch (_e) {
      listEl.innerHTML = '<p style="color:var(--fg-subtle); font-size:12px; margin:0;">Existing evidence could not be loaded.</p>';
    }
  }

  // ==== 477: Select from Evidence Center ==================================
  // The shared picker (Shared/evidence-picker.js). The API lists the
  // Evidence Center items the caller can see; one whose validity does not
  // cover the task's period is listed with the reason and cannot be linked.
  // A link keeps the version it was made with (a task completed for a
  // period keeps that file).
  var taskOrganizations = {};

  function rememberTaskOrganization(taskId, detail) {
    var h = detail && (detail.header || detail.Header);
    var org = h && (h.organizationId || h.OrganizationId);
    if (org) taskOrganizations[String(taskId)] = org;
  }

  async function taskOrganizationId(taskId) {
    if (taskOrganizations[String(taskId)]) return taskOrganizations[String(taskId)];
    try {
      var r = await fetch(U('/practice/api/tasks/') + encodeURIComponent(taskId), { credentials: 'same-origin' });
      rememberTaskOrganization(taskId, r.ok ? await r.json() : null);
    } catch (_e) { /* falls back below */ }
    return taskOrganizations[String(taskId)] || cfg.getOrganizationId() || null;
  }

  // Resolves to the success message, or null when nothing was linked.
  // 482: opts = { instanceEvidenceId, typeId, typeName } when the item
  // answers one recurring evidence row (Complete Task); omitted = general.
  async function pickFromEvidenceCenter(taskId, context, opts) {
    if (!window.gracEvidencePicker) return null;
    opts = opts || {};
    var orgId = await taskOrganizationId(taskId);
    if (!orgId) { alert('The organization of this task could not be determined.'); return null; }
    var base = U('/practice/api/tasks/') + encodeURIComponent(taskId);
    var outcome = await window.gracEvidencePicker.open({
      context: context || '',
      typeId:   opts.typeId   || null,
      typeName: opts.typeName || null,
      load: async function (q) {
        var qs = new URLSearchParams({ organizationId: orgId, pageNumber: q.pageNumber, pageSize: q.pageSize });
        if (q.search) qs.set('search', q.search);
        if (q.typeId) qs.set('evidenceTypeId', q.typeId);
        var r = await fetch(base + '/evidence-center?' + qs.toString(), { credentials: 'same-origin' });
        var b = await r.json().catch(function () { return {}; });
        return r.ok ? { ok: true, rows: b.data || [], totalRows: b.totalRows || 0 }
                    : { ok: false, error: b.error || b.title || ('Could not load the Evidence Center (HTTP ' + r.status + ').') };
      },
      link: async function (item) {
        var r = await fetch(base + '/evidence-links', {
          method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ organizationId: Number(orgId),
                                 evidenceItemId: Number(item.evidenceItemId || item.EvidenceItemId),
                                 instanceEvidenceId: opts.instanceEvidenceId ? Number(opts.instanceEvidenceId) : null })
        });
        var b = await r.json().catch(function () { return {}; });
        return r.ok ? { ok: true, message: b.message }
                    : { ok: false, error: b.error || b.title || ('Could not link the evidence (HTTP ' + r.status + ').') };
      }
    });
    return outcome && outcome.linked ? (outcome.message || 'Evidence linked.') : null;
  }

  async function pickFromEvidenceDialog() {
    var dlg    = $('taskEvidenceDialog');
    var taskId = dlg.getAttribute('data-task-id');
    var linked = await pickFromEvidenceCenter(taskId, $('taskEvidenceSubject').textContent);
    if (!linked) return;
    hideDialog(dlg);
    openView(taskId);
    changed();
  }

  async function pickFromCompleteDialog() {
    var dlg    = $('taskCompleteDialog');
    var taskId = dlg.getAttribute('data-task-id');
    var msg    = $('taskCompleteMsg');
    var linked = await pickFromEvidenceCenter(taskId, $('taskCompleteSubject').textContent);
    if (!linked) return;
    msg.style.color = 'var(--success-700)';
    msg.textContent = linked;
    await refreshCompleteEvidence(taskId);
  }

  async function submitEvidenceUpload(ev) {
    ev.preventDefault();
    var dlg    = $('taskEvidenceDialog');
    var taskId = dlg.getAttribute('data-task-id');
    var input  = $('taskEvidenceFile');
    var msg    = $('taskEvidenceMsg');
    msg.style.color = 'var(--danger-700)';
    msg.textContent = '';

    if (!input.files || !input.files.length) { msg.textContent = 'Choose a file first.'; return; }

    msg.style.color = 'var(--fg-muted)';
    msg.textContent = 'Uploading…';
    var res = await postEvidence(taskId, input.files[0],
                                   $('taskEvidenceDesc').value.trim() || null);
    if (!res.ok) { msg.style.color = 'var(--danger-700)'; msg.textContent = res.error; return; }

    hideDialog(dlg);
    openView(taskId);
    changed();
  }

  // ==== Complete / Close -- workflow actions, each with its own gate ===
  async function postTaskAction(taskId, path, payload, okMessage) {
    try {
      var r = await fetch(U('/practice/api/tasks/') + encodeURIComponent(taskId) + path, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin', body: JSON.stringify(payload || {})
      });
      var b = await r.json().catch(function () { return {}; });
      if (r.ok) {
        if (okMessage) alert(typeof okMessage === 'function' ? okMessage(b) : okMessage);
        changed();
        return true;
      }
      alert((b.error || 'Request failed') + (b.reasonCode ? '\n[' + b.reasonCode + ']' : ''));
      return false;
    } catch (err) {
      alert('Network error: ' + err.message);
      return false;
    }
  }

  // pageOpts.host === "page" -> rendered inline on task-complete.cshtml;
  // Cancel and a successful completion go back to pageOpts.backUrl. The
  // page knows only the id, so the subject is filled from the task itself.
  async function openComplete(taskId, taskNumber, taskTitle, pageOpts) {
    var dlg = $('taskCompleteDialog');
    if (!dlg) return;
    if (pageOpts && pageOpts.host === 'page') {
      pageMode = true;
      pageDialogId = 'taskCompleteDialog';
      pageBackUrl = pageOpts.backUrl || U('/Practice/Index/tasks');
    }
    $('taskCompleteSubject').textContent = taskNumber
      ? taskNumber + (taskTitle ? ' — ' + taskTitle : '')
      : 'Task #' + taskId;
    $('taskCompleteRemark').value = '';
    $('taskCompleteMsg').textContent = '';
    // 499: the general evidence picker became a dialog button; nothing to reset.
    dlg.setAttribute('data-task-id', taskId);

    // 482: a fresh dialog forgets choices made for another task.
    completeRecurring = { taskId: String(taskId), rows: [], state: {}, generalStored: null, general: null };
    renderCompleteRecurring([]);
    renderCompleteGeneral();
    refreshCompleteEvidence(taskId);

    var gate = $('taskCompleteGate');
    gate.style.display = 'none';
    try {
      var r = await fetch(U('/practice/api/tasks/') + encodeURIComponent(taskId) + '/eligibility',
                            { credentials: 'same-origin' });
      if (r.ok) {
        var el = await r.json();
        if (el && el.isEligible === false) {
          gate.style.cssText = 'display:block; font-size:12px; border-radius:5px; padding:8px 10px; '
                             + 'margin-bottom:10px; background:var(--warning-50); border:1px solid var(--warning-200); color:var(--danger-700);';
          gate.textContent = el.reason || 'Mandatory sub tasks are still open (BRD §12).';
        } else if (el && el.mandatoryChildCount > 0) {
          gate.style.cssText = 'display:block; font-size:12px; border-radius:5px; padding:8px 10px; '
                             + 'margin-bottom:10px; background:var(--success-50); border:1px solid var(--success-200); color:var(--success-700);';
          gate.textContent = 'All ' + el.mandatoryChildCount
                           + ' mandatory sub task(s) are complete. Confirm the overall objective is achieved.';
        }
      }
    } catch (_e) { /* the server still enforces it on submit */ }

    showDialog(dlg);
  }

  async function refreshCompleteEvidence(taskId) {
    var el = $('taskCompleteEvidence');
    if (!el) return;
    el.innerHTML = '<p style="color:var(--fg-subtle); font-size:12px; margin:0;">Loading…</p>';
    try {
      var r = await fetch(U('/practice/api/tasks/') + encodeURIComponent(taskId), { credentials: 'same-origin' });
      var d = r.ok ? await r.json() : null;
      rememberTaskOrganization(taskId, d);
      // Full page: the subject comes from the task (the page has only its id).
      var hh = d && (d.header || d.Header);
      if (hh && hh.taskNumber && $('taskCompleteSubject').textContent === 'Task #' + taskId)
        $('taskCompleteSubject').textContent = hh.taskNumber + (hh.subjectTitle ? ' — ' + hh.subjectTitle : '');
      var files = (d && d.attachments) || [];
      // 482: a file that answers a recurring evidence row is listed under
      // that row; this list keeps the general task evidence.
      el.innerHTML = renderEvidenceList(files.filter(function (f) { return !f.instanceEvidenceId; }), { compact: true });
      await loadCompleteRecurring(taskId);
      renderCompleteRecurring(files);
      renderCompleteGeneral();   // 483
    } catch (_e) {
      el.innerHTML = '<p style="color:var(--fg-subtle); font-size:12px; margin:0;">Evidence could not be loaded.</p>';
    }
  }

  // ==== 482: recurring evidence on Complete Task ==========================
  // The recurring evidence of a scheduled task's obligation (481 took it
  // off Operationalize). Each row asks how it is provided -- the shared
  // Shared/evidence-source.js options -- and shows only that option's
  // control. Nothing is required. A chosen file and an external reference
  // are saved by Complete task (saveCompleteRecurring); Select from
  // Evidence Center links at once, like the dialog's own picker.
  var completeRecurring = { taskId: null, rows: [], state: {}, generalStored: null, general: null };
  var rv = function (o, k) {   // rows arrive with PascalCase keys (column-name rows)
    if (!o) return null;
    var v = o[k] !== undefined ? o[k] : o[k.charAt(0).toLowerCase() + k.slice(1)];
    return v === undefined ? null : v;
  };

  async function loadCompleteRecurring(taskId) {
    var rows = [], general = null;
    try {
      var orgId = await taskOrganizationId(taskId);
      if (orgId) {
        var r = await fetch(U('/practice/api/tasks/') + encodeURIComponent(taskId)
                            + '/recurring-evidence?organizationId=' + encodeURIComponent(orgId),
                            { credentials: 'same-origin' });
        var b = r.ok ? await r.json().catch(function () { return {}; }) : {};
        rows = b.data || [];
        general = b.general || null;   // 483
      }
    } catch (_e) { rows = []; }
    if (completeRecurring.taskId !== String(taskId))
      completeRecurring = { taskId: String(taskId), rows: [], state: {}, generalStored: null, general: null };
    completeRecurring.rows = rows;
    completeRecurring.generalStored = general;
  }

  // ==== 483: the same three options for the dialog's general evidence ====
  // Direct Upload (Attach) and Select from Evidence Center keep their own
  // immediate buttons; External is held here and saved with the
  // recurring rows by saveCompleteRecurring (an item with no evidenceId).
  function generalState() {
    var S = window.gracEvidenceSource;
    if (!completeRecurring.general) {
      var stored = completeRecurring.generalStored;
      var src = stored ? rv(stored, 'EvidenceSource') : null;
      completeRecurring.general = {
        source:   S && S.isKnown(src) ? src : (S ? S.DEFAULT : 'DirectUpload'),
        location: (stored && rv(stored, 'EvidenceLocation')) || '',
        locator:  (stored && rv(stored, 'EvidenceLocator'))  || '',
        touched:  false
      };
    }
    return completeRecurring.general;
  }

  function renderCompleteGeneral() {
    var S = window.gracEvidenceSource;
    var host = $('taskCompleteGeneralSource');
    if (!S || !host) return;
    // A stored choice that arrived after the dialog opened replaces the
    // default, unless the operator has already changed something.
    if (completeRecurring.general && !completeRecurring.general.touched && completeRecurring.generalStored)
      completeRecurring.general = null;
    var st = generalState();
    host.innerHTML = S.radios('taskGenSrc', st.source, { 'data-gen-source': '1' });
    $('taskCompleteGenLocation').value = st.location;
    $('taskCompleteGenLocator').value  = st.locator;
    S.showPanels($('taskCompleteGeneral'), st.source);
    host.querySelector('[data-gen-source]').addEventListener('change', function (ev) {
      if (!ev.target.matches('input[type="radio"]')) return;
      var g = generalState();
      g.source = ev.target.value; g.touched = true;
      S.showPanels($('taskCompleteGeneral'), g.source);
    });
  }

  // What the operator has chosen / typed and not saved yet wins over what
  // is stored, so a refresh after a link keeps it.
  function recurringStateOf(row) {
    var S = window.gracEvidenceSource;
    var id = String(rv(row, 'EvidenceId'));
    var st = completeRecurring.state[id];
    if (!st) {
      var stored = rv(row, 'EvidenceSource');
      st = completeRecurring.state[id] = {
        source:   S && S.isKnown(stored) ? stored : (S ? S.DEFAULT : 'DirectUpload'),
        location: rv(row, 'EvidenceLocation') || '',
        locator:  rv(row, 'EvidenceLocator')  || '',
        touched:  false
      };
    }
    return st;
  }

  function renderCompleteRecurring(files) {
    var wrap = $('taskCompleteRecurringWrap');
    var host = $('taskCompleteRecurring');
    var label = $('taskCompleteEvidenceLabel');
    var S = window.gracEvidenceSource;
    if (!wrap || !host) return;
    var rows = completeRecurring.rows || [];
    if (!rows.length || !S) {
      wrap.style.display = 'none';
      host.innerHTML = '';
      if (label) label.textContent = 'Evidence';
      return;
    }
    wrap.style.display = 'block';
    if (label) label.textContent = 'Other evidence';

    host.innerHTML = rows.map(function (row) {
      var id  = String(rv(row, 'EvidenceId'));
      var st  = recurringStateOf(row);
      var mine = (files || []).filter(function (f) { return String(f.instanceEvidenceId || '') === id; });
      var type = rv(row, 'EvidenceType');
      var name = rv(row, 'EvidenceName') || type || 'Evidence';
      var sub  = [rv(row, 'ObligationName'), rv(row, 'EvidenceDescription')].filter(Boolean).map(escape).join(' &middot; ');
      return '<div class="tce-row" data-rec-ev="' + escape(id) + '">'
           + '<div style="font-size:12px; font-weight:600;">' + escape(name)
           + (type && type !== name ? ' ' + formatBadge(type) : '')
           + (rv(row, 'IsProvided') ? ' <span class="pm-badge" style="background:var(--success-50); color:var(--success-700);">Provided</span>' : '')
           + '</div>'
           + (sub ? '<div style="font-size:11px; color:var(--fg-muted);">' + sub + '</div>' : '')
           + S.radios('taskRecSrc-' + id, st.source, { 'data-rec-source': id })
           // The chosen File is held in the row's state, so a redraw
           // (after a link elsewhere in the dialog) does not lose it.
           // 499: the dialog stores the file when it is submitted, so there
           // is no chosen-but-unattached file to carry to task completion.
           + S.panel('DirectUpload', st.source,
               '<button type="button" class="pm-button" data-rec-upload="' + escape(id) + '" style="padding:3px 10px; font-size:12px;"'
               + ' title="Upload a file and describe it for the Evidence Center in one step.">'
               + '<i class="fa-solid fa-upload" aria-hidden="true"></i> Upload evidence</button>'
               + '<span data-rec-file-name="' + escape(id) + '" style="display:block; font-size:11px; color:var(--fg-muted);"></span>')
           + S.panel('EvidenceCenter', st.source,
               '<button type="button" class="pm-button" data-rec-pick="' + escape(id) + '" style="padding:3px 10px; font-size:12px;"'
               + ' title="Link evidence already uploaded to the Evidence Center. It must be valid for this task\'s period.">'
               + '<i class="fa-solid fa-box-archive" aria-hidden="true"></i> Select from Evidence Center</button>')
           + S.panel('External', st.source,
               '<div style="display:flex; gap:8px; flex-wrap:wrap;">'
               + '<label style="flex:1 1 180px; font-size:12px;">Location'
               + '<input class="pm-input" type="text" maxlength="500" data-rec-location="' + escape(id) + '" value="' + escape(st.location)
               + '" placeholder="Where it is kept" style="width:100%; font-size:13px;" /></label>'
               + '<label style="flex:1 1 180px; font-size:12px;">Locator'
               + '<input class="pm-input" type="text" maxlength="500" data-rec-locator="' + escape(id) + '" value="' + escape(st.locator)
               + '" placeholder="Path, link or reference" style="width:100%; font-size:13px;" /></label>'
               + '</div>')
           + S.panel('DirectUpload EvidenceCenter', st.source,
               mine.length ? renderEvidenceList(mine, { compact: true }) : '')
           + '</div>';
    }).join('');

    host.querySelectorAll('[data-rec-source]').forEach(function (group) {
      group.addEventListener('change', function (ev) {
        if (!ev.target.matches('input[type="radio"]')) return;
        var st = completeRecurring.state[group.getAttribute('data-rec-source')];
        if (st) { st.source = ev.target.value; st.touched = true; }
        S.showPanels(group.closest('[data-rec-ev]'), ev.target.value);
      });
    });
    host.querySelectorAll('[data-rec-location], [data-rec-locator]').forEach(function (input) {
      input.addEventListener('change', function () {
        var isLoc = input.hasAttribute('data-rec-location');
        var st = completeRecurring.state[input.getAttribute(isLoc ? 'data-rec-location' : 'data-rec-locator')];
        if (!st) return;
        if (isLoc) st.location = input.value; else st.locator = input.value;
        st.touched = true;
      });
    });
    // 499: Direct Upload opens the shared Evidence Center form and stores
    // the file there and then; the row only reports what happened.
    host.querySelectorAll('[data-rec-upload]').forEach(function (b) {
      b.addEventListener('click', async function () {
        var id = b.getAttribute('data-rec-upload');
        var st = completeRecurring.state[id];
        var row = (completeRecurring.rows || []).filter(function (r) {
          return String(rv(r, 'EvidenceId')) === String(id);
        })[0];
        var note = host.querySelector('[data-rec-file-name="' + id + '"]');
        var res = await openEcUploadDialog(
          completeRecurring.taskId, Number(id),
          row ? ('Evidence: ' + (rv(row, 'EvidenceName') || rv(row, 'EvidenceType') || '')) : '',
          row ? rv(row, 'EvidenceTypeId') : '');
        if (res.cancelled) return;
        if (note) note.textContent = res.ok ? (res.message || 'Attached.') : res.error;
        if (res.ok && st) st.touched = true;
        if (res.ok) await refreshCompleteEvidence(completeRecurring.taskId);
      });
    });
    host.querySelectorAll('[data-rec-pick]').forEach(function (b) {
      b.addEventListener('click', function () { pickRecurringFromEvidenceCenter(b.getAttribute('data-rec-pick')); });
    });
  }

  async function pickRecurringFromEvidenceCenter(evidenceId) {
    var dlg    = $('taskCompleteDialog');
    var taskId = dlg.getAttribute('data-task-id');
    var msg    = $('taskCompleteMsg');
    var row = (completeRecurring.rows || []).filter(function (x) { return String(rv(x, 'EvidenceId')) === String(evidenceId); })[0];
    var st  = completeRecurring.state[String(evidenceId)];
    var linked = await pickFromEvidenceCenter(taskId,
        row ? 'Evidence: ' + (rv(row, 'EvidenceName') || rv(row, 'EvidenceType') || '') : $('taskCompleteSubject').textContent,
        { instanceEvidenceId: evidenceId,
          typeId:   row ? rv(row, 'EvidenceTypeId') : null,
          typeName: row ? rv(row, 'EvidenceType')   : null });
    if (!linked) return;
    if (st) st.touched = true;   // the option is recorded with the task's completion
    msg.style.color = 'var(--success-700)';
    msg.textContent = linked;
    await refreshCompleteEvidence(taskId);
  }

  // Uploads the files chosen under Direct Upload, then records the option
  // (and the external reference) of every row the operator touched.
  // Returns { ok, error }. Nothing chosen = nothing to do.
  async function saveCompleteRecurring(taskId) {
    var rows = completeRecurring.rows || [];
    if (completeRecurring.taskId !== String(taskId)) return { ok: true };
    var items = [];
    for (var i = 0; i < rows.length; i++) {
      var id = String(rv(rows[i], 'EvidenceId'));
      var st = completeRecurring.state[id];
      if (!st) continue;
      // 499: nothing to attach here. Direct Upload is a dialog that stores
      // the file on submit, so a file can no longer be held on the row
      // waiting for this moment.
      if (st.touched) {
        items.push({ evidenceId: Number(id), evidenceSource: st.source,
                     evidenceLocation: st.source === 'External' ? (st.location || null) : null,
                     evidenceLocator:  st.source === 'External' ? (st.locator  || null) : null });
      }
    }
    // 483: the general evidence's option (and, for External, its reference).
    // 2026-10-23: its Direct Upload file is attached here too (no Attach
    // button any more), as general task evidence.
    var g = generalState();
    // 499: the general evidence file is uploaded by the dialog too.
    if (g.touched) {
      items.push({ evidenceId: null, evidenceSource: g.source,
                   evidenceLocation: g.source === 'External' ? (g.location || null) : null,
                   evidenceLocator:  g.source === 'External' ? (g.locator  || null) : null });
    }
    if (!items.length) return { ok: true };
    try {
      var orgId = await taskOrganizationId(taskId);
      var r = await fetch(U('/practice/api/tasks/') + encodeURIComponent(taskId) + '/recurring-evidence', {
        method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ organizationId: Number(orgId), items: items })
      });
      if (r.ok) return { ok: true };
      var b = await r.json().catch(function () { return {}; });
      return { ok: false, error: b.error || b.title || ('The evidence details could not be saved (HTTP ' + r.status + ').') };
    } catch (err) {
      return { ok: false, error: 'Network error: ' + err.message };
    }
  }

  async function submitCompleteTask(ev) {
    ev.preventDefault();
    var dlg    = $('taskCompleteDialog');
    var taskId = dlg.getAttribute('data-task-id');
    var msg    = $('taskCompleteMsg');
    msg.textContent = '';

    // 482: the recurring evidence chosen in the dialog goes first, so the
    // task completes with it. Optional -- an empty dialog saves nothing.
    msg.style.color = 'var(--fg-muted)';
    var saved = await saveCompleteRecurring(taskId);
    msg.style.color = 'var(--danger-700)';
    if (!saved.ok) { msg.textContent = saved.error + ' The task was not completed.'; return; }

    var ok = await postTaskAction(taskId, '/complete',
        { completionRemark: $('taskCompleteRemark').value.trim() || null }, null);
    if (ok) hideDialog(dlg);
    else    msg.textContent = 'The task was not completed — see the message above.';
  }

  async function openClose(taskId, taskNumber, taskTitle) {
    var dlg = $('taskCloseDialog');
    if (!dlg) return;
    $('taskCloseSubject').textContent = taskNumber + (taskTitle ? ' — ' + taskTitle : '');
    $('taskCloseReason').value = '';
    $('taskCloseMsg').textContent = '';
    dlg.setAttribute('data-task-id', taskId);

    var warn = $('taskCloseWarn');
    warn.style.display = 'none';
    try {
      var r = await fetch(U('/practice/api/tasks/') + encodeURIComponent(taskId) + '/eligibility',
                            { credentials: 'same-origin' });
      if (r.ok) {
        var el = await r.json();
        if (el && el.mandatoryChildOpenCount > 0) {
          warn.style.display = 'block';
          warn.innerHTML = '<strong>' + el.mandatoryChildOpenCount + ' mandatory sub task(s) are still open.</strong> '
                         + 'Closing shuts this task without completing it and does not wait for them. '
                         + 'If the work was actually done, use <em>Complete Task</em> instead.';
        }
      }
    } catch (_e) { /* advisory only */ }

    showDialog(dlg);
  }

  async function submitCloseTask(ev) {
    ev.preventDefault();
    var dlg    = $('taskCloseDialog');
    var taskId = dlg.getAttribute('data-task-id');
    var msg    = $('taskCloseMsg');
    var reason = $('taskCloseReason').value.trim();
    msg.textContent = '';
    if (!reason) { msg.textContent = 'A reason is required to close a task without completing it.'; return; }

    var ok = await postTaskAction(taskId, '/close',
        { reasonCode: 'MANUAL_CLOSE', reasonText: reason }, null);
    if (ok) hideDialog(dlg);
    else    msg.textContent = 'The task was not closed — see the message above.';
  }

  async function openReopen(taskId, taskNumber, taskTitle) {
    var dlg = $('taskReopenDialog');
    if (!dlg) return;
    $('taskReopenSubject').textContent = taskNumber + (taskTitle ? ' — ' + taskTitle : '');
    $('taskReopenReason').value = '';
    $('taskReopenMsg').textContent = '';
    var warn = $('taskReopenWarn');
    if (warn) warn.style.display = 'none';
    dlg.setAttribute('data-task-id', taskId);
    showDialog(dlg);
  }

  async function submitReopen(ev) {
    ev.preventDefault();
    var dlg    = $('taskReopenDialog');
    var taskId = dlg.getAttribute('data-task-id');
    var msg    = $('taskReopenMsg');
    var reason = $('taskReopenReason').value.trim();
    msg.textContent = '';
    if (!reason) { msg.textContent = 'A reason is required to reopen a closed task.'; return; }

    var ok = await postTaskAction(taskId, '/reopen',
        { reasonText: reason }, null);
    if (ok) hideDialog(dlg);
    else    msg.textContent = 'The task was not reopened — see the message above.';
  }

  // ==== Add Update / Comment ==========================================
  async function openAddUpdate(taskId) {
    var remark = await window.gracUi.prompt('Add an update or comment to this task.',
        { title: 'Task #' + taskId, inputLabel: 'Update', confirmText: 'Add update',
          multiline: true, rows: 7, wide: true });
    if (!remark || !remark.trim()) return;
    await postTaskAction(taskId, '/activity',
        { activityTypeCode: 'Update', remark: remark.trim() }, null);
  }

  // ==== wiring / init ==================================================
  function wire() {
    if (wired) return;
    wired = true;

    var dlg = $('taskDetailDialog');
    if (dlg) {
      var closeB = $('taskDetailClose');
      if (closeB) closeB.addEventListener('click', function () { hideDialog(dlg); });

      var editB = $('taskDetailEditBtn');
      if (editB) editB.addEventListener('click', function () {
        var id = editB.getAttribute('data-task-id');
        if (id) openEdit(id);
      });

      dlg.addEventListener('click', function (e) {
        if (e.target !== dlg) return;
        if ($('taskEditForm')) return;
        hideDialog(dlg);
      });

      dlg.addEventListener('cancel', function (e) {
        if (!$('taskEditForm')) return;
        e.preventDefault();
        var id = currentTaskDetail && currentTaskDetail.header && currentTaskDetail.header.taskId;
        if (id) openView(id);
      });
    }

    var cDlg = $('taskCompleteDialog');
    var xDlg = $('taskCloseDialog');
    var cFrm = $('taskCompleteForm');
    var xFrm = $('taskCloseForm');
    if (cFrm) cFrm.addEventListener('submit', submitCompleteTask);
    if (xFrm) xFrm.addEventListener('submit', submitCloseTask);
    document.querySelectorAll('[data-close-task-complete]').forEach(function (b) {
      b.addEventListener('click', function () { hideDialog(cDlg); });
    });
    document.querySelectorAll('[data-close-task-close]').forEach(function (b) {
      b.addEventListener('click', function () { hideDialog(xDlg); });
    });

    var rDlg = $('taskReopenDialog');
    var rFrm = $('taskReopenForm');
    if (rFrm) rFrm.addEventListener('submit', submitReopen);
    document.querySelectorAll('[data-close-task-reopen]').forEach(function (b) {
      b.addEventListener('click', function () { hideDialog(rDlg); });
    });

    var eDlg = $('taskEvidenceDialog');
    var eFrm = $('taskEvidenceForm');
    if (eFrm) eFrm.addEventListener('submit', submitEvidenceUpload);
    document.querySelectorAll('[data-close-task-evidence]').forEach(function (b) {
      b.addEventListener('click', function () { hideDialog(eDlg); });
    });
    // 483: the general evidence's external reference (saved on Complete).
    ['taskCompleteGenLocation', 'taskCompleteGenLocator'].forEach(function (fid) {
      var inp = $(fid);
      if (!inp) return;
      inp.addEventListener('change', function () {
        var g = generalState();
        if (fid === 'taskCompleteGenLocation') g.location = inp.value; else g.locator = inp.value;
        g.touched = true;
      });
    });
    // 499: general task evidence, Direct Upload -> the shared dialog.
    var cUp = $('taskCompleteUpload');
    if (cUp) cUp.addEventListener('click', async function () {
      var dlg = $('taskCompleteDialog');
      var taskId = completeRecurring.taskId || (dlg && dlg.getAttribute('data-task-id'));
      if (!taskId) return;
      var note = $('taskCompleteUploadNote');
      var res  = await openEcUploadDialog(taskId, null, 'General task evidence', '');
      if (res.cancelled) return;
      if (note) note.textContent = res.ok ? (res.message || 'Attached.') : res.error;
      if (res.ok) {
        generalState().touched = true;
        await refreshCompleteEvidence(taskId);
      }
    });
    // 477
    var cPick = $('taskCompletePick');
    if (cPick) cPick.addEventListener('click', pickFromCompleteDialog);
    var ePick = $('taskEvidencePick');
    if (ePick) ePick.addEventListener('click', pickFromEvidenceDialog);
  }

  function init(options) {
    cfg = Object.assign({ getOrganizationId: function () { return null; }, onChanged: function () {} }, options || {});
    wire();
  }

  window.gracTaskActions = {
    init: init,
    FLAGS: FLAGS,
    buildMenu: buildMenu,
    openView: openView,
    openEdit: openEdit,
    openComplete: openComplete,
    openClose: openClose,
    openReopen: openReopen,
    openEvidenceUpload: openEvidenceUpload,
    openAddUpdate: openAddUpdate,
    postTaskAction: postTaskAction
  };
})();
