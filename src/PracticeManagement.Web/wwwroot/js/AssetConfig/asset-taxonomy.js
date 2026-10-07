// =====================================================================
// Asset Taxonomy (migration 424) -- governance of the global category /
// L1-L2 subcategory / asset type masters (BRD 4.1, 5.2.3) and each
// organization's default owner role and support group per asset type.
// Loaded by asset-taxonomy.cshtml. Every rule (unique names, L1/L2 only,
// no move while in use, effective dates, concurrency) is enforced by the
// procedures; this screen only mirrors them and shows their messages.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config/taxonomy";
  const root = document.getElementById("atxRoot");
  if (!root) return;
  const CAN_GLOBAL = root.dataset.canEditGlobal === "1";
  const CAN_ORG = root.dataset.canEditOrg === "1";

  // modal: { kind: CATEGORY | SUBCATEGORY | TYPE, row }
  const state = { organizationId: null, data: null, modal: null, orgType: null };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    bind();
    await populateOrgs();
    const sel = document.getElementById("atxOrg");
    window.gracOrgPref.apply(sel);   // 2026-10-06: last-picked org, else lowest id
    state.organizationId = Number(sel.value) || null;
    await load();
  }

  async function populateOrgs() {
    const sel = document.getElementById("atxOrg");
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
    document.getElementById("atxOrg").addEventListener("change", e => { state.organizationId = Number(e.target.value) || null; load(); });
    document.getElementById("atxRefresh").addEventListener("click", () => load());
    let t = null;
    document.getElementById("atxSearch").addEventListener("input", () => { clearTimeout(t); t = setTimeout(render, 250); });
    document.getElementById("atxShowInactive").addEventListener("change", render);
    document.getElementById("atxSubCatFilter").addEventListener("change", render);
    document.getElementById("atxTypeCatFilter").addEventListener("change", () => { fillSubFilter(); render(); });
    document.getElementById("atxTypeSubFilter").addEventListener("change", render);
    document.querySelectorAll("[data-atx-tab]").forEach(b => b.addEventListener("click", () => selectTab(b.dataset.atxTab)));
    document.querySelectorAll("[data-atx-add]").forEach(b => b.addEventListener("click", () => openModal(b.dataset.atxAdd, null)));
    ["atxCatBody", "atxSubBody", "atxTypeBody"].forEach(id => document.getElementById(id).addEventListener("click", onRowAction));
    document.getElementById("atxCategory").addEventListener("change", () => fillParentPicker(null));
    document.getElementById("atxTypeCategory").addEventListener("change", () => fillTypeSubPicker(null));
    document.getElementById("atxForm").addEventListener("submit", saveModal);
    document.getElementById("atxOrgForm").addEventListener("submit", saveOrgDefaults);
    document.querySelectorAll("[data-close-atx]").forEach(b => b.addEventListener("click", closeModal));
    document.querySelectorAll("[data-close-atx-org]").forEach(b => b.addEventListener("click", closeOrgModal));
    document.addEventListener("keydown", ev => { if (ev.key === "Escape") { closeModal(); closeOrgModal(); } });
  }

  function selectTab(tab) {
    document.querySelectorAll("[data-atx-tab]").forEach(b => {
      const on = b.dataset.atxTab === tab; b.classList.toggle("active", on); b.setAttribute("aria-selected", on ? "true" : "false");
    });
    document.querySelectorAll("[data-atx-panel]").forEach(p => { p.hidden = p.dataset.atxPanel !== tab; });
  }

  // ------------------------------------------------------------------ load + render
  async function load(message) {
    const bodies = ["atxCatBody", "atxSubBody", "atxTypeBody"].map(id => document.getElementById(id));
    if (!state.organizationId) { bodies.forEach(b => { b.innerHTML = `<tr><td colspan="10" class="pm-empty">Select an organization.</td></tr>`; }); return; }
    bodies.forEach(b => { b.innerHTML = `<tr><td colspan="10" class="pm-empty">Loading...</td></tr>`; });
    const res = await api("GET", `/governance?organizationId=${state.organizationId}`);
    if (!res.ok) { bodies.forEach(b => { b.innerHTML = `<tr><td colspan="10" class="pm-empty">${esc(res.error)}</td></tr>`; }); return; }
    state.data = res.data.data;
    fillFilters();
    render();
    if (message) showMessage(message, "success");
  }

  function fillFilters() {
    const cats = state.data.categories || [];
    ["atxSubCatFilter", "atxTypeCatFilter"].forEach(id => {
      const sel = document.getElementById(id), keep = sel.value;
      sel.innerHTML = `<option value="">All categories</option>` + cats.map(c => `<option value="${c.categoryId}">${esc(c.categoryName)}</option>`).join("");
      sel.value = cats.some(c => String(c.categoryId) === keep) ? keep : "";
    });
    fillSubFilter();
  }

  function fillSubFilter() {
    const sel = document.getElementById("atxTypeSubFilter"), keep = sel.value, cat = val("atxTypeCatFilter");
    const subs = (state.data.subcategories || []).filter(s => !cat || String(s.categoryId) === cat);
    sel.innerHTML = `<option value="">All subcategories</option>` + subs.map(s => `<option value="${s.subcategoryId}">${esc(subPath(s))}</option>`).join("");
    sel.value = subs.some(s => String(s.subcategoryId) === keep) ? keep : "";
  }

  function render() {
    const q = val("atxSearch").toLowerCase(), showInactive = document.getElementById("atxShowInactive").checked;
    const keep = (name, active) => (showInactive || active) && (!q || String(name || "").toLowerCase().includes(q));
    const d = state.data;
    if (!d) return;
    const btn = (act, id, icon, title) => `<button type="button" class="pm-button icon" data-atx-act="${act}" data-atx-id="${id}" title="${title}" aria-label="${title}"><i class="fa-solid ${icon}"></i></button>`;

    document.getElementById("atxCatBody").innerHTML = d.categories.filter(c => keep(c.categoryName, c.isActive)).map(c => `
      <tr class="${c.isActive ? "" : "atx-off"}">
        <td>${esc(c.categoryName)}<div class="atx-code">${esc(c.categoryCode)}</div></td>
        <td>${esc(c.sector || "--")}</td>
        <td>${esc(c.ownerName || "--")}</td>
        <td>${esc(c.defaultCriticalityName || "--")}</td>
        <td>${esc(dateRange(c.effectiveFrom, c.effectiveTo))}</td>
        <td>${statusChip(c)}</td>
        <td>${esc(c.subcategoryCount)}</td>
        <td>${esc(c.assetCount)}</td>
        <td>${CAN_GLOBAL ? btn("CATEGORY", c.categoryId, "fa-pen", "Edit") : btn("VIEW_CATEGORY", c.categoryId, "fa-eye", "View")}</td>
      </tr>`).join("") || empty(9, "No categories match.");

    const subCat = val("atxSubCatFilter");
    document.getElementById("atxSubBody").innerHTML = d.subcategories
      .filter(s => (!subCat || String(s.categoryId) === subCat) && keep(s.subcategoryName, s.isActive)).map(s => `
      <tr class="${s.isActive ? "" : "atx-off"}">
        <td class="${s.levelNo === 2 ? "atx-l2" : ""}">${s.levelNo === 2 ? `<span class="atx-code">${esc(s.parentSubcategoryName)} /</span> ` : ""}${esc(s.subcategoryName)}<div class="atx-code">${esc(s.subcategoryCode)}</div></td>
        <td>L${esc(s.levelNo)}</td>
        <td>${esc(catName(s.categoryId))}</td>
        <td>${esc(dateRange(s.effectiveFrom, s.effectiveTo))}</td>
        <td>${statusChip(s)}</td>
        <td>${esc(s.typeCount)}</td>
        <td>${esc(s.assetCount)}</td>
        <td>${CAN_GLOBAL ? btn("SUBCATEGORY", s.subcategoryId, "fa-pen", "Edit") : btn("VIEW_SUBCATEGORY", s.subcategoryId, "fa-eye", "View")}</td>
      </tr>`).join("") || empty(8, "No subcategories match.");

    const tCat = val("atxTypeCatFilter"), tSub = val("atxTypeSubFilter");
    document.getElementById("atxTypeBody").innerHTML = d.types
      .filter(t => (!tCat || String(t.categoryId) === tCat) && (!tSub || String(t.subcategoryId) === tSub) && keep(t.assetTypeName, t.isActive)).map(t => `
      <tr class="${t.isActive ? "" : "atx-off"}">
        <td>${esc(t.assetTypeName)}<div class="atx-code">${esc(t.assetTypeCode)}</div></td>
        <td>${esc(subPath(subById(t.subcategoryId)))}</td>
        <td>${esc(t.defaultCriticalityName || (t.effectiveCriticalityName ? t.effectiveCriticalityName + " (category)" : "--"))}</td>
        <td>${esc(t.businessOwnerRoleName || "--")}</td>
        <td>${esc(t.supportTeamName || "--")}</td>
        <td>${esc(dateRange(t.effectiveFrom, t.effectiveTo))}</td>
        <td>${statusChip(t)}</td>
        <td>${esc(t.templateCount)}</td>
        <td>${esc(t.assetCount)}</td>
        <td>${CAN_GLOBAL ? btn("TYPE", t.assetTypeId, "fa-pen", "Edit") : btn("VIEW_TYPE", t.assetTypeId, "fa-eye", "View")}${CAN_ORG ? btn("ORG", t.assetTypeId, "fa-user-gear", "Organization defaults") : ""}</td>
      </tr>`).join("") || empty(10, "No asset types match.");
  }

  function onRowAction(ev) {
    const b = ev.target.closest("[data-atx-act]");
    if (!b) return;
    const id = Number(b.dataset.atxId), act = b.dataset.atxAct;
    if (act === "ORG") { openOrgModal(id); return; }
    const kind = act.replace(/^VIEW_/, "");
    const row = kind === "CATEGORY" ? state.data.categories.find(c => c.categoryId === id)
              : kind === "SUBCATEGORY" ? subById(id) : state.data.types.find(t => t.assetTypeId === id);
    if (row) openModal(kind, row);
  }

  // ------------------------------------------------------------------ node modal
  function openModal(kind, row) {
    state.modal = { kind, row };
    const readOnly = !CAN_GLOBAL;
    const noun = kind === "CATEGORY" ? "Category" : kind === "SUBCATEGORY" ? "Subcategory" : "Asset Type";
    document.getElementById("atxModalTitle").textContent = (readOnly ? "" : row ? "Edit " : "Add ") + noun + (readOnly && row ? `: ${row.categoryName || row.subcategoryName || row.assetTypeName}` : "");
    document.querySelectorAll("#atxForm [data-atx-for]").forEach(el => { el.hidden = !el.dataset.atxFor.split(" ").includes(kind); });
    const code = row ? (row.categoryCode || row.subcategoryCode || row.assetTypeCode) : "";
    document.getElementById("atxCode").textContent = row ? `Code: ${code} (fixed)` : "The code is generated from the name when saved.";
    setVal("atxName", row ? (row.categoryName || row.subcategoryName || row.assetTypeName) : "");
    setVal("atxDesc", row ? row.description || "" : "");
    setVal("atxOrder", row ? row.displayOrder : "");
    setVal("atxFrom", row ? isoDate(row.effectiveFrom) : "");
    setVal("atxTo", row ? isoDate(row.effectiveTo) : "");
    document.getElementById("atxActive").checked = row ? !!row.isActive : true;
    document.getElementById("atxCriticality").innerHTML = `<option value="">${kind === "TYPE" ? "Use the category default" : "None"}</option>`
      + (state.data.criticality || []).map(c => `<option value="${c.criticalityId}">${esc(c.criticalityName)}</option>`).join("");
    setVal("atxCriticality", row ? row.defaultCriticalityId ?? "" : "");
    if (kind === "CATEGORY") {
      setVal("atxSector", row ? row.sector || "" : ""); setVal("atxOwner", row ? row.ownerName || "" : ""); setVal("atxStandards", row ? row.standards || "" : "");
    }
    const catOptions = selected => `<option value="">Select</option>` + state.data.categories
      .filter(c => c.isActive || String(c.categoryId) === String(selected))
      .map(c => `<option value="${c.categoryId}">${esc(c.categoryName)}</option>`).join("");
    if (kind === "SUBCATEGORY") {
      const cat = row ? row.categoryId : (val("atxSubCatFilter") || "");
      document.getElementById("atxCategory").innerHTML = catOptions(cat);
      setVal("atxCategory", cat);
      fillParentPicker(row ? row.parentSubcategoryId : null);
    }
    if (kind === "TYPE") {
      const sub = row ? subById(row.subcategoryId) : subById(Number(val("atxTypeSubFilter")));
      const cat = sub ? sub.categoryId : (val("atxTypeCatFilter") || "");
      document.getElementById("atxTypeCategory").innerHTML = catOptions(cat);
      setVal("atxTypeCategory", cat);
      fillTypeSubPicker(sub ? sub.subcategoryId : null);
    }
    document.querySelectorAll("#atxForm input, #atxForm select, #atxForm textarea").forEach(el => { el.disabled = readOnly; });
    document.querySelector("#atxForm button[type=submit]").hidden = readOnly;
    modalMessage("atxModalMessage", "");
    document.getElementById("atxModal").hidden = false;
    if (!readOnly) document.getElementById("atxName").focus();
  }

  // L2 parent: an L1 of the chosen category, never the row itself.
  function fillParentPicker(selected) {
    const cat = val("atxCategory"), self = state.modal?.row?.subcategoryId;
    const l1 = (state.data.subcategories || []).filter(s => String(s.categoryId) === cat && s.levelNo === 1 && s.subcategoryId !== self
      && (s.isActive || s.subcategoryId === selected));
    document.getElementById("atxParent").innerHTML = `<option value="">None (level 1)</option>`
      + l1.map(s => `<option value="${s.subcategoryId}">${esc(s.subcategoryName)}</option>`).join("");
    setVal("atxParent", selected ?? "");
  }

  function fillTypeSubPicker(selected) {
    const cat = val("atxTypeCategory");
    const subs = (state.data.subcategories || []).filter(s => String(s.categoryId) === cat && (s.isActive || s.subcategoryId === selected));
    document.getElementById("atxTypeSub").innerHTML = `<option value="">Select</option>`
      + subs.map(s => `<option value="${s.subcategoryId}">${esc(subPath(s))}</option>`).join("");
    setVal("atxTypeSub", selected ?? "");
  }

  function closeModal() { document.getElementById("atxModal").hidden = true; state.modal = null; }

  async function saveModal(ev) {
    ev.preventDefault();
    if (!state.modal || !CAN_GLOBAL) return;
    const { kind, row } = state.modal;
    const name = val("atxName");
    if (!name) { modalMessage("atxModalMessage", "A name is required."); return; }
    const from = val("atxFrom") || null, to = val("atxTo") || null;
    if (from && to && to < from) { modalMessage("atxModalMessage", "Effective To cannot be before Effective From."); return; }
    const common = {
      description: val("atxDesc") || null, effectiveFrom: from, effectiveTo: to,
      isActive: document.getElementById("atxActive").checked,
      displayOrder: val("atxOrder") === "" ? null : Number(val("atxOrder")),
      expectedRecordVersion: row ? row.recordVersion : null
    };
    let res;
    if (kind === "CATEGORY") {
      res = await api("POST", "/categories", { ...common, categoryId: row ? row.categoryId : null, categoryName: name,
        sector: val("atxSector") || null, ownerName: val("atxOwner") || null, standards: val("atxStandards") || null,
        defaultCriticalityId: Number(val("atxCriticality")) || null });
    } else if (kind === "SUBCATEGORY") {
      if (!val("atxCategory")) { modalMessage("atxModalMessage", "Select a category."); return; }
      res = await api("POST", "/subcategories", { ...common, subcategoryId: row ? row.subcategoryId : null,
        categoryId: Number(val("atxCategory")), parentSubcategoryId: Number(val("atxParent")) || null, subcategoryName: name });
    } else {
      if (!val("atxTypeSub")) { modalMessage("atxModalMessage", "Select a subcategory."); return; }
      res = await api("POST", "/types", { ...common, assetTypeId: row ? row.assetTypeId : null,
        subcategoryId: Number(val("atxTypeSub")), assetTypeName: name, defaultCriticalityId: Number(val("atxCriticality")) || null });
    }
    if (!res.ok) {
      modalMessage("atxModalMessage", res.error);
      if (res.status === 409) await load();
      return;
    }
    closeModal();
    await load(`"${name}" saved.`);
  }

  // ------------------------------------------------------------------ organization defaults
  function openOrgModal(typeId) {
    const t = state.data.types.find(x => x.assetTypeId === typeId);
    if (!t) return;
    state.orgType = t;
    document.getElementById("atxOrgModalTitle").textContent = `Organization defaults: ${t.assetTypeName}`;
    document.getElementById("atxOrgRole").innerHTML = `<option value="">None</option>`
      + (state.data.roles || []).map(r => `<option value="${r.roleId}">${esc(r.roleName)}</option>`).join("");
    document.getElementById("atxOrgTeam").innerHTML = `<option value="">None</option>`
      + (state.data.teams || []).map(x => `<option value="${x.teamId}">${esc(x.teamName)}</option>`).join("");
    setVal("atxOrgRole", t.businessOwnerRoleId ?? "");
    setVal("atxOrgTeam", t.supportTeamId ?? "");
    modalMessage("atxOrgMessage", "");
    document.getElementById("atxOrgModal").hidden = false;
  }

  function closeOrgModal() { document.getElementById("atxOrgModal").hidden = true; state.orgType = null; }

  async function saveOrgDefaults(ev) {
    ev.preventDefault();
    const t = state.orgType;
    if (!t || !CAN_ORG) return;
    const res = await api("POST", `/types/${t.assetTypeId}/org-defaults`, {
      organizationId: state.organizationId,
      businessOwnerRoleId: Number(val("atxOrgRole")) || null,
      supportTeamId: Number(val("atxOrgTeam")) || null
    });
    if (!res.ok) { modalMessage("atxOrgMessage", res.error); return; }
    closeOrgModal();
    await load(`Organization defaults saved for "${t.assetTypeName}".`);
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
  function statusChip(r) {
    if (!r.isActive) return `<span class="atx-chip atx-st-inactive">Inactive</span>`;
    return r.isSelectable ? `<span class="atx-chip atx-st-active">Active</span>`
      : `<span class="atx-chip atx-st-pending" title="Active, but outside its effective dates or under an inactive parent">Not in effect</span>`;
  }
  function subById(id) { return (state.data?.subcategories || []).find(s => s.subcategoryId === id); }
  function subPath(s) { return !s ? "" : s.levelNo === 2 ? `${s.parentSubcategoryName} / ${s.subcategoryName}` : s.subcategoryName; }
  function catName(id) { const c = (state.data?.categories || []).find(x => x.categoryId === id); return c ? c.categoryName : ""; }
  function empty(cols, text) { return `<tr><td colspan="${cols}" class="pm-empty">${esc(text)}</td></tr>`; }
  function showMessage(text, kind) {
    const el = document.getElementById("atxMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.hidden = !text;
  }
  function modalMessage(id, text) { const el = document.getElementById(id); el.textContent = text || ""; el.hidden = !text; }
  function val(id) { return (document.getElementById(id).value || "").trim(); }
  function setVal(id, v) { document.getElementById(id).value = v ?? ""; }
  function isoDate(v) { return v ? String(v).substring(0, 10) : ""; }
  function fmtDate(v) { return !v ? "" : (window.gracFormatDisplayDate ? window.gracFormatDisplayDate(v) : isoDate(v)); }
  function dateRange(from, to) { return !from && !to ? "--" : `${from ? fmtDate(from) : "Always"}${to ? " to " + fmtDate(to) : " onwards"}`; }
  function esc(v) { return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
})();
