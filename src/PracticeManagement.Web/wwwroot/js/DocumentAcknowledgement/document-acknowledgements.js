// =====================================================================
// Document Acknowledgements -- admin batches (Phase 2)
//
// Loaded by Views/Practice/Partials/document-acknowledgements.cshtml.
// Same conventions as document-uploads.js: fetch via /practice/api/... ,
// U() prefix for app base path, DOMContentLoaded guard.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/document-acknowledgements";

  const state = {
    organizationId: null,
    detailId: null,          // active batch when in detail view
    docSelectedId: null      // active doc within detail
  };

  // pm-grid handle for the BATCH list only. sp_document_ack_list has
  // paged at 25 since 151, but this screen sent no page parameter, so
  // batch 26 onwards could not be reached. The detail view's user and
  // document tables are children of one batch and are left unpaged.
  // null when pm-grid.js has not loaded; every use is optional-chained.
  let pager = null;

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    if (!document.getElementById("ackListView")) return;
    showView("list");
    bindEvents();
    await populateOrgFilter();
    const sel = document.getElementById("ackFilterOrganization");
    if (sel.options.length > 1 && !state.organizationId) {
      sel.selectedIndex = 1;
      state.organizationId = Number(sel.value) || null;
      if (state.organizationId) await refreshBatches();
    }
  }

  // -------------------- events ----------------------------------------
  function bindEvents() {
    // Mounted before the first refreshBatches() so the very first fetch
    // already carries a page number.
    pager = window.__pmGrid ? window.__pmGrid.attach({
      hostId:   "ackPager",
      onChange: refreshBatches      // refetch -- never slice locally
    }) : null;

    document.getElementById("ackFilterOrganization").addEventListener("change", async e => {
      state.organizationId = e.target.value ? Number(e.target.value) : null;
      // A different organisation is a different data set. Silent, because
      // refreshBatches() is called right after.
      pager?.reset(true);
      await refreshBatches();
    });
    // Refresh is NOT a filter change: it re-reads the page the user is
    // on, so it must not reset. Returning from the detail view (below)
    // does not reset either -- the user came back to where they were.
    document.getElementById("ackRefreshBtn").addEventListener("click", refreshBatches);
    document.getElementById("ackNewBtn").addEventListener("click", showCreateView);

    document.querySelectorAll("[data-ack-back]").forEach(el =>
      el.addEventListener("click", () => { state.detailId = null; state.docSelectedId = null; showView("list"); refreshBatches(); }));

    document.getElementById("ackPendingAll").addEventListener("change", ev => {
      document.querySelectorAll("#ackPendingBody input[type=checkbox]").forEach(cb => cb.checked = ev.target.checked);
    });

    document.getElementById("ackCreateForm").addEventListener("submit", onCreateSubmit);
  }

  // -------------------- orgs ------------------------------------------
  async function populateOrgFilter() {
    const sel = document.getElementById("ackFilterOrganization");
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

  // -------------------- list view -------------------------------------
  async function refreshBatches() {
    const tbody = document.getElementById("ackTableBody");
    if (!state.organizationId) {
      pager?.clear();
      tbody.innerHTML = `<tr><td colspan="9" class="pm-empty-row">Select an organization to load batches.</td></tr>`;
      return;
    }
    // The endpoint's parameter is "page", not "pageNumber".
    const paging = pager ? `&page=${pager.page()}&pageSize=${pager.size()}` : "";
    const data = await apiGet(`?organizationId=${state.organizationId}${paging}`);
    const rows = data?.rows || [];
    // Row count as well as the total, so a short last page reads
    // "26-31 of 31" rather than assuming every page is full.
    pager?.setTotal(data?.totalRows, rows.length);
    if (!rows.length) {
      tbody.innerHTML = `<tr><td colspan="9" class="pm-empty-row">No acknowledgement batches yet. Click "New Batch" to create one from pending documents.</td></tr>`;
      return;
    }
    tbody.innerHTML = "";
    rows.forEach(r => {
      const tr = document.createElement("tr");
      tr.dataset.ackId = r.acknowledgementId;
      tr.innerHTML = `
        <td><a href="#" class="ack-detail-link">${escapeHtml(r.acknowledgementName)}</a></td>
        <td>${r.dueDate ? window.gracFormatDateOnly(r.dueDate) : "--"}</td>
        <td>${r.documentCount}</td>
        <td>${r.userCount}</td>
        <td>${r.ackCount}</td>
        <td>${progressBar(r.completionPct)}</td>
        <td>${progressChip(r.progressLabel)}</td>
        <td>${escapeHtml(r.createdBy || "")}<br><span class="pm-hint">${window.gracFormatDisplayDate(r.createdOn)}</span></td>
        <td>
          <button type="button" class="pm-action-trigger" data-ack-menu="${r.acknowledgementId}"
                  aria-haspopup="menu" aria-expanded="false" title="Actions">
            <i class="fas fa-ellipsis-v fa-solid fa-ellipsis-vertical" aria-hidden="true"></i>
          </button>
        </td>`;
      tr.querySelector(".ack-detail-link").addEventListener("click", ev => {
        ev.preventDefault();
        openDetail(r.acknowledgementId, r);
      });
      tbody.appendChild(tr);
    });
    wireRowMenu();
  }

  // -------------------- create view -----------------------------------
  async function showCreateView() {
    if (!state.organizationId) { alert("Select an organization first."); return; }
    document.getElementById("ackCreateName").value    = "";
    document.getElementById("ackCreateDueDate").value = "";
    document.getElementById("ackCreateMessage").textContent = "";
    showView("create");
    await loadPending();
  }

  async function loadPending() {
    const tbody = document.getElementById("ackPendingBody");
    tbody.innerHTML = `<tr><td colspan="6" class="pm-empty-row">Loading...</td></tr>`;
    const data = await apiGet(`/pending?organizationId=${state.organizationId}`);
    const rows = data?.rows || [];
    if (!rows.length) {
      tbody.innerHTML = `<tr><td colspan="6" class="pm-empty-row">No pending documents. Publish a document with "Acknowledgement required" checked to see it here.</td></tr>`;
      return;
    }
    tbody.innerHTML = "";
    rows.forEach(r => {
      const tr = document.createElement("tr");
      tr.innerHTML = `
        <td><input type="checkbox" name="pending" value="${r.pendingId}" /></td>
        <td>${escapeHtml(r.documentCode)}</td>
        <td>${escapeHtml(r.documentName)}</td>
        <td>${escapeHtml(r.versionNumber)}</td>
        <td>${r.cycleNo}</td>
        <td>${window.gracFormatDisplayDate(r.queuedOn)}</td>`;
      tbody.appendChild(tr);
    });
  }

  async function onCreateSubmit(ev) {
    ev.preventDefault();
    const msg  = document.getElementById("ackCreateMessage");
    msg.textContent = "";
    const name = document.getElementById("ackCreateName").value.trim();
    const due  = document.getElementById("ackCreateDueDate").value;
    const picks = [...document.querySelectorAll("#ackPendingBody input[type=checkbox]:checked")]
      .map(cb => Number(cb.value)).filter(n => n > 0);
    if (!name)       { msg.textContent = "Batch name is required."; return; }
    if (!picks.length) { msg.textContent = "Pick at least one pending document."; return; }

    const payload = {
      organizationId:      state.organizationId,
      acknowledgementName: name,
      dueDate:             due || null,
      pendingIds:          picks
    };
    const result = await apiPost("", payload);
    if (!result || result.success === false) {
      msg.textContent = (result && result.error) || "Create failed.";
      return;
    }
    showView("list");
    await refreshBatches();
  }

  // -------------------- detail view -----------------------------------
  async function openDetail(id, listRow) {
    state.detailId      = id;
    state.docSelectedId = null;
    document.getElementById("ackDetailTitle").textContent = listRow?.acknowledgementName || "Batch";

    const meta = document.getElementById("ackDetailMeta");
    if (listRow) {
      meta.innerHTML =
        `<dt>Due</dt><dd>${listRow.dueDate ? window.gracFormatDateOnly(listRow.dueDate) : "--"}</dd>` +
        `<dt>Status</dt><dd>${progressChip(listRow.progressLabel)}</dd>` +
        `<dt>Documents</dt><dd>${listRow.documentCount}</dd>` +
        `<dt>Users</dt><dd>${listRow.userCount}</dd>` +
        `<dt>Acknowledged</dt><dd>${listRow.ackCount} (${Number(listRow.completionPct).toFixed(0)}%)</dd>` +
        `<dt>Created</dt><dd>${escapeHtml(listRow.createdBy || "")} @ ${window.gracFormatDisplayDate(listRow.createdOn)}</dd>`;
    }

    // Clear right pane; show hint until a doc is picked.
    document.getElementById("ackUsersHeader").textContent = "Users";
    document.getElementById("ackUsersHint").hidden = false;
    document.getElementById("ackUsersWrap").hidden = true;
    document.getElementById("ackDetailUsersBody").innerHTML = "";

    showView("detail");
    await loadBatchDocs(id);
  }

  async function loadBatchDocs(id) {
    const tbody = document.getElementById("ackDetailDocsBody");
    tbody.innerHTML = `<tr><td colspan="5" class="pm-empty-row">Loading...</td></tr>`;
    const rows = await apiGet(`/${id}/documents`);
    if (!Array.isArray(rows) || !rows.length) {
      tbody.innerHTML = `<tr><td colspan="5" class="pm-empty-row">No documents in this batch.</td></tr>`;
      return;
    }
    tbody.innerHTML = "";
    rows.forEach(r => {
      const tr = document.createElement("tr");
      tr.dataset.docId = r.documentId;
      tr.innerHTML = `
        <td>${escapeHtml(r.documentCode)}</td>
        <td>${escapeHtml(r.documentName)}</td>
        <td>${r.userCount}</td>
        <td>${r.ackCount}</td>
        <td>${progressBar(r.completionPct)}<br>${progressChip(r.progressLabel)}</td>`;
      tr.addEventListener("click", () => selectDoc(r));
      tbody.appendChild(tr);
    });
  }

  async function selectDoc(docRow) {
    state.docSelectedId = docRow.documentId;
    document.querySelectorAll("#ackDetailDocsBody tr").forEach(tr =>
      tr.classList.toggle("ack-doc-selected", Number(tr.dataset.docId) === docRow.documentId));

    document.getElementById("ackUsersHeader").textContent = `Users -- ${docRow.documentName}`;
    document.getElementById("ackUsersHint").hidden = true;
    document.getElementById("ackUsersWrap").hidden = false;

    const tbody = document.getElementById("ackDetailUsersBody");
    tbody.innerHTML = `<tr><td colspan="4" class="pm-empty-row">Loading...</td></tr>`;
    const users = await apiGet(`/${state.detailId}/documents/${docRow.documentId}/users`);
    if (!Array.isArray(users) || !users.length) {
      tbody.innerHTML = `<tr><td colspan="4" class="pm-empty-row">No users assigned.</td></tr>`;
      return;
    }
    tbody.innerHTML = "";
    users.forEach(u => {
      const tr = document.createElement("tr");
      const statusClass = u.statusCode === "Acknowledged" ? "ack-status-ack" : "ack-status-pending";
      tr.innerHTML = `
        <td>${escapeHtml(u.employeeName || "")}${u.employeeCode ? ` <span class="pm-hint">(${escapeHtml(u.employeeCode)})</span>` : ""}</td>
        <td>${escapeHtml(u.email || "--")}</td>
        <td><span class="ack-status-chip ${statusClass}">${escapeHtml(u.statusCode)}</span></td>
        <td>${u.acknowledgedOn ? window.gracFormatDisplayDate(u.acknowledgedOn) : "--"}</td>`;
      tbody.appendChild(tr);
    });
  }

  // -------------------- 3-dot row menu --------------------------------
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
  function wireRowMenu() {
    const root = document.getElementById("ackListView");
    if (!root) return;
    root.addEventListener("click", ev => {
      const trigger = ev.target.closest(".pm-action-trigger[data-ack-menu]");
      if (!trigger) return;
      ev.preventDefault(); ev.stopPropagation();
      const tr = trigger.closest("tr");
      if (openMenuTrigger === trigger) { closeRowMenu(); return; }
      closeRowMenu();
      openMenuTrigger = trigger;
      trigger.setAttribute("aria-expanded", "true");
      openMenuEl = document.createElement("div");
      openMenuEl.className = "pm-action-menu";
      openMenuEl.setAttribute("role", "menu");
      [
        { icon: "fa-eye", label: "View details",
          action: () => openDetail(Number(trigger.dataset.ackMenu), scrapeListRow(tr)) }
      ].forEach(it => {
        const b = document.createElement("button");
        b.type = "button"; b.setAttribute("role", "menuitem");
        b.innerHTML = `<i class="fa-solid ${it.icon}" aria-hidden="true"></i> ${escapeHtml(it.label)}`;
        b.addEventListener("click", ev => {
          ev.preventDefault(); ev.stopPropagation(); closeRowMenu();
          try { it.action(); } catch (err) { console.error("[ack] menu action failed", err); }
        });
        openMenuEl.appendChild(b);
      });
      document.body.appendChild(openMenuEl);
      positionRowMenu(trigger);
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

  function scrapeListRow(tr) {
    if (!tr) return null;
    const cells = tr.children;
    return {
      acknowledgementName: cells[0]?.innerText || "",
      dueDate:             cells[1]?.innerText === "--" ? null : cells[1]?.innerText,
      documentCount:       Number(cells[2]?.innerText || 0),
      userCount:           Number(cells[3]?.innerText || 0),
      ackCount:            Number(cells[4]?.innerText || 0),
      completionPct:       Number(cells[5]?.innerText.replace(/[^\d.]/g, "") || 0),
      progressLabel:       cells[6]?.innerText || "",
      createdBy:           cells[7]?.innerText.split("\n")[0] || "",
      createdOn:           new Date().toISOString()
    };
  }

  // -------------------- helpers ---------------------------------------
  function showView(name) {
    const map = { list: "ackListView", create: "ackCreateView", detail: "ackDetailView" };
    Object.entries(map).forEach(([k, id]) => {
      const el = document.getElementById(id);
      if (el) el.hidden = (k !== name);
    });
    window.scrollTo({ top: 0, behavior: "instant" in window ? "instant" : "auto" });
  }

  function progressBar(pct) {
    const p = Math.max(0, Math.min(100, Number(pct) || 0));
    return `<span class="ack-progress"><span style="width:${p}%"></span></span><span class="ack-progress-label">${p.toFixed(0)}%</span>`;
  }
  function progressChip(label) {
    const cls = label === "Completed"   ? "ack-status-completed"
              : label === "In Progress" ? "ack-status-progress"
              : label === "Pending"     ? "ack-status-open"
              : "ack-status-open";
    return `<span class="ack-status-chip ${cls}">${escapeHtml(label || "")}</span>`;
  }
  function escapeHtml(s) {
    if (s == null) return "";
    return String(s).replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
  }

  async function apiGet(path) {
    const url = path.startsWith("http") ? path
              : path.startsWith("/")   ? U(`${base}${path}`)
              : U(`${base}/${path}`);
    try {
      const r = await fetch(url, { credentials: "same-origin" });
      if (!r.ok) { console.warn("ack GET", url, r.status); return null; }
      return await r.json();
    } catch (err) { console.error("ack GET failed", url, err); return null; }
  }

  async function apiPost(path, body) {
    const url = U(`${base}${path.startsWith("/") ? path : "/" + path}`.replace(/\/+$/, "") || U(base));
    // Guard: when path is "", we want the plain base URL.
    const finalUrl = path === "" ? U(base) : U(`${base}${path.startsWith("/") ? path : "/" + path}`);
    try {
      const r = await fetch(finalUrl, {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok) return { success: false, error: data.error || `HTTP ${r.status}` };
      return data;
    } catch (err) {
      console.error("ack POST failed", finalUrl, err);
      return { success: false, error: err.message };
    }
  }
})();
