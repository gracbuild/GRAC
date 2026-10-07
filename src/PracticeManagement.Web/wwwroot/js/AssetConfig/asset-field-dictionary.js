// =====================================================================
// Field Dictionary (migration 420) -- read-only list of the global asset
// field dictionary. Loaded by Views/Practice/Partials/asset-field-dictionary.cshtml.
// Server-side paging through pm-grid (never slices locally).
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config";
  const state = { groupCode: "", dataTypeCode: "", sensitivityCode: "", search: "", rows: [] };
  let pager = null;
  let searchTimer = null;

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    if (!document.getElementById("afdRoot")) return;
    pager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "afdPager", onChange: refresh }) : null;
    bind();
    await loadGroups();
    await refresh();
  }

  function bind() {
    const onFilter = (id, key) => document.getElementById(id).addEventListener("change", e => {
      state[key] = e.target.value || ""; pager?.reset(true); refresh();
    });
    onFilter("afdGroup", "groupCode");
    onFilter("afdDataType", "dataTypeCode");
    onFilter("afdSensitivity", "sensitivityCode");
    document.getElementById("afdSearch").addEventListener("input", e => {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(() => { state.search = e.target.value.trim(); pager?.reset(true); refresh(); }, 300);
    });
    document.getElementById("afdRefresh").addEventListener("click", refresh);
    document.getElementById("afdBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-afd-index]");
      if (tr) openDetail(state.rows[Number(tr.dataset.afdIndex)]);
    });
    document.querySelectorAll("[data-close-afd]").forEach(b => b.addEventListener("click", () => {
      document.getElementById("afdDetailModal").hidden = true;
    }));
    document.addEventListener("keydown", ev => {
      if (ev.key === "Escape") document.getElementById("afdDetailModal").hidden = true;
    });
  }

  async function loadGroups() {
    const res = await apiGet("/field-groups");
    const data = (res && !res.failed && res.data) || {};
    fill("afdGroup", data.groups || [], g => g.groupCode, g => `${g.brdSection ? g.brdSection + " " : ""}${g.groupName} (${g.fieldCount})`);
    fill("afdDataType", (data.dataTypes || []), t => t.dataTypeCode, t => t.dataTypeName);
  }

  function fill(id, rows, value, label) {
    const sel = document.getElementById(id);
    rows.forEach(r => {
      const o = document.createElement("option");
      o.value = value(r); o.textContent = label(r);
      sel.appendChild(o);
    });
  }

  async function refresh() {
    const body = document.getElementById("afdBody");
    body.innerHTML = `<tr><td colspan="7" class="pm-empty">Loading...</td></tr>`;
    const qs = new URLSearchParams({ pageNumber: pager ? pager.page() : 1, pageSize: pager ? pager.size() : 25 });
    if (state.groupCode) qs.set("groupCode", state.groupCode);
    if (state.dataTypeCode) qs.set("dataTypeCode", state.dataTypeCode);
    if (state.sensitivityCode) qs.set("sensitivityCode", state.sensitivityCode);
    if (state.search) qs.set("search", state.search);
    const res = await apiGet(`/field-definitions?${qs}`);
    if (!res || res.failed) {
      // Show WHY (status + server message) instead of a generic line, so a
      // missing migration, an undeployed API or a permission gap is visible.
      body.innerHTML = `<tr><td colspan="7" class="pm-empty">The dictionary could not be loaded${res?.detail ? ": " + esc(res.detail) : "."}</td></tr>`;
      pager?.clear(); return;
    }
    const rows = res.data?.rows || [];
    state.rows = rows;
    pager?.setTotal(res.data?.totalRows, rows.length);
    if (!rows.length) { body.innerHTML = `<tr><td colspan="7" class="pm-empty">No fields match the filters.</td></tr>`; return; }
    body.innerHTML = rows.map((r, i) => `
      <tr class="pm-row-clickable" data-afd-index="${i}" title="View field details">
        <td>${esc(r.displayLabel)}</td>
        <td><span class="afd-key">${esc(r.fieldKey)}</span></td>
        <td>${esc(r.groupName)}</td>
        <td>${esc(r.dataTypeName)}</td>
        <td>${sensBadge(r.sensitivityCode)}</td>
        <td>${esc(storageLabel(r))}</td>
        <td>${r.isSystemMandatory ? `<span class="pm-badge afd-baseline">Baseline</span>` : ""}</td>
      </tr>`).join("");
  }

  function storageLabel(r) {
    if (r.storageKind === "COLUMN") return `Asset record (${r.columnName})`;
    if (r.storageKind === "SYSTEM") return "System-maintained";
    return "Field value";
  }

  function sensBadge(code) {
    const cls = code === "CONFIDENTIAL" ? " afd-sens-confidential" : code === "RESTRICTED" ? " afd-sens-restricted" : "";
    const label = code ? code.charAt(0) + code.slice(1).toLowerCase() : "";
    return `<span class="pm-badge${cls}">${esc(label)}</span>`;
  }

  function openDetail(r) {
    if (!r) return;
    document.getElementById("afdDetailTitle").textContent = r.displayLabel || "Field";
    const items = [
      ["Field key", r.fieldKey],
      ["Group", `${r.brdSection || ""} ${r.groupName || ""}`.trim()],
      ["Data type", r.dataTypeName],
      ["Lookup source", r.lookupSource || "--"],
      ["Validation / mandatory rule", r.validationRule || "--"],
      ["Description", r.description || "--"],
      ["Sensitivity baseline", r.sensitivityCode],
      ["Stored in", storageLabel(r)],
      ["Baseline field", r.isSystemMandatory ? "Yes -- every template must include it, visible and mandatory" : "No"],
      ["Definition version", r.definitionVersion],
      ["Effective from", window.gracFormatDisplayDate ? window.gracFormatDisplayDate(r.effectiveFrom) : r.effectiveFrom],
      ["Status", r.statusCode]
    ];
    document.getElementById("afdDetailBody").innerHTML =
      items.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v ?? "")}</dd>`).join("");
    document.getElementById("afdDetailModal").hidden = false;
  }

  async function apiGet(path) {
    try {
      const r = await fetch(U(base + path), { credentials: "same-origin" });
      if (!r.ok) {
        const text = await r.text().catch(() => "");
        let msg = "";
        try { msg = JSON.parse(text).error || ""; } catch (_) { /* not JSON, e.g. an HTML 404 page */ }
        console.warn("asset-config GET", path, r.status, msg || text.slice(0, 300));
        const hint = r.status === 404 ? "the Asset Configuration API was not found -- deploy the latest API and Web build"
                   : r.status === 403 ? "you do not have permission (sign out and back in after the menu grant)"
                   : r.status === 502 ? "the API is not reachable"
                   : "";
        return { failed: true, detail: `HTTP ${r.status}${msg ? " -- " + msg : hint ? " -- " + hint : ""}` };
      }
      return await r.json();
    } catch (err) { console.error("asset-config GET failed", path, err); return { failed: true, detail: err.message }; }
  }

  function esc(v) {
    return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }
})();
