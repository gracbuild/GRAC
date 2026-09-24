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
    activeRequest: null,
    evidenceTypesCache: [],
    exceptionTypesCache: [],
    employeesCache: [],
    frequenciesCache: [],
    practicesCache: []
  };

  // pm-grid handle. sp_exception_request_list has paged at 25 since 193,
  // but this screen sent no page parameter, so request 26 onwards could
  // not be reached. null when pm-grid.js has not loaded; every use is
  // optional-chained, so the list still fetches its first page.
  let pager = null;

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    if (!document.getElementById("excListView")) return;
    document.getElementById("excListView").hidden = false;
    bindEvents();
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

    document.getElementById("excApproveForm").addEventListener("submit", onApproveSubmit);
    document.getElementById("excRejectForm").addEventListener("submit", onRejectSubmit);
    document.querySelectorAll("[data-close-exc-approve]").forEach(el =>
      el.addEventListener("click", () => hide("excApproveModal")));
    document.querySelectorAll("[data-close-exc-reject]").forEach(el =>
      el.addEventListener("click", () => hide("excRejectModal")));

    // Reject now starts from the Approve form rather than the row menu.
    // It hands off to the existing Reject modal so the mandatory reason
    // is still captured in one place.
    document.getElementById("excApproveRejectBtn").addEventListener("click", () => {
      const id = Number(document.getElementById("excApproveId").value);
      if (!id) return;
      hide("excApproveModal");
      openRejectModal(id);
    });

    // Toggle Manual (file) vs Automated (location+locator) vs none.
    document.getElementById("excApproveMethod").addEventListener("change", renderApproveMethodFields);

    // Migration 327 -- "+ Add Custom Exception."
    const addCustomBtn = document.getElementById("excAddCustomBtn");
    if (addCustomBtn) addCustomBtn.addEventListener("click", openAddCustomDialog);
    document.querySelectorAll("[data-close-exc-add-custom]").forEach(el =>
      el.addEventListener("click", () => hide("excAddCustomModal")));
    const addCustomForm = document.getElementById("excAddCustomForm");
    if (addCustomForm) addCustomForm.addEventListener("submit", onAddCustomSubmit);
  }

  function renderApproveMethodFields() {
    const m = document.getElementById("excApproveMethod").value;
    document.getElementById("excApproveFileWrap").hidden     = (m !== "Manual");
    document.getElementById("excApproveLocationWrap").hidden = (m !== "Automated");
    document.getElementById("excApproveLocatorWrap").hidden  = (m !== "Automated");
    // Evidence type only meaningful when we actually attach something.
    document.getElementById("excApproveEvidenceTypeWrap").hidden = (m === "");
  }

  async function onExpireDue() {
    if (!confirm("Expire all Approved exceptions whose Valid Until date has passed?")) return;
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

  // 327: same list, needed for the Add Custom Exception dialog's own
  // Related Control / Practice picker.
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

  async function loadFrequencies() {
    if (state.frequenciesCache.length) { populateFrequencySelect(); return; }
    // The frequency master doesn't yet have a shared endpoint; the
    // exception centre exposes one via its own path only when needed.
    // For now embed the common frequencies as a fallback so approve
    // works even if no endpoint exists yet.
    state.frequenciesCache = [
      { frequencyId: -1, frequencyName: "(free-text later)" }
    ];
    populateFrequencySelect();
  }
  function populateFrequencySelect() {
    const sel = document.getElementById("excApproveReviewFrequency");
    if (!sel) return;
    sel.innerHTML = `<option value="">-- select --</option>`;
    state.frequenciesCache.forEach(f => {
      const o = document.createElement("option");
      o.value = f.frequencyId; o.textContent = f.frequencyName;
      sel.appendChild(o);
    });
  }

  async function loadEvidenceTypes() {
    if (state.evidenceTypesCache.length) return;
    try {
      const r = await fetch(U(`${base}/lookups/evidence-types`), { credentials: "same-origin" });
      state.evidenceTypesCache = r.ok ? (await r.json()) || [] : [];
    } catch (_) { state.evidenceTypesCache = []; }
    const sel = document.getElementById("excApproveEvidenceType");
    if (!sel) return;
    sel.innerHTML = `<option value="">-- select --</option>`;
    state.evidenceTypesCache.forEach(t => {
      const o = document.createElement("option");
      o.value = t.evidenceTypeCode;
      o.textContent = t.evidenceTypeName;
      sel.appendChild(o);
    });
  }

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
      tbody.innerHTML = `<tr><td colspan="8" class="pm-empty-row">Select an organization.</td></tr>`;
      return;
    }
    tbody.innerHTML = `<tr><td colspan="8" class="pm-empty-row">Loading...</td></tr>`;
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
      tbody.innerHTML = `<tr><td colspan="8" class="pm-empty-row">
        No ${scope}exception requests.</td></tr>`;
      return;
    }
    tbody.innerHTML = "";
    rows.forEach(r => {
      const tr = document.createElement("tr");
      const chip = statusChip(r.statusCode);
      const effective = formatEffective(r);
      tr.innerHTML = `
        <td>${escapeHtml(r.requestTitle)}</td>
        <td>${escapeHtml(r.exceptionTypeName || "--")}</td>
        <td>${r.customGapId
              ? `<a href="${U('/Practice/Index/gap-detail')}?gapId=${r.customGapId}&orgId=${state.organizationId}">`
                + `${escapeHtml(r.gapTitle || `Gap #${r.customGapId}`)}</a>`
              // 327: no gap at all is now an ordinary shape (CUSTOM, and
              // already true of TASK_SLA_EXTENSION / TASK_PRIORITY_REDUCTION
              // since 192) -- render "--" rather than a link to
              // "gapId=undefined".
              : `<span class="pm-hint">--</span>`}</td>
        <td>${new Date(r.requestedOn).toLocaleString()}<br>
            <span class="pm-hint">${escapeHtml(r.requestedByName || "system")}</span></td>
        <td>${chip}</td>
        <td>${effective}</td>
        <td>${escapeHtml(r.approvedByName || "--")}</td>
        <td>${r.attachmentCount || 0}</td>
        <td>
          <button type="button" class="pm-action-trigger" data-exc-menu="${r.exceptionRequestId}"
                  data-exc-status="${r.statusCode}"
                  data-exc-type="${r.requestTypeCode || 'GAP_CANDIDATE'}"
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
    const fromTxt = r.effectiveFrom ? new Date(r.effectiveFrom).toLocaleDateString() : "--";
    const untilTxt = until.toLocaleDateString();
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
      if (!trigger) return;
      ev.preventDefault(); ev.stopPropagation();
      if (openMenuTrigger === trigger) { closeRowMenu(); return; }
      const id = Number(trigger.dataset.excMenu);
      const status = trigger.dataset.excStatus;
      const reqType = trigger.dataset.excType || "GAP_CANDIDATE";

      // Migration 257. The menu now follows the lifecycle:
      //
      //   Pending               -> Analysis        (no decision yet)
      //   SubmittedForApproval  -> Approve/Reject  (the decision)
      //
      // Approve and Reject are deliberately NOT offered at Pending: a
      // request that has not been analysed is not ready to be judged.
      //
      // The task-side types (SLA / priority requests raised from Task
      // Centre) have no analysis stage at all -- they are decided
      // straight from Pending, which is what the procedures enforce too.
      const isTaskType = (reqType === "SLA_CANDIDATE"
                       || reqType === "TASK_SLA_EXTENSION"
                       || reqType === "TASK_PRIORITY_REDUCTION");
      const items = [];

      // "View" -- the dedicated read-only Exception View full page,
      // available in ANY status (unlike Analysis below, which only
      // applies to a Pending/SubmittedForApproval request). Same
      // disabled-when-there-is-no-id guard as Analysis, for the same
      // reason: a row without an id has nothing to view either.
      items.push({
        icon: "fa-eye", label: "View",
        disabled: !Number.isFinite(id) || id <= 0,
        disabledReason: "This row arrived without an exception request id, so there is nothing to view. "
          + "Reload the list; if it persists the request id is missing from the list response.",
        action: () => {
          if (!Number.isFinite(id) || id <= 0) return;
          window.location.href = U("/Practice/Index/exception-view")
            + "?exceptionId=" + encodeURIComponent(id);
        }
      });

      if (!isTaskType) {
        items.push({
          icon: "fa-magnifying-glass", label: "Analysis",
          // DISABLED WHEN THERE IS NO ID TO SEND, not just when the
          // status is wrong.
          //
          // data-exc-menu is interpolated from r.exceptionRequestId. If
          // that row ever arrives without one, Number() gives NaN, the
          // old code cheerfully navigated to "?exceptionId=NaN", and the
          // analysis page answered "No exception request was specified"
          // -- which reads as a broken page rather than a broken row.
          // Refusing here keeps the cause where the effect is.
          disabled: !Number.isFinite(id) || id <= 0
                    || (status !== "Pending" && status !== "SubmittedForApproval"),
          disabledReason: (!Number.isFinite(id) || id <= 0)
            ? "This row arrived without an exception request id, so there is nothing to analyse. "
              + "Reload the list; if it persists the request id is missing from the list response."
            : `Analysis applies to a Pending request (current: ${status}).`,
          action: () => {
            // Belt and braces: the item is disabled above, and a
            // disabled item's action is not invoked -- but this is the
            // one navigation on the screen that leaves the SPA, and
            // sending "NaN" is worse than doing nothing.
            if (!Number.isFinite(id) || id <= 0) return;
            window.location.href = U("/Practice/Index/exception-analysis")
              + "?exceptionId=" + encodeURIComponent(id);
          }
        });
      }

      const canDecide = isTaskType ? (status === "Pending")
                                   : (status === "SubmittedForApproval");

      // Approve is OFFERED only while the request is actually decidable —
      // a greyed-out row on every other status was noise. Reject is not a
      // menu item at all: rejecting is a decision the approver makes with
      // the request in front of them, so it lives on the Approve form.
      if (canDecide) {
        items.push({ icon: "fa-check", label: "Approve",
          action: isTaskType ? () => onApproveSlaQuick(id) : () => openApproveModal(id) });
      }

      // 327: a CUSTOM (or task-side) row can have no gap at all -- the
      // Gap column then renders no link (see renderRows), so this item
      // is disabled rather than silently doing nothing on click.
      const gapLink = trigger.closest("tr").querySelector("a[href*='gap-detail']");
      items.push(
        { icon: "fa-route", label: "Open source gap",
          disabled: !gapLink,
          disabledReason: "This request has no linked gap.",
          action: () => { if (gapLink) window.location.href = gapLink.getAttribute("href"); } }
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

  // ---- Approve ----
  async function openApproveModal(id) {
    const req = await apiGet(`/${id}`);
    if (!req) { alert("Request not found."); return; }
    state.activeRequest = req;
    document.getElementById("excApproveId").value = id;
    // 260: open on the analyst's proposal rather than on two blank
    // boxes. The approver is judging a window that was justified, not
    // inventing one -- and any edit from here is recorded as a change.
    const propFrom  = isoDate(req.proposedEffectiveFrom);
    const propUntil = isoDate(req.proposedEffectiveUntil);
    document.getElementById("excApproveEffectiveFrom").value  = propFrom;
    document.getElementById("excApproveEffectiveUntil").value = propUntil;

    const proposedHint = document.getElementById("excApproveProposed");
    if (proposedHint) {
      if (propFrom || propUntil) {
        proposedHint.textContent =
          `Analyst proposed ${propFrom || "(not set)"} to ${propUntil || "(not set)"}.`
          + " Change these only if the window needs to differ — the change is recorded.";
        proposedHint.hidden = false;
      } else {
        // Task-side requests never went through analysis, so there is no
        // proposal to show and nothing to compare against.
        proposedHint.hidden = true;
      }
    }
    document.getElementById("excApproveNote").value = "";
    document.getElementById("excApproveFile").value = "";
    document.getElementById("excApproveMethod").value = "";
    document.getElementById("excApproveLocation").value = "";
    document.getElementById("excApproveLocator").value = "";
    document.getElementById("excApproveMessage").textContent = "";
    // Migration 257: the analysis is rendered here, read-only, so the
    // approver decides with the case in front of them instead of being
    // asked to write it.
    document.getElementById("excApproveMeta").innerHTML = metaOf(req);

    await Promise.all([loadEvidenceTypes(), loadFrequencies()]);
    document.getElementById("excApproveEvidenceType").value = "";
    document.getElementById("excApproveReviewFrequency").value = "";

    renderApproveMethodFields();
    show("excApproveModal");
    // After the modal is up: the trail is context, not a gate, so it
    // must not delay the form the approver came to fill in.
    loadApproveHistory(id);
  }

  // ---- History (260) ----
  // Same labels and the same "the date change is what people come for"
  // emphasis as the analysis page, kept in the two files that own the
  // two screens rather than in a shared bundle neither of them loads.
  const HISTORY_LABEL = {
    Create:                "Created",
    SubmitForApproval:     "Submitted for approval",
    EffectiveDatesChanged: "Effective dates changed",
    Approve:               "Approved",
    Reject:                "Rejected",
    Withdraw:              "Withdrawn",
    AttachmentUpload:      "Attachment added"
  };

  async function loadApproveHistory(id) {
    const body = document.getElementById("excApproveHistoryBody");
    if (!body) return;
    const rows = (await apiGet(`/${id}/history`)) || [];
    if (!rows.length) {
      body.innerHTML = `<tr><td colspan="4" class="pm-empty-row">Nothing recorded yet.</td></tr>`;
      return;
    }
    body.innerHTML = rows.map(h => {
      const label = HISTORY_LABEL[h.actionCode] || h.actionCode || "";
      const cls = h.actionCode === "EffectiveDatesChanged" ? " exc-pending" : "";
      return `
      <tr>
        <td>${escapeHtml(new Date(h.enteredOn).toLocaleString())}</td>
        <td><span class="exc-status-chip${cls}">${escapeHtml(label)}</span></td>
        <td>${escapeHtml(h.actorName || "system")}</td>
        <td>${escapeHtml(h.remark || "")}</td>
      </tr>`;
    }).join("");
  }

  // <input type="date"> speaks yyyy-mm-dd and nothing else.
  function isoDate(v) {
    if (!v) return "";
    const d = new Date(v);
    return isNaN(d.getTime()) ? String(v).slice(0, 10) : d.toISOString().slice(0, 10);
  }

  async function onApproveSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("excApproveMessage");
    msg.textContent = "";
    const id = Number(document.getElementById("excApproveId").value);
    const effectiveUntil = document.getElementById("excApproveEffectiveUntil").value;
    const note           = document.getElementById("excApproveNote").value.trim();
    if (!effectiveUntil || !note) { msg.textContent = "Effective until date and approval note are required."; return; }

    const efFrom     = document.getElementById("excApproveEffectiveFrom").value || null;
    const freqIdVal  = Number(document.getElementById("excApproveReviewFrequency").value) || null;
    // -1 is the placeholder in the fallback list -- treat as no selection.
    const reviewFreq = (freqIdVal && freqIdVal > 0) ? freqIdVal : null;

    // Migration 257: exceptionTypeCode / justification / riskImpact /
    // ownerEmployeeId / linkedPracticeId / linkedRequirementRef are no
    // longer sent -- the analysis page owns them. compensatingControl is
    // gone entirely. The procedure COALESCE-preserves every one of these,
    // so omitting them leaves what the analysis recorded untouched.
    const result = await apiPost(`/${id}/approve`, {
      effectiveFrom:     efFrom,
      effectiveUntil:    effectiveUntil,
      approvalNote:      note,
      reviewFrequencyId: reviewFreq
    });
    if (!result || result.success === false) {
      const err = (result && result.error) || "Approve failed.";
      msg.textContent = err; alert(err);
      return;
    }

    // Optional evidence-style attachment after approve succeeded.
    // Manual -> file. Automated -> location + locator. Same shape as
    // practice_instance_evidence collection method.
    const method = document.getElementById("excApproveMethod").value;
    if (method) {
      const fd = new FormData();
      fd.append("CollectionMethodCode", method);
      const evType = document.getElementById("excApproveEvidenceType").value;
      if (evType) fd.append("EvidenceTypeCode", evType);

      if (method === "Manual") {
        const file = document.getElementById("excApproveFile").files?.[0];
        if (!file) { alert("Approved, but Manual attachment needs a file. Skipping upload."); }
        else       { fd.append("File", file, file.name); }
      } else if (method === "Automated") {
        const loc = document.getElementById("excApproveLocation").value.trim();
        const lct = document.getElementById("excApproveLocator").value.trim();
        if (!loc || !lct) {
          alert("Approved, but Automated attachment needs Location and Locator. Skipping upload.");
        } else {
          fd.append("EvidenceLocation", loc);
          fd.append("EvidenceLocator",  lct);
        }
      }
      // Only fire the upload if we actually populated the required side.
      if ((method === "Manual" && fd.has("File")) ||
          (method === "Automated" && fd.has("EvidenceLocation"))) {
        try {
          const r = await fetch(U(`${base}/${id}/attachments`), {
            method: "POST", body: fd, credentials: "same-origin"
          });
          const b = await r.json().catch(() => ({}));
          if (!r.ok || b.success === false) {
            alert("Approved, but attachment upload failed: " + (b.error || `HTTP ${r.status}`));
          }
        } catch (err) {
          alert("Approved, but attachment upload failed: " + err.message);
        }
      }
    }
    hide("excApproveModal");
    alert("Exception approved.");
    await refresh();
  }

  // ---- Reject ----
  async function openRejectModal(id) {
    const req = await apiGet(`/${id}`);
    if (!req) { alert("Request not found."); return; }
    state.activeRequest = req;
    document.getElementById("excRejectId").value = id;
    document.getElementById("excRejectReason").value = "";
    document.getElementById("excRejectMessage").textContent = "";
    document.getElementById("excRejectMeta").innerHTML = metaOf(req);
    show("excRejectModal");
  }

  async function onRejectSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("excRejectMessage");
    msg.textContent = "";
    const id = Number(document.getElementById("excRejectId").value);
    const reason = document.getElementById("excRejectReason").value.trim();
    if (!reason) { msg.textContent = "Rejection reason is required."; return; }
    const result = await apiPost(`/${id}/reject`, { rejectionReason: reason });
    if (!result || result.success === false) {
      const err = (result && result.error) || "Reject failed.";
      msg.textContent = err; alert(err);
      return;
    }
    hide("excRejectModal");
    alert("Exception rejected.");
    await refresh();
  }

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

    ["newExcTitle", "newExcDescription", "newExcJustification", "newExcRequirementRef",
     "newExcGapId", "newExcValidFrom", "newExcValidUntil"].forEach(id => {
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
    await Promise.all([loadExceptionTypes(), loadEmployees(), loadPractices()]);
    renderExceptionTypeOptions("newExcType", "-- select --");
    renderEmployeeOptions("newExcOwner", "-- unassigned --");
    renderEmployeeOptions("newExcRequestedBy", "-- select --");
    renderPracticeOptions("newExcPractice", "-- none --");

    show("excAddCustomModal");
    setTimeout(() => { const t = document.getElementById("newExcTitle"); if (t) t.focus(); }, 40);
  }

  async function onAddCustomSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("excAddCustomMessage");
    msg.textContent = "";
    const title = document.getElementById("newExcTitle").value.trim();
    if (!title) { msg.textContent = "Exception Title / Subject is required."; return; }

    const gapIdRaw = document.getElementById("newExcGapId").value;
    const gapId = gapIdRaw ? Number(gapIdRaw) : null;
    if (gapIdRaw && (!Number.isFinite(gapId) || gapId <= 0)) {
      msg.textContent = "Related Gap ID must be a positive number."; return;
    }

    const submit = document.getElementById("excAddCustomSubmit");
    submit.disabled = true; msg.textContent = "Saving...";

    const payload = {
      organizationId:         state.organizationId,
      requestTitle:           title,
      requestReason:          document.getElementById("newExcDescription").value.trim() || null,
      justification:          document.getElementById("newExcJustification").value.trim() || null,
      exceptionTypeCode:      document.getElementById("newExcType").value || null,
      ownerEmployeeId:        Number(document.getElementById("newExcOwner").value) || null,
      requestedByEmployeeId:  Number(document.getElementById("newExcRequestedBy").value) || null,
      linkedPracticeId:       Number(document.getElementById("newExcPractice").value) || null,
      linkedRequirementRef:   document.getElementById("newExcRequirementRef").value.trim() || null,
      customGapId:            gapId,
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
  // Migration 257: this is the approver's view of the analysis. It used
  // to show four facts about the request while the analysis fields sat
  // BELOW as empty inputs for the approver to fill in; now the analysis
  // is done first and shown here as the case being judged.
  function metaOf(r) {
    const row = (k, v) => v ? `<dt>${escapeHtml(k)}</dt><dd>${escapeHtml(v)}</dd>` : "";
    return row("Request", r.requestTitle) +
           row("Gap", r.gapTitle || (r.customGapId ? `#${r.customGapId}` : "")) +
           row("Reason", r.requestReason) +
           row("Exception type", r.exceptionTypeName || r.exceptionTypeCode) +
           row("Exception owner", r.ownerName) +
           row("Justification", r.justification) +
           row("Risk / Impact", r.riskImpact) +
           `<dt>Requested</dt><dd>${new Date(r.requestedOn).toLocaleString()} by ${escapeHtml(r.requestedByName || "system")}</dd>`;
  }
  function show(id) { document.getElementById(id).hidden = false; }
  function hide(id) { document.getElementById(id).hidden = true; }
  function escapeHtml(s) {
    if (s == null) return "";
    return String(s).replace(/[&<>"']/g, ch => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[ch]));
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

  // Migration 184 -- SLA_CANDIDATE approve. No effective-until dialog;
  // the requested days already sit on the row. Styled confirm via
  // window.gracConfirm (grac-dialog.js) so we match the app's dialog
  // look-and-feel instead of using the raw browser confirm().
  async function onApproveSlaQuick(id) {
    const confirmFn = window.gracConfirm || (msg => Promise.resolve(confirm(msg)));
    const ok = await confirmFn({
      type:        "confirm",
      title:       "Approve SLA override",
      message:     "Approve this SLA override and apply the requested days to the gap?",
      confirmText: "Approve",
      cancelText:  "Cancel"
    });
    if (!ok) return;
    const result = await apiPost(`/${id}/approve-sla`, {
      approvedByEmployeeId: Number(window.pmEmployeeId || 0) || null,
      callerDisplayName:    window.pmEmail || "system"
    });
    if (!result.success) {
      (window.gracAlert || alert)({ type: "error", title: "Approve failed", message: result.error || "Unknown error." });
      return;
    }
    await refresh();
  }
})();
