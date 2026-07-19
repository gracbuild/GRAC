/*
 * practice-instance-implementation-task.js  (Q13/Q14/Q15)
 *
 * Adds an "Add Implementation Task" affordance to the Practice Instances
 * screen. Non-intrusive — does not modify the existing practice.js grid
 * rendering. Two entry points:
 *   1. A header button next to "Add New Instance" that opens the modal.
 *   2. A MutationObserver that decorates any grid row whose
 *      ImplementationStatus text is "Not Implemented" with a small
 *      "Add Implementation Task" link inside the row's action cell.
 *
 * Both entry points show the same modal. Modal payload is POSTed to
 *   /practice/api/instances/{id}/open-implementation-task
 * which proxies to the Api tier.
 */
(function () {
    'use strict';

    if (!window.pmScreen || window.pmScreen.Key !== 'practice-instances') return;

    var modal        = document.getElementById('implTaskModal');
    if (!modal) return;   // partial not on this page
    var closeBtn     = document.getElementById('implTaskClose');
    var cancelBtn    = document.getElementById('implTaskCancel');
    var form         = document.getElementById('implTaskForm');
    var msg          = document.getElementById('implTaskMessage');
    var selInstance  = document.getElementById('implTaskInstance');
    var inName       = document.getElementById('implTaskName');
    var inDesc       = document.getElementById('implTaskDescription');
    var inAssignee   = document.getElementById('implTaskAssignee');
    var inTarget     = document.getElementById('implTaskTargetDate');
    var inPriority   = document.getElementById('implTaskPriority');
    var inRemarks    = document.getElementById('implTaskRemarks');
    var submitBtn    = document.getElementById('implTaskSubmit');

    // Cache of "Not Implemented" instances scraped from the grid so the
    // dropdown can be populated without an extra API call. Structured as
    // { id: string, label: string }.
    var notImplementedInstances = [];

    function openModal(prefillInstanceId) {
        rebuildInstanceOptions();
        if (prefillInstanceId) selInstance.value = String(prefillInstanceId);
        setMessage(null);
        inName.value = '';
        inDesc.value = '';
        inAssignee.value = '';
        inTarget.value = '';
        inPriority.value = 'Medium';
        inRemarks.value = '';
        modal.hidden = false;
        setTimeout(function () { inName.focus(); }, 40);
    }

    function closeModal() {
        modal.hidden = true;
    }

    function setMessage(text, kind) {
        if (!msg) return;
        if (!text) { msg.hidden = true; msg.textContent = ''; msg.className = 'pm-form-message'; return; }
        msg.hidden = false;
        msg.textContent = text;
        msg.className = 'pm-form-message ' + (kind === 'error' ? 'pm-form-message-error' : 'pm-form-message-ok');
    }

    function rebuildInstanceOptions() {
        selInstance.innerHTML = '';
        if (notImplementedInstances.length === 0) {
            var opt = document.createElement('option');
            opt.value = '';
            opt.textContent = 'No Practice Instances currently marked Not Implemented';
            opt.disabled = true;
            selInstance.appendChild(opt);
            submitBtn.disabled = true;
            return;
        }
        submitBtn.disabled = false;
        for (var i = 0; i < notImplementedInstances.length; i++) {
            var row = notImplementedInstances[i];
            var opt = document.createElement('option');
            opt.value = row.id;
            opt.textContent = row.label;
            selInstance.appendChild(opt);
        }
    }

    // Scrape the currently rendered grid for rows whose ImplementationStatus
    // text is "Not Implemented" and decorate them with an inline link.
    function refreshFromGrid() {
        notImplementedInstances = [];
        var table = document.querySelector('table');
        if (!table) return;

        // Locate the ImplementationStatus column by its header.
        var headers = table.querySelectorAll('thead th');
        var statusColIndex = -1, idColIndex = -1, nameColIndex = -1, codeColIndex = -1;
        for (var i = 0; i < headers.length; i++) {
            var txt = (headers[i].textContent || '').trim().toLowerCase();
            if (txt === 'implementationstatus' || txt === 'implementation status') statusColIndex = i;
            if (txt === 'id' || txt === 'practiceinstanceid') idColIndex = i;
            if (txt === 'name' || txt === 'instancename' || txt === 'instance') nameColIndex = i;
            if (txt === 'code' || txt === 'instancecode') codeColIndex = i;
        }
        if (statusColIndex === -1) return;

        var rows = table.querySelectorAll('tbody tr');
        rows.forEach(function (tr) {
            var cells = tr.children;
            if (!cells || cells.length <= statusColIndex) return;
            var statusText = (cells[statusColIndex].textContent || '').trim();
            if (statusText !== 'Not Implemented' && statusText !== 'Not Started') return;

            // Try to resolve the instance id from a data-* attribute or from
            // a visible id/code column.
            var id = tr.getAttribute('data-id') || tr.getAttribute('data-instance-id');
            if (!id && idColIndex !== -1) id = (cells[idColIndex].textContent || '').trim();
            var label = '';
            if (codeColIndex !== -1) label += (cells[codeColIndex].textContent || '').trim() + ' — ';
            if (nameColIndex !== -1) label += (cells[nameColIndex].textContent || '').trim();
            if (!label) label = 'Instance ' + (id || '?');
            if (!id) return;

            notImplementedInstances.push({ id: id, label: label });

            // Decorate the row with a link if not already there.
            if (!tr.querySelector('.pm-impl-task-link')) {
                var link = document.createElement('a');
                link.href = '#';
                link.className = 'pm-impl-task-link';
                link.style.marginLeft = '8px';
                link.textContent = 'Add Implementation Task';
                link.setAttribute('data-instance-id', id);
                link.addEventListener('click', function (e) {
                    e.preventDefault();
                    openModal(this.getAttribute('data-instance-id'));
                });
                var actionCell = cells[cells.length - 1];
                if (actionCell) actionCell.appendChild(link);
            }
        });
    }

    // Header button — visible whenever Practice Instances screen is showing.
    function injectHeaderButton() {
        if (document.getElementById('addImplTaskHeaderBtn')) return;
        var actions = document.querySelector('.pm-page-heading .pm-actions');
        if (!actions) return;
        var btn = document.createElement('button');
        btn.type = 'button';
        btn.id = 'addImplTaskHeaderBtn';
        btn.className = 'pm-button';
        btn.innerHTML = '<i class="fa-solid fa-list-check" aria-hidden="true"></i> Add Implementation Task';
        btn.addEventListener('click', function () {
            refreshFromGrid();
            openModal();
        });
        actions.appendChild(btn);
    }

    // Modal wiring.
    if (closeBtn)  closeBtn.addEventListener('click', closeModal);
    if (cancelBtn) cancelBtn.addEventListener('click', closeModal);
    modal.addEventListener('click', function (e) {
        if (e.target === modal) closeModal();
    });

    form.addEventListener('submit', async function (e) {
        e.preventDefault();
        var id = selInstance.value;
        if (!id) { setMessage('Select a Practice Instance.', 'error'); return; }
        if (!inName.value.trim()) { setMessage('Task Name is required.', 'error'); return; }

        submitBtn.disabled = true;
        setMessage('Saving…', 'ok');

        var payload = {
            subjectTitle:       inName.value.trim(),
            subjectDescription: inDesc.value.trim() || null,
            assignedToEmployeeId: inAssignee.value ? Number(inAssignee.value) : null,
            targetDate:         inTarget.value ? new Date(inTarget.value + 'T00:00:00Z').toISOString() : null,
            priority:           inPriority.value,
            remarks:            inRemarks.value.trim() || null
        };
        try {
            var resp = await fetch('/practice/api/instances/' + encodeURIComponent(id) + '/open-implementation-task', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                credentials: 'same-origin',
                body: JSON.stringify(payload)
            });
            var body = await resp.json().catch(function () { return {}; });
            if (resp.ok) {
                setMessage('Task #' + (body.taskId || '?') + ' created. Visible under Task Center.', 'ok');
                setTimeout(closeModal, 1200);
            } else {
                setMessage((body.error || 'Failed') + (body.reasonCode ? ' [' + body.reasonCode + ']' : ''), 'error');
            }
        } catch (err) {
            setMessage('Network error: ' + err.message, 'error');
        } finally {
            submitBtn.disabled = false;
        }
    });

    // Bootstrap on DOMContentLoaded and re-run refresh when the grid changes.
    document.addEventListener('DOMContentLoaded', function () {
        injectHeaderButton();
        refreshFromGrid();
        var mainRoot = document.querySelector('main') || document.body;
        var mo = new MutationObserver(function () {
            injectHeaderButton();  // header may render lazily
            refreshFromGrid();
        });
        mo.observe(mainRoot, { childList: true, subtree: true });
    });
})();
