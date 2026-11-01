// =====================================================================
// Third Parties (migrations 486-490). Loaded by tprm-third-parties.cshtml.
// Backend: practice/api/tprm (TprmController -> sp_tprm_*)
//   GET  third-parties?organizationId&search&statusCode&serviceCategoryCode
//        &includeArchived&sample&pageNumber&pageSize        grid
//   GET  third-parties/{id}?organizationId                  detail (7 sets)
//   POST third-parties             { organizationId, thirdPartyId?, ... }
//        409 = possible duplicates (nothing saved) -> confirmDuplicates
//   POST third-parties/{id}/status { organizationId, statusCode?, archive?, reason }
//   GET  vendors?organizationId&search&onlyUnlinked         GRAC vendors
//   POST vendors/{vendorId}/import { organizationId, thirdPartyId?, createEngagement, confirmDuplicates }
//   POST samples/load              { organizationId }
// The procedures decide every rule; the buttons only mirror the screen
// permissions (data-can-*).
// =====================================================================
(() => {
  "use strict";

  const T = window.gracTprm;
  const root = document.getElementById("tpRoot");
  if (!root || !T) return;
  const { F, esc, date, empty, info, show, hide, api, qs } = T;
  const CAN_ADD = root.dataset.canAdd === "1";
  const CAN_EDIT = root.dataset.canEdit === "1";
  const state = { org: null, lk: null, pager: null, detail: null };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    state.pager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "tpPager", onChange: refreshList }) : null;
    bind();
    await changeOrg(await T.orgs("tpOrg"));
    const id = Number(new URLSearchParams(window.location.search).get("thirdPartyId"));
    if (id > 0 && state.org) openDetail(id);
  }

  function bind() {
    document.getElementById("tpOrg").addEventListener("change", e => changeOrg(Number(e.target.value) || null));
    document.getElementById("tpRefresh").addEventListener("click", () => refreshList());
    let t = null;
    document.getElementById("tpSearch").addEventListener("input", () => { clearTimeout(t); t = setTimeout(() => { state.pager?.reset(true); refreshList(); }, 300); });
    ["tpStatusFilter", "tpCategoryFilter", "tpSampleFilter", "tpArchived"].forEach(id =>
      document.getElementById(id).addEventListener("change", () => { state.pager?.reset(true); refreshList(); }));
    document.getElementById("tpNew")?.addEventListener("click", () => editThirdParty(null));
    document.getElementById("tpImport")?.addEventListener("click", openVendors);
    document.getElementById("tpSamples")?.addEventListener("click", loadSamples);
    document.getElementById("tpListBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-tp-row]");
      if (tr) openDetail(Number(tr.dataset.tpRow));
    });
    document.querySelectorAll("[data-close-tp]").forEach(b => b.addEventListener("click", () => { document.getElementById(b.dataset.closeTp).hidden = true; }));
    document.querySelectorAll("[data-tp-tab]").forEach(b => b.addEventListener("click", () => selectTab(b.dataset.tpTab)));
    document.getElementById("tpDetailActions").addEventListener("click", ev => {
      const b = ev.target.closest("[data-tp-action]");
      if (b) detailAction(b.dataset.tpAction);
    });
    let vt = null;
    document.getElementById("tpVendorSearch").addEventListener("input", () => { clearTimeout(vt); vt = setTimeout(loadVendors, 300); });
    document.getElementById("tpVendorUnlinked").addEventListener("change", loadVendors);
    document.getElementById("tpVendorBody").addEventListener("click", ev => {
      const b = ev.target.closest("[data-vendor-import]");
      if (b) importVendor(Number(b.dataset.vendorImport), b.dataset.mode);
    });
  }

  async function changeOrg(id) {
    state.org = id;
    hide("tpMessage");
    state.pager?.reset(true);
    state.lk = await T.lookups(id);
    if (state.lk.error) show("tpMessage", state.lk.error);
    fill("tpStatusFilter", state.lk.options("TP_STATUS"), "All statuses");
    fill("tpCategoryFilter", state.lk.options("SERVICE_CATEGORY"), "All service categories");
    await refreshList();
  }

  function fill(id, options, blank) {
    const sel = document.getElementById(id);
    const keep = sel.value;
    sel.length = 0;
    sel.add(new Option(blank, ""));
    options.forEach(o => sel.add(new Option(o.label, o.value)));
    if ([...sel.options].some(o => o.value === keep)) sel.value = keep;
  }

  // ------------------------------------------------------------------ grid
  async function refreshList() {
    const body = document.getElementById("tpListBody");
    if (!state.org) { body.innerHTML = empty(8, "Select an organization."); state.pager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const res = await api("GET", `/third-parties?${qs({
      organizationId: state.org, search: val("tpSearch"), statusCode: val("tpStatusFilter"),
      serviceCategoryCode: val("tpCategoryFilter"), sample: val("tpSampleFilter"),
      includeArchived: document.getElementById("tpArchived").checked ? "true" : "",
      pageNumber: state.pager ? state.pager.page() : 1, pageSize: state.pager ? state.pager.size() : 25 })}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.pager?.clear(); return; }
    const rows = res.data.data || [];
    state.pager?.setTotal(res.data.totalRows, rows.length);
    body.innerHTML = rows.map(r => `<tr data-tp-row="${esc(F(r, "thirdPartyId"))}">
        <td>${esc(F(r, "thirdPartyCode"))}${T.yes(F(r, "isSample")) ? ' <span class="pm-badge tprm-sample">Sample</span>' : ""}</td>
        <td>${esc(F(r, "legalName"))}${F(r, "tradingName") ? `<div class="tprm-muted">${esc(F(r, "tradingName"))}</div>` : ""}${F(r, "vendorName") ? `<div class="tprm-muted">Vendor: ${esc(F(r, "vendorName"))}</div>` : ""}</td>
        <td>${esc(F(r, "providerType") || "--")}</td>
        <td>${esc(F(r, "serviceCategory") || "--")}</td>
        <td>${T.badge(F(r, "statusLabel") || F(r, "statusCode"), F(r, "statusColor"))}${F(r, "recordStatus") === "Archived" ? ' <span class="pm-badge">Archived</span>' : ""}</td>
        <td>${esc(F(r, "engagementCount") ?? 0)}<div class="tprm-muted">${esc(F(r, "activeEngagementCount") ?? 0)} active, ${esc(F(r, "inAssessmentCount") ?? 0)} in assessment</div></td>
        <td>${F(r, "highestResidualScore") != null ? `Residual ${esc(Number(F(r, "highestResidualScore")).toFixed(1))}`
              : F(r, "highestInherentScore") != null ? `Inherent ${esc(Number(F(r, "highestInherentScore")).toFixed(1))}` : '<span class="tprm-muted">Not assessed</span>'}</td>
        <td>${esc(F(r, "relationshipOwnerName") || "--")}</td>
      </tr>`).join("") || empty(8, "No third parties yet. Register one, import GRAC vendors, or load the sample records.");
  }

  // ------------------------------------------------------------------ detail
  async function openDetail(id) {
    const res = await api("GET", `/third-parties/${id}?${qs({ organizationId: state.org })}`);
    if (!res.ok) { show("tpMessage", res.error); return; }
    state.detail = res.data;
    render();
    hide("tpDetailMessage");
    document.getElementById("tpDetailModal").hidden = false;
    selectTab("ENG");
  }
  async function reloadDetail() {
    const h = head();
    if (!h) return;
    const res = await api("GET", `/third-parties/${F(h, "thirdPartyId")}?${qs({ organizationId: state.org })}`);
    if (res.ok) { state.detail = res.data; render(); }
  }
  const head = () => (state.detail?.header || [])[0];

  function render() {
    const h = head();
    const d = state.detail;
    document.getElementById("tpDetailTitle").textContent = `${F(h, "thirdPartyCode")} - ${F(h, "legalName")}`;
    const cats = (d.categories || []).map(c => F(c, "label")).join(", ");
    document.getElementById("tpDetailInfo").innerHTML = info([
      ["Status", T.badge(F(h, "statusLabel") || F(h, "statusCode"), F(h, "statusColor"))
        + (F(h, "recordStatus") === "Archived" ? ' <span class="pm-badge">Archived</span>' : "")
        + (T.yes(F(h, "isSample")) ? ' <span class="pm-badge tprm-sample">Sample record</span>' : ""), true],
      ["Trading name", F(h, "tradingName")],
      ["Provider type", F(h, "providerType")],
      ["Service categories", cats || F(h, "serviceCategory")],
      ["Registration number", F(h, "registrationNumber")],
      ["Tax ID", F(h, "taxId")],
      ["LEI", F(h, "leiCode")],
      ["Country", [F(h, "city"), F(h, "stateRegion"), F(h, "country")].filter(Boolean).join(", ")],
      ["Relationship owner", F(h, "relationshipOwnerName")],
      ["GRAC vendor", F(h, "vendorName")],
      ["Reporting category", F(h, "reportingCategory")]
    ]);
    const archived = F(h, "recordStatus") === "Archived";
    const b = [];
    if (CAN_EDIT && !archived) {
      b.push(`<button type="button" class="pm-button" data-tp-action="EDIT"><i class="fa-solid fa-pen"></i> Edit</button>`);
      b.push(`<button type="button" class="pm-button" data-tp-action="STATUS"><i class="fa-solid fa-flag"></i> Change status</button>`);
      b.push(`<button type="button" class="pm-button" data-tp-action="ARCHIVE"><i class="fa-solid fa-box-archive"></i> Archive</button>`);
    }
    if (CAN_EDIT && archived)
      b.push(`<button type="button" class="pm-button" data-tp-action="RESTORE"><i class="fa-solid fa-rotate-left"></i> Restore</button>`);
    if (!archived)
      b.push(`<a class="pm-button primary" href="${esc(T.U("/Practice/Index/tprm-engagements") + "?" + qs({ organizationId: state.org, newForThirdParty: F(h, "thirdPartyId") }))}"><i class="fa-solid fa-plus"></i> New engagement</a>`);
    document.getElementById("tpDetailActions").innerHTML = b.join("");

    const engHref = id => T.U("/Practice/Index/tprm-engagements") + "?" + qs({ organizationId: state.org, engagementId: id });
    document.getElementById("tpEngBody").innerHTML = (d.engagements || []).map(e => `<tr>
        <td><a href="${esc(engHref(F(e, "engagementId")))}">${esc(F(e, "engagementCode"))}</a> ${esc(F(e, "engagementTitle"))}</td>
        <td>${esc(T.stageLabel(F(e, "stageCode")))}</td>
        <td>${state.lk.badge("CRITICALITY", F(e, "criticalityCode")) || "--"}</td>
        <td>${F(e, "inherentScore") != null ? esc(Number(F(e, "inherentScore")).toFixed(1)) + " " + esc(F(e, "inherentBandCode") || "") : "--"}</td>
        <td>${F(e, "residualScore") != null ? esc(Number(F(e, "residualScore")).toFixed(1)) + " " + esc(F(e, "residualBandCode") || "") : "--"}</td>
        <td>${esc(state.lk.label("DD_TIER", F(e, "ddTierCode")) || "--")}</td>
        <td>${esc(date(F(e, "nextReviewDt")) || "--")}</td>
        <td>${esc(F(e, "businessOwnerName") || "--")}</td>
      </tr>`).join("") || empty(8, "No engagements yet.");
    document.getElementById("tpContactBody").innerHTML = (d.contacts || []).map(c => `<tr>
        <td>${esc(F(c, "contactName"))}</td><td>${esc(F(c, "contactRole") || "--")}</td><td>${esc(F(c, "email") || "--")}</td>
        <td>${esc(F(c, "phone") || "--")}</td><td>${T.yes(F(c, "isPrimary")) ? "Yes" : ""}</td></tr>`).join("") || empty(5, "No contacts.");
    document.getElementById("tpProfileInfo").innerHTML = info([
      ["Address", F(h, "address")], ["Website", F(h, "website")], ["Parent company", F(h, "parentCompany")],
      ["Year established", F(h, "yearEstablished")], ["Employees", F(h, "employeeCountBand")], ["Annual revenue", F(h, "annualRevenueBand")],
      ["Certifications", F(h, "certificationsText")], ["Notes", F(h, "profileNotes")],
      ...(d.customValues || []).map(c => [F(c, "label"), F(c, "value")]),
      ["Registered", `${T.dateTime(F(h, "enteredDt"))} by ${F(h, "enteredBy") || ""}`],
      ["Updated", F(h, "updatedDt") ? `${T.dateTime(F(h, "updatedDt"))} by ${F(h, "updatedBy") || ""}` : ""]
    ]);
    document.getElementById("tpHistoryBody").innerHTML = (d.history || []).map(x => `<tr>
        <td>${esc(T.dateTime(F(x, "changedDt")))}</td><td>${esc(state.lk.label("TP_STATUS", F(x, "fromStatusCode")) || "--")}</td>
        <td>${esc(state.lk.label("TP_STATUS", F(x, "toStatusCode")))}</td>
        <td>${esc(F(x, "reason") || "")}${T.yes(F(x, "isAutomatic")) ? ' <span class="tprm-muted">(from an engagement)</span>' : ""}</td>
        <td>${esc(F(x, "actorName") || F(x, "actor") || "")}</td></tr>`).join("") || empty(5, "No status changes.");
  }

  function selectTab(name) {
    document.querySelectorAll("[data-tp-tab]").forEach(x => { const on = x.dataset.tpTab === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    document.querySelectorAll("[data-tp-panel]").forEach(p => { p.hidden = p.dataset.tpPanel !== name; });
  }

  async function detailAction(action) {
    const h = head();
    if (action === "EDIT") { editThirdParty(state.detail); return; }
    const id = F(h, "thirdPartyId");
    let body = null;
    if (action === "STATUS") {
      const r = await T.form({
        title: "Change lifecycle status", submitText: "Change status",
        intro: "Statuses that follow the engagements (under assessment, approved, active ...) are also set automatically when an engagement moves.",
        fields: [
          { name: "statusCode", label: "Status", type: "select", options: state.lk.options("TP_STATUS"), value: F(h, "statusCode"), required: true },
          { name: "reason", label: "Reason", type: "textarea", required: true, maxLength: 1000 }
        ]
      });
      if (!r) return;
      body = { statusCode: r.statusCode, reason: r.reason };
    } else if (action === "ARCHIVE" || action === "RESTORE") {
      const reason = await T.note(action === "ARCHIVE"
        ? "Archive this third party? An archived third party is hidden from lists and cannot start engagements. Give the reason."
        : "Restore this third party? Give the reason.", action === "ARCHIVE" ? "Archive third party" : "Restore third party", action === "ARCHIVE" ? "Archive" : "Restore");
      if (reason === null) return;
      body = { archive: action === "ARCHIVE", reason };
    } else return;
    const res = await api("POST", `/third-parties/${id}/status`, { organizationId: state.org, ...body });
    if (!res.ok) { show("tpDetailMessage", res.error); return; }
    await reloadDetail();
    show("tpDetailMessage", "Saved.", "success");
    await refreshList();
  }

  // ------------------------------------------------------------------ register / edit
  // detail = the loaded third party (edit) or null (new).
  async function editThirdParty(detail, prefill) {
    const lk = state.lk;
    const h = detail ? (detail.header || [])[0] : (prefill || {});
    const contacts = detail ? (detail.contacts || []) : [];
    const cats = detail ? (detail.categories || []).map(c => F(c, "serviceCategoryCode")) : [];
    const contactLines = contacts.map(c => [F(c, "contactName"), F(c, "contactRole"), F(c, "email"), F(c, "phone"), T.yes(F(c, "isPrimary")) ? "primary" : ""].join(" | ")).join("\n");
    const fields = [
      { type: "section", label: "Identity", name: "_id" },
      { name: "legalName", label: "Legal name", required: true, maxLength: 250, value: F(h, "legalName") },
      { name: "tradingName", label: "Trading name", maxLength: 250, value: F(h, "tradingName") },
      { name: "registrationNumber", label: "Registration number", maxLength: 100, value: F(h, "registrationNumber") },
      { name: "taxId", label: "Tax ID", maxLength: 100, value: F(h, "taxId") },
      { name: "leiCode", label: "LEI", maxLength: 40, value: F(h, "leiCode") },
      { name: "providerTypeCode", label: "Provider type", type: "select", options: lk.options("PROVIDER_TYPE"), value: F(h, "providerTypeCode") },
      { type: "section", label: "Services", name: "_svc" },
      { name: "primaryServiceCategoryCode", label: "Primary service category", type: "select", options: lk.options("SERVICE_CATEGORY"), value: F(h, "serviceCategoryCode"), required: true },
      { name: "reportingCategoryCode", label: "Reporting category", type: "select", options: lk.options("REPORTING_CATEGORY"), value: F(h, "reportingCategoryCode") },
      { name: "categories", label: "Other service categories", type: "multi", options: lk.options("SERVICE_CATEGORY"), value: cats },
      { name: "relationshipOwnerEmployeeId", label: "Relationship owner", type: "select", options: lk.employeeOptions(), value: F(h, "relationshipOwnerEmployeeId") },
      { type: "section", label: "Location and profile", name: "_loc" },
      { name: "country", label: "Country", maxLength: 120, value: F(h, "country") },
      { name: "stateRegion", label: "State / region", maxLength: 120, value: F(h, "stateRegion") },
      { name: "city", label: "City", maxLength: 120, value: F(h, "city") },
      { name: "website", label: "Website", maxLength: 300, value: F(h, "website") },
      { name: "address", label: "Address", type: "textarea", rows: 2, maxLength: 1000, value: F(h, "address") },
      { name: "parentCompany", label: "Parent company", maxLength: 250, value: F(h, "parentCompany") },
      { name: "yearEstablished", label: "Year established", type: "number", min: 1800, max: 2100, value: F(h, "yearEstablished") },
      { name: "employeeCountBand", label: "Employees (band)", maxLength: 60, value: F(h, "employeeCountBand") },
      { name: "annualRevenueBand", label: "Annual revenue (band)", maxLength: 60, value: F(h, "annualRevenueBand") },
      { name: "certificationsText", label: "Certifications held", type: "textarea", rows: 2, maxLength: 1000, value: F(h, "certificationsText"),
        help: "As stated by the third party. A certification counts only when it is evidenced and verified in due diligence." },
      { name: "profileNotes", label: "Notes", type: "textarea", rows: 2, value: F(h, "profileNotes") },
      { type: "section", label: "Contacts", name: "_ct" },
      { name: "contacts", label: "Contacts -- one per line: name | role | email | phone | primary", type: "textarea", rows: 4, value: contactLines },
      ...T.customFields(lk, "THIRD_PARTY", detail ? detail.customValues : []),
      { name: "confirmDuplicates", label: "Register anyway if possible duplicates are found", type: "checkbox", value: false }
    ];
    const res = await T.form({
      title: detail ? `Edit ${F(h, "thirdPartyCode")}` : "New third party", wide: true, submitText: detail ? "Save" : "Register",
      intro: detail ? "" : "Possible duplicates (same identifier or name, or a GRAC vendor of that name) are checked before anything is saved.",
      fields,
      validate: v => contactsJson(v.contacts) === false ? "Each contact line needs at least a name." : null,
      onSubmit: async v => {
        const body = {
          organizationId: state.org,
          thirdPartyId: detail ? F(h, "thirdPartyId") : null,
          legalName: v.legalName, tradingName: v.tradingName, registrationNumber: v.registrationNumber, taxId: v.taxId, leiCode: v.leiCode,
          providerTypeCode: v.providerTypeCode, primaryServiceCategoryCode: v.primaryServiceCategoryCode,
          categoriesCsv: (v.categories || []).join(",") || null, reportingCategoryCode: v.reportingCategoryCode,
          country: v.country, stateRegion: v.stateRegion, city: v.city, address: v.address, website: v.website,
          parentCompany: v.parentCompany, yearEstablished: v.yearEstablished, employeeCountBand: v.employeeCountBand,
          annualRevenueBand: v.annualRevenueBand, certificationsText: v.certificationsText, profileNotes: v.profileNotes,
          relationshipOwnerEmployeeId: v.relationshipOwnerEmployeeId ? Number(v.relationshipOwnerEmployeeId) : null,
          contactsJson: contactsJson(v.contacts) || "[]",
          customJson: T.customJson(v),
          confirmDuplicates: !!v.confirmDuplicates,
          expectedRecordVersion: detail ? F(h, "recordVersion") : null
        };
        const r = await api("POST", "/third-parties", body);
        if (r.status === 409 && r.data.duplicate)
          return { ok: false, extraHtml: T.duplicatesHtml(r.data, "Tick \"Register anyway\" and save again to register it as a separate third party.") };
        return r.ok ? { ok: true, id: F(r.data.result, "thirdPartyId") } : r;
      }
    });
    if (!res) return;
    show("tpMessage", detail ? "Third party saved." : "Third party registered.", "success");
    await refreshList();
    if (detail) await reloadDetail(); else if (res.result.id) openDetail(res.result.id);
  }

  // "name | role | email | phone | primary" lines -> contacts_json; false
  // when a line has no name.
  function contactsJson(text) {
    const lines = String(text || "").split("\n").map(l => l.trim()).filter(Boolean);
    const out = [];
    for (const line of lines) {
      const [name, role, email, phone, primary] = line.split("|").map(x => (x || "").trim());
      if (!name) return false;
      out.push({ contactId: null, name, role: role || null, email: email || null, phone: phone || null, isPrimary: /^(primary|yes|y|1|true)$/i.test(primary || "") });
    }
    return JSON.stringify(out);
  }

  // ------------------------------------------------------------------ vendors (GRAC Dependencies)
  async function openVendors() {
    if (!state.org) { show("tpMessage", "Select an organization."); return; }
    hide("tpVendorMessage");
    document.getElementById("tpVendorModal").hidden = false;
    await loadVendors();
  }
  async function loadVendors() {
    const body = document.getElementById("tpVendorBody");
    body.innerHTML = empty(7, "Loading...");
    const res = await api("GET", `/vendors?${qs({ organizationId: state.org, search: val("tpVendorSearch"),
      onlyUnlinked: document.getElementById("tpVendorUnlinked").checked ? "true" : "false" })}`);
    if (!res.ok) { body.innerHTML = empty(7, res.error); return; }
    body.innerHTML = (res.data.data || []).map(v => {
      const linked = F(v, "thirdPartyId");
      const suggested = F(v, "suggestedThirdPartyId");
      const actions = linked ? "" : `
        <button type="button" class="pm-button small" data-vendor-import="${esc(F(v, "vendorId"))}" data-mode="NEW">Import</button>
        <button type="button" class="pm-button small" data-vendor-import="${esc(F(v, "vendorId"))}" data-mode="NEW_ENG">Import + engagement</button>
        ${suggested ? `<button type="button" class="pm-button small" data-vendor-import="${esc(F(v, "vendorId"))}" data-mode="LINK:${esc(suggested)}" title="Link to the matching third party">Link to ${esc(F(v, "suggestedThirdPartyCode"))}</button>` : ""}`;
      return `<tr>
        <td>${esc(F(v, "vendorName"))}<div class="tprm-muted">${esc(F(v, "relationshipOwnerName") || "")}</div></td>
        <td>${esc(F(v, "serviceCategory") || "--")}</td>
        <td>${esc(F(v, "criticality") || "--")}</td>
        <td>${esc([date(F(v, "contractStartDt")), date(F(v, "contractEndDt"))].filter(Boolean).join(" to ") || "--")}</td>
        <td>${esc(F(v, "practiceInstanceCount") ?? 0)} instances, ${esc(F(v, "applicationCount") ?? 0)} applications, ${esc(F(v, "openRiskCount") ?? 0)} open risks</td>
        <td>${linked ? `${esc(F(v, "thirdPartyCode"))} ${esc(F(v, "thirdPartyName"))}` : (suggested ? `<span class="tprm-muted">Possible match: ${esc(F(v, "suggestedThirdPartyCode"))} ${esc(F(v, "suggestedThirdPartyName"))}</span>` : "--")}</td>
        <td>${CAN_ADD ? actions : ""}</td></tr>`;
    }).join("") || empty(7, "No vendors to import.");
  }
  async function importVendor(vendorId, mode, confirmDuplicates) {
    const link = mode.startsWith("LINK:") ? Number(mode.substring(5)) : null;
    const res = await api("POST", `/vendors/${vendorId}/import`, {
      organizationId: state.org, thirdPartyId: link, createEngagement: mode === "NEW_ENG", confirmDuplicates: !!confirmDuplicates });
    if (res.status === 409 && res.data.duplicate) {
      const names = (res.data.duplicates || []).map(d => [F(d, "matchCode"), F(d, "matchName")].filter(Boolean).join(" ")).join(", ");
      if (await T.confirm(`Possible duplicates: ${names}. Import as a separate third party anyway?`, "Possible duplicates", "Import anyway"))
        return importVendor(vendorId, mode, true);
      return;
    }
    if (!res.ok) { show("tpVendorMessage", res.error); return; }
    const r = res.data.result || {};
    show("tpVendorMessage", F(r, "engagementId") ? "Imported; an engagement was started for it." : "Imported.", "success");
    await loadVendors();
    await refreshList();
  }

  async function loadSamples() {
    if (!state.org) { show("tpMessage", "Select an organization."); return; }
    if (!await T.confirm("Load the GRAC sample third parties and engagements into this organization? They are marked as samples, are for illustration only and can be archived at any time.",
      "Load sample records", "Load samples")) return;
    const res = await api("POST", "/samples/load", { organizationId: state.org });
    if (!res.ok) { show("tpMessage", res.error); return; }
    show("tpMessage", `${F(res.data.result, "loadedCount") ?? 0} sample record(s) loaded.`, "success");
    await refreshList();
  }

  function val(id) { return (document.getElementById(id).value || "").trim(); }
})();
