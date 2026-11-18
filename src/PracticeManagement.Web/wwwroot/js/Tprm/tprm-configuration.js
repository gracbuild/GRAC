// =====================================================================
// TPRM Configuration (migrations 486-490). Loaded by tprm-configuration.cshtml.
// Backend: practice/api/tprm/config/... (TprmController -> sp_tprm_* of 486)
//   reference   GET config/reference?organizationId&listCode
//               POST config/reference/values | /overrides
//   library     GET config/library?organizationId&libraryCode
//               POST config/library/items | /overrides
//   templates   GET config/templates, config/templates/versions/{id},
//               config/templates/compare?versionA&versionB
//               POST config/templates (create), .../{id}/adopt, .../{id}/new-version,
//               .../{id}/retire, .../versions/{id}/header | /risk-items |
//               /questionnaire-items | /items/remove | /activate
//   rules       GET config/rules; POST config/rules/approval | /review
//   delegations POST config/delegations
//   fields      GET config/custom-fields; POST config/custom-fields
// Scope: the organization picked, or -- for the platform administrator --
// the GRAC baseline (organizationId omitted). Origin per row: GRAC,
// GRAC_OVERRIDDEN (the organization changed it), ORGANIZATION (its own).
// =====================================================================
(() => {
  "use strict";

  const T = window.gracTprm;
  const root = document.getElementById("cfRoot");
  if (!root || !T) return;
  const { F, esc, date, empty, show, hide, api, qs, yes } = T;
  const CAN_CHANGE = root.dataset.canChange === "1";
  const CAN_APPROVE = root.dataset.canApprove === "1";
  const ORIGIN = { GRAC: "GRAC", GRAC_OVERRIDDEN: "GRAC, changed", ORGANIZATION: "Organization" };
  const LIBRARIES = [{ value: "SAFEGUARD", label: "Safeguards" }, { value: "EVIDENCE_REQUIREMENT", label: "Evidence requirements" }, { value: "TREATMENT_ACTION", label: "Treatment actions" }];
  const ENTITIES = [{ value: "THIRD_PARTY", label: "Vendor" }, { value: "ENGAGEMENT", label: "Engagement" }, { value: "FINDING", label: "Finding" }, { value: "REVIEW", label: "Review" }];
  const DATA_TYPES = ["TEXT", "NUMBER", "DATE", "BOOLEAN", "SINGLE_SELECT", "MULTI_SELECT", "REFERENCE"].map(x => ({ value: x, label: x }));
  const PREFILL = ["SERVICE_CRITICALITY", "DATA_EXPOSURE", "ACCESS", "FOURTH_PARTY_COUNT", "IS_EXISTING", "SERVICE_MODEL", "LOCATION_COUNT"].map(x => ({ value: x, label: x }));
  const RESPONSE_TYPES = ["YES_NO", "SINGLE", "MULTI", "TEXT", "NUMBER", "DATE"].map(x => ({ value: x, label: x }));
  const state = { org: null, baseline: false, lk: null, tab: "LISTS", listCode: null, libraryCode: "SAFEGUARD", entity: "THIRD_PARTY",
                  data: {}, version: null };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    bind();
    state.org = await T.orgs("cfOrg");
    await changeScope();
  }
  function bind() {
    document.getElementById("cfOrg").addEventListener("change", e => { state.org = Number(e.target.value) || null; changeScope(); });
    document.getElementById("cfScope")?.addEventListener("change", changeScope);
    document.querySelectorAll("[data-cf-tab]").forEach(b => b.addEventListener("click", () => selectTab(b.dataset.cfTab)));
    document.querySelectorAll("[data-close-cf]").forEach(b => b.addEventListener("click", () => { document.getElementById(b.dataset.closeCf).hidden = true; }));
    root.addEventListener("click", ev => { const b = ev.target.closest("[data-act]"); if (b) act(b.dataset.act, b.dataset); });
    root.addEventListener("change", ev => { const s = ev.target.closest("[data-pick]"); if (s) { state[s.dataset.pick] = s.value; render(); } });
    document.getElementById("cfVersionModal").addEventListener("click", ev => { const b = ev.target.closest("[data-act]"); if (b) act(b.dataset.act, b.dataset); });
  }

  async function changeScope() {
    state.baseline = document.getElementById("cfScope")?.value === "BASELINE";
    document.getElementById("cfOrg").disabled = state.baseline;
    document.getElementById("cfScopeNote").textContent = state.baseline
      ? "GRAC baseline: changes reach every organization that has not changed the item. Baseline content is illustrative and is not a regulatory requirement unless its source says so."
      : "Organization configuration: GRAC values can be relabelled, reordered or hidden for this organization; its own values, items, rules and templates are added beside them. The baseline itself is never changed from here.";
    hide("cfMessage");
    state.lk = state.org ? await T.lookups(state.org, true) : null;
    await render();
  }
  const scopeQs = extra => qs({ organizationId: state.baseline ? null : state.org, ...(extra || {}) });
  const scopeBody = extra => ({ organizationId: state.baseline ? null : state.org, ...(extra || {}) });
  const ready = () => state.baseline || state.org;

  function selectTab(name) {
    state.tab = name;
    document.querySelectorAll("[data-cf-tab]").forEach(x => { const on = x.dataset.cfTab === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    document.querySelectorAll("[data-cf-panel]").forEach(p => { p.hidden = p.dataset.cfPanel !== name; });
    render();
  }
  async function render() {
    const panel = document.querySelector(`[data-cf-panel="${state.tab}"]`);
    if (!ready()) { panel.innerHTML = `<p class="pm-empty">Select an organization.</p>`; return; }
    if (state.tab === "DELEGATIONS" && state.baseline) { panel.innerHTML = `<p class="tprm-note">Delegations belong to an organization. Switch to the organization configuration.</p>`; return; }
    panel.innerHTML = `<p class="pm-empty">Loading...</p>`;
    if (state.tab === "LISTS") await renderLists(panel);
    else if (state.tab === "LIBRARY") await renderLibrary(panel);
    else if (state.tab === "TEMPLATES") await renderTemplates(panel);
    else if (state.tab === "RULES" || state.tab === "DELEGATIONS") await renderRules(panel);
    else await renderFields(panel);
  }
  const originBadge = o => `<span class="pm-badge cf-origin-${esc(o)}">${esc(ORIGIN[o] || o)}</span>`;
  const btn = (action, icon, text, data, kind) => `<button type="button" class="pm-button small${kind ? " " + kind : ""}" data-act="${esc(action)}"${
    Object.entries(data || {}).map(([k, v]) => ` data-${k}="${esc(v)}"`).join("")}><i class="fa-solid ${esc(icon)}" aria-hidden="true"></i>${text ? " " + esc(text) : ""}</button>`;
  const picker = (key, options, value) => `<select data-pick="${esc(key)}">${options.map(o => `<option value="${esc(o.value)}"${o.value === value ? " selected" : ""}>${esc(o.label)}</option>`).join("")}</select>`;

  // ------------------------------------------------------------------ reference lists
  async function renderLists(panel) {
    const r = await api("GET", `/config/reference?${scopeQs({ listCode: state.listCode })}`);
    if (!r.ok) { panel.innerHTML = `<p class="pm-message">${esc(r.error)}</p>`; return; }
    const lists = r.data.lists || [];
    if (!state.listCode && lists.length) { state.listCode = F(lists[0], "listCode"); return renderLists(panel); }
    const list = lists.find(l => F(l, "listCode") === state.listCode) || {};
    const values = (r.data.values || []).filter(v => F(v, "listCode") === state.listCode);
    state.data.lists = { lists, list, values };
    const meaningful = F(list, "scopeRule") === "MEANING";
    panel.innerHTML = `
      <div class="pm-toolbar">${picker("listCode", lists.map(l => ({ value: F(l, "listCode"), label: F(l, "listName") })), state.listCode)}
        ${CAN_CHANGE ? btn("value-add", "fa-plus", "Add value") : ""}</div>
      <p class="tprm-note">${esc(F(list, "description") || "")}${meaningful ? ` Each value maps to one of: ${esc(F(list, "allowedMeanings"))} -- the workflow uses the meaning, the organization chooses the label.` : ""}</p>
      <div class="pm-table-wrap"><table><thead><tr><th>Code</th><th>Label</th>${meaningful ? "<th>Meaning</th>" : ""}<th>Rank</th><th>Colour</th><th>Mandatory</th><th>Order</th><th>Origin</th><th>Status</th><th></th></tr></thead>
      <tbody>${values.map(v => `<tr class="${yes(F(v, "isHidden")) || F(v, "status") !== "Active" ? "cf-hidden-row" : ""}">
        <td>${esc(F(v, "valueCode"))}</td><td>${esc(F(v, "label"))}${F(v, "description") ? `<div class="tprm-muted">${esc(F(v, "description"))}</div>` : ""}</td>
        ${meaningful ? `<td>${esc(F(v, "meaningCode") || "")}</td>` : ""}
        <td>${esc(F(v, "rankNo") ?? "")}</td><td>${F(v, "colorHex") ? `<span class="cf-swatch" style="background:${esc(F(v, "colorHex"))}"></span>` : ""}</td>
        <td>${yes(F(v, "isMandatory")) ? "Yes" : ""}</td><td>${esc(F(v, "displayOrder"))}</td><td>${originBadge(F(v, "origin"))}</td>
        <td>${yes(F(v, "isHidden")) ? "Hidden" : esc(F(v, "status"))}</td>
        <td>${CAN_CHANGE ? btn("value-edit", "fa-pen", "", { id: F(v, "valueId"), base: F(v, "baselineValueId") ?? "", origin: F(v, "origin") }) : ""}</td></tr>`).join("") || empty(10, "No values.")}</tbody></table></div>`;
  }
  async function editValue(d) {
    const { list, values } = state.data.lists;
    const v = d ? values.find(x => String(F(x, "valueId")) === String(d.id) && F(x, "origin") === d.origin) : null;
    const meanings = String(F(list, "allowedMeanings") || "").split(",").filter(Boolean).map(m => ({ value: m, label: m }));
    const overriding = v && !state.baseline && F(v, "origin") !== "ORGANIZATION";
    const fields = [
      ...(overriding ? [] : [{ name: "valueCode", label: "Code", required: true, maxLength: 60, value: v ? F(v, "valueCode") : "", readonly: !!v }]),
      { name: "label", label: "Label", required: true, maxLength: 200, value: v ? F(v, "label") : "" },
      { name: "description", label: "Description", type: "textarea", rows: 2, maxLength: 1000, value: v ? F(v, "description") : "" },
      ...(meanings.length && !overriding ? [{ name: "meaningCode", label: "Meaning", type: "select", options: meanings, value: v ? F(v, "meaningCode") : "", required: true }] : []),
      { name: "rankNo", label: "Rank (higher = more severe / more)", type: "number", value: v ? F(v, "rankNo") : "" },
      { name: "colorHex", label: "Colour (#RRGGBB)", maxLength: 9, value: v ? F(v, "colorHex") : "" },
      { name: "displayOrder", label: "Order", type: "number", value: v ? F(v, "displayOrder") : 100 },
      { name: "isMandatory", label: "Mandatory (checks lists)", type: "checkbox", value: v ? F(v, "isMandatory") : false },
      ...(overriding ? [{ name: "isHidden", label: "Hide for this organization", type: "checkbox", value: F(v, "isHidden") },
                        { name: "reset", label: "Reset to the GRAC value", type: "checkbox" }]
                     : [{ name: "status", label: "Status", type: "select", blank: false, value: v ? F(v, "status") : "Active", options: [{ value: "Active", label: "Active" }, { value: "Retired", label: "Retired" }] }])
    ];
    const res = await T.form({ title: v ? `${overriding ? "Change GRAC value" : "Edit value"} ${F(v, "valueCode")}` : `Add value to ${F(list, "listName")}`, fields,
      intro: overriding ? "The organization's change is kept beside the GRAC value; reset to go back to it." : "",
      onSubmit: x => overriding
        ? api("POST", "/config/reference/overrides", { organizationId: state.org, baselineValueId: Number(F(v, "baselineValueId") ?? F(v, "valueId")), label: x.label,
            description: x.description, rankNo: x.rankNo, colorHex: x.colorHex, isMandatory: !!x.isMandatory, displayOrder: x.displayOrder, isHidden: !!x.isHidden, reset: !!x.reset })
        : api("POST", "/config/reference/values", scopeBody({ valueId: v ? F(v, "valueId") : null, listCode: state.listCode, valueCode: x.valueCode || F(v, "valueCode"),
            label: x.label, description: x.description, meaningCode: x.meaningCode, rankNo: x.rankNo, colorHex: x.colorHex, isMandatory: !!x.isMandatory,
            displayOrder: x.displayOrder, status: x.status })) });
    if (res) { show("cfMessage", "Saved.", "success"); await render(); }
  }

  // ------------------------------------------------------------------ library
  async function renderLibrary(panel) {
    const r = await api("GET", `/config/library?${scopeQs({ libraryCode: state.libraryCode })}`);
    if (!r.ok) { panel.innerHTML = `<p class="pm-message">${esc(r.error)}</p>`; return; }
    const rows = r.data.data || [];
    state.data.library = rows;
    panel.innerHTML = `
      <div class="pm-toolbar">${picker("libraryCode", LIBRARIES, state.libraryCode)}${CAN_CHANGE ? btn("item-add", "fa-plus", "Add item") : ""}</div>
      <p class="tprm-note">Baseline items are illustrative; the source columns record where an item comes from and whether it is a regulatory requirement.</p>
      <div class="pm-table-wrap"><table><thead><tr><th>Item</th><th>Category / dimension</th><th>Details</th><th>Source</th><th>Origin</th><th>Status</th><th></th></tr></thead>
      <tbody>${rows.map(x => `<tr class="${yes(F(x, "isHidden")) || F(x, "status") !== "Active" ? "cf-hidden-row" : ""}">
        <td>${esc(F(x, "itemCode"))} ${esc(F(x, "itemName"))}${F(x, "description") ? `<div class="tprm-muted">${esc(F(x, "description"))}</div>` : ""}</td>
        <td>${esc([F(x, "categoryCode"), F(x, "dimensionCode")].filter(Boolean).join(" / "))}</td>
        <td class="tprm-muted">${esc([F(x, "effectivenessCriteria") && `Effective when: ${F(x, "effectivenessCriteria")}`, yes(F(x, "isContractClause")) && "Contract clause",
            F(x, "evidenceRequirementCode") && `Evidence: ${F(x, "evidenceRequirementCode")}`, F(x, "validityMonths") && `Valid ${F(x, "validityMonths")} months`,
            F(x, "defaultDueDays") && `Due in ${F(x, "defaultDueDays")} days`].filter(Boolean).join(" - "))}</td>
        <td class="tprm-muted">${esc(F(x, "sourceAuthority") || "")}${F(x, "sourceReference") ? `, ${esc(F(x, "sourceReference"))}` : ""}${yes(F(x, "isRegulatory")) ? " (regulatory)" : ""}</td>
        <td>${originBadge(F(x, "origin"))}</td><td>${yes(F(x, "isHidden")) ? "Hidden" : esc(F(x, "status"))}</td>
        <td>${CAN_CHANGE ? btn("item-edit", "fa-pen", "", { id: F(x, "itemId"), origin: F(x, "origin") }) : ""}</td></tr>`).join("") || empty(7, "No items.")}</tbody></table></div>`;
  }
  async function editItem(d) {
    const lk = state.lk;
    const x = d ? state.data.library.find(i => String(F(i, "itemId")) === String(d.id) && F(i, "origin") === d.origin) : null;
    const overriding = x && !state.baseline && F(x, "origin") !== "ORGANIZATION";
    const lib = state.libraryCode;
    const cats = lk ? lk.options("SAFEGUARD_CATEGORY") : [];
    const dims = lk ? lk.dimensions.map(dd => ({ value: F(dd, "dimensionCode"), label: F(dd, "dimensionName") })) : [];
    const fields = [
      ...(overriding ? [] : [{ name: "itemCode", label: "Code", required: true, maxLength: 60, value: x ? F(x, "itemCode") : "", readonly: !!x }]),
      { name: "itemName", label: "Name", required: true, maxLength: 250, value: x ? F(x, "itemName") : "" },
      { name: "description", label: "Description", type: "textarea", rows: 2, maxLength: 2000, value: x ? F(x, "description") : "" },
      ...(lib === "SAFEGUARD" ? [
        { name: "categoryCode", label: "Category", type: cats.length ? "select" : "text", options: cats, value: x ? F(x, "categoryCode") : "" },
        { name: "dimensionCode", label: "Risk dimension", type: dims.length ? "select" : "text", options: dims, value: x ? F(x, "dimensionCode") : "" },
        { name: "effectivenessCriteria", label: "Effective when", type: "textarea", rows: 2, maxLength: 2000, value: x ? F(x, "effectivenessCriteria") : "" },
        { name: "isContractClause", label: "Contractual safeguard (clause)", type: "checkbox", value: x ? F(x, "isContractClause") : false },
        { name: "evidenceRequirementCode", label: "Evidence requirement code", maxLength: 60, value: x ? F(x, "evidenceRequirementCode") : "" }] : []),
      ...(lib === "EVIDENCE_REQUIREMENT" ? [
        { name: "evidenceTypeId", label: "Evidence Center type", type: "select", options: (lk ? lk.evidenceTypes : []).map(t => ({ value: F(t, "evidenceTypeId"), label: F(t, "evidenceType") })), value: x ? F(x, "evidenceTypeId") : "" },
        { name: "validityMonths", label: "Valid for (months)", type: "number", min: 0, value: x ? F(x, "validityMonths") : "" },
        { name: "reviewRequired", label: "Needs review when received", type: "checkbox", value: x ? F(x, "reviewRequired") : true }] : []),
      ...(lib === "TREATMENT_ACTION" ? [
        { name: "defaultDueDays", label: "Default due (days)", type: "number", min: 0, value: x ? F(x, "defaultDueDays") : "" },
        { name: "defaultOwnerHint", label: "Usual owner", maxLength: 200, value: x ? F(x, "defaultOwnerHint") : "" }] : []),
      { name: "guidance", label: "Guidance", type: "textarea", rows: 2, maxLength: 2000, value: x ? F(x, "guidance") : "" },
      ...(overriding ? [] : [
        { type: "section", label: "Source", name: "_src" },
        { name: "sourceAuthority", label: "Source authority", maxLength: 200, value: x ? F(x, "sourceAuthority") : "" },
        { name: "sourceDocument", label: "Source document", maxLength: 300, value: x ? F(x, "sourceDocument") : "" },
        { name: "sourceVersion", label: "Version", maxLength: 100, value: x ? F(x, "sourceVersion") : "" },
        { name: "sourceReference", label: "Reference", maxLength: 300, value: x ? F(x, "sourceReference") : "" },
        { name: "applicabilityNote", label: "Applicability", type: "textarea", rows: 2, maxLength: 1000, value: x ? F(x, "applicabilityNote") : "" },
        { name: "isRegulatory", label: "A regulatory requirement (only when the source establishes it)", type: "checkbox", value: x ? F(x, "isRegulatory") : false }]),
      { name: "displayOrder", label: "Order", type: "number", value: x ? F(x, "displayOrder") : 100 },
      ...(overriding ? [{ name: "isHidden", label: "Hide for this organization", type: "checkbox", value: F(x, "isHidden") }, { name: "reset", label: "Reset to the GRAC item", type: "checkbox" }]
                     : [{ name: "status", label: "Status", type: "select", blank: false, value: x ? F(x, "status") : "Active", options: [{ value: "Active", label: "Active" }, { value: "Retired", label: "Retired" }] }])
    ];
    const res = await T.form({ title: x ? `${overriding ? "Change GRAC item" : "Edit item"} ${F(x, "itemCode")}` : "Add library item", wide: true, fields,
      onSubmit: v => {
        const common = { itemName: v.itemName, description: v.description, categoryCode: v.categoryCode, dimensionCode: v.dimensionCode, guidance: v.guidance,
          effectivenessCriteria: v.effectivenessCriteria, isContractClause: v.isContractClause, evidenceRequirementCode: v.evidenceRequirementCode,
          evidenceTypeId: v.evidenceTypeId ? Number(v.evidenceTypeId) : null, validityMonths: v.validityMonths, reviewRequired: v.reviewRequired,
          defaultDueDays: v.defaultDueDays, defaultOwnerHint: v.defaultOwnerHint, displayOrder: v.displayOrder };
        return overriding
          ? api("POST", "/config/library/overrides", { organizationId: state.org, baselineItemId: Number(F(x, "baselineItemId") ?? F(x, "itemId")), ...common, isHidden: !!v.isHidden, reset: !!v.reset })
          : api("POST", "/config/library/items", scopeBody({ itemId: x ? F(x, "itemId") : null, libraryCode: lib, itemCode: v.itemCode || F(x, "itemCode"), ...common,
              sourceAuthority: v.sourceAuthority, sourceDocument: v.sourceDocument, sourceVersion: v.sourceVersion, sourceReference: v.sourceReference,
              applicabilityNote: v.applicabilityNote, isRegulatory: !!v.isRegulatory, status: v.status }));
      } });
    if (res) { show("cfMessage", "Saved.", "success"); await render(); }
  }

  // ------------------------------------------------------------------ templates
  async function renderTemplates(panel) {
    const r = await api("GET", `/config/templates?${scopeQs()}`);
    if (!r.ok) { panel.innerHTML = `<p class="pm-message">${esc(r.error)}</p>`; return; }
    const rows = r.data.data || [];
    state.data.templates = rows;
    const row = t => {
      const own = state.baseline || F(t, "origin") !== "GRAC";
      const acts = [];
      if (F(t, "currentVersionId")) acts.push(btn("version-open", "fa-eye", "Open", { id: F(t, "currentVersionId") }));
      if (F(t, "draftVersionId")) acts.push(btn("version-open", "fa-pen-to-square", `Draft v${F(t, "draftVersionNo")}`, { id: F(t, "draftVersionId") }));
      if (CAN_CHANGE && own && !F(t, "draftVersionId") && F(t, "status") === "Active") acts.push(btn("template-new-version", "fa-code-branch", "New version", { id: F(t, "templateId") }));
      if (CAN_CHANGE && !state.baseline && F(t, "origin") === "GRAC" && (!F(t, "adoptedTemplateId") || yes(F(t, "updateAvailable"))))
        acts.push(btn("template-adopt", "fa-copy", F(t, "adoptedTemplateId") ? "Take the update" : "Adopt", { id: F(t, "templateId") }));
      if (CAN_APPROVE && own) acts.push(btn("template-retire", F(t, "status") === "Active" ? "fa-box-archive" : "fa-rotate-left", F(t, "status") === "Active" ? "Retire" : "Restore", { id: F(t, "templateId"), restore: F(t, "status") === "Active" ? "0" : "1" }));
      return `<tr class="${F(t, "status") !== "Active" ? "cf-hidden-row" : ""}">
        <td>${esc(F(t, "templateCode"))} ${esc(F(t, "templateName"))}${F(t, "description") ? `<div class="tprm-muted">${esc(F(t, "description"))}</div>` : ""}</td>
        <td>${F(t, "templateKind") === "RISK_MODEL" ? "Risk model" : "Questionnaire"}${yes(F(t, "isDefault")) ? ' <span class="pm-badge">Default</span>' : ""}
          ${F(t, "templateKind") === "QUESTIONNAIRE" ? `<div class="tprm-muted">${yes(F(t, "isCore")) ? "Core" : esc([F(t, "appliesServiceCategories"), F(t, "appliesMinTierRank") ? `tier ${F(t, "appliesMinTierRank")}+` : ""].filter(Boolean).join(", "))}</div>` : ""}</td>
        <td>${F(t, "currentVersionNo") ? `v${esc(F(t, "currentVersionNo"))}` : "--"} <span class="tprm-muted">${esc(date(F(t, "currentActivatedDt")))}</span>
          ${yes(F(t, "inForce")) ? '<div><span class="pm-badge">In force</span></div>' : ""}</td>
        <td>${originBadge(F(t, "origin"))}${F(t, "baselineTemplateName") ? `<div class="tprm-muted">from ${esc(F(t, "baselineTemplateName"))} v${esc(F(t, "derivedFromBaselineVersionNo") ?? "")}</div>` : ""}
          ${yes(F(t, "updateAvailable")) ? `<div class="tprm-alert">GRAC v${esc(F(t, "baselineCurrentVersionNo"))} available</div>` : ""}</td>
        <td>${esc(F(t, "status"))}</td><td>${acts.join(" ")}</td></tr>`;
    };
    panel.innerHTML = `
      <div class="tprm-actions">${CAN_CHANGE ? btn("template-create", "fa-plus", "New template") : ""}${btn("template-compare", "fa-code-compare", "Compare versions")}</div>
      <p class="tprm-note">One version of a template is in force. Changes are made on a Draft and take effect when it is activated; assessments keep the version they used.${state.baseline ? "" : " A GRAC template is used as it is until the organization adopts (copies) it."}</p>
      <div class="pm-table-wrap"><table><thead><tr><th>Template</th><th>Kind</th><th>Version in force</th><th>Origin</th><th>Status</th><th></th></tr></thead>
      <tbody>${rows.map(row).join("") || empty(6, "No templates.")}</tbody></table></div>`;
  }

  async function openVersion(versionId) {
    const r = await api("GET", `/config/templates/versions/${versionId}?${scopeQs()}`);
    if (!r.ok) { show("cfMessage", r.error); return; }
    state.version = r.data;
    renderVersion();
    hide("cfVersionMessage");
    document.getElementById("cfVersionModal").hidden = false;
  }
  function renderVersion() {
    const v = state.version;
    const h = (v.header || [])[0];
    const rm = F(h, "templateKind") === "RISK_MODEL";
    const edit = yes(F(h, "isEditable")) && CAN_CHANGE;
    document.getElementById("cfVersionTitle").textContent = `${F(h, "templateName")} v${F(h, "versionNo")} (${F(h, "versionStatus")})`;
    const itemBtns = (type, id) => edit ? btn("item-edit-v", "fa-pen", "", { type, id }) + btn("item-remove-v", "fa-trash", "", { type, id }) : "";
    const header = T.info([
      ["Template", `${F(h, "templateCode")} - ${F(h, "templateName")}`], ["Origin", ORIGIN[F(h, "origin")] || F(h, "origin")],
      ["Version", `v${F(h, "versionNo")} ${F(h, "versionStatus")}`], ["Change summary", F(h, "changeSummary")],
      ...(rm ? [["Aggregation", `${F(h, "aggregationMethod")}${F(h, "aggregationMethod") === "BLENDED" ? ` (${F(h, "blendPct")}% highest dimension)` : ""}`],
                ["Residual reductions", `effective ${F(h, "effectiveReductionPct")}%, partial ${F(h, "partialReductionPct")}%, floor ${F(h, "residualFloorPct")}%, deficiency uplift ${F(h, "deficiencyUpliftPct")}%`]]
             : [["Applies to", yes(F(h, "isCore")) ? "Every engagement (core)" : [F(h, "appliesServiceCategories"), F(h, "appliesMinTierRank") ? `tier rank ${F(h, "appliesMinTierRank")}+` : "", F(h, "appliesEngagementTypes")].filter(Boolean).join(", ")]]),
      ["Activated", F(h, "activatedDt") ? `${T.dateTime(F(h, "activatedDt"))} by ${F(h, "activatedBy") || ""}` : ""]
    ]);
    let body;
    if (rm) {
      const opts = fid => (v.options || []).filter(o => String(F(o, "factorId")) === String(fid)).map(o => `${F(o, "optionLabel")} (${F(o, "score")})`).join("; ");
      body = `
        <div class="tprm-subhead">Dimensions ${edit ? btn("item-add-v", "fa-plus", "Add", { type: "DIMENSION" }) : ""}</div>
        <div class="pm-table-wrap"><table><thead><tr><th>Code</th><th>Dimension</th><th>Weight</th><th></th></tr></thead><tbody>${
          (v.dimensions || []).map(d => `<tr><td>${esc(F(d, "dimensionCode"))}</td><td>${esc(F(d, "dimensionName"))}</td><td>${esc(F(d, "weight"))}</td><td>${itemBtns("DIMENSION", F(d, "dimensionId"))}</td></tr>`).join("") || empty(4, "None.")}</tbody></table></div>
        <div class="tprm-subhead">Factors ${edit ? btn("item-add-v", "fa-plus", "Add", { type: "FACTOR" }) : ""}</div>
        <div class="pm-table-wrap"><table><thead><tr><th>Factor</th><th>Dimension</th><th>Options (score)</th><th>Prefill</th><th></th></tr></thead><tbody>${
          (v.factors || []).map(f => `<tr><td>${esc(F(f, "factorCode"))} ${esc(F(f, "questionText"))}${yes(F(f, "isMandatory")) ? " *" : ""}</td><td>${esc(F(f, "dimensionCode"))}</td>
            <td class="tprm-muted">${esc(opts(F(f, "factorId")))}</td><td>${esc(F(f, "prefillSource") || "")}</td><td>${itemBtns("FACTOR", F(f, "factorId"))}</td></tr>`).join("") || empty(5, "None.")}</tbody></table></div>
        <div class="tprm-subhead">Risk bands ${edit ? btn("item-add-v", "fa-plus", "Add", { type: "BAND" }) : ""}</div>
        <div class="pm-table-wrap"><table><thead><tr><th>Band</th><th>From score</th><th>Rank</th><th>Due-diligence tier</th><th></th></tr></thead><tbody>${
          (v.bands || []).map(b => `<tr><td>${T.badge(F(b, "bandName"), F(b, "colorHex"))} ${esc(F(b, "bandCode"))}</td><td>${esc(F(b, "minScore"))}${F(b, "nextMinScore") != null ? ` to below ${esc(F(b, "nextMinScore"))}` : ""}</td>
            <td>${esc(F(b, "rankNo"))}</td><td>${esc(F(b, "ddTierCode"))}</td><td>${itemBtns("BAND", F(b, "bandId"))}</td></tr>`).join("") || empty(5, "None.")}</tbody></table></div>
        <div class="tprm-subhead">Minimum tier rules ${edit ? btn("item-add-v", "fa-plus", "Add", { type: "TIER_RULE" }) : ""}</div>
        <div class="pm-table-wrap"><table><thead><tr><th>When</th><th>Value</th><th>At least tier</th><th></th></tr></thead><tbody>${
          (v.tierRules || []).map(t => `<tr><td>${esc(F(t, "conditionKind"))}</td><td>${esc(F(t, "conditionCode"))}</td><td>${esc(F(t, "minDdTierCode"))}</td><td>${itemBtns("TIER_RULE", F(t, "tierRuleId"))}</td></tr>`).join("") || empty(4, "None.")}</tbody></table></div>`;
    } else {
      const opts = qid => (v.options || []).filter(o => String(F(o, "questionId")) === String(qid)).map(o => `${F(o, "optionLabel")}${yes(F(o, "flagsDeficiency")) ? ` [deficiency ${F(o, "deficiencySeverityCode") || ""}]` : ""}`).join("; ");
      body = `
        <div class="tprm-subhead">Sections ${edit ? btn("item-add-v", "fa-plus", "Add", { type: "SECTION" }) : ""}</div>
        <div class="pm-table-wrap"><table><thead><tr><th>Code</th><th>Section</th><th></th></tr></thead><tbody>${
          (v.sections || []).map(s => `<tr><td>${esc(F(s, "sectionCode"))}</td><td>${esc(F(s, "title"))}</td><td>${itemBtns("SECTION", F(s, "sectionId"))}</td></tr>`).join("") || empty(3, "None.")}</tbody></table></div>
        <div class="tprm-subhead">Questions ${edit ? btn("item-add-v", "fa-plus", "Add", { type: "QUESTION" }) : ""}</div>
        <div class="pm-table-wrap"><table><thead><tr><th>Question</th><th>Type</th><th>Applies when</th><th>Options</th><th>Source</th><th></th></tr></thead><tbody>${
          (v.questions || []).map(q => `<tr><td>${esc(F(q, "questionCode"))} ${esc(F(q, "questionText"))}${yes(F(q, "isMandatory")) ? " *" : ""}
              ${F(q, "parentQuestionCode") ? `<div class="tprm-muted">Follow-up of ${esc(F(q, "parentQuestionCode"))} when ${esc(F(q, "triggerOptionCodes") || "")}</div>` : ""}</td>
            <td>${esc(F(q, "responseType"))}${yes(F(q, "evidenceExpected")) ? '<div class="tprm-muted">evidence expected</div>' : ""}</td>
            <td class="tprm-muted">${esc([F(q, "minTierRank") && `tier ${F(q, "minTierRank")}+`, F(q, "appliesServiceCategories"), F(q, "appliesMinDataRank") && `data rank ${F(q, "appliesMinDataRank")}+`, F(q, "appliesAccessCodes")].filter(Boolean).join(", ") || "always")}</td>
            <td class="tprm-muted">${esc(opts(F(q, "questionId")))}</td>
            <td class="tprm-muted">${esc(F(q, "sourceAuthority") || "")}${yes(F(q, "isRegulatory")) ? " (regulatory)" : ""}</td>
            <td>${itemBtns("QUESTION", F(q, "questionId"))}</td></tr>`).join("") || empty(6, "None.")}</tbody></table></div>`;
    }
    const versions = (v.versions || []).map(x => `<tr><td>v${esc(F(x, "versionNo"))}</td><td>${esc(F(x, "status"))}</td><td>${esc(F(x, "changeSummary") || "")}</td>
      <td>${esc(T.dateTime(F(x, "activatedDt") || F(x, "createdDt")))}</td><td>${String(F(x, "versionId")) !== String(F(h, "versionId")) ? btn("version-open", "fa-eye", "", { id: F(x, "versionId") }) : ""}</td></tr>`).join("");
    document.getElementById("cfVersionBody").innerHTML = `
      <div class="tprm-info">${header}</div>
      <div class="tprm-actions">
        ${edit ? btn("version-header", "fa-sliders", "Settings") : ""}
        ${edit && CAN_APPROVE ? btn("version-activate", "fa-circle-check", "Activate", {}, "primary") + btn("version-discard", "fa-xmark", "Discard draft") : ""}
        ${!yes(F(h, "isEditable")) ? '<span class="tprm-muted">This version is read-only. Create a new version to change it.</span>' : ""}
      </div>
      ${body}
      <div class="tprm-subhead">Versions</div>
      <div class="pm-table-wrap"><table><thead><tr><th>Version</th><th>Status</th><th>Change</th><th>When</th><th></th></tr></thead><tbody>${versions}</tbody></table></div>`;
  }

  async function editVersionItem(type, id) {
    const v = state.version;
    const h = v.header[0];
    const vid = F(h, "versionId");
    const lk = state.lk;
    const find = (set, key) => id ? (v[set] || []).find(x => String(F(x, key)) === String(id)) : null;
    let fields, map;
    const tiers = lk ? lk.options("DD_TIER") : [];
    const sev = lk ? lk.options("FINDING_SEVERITY") : [];
    if (type === "DIMENSION") {
      const d = find("dimensions", "dimensionId");
      fields = [{ name: "code", label: "Code", required: true, maxLength: 60, value: F(d, "dimensionCode") }, { name: "name", label: "Dimension", required: true, maxLength: 200, value: F(d, "dimensionName") },
                { name: "weight", label: "Weight", type: "number", step: "any", min: 0, required: true, value: F(d, "weight") }, { name: "description", label: "Description", type: "textarea", value: F(d, "description") },
                { name: "displayOrder", label: "Order", type: "number", value: F(d, "displayOrder") ?? 100 }];
      map = x => x;
    } else if (type === "FACTOR") {
      const f = find("factors", "factorId");
      const opts = f ? (v.options || []).filter(o => String(F(o, "factorId")) === String(id)).map(o => [F(o, "optionCode"), F(o, "optionLabel"), F(o, "score"), F(o, "prefillMatchCode") || ""].join(" | ")).join("\n") : "";
      fields = [{ name: "code", label: "Code", required: true, maxLength: 60, value: F(f, "factorCode") },
                { name: "dimensionCode", label: "Dimension", type: "select", required: true, options: (v.dimensions || []).map(d => ({ value: F(d, "dimensionCode"), label: F(d, "dimensionName") })), value: F(f, "dimensionCode") },
                { name: "name", label: "Question", type: "textarea", required: true, maxLength: 1000, value: F(f, "questionText") },
                { name: "description", label: "Guidance", type: "textarea", value: F(f, "guidance") },
                { name: "prefillSource", label: "Prefill from the scope", type: "select", options: PREFILL, value: F(f, "prefillSource") },
                { name: "isMandatory", label: "Mandatory", type: "checkbox", value: f ? F(f, "isMandatory") : true },
                { name: "options", label: "Options -- one per line: code | label | score (0-100) | prefill match codes (comma separated)", type: "textarea", rows: 5, required: true, value: opts },
                { name: "displayOrder", label: "Order", type: "number", value: F(f, "displayOrder") ?? 100 }];
      map = x => ({ ...x, optionsJson: JSON.stringify(lines(x.options).map(([code, label, score, prefill]) => ({ code, label, score: Number(score), prefillMatch: prefill || null }))) });
    } else if (type === "BAND") {
      const b = find("bands", "bandId");
      fields = [{ name: "code", label: "Code", required: true, maxLength: 60, value: F(b, "bandCode") }, { name: "name", label: "Band", required: true, maxLength: 120, value: F(b, "bandName") },
                { name: "minScore", label: "From score (0-100)", type: "number", step: "any", min: 0, max: 100, required: true, value: F(b, "minScore") },
                { name: "rankNo", label: "Rank (1 = lowest risk)", type: "number", min: 1, required: true, value: F(b, "rankNo") },
                { name: "colorHex", label: "Colour (#RRGGBB)", maxLength: 9, value: F(b, "colorHex") },
                { name: "ddTierCode", label: "Due-diligence tier", type: "select", options: tiers, required: true, value: F(b, "ddTierCode") }];
      map = x => x;
    } else if (type === "TIER_RULE") {
      const t = find("tierRules", "tierRuleId");
      fields = [{ name: "conditionKind", label: "When", type: "select", required: true, value: F(t, "conditionKind"),
                  options: [{ value: "CRITICALITY", label: "Service criticality is" }, { value: "DATA_EXPOSURE", label: "Data exposure includes" }, { value: "ACCESS", label: "Access includes" }] },
                { name: "code", label: "Value code", required: true, maxLength: 60, value: F(t, "conditionCode") },
                { name: "ddTierCode", label: "At least tier", type: "select", options: tiers, required: true, value: F(t, "minDdTierCode") }];
      map = x => x;
    } else if (type === "SECTION") {
      const s = find("sections", "sectionId");
      fields = [{ name: "code", label: "Code", required: true, maxLength: 60, value: F(s, "sectionCode") }, { name: "text", label: "Title", required: true, maxLength: 2000, value: F(s, "title") },
                { name: "description", label: "Description", type: "textarea", value: F(s, "description") }, { name: "displayOrder", label: "Order", type: "number", value: F(s, "displayOrder") ?? 100 }];
      map = x => x;
    } else {
      const q = find("questions", "questionId");
      const opts = q ? (v.options || []).filter(o => String(F(o, "questionId")) === String(id)).map(o => [F(o, "optionCode"), F(o, "optionLabel"), F(o, "score") ?? "", yes(F(o, "flagsDeficiency")) ? "deficiency" : "", F(o, "deficiencySeverityCode") || ""].join(" | ")).join("\n") : "";
      const lib = c => (lk ? lk.libraryItems(c) : []).map(x => ({ value: F(x, "itemCode"), label: F(x, "itemName") }));
      fields = [{ name: "code", label: "Code", required: true, maxLength: 60, value: F(q, "questionCode") },
                { name: "sectionCode", label: "Section", type: "select", required: true, options: (v.sections || []).map(s => ({ value: F(s, "sectionCode"), label: F(s, "title") })),
                  value: q ? F((v.sections || []).find(s => String(F(s, "sectionId")) === String(F(q, "sectionId"))), "sectionCode") : "" },
                { name: "text", label: "Question", type: "textarea", required: true, maxLength: 2000, value: F(q, "questionText") },
                { name: "description", label: "Guidance", type: "textarea", value: F(q, "guidance") },
                { name: "responseType", label: "Answer type", type: "select", options: RESPONSE_TYPES, required: true, value: F(q, "responseType") || "YES_NO" },
                { name: "options", label: "Options (choice types) -- one per line: code | label | score | deficiency | severity code", type: "textarea", rows: 4, value: opts,
                  help: "Yes / No questions get Yes, No (deficiency, medium) and N/A when left empty." },
                { name: "isMandatory", label: "Mandatory", type: "checkbox", value: q ? F(q, "isMandatory") : true },
                { name: "evidenceExpected", label: "Evidence expected", type: "checkbox", value: q ? F(q, "evidenceExpected") : false },
                { name: "evidenceRequirementCode", label: "Evidence requirement", type: "select", options: lib("EVIDENCE_REQUIREMENT"), value: F(q, "evidenceRequirementCode") },
                { name: "safeguardCode", label: "Safeguard it tests", type: "select", options: lib("SAFEGUARD"), value: F(q, "safeguardCode") },
                { name: "dimensionCode", label: "Risk dimension", maxLength: 60, value: F(q, "dimensionCode") },
                { type: "section", label: "Applies when (empty = always)", name: "_ap" },
                { name: "minTierRank", label: "Due-diligence tier rank at least", type: "number", min: 1, value: F(q, "minTierRank") },
                { name: "appliesServiceCategories", label: "Service categories (codes, comma separated)", maxLength: 1000, value: F(q, "appliesServiceCategories") },
                { name: "appliesMinDataRank", label: "Data exposure rank at least", type: "number", min: 0, value: F(q, "appliesMinDataRank") },
                { name: "appliesAccessCodes", label: "Access codes (comma separated)", maxLength: 600, value: F(q, "appliesAccessCodes") },
                { name: "parentQuestionCode", label: "Follow-up of question (code)", maxLength: 60, value: F(q, "parentQuestionCode") },
                { name: "triggerOptionCodes", label: "Shown when the parent's answer is (codes)", maxLength: 400, value: F(q, "triggerOptionCodes") },
                { type: "section", label: "Source", name: "_src" },
                { name: "sourceAuthority", label: "Source authority", maxLength: 200, value: F(q, "sourceAuthority") },
                { name: "sourceReference", label: "Reference", maxLength: 300, value: F(q, "sourceReference") },
                { name: "isRegulatory", label: "A regulatory requirement", type: "checkbox", value: q ? F(q, "isRegulatory") : false },
                { name: "displayOrder", label: "Order", type: "number", value: F(q, "displayOrder") ?? 100 }];
      map = x => ({ ...x, optionsJson: x.options ? JSON.stringify(lines(x.options).map(([code, label, score, def, severity]) => ({
        code, label, score: score === "" || score === undefined ? null : Number(score), flagsDeficiency: /^(deficiency|yes|1|true)$/i.test(def || ""), severity: severity || null }))) : null });
    }
    if (sev.length === 0) { /* severity codes are free text when the lookups are not loaded (baseline scope) */ }
    const path = ["SECTION", "QUESTION"].includes(type) ? "questionnaire-items" : "risk-items";
    const res = await T.form({ title: `${id ? "Edit" : "Add"} ${type.replace("_", " ").toLowerCase()}`, wide: type === "QUESTION" || type === "FACTOR", fields,
      onSubmit: x => { const m = map(x); delete m.options; return api("POST", `/config/templates/versions/${vid}/${path}`, scopeBody({ itemType: type, itemId: id ? Number(id) : null, ...m })); } });
    if (res) await openVersion(vid);
  }
  function lines(text) { return String(text || "").split("\n").map(l => l.trim()).filter(Boolean).map(l => l.split("|").map(x => x.trim())); }

  // ------------------------------------------------------------------ rules + delegations
  async function renderRules(panel) {
    const r = await api("GET", `/config/rules?${scopeQs()}`);
    if (!r.ok) { panel.innerHTML = `<p class="pm-message">${esc(r.error)}</p>`; return; }
    state.data.rules = r.data;
    if (state.tab === "DELEGATIONS") {
      panel.innerHTML = `
        <div class="tprm-actions">${CAN_APPROVE ? btn("delegation-add", "fa-plus", "Delegate approval") : ""}</div>
        <p class="tprm-note">While a delegation is active, the delegate can approve engagement decisions on behalf of the approver (recorded as such).</p>
        <div class="pm-table-wrap"><table><thead><tr><th>From</th><th>To</th><th>Valid</th><th>Reason</th><th>Status</th><th></th></tr></thead><tbody>${
          (r.data.delegations || []).map(d => `<tr><td>${esc(F(d, "fromEmployeeName"))}</td><td>${esc(F(d, "toEmployeeName"))}</td>
            <td>${esc(date(F(d, "validFrom")))} to ${esc(date(F(d, "validTo")))}</td><td>${esc(F(d, "reason") || "")}</td><td>${esc(F(d, "status"))}</td>
            <td>${CAN_APPROVE && F(d, "status") === "Active" ? btn("delegation-revoke", "fa-ban", "Revoke", { id: F(d, "delegationId") }) : ""}</td></tr>`).join("") || empty(6, "No delegations.")}</tbody></table></div>`;
      return;
    }
    const ruleRow = (kind, x) => `<tr class="${yes(F(x, "isHidden")) || yes(F(x, "isOverridden")) ? "cf-hidden-row" : ""}">
      <td>${esc(F(x, "ruleCode"))} ${esc(F(x, "ruleName"))}${yes(F(x, "isOverridden")) ? '<div class="tprm-muted">Changed by this organization (see its row)</div>' : ""}</td>
      <td>${esc(F(x, "priority"))}</td>
      <td>${esc([F(x, "minBandRank") != null ? `band rank ${F(x, "minBandRank")}+` : "", F(x, "minCriticalityRank") != null ? `criticality rank ${F(x, "minCriticalityRank")}+` : ""].filter(Boolean).join(" or ") || "catch-all")}</td>
      <td>${kind === "approval"
          ? esc(`${F(x, "approvalLevels")} level(s): ${[F(x, "level1RoleName"), F(x, "level2RoleName"), F(x, "level3RoleName")].filter(Boolean).join(" -> ")}${yes(F(x, "sodRequired")) ? "; SoD" : ""}${yes(F(x, "escalateToRiskCentre")) ? "; escalate" : ""}${F(x, "maxAcceptanceMonths") ? `; accept <= ${F(x, "maxAcceptanceMonths")} m` : ""}`)
          : esc(`review every ${F(x, "reviewFrequencyMonths")} m; evidence ${F(x, "evidenceRenewalMonths") ?? "--"} m; contract alert ${F(x, "contractExpiryAlertDays") ?? "--"} d; reassess on ${F(x, "reassessmentTriggerCodes") || "--"}`)}</td>
      <td>${originBadge(F(x, "origin"))}</td><td>${yes(F(x, "isHidden")) ? "Hidden" : esc(F(x, "status"))}</td>
      <td>${CAN_CHANGE ? btn("rule-edit", "fa-pen", "", { kind, id: F(x, "ruleId"), origin: F(x, "origin") }) : ""}</td></tr>`;
    panel.innerHTML = `
      <div class="tprm-subhead">Approval rules <span>${CAN_CHANGE ? btn("rule-add", "fa-plus", "Add", { kind: "approval" }) : ""}</span></div>
      <p class="tprm-note">The first rule (lowest priority number) whose threshold the engagement meets decides the approval path: residual band rank (inherent while there is none) or service criticality rank. Approver roles are GRAC organization roles.</p>
      <div class="pm-table-wrap"><table><thead><tr><th>Rule</th><th>Priority</th><th>Applies at</th><th>Path</th><th>Origin</th><th>Status</th><th></th></tr></thead>
        <tbody>${(r.data.approvalRules || []).map(x => ruleRow("approval", x)).join("") || empty(7, "None.")}</tbody></table></div>
      <div class="tprm-subhead">Review rules <span>${CAN_CHANGE ? btn("rule-add", "fa-plus", "Add", { kind: "review" }) : ""}</span></div>
      <div class="pm-table-wrap"><table><thead><tr><th>Rule</th><th>Priority</th><th>Applies at</th><th>Monitoring</th><th>Origin</th><th>Status</th><th></th></tr></thead>
        <tbody>${(r.data.reviewRules || []).map(x => ruleRow("review", x)).join("") || empty(7, "None.")}</tbody></table></div>`;
  }
  async function editRule(d) {
    const kind = d.kind;
    const set = kind === "approval" ? state.data.rules.approvalRules : state.data.rules.reviewRules;
    const x = d.id ? set.find(r => String(F(r, "ruleId")) === String(d.id) && F(r, "origin") === d.origin) : null;
    const overridingBaseline = x && !state.baseline && F(x, "origin") === "GRAC";
    const roles = (state.data.rules.roles || []).map(r => ({ value: F(r, "roleName"), label: F(r, "roleName") }));
    const roleField = (n, label) => roles.length ? { name: n, label, type: "select", options: roles, value: F(x, n) } : { name: n, label, maxLength: 120, value: F(x, n) };
    const fields = [
      { name: "ruleCode", label: "Code", maxLength: 60, value: F(x, "ruleCode"), readonly: !!x, required: !x },
      { name: "ruleName", label: "Name", required: true, maxLength: 200, value: F(x, "ruleName") },
      { name: "description", label: "Description", type: "textarea", rows: 2, maxLength: 1000, value: F(x, "description") },
      { name: "priority", label: "Priority (lower first)", type: "number", value: F(x, "priority") ?? 100 },
      { name: "minBandRank", label: "From risk band rank", type: "number", min: 1, value: F(x, "minBandRank") },
      { name: "minCriticalityRank", label: "Or from criticality rank", type: "number", min: 1, value: F(x, "minCriticalityRank") },
      ...(kind === "approval" ? [
        { name: "approvalLevels", label: "Approval levels (1-3)", type: "number", min: 1, max: 3, required: true, value: F(x, "approvalLevels") ?? 1 },
        roleField("level1RoleName", "Level 1 role"), roleField("level2RoleName", "Level 2 role"), roleField("level3RoleName", "Level 3 role"),
        { name: "sodRequired", label: "Segregation of duties", type: "checkbox", value: x ? F(x, "sodRequired") : true },
        { name: "escalateToRiskCentre", label: "Recommend escalation to the Risk Centre", type: "checkbox", value: F(x, "escalateToRiskCentre") },
        { name: "maxAcceptanceMonths", label: "Risk acceptance at most (months)", type: "number", min: 1, value: F(x, "maxAcceptanceMonths") },
        { name: "allowedDecisionCodes", label: "Allowed outcomes (DECISION codes, empty = all)", maxLength: 400, value: F(x, "allowedDecisionCodes") }]
      : [
        { name: "reviewFrequencyMonths", label: "Review every (months)", type: "number", min: 1, required: true, value: F(x, "reviewFrequencyMonths") ?? 12 },
        { name: "evidenceRenewalMonths", label: "Evidence renewal (months)", type: "number", min: 1, value: F(x, "evidenceRenewalMonths") },
        { name: "contractExpiryAlertDays", label: "Contract expiry alert (days)", type: "number", min: 0, value: F(x, "contractExpiryAlertDays") },
        { name: "certExpiryAlertDays", label: "Certification expiry alert (days)", type: "number", min: 0, value: F(x, "certExpiryAlertDays") },
        { name: "reviewLeadDays", label: "Raise the review this many days before", type: "number", min: 0, value: F(x, "reviewLeadDays") },
        { name: "reassessmentTriggerCodes", label: "Triggers that require reassessment (REVIEW_TRIGGER codes)", maxLength: 600, value: F(x, "reassessmentTriggerCodes") },
        { name: "monitoringNote", label: "Monitoring note", type: "textarea", rows: 2, maxLength: 1000, value: F(x, "monitoringNote") }]),
      ...(x && !state.baseline && F(x, "origin") !== "ORGANIZATION" || (x && F(x, "origin") === "GRAC_OVERRIDDEN")
        ? [{ name: "isHidden", label: "Hide this GRAC rule for the organization", type: "checkbox", value: F(x, "isHidden") }]
        : [{ name: "status", label: "Status", type: "select", blank: false, value: F(x, "status") || "Active", options: [{ value: "Active", label: "Active" }, { value: "Retired", label: "Retired" }] }])
    ];
    const res = await T.form({ title: x ? (overridingBaseline ? `Change GRAC rule ${F(x, "ruleCode")} for this organization` : `Edit ${F(x, "ruleCode")}`) : `Add ${kind} rule`, wide: true, fields,
      onSubmit: v => api("POST", `/config/rules/${kind}`, scopeBody({
        ruleId: x && !overridingBaseline ? F(x, "ruleId") : null,
        baselineRuleId: overridingBaseline ? F(x, "ruleId") : (x ? F(x, "baselineRuleId") : null),
        ...v, ruleCode: v.ruleCode || F(x, "ruleCode"),
        sodRequired: v.sodRequired, escalateToRiskCentre: v.escalateToRiskCentre, isHidden: v.isHidden })) });
    if (res) { show("cfMessage", "Saved.", "success"); await render(); }
  }

  // ------------------------------------------------------------------ custom fields
  async function renderFields(panel) {
    if (state.baseline) { panel.innerHTML = `<p class="tprm-note">Custom fields belong to an organization. Switch to the organization configuration.</p>`; return; }
    const r = await api("GET", `/config/custom-fields?${qs({ organizationId: state.org, entityCode: state.entity, activeOnly: "false" })}`);
    if (!r.ok) { panel.innerHTML = `<p class="pm-message">${esc(r.error)}</p>`; return; }
    state.data.fields = r.data.data || [];
    panel.innerHTML = `
      <div class="pm-toolbar">${picker("entity", ENTITIES, state.entity)}${CAN_CHANGE ? btn("field-add", "fa-plus", "Add field") : ""}</div>
      <p class="tprm-note">Fields the organization adds to vendors, engagements, findings and reviews. Mandatory fields are enforced on save; access by role limits who can change a field.</p>
      <div class="pm-table-wrap"><table><thead><tr><th>Field</th><th>Type</th><th>Rules</th><th>Visible when</th><th>Use</th><th>Status</th><th></th></tr></thead><tbody>${
        state.data.fields.map(f => `<tr class="${F(f, "status") !== "Active" ? "cf-hidden-row" : ""}"><td>${esc(F(f, "fieldCode"))} ${esc(F(f, "label"))}</td>
          <td>${esc(F(f, "dataType"))}${F(f, "referenceKind") ? ` (${esc(F(f, "referenceKind"))})` : ""}</td>
          <td class="tprm-muted">${esc([yes(F(f, "isMandatory")) && "mandatory", F(f, "defaultValue") && `default ${F(f, "defaultValue")}`, F(f, "validationRegex") && "pattern",
              F(f, "minValue") != null && `min ${F(f, "minValue")}`, F(f, "maxValue") != null && `max ${F(f, "maxValue")}`, F(f, "accessRoleNames") && `roles: ${F(f, "accessRoleNames")}`].filter(Boolean).join(", "))}</td>
          <td class="tprm-muted">${F(f, "visibleWhenFieldCode") ? `${esc(F(f, "visibleWhenFieldCode"))} = ${esc(F(f, "visibleWhenValue") || "")}` : ""}</td>
          <td class="tprm-muted">${esc([yes(F(f, "isSearchable")) && "search", yes(F(f, "isFilterable")) && "filter", yes(F(f, "isReportable")) && "report"].filter(Boolean).join(", "))}</td>
          <td>${esc(F(f, "status"))}</td><td>${CAN_CHANGE ? btn("field-edit", "fa-pen", "", { id: F(f, "fieldId") }) : ""}</td></tr>`).join("") || empty(7, "No custom fields.")}</tbody></table></div>`;
  }
  async function editField(id) {
    const f = id ? state.data.fields.find(x => String(F(x, "fieldId")) === String(id)) : null;
    const optionLines = (() => { try { return (JSON.parse(F(f, "optionsJson") || "[]")).map(o => `${o.code} | ${o.label || o.code}`).join("\n"); } catch (_) { return ""; } })();
    const res = await T.form({ title: f ? `Edit field ${F(f, "fieldCode")}` : "Add custom field", wide: true,
      fields: [
        { name: "fieldCode", label: "Code", required: true, maxLength: 60, value: F(f, "fieldCode"), readonly: !!f },
        { name: "label", label: "Label", required: true, maxLength: 200, value: F(f, "label") },
        { name: "dataType", label: "Type", type: "select", options: DATA_TYPES, required: true, value: F(f, "dataType") || "TEXT", readonly: !!f },
        { name: "referenceKind", label: "Reference to (REFERENCE type)", type: "select", value: F(f, "referenceKind"),
          // 521: VENDOR (the legacy GRAC vendor) removed; THIRD_PARTY = a Vendor Registry vendor
          options: [{ value: "EMPLOYEE", label: "Employee" }, { value: "THIRD_PARTY", label: "Vendor (Vendor Registry)" },
                    { value: "BUSINESS_FUNCTION", label: "Business function" }] },
        { name: "options", label: "Options (select types) -- one per line: code | label", type: "textarea", rows: 3, value: optionLines },
        { name: "description", label: "Help text", type: "textarea", rows: 2, maxLength: 1000, value: F(f, "description") },
        { name: "isMandatory", label: "Mandatory", type: "checkbox", value: F(f, "isMandatory") },
        { name: "defaultValue", label: "Default value", maxLength: 500, value: F(f, "defaultValue") },
        { name: "validationRegex", label: "Validation pattern (regular expression)", maxLength: 300, value: F(f, "validationRegex") },
        { name: "maxLength", label: "Maximum length", type: "number", min: 1, value: F(f, "maxLength") },
        { name: "minValue", label: "Minimum (number)", type: "number", step: "any", value: F(f, "minValue") },
        { name: "maxValue", label: "Maximum (number)", type: "number", step: "any", value: F(f, "maxValue") },
        { name: "visibleWhenFieldCode", label: "Visible when field (code)", maxLength: 60, value: F(f, "visibleWhenFieldCode") },
        { name: "visibleWhenValue", label: "has value", maxLength: 200, value: F(f, "visibleWhenValue") },
        { name: "accessRoleNames", label: "Only these roles may change it (comma separated, empty = everyone)", maxLength: 600, value: F(f, "accessRoleNames") },
        { name: "isSearchable", label: "Searchable", type: "checkbox", value: F(f, "isSearchable") },
        { name: "isFilterable", label: "Filterable", type: "checkbox", value: F(f, "isFilterable") },
        { name: "isReportable", label: "Reportable", type: "checkbox", value: F(f, "isReportable") },
        { name: "displayOrder", label: "Order", type: "number", value: F(f, "displayOrder") ?? 100 },
        { name: "status", label: "Status", type: "select", blank: false, value: F(f, "status") || "Active", options: [{ value: "Active", label: "Active" }, { value: "Retired", label: "Retired" }] }],
      onSubmit: v => {
        const body = { ...v, organizationId: state.org, fieldId: f ? F(f, "fieldId") : null, entityCode: state.entity, fieldCode: v.fieldCode || F(f, "fieldCode"),
          dataType: v.dataType || F(f, "dataType"),
          optionsJson: v.options ? JSON.stringify(lines(v.options).map(([code, label]) => ({ code, label: label || code }))) : null };
        delete body.options;
        return api("POST", "/config/custom-fields", body);
      } });
    if (res) { show("cfMessage", "Saved.", "success"); T.lookups(state.org, true); await render(); }
  }

  // ------------------------------------------------------------------ actions
  async function act(name, d) {
    const done = async (r, message, after) => {
      if (!r.ok) { show(document.getElementById("cfVersionModal").hidden ? "cfMessage" : "cfVersionMessage", r.error); return false; }
      show("cfMessage", message, "success");
      if (after) await after();
      return true;
    };
    switch (name) {
      case "value-add": return editValue(null);
      case "value-edit": return editValue(d);
      case "item-add": return editItem(null);
      case "item-edit": return editItem(d);
      case "rule-add": return editRule({ kind: d.kind });
      case "rule-edit": return editRule(d);
      case "field-add": return editField(null);
      case "field-edit": return editField(d.id);
      case "delegation-add": {
        const emp = state.lk ? state.lk.employeeOptions() : [];
        const res = await T.form({ title: "Delegate approval", submitText: "Delegate", fields: [
          { name: "fromEmployeeId", label: "Approver", type: "select", options: emp, required: true },
          { name: "toEmployeeId", label: "Delegate", type: "select", options: emp, required: true },
          { name: "validFrom", label: "From", type: "date", required: true }, { name: "validTo", label: "To", type: "date", required: true },
          { name: "reason", label: "Reason", type: "textarea", rows: 2, maxLength: 500 }],
          onSubmit: v => api("POST", "/config/delegations", { organizationId: state.org, ...v, fromEmployeeId: Number(v.fromEmployeeId), toEmployeeId: Number(v.toEmployeeId) }) });
        if (res) { show("cfMessage", "Delegation saved.", "success"); await render(); }
        return;
      }
      case "delegation-revoke":
        if (!await T.confirm("Revoke this delegation?", "Revoke delegation", "Revoke")) return;
        return done(await api("POST", "/config/delegations", { organizationId: state.org, delegationId: Number(d.id), revoke: true }), "Delegation revoked.", render);
      case "template-create": {
        const res = await T.form({ title: "New template", submitText: "Create", fields: [
          { name: "templateKind", label: "Kind", type: "select", required: true, options: [{ value: "RISK_MODEL", label: "Risk model" }, { value: "QUESTIONNAIRE", label: "Questionnaire" }] },
          { name: "templateCode", label: "Code", required: true, maxLength: 60 }, { name: "templateName", label: "Name", required: true, maxLength: 250 },
          { name: "description", label: "Description", type: "textarea", rows: 2, maxLength: 2000 },
          { name: "copyFromVersionId", label: "Start from (copy of)", type: "select",
            options: (state.data.templates || []).filter(t => F(t, "currentVersionId")).map(t => ({ value: F(t, "currentVersionId"), label: `${F(t, "templateName")} v${F(t, "currentVersionNo")}` })) }],
          onSubmit: v => api("POST", "/config/templates", scopeBody({ ...v, copyFromVersionId: v.copyFromVersionId ? Number(v.copyFromVersionId) : null })) });
        if (res) { await render(); openVersion(F(res.result.data.result, "versionId")); }
        return;
      }
      case "template-adopt": {
        if (!await T.confirm("Copy this GRAC template into the organization as a Draft? It takes effect when activated; until then the version in force stays.", "Adopt template", "Adopt")) return;
        const r = await api("POST", `/config/templates/${d.id}/adopt`, { organizationId: state.org });
        if (await done(r, "Adopted as a Draft.", render)) openVersion(F(r.data.result, "versionId"));
        return;
      }
      case "template-new-version": {
        const r = await api("POST", `/config/templates/${d.id}/new-version`, scopeBody());
        if (await done(r, "Draft version created.", render)) openVersion(F(r.data.result, "versionId"));
        return;
      }
      case "template-retire": {
        const restore = d.restore === "1";
        if (!await T.confirm(restore ? "Restore this template?" : "Retire this template? It is no longer used for new assessments; completed ones keep their version.", restore ? "Restore" : "Retire", restore ? "Restore" : "Retire")) return;
        return done(await api("POST", `/config/templates/${d.id}/retire`, scopeBody({ restore })), restore ? "Restored." : "Retired.", render);
      }
      case "template-compare": {
        const opts = [];
        for (const t of state.data.templates || []) {
          if (F(t, "currentVersionId")) opts.push({ value: F(t, "currentVersionId"), label: `${F(t, "templateName")} v${F(t, "currentVersionNo")} (in force)` });
          if (F(t, "draftVersionId")) opts.push({ value: F(t, "draftVersionId"), label: `${F(t, "templateName")} v${F(t, "draftVersionNo")} (draft)` });
        }
        const v = await T.form({ title: "Compare two versions", submitText: "Compare", fields: [
          { name: "versionA", label: "Version A", type: "select", options: opts, required: true }, { name: "versionB", label: "Version B", type: "select", options: opts, required: true }] });
        if (!v) return;
        const r = await api("GET", `/config/templates/compare?${scopeQs({ versionA: v.versionA, versionB: v.versionB })}`);
        if (!r.ok) { show("cfMessage", r.error); return; }
        const rows = r.data.data || [];
        await T.form({ title: "Differences", submitText: "Close", wide: true, fields: [{ type: "note", name: "_n", html: true, label:
          `<div class="pm-table-wrap"><table><thead><tr><th>Item</th><th>Change</th><th>A</th><th>B</th></tr></thead><tbody>${
            rows.map(x => `<tr><td>${esc(F(x, "itemType"))} ${esc(F(x, "itemCode"))}<div class="tprm-muted">${esc(F(x, "itemName") || "")}</div></td><td>${esc(F(x, "changeKind"))}</td>
              <td class="tprm-muted">${esc(F(x, "valueA") || "")}</td><td class="tprm-muted">${esc(F(x, "valueB") || "")}</td></tr>`).join("") || empty(4, "No differences.")}</tbody></table></div>` }] });
        return;
      }
      case "version-open": return openVersion(Number(d.id));
      case "version-header": {
        const h = state.version.header[0];
        const rm = F(h, "templateKind") === "RISK_MODEL";
        const res = await T.form({ title: "Version settings", wide: true, fields: [
          { name: "templateName", label: "Name", maxLength: 250, value: F(h, "templateName") },
          { name: "description", label: "Description", type: "textarea", rows: 2, value: F(h, "description") },
          { name: "changeSummary", label: "What changed in this version", type: "textarea", rows: 2, value: F(h, "changeSummary") },
          { name: "isDefault", label: "Default of its kind", type: "checkbox", value: F(h, "isDefault") },
          ...(rm ? [
            { name: "aggregationMethod", label: "Overall score", type: "select", blank: false, value: F(h, "aggregationMethod"),
              options: [{ value: "WEIGHTED_AVERAGE", label: "Weighted average" }, { value: "HIGHEST_DIMENSION", label: "Highest dimension" }, { value: "BLENDED", label: "Blend of both" }] },
            { name: "blendPct", label: "Blend: % highest dimension", type: "number", min: 0, max: 100, value: F(h, "blendPct") },
            { name: "effectiveReductionPct", label: "Reduction of a verified effective safeguard %", type: "number", min: 0, max: 100, value: F(h, "effectiveReductionPct") },
            { name: "partialReductionPct", label: "Reduction of a verified partially effective safeguard %", type: "number", min: 0, max: 100, value: F(h, "partialReductionPct") },
            { name: "residualFloorPct", label: "Residual never below % of inherent", type: "number", min: 0, max: 100, value: F(h, "residualFloorPct") },
            { name: "deficiencyUpliftPct", label: "Uplift per open high deficiency %", type: "number", min: 0, max: 100, value: F(h, "deficiencyUpliftPct") }]
          : [
            { name: "isCore", label: "Core (applies to every engagement)", type: "checkbox", value: F(h, "isCore") },
            { name: "appliesServiceCategories", label: "Service categories (codes, comma separated)", maxLength: 1000, value: F(h, "appliesServiceCategories") },
            { name: "appliesMinTierRank", label: "Due-diligence tier rank at least", type: "number", min: 1, value: F(h, "appliesMinTierRank") },
            { name: "appliesEngagementTypes", label: "Engagement types (codes)", maxLength: 600, value: F(h, "appliesEngagementTypes") }])],
          onSubmit: v => api("POST", `/config/templates/versions/${F(h, "versionId")}/header`, scopeBody({ ...v, isDefault: !!v.isDefault, isCore: v.isCore })) });
        if (res) await openVersion(F(h, "versionId"));
        return;
      }
      case "version-activate": {
        const h = state.version.header[0];
        const summary = await T.note("What changed in this version? It is recorded with the version.", "Activate version", "Activate");
        if (summary === null) return;
        const r = await api("POST", `/config/templates/versions/${F(h, "versionId")}/activate`, scopeBody({ changeSummary: summary }));
        if (await done(r, "Version activated. It is in force from now on; assessments already made keep their version.", render)) await openVersion(F(h, "versionId"));
        return;
      }
      case "version-discard": {
        const h = state.version.header[0];
        if (!await T.confirm("Discard this draft?", "Discard draft", "Discard")) return;
        if (await done(await api("POST", `/config/templates/versions/${F(h, "versionId")}/activate`, scopeBody({ discard: true })), "Draft discarded.", render))
          document.getElementById("cfVersionModal").hidden = true;
        return;
      }
      case "item-add-v": return editVersionItem(d.type, null);
      case "item-edit-v": return editVersionItem(d.type, d.id);
      case "item-remove-v": {
        if (!await T.confirm("Remove this item from the draft?", "Remove", "Remove")) return;
        const vid = F(state.version.header[0], "versionId");
        if (await done(await api("POST", `/config/templates/versions/${vid}/items/remove`, scopeBody({ itemType: d.type, itemId: Number(d.id) })), "Removed.")) await openVersion(vid);
        return;
      }
      default: return;
    }
  }
})();
