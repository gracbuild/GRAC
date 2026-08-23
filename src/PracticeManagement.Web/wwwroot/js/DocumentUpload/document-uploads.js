// =====================================================================
// Document Uploads -- list, upload, workflow (Phase 1)
//
// Loaded by Views/Practice/Partials/document-uploads.cshtml.
//
// Uses the same session assumptions as practice.js:
//   window.pmOrganizations -- allowed orgs for the caller
//   window.pmEmployeeId    -- caller's employee id (for audit stamp)
//   window.pmUserName      -- display name
//
// All server calls go through the Web tier proxy under
// /practice/api/document-uploads/... The Api itself stays behind CORS.
// =====================================================================
(() => {
  "use strict";

  // Prefix helper -- matches tasks.cshtml / gaps.cshtml convention so
  // the module works whether the app is mounted at "/" or "/PracticeManagement".
  const U = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/document-uploads";
  const state = {
    organizationId: null,
    typeId: -1,
    stageId: -1,
    statusId: -1,
    search: "",
    page: 1,
    pageSize: 25,
    lookups: { types: [], stages: [], statuses: [], distributions: [], employees: [], departments: [] },
    pickers: { departments: null, employees: null }  // MultiSelect instances
  };

  // -------------------- boot -------------------------------------------
  // Script is loaded from a partial that renders AFTER DOMContentLoaded
  // has already fired, so a plain addEventListener would never trigger.
  // Same guard as tasks.cshtml / gaps.cshtml use.
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    const list = document.getElementById("docListView");
    if (!list) return;
    showView("list");    // start on the list view

    bindEvents();
    await Promise.all([populateOrgFilter(), loadGlobalLookups()]);
    // Auto-select the first (or only) allowed org so records load on
    // initial page render -- matches Task Center / Gap Center behaviour.
    const sel = document.getElementById("docFilterOrganization");
    if (sel.options.length > 1 && !state.organizationId) {
      sel.selectedIndex = 1; // skip the "Select organization" placeholder
      state.organizationId = Number(sel.value) || null;
      if (state.organizationId) {
        await loadOrgScopedLookups();
        await refresh();
      }
    }
  }

  // Fetches allowed orgs from the same endpoint tasks.cshtml / gaps.cshtml
  // use, and populates the filter select. Falls back to an empty list on
  // error so the UI still renders (empty state row explains what to do).
  async function populateOrgFilter() {
    const sel = document.getElementById("docFilterOrganization");
    let rows = [];
    try {
      const r = await fetch(U("/practice/api/organizations/allowed"), { credentials: "same-origin" });
      if (r.ok) {
        const b = await r.json();
        rows = (b && (b.data || b.Data)) || [];
      }
    } catch (_) { /* ignore, leave rows empty */ }

    rows.forEach(row => {
      const value = String(row.organizationId ?? row.OrganizationId ?? "");
      const label = String(row.organizationName ?? row.OrganizationName ?? "");
      if (!value) return;
      const opt = document.createElement("option");
      opt.value = value;
      opt.textContent = label;
      sel.appendChild(opt);
    });

    // If the caller only has one org, disable the dropdown (nothing to switch to).
    if (sel.options.length === 2) sel.disabled = true;
  }

  function bindEvents() {
    document.getElementById("docFilterOrganization").addEventListener("change", e => {
      state.organizationId = e.target.value ? Number(e.target.value) : null;
      state.page = 1;
      loadOrgScopedLookups().then(refresh);
    });
    ["docFilterType", "docFilterStage", "docFilterStatus"].forEach(id => {
      document.getElementById(id).addEventListener("change", e => {
        const key = id === "docFilterType" ? "typeId" : id === "docFilterStage" ? "stageId" : "statusId";
        state[key] = e.target.value ? Number(e.target.value) : -1;
        state.page = 1;
        refresh();
      });
    });
    document.getElementById("docSearch").addEventListener("input", debounce(e => {
      state.search = e.target.value.trim();
      state.page = 1;
      refresh();
    }, 300));
    document.getElementById("docRefreshBtn").addEventListener("click", refresh);
    document.getElementById("docNewBtn").addEventListener("click", () => showSaveView(null));
    document.getElementById("docPrev").addEventListener("click", () => { if (state.page > 1) { state.page--; refresh(); } });
    document.getElementById("docNext").addEventListener("click", () => { state.page++; refresh(); });

    document.getElementById("docSaveForm").addEventListener("submit", onSaveSubmit);
    document.getElementById("docSaveDistType").addEventListener("change", onDistTypeChange);

    document.getElementById("docWorkflowForm").addEventListener("submit", onWorkflowSubmit);

    // Any element carrying data-doc-back returns to the list view.
    document.querySelectorAll("[data-doc-back]").forEach(el =>
      el.addEventListener("click", () => showView("list")));

    // 3-dot row action menu -- delegated click handling on the module root.
    wireRowMenu();
  }

  // -------------------- lookups ----------------------------------------
  async function loadGlobalLookups() {
    // Source-types omitted -- source is server-defaulted to UPLOADED for
    // documents added through this screen.
    const [types, stages, statuses, distributions] = await Promise.all([
      apiGet("lookups/types"),
      apiGet("lookups/stages"),
      apiGet("lookups/statuses"),
      apiGet("lookups/distribution-types")
    ]);
    state.lookups.types         = types || [];
    state.lookups.stages        = stages || [];
    state.lookups.statuses      = statuses || [];
    state.lookups.distributions = distributions || [];

    fillSelect("docFilterType",   state.lookups.types,    "documentTypeId",   "documentType",   { includeAll: true, allLabel: "All types",    allVal: -1 });
    fillSelect("docFilterStage",  state.lookups.stages,   "documentStageId",  "documentStage",  { includeAll: true, allLabel: "All stages",   allVal: -1 });
    fillSelect("docFilterStatus", state.lookups.statuses, "documentStatusId", "documentStatus", { includeAll: true, allLabel: "All statuses", allVal: -1 });
  }

  async function loadOrgScopedLookups() {
    if (!state.organizationId) return;
    const [departments, employees] = await Promise.all([
      apiGet(`lookups/departments?organizationId=${state.organizationId}`),
      apiGet(`lookups/employees?organizationId=${state.organizationId}`)
    ]);
    state.lookups.departments = departments || [];
    state.lookups.employees   = employees   || [];
  }

  // -------------------- list -------------------------------------------
  async function refresh() {
    if (!state.organizationId) return;
    const qs = new URLSearchParams({
      organizationId: state.organizationId,
      typeId:   state.typeId,
      stageId:  state.stageId,
      statusId: state.statusId,
      search:   state.search,
      page:     state.page,
      pageSize: state.pageSize
    });
    const data = await apiGet(`?${qs}`);
    renderList(data);
  }

  function renderList(data) {
    const tbody = document.getElementById("docTableBody");
    tbody.innerHTML = "";
    const rows = data?.rows || [];
    if (!rows.length) {
      tbody.innerHTML = `<tr><td colspan="9" class="pm-empty-row">No documents match the current filters.</td></tr>`;
      document.getElementById("docPager").hidden = true;
      return;
    }
    rows.forEach(r => {
      const tr = document.createElement("tr");
      tr.dataset.docId  = r.documentId;
      tr.dataset.stage  = r.documentStage;
      tr.dataset.status = r.documentStatus;
      tr.innerHTML = `
        <td>${escapeHtml(r.documentCode)}</td>
        <td>${escapeHtml(r.documentName)}</td>
        <td>${escapeHtml(r.documentType)}</td>
        <td>${escapeHtml(r.versionNumber)}</td>
        <td>${escapeHtml(r.documentStage)}</td>
        <td>${escapeHtml(r.documentStatus)}</td>
        <td>${r.nextReviewDate ? new Date(r.nextReviewDate).toLocaleDateString() : "--"}</td>
        <td>${r.lastActivityDt ? new Date(r.lastActivityDt).toLocaleString() : "--"}</td>
        <td>
          <button type="button" class="pm-action-trigger" data-doc-menu="${r.documentId}"
                  aria-haspopup="menu" aria-expanded="false" title="Actions">
            <i class="fas fa-ellipsis-v fa-solid fa-ellipsis-vertical" aria-hidden="true"></i>
            <span class="visually-hidden">Actions</span>
          </button>
        </td>`;
      tbody.appendChild(tr);
    });

    const total = Number(data?.totalRows || 0);
    const pager = document.getElementById("docPager");
    pager.hidden = false;
    document.getElementById("docPageInfo").textContent =
      `Page ${state.page} of ${Math.max(1, Math.ceil(total / state.pageSize))} (${total} total)`;
    document.getElementById("docPrev").disabled = state.page <= 1;
    document.getElementById("docNext").disabled = state.page * state.pageSize >= total;
  }

  // -------------------- 3-dot row menu (PM standard) -------------------
  // Same pattern the Task Center and Gap Center use: one `pm-action-trigger`
  // per row, click opens a floating `.pm-action-menu` positioned relative
  // to the trigger. Close on outside click, Escape, resize, or scroll.
  let openMenuEl = null;
  let openMenuTrigger = null;

  function closeRowMenu() {
    if (openMenuEl) { openMenuEl.remove(); openMenuEl = null; }
    if (openMenuTrigger) {
      openMenuTrigger.setAttribute("aria-expanded", "false");
      openMenuTrigger = null;
    }
  }

  function positionRowMenu(trigger) {
    if (!openMenuEl) return;
    const r  = trigger.getBoundingClientRect();
    const mr = openMenuEl.getBoundingClientRect();
    const gap = 6;
    let top = r.bottom + gap, left = r.right - mr.width;
    if (top + mr.height > window.innerHeight - 8) top = Math.max(8, r.top - mr.height - gap);
    if (left < 8) left = 8;
    if (left + mr.width > window.innerWidth - 8) left = window.innerWidth - mr.width - 8;
    openMenuEl.style.top  = top  + "px";
    openMenuEl.style.left = left + "px";
  }

  function openRowMenu(trigger, items) {
    closeRowMenu();
    openMenuTrigger = trigger;
    trigger.setAttribute("aria-expanded", "true");
    openMenuEl = document.createElement("div");
    openMenuEl.className = "pm-action-menu";
    openMenuEl.setAttribute("role", "menu");
    for (const it of items) {
      const b = document.createElement("button");
      b.type = "button";
      b.setAttribute("role", "menuitem");
      b.innerHTML = `<i class="fa-solid ${escapeHtml(it.icon)}" aria-hidden="true"></i> ${escapeHtml(it.label)}`;
      if (it.disabled) { b.disabled = true; b.title = it.disabledReason || ""; }
      b.addEventListener("click", ev => {
        ev.preventDefault();
        ev.stopPropagation();
        closeRowMenu();
        try { it.action(); } catch (err) { console.error("[document-uploads] menu action failed", err); }
      });
      openMenuEl.appendChild(b);
    }
    document.body.appendChild(openMenuEl);
    positionRowMenu(trigger);
  }

  function buildRowMenu(tr) {
    const id     = Number(tr.dataset.docId);
    const stage  = tr.dataset.stage;
    const status = tr.dataset.status;

    // Base actions available for every document regardless of stage.
    const items = [
      { icon: "fa-eye", label: "View",
        action: () => window.open(U(`${base}/${id}/file?inline=true`), "_blank") },
      { icon: "fa-download", label: "Download",
        action: () => window.open(U(`${base}/${id}/file`), "_blank") },
      { icon: "fa-pen", label: "Edit",
        action: () => showSaveView(id) }
    ];

    // Stage-conditional workflow actions. Menu shows ONLY the next legal
    // step (as opposed to greying out disallowed ones):
    //   Draft     -> Review
    //   Reviewed  -> Approve
    //   Published -> neither (workflow complete)
    if (stage === "Draft") {
      items.push({ icon: "fa-clipboard-check", label: "Review",
        action: () => showWorkflowView(id, "Review", "Review Document") });
    } else if (stage === "Reviewed") {
      items.push({ icon: "fa-check-double", label: "Approve",
        action: () => showWorkflowView(id, "Approve", "Approve Document") });
    }

    // Toggle between Active and Retired -- label follows current status.
    items.push({ icon: "fa-power-off",
      label: status === "Active" ? "Retire" : "Reactivate",
      action: async () => {
        const verb = status === "Active" ? "Retire" : "Reactivate";
        if (!confirm(`${verb} this document?`)) return;
        await apiPost(`${id}/toggle-status?organizationId=${state.organizationId}`, {
          callerEmployeeId:  window.pmEmployeeId ? Number(window.pmEmployeeId) : null,
          callerDisplayName: window.pmUserName || null
        });
        await refresh();
      } });

    return items;
  }

  function wireRowMenu() {
    const root = document.getElementById("docListView");
    if (!root) return;
    root.addEventListener("click", ev => {
      const trigger = ev.target.closest(".pm-action-trigger[data-doc-menu]");
      if (!trigger || !root.contains(trigger)) return;
      ev.preventDefault();
      ev.stopPropagation();
      const tr = trigger.closest("tr");
      if (!tr) return;
      if (openMenuTrigger === trigger) { closeRowMenu(); return; }
      openRowMenu(trigger, buildRowMenu(tr));
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

  // -------------------- save view (full page) --------------------------
  async function showSaveView(documentId) {
    if (!state.organizationId) { alert("Select an organization first."); return; }
    await loadOrgScopedLookups();

    fillSelect("docSaveTypeId",     state.lookups.types,         "documentTypeId",     "documentType");
    fillSelect("docSaveDistType",   state.lookups.distributions, "distributionCode",   "distributionType", { includePlaceholder: true });
    fillSelect("docSaveOwnerId",    state.lookups.employees,     "employeeId",         "employeeName",     { includePlaceholder: true });
    fillSelect("docSaveReviewerId", state.lookups.employees,     "employeeId",         "employeeName",     { includePlaceholder: true });
    fillSelect("docSaveApproverId", state.lookups.employees,     "employeeId",         "employeeName",     { includePlaceholder: true });

    // Searchable multi-select pickers (re-init per open so options reflect
    // the currently loaded org and previous state does not leak between
    // documents).
    state.pickers.departments = new MultiSelect(document.getElementById("docSaveDistDepts"),
      state.lookups.departments.map(d => ({ value: d.departmentId, label: d.departmentName })));
    state.pickers.employees   = new MultiSelect(document.getElementById("docSaveDistEmps"),
      state.lookups.employees.map(e => ({ value: e.employeeId,   label: e.employeeName })));

    document.getElementById("docSaveDocumentId").value     = documentId || "";
    document.getElementById("docSaveOrganizationId").value = state.organizationId;
    document.getElementById("docSaveTitle").textContent    = documentId ? "Edit Document" : "New Document";
    document.getElementById("docSaveFileHint").textContent = documentId ? "(optional -- upload only to add a new version)" : "(required)";
    document.getElementById("docSaveFile").required        = !documentId;
    document.getElementById("docSaveMessage").textContent  = "";

    if (documentId) {
      const detail = await apiGet(`${documentId}`);
      if (detail) prefill(detail);
    } else {
      document.getElementById("docSaveForm").reset();
      document.getElementById("docSaveDocumentId").value     = "";
      document.getElementById("docSaveOrganizationId").value = state.organizationId;
    }
    onDistTypeChange();
    showView("save");
  }

  function prefill(d) {
    setVal("docSaveName",           d.documentName);
    setVal("docSaveCompanyCode",    d.companyDocumentCode);
    setVal("docSaveTypeId",         d.documentTypeId);
    setVal("docSaveVersion",        d.versionNumber);
    setVal("docSaveEffective",      d.effectiveDate ? d.effectiveDate.substring(0, 10) : "");
    setVal("docSaveNextReview",     d.nextReviewDate ? d.nextReviewDate.substring(0, 10) : "");
    setVal("docSaveOwnerId",        d.ownerId);
    setVal("docSaveReviewerId",     d.reviewerId);
    setVal("docSaveApproverId",     d.approverId);
    setVal("docSaveChangeSummary",  d.changeSummary || "");
    setVal("docSaveKeywords",       d.keywordsTag || "");
    document.getElementById("docSaveAckRequired").checked = !!d.acknowledgementRequired;

    const distSel = document.getElementById("docSaveDistType");
    if (d.distributionType) distSel.value = d.distributionType;
  }

  function onDistTypeChange() {
    const code = document.getElementById("docSaveDistType").value;
    document.getElementById("docSaveDistDeptWrap").hidden = code !== "Departments";
    document.getElementById("docSaveDistEmpWrap").hidden  = code !== "Users";
  }

  async function onSaveSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("docSaveMessage");
    msg.textContent = "";

    const form  = document.getElementById("docSaveForm");
    const docId = document.getElementById("docSaveDocumentId").value;
    const fd    = new FormData(form);

    // Multi-select DistributionIds -> comma-separated (from MultiSelect)
    const distType = document.getElementById("docSaveDistType").value;
    fd.delete("DistributionIds");
    if (distType === "Departments" && state.pickers.departments) {
      fd.append("DistributionIds", state.pickers.departments.values().join(","));
    } else if (distType === "Users" && state.pickers.employees) {
      fd.append("DistributionIds", state.pickers.employees.values().join(","));
    }

    // Audit stamps
    if (window.pmEmployeeId) fd.append("CallerEmployeeId", window.pmEmployeeId);
    if (window.pmUserName)   fd.append("CallerDisplayName", window.pmUserName);

    const url    = docId ? U(`${base}/${docId}`) : U(base);
    const method = docId ? "PUT" : "POST";
    try {
      const resp = await fetch(url, { method, body: fd, credentials: "same-origin" });
      const text = await resp.text();
      let body = {};
      try { body = text ? JSON.parse(text) : {}; } catch (_) { body = { error: text }; }

      // Log both the status and body so a mismatch between what the DB
      // did and what the browser sees is visible in DevTools.
      console.log("[docs-save]", method, url, "->", resp.status, body);

      if (!resp.ok || body.success === false) {
        const errText = body.error || `Save failed (HTTP ${resp.status}).`;
        msg.textContent   = errText;
        msg.style.color   = "#c53030";
        msg.style.padding = "8px";
        msg.style.border  = "1px solid #feb2b2";
        msg.style.background = "#fff5f5";
        msg.style.borderRadius = "4px";
        // Pop so the message cannot be missed. window.gracAlert
        // (grac-dialog.js, loaded by _Layout) is the app's dialog -- same
        // call shape Exception Centre and Risk Centre use. A bare alert()
        // renders as an "Information" box, which made a one-word server
        // error look like a stray notice rather than a failed save.
        saveAlert("Save failed", errText);
        return;
      }
      msg.textContent = "";
      msg.removeAttribute("style");
      showView("list");
      await refresh();
    } catch (err) {
      console.error("[docs-save] network error", err);
      msg.textContent = "Network error: " + err.message;
      msg.style.color = "#c53030";
      saveAlert("Network error", err.message);
    }
  }

  // House dialog with a plain-alert fallback for the case where
  // grac-dialog.js has not loaded (same guard style as risk-centre.js).
  function saveAlert(title, message) {
    const show = window.gracAlert || (o => window.alert(`${o.title}: ${o.message}`));
    show({ type: "error", title, message: message || "Unknown error." });
  }

  // -------------------- workflow view (split pane with PDF) ------------
  async function showWorkflowView(documentId, transition, title) {
    document.getElementById("docWorkflowDocumentId").value = documentId;
    document.getElementById("docWorkflowTransition").value = transition;
    document.getElementById("docWorkflowTitle").textContent = title;
    document.getElementById("docWorkflowDecision").value = "Approve";
    document.getElementById("docWorkflowRemark").value = "";
    document.getElementById("docWorkflowMessage").textContent = "";

    // Load metadata for the left summary panel.
    const detail = await apiGet(`${documentId}`);
    const meta = document.getElementById("docWorkflowMeta");
    if (detail) {
      meta.innerHTML =
        `<dt>Code</dt><dd>${escapeHtml(detail.documentCode || "")}</dd>` +
        `<dt>Name</dt><dd>${escapeHtml(detail.documentName || "")}</dd>` +
        `<dt>Type</dt><dd>${escapeHtml(detail.documentType || "")}</dd>` +
        `<dt>Version</dt><dd>${escapeHtml(detail.versionNumber || "")}</dd>` +
        `<dt>Current stage</dt><dd>${escapeHtml(detail.documentStage || "")}</dd>` +
        `<dt>Owner</dt><dd>${escapeHtml(detail.ownerName || "--")}</dd>`;
    } else {
      meta.innerHTML = `<dd>Could not load document details.</dd>`;
    }

    // Fetch the file as a Blob and hand a same-origin blob: URL to the
    // iframe. This bypasses X-Frame-Options / CSP frame-ancestors headers
    // set by upstream reverse proxies (IIS / nginx / CDN) which would
    // otherwise show "refused to connect" in the iframe on production.
    // The plain server URL is kept as the "Open in new tab" fallback.
    const fileUrl = U(`${base}/${documentId}/file?inline=true`);
    const iframe  = document.getElementById("docWorkflowPdf");
    const empty   = document.getElementById("docWorkflowPdfEmpty");
    const msg2    = document.getElementById("docWorkflowPdfMessage");
    const link    = document.getElementById("docWorkflowPdfLink");
    if (link) link.setAttribute("href", fileUrl);

    // Reset viewer + release any earlier blob URL to avoid a memory leak.
    if (iframe) {
      if (iframe.dataset.blobUrl) { try { URL.revokeObjectURL(iframe.dataset.blobUrl); } catch (_) {} }
      iframe.removeAttribute("data-blob-url");
      iframe.setAttribute("src", "about:blank");
    }
    if (empty) empty.hidden = true;

    try {
      const resp = await fetch(fileUrl, { method: "GET", credentials: "same-origin" });
      if (!resp.ok) {
        if (empty) { empty.hidden = false; msg2.textContent = `Could not load file (HTTP ${resp.status}).`; }
        return;
      }
      const ct   = (resp.headers.get("Content-Type") || "").toLowerCase();
      const blob = await resp.blob();
      // Force the blob's own type to application/pdf when the server
      // reported PDF; otherwise pass through whatever came back.
      const typed = ct.includes("pdf")
        ? new Blob([blob], { type: "application/pdf" })
        : blob;
      const url = URL.createObjectURL(typed);
      if (iframe) {
        iframe.dataset.blobUrl = url;
        iframe.setAttribute("src", url);
      }
      // If it wasn't a PDF, also surface the fallback so the user can
      // download it via the "Open in new tab" link on top of the preview.
      if (!ct.includes("pdf") && empty) {
        empty.hidden = false;
        msg2.textContent = `Preview may not render for this file type (${ct || "unknown"}). Use "Open in new tab" to download.`;
      }
    } catch (err) {
      console.error("[docs] pdf preview failed", err);
      if (empty) { empty.hidden = false; msg2.textContent = "Network error loading file preview."; }
    }

    showView("workflow");
  }

  async function onWorkflowSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("docWorkflowMessage");
    msg.textContent = "";
    const id  = document.getElementById("docWorkflowDocumentId").value;
    const payload = {
      transition:        document.getElementById("docWorkflowTransition").value,
      decision:          document.getElementById("docWorkflowDecision").value,
      remark:            document.getElementById("docWorkflowRemark").value,
      callerEmployeeId:  window.pmEmployeeId ? Number(window.pmEmployeeId) : null,
      callerDisplayName: window.pmUserName || null
    };
    const result = await apiPost(`${id}/workflow`, payload);
    if (!result || result.success === false) {
      msg.textContent = (result && result.error) || "Workflow transition failed.";
      return;
    }
    showView("list");
    await refresh();
  }

  // -------------------- helpers ----------------------------------------
  function fillSelect(id, rows, valueKey, textKey, opts = {}) {
    const el = document.getElementById(id);
    if (!el) return;
    el.innerHTML = "";
    if (opts.includePlaceholder) {
      el.appendChild(new Option("--", ""));
    } else if (opts.includeAll) {
      el.appendChild(new Option(opts.allLabel || "All", String(opts.allVal ?? -1)));
    }
    rows.forEach(r => {
      const v = r[valueKey] ?? r[valueKey?.[0]?.toLowerCase() + valueKey?.slice(1)] ?? "";
      const t = r[textKey]  ?? r[textKey?.[0]?.toLowerCase()  + textKey?.slice(1)]  ?? "";
      el.appendChild(new Option(t, v));
    });
  }

  function setVal(id, v) {
    const el = document.getElementById(id);
    if (el != null) el.value = v == null ? "" : v;
  }

  function show(id) { const el = document.getElementById(id); if (el) el.hidden = false; }
  function hide(id) { const el = document.getElementById(id); if (el) el.hidden = true; }

  // Swap between the three top-level views inside the partial. Also
  // resets the PDF viewer when leaving the workflow view so the browser
  // stops fetching / rendering the previous document.
  function showView(name) {
    const map = { list: "docListView", save: "docSaveView", workflow: "docWorkflowView" };
    Object.entries(map).forEach(([k, id]) => {
      const el = document.getElementById(id);
      if (el) el.hidden = (k !== name);
    });
    if (name !== "workflow") {
      const iframe = document.getElementById("docWorkflowPdf");
      if (iframe) iframe.setAttribute("src", "about:blank");
      const empty = document.getElementById("docWorkflowPdfEmpty");
      if (empty) empty.hidden = true;
    }
    // Scroll to top on view swap so long forms do not open mid-page.
    window.scrollTo({ top: 0, behavior: "instant" in window ? "instant" : "auto" });
  }

  function escapeHtml(s) {
    if (s == null) return "";
    return String(s).replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
  }

  function debounce(fn, ms) {
    let t;
    return function (...args) {
      clearTimeout(t);
      t = setTimeout(() => fn.apply(this, args), ms);
    };
  }

  async function apiGet(path) {
    // Absolute / already-prefixed paths pass through; relative paths get
    // both the module base and (via U) the app base path prefix.
    const url = path.startsWith("http")
      ? path
      : path.startsWith("/")
        ? U(path)
        : U(`${base}/${path.replace(/^\//, "")}`);
    try {
      const r = await fetch(url, { credentials: "same-origin" });
      if (!r.ok) { console.warn("docs GET", url, r.status); return null; }
      return await r.json();
    } catch (err) {
      console.error("docs GET failed", url, err);
      return null;
    }
  }

  async function apiPost(path, body) {
    const url = U(`${base}/${path.replace(/^\//, "")}`);
    try {
      const r = await fetch(url, {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok) return { success: false, error: data.error || `HTTP ${r.status}` };
      return data;
    } catch (err) {
      console.error("docs POST failed", url, err);
      return { success: false, error: err.message };
    }
  }

  // -------------------- MultiSelect (searchable combobox) --------------
  //
  // Lightweight, no-dependencies picker used for Departments and Employees.
  // API:
  //   const ms = new MultiSelect(hostEl, [{value, label}, ...]);
  //   ms.values()          -> array of selected value strings
  //   ms.setSelected(vals) -> highlight a set of values
  //
  // Behaviour:
  //   * Focus opens the dropdown, click-outside closes it.
  //   * Typing filters the option list (case-insensitive).
  //   * ArrowUp/Down navigate, Enter toggles.
  //   * Selected items render as chips inside the input area; the X on a
  //     chip removes that value.
  //
  // Not extracted to a shared file yet because it is only used here; if a
  // second module needs it, promote to wwwroot/js/pm-multiselect.js.
  class MultiSelect {
    constructor(host, options) {
      this.host = host;
      this.options = options || [];
      this.selected = new Set();
      this.placeholder = host.getAttribute("data-placeholder") || "Type to search...";
      this._render();
      this._bind();
    }

    values() { return [...this.selected]; }

    setSelected(vals) {
      this.selected = new Set((vals || []).map(String));
      this._syncChips();
    }

    _render() {
      this.host.innerHTML = "";
      this.host.classList.add("pm-multiselect");
      this.input = document.createElement("div");
      this.input.className = "pm-multiselect-input";
      this.chips = document.createElement("div");
      this.chips.className = "pm-multiselect-chips";
      this.chips.style.display = "contents";
      this.search = document.createElement("input");
      this.search.type = "text";
      this.search.className = "pm-multiselect-search";
      this.search.placeholder = this.placeholder;
      this.input.appendChild(this.chips);
      this.input.appendChild(this.search);
      this.dropdown = document.createElement("div");
      this.dropdown.className = "pm-multiselect-dropdown";
      this.dropdown.hidden = true;
      this.list = document.createElement("ul");
      this.list.className = "pm-multiselect-options";
      this.list.style.listStyle = "none";
      this.list.style.margin = "0";
      this.list.style.padding = "0";
      this.dropdown.appendChild(this.list);
      this.host.appendChild(this.input);
      this.host.appendChild(this.dropdown);
      this._renderOptions("");
    }

    _bind() {
      this.input.addEventListener("click", () => { this.search.focus(); this._open(); });
      this.search.addEventListener("focus", () => this._open());
      this.search.addEventListener("input", () => this._renderOptions(this.search.value));
      this.search.addEventListener("keydown", ev => this._onKey(ev));
      document.addEventListener("mousedown", ev => {
        if (!this.host.contains(ev.target)) this._close();
      });
    }

    _open()  { this.dropdown.hidden = false; }
    _close() { this.dropdown.hidden = true; this._hi = -1; }

    _onKey(ev) {
      const items = [...this.list.querySelectorAll(".pm-multiselect-option")];
      if (!items.length) return;
      if (ev.key === "ArrowDown" || ev.key === "ArrowUp") {
        ev.preventDefault();
        this._hi = ((this._hi ?? -1) + (ev.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
        items.forEach(i => i.classList.remove("pm-hi"));
        items[this._hi].classList.add("pm-hi");
        items[this._hi].scrollIntoView({ block: "nearest" });
      } else if (ev.key === "Enter" && this._hi >= 0) {
        ev.preventDefault();
        items[this._hi].click();
      } else if (ev.key === "Escape") {
        this._close();
      }
    }

    _renderOptions(term) {
      const q = (term || "").toLowerCase().trim();
      const matches = this.options.filter(o =>
        !q || String(o.label).toLowerCase().includes(q));
      this.list.innerHTML = "";
      if (!matches.length) {
        const li = document.createElement("li");
        li.className = "pm-multiselect-empty";
        li.textContent = q ? "No matches" : "No options available";
        this.list.appendChild(li);
        return;
      }
      matches.forEach(o => {
        const li = document.createElement("li");
        li.className = "pm-multiselect-option";
        const key = String(o.value);
        li.dataset.value = key;
        const cb = document.createElement("input");
        cb.type = "checkbox";
        cb.checked = this.selected.has(key);
        li.appendChild(cb);
        const span = document.createElement("span");
        span.textContent = o.label;
        li.appendChild(span);
        li.addEventListener("click", ev => {
          ev.preventDefault();
          if (this.selected.has(key)) this.selected.delete(key);
          else                        this.selected.add(key);
          cb.checked = this.selected.has(key);
          this._syncChips();
          this.search.focus();
        });
        this.list.appendChild(li);
      });
    }

    _syncChips() {
      this.chips.innerHTML = "";
      this.options
        .filter(o => this.selected.has(String(o.value)))
        .forEach(o => {
          const chip = document.createElement("span");
          chip.className = "pm-multiselect-chip";
          chip.textContent = o.label;
          const x = document.createElement("button");
          x.type = "button";
          x.textContent = "×";
          x.title = "Remove";
          x.addEventListener("click", ev => {
            ev.stopPropagation();
            this.selected.delete(String(o.value));
            this._syncChips();
            this._renderOptions(this.search.value);
          });
          chip.appendChild(x);
          this.chips.appendChild(chip);
        });
    }
  }
})();
