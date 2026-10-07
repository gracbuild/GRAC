// =====================================================================
// My Notifications -- Asset & Contract section (migration 437, BRD 9.1).
// Loaded by my-notifications.cshtml. Lists the reminders and escalations
// addressed to the signed-in employee: notifications/mine (filter UNREAD |
// TO_ACKNOWLEDGE | TO_CONFIRM | READ | ALL), notifications/mine/counts,
// notifications/mine/{id}/action (READ | ACKNOWLEDGE | CONFIRM) and
// notifications/mine/read-all. The API takes the recipient from the
// session (X-PM-Caller-Employee-Id); the browser never names one. The
// acknowledgement each notice needs comes from its profile: Read, Action
// (the action taken) or Manager (the reporting officer confirms).
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config/notifications/mine";
  const root = document.getElementById("amnRoot");
  if (!root) return;

  const CLASS = {
    INFORMATIONAL: ["Information", "background:var(--neutral-200); color:var(--fg-secondary);"],
    REMINDER:      ["Reminder", "background:var(--warning-50); color:var(--warning-700);"],
    ESCALATION:    ["Escalation", "background:var(--warning-100); color:var(--danger-700);"],
    CRITICAL:      ["Critical", "background:var(--danger-100); color:var(--danger-700);"]
  };
  const REASON = {
    ACTIVITY_OWNER: "You own the activity", ASSET_OWNER: "Asset owner", BUSINESS_OWNER: "Business owner",
    TECHNICAL_OWNER: "Technical owner", CUSTODIAN: "Custodian", MAINTENANCE_OWNER: "Maintenance owner",
    COMPLIANCE_OWNER: "Compliance owner", PRIVACY_OWNER: "Privacy owner", SECURITY_OWNER: "Information security owner",
    CONTRACT_OWNER: "Contract owner", PROCUREMENT_OWNER: "Procurement owner", AFFECTED_ASSET_OWNERS: "Owner of a covered asset",
    EXCEPTION_APPROVER: "You approved the exception", MANAGER: "Manager of the activity owner",
    DEPARTMENT_HEAD: "Department head of the activity owner"
  };

  let pager = null;

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    // An account that is not linked to an employee (403) or a build without
    // 437 (404) leaves the section hidden; the task section explains why.
    const counts = await api("GET", "/counts");
    if (!counts.ok) return;
    root.hidden = false;
    renderCounts(counts.data.data);
    pager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "amnPager", onChange: load }) : null;
    document.getElementById("amnFilter").addEventListener("change", () => { if (pager) pager.reset(true); load(); });
    document.getElementById("amnRefresh").addEventListener("click", () => { load(); refreshCounts(); });
    document.getElementById("amnReadAll").addEventListener("click", readAll);
    document.getElementById("amnBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-amn-act]");
      if (b) act(Number(b.dataset.amnId), b.dataset.amnAct, b.dataset.amnMode);
    });
    await load();
  }

  async function refreshCounts() {
    const res = await api("GET", "/counts");
    if (res.ok) renderCounts(res.data.data);
  }

  function renderCounts(c) {
    c = c || {};
    document.getElementById("amnCounts").textContent =
      `${c.unreadCount || 0} unread, ${c.toAcknowledgeCount || 0} to acknowledge, ${c.toConfirmCount || 0} to confirm`;
  }

  async function load() {
    const body = document.getElementById("amnBody");
    body.innerHTML = empty("Loading...");
    const qs = new URLSearchParams({ filter: document.getElementById("amnFilter").value,
      pageNumber: pager ? pager.page() : 1, pageSize: pager ? pager.size() : 25 });
    const res = await api("GET", `?${qs}`);
    if (!res.ok) { body.innerHTML = empty(res.error); if (pager) pager.clear(); return; }
    const rows = res.data.data.rows || [];
    if (pager) pager.setTotal(res.data.data.totalRows, rows.length);
    body.innerHTML = rows.map(row).join("") || empty("No notifications here.");
  }

  function row(n) {
    const [label, style] = CLASS[n.notificationClass] || [n.notificationClass, ""];
    const confirm = !!n.isManagerConfirmation;
    const unread = !confirm && !n.readDt;
    const needsAck = !confirm && (n.ackMode === "ACTION" || n.ackMode === "MANAGER") && !n.acknowledgedDt;
    const status = confirm ? "Awaiting your confirmation"
      : n.managerAckDt ? "Confirmed by manager"
      : n.acknowledgedDt ? (n.ackMode === "MANAGER" ? "Acknowledged, awaiting manager" : "Acknowledged")
      : n.readDt ? "Read" : "Unread";
    const why = confirm ? `Acknowledged by ${n.recipientName || "your report"}`
      : n.recipientReasonCode === "ROLE" ? `Role: ${n.roleName || ""}` : (REASON[n.recipientReasonCode] || n.recipientReasonCode || "");
    const stage = n.stageKind === "REMINDER" ? `${n.stageOffsetDays} day(s) before`
      : n.stageKind === "DUE" ? "Due date" : `Escalation ${n.escalationLevel}${n.stageOffsetDays ? `, ${n.stageOffsetDays} day(s) after` : ""}`;
    let actions = "";
    if (confirm) actions = button(n, "CONFIRM", "Confirm");
    else {
      if (needsAck) actions += button(n, "ACKNOWLEDGE", "Acknowledge");
      if (unread && !needsAck) actions += button(n, "READ", "Mark read");
    }
    return `<tr${unread || confirm ? ' style="font-weight:600;"' : ""}>
      <td><span class="pm-badge" style="${style}">${esc(label)}</span></td>
      <td><details><summary>${esc(n.subject || n.activityName)}</summary>
          <div class="amn-note" style="white-space:pre-wrap;">${esc(n.bodyText || "")}</div></details>
          <div class="amn-note">${esc(n.activityName)} - ${esc(n.objectRef || "")}</div>
          ${confirm && n.ackNote ? `<div class="amn-note">Action taken: ${esc(n.ackNote)}</div>` : ""}</td>
      <td>${esc(why)}</td>
      <td>${esc(date(n.triggerDate))}<div class="amn-note">${esc(stage)}</div></td>
      <td>${esc(dateTime(n.enteredDt))}</td>
      <td>${esc(status)}</td>
      <td>${actions}</td></tr>`;
  }

  function button(n, action, text) {
    return `<button type="button" class="pm-button" data-amn-act="${action}" data-amn-id="${n.notificationId}" data-amn-mode="${esc(n.ackMode)}">${esc(text)}</button> `;
  }

  async function act(id, action, mode) {
    let note = null;
    if (action === "ACKNOWLEDGE" && (mode === "ACTION" || mode === "MANAGER")) {
      note = await window.gracUi.promptRequired("Describe the action taken.", { title: "Acknowledge notification", inputLabel: "Action taken" });
      if (note === null) return;
    } else if (action === "CONFIRM") {
      note = await window.gracUi.prompt("Comments (optional)", { title: "Confirm acknowledgement", inputLabel: "Comments" });
      if (note === null) return;
    }
    const res = await api("POST", `/${id}/action`, { action, note: note || null });
    if (!res.ok) { show(res.error); return; }
    hide();
    await load();
    await refreshCounts();
  }

  async function readAll() {
    if (!await window.gracUi.confirm("Mark every unread asset and contract notification that needs no action as read? Notices that need an action stay open.",
      { title: "Mark all read", confirmText: "Mark all read" })) return;
    const res = await api("POST", "/read-all", {});
    if (!res.ok) { show(res.error); return; }
    show(`${res.data.markedCount || 0} notification(s) marked read.`, "success");
    await load();
    await refreshCounts();
  }

  async function api(method, path, body) {
    try {
      const r = await fetch(U(base + path), {
        method, credentials: "same-origin",
        headers: body ? { "Content-Type": "application/json" } : undefined,
        body: body ? JSON.stringify(body) : undefined
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok || data.success === false) return { ok: false, status: r.status, data, error: data.error || `Request failed (HTTP ${r.status}).` };
      return { ok: true, status: r.status, data };
    } catch (err) { return { ok: false, status: 0, data: {}, error: err.message }; }
  }
  function show(text, kind) {
    const el = document.getElementById("amnMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.hidden = !text;
  }
  function hide() { const el = document.getElementById("amnMessage"); el.hidden = true; el.textContent = ""; }
  function empty(text) { return `<tr><td colspan="7" class="pm-empty">${esc(text)}</td></tr>`; }
  function date(v) { return v ? String(v).substring(0, 10) : ""; }
  function dateTime(v) { if (!v) return ""; const x = new Date(v); return isNaN(x) ? String(v) : x.toLocaleString(); }
  function esc(v) { return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
})();
