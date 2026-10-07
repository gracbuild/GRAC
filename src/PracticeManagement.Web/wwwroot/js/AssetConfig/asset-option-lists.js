// =====================================================================
// Option Lists (migration 423) -- the organization's values for asset
// drop-down lists (BRD 5.1.2 / 5.1.6 / 5.1.10 / 5.2.5). Loaded by
// asset-option-lists.cshtml.
// Every rule (scope, unique code, parent required and valid, no retiring a
// value that still has active children, defaults only overridable on
// ORG_EXTENSIBLE lists) is enforced by the procedures; this screen only
// mirrors them and shows their messages.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config/option-lists";
  const root = document.getElementById("aolRoot");
  if (!root) return;
  const CAN_EDIT = root.dataset.canEdit === "1";

  const SCOPE = {
    ORG_ONLY:       { label: "Organization values",     cls: "aol-sc-org",
                      note: "Every value of this list belongs to the organization. Add the values in use; retire a value when it is no longer used." },
    ORG_EXTENSIBLE: { label: "Defaults + organization", cls: "aol-sc-ext",
                      note: "The defaults apply to every organization. Add this organization's own values, or relabel, reorder or hide a default for this organization only." },
    GLOBAL_ONLY:    { label: "Fixed",                   cls: "aol-sc-fixed",
                      note: "This list is the same for every organization and cannot be changed here." }
  };
  const SOURCE = {
    GLOBAL:   { label: "Default",      cls: "aol-src-global" },
    OVERRIDE: { label: "Relabelled",   cls: "aol-src-override" },
    HIDDEN:   { label: "Hidden",       cls: "aol-src-hidden" },
    ORG:      { label: "Organization", cls: "aol-src-org" }
  };

  // modal.mode: "org" (add / edit an organization value) | "override" (a default)
  const state = { organizationId: null, rows: [], group: null, detail: null, modal: null };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    bind();
    await populateOrgs();
    const sel = document.getElementById("aolOrg");
    window.gracOrgPref.apply(sel);   // 2026-10-06: last-picked org, else lowest id
    state.organizationId = Number(sel.value) || null;
    await refreshList();
  }

  async function populateOrgs() {
    const sel = document.getElementById("aolOrg");
    try {
      const r = await fetch(U("/practice/api/organizations/allowed"), { credentials: "same-origin" });
      const b = r.ok ? await r.json() : null;
      ((b && (b.data || b.Data)) || []).forEach(row => {
        const value = String(row.organizationId ?? row.OrganizationId ?? "");
        if (!value) return;
        const o = document.createElement("option");
        o.value = value; o.textContent = String(row.organizationName ?? row.OrganizationName ?? value);
        sel.appendChild(o);
      });
    } catch (_) { /* placeholder stays */ }
    if (sel.options.length === 2) sel.disabled = true;
  }

  function bind() {
    document.getElementById("aolOrg").addEventListener("change", e => {
      state.organizationId = Number(e.target.value) || null;
      if (state.group) showList(); else refreshList();
    });
    document.getElementById("aolRefresh").addEventListener("click", refreshList);
    let t = null;
    document.getElementById("aolSearch").addEventListener("input", () => { clearTimeout(t); t = setTimeout(refreshList, 300); });
    document.getElementById("aolScope").addEventListener("change", renderList);
    document.getElementById("aolListBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-aol-group]");
      if (tr) openList(tr.dataset.aolGroup);
    });
    document.getElementById("aolBack").addEventListener("click", showList);
    document.getElementById("aolAddBtn")?.addEventListener("click", () => openModal("org", null));
    document.getElementById("aolValueBody").addEventListener("click", onValueAction);
    document.getElementById("aolForm").addEventListener("submit", saveModal);
    document.querySelectorAll("[data-close-aol]").forEach(b => b.addEventListener("click", closeModal));
    document.addEventListener("keydown", ev => { if (ev.key === "Escape") closeModal(); });
  }

  // ------------------------------------------------------------------ catalogue
  async function refreshList() {
    const body = document.getElementById("aolListBody");
    if (!state.organizationId) { body.innerHTML = `<tr><td colspan="6" class="pm-empty">Select an organization.</td></tr>`; return; }
    body.innerHTML = `<tr><td colspan="6" class="pm-empty">Loading...</td></tr>`;
    const search = val("aolSearch");
    const res = await api("GET", `?organizationId=${state.organizationId}${search ? "&search=" + encodeURIComponent(search) : ""}`);
    if (!res.ok) { body.innerHTML = `<tr><td colspan="6" class="pm-empty">${esc(res.error)}</td></tr>`; return; }
    state.rows = res.data.data || [];
    renderList();
  }

  function renderList() {
    const scope = val("aolScope");
    const rows = state.rows.filter(r => !scope || r.scopeCode === scope);
    document.getElementById("aolListBody").innerHTML = rows.map(r => `
      <tr class="pm-row-clickable" data-aol-group="${esc(r.optionGroup)}">
        <td>${esc(r.listName)}<div class="aol-code">${esc(shortGroup(r.optionGroup))}</div></td>
        <td>${scopeChip(r.scopeCode)}</td>
        <td>${esc(r.parentFieldLabel || r.parentFieldKey || "--")}</td>
        <td>${esc(r.effectiveCount)}</td>
        <td>${r.scopeCode === "GLOBAL_ONLY" ? "--" : esc(r.orgCount)}</td>
        <td>${esc(r.usedBy || "")}</td>
      </tr>`).join("") || `<tr><td colspan="6" class="pm-empty">No option lists match.</td></tr>`;
  }

  function showList() {
    document.getElementById("aolDetailView").hidden = true;
    document.getElementById("aolListView").hidden = false;
    state.group = null; state.detail = null;
    refreshList();
  }

  // ------------------------------------------------------------------ list detail
  async function openList(group) {
    const res = await api("GET", `/${encodeURIComponent(group)}?organizationId=${state.organizationId}`);
    if (!res.ok) { await notify(res.error, "error"); return; }
    state.group = group;
    state.detail = res.data.data;
    document.getElementById("aolListView").hidden = true;
    document.getElementById("aolDetailView").hidden = false;
    hideMessage();
    renderDetail();
  }

  async function reload(message) {
    const res = await api("GET", `/${encodeURIComponent(state.group)}?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.detail = res.data.data;
    renderDetail();
    if (message) showMessage(message, "success");
  }

  function renderDetail() {
    const l = state.detail.list, sc = SCOPE[l.scopeCode] || SCOPE.GLOBAL_ONLY;
    const dependent = !!l.parentFieldKey;
    document.getElementById("aolTitle").textContent = l.listName;
    document.getElementById("aolMeta").innerHTML = `${scopeChip(l.scopeCode)} <span class="aol-code">${esc(shortGroup(l.optionGroup))}</span>`
      + (dependent ? ` &middot; each value belongs to a ${esc(l.parentFieldLabel || l.parentFieldKey)}` : "");
    document.getElementById("aolScopeNote").textContent = sc.note
      + (dependent && l.scopeCode !== "GLOBAL_ONLY" && !(state.detail.parents || []).length
        ? ` No ${l.parentFieldLabel || l.parentFieldKey} value exists yet for this organization -- add those first.` : "");
    const addBtn = document.getElementById("aolAddBtn");
    if (addBtn) addBtn.hidden = !CAN_EDIT || l.scopeCode === "GLOBAL_ONLY";
    document.getElementById("aolParentHead").hidden = !dependent;

    const parentLabel = v => {
      if (v == null || v === "") return "--";
      const p = (state.detail.parents || []).find(x => String(x.parentValue) === String(v));
      return p ? p.parentLabel : `${v} (not active)`;
    };
    const editable = CAN_EDIT && l.scopeCode !== "GLOBAL_ONLY";
    const overridable = CAN_EDIT && l.scopeCode === "ORG_EXTENSIBLE";
    document.getElementById("aolValueBody").innerHTML = (state.detail.values || []).map((v, i) => {
      const off = v.status === "Inactive";
      const btn = (act, icon, title) => `<button type="button" class="pm-button icon" data-aol-act="${act}" data-aol-i="${i}" title="${title}" aria-label="${title}"><i class="fa-solid ${icon}"></i></button>`;
      let actions = "";
      if (v.source === "ORG" && editable) {
        actions = off ? btn("reactivate", "fa-rotate-left", "Reactivate")
                      : btn("edit", "fa-pen", "Edit") + btn("retire", "fa-box-archive", "Retire");
      } else if (v.source !== "ORG" && overridable) {
        if (v.source === "HIDDEN") actions = btn("show", "fa-eye", "Show again") + btn("reset", "fa-rotate-left", "Reset to default");
        else actions = btn("override", "fa-pen", "Relabel / reorder") + btn("hide", "fa-eye-slash", "Hide for this organization")
                     + (v.source === "OVERRIDE" ? btn("reset", "fa-rotate-left", "Reset to default") : "");
      }
      const label = esc(v.optionLabel) + (v.source === "OVERRIDE" && v.globalLabel && v.globalLabel !== v.optionLabel
        ? `<div class="aol-code">Default: ${esc(v.globalLabel)}</div>` : "");
      return `<tr class="${off ? "aol-off" : ""}">
        <td>${label}</td>
        <td><span class="aol-code">${esc(v.optionValue)}</span></td>
        ${dependent ? `<td>${esc(v.source === "ORG" ? parentLabel(v.parentValue) : "Any")}</td>` : ""}
        <td>${esc(v.displayOrder)}</td>
        <td>${sourceChip(v.source)}</td>
        <td><span class="aol-chip ${off ? "aol-st-inactive" : "aol-st-active"}">${off ? (v.source === "ORG" ? "Retired" : "Hidden") : "Active"}</span></td>
        <td>${actions}</td>
      </tr>`;
    }).join("") || `<tr><td colspan="${dependent ? 7 : 6}" class="pm-empty">No values yet${editable ? " -- use Add Value." : "."}</td></tr>`;
  }

  async function onValueAction(ev) {
    const b = ev.target.closest("[data-aol-act]");
    if (!b) return;
    const v = state.detail.values[Number(b.dataset.aolI)];
    if (!v) return;
    switch (b.dataset.aolAct) {
      case "edit":       openModal("org", v); break;
      case "override":   openModal("override", v); break;
      case "retire":
        if (!await window.gracUi.confirm(`Retire "${v.optionLabel}"? It will no longer be offered on asset forms. Existing assets keep the value.`)) return;
        await saveOrg({ orgOptionId: v.orgOptionId, optionLabel: v.optionLabel, parentValue: v.parentValue, displayOrder: v.displayOrder, status: "Inactive" },
          `"${v.optionLabel}" retired.`);
        break;
      case "reactivate":
        await saveOrg({ orgOptionId: v.orgOptionId, optionLabel: v.optionLabel, parentValue: v.parentValue, displayOrder: v.displayOrder, status: "Active" },
          `"${v.optionLabel}" reactivated.`);
        break;
      case "hide":
        if (!await window.gracUi.confirm(`Hide the default "${v.optionLabel}" for this organization? It can be shown again later.`)) return;
        await override({ optionValue: v.optionValue, hidden: true }, `"${v.optionLabel}" hidden for this organization.`);
        break;
      case "show":
        await override({ optionValue: v.optionValue, hidden: false }, `"${v.optionLabel}" is offered again.`);
        break;
      case "reset":
        if (!await window.gracUi.confirm(`Reset "${v.optionLabel}" to the default label and order?`)) return;
        await override({ optionValue: v.optionValue, reset: true }, `"${v.globalLabel || v.optionLabel}" reset to the default.`);
        break;
    }
  }

  // ------------------------------------------------------------------ modal
  function openModal(mode, v) {
    const l = state.detail.list;
    state.modal = { mode, value: v };
    const dependent = mode === "org" && !!l.parentFieldKey;
    document.getElementById("aolModalTitle").textContent =
      mode === "override" ? "Relabel default" : v ? "Edit value" : `Add value to ${l.listName}`;
    setVal("aolLabel", v ? v.optionLabel : "");
    setVal("aolCode", v ? v.optionValue : "");
    document.getElementById("aolCode").disabled = !!v;
    document.getElementById("aolCodeWrap").hidden = mode === "override";
    document.getElementById("aolParentWrap").hidden = !dependent;
    document.getElementById("aolParentCaption").textContent = `${l.parentFieldLabel || l.parentFieldKey || "Parent"} *`;
    if (dependent) {
      document.getElementById("aolParent").innerHTML = `<option value="">Select</option>` + (state.detail.parents || [])
        .map(p => `<option value="${esc(p.parentValue)}">${esc(p.parentLabel)}</option>`).join("");
      setVal("aolParent", v ? v.parentValue : "");
    }
    setVal("aolOrder", v ? v.displayOrder : "");
    document.getElementById("aolGlobalNote").textContent = mode === "override" && v
      ? `Default label: ${v.globalLabel || v.optionLabel}. The change applies to this organization only; the code stays ${v.optionValue}.` : "";
    modalMessage("");
    document.getElementById("aolModal").hidden = false;
    document.getElementById("aolLabel").focus();
  }

  function closeModal() { document.getElementById("aolModal").hidden = true; state.modal = null; }

  async function saveModal(ev) {
    ev.preventDefault();
    if (!state.modal) return;
    const { mode, value } = state.modal;
    const label = val("aolLabel");
    if (!label) { modalMessage("A label is required."); return; }
    const orderText = val("aolOrder");
    const displayOrder = orderText === "" ? null : Number(orderText);
    let res;
    if (mode === "override") {
      res = await api("POST", `/${encodeURIComponent(state.group)}/override`, {
        organizationId: state.organizationId, optionValue: value.optionValue, optionLabel: label, displayOrder,
        hidden: value.source === "HIDDEN"
      });
    } else {
      if (!document.getElementById("aolParentWrap").hidden && !val("aolParent")) {
        modalMessage(`Choose the ${state.detail.list.parentFieldLabel || "parent"} this value belongs to.`); return;
      }
      res = await api("POST", `/${encodeURIComponent(state.group)}/values`, {
        organizationId: state.organizationId,
        orgOptionId: value ? value.orgOptionId : null,
        optionValue: value ? null : (val("aolCode") || null),
        optionLabel: label,
        parentValue: val("aolParent") || null,
        displayOrder: displayOrder ?? (value ? value.displayOrder : null),
        status: value ? value.status : "Active"
      });
    }
    if (!res.ok) { modalMessage(res.error); return; }
    closeModal();
    await reload(mode === "override" ? `"${label}" saved for this organization.` : value ? `"${label}" saved.` : `"${label}" added.`);
  }

  async function saveOrg(payload, message) {
    const res = await api("POST", `/${encodeURIComponent(state.group)}/values`, { organizationId: state.organizationId, ...payload });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    await reload(message);
  }

  async function override(payload, message) {
    const res = await api("POST", `/${encodeURIComponent(state.group)}/override`, { organizationId: state.organizationId, ...payload });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    await reload(message);
  }

  // ------------------------------------------------------------------ helpers
  async function api(method, path, body) {
    try {
      const r = await fetch(U(base + path), {
        method, credentials: "same-origin",
        headers: body ? { "Content-Type": "application/json" } : undefined,
        body: body ? JSON.stringify(body) : undefined
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok || data.success === false) {
        const hint = r.status === 404 && !data.error ? " -- the Asset Configuration API was not found; deploy the latest API and Web build" : "";
        return { ok: false, status: r.status, errorNumber: data.errorNumber, error: data.error || `Request failed (HTTP ${r.status})${hint}.` };
      }
      return { ok: true, status: r.status, data };
    } catch (err) { return { ok: false, status: 0, error: err.message }; }
  }
  function showMessage(text, kind) {
    const el = document.getElementById("aolMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.hidden = !text;
  }
  function hideMessage() { const el = document.getElementById("aolMessage"); el.hidden = true; el.textContent = ""; }
  function modalMessage(text) { const el = document.getElementById("aolModalMessage"); el.textContent = text || ""; el.hidden = !text; }
  async function notify(message, type) {
    if (window.gracUi) await window.gracUi.alert(message, { type: type || "info" }); else window.alert(message);
  }
  function scopeChip(code) { const s = SCOPE[code] || { label: code || "", cls: "aol-sc-fixed" }; return `<span class="aol-chip ${s.cls}">${esc(s.label)}</span>`; }
  function sourceChip(code) { const s = SOURCE[code] || { label: code || "", cls: "aol-src-global" }; return `<span class="aol-chip ${s.cls}">${esc(s.label)}</span>`; }
  function shortGroup(g) { return String(g || "").replace(/^asset_field\./, ""); }
  function val(id) { return (document.getElementById(id).value || "").trim(); }
  function setVal(id, v) { document.getElementById(id).value = v ?? ""; }
  function esc(v) { return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
})();
