// =====================================================================
// Asset Form Templates (migration 420) -- BRD 5.2 Asset Type Form Designer.
// Loaded by Views/Practice/Partials/asset-form-templates.cshtml.
//
// All rules (Draft-only edits, baseline fields, sensitivity floor,
// segregation of duties, readiness gates, one Active / one working
// version, optimistic concurrency) are enforced by the procedures; this
// screen only mirrors them so the user is not offered moves that will be
// refused. Every refusal message shown here is the procedure's own.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config";
  const root = document.getElementById("aftRoot");
  if (!root) return;
  const CAN_EDIT = root.dataset.canEdit === "1";
  const CAN_APPROVE = root.dataset.canApprove === "1";

  const STATUS = {
    DRAFT:            { label: "Draft",            cls: "aft-st-draft" },
    TESTING:          { label: "Testing",          cls: "aft-st-testing" },
    PENDING_APPROVAL: { label: "Pending Approval", cls: "aft-st-pending" },
    APPROVED:         { label: "Approved",         cls: "aft-st-approved" },
    ACTIVE:           { label: "Active",           cls: "aft-st-active" },
    RETIRED:          { label: "Retired",          cls: "aft-st-retired" }
  };

  const state = {
    organizationId: null, statusCode: "", search: "",
    listRows: [], taxonomy: [], employees: [],
    detail: null,              // { header, sections, fields, history }
    libRows: [], libGroup: "", libSearch: ""
  };
  let pager = null, libPager = null, openMenuEl = null, openMenuTrigger = null, searchTimer = null, libTimer = null;

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  // ------------------------------------------------------------------ init
  async function init() {
    pager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "aftPager", onChange: refreshList }) : null;
    libPager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "aftLibPager", onChange: refreshLibrary }) : null;
    bindList();
    bindDesigner();
    bindModals();
    await populateOrgs();
    const params = new URLSearchParams(window.location.search);
    const sel = document.getElementById("aftOrg");
    const wantedOrg = params.get("orgId");
    if (wantedOrg && [...sel.options].some(o => o.value === wantedOrg)) sel.value = wantedOrg;
    else window.gracOrgPref.apply(sel);   // 2026-10-06: last-picked org, else lowest id
    state.organizationId = Number(sel.value) || null;
    await refreshList();
    const wantedTemplate = Number(params.get("templateId"));
    if (wantedTemplate && state.organizationId) await openDesigner(wantedTemplate);
  }

  async function populateOrgs() {
    const sel = document.getElementById("aftOrg");
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
    } catch (_) { /* leaves the placeholder */ }
    if (sel.options.length === 2) sel.disabled = true;
  }

  // ------------------------------------------------------------------ list
  function bindList() {
    document.getElementById("aftOrg").addEventListener("change", e => {
      state.organizationId = Number(e.target.value) || null;
      state.employees = [];
      pager?.reset(true); refreshList();
    });
    document.getElementById("aftStatus").addEventListener("change", e => {
      state.statusCode = e.target.value || ""; pager?.reset(true); refreshList();
    });
    document.getElementById("aftSearch").addEventListener("input", e => {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(() => { state.search = e.target.value.trim(); pager?.reset(true); refreshList(); }, 300);
    });
    document.getElementById("aftRefresh").addEventListener("click", refreshList);
    document.getElementById("aftNewBtn")?.addEventListener("click", openNewModal);

    const body = document.getElementById("aftListBody");
    body.addEventListener("click", ev => {
      const trigger = ev.target.closest(".pm-action-trigger[data-aft-row]");
      if (trigger) {
        ev.preventDefault(); ev.stopPropagation();
        if (openMenuTrigger === trigger) { closeMenu(); return; }
        openMenu(trigger, rowMenu(state.listRows[Number(trigger.dataset.aftRow)]));
        return;
      }
      const tr = ev.target.closest("tr[data-aft-id]");
      if (tr) openDesigner(Number(tr.dataset.aftId));
    });
    document.addEventListener("click", ev => {
      if (!openMenuEl || ev.target.closest(".pm-action-menu") || ev.target.closest(".pm-action-trigger")) return;
      closeMenu();
    });
    document.addEventListener("keydown", ev => { if (ev.key === "Escape") { closeMenu(); closeAllModals(); } });
    window.addEventListener("resize", closeMenu);
    window.addEventListener("scroll", closeMenu, true);
  }

  async function refreshList() {
    const body = document.getElementById("aftListBody");
    if (!state.organizationId) {
      pager?.clear();
      body.innerHTML = `<tr><td colspan="8" class="pm-empty">Select an organization.</td></tr>`;
      return;
    }
    body.innerHTML = `<tr><td colspan="8" class="pm-empty">Loading...</td></tr>`;
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: pager ? pager.page() : 1, pageSize: pager ? pager.size() : 25 });
    if (state.statusCode) qs.set("statusCode", state.statusCode);
    if (state.search) qs.set("search", state.search);
    const res = await api("GET", `/templates?${qs}`);
    if (!res.ok) { pager?.clear(); body.innerHTML = `<tr><td colspan="8" class="pm-empty">${esc(res.error || "Templates could not be loaded.")}</td></tr>`; return; }
    const rows = res.data?.data?.rows || [];
    state.listRows = rows;
    pager?.setTotal(res.data?.data?.totalRows, rows.length);
    if (!rows.length) {
      body.innerHTML = `<tr><td colspan="8" class="pm-empty">No asset form templates yet${CAN_EDIT ? " -- use New Template to design one." : "."}</td></tr>`;
      return;
    }
    body.innerHTML = rows.map((r, i) => `
      <tr class="pm-row-clickable" data-aft-id="${r.templateId}">
        <td>${esc(r.assetTypeName)}<span class="aft-sub">${esc(r.categoryName)} / ${esc(r.subcategoryName)}</span></td>
        <td>${esc(r.templateName)}</td>
        <td>v${esc(r.versionNo)}</td>
        <td>${chip(r.statusCode)}</td>
        <td>${esc(dateRange(r.effectiveFrom, r.effectiveTo))}</td>
        <td>${esc(r.templateOwnerName || "--")}</td>
        <td>${esc(r.fieldCount)}</td>
        <td><button type="button" class="pm-action-trigger" data-aft-row="${i}" aria-haspopup="menu" aria-expanded="false" title="Actions">
              <i class="fas fa-ellipsis-v fa-solid fa-ellipsis-vertical" aria-hidden="true"></i></button></td>
      </tr>`).join("");
  }

  function rowMenu(r) {
    const items = [{ icon: "fa-pen-ruler", label: r.statusCode === "DRAFT" && CAN_EDIT ? "Design" : "Open", action: () => openDesigner(r.templateId) }];
    if (CAN_EDIT && (r.statusCode === "ACTIVE" || r.statusCode === "RETIRED"))
      items.push({ icon: "fa-code-branch", label: "New Version", action: () => newVersion(r.templateId) });
    return items;
  }

  // ------------------------------------------------------------------ designer
  function bindDesigner() {
    document.getElementById("aftBack").addEventListener("click", () => showList());
    document.querySelectorAll("[data-aft-tab]").forEach(btn => btn.addEventListener("click", () => selectTab(btn.dataset.aftTab)));
    document.getElementById("aftAddFieldsBtn").addEventListener("click", openLibrary);
    document.getElementById("aftAddSectionBtn").addEventListener("click", () => openSectionModal(null));
    document.getElementById("aftReadyRefresh").addEventListener("click", loadReadiness);
    document.getElementById("aftSettingsForm").addEventListener("submit", saveSettings);

    document.getElementById("aftFieldSections").addEventListener("click", ev => {
      const edit = ev.target.closest("[data-aft-field-edit]");
      if (edit) { openFieldModal(Number(edit.dataset.aftFieldEdit)); return; }
      const rm = ev.target.closest("[data-aft-field-remove]");
      if (rm) removeField(Number(rm.dataset.aftFieldRemove));
    });
    document.getElementById("aftSectionBody").addEventListener("click", ev => {
      const edit = ev.target.closest("[data-aft-section-edit]");
      if (edit) openSectionModal(Number(edit.dataset.aftSectionEdit));
    });
    // 421: rules + preview.
    document.getElementById("aftAddRuleBtn").addEventListener("click", () => openRuleModal(null));
    document.getElementById("aftRuleBody").addEventListener("click", ev => {
      const edit = ev.target.closest("[data-aft-rule-edit]");
      if (edit) { openRuleModal(Number(edit.dataset.aftRuleEdit)); return; }
      const rm = ev.target.closest("[data-aft-rule-remove]");
      if (rm) removeRule(Number(rm.dataset.aftRuleRemove));
    });
    document.getElementById("aftPreviewRun").addEventListener("click", runPreview);
  }

  function showList() {
    document.getElementById("aftDesignView").hidden = true;
    document.getElementById("aftListView").hidden = false;
    state.detail = null;
    refreshList();
  }

  function selectTab(name) {
    document.querySelectorAll("[data-aft-tab]").forEach(b => {
      const on = b.dataset.aftTab === name;
      b.classList.toggle("active", on); b.setAttribute("aria-selected", on ? "true" : "false");
    });
    document.querySelectorAll("[data-aft-panel]").forEach(p => { p.hidden = p.dataset.aftPanel !== name; });
    if (name === "readiness") loadReadiness();
  }

  async function openDesigner(templateId) {
    closeMenu();
    const res = await api("GET", `/templates/${templateId}?organizationId=${state.organizationId}`);
    if (!res.ok) { await notify(res.error || "The template could not be opened.", "error"); return; }
    state.detail = res.data.data;
    document.getElementById("aftListView").hidden = true;
    document.getElementById("aftDesignView").hidden = false;
    await ensureEmployees();
    renderDesigner();
    selectTab(document.querySelector("[data-aft-tab].active")?.dataset.aftTab || "fields");
  }

  async function reloadDesigner(message) {
    if (!state.detail) return;
    const id = state.detail.header.templateId;
    const res = await api("GET", `/templates/${id}?organizationId=${state.organizationId}`);
    if (res.ok) state.detail = res.data.data;
    renderDesigner();
    if (message) showMessage("aftDesignMessage", message, "success");
    if (!document.querySelector('[data-aft-panel="readiness"]').hidden) loadReadiness();
  }

  function editable() {
    return CAN_EDIT && state.detail && state.detail.header.statusCode === "DRAFT";
  }

  function renderDesigner() {
    const h = state.detail.header;
    document.getElementById("aftDesignTitle").innerHTML =
      `${esc(h.templateName)} &middot; v${esc(h.versionNo)} ${chip(h.statusCode)}`;
    document.getElementById("aftDesignMeta").textContent =
      `${h.categoryName} / ${h.subcategoryName} / ${h.assetTypeName}` +
      ` -- owner: ${h.templateOwnerName || "not set"}` +
      (h.effectiveFrom ? ` -- effective ${dateRange(h.effectiveFrom, h.effectiveTo)}` : "") +
      (h.sourceVersionNo ? ` -- from v${h.sourceVersionNo}` : "");
    root.classList.toggle("aft-locked", !editable());
    renderActions();
    renderFields();
    renderSections();
    renderRules();
    renderPreviewInputs();
    renderSettings();
    renderHistory();
  }

  // Moves offered per status -- the framework's transition rules (420).
  function renderActions() {
    const h = state.detail.header, host = document.getElementById("aftDesignActions");
    const a = [];
    const btn = (label, icon, fn, primary) => a.push({ label, icon, fn, primary });
    if (CAN_EDIT) {
      if (h.statusCode === "DRAFT") {
        btn("Submit for Testing", "fa-flask", () => transition("TESTING"), true);
        btn("Discard Draft", "fa-trash-can", () => transition("RETIRED", "Why is this draft being discarded?"));
      }
      if (h.statusCode === "TESTING") {
        if (h.approvalRequired) btn("Submit for Approval", "fa-paper-plane", () => transition("PENDING_APPROVAL"), true);
        else if (CAN_APPROVE) btn("Approve", "fa-circle-check", () => transition("APPROVED"), true);
        btn("Return to Draft", "fa-rotate-left", () => transition("DRAFT", "What needs to change?"));
      }
      if (h.statusCode === "APPROVED") {
        btn("Activate", "fa-bolt", () => transition("ACTIVE", null,
          "Activate this version for new asset registrations? The current Active version, if any, will be retired."), true);
        btn("Withdraw", "fa-ban", () => transition("RETIRED", "Why is this approved version being withdrawn?"));
      }
      if (h.statusCode === "ACTIVE") btn("Retire", "fa-box-archive", () => transition("RETIRED", "Why is this active version being retired?"));
      if (h.statusCode === "ACTIVE" || h.statusCode === "RETIRED") btn("New Version", "fa-code-branch", () => newVersion(h.templateId), true);
    }
    if (h.statusCode === "PENDING_APPROVAL" && CAN_APPROVE) {
      btn("Approve", "fa-circle-check", () => transition("APPROVED", null, "Approve this template version?"), true);
      btn("Return / Reject", "fa-rotate-left", () => transition("DRAFT", "Why is this version being returned?"));
    }
    host.innerHTML = a.map((x, i) =>
      `<button type="button" class="pm-button${x.primary ? " primary" : ""}" data-aft-act="${i}"><i class="fa-solid ${x.icon}"></i> ${esc(x.label)}</button>`).join("");
    host.querySelectorAll("[data-aft-act]").forEach(b => b.addEventListener("click", () => a[Number(b.dataset.aftAct)].fn()));
  }

  function renderFields() {
    const { sections, fields } = state.detail;
    const host = document.getElementById("aftFieldSections");
    const placeable = sections.filter(s => !s.isSystem);
    if (!placeable.length) { host.innerHTML = `<p class="pm-empty">No sections. Add one on the Sections tab.</p>`; return; }
    host.innerHTML = placeable.map(s => {
      const own = fields.filter(f => f.sectionId === s.sectionId);
      const rows = own.length ? own.map(f => `
        <tr>
          <td>${esc(f.displayLabel)} ${f.isSystemMandatory ? `<span class="pm-badge aft-baseline" title="Baseline field: cannot be removed, hidden or made optional">Baseline</span>` : ""}
              <span class="aft-sub">${esc(f.groupName)}${f.definitionStatus !== "ACTIVE" ? " -- retired in dictionary" : ""}</span></td>
          <td>${esc(f.dataTypeCode)}</td>
          <td>${yn(f.isVisible)}</td>
          <td>${yn(f.isMandatory)}</td>
          <td>${yn(f.isReadOnly)}</td>
          <td>${esc(f.hiddenValueBehavior)}</td>
          <td>${esc(f.sensitivityOverride || f.baselineSensitivity)}</td>
          <td>${esc(f.displayOrder)}</td>
          <td class="aft-row-actions">
            <button type="button" class="pm-button icon" data-aft-field-edit="${f.fieldDefinitionId}" title="${editable() ? "Edit" : "View"}"><i class="fa-solid ${editable() ? "fa-pen" : "fa-eye"}"></i></button>
            ${editable() && !f.isSystemMandatory ? `<button type="button" class="pm-button icon" data-aft-field-remove="${f.fieldDefinitionId}" title="Remove"><i class="fa-solid fa-xmark"></i></button>` : ""}
          </td>
        </tr>`).join("") : `<tr><td colspan="9" class="pm-empty">No fields in this section.</td></tr>`;
      return `
        <div class="aft-section">
          <div class="aft-section-title">${esc(s.sectionLabel)}${s.tabLabel ? `<small>Tab: ${esc(s.tabLabel)}</small>` : ""}<small>${s.layoutColumns === 1 ? "One column" : "Two columns"}${s.isActive ? "" : " -- inactive"}</small></div>
          <div class="pm-table-wrap">
            <table>
              <thead><tr><th>Field</th><th>Type</th><th>Visible</th><th>Mandatory</th><th>Read only</th><th>If hidden</th><th>Sensitivity</th><th>Order</th><th aria-label="Actions"></th></tr></thead>
              <tbody>${rows}</tbody>
            </table>
          </div>
        </div>`;
    }).join("");
  }

  function renderSections() {
    const body = document.getElementById("aftSectionBody");
    body.innerHTML = state.detail.sections.map(s => `
      <tr>
        <td>${esc(s.sectionLabel)} ${s.isSystem ? `<span class="pm-badge">System</span>` : ""}</td>
        <td>${esc(s.tabLabel || "--")}</td>
        <td>${s.layoutColumns === 1 ? "One column" : "Two columns"}</td>
        <td>${esc(s.displayOrder)}</td>
        <td>${esc(s.fieldCount)}</td>
        <td>${s.isActive ? "Active" : "Inactive"}</td>
        <td>${editable() && !s.isSystem ? `<button type="button" class="pm-button icon" data-aft-section-edit="${s.sectionId}" title="Edit"><i class="fa-solid fa-pen"></i></button>` : ""}</td>
      </tr>`).join("") || `<tr><td colspan="7" class="pm-empty">No sections.</td></tr>`;
  }

  function renderSettings() {
    const h = state.detail.header;
    setVal("aftSetName", h.templateName);
    renderEmployeeOptions("aftSetOwner", "-- select --", h.templateOwnerEmployeeId);
    setVal("aftSetApproval", h.approvalRequired ? "true" : "false");
    setVal("aftSetFrom", isoDate(h.effectiveFrom));
    setVal("aftSetTo", isoDate(h.effectiveTo));
    setVal("aftSetReason", h.changeReason || "");
    document.querySelectorAll("#aftSettingsForm input, #aftSettingsForm select, #aftSettingsForm textarea")
      .forEach(el => { el.disabled = !editable(); });
  }

  function renderHistory() {
    const body = document.getElementById("aftHistoryBody");
    body.innerHTML = (state.detail.history || []).map(x => `
      <tr>
        <td>${esc(dateTime(x.transitionedAt))}</td>
        <td>${esc(x.fromStatus || "--")}</td>
        <td>${esc(x.toStatus)}</td>
        <td>${esc(x.actorName || (x.actorEmployeeId ? "Employee #" + x.actorEmployeeId : "System"))}</td>
        <td>${esc(x.reasonText || x.reasonCode || "")}</td>
      </tr>`).join("") || `<tr><td colspan="5" class="pm-empty">No history.</td></tr>`;
  }

  async function loadReadiness() {
    if (!state.detail) return;
    const body = document.getElementById("aftReadyBody");
    body.innerHTML = `<tr><td colspan="3" class="pm-empty">Checking...</td></tr>`;
    const res = await api("GET", `/templates/${state.detail.header.templateId}/readiness?organizationId=${state.organizationId}`);
    if (!res.ok) { body.innerHTML = `<tr><td colspan="3" class="pm-empty">${esc(res.error || "Readiness could not be checked.")}</td></tr>`; return; }
    const d = res.data.data;
    document.getElementById("aftReadySummary").textContent = d.errorCount
      ? `${d.errorCount} blocking issue(s), ${d.warningCount} warning(s). Blocking issues must be resolved before testing, approval or activation.`
      : `Ready to publish. ${d.warningCount} warning(s).`;
    body.innerHTML = (d.issues || []).map(i => `
      <tr>
        <td><span class="aft-status ${i.severity === "ERROR" ? "aft-sev-error" : "aft-sev-warning"}">${esc(i.severity === "ERROR" ? "Blocking" : "Warning")}</span></td>
        <td>${esc(i.checkCode)}</td>
        <td>${esc(i.message)}</td>
      </tr>`).join("") || `<tr><td colspan="3" class="pm-empty">No issues found.</td></tr>`;
  }

  // ------------------------------------------------------------------ writes
  async function transition(toStatusCode, reasonQuestion, confirmQuestion) {
    const h = state.detail.header;
    let reasonText = null;
    if (reasonQuestion) {
      reasonText = await window.gracUi.promptRequired(reasonQuestion, { title: "Reason required", inputLabel: "Reason" });
      if (reasonText === null) return;
    } else if (confirmQuestion && !await window.gracUi.confirm(confirmQuestion)) return;
    const res = await api("POST", `/templates/${h.templateId}/transition`, {
      organizationId: state.organizationId, toStatusCode, reasonText, expectedRecordVersion: h.recordVersion
    });
    if (!res.ok) {
      showMessage("aftDesignMessage", res.error, "error");
      if (res.errorNumber === 54223) selectTab("readiness");
      if (res.status === 409) await reloadDesigner();
      return;
    }
    await reloadDesigner(`Template moved to ${STATUS[toStatusCode]?.label || toStatusCode}.`);
  }

  async function newVersion(templateId) {
    closeMenu();
    const reason = await window.gracUi.promptRequired("Why is a new version needed? This is recorded as the change reason.",
      { title: "New version", inputLabel: "Change reason" });
    if (reason === null) return;
    const res = await api("POST", `/templates/${templateId}/new-version`, { organizationId: state.organizationId, changeReason: reason });
    if (!res.ok) { await notify(res.error, "error"); return; }
    await openDesigner(res.data.id);
    showMessage("aftDesignMessage", "New draft version created from the selected version.", "success");
  }

  async function saveSettings(ev) {
    ev.preventDefault();
    if (!editable()) return;
    const h = state.detail.header;
    const res = await api("POST", `/templates/${h.templateId}/header`, {
      organizationId: state.organizationId,
      templateName: val("aftSetName"),
      approvalRequired: val("aftSetApproval") === "true",
      templateOwnerEmployeeId: Number(val("aftSetOwner")) || null,
      effectiveFrom: val("aftSetFrom") || null,
      effectiveTo: val("aftSetTo") || null,
      changeReason: val("aftSetReason") || null,
      expectedRecordVersion: h.recordVersion
    });
    if (!res.ok) { showMessage("aftDesignMessage", res.error, "error"); if (res.status === 409) await reloadDesigner(); return; }
    await reloadDesigner("Settings saved.");
  }

  async function removeField(fieldDefinitionId) {
    const f = state.detail.fields.find(x => x.fieldDefinitionId === fieldDefinitionId);
    if (!f || !await window.gracUi.confirm(`Remove "${f.displayLabel}" from this template?`)) return;
    const res = await api("POST", `/templates/${state.detail.header.templateId}/fields/remove`,
      { organizationId: state.organizationId, fieldDefinitionId });
    if (!res.ok) { showMessage("aftDesignMessage", res.error, "error"); return; }
    await reloadDesigner(`"${f.displayLabel}" removed.`);
  }

  // ------------------------------------------------------------------ modals
  function bindModals() {
    document.querySelectorAll("[data-close-aft]").forEach(b =>
      b.addEventListener("click", () => { document.getElementById(b.dataset.closeAft).hidden = true; }));
    document.getElementById("aftNewCategory").addEventListener("change", () => fillTaxonomy("aftNewSubcategory", "asset-subcategories", val("aftNewCategory"), "aftNewType"));
    document.getElementById("aftNewSubcategory").addEventListener("change", () => {
      fillTaxonomy("aftNewType", "asset-types", val("aftNewSubcategory"));
    });
    document.getElementById("aftNewType").addEventListener("change", () => {
      const sel = document.getElementById("aftNewType");
      const name = document.getElementById("aftNewName");
      if (sel.value && !name.value.trim()) name.value = `${sel.options[sel.selectedIndex].text} Registration Form`;
    });
    document.getElementById("aftNewForm").addEventListener("submit", createTemplate);
    document.getElementById("aftFieldForm").addEventListener("submit", saveField);
    document.getElementById("aftSectionForm").addEventListener("submit", saveSection);
    document.getElementById("aftLibGroup").addEventListener("change", e => { state.libGroup = e.target.value; libPager?.reset(true); refreshLibrary(); });
    document.getElementById("aftLibSearch").addEventListener("input", e => {
      clearTimeout(libTimer);
      libTimer = setTimeout(() => { state.libSearch = e.target.value.trim(); libPager?.reset(true); refreshLibrary(); }, 300);
    });
    document.getElementById("aftLibAll").addEventListener("change", e => {
      document.querySelectorAll("#aftLibBody input[type=checkbox]:not(:disabled)").forEach(c => { c.checked = e.target.checked; });
    });
    document.getElementById("aftLibAdd").addEventListener("click", addSelectedFields);
    document.getElementById("aftRuleForm").addEventListener("submit", saveRule);
    document.getElementById("aftRuleAddCond").addEventListener("click", () => {
      const groups = [...document.querySelectorAll("#aftRuleConditions .aft-cond")].map(r => Number(r.dataset.group) || 1);
      addConditionRow({ groupNo: groups.length ? Math.max(...groups) : 1 });
    });
    document.getElementById("aftRuleAddGroup").addEventListener("click", () => {
      const groups = [...document.querySelectorAll("#aftRuleConditions .aft-cond")].map(r => Number(r.dataset.group) || 1);
      addConditionRow({ groupNo: (groups.length ? Math.max(...groups) : 0) + 1 });
    });
    document.getElementById("aftRuleConditions").addEventListener("click", ev => {
      const rm = ev.target.closest("[data-aft-cond-remove]");
      if (rm) rm.closest(".aft-cond").remove();
    });
    document.getElementById("aftRuleConditions").addEventListener("change", ev => {
      if (ev.target.matches("[data-cond-source]")) refreshValueInput(ev.target.closest(".aft-cond"));
    });
  }

  function closeAllModals() {
    ["aftNewModal", "aftLibModal", "aftFieldModal", "aftSectionModal", "aftRuleModal"].forEach(id => { document.getElementById(id).hidden = true; });
  }

  async function openNewModal() {
    if (!state.organizationId) { await notify("Select an organization first.", "warning"); return; }
    if (!state.taxonomy.length) {
      const res = await api("GET", "/taxonomy");
      state.taxonomy = res.ok ? (res.data.data || []) : [];
    }
    await ensureEmployees();
    fillTaxonomy("aftNewCategory", "asset-categories", null, "aftNewSubcategory");
    setVal("aftNewName", "");
    renderEmployeeOptions("aftNewOwner", "-- me --", null);
    hideMessage("aftNewMessage");
    document.getElementById("aftNewModal").hidden = false;
  }

  function fillTaxonomy(selectId, entity, parent, clearId) {
    const sel = document.getElementById(selectId);
    const rows = state.taxonomy.filter(t => t.entityType === entity && (parent == null || String(t.parent) === String(parent)));
    sel.innerHTML = `<option value="">-- select --</option>` + rows.map(r => `<option value="${esc(r.value)}">${esc(r.label)}</option>`).join("");
    if (clearId) {
      document.getElementById(clearId).innerHTML = `<option value="">-- select --</option>`;
      if (clearId === "aftNewSubcategory") document.getElementById("aftNewType").innerHTML = `<option value="">-- select --</option>`;
    }
  }

  async function createTemplate(ev) {
    ev.preventDefault();
    const assetTypeId = Number(val("aftNewType"));
    if (!assetTypeId) { showMessage("aftNewMessage", "Choose the asset type.", "error"); return; }
    const res = await api("POST", "/templates", {
      organizationId: state.organizationId, assetTypeId,
      templateName: val("aftNewName"), templateOwnerEmployeeId: Number(val("aftNewOwner")) || null
    });
    if (!res.ok) { showMessage("aftNewMessage", res.error, "error"); return; }
    document.getElementById("aftNewModal").hidden = true;
    await openDesigner(res.data.id);
    showMessage("aftDesignMessage", "Draft created with the baseline fields. Add sections and fields, then submit for testing.", "success");
  }

  // Field library -- placeable dictionary fields, paged server-side.
  async function openLibrary() {
    if (!editable()) return;
    const groupSel = document.getElementById("aftLibGroup");
    if (groupSel.options.length <= 1) {
      const res = await api("GET", "/field-groups");
      (res.ok ? res.data.data.groups : []).forEach(g => {
        const o = document.createElement("option"); o.value = g.groupCode; o.textContent = g.groupName; groupSel.appendChild(o);
      });
    }
    const secSel = document.getElementById("aftLibSection");
    secSel.innerHTML = state.detail.sections.filter(s => !s.isSystem && s.isActive)
      .map(s => `<option value="${s.sectionId}">${esc(s.sectionLabel)}</option>`).join("");
    document.getElementById("aftLibAll").checked = false;
    hideMessage("aftLibMessage");
    document.getElementById("aftLibModal").hidden = false;
    libPager?.reset(true);
    await refreshLibrary();
  }

  async function refreshLibrary() {
    const body = document.getElementById("aftLibBody");
    body.innerHTML = `<tr><td colspan="5" class="pm-empty">Loading...</td></tr>`;
    const qs = new URLSearchParams({ placeableOnly: "true", pageNumber: libPager ? libPager.page() : 1, pageSize: libPager ? libPager.size() : 25 });
    if (state.libGroup) qs.set("groupCode", state.libGroup);
    if (state.libSearch) qs.set("search", state.libSearch);
    const res = await api("GET", `/field-definitions?${qs}`);
    if (!res.ok) { libPager?.clear(); body.innerHTML = `<tr><td colspan="5" class="pm-empty">${esc(res.error)}</td></tr>`; return; }
    const rows = res.data.data.rows || [];
    state.libRows = rows;
    libPager?.setTotal(res.data.data.totalRows, rows.length);
    const onForm = new Set(state.detail.fields.map(f => f.fieldDefinitionId));
    body.innerHTML = rows.map(r => `
      <tr>
        <td><input type="checkbox" value="${r.fieldDefinitionId}" ${onForm.has(r.fieldDefinitionId) ? "disabled checked title=\"Already on the form\"" : ""} aria-label="Select ${esc(r.displayLabel)}" /></td>
        <td>${esc(r.displayLabel)}${r.isSystemMandatory ? ` <span class="pm-badge aft-baseline">Baseline</span>` : ""}</td>
        <td>${esc(r.groupName)}</td>
        <td>${esc(r.dataTypeName)}</td>
        <td>${esc(r.validationRule || "")}</td>
      </tr>`).join("") || `<tr><td colspan="5" class="pm-empty">No fields match.</td></tr>`;
  }

  // Adds one field per call and reports every outcome individually --
  // a refusal for one field never hides the others' success.
  async function addSelectedFields() {
    const sectionId = Number(val("aftLibSection"));
    if (!sectionId) { showMessage("aftLibMessage", "Choose the section to add the fields into.", "error"); return; }
    const picked = [...document.querySelectorAll("#aftLibBody input[type=checkbox]:checked:not(:disabled)")].map(c => Number(c.value));
    if (!picked.length) { showMessage("aftLibMessage", "Select at least one field.", "error"); return; }
    const templateId = state.detail.header.templateId;
    const ok = [], failed = [];
    for (const id of picked) {
      const def = state.libRows.find(r => r.fieldDefinitionId === id);
      const res = await api("POST", `/templates/${templateId}/fields`, {
        organizationId: state.organizationId, fieldDefinitionId: id, sectionId,
        isVisible: true, isMandatory: !!def?.isSystemMandatory, isReadOnly: false, hiddenValueBehavior: "RETAIN"
      });
      (res.ok ? ok : failed).push(`${def?.displayLabel || id}${res.ok ? "" : ": " + res.error}`);
    }
    await reloadDesigner();
    await refreshLibrary();
    const msg = `${ok.length} field(s) added.` + (failed.length ? ` ${failed.length} not added -- ${failed.join("; ")}` : "");
    showMessage("aftLibMessage", msg, failed.length ? "error" : "success");
  }

  function openFieldModal(fieldDefinitionId) {
    const f = state.detail.fields.find(x => x.fieldDefinitionId === fieldDefinitionId);
    if (!f) return;
    const canEdit = editable();
    document.getElementById("aftFieldTitle").textContent = f.displayLabel;
    document.getElementById("aftFieldNote").textContent =
      `${f.groupName} -- ${f.dataTypeCode}${f.lookupSource ? " -- source " + f.lookupSource : ""}` +
      (f.isSystemMandatory ? " -- Baseline field: it stays visible and mandatory." : "");
    document.getElementById("aftFldSection").innerHTML = state.detail.sections.filter(s => !s.isSystem && s.isActive)
      .map(s => `<option value="${s.sectionId}" ${s.sectionId === f.sectionId ? "selected" : ""}>${esc(s.sectionLabel)}</option>`).join("");
    setVal("aftFldOrder", f.displayOrder);
    check("aftFldVisible", f.isVisible); check("aftFldMandatory", f.isMandatory); check("aftFldReadOnly", f.isReadOnly);
    check("aftFldEvidence", f.evidenceRequired); check("aftFldImport", f.includeInImportExport); check("aftFldSearchable", f.isSearchable);
    setVal("aftFldHidden", f.hiddenValueBehavior || "RETAIN");
    setVal("aftFldSensitivity", f.sensitivityOverride || "");
    setVal("aftFldDefault", f.defaultValue || ""); setVal("aftFldHelp", f.helpText || ""); setVal("aftFldPlaceholder", f.placeholderText || "");
    document.querySelectorAll("#aftFieldForm input, #aftFieldForm select").forEach(el => { el.disabled = !canEdit; });
    if (f.isSystemMandatory) { document.getElementById("aftFldVisible").disabled = true; document.getElementById("aftFldMandatory").disabled = true; }
    document.getElementById("aftFieldForm").dataset.fieldId = String(fieldDefinitionId);
    hideMessage("aftFieldMessage");
    document.getElementById("aftFieldModal").hidden = false;
  }

  async function saveField(ev) {
    ev.preventDefault();
    if (!editable()) return;
    const id = Number(document.getElementById("aftFieldForm").dataset.fieldId);
    const res = await api("POST", `/templates/${state.detail.header.templateId}/fields`, {
      organizationId: state.organizationId, fieldDefinitionId: id, sectionId: Number(val("aftFldSection")),
      displayOrder: val("aftFldOrder") === "" ? null : Number(val("aftFldOrder")),
      isVisible: checked("aftFldVisible"), isMandatory: checked("aftFldMandatory"), isReadOnly: checked("aftFldReadOnly"),
      evidenceRequired: checked("aftFldEvidence"), includeInImportExport: checked("aftFldImport"), isSearchable: checked("aftFldSearchable"),
      hiddenValueBehavior: val("aftFldHidden"), sensitivityOverride: val("aftFldSensitivity") || null,
      defaultValue: val("aftFldDefault") || null, helpText: val("aftFldHelp") || null, placeholderText: val("aftFldPlaceholder") || null
    });
    if (!res.ok) { showMessage("aftFieldMessage", res.error, "error"); return; }
    document.getElementById("aftFieldModal").hidden = true;
    await reloadDesigner("Field saved.");
  }

  function openSectionModal(sectionId) {
    if (!editable()) return;
    const s = sectionId ? state.detail.sections.find(x => x.sectionId === sectionId) : null;
    document.getElementById("aftSectionTitle").textContent = s ? `Edit section: ${s.sectionLabel}` : "Add section";
    setVal("aftSecLabel", s?.sectionLabel || ""); setVal("aftSecTab", s?.tabLabel || "");
    setVal("aftSecCols", String(s?.layoutColumns || 2)); setVal("aftSecOrder", s?.displayOrder ?? "");
    check("aftSecActive", s ? s.isActive : true);
    document.getElementById("aftSectionForm").dataset.sectionId = s ? String(s.sectionId) : "";
    hideMessage("aftSectionMessage");
    document.getElementById("aftSectionModal").hidden = false;
  }

  async function saveSection(ev) {
    ev.preventDefault();
    const sid = Number(document.getElementById("aftSectionForm").dataset.sectionId) || null;
    const res = await api("POST", `/templates/${state.detail.header.templateId}/sections`, {
      organizationId: state.organizationId, sectionId: sid, sectionLabel: val("aftSecLabel"), tabLabel: val("aftSecTab") || null,
      layoutColumns: Number(val("aftSecCols")) || 2, displayOrder: val("aftSecOrder") === "" ? null : Number(val("aftSecOrder")),
      isActive: checked("aftSecActive")
    });
    if (!res.ok) { showMessage("aftSectionMessage", res.error, "error"); return; }
    document.getElementById("aftSectionModal").hidden = true;
    await reloadDesigner("Section saved.");
  }

  // ------------------------------------------------------------------ rules + preview (421)
  const OPERATORS = [
    ["EQ", "equals"], ["NEQ", "does not equal"], ["IN", "is one of"], ["NOT_IN", "is not one of"],
    ["EMPTY", "is empty"], ["NOT_EMPTY", "is not empty"],
    ["GT", "greater than"], ["GTE", "at least"], ["LT", "less than"], ["LTE", "at most"],
    ["DATE_BEFORE_TODAY", "date before today"], ["DATE_AFTER_TODAY", "date after today"], ["DATE_WITHIN_DAYS", "date within N days"]
  ];
  const NO_VALUE_OPS = new Set(["EMPTY", "NOT_EMPTY", "DATE_BEFORE_TODAY", "DATE_AFTER_TODAY"]);
  const ACTION_LABEL = { SHOW: "Show", REQUIRE: "Require", SHOW_AND_REQUIRE: "Show and require" };

  function optionsFor(fieldDefinitionId) {
    return (state.detail.options || []).filter(o => o.fieldDefinitionId === fieldDefinitionId);
  }
  function optionLabel(fieldDefinitionId, value) {
    const o = optionsFor(fieldDefinitionId).find(x => x.optionValue === value);
    return o ? o.optionLabel : value;
  }

  function ruleSummary(ruleId) {
    const conds = (state.detail.conditions || []).filter(c => c.ruleId === ruleId);
    const groups = [...new Set(conds.map(c => c.groupNo))];
    return groups.map(g => conds.filter(c => c.groupNo === g).map(c => {
      const op = (OPERATORS.find(o => o[0] === c.operatorCode) || [c.operatorCode, c.operatorCode])[1];
      const v = NO_VALUE_OPS.has(c.operatorCode) ? "" : " " + String(c.compareValue || "").split("|")
        .map(x => optionLabel(c.sourceFieldDefinitionId, x)).join(" / ");
      return `${c.sourceLabel} ${op}${v}`;
    }).join(" AND ")).join("  OR  ");
  }

  function renderRules() {
    const body = document.getElementById("aftRuleBody");
    const rules = state.detail.rules || [];
    body.innerHTML = rules.map(r => `
      <tr>
        <td>${esc(r.ruleName)}</td>
        <td>${esc(ruleSummary(r.ruleId))}</td>
        <td>${esc(ACTION_LABEL[r.actionCode] || r.actionCode)} "${esc(r.targetLabel)}"</td>
        <td>${r.isActive ? "Active" : "Inactive"}</td>
        <td class="aft-row-actions">
          <button type="button" class="pm-button icon" data-aft-rule-edit="${r.ruleId}" title="${editable() ? "Edit" : "View"}"><i class="fa-solid ${editable() ? "fa-pen" : "fa-eye"}"></i></button>
          ${editable() ? `<button type="button" class="pm-button icon" data-aft-rule-remove="${r.ruleId}" title="Remove"><i class="fa-solid fa-xmark"></i></button>` : ""}
        </td>
      </tr>`).join("") || `<tr><td colspan="5" class="pm-empty">No conditional rules. Fields follow their Visible and Mandatory settings.</td></tr>`;
  }

  function fieldSelectHtml(selected, excludeBaseline, cssAttr) {
    const fields = state.detail.fields.filter(f => !(excludeBaseline && f.isSystemMandatory));
    return `<select ${cssAttr || ""}><option value="">-- field --</option>` + fields.map(f =>
      `<option value="${f.fieldDefinitionId}" ${f.fieldDefinitionId === selected ? "selected" : ""}>${esc(f.displayLabel)}</option>`).join("") + `</select>`;
  }

  function openRuleModal(ruleId) {
    const r = ruleId ? (state.detail.rules || []).find(x => x.ruleId === ruleId) : null;
    const canEdit = editable();
    document.getElementById("aftRuleTitle").textContent = r ? (canEdit ? "Edit rule" : "Rule") : "Add rule";
    setVal("aftRuleName", r?.ruleName || "");
    setVal("aftRuleAction", r?.actionCode || "SHOW_AND_REQUIRE");
    document.getElementById("aftRuleTarget").outerHTML = fieldSelectHtml(r?.targetFieldDefinitionId, true, 'id="aftRuleTarget"');
    check("aftRuleActive", r ? r.isActive : true);
    const host = document.getElementById("aftRuleConditions");
    host.innerHTML = "";
    const conds = r ? (state.detail.conditions || []).filter(c => c.ruleId === r.ruleId) : [];
    if (conds.length) conds.forEach(addConditionRow); else addConditionRow({ groupNo: 1 });
    document.querySelectorAll("#aftRuleForm input, #aftRuleForm select, #aftRuleForm button[type=submit], #aftRuleForm [data-aft-cond-remove], #aftRuleAddCond, #aftRuleAddGroup")
      .forEach(el => { el.disabled = !canEdit; });
    document.getElementById("aftRuleForm").dataset.ruleId = r ? String(r.ruleId) : "";
    hideMessage("aftRuleMessage");
    document.getElementById("aftRuleModal").hidden = false;
  }

  function addConditionRow(c) {
    const row = document.createElement("div");
    row.className = "aft-cond";
    row.dataset.group = String(c.groupNo || 1);
    row.innerHTML = `
      <span class="aft-cond-group">Group ${esc(c.groupNo || 1)}</span>
      ${fieldSelectHtml(c.sourceFieldDefinitionId, false, "data-cond-source")}
      <select data-cond-op>${OPERATORS.map(o => `<option value="${o[0]}" ${o[0] === (c.operatorCode || "EQ") ? "selected" : ""}>${esc(o[1])}</option>`).join("")}</select>
      <span data-cond-value-host></span>
      <button type="button" class="pm-button icon" data-aft-cond-remove title="Remove condition"><i class="fa-solid fa-xmark"></i></button>`;
    document.getElementById("aftRuleConditions").appendChild(row);
    refreshValueInput(row, c.compareValue);
  }

  // Option-backed sources get a picker (multi-select for IN / NOT_IN is
  // typed as a '|' list); everything else is free text.
  function refreshValueInput(row, value) {
    const src = Number(row.querySelector("[data-cond-source]").value);
    const host = row.querySelector("[data-cond-value-host]");
    const current = value ?? host.querySelector("input,select")?.value ?? "";
    const opts = src ? optionsFor(src) : [];
    host.innerHTML = opts.length
      ? `<input type="text" data-cond-value list="aftOpt${src}" placeholder="value, or A|B for 'one of'" />
         <datalist id="aftOpt${src}">${opts.map(o => `<option value="${esc(o.optionValue)}">${esc(o.optionLabel)}</option>`).join("")}</datalist>`
      : `<input type="text" data-cond-value placeholder="value (blank for empty / date checks)" />`;
    host.querySelector("[data-cond-value]").value = current;
  }

  async function saveRule(ev) {
    ev.preventDefault();
    if (!editable()) return;
    const conditions = [...document.querySelectorAll("#aftRuleConditions .aft-cond")].map(r => ({
      groupNo: Number(r.dataset.group) || 1,
      sourceFieldDefinitionId: Number(r.querySelector("[data-cond-source]").value) || 0,
      operatorCode: r.querySelector("[data-cond-op]").value,
      compareValue: r.querySelector("[data-cond-value]").value.trim() || null
    }));
    const ruleId = Number(document.getElementById("aftRuleForm").dataset.ruleId) || null;
    const res = await api("POST", `/templates/${state.detail.header.templateId}/rules`, {
      organizationId: state.organizationId, ruleId,
      ruleName: val("aftRuleName") || null, actionCode: val("aftRuleAction"),
      targetFieldDefinitionId: Number(val("aftRuleTarget")) || 0,
      isActive: checked("aftRuleActive"), conditions
    });
    if (!res.ok) { showMessage("aftRuleMessage", res.error, "error"); return; }
    document.getElementById("aftRuleModal").hidden = true;
    await reloadDesigner("Rule saved.");
  }

  async function removeRule(ruleId) {
    const r = (state.detail.rules || []).find(x => x.ruleId === ruleId);
    if (!r || !await window.gracUi.confirm(`Remove the rule "${r.ruleName}"?`)) return;
    const res = await api("POST", `/templates/${state.detail.header.templateId}/rules/remove`, { organizationId: state.organizationId, ruleId });
    if (!res.ok) { showMessage("aftDesignMessage", res.error, "error"); return; }
    await reloadDesigner("Rule removed.");
  }

  // Inputs only for fields that drive at least one rule.
  function renderPreviewInputs() {
    const host = document.getElementById("aftPreviewInputs");
    const ids = [...new Set((state.detail.conditions || []).map(c => c.sourceFieldDefinitionId))];
    const fields = state.detail.fields.filter(f => ids.includes(f.fieldDefinitionId));
    if (!fields.length) { host.innerHTML = `<p class="aft-note full">No field drives a rule yet, so every field follows its static settings.</p>`; return; }
    host.innerHTML = fields.map(f => {
      const opts = optionsFor(f.fieldDefinitionId);
      const input = opts.length
        ? `<select data-preview-key="${esc(f.fieldKey)}"><option value="">-- not set --</option>${opts.map(o => `<option value="${esc(o.optionValue)}">${esc(o.optionLabel)}</option>`).join("")}</select>`
        : `<input type="${f.dataTypeCode === "DATE" ? "date" : "text"}" data-preview-key="${esc(f.fieldKey)}" />`;
      return `<label><span>${esc(f.displayLabel)}</span>${input}</label>`;
    }).join("");
  }

  async function runPreview() {
    const values = {};
    document.querySelectorAll("#aftPreviewInputs [data-preview-key]").forEach(el => {
      if (el.value !== "") values[el.dataset.previewKey] = el.value;
    });
    const body = document.getElementById("aftPreviewBody");
    body.innerHTML = `<tr><td colspan="5" class="pm-empty">Evaluating...</td></tr>`;
    const res = await api("POST", `/templates/${state.detail.header.templateId}/evaluate`, { organizationId: state.organizationId, values });
    if (!res.ok) { body.innerHTML = `<tr><td colspan="5" class="pm-empty">${esc(res.error)}</td></tr>`; return; }
    const sectionName = id => (state.detail.sections.find(s => s.sectionId === id) || {}).sectionLabel || "";
    body.innerHTML = (res.data.data.fields || []).map(f => `
      <tr>
        <td>${esc(f.displayLabel)}</td>
        <td>${esc(sectionName(f.sectionId))}</td>
        <td>${f.isVisible ? "Yes" : "No"}${f.visibilityByRule ? " (by rule)" : ""}</td>
        <td>${f.isMandatory ? "Yes" : "No"}</td>
        <td>${esc(f.rulesFired || "")}</td>
      </tr>`).join("") || `<tr><td colspan="5" class="pm-empty">No fields.</td></tr>`;
  }

  // ------------------------------------------------------------------ helpers
  async function ensureEmployees() {
    if (state.employees.length || !state.organizationId) return;
    try {
      const r = await fetch(U(`/practice/api/document-uploads/lookups/employees?organizationId=${state.organizationId}`), { credentials: "same-origin" });
      state.employees = r.ok ? (await r.json()) || [] : [];
    } catch (_) { state.employees = []; }
  }

  function renderEmployeeOptions(selectId, placeholder, selected) {
    const sel = document.getElementById(selectId);
    sel.innerHTML = `<option value="">${esc(placeholder)}</option>` + state.employees.map(e =>
      `<option value="${e.employeeId}" ${String(e.employeeId) === String(selected ?? "") ? "selected" : ""}>${esc(e.employeeName)}${e.employeeCode ? " (" + esc(e.employeeCode) + ")" : ""}</option>`).join("");
  }

  function openMenu(trigger, items) {
    closeMenu();
    openMenuTrigger = trigger;
    trigger.setAttribute("aria-expanded", "true");
    openMenuEl = document.createElement("div");
    openMenuEl.className = "pm-action-menu";
    openMenuEl.setAttribute("role", "menu");
    items.forEach(it => {
      const b = document.createElement("button");
      b.type = "button"; b.setAttribute("role", "menuitem");
      b.innerHTML = `<i class="fa-solid ${esc(it.icon)}" aria-hidden="true"></i> ${esc(it.label)}`;
      b.addEventListener("click", ev => { ev.preventDefault(); ev.stopPropagation(); closeMenu(); it.action(); });
      openMenuEl.appendChild(b);
    });
    document.body.appendChild(openMenuEl);   // portalled: never inside .pm-table-wrap
    const r = trigger.getBoundingClientRect(), mr = openMenuEl.getBoundingClientRect();
    let top = r.bottom + 6, left = r.right - mr.width;
    if (top + mr.height > window.innerHeight - 8) top = Math.max(8, r.top - mr.height - 6);
    if (left < 8) left = 8;
    openMenuEl.style.top = top + "px"; openMenuEl.style.left = left + "px";
  }

  function closeMenu() {
    if (openMenuEl) openMenuEl.remove();
    if (openMenuTrigger) openMenuTrigger.setAttribute("aria-expanded", "false");
    openMenuEl = null; openMenuTrigger = null;
  }

  async function api(method, path, body) {
    try {
      const r = await fetch(U(base + path), {
        method, credentials: "same-origin",
        headers: body ? { "Content-Type": "application/json" } : undefined,
        body: body ? JSON.stringify(body) : undefined
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok || data.success === false)
        return { ok: false, status: r.status, errorNumber: data.errorNumber, error: data.error || `Request failed (HTTP ${r.status}).` };
      return { ok: true, status: r.status, data };
    } catch (err) { return { ok: false, status: 0, error: err.message }; }
  }

  function showMessage(id, text, kind) {
    const el = document.getElementById(id);
    el.textContent = text || "";
    el.classList.toggle("success", kind === "success");
    el.classList.toggle("info", kind === "info");
    el.hidden = !text;
  }
  function hideMessage(id) { const el = document.getElementById(id); el.hidden = true; el.textContent = ""; }
  async function notify(message, type) {
    if (window.gracUi) await window.gracUi.alert(message, { type: type || "info" });
    else window.alert(message);
  }

  function chip(code) {
    const s = STATUS[code] || { label: code || "", cls: "aft-st-draft" };
    return `<span class="aft-status ${s.cls}">${esc(s.label)}</span>`;
  }
  function yn(v) { return v ? "Yes" : "No"; }
  function val(id) { return (document.getElementById(id).value || "").trim(); }
  function setVal(id, v) { document.getElementById(id).value = v ?? ""; }
  function check(id, v) { document.getElementById(id).checked = !!v; }
  function checked(id) { return document.getElementById(id).checked; }
  function isoDate(v) { return v ? String(v).substring(0, 10) : ""; }
  function fmtDate(v) { return !v ? "" : (window.gracFormatDisplayDate ? window.gracFormatDisplayDate(v) : isoDate(v)); }
  function dateRange(from, to) { return !from ? "--" : `${fmtDate(from)}${to ? " to " + fmtDate(to) : " onwards"}`; }
  function dateTime(v) { if (!v) return ""; const d = new Date(v); return isNaN(d) ? String(v) : d.toLocaleString(); }
  function esc(v) {
    return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }
})();
