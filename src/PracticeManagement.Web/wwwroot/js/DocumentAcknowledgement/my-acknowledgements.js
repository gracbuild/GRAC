// =====================================================================
// My Acknowledgements (Phase 3) -- employee-side pending inbox.
// Loaded by Views/Practice/Partials/my-acknowledgements.cshtml.
// =====================================================================
(() => {
  "use strict";

  const U       = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const ackBase = "/practice/api/document-acknowledgements";
  const docBase = "/practice/api/document-uploads";     // for the file preview endpoint

  // Admin detection matches practice.js -- DataScope GLOBAL or ORGANIZATION
  // gives an org-wide view of pending acknowledgements on this page.
  const sessionDataScope = String(window.pmDataScope || "ORGANIZATION").toUpperCase();
  const isAdmin          = sessionDataScope === "GLOBAL" || sessionDataScope === "ORGANIZATION";
  const sessionEmpId     = Number(window.pmEmployeeId || 0);

  const state = {
    includeCompleted: false,
    organizationId: null,      // only used in admin mode
    activeBatchId: null,
    activeBatchMeta: null,     // for the docs view header
    activeDocRow: null         // for the acknowledge view
  };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    if (!document.getElementById("myAckListView")) return;
    // Rename the page for admins so the semantics are unambiguous -- this
    // is not "my own pending" any more, it's an org-wide overview.
    if (isAdmin) {
      const h = document.querySelector(".pm-page-heading h1");
      if (h) h.textContent = "Acknowledgements Overview";
      const p = document.querySelector(".pm-page-heading p");
      if (p) p.textContent = "Every pending and completed acknowledgement across your organization.";
    }
    showView("list");
    bindEvents();
    if (isAdmin) {
      await populateOrgFilter();
      // Auto-select the first org so the page shows data on landing.
      const sel = document.getElementById("myAckFilterOrganization");
      if (sel.options.length > 1 && !state.organizationId) {
        sel.selectedIndex   = 1;
        state.organizationId = Number(sel.value) || null;
      }
    }
    await loadBatches();
  }

  // Admin-only: pull the org list this user can operate on and unhide
  // the select. Same endpoint Task Center / Doc Uploads use.
  async function populateOrgFilter() {
    const sel = document.getElementById("myAckFilterOrganization");
    sel.hidden = false;
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

  function bindEvents() {
    document.getElementById("myAckIncludeCompleted").addEventListener("change", ev => {
      state.includeCompleted = ev.target.checked;
      loadBatches();
    });
    document.getElementById("myAckRefreshBtn").addEventListener("click", loadBatches);
    document.getElementById("myAckFilterOrganization").addEventListener("change", ev => {
      state.organizationId = ev.target.value ? Number(ev.target.value) : null;
      loadBatches();
    });

    document.querySelectorAll("[data-my-ack-back]").forEach(el =>
      el.addEventListener("click", () => showView("list")));
    document.querySelectorAll("[data-my-ack-back-docs]").forEach(el =>
      el.addEventListener("click", () => showView("docs")));

    document.getElementById("myAckActForm").addEventListener("submit", onAcknowledgeSubmit);
  }

  // ------------------ view 1: batches ------------------------------
  async function loadBatches() {
    const tbody = document.getElementById("myAckTableBody");
    tbody.innerHTML = `<tr><td colspan="8" class="pm-empty-row">Loading...</td></tr>`;
    console.log("[my-ack] loadBatches -- isAdmin=", isAdmin,
                "empId=", sessionEmpId, "scope=", sessionDataScope,
                "orgId=", state.organizationId);

    if (isAdmin && !state.organizationId) {
      tbody.innerHTML = `<tr><td colspan="8" class="pm-empty-row">
        Select an organization to load acknowledgements.</td></tr>`;
      return;
    }

    const qs   = `includeCompleted=${state.includeCompleted ? "true" : "false"}`
               + (state.organizationId ? `&organizationId=${state.organizationId}` : "");
    const raw  = await apiGetRaw(`/my/batches?${qs}`);
    console.log("[my-ack] batches response", raw);
    const rows = raw?.body;
    if (raw && !raw.ok) {
      tbody.innerHTML = `<tr><td colspan="8" class="pm-empty-row">
        Could not load acknowledgements: ${escapeHtml(raw.error || `HTTP ${raw.status}`)}</td></tr>`;
      return;
    }
    if (!Array.isArray(rows) || !rows.length) {
      tbody.innerHTML = `<tr><td colspan="8" class="pm-empty-row">
        ${isAdmin
          ? "No acknowledgement batches yet. Publish a document with 'Acknowledgement required' and create a batch first."
          : `You have no ${state.includeCompleted ? "" : "outstanding "}acknowledgements right now.`}
      </td></tr>`;
      return;
    }
    tbody.innerHTML = "";
    rows.forEach(r => {
      const tr = document.createElement("tr");
      tr.innerHTML = `
        <td><a href="#" class="my-ack-open">${escapeHtml(r.acknowledgementName)}</a></td>
        <td>${r.dueDate ? new Date(r.dueDate).toLocaleDateString() : "--"}</td>
        <td>${r.myDocCount}</td>
        <td>${r.myAckCount}</td>
        <td>${r.myPendingCount}</td>
        <td>${progressBar(r.myCompletionPct)}</td>
        <td>${progressChip(r.myStatusLabel)}</td>
        <td>
          <button type="button" class="pm-button primary my-ack-open-btn">
            <i class="fa-solid fa-arrow-right"></i> Open
          </button>
        </td>`;
      const open = () => openBatch(r);
      tr.querySelector(".my-ack-open").addEventListener("click", ev => { ev.preventDefault(); open(); });
      tr.querySelector(".my-ack-open-btn").addEventListener("click", open);
      tbody.appendChild(tr);
    });
  }

  // ------------------ view 2: docs in a batch ----------------------
  async function openBatch(batch) {
    state.activeBatchId   = batch.acknowledgementId;
    state.activeBatchMeta = batch;
    document.getElementById("myAckDocsTitle").textContent = batch.acknowledgementName || "Batch";
    document.getElementById("myAckDocsMeta").innerHTML =
      `<dt>Due</dt><dd>${batch.dueDate ? new Date(batch.dueDate).toLocaleDateString() : "--"}</dd>` +
      `<dt>Status</dt><dd>${progressChip(batch.myStatusLabel)}</dd>` +
      `<dt>My Documents</dt><dd>${batch.myDocCount}</dd>` +
      `<dt>Acknowledged</dt><dd>${batch.myAckCount} (${Number(batch.myCompletionPct).toFixed(0)}%)</dd>`;

    showView("docs");
    const tbody = document.getElementById("myAckDocsBody");
    tbody.innerHTML = `<tr><td colspan="6" class="pm-empty-row">Loading...</td></tr>`;
    const docs = await apiGet(`/my/batches/${batch.acknowledgementId}/documents`);
    if (!Array.isArray(docs) || !docs.length) {
      tbody.innerHTML = `<tr><td colspan="6" class="pm-empty-row">No documents assigned to you in this batch.</td></tr>`;
      return;
    }
    tbody.innerHTML = "";
    // Admin mode: table gains an Employee column and the action button
    // becomes View-only for rows that don't belong to the signed-in
    // employee (server-side proc also blocks a cross-user ack).
    if (isAdmin) {
      const headRow = document.querySelector("#myAckDocsTable thead tr");
      if (headRow && !headRow.dataset.adminAugmented) {
        const th = document.createElement("th");
        th.textContent = "Employee";
        headRow.insertBefore(th, headRow.children[headRow.children.length - 1]);
        headRow.dataset.adminAugmented = "1";
      }
    }

    docs.forEach(d => {
      const tr    = document.createElement("tr");
      const isAck = d.statusCode === "Acknowledged";
      const mine  = d.employeeId === sessionEmpId;

      const empCol = isAdmin
        ? `<td>${escapeHtml(d.employeeName || "")}${d.employeeCode ? ` <span class="pm-hint">(${escapeHtml(d.employeeCode)})</span>` : ""}</td>`
        : "";

      // Action button: Acknowledge only when it is my row and still Pending.
      // Other rows get a View that opens the same split-pane read-only.
      const btn = (mine && !isAck)
        ? `<button type="button" class="pm-button primary my-ack-act">
             <i class="fa-solid fa-clipboard-check"></i> Acknowledge
           </button>`
        : `<button type="button" class="pm-button my-ack-act">
             <i class="fa-solid fa-eye"></i> View
           </button>`;

      tr.innerHTML = `
        <td>${escapeHtml(d.documentCode)}</td>
        <td>${escapeHtml(d.documentName)} <span class="pm-hint">v${escapeHtml(d.versionNumber)}</span></td>
        <td>${escapeHtml(d.versionNumber)}</td>
        <td><span class="ack-status-chip ${isAck ? "ack-status-ack" : "ack-status-pending"}">${escapeHtml(d.statusCode)}</span></td>
        <td>${d.acknowledgedOn ? new Date(d.acknowledgedOn).toLocaleString() : "--"}</td>
        ${empCol}
        <td>${btn}</td>`;
      tr.querySelector(".my-ack-act").addEventListener("click", () => openAcknowledge(d));
      tbody.appendChild(tr);
    });
  }

  // ------------------ view 3: acknowledge --------------------------
  async function openAcknowledge(docRow) {
    state.activeDocRow = docRow;
    const isAck = docRow.statusCode === "Acknowledged";
    document.getElementById("myAckActTitle").textContent =
      isAck ? `View: ${docRow.documentName}` : `Acknowledge: ${docRow.documentName}`;

    document.getElementById("myAckActBatchId").value = docRow.acknowledgementId;
    document.getElementById("myAckActDocId").value   = docRow.documentId;

    document.getElementById("myAckActMeta").innerHTML =
      `<dt>Code</dt><dd>${escapeHtml(docRow.documentCode)}</dd>` +
      `<dt>Name</dt><dd>${escapeHtml(docRow.documentName)}</dd>` +
      `<dt>Version</dt><dd>${escapeHtml(docRow.versionNumber)}</dd>` +
      `<dt>Batch</dt><dd>${escapeHtml(docRow.acknowledgementName)}</dd>` +
      `<dt>Due</dt><dd>${docRow.dueDate ? new Date(docRow.dueDate).toLocaleDateString() : "--"}</dd>` +
      `<dt>My status</dt><dd>${escapeHtml(docRow.statusCode)}</dd>`;

    // Show remark from a previous acknowledgement in the textarea.
    document.getElementById("myAckActRemark").value = docRow.remark || "";
    document.getElementById("myAckActMessage").textContent = "";

    // Determine if this row is mine or someone else's (admin viewing).
    const mine = !docRow.employeeId || docRow.employeeId === sessionEmpId;

    // Disable submit + remark when either already acknowledged OR it's
    // someone else's row (admin viewing). Server-side proc also rejects
    // cross-user acks, but the UI mirrors it to prevent the click.
    const done   = document.getElementById("myAckActAlreadyDone");
    const doneDt = document.getElementById("myAckActAlreadyDate");
    const submit = document.getElementById("myAckActSubmit");
    if (!mine) {
      submit.disabled = true;
      submit.title    = "This assignment belongs to another employee.";
      done.hidden     = false;
      doneDt.textContent = `${docRow.employeeName || "Another user"} is the assigned user.`;
      document.getElementById("myAckActRemark").disabled = true;
    } else if (isAck) {
      submit.disabled = true;
      submit.title    = "Already acknowledged.";
      done.hidden     = false;
      doneDt.textContent = docRow.acknowledgedOn ? new Date(docRow.acknowledgedOn).toLocaleString() : "--";
      document.getElementById("myAckActRemark").disabled = true;
    } else {
      submit.disabled = false;
      submit.title    = "";
      done.hidden     = true;
      document.getElementById("myAckActRemark").disabled = false;
    }

    // Same approach as the review view: fetch to a blob and hand a
    // same-origin blob: URL to the iframe so upstream X-Frame-Options
    // or CSP frame-ancestors headers on production do not block it.
    const fileUrl = U(`${docBase}/${docRow.documentId}/file?inline=true`);
    const iframe  = document.getElementById("myAckActPdf");
    const empty   = document.getElementById("myAckActPdfEmpty");
    const msg2    = document.getElementById("myAckActPdfMessage");
    const link    = document.getElementById("myAckActPdfLink");
    if (link) link.setAttribute("href", fileUrl);
    if (iframe) {
      if (iframe.dataset.blobUrl) { try { URL.revokeObjectURL(iframe.dataset.blobUrl); } catch (_) {} }
      iframe.removeAttribute("data-blob-url");
      iframe.setAttribute("src", "about:blank");
    }
    if (empty) empty.hidden = true;

    showView("act");

    try {
      const resp = await fetch(fileUrl, { method: "GET", credentials: "same-origin" });
      if (!resp.ok) {
        if (empty) { empty.hidden = false; msg2.textContent = `Could not load file (HTTP ${resp.status}).`; }
        return;
      }
      const ct   = (resp.headers.get("Content-Type") || "").toLowerCase();
      const blob = await resp.blob();
      const typed = ct.includes("pdf")
        ? new Blob([blob], { type: "application/pdf" })
        : blob;
      const url = URL.createObjectURL(typed);
      if (iframe) {
        iframe.dataset.blobUrl = url;
        iframe.setAttribute("src", url);
      }
      if (!ct.includes("pdf") && empty) {
        empty.hidden = false;
        msg2.textContent = `Preview may not render for this file type (${ct || "unknown"}). Use "Open in new tab" to download.`;
      }
    } catch (err) {
      console.error("[my-ack] pdf preview failed", err);
      if (empty) { empty.hidden = false; msg2.textContent = "Network error loading file preview."; }
    }
  }

  async function onAcknowledgeSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("myAckActMessage");
    msg.textContent = "";

    const payload = {
      acknowledgementId: Number(document.getElementById("myAckActBatchId").value),
      documentId:        Number(document.getElementById("myAckActDocId").value),
      remark:            document.getElementById("myAckActRemark").value
    };

    const result = await apiPost("/my/acknowledge", payload);
    if (!result || result.success === false) {
      const err = (result && result.error) || "Acknowledge failed.";
      msg.textContent = err;
      alert(err);
      return;
    }

    // Update local state and go back to the docs view with a fresh load.
    alert("Acknowledged. Thank you.");
    showView("docs");
    if (state.activeBatchMeta) {
      // Re-fetch the batch header so counts refresh.
      const batches = await apiGet(`/my/batches?includeCompleted=true`);
      const fresh   = Array.isArray(batches)
        ? batches.find(b => b.acknowledgementId === state.activeBatchMeta.acknowledgementId)
        : null;
      if (fresh) state.activeBatchMeta = fresh;
      await openBatch(state.activeBatchMeta);
    }
  }

  // ------------------ helpers --------------------------------------
  function showView(name) {
    const map = { list: "myAckListView", docs: "myAckDocsView", act: "myAckActView" };
    Object.entries(map).forEach(([k, id]) => {
      const el = document.getElementById(id);
      if (el) el.hidden = (k !== name);
    });
    if (name !== "act") {
      const iframe = document.getElementById("myAckActPdf");
      if (iframe) iframe.setAttribute("src", "about:blank");
      const empty = document.getElementById("myAckActPdfEmpty");
      if (empty) empty.hidden = true;
    }
    window.scrollTo({ top: 0, behavior: "instant" in window ? "instant" : "auto" });
  }

  function progressBar(pct) {
    const p = Math.max(0, Math.min(100, Number(pct) || 0));
    return `<span class="ack-progress"><span style="width:${p}%"></span></span><span class="ack-progress-label">${p.toFixed(0)}%</span>`;
  }
  function progressChip(label) {
    const cls = label === "Completed"   ? "ack-status-completed"
              : label === "In Progress" ? "ack-status-progress"
              : "ack-status-open";
    return `<span class="ack-status-chip ${cls}">${escapeHtml(label || "")}</span>`;
  }
  function escapeHtml(s) {
    if (s == null) return "";
    return String(s).replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
  }

  async function apiGet(path) {
    const raw = await apiGetRaw(path);
    return raw?.ok ? raw.body : null;
  }

  // Same as apiGet but returns { ok, status, body, error } so callers can
  // distinguish "empty result" from "request failed" and show a real
  // message instead of a generic empty state.
  async function apiGetRaw(path) {
    const url = U(`${ackBase}${path.startsWith("/") ? path : "/" + path}`);
    try {
      const r    = await fetch(url, { credentials: "same-origin" });
      const text = await r.text();
      let body   = null;
      try { body = text ? JSON.parse(text) : null; } catch (_) { body = text; }
      if (!r.ok) {
        console.warn("myAck GET", url, r.status, body);
        return { ok: false, status: r.status, body: null,
                 error: (body && (body.error || body.title)) || `HTTP ${r.status}` };
      }
      return { ok: true, status: r.status, body };
    } catch (err) {
      console.error("myAck GET failed", url, err);
      return { ok: false, status: 0, body: null, error: err.message };
    }
  }

  async function apiPost(path, body) {
    const url = U(`${ackBase}${path.startsWith("/") ? path : "/" + path}`);
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
    } catch (err) { console.error("myAck POST failed", url, err); return { success: false, error: err.message }; }
  }
})();
