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
        ? '<div style="font-size:11px; color:#64748b;">' + escape(ownerSourceLabel(r.ownerSourceCode)) + '</div>'
        : '';
      return escape(r.assignedToEmployeeName) + src;
    }
    if (r.assignedToEmployeeId) return escape(r.assignedToEmployeeId);
    return '<span style="color:#b45309;">Unassigned</span>';
  }
  var SLA_BADGE_STYLE = {
    OnTrack:   { bg: '#dcfce7', fg: '#166534', label: 'On Track'  },
    DueSoon:   { bg: '#fef9c3', fg: '#854d0e', label: 'Due Soon'  },
    DueToday:  { bg: '#ffedd5', fg: '#9a3412', label: 'Due Today' },
    Breached:  { bg: '#fee2e2', fg: '#991b1b', label: 'Breached'  },
    Extended:  { bg: '#e0e7ff', fg: '#3730a3', label: 'Extended'  },
    Completed: { bg: '#f1f5f9', fg: '#475569', label: 'Completed' },
    NotSet:    { bg: '#f1f5f9', fg: '#64748b', label: 'No SLA'    }
  };
  function slaStatusBadge(r) {
    var code = r.slaStatusCode;
    if (!code) return r.isOverdue ? '<span class="pm-badge">Breached</span>' : '';
    var s = SLA_BADGE_STYLE[code] || { bg: '#f1f5f9', fg: '#475569', label: code };
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
        label: fields.taskType === 'Custom' ? 'Close / Inactivate' : 'Close Task',
        applicable: !fields.isTerminal && fields.taskType !== 'Assurance',
        action: handlers.onClose });
    }
    return items;
  }

  // ---- module state (the dialogs this drives) --------------------------
  var cfg = { getOrganizationId: function () { return null; }, onChanged: function () {} };
  var wired = false;
  var currentTaskDetail  = null;
  var currentEditOptions = null;

  function changed() {
    try { cfg.onChanged && cfg.onChanged(); } catch (err) { console.error('[grac-task-actions] onChanged handler failed', err); }
  }

  function showDialog(dlg) {
    if (!dlg) return;
    if (dlg.open) return;
    if (typeof dlg.showModal === 'function') dlg.showModal();
    else { dlg.setAttribute('open', 'open'); dlg.style.display = 'block'; }
  }
  function hideDialog(dlg) {
    if (!dlg) return;
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

  async function openEdit(taskId) {
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

    var employees = await fetchOrgEmployees(cfg.getOrganizationId());
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
         + escape(dateVal(cur.startDate != null ? cur.startDate : h.startDate)) + '" /></label>');

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

    var title = (val('tefTitle') || '').trim();
    if (!title) { msg.style.color = '#b91c1c'; msg.textContent = 'Task name is required.'; return; }

    var body = {
      subjectTitle:         title,
      subjectDescription:   val('tefDescription'),
      assignedToEmployeeId: num('tefOwner'),
      priority:             val('tefPriority'),
      statusCode:           val('tefStatus'),
      startDate:            val('tefStartDate') || null,
      dueAt:                val('tefDueAt') || null,
      isMandatoryChild:     mand ? mand.checked : null,
      changeReason:         (val('tefReason') || '').trim() || null,
      expectedUpdatedDt:    (currentEditOptions && currentEditOptions.updatedDt) || null
    };

    msg.style.color = '#64748b';
    msg.textContent = 'Saving...';

    try {
      var r = await fetch(U('/practice/api/tasks/') + encodeURIComponent(h.taskId), {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin', body: JSON.stringify(body)
      });
      var b = await r.json().catch(function () { return {}; });

      if (!r.ok) {
        msg.style.color = '#b91c1c';
        msg.textContent = (b.error || ('Save failed (HTTP ' + r.status + ')'))
                        + (b.reasonCode ? ' [' + b.reasonCode + ']' : '');
        return;
      }

      var changes = b.changes || [];
      if (!changes.length) {
        msg.style.color = '#64748b';
        msg.textContent = 'Nothing was different — no changes were recorded.';
        return;
      }

      await openView(h.taskId);
      renderSaveOutcome(changes);
      changed();
    } catch (err) {
      msg.style.color = '#b91c1c';
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
               ? ' <span class="pm-badge" style="background:#fef9c3; color:#854d0e;">awaiting approval</span>'
               : '')
           + (c.detail ? '<div style="font-size:11px; color:#64748b;">' + escape(c.detail) + '</div>' : '')
           + '</li>';
    }).join('');

    var box = document.createElement('div');
    box.style.cssText = 'border-radius:6px; padding:10px 12px; margin-bottom:12px; font-size:12px; '
                      + (pending.length
                          ? 'background:#fffbeb; border:1px solid #fcd34d; color:#78350f;'
                          : 'background:#f0fdf4; border:1px solid #86efac; color:#14532d;');
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
    return '<div><div style="font-size:11px; color:#64748b; text-transform:uppercase; letter-spacing:.04em;">'
         + escape(label) + '</div><div style="font-weight:600; color:#0f172a;">'
         + (value || '<span style="font-weight:400; color:#94a3b8;">&mdash;</span>') + '</div></div>';
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
                  ? ' <span class="pm-badge" style="background:#fef9c3; color:#854d0e;">'
                    + escape(h.requestedPriority || '') + ' pending</span>' : '')));
    parts.push(detailField('Owner',    ownerCell(h)));
    parts.push(detailField('Origin',   h.sourceTypeCode
               ? escape(h.sourceTypeCode + ' #' + (h.sourceRecordId || '')) : ''));
    parts.push(detailField('Parent',   h.parentTaskId
               ? '<a href="#" data-open-task="' + escape(h.parentTaskId) + '">'
                 + escape(h.parentTaskNumber || ('#' + h.parentTaskId)) + '</a>' : ''));
    parts.push('</div>');

    parts.push('<div style="background:#f8fafc; border:1px solid #e2e8f0; border-radius:6px; padding:10px 12px; margin-bottom:14px;">');
    parts.push('<div style="display:grid; grid-template-columns:repeat(4,1fr); gap:12px;">');
    parts.push(detailField('Standard SLA', h.standardSlaDays != null ? escape(h.standardSlaDays + ' days') : ''));
    parts.push(detailField('Standard Due', escape(fmtDate(h.standardDueAt))));
    parts.push(detailField('Approved Extended Due', escape(fmtDate(h.approvedExtendedDueAt))));
    parts.push(detailField('SLA Status', slaStatusBadge(h)));
    parts.push('</div>');
    if (h.extensionStatusCode === 'Pending') {
      parts.push('<div style="margin-top:8px; font-size:12px; color:#854d0e;">'
               + 'Extension to ' + escape(fmtDate(h.requestedDueAt))
               + ' is awaiting Exception Centre approval. The due date is unchanged until then.'
               + '</div>');
    }
    if (h.slaSourceCode === 'TYPE_DEFAULT') {
      parts.push('<div style="margin-top:8px; font-size:12px; color:#64748b;">'
               + 'No organisation SLA policy matched this priority — the task-type default was used. '
               + 'Configure an SLA for this classification in Org SLA Configuration.'
               + '</div>');
    }
    parts.push('</div>');

    if (h.subjectDescription) {
      parts.push('<div style="margin-bottom:14px;"><div style="font-size:11px; color:#64748b; text-transform:uppercase; letter-spacing:.04em;">Action required</div>'
               + '<div style="white-space:pre-wrap; color:#0f172a;">' + escape(h.subjectDescription) + '</div></div>');
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
        parts.push('<p style="font-size:12px; color:#854d0e; margin:6px 0 0;">'
                 + escape(h.mandatoryChildOpenCount) + ' mandatory child task(s) still open — '
                 + 'the parent cannot be completed until they are done.</p>');
      }
    }

    var reqs = d.governanceRequests || [];
    if (reqs.length) {
      parts.push('<h3 style="font-size:13px; margin:14px 0 6px;">Exception Centre requests</h3>'
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
      parts.push('<p style="color:#94a3b8; font-size:12px;">No activity recorded yet.</p>');
    } else {
      parts.push('<ul style="list-style:none; margin:0; padding:0;">');
      for (var ai = 0; ai < acts.length; ai++) {
        var a = acts[ai];
        var change = (a.fromValue || a.toValue)
            ? ' <span style="color:#64748b;">' + escape(a.fromValue || '') + ' → ' + escape(a.toValue || '') + '</span>'
            : '';
        parts.push('<li style="border-left:2px solid #e2e8f0; padding:4px 0 8px 10px; margin-bottom:2px;">'
                 + '<div style="font-size:12px; font-weight:600; color:#0f172a;">'
                 + escape(a.activityTypeCode) + change + '</div>'
                 + (a.remark ? '<div style="font-size:12px; color:#334155; white-space:pre-wrap;">' + escape(a.remark) + '</div>' : '')
                 + '<div style="font-size:11px; color:#94a3b8;">'
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
           + (n ? ' <span class="pm-badge" style="background:#e2e8f0; color:#334155;">' + n + '</span>' : '')
           + '</h3>');
    }

    if (!n) {
      p.push('<p style="color:#94a3b8; font-size:12px; margin:0 0 8px;">No evidence uploaded.</p>');
      return p.join('');
    }

    p.push('<div style="border:1px solid #e2e8f0; border-radius:6px; overflow:hidden; margin-bottom:10px;">');
    p.push('<table style="width:100%; border-collapse:collapse; font-size:12px;">');
    p.push('<thead><tr style="background:#f8fafc; color:#64748b;">'
         + '<th style="text-align:left; padding:5px 8px; font-weight:600;">File</th>'
         + '<th style="text-align:left; padding:5px 8px; font-weight:600;">Uploaded by</th>'
         + '<th style="text-align:left; padding:5px 8px; font-weight:600;">Uploaded</th>'
         + '<th style="text-align:right; padding:5px 8px; font-weight:600;">&nbsp;</th></tr></thead><tbody>');

    for (var fi = 0; fi < files.length; fi++) {
      var f = files[fi];
      var href = U('/practice/api/tasks/attachments/') + escape(f.taskAttachmentId);
      var kb   = Math.max(1, Math.round((f.fileSizeBytes || 0) / 1024));
      p.push('<tr style="border-top:1px solid #f1f5f9;">'
           + '<td style="padding:5px 8px;">' + escape(f.fileName)
           + ' <span style="color:#94a3b8;">(' + kb + ' KB)</span>'
           + (f.evidenceDescription
               ? '<div style="color:#64748b; font-size:11px;">' + escape(f.evidenceDescription) + '</div>' : '')
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

  async function postEvidence(taskId, file, description) {
    var fd = new FormData();
    fd.append('file', file);
    if (description) fd.append('evidenceDescription', description);
    try {
      var r = await fetch(U('/practice/api/tasks/') + encodeURIComponent(taskId) + '/attachments', {
        method: 'POST', credentials: 'same-origin', body: fd
      });
      if (r.ok) return { ok: true };
      var b = await r.json().catch(function () { return {}; });
      return { ok: false, error: b.error || ('Upload failed (HTTP ' + r.status + ')') };
    } catch (err) {
      return { ok: false, error: 'Network error: ' + err.message };
    }
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
    listEl.innerHTML = '<p style="color:#94a3b8; font-size:12px; margin:0;">Loading…</p>';
    showDialog(dlg);
    try {
      var r = await fetch(U('/practice/api/tasks/') + encodeURIComponent(taskId), { credentials: 'same-origin' });
      var d = r.ok ? await r.json() : null;
      listEl.innerHTML = renderEvidenceList((d && d.attachments) || [], { compact: true });
    } catch (_e) {
      listEl.innerHTML = '<p style="color:#94a3b8; font-size:12px; margin:0;">Existing evidence could not be loaded.</p>';
    }
  }

  async function submitEvidenceUpload(ev) {
    ev.preventDefault();
    var dlg    = $('taskEvidenceDialog');
    var taskId = dlg.getAttribute('data-task-id');
    var input  = $('taskEvidenceFile');
    var msg    = $('taskEvidenceMsg');
    msg.style.color = '#b91c1c';
    msg.textContent = '';

    if (!input.files || !input.files.length) { msg.textContent = 'Choose a file first.'; return; }

    msg.style.color = '#64748b';
    msg.textContent = 'Uploading…';
    var res = await postEvidence(taskId, input.files[0],
                                   $('taskEvidenceDesc').value.trim() || null);
    if (!res.ok) { msg.style.color = '#b91c1c'; msg.textContent = res.error; return; }

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

  async function openComplete(taskId, taskNumber, taskTitle) {
    var dlg = $('taskCompleteDialog');
    if (!dlg) return;
    $('taskCompleteSubject').textContent = taskNumber + (taskTitle ? ' — ' + taskTitle : '');
    $('taskCompleteRemark').value = '';
    $('taskCompleteMsg').textContent = '';
    $('taskCompleteFile').value = '';
    dlg.setAttribute('data-task-id', taskId);

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
                             + 'margin-bottom:10px; background:#fffaf0; border:1px solid #fbd38d; color:#7b341e;';
          gate.textContent = el.reason || 'Mandatory sub tasks are still open (BRD §12).';
        } else if (el && el.mandatoryChildCount > 0) {
          gate.style.cssText = 'display:block; font-size:12px; border-radius:5px; padding:8px 10px; '
                             + 'margin-bottom:10px; background:#f0fff4; border:1px solid #9ae6b4; color:#22543d;';
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
    el.innerHTML = '<p style="color:#94a3b8; font-size:12px; margin:0;">Loading…</p>';
    try {
      var r = await fetch(U('/practice/api/tasks/') + encodeURIComponent(taskId), { credentials: 'same-origin' });
      var d = r.ok ? await r.json() : null;
      el.innerHTML = renderEvidenceList((d && d.attachments) || [], { compact: true });
    } catch (_e) {
      el.innerHTML = '<p style="color:#94a3b8; font-size:12px; margin:0;">Evidence could not be loaded.</p>';
    }
  }

  async function attachFromCompleteDialog() {
    var dlg    = $('taskCompleteDialog');
    var taskId = dlg.getAttribute('data-task-id');
    var input  = $('taskCompleteFile');
    var msg    = $('taskCompleteMsg');
    msg.style.color = '#b91c1c';
    if (!input.files || !input.files.length) { msg.textContent = 'Choose a file to attach.'; return; }

    msg.style.color = '#64748b';
    msg.textContent = 'Uploading evidence…';
    var res = await postEvidence(taskId, input.files[0], null);
    if (!res.ok) { msg.style.color = '#b91c1c'; msg.textContent = res.error; return; }

    input.value = '';
    msg.style.color = '#166534';
    msg.textContent = 'Evidence attached.';
    await refreshCompleteEvidence(taskId);
  }

  async function submitCompleteTask(ev) {
    ev.preventDefault();
    var dlg    = $('taskCompleteDialog');
    var taskId = dlg.getAttribute('data-task-id');
    var msg    = $('taskCompleteMsg');
    msg.textContent = '';

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

  // ==== Add Update / Comment ==========================================
  async function openAddUpdate(taskId) {
    var remark = await window.gracUi.prompt('Add an update or comment to this task.',
        { title: 'Task #' + taskId, inputLabel: 'Update', confirmText: 'Add update' });
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

    var eDlg = $('taskEvidenceDialog');
    var eFrm = $('taskEvidenceForm');
    if (eFrm) eFrm.addEventListener('submit', submitEvidenceUpload);
    document.querySelectorAll('[data-close-task-evidence]').forEach(function (b) {
      b.addEventListener('click', function () { hideDialog(eDlg); });
    });
    var cAttach = $('taskCompleteAttach');
    if (cAttach) cAttach.addEventListener('click', attachFromCompleteDialog);
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
    openEvidenceUpload: openEvidenceUpload,
    openAddUpdate: openAddUpdate,
    postTaskAction: postTaskAction
  };
})();
