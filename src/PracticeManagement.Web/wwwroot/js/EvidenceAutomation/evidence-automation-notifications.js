// =====================================================================
// My Notifications -- Evidence Automation section (migration 530).
// Loaded by my-notifications.cshtml. Lists the "automated evidence not
// received" notices addressed to the signed-in employee -- raised for the
// source owner and the obligation owner when an expected period passes
// with nothing received. Backend:
//   GET  /practice/api/evidence-automation/notices/me?status&pageNumber&pageSize
//   POST /practice/api/evidence-automation/notices/me/mark { noticeId? }
// The API takes the recipient from the session (X-PM-Caller-Employee-Id);
// the browser never names one. Same shape as the Evidence Center section
// (EvidenceCenter/evidence-my-notifications.js).
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/evidence-automation/notices/me";
  const root = document.getElementById("eanRoot");
  if (!root) return;
  const CSRF = document.querySelector('meta[name="csrf-token"]')?.content || "";
  const F = (o, k) => o == null ? undefined : (o[k] !== undefined ? o[k] : o[k.charAt(0).toUpperCase() + k.slice(1)]);

  let pager = null;

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    // An account without an employee, or a build without 530 (404), leaves
    // the section hidden; the task section explains why.
    const probe = await api("GET", "?status=Unread&pageSize=1");
    if (!probe.ok) return;
    root.hidden = false;
    pager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "eanPager", onChange: load }) : null;
    document.getElementById("eanFilter").addEventListener("change", () => { if (pager) pager.reset(true); load(); });
    document.getElementById("eanRefresh").addEventListener("click", () => load());
    document.getElementById("eanReadAll").addEventListener("click", () => mark(null));
    document.getElementById("eanBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-ean-read]");
      if (b) mark(Number(b.dataset.eanRead));
    });
    await load();
  }

  async function load() {
    const body = document.getElementById("eanBody");
    body.innerHTML = empty("Loading...");
    const qs = new URLSearchParams({ status: document.getElementById("eanFilter").value,
      pageNumber: pager ? pager.page() : 1, pageSize: pager ? pager.size() : 25 });
    const res = await api("GET", `?${qs}`);
    if (!res.ok) { body.innerHTML = empty(res.error); if (pager) pager.clear(); return; }
    const rows = res.data.data || [];
    if (pager) pager.setTotal(res.data.totalRows, rows.length);
    document.getElementById("eanCounts").textContent = `${res.data.unreadCount || 0} unread`;
    body.innerHTML = rows.map(row).join("") || empty("No automated evidence notices here.");
  }

  function row(n) {
    // No record id in the URL: the screen lists the sources with their health.
    const href = U("/Practice/Index/evidence-automation");
    const read = !!F(n, "readDt");
    const arrivedSince = F(n, "currentLastReceivedDt") && F(n, "currentLastReceivedDt") !== F(n, "lastReceivedDt");
    return `<tr>
      <td><span class="pm-badge" style="background:var(--danger-100); color:var(--danger-700);">Not received</span></td>
      <td><a href="${esc(href)}">${esc(F(n, "bindingName"))}</a>
        <div class="amn-note">${esc(F(n, "obligationName") || "")} - ${esc(F(n, "instanceName") || "")}${arrivedSince ? " - evidence has arrived since" : ""}</div></td>
      <td>${esc(F(n, "whyYou") || "")}</td>
      <td>${esc(date(F(n, "duePeriodEnd")))}</td>
      <td>${esc(dateTime(F(n, "raisedDt")))}</td>
      <td>${read ? "Read" : "Unread"}</td>
      <td>${read ? "" : `<button type="button" class="pm-button" data-ean-read="${esc(F(n, "noticeId"))}">Mark read</button>`}</td>
    </tr>`;
  }

  async function mark(id) {
    const res = await api("POST", "/mark", id ? { noticeId: id } : {});
    if (!res.ok) { show(res.error); return; }
    await load();
  }

  async function api(method, path, body) {
    try {
      const r = await fetch(U(base + path), {
        method, credentials: "same-origin",
        headers: body ? { "Content-Type": "application/json", "X-CSRF-TOKEN": CSRF } : undefined,
        body: body ? JSON.stringify(body) : undefined
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok) return { ok: false, status: r.status, data, error: data.error || `Request failed (HTTP ${r.status}).` };
      return { ok: true, status: r.status, data };
    } catch (err) { return { ok: false, status: 0, data: {}, error: err.message }; }
  }
  function show(text) {
    const el = document.getElementById("eanMessage");
    el.textContent = text || ""; el.hidden = !text;
  }
  function empty(text) { return `<tr><td colspan="7" class="pm-empty">${esc(text)}</td></tr>`; }
  function date(v) { return v ? String(v).substring(0, 10) : ""; }
  function dateTime(v) {
    if (!v) return "";
    if (typeof window.gracFormatDisplayDate === "function") { const g = window.gracFormatDisplayDate(v); if (g && g !== v) return g; }
    const x = new Date(v); return isNaN(x) ? String(v) : x.toLocaleString();
  }
  function esc(v) { return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
})();
