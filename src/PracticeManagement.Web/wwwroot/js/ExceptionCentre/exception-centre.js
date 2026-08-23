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
    statusCode: "Pending",
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
    document.getElementById("excFilterOrganization").addEventListener("change", e => {
      state.organizationId = e.target.value ? Number(e.target.value) : null;
      // Org-scoped combos must reload for the new org.
      state.employeesCache = [];
      state.practicesCache = [];
      refresh();
    });
    document.getElementById("excFilterStatus").addEventListener("change", e => {
      state.statusCode = e.target.value || null;
      refresh();
    });
    document.getElementById("excRefreshBtn").addEventListener("click", refresh);
    document.getElementById("excExpireDueBtn").addEventListener("click", onExpireDue);

    // Migration 184 -- tab switcher. Underlined active tab, single-open.
    document.querySelectorAll(".pm-tab[data-req-type]").forEach(btn => {
      btn.addEventListener("click", () => {
        const type = btn.dataset.reqType;
        if (state.requestType === type) return;
        state.requestType = type;
        document.querySelectorAll(".pm-tab[data-req-type]").forEach(b => {
          const active = b === btn;
          b.classList.toggle("active", active);
          b.setAttribute("aria-selected", active ? "true" : "false");
          b.style.borderBottomColor = active ? "#2563eb" : "transparent";
          b.style.color             = active ? "#0f172a" : "#64748b";
          b.style.fontWeight        = active ? "600" : "normal";
        });
        refresh();
      });
    });
    // Bootstrap the active style for the default (Gap Candidate) tab.
    const initTab = document.querySelector('.pm-tab[data-req-type="GAP_CANDIDATE"]');
    if (initTab) {
      initTab.style.borderBottomColor = "#2563eb";
      initTab.style.color             = "#0f172a";
      initTab.style.fontWeight        = "600";
    }

    document.getElementById("excApproveForm").addEventListener("submit", onApproveSubmit);
    document.getElementById("excRejectForm").addEventListener("submit", onRejectSubmit);
    document.querySelectorAll("[data-close-exc-approve]").forEach(el =>
      el.addEventListener("click", () => hide("excApproveModal")));
    document.querySelectorAll("[data-close-exc-reject]").forEach(el =>
      el.addEventListener("click", () => hide("excRejectModal")));

    // Toggle Manual (file) vs Automated (location+locator) vs none.
    document.getElementById("excApproveMethod").addEventListener("change", renderApproveMethodFields);
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

  async function loadExceptionTypes() {
    if (state.exceptionTypesCache.length) { populateExceptionTypeSelect(); return; }
    try {
      const r = await fetch(U(`${base}/lookups/exception-types`), { credentials: "same-origin" });
      state.exceptionTypesCache = r.ok ? (await r.json()) || [] : [];
    } catch (_) { state.exceptionTypesCache = []; }
    populateExceptionTypeSelect();
  }
  function populateExceptionTypeSelect() {
    const sel = document.getElementById("excApproveType");
    if (!sel) return;
    sel.innerHTML = `<option value="">-- select --</option>`;
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
  function populateOwnerSelect() {
    const sel = document.getElementById("excApproveOwner");
    if (!sel) return;
    sel.innerHTML = `<option value="">-- unassigned --</option>`;
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
  function populatePracticeSelect() {
    const sel = document.getElementById("excApproveLinkedPracticeId");
    if (!sel) return;
    sel.innerHTML = `<option value="">-- select --</option>`;
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
      tbody.innerHTML = `<tr><td colspan="8" class="pm-empty-row">Select an organization.</td></tr>`;
      return;
    }
    tbody.innerHTML = `<tr><td colspan="8" class="pm-empty-row">Loading...</td></tr>`;
    const qs = new URLSearchParams({ organizationId: state.organizationId });
    if (state.statusCode)  qs.set("statusCode",  state.statusCode);
    if (state.requestType) qs.set("requestType", state.requestType);
    const data = await apiGet(`?${qs}`);
    const rows = data?.rows || [];
    if (!rows.length) {
      tbody.innerHTML = `<tr><td colspan="8" class="pm-empty-row">
        No ${escapeHtml(state.statusCode || "")} exception requests.</td></tr>`;
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
        <td><a href="${U('/Practice/Index/gap-detail')}?gapId=${r.customGapId}&orgId=${state.organizationId}">
              ${escapeHtml(r.gapTitle || `Gap #${r.customGapId}`)}</a></td>
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
    return `<span class="exc-status-chip ${cls}">${escapeHtml(code || "")}</span>`;
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
      const isPending = status === "Pending";
      // Migration 184 -- SLA_CANDIDATE approvals go to a distinct
      // endpoint (no effective-until dialog fields).
      const reqType = trigger.dataset.excType || "GAP_CANDIDATE";
      const approveAction = reqType === "SLA_CANDIDATE"
        ? () => onApproveSlaQuick(id)
        : () => openApproveModal(id);
      openRowMenu(trigger, [
        { icon: "fa-check", label: "Approve",
          disabled: !isPending, disabledReason: `Only Pending can be approved (current: ${status}).`,
          action: approveAction },
        { icon: "fa-ban", label: "Reject",
          disabled: !isPending, disabledReason: `Only Pending can be rejected (current: ${status}).`,
          action: () => openRejectModal(id) },
        { icon: "fa-route", label: "Open source gap",
          action: () => {
            const btn = trigger.closest("tr").querySelector("a[href*='gap-detail']");
            if (btn) window.location.href = btn.getAttribute("href");
          } }
      ]);
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
    document.getElementById("excApproveEffectiveFrom").value  = "";
    document.getElementById("excApproveEffectiveUntil").value = "";
    document.getElementById("excApproveNote").value = "";
    document.getElementById("excApproveCompensatingControl").value = "";
    document.getElementById("excApproveFile").value = "";
    document.getElementById("excApproveMethod").value = "";
    document.getElementById("excApproveLocation").value = "";
    document.getElementById("excApproveLocator").value = "";
    document.getElementById("excApproveMessage").textContent = "";
    document.getElementById("excApproveMeta").innerHTML = metaOf(req);

    // Load all combos in parallel (cached across opens).
    await Promise.all([
      loadEvidenceTypes(),
      loadExceptionTypes(),
      loadEmployees(),
      loadFrequencies(),
      loadPractices()
    ]);
    document.getElementById("excApproveEvidenceType").value = "";
    document.getElementById("excApproveReviewFrequency").value = "";

    // Prefill request-level fields from whatever was already captured.
    document.getElementById("excApproveType").value                 = req.exceptionTypeCode || "";
    document.getElementById("excApproveOwner").value                = req.ownerEmployeeId ? String(req.ownerEmployeeId) : "";
    document.getElementById("excApproveJustification").value        = req.justification || req.requestReason || "";
    document.getElementById("excApproveRiskImpact").value           = req.riskImpact || "";
    document.getElementById("excApproveLinkedPracticeId").value     = req.linkedPracticeId ? String(req.linkedPracticeId) : "";
    document.getElementById("excApproveLinkedRequirementRef").value = req.linkedRequirementRef || "";

    renderApproveMethodFields();
    show("excApproveModal");
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
    const compCtrl   = document.getElementById("excApproveCompensatingControl").value.trim() || null;
    const freqIdVal  = Number(document.getElementById("excApproveReviewFrequency").value) || null;
    // -1 is the placeholder in the fallback list -- treat as no selection.
    const reviewFreq = (freqIdVal && freqIdVal > 0) ? freqIdVal : null;

    const result = await apiPost(`/${id}/approve`, {
      effectiveFrom:  efFrom,
      effectiveUntil: effectiveUntil,
      approvalNote:   note,
      compensatingControl: compCtrl,
      reviewFrequencyId:   reviewFreq,
      exceptionTypeCode:      document.getElementById("excApproveType").value || null,
      justification:          document.getElementById("excApproveJustification").value.trim() || null,
      riskImpact:             document.getElementById("excApproveRiskImpact").value.trim() || null,
      ownerEmployeeId:        Number(document.getElementById("excApproveOwner").value) || null,
      linkedPracticeId:       Number(document.getElementById("excApproveLinkedPracticeId").value) || null,
      linkedRequirementRef:   document.getElementById("excApproveLinkedRequirementRef").value.trim() || null
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

  // ---- helpers ----
  function metaOf(r) {
    return `<dt>Request</dt><dd>${escapeHtml(r.requestTitle || "")}</dd>` +
           `<dt>Gap</dt><dd>${escapeHtml(r.gapTitle || `#${r.customGapId}`)}</dd>` +
           (r.requestReason ? `<dt>Reason</dt><dd>${escapeHtml(r.requestReason)}</dd>` : "") +
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
