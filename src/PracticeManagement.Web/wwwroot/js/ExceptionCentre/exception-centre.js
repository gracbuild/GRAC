// =====================================================================
// Exception Centre -- list + approve + reject (Phase 1).
// Loaded by Views/Practice/Partials/exception-centre.cshtml.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/exception-centre";

  const state = {
    organizationId: null,
    // All statuses by default. Defaulting to Pending made a request
    // vanish from the grid the moment it was submitted for approval —
    // the row moves to SubmittedForApproval, which the filter excluded,
    // so the analyst saw "No Pending exception requests" and assumed the
    // submission had failed. The filter still narrows on demand.
    statusCode: null,
    // Migration 184: tab selection. GAP_CANDIDATE = classical
    // exception request (approve requires effective_until + note; reject
    // auto-raises a risk). SLA_CANDIDATE = SLA-override request from a
    // gap (approve applies the days to the gap; reject is neutral).
    requestType: "GAP_CANDIDATE",
    // activeRequest, evidenceTypesCache, frequenciesCache removed (change
    // request, 2026-09-22): those existed only for the Approve/Reject
    // dialogs, which now live entirely in Shared/exception-actions.js
    // (window.gracExceptionActions) -- see that file's own header
    // comment. exceptionTypesCache/employeesCache/practicesCache stay:
    // Add Custom Exception still uses them.
    exceptionTypesCache: [],
    employeesCache: [],
    practicesCache: []
  };

  // pm-grid handle. sp_exception_request_list has paged at 25 since 193,
  // but this screen sent no page parameter, so request 26 onwards could
  // not be reached. null when pm-grid.js has not loaded; every use is
  // optional-chained, so the list still fetches its first page.
  let pager = null;

  // Migration 328 -- the Add Custom Exception dialog's own Practice
  // Picker. One instance, attached once and reset() between opens --
  // the same singleton pattern Risk Centre's own mapPicker uses for its
  // Map Practice dialog. addCustomPractices is the running "Add to
  // list" result: {practiceId, practiceName} entries, in add order, no
  // duplicates by practiceId.
  let addCustomPicker = null;
  let addCustomPractices = [];

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    if (!document.getElementById("excListView")) return;
    document.getElementById("excListView").hidden = false;
    bindEvents();
    // Shared Approve/Reject dialogs + row-menu actions (change request,
    // 2026-09-22) -- see Shared/exception-actions.js's own header
    // comment. onChanged: refresh mirrors what onApproveSubmit/
    // onRejectSubmit/onApproveSlaQuick used to do inline.
    if (window.gracExceptionActions) window.gracExceptionActions.init({ onChanged: refresh });
    await populateOrgFilter();
    const sel = document.getElementById("excFilterOrganization");
    if (sel.options.length > 1 && !state.organizationId) {
      sel.selectedIndex = 1;
      state.organizationId = Number(sel.value) || null;
      if (state.organizationId) await refresh();
    }
  }

  function bindEvents() {
    // Mounted before the first refresh() so the very first fetch already
    // carries a page number. reset(true) is silent -- it moves the pager
    // without firing onChange -- because refresh() is called right after.
    pager = window.__pmGrid ? window.__pmGrid.attach({
      hostId:   "excPager",
      onChange: refresh          // refetch -- never slice locally
    }) : null;

    document.getElementById("excFilterOrganization").addEventListener("change", e => {
      state.organizationId = e.target.value ? Number(e.target.value) : null;
      // Org-scoped combos must reload for the new org.
      state.employeesCache = [];
      state.practicesCache = [];
      // A different organisation is a different data set.
      pager?.reset(true);
      refresh();
    });
    document.getElementById("excFilterStatus").addEventListener("change", e => {
      state.statusCode = e.target.value || null;
      pager?.reset(true);
      refresh();
    });
    // Refresh is NOT a filter change: it re-reads the page the user is
    // on, so it must not reset.
    document.getElementById("excRefreshBtn").addEventListener("click", refresh);
    document.getElementById("excExpireDueBtn").addEventListener("click", onExpireDue);

    // Migration 255 -- the 184 tab switcher is replaced by a Type filter.
    // Same state field, same query parameter; only the control changed,
    // so the fetch, the grid and the per-row approve routing below are
    // untouched. An empty value means "all types", which the two tabs
    // could never express.
    const typeSel = document.getElementById("excFilterType");
    if (typeSel) {
      state.requestType = typeSel.value || null;
      typeSel.addEventListener("change", e => {
        state.requestType = e.target.value || null;
        pager?.reset(true);
        refresh();
      });
    }

    // Approve/Reject form submits, their close buttons, the Approve
    // form's own Reject hand-off button, and the evidence-method toggle
    // are now wired by window.gracExceptionActions.init() (called from
    // init() above) -- see Shared/exception-actions.js's own wire().

    // Migration 327 -- "+ Add Custom Exception."
    const addCustomBtn = document.getElementById("excAddCustomBtn");
    if (addCustomBtn) addCustomBtn.addEventListener("click", openAddCustomDialog);
    document.querySelectorAll("[data-close-exc-add-custom]").forEach(el =>
      el.addEventListener("click", () => hide("excAddCustomModal")));
    const addCustomForm = document.getElementById("excAddCustomForm");
    if (addCustomForm) addCustomForm.addEventListener("submit", onAddCustomSubmit);

    // Migration 329 -- "Add a practice" opens the picker in its own popup
    // (#newExcPracticeModal) instead of the picker sitting inline in the
    // form; the actual add-to-list happens on the popup's own Confirm
    // button, which closes the popup afterward -- the same shape Risk
    // Centre's own "Map a practice" dialog uses for #riskMapPickerConfirm.
    const addCustomPracticeBtn = document.getElementById("newExcPracticeAddBtn");
    if (addCustomPracticeBtn) addCustomPracticeBtn.addEventListener("click", openAddCustomPracticeDialog);
    document.querySelectorAll("[data-close-exc-practice]").forEach(el =>
      el.addEventListener("click", closeAddCustomPracticeDialog));
    const addCustomPracticeConfirm = document.getElementById("newExcPracticeConfirm");
    if (addCustomPracticeConfirm) addCustomPracticeConfirm.addEventListener("click", onAddCustomPracticeConfirm);
    // Delegated: the list's own remove buttons are re-rendered on every
    // add/remove, so a direct listener would need rebinding each time.
    const addCustomPracticeList = document.getElementById("newExcPracticeList");
    if (addCustomPracticeList) addCustomPracticeList.addEventListener("click", ev => {
      const btn = ev.target.closest("[data-remove-practice]");
      if (!btn) return;
      const removeId = Number(btn.dataset.removePractice);
      addCustomPractices = addCustomPractices.filter(p => p.practiceId !== removeId);
      renderAddCustomPracticeList();
    });
  }

  async function onExpireDue() {
    if (!await window.gracUi.confirm(
          "Expire all Approved exceptions whose Valid Until date has passed?",
          { type: "warning", title: "Expire due exceptions", confirmText: "Expire" })) return;
    try {
      const r = await fetch(U(`${base}/expire-due`), {
        method: "POST", credentials: "same-origin",
        headers: { "Content-Type": "application/json" }, body: JSON.stringify({})
      });
      const b = await r.json().catch(() => ({}));
      if (!r.ok || b.success === false) {
        alert("Expire failed: " + (b.error || `HTTP ${r.status}`));
        return;
      }
      alert(`Expired ${b.expiredCount ?? 0} exception(s).`);
      await refresh();
    } catch (err) { alert("Network error: " + err.message); }
  }

  // Migration 257: the next three loaders fill combos that lived on the
  // Approve modal's "Request details" block, which moved to the analysis
  // page. Nothing calls them now. Kept -- with their populate* guards
  // already returning early when the element is absent -- because the
  // approve form may yet need a read-only lookup, and deleting a working
  // fetch is easier than writing it again.
  async function loadExceptionTypes() {
    if (state.exceptionTypesCache.length) { populateExceptionTypeSelect(); return; }
    try {
      const r = await fetch(U(`${base}/lookups/exception-types`), { credentials: "same-origin" });
      state.exceptionTypesCache = r.ok ? (await r.json()) || [] : [];
    } catch (_) { state.exceptionTypesCache = []; }
    populateExceptionTypeSelect();
  }
  function populateExceptionTypeSelect() { renderExceptionTypeOptions("excApproveType", "-- select --"); }

  // 327: the Add Custom Exception dialog's own Exception Type field.
  function renderExceptionTypeOptions(selectId, placeholder) {
    const sel = document.getElementById(selectId);
    if (!sel) return;
    sel.innerHTML = `<option value="">${placeholder}</option>`;
    state.exceptionTypesCache.forEach(t => {
      const o = document.createElement("option");
      o.value = t.exceptionTypeCode;
      o.textContent = t.exceptionTypeName;
      sel.appendChild(o);
    });
  }

  async function loadEmployees() {
    if (state.employeesCache.length || !state.organizationId) { populateOwnerSelect(); return; }
    try {
      const r = await fetch(U(`/practice/api/document-uploads/lookups/employees?organizationId=${state.organizationId}`),
        { credentials: "same-origin" });
      state.employeesCache = r.ok ? (await r.json()) || [] : [];
    } catch (_) { state.employeesCache = []; }
    populateOwnerSelect();
  }
  function populateOwnerSelect() { renderEmployeeOptions("excApproveOwner", "-- unassigned --"); }

  // 327: the Add Custom Exception dialog needs this same org-scoped
  // employee list for two selects (Owner, Requested By). Pulled out of
  // populateOwnerSelect so every select renders off the one cache and
  // markup instead of a third copy.
  function renderEmployeeOptions(selectId, placeholder) {
    const sel = document.getElementById(selectId);
    if (!sel) return;
    sel.innerHTML = `<option value="">${placeholder}</option>`;
    state.employeesCache.forEach(e => {
      const o = document.createElement("option");
      o.value = e.employeeId;
      o.textContent = e.employeeName + (e.employeeCode ? ` (${e.employeeCode})` : "");
      sel.appendChild(o);
    });
  }

  // Like loadExceptionTypes/loadEmployees above: nothing calls this now.
  // 327 added it for the Add Custom Exception dialog's flat Related
  // Practice select; 328 replaced that select with the cascading
  // Practice Picker (see openAddCustomDialog), so this flat org-wide
  // list is unused again. Kept dormant for the same reason as the two
  // lookups above it -- the Approve modal's excApproveLinkedPracticeId
  // combo may yet want a read-only render of it.
  async function loadPractices() {
    if (state.practicesCache.length || !state.organizationId) { populatePracticeSelect(); return; }
    try {
      const r = await fetch(U(`${base}/lookups/practices?organizationId=${state.organizationId}`),
        { credentials: "same-origin" });
      state.practicesCache = r.ok ? (await r.json()) || [] : [];
    } catch (_) { state.practicesCache = []; }
    populatePracticeSelect();
  }
  function populatePracticeSelect() { renderPracticeOptions("excApproveLinkedPracticeId", "-- select --"); }

  function renderPracticeOptions(selectId, placeholder) {
    const sel = document.getElementById(selectId);
    if (!sel) return;
    sel.innerHTML = `<option value="">${placeholder}</option>`;
    state.practicesCache.forEach(p => {
      const o = document.createElement("option");
      o.value = p.practiceId;
      // Show code + name so the reviewer recognises the practice quickly.
      o.textContent = (p.practiceCode ? `${p.practiceCode} — ` : "") + p.practiceName;
      sel.appendChild(o);
    });
  }

  // loadFrequencies/populateFrequencySelect/loadEvidenceTypes removed
  // (change request, 2026-09-22): they filled fields that only ever
  // existed on the Approve modal, which now lives entirely in the
  // shared partial + Shared/exception-actions.js, which carries its own
  // copies (its own header comment explains why they are duplicated
  // rather than exported from here).

  async function populateOrgFilter() {
    const sel = document.getElementById("excFilterOrganization");
    let rows = [];
    try {
      const r = await fetch(U("/practice/api/organizations/allowed"), { credentials: "same-origin" });
      if (r.ok) { const b = await r.json(); rows = (b && (b.data || b.Data)) || []; }
    } catch (_) {}
    rows.forEach(row => {
      const value = String(row.organizationId ?? row.OrganizationId ?? "");
      const label = String(row.organizationName ?? row.OrganizationName ?? "");
      if (!value) return;
      const opt = document.createElement("option");
      opt.value = value; opt.textContent = label;
      sel.appendChild(opt);
    });
    if (sel.options.length === 2) sel.disabled = true;
  }

  async function refresh() {
    const tbody = document.getElementById("excTableBody");
    if (!state.organizationId) {
      pager?.clear();
      tbody.innerHTML = `<tr><td colspan="7" class="pm-empty-row">Select an organization.</td></tr>`;
      return;
    }
    tbody.innerHTML = `<tr><td colspan="7" class="pm-empty-row">Loading...</td></tr>`;
    const qs = new URLSearchParams({ organizationId: state.organizationId });
    if (state.statusCode)  qs.set("statusCode",  state.statusCode);
    if (state.requestType) qs.set("requestType", state.requestType);
    // The endpoint's parameter is "page", not "pageNumber".
    if (pager) {
      qs.set("page",     pager.page());
      qs.set("pageSize", pager.size());
    }
    const data = await apiGet(`?${qs}`);
    const rows = data?.rows || [];
    // Row count as well as the total, so a short last page reads
    // "26-31 of 31" rather than assuming every page is full.
    pager?.setTotal(data?.totalRows, rows.length);
    if (!rows.length) {
      // No status filter now means "all", so the label must not leave a
      // double space where the status word used to sit.
      const scope = state.statusCode ? `${escapeHtml(state.statusCode)} ` : "";
      tbody.innerHTML = `<tr><td colspan="7" class="pm-empty-row">
        No ${scope}exception requests.</td></tr>`;
      return;
    }
    tbody.innerHTML = "";
    rows.forEach(r => {
      const tr = document.createElement("tr");
      // Row click-to-View (change request, 2026-09-22): "View" is
      // unconditional on every exception request (buildMenu()'s own
      // onView item carries no applicable/disabled gate beyond a valid
      // id, which every real row has), so every row gets it -- see
      // wireRowMenu() below for the click itself.
      tr.className = "pm-row-clickable";
      const chip = statusChip(r.statusCode);
      const effective = formatEffective(r);
      tr.innerHTML = `
        <td>${escapeHtml(displayRequestTitle(r.requestTitle))}</td>
        <td>${window.gracFormatDisplayDate(r.requestedOn)}</td>
        <td>${chip}</td>
        <td>${escapeHtml(r.requestedByName || "system")}</td>
        <td>${effective}</td>
        <td>${escapeHtml(r.approvedByName || "--")}</td>
        <td>
          <button type="button" class="pm-action-trigger" data-exc-menu="${r.exceptionRequestId}"
                  data-exc-status="${r.statusCode}"
                  data-exc-type="${r.requestTypeCode || 'GAP_CANDIDATE'}"
                  data-exc-gap-id="${r.customGapId || ''}"
                  aria-haspopup="menu" aria-expanded="false" title="Actions">
            <i class="fas fa-ellipsis-v fa-solid fa-ellipsis-vertical" aria-hidden="true"></i>
          </button>
        </td>`;
      tbody.appendChild(tr);
    });
    wireRowMenu();
  }

  function statusChip(code) {
    const cls = code === "Approved" ? "exc-approved"
              : code === "Rejected" ? "exc-rejected"
              : code === "Withdrawn" ? "exc-withdrawn"
              : code === "Expired"  ? "exc-rejected"
              : "exc-pending";
    // Migration 257: the stored code is one word; the grid reads better
    // with the space, and "SubmittedForApproval" is wide enough to wreck
    // a column.
    const label = code === "SubmittedForApproval" ? "Submitted" : (code || "");
    return `<span class="exc-status-chip ${cls}" title="${escapeHtml(code || "")}">${escapeHtml(label)}</span>`;
  }

  // Effective window with a "days remaining" badge -- makes expiring
  // exceptions jump out per sir's "never a permanent parking lot" rule.
  function formatEffective(r) {
    if (!r.effectiveUntil) return "--";
    const until = new Date(r.effectiveUntil);
    const now   = new Date();
    const oneDay = 24 * 60 * 60 * 1000;
    const days = Math.ceil((until - now) / oneDay);
    const fromTxt = r.effectiveFrom ? window.gracFormatDateOnly(r.effectiveFrom) : "--";
    const untilTxt = window.gracFormatDisplayDateObj(until);
    let badge = "";
    if (r.statusCode === "Expired") {
      badge = ` <span class="exc-status-chip exc-rejected">Expired</span>`;
    } else if (r.statusCode === "Approved") {
      if (days < 0)       badge = ` <span class="exc-status-chip exc-rejected">Overdue</span>`;
      else if (days <= 7) badge = ` <span class="exc-status-chip exc-pending">${days}d left</span>`;
      else if (days <= 30) badge = ` <span class="exc-status-chip exc-withdrawn">${days}d left</span>`;
    }
    return `${fromTxt} -> ${untilTxt}${badge}`;
  }

  // ---- 3-dot menu (PM standard) ----
  let openMenuEl = null, openMenuTrigger = null;
  function closeRowMenu() {
    if (openMenuEl) { openMenuEl.remove(); openMenuEl = null; }
    if (openMenuTrigger) { openMenuTrigger.setAttribute("aria-expanded", "false"); openMenuTrigger = null; }
  }
  function positionRowMenu(trigger) {
    if (!openMenuEl) return;
    const r = trigger.getBoundingClientRect(), mr = openMenuEl.getBoundingClientRect();
    let top = r.bottom + 6, left = r.right - mr.width;
    if (top + mr.height > window.innerHeight - 8) top = Math.max(8, r.top - mr.height - 6);
    if (left < 8) left = 8;
    if (left + mr.width > window.innerWidth - 8) left = window.innerWidth - mr.width - 8;
    openMenuEl.style.top = top + "px"; openMenuEl.style.left = left + "px";
  }
  function openRowMenu(trigger, items) {
    closeRowMenu();
    openMenuTrigger = trigger;
    trigger.setAttribute("aria-expanded", "true");
    openMenuEl = document.createElement("div");
    openMenuEl.className = "pm-action-menu";
    openMenuEl.setAttribute("role", "menu");
    items.forEach(it => {
      const b = document.createElement("button");
      b.type = "button"; b.setAttribute("role", "menuitem");
      b.innerHTML = `<i class="fa-solid ${escapeHtml(it.icon)}" aria-hidden="true"></i> ${escapeHtml(it.label)}`;
      if (it.disabled) { b.disabled = true; b.title = it.disabledReason || ""; }
      b.addEventListener("click", ev => {
        ev.preventDefault(); ev.stopPropagation(); closeRowMenu();
        try { it.action(); } catch (err) { console.error("[exc] menu action failed", err); }
      });
      openMenuEl.appendChild(b);
    });
    document.body.appendChild(openMenuEl);
    positionRowMenu(trigger);
  }
  function wireRowMenu() {
    const root = document.getElementById("excListView");
    if (!root || root.dataset.wired === "1") return;
    root.dataset.wired = "1";
    root.addEventListener("click", ev => {
      const trigger = ev.target.closest(".pm-action-trigger[data-exc-menu]");
      if (!trigger) {
        // Row click-to-View (change request, 2026-09-22): a plain click
        // anywhere else on the row opens Exception View, the same
        // destination the row's own "View" menu item navigates to.
        // Excludes the Related Gap link in its own column (its own
        // destination, gap-detail, not this row's) -- every other cell is
        // plain text or a badge with nothing of its own to click.
        const tr = ev.target.closest("tr.pm-row-clickable");
        if (!tr || !root.contains(tr) || ev.target.closest("a")) return;
        const rowTrigger = tr.querySelector(".pm-action-trigger[data-exc-menu]");
        if (!rowTrigger) return;
        window.location.href = U("/Practice/Index/exception-view")
          + "?exceptionId=" + encodeURIComponent(rowTrigger.dataset.excMenu);
        return;
      }
      ev.preventDefault(); ev.stopPropagation();
      if (openMenuTrigger === trigger) { closeRowMenu(); return; }
      const id = Number(trigger.dataset.excMenu);
      const status = trigger.dataset.excStatus;
      const reqType = trigger.dataset.excType || "GAP_CANDIDATE";
      // Migration change request 2026-09-22: sourced straight off the
      // row's own data-exc-gap-id (set in refresh() from r.customGapId)
      // instead of sniffing the Gap column's rendered <a href> -- the
      // same value, read directly rather than re-derived from markup.
      const gapId = Number(trigger.dataset.excGapId) || null;

      // Migration 257 / change request 2026-09-22: the item list and
      // every applicability/disabled rule now come from
      // window.gracExceptionActions.buildMenu() (Shared/exception-actions.js)
      // -- Exception View's own "Actions" button calls the exact same
      // function, so there is exactly one implementation of these rules,
      // used from both screens. See that module's own header comment for
      // the lifecycle/permission rules themselves.
      if (!window.gracExceptionActions) {
        console.error("[exception-centre] Shared/exception-actions.js did not load -- row menu unavailable.");
        return;
      }
      const items = window.gracExceptionActions.buildMenu(
        { exceptionId: id, requestTypeCode: reqType, statusCode: status, customGapId: gapId },
        {
          onView: () => {
            window.location.href = U("/Practice/Index/exception-view")
              + "?exceptionId=" + encodeURIComponent(id);
          },
          onAnalysis: () => {
            window.location.href = U("/Practice/Index/exception-analysis")
              + "?exceptionId=" + encodeURIComponent(id);
          },
          onApprove: (reqType === "SLA_CANDIDATE" || reqType === "TASK_SLA_EXTENSION" || reqType === "TASK_PRIORITY_REDUCTION")
            ? () => window.gracExceptionActions.approveSlaQuick(id)
            : () => window.gracExceptionActions.openApprove(id),
          onOpenSourceGap: () => {
            window.location.href = U("/Practice/Index/gap-detail")
              + "?gapId=" + encodeURIComponent(gapId)
              + "&orgId=" + encodeURIComponent(state.organizationId || "");
          }
        }
      );

      openRowMenu(trigger, items);
    });
    document.addEventListener("click", ev => {
      if (!openMenuEl) return;
      if (ev.target.closest(".pm-action-menu")) return;
      if (ev.target.closest(".pm-action-trigger")) return;
      closeRowMenu();
    });
    document.addEventListener("keydown", ev => { if (ev.key === "Escape") closeRowMenu(); });
    window.addEventListener("resize", closeRowMenu);
    window.addEventListener("scroll", closeRowMenu, true);
  }

  // Approve, History, Reject: openApproveModal/HISTORY_LABEL/
  // loadApproveHistory/isoDate/onApproveSubmit/openRejectModal/
  // onRejectSubmit all removed (change request, 2026-09-22) -- they now
  // live entirely in Shared/exception-actions.js as openApprove/
  // loadApproveHistory/onApproveSubmit/openReject/onRejectSubmit, driven
  // off the same partial's markup, called from this file's wireRowMenu()
  // (Approve) and that module's own wire() (the Approve form's Reject
  // hand-off button). See that module's header comment.

  // ---- Add Custom Exception (migration 327) ----
  //
  // "Exception Management -> Add Custom Exception -> Enter Basic Details
  // -> Save -> Exception Request Created -> Existing Exception Approval /
  // Processing Flow." The fields here are exactly what
  // sp_exception_request_create already accepted -- nothing new is
  // captured that the existing Exception data model does not already
  // have a column for.
  async function openAddCustomDialog() {
    if (!state.organizationId) { alert("Select an organization first."); return; }
    const msg = document.getElementById("excAddCustomMessage");
    if (msg) msg.textContent = "";

    ["newExcTitle", "newExcDescription", "newExcJustification",
     "newExcValidFrom", "newExcValidUntil"].forEach(id => {
      const el = document.getElementById(id); if (el) el.value = "";
    });

    const orgSel = document.getElementById("excFilterOrganization");
    const orgLabel = (orgSel && orgSel.options[orgSel.selectedIndex]
                      && orgSel.options[orgSel.selectedIndex].textContent)
                     || `Organization ${state.organizationId}`;
    const orgMeta = document.getElementById("excAddCustomOrgMeta");
    if (orgMeta) orgMeta.innerHTML = `<dt>Organization</dt><dd>${escapeHtml(orgLabel)}</dd>`;

    const submit = document.getElementById("excAddCustomSubmit");
    if (submit) submit.disabled = false;

    // Reuses the same org-scoped caches (and the same lookup endpoints)
    // the Approve modal's dormant combos already fetch from -- one cache
    // per organization, not one per dialog.
    await Promise.all([loadExceptionTypes(), loadEmployees()]);
    renderExceptionTypeOptions("newExcType", "-- select --");
    renderEmployeeOptions("newExcOwner", "-- unassigned --");

    // Migration 328/329 -- Related Control / Practice(s) is the reusable
    // cascading Practice Picker, opened from its own popup (see
    // openAddCustomPracticeDialog below) rather than sitting inline here.
    // Reset the running list every time this dialog opens.
    addCustomPractices = [];
    renderAddCustomPracticeList();

    show("excAddCustomModal");
    setTimeout(() => { const t = document.getElementById("newExcTitle"); if (t) t.focus(); }, 40);
  }

  // 329 -- "Add a practice" popup, opened on top of the still-open Add
  // Custom Exception dialog. Same reuse-across-opens sequence Risk
  // Centre's own mapPicker singleton uses: retarget the organisation,
  // exclude whatever is already in the list, and reload the cascade from
  // the framework level.
  function openAddCustomPracticeDialog() {
    const hint = document.getElementById("newExcPracticeAddHint");
    if (hint) hint.textContent = "";
    if (!window.__practicePicker || !document.getElementById("newExcPracticePickerHost")) {
      if (hint) hint.textContent = "Practice picker unavailable -- practice-picker.js did not load.";
      show("newExcPracticeModal");
      return;
    }
    const excluded = addCustomPractices.map(p => p.practiceId);
    if (addCustomPicker) {
      addCustomPicker.setOrganizationId(state.organizationId);
      addCustomPicker.setExcluded(excluded);
      addCustomPicker.reset();
    } else {
      addCustomPicker = window.__practicePicker.attach({
        host:               "newExcPracticePickerHost",
        organizationId:     state.organizationId,
        required:           false,
        excludePracticeIds: excluded
      });
    }
    show("newExcPracticeModal");
  }

  function closeAddCustomPracticeDialog() {
    hide("newExcPracticeModal");
  }

  // 329: one practice at a time from the picker. Confirm both adds it to
  // the running list AND closes the popup -- the same shape Risk Centre's
  // own Map Practice confirm uses (closeMapPracticeDialog() after a
  // successful map). Reopen "Add a practice" to add another.
  function onAddCustomPracticeConfirm() {
    const hint = document.getElementById("newExcPracticeAddHint");
    if (!addCustomPicker) return;
    const picked = addCustomPicker.getState();
    if (!picked || !picked.isComplete || !picked.practiceId) {
      if (hint) hint.textContent = "Pick a Framework, Source Structure, Control and Practice first.";
      return;
    }
    const practiceId = picked.practiceId;
    if (addCustomPractices.some(p => p.practiceId === practiceId)) {
      if (hint) hint.textContent = "That practice is already in the list.";
      return;
    }
    const practiceName = picked.practiceName || `Practice #${practiceId}`;
    addCustomPractices.push({ practiceId, practiceName });
    renderAddCustomPracticeList();
    closeAddCustomPracticeDialog();
  }

  function renderAddCustomPracticeList() {
    const ul = document.getElementById("newExcPracticeList");
    if (!ul) return;
    if (!addCustomPractices.length) {
      ul.innerHTML = `<li class="pm-hint">No practices added yet.</li>`;
      return;
    }
    ul.innerHTML = addCustomPractices.map(p => `
      <li>
        <span>${escapeHtml(p.practiceName)}</span>
        <button type="button" data-remove-practice="${p.practiceId}" title="Remove">
          <i class="fa-solid fa-xmark" aria-hidden="true"></i>
        </button>
      </li>`).join("");
  }

  async function onAddCustomSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("excAddCustomMessage");
    msg.textContent = "";
    const title = document.getElementById("newExcTitle").value.trim();
    if (!title) { msg.textContent = "Exception Title / Subject is required."; return; }

    const submit = document.getElementById("excAddCustomSubmit");
    submit.disabled = true; msg.textContent = "Saving...";

    // requestedByEmployeeId is NOT sent from here -- the Web-tier proxy
    // stamps it from the signed-in session (sir's follow-up: automatic,
    // no manual input), the same way Approve/Reject stamp their own
    // employee-id field server-side rather than trusting the client.
    const payload = {
      organizationId:         state.organizationId,
      requestTitle:           title,
      requestReason:          document.getElementById("newExcDescription").value.trim() || null,
      justification:          document.getElementById("newExcJustification").value.trim() || null,
      exceptionTypeCode:      document.getElementById("newExcType").value || null,
      ownerEmployeeId:        Number(document.getElementById("newExcOwner").value) || null,
      // Migration 328 -- every practice added via the cascading Practice
      // Picker's "Add to list" row, in add order. The API derives the
      // single legacy linked_practice_id from the first entry; this
      // dialog no longer sends that field itself.
      linkedPracticeIds:      addCustomPractices.length ? addCustomPractices.map(p => p.practiceId) : null,
      // Related Obligation/Requirement and Related Gap ID removed from this
      // form (change request 2026-09-24) -- always null on creation now;
      // see the .cshtml comment where the two fields used to sit.
      linkedRequirementRef:   null,
      customGapId:            null,
      proposedEffectiveFrom:  document.getElementById("newExcValidFrom").value || null,
      proposedEffectiveUntil: document.getElementById("newExcValidUntil").value || null
    };

    // Posts to the collection route itself (base, no suffix) -- the same
    // "POST the list route to create" shape CustomGapController uses for
    // its own Open action.
    const url = U(base);
    let result;
    try {
      const r = await fetch(url, {
        method: "POST", credentials: "same-origin",
        headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload)
      });
      const data = await r.json().catch(() => ({}));
      result = r.ok ? { success: true, ...data } : { success: false, error: data.error || `HTTP ${r.status}` };
    } catch (err) { result = { success: false, error: err.message }; }

    if (!result.success) {
      msg.textContent = result.error || "Save failed.";
      submit.disabled = false;
      return;
    }

    msg.textContent = `Custom Exception #${result.exceptionRequestId} created.`;
    setTimeout(async () => {
      hide("excAddCustomModal");
      // The new row is Pending / CUSTOM -- make sure the current filters
      // do not immediately hide it from the analyst who just created it.
      const typeSel = document.getElementById("excFilterType");
      if (typeSel && typeSel.value && typeSel.value !== "CUSTOM") { typeSel.value = "CUSTOM"; state.requestType = "CUSTOM"; }
      const statusSel = document.getElementById("excFilterStatus");
      if (statusSel && statusSel.value && statusSel.value !== "Pending") { statusSel.value = ""; state.statusCode = null; }
      pager?.reset(true);
      await refresh();
    }, 700);
  }

  // ---- helpers ----
  // metaOf(r) removed (change request, 2026-09-22): it rendered the
  // approver's read of the case onto the Approve/Reject dialogs, which
  // now live in Shared/exception-actions.js as its own copy of the same
  // function.
  // Background-scroll lock (change request 2026-09-24): .pm-modal is a
  // fixed, full-viewport overlay (practice-management.css), but nothing
  // ever stopped the PAGE behind it from also scrolling while a modal is
  // open -- sir's "scrolling ozhivakkanam" (avoid the scrolling). Scoped
  // to this file's own two modals only (excAddCustomModal, and the
  // practice picker that nests on top of it) rather than touching the
  // shared .pm-modal rule other views (gap-detail, risk-centre) also use.
  // anyOpen() covers the nesting: closing the picker while Add Custom
  // Exception is still open behind it must not unlock the page.
  function anyOpen() {
    var a = document.getElementById("excAddCustomModal");
    var b = document.getElementById("newExcPracticeModal");
    return (a && !a.hidden) || (b && !b.hidden);
  }
  function show(id) {
    document.getElementById(id).hidden = false;
    document.body.style.overflow = "hidden";
  }
  function hide(id) {
    document.getElementById(id).hidden = true;
    if (!anyOpen()) document.body.style.overflow = "";
  }
  function escapeHtml(s) {
    if (s == null) return "";
    return String(s).replace(/[&<>"']/g, ch => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[ch]));
  }

  // Change request 2026-09-22: the Request column showed "Exception: <gap
  // title>" verbatim -- that prefix is baked into the STORED request_title
  // by sp_exception_request_create (COALESCE default of "Exception: " +
  // gap title when no explicit title is given; see database/328_custom_
  // exception_multi_practice.sql). This is a display-only strip for the
  // grid: it does not touch r.requestTitle itself or the row object, so
  // every other reader of requestTitle (e.g. the Add Custom Exception
  // payload further down) still sees/sends the real stored value
  // unchanged. Case-insensitive and whitespace-tolerant so a hand-typed
  // custom title like "exception:no space" still strips cleanly, but a
  // title that merely CONTAINS "Exception:" mid-string (not as its
  // opening word) is left alone.
  function displayRequestTitle(title) {
    return String(title || "").replace(/^\s*Exception:\s*/i, "");
  }

  async function apiGet(path) {
    const url = U(`${base}${path.startsWith("/") ? path : "/" + path}`);
    try {
      const r = await fetch(url, { credentials: "same-origin" });
      if (r.status === 404) return null;
      if (!r.ok) { console.warn("exc GET", url, r.status); return null; }
      return await r.json();
    } catch (err) { console.error("exc GET failed", url, err); return null; }
  }
  async function apiPost(path, body) {
    const url = U(`${base}${path.startsWith("/") ? path : "/" + path}`);
    try {
      const r = await fetch(url, {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok) return { success: false, error: data.error || `HTTP ${r.status}` };
      return { success: data.success !== false, ...data };
    } catch (err) { return { success: false, error: err.message }; }
  }

  // onApproveSlaQuick removed (change request, 2026-09-22): it now lives
  // in Shared/exception-actions.js as approveSlaQuick, called from this
  // file's wireRowMenu() and from Exception View's own Actions menu.
})();
